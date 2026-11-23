"""Sumi Shell installer — `install.sh update` (portability F6f, 2026-10-14).

Comentarios en español, textos en inglés. Diseño: portabilidad/F6F-DISENO.md §10–§11 (P7.11/P7.12; implementación P7.13).

    update                          vista previa: versiones y construcciones, compatibilidad, diferencias, qué hace falta
    update --apply [--reload | --restart] [--accept-api N] [--accept-settings-migration] [--downgrade] [--replace-modified]
    update --finish (--reload | --restart)     terminar una actualización que quedó en disco sin cargar
    update --verify                           comprobar la instancia viva frente a lo instalado
    update --rollback [--reload | --restart]  volver a la generación anterior conservada

Lo esencial:
  · El manifiesto describe SIEMPRE lo que hay en disco en la ruta del árbol (`files`, `tree`); lo que corre va aparte
    (`update.running`, la última instancia COMPROBADA). Disco ≠ proceso ≠ configuración tienen estados propios, nunca «éxito».
  · La identidad de construcción (`build.json`, `api` → build) prueba que lo cargado es lo que se intentó instalar.
  · Recarga sólo si se puede argumentar: restart.required = false declarado, sin componentes en línea nuevos ni cambios de
    qmldir, y la construcción en ejecución conocida e igual a la del disco. Si no, arranque en frío explícito (`--restart`).
  · Nunca se reinicia la shell sin `--restart`; nunca se toca el Lock; `settings.json` sólo se repone por evidencia (sha).
"""
import hashlib
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

I = None          # el módulo installer (primitivas, Refused, manifiesto…), lo ponen run_update()/recover()
CRITICAL_VERBS = ("api", "status", "reload", "lockStatus", "lockNow", "notifServer")
HELPER_MODES = ("rescue-request", "rescue", "instant", "*")          # `*` = session (el modo por defecto)
LOAD_ERRORS = re.compile(r"Failed to load configuration|is not a type|Type \w+ unavailable")
ANSI = re.compile(r"\x1b\[[0-9;]*m")
SETTINGS_REL = ("sumi-shell", "settings.json")
# Estados de `update.state` que piden una decisión antes de otra actualización
BLOCKING = ("swapped-not-loaded", "installed-unverified", "verify-failed", "settings-conflict", "broken")


def sha(b):
    return hashlib.sha256(b).hexdigest()


def run(argv, timeout=20, env=None):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, env=env, stdin=subprocess.DEVNULL)
        return p.returncode, p.stdout, p.stderr
    except (OSError, subprocess.TimeoutExpired) as e:
        return 127, "", str(e)


def semver_module():
    """SemVer 2.0.0 (packaging/semver.py): precedencia completa, prereleases incluidas (antes: sólo X.Y.Z, y una
    0.5.0-beta.1 hacía que `update` se negara por «no valid version»)."""
    return I.load_module("sumi_semver", os.path.join("packaging", "semver.py"))


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def short(b):
    return (b or "unknown").split(":")[-1][:12]


def parse_usec(v):
    """`systemctl show` da StartLimitIntervalUSec como «1min», «10s», «1min 30s»… → segundos."""
    total = 0.0
    for n, u in re.findall(r"(\d+(?:\.\d+)?)\s*(us|ms|min|s|h)?", v or ""):
        total += float(n) * {"us": 1e-6, "ms": 1e-3, "s": 1, "min": 60, "h": 3600, "": 1e-6}[u]
    return total


# ---- árboles: componentes en línea, qmldir, comprobaciones sin ejecutar ----------------------------------------------

def read_tree(path):
    """[(rel, sha, modo, datos)] de un árbol en disco (sin seguir enlaces)."""
    out = []
    for folder, dirs, files in os.walk(path):
        dirs[:] = sorted(dirs)
        for n in sorted(files):
            p = os.path.join(folder, n)
            st = os.lstat(p)
            if not stat.S_ISREG(st.st_mode):
                continue
            with open(p, "rb") as f:
                data = f.read()
            out.append((os.path.relpath(p, path), sha(data), 0o755 if st.st_mode & 0o111 else 0o644, data))
    return out


def inline_components(files):
    out = set()
    for rel, _, _, data in files:
        if rel.endswith(".qml"):
            for m in re.finditer(rb"^\s*component\s+([A-Z]\w*)\s*:", data, re.M):
                out.add((rel, m.group(1).decode()))
    return out


def qmldirs(files):
    return {rel: h for rel, h, _, _ in files if os.path.basename(rel) == "qmldir"}


def qmllint():
    # Qt 5 can own /usr/bin/qmllint even when Qt 6 is installed (F7, EndeavourOS).
    # Select by the flag we need, not the executable's name or version string.
    seen = set()
    for path in (shutil.which("qmllint"), shutil.which("qmllint6"),
                 "/usr/lib/qt6/bin/qmllint", "/usr/lib64/qt6/bin/qmllint"):
        if not path or not os.access(path, os.X_OK):
            continue
        real = os.path.realpath(path)
        if real in seen:
            continue
        seen.add(real)
        rc, out, err = run([path, "--help"], timeout=5)
        if rc == 0 and re.search(r"(?m)^\s*--bare\b", out + err):
            return path
    return None


def static_checks(files):
    """Sin ejecutar nada del árbol: QML (qmllint --bare, U3: sólo sintaxis), sh/bash (-n), Python (compile en memoria),
    JSON. Devuelve (errores, notas)."""
    errs, notes = [], []
    lint = qmllint()
    d = tempfile.mkdtemp(prefix="sumi-update-check-")
    try:
        qml = []
        for rel, _, mode, data in files:
            p = os.path.join(d, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "wb") as f:
                f.write(data)
            first = data.split(b"\n", 1)[0]
            if rel.endswith(".qml"):
                qml.append(p)
            elif rel.endswith(".py") or (first.startswith(b"#!") and b"python" in first):
                try:
                    compile(data, rel, "exec", dont_inherit=True)
                except (SyntaxError, ValueError) as e:
                    errs.append("%s: %s" % (rel, e))
            elif rel.endswith(".json"):
                try:
                    json.loads(data)
                except ValueError as e:
                    errs.append("%s: %s" % (rel, e))
            elif first.startswith(b"#!") and (b"bash" in first or first.rstrip().endswith(b"/sh")):
                rc, out, err = run(["bash" if b"bash" in first else "sh", "-n", p])
                if rc != 0:
                    errs.append("%s: %s" % (rel, (err or out).strip().replace(d + "/", "")[:200]))
        if lint:
            for i in range(0, len(qml), 40):
                rc, out, err = run([lint, "--bare"] + qml[i:i + 40], timeout=120)
                if rc != 0:
                    msg = [l for l in (err + out).splitlines() if "rror" in l]
                    errs.append("QML: " + " · ".join(msg or [(err or out).strip()])[:300].replace(d + "/", ""))
        else:
            notes.append("No qmllint with --bare is available: QML syntax wasn't checked before swapping "
                         "(the load check still runs)")
    finally:
        shutil.rmtree(d, ignore_errors=True)
    return errs, notes


def consumer_checks(files, contract):
    """Lo que esperan los consumidores críticos, en el árbol nuevo: los verbos del helper, las unidades y los clientes; los modos
    del helper (hypridle y las unidades lo llaman); los scripts de las unidades; los atajos del contrato público."""
    byrel = {rel: data for rel, _, _, data in files}
    probs = []
    ipc = byrel.get("core/Ipc.qml", b"").decode("utf-8", "replace")
    for v in CRITICAL_VERBS:
        if not re.search(r"function %s\(" % v, ipc):
            probs.append("the new tree's IPC lacks `%s` (the lock helper, the units or clients use it)" % v)
    helper = byrel.get("scripts/sumi-lock", b"").decode("utf-8", "replace")
    labels = set(re.findall(r"^\s*([a-z*-]+)\)", helper, re.M))
    for mode in HELPER_MODES:
        if mode not in labels:
            probs.append("the new lock helper lacks its `%s` mode (hypridle and the units call it)" % (
                "session" if mode == "*" else mode))
    for rel in ("scripts/session-check", "scripts/wait-for-hyprland", "scripts/sumi-lock", "systemd/sumi-shell.service",
                "systemd/sumi-lock-rescue.service"):
        if rel not in byrel:
            probs.append("the new tree lacks %s" % rel)
    sc = byrel.get("core/Shortcuts.qml", b"").decode("utf-8", "replace")
    missing = [n for n in contract["shortcuts"]["names"] if not re.search(r'name:\s*"%s"' % re.escape(n), sc)]
    if missing:
        probs.append("the new tree doesn't register these public shortcuts: %s" % ", ".join(missing))
    return probs


# ---- la instancia ----------------------------------------------------------------------------------------------------

def qs_ipc(pid, *args, timeout=10):
    rc, out, err = run(["qs", "ipc", "--pid", str(pid)] + list(args), timeout=timeout)
    return rc, out.strip(), err.strip()


def ipc_json(pid, verb):
    rc, out, err = qs_ipc(pid, "call", "sumi", verb)
    try:
        d = json.loads(out)
        return d if isinstance(d, dict) else None
    except ValueError:
        return None


NOT_READY = "Not ready to accept queries"


def ipc_ready(pid, wait=20):
    """Medido (F6f, anidado): tras `reload` la instancia escribe «Configuration Loaded» y aún contesta ~2,5 s «Not ready to
    accept queries yet.»; una orden enviada entonces NO se ejecuta. Espera a que conteste de verdad."""
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        rc, out, err = qs_ipc(pid, "call", "sumi", "api")
        if out.startswith("{"):
            return True
        if NOT_READY not in out + err and rc != 0 and "No running" in out + err:
            return False
        time.sleep(0.4)
    return False


def request_reload(pid, guard=None):
    """`reload` sólo cuando la instancia acepta órdenes; si aun así contesta «Not ready», se repite (nunca se da por
    pedida una recarga que no se aceptó)."""
    for _ in range(3):
        if not ipc_ready(pid):
            return False
        if guard:
            guard()
        rc, out, err = qs_ipc(pid, "call", "sumi", "reload")
        if NOT_READY not in out + err and rc == 0:
            return True
        time.sleep(0.5)
    return False


def qs_log(pid):
    rc, out, err = run(["qs", "log", "--pid", str(pid)], timeout=20)
    return [ANSI.sub("", l) for l in out.splitlines()] if rc == 0 else None


