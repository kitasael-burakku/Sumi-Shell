#!/usr/bin/env python3
"""Sumi Shell — user installer: install, uninstall, recover, status. Portability F6d, 2026-10-13.

    installer.py install   [--no-units] [--enable] [--dry-run]
    installer.py uninstall [--keep-modified] [--purge [--yes]] [--dry-run]
    installer.py recover   [--apply [--reload | --restart]]
    installer.py status
    installer.py update    [--apply | --finish | --verify | --rollback] …   (F6f: packaging/update.py)
    installer.py migrate   [ID [--apply | --revert]]                       (F6f: packaging/migrations.py)

Diseño: portabilidad/F6D-DISENO.md (aceptado, P7.5). Lo esencial:
  · Sólo es del instalador lo que creó y puede demostrar con evidencia registrada ANTES de crearlo (sha, la marca
    `.sumi-install` con el id, el destino de un enlace). La ruta no prueba nada. Ante la duda: conservar y parar.
  · Nada se sobrescribe: el árbol entra con renameat2(RENAME_NOREPLACE) y los archivos con O_EXCL/linkat; si el sistema
    de archivos no lo soporta, se niega. Todo se hace relativo a descriptores de directorio abiertos con O_NOFOLLOW.
  · XDG_CONFIG_HOME y XDG_STATE_HOME, dentro de HOME; ningún enlace debajo de ellos en las rutas que se tocan.
  · Nunca `systemctl disable`: se para la unidad y se quitan sólo los enlaces registrados.
  · Las activaciones D-Bus nunca se borran. La cadena del bloqueo se comprueba antes de desinstalar.
  · Cerrojo: flock sobre $XDG_RUNTIME_DIR/sumi-install.lock, que nunca se borra.
Salida: 0 hecho o nada que hacer · 1 rechazado o parcial · 2 fallo del instalador · 3 interrumpido (`recover`).
"""
import argparse
import ctypes
import ctypes.util
import errno
import fcntl
import hashlib
import importlib.util
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True

# Formato 2 (F6e, 2026-10-14): añade `integrations`. Se lee el 1 (F6d) y se convierte al guardar, dejando constancia en
# `formatHistory`. El instalador de F6d sólo acepta el 1: ante un 2 se niega sin tocar nada, en vez de desinstalar sin ver
# las integraciones y borrar el manifiesto con la prueba de qué líneas son suyas.
# Formato 3 (F6f, 2026-10-14): añade `tree` (versión, apiVersion e identidad de construcción del árbol en disco), `previous`
# (la generación anterior conservada), `update` (estado, instancia comprobada, settings.json antes/después). Los instaladores
# de F6d (sólo 1) y F6e (1 y 2) se niegan ante un 3 sin tocar nada (medido, P7.12).
FORMAT, FORMAT_VERSION, READABLE_VERSIONS = "sumi-install-manifest", 3, (1, 2, 3)
BUILD_NAME = "build.json"
UNITS = ("sumi-shell.service", "sumi-lock-rescue.service")
TREE_REL = ("quickshell", "sumi")
UNITS_REL = ("systemd", "user")
INSTALL_REL = ("sumi-shell", "install")
MARKER = ".sumi-install"
# El envoltorio del rice (hypr/scripts/lock.sh de F5b): si falta el helper, `exec hyprlock`. Sólo se acepta una versión
# conocida por su sha: su comportamiento está medido (F5b) y se vuelve a simular antes de desinstalar.
# Envoltorios conocidos que bloquean aunque falte la shell (caen a hyprlock). El de antes del cambio de nombre
# (llama a quickshell/kitasan/scripts/kitasan-lock) sigue cayendo a hyprlock sin ese árbol: también vale.
KNOWN_WRAPPERS = {"8c72c6607b45834fd85ece749ae6eba1cd99fe6378c05fece434d84e446c06d7": "the Minimaru rice's lock.sh (Sumi Shell)",
                  "ac6c41ae9e867454630dafe7cd6ab68ac014e2d7ed6c3ea3a8562458a318183d": "the rice's lock.sh from before Sumi Shell (F5b)"}
PURGE = (("config", "sumi-shell"), ("state", "sumi-shell"), ("cache", "sumi-shell"),
         ("cache", "sumi-weather.json"), ("cache", "sumi-theme-samples"))
SHARED = (("cache", "sumi-wallpapers"), ("cache", "sumi-desktop-mode"))
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
EXIT_OK, EXIT_REFUSED, EXIT_FAIL, EXIT_PENDING = 0, 1, 2, 3


class Refused(Exception):
    """El instalador se niega (salida 1): cada motivo, con qué hacer."""
    def __init__(self, reasons):
        super().__init__("; ".join(reasons))
        self.reasons = reasons


class Interrupted(Exception):
    pass


# ---- modo de prueba e inyección de fallos (D7) -----------------------------------------------------------------------

def test_mode():
    """Sólo con SUMI_INSTALL_TEST=1 Y el HOME real bajo /tmp o /run/user/<uid> (nunca un HOME normal)."""
    if os.environ.get("SUMI_INSTALL_TEST") != "1":
        return False
    home = os.path.realpath(os.environ.get("HOME", ""))
    bases = [os.path.realpath(tempfile.gettempdir()), "/run/user/%d" % os.geteuid()]
    return any(home.startswith(b + "/") for b in bases)


def fault(step, when):
    spec = os.environ.get("SUMI_INSTALL_FAULT", "")
    if not spec:
        return
    if not test_mode():
        if not getattr(fault, "warned", False):
            print("installer: SUMI_INSTALL_FAULT ignored (only for the test bench)", file=sys.stderr)
            fault.warned = True
        return
    s, w, action = (spec.split(":") + ["", "", ""])[:3]
    if s != step or w != when:
        return
    if action.startswith("SLEEP"):
        time.sleep(float(action[5:] or 5))
        return
    os.kill(os.getpid(), getattr(signal, action))


# ---- señales: INT/TERM se atienden entre pasos ---------------------------------------------------------------------

STOP = {"sig": None}


def _on_signal(signum, frame):
    STOP["sig"] = signum


def checkpoint():
    if STOP["sig"] is not None:
        raise Interrupted(signal.Signals(STOP["sig"]).name)


# ---- primitivas de archivos: relativas a descriptores, sin seguir enlaces --------------------------------------------

_libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
RENAME_NOREPLACE = 1


def rename_noreplace(src_fd, src, dst_fd, dst):
    try:
        fn = _libc.renameat2
    except AttributeError:
        raise Refused(["the C library has no renameat2: the tree can't be created without the risk of replacing one"])
    r = fn(src_fd, src.encode(), dst_fd, dst.encode(), RENAME_NOREPLACE)
    if r != 0:
        e = ctypes.get_errno()
        raise OSError(e, os.strerror(e), dst)


def open_dir(parent_fd, name, create=False, mode=0o755):
    """Abre `name` dentro de parent_fd como directorio, sin seguir enlaces, y comprueba que es del usuario."""
    if create:
        try:
            os.mkdir(name, mode, dir_fd=parent_fd)
        except FileExistsError:
            pass
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
    st = os.fstat(fd)
    if st.st_uid != os.geteuid():
        os.close(fd)
        raise Refused(["%s is not yours" % name])
    return fd


def sha_fd(fd):
    h = hashlib.sha256()
    while True:
        b = os.read(fd, 1 << 16)
        if not b:
            return h.hexdigest()
        h.update(b)


def file_sha(dir_fd, name):
    """(sha, modo, ino) de un archivo REGULAR, o None si no existe o no es un archivo regular (un enlace no lo es)."""
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dir_fd)
    except FileNotFoundError:
        return None
    except OSError as e:
        if e.errno == errno.ELOOP:
            return None
        raise
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return None
        return sha_fd(fd), stat.S_IMODE(st.st_mode), st.st_ino
    finally:
        os.close(fd)


def lexists(dir_fd, name):
    try:
        os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False


def write_new(dir_fd, name, data, mode):
    """Crea un archivo que NO puede existir (O_EXCL); fsync."""
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode, dir_fd=dir_fd)
    try:
        os.write(fd, data)
        os.fchmod(fd, mode)
        os.fsync(fd)
    finally:
        os.close(fd)


ASIDE = ".sumi-rm."


def race(name, point):
    """Sólo pruebas (D7): SUMI_INSTALL_RACE=<nombre>:<punto>:<dir> detiene aquí la retirada de <nombre> hasta que otro
    proceso, avisado por <dir>/ready, cree <dir>/go. Sirve para intercalar un cambio ajeno de forma determinista."""
    if not test_mode():
        return
    for var in ("SUMI_INSTALL_RACE", "SUMI_INSTALL_RACE2"):     # dos paradas como mucho (F6e: antes y después)
        spec = os.environ.get(var, "")
        if not spec:
            continue
        n, pt, d = (spec.split(":", 2) + ["", "", ""])[:3]
        done = getattr(race, "done", set())
        if n != name or pt != point or var in done:
            continue
        race.done = done | {var}
        open(os.path.join(d, "ready"), "x").close()
        end = time.monotonic() + 30
        while not os.path.exists(os.path.join(d, "go")) and time.monotonic() < end:
            time.sleep(0.01)
        return


def put_back(dir_fd, aside, name):
    """Devuelve lo apartado a su nombre sin reemplazar nada. 'kept' si vuelve; 'aside' si el nombre ya está ocupado."""
    try:
        rename_noreplace(dir_fd, aside, dir_fd, name)
        return "kept"
    except OSError:
        return "aside"


def kept_label(rel, r):
    if r != "aside":
        return rel
    d, n = os.path.split(rel)
    return "%s (another file took its name while it was being removed; the installed one was set aside as %s)" % (
        rel, os.path.join(d, ASIDE + n))


