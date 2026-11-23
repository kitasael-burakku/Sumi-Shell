"""T4 · núcleo de la sincronización tipográfica con otras apps (comentarios en español, textos en inglés).

Lo comparten los adaptadores (font_sync_gtk/kitty/qt6ct/vscodium/browsers) y el CLI `font-sync.py`:

  · Rutas: sólo bajo XDG_CONFIG_HOME, que tiene que estar dentro de HOME. Cada directorio del camino se abre
    con O_NOFOLLOW desde la base: un enlace simbólico (Stow, dotfiles enlazados) es un motivo para NO escribir.
  · Archivos: regulares, tuyos, un solo enlace, sin xattrs/ACL, UTF-8. Se sustituyen con renameat2(RENAME_EXCHANGE)
    y comparación de inodo + sha antes y después (mismo modelo que packaging/integrations.replace_file): si alguien
    escribió entre medias, nada cambia.
  · Registro (ledger): por propiedad, {before, set}. Volver atrás sólo si el valor actual sigue siendo `set`;
    si es otro, es un cambio tuyo posterior y se respeta (conflicto, se informa, no se escribe).
  · Cerrojo: flock en $XDG_RUNTIME_DIR/sumi-shell/typography-sync.lock (nunca se borra).
  · Ganchos de carrera sólo con KT_FONT_SYNC_TEST=1 y un HOME que no es el real (bancos).
"""
import ctypes
import errno
import fcntl
import hashlib
import json
import os
import pwd
import re
import stat
import subprocess
import time
import uuid

LEDGER_VERSION = 1
MARK = "Sumi Shell —"


class Refused(Exception):
    """Un motivo legible para no hacer algo; nunca deja nada a medias."""


def sha(data):
    return hashlib.sha256(data).hexdigest()


def normal(name):
    return " ".join(str(name or "").split()).casefold()


def real_home():
    return pwd.getpwuid(os.getuid()).pw_dir


def testing():
    """Ganchos de prueba sólo en bancos: variable explícita y HOME distinto del real."""
    return os.environ.get("KT_FONT_SYNC_TEST") == "1" and os.path.realpath(os.environ.get("HOME", "")) \
        != os.path.realpath(real_home())


def race(stage):
    """Banco: KT_FONT_SYNC_TEST_RACE=<archivo>:<etapa>:<texto> añade <texto> a <archivo> en esa etapa."""
    spec = os.environ.get("KT_FONT_SYNC_TEST_RACE", "")
    if not spec or not testing():
        return
    path, _, rest = spec.partition(":")
    want, _, text = rest.partition(":")
    if want == stage:
        if text == "!crash":                      # simular un corte del proceso a mitad
            os._exit(9)
        with open(path, "a") as f:
            f.write(text.replace("\\n", "\n"))


# ---- rutas -------------------------------------------------------------------------------------------------------

class Paths:
    def __init__(self, env=None):
        env = env or os.environ
        home = env.get("HOME") or real_home()
        if not os.path.isabs(home):
            raise Refused("HOME is not an absolute path")
        self.home = os.path.realpath(home)
        cfg = env.get("XDG_CONFIG_HOME") or os.path.join(self.home, ".config")
        state = env.get("XDG_STATE_HOME") or os.path.join(self.home, ".local", "state")
        for name, p in (("XDG_CONFIG_HOME", cfg), ("XDG_STATE_HOME", state)):
            if not os.path.isabs(p):
                raise Refused("%s is not an absolute path" % name)
        self.config = os.path.abspath(cfg)
        self.state = os.path.abspath(state)
        for name, p in (("XDG_CONFIG_HOME", self.config), ("XDG_STATE_HOME", self.state)):
            if os.path.commonpath([p, self.home]) != self.home:
                raise Refused("%s (%s) is outside your home folder" % (name, p))
        self.runtime = env.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()
        self.sync_state = os.path.join(self.state, "sumi-shell", "typography-sync")

    def rel(self, path):
        """Partes de `path` relativas a XDG_CONFIG_HOME, o Refused."""
        a = os.path.abspath(path)
        if os.path.commonpath([a, self.config]) != self.config or a == self.config:
            raise Refused("%s is outside %s" % (path, self.config))
        return os.path.relpath(a, self.config).split(os.sep)


