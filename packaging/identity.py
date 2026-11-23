"""Sumi Shell installer — `install.sh migrate identity-v1`: the state of the shell under its former name (2026-11-07).

Comentarios en español, textos en inglés. Antes del cambio de nombre la shell se llamaba Kitasan-Shell y guardaba su estado
en `$XDG_{CONFIG,STATE,DATA}_HOME/kitasan-shell`; ahora es `…/sumi-shell` (docs/sumi-shell/MIGRATION-PLAN.md §4).

    migrate identity-v1            qué haría, sin escribir nada
    migrate identity-v1 --apply    COPIA los tres directorios (con todas las shells paradas); los viejos no se tocan
    migrate identity-v1 --recover  retira lo que dejó una copia cortada (sólo lo marcado como suyo)
    migrate identity-v1 --revert   quita la copia SÓLO si nada cambió desde entonces (sha de cada archivo)

Reglas:
  · Nada se mueve ni se borra en el origen. Nada se sobrescribe: cada base se copia a `.sumi-shell.partial-<tx>` (con
    una marca propia dentro) y entra con renameat2(RENAME_NOREPLACE). Un `sumi-shell` que ya exista sin registro = conflicto.
  · Todo por descriptores de directorio y O_NOFOLLOW; un enlace, un archivo especial o algo ajeno en el origen → se niega
    antes de escribir nada.
  · Con cualquier shell en marcha (ésta o la de antes) o un helper de cualquiera de las dos vivo (grabador, calendario,
    sincronización…), se niega: escriben estos archivos.
  · Se verifica la copia (mismos archivos, tamaños, modos y sha256) y, si hay calendario, `PRAGMA integrity_check` sobre una
    copia temporal (ni el origen ni la copia se abren con SQLite).
  · En los JSON copiados se reescriben las cadenas que EMPIEZAN por una ruta vieja de estos directorios (absoluta o con ~) y
    sólo si el archivo nombrado existe en la copia con el mismo contenido (el registro de la sincronización de fuentes y
    providers.json guardan rutas así). Lo demás se informa y se deja.
  · El registro `identity-migration-v1.json` se escribe EL ÚLTIMO, en el estado nuevo: es lo que dice «hecho».
"""
import hashlib
import json
import os
import shutil
import sqlite3
import stat
import tempfile
import time

I = None
ID = "identity-v1"
OLD, NEW = "kitasan-shell", "sumi-shell"
BASES = (("config", "XDG_CONFIG_HOME", ".config"), ("state", "XDG_STATE_HOME", ".local/state"),
         ("data", "XDG_DATA_HOME", ".local/share"))
TILDE = {"config": "~/.config", "state": "~/.local/state", "data": "~/.local/share"}
RECORD = "identity-migration-v1.json"
PARTIAL = ".%s.partial-" % NEW
PARTIAL_MARK = ".sumi-identity-partial"
# Lo que escribe cualquiera de las dos shells (procesos fuera de la shell: grabador, calendario, fuentes, fondos…)
HELPER_PATHS = ("/quickshell/kitasan/scripts/", "/quickshell/sumi/scripts/")


def sha(b):
    return hashlib.sha256(b).hexdigest()


class Refused(Exception):
    pass


# ---- bases --------------------------------------------------------------------------------------------------------

def bases():
    """{key: real} de config/state/data, absolutas y dentro de HOME (las mismas reglas que Roots del instalador)."""
    home = os.environ.get("HOME", "")
    if not os.path.isabs(home):
        raise I.Refused(["HOME is not an absolute path"])
    home_real = os.path.realpath(home)
    out, problems = {}, []
    for key, var, default in BASES:
        p = os.environ.get(var) or os.path.join(home, default)
        if not os.path.isabs(p):
            problems.append("%s=%s is not an absolute path" % (var, p))
            continue
        r = os.path.realpath(p)
        if os.path.commonpath([r, home_real]) != home_real:
            problems.append("%s (%s) is outside your home: not supported" % (key, r))
        out[key] = {"path": p, "real": r}
    if problems:
        raise I.Refused(problems)
    return out