def remove_if(dir_fd, name, want_sha):
    """Borra `name` sólo si es un archivo regular con ese sha. 'removed' | 'absent' | 'kept' | 'aside'.

    Retirada verificable: se abre, se comprueba el sha, se APARTA con renameat2(NOREPLACE) a .sumi-rm.<name> en el mismo
    directorio, se comprueba que lo apartado es el mismo inodo y se vuelve a calcular el sha por el descriptor; sólo
    entonces se borra. Si algo no cuadra, vuelve a su nombre. Lo que otro proceso haga por la RUTA (escribir, sustituir,
    borrar, cambiar por un enlace) antes de apartarlo se detecta; después ya no la tiene. Riesgo residual: un proceso que
    YA tenía el archivo abierto y escribe entre la última comprobación y el borrado (o después) pierde esa escritura, como
    con cualquier borrado. 'aside': no se pudo devolver (el nombre lo ocupó otro) y queda como .sumi-rm.<name>."""
    aside = ASIDE + name
    if lexists(dir_fd, aside):            # de una ejecución cortada entre apartar y borrar
        got = file_sha(dir_fd, aside)
        if got is not None and got[0] == want_sha:
            os.unlink(aside, dir_fd=dir_fd)   # idéntico a lo instalado: no se pierde nada
            return "kept" if lexists(dir_fd, name) else "removed"
        if not lexists(dir_fd, name):
            return put_back(dir_fd, aside, name)
        return "aside"
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
    except FileNotFoundError:
        return "absent"
    except OSError as e:
        if e.errno == errno.ELOOP:
            return "kept"
        raise
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or sha_fd(fd) != want_sha:
            return "kept"
        race(name, "checked")
        try:
            rename_noreplace(dir_fd, name, dir_fd, aside)
        except FileNotFoundError:
            return "absent"
        except FileExistsError:
            return "kept"
        race(name, "moved")
        moved = os.stat(aside, dir_fd=dir_fd, follow_symlinks=False)
        if (moved.st_dev, moved.st_ino) != (st.st_dev, st.st_ino):
            return put_back(dir_fd, aside, name)      # entre abrir y apartar, la ruta pasó a ser otra cosa
        os.lseek(fd, 0, os.SEEK_SET)
        if sha_fd(fd) != want_sha:
            return put_back(dir_fd, aside, name)      # escrito entre la comprobación y apartarlo
        race(name, "verified")
        os.unlink(aside, dir_fd=dir_fd)
        return "removed"
    finally:
        os.close(fd)


# ---- raíces y política de rutas (F) ---------------------------------------------------------------------------------