def _open_base(base):
    """La base (XDG_CONFIG_HOME) se abre siguiendo enlaces: puede ser un enlace del usuario, igual que su HOME;
    lo que NO se sigue es nada por debajo."""
    return os.open(base, os.O_RDONLY | os.O_DIRECTORY)


def open_dir(base, parts, create=False, created=None):
    """fd del directorio base/parts[0]/…, cada paso con O_NOFOLLOW. `created`: lista de los que se crearon."""
    fd = _open_base(base)
    walked = []
    try:
        for part in parts:
            if part in ("", ".", ".."):
                raise Refused("unsafe path component %r" % part)
            here = os.path.join(base, *walked, part)
            try:
                nfd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            except FileNotFoundError:
                if not create:
                    raise
                os.mkdir(part, 0o755, dir_fd=fd)
                if created is not None:
                    created.append("/".join(walked + [part]))
                nfd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            except OSError as e:
                if e.errno in (errno.ELOOP, errno.ENOTDIR):
                    raise Refused("%s is a symbolic link or not a folder (dotfiles managers like Stow do this): "
                                  "not followed" % here)
                raise
            st = os.fstat(nfd)
            if st.st_uid != os.getuid():
                os.close(nfd)
                raise Refused("%s is not yours" % here)
            os.close(fd)
            fd = nfd
            walked.append(part)
        return fd
    except BaseException:
        os.close(fd)
        raise


def read_regular(dfd, name):
    """(stat, bytes) de un archivo regular sin seguir enlaces."""
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise Refused("%s is not a regular file" % name)
        chunks = []
        while True:
            b = os.read(fd, 1 << 16)
            if not b:
                break
            chunks.append(b)
        return st, b"".join(chunks)
    finally:
        os.close(fd)


def file_problems(paths, path, must_exist=True):
    """Motivos por los que `path` no se puede editar con seguridad (lista vacía = se puede)."""
    try:
        parts = paths.rel(path)
    except Refused as e:
        return [str(e)]
    try:
        dfd = open_dir(paths.config, parts[:-1])
    except FileNotFoundError:
        return ["%s doesn't exist" % os.path.dirname(path)] if must_exist else []
    except Refused as e:
        return [str(e)]
    why = []
    try:
        try:
            st = os.stat(parts[-1], dir_fd=dfd, follow_symlinks=False)
        except FileNotFoundError:
            return ["%s doesn't exist" % path] if must_exist else []
        if stat.S_ISLNK(st.st_mode):
            return ["%s is a symbolic link (dotfiles managers like Stow do this): not followed" % path]
        if not stat.S_ISREG(st.st_mode):
            return ["%s is not a regular file" % path]
        if st.st_uid != os.getuid():
            why.append("%s is not yours" % path)
        if st.st_nlink != 1:
            why.append("%s has other hard links: replacing it would split them" % path)
        try:
            if os.listxattr(path, follow_symlinks=False):
                why.append("%s has extended attributes or an ACL that replacing it would lose" % path)
        except OSError:
            pass
        try:
            read_regular(dfd, parts[-1])[1].decode("utf-8")
        except (OSError, UnicodeDecodeError):
            why.append("%s is not readable UTF-8 text" % path)
    finally:
        os.close(dfd)
    return why


def read_file(paths, path):
    """(stat, bytes) o (None, None) si no existe. Refused si el camino no es seguro."""
    parts = paths.rel(path)
    try:
        dfd = open_dir(paths.config, parts[:-1])
    except FileNotFoundError:
        return None, None
    try:
        return read_regular(dfd, parts[-1])
    except FileNotFoundError:
        return None, None
    finally:
        os.close(dfd)


_libc = ctypes.CDLL(None, use_errno=True)
_RENAME_NOREPLACE, _RENAME_EXCHANGE = 1, 2
_AT_FDCWD = -100


def _renameat2(sfd, src, dfd, dst, flags):
    try:
        fn = _libc.renameat2
    except AttributeError:
        raise Refused("renameat2 isn't available: atomic replacement not supported here")
    fn.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    if fn(sfd, src.encode(), dfd, dst.encode(), flags) != 0:
        e = ctypes.get_errno()
        raise OSError(e, os.strerror(e))