def open_base(real):
    fd = os.open(real, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    if os.fstat(fd).st_uid != os.geteuid():
        os.close(fd)
        raise I.Refused(["%s is not yours" % real])
    return fd


def lstat_at(dfd, name):
    try:
        return os.stat(name, dir_fd=dfd, follow_symlinks=False)
    except FileNotFoundError:
        return None


def subdir(dfd, name):
    return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dfd)


def read_at(dfd, name):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise Refused("%s is not a regular file" % name)
        chunks = []
        while True:
            b = os.read(fd, 1 << 16)
            if not b:
                return b"".join(chunks), st
            chunks.append(b)
    finally:
        os.close(fd)


# ---- inventario de un árbol (sin escribir) ------------------------------------------------------------------------

def inventory(dfd, rel="", out=None, problems=None):
    """{rel: (tipo, modo, tamaño, sha|None, mtime_ns)} de un directorio abierto; los problemas se acumulan."""
    out = {} if out is None else out
    problems = [] if problems is None else problems
    for name in sorted(os.listdir(dfd)):
        r = os.path.join(rel, name)
        st = lstat_at(dfd, name)
        if st is None:
            continue
        if st.st_uid != os.geteuid():
            problems.append("%s is not yours" % r)
            continue
        if stat.S_ISLNK(st.st_mode):
            problems.append("%s is a symbolic link" % r)
        elif stat.S_ISDIR(st.st_mode):
            out[r] = ("dir", stat.S_IMODE(st.st_mode), 0, None, st.st_mtime_ns)
            cfd = subdir(dfd, name)
            try:
                inventory(cfd, r, out, problems)
            finally:
                os.close(cfd)
        elif stat.S_ISREG(st.st_mode):
            data, fst = read_at(dfd, name)
            out[r] = ("file", stat.S_IMODE(fst.st_mode), len(data), sha(data), fst.st_mtime_ns)
        else:
            problems.append("%s is not a regular file or a directory" % r)
    return out, problems


def same(a, b):
    """Mismos archivos, tipos, modos, tamaños y contenido (los mtime de los directorios no cuentan)."""
    if set(a) != set(b):
        return False
    return all(a[k][:4] == b[k][:4] for k in a)


# ---- estado ---------------------------------------------------------------------------------------------------------

def look(B=None):
    """{state, why, bases:{key:{old, new, partial}}, record}: sin escribir nada."""
    B = B or bases()
    res = {"id": ID, "bases": {}, "record": None}
    for key, b in B.items():
        info = {"old": False, "new": False, "partial": [], "real": b["real"]}
        if os.path.isdir(b["real"]):
            fd = open_base(b["real"])
            try:
                o, n = lstat_at(fd, OLD), lstat_at(fd, NEW)
                info["old"] = o is not None and stat.S_ISDIR(o.st_mode)
                info["oldOdd"] = o is not None and not stat.S_ISDIR(o.st_mode)
                info["new"] = n is not None
                info["partial"] = [x for x in os.listdir(fd) if x.startswith(PARTIAL)]
                info["markedNew"] = False
                if n is not None and stat.S_ISDIR(n.st_mode):
                    nfd = subdir(fd, NEW)
                    try:
                        info["markedNew"] = lstat_at(nfd, PARTIAL_MARK) is not None
                    finally:
                        os.close(nfd)
                if key == "state" and info["new"] and n is not None and stat.S_ISDIR(n.st_mode):
                    nfd = subdir(fd, NEW)
                    try:
                        data, _ = read_at(nfd, RECORD)
                        res["record"] = json.loads(data)
                    except (FileNotFoundError, Refused, ValueError):
                        pass
                    finally:
                        os.close(nfd)
            finally:
                os.close(fd)
        res["bases"][key] = info
    olds = [k for k, i in res["bases"].items() if i["old"]]
    odd = [k for k, i in res["bases"].items() if i.get("oldOdd")]
    partial = [k for k, i in res["bases"].items() if i["partial"] or (i.get("markedNew") and res["record"] is None)]
    if partial:
        res["state"], res["why"] = "partial", "an earlier copy was interrupted in %s: run `install.sh migrate %s " \
                                              "--recover`" % (", ".join(partial), ID)
    elif res["record"] is not None:
        res["state"], res["why"] = "done", "copied on %s" % res["record"].get("at", "?")
    elif odd:
        res["state"], res["why"] = "conflict", "%s/%s is not a directory" % (odd[0], OLD)
    elif not olds:
        res["state"], res["why"] = "not-applicable", "there is no state from Kitasan-Shell here"
    elif any(res["bases"][k]["new"] for k in res["bases"]):
        res["state"], res["why"] = "conflict", "%s already exists without a record of this migration: it is left as " \
                                               "it is (move one of them aside by hand)" % ", ".join(
            "%s/%s" % (k, NEW) for k in res["bases"] if res["bases"][k]["new"])
    else:
        res["state"], res["why"] = "pending", "state of the former name in %s" % ", ".join(olds)
    return res