class Failed(Exception):
    """La comprobación falló de forma definitiva (no tiene sentido esperar más)."""


class Updater:
    def __init__(self, inst):
        self.inst = inst
        self.roots = inst.roots
        self.man = inst.man
        self.args = inst.args
        self.inhibitor = None
        self.unit_backed = False
        self.watch_settings = None     # el registro de settings.json de la actualización en curso (ver observe_settings)
        self.lc = I.load_module("sumi_lockchain", os.path.join("packaging", "lockchain.py"))
        self.gs = I.load_module("sumi_integrations", os.path.join("packaging", "integrations.py"))
        self.gs.I = I
        with open(os.path.join(I.ROOT, "api", "contract-v1.json")) as f:
            self.contract = json.load(f)

    def say(self, m):
        self.inst.say(m)

    def tree(self):
        return self.inst.tree_real()

    # -- lo que corre --
    def instances(self):
        """(las de este árbol, las de otras copias) por `qs list` (F6a: la identidad de qs va por la ruta)."""
        q = self.inst.running()
        if q.get("error"):
            raise I.Refused(["can't tell whether Sumi Shell is running (%s)" % q["error"]])
        mine, other = [], []
        for i in q.get("instances", []):
            (mine if os.path.realpath(i["path"]) == self.tree() else other).append(i)
        other += q.get("legacyInstances", [])         # Kitasan-Shell (nombre de antes): otra shell, nunca «la mía»
        return mine, other

    def unit(self):
        rc, out, err = I.systemctl("show", I.UNITS[0], "-p", "MainPID", "-p", "ActiveState", "-p", "SubState",
                                   "-p", "StartLimitBurst", "-p", "StartLimitIntervalUSec", "-p", "Restart",
                                   "-p", "NRestarts", "-p", "ActiveEnterTimestampMonotonic", "-p", "LoadState",
                                   "-p", "FragmentPath", "-p", "Result")
        props = dict(l.split("=", 1) for l in (out or "").splitlines() if "=" in l) if rc == 0 else {}
        props["rescueLoaded"] = (I.unit_props(I.UNITS[1]) or {}).get("LoadState") == "loaded"
        return props

    def snapshot(self, pid, wait=True):
        """La identidad de ejecución: pid, hora de arranque (/proc) y lo que dice `api` (versión, contrato, construcción).
        Con `wait`, si la instancia aún no acepta órdenes (recién recargada), se espera a que lo haga."""
        api = ipc_json(pid, "api")
        if api is None and wait and ipc_ready(pid, 15):
            api = ipc_json(pid, "api")
        api = api or {}
        return {"pid": pid, "start": self.lc.proc_start(pid), "version": api.get("version"),
                "apiVersion": api.get("apiVersion"), "build": api.get("build") or None, "at": now()}

    def lock_phase(self, pid):
        d = ipc_json(pid, "lockStatus")
        if d is None and ipc_ready(pid, 15):
            d = ipc_json(pid, "lockStatus")
        return (d or {}).get("phase")

    def require_unlocked(self):
        """Una transición del proceso exige una lectura fresca; desconocido conserva la transacción."""
        inst = self.one_instance()
        if inst and self.lock_phase(inst["pid"]) != "unlocked":
            raise I.Refused(["the session isn't unlocked: the transaction stays pending; once unlocked, "
                             "run `install.sh recover --apply --reload|--restart`"])

    # -- verificación (§11.3): las cinco comprobaciones --
    def check_once(self, expect, mode, before, log_mark, t0, nrestarts):
        """Una pasada. (instantánea | None, problemas); lanza Failed si ya no tiene sentido esperar."""
        probs = []
        mine, other = self.instances()
        if self.unit_backed:
            u = self.unit()
            if u.get("ActiveState") == "failed":
                raise Failed("sumi-shell.service failed (%s)" % u.get("Result"))
            if nrestarts is not None and (int(u.get("NRestarts") or 0) > nrestarts or u.get("SubState") == "auto-restart"):
                raise Failed("the new start failed (systemd is retrying it)")
        if len(mine) != 1:
            return None, ["%d instances run from %s" % (len(mine), self.tree())]
        pid = mine[0]["pid"]
        # 1. identidad: recarga = MISMO proceso (pid y hora de arranque); reinicio = proceso NUEVO, el de la unidad, nacido
        #    después de pedirlo. Que el pid cambie en un reinicio es lo esperado, no un fallo.
        if mode == "reload" and (pid != before["pid"] or self.lc.proc_start(pid) != before["start"]):
            raise Failed("the instance changed (pid %s → %s) during a reload" % (before["pid"], pid))
        if mode == "restart":
            u = self.unit()
            if str(pid) != u.get("MainPID"):
                return None, ["the running instance (pid %s) isn't the unit's main process (%s)" % (pid, u.get("MainPID"))]
            if before and pid == before["pid"] and self.lc.proc_start(pid) == before["start"]:
                return None, ["still the old process (pid %s)" % pid]
            if t0 and (self.lc.proc_start(pid) or 0) < t0 - 1.5:
                raise Failed("the unit's process (pid %s) started before the restart was asked" % pid)
        # 5 (primero: es lo que decide). Errores de ESTE intento de carga: desde la marca, o todo el log de un proceso nuevo
        lines = qs_log(pid)
        if lines is None:
            return None, ["the instance's log can't be read"]
        fresh = lines[log_mark:] if mode == "reload" else lines
        bad = [l for l in fresh if LOAD_ERRORS.search(l)]
        if bad:
            raise Failed("load error: " + bad[0].strip()[-200:])
        if not any("Configuration Loaded" in l for l in fresh):
            return None, ["no «Configuration Loaded» yet"]
        self.observe_settings()
        snap = self.snapshot(pid, wait=False)
        if snap.get("version") is None:
            return None, ["the instance doesn't answer `api` yet"]
        # 2. versión, contrato y construcción: lo cargado es lo que se intentó instalar
        for k in ("version", "apiVersion", "build"):
            if snap.get(k) != expect.get(k):
                raise Failed("%s: running %r, expected %r" % (k, snap.get(k), expect.get(k)))
        # 3. consumidores críticos: verbos y atajos registrados en Hyprland
        rc, out, err = qs_ipc(pid, "show")
        for v in CRITICAL_VERBS:
            if not re.search(r"function %s\(" % v, out):
                raise Failed("the running shell lacks the `%s` verb" % v)
        g = self.gs.hj("globalshortcuts")
        if isinstance(g, list):
            names = {x.get("name") for x in g if isinstance(x, dict)}
            appid = self.contract["shortcuts"]["appid"]
            miss = [n for n in self.contract["shortcuts"]["names"] if "%s:%s" % (appid, n) not in names]
            if miss:
                probs.append("%d public shortcuts aren't registered with Hyprland (%s…)" % (len(miss), ", ".join(miss[:3])))
        else:
            probs.append("Hyprland's global shortcuts can't be read")
        # 4. funcionamiento mínimo: ajustes listos y el Lock responde
        st = ipc_json(pid, "status") or {}
        store = (((st.get("settings") or {}).get("store")) or {}).get("status")
        if store != "ready":
            probs.append("the settings store is %r, not ready" % store)
        if self.lock_phase(pid) is None:
            probs.append("`lockStatus` doesn't answer")
        return snap, probs

    def verify(self, expect, mode, before=None, log_mark=0, t0=None, wait=25, nrestarts=None):
        """expect = {version, apiVersion, build}; mode = reload | restart | cold. (instantánea | None, problemas)."""
        deadline = time.monotonic() + wait
        while True:
            try:
                snap, probs = self.check_once(expect, mode, before, log_mark, t0, nrestarts)
            except Failed as e:
                return None, [str(e)]
            if snap and not probs:
                return snap, []
            if time.monotonic() >= deadline:
                return None, probs
            time.sleep(0.6)

    # -- el diagnóstico (sin escribir nada) --
    def plan(self, doc):
        p = {"refuse": [], "notes": [], "need": []}
        new_files = I.with_build(I.source_files())
        info = I.source_info()
        p["to"] = {"version": info.get("version"), "apiVersion": info.get("apiVersion"), "build": I.build_id(new_files),
                   "settingsSchema": info.get("settingsSchema"), "restart": info.get("restart"),
                   "minUpdateFrom": info.get("minUpdateFrom")}
        t = doc.get("tree") or {}
        p["from"] = {"version": t.get("version"), "apiVersion": t.get("apiVersion"), "build": t.get("buildId")}
        p["newFiles"] = new_files
        p["recorded"] = dict(doc["files"])
        # el árbol instalado frente al manifiesto (§3)
        disk_files = read_tree(self.tree()) if os.path.isdir(self.tree()) else []
        disk = {rel: (h, mode) for rel, h, mode, _ in disk_files}
        rec = {rel: (v[0], int(v[1], 8)) for rel, v in doc["files"].items()}
        p["modified"] = sorted(r for r in rec if r in disk and disk[r] != rec[r])
        p["missing"] = sorted(r for r in rec if r not in disk)
        p["foreign"] = sorted(r for r in disk if r not in rec and r != I.MARKER)
        p["diskSha"] = {r: disk[r][0] for r in p["modified"]}
        if p["to"]["build"] == p["from"]["build"] and not (p["modified"] or p["missing"] or p["foreign"]):
            p["same"] = True
            return p
        if self.man.converted_from:
            p["notes"].append("the install record is format %d; it becomes format %d with this update (noted in it)" % (
                self.man.converted_from, I.FORMAT_VERSION))
        sv = semver_module()
        a, b = sv.parse(p["from"]["version"]), sv.parse(p["to"]["version"])
        if not b:
            p["refuse"].append("the new version.json has no valid version (SemVer 2.0.0: MAJOR.MINOR.PATCH[-PRERELEASE])")
        elif a and sv.compare(b, a) < 0 and not self.args.downgrade:
            p["refuse"].append("%s is older than the installed %s: pass --downgrade to go back to it" % (
                p["to"]["version"], p["from"]["version"]))
        mu = sv.parse(p["to"].get("minUpdateFrom") or "")
        if not mu:
            p["refuse"].append("the new version.json doesn't say which versions it can update from (minUpdateFrom)")
        elif a and sv.compare(a, mu) < 0:
            p["refuse"].append("%s can only update from %s or later (installed: %s): update to an intermediate release "
                               "first" % (p["to"]["version"], p["to"]["minUpdateFrom"], p["from"]["version"]))
        if p["to"]["apiVersion"] != p["from"]["apiVersion"] and str(self.args.accept_api) != str(p["to"]["apiVersion"]):
            p["refuse"].append("the public API changes from %s to %s (clients and integrations may break): pass "
                               "--accept-api %s" % (p["from"]["apiVersion"], p["to"]["apiVersion"], p["to"]["apiVersion"]))
        if p["foreign"]:
            p["refuse"].append("files in the installed tree that the installer didn't install (move them out first): " +
                               ", ".join(p["foreign"][:5]))
        if (p["modified"] or p["missing"]) and not self.args.replace_modified:
            p["refuse"].append("installed files were changed or removed (%s): restore them, or pass --replace-modified "
                               "(a copy of each is kept, and the version kept from before is exactly what you had)" %
                               ", ".join((p["modified"] + p["missing"])[:5]))
        p["refuse"] += consumer_checks(new_files, self.contract)
        newmap = {rel: (h, mode) for rel, h, mode, _ in new_files}
        p["diff"] = {"added": sorted(r for r in newmap if r not in rec), "removed": sorted(r for r in rec if r not in newmap),
                     "changed": sorted(r for r in newmap if r in rec and newmap[r][0] != rec[r][0]),
                     "mode": sorted(r for r in newmap if r in rec and newmap[r][0] == rec[r][0] and newmap[r][1] != rec[r][1])}
        units_changed = [u for u in I.UNITS if ("systemd/" + u) in p["diff"]["changed"]]
        if units_changed and doc.get("units"):
            p["refuse"].append("the new version changes the systemd units (%s): installed units aren't updated by this "
                               "release; uninstall and install" % ", ".join(units_changed))
        for kind, r in sorted((doc.get("integrations") or {}).items()):
            st = self.gs.current_status(I, self.inst, r)
            if st not in ("loaded", "reverted"):
                p["refuse"].append("the %s integration is %s: finish or revert it first" % (kind, st))
        # settings.json (§11.2)
        sj = os.path.join(self.roots.real["config"], *SETTINGS_REL)
        p["settings"] = None
        if os.path.lexists(sj):
            try:
                st, data = self.read_settings(sj)
                d = json.loads(data)
                cur = d.get("schemaVersion")
                nmig = len(d.get("migrations") or [])
            except (OSError, ValueError, I.Refused) as e:
                p["refuse"].append("%s can't be read (%s): the update can't tell what the new version would do with it"
                                   % (sj, e))
                cur, data, nmig = None, b"", 0
            p["settings"] = {"path": sj, "sha": sha(data), "schema": cur, "migrations": nmig}
            new_schema = p["to"]["settingsSchema"]
            if not isinstance(new_schema, int):
                p["refuse"].append("the new version doesn't declare its settings schema")
            elif isinstance(cur, int) and new_schema > cur and not self.args.accept_settings_migration:
                p["refuse"].append("the new version converts your settings.json (schema %s → %s) when it loads: pass "
                                   "--accept-settings-migration (a verified copy is kept; it can be put back only while the "
                                   "file stays exactly as converted)" % (cur, new_schema))
            elif isinstance(cur, int) and new_schema < cur:
                p["refuse"].append("your settings.json (schema %s) is newer than what %s understands (%s): it would run "
                                   "read only. `install.sh update --rollback` restores it if it came from a recorded "
                                   "update" % (cur, p["to"]["version"], new_schema))
        # dónde corre la shell; recarga o frío (§11.5)
        mine, other = self.instances()
        if other:
            p["refuse"].append("Sumi Shell runs from another copy (%s): `qs -c sumi` wouldn't reach the one being "
                               "updated" % ", ".join(i["path"] for i in other))
        if len(mine) > 1:
            p["refuse"].append("%d instances run from %s" % (len(mine), self.tree()))
        p["instance"] = self.snapshot(mine[0]["pid"]) if len(mine) == 1 else None
        if not doc.get("units"):
            if p["instance"]:
                p["refuse"].append("this install has no service manager: stop the shell while unlocked, then update "
                                   "offline; verify the new build after starting it again")
            if self.args.reload or self.args.restart:
                p["refuse"].append("--reload/--restart require a managed shell; an exec-once shell must be started "
                                   "manually after the offline update")
        cold = []
        r = p["to"].get("restart")
        if not isinstance(r, dict) or not isinstance(r.get("required"), bool):
            cold.append("the new version doesn't declare whether a reload is enough")
        elif r["required"]:
            cold.append("the new version requires a cold start (%s)" % (r.get("why") or "declared"))
        newc = inline_components(new_files) - inline_components(disk_files)
        if newc:
            cold.append("new inline components (%s) don't load on a reload (measured)" % ", ".join(
                "%s in %s" % (n, f) for f, n in sorted(newc)[:3]))
        if qmldirs(new_files) != qmldirs(disk_files):
            cold.append("the QML module definitions (qmldir) change")
        if p["instance"]:
            rb = p["instance"].get("build")
            if not rb or rb != p["from"]["build"]:
                cold.append("the running build (%s) isn't known to be the installed one (%s)" % (
                    short(rb), short(p["from"]["build"])))
            if p["modified"] or p["missing"]:
                cold.append("installed files were changed: what runs may not be what's on disk")
        p["cold"] = cold
        if p["instance"]:
            ph = self.lock_phase(p["instance"]["pid"])
            if ph != "unlocked":
                p["refuse"].append("the session is %s: update only with the session unlocked" % (
                    ph or "in an unknown lock state"))
            if self.args.reload and self.args.restart:
                p["refuse"].append("--reload and --restart are exclusive")
            if cold and self.args.reload:
                p["refuse"].append("a reload can't be shown to be enough (%s): use --restart" % "; ".join(cold))
            elif cold and not self.args.restart:
                p["need"].append("--restart (%s)" % "; ".join(cold))
            elif not (self.args.reload or self.args.restart):
                p["need"].append("--reload (it looks enough) or --restart")
            if self.args.restart:
                p["refuse"] += self.restart_budget(p["instance"])
        # la generación anterior va al estado del instalador: mismo sistema de archivos que el árbol (rename atómico)
        try:
            if os.stat(os.path.dirname(self.tree())).st_dev != os.stat(self.roots.real["state"]).st_dev:
                p["refuse"].append("the shell's tree and the installer's state are on different filesystems: the version "
                                   "from before can't be kept atomically")
        except OSError:
            pass
        return p

    def restart_budget(self, inst):
        """§11.5: la política EFECTIVA de la unidad leída con systemctl show (P1), no una suposición."""
        u = self.unit()
        probs = []
        want = os.path.join(self.roots.real["config"], *I.UNITS_REL, I.UNITS[0])
        if u.get("LoadState") != "loaded" or u.get("ActiveState") != "active":
            return ["--restart needs sumi-shell.service running the shell (it is %s)" % (
                u.get("ActiveState") or "unreachable")]
        if str(inst["pid"]) != u.get("MainPID"):
            return ["the shell (pid %s) doesn't run under sumi-shell.service (main pid %s): restart it yourself" % (
                inst["pid"], u.get("MainPID"))]
        if os.path.realpath(u.get("FragmentPath", "")) != want:
            probs.append("sumi-shell.service comes from %s, not the installed unit" % u.get("FragmentPath"))
        if not u.get("rescueLoaded"):
            probs.append("--restart needs sumi-lock-rescue.service loaded (the lock's safety net while the shell "
                         "restarts)")
        if (u.get("Restart") or "no") == "no":
            probs.append("the unit doesn't restart on failure: a failed start would leave no shell")
        try:
            burst = int(u.get("StartLimitBurst") or 0)
        except ValueError:
            burst = 0
        interval = parse_usec(u.get("StartLimitIntervalUSec"))
        if burst and burst < 4:
            probs.append("the unit allows %d starts per %s: a failed start and the way back may not fit" % (
                burst, u.get("StartLimitIntervalUSec")))
        try:
            since = time.clock_gettime(time.CLOCK_MONOTONIC) - int(u.get("ActiveEnterTimestampMonotonic") or 0) / 1e6
        except ValueError:
            since = 0
        if burst and interval and since < interval:
            probs.append("the shell started %d s ago and its start limit counts %d s: try again in %d s" % (
                since, interval, interval - since + 1))
        return probs

    # -- vista previa --
    def need_install(self):
        doc = self.man.load()
        if doc is None or doc.get("status") != "installed":
            raise I.Refused(["Sumi Shell isn't installed by this installer here (or the install isn't complete)"])
        if doc.get("transaction"):
            raise I.pending_refusal(doc["transaction"])
        return doc

    def preview(self):
        doc = self.need_install()
        st = (doc.get("update") or {}).get("state")
        if st in BLOCKING:
            self.say("A previous update is %s: %s" % (st, self.hint(st)))
        p = self.plan(doc)
        if p.get("same"):
            self.say("Already up to date: build %s (%s) is installed." % (short(p["to"]["build"]), p["to"]["version"]))
            return I.EXIT_OK
        self.say("Update %s → %s (build %s → %s)" % (p["from"]["version"], p["to"]["version"], short(p["from"]["build"]),
                                                     short(p["to"]["build"])))
        d = p["diff"]
        self.say("  files: %d added, %d removed, %d changed, %d mode changes" % (
            len(d["added"]), len(d["removed"]), len(d["changed"]), len(d["mode"])))
        if p["instance"]:
            self.say("  running: %s build %s (pid %s)" % (p["instance"]["version"], short(p["instance"]["build"]),
                                                          p["instance"]["pid"]))
            self.say("  load: " + ("cold start needed: " + "; ".join(p["cold"]) if p["cold"] else
                                   "a reload looks enough (none of the cold-start conditions holds)"))
        else:
            self.say("  load: the shell isn't running from %s; the new version is checked the next time it runs "
                     "(state installed-unverified)" % self.tree())
        if p["settings"]:
            self.say("  settings.json: schema %s; the new version uses %s" % (p["settings"]["schema"],
                                                                             p["to"]["settingsSchema"]))
        for n in p["notes"]:
            self.say("  note: " + n)
        mig = I.load_module("sumi_migrations", os.path.join("packaging", "migrations.py"))
        for m in mig.listing(I, self.roots):
            if m["state"] in ("pending", "partial", "conflict"):
                self.say("  migration %s is %s (an update never runs it: `install.sh migrate %s`)" % (
                    m["id"], m["state"], m["id"]))
        for r in p["refuse"]:
            self.say("  refused: " + r)
        for n in p["need"]:
            self.say("  needs: " + n)
        if st in BLOCKING:
            return I.EXIT_REFUSED
        if not (p["refuse"] or p["need"]):
            self.say("  ready: run it with --apply%s" % (
                "" if not p["instance"] else " --restart" if (p["cold"] or self.args.restart) else " --reload"))
        return I.EXIT_REFUSED if p["refuse"] or p["need"] else I.EXIT_OK

    # -- aplicar --
    def apply(self):
        doc = self.need_install()
        st = (doc.get("update") or {}).get("state")
        if st in BLOCKING:
            raise I.Refused(["a previous update is %s: %s" % (st, self.hint(st))])
        p = self.plan(doc)
        if p.get("same"):
            self.say("Already up to date: build %s (%s) is installed; nothing was changed." % (
                short(p["to"]["build"]), p["to"]["version"]))
            return I.EXIT_OK
        if p["refuse"] or p["need"]:
            raise I.Refused(p["refuse"] + ["needs " + n for n in p["need"]])
        errs, notes = static_checks(p["newFiles"])
        for n in notes:
            self.say("  ! " + n)
        if errs:
            raise I.Refused(["the new tree doesn't pass the checks made without running it: " + "; ".join(errs[:5])])
        mode = "none" if not p["instance"] else ("restart" if self.args.restart else "reload")
        self.unit_backed = mode == "restart"
        lock = I.take_lock()
        try:
            doc = self.man.load()
            if doc.get("transaction"):
                raise I.pending_refusal(doc["transaction"])
            if (doc.get("tree") or {}).get("buildId") != p["from"]["build"] or doc["files"] != p["recorded"]:
                raise I.Refused(["the installation changed while the update was being prepared: run it again"])
            return self.apply_locked(doc, p, mode)
        finally:
            os.close(lock)

    def apply_locked(self, doc, p, mode):
        tx = uuid.uuid4().hex[:12]
        prior = doc.get("update")
        doc["transaction"] = {"id": tx, "op": "update", "pid": os.getpid(), "steps": {}, "staging": ".sumi-staging-" + tx,
                              "linksBefore": None}
        doc["update"] = {"op": "update", "state": "in-progress", "tx": tx, "mode": mode, "at": now(), "why": "",
                         "from": p["from"], "to": {k: p["to"][k] for k in ("version", "apiVersion", "build")},
                         "settingsSchema": p["to"]["settingsSchema"], "inPlace": "old",
                         "instance": p["instance"], "running": (prior or {}).get("running") or p["instance"],
                         "oldFiles": dict(doc["files"]), "newFiles": {rel: [h, oct(m)] for rel, h, m, _ in p["newFiles"]},
                         "modified": p["diskSha"], "missing": p["missing"], "copies": [], "settings": None,
                         "previousUpdate": prior}
        self.man.save(doc)
        self.say("Updating %s → %s (build %s)" % (p["from"]["version"], p["to"]["version"], short(p["to"]["build"])))
        try:
            try:
                if p["modified"]:
                    self.step(doc, "copies", lambda: self.copy_modified(doc, p["modified"]))
                self.step(doc, "stage", lambda: self.stage(doc, p["newFiles"]))
                if p["settings"]:
                    self.step(doc, "settings-pre", lambda: self.settings_pre(doc, p["settings"]))
                if mode != "none":
                    self.step(doc, "inhibit", self.inhibit)
                    ph = self.lock_phase(p["instance"]["pid"])
                    if ph != "unlocked":
                        raise I.Refused(["the session got %s before swapping" % (ph or "into an unknown lock state")])
            except I.Refused as e:
                return self.abandon(doc, prior, "; ".join(e.reasons))
            self.step(doc, "exchange", lambda: self.exchange(doc))
            if mode == "none":
                self.step(doc, "keep", lambda: self.keep_previous(doc))
                return self.commit(doc, "installed-unverified", "the shell isn't running: the new version is checked the "
                                   "next time it runs (`install.sh update --verify`)")
            ph = self.lock_phase(p["instance"]["pid"])
            if ph != "unlocked":
                return self.commit(doc, "swapped-not-loaded", "the session got %s during the update: the new files are "
                                   "in place, the running shell is still the version from before. Once unlocked, finish "
                                   "with `install.sh update --finish --%s` or undo with `install.sh update --rollback "
                                   "--%s`" % (ph or "into an unknown lock state", mode, mode), ok=False)
            return self.load_and_verify(doc, mode)
        except I.Interrupted as e:
            self.say("Interrupted (%s): run `install.sh recover`." % e)
            return I.EXIT_PENDING
        finally:
            self.release_inhibit()

    def abandon(self, doc, prior, why):
        """Antes del intercambio: el staging se retira por sha y el registro de actualización vuelve a ser el de antes."""
        kept = self.remove_staging(doc, doc["transaction"]["staging"], doc["update"]["newFiles"])
        doc["transaction"] = None
        doc["update"] = prior
        doc.setdefault("history", []).append({"op": "update", "at": now(), "result": "refused", "why": why})
        self.man.save(doc)
        self.say("Stopped before swapping anything: %s%s" % (why, ("; left in the staging tree: " + ", ".join(kept))
                                                              if kept else ""))
        return I.EXIT_REFUSED

    def step(self, doc, name, fn):
        I.checkpoint()
        doc["transaction"]["steps"][name] = "intent"
        self.man.save(doc)
        I.fault(name, "before")
        r = fn()
        I.fault(name, "after")
        doc["transaction"]["steps"][name] = "done"
        self.man.save(doc)
        I.checkpoint()
        return r

    def load_and_verify(self, doc, mode):
        u = doc["update"]
        before = u["instance"]
        expect = dict(u["to"])
        self.unit_backed = mode == "restart"
        self.watch_settings = u.get("settings")
        if mode == "reload":
            mark = len(qs_log(before["pid"]) or [])
            if not self.step(doc, "load", lambda: request_reload(before["pid"], self.require_unlocked)):
                return self.commit(doc, "swapped-not-loaded", "the running shell didn't accept the reload: the new files "
                                   "are in place, the running shell is still the version from before. `install.sh update "
                                   "--finish --reload|--restart` or `install.sh update --rollback --reload|--restart`",
                                   ok=False)
            snap, probs = self.verify(expect, "reload", before, mark)
        else:
            self.require_unlocked()
            n0 = int(self.unit().get("NRestarts") or 0)
            t0 = time.time()
            self.step(doc, "load", lambda: I.systemctl("restart", I.UNITS[0], timeout=90))
            snap, probs = self.verify(expect, "restart", before, 0, t0, wait=30, nrestarts=n0)
        if probs:
            self.say("The new version didn't pass the checks: " + "; ".join(probs[:3]))
            return self.roll_back_now(doc, mode, "the new version didn't pass the checks (%s)" % "; ".join(probs[:2]))
        u["running"] = snap
        self.settings_post(doc)
        self.step(doc, "keep", lambda: self.keep_previous(doc))
        return self.commit(doc, "verified", "")

    # -- piezas de disco --
    def backups_rel(self, doc):
        return "/".join(I.INSTALL_REL + ("backups", doc["update"]["tx"]))

    def copy_modified(self, doc, rels):
        """--replace-modified: una copia de cada archivo cambiado (con su sha) en backups/<tx>/. El original sigue en el árbol y
        viaja con él a la generación anterior: volver atrás devuelve exactamente lo que había."""
        bfd = self.gs.backups_dir(self.roots, doc["update"]["tx"], doc["createdDirs"])
        tfd = self.roots.chain("config", I.TREE_REL, ident=doc["roots"]["config"])
        try:
            for rel in rels:
                d = os.path.dirname(rel)
                dfd = self.inst.roots_open_rel(tfd, d) if d else os.dup(tfd)
                try:
                    st, data = self.gs.read_regular(dfd, os.path.basename(rel))
                finally:
                    os.close(dfd)
                name = "modified." + rel.replace("/", "__")
                if not I.lexists(bfd, name):
                    I.write_new(bfd, name, data, 0o600)
                doc["update"]["copies"].append({"rel": rel, "sha": sha(data), "kept": self.backups_rel(doc) + "/" + name})
        finally:
            os.close(tfd)
            os.close(bfd)
        self.say("  your changes are kept (copies in %s): %s" % (self.backups_rel(doc), ", ".join(rels)))

    def stage(self, doc, files):
        marker = json.dumps({"format": "sumi-install-marker", "id": doc["id"]}).encode() + b"\n"
        if sha(marker) != doc["markerSha256"]:
            raise I.Refused(["the installed tree's marker can't be reproduced from the record: nothing was changed"])
        qfd = self.roots.chain("config", ("quickshell",), ident=doc["roots"]["config"])
        try:
            name = doc["transaction"]["staging"]
            os.mkdir(name, 0o755, dir_fd=qfd)
            sfd = I.open_dir(qfd, name)
            try:
                I.write_new(sfd, I.MARKER, marker, 0o644)
                dfds = {"": sfd}
                for d in I.all_dirs(rel for rel, *_ in files):
                    parent = dfds[os.path.dirname(d)]
                    os.mkdir(os.path.basename(d), 0o755, dir_fd=parent)
                    dfds[d] = I.open_dir(parent, os.path.basename(d))
                for rel, h, mode, data in files:
                    I.write_new(dfds[os.path.dirname(rel)], os.path.basename(rel), data, mode)
                    I.checkpoint()
                for d, f in dfds.items():
                    if d:
                        os.close(f)
                os.fsync(sfd)
                staging_ino = os.fstat(sfd).st_ino
            finally:
                os.close(sfd)
            tree_ino = os.stat(I.TREE_REL[1], dir_fd=qfd, follow_symlinks=False).st_ino
        finally:
            os.close(qfd)
        doc["update"]["inodes"] = {"tree": tree_ino, "staging": staging_ino}

    def swap(self, doc, expect_in_place):
        """RENAME_EXCHANGE de quickshell/sumi y el staging, comprobando antes QUÉ está en su sitio (por inodo)."""
        qfd = self.roots.chain("config", ("quickshell",), ident=doc["roots"]["config"])
        try:
            ino = doc["update"]["inodes"]
            here = os.stat(I.TREE_REL[1], dir_fd=qfd, follow_symlinks=False).st_ino
            if here != ino[expect_in_place]:
                raise I.Refused(["the tree in place isn't the one expected (inode %d, not %d): nothing was swapped" % (
                    here, ino[expect_in_place])])
            self.gs.exchange(qfd, doc["transaction"]["staging"], I.TREE_REL[1])
            os.fsync(qfd)
        finally:
            os.close(qfd)

    def describe_disk(self, doc, files, tree):
        doc["files"] = dict(files)
        doc["dirs"] = I.all_dirs(doc["files"])
        doc["tree"] = {"version": tree["version"], "apiVersion": tree["apiVersion"], "buildId": tree["build"]}
        doc["source"] = {"version": tree["version"], "apiVersion": tree["apiVersion"]}

    def exchange(self, doc):
        u = doc["update"]
        self.swap(doc, "tree")
        # el manifiesto describe lo que hay en disco en la ruta del árbol: se guarda con el «done» del paso; si se corta
        # entre el intercambio y ese guardado, `recover` lo corrige por los inodos
        self.describe_disk(doc, u["newFiles"], u["to"])
        u["inPlace"] = "new"

    def exchange_back(self, doc):
        u = doc["update"]
        self.swap(doc, "staging")
        self.describe_disk(doc, u["oldFiles"], u["from"])
        u["inPlace"] = "old"

    def remove_staging(self, doc, name, files):
        """Retira quickshell/<name> SÓLO por sha (remove_tree de F6d: lo cambiado se queda y se dice)."""
        qfd = self.roots.chain("config", ("quickshell",), ident=doc["roots"]["config"])
        try:
            if not I.lexists(qfd, name):
                return []
            tmp = dict(doc, files=dict(files), dirs=I.all_dirs(files))
            return self.inst.remove_tree(qfd, name, tmp)
        finally:
            os.close(qfd)

    def keep_previous(self, doc):
        """El árbol anterior (ahora en el staging) pasa a previous/<versión>-<build>. La generación de antes se retira por sha
        sólo ahora, tras verificar la nueva o sin instancia que verificar (D-F5: nunca mientras algo la necesite)."""
        u = doc["update"]
        keeping = u.get("keeping")
        if keeping is None:
            old = doc.get("previous")
            label = "%s-%s" % (u["from"]["version"], short(u["from"]["build"]))
            if old and old.get("name") == label:
                label += "-" + u["tx"][:6]
            files = {rel: v for rel, v in u["oldFiles"].items() if rel not in u["missing"]}
            for rel, h in u["modified"].items():
                files[rel] = [h, u["oldFiles"][rel][1]]
            previous = {"version": u["from"]["version"], "apiVersion": u["from"]["apiVersion"],
                        "build": u["from"]["build"], "name": label,
                        "rel": "/".join(I.INSTALL_REL + ("previous", label)), "files": files,
                        "owned": dict(u["oldFiles"]), "fromUpdate": u["tx"]}
            keeping = u["keeping"] = {"previous": previous, "retired": old, "inode": u["inodes"]["tree"]}
            # Destino e identidad durables ANTES de mover; recover no infiere propiedad por el nombre.
            self.man.save(doc)
        previous, old = keeping["previous"], keeping["retired"]
        label = previous["name"]
        qfd = self.roots.chain("config", ("quickshell",), ident=doc["roots"]["config"])
        try:
            pfd = self.roots.chain("state", I.INSTALL_REL + ("previous",), create=True, created=doc["createdDirs"])
            try:
                staging = doc["transaction"]["staging"]
                if I.lexists(qfd, staging):
                    st = os.stat(staging, dir_fd=qfd, follow_symlinks=False)
                    if not stat.S_ISDIR(st.st_mode) or st.st_ino != keeping["inode"]:
                        raise I.Refused(["the earlier tree's identity changed: nothing was moved"])
                    I.fault("keep-move", "before")
                    I.rename_noreplace(qfd, staging, pfd, label)
                    os.fsync(qfd)
                    os.fsync(pfd)
                    I.fault("keep-move", "after")
                st = os.stat(label, dir_fd=pfd, follow_symlinks=False)
                if not stat.S_ISDIR(st.st_mode) or st.st_ino != keeping["inode"]:
                    raise I.Refused(["the kept tree's identity changed: nothing was removed"])
                os.fsync(pfd)
            finally:
                os.close(pfd)
        finally:
            os.close(qfd)
        # lo que hay en la generación anterior (lo cambiado, tal cual) y qué era del instalador (`owned`)
        doc["previous"] = previous
        self.man.save(doc)
        if old:
            kept = self.remove_previous(doc, old)
            if kept:
                self.say("  the version kept from before (%s) had changed files; these stay: %s" % (
                    old["version"], ", ".join(kept)))
                doc.setdefault("kept", []).extend("%s/%s" % (old["rel"], k) for k in kept)

    def remove_previous(self, doc, prev):
        """Retira una generación conservada por sha; sólo lo que era del instalador y sigue igual."""
        try:
            pfd = self.roots.chain("state", I.INSTALL_REL + ("previous",))
        except FileNotFoundError:
            return []
        try:
            if not I.lexists(pfd, prev["name"]):
                return []
            owned = {rel: v for rel, v in prev.get("owned", prev["files"]).items() if prev["files"].get(rel) == v}
            tmp = dict(doc, files=owned, dirs=I.all_dirs(prev["files"]))
            kept = self.inst.remove_tree(pfd, prev["name"], tmp)
            return kept + sorted(r for r in prev["files"] if r not in owned)
        finally:
            os.close(pfd)

    # -- settings.json (§11.2) --
    def read_settings(self, path):
        dfd = self.gs.open_parent(path, self.roots)
        try:
            return self.gs.read_regular(dfd, os.path.basename(path))
        finally:
            os.close(dfd)

    def settings_pre(self, doc, s):
        """Copia propia verificada (0600) ANTES de cargar nada; el sha de antes queda en el manifiesto."""
        st, data = self.read_settings(s["path"])
        if sha(data) != s["sha"]:
            raise I.Refused(["settings.json changed while the update was starting: run it again"])
        bfd = self.gs.backups_dir(self.roots, doc["update"]["tx"], doc["createdDirs"])
        try:
            I.write_new(bfd, "settings.json.pre", data, 0o600)
            os.fsync(bfd)
            st2, copy = self.gs.read_regular(bfd, "settings.json.pre")
        finally:
            os.close(bfd)
        if sha(copy) != s["sha"]:
            raise I.Refused(["the copy of settings.json doesn't match it: nothing was changed"])
        doc["update"]["settings"] = {"path": s["path"], "post": None, "state": "kept",
                                     "pre": {"sha": s["sha"], "schema": s["schema"], "migrations": s["migrations"],
                                             "copy": self.backups_rel(doc) + "/settings.json.pre"}}

    def settings_now(self, s):
        """(sha, esquema, ¿es la conversión de la shell?) de settings.json ahora. Conversión = esquema distinto y la PRIMERA
        migración añadida tras la copia apunta a la copia de la shell con el sha de antes (la shell copia byte a byte, S1)."""
        try:
            st, data = self.read_settings(s["path"])
            d = json.loads(data)
        except (OSError, ValueError, I.Refused):
            return None, None, False
        h = sha(data)
        schema = d.get("schemaVersion")
        added = (d.get("migrations") or [])[s["pre"]["migrations"]:]
        conv = False
        if schema != s["pre"]["schema"] and added and isinstance(added[0], dict) and added[0].get("backup"):
            try:
                with open(added[0]["backup"], "rb") as f:
                    conv = sha(f.read()) == s["pre"]["sha"]
            except OSError:
                conv = False
        return h, schema, conv

    def observe_settings(self):
        """En cuanto se VE la conversión (en cada pasada de la comprobación, antes de las demás preguntas), se fija su sha:
        es el único momento en que se puede decir «esto es lo que escribió la shell». Lo que cambie después es del usuario
        y bloquea cualquier reposición. Riesgo residual: una edición en los ~0,6 s entre la conversión y esta lectura
        cuenta como parte de ella; aun así no se pierde (al reponer, lo desplazado se guarda en las copias)."""
        s = self.watch_settings
        if not s or (s.get("post") or {}).get("observed"):
            return
        h, schema, conv = self.settings_now(s)
        if conv:
            s["post"] = {"sha": h, "schema": schema, "converted": True, "observed": now()}

    def settings_post(self, doc):
        """Tras verificar: lo observado se conserva; si no hubo conversión, se registra cómo quedó."""
        s = doc["update"].get("settings")
        if not s:
            return
        self.watch_settings = s
        self.observe_settings()
        h, schema, conv = self.settings_now(s)
        if (s.get("post") or {}).get("observed"):
            s["post"]["atVerify"] = h
            s["state"] = "converted" if h == s["post"]["sha"] else "converted, then changed"
            return
        s["post"] = {"sha": h, "schema": schema, "converted": conv}
        s["state"] = "converted" if conv else ("unchanged" if h == s["pre"]["sha"] else "changed")

    def settings_decide(self, s):
        """Antes de volver a un código anterior: 'none' (nada que reponer), 'restore' (es la conversión, tal cual se
        comprobó) o el motivo del conflicto (cambió después de convertir, o de una forma que no es la conversión)."""
        if not s:
            return "none"
        h, schema, conv = self.settings_now(s)
        if h is None:
            return "settings.json is missing or unreadable now"
        if h == s["pre"]["sha"]:
            return "none"
        post = (s.get("post") or {}).get("sha")
        if conv and post == h:
            return "restore"
        if conv and post is None:
            return ("settings.json was converted but the converted file was never seen unchanged, so it can't be shown "
                    "that nothing else changed in it")
        if conv:
            return "settings.json was changed after the new version converted it"
        if schema == s["pre"]["schema"]:
            return "none"                    # mismo esquema: la versión de antes lo entiende; los cambios son del usuario
        return "settings.json changed in a way that isn't the shell's own conversion"

    def settings_restore(self, doc, s):
        """Repone la copia de antes SÓLO si settings.json sigue siendo exactamente el que se comprobó (inodo y sha, con
        RENAME_EXCHANGE); lo desplazado se conserva en las copias. '' o el motivo por el que no se tocó."""
        cp = os.path.join(self.roots.real["state"], s["pre"]["copy"])
        try:
            with open(cp, "rb") as f:
                pre = f.read()
        except OSError:
            return "the kept copy of settings.json is missing"
        if sha(pre) != s["pre"]["sha"]:
            return "the kept copy of settings.json was changed: it can't be trusted"
        h, schema, conv = self.settings_now(s)
        post = (s.get("post") or {}).get("sha")
        if not conv or post != h:
            return "settings.json is no longer exactly the converted file: it was left as it is"
        st, data = self.read_settings(s["path"])
        if sha(data) != h:
            return "settings.json changed while it was being checked: it was left as it is"
        r, info = self.gs.replace_file(s["path"], self.roots, st.st_ino, h, pre, doc["update"]["tx"],
                                       "settings.json.converted", doc["createdDirs"])
        if r == "done":
            s["state"] = "restored"
            s["displaced"] = info
            return ""
        if r == "conflict":
            s["conflict"] = info
        return "settings.json changed while it was being restored (%s): both versions were left where they are" % r

    # -- vuelta atrás inmediata (la verificación falló) --
    def roll_back_now(self, doc, mode, why):
        self.require_unlocked()
        u = doc["update"]
        s = u.get("settings")
        # la comprobación pudo fallar antes de ver la conversión (la shell copia y escribe un instante después de cargar)
        self.watch_settings = s
        self.observe_settings()
        dec = self.settings_decide(s)
        if dec not in ("none", "restore"):
            # no se repone nada y no se vuelve a un código que no entiende lo que hay: se conserva y se pide decidir
            return self.commit(doc, "settings-conflict", why + "; " + dec + ". The new files stay and nothing was "
                               "restored: keep your settings and `install.sh update --finish --%s`, or put back %s "
                               "yourself and `install.sh update --rollback --%s`" % (mode, s["pre"]["copy"], mode),
                               ok=False)
        if u["inPlace"] != "old":
            self.step(doc, "exchange-back", lambda: self.exchange_back(doc))
        snap, probs = self.load_old(doc, mode, u["instance"], u["from"], dec, s)
        kept = self.remove_staging(doc, doc["transaction"]["staging"], u["newFiles"])
        if kept:
            doc.setdefault("kept", []).extend("quickshell/%s/%s" % (doc["transaction"]["staging"], k) for k in kept)
        if probs and probs[0].startswith("settings:"):
            return self.commit(doc, "settings-conflict", why + "; the version from before is back on disk, but " +
                               probs[0][9:], ok=False)
        if probs:
            return self.commit(doc, "broken", why + "; the version from before is back on disk but doesn't pass the checks "
                               "either (%s). Nothing else was done: see `qs log -c sumi`" % "; ".join(probs[:2]),
                               ok=False)
        u["running"] = snap
        return self.commit(doc, "rolled-back", why + "; the version from before is back and checked" + (
            " (settings.json restored from its verified copy)" if dec == "restore" else ""), ok=False)

    def load_old(self, doc, mode, before, tree, dec, s):
        """Carga el árbol que ya está en su sitio, repone settings.json si toca (DESPUÉS de cargar: con el código nuevo
        corriendo, lo volvería a convertir) y comprueba. (instantánea, problemas)."""
        expect = {k: tree[k] for k in ("version", "apiVersion", "build")}
        if mode == "reload":
            mine, other = self.instances()
            pid = mine[0]["pid"] if len(mine) == 1 else before["pid"]
            vbefore = before if pid == before["pid"] else self.snapshot(pid)
            mark = len(qs_log(pid) or [])
            if not self.step(doc, "load-back", lambda: request_reload(pid, self.require_unlocked)):
                return None, ["the running shell didn't accept the reload back"]
            vmode = "reload"
        else:
            self.unit_backed = True
            self.step(doc, "load-back", self.restart_back)
            vmode, vbefore, mark = "cold", None, 0
        if dec == "restore":
            # el código de antes ya está cargando: se espera a que esté en pie (en sólo lectura con el esquema nuevo)
            if not self.wait_loaded(expect, vmode, vbefore, mark):
                raise I.Refused(["the earlier code hasn't been confirmed loaded; settings.json was left unchanged; "
                                 "the transaction stays pending for `install.sh recover --apply --reload|--restart`"])
            self.require_unlocked()
            err = self.settings_restore(doc, s)
            if err:
                return None, ["settings:" + err]
        return self.verify(expect, vmode, vbefore, mark, wait=40)

    def wait_loaded(self, expect, mode, before, mark, wait=25):
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline:
            try:
                snap, probs = self.check_once(expect, mode, before, mark, None, None)
            except Failed:
                return False
            if snap:
                return True
            time.sleep(0.6)
        return False

    def restart_back(self):
        """Con --restart: el árbol de antes ya está en su sitio. Si systemd está reintentando (la carga nueva falló), su
        próximo intento lo coge; si la nueva corre (cargó pero no pasó), se reinicia otra vez; si la unidad agotó su
        límite, reset-failed y start. Todo es parte del reinicio que se pidió."""
        self.require_unlocked()
        u = self.unit()
        state = u.get("ActiveState")
        if state == "failed":
            I.systemctl("reset-failed", I.UNITS[0])
            I.systemctl("start", I.UNITS[0], timeout=90)
        elif state == "active" and u.get("SubState") == "running":
            I.systemctl("restart", I.UNITS[0], timeout=90)
        elif state == "inactive":
            I.systemctl("start", I.UNITS[0], timeout=90)

    # -- registro --
    def commit(self, doc, state, why, ok=True):
        u = doc["update"]
        u["state"] = state
        u["why"] = why
        u["at"] = now()
        doc["transaction"] = None
        doc.setdefault("history", []).append({"op": u.get("op", "update"), "at": u["at"], "result": state,
                                              "from": u["from"]["version"], "to": u["to"]["version"],
                                              "buildFrom": u["from"]["build"], "buildTo": u["to"]["build"]})
        self.man.save(doc)
        if state == "verified":
            self.say("Updated: %s build %s is on disk and running, checked." % (u["to"]["version"], short(u["to"]["build"])))
        else:
            self.say("%s: %s" % (state, why))
        return I.EXIT_OK if ok else I.EXIT_REFUSED

    def hint(self, st):
        return {"swapped-not-loaded": "finish it with `install.sh update --finish --reload|--restart` or undo it with "
                                      "`install.sh update --rollback --reload|--restart`",
                "installed-unverified": "check it with `install.sh update --verify` once the shell runs, or undo it with "
                                        "`install.sh update --rollback`",
                "verify-failed": "`install.sh update --rollback`",
                "settings-conflict": "see `install.sh status`: settings.json needs your decision first",
                "broken": "see `install.sh status` and `qs log -c sumi`"}.get(st, "see `install.sh status`")

    # -- inhibición (§11.4, complementaria) --
    def inhibit(self):
        pids = self.lc.processes("hypridle") or []
        if not pids:
            self.say("  no hypridle running: nothing to inhibit")
            return
        if len(pids) > 1:
            # varios (otra sesión, un banco): elegir uno sería inhibir quizá el de otra sesión
            self.say("  ! %d hypridle processes run (%s): idle isn't inhibited (it's a complement)" % (
                len(pids), ", ".join(map(str, pids))))
            return
        addr = self.lc.proc_env(pids[0]).get("DBUS_SESSION_BUS_ADDRESS")
        if not addr:
            self.say("  ! hypridle's session bus can't be read: idle isn't inhibited during the update")
            return
        try:
            p = subprocess.Popen([sys.executable, "-I", os.path.abspath(__file__), "--hold-inhibit", addr, str(pids[0])],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                 start_new_session=True)
        except OSError as e:
            self.say("  ! idle couldn't be inhibited (%s); it's a complement, continuing" % e)
            return
        line = p.stdout.readline().strip()
        if not line.startswith("ok "):
            p.kill()
            p.wait()
            self.say("  ! idle couldn't be inhibited (%s); it's a complement, continuing" % (
                line or p.stderr.read().strip()[-160:] or "no answer"))
            return
        self.inhibitor = p
        self.say("  idle inhibited during the update (hypridle pid %s, cookie %s)" % (pids[0], line[3:]))

    def release_inhibit(self):
        if self.inhibitor and self.inhibitor.poll() is None:
            self.inhibitor.terminate()
            try:
                self.inhibitor.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.inhibitor.kill()
                self.inhibitor.wait()
        self.inhibitor = None

    # -- terminar, verificar, volver atrás --
    def one_instance(self):
        mine, other = self.instances()
        if other:
            raise I.Refused(["Sumi Shell runs from another copy (%s)" % ", ".join(i["path"] for i in other)])
        if len(mine) > 1:
            raise I.Refused(["%d instances run from %s" % (len(mine), self.tree())])
        return mine[0] if mine else None

    def mode_for(self, inst, what):
        if not inst:
            return "none"
        if self.args.reload and self.args.restart:
            raise I.Refused(["--reload and --restart are exclusive"])
        mode = "restart" if self.args.restart else ("reload" if self.args.reload else None)
        if not mode:
            raise I.Refused(["the shell is running: %s needs --reload or --restart" % what])
        if self.lock_phase(inst["pid"]) != "unlocked":
            raise I.Refused(["the session isn't unlocked"])
        if mode == "restart":
            b = self.restart_budget(inst)
            if b:
                raise I.Refused(b)
        return mode

    def finish(self):
        doc = self.need_install()
        u = doc.get("update") or {}
        if u.get("state") not in ("swapped-not-loaded", "settings-conflict") or u.get("inPlace") != "new":
            raise I.Refused(["there's no update waiting to be finished (state: %s)" % u.get("state")])
        inst = self.one_instance()
        if not inst:
            raise I.Refused(["the shell isn't running from %s: start it, then `install.sh update --verify`" % self.tree()])
        if self.snapshot(inst["pid"]).get("build") == u["to"]["build"] and u["to"]["build"]:
            # la shell ya arrancó con la versión nueva (p. ej. tras reiniciar la sesión): sólo se comprueba
            if self.lock_phase(inst["pid"]) != "unlocked":
                raise I.Refused(["the session isn't unlocked"])
            lock = I.take_lock()
            try:
                doc = self.man.load()
                u = doc["update"]
                doc["transaction"] = {"id": uuid.uuid4().hex[:12], "op": "update", "pid": os.getpid(), "steps": {},
                                      "staging": ".sumi-staging-" + u["tx"], "linksBefore": None}
                self.man.save(doc)
                self.watch_settings = u.get("settings")
                snap, probs = self.verify(dict(u["to"]), "cold", None, 0, wait=15)
                if probs:
                    doc["transaction"] = None
                    self.man.save(doc)
                    raise I.Refused(["the new version is already running but doesn't pass the checks (%s): "
                                     "`install.sh update --rollback --reload|--restart`" % "; ".join(probs[:2])])
                u["running"] = snap
                self.settings_post(doc)
                self.step(doc, "keep", lambda: self.keep_previous(doc))
                return self.commit(doc, "verified", "")
            finally:
                os.close(lock)
        mode = self.mode_for(inst, "--finish")
        if mode == "reload":
            cold = self.cold_for_finish(doc, inst)
            if cold:
                raise I.Refused(["a reload can't be shown to be enough (%s): use --restart" % "; ".join(cold)])
        lock = I.take_lock()
        try:
            doc = self.man.load()
            u = doc["update"]
            u["instance"] = self.snapshot(inst["pid"])
            doc["transaction"] = {"id": uuid.uuid4().hex[:12], "op": "update", "pid": os.getpid(), "steps": {},
                                  "staging": ".sumi-staging-" + u["tx"], "linksBefore": None}
            self.man.save(doc)
            self.inhibit()
            try:
                return self.load_and_verify(doc, mode)
            finally:
                self.release_inhibit()
        finally:
            os.close(lock)

    def cold_for_finish(self, doc, inst):
        u = doc["update"]
        cold = []
        snap = self.snapshot(inst["pid"])
        if not snap.get("build") or snap["build"] != u["from"]["build"]:
            cold.append("the running build isn't known to be the one from before")
        old = read_tree(os.path.join(self.roots.real["config"], "quickshell", ".sumi-staging-" + u["tx"]))
        new = read_tree(self.tree())
        if inline_components(new) - inline_components(old):
            cold.append("new inline components")
        if qmldirs(new) != qmldirs(old):
            cold.append("qmldir changes")
        try:
            with open(os.path.join(self.tree(), "version.json")) as f:
                r = json.load(f).get("restart") or {}
        except (OSError, ValueError):
            r = {}
        if r.get("required") is not False:
            cold.append("the version doesn't say a reload is enough")
        return cold

    def verify_cmd(self):
        doc = self.need_install()
        u = doc.get("update") or {}
        t = doc.get("tree") or {}
        inst = self.one_instance()
        if not inst:
            self.say("The shell isn't running from %s: nothing to check yet." % self.tree())
            return I.EXIT_REFUSED
        expect = {"version": t.get("version"), "apiVersion": t.get("apiVersion"), "build": t.get("buildId")}
        snap, probs = self.verify(expect, "cold", None, 0, wait=15)
        if probs:
            self.say("The running shell doesn't match what's installed: " + "; ".join(probs[:4]))
        else:
            self.say("The running shell is the installed build %s (%s), checked." % (short(t.get("buildId")),
                                                                                     t.get("version")))
        if u.get("state") in ("installed-unverified", "verify-failed", "verified", "rolled-back"):
            lock = I.take_lock()
            try:
                doc = self.man.load()
                v = doc["update"]
                if probs:
                    if v["state"] == "installed-unverified":
                        v["state"], v["why"] = "verify-failed", "; ".join(probs[:3]) + " — `install.sh update --rollback`"
                else:
                    if v["state"] in ("installed-unverified", "verify-failed"):
                        v["state"], v["why"] = "verified", ""
                        self.settings_post(doc)
                    v["running"] = snap
                doc.setdefault("history", []).append({"op": "verify", "at": now(), "result": "ok" if not probs else
                                                      "; ".join(probs[:2])})
                self.man.save(doc)
            finally:
                os.close(lock)
        return I.EXIT_OK if not probs else I.EXIT_REFUSED

    def rollback(self):
        """Explícito: la generación anterior (comprobada por sha) vuelve a su sitio; settings.json sólo por evidencia."""
        doc = self.need_install()
        u = doc.get("update") or {}
        swapped = u.get("state") in ("swapped-not-loaded", "settings-conflict") and u.get("inPlace") == "new"
        prev = doc.get("previous")
        if not swapped and not prev:
            raise I.Refused(["no version from before is kept"])
        inst = self.one_instance()
        mode = self.mode_for(inst, "--rollback")
        # la copia de settings.json sólo vale si la generación que vuelve es la de ESA actualización
        s = u.get("settings") if (swapped or prev.get("fromUpdate") == u.get("tx")) else None
        dec = self.settings_decide(s)
        if dec not in ("none", "restore"):
            raise I.Refused([dec + ": going back would leave the version from before with settings it may not read. "
                             "Nothing was changed. Put back %s yourself if you want it, or keep this version" %
                             s["pre"]["copy"]])
        lock = I.take_lock()
        try:
            doc = self.man.load()
            u = doc["update"]
            self.unit_backed = mode == "restart"
            if swapped:
                # el árbol de antes sigue en el staging de esa actualización
                staging = ".sumi-staging-" + u["tx"]
                rb = dict(u, op="rollback", state="in-progress", oldFiles=u["newFiles"], newFiles=u["oldFiles"],
                          modified={}, missing=[], inPlace="old", undoes=u["tx"])
                rb["from"], rb["to"] = u["to"], u["from"]
                from_previous = False
            else:
                tx = uuid.uuid4().hex[:12]
                staging = ".sumi-staging-" + tx
                cur = doc.get("tree") or {}
                rb = {"op": "rollback", "tx": tx, "mode": mode, "at": now(), "why": "", "state": "in-progress",
                      "from": {"version": cur.get("version"), "apiVersion": cur.get("apiVersion"),
                               "build": cur.get("buildId")},
                      "to": {"version": prev["version"], "apiVersion": prev["apiVersion"], "build": prev["build"]},
                      "oldFiles": dict(doc["files"]), "newFiles": dict(prev["owned"]), "prevFiles": dict(prev["files"]),
                      "modified": {}, "missing": [], "copies": [], "settings": s, "running": u.get("running"),
                      "inPlace": "old", "undoes": u.get("tx")}
                from_previous = True
            rb["mode"] = mode
            rb["instance"] = self.snapshot(inst["pid"]) if inst else None
            doc["update"] = rb
            doc["transaction"] = {"id": rb["tx"], "op": "rollback", "pid": os.getpid(), "steps": {}, "staging": staging,
                                  "linksBefore": None, "fromPrevious": from_previous}
            self.man.save(doc)
            if from_previous:
                self.step(doc, "unkeep", lambda: self.unkeep(doc, prev, staging))
            qfd = self.roots.chain("config", ("quickshell",), ident=doc["roots"]["config"])
            try:
                rb["inodes"] = {"tree": os.stat(I.TREE_REL[1], dir_fd=qfd, follow_symlinks=False).st_ino,
                                "staging": os.stat(staging, dir_fd=qfd, follow_symlinks=False).st_ino}
            finally:
                os.close(qfd)
            self.man.save(doc)
            if mode != "none":
                self.inhibit()
            try:
                if mode != "none":
                    self.require_unlocked()
                self.step(doc, "exchange", lambda: self.exchange(doc))
                if mode == "none":
                    return self.after_rollback(doc, dec, s, None, "installed-unverified")
                snap, probs = self.load_old(doc, mode, rb["instance"], rb["to"], dec, s)
                if probs and probs[0].startswith("settings:"):
                    return self.commit(doc, "settings-conflict", "rolled back on disk, but " + probs[0][9:],
                                       ok=False)
                if probs:
                    return self.commit(doc, "broken", "rolled back on disk, but the version from before doesn't pass the "
                                       "checks: " + "; ".join(probs[:2]), ok=False)
                return self.after_rollback(doc, "none", s, snap, "rolled-back")
            finally:
                self.release_inhibit()
        finally:
            os.close(lock)

    def unkeep(self, doc, prev, staging):
        """La generación conservada vuelve al staging SÓLO si es exactamente la registrada (sha y modo de cada archivo)."""
        got = read_tree(os.path.join(self.roots.real["state"], prev["rel"]))
        disk = {rel: [h, oct(m)] for rel, h, m, _ in got if rel != I.MARKER}
        diff = sorted(r for r in set(disk) | set(prev["files"]) if disk.get(r) != prev["files"].get(r))
        if diff:
            raise I.Refused(["the version kept from before was changed (%s): it can't be shown to be the one installed "
                             "before. Nothing was changed" % ", ".join(diff[:5])])
        pfd = self.roots.chain("state", I.INSTALL_REL + ("previous",))
        try:
            qfd = self.roots.chain("config", ("quickshell",), ident=doc["roots"]["config"])
            try:
                I.rename_noreplace(pfd, prev["name"], qfd, staging)
                os.fsync(qfd)
            finally:
                os.close(qfd)
        finally:
            os.close(pfd)

    def after_rollback(self, doc, dec, s, snap, state):
        u = doc["update"]
        if dec == "restore":
            err = self.settings_restore(doc, s)
            if err:
                return self.commit(doc, "settings-conflict", "the version from before is on disk, but " + err, ok=False)
        kept = self.remove_staging(doc, doc["transaction"]["staging"], u["oldFiles"])
        if kept:
            doc.setdefault("kept", []).extend("quickshell/%s/%s" % (doc["transaction"]["staging"], k) for k in kept)
        # la generación restaurada ya no está conservada; la abandonada se ha retirado por sha (lo cambiado se queda)
        if doc["transaction"].get("fromPrevious"):
            doc["previous"] = None
            # lo que estaba cambiado por el usuario en la generación restaurada vuelve a ser suyo: `files` = lo del instalador
            doc["files"] = dict(u["newFiles"])
        if snap:
            u["running"] = snap
        why = "back to %s build %s%s%s" % (u["to"]["version"], short(u["to"]["build"]),
                                          "; settings.json restored from its verified copy" if (
                                              s and s.get("state") == "restored") else "",
                                          ("; changed files of the abandoned version stay: " + ", ".join(kept)) if kept
                                          else "")
        if state == "installed-unverified":
            why += "; the shell isn't running: `install.sh update --verify` once it runs"
        return self.commit(doc, state, why, ok=True)

    # -- recuperación (`install.sh recover`) por los inodos registrados --
    def recover(self, doc, tx, apply):
        u = doc.get("update") or {}
        qfd = self.roots.chain("config", ("quickshell",), ident=doc["roots"]["config"])
        try:
            cur = os.stat(I.TREE_REL[1], dir_fd=qfd, follow_symlinks=False).st_ino
            has_staging = I.lexists(qfd, tx["staging"])
        finally:
            os.close(qfd)
        ino = u.get("inodes") or {}
        if ino and cur not in (ino.get("tree"), ino.get("staging")):
            raise I.Refused(["the installed tree has an unrecorded identity: recovery left everything unchanged"])
        swapped = bool(ino) and cur == ino.get("staging")
        self.say("Pending %s (%s → %s): the %s tree is in place; steps: %s" % (
            tx["op"], (u.get("from") or {}).get("version"), (u.get("to") or {}).get("version"),
            "new" if swapped else "earlier", json.dumps(tx["steps"])))
        # si el intercambio ocurrió y su «done» no llegó a escribirse (o al revés), el manifiesto se corrige aquí por los
        # inodos: la verdad es el disco
        if swapped and u.get("inPlace") != "new":
            self.describe_disk(doc, u["newFiles"], u["to"])
            u["inPlace"] = "new"
        elif not swapped and u.get("inPlace") == "new" and ino and cur == ino.get("tree"):
            self.describe_disk(doc, u["oldFiles"], u["from"])
            u["inPlace"] = "old"
        if not apply:
            self.say("Recovery leaves the earlier tree in place (by its recorded inode) unless the new one is already "
                     "loaded and passes the checks; settings.json is only put back while it's exactly the converted one. "
                     "Run `install.sh recover --apply` (with --reload or --restart if the shell runs).")
            return I.EXIT_PENDING
        inst = self.one_instance()
        mode = self.mode_for(inst, "recover --apply")
        self.unit_backed = mode == "restart"
        u["instance"] = self.snapshot(inst["pid"]) if inst else None
        if swapped and tx["op"] == "update" and u.get("keeping"):
            # La verificación ya terminó (o no había instancia) cuando se pidió conservar la generación.
            # Completar ese movimiento es idempotente incluso tras morir antes de su registro final.
            self.step(doc, "keep", lambda: self.keep_previous(doc))
            if not inst:
                return self.commit(doc, "installed-unverified", "the interrupted update is on disk; "
                                   "the earlier tree is kept; run `install.sh update --verify` once the shell runs")
            snap, probs = self.verify(dict(u["to"]), "cold", wait=10)
            if probs:
                return self.commit(doc, "verify-failed", "; ".join(probs) +
                                   "; the earlier tree is kept for `install.sh update --rollback`", ok=False)
            u["running"] = snap
            self.settings_post(doc)
            return self.commit(doc, "verified", "")
        if not swapped:
            if tx["op"] == "update" and tx["steps"].get("exchange-back"):
                # Se cortó la vuelta atrás DESPUÉS del intercambio: aún falta cargar/restaurar y verificar.
                if mode != "none":
                    rc = self.roll_back_now(doc, mode, "the interrupted rollback is being resumed")
                    return I.EXIT_OK if doc["update"]["state"] == "rolled-back" else rc
                dec = self.settings_decide(u.get("settings"))
                if dec not in ("none", "restore"):
                    return self.commit(doc, "settings-conflict", dec, ok=False)
                if dec == "restore":
                    err = self.settings_restore(doc, u["settings"])
                    if err:
                        return self.commit(doc, "settings-conflict", err, ok=False)
                kept = self.remove_staging(doc, tx["staging"], u["newFiles"])
                doc.setdefault("kept", []).extend("quickshell/%s/%s" % (tx["staging"], k) for k in kept)
                return self.commit(doc, "installed-unverified", "the earlier tree and settings are back on disk; "
                                   "run `install.sh update --verify` once the shell runs")
            if has_staging and tx["op"] == "update":
                kept = self.remove_staging(doc, tx["staging"], u["newFiles"])
                if kept:
                    doc.setdefault("kept", []).extend("quickshell/%s/%s" % (tx["staging"], k) for k in kept)
                doc["update"] = u.get("previousUpdate")
                doc["transaction"] = None
                doc.setdefault("history", []).append({"op": "recover", "at": now(), "result": "update undone before "
                                                      "swapping"})
                self.man.save(doc)
                self.say("Undone: nothing had been swapped; the staging tree was removed by checksum.")
                return I.EXIT_OK
            if has_staging and tx["op"] == "rollback" and tx.get("fromPrevious"):
                # la generación conservada estaba saliendo de previous/: vuelve allí
                pfd = self.roots.chain("state", I.INSTALL_REL + ("previous",))
                try:
                    qfd = self.roots.chain("config", ("quickshell",), ident=doc["roots"]["config"])
                    try:
                        I.rename_noreplace(qfd, tx["staging"], pfd, doc["previous"]["name"])
                    finally:
                        os.close(qfd)
                finally:
                    os.close(pfd)
            # nada se intercambió: sigue en su sitio lo que había; no se afirma que corra, se pide comprobarlo
            doc["update"] = dict(u, state="installed-unverified", why="an interrupted rollback was undone before "
                                 "swapping: check the running shell with `install.sh update --verify`")
            doc["transaction"] = None
            doc.setdefault("history", []).append({"op": "recover", "at": now(), "result": "rollback undone before "
                                                  "swapping"})
            self.man.save(doc)
            self.say("Undone: nothing had been swapped; the current version stays (check it with `install.sh update "
                     "--verify`).")
            return I.EXIT_OK
        if inst and tx["op"] == "update":
            snap = u["instance"]
            if snap.get("build") and snap["build"] == u["to"]["build"]:
                # la versión nueva YA está en disco y cargada: se comprueba y, si pasa, se termina hacia delante
                ok, probs = self.verify(dict(u["to"]), "cold", None, 0, wait=10)
                if not probs:
                    u["running"] = ok
                    self.settings_post(doc)
                    self.step(doc, "keep", lambda: self.keep_previous(doc))
                    return self.commit(doc, "verified", "")
        if tx["op"] == "rollback":
            # una vuelta atrás interrumpida tras el intercambio: se termina hacia delante (la generación de antes ya está)
            if mode == "none":
                return self.after_rollback(doc, "none", u.get("settings"), None, "installed-unverified")
            dec = self.settings_decide(u.get("settings"))
            if dec not in ("none", "restore"):
                return self.commit(doc, "settings-conflict", dec, ok=False)
            snap, probs = self.load_old(doc, mode, u["instance"], u["to"], dec, u.get("settings"))
            if probs:
                return self.commit(doc, "broken", "the interrupted rollback was finished on disk, but: " +
                                   "; ".join(probs[:2]), ok=False)
            return self.after_rollback(doc, "none", u.get("settings"), snap, "rolled-back")
        if mode == "none":
            self.step(doc, "exchange-back", lambda: self.exchange_back(doc))
            kept = self.remove_staging(doc, tx["staging"], u["newFiles"])
            return self.commit(doc, "installed-unverified", "the interrupted update was undone on disk%s; the version "
                               "from before is checked the next time the shell runs (`install.sh update --verify`)" % (
                                   ("; these changed files stay: " + ", ".join(kept)) if kept else ""))
        rc = self.roll_back_now(doc, mode, "the update was interrupted")
        return I.EXIT_OK if doc["update"]["state"] == "rolled-back" else rc