class Roots:
    """HOME, XDG_CONFIG_HOME, XDG_STATE_HOME y XDG_CACHE_HOME resueltos; los tres últimos dentro de HOME."""

    def __init__(self):
        home = os.environ.get("HOME", "")
        problems = []
        if not os.path.isabs(home):
            raise Refused(["HOME is not an absolute path"])
        self.home_real = os.path.realpath(home)
        self.paths = {"home": home}
        for key, var, default in (("config", "XDG_CONFIG_HOME", ".config"), ("state", "XDG_STATE_HOME", ".local/state"),
                                  ("cache", "XDG_CACHE_HOME", ".cache")):
            p = os.environ.get(var) or os.path.join(home, default)
            if not os.path.isabs(p):
                problems.append("%s=%s is not an absolute path" % (var, p))
                continue
            self.paths[key] = p
        if problems:
            raise Refused(problems)
        self.real = {}
        for key in ("config", "state", "cache"):
            r = os.path.realpath(self.paths[key])
            if os.path.commonpath([r, self.home_real]) != self.home_real:
                problems.append("%s (%s) is outside your home: not supported" % (key, r))
            self.real[key] = r
        if problems:
            raise Refused(problems)

    def parts_problems(self, key, parts, *, installing=False):
        """Sin escribir: cada componente de base/parts tiene que no existir o ser un directorio real del usuario."""
        path = self.real[key]
        try:
            fd = self.base_fd(key, allow_missing=installing)
        except Refused as e:
            return e.reasons
        except OSError as e:
            return ["%s (%s) cannot be opened safely: %s" % (key, path, e.strerror)]
        if fd is None:
            return []
        try:
            for p in parts:
                path = os.path.join(path, p)
                try:
                    child = open_dir(fd, p)
                except FileNotFoundError:
                    break
                except (OSError, Refused):
                    return ["%s is a symbolic link, not a directory or not yours" % path]
                os.close(fd)
                fd = child
            if installing and not os.access(".", os.W_OK | os.X_OK, dir_fd=fd):
                return ["%s: the nearest existing directory is not writable and searchable" % path]
        finally:
            os.close(fd)
        return []

    def ident(self, key):
        fd = self.base_fd(key)
        try:
            st = os.fstat(fd)
        finally:
            os.close(fd)
        return {"path": self.paths[key], "real": self.real[key], "dev": st.st_dev, "ino": st.st_ino}

    def base_fd(self, key, ident=None, *, create=False, allow_missing=False):
        """Abre la ruta ya resuelta bajo HOME, sin seguir enlaces que aparezcan después de resolverla."""
        r = self.real[key]
        try:
            fd = os.open(self.home_real, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        except OSError as e:
            raise Refused(["HOME cannot be opened safely: %s" % e.strerror]) from e
        try:
            if os.fstat(fd).st_uid != os.geteuid():
                raise Refused(["%s is not yours" % self.home_real])
            if r != self.home_real:
                for part in os.path.relpath(r, self.home_real).split(os.sep):
                    try:
                        next_fd = open_dir(fd, part, create=create, mode=0o700)
                    except FileNotFoundError:
                        if not allow_missing:
                            raise
                        if not os.access(".", os.W_OK | os.X_OK, dir_fd=fd):
                            raise Refused(["%s cannot be created: its parent is not writable and searchable" % r])
                        os.close(fd)
                        return None
                    os.close(fd)
                    fd = next_fd
            st = os.fstat(fd)
            if ident and (st.st_dev, st.st_ino, r) != (ident["dev"], ident["ino"], ident["real"]):
                raise Refused(["%s is not the directory the manifest was written for" % r])
            return fd
        except FileNotFoundError:
            os.close(fd)
            raise
        except OSError as e:
            os.close(fd)
            raise Refused(["%s cannot be opened safely: %s" % (r, e.strerror)]) from e
        except BaseException:
            os.close(fd)
            raise

    def chain(self, key, parts, create=False, ident=None, created=None):
        """Abre base/parts[0]/…: cada componente sin seguir enlaces (un enlace → ENOTDIR/ELOOP → se niega)."""
        fd = self.base_fd(key, ident)
        rel = ""
        try:
            for p in parts:
                rel = os.path.join(rel, p)
                existed = lexists(fd, p)
                try:
                    nfd = open_dir(fd, p, create=create)
                except (NotADirectoryError, OSError) as e:
                    if isinstance(e, FileNotFoundError):
                        raise
                    raise Refused(["%s/%s is a symbolic link or not a directory: not supported" % (self.real[key], rel)])
                if create and not existed and created is not None:
                    created.append([key, rel])
                os.close(fd)
                fd = nfd
            return fd
        except BaseException:
            os.close(fd)
            raise


# ---- manifiesto ------------------------------------------------------------------------------------------------------

def canonical(doc):
    body = {k: v for k, v in doc.items() if k != "bodySha256"}
    return json.dumps(body, sort_keys=True, separators=(",", ":")).encode()


class Manifest:
    NAME = "manifest.json"

    def __init__(self, roots):
        self.roots = roots
        self.converted_from = None

    def dir_fd(self, create=False, created=None):
        return self.roots.chain("state", INSTALL_REL, create=create, created=created)

    def load(self):
        """None si no hay manifiesto; el documento si es íntegro; Refused si está corrupto o es de otra raíz."""
        try:
            fd = self.dir_fd()
        except FileNotFoundError:
            return None
        try:
            try:
                f = os.open(self.NAME, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
            except FileNotFoundError:
                return None
            except OSError as e:
                raise Refused(["the install manifest cannot be opened safely: %s" % e.strerror]) from e
            try:
                st = os.fstat(f)
                if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid():
                    raise Refused(["the install manifest is not a regular file of yours"])
                raw = b""
                while True:
                    b = os.read(f, 1 << 16)
                    if not b:
                        break
                    raw += b
            finally:
                os.close(f)
        finally:
            os.close(fd)
        try:
            doc = json.loads(raw)
            ok = (isinstance(doc, dict) and doc.get("format") == FORMAT and doc.get("formatVersion") in READABLE_VERSIONS
                  and doc.get("bodySha256") == hashlib.sha256(canonical(doc)).hexdigest())
        except ValueError:
            ok = False
            doc = None
        if (not ok and isinstance(doc, dict) and doc.get("format") == FORMAT and isinstance(doc.get("formatVersion"), int)
                and doc["formatVersion"] > FORMAT_VERSION):
            raise Refused(["the install manifest was written by a newer install.sh (format %d; this one reads up to %d): "
                           "nothing will be changed. Use the install.sh of that version" % (doc["formatVersion"],
                                                                                           FORMAT_VERSION)])
        if not ok:
            raise Refused(["the install manifest is damaged or of an unknown format: nothing will be changed. Inspect it "
                           "with `install.sh status`; moving it away is your decision"])
        for key in ("config", "state"):
            want = doc["roots"][key]
            r = self.roots.real[key]
            try:
                st = os.stat(r)
            except OSError:
                st = None
            if not st or (st.st_dev, st.st_ino, r) != (want["dev"], want["ino"], want["real"]):
                raise Refused(["the install manifest belongs to another %s directory (%s): nothing will be changed"
                               % (key, want["real"])])
        if doc["formatVersion"] < FORMAT_VERSION:
            # transición explícita (1 o 2) → 3: en memoria ahora; en disco con la próxima escritura, y anotada. Lo que el
            # formato viejo no sabía se marca como desconocido (buildId None), nunca se inventa.
            frm = doc["formatVersion"]
            doc["formatVersion"] = FORMAT_VERSION
            doc.setdefault("integrations", {})
            doc.setdefault("tree", {"version": doc.get("source", {}).get("version"),
                                    "apiVersion": doc.get("source", {}).get("apiVersion"), "buildId": None})
            doc.setdefault("formatHistory", []).append({"from": frm, "to": FORMAT_VERSION,
                                                        "at": time.strftime("%Y-%m-%dT%H:%M:%S%z")})
            self.converted_from = frm
        return doc

    def save(self, doc):
        doc["updatedAt"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        doc["bodySha256"] = hashlib.sha256(canonical(doc)).hexdigest()
        data = json.dumps(doc, indent=1, sort_keys=True).encode() + b"\n"
        fd = self.dir_fd()
        tmp = ".%s.%d.tmp" % (self.NAME, os.getpid())
        try:
            try:
                os.unlink(tmp, dir_fd=fd)
            except FileNotFoundError:
                pass
            write_new(fd, tmp, data, 0o600)
            os.rename(tmp, self.NAME, src_dir_fd=fd, dst_dir_fd=fd)
            os.fsync(fd)
        finally:
            os.close(fd)

    def delete(self):
        fd = self.dir_fd()
        try:
            os.unlink(self.NAME, dir_fd=fd)
            os.fsync(fd)
        finally:
            os.close(fd)


# ---- cerrojo (D) -----------------------------------------------------------------------------------------------------

LOCK_NAME = "sumi-install.lock"


def runtime_fd():
    run = os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.geteuid()
    # El override antiguo se conserva para los bancos que simulan un inicio de sesión.
    if test_mode():
        run = os.environ.get("SUMI_INSTALL_RUNTIME_DIR") or run
    parts = run.split("/")
    if not os.path.isabs(run) or any(part in (".", "..") for part in parts):
        raise Refused(["XDG_RUNTIME_DIR must be an absolute path without . or .. components"])
    uid = os.geteuid()
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in filter(None, parts):
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
            st = os.fstat(fd)
            if st.st_uid not in (0, uid) or (st.st_mode & 0o022 and not st.st_mode & stat.S_ISVTX):
                raise Refused(["%s has an unsafe runtime directory or ancestor" % run])
        st = os.fstat(fd)
        if st.st_uid != uid or stat.S_IMODE(st.st_mode) != 0o700:
            raise Refused(["%s must be a private directory owned by you with mode 0700" % run])
        if not os.access(".", os.W_OK | os.X_OK, dir_fd=fd):
            raise Refused(["%s must be writable and searchable" % run])
        return fd
    except OSError as e:
        os.close(fd)
        raise Refused(["%s cannot be used for the installer lock: %s (expected a real directory, without symlinks)"
                       % (run, e.strerror)]) from e
    except BaseException:
        os.close(fd)
        raise


def lock_file(create=False):
    directory = runtime_fd()
    try:
        flags = os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK
        if create:
            flags |= os.O_CREAT
        try:
            fd = os.open(LOCK_NAME, flags, 0o600, dir_fd=directory)
        except FileNotFoundError:
            if create:
                raise
            return None
        st = os.fstat(fd)
        if (not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid()
                or stat.S_IMODE(st.st_mode) != 0o600 or st.st_nlink != 1):
            os.close(fd)
            raise Refused(["%s must be a regular file owned by you with mode 0600 and one link" % LOCK_NAME])
        return fd
    except OSError as e:
        raise Refused(["%s cannot be opened safely: %s" % (LOCK_NAME, e.strerror)]) from e
    finally:
        os.close(directory)


def lock_busy():
    """Consulta el cerrojo sin crearlo ni modificarlo."""
    fd = lock_file()
    if fd is None:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return False
    except BlockingIOError:
        return True
    except OSError as e:
        raise Refused(["cannot test the installer lock: %s" % e.strerror]) from e
    finally:
        os.close(fd)


def pending_refusal(tx):
    if lock_busy():
        return Refused(["another install.sh is running for your user: wait for it to finish"])
    return Refused(["an interrupted %s is pending: run `install.sh recover`" % tx["op"]])


def take_lock():
    """Toma el mismo cerrojo que valida el diagnóstico. Nunca se borra."""
    fd = lock_file(create=True)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        raise Refused(["another install.sh is running for your user: wait for it to finish"])
    except OSError as e:
        os.close(fd)
        raise Refused(["cannot acquire the installer lock: %s" % e.strerror]) from e
    return fd


# ---- módulos reutilizados del árbol fuente ---------------------------------------------------------------------------

def load_module(name, rel):
    spec = importlib.util.spec_from_file_location(name, os.path.join(ROOT, rel))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def run(argv, timeout=10, env=None):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL, env=env)
        return p.returncode, p.stdout, p.stderr
    except FileNotFoundError:
        return None, "", "not found: " + argv[0]
    except subprocess.TimeoutExpired:
        return None, "", "timed out: " + argv[0]


def systemctl(*args, timeout=30):
    return run(["systemctl", "--user"] + list(args), timeout=timeout)


def unit_props(unit):
    rc, out, err = systemctl("show", unit, "-p", "LoadState", "-p", "ActiveState", "-p", "FragmentPath",
                             "-p", "UnitFileState", "-p", "MainPID")
    if rc != 0:
        return None
    return dict(l.split("=", 1) for l in out.splitlines() if "=" in l)


def manager_ok():
    rc, out, err = systemctl("show-environment", timeout=5)
    return rc == 0


def quickshell_path():
    qs = shutil.which("qs")
    return os.path.abspath(qs) if qs else None


def missing_qs_features(qs, probe):
    help_rc, help_out, _ = probe([qs, "--help"])
    ipc_rc, _, _ = probe([qs, "ipc", "call", "--help"])
    missing = []
    if help_rc != 0 or "--no-duplicate" not in help_out:
        missing.append("--no-duplicate")
    if ipc_rc != 0:
        missing.append("qs ipc call")
    return missing


def session_locked():
    """True / False / None (no se pudo saber)."""
    if not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        return None
    rc, out, err = run(["hyprctl", "locked"], timeout=3)
    if rc != 0:
        return None
    return out.strip() == "true"


# ---- el árbol fuente ---------------------------------------------------------------------------------------------------

def source_files():
    """[(rel, sha, modo, datos)] del sumi/ que va al lado de este script, filtrado por runtime-excludes.txt."""
    src = os.path.join(ROOT, "sumi")
    excl = set()
    with open(os.path.join(HERE, "runtime-excludes.txt")) as f:
        for l in f:
            l = l.strip()
            if l and not l.startswith("#"):
                excl.add(l)
    out = []
    for folder, dirs, files in os.walk(src):
        dirs[:] = sorted(d for d in dirs if d != "__pycache__")
        for d in dirs:
            if os.path.islink(os.path.join(folder, d)):
                raise Refused(["the source tree contains a symbolic link (%s): not supported" % d])
        for n in sorted(files):
            p = os.path.join(folder, n)
            rel = os.path.relpath(p, src)
            if rel in excl or n.endswith(".pyc"):
                continue
            st = os.lstat(p)
            if not stat.S_ISREG(st.st_mode):
                raise Refused(["the source tree contains something that isn't a regular file: %s" % rel])
            data = open(p, "rb").read()
            mode = 0o755 if st.st_mode & 0o111 else 0o644
            out.append((rel, hashlib.sha256(data).hexdigest(), mode, data))
    if not any(r == "shell.qml" for r, *_ in out):
        raise Refused(["%s is not a Sumi Shell tree" % src])
    return out


def build_id(files):
    """Identidad de construcción reproducible: sha256 de «ruta sha modo» de cada archivo del árbol distribuido (sin build.json),
    ordenado. Mismo contenido → misma identidad, se instale donde se instale; otra revisión con la misma versión → otra."""
    lines = sorted("%s %s %o" % (rel, sha, mode) for rel, sha, mode, _ in files if rel != BUILD_NAME)
    return "sha256:" + hashlib.sha256("\n".join(lines).encode()).hexdigest()


def with_build(files):
    """El árbol con su build.json (lo lee la shell al cargar: `api` → build)."""
    files = [f for f in files if f[0] != BUILD_NAME]
    data = (json.dumps({"format": "sumi-build", "buildId": build_id(files), "files": len(files)}, sort_keys=True)
            + "\n").encode()
    return sorted(files + [(BUILD_NAME, hashlib.sha256(data).hexdigest(), 0o644, data)])


def source_info():
    """version.json completo del árbol fuente (F6f: settingsSchema, minUpdateFrom, restart)."""
    try:
        with open(os.path.join(ROOT, "sumi", "version.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        raise Refused(["the source tree has no readable version.json"])


def source_version():
    try:
        with open(os.path.join(ROOT, "sumi", "version.json")) as f:
            v = json.load(f)
        return v["version"], v["apiVersion"]
    except (OSError, ValueError, KeyError):
        raise Refused(["the source tree has no readable version.json"])


def render_unit(text, tree_real, roots, qs):
    """Las unidades del árbol nombran %h/.config/quickshell/sumi; si el árbol vive en otra parte, se sustituye."""
    default = os.path.join(roots.home_real, ".config", "quickshell", "sumi")
    env = []
    if tree_real != default:
        if not re.fullmatch(r"[A-Za-z0-9/._+-]+", tree_real):
            raise Refused(["the tree path %s has characters a unit file can't take as they are" % tree_real])
        text = text.replace("%h/.config/quickshell/sumi", tree_real)
        env.append("Environment=XDG_CONFIG_HOME=" + roots.real["config"])
    if qs != "/usr/bin/qs":
        if not re.fullmatch(r"[A-Za-z0-9/._+-]+", qs):
            raise Refused(["the qs path %s has characters a unit file can't take as they are; use --no-units or "
                           "install qs in a unit-safe path" % qs])
        text = text.replace("/usr/bin/qs ", qs + " ")
        env.append("Environment=SUMI_QS=" + qs)
    if env:
        text = text.replace("[Service]\n", "[Service]\n" + "\n".join(env) + "\n")
    return text


# ---- cadena del bloqueo (G) --------------------------------------------------------------------------------------------

def simulate_wrapper(path):
    """Ejecuta el envoltorio CONOCIDO con el helper ausente y falsos delante: tiene que acabar en hyprlock."""
    tmp = tempfile.mkdtemp(prefix="sumi-lockcheck-")
    try:
        fake = os.path.join(tmp, "bin")
        os.mkdir(fake)
        log = os.path.join(tmp, "log")
        for name, body in (("hyprctl", 'echo false\n'), ("hyprlock", 'echo "hyprlock $*" >> "%s"\n' % log),
                           ("logger", ""), ("systemctl", ""), ("pgrep", "exit 1\n")):
            p = os.path.join(fake, name)
            with open(p, "w") as f:
                f.write("#!/bin/sh\n" + body)
            os.chmod(p, 0o755)
        env = {"PATH": fake + ":/usr/bin:/bin", "HOME": tmp, "XDG_CONFIG_HOME": os.path.join(tmp, "empty")}
        ok = True
        for mode in ("session", "instant"):
            open(log, "w").close()
            rc, out, err = run(["bash", path, mode], timeout=10, env=env)
            ok = ok and rc == 0 and open(log).read().startswith("hyprlock")
        return ok
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def hyprlock_ready(tree_scripts):
    """Que hyprlock sirva de red: ejecutable, sus bibliotecas cargan (ldd) y su pila PAM existe (pam_stack)."""
    exe = shutil.which("hyprlock")
    if not exe:
        return "hyprlock is not installed"
    rc, out, err = run(["ldd", exe], timeout=10)
    if rc != 0 or "not found" in out:
        return "hyprlock's libraries don't all load (ldd)"
    pam = load_module("sumi_pam_stack", os.path.join("sumi", "scripts", "pam_stack.py")).report("hyprlock")
    if not pam.get("exists") or pam.get("error") or not pam.get("auth"):
        return "hyprlock's PAM service is missing or unreadable"
    return ""


def lock_chain(tree_real, roots):
    """F6e (G1–G4, G1-H): el informe de packaging/lockchain.py, sus rechazos y avisos, y el envoltorio conocido comprobado."""
    lc = load_module("sumi_lockchain", os.path.join("packaging", "lockchain.py"))
    hyprdir = os.path.join(roots.real["config"], "hypr")
    rep = lc.report(tree_real, hyprdir, KNOWN_WRAPPERS)
    refuse, warn, wrappers = lc.problems(rep)
    checked = {}
    for who, key, cmd, real in wrappers:
        if real not in checked:
            if not simulate_wrapper(real):
                checked[real] = "did not fall back to hyprlock in a simulation"
            else:
                why = hyprlock_ready(tree_real)
                checked[real] = ("falls back to hyprlock, but %s" % why) if why else ""
        if checked[real]:
            refuse.append("%s %s: the lock wrapper (%s) %s" % (who, key, real, checked[real]))
    # en disco: la config de Hyprland no puede llamar al helper ni a lockNow (fuera del envoltorio conocido)
    pat = re.compile(rb"sumi-lock|ipc\s+call\s+sumi\s+lockNow|" + re.escape(tree_real.encode()) + rb"/scripts")
    for folder, dirs, files in os.walk(hyprdir):
        if folder[len(hyprdir):].count("/") >= 3:
            dirs[:] = []
        for n in files:
            if not n.endswith((".lua", ".conf")):
                continue
            p = os.path.join(folder, n)
            try:
                with open(p, "rb") as f:
                    data = f.read(1 << 20)
            except OSError:
                continue
            if pat.search(data):
                refuse.append("%s refers to the shell's lock helper: that would fail after uninstalling" % p)
    return {"report": rep, "refuse": refuse, "warn": warn, "describe": lc.describe(rep)}


def lock_chain_problems(tree_real, roots):
    """Motivos por los que, sin este árbol, el bloqueo podría dejar de funcionar. Vacío = establecido que sigue."""
    return lock_chain(tree_real, roots)["refuse"]


def notification_activations(roots):
    """Archivos de activación de org.freedesktop.Notifications que apuntan a la shell (nunca se borran)."""
    data = os.environ.get("XDG_DATA_HOME") or os.path.join(roots.paths["home"], ".local", "share")
    dirs = [data] + (os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":")
    found = []
    for d in dirs:
        sd = os.path.join(d, "dbus-1", "services")
        try:
            names = sorted(os.listdir(sd))
        except OSError:
            continue
        for n in names:
            p = os.path.join(sd, n)
            try:
                text = open(p, errors="replace").read()
            except OSError:
                continue
            if re.search(r"^Name=org\.freedesktop\.Notifications\s*$", text, re.M) and (
                    re.search(r"^SystemdService=sumi-shell\.service\s*$", text, re.M) or
                    re.search(r"^Exec=.*sumi", text, re.M)):
                found.append(p)
    return found


# ---- la instalación ----------------------------------------------------------------------------------------------------

class Installer:
    def __init__(self, args):
        self.args = args
        self.roots = Roots()
        self.man = Manifest(self.roots)
        self.out = []
        self.chain = None
        self.warned = set()

    def say(self, msg):
        print(msg)

    def tree_real(self):
        return os.path.join(self.roots.real["config"], *TREE_REL)

    def unit_links(self):
        """{rel: destino} de todo enlace bajo systemd/user que nombre una de las dos unidades (sin seguir enlaces)."""
        res = {}
        try:
            fd = self.roots.chain("config", UNITS_REL)
        except (FileNotFoundError, Refused):
            return res
        try:
            for top, dirs, files, dfd in os.fwalk(".", dir_fd=fd, follow_symlinks=False):
                for n in files + dirs:
                    if n in UNITS:
                        st = os.stat(n, dir_fd=dfd, follow_symlinks=False)
                        if stat.S_ISLNK(st.st_mode):
                            res[os.path.normpath(os.path.join(top, n))] = os.readlink(n, dir_fd=dfd)
        finally:
            os.close(fd)
        return res

    def running(self):
        caps = load_module("sumi_capabilities", os.path.join("sumi", "scripts", "capabilities.py"))
        return caps.q_install()

    # -- diagnóstico de install (sin escribir nada) --
    def install_preflight(self, doc):
        reasons = []
        if doc is not None:
            if doc.get("transaction"):
                raise pending_refusal(doc["transaction"])
            if doc.get("status") == "installed":
                if doc["source"]["version"] == source_version()[0] and self.tree_intact(doc):
                    # Lo pedido tiene que coincidir con lo instalado: no se añade nada a una instalación hecha
                    if not self.args.no_units and not doc["units"]:
                        raise Refused(["Sumi Shell was installed with --no-units: to get the units, run "
                                       "`install.sh uninstall` and install again"])
                    if self.args.enable and not doc["links"]:
                        raise Refused(["Sumi Shell was installed without --enable: to have it start at login, run "
                                       "`install.sh uninstall` and install again with --enable"])
                    return "already"
                raise Refused(["Sumi Shell %s is already installed here: `install.sh update` replaces it with this "
                               "version" % doc["source"]["version"]])
            raise Refused(["the previous uninstall left items to resolve (status %s): run `install.sh uninstall`"
                           % doc.get("status")])
        cfg = self.roots.real["config"]
        tree = self.tree_real()
        reasons += self.roots.parts_problems("config", ("quickshell",), installing=True)
        reasons += self.roots.parts_problems("state", INSTALL_REL, installing=True)
        if not self.args.no_units:
            reasons += self.roots.parts_problems("config", UNITS_REL, installing=True)
        if reasons:
            raise Refused(reasons)
        if os.path.lexists(tree):
            reasons.append("%s already exists and this installer didn't create it (it can be your own copy or a "
                           "development tree): it won't be replaced" % tree)
        if os.path.lexists(os.path.join(cfg, "quickshell", "shell.qml")):
            reasons.append("%s/quickshell/shell.qml (a default Quickshell config) would hide the installed copy" % cfg)
        if not self.args.no_units:
            for u in UNITS:
                if os.path.lexists(os.path.join(cfg, *UNITS_REL, u)):
                    reasons.append("%s already exists: not this installer's (use --no-units to install without "
                                   "units)" % os.path.join(cfg, *UNITS_REL, u))
            for rel, target in self.unit_links().items():
                reasons.append("the link %s names a Sumi Shell unit and isn't this installer's" % rel)
        for d in ("/etc/systemd/user", "/usr/lib/systemd/user", "/usr/local/lib/systemd/user"):
            for u in UNITS:
                if os.path.exists(os.path.join(d, u)):
                    reasons.append("%s exists: Sumi Shell is installed system-wide (a package); a user install next "
                                   "to it is not supported" % os.path.join(d, u))
        q = self.running()
        for c in q.get("copies", []):
            if c.get("scope") == "system" and not c.get("absent"):
                reasons.append("a system copy exists at %s (a package): a user install would hide it" % c["path"])
        if q.get("error"):
            reasons.append("couldn't list running shells (%s)" % q["error"])
        for i in q.get("instances", []):
            reasons.append("Sumi Shell is running from %s (pid %s): stop it first, or `qs -c sumi` commands would "
                           "stop reaching it" % (i["path"], i["pid"]))
        for i in q.get("legacyInstances", []):
            reasons.append("the shell under its former name (Kitasan-Shell) is running from %s (pid %s): stop it first, "
                           "or there would be two shells (two sets of shortcuts, notification servers and polkit agents)"
                           % (i["path"], i["pid"]))
        if self.args.enable and self.args.no_units:
            reasons.append("--enable needs the units (drop --no-units)")
        if not self.args.no_units and not manager_ok():
            reasons.append("the user service manager can't be reached: installing units needs it. "
                           "Use --no-units for a direct installation")
        if reasons:
            raise Refused(reasons)
        return "go"

    def tree_intact(self, doc):
        try:
            fd = self.roots.chain("config", TREE_REL, ident=doc["roots"]["config"])
        except (FileNotFoundError, Refused):
            return False
        try:
            m = file_sha(fd, MARKER)
            return bool(m) and m[0] == doc["markerSha256"]
        finally:
            os.close(fd)

    def plan_install(self):
        """Comparte las condiciones de escritura entre check, dry-run e install."""
        doc = self.man.load()
        if self.install_preflight(doc) == "already":
            return None
        if lock_busy():
            raise Refused(["another install.sh is running for your user: wait for it to finish"])
        self.check_install_dependencies()
        return self.install_units()

    def check_install_dependencies(self):
        qs = quickshell_path()
        if qs is None:
            raise Refused(["the qs command is missing"])
        missing = missing_qs_features(qs, run)
        if missing:
            raise Refused(["%s could not provide %s" % (qs, ", ".join(missing))])
        absent = [command for command in ("hyprctl", "timeout") if not shutil.which(command)]
        if absent:
            raise Refused(["missing required commands: " + ", ".join(absent)])
        qml = load_module("sumi_qml_requirements", "packaging/qml_requirements.py")
        _, _, _, _, absent = qml.inspect(os.path.join(ROOT, "sumi"), run)
        missing = [name for name in absent if name not in qml.OPTIONAL_MODULES]
        if missing:
            raise Refused(["missing required QML modules: " + ", ".join(missing)])

    def install_units(self):
        units = []
        if not self.args.no_units:
            qs = quickshell_path()
            if qs is None:
                raise Refused(["the qs command is missing"])
            for u in UNITS:
                with open(os.path.join(ROOT, "sumi", "systemd", u)) as f:
                    text = render_unit(f.read(), self.tree_real(), self.roots, qs).encode()
                units.append((u, hashlib.sha256(text).hexdigest(), text))
        return units

    def install(self):
        files = with_build(source_files())
        version, api = source_version()
        units = self.plan_install()
        if units is None:
            self.say("Sumi Shell %s is already installed (%s): nothing to do." % (version, self.tree_real()))
            return EXIT_OK
        if self.args.dry_run:
            self.say("Would install Sumi Shell %s (API %d): %d files into %s%s%s." % (
                version, api, len(files), self.tree_real(),
                "" if self.args.no_units else ", units %s" % ", ".join(u for u, *_ in units),
                ", enabled" if self.args.enable else ""))
            return EXIT_OK
        lock = take_lock()
        try:
            doc = self.man.load()
            if self.install_preflight(doc) == "already":
                self.say("Sumi Shell %s is already installed: nothing to do." % version)
                return EXIT_OK
            return self.install_locked(files, version, api, self.install_units())
        finally:
            os.close(lock)

    def install_locked(self, files, version, api, units):
        tx = uuid.uuid4().hex[:12]
        mid = uuid.uuid4().hex
        created = []
        # Las bases XDG son infraestructura del usuario, como el HOME. Sus hijos de Sumi sí se registran.
        for key in ("config", "state"):
            os.close(self.roots.base_fd(key, create=True))
        fd = self.man.dir_fd(create=True, created=created)
        os.close(fd)
        marker = json.dumps({"format": "sumi-install-marker", "id": mid}).encode() + b"\n"
        doc = {"format": FORMAT, "formatVersion": FORMAT_VERSION, "id": mid, "scope": "user",
               "roots": {k: self.roots.ident(k) for k in ("config", "state")},
               "source": {"version": version, "apiVersion": api},
               "tree": {"version": version, "apiVersion": api, "buildId": build_id(files)},
               "status": "installing", "markerSha256": hashlib.sha256(marker).hexdigest(),
               "files": {rel: [sha, oct(mode)] for rel, sha, mode, _ in files},
               "dirs": all_dirs(rel for rel, *_ in files),
               "units": {u: sha for u, sha, _ in units}, "links": {}, "createdDirs": created, "kept": [],
               "transaction": {"id": tx, "op": "install", "pid": os.getpid(), "staging": ".sumi-staging-" + tx,
                               "steps": {}, "linksBefore": None},
               "history": []}
        self.man.save(doc)
        self.say("Installing Sumi Shell %s (API %d) into %s" % (version, api, self.tree_real()))
        try:
            self.step(doc, "dirs", lambda: self.do_make_dirs(doc, bool(units)))
            self.step(doc, "stage", lambda: self.do_stage(doc, files, marker))
            self.step(doc, "rename", lambda: self.do_rename(doc))
            if units:
                self.step(doc, "units", lambda: self.do_units(doc, units))
                self.step(doc, "reload", lambda: self.do_reload(doc))
            if self.args.enable and not doc.get("problems"):
                self.step(doc, "enable", lambda: self.do_enable(doc))
        except Interrupted as e:
            self.say("Interrupted (%s): run `install.sh recover` to undo what was done." % e)
            return EXIT_PENDING
        except Refused as e:
            self.say("Stopped: " + "; ".join(e.reasons))
            self.say("Undoing what this install did (only what carries its evidence)…")
            rc = self.rollback_install(doc)
            if rc != EXIT_OK:
                self.say("Run `install.sh recover --apply` once the items above are resolved.")
            return EXIT_REFUSED
        doc["status"] = "partial" if doc.get("problems") else "installed"
        doc["transaction"] = None
        doc["history"].append({"op": "install", "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "result": doc["status"]})
        self.man.save(doc)
        for p in doc.get("problems", []):
            self.say("  ! " + p)
        if doc["status"] == "partial":
            self.say("Installation is partial. Correct the problems above before starting Sumi Shell.")
            return EXIT_REFUSED
        self.say("Installed. %s" % ("Start it with `systemctl --user start sumi-shell` (or at your next login)."
                                    if self.args.enable else
                                    "Start it with `systemctl --user start sumi-shell`. To start it at every login, "
                                    "install with --enable (a link made with `systemctl --user enable` isn't this "
                                    "installer's: uninstall would stop until you remove it)." if units else
                                    "Start it with `exec-once = qs -c sumi --no-duplicate` in Hyprland."))
        return EXIT_PARTIAL_OR_OK(doc)

    def step(self, doc, name, fn):
        checkpoint()
        doc["transaction"]["steps"][name] = "intent"
        self.man.save(doc)
        fault(name, "before")
        fn()
        fault(name, "after")
        doc["transaction"]["steps"][name] = "done"
        self.man.save(doc)
        checkpoint()

    def do_make_dirs(self, doc, units):
        """quickshell/ y systemd/user/ si faltan: se registran como creados ANTES de crearlos."""
        want = [("quickshell",)] + ([("systemd",), ("systemd", "user")] if units else [])
        missing = [list(p) for p in want if not os.path.lexists(os.path.join(self.roots.real["config"], *p))]
        doc["createdDirs"] += [["config", "/".join(p)] for p in missing]
        self.man.save(doc)
        for p in want:
            fd = self.roots.chain("config", p, create=True, ident=doc["roots"]["config"])
            os.close(fd)

    def do_stage(self, doc, files, marker):
        qfd = self.roots.chain("config", ("quickshell",), ident=doc["roots"]["config"])
        try:
            st_name = doc["transaction"]["staging"]
            os.mkdir(st_name, 0o755, dir_fd=qfd)
            sfd = open_dir(qfd, st_name)
            try:
                write_new(sfd, MARKER, marker, 0o644)
                dfds = {"": sfd}
                for d in doc["dirs"]:
                    parent = dfds[os.path.dirname(d)]
                    os.mkdir(os.path.basename(d), 0o755, dir_fd=parent)
                    dfds[d] = open_dir(parent, os.path.basename(d))
                for rel, sha, mode, data in files:
                    write_new(dfds[os.path.dirname(rel)], os.path.basename(rel), data, mode)
                    checkpoint()
                for d, f in dfds.items():
                    if d:
                        os.close(f)
            finally:
                os.close(sfd)
        finally:
            os.close(qfd)

    def do_rename(self, doc):
        qfd = self.roots.chain("config", ("quickshell",), ident=doc["roots"]["config"])
        try:
            try:
                if test_mode() and os.environ.get("SUMI_INSTALL_FAULT") == "rename:einval":
                    raise OSError(errno.EINVAL, "simulated: no RENAME_NOREPLACE here")   # sólo el banco
                rename_noreplace(qfd, doc["transaction"]["staging"], qfd, TREE_REL[1])
            except OSError as e:
                if e.errno == errno.EEXIST:
                    raise Refused(["%s appeared while installing: it was not touched" % self.tree_real()])
                if e.errno in (errno.EINVAL, errno.ENOSYS):
                    raise Refused(["this filesystem can't create the tree without the risk of replacing one "
                                   "(no RENAME_NOREPLACE): not supported"])
                raise
            os.fsync(qfd)
        finally:
            os.close(qfd)

    def do_units(self, doc, units):
        ufd = self.roots.chain("config", UNITS_REL, ident=doc["roots"]["config"])
        try:
            for name, sha, text in units:
                tmp = ".%s.%s.tmp" % (name, doc["transaction"]["id"])
                write_new(ufd, tmp, text, 0o644)
                try:
                    os.link(tmp, name, src_dir_fd=ufd, dst_dir_fd=ufd, follow_symlinks=False)
                except FileExistsError:
                    raise Refused(["%s appeared while installing: it was not touched" % name])
                finally:
                    os.unlink(tmp, dir_fd=ufd)
            os.fsync(ufd)
        finally:
            os.close(ufd)

    def do_reload(self, doc):
        rc, out, err = systemctl("daemon-reload")
        if rc != 0:
            doc.setdefault("problems", []).append("systemctl --user daemon-reload failed (%s): the units load at your "
                                                  "next login" % (err.strip() or rc))
            return
        for unit in UNITS:
            p = unit_props(unit) or {}
            want = os.path.join(self.roots.real["config"], *UNITS_REL, unit)
            if p.get("LoadState") != "loaded" or os.path.realpath(p.get("FragmentPath", "")) != want:
                doc.setdefault("problems", []).append("systemd loads %s from %s, not from the installed unit"
                                                      % (unit, p.get("FragmentPath") or "nowhere"))

    def unit_dirs(self):
        """Directorios bajo systemd/user (sin seguir enlaces)."""
        res = set()
        try:
            fd = self.roots.chain("config", UNITS_REL)
        except (FileNotFoundError, Refused):
            return res
        try:
            for top, dirs, files, dfd in os.fwalk(".", dir_fd=fd, follow_symlinks=False):
                for d in dirs:
                    res.add(os.path.normpath(os.path.join(top, d)))
        finally:
            os.close(fd)
        return res

    def do_enable(self, doc):
        before = self.unit_links()
        dirs_before = sorted(self.unit_dirs())
        doc["transaction"]["linksBefore"] = before
        doc["transaction"]["dirsBefore"] = dirs_before
        self.man.save(doc)
        rc, out, err = systemctl("enable", UNITS[0])
        after = self.unit_links()
        doc["links"] = {k: v for k, v in after.items() if k not in before}
        doc["createdDirs"] += [["config", "/".join(UNITS_REL) + "/" + d] for d in sorted(self.unit_dirs() - set(dirs_before))]
        if rc != 0:
            doc.setdefault("problems", []).append("systemctl --user enable failed (%s): the shell is installed but "
                                                  "not enabled" % (err.strip() or rc))
        elif "graphical-session.target.wants/" + UNITS[0] not in doc["links"]:
            doc.setdefault("problems", []).append("systemctl did not create the expected enable link")

    # -- desinstalación --
    def uninstall(self):
        doc = self.man.load()
        if doc is None:
            if self.args.purge:
                return self.purge()
            self.say("Sumi Shell is not installed by this installer here: nothing to do.")
            return EXIT_OK
        tx = doc.get("transaction")
        if tx and lock_busy():
            raise pending_refusal(tx)
        if tx and tx["op"] == "install":
            raise Refused(["an interrupted install is pending: run `install.sh recover --apply` (it undoes it)"])
        probs = self.uninstall_preflight(doc)
        if probs or self.args.dry_run:
            self.say_chain()
        if probs:
            raise Refused(probs)
        if self.args.dry_run:
            self.say("Would uninstall Sumi Shell %s from %s (%d files, units: %s, links: %s)." % (
                doc["source"]["version"], self.tree_real(), len(doc["files"]), ", ".join(doc["units"]) or "none",
                ", ".join(doc["links"]) or "none"))
            return EXIT_OK
        lock = take_lock()
        try:
            doc = self.man.load()
            if doc is None:
                self.say("Nothing to uninstall.")
                return EXIT_OK
            probs = self.uninstall_preflight(doc)
            if probs:
                raise Refused(probs)
            rc = self.uninstall_locked(doc)
        finally:
            os.close(lock)
        if rc == EXIT_OK and self.args.purge:
            return self.purge()
        return rc

    def uninstall_preflight(self, doc):
        probs = self.roots.parts_problems("config", ("quickshell",)) + self.roots.parts_problems("config", UNITS_REL)
        if not self.marker_evidence(doc):
            probs.append("the installed tree's marker is missing or isn't this installation's, and no uninstall had "
                         "removed it: the tree is treated as unknown and won't be deleted")
        tree = self.tree_real()
        shell = unit_props(UNITS[0]) if doc["units"] else None
        q = self.running()
        mine_main = (shell or {}).get("MainPID", "0")
        for i in q.get("instances", []):
            if os.path.realpath(i["path"]) == tree and str(i["pid"]) != mine_main:
                probs.append("Sumi Shell runs from %s outside its unit (pid %s, exec-once?): quit it first" % (
                    i["path"], i["pid"]))
        if shell and shell.get("ActiveState") in ("active", "activating", "deactivating", "reloading"):
            locked = session_locked()
            if locked is None:
                probs.append("the shell is running but the lock state can't be read (run uninstall from inside "
                             "Hyprland)")
            elif locked:
                probs.append("the session is locked")
        links = self.unit_links()
        for rel, target in links.items():
            if doc["links"].get(rel) != target:
                probs.append("the link %s names a Sumi Shell unit and isn't this installer's: removing the unit would "
                             "break it (remove the link yourself first)" % rel)
        probs += self.update_module().uninstall_problems(doc)
        for kind, rec in sorted((doc.get("integrations") or {}).items()):
            if self.integrations_module().current_status(sys.modules[__name__], self, rec) != "reverted":
                probs.append("the %s integration is %s: undo it first with `install.sh %s --revert%s` (the record that "
                             "proves which lines are the installer's goes away with the uninstall)" % (
                                 kind, rec.get("status"), kind, " --restart" if kind == "hypridle" else
                                 "" if kind == "theme-apps" else " --reload"))
        self.chain = lock_chain(tree, self.roots)
        probs += self.chain["refuse"]
        for w in self.chain["warn"]:
            if w not in self.warned:
                self.warned.add(w)
                self.say("  ! " + w)
        for p in notification_activations(self.roots):
            probs.append("%s makes D-Bus start Sumi Shell for notifications; without the shell it would also hide "
                         "any other notification server. Remove it first with `%s/scripts/notif-server %s`" % (
                             p, tree, "off" if doc["units"] else "direct-off"))
        for msg in self.integration_warnings(tree):
            self.say("  ! " + msg)
        return probs

    def say_chain(self):
        """Lo que se sabe de la cadena del bloqueo: en disco, probablemente cargado, comprobado o desconocido."""
        if self.chain:
            self.say("Lock chain (disk = on disk only · probable = loaded and unchanged since it started · effective = "
                     "checked in the running process · unknown = can't be established):")
            for line in self.chain["describe"]:
                self.say("  " + line)

    def integration_warnings(self, tree):
        out = []
        pw = os.path.join(self.roots.real["config"], "pipewire", "filter-chain.conf.d", "kitasan-eq.conf")
        if os.path.exists(pw):
            out.append("the shell's equalizer config stays (%s); remove it first with `%s/scripts/audio-eq.py remove` "
                       "if you don't want it" % (pw, tree))
        idle = os.path.join(self.roots.real["config"], "hypr", "hypridle-sumi.conf")
        if os.path.exists(idle):
            out.append("idle timeouts managed by the shell stay in %s (Settings → System → Power can hand them back "
                       "before uninstalling)" % idle)
        led = os.path.join(self.roots.real["state"], "sumi-shell", "theme", "desktop-ledger.json")
        if os.path.exists(led):
            out.append("desktop settings changed by the theme sync stay (Settings → Theme → Restore desktop settings "
                       "puts them back)")
        return out

    def marker_evidence(self, doc):
        tx = doc.get("transaction") or {}
        if tx.get("op") == "uninstall" and tx["steps"].get("marker") in ("intent", "done"):
            return True
        try:
            fd = self.roots.chain("config", TREE_REL, ident=doc["roots"]["config"])
        except FileNotFoundError:
            return True                        # sin árbol no hay nada nuestro que borrar en él
        except Refused:
            return False
        try:
            m = file_sha(fd, MARKER)
            if m is None:
                return doc.get("status") == "partial" and doc.get("markerGone") is True
            return m[0] == doc["markerSha256"]
        finally:
            os.close(fd)

    def uninstall_locked(self, doc):
        if not doc.get("transaction"):
            p = unit_props(UNITS[0]) if doc["units"] else None
            doc["transaction"] = {"id": uuid.uuid4().hex[:12], "op": "uninstall", "pid": os.getpid(), "steps": {},
                                  "prior": p or {}}
            doc["status"] = "uninstalling"
            doc["kept"] = []
            self.man.save(doc)
        try:
            if doc["units"]:
                self.step(doc, "stop", lambda: self.do_stop(doc))
                self.step(doc, "relock", lambda: self.do_relock(doc))
            self.step(doc, "links", lambda: self.do_unlinks(doc))
            if doc["units"]:
                self.step(doc, "units", lambda: self.do_unit_removal(doc))
            self.step(doc, "tree", lambda: self.do_tree_removal(doc))
            self.step(doc, "marker", lambda: self.do_marker_removal(doc))
            if doc.get("previous"):
                self.step(doc, "previous", lambda: self.do_previous_removal(doc))
            self.step(doc, "dirs", lambda: self.do_dirs(doc))
        except Interrupted as e:
            self.say("Interrupted (%s): run `install.sh recover --apply` (or `uninstall` again) to finish." % e)
            return EXIT_PENDING
        except Refused as e:
            doc["status"] = "partial"
            doc["transaction"] = None
            doc.setdefault("notes", []).extend(e.reasons)
            self.man.save(doc)
            self.say("Stopped, nothing else was removed: " + "; ".join(e.reasons))
            return EXIT_REFUSED
        return self.finish_uninstall(doc)

    def do_stop(self, doc):
        p = unit_props(UNITS[0])
        if not p or p.get("ActiveState") not in ("active", "activating", "reloading", "deactivating"):
            return
        want = os.path.join(self.roots.real["config"], *UNITS_REL, UNITS[0])
        if os.path.realpath(p.get("FragmentPath", "")) != want:
            raise Refused(["the running sumi-shell.service is not the installed one (%s)" % p.get("FragmentPath")])
        rc, out, err = systemctl("stop", UNITS[0], timeout=60)
        if rc != 0:
            raise Refused(["systemctl --user stop sumi-shell failed: %s" % (err.strip() or rc)])
        for _ in range(100):
            r = unit_props(UNITS[1]) or {}
            if r.get("ActiveState") not in ("active", "activating", "deactivating"):
                return
            time.sleep(0.1)

    def do_relock(self, doc):
        if session_locked():
            raise Refused(["the session locked while uninstalling: the lock helper, the rescue unit and the tree were "
                           "kept. Unlock and run `install.sh uninstall` again"])

    def do_unlinks(self, doc):
        try:
            ufd = self.roots.chain("config", UNITS_REL, ident=doc["roots"]["config"])
        except FileNotFoundError:
            doc["links"] = {}
            return
        try:
            for rel, target in sorted(list(doc["links"].items())):
                parent, name = os.path.split(rel)
                pfd = ufd
                try:
                    if parent:
                        pfd = self.roots_open_rel(ufd, parent)
                except (FileNotFoundError, Refused):
                    continue
                try:
                    try:
                        cur = os.readlink(name, dir_fd=pfd)
                    except (FileNotFoundError, OSError):
                        cur = None
                    if cur == target:
                        os.unlink(name, dir_fd=pfd)
                        doc["links"].pop(rel)
                    elif cur is None:
                        doc["links"].pop(rel)
                    else:
                        doc["kept"].append("systemd/user/" + rel)
                finally:
                    if pfd != ufd:
                        os.close(pfd)
        finally:
            os.close(ufd)

    def roots_open_rel(self, fd, rel):
        cur = os.dup(fd)
        try:
            for p in rel.split("/"):
                try:
                    n = open_dir(cur, p)
                except FileNotFoundError:
                    raise
                except OSError as e:
                    raise Refused(["%s is a symbolic link or not a directory" % rel]) from e
                os.close(cur)
                cur = n
        except BaseException:
            os.close(cur)
            raise
        return cur

    def do_unit_removal(self, doc):
        try:
            ufd = self.roots.chain("config", UNITS_REL, ident=doc["roots"]["config"])
        except FileNotFoundError:
            doc["units"] = {}
            return
        try:
            for u, sha in sorted(doc["units"].items()):
                r = remove_if(ufd, u, sha)
                if r in ("kept", "aside"):
                    doc["kept"].append(kept_label("systemd/user/" + u, r))
                else:
                    doc["units"].pop(u)
            os.fsync(ufd)
        finally:
            os.close(ufd)
        if manager_ok():
            systemctl("daemon-reload")
            systemctl("reset-failed", *UNITS)

    def do_tree_removal(self, doc):
        try:
            tfd = self.roots.chain("config", TREE_REL, ident=doc["roots"]["config"])
        except FileNotFoundError:
            doc["files"] = {}
            return
        try:
            dfds = {"": tfd}
            for rel in sorted(doc["files"], key=lambda r: (-r.count("/"), r)):
                d = os.path.dirname(rel)
                try:
                    if d not in dfds:
                        dfds[d] = self.roots_open_rel(tfd, d)
                except FileNotFoundError:
                    doc["files"].pop(rel)                 # su directorio ya no está: nada nuestro que borrar
                    continue
                except Refused:
                    doc["kept"].append("quickshell/sumi/" + d + " (not a directory any more)")
                    dfds[d] = None
                if dfds.get(d) is None:
                    continue
                r = remove_if(dfds[d], os.path.basename(rel), doc["files"][rel][0])
                if r in ("kept", "aside"):
                    doc["kept"].append(kept_label("quickshell/sumi/" + rel, r))
                else:
                    doc["files"].pop(rel)
                checkpoint()
            for d, f in dfds.items():
                if d and f is not None:
                    os.close(f)
        finally:
            os.close(tfd)

    def do_marker_removal(self, doc):
        if any(k.startswith("quickshell/sumi/") for k in doc["kept"]):
            return                              # la marca sigue: es la evidencia para terminar más tarde
        try:
            tfd = self.roots.chain("config", TREE_REL, ident=doc["roots"]["config"])
        except FileNotFoundError:
            return
        try:
            r = remove_if(tfd, MARKER, doc["markerSha256"])
            if r in ("kept", "aside"):
                doc["kept"].append(kept_label("quickshell/sumi/" + MARKER, r))
        finally:
            os.close(tfd)
        doc["markerGone"] = True

    def rmdir_rel(self, key, rel, ident):
        """rmdir de base/rel si está vacío, abriendo cada padre sin seguir enlaces. Nunca falla por ello."""
        parent, name = os.path.split(rel)
        try:
            fd = self.roots.chain(key, tuple(p for p in parent.split("/") if p), ident=ident)
        except (FileNotFoundError, Refused):
            return
        try:
            os.rmdir(name, dir_fd=fd)
        except OSError:
            pass
        finally:
            os.close(fd)

    def do_previous_removal(self, doc):
        """F6f: la generación conservada por `update`, por sha (lo cambiado se queda, como en el árbol)."""
        kept = self.update_module().remove_previous_for_uninstall(sys.modules[__name__], self, doc)
        doc["kept"] += kept
        if not kept:
            doc["previous"] = None

    def do_dirs(self, doc):
        """Los directorios del árbol, de dentro afuera, y el árbol: sólo si están vacíos."""
        ident = doc["roots"]["config"]
        for d in sorted(doc["dirs"], key=lambda x: -x.count("/")):
            self.rmdir_rel("config", "/".join(TREE_REL) + "/" + d, ident)
        self.rmdir_rel("config", "/".join(TREE_REL), ident)

    def finish_uninstall(self, doc):
        kept = sorted(set(doc["kept"]))
        if kept and self.args.keep_modified:
            try:
                tfd = self.roots.chain("config", TREE_REL, ident=doc["roots"]["config"])
                try:
                    remove_if(tfd, MARKER, doc["markerSha256"])
                finally:
                    os.close(tfd)
            except (FileNotFoundError, Refused):
                pass
            self.do_dirs(doc)
        if kept and not self.args.keep_modified:
            doc["status"] = "partial"
            doc["transaction"] = None
            doc["kept"] = kept
            self.man.save(doc)
            self.say("Not finished: these were changed after installing and were kept:")
            for k in kept:
                self.say("  " + k)
            self.say("Move them away (or restore them) and run `install.sh uninstall` again, or run "
                     "`install.sh uninstall --keep-modified` to keep them as your own files.")
            return EXIT_REFUSED
        # copias de las integraciones que siguen ahí: dejan de estar registradas, se dice cuáles
        for kind, rec in sorted((doc.get("integrations") or {}).items()):
            for k in rec.get("kept", []):
                p = os.path.join(self.roots.real["state"], k["rel"])
                if os.path.exists(p):
                    self.say("  kept for you (no longer managed): %s (%s)" % (p, k["why"]))
        # el manifiesto se borra ANTES que su carpeta; después, lo creado por el instalador, de dentro afuera, sólo vacío
        self.man.delete()
        for key, rel in sorted(doc.get("createdDirs", []), key=lambda kr: -kr[1].count("/")):
            self.rmdir_rel(key, rel, doc["roots"][key])
        tree = self.tree_real()
        if os.path.isdir(tree) and not os.path.islink(tree):
            self.say("  left in place: %s (it contains files that were not installed by this installer)" % tree)
        if kept:
            self.say("Uninstalled. These files are now yours and no longer managed by the installer (a later install "
                     "will refuse to replace them):")
            for k in kept:
                self.say("  " + k)
        else:
            self.say("Uninstalled. Your settings and data were kept (`install.sh uninstall --purge` removes them).")
        for k, rel in SHARED:
            p = os.path.join(self.roots.real[k], rel)
            if os.path.exists(p):
                self.say("  kept (shared with the rice): %s" % p)
        bk = os.path.join(self.roots.real["state"], *INSTALL_REL, "backups")
        if os.path.isdir(bk):
            self.say("  kept for you (no longer managed): %s (copies made by hyprland/hypridle/update: your files as "
                     "they were)" % bk)
        return EXIT_OK

    # -- purge --
    def purge(self):
        if self.man.load() is not None:
            raise Refused(["--purge needs a complete uninstall first"])
        targets = []
        for key, rel in PURGE:
            p = os.path.join(self.roots.real[key], rel)
            if os.path.lexists(p):
                st = os.lstat(p)
                if stat.S_ISLNK(st.st_mode) or st.st_uid != os.geteuid():
                    raise Refused(["%s is a symbolic link or isn't yours: --purge won't touch it" % p])
                targets.append((key, rel, p))
        if not targets:
            self.say("Nothing to purge.")
            return EXIT_OK
        self.say("--purge deletes these, with your settings, history and secrets:")
        for _, _, p in targets:
            self.say("  " + p)
        if self.args.dry_run:
            return EXIT_OK
        if not self.args.yes:
            if not sys.stdin.isatty():
                raise Refused(["--purge needs confirmation: run it in a terminal or add --yes"])
            if input("Type 'purge' to confirm: ").strip() != "purge":
                self.say("Nothing deleted.")
                return EXIT_OK
        for key, rel, p in targets:
            bfd = self.roots.base_fd(key)
            try:
                st = os.stat(rel, dir_fd=bfd, follow_symlinks=False)
                if stat.S_ISDIR(st.st_mode):
                    shutil.rmtree(rel, dir_fd=bfd)
                elif stat.S_ISREG(st.st_mode):
                    os.unlink(rel, dir_fd=bfd)
            finally:
                os.close(bfd)
        self.say("Purged.")
        return EXIT_OK

    # -- recuperación (D10) --
    def recover(self):
        doc = self.man.load()
        tx = (doc or {}).get("transaction")
        if not tx:
            self.say("Nothing to recover%s." % (" (status: %s)" % doc["status"] if doc else ""))
            return EXIT_OK
        if tx["op"] in ("update", "rollback"):
            if not self.args.apply:
                return self.update_module().recover(sys.modules[__name__], self, doc, tx, False)
            lock = take_lock()
            try:
                doc = self.man.load()
                tx = (doc or {}).get("transaction")
                if not tx:
                    return EXIT_OK
                return self.update_module().recover(sys.modules[__name__], self, doc, tx, True)
            finally:
                os.close(lock)
        if tx["op"].startswith("theme-apps-"):
            # F-e (paletas estáticas, 2026-11-04): los colores de la shell en otras apps
            if not self.args.apply:
                return self.theme_apps_module().recover(sys.modules[__name__], self.integrations_module(), self, doc, tx,
                                                        False)
            lock = take_lock()
            try:
                doc = self.man.load()
                tx = (doc or {}).get("transaction")
                if not tx:
                    return EXIT_OK
                return self.theme_apps_module().recover(sys.modules[__name__], self.integrations_module(), self, doc, tx,
                                                        True)
            finally:
                os.close(lock)
        if tx["op"].startswith(("hyprland-", "hypridle-")):
            if not self.args.apply:
                return self.integrations_module().recover(sys.modules[__name__], self, doc, tx, False)
            lock = take_lock()
            try:
                doc = self.man.load()
                tx = (doc or {}).get("transaction")
                if not tx:
                    return EXIT_OK
                return self.integrations_module().recover(sys.modules[__name__], self, doc, tx, True)
            finally:
                os.close(lock)
        self.say("Pending %s (started %s by pid %s), steps: %s" % (tx["op"], doc.get("updatedAt", "?"), tx.get("pid"),
                                                                   json.dumps(tx["steps"])))
        if tx["op"] == "install":
            self.say("Recovery undoes it, removing only what carries this installation's evidence.")
        else:
            self.say("Recovery finishes it, with the same checks as uninstall.")
        if not self.args.apply:
            self.say("Run `install.sh recover --apply` to do it.")
            return EXIT_PENDING
        lock = take_lock()
        try:
            doc = self.man.load()
            tx = (doc or {}).get("transaction")
            if not tx:
                return EXIT_OK
            if tx["op"] == "install":
                return self.rollback_install(doc)
            probs = self.uninstall_preflight(doc)
            if probs:
                raise Refused(probs)
            return self.uninstall_locked(doc)
        finally:
            os.close(lock)

    def integrations_module(self):
        return load_module("sumi_integrations", os.path.join("packaging", "integrations.py"))

    def theme_apps_module(self):
        return load_module("sumi_theme_apps", os.path.join("packaging", "theme_apps.py"))

    def theme_apps(self):
        return self.theme_apps_module().run(sys.modules[__name__], self.integrations_module(), self)

    def update_module(self):
        return load_module("sumi_update", os.path.join("packaging", "update.py"))

    def update(self):
        return self.update_module().run_update(sys.modules[__name__], self)

    def migrate(self):
        return load_module("sumi_migrations", os.path.join("packaging", "migrations.py")).run(sys.modules[__name__], self)

    def hyprland(self):
        return self.integrations_module().run(sys.modules[__name__], self)

    def hypridle(self):
        return self.integrations_module().run(sys.modules[__name__], self)

    def rollback_install(self, doc):
        tx = doc["transaction"]
        kept = []
        # enlaces creados por enable: los que ahora nombran la unidad y no estaban antes (foto previa registrada)
        before = tx.get("linksBefore")
        if tx["steps"].get("enable") and before is not None:
            now = self.unit_links()
            doc["links"] = {k: v for k, v in now.items() if k not in before}
            known = {r for _, r in doc["createdDirs"]}
            for d in sorted(self.unit_dirs() - set(tx.get("dirsBefore") or [])):
                if "/".join(UNITS_REL) + "/" + d not in known:
                    doc["createdDirs"].append(["config", "/".join(UNITS_REL) + "/" + d])
            self.do_unlinks(doc)
        if tx["steps"].get("units"):
            self.do_unit_removal(doc)
        qfd = None
        try:
            qfd = self.roots.chain("config", ("quickshell",), ident=doc["roots"]["config"])
        except FileNotFoundError:
            pass
        if qfd is not None:
            try:
                for name in (tx["staging"], TREE_REL[1]):
                    if not lexists(qfd, name):
                        continue
                    try:
                        tfd = open_dir(qfd, name)
                    except (OSError, Refused):
                        kept.append("quickshell/" + name)
                        continue
                    try:
                        m = file_sha(tfd, MARKER)
                        empty = not os.listdir(tfd)
                    finally:
                        os.close(tfd)
                    if name == tx["staging"] and empty:
                        os.rmdir(name, dir_fd=qfd)               # vacía y con el nombre único de esta transacción
                        continue
                    if not m or m[0] != doc["markerSha256"]:
                        if name == tx["staging"]:
                            kept.append("quickshell/" + name)    # con nuestro nombre único y contenido inesperado: incierto
                        # en la ruta final, sin la marca de ESTA instalación: nunca fue nuestro, nada que deshacer
                        continue
                    k = self.remove_tree(qfd, name, doc)
                    kept += ["quickshell/%s/%s" % (name, r) for r in k]
            finally:
                os.close(qfd)
        if kept:
            doc["status"] = "partial"
            doc["kept"] = kept
            doc["transaction"] = None
            self.man.save(doc)
            self.say("Undone except these, which don't carry this installation's evidence and were kept:")
            for k in kept:
                self.say("  " + k)
            return EXIT_REFUSED
        doc["kept"] = []
        self.args.keep_modified = False
        return self.finish_uninstall(doc)

    def remove_tree(self, qfd, name, doc):
        """Quita de quickshell/<name> los archivos con el sha esperado, la marca y los directorios vacíos."""
        kept = []
        tfd = open_dir(qfd, name)
        try:
            for rel, (sha, _) in sorted(doc["files"].items(), key=lambda kv: -kv[0].count("/")):
                d = os.path.dirname(rel)
                try:
                    dfd = self.roots_open_rel(tfd, d) if d else os.dup(tfd)
                except (FileNotFoundError, Refused):
                    continue
                try:
                    r = remove_if(dfd, os.path.basename(rel), sha)
                    if r in ("kept", "aside"):
                        kept.append(kept_label(rel, r))
                finally:
                    os.close(dfd)
            r = remove_if(tfd, MARKER, doc["markerSha256"])
            if r in ("kept", "aside"):
                kept.append(kept_label(MARKER, r))
            for d in sorted(doc["dirs"], key=lambda x: -x.count("/")):
                try:
                    os.rmdir(d, dir_fd=tfd)
                except OSError:
                    pass
        finally:
            os.close(tfd)
        try:
            os.rmdir(name, dir_fd=qfd)
        except OSError:
            pass
        return kept

    def status(self):
        try:
            doc = self.man.load()
        except Refused as e:
            self.say("Manifest: " + "; ".join(e.reasons))
            return EXIT_REFUSED
        if doc is None:
            self.say("Sumi Shell is not installed by this installer here.")
            return EXIT_OK
        self.say("Sumi Shell %s · status %s · tree %s · %d files · units %s · links %s" % (
            doc["source"]["version"], doc["status"], self.tree_real(), len(doc["files"]),
            ", ".join(doc["units"]) or "none", ", ".join(doc["links"]) or "none"))
        t = doc.get("tree") or {}
        self.say("  on disk: %s · build %s" % (t.get("version"), t.get("buildId") or "unknown (installed before builds)"))
        u = doc.get("update") or {}
        if u.get("running"):
            r = u["running"]
            self.say("  running: %s · build %s · pid %s (checked %s)" % (r.get("version"), r.get("build") or "?", r.get("pid"),
                                                                        r.get("at")))
        if u.get("state") and u["state"] != "verified":
            self.say("  update: %s — %s" % (u["state"], u.get("why", "")))
        if doc.get("previous"):
            self.say("  previous version kept: %s (%s)" % (doc["previous"].get("version"), doc["previous"].get("rel")))
        if doc.get("transaction"):
            self.say("Pending %s: %s (run `install.sh recover`)" % (doc["transaction"]["op"],
                                                                     json.dumps(doc["transaction"]["steps"])))
        for k in doc.get("kept", []):
            self.say("  kept: " + k)
        if doc.get("integrations"):
            for line in self.integrations_module().status_lines(sys.modules[__name__], self, doc):
                self.say(line)
        return EXIT_PENDING if doc.get("transaction") else EXIT_OK


def all_dirs(rels):
    """Todos los directorios (y sus ancestros) que contienen los archivos `rels`, de fuera adentro."""
    out = set()
    for rel in rels:
        d = os.path.dirname(rel)
        while d:
            out.add(d)
            d = os.path.dirname(d)
    return sorted(out, key=lambda x: (x.count("/"), x))


def EXIT_PARTIAL_OR_OK(doc):
    return EXIT_REFUSED if doc.get("status") == "partial" else EXIT_OK


def main():
    p = argparse.ArgumentParser(prog="install.sh")
    sub = p.add_subparsers(dest="cmd", required=True)
    i = sub.add_parser("install")
    i.add_argument("--no-units", action="store_true")
    i.add_argument("--enable", action="store_true")
    i.add_argument("--dry-run", action="store_true")
    u = sub.add_parser("uninstall")
    u.add_argument("--keep-modified", action="store_true")
    u.add_argument("--purge", action="store_true")
    u.add_argument("--yes", action="store_true")
    u.add_argument("--dry-run", action="store_true")
    r = sub.add_parser("recover")
    r.add_argument("--apply", action="store_true")
    r.add_argument("--reload", action="store_true")
    r.add_argument("--restart", action="store_true")
    sub.add_parser("status")
    up = sub.add_parser("update")
    ug = up.add_mutually_exclusive_group()
    ug.add_argument("--apply", action="store_true")
    ug.add_argument("--finish", action="store_true")
    ug.add_argument("--verify", action="store_true")
    ug.add_argument("--rollback", action="store_true")
    up.add_argument("--reload", action="store_true")
    up.add_argument("--restart", action="store_true")
    up.add_argument("--accept-api", default=None)
    up.add_argument("--accept-settings-migration", action="store_true")
    up.add_argument("--downgrade", action="store_true")
    up.add_argument("--replace-modified", action="store_true")
    mg = sub.add_parser("migrate")
    mg.add_argument("id", nargs="?")
    mgg = mg.add_mutually_exclusive_group()
    mgg.add_argument("--apply", action="store_true")
    mgg.add_argument("--revert", action="store_true")
    mgg.add_argument("--recover", action="store_true")
    h = sub.add_parser("hyprland")
    hg = h.add_mutually_exclusive_group()
    hg.add_argument("--apply", action="store_true")
    hg.add_argument("--revert", action="store_true")
    hg.add_argument("--verify", action="store_true")
    h.add_argument("--reload", action="store_true")
    ta = sub.add_parser("theme-apps")
    ta.add_argument("apps", nargs="*")
    tag = ta.add_mutually_exclusive_group()
    tag.add_argument("--apply", action="store_true")
    tag.add_argument("--revert", action="store_true")
    tag.add_argument("--verify", action="store_true")
    d = sub.add_parser("hypridle")
    dg = d.add_mutually_exclusive_group()
    dg.add_argument("--apply", action="store_true")
    dg.add_argument("--revert", action="store_true")
    d.add_argument("--replace-lock-cmd", action="store_true")
    d.add_argument("--replace-before-sleep-cmd", action="store_true")
    d.add_argument("--inhibit-sleep", choices=["3"])
    d.add_argument("--restart", action="store_true")
    a = p.parse_args()
    for name in ("no_units", "enable", "dry_run", "keep_modified", "purge", "yes", "apply", "revert", "verify", "reload",
                 "replace_lock_cmd", "replace_before_sleep_cmd", "inhibit_sleep", "restart", "finish", "rollback",
                 "accept_api", "accept_settings_migration", "downgrade", "replace_modified", "id"):
        if not hasattr(a, name):
            setattr(a, name, False)
    signal.signal(signal.SIGINT, _on_signal)
    signal.signal(signal.SIGTERM, _on_signal)
    try:
        inst = Installer(a)
        return {"install": inst.install, "uninstall": inst.uninstall, "recover": inst.recover,
                "status": inst.status, "hyprland": inst.hyprland, "hypridle": inst.hypridle, "update": inst.update,
                "theme-apps": inst.theme_apps,
                "migrate": inst.migrate}[a.cmd]()
    except Refused as e:
        print("install.sh %s: refused:" % a.cmd, file=sys.stderr)
        for r_ in e.reasons:
            print("  - " + r_, file=sys.stderr)
        return EXIT_REFUSED
    except Interrupted as e:
        print("install.sh %s: interrupted (%s): run `install.sh recover`" % (a.cmd, e), file=sys.stderr)
        return EXIT_PENDING
    except Exception as e:
        print("install.sh %s: internal error: %s: %s" % (a.cmd, type(e).__name__, e), file=sys.stderr)
        return EXIT_FAIL


if __name__ == "__main__":
    sys.exit(main())