# ---- precondiciones -------------------------------------------------------------------------------------------------

def helpers_running():
    """Procesos con un helper de cualquiera de las dos shells en su línea de órdenes (por /proc; SUMI_PROC en el banco)."""
    proc = os.environ.get("SUMI_PROC", "/proc")
    found = []
    try:
        pids = [p for p in os.listdir(proc) if p.isdigit()]
    except OSError:
        return [{"pid": "?", "cmd": "can't read %s" % proc}]
    for pid in pids:
        try:
            with open(os.path.join(proc, pid, "cmdline"), "rb") as f:
                cmd = f.read().replace(b"\0", b" ").decode("utf-8", "replace")
        except OSError:
            continue
        if int(pid) != os.getpid() and any(h in cmd for h in HELPER_PATHS):
            found.append({"pid": pid, "cmd": cmd.strip()[:120]})
    return found


# ---- copia ----------------------------------------------------------------------------------------------------------

def copy_tree(src_fd, dst_fd, inv, rel=""):
    """Copia lo inventariado: directorios con su modo, archivos con O_EXCL, su modo y su mtime."""
    for name in sorted(os.listdir(src_fd)):
        r = os.path.join(rel, name)
        if r not in inv:
            continue
        kind, mode = inv[r][0], inv[r][1]
        if kind == "dir":
            os.mkdir(name, 0o700, dir_fd=dst_fd)
            s, d = subdir(src_fd, name), subdir(dst_fd, name)
            try:
                copy_tree(s, d, inv, r)
                os.fchmod(d, mode)
            finally:
                os.close(s)
                os.close(d)
        else:
            data, st = read_at(src_fd, name)
            if sha(data) != inv[r][3]:
                raise I.Refused(["%s changed while it was being copied: stopped (the original is untouched)" % r])
            I.fault("identity-file", "before")
            fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dst_fd)
            try:
                os.write(fd, data)
                os.fchmod(fd, mode)
                os.fsync(fd)
                os.utime(fd, ns=(st.st_atime_ns, st.st_mtime_ns))
            finally:
                os.close(fd)


def old_prefixes(B):
    """Las formas en que un archivo puede nombrar los directorios viejos: absoluta (real y la de la variable) y con ~."""
    out = []
    for key, b in B.items():
        new_real = os.path.join(b["real"], NEW)
        for p in {os.path.join(b["real"], OLD), os.path.join(b["path"], OLD)}:
            out.append((p, os.path.join(os.path.dirname(p), NEW), key, new_real))
        default_home = os.path.join(os.path.realpath(os.environ["HOME"]), TILDE[key][2:])
        if os.path.realpath(b["real"]) == os.path.realpath(default_home):
            out.append((TILDE[key] + "/" + OLD, TILDE[key] + "/" + NEW, key, new_real))
    return out