def write_new(dfd, name, data, mode):
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode, dir_fd=dfd)
    try:
        os.fchmod(fd, mode)
        view = memoryview(data)
        while view:
            n = os.write(fd, view)
            view = view[n:]
        os.fsync(fd)
    finally:
        os.close(fd)


def replace(paths, path, want_ino, want_sha, new):
    """Sustituye `path` por `new` si sigue siendo (want_ino, want_sha).
    'done' · 'changed' (cambió antes o durante: nada cambió) · 'conflict' (cambió y no se puede deshacer limpio)."""
    parts = paths.rel(path)
    dfd = open_dir(paths.config, parts[:-1])
    name = parts[-1]
    cand = ".%s.sumi-fontsync-%s" % (name, uuid.uuid4().hex[:12])
    try:
        try:
            st, data = read_regular(dfd, name)
        except FileNotFoundError:
            return "changed"
        if (st.st_ino, sha(data)) != (want_ino, want_sha):
            return "changed"
        write_new(dfd, cand, new, stat.S_IMODE(st.st_mode))
        c_ino = os.stat(cand, dir_fd=dfd, follow_symlinks=False).st_ino
        race("before-exchange")
        try:
            _renameat2(dfd, cand, dfd, name, _RENAME_EXCHANGE)
        except OSError as e:
            os.unlink(cand, dir_fd=dfd)
            if e.errno in (errno.EINVAL, errno.ENOSYS, errno.EOPNOTSUPP):
                raise Refused("this filesystem can't exchange files atomically (RENAME_EXCHANGE)")
            if e.errno == errno.ENOENT:
                return "changed"
            raise
        try:
            ost, odata = read_regular(dfd, cand)
        except FileNotFoundError:
            ost, odata = None, b""
        if ost is not None and (ost.st_ino, sha(odata)) == (want_ino, want_sha):
            os.unlink(cand, dir_fd=dfd)              # la copia previa ya está en la transacción
            os.fsync(dfd)
            return "done"
        # cambió entre leerlo e intercambiarlo: devolver su versión si el principal sigue siendo la nuestra
        try:
            mst, mdata = read_regular(dfd, name)
        except FileNotFoundError:
            mst, mdata = None, b""
        if mst is not None and mst.st_ino == c_ino and sha(mdata) == sha(new):
            _renameat2(dfd, cand, dfd, name, _RENAME_EXCHANGE)
            cst, cdata = read_regular(dfd, cand)
            if cst.st_ino == c_ino and sha(cdata) == sha(new):
                os.unlink(cand, dir_fd=dfd)
            return "changed"
        return "conflict"
    finally:
        os.close(dfd)


def create(paths, path, data, mode=0o644, created_dirs=None):
    """Crea `path` (no puede existir). Los directorios que falten se crean sin seguir enlaces."""
    parts = paths.rel(path)
    dfd = open_dir(paths.config, parts[:-1], create=True, created=created_dirs)
    try:
        try:
            write_new(dfd, parts[-1], data, mode)
        except FileExistsError:
            return "exists"
        os.fsync(dfd)
        return "done"
    finally:
        os.close(dfd)


def remove(paths, path, want_sha):
    """Borra `path` sólo si su contenido sigue siendo `want_sha`: se aparta con RENAME_NOREPLACE, se comprueba lo
    apartado y sólo entonces se borra. 'done' · 'absent' · 'changed'."""
    parts = paths.rel(path)
    try:
        dfd = open_dir(paths.config, parts[:-1])
    except FileNotFoundError:
        return "absent"
    name = parts[-1]
    aside = ".%s.sumi-fontsync-rm-%s" % (name, uuid.uuid4().hex[:12])
    try:
        try:
            st, data = read_regular(dfd, name)
        except FileNotFoundError:
            return "absent"
        if sha(data) != want_sha:
            return "changed"
        race("before-remove")
        _renameat2(dfd, name, dfd, aside, _RENAME_NOREPLACE)
        ast, adata = read_regular(dfd, aside)
        if ast.st_ino == st.st_ino and sha(adata) == want_sha:
            os.unlink(aside, dir_fd=dfd)
            os.fsync(dfd)
            return "done"
        try:                                         # no era lo leído: devolverlo a su nombre
            _renameat2(dfd, aside, dfd, name, _RENAME_NOREPLACE)
        except OSError:
            pass
        return "changed"
    finally:
        os.close(dfd)


