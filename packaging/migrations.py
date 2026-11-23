"""Sumi Shell installer — `install.sh migrate` (portability F6f, 2026-10-14).

Comentarios en español, textos en inglés. Diseño: portabilidad/F6F-DISENO.md D-F7 (P7.11–P7.13): los dos migradores de F1
(tools/f1/migrate-{wallpaper,theme}-state.py) pasan al repo distribuible como una LISTA FIJA, no un sistema genérico.

    migrate                    lista el estado de cada migración
    migrate ID                 qué haría, sin escribir nada
    migrate ID --apply         importa el estado legado (con la shell parada: es el contrato de F1)
    migrate ID --revert        deshace una importación SÓLO si nada cambió desde entonces (sha de cada archivo)

Mismas reglas que F1: los archivos legados nunca se tocan; nunca se mezcla un estado nuevo con el legado; publicar es
exclusivo (link(), nunca reemplaza); el registro `*-migration-v1.json` se escribe EL ÚLTIMO y es lo que dice «hecho». Lo
nuevo frente a F1: el corte entre publicar y registrar se reconoce (estado `partial`: lo publicado es idéntico, byte a byte,
al legado) y se completa; lo que no sea idéntico es `conflict` y no se toca. `update` nunca ejecuta una migración.
"""
import fcntl
import hashlib
import json
import os
import stat
import time

I = None
WALLPAPER = ("current-wallpaper", "current-wallpaper-outputs")
THEME = ("enabled", "scheme", "mode", "contrast", "source")
# id → origen en config, destino XDG, registro y cerrojo.
MIGRATIONS = (
    {"id": "wallpaper-state-v1", "what": "the wallpaper (global and per output) from the rice's ~/.config/hypr",
     "legacy": ("hypr",), "prefix": ".", "names": WALLPAPER, "dest": ("state", ("sumi-shell",)),
     "record": "wallpaper-migration-v1.json", "lock": ".wallpaper-migration.lock"},
    {"id": "theme-state-v1", "what": "the theme settings (enabled, scheme, mode, contrast, source) from ~/.config/matugen",
     "legacy": ("matugen",), "prefix": "", "names": THEME, "dest": ("state", ("sumi-shell", "theme")),
     "record": "theme-migration-v1.json", "lock": ".theme-migration.lock"},
    {"id": "websites-v1", "what": "bookmarks from hypr/websites.conf",
     "legacy": ("hypr",), "prefix": "", "names": ("websites.conf",), "dest": ("config", ("sumi-shell",)),
     "record": ".websites-migration-v1.json", "lock": ".websites-migration.lock", "keep_identical": True},
)


def sha(b):
    return hashlib.sha256(b).hexdigest() if b is not None else None


def read_file(dfd, name):
    """Contenido de un archivo regular sin seguir enlaces; None si no existe; ValueError si no es un archivo regular."""
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
    except FileNotFoundError:
        return None
    except OSError as e:
        raise ValueError("%s can't be read safely (%s)" % (name, e.strerror))
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ValueError("%s isn't a regular file" % name)
        data = b""
        while True:
            b = os.read(fd, 1 << 16)
            if not b:
                return data
            data += b
    finally:
        os.close(fd)


def open_chain(roots, key, parts, create=False):
    try:
        return roots.chain(key, parts, create=create)
    except FileNotFoundError:
        return None