def rewrite_json(path_fd, name, prefixes, partials, report, rel):
    """Reescribe en un JSON de la copia las cadenas que empiezan por una ruta vieja (con destino idéntico en la copia)."""
    data, st = read_at(path_fd, name)
    try:
        doc = json.loads(data)
    except ValueError:
        return
    changes = {}

    def mapped(s):
        for old, new, key, _ in prefixes:
            if s == old or s.startswith(old + "/"):
                rest = s[len(old):].lstrip("/")
                return new + ("/" + rest if rest else ""), key, rest
        return None

    def visit(x):
        if isinstance(x, dict):
            for v in x.values():
                visit(v)
        elif isinstance(x, list):
            for v in x:
                visit(v)
        elif isinstance(x, str):
            m = mapped(x)
            if m and x not in changes:
                new, key, rest = m
                if key not in partials:
                    report.append("%s: left %s as it is (nothing was copied for %s)" % (rel, x, key))
                    changes[x] = x
                    return
                target = os.path.join(partials[key], rest) if rest else partials[key]
                oldp = os.path.expanduser(x)
                if os.path.lexists(oldp) and os.path.lexists(target) and (
                        os.path.isdir(target) or (os.path.isfile(oldp) and open(oldp, "rb").read() ==
                                                  open(target, "rb").read())):
                    changes[x] = new
                else:
                    report.append("%s: left %s as it is (nothing identical at the new place)" % (rel, x))
    visit(doc)
    changes = {k: v for k, v in changes.items() if k != v}
    if not changes:
        return
    text = data.decode("utf-8")
    for old, new in changes.items():
        text = text.replace(json.dumps(old)[1:-1].join('""'), json.dumps(new)[1:-1].join('""'))

    def expect(x):
        if isinstance(x, dict):
            return {k: expect(v) for k, v in x.items()}
        if isinstance(x, list):
            return [expect(v) for v in x]
        return changes.get(x, x) if isinstance(x, str) else x
    if json.loads(text) != expect(doc):
        report.append("%s: its paths could not be rewritten exactly: left as it is" % rel)
        return
    tmp = ".%s.sumi-identity-%d" % (name, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=path_fd)
    try:
        os.write(fd, text.encode("utf-8"))
        os.fchmod(fd, stat.S_IMODE(st.st_mode))
        os.fsync(fd)
    finally:
        os.close(fd)
    os.rename(tmp, name, src_dir_fd=path_fd, dst_dir_fd=path_fd)   # dentro de la copia propia, aún sin publicar
    report.append("%s: %d path(s) now name %s" % (rel, len(changes), NEW))