def remove_dirs(paths, rels):
    """Directorios que creó la sincronización, de los más hondos a los menos, si están vacíos."""
    for rel in sorted(set(rels or []), key=lambda r: -r.count("/")):
        p = os.path.join(paths.config, rel)
        try:
            if not os.path.islink(p) and os.path.isdir(p):
                os.rmdir(p)
        except OSError:
            pass


# ---- estado, cerrojo y registro ----------------------------------------------------------------------------------

def private_dir(path):
    os.makedirs(path, mode=0o700, exist_ok=True)
    st = os.stat(path, follow_symlinks=False)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) & 0o077:
        raise Refused("%s is not a private folder of yours" % path)
    return path


def take_lock(paths):
    run = paths.runtime
    try:
        st = os.stat(run, follow_symlinks=False)
    except OSError:
        raise Refused("%s doesn't exist: the font sync needs your runtime folder for its lock" % run)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) & 0o077:
        raise Refused("%s is not a private folder of yours" % run)
    # $XDG_RUNTIME_DIR/sumi-shell lo comparte la shell (grabador, temas) y en una sesión real es 0755 (medido
    # en el banco anidado 2026-11-05): basta con que sea tuyo, no un enlace y sin escritura de grupo/otros; el
    # runtime de encima ya es 0700.
    d = os.path.join(run, "sumi-shell")
    os.makedirs(d, mode=0o700, exist_ok=True)
    st = os.stat(d, follow_symlinks=False)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) & 0o022:
        raise Refused("%s is not a folder only you can write to" % d)
    fd = os.open(os.path.join(d, "typography-sync.lock"), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
        os.close(fd)
        raise Refused("the font sync lock is not a regular file of yours")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        raise Refused("another font sync is running")
    return fd


def write_json_atomic(path, doc):
    d = os.path.dirname(path)
    tmp = os.path.join(d, ".%s.%s" % (os.path.basename(path), uuid.uuid4().hex[:8]))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.write(fd, (json.dumps(doc, indent=1, sort_keys=True, ensure_ascii=False) + "\n").encode())
        os.fsync(fd)
    finally:
        os.close(fd)
    os.rename(tmp, path)


class Ledger:
    """{"version":1, "entries": {slot: entrada}, "log": [...]}. Una entrada por propiedad gestionada."""

    def __init__(self, paths):
        self.paths = paths
        self.path = os.path.join(paths.sync_state, "ledger.json")
        self.doc = {"version": LEDGER_VERSION, "entries": {}, "log": []}

    def load(self):
        try:
            st = os.stat(self.path, follow_symlinks=False)
        except FileNotFoundError:
            return self
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
            raise Refused("%s is not a regular file of yours" % self.path)
        try:
            doc = json.load(open(self.path))
        except ValueError:
            raise Refused("%s is damaged: nothing is changed until it's fixed or removed by you" % self.path)
        if not isinstance(doc, dict) or doc.get("version") != LEDGER_VERSION or not isinstance(doc.get("entries"), dict):
            raise Refused("%s has a format this version doesn't understand: nothing is changed" % self.path)
        self.doc = doc
        self.doc.setdefault("log", [])
        return self

    def save(self):
        private_dir(self.paths.sync_state)
        self.doc["log"] = self.doc["log"][-200:]
        write_json_atomic(self.path, self.doc)

    @property
    def entries(self):
        return self.doc["entries"]

    def note(self, event, **kw):
        self.doc["log"].append(dict(kw, event=event, at=round(time.time(), 3)))


def new_tx(paths):
    tx = time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]
    d = os.path.join(private_dir(paths.sync_state), "tx")
    private_dir(d)
    os.mkdir(os.path.join(d, tx), 0o700)
    return tx, os.path.join(d, tx)