def look(roots, m):
    """El estado de una migración, sin escribir nada: {id, state, why, legacy:{}, new:{}, record}."""
    key, parts = m["dest"]
    out = {"id": m["id"], "what": m["what"], "legacy": {}, "new": {}, "record": None,
           "legacyDir": os.path.join(roots.real["config"], *m["legacy"]),
           "destDir": os.path.join(roots.real[key], *parts)}
    try:
        lfd = open_chain(roots, "config", m["legacy"])
        sfd = open_chain(roots, *m["dest"])
        try:
            for n in m["names"]:
                out["legacy"][n] = read_file(lfd, m["prefix"] + n) if lfd is not None else None
                out["new"][n] = read_file(sfd, n) if sfd is not None else None
            rec = read_file(sfd, m["record"]) if sfd is not None else None
        finally:
            for fd in (lfd, sfd):
                if fd is not None:
                    os.close(fd)
    except (ValueError, I.Refused) as e:
        out.update(state="unknown", why=str(e))
        return out
    if rec is not None:
        try:
            r = json.loads(rec)
        except ValueError:
            r = None
        if not isinstance(r, dict) or r.get("version") != 1:
            out.update(state="unknown", why="its record %s isn't a version-1 record" % m["record"])
            return out
        out["record"] = r
        changed = [n for n, f in (r.get("files") or {}).items() if f.get("present") and sha(out["new"].get(n)) !=
                   f.get("sha256")]
        out.update(state="done", why="imported%s%s" % (" by " + r["by"] if r.get("by") else "", (
            "; changed since (yours now): " + ", ".join(changed)) if changed else ""))
        out["changed"] = changed
        return out
    have_legacy = [n for n in m["names"] if out["legacy"][n] is not None]
    have_new = [n for n in m["names"] if out["new"][n] is not None]
    if not have_legacy:
        out.update(state="not-applicable", why="there's no legacy state to import")
    elif not have_new:
        out.update(state="pending", why="legacy files to import: " + ", ".join(m["prefix"] + n for n in have_legacy))
    elif all(out["legacy"][n] is not None and out["new"][n] == out["legacy"][n] for n in have_new):
        if m.get("keep_identical"):
            out.update(state="present", why="an identical file already exists and remains yours")
        else:
            out.update(state="partial", why="an import was cut before it was recorded: what was published (%s) is identical "
                       "to the legacy files, so it can be completed" % ", ".join(have_new))
    else:
        diff = [n for n in have_new if out["new"][n] != out["legacy"][n]]
        out.update(state="conflict", why="state already exists that doesn't come from the legacy files (%s): it isn't "
                   "touched; review it by hand" % ", ".join(diff))
    return out


def listing(installer_module, roots):
    global I
    I = installer_module
    return [look(roots, m) for m in MIGRATIONS]


def settings_line(roots):
    """Informativo: settings.json lo convierte la propia shell al cargar (con su copia), nunca `migrate`."""
    p = os.path.join(roots.real["config"], "sumi-shell", "settings.json")
    try:
        with open(os.path.join(I.ROOT, "sumi", "version.json")) as f:
            want = json.load(f).get("settingsSchema")
        with open(p) as f:
            have = json.load(f).get("schemaVersion")
    except (OSError, ValueError):
        return "settings-schema: no settings.json (or unreadable): nothing to say"
    if have == want:
        return "settings-schema: settings.json is at schema %s, what this version uses" % have
    if isinstance(have, int) and isinstance(want, int) and have < want:
        return ("settings-schema: settings.json is at schema %s; this version converts it to %s itself when it loads, "
                "keeping a copy (`install.sh update` asks for --accept-settings-migration)" % (have, want))
    return "settings-schema: settings.json is at schema %s, newer than this version's %s (it would run read only)" % (
        have, want)