def clear_marks(B):
    """Quita la marca de cada `sumi-shell` publicado (sólo el archivo de la marca, si es de esta migración)."""
    for key, b in B.items():
        p = os.path.join(b["real"], NEW)
        if not os.path.isdir(p) or os.path.islink(p):
            continue
        fd = os.open(p, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            try:
                mark, _ = read_at(fd, PARTIAL_MARK)
            except (FileNotFoundError, Refused):
                continue
            try:
                ok = json.loads(mark).get("id") == ID
            except ValueError:
                ok = False
            if ok:
                os.unlink(PARTIAL_MARK, dir_fd=fd)
                os.fsync(fd)
        finally:
            os.close(fd)


def walk_json(dfd, rel, fn):
    for name in sorted(os.listdir(dfd)):
        r = os.path.join(rel, name)
        st = lstat_at(dfd, name)
        if stat.S_ISDIR(st.st_mode):
            c = subdir(dfd, name)
            try:
                walk_json(c, r, fn)
            finally:
                os.close(c)
        elif stat.S_ISREG(st.st_mode) and name.endswith(".json") and name != PARTIAL_MARK:
            fn(dfd, name, r)


def sqlite_ok(src_dir):
    """`PRAGMA integrity_check` de cada *.sqlite3 de la copia, sobre OTRA copia temporal (con su -wal/-shm)."""
    bad = []
    for root, _dirs, files in os.walk(src_dir):
        for f in files:
            if not f.endswith(".sqlite3"):
                continue
            with tempfile.TemporaryDirectory(prefix="sumi-identity-db-") as t:
                for ext in ("", "-wal", "-shm"):
                    if os.path.isfile(os.path.join(root, f + ext)):
                        shutil.copy2(os.path.join(root, f + ext), os.path.join(t, f + ext))
                try:
                    c = sqlite3.connect(os.path.join(t, f))
                    r = c.execute("PRAGMA integrity_check").fetchone()[0]
                    c.close()
                except sqlite3.Error as e:
                    r = str(e)
                if r != "ok":
                    bad.append("%s: %s" % (os.path.relpath(os.path.join(root, f), src_dir), r))
    return bad


# ---- órdenes ---------------------------------------------------------------------------------------------------------

class Identity:
    def __init__(self, migrator):
        self.m = migrator
        self.say = migrator.say
        self.args = migrator.args

    def preview(self):
        r = look()
        self.say("%s: %s — %s" % (ID, r["state"], r["why"]))
        self.say("  copies the state of the former name (%s) into %s, in config, state and data; the originals stay"
                 % (OLD, NEW))
        for k, i in r["bases"].items():
            self.say("  %-6s %s/%s: %s" % (k, i["real"], OLD, "present" if i["old"] else "absent"))
        if r["state"] == "pending":
            self.say("  run `install.sh migrate %s --apply` with every shell stopped" % ID)
        return I.EXIT_OK if r["state"] in ("pending", "done", "not-applicable") else I.EXIT_REFUSED

    def preconditions(self):
        self.m.no_shell()
        h = helpers_running()
        if h:
            raise I.Refused(["a helper of the shell is still running (pid %s: %s): wait for it or stop it; it writes "
                             "these files" % (h[0]["pid"], h[0]["cmd"])])

    def apply(self):
        self.preconditions()
        B = bases()
        lock = I.take_lock()
        try:
            r = look(B)
            if r["state"] in ("done", "not-applicable"):
                if r["state"] == "done":
                    clear_marks(B)       # un corte entre el registro y el final dejó marcas: se completan
                self.say("%s: %s; nothing to do." % (ID, r["why"]))
                return I.EXIT_OK
            if r["state"] != "pending":
                raise I.Refused(["%s is %s: %s" % (ID, r["state"], r["why"])])
            # 1) inventario y comprobación de TODO el origen antes de escribir nada
            invs, problems = {}, []
            for key, i in r["bases"].items():
                if not i["old"]:
                    continue
                fd = open_base(i["real"])
                try:
                    ofd = subdir(fd, OLD)
                    try:
                        invs[key], p = inventory(ofd)
                        problems += ["%s/%s/%s" % (key, OLD, x) for x in p]
                    finally:
                        os.close(ofd)
                finally:
                    os.close(fd)
            if problems:
                raise I.Refused(["the old state can't be copied safely (nothing was written): " + problems[0]] +
                                problems[1:5])
            # D-10: una instalación del instalador de antes (su manifiesto) no se convierte: el nuevo no entiende ese formato
            if any(p.startswith("install/") for p in invs.get("state", {})):
                raise I.Refused(["the old state has an installation made by the former installer (%s/%s/install): "
                                 "uninstall it with that installer first (`install.sh uninstall` from the Kitasan-Shell "
                                 "copy), then migrate; nothing was written" % (r["bases"]["state"]["real"], OLD)])
            tx = time.strftime("%Y%m%d-%H%M%S") + "-%d" % os.getpid()
            partials, report = {}, []
            # 2) copia a .sumi-shell.partial-<tx> con su marca, en cada base
            for key, inv in invs.items():
                fd = open_base(r["bases"][key]["real"])
                try:
                    pname = PARTIAL + tx
                    os.mkdir(pname, 0o700, dir_fd=fd)
                    partials[key] = os.path.join(r["bases"][key]["real"], pname)
                    pfd = subdir(fd, pname)
                    try:
                        I.write_new(pfd, PARTIAL_MARK, json.dumps({"id": ID, "tx": tx}).encode(), 0o600)
                        ofd = subdir(fd, OLD)
                        try:
                            copy_tree(ofd, pfd, inv)
                            omode = stat.S_IMODE(os.fstat(ofd).st_mode)
                        finally:
                            os.close(ofd)
                        os.fchmod(pfd, omode)
                    finally:
                        os.close(pfd)
                finally:
                    os.close(fd)
                I.fault("identity-base-" + key, "after")
            # 3) verificación: la copia (sin la marca) es el origen, y el origen no cambió entretanto
            for key, inv in invs.items():
                fd = open_base(r["bases"][key]["real"])
                try:
                    pfd, ofd = subdir(fd, os.path.basename(partials[key])), subdir(fd, OLD)
                    try:
                        cinv, _ = inventory(pfd)
                        cinv.pop(PARTIAL_MARK, None)
                        oinv, _ = inventory(ofd)
                    finally:
                        os.close(pfd)
                        os.close(ofd)
                finally:
                    os.close(fd)
                if not same(inv, cinv) or not same(inv, oinv):
                    raise I.Refused(["%s: the copy doesn't match the original (or the original changed): stopped; run "
                                     "`install.sh migrate %s --recover`" % (key, ID)])
            bad = sqlite_ok(partials["data"]) if "data" in partials else []
            if bad:
                raise I.Refused(["the calendar copy fails its integrity check (%s): stopped; run `install.sh migrate %s "
                                 "--recover`" % (bad[0], ID)])
            # 4) rutas viejas dentro de los JSON copiados
            pre = old_prefixes(B)
            for key in invs:
                fd = os.open(partials[key], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                try:
                    walk_json(fd, key, lambda dfd, name, rel: rewrite_json(dfd, name, pre, partials, report, rel))
                finally:
                    os.close(fd)
            # 5) publicar cada base (renameat2 NOREPLACE) y quitar la marca
            for key in invs:
                fd = open_base(r["bases"][key]["real"])
                try:
                    pname = os.path.basename(partials[key])
                    I.fault("identity-publish-" + key, "before")
                    I.rename_noreplace(fd, pname, fd, NEW)
                    os.fsync(fd)
                finally:
                    os.close(fd)
            # 6) el registro, lo último
            st = os.path.join(r["bases"]["state"]["real"], NEW)
            if not os.path.isdir(st):
                sfd = open_base(r["bases"]["state"]["real"])
                try:
                    os.mkdir(NEW, 0o755, dir_fd=sfd)
                finally:
                    os.close(sfd)
            final = {}
            for k in invs:
                nfd = os.open(os.path.join(r["bases"][k]["real"], NEW), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                try:
                    final[k], _ = inventory(nfd)
                    final[k].pop(PARTIAL_MARK, None)
                finally:
                    os.close(nfd)
            record = {"version": 1, "id": ID, "by": "install.sh migrate", "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                      "from": OLD, "to": NEW, "tx": tx,
                      "bases": {k: {"from": os.path.join(r["bases"][k]["real"], OLD),
                                    "to": os.path.join(r["bases"][k]["real"], NEW),
                                    "source": {p: v[3] for p, v in invs[k].items() if v[0] == "file"},
                                    "files": {p: v[3] for p, v in final[k].items() if v[0] == "file"}} for k in invs},
                      "rewritten": report}
            sfd = os.open(st, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                I.fault("identity-record", "before")
                I.write_new(sfd, RECORD, (json.dumps(record, indent=2) + "\n").encode(), 0o600)
                os.fsync(sfd)
            finally:
                os.close(sfd)
            I.fault("identity-marks", "before")
            clear_marks(B)
        finally:
            os.close(lock)
        for line in report:
            self.say("  " + line)
        self.say("%s: copied %s into %s. The originals in %s were not touched; keep them until you're happy." % (
            ID, ", ".join(sorted(invs)), NEW, ", ".join("%s/%s" % (k, OLD) for k in sorted(invs))))
        return I.EXIT_OK

    def recover(self):
        """Retira sólo los `.sumi-shell.partial-*` que llevan la marca de esta migración (nunca el origen)."""
        self.preconditions()
        B = bases()
        lock = I.take_lock()
        removed = []
        try:
            r = look(B)
            if r["record"] is not None:
                clear_marks(B)
                self.say("%s: the copy had finished (%s); leftover marks cleared." % (ID, r["why"]))
                return I.EXIT_OK
            for key, b in B.items():
                if not os.path.isdir(b["real"]):
                    continue
                fd = open_base(b["real"])
                try:
                    names = [x for x in os.listdir(fd) if x.startswith(PARTIAL)]
                    if r["bases"][key].get("markedNew"):
                        names.append(NEW)        # publicado pero sin registro: también es de esta migración
                    for name in names:
                        pfd = subdir(fd, name)
                        try:
                            mark, _ = read_at(pfd, PARTIAL_MARK)
                            ok = json.loads(mark).get("id") == ID
                        except (FileNotFoundError, Refused, ValueError):
                            ok = False
                        finally:
                            os.close(pfd)
                        if not ok:
                            raise I.Refused(["%s/%s has no mark of this migration: left as it is" % (b["real"], name)])
                        shutil.rmtree(os.path.join(b["real"], name))
                        removed.append("%s/%s" % (key, name))
                finally:
                    os.close(fd)
        finally:
            os.close(lock)
        self.say("%s: %s" % (ID, ("removed " + ", ".join(removed)) if removed else "nothing to recover"))
        return I.EXIT_OK

    def revert(self):
        """Quita la copia publicada sólo si cada archivo sigue con el sha registrado (ajustes tocados después = tuyos)."""
        self.preconditions()
        B = bases()
        lock = I.take_lock()
        try:
            r = look(B)
            if r["state"] != "done":
                raise I.Refused(["%s is %s: there's no copy to undo" % (ID, r["state"])])
            rec = r["record"]
            changed = []
            for key, b in rec["bases"].items():
                fd = os.open(b["to"], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                try:
                    inv, _ = inventory(fd)
                finally:
                    os.close(fd)
                files = {p: v[3] for p, v in inv.items() if v[0] == "file"}
                files.pop(PARTIAL_MARK, None)
                if key == "state":
                    files.pop(RECORD, None)
                for p, s in files.items():
                    if p in b["files"] and b["files"][p] != s:
                        changed.append("%s/%s" % (key, p))
                changed += ["%s/%s" % (key, p) for p in b["files"] if p not in files]
                changed += ["%s/%s (new)" % (key, p) for p in files if p not in b["files"]]
            if changed:
                raise I.Refused(["the copy changed since the migration (%s): those files are yours now; nothing was "
                                 "removed" % ", ".join(changed[:5])])
            for key, b in rec["bases"].items():
                shutil.rmtree(b["to"])
        finally:
            os.close(lock)
        self.say("%s: the copy was removed; the originals in %s were never touched." % (ID, OLD))
        return I.EXIT_OK


def run(installer_module, migrator):
    global I
    I = installer_module
    a = migrator.args
    ident = Identity(migrator)
    if getattr(a, "recover", False):
        return ident.recover()
    if a.apply:
        return ident.apply()
    if a.revert:
        return ident.revert()
    return ident.preview()


def listing_row(installer_module):
    global I
    I = installer_module
    try:
        r = look()
        return {"id": ID, "state": r["state"], "why": r["why"]}
    except Exception as e:      # el listado nunca se cae por esto
        return {"id": ID, "state": "unknown", "why": str(e)[:160]}