def keep_copy(txdir, label, st, data):
    """Copia previa de un archivo dentro de la transacción (contenido, modo y sha)."""
    name = re.sub(r"[^A-Za-z0-9._-]", "_", label)
    with open(os.path.join(txdir, name), "xb") as f:
        f.write(data)
    meta = {"sha256": sha(data), "mode": oct(stat.S_IMODE(st.st_mode)), "uid": st.st_uid, "mtime": st.st_mtime,
            "inode": st.st_ino, "size": st.st_size}
    with open(os.path.join(txdir, name + ".json"), "x") as f:
        json.dump(meta, f, indent=1)
    return name


# ---- fuentes (Fontconfig: es lo que usan GTK, Qt, kitty y Electron) ----------------------------------------------

def inventory():
    """{normal: {"name", "spacing": {90,100,…} (0 = cara sin «spacing»), "file": una cara Regular si hay}}."""
    try:
        r = subprocess.run(["fc-list", "--format=%{family}\t%{spacing}\t%{style[0]}\t%{file}\n"],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise Refused("Fontconfig isn't available (%s)" % e)
    if r.returncode:
        raise Refused("fc-list failed")
    out = {}
    for line in r.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 4:
            continue
        fams, spacing, style, path = parts
        sp = {int(x) for x in spacing.split(",") if x.strip().isdigit()}
        for n in fams.split(","):
            n = n.strip()
            if not n:
                continue
            e = out.setdefault(normal(n), {"name": n, "spacing": set(), "faces": 0, "file": path})
            e["faces"] += 1
            e["spacing"] |= sp or {0}
            if style.strip().lower() in ("regular", "book", "normal"):
                e["file"] = path
    return out


_MEASURED = {}


def measure(path):
    """'mono' · 'proportional' · 'unknown': avances de «iMW0.» con fontTools (opcional). Los metadatos
    (post.isFixedPitch, PANOSE) no sirven: medido 2026-11-05, IosevkaTerm Propo declara PANOSE 9 y
    Noto Sans Mono isFixedPitch=0."""
    if path in _MEASURED:
        return _MEASURED[path]
    res = "unknown"
    try:
        from fontTools.ttLib import TTFont
        t = TTFont(path, lazy=True, fontNumber=0)
        cmap, hmtx = t.getBestCmap(), t["hmtx"]
        adv = {hmtx[cmap[ord(c)]][0] for c in "iMW0." if ord(c) in cmap}
        if len(adv) >= 1 and len([c for c in "iMW0." if ord(c) in cmap]) >= 4:
            if len(adv) != 1:
                res = "proportional"
            else:
                # letras de un ancho; los iconos (área privada, Nerd Fonts) también tienen que caber en 1 o 2
                # celdas: las variantes «Propo» las tienen de cientos de anchos (medido: 530 en IosevkaTerm Propo)
                w = adv.pop()
                pua = {hmtx[g][0] for cp, g in cmap.items() if 0xE000 <= cp <= 0xF8FF or 0xF0000 <= cp <= 0xFFFFD}
                res = "mono" if pua <= {0, w, 2 * w} else "proportional"
        t.close()
    except Exception:
        res = "unknown"
    _MEASURED[path] = res
    return res


def monospace(entry):
    """'mono' · 'proportional' · 'unknown' para una familia del inventario. Fontconfig manda si lo dice
    (90 dual, 100 mono, 110 celda); si no lo dice, se mide."""
    if not entry:
        return "unknown"
    if entry["spacing"] and entry["spacing"] <= {90, 100, 110}:
        return "mono"
    return measure(entry.get("file") or "")


def monospaced(entry):
    return monospace(entry) == "mono"


SAFE_FAMILY = re.compile(r"^[^\x00-\x1f\x7f]{1,160}$")


def family_ok(name, forbid=""):
    """Un nombre de familia que se puede escribir: sin controles, sin espacios al borde, sin los caracteres
    que el formato del destino no sabe proteger (`forbid`)."""
    return isinstance(name, str) and bool(SAFE_FAMILY.match(name)) and name == name.strip() \
        and not any(c in name for c in forbid)