class Migrator:
    def __init__(self, inst):
        self.inst = inst
        self.roots = inst.roots
        self.args = inst.args

    def say(self, m):
        self.inst.say(m)

    def find(self, mid):
        for m in MIGRATIONS:
            if m["id"] == mid:
                return m
        raise I.Refused(["no migration called %r (there are: %s, identity-v1)" % (mid, ", ".join(m["id"] for m in MIGRATIONS))])

    def no_shell(self):
        """El contrato de F1: importar con los consumidores parados (la shell lee estos archivos y reaccionaría)."""
        q = self.inst.running()
        if q.get("error"):
            raise I.Refused(["can't tell whether Sumi Shell is running (%s)" % q["error"]])
        live = q.get("instances", []) + q.get("legacyInstances", [])
        if live:
            raise I.Refused(["a shell is running (pid %s): stop it first; it reads these files and would act on them "
                             "while they're being written" % ", ".join(str(i["pid"]) for i in live)])

    def identity(self):
        return I.load_module("sumi_identity", os.path.join("packaging", "identity.py"))

    def run(self):
        if not self.args.id:
            for r in listing(I, self.roots) + [self.identity().listing_row(I)]:
                self.say("%-20s %-15s %s" % (r["id"], r["state"], r["why"]))
            self.say(settings_line(self.roots))
            return I.EXIT_OK
        # Sumi Shell (2026-11-07): el estado del nombre de antes, con su propio módulo (copia de directorios enteros)
        if self.args.id == "identity-v1":
            return self.identity().run(I, self)
        if getattr(self.args, "recover", False):
            raise I.Refused(["--recover is only for identity-v1"])
        m = self.find(self.args.id)
        r = look(self.roots, m)
        if not (self.args.apply or self.args.revert):
            self.say("%s: %s — %s" % (m["id"], r["state"], r["why"]))
            self.say("  imports %s into %s (the legacy files stay as they are)" % (m["what"], r["destDir"]))
            if r["state"] in ("pending", "partial"):
                self.say("  run `install.sh migrate %s --apply` with the shell stopped" % m["id"])
            elif r["state"] == "done" and not r.get("changed"):
                self.say("  `install.sh migrate %s --revert` would remove what it imported (nothing changed since)" % m["id"])
            return I.EXIT_OK if r["state"] not in ("conflict", "unknown") else I.EXIT_REFUSED
        self.no_shell()
        lock = I.take_lock()
        try:
            return self.apply(m) if self.args.apply else self.revert(m)
        finally:
            os.close(lock)

    def f1_lock(self, sfd, m):
        """El cerrojo de F1 (mismo nombre): tools/f1 y `install.sh migrate` no se pisan."""
        fd = os.open(m["lock"], os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=sfd)
        fcntl.flock(fd, fcntl.LOCK_EX)
        return fd

    def publish(self, sfd, name, data):
        """Exclusivo: un temporal propio y link(), que nunca reemplaza; un destino que aparece entretanto → se niega."""
        tmp = ".%s.sumi-migrate-%d" % (name, os.getpid())
        try:
            os.unlink(tmp, dir_fd=sfd)
        except FileNotFoundError:
            pass
        I.write_new(sfd, tmp, data, 0o644)
        try:
            os.link(tmp, name, src_dir_fd=sfd, dst_dir_fd=sfd, follow_symlinks=False)
        except FileExistsError:
            raise I.Refused(["%s appeared while importing: it was left as it is" % name])
        finally:
            os.unlink(tmp, dir_fd=sfd)

    def apply(self, m):
        sfd = self.roots.chain(*m["dest"], create=True)
        try:
            lk = self.f1_lock(sfd, m)
            try:
                r = look(self.roots, m)          # otra vez, bajo los dos cerrojos
                if r["state"] == "done":
                    self.say("%s: already imported; nothing to do." % m["id"])
                    return I.EXIT_OK
                if r["state"] in ("not-applicable", "present"):
                    self.say("%s: %s; nothing to do." % (m["id"], r["why"]))
                    return I.EXIT_OK
                if r["state"] not in ("pending", "partial"):
                    raise I.Refused(["%s is %s: %s" % (m["id"], r["state"], r["why"])])
                record = {"version": 1, "legacy": r["legacyDir"], "by": "install.sh migrate",
                          "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "completed": r["state"] == "partial",
                          "files": {n: {"present": r["legacy"][n] is not None, "sha256": sha(r["legacy"][n])}
                                    for n in m["names"]}}
                done = []
                for n in m["names"]:
                    data = r["legacy"][n]
                    if data is None:
                        continue
                    if r["new"][n] is not None:
                        continue                 # `partial`: ya está, idéntico (comprobado en look)
                    I.fault("migrate-" + n, "before")
                    self.publish(sfd, n, data)
                    done.append(n)
                I.fault("migrate-record", "before")
                self.publish(sfd, m["record"], (json.dumps(record, indent=2) + "\n").encode())
                os.fsync(sfd)
            finally:
                os.close(lk)
        finally:
            os.close(sfd)
        self.say("%s: imported (%s)%s. The legacy files in %s were not touched." % (
            m["id"], ", ".join(done) or "nothing new", "; completed an interrupted import" if r["state"] == "partial" else
            "", r["legacyDir"]))
        return I.EXIT_OK

    def revert(self, m):
        try:
            sfd = self.roots.chain(*m["dest"])
        except FileNotFoundError:
            raise I.Refused(["%s was never imported here" % m["id"]])
        try:
            lk = self.f1_lock(sfd, m)
            try:
                r = look(self.roots, m)
                if r["state"] != "done":
                    raise I.Refused(["%s is %s: there's no import to undo" % (m["id"], r["state"])])
                if r.get("changed"):
                    raise I.Refused(["changed since the import (%s): those files are yours now; nothing was removed" %
                                     ", ".join(r["changed"])])
                files = r["record"].get("files") or {}
                # cada archivo, sólo con el sha registrado (remove_if de F6d: aparta, comprueba y borra)
                for n, f in files.items():
                    if f.get("present"):
                        res = I.remove_if(sfd, n, f["sha256"])
                        if res not in ("removed", "absent"):
                            raise I.Refused(["%s changed while it was being removed (%s): stopped; the record stays" % (
                                n, res)])
                rec = read_file(sfd, m["record"])
                res = I.remove_if(sfd, m["record"], sha(rec))
                if res not in ("removed", "absent"):
                    raise I.Refused(["the record changed while it was being removed: it stays"])
                os.fsync(sfd)
            finally:
                os.close(lk)
        finally:
            os.close(sfd)
        self.say("%s: the import was undone (the legacy files were never touched)." % m["id"])
        return I.EXIT_OK


def run(installer_module, inst):
    global I
    I = installer_module
    return Migrator(inst).run()