def hold_inhibit(addr, hypridle_pid):
    """Proceso hijo: ScreenSaver.Inhibit en el bus de sesión de hypridle, tras comprobar que el dueño del nombre ES ese
    hypridle; imprime «ok <cookie>» y espera. Si muere, hypridle suelta la inhibición solo (U4, medido)."""
    from gi.repository import Gio, GLib
    c = Gio.DBusConnection.new_for_address_sync(addr, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT |
                                                Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
    owner = c.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner",
                        GLib.Variant("(s)", ("org.freedesktop.ScreenSaver",)), GLib.VariantType("(s)"), 0, 3000,
                        None).unpack()[0]
    pid = c.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionUnixProcessID",
                      GLib.Variant("(s)", (owner,)), GLib.VariantType("(u)"), 0, 3000, None).unpack()[0]
    if pid != int(hypridle_pid):
        print("org.freedesktop.ScreenSaver belongs to pid %d, not to hypridle (%s)" % (pid, hypridle_pid), flush=True)
        return 1
    cookie = c.call_sync(owner, "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver", "Inhibit",
                         GLib.Variant("(ss)", ("sumi-install", "updating Sumi Shell")), GLib.VariantType("(u)"), 0,
                         3000, None).unpack()[0]
    print("ok %d" % cookie, flush=True)

    def bye(*a):
        try:
            c.call_sync(owner, "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver", "UnInhibit",
                        GLib.Variant("(u)", (cookie,)), None, 0, 2000, None)
        finally:
            os._exit(0)
    signal.signal(signal.SIGTERM, bye)
    signal.signal(signal.SIGINT, bye)
    while True:
        time.sleep(3600)


def run_update(installer_module, inst):
    global I
    I = installer_module
    u = Updater(inst)
    a = inst.args
    if a.finish:
        return u.finish()
    if a.rollback:
        return u.rollback()
    if a.verify:
        return u.verify_cmd()
    return u.apply() if a.apply else u.preview()


def recover(installer_module, inst, doc, tx, apply):
    global I
    I = installer_module
    return Updater(inst).recover(doc, tx, apply)


def uninstall_problems(doc):
    """Lo que impide desinstalar con una actualización a medias (el instalador lo pregunta en su diagnóstico)."""
    u = doc.get("update") or {}
    if u.get("state") in ("swapped-not-loaded", "settings-conflict", "broken"):
        return ["an update is %s: resolve it first (`install.sh status`)" % u["state"]]
    return []


def remove_previous_for_uninstall(installer_module, inst, doc):
    global I
    I = installer_module
    prev = doc.get("previous")
    if not prev:
        return []
    return ["%s/%s" % (prev["rel"], k) for k in Updater(inst).remove_previous(doc, prev)]


if __name__ == "__main__" and len(sys.argv) == 4 and sys.argv[1] == "--hold-inhibit":
    sys.exit(hold_inhibit(sys.argv[2], sys.argv[3]) or 0)
