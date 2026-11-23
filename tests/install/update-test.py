#!/usr/bin/env python3
"""Sumi Shell — `install.sh update` y `install.sh migrate` en HOMEs temporales (portabilidad F6f, 2026-10-14).

Uso: python3 -B tests/install/update-test.py [nombre…]       (desde la raíz del repo; sin nombres, todos)

REAL en cada escenario: install.sh/installer.py/update.py/migrations.py, los árboles distribuidos (copias de sumi/ con
cambios pequeños: «A» instalado, «B» la versión nueva), qmllint --bare, bash -n, el sistema de archivos (renameat2,
RENAME_EXCHANGE, link) y, en `old-installers-refuse-format-3`, el instalador de F6e (4ed6786; 7d99a78 en dotfiles) sacado de git.
SIMULADO (con estado, en $tmp/fix): `qs` (instancias; `reload` y el arranque LEEN EL ÁRBOL DEL DISCO: versión, build.json,
verbos de core/Ipc.qml, componentes en línea —una recarga no carga uno nuevo, medido en F5e/U6—, `.kt-broken` = la carga
falla, `.kt-noshow` = carga pero le falta lockNow, `.kt-touch-settings` = el usuario edita settings.json justo después de
convertirlo; settings.json se convierte como la shell: copia byte a byte en backups/settings y `migrations[]`, también si
se repone uno más viejo con el código nuevo corriendo; uno más nuevo → «read-only»), `systemctl` (sumi-shell.service con
MainPID, reintento automático a los 0,5 s, NRestarts y StartLimitBurst=5/1min; `disable` prohibido) y `hyprctl`
(globalshortcuts = los del contrato si hay instancia). Nada toca la sesión real: HOME bajo /tmp, SUMI_INSTALL_TEST=1.

Salida: una línea por escenario; código = escenarios fallidos.
"""
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SIG = "kt6f_fixture_signature"
# Instalador de F6e en el historial de este repositorio (7d99a78 en dotfiles).
F6E_REV = "4ed6786b81513ae8b83095e758fdb7f8272254c3"
CONTRACT = json.load(open(os.path.join(ROOT, "api", "contract-v1.json")))

FAKE = r'''#!@PYTHON@
import fcntl, json, os, re, shutil, sys, time
name = os.path.basename(sys.argv[0]); a = sys.argv[1:]
fix = os.environ["KT_FIX"]
open(os.path.join(fix, "argv.log"), "a").write(json.dumps([name] + a) + "\n")
spec = json.load(open(os.path.join(fix, "spec.json")))
lockf = open(os.path.join(fix, "fake.lock"), "a")
fcntl.flock(lockf, fcntl.LOCK_EX)
SH = os.path.join(fix, "shell.json")
sh = json.load(open(SH)) if os.path.exists(SH) else {"instances": {}, "nextPid": 5000, "lockCalls": 0,
    "unit": {"active": "inactive", "sub": "dead", "mainpid": 0, "nrestarts": 0, "starts": [], "result": "success",
             "retryAt": None, "enter": 0}}
CFG = os.environ["XDG_CONFIG_HOME"]; STATE = os.environ["XDG_STATE_HOME"]
TREE = os.path.join(CFG, "quickshell", "sumi")
UDIR = os.path.join(CFG, "systemd", "user")
PROC = os.environ["SUMI_PROC"]
def save():
    json.dump(sh, open(SH, "w"))
def out(s="", rc=0):
    save(); sys.stdout.write(s); sys.exit(rc)
def mono():
    return time.clock_gettime(time.CLOCK_MONOTONIC)
def read(p):
    try:
        return open(p, "rb").read()
    except OSError:
        return None
def code_of(tree):
    """Lo que «cargaría» la shell desde el árbol EN DISCO ahora."""
    v = json.loads(read(os.path.join(tree, "version.json")) or b"{}")
    b = read(os.path.join(tree, "build.json"))
    build = json.loads(b).get("buildId", "") if b else ""
    ipc = (read(os.path.join(tree, "core", "Ipc.qml")) or b"").decode()
    verbs = sorted(set(re.findall(r"function (\w+)\(", ipc)))
    if os.path.exists(os.path.join(tree, ".kt-noshow")):
        verbs = [x for x in verbs if x != "lockNow"]
    inline = []
    for folder, dirs, files in os.walk(tree):
        for n in files:
            if n.endswith(".qml"):
                for m in re.finditer(rb"^\s*component\s+([A-Z]\w*)\s*:", read(os.path.join(folder, n)) or b"", re.M):
                    inline.append(m.group(1).decode())
    return {"version": v.get("version"), "apiVersion": v.get("apiVersion"), "schema": v.get("settingsSchema", 4),
            "build": build, "verbs": verbs, "inline": sorted(inline),
            "broken": os.path.exists(os.path.join(tree, ".kt-broken")),
            "touch": os.path.exists(os.path.join(tree, ".kt-touch-settings"))}
SETTINGS = os.path.join(CFG, "sumi-shell", "settings.json")
def settings_sync(inst):
    """Como ConfigStore: con un archivo de esquema MENOR, copia byte a byte y lo convierte; con uno MAYOR, sólo lectura."""
    raw = read(SETTINGS)
    if raw is None:
        return "ready"
    try:
        d = json.loads(raw)
    except ValueError:
        return "invalid"
    have, want = d.get("schemaVersion"), inst["schema"]
    if have == want:
        return "ready"
    if isinstance(have, int) and have > want:
        return "read-only"
    bdir = os.path.join(STATE, "sumi-shell", "backups", "settings")
    os.makedirs(bdir, exist_ok=True)
    bk = os.path.join(bdir, "settings.v%d-premigration-%s-%d.json" % (have, time.strftime("%Y%m%d-%H%M%S"), sh["nextPid"]))
    sh["nextPid"] += 1
    open(bk, "wb").write(raw); os.chmod(bk, 0o600)
    d["schemaVersion"] = want
    d.setdefault("migrations", []).append({"from": have, "to": want, "at": "now", "backup": bk})
    open(SETTINGS, "w").write(json.dumps(d, indent=2) + "\n")      # en el sitio, como FileView
    inst["log"].append("  INFO settings: migrated v%d → v%d" % (have, want))
    return "ready"
def proc_write(pid, start):
    d = os.path.join(PROC, str(pid)); os.makedirs(d, exist_ok=True)
    btime = int([l for l in open(os.path.join(PROC, "stat")) if l.startswith("btime")][0].split()[1])
    ticks = int((start - btime) * os.sysconf("SC_CLK_TCK")) + 1
    open(os.path.join(d, "stat"), "w").write("%d (qs) S %s %d 0 0\n" % (pid, " ".join(["0"] * 18), ticks))
    open(os.path.join(d, "comm"), "w").write("qs\n")
def start_instance(managed):
    c = code_of(TREE)
    pid = sh["nextPid"]; sh["nextPid"] += 1
    if c["broken"] or not os.path.exists(os.path.join(TREE, "shell.qml")):
        return None, ["  INFO Launching config: " + TREE + "/shell.qml",
                      " ERROR Failed to load configuration", " ERROR   caused by Broken is not a type"]
    st = time.time()
    inst = dict(c, start=st, managed=managed, phase="unlocked", readyAt=mono() + spec.get("notReady", 0.8),
                log=["  INFO Launching config: " + TREE + "/shell.qml", "  INFO Configuration Loaded"])
    sh["instances"][str(pid)] = inst
    proc_write(pid, st)
    settings_sync(inst)
    inst["pendingTouch"] = c["touch"]
    return pid, None
def user_touch(inst):
    """`.kt-touch-settings`: el usuario edita settings.json justo DESPUÉS de la conversión (en la primera llamada a `api`)."""
    if inst.get("pendingTouch") and read(SETTINGS) is not None:
        inst["pendingTouch"] = False
        d = json.loads(read(SETTINGS)); d["userEdit"] = True
        open(SETTINGS, "w").write(json.dumps(d, indent=2) + "\n")
def unit_start():
    u = sh["unit"]
    now = mono()
    u["starts"] = [t for t in u["starts"] if now - t < 60] + [now]
    if len(u["starts"]) > spec.get("burst", 5):
        u.update(active="failed", sub="failed", mainpid=0, result="start-limit-hit", retryAt=None)
        return
    pid, err = start_instance(True)
    if pid is None:
        sh.setdefault("deadLogs", []).append(err)
        u.update(active="activating", sub="auto-restart", mainpid=0, result="exit-code", retryAt=now + 0.5)
        return
    u.update(active="active", sub="running", mainpid=pid, result="success", retryAt=None, enter=now)
def unit_stop():
    u = sh["unit"]
    if u["mainpid"]:
        sh["instances"].pop(str(u["mainpid"]), None)
        shutil.rmtree(os.path.join(PROC, str(u["mainpid"])), ignore_errors=True)
    u.update(active="inactive", sub="dead", mainpid=0, retryAt=None)
def tick():
    u = sh["unit"]
    if u.get("retryAt") and mono() >= u["retryAt"]:
        u["nrestarts"] += 1
        unit_start()
tick()
if name == "kt-shell":          # sólo el banco: arrancar/parar una instancia fuera de la unidad, o «reiniciar la sesión»
    if a[:1] == ["start"]:
        pid, err = start_instance(False); out(str(pid) + "\n")
    if a[:1] == ["unit-start"]:
        unit_start(); out(str(sh["unit"]["mainpid"]) + "\n")
    if a[:1] == ["stop-all"]:
        for p in list(sh["instances"]):
            shutil.rmtree(os.path.join(PROC, p), ignore_errors=True)
        sh["instances"] = {}; sh["unit"].update(active="inactive", sub="dead", mainpid=0, retryAt=None); out()
    if a[:1] == ["phase"]:
        for i in sh["instances"].values(): i["phase"] = a[1]
        out()
    out("", 1)
if name == "qs":
    if a == ["--help"]:
        out("--no-duplicate\n")
    if a == ["ipc", "call", "--help"]:
        out()
    if a[:1] == ["list"]:
        inst = [{"config_path": TREE + "/shell.qml", "pid": int(p), "id": "x", "shell_id": "x"}
                for p in sorted(sh["instances"])] + spec.get("otherInstances", [])
        out((json.dumps(inst) if inst else "No running instances.") + "\n")
    if a[:2] == ["ipc", "--pid"] or a[:2] == ["log", "--pid"]:
        pid = a[2]; i = sh["instances"].get(pid)
        if i is None:
            out("No running instance with pid %s\n" % pid, 1)
        if a[0] == "log":
            out("\n".join(i["log"]) + "\n")
        rest = a[3:]
        if mono() < i.get("readyAt", 0):
            # medido (F6f, anidado): tras cargar, «Configuration Loaded» ya está en el log y el IPC aún dice esto ~2,5 s;
            # la orden NO se ejecuta
            out("Not ready to accept queries yet.\n", 1)
        if rest == ["show"]:
            out("target sumi\n" + "".join("  function %s(): string\n" % v for v in i["verbs"]))
        if rest[:2] == ["call", "sumi"]:
            verb = rest[2]
            if verb not in i["verbs"]:
                out("no function %s\n" % verb, 1)
            if verb == "api":
                user_touch(i)
                d = {"apiVersion": i["apiVersion"], "version": i["version"]}
                if i.get("build") is not None and spec.get("buildAware", True):
                    d["build"] = i["build"]
                out(json.dumps(d) + "\n")
            if verb == "lockStatus":
                sh["lockCalls"] += 1
                n = spec.get("lockOnNth")
                ph = "locked" if (n and sh["lockCalls"] >= n and not os.path.exists(os.path.join(fix, "unlocked"))) else i["phase"]
                out(json.dumps({"phase": ph, "secure": ph == "locked"}) + "\n")
            if verb == "status":
                out(json.dumps({"settings": {"store": {"status": settings_sync(i)}}}) + "\n")
            if verb == "reload":
                c = code_of(TREE)
                new_inline = sorted(set(c["inline"]) - set(i["inline"]))
                if os.path.exists(os.path.join(TREE, ".kt-crash-on-reload")) and i.get("managed"):
                    # la shell cae al recargar y systemd la levanta (otro proceso, con lo que haya en disco)
                    sh["instances"].pop(pid); shutil.rmtree(os.path.join(PROC, pid), ignore_errors=True)
                    sh["unit"]["nrestarts"] += 1
                    unit_start()
                    out("")
                if c["broken"] or c["schema"] == spec.get("failReloadSchema"):
                    i["log"] += [" ERROR Failed to load configuration", " ERROR   caused by Broken is not a type"]
                elif new_inline:
                    i["log"] += [" ERROR Failed to load configuration", " ERROR   caused by %s is not a type" % new_inline[0]]
                else:
                    keep = {k: i[k] for k in ("start", "managed", "phase", "log")}
                    i.clear(); i.update(c); i.update(keep)
                    i["log"].append("  INFO Configuration Loaded")
                    i["readyAt"] = mono() + spec.get("notReady", 0.8)
                    settings_sync(i)
                    i["pendingTouch"] = c["touch"]
                out("")
            out("\n")
    out("", 1)
if name == "hyprctl":
    if a == ["-j", "globalshortcuts"]:
        alive = [i for i in sh["instances"].values()]
        names = [{"name": "sumi:" + n, "description": ""} for n in json.load(open(os.path.join(fix, "names.json")))]
        out(json.dumps(names if alive and not spec.get("noShortcuts") else []) + "\n")
    if a == ["locked"]:
        out("false\n")
    if a == ["-j", "instances"]:
        out("[]\n")
    out("", 1)
if name == "systemctl":
    if a[:1] == ["--user"]:
        a = a[1:]
    if a[:1] == ["daemon-reload"] or a[:1] == ["show-environment"]:
        out("")
    if a[:1] == ["reset-failed"]:
        sh["unit"].update(active="inactive", sub="dead", starts=[], result="success"); out()
    if a[:1] == ["show"]:
        u = a[1]; keys = [a[i + 1] for i in range(2, len(a) - 1) if a[i] == "-p"]
        frag = os.path.join(UDIR, u)
        loaded = os.path.isfile(frag)
        if u == "sumi-shell.service":
            s = sh["unit"]
            vals = {"LoadState": "loaded" if loaded else "not-found", "FragmentPath": frag if loaded else "",
                    "ActiveState": s["active"], "SubState": s["sub"], "MainPID": str(s["mainpid"]),
                    "NRestarts": str(s["nrestarts"]), "Result": s["result"], "Restart": "on-failure",
                    "StartLimitBurst": str(spec.get("burst", 5)), "StartLimitIntervalUSec": "1min",
                    "ActiveEnterTimestampMonotonic": str(int((s["enter"] - spec.get("activeAgo", 120)) * 1e6)) if s["enter"] else "0",
                    "UnitFileState": "static" if loaded else ""}
        else:
            vals = {"LoadState": "loaded" if loaded and not spec.get("noRescue") else "not-found",
                    "FragmentPath": frag if loaded else "", "ActiveState": "inactive", "MainPID": "0", "UnitFileState": "static"}
        out("".join("%s=%s\n" % (k, vals.get(k, "")) for k in keys))
    if a[:2] == ["restart", "sumi-shell.service"]:
        unit_stop(); unit_start(); out()
    if a[:2] == ["start", "sumi-shell.service"]:
        if sh["unit"]["active"] in ("inactive",):
            unit_start()
        out()
    if a[:2] == ["stop", "sumi-shell.service"]:
        unit_stop(); out()
    if a[:1] == ["stop"]:
        out()
    if a[:1] == ["disable"]:
        out("disable is forbidden in the bench\n", 1)
    out("", 1)
out("", 1)
'''

def sha_file(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


def snapshot(home, skip=()):
    res = {}
    for folder, dirs, files in os.walk(home):
        for n in sorted(dirs + files):
            p = os.path.join(folder, n)
            rel = os.path.relpath(p, home)
            if any(rel.startswith(s) for s in skip):
                continue
            st = os.lstat(p)
            if stat.S_ISLNK(st.st_mode):
                res[rel] = ("link", os.readlink(p))
            elif stat.S_ISDIR(st.st_mode):
                res[rel] = ("dir", oct(stat.S_IMODE(st.st_mode)))
            else:
                res[rel] = ("file", sha_file(p), oct(stat.S_IMODE(st.st_mode)))
    return res


def diff_snap(a, b):
    return [k for k in sorted(set(a) | set(b)) if a.get(k) != b.get(k)]


# ---- árboles fuente: copias de la distribución con cambios pequeños --------------------------------------------------

def make_src(base, name, version=None, settings_schema=None, restart=None, extra=None, mutate=None, min_from=None):
    """Una distribución (install.sh, packaging/, api/, sumi/) en base/<name>, con su version.json y cambios."""
    root = os.path.join(base, name)
    os.makedirs(root)
    shutil.copy2(os.path.join(ROOT, "install.sh"), root)
    for d in ("packaging", "api", "sumi"):
        shutil.copytree(os.path.join(ROOT, d), os.path.join(root, d),
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "build.json"))
    vp = os.path.join(root, "sumi", "version.json")
    v = json.load(open(vp))
    if version:
        v["version"] = version
    if settings_schema is not None:
        v["settingsSchema"] = settings_schema
    if restart is not None:
        v["restart"] = restart
    if min_from:
        v["minUpdateFrom"] = min_from
    open(vp, "w").write(json.dumps(v, indent=2) + "\n")
    for rel, body in (extra or {}).items():
        p = os.path.join(root, "sumi", rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write(body)
    if mutate:
        mutate(os.path.join(root, "sumi"))
    return root


def touch_qml(rel, text):
    def m(tree):
        p = os.path.join(tree, rel)
        s = open(p).read()
        i = s.rstrip().rfind("}")
        open(p, "w").write(s[:i] + text + "\n" + s[i:])
    return m


REV = touch_qml("services/Clip.qml", "    // F6f bench: another revision with the same version")
INLINE = touch_qml("services/Clip.qml", "    component KtBenchThing: Item {}")


class Bench:
    def __init__(self, spec=None):
        self.tmp = tempfile.mkdtemp(prefix="kt6f-")
        self.h = os.path.join(self.tmp, "h")
        for d in (".config", ".local/state", ".local/share", ".cache"):
            os.makedirs(os.path.join(self.h, d))
        self.cfg = os.path.join(self.h, ".config")
        self.state = os.path.join(self.h, ".local", "state")
        self.tree = os.path.join(self.cfg, "quickshell", "sumi")
        self.man_path = os.path.join(self.state, "sumi-shell", "install", "manifest.json")
        self.settings = os.path.join(self.cfg, "sumi-shell", "settings.json")
        self.run_dir = os.path.join(self.tmp, "run")
        os.makedirs(self.run_dir, mode=0o700)
        self.fix = os.path.join(self.tmp, "fix")
        self.bin = os.path.join(self.tmp, "bin")
        self.proc = os.path.join(self.tmp, "proc")
        self.srcs = os.path.join(self.tmp, "src")
        for d in (self.fix, self.bin, self.proc, self.srcs, os.path.join(self.tmp, "etcxdg"), os.path.join(self.tmp, "nodata"),
                  os.path.join(self.tmp, "units"), os.path.join(self.tmp, "pam")):
            os.makedirs(d)
        self.btime = int(time.time()) - 100000
        open(os.path.join(self.proc, "stat"), "w").write("cpu 0 0 0 0\nbtime %d\n" % self.btime)
        self.spec = dict(spec or {})
        self.save_spec()
        json.dump(CONTRACT["shortcuts"]["names"], open(os.path.join(self.fix, "names.json"), "w"))
        fake = os.path.join(self.fix, "fake.py")
        open(fake, "w").write(FAKE.replace("@PYTHON@", os.path.realpath(sys.executable)))
        os.chmod(fake, 0o755)
        for n in ("systemctl", "qs", "hyprctl", "kt-shell"):
            os.symlink(fake, os.path.join(self.bin, n))
        self.shim = os.path.join(self.tmp, "shim")
        os.makedirs(self.shim)
        for n in ("bash", "sh", "python3", "env", "dirname", "ldd", "timeout", "sleep", "cat", "true", "false", "uname"):
            real = shutil.which(n)
            if real:
                os.symlink(real, os.path.join(self.shim, n))

    def save_spec(self):
        json.dump(self.spec, open(os.path.join(self.fix, "spec.json"), "w"))

    def set(self, **kw):
        self.spec = json.load(open(os.path.join(self.fix, "spec.json")))
        self.spec.update(kw)
        self.save_spec()

    def env(self, extra=None):
        e = {"HOME": self.h, "XDG_CONFIG_HOME": self.cfg, "XDG_STATE_HOME": self.state,
             "XDG_CACHE_HOME": os.path.join(self.h, ".cache"), "XDG_DATA_HOME": os.path.join(self.h, ".local", "share"),
             "XDG_CONFIG_DIRS": os.path.join(self.tmp, "etcxdg"), "XDG_DATA_DIRS": os.path.join(self.tmp, "nodata"),
             "XDG_RUNTIME_DIR": self.run_dir, "SUMI_INSTALL_TEST": "1", "SUMI_INSTALL_RUNTIME_DIR": self.run_dir,
             "SUMI_PROC": self.proc, "KT_CAPS_PROC_DIR": self.proc, "KT_FIX": self.fix,
             "HYPRLAND_INSTANCE_SIGNATURE": SIG, "PATH": self.bin + ":" + self.shim, "LANG": "C.UTF-8",
             "SUMI_PAM_DIRS": os.path.join(self.tmp, "pam"), "SUMI_UNIT_DIRS": os.path.join(self.tmp, "units")}
        e.update(extra or {})
        return e

    def src(self, name, **kw):
        return make_src(self.srcs, name, **kw)

    def run(self, src, *args, extra=None, timeout=240):
        p = subprocess.run(["bash", os.path.join(src, "install.sh")] + list(args), env=self.env(extra),
                           capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout + p.stderr

    def shell(self, *args):
        p = subprocess.run([os.path.join(self.bin, "kt-shell")] + list(args), env=self.env(), capture_output=True,
                           text=True, timeout=30)
        return p.stdout.strip()

    def sh(self):
        return json.load(open(os.path.join(self.fix, "shell.json")))

    def running(self):
        """{pid: instancia} vivas (pasando por el falso, que aplica los reintentos de systemd)."""
        subprocess.run([os.path.join(self.bin, "qs"), "list"], env=self.env(), capture_output=True, timeout=30)
        return self.sh()["instances"]

    def man(self):
        return json.load(open(self.man_path))

    def calls(self):
        log = os.path.join(self.fix, "argv.log")
        return [json.loads(l) for l in open(log)] if os.path.exists(log) else []

    def write_settings(self, schema, extra=None):
        d = {"schemaVersion": schema, "shell": {"x": 1}}
        d.update(extra or {})
        os.makedirs(os.path.dirname(self.settings), exist_ok=True)
        open(self.settings, "w").write(json.dumps(d, indent=2) + "\n")
        return sha_file(self.settings)

    def close(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


def expect(cond, msg, probs):
    if not cond:
        probs.append(msg)


def tree_build(b):
    try:
        return json.load(open(os.path.join(b.tree, "build.json")))["buildId"]
    except OSError:
        return None


def installed(b, src, units=True, start="unit"):
    rc, out = b.run(src, "install", *([] if units else ["--no-units"]))
    if rc != 0:
        raise AssertionError("install rc %d: %s" % (rc, out[-400:]))
    if start == "unit":
        b.shell("unit-start")
    elif start == "exec":
        b.shell("start")
    return b.man()


def only_instance(b):
    inst = b.running()
    return (list(inst.items()) or [(None, None)])[0] if len(inst) == 1 else (None, None)


def stagings(b):
    return [n for n in os.listdir(os.path.join(b.cfg, "quickshell")) if n.startswith(".sumi-staging-")]


def coherent(b, probs, want_build, want_running_build, state):
    """Disco, proceso y manifiesto coinciden con lo esperado; sin restos de staging."""
    m = b.man()
    expect(m.get("transaction") is None, "a transaction is left pending", probs)
    expect((m.get("update") or {}).get("state") == state, "update state %r, expected %r (%s)" % (
        (m.get("update") or {}).get("state"), state, (m.get("update") or {}).get("why")), probs)
    expect(tree_build(b) == want_build, "on disk build %s, expected %s" % (tree_build(b), want_build), probs)
    expect(m["tree"]["buildId"] == want_build, "manifest tree %s, expected %s" % (m["tree"]["buildId"], want_build), probs)
    # el manifiesto describe EXACTAMENTE lo que hay en disco
    disk = {}
    for folder, dirs, files in os.walk(b.tree):
        for n in files:
            p = os.path.join(folder, n)
            rel = os.path.relpath(p, b.tree)
            if rel != ".sumi-install":
                disk[rel] = sha_file(p)
    recd = {rel: v[0] for rel, v in m["files"].items()}
    expect(disk == recd, "manifest files ≠ disk (%s)" % ", ".join(sorted(set(disk.items()) ^ set(recd.items()))[:3]), probs)
    if want_running_build is not False:
        pid, inst = only_instance(b)
        got = (inst or {}).get("build") or None
        expect(got == want_running_build, "running build %s, expected %s" % (got, want_running_build), probs)
    expect(not stagings(b), "staging left: %s" % stagings(b), probs)


# ---- escenarios: actualizar y cargar --------------------------------------------------------------------------------

def s_reload_compatible(b, probs):
    A = b.src("A")
    installed(b, A)
    pid0 = int(list(b.running())[0])
    start0 = b.sh()["instances"][str(pid0)]["start"]
    B = b.src("B", mutate=REV)
    rc, out = b.run(B, "update")
    expect(rc == 1 and "--reload (it looks enough)" in out, "preview: %d %s" % (rc, out[-300:]), probs)
    rc, out = b.run(B, "update", "--apply", "--reload")
    expect(rc == 0 and "Updated:" in out, "apply --reload rc %d: %s" % (rc, out[-400:]), probs)
    want = b.man()["tree"]["buildId"]
    coherent(b, probs, want, want, "verified")
    inst = b.sh()["instances"]
    expect(list(inst) == [str(pid0)] and inst[str(pid0)]["start"] == start0, "a reload changed the process", probs)
    m = b.man()
    expect(m["update"]["running"]["pid"] == pid0, "running record pid", probs)
    expect(m["previous"] and os.path.isdir(os.path.join(b.state, m["previous"]["rel"])), "no previous kept", probs)
    expect(not any(c[0] == "systemctl" and "restart" in c for c in b.calls()), "a reload restarted something", probs)
    b.A, b.B = A, B


def s_catalog_added_by_update(b, probs):
    """Ayuda de atajos (2026-10-30): una instalación anterior sin `lib/shortcuts.json` (el catálogo de los atajos) lo recibe
    al actualizar, con su sha y en el manifiesto, junto a los archivos nuevos de la ayuda; `--rollback` lo retira."""
    new = ("lib/shortcuts.json", "lib/keybinds.js", "services/Keybinds.qml", "services/KeybindsUi.qml",
           "core/KeybindsLayer.qml", "core/KeybindsKeys.qml")

    def without(tree):
        for rel in new:
            os.unlink(os.path.join(tree, rel))
    A = b.src("A", mutate=without)
    installed(b, A)
    expect(not os.path.exists(os.path.join(b.tree, "lib", "shortcuts.json")), "A already had the catalog", probs)
    B = b.src("B")
    rc, out = b.run(B, "update", "--apply", "--reload")
    expect(rc == 0 and "Updated:" in out, "apply --reload rc %d: %s" % (rc, out[-400:]), probs)
    files = b.man().get("files", {})
    for rel in new:
        p = os.path.join(b.tree, rel)
        want = hashlib.sha256(open(os.path.join(B, "sumi", rel), "rb").read()).hexdigest()
        expect(os.path.isfile(p) and hashlib.sha256(open(p, "rb").read()).hexdigest() == want, "%s not installed" % rel, probs)
        expect(rel in files and files[rel][0] == want, "%s not in the manifest" % rel, probs)
    expect(oct(os.stat(os.path.join(b.tree, "lib", "shortcuts.json")).st_mode & 0o777) == "0o644", "catalog mode", probs)
    rc, out = b.run(B, "update", "--rollback", "--reload")
    expect(rc == 0, "rollback rc %d: %s" % (rc, out[-400:]), probs)
    expect(not any(os.path.exists(os.path.join(b.tree, rel)) for rel in new), "rollback left the new files", probs)


def s_reload_incompatible(b, probs):
    A = b.src("A")
    installed(b, A)
    B = b.src("B", mutate=INLINE)
    before = snapshot(b.h)
    rc, out = b.run(B, "update")
    expect(rc == 1 and "needs: --restart" in out and "KtBenchThing" in out, "preview: %s" % out[-400:], probs)
    rc, out = b.run(B, "update", "--apply", "--reload")
    expect(rc == 1 and "use --restart" in out, "--reload not refused: %s" % out[-400:], probs)
    expect(diff_snap(before, snapshot(b.h)) == [], "refused but HOME changed", probs)
    # una versión que declara restart.required también exige --restart, aunque no tenga componentes nuevos
    C = b.src("C", mutate=REV, restart={"required": True, "why": "bench"})
    rc, out = b.run(C, "update", "--apply", "--reload")
    expect(rc == 1 and "requires a cold start (bench)" in out, "declared restart ignored: %s" % out[-300:], probs)
    # sin la declaración (un version.json que no dice nada): tampoco se puede argumentar la recarga
    D = b.src("D", mutate=REV)
    vp = os.path.join(D, "sumi", "version.json")
    v = json.load(open(vp)); v.pop("restart")
    open(vp, "w").write(json.dumps(v))
    rc, out = b.run(D, "update", "--apply", "--reload")
    expect(rc == 1 and "doesn't declare whether a reload is enough" in out, "undeclared restart: %s" % out[-300:], probs)


def s_restart_new_pid(b, probs):
    A = b.src("A")
    installed(b, A)
    pid0 = int(list(b.running())[0])
    B = b.src("B", mutate=INLINE)
    rc, out = b.run(B, "update", "--apply", "--restart")
    expect(rc == 0 and "Updated:" in out, "apply --restart rc %d: %s" % (rc, out[-500:]), probs)
    want = b.man()["tree"]["buildId"]
    coherent(b, probs, want, want, "verified")
    pid, inst = only_instance(b)
    expect(pid and int(pid) != pid0, "the pid didn't change with --restart", probs)
    expect(b.sh()["unit"]["mainpid"] == int(pid), "running instance isn't the unit's", probs)
    expect(b.man()["update"]["running"]["pid"] == int(pid), "manifest records the old pid", probs)


def s_restart_budget(b, probs):
    A = b.src("A")
    installed(b, A)
    B = b.src("B", mutate=INLINE)
    b.set(activeAgo=5)
    rc, out = b.run(B, "update", "--apply", "--restart")
    expect(rc == 1 and "try again in" in out, "recent start not refused: %s" % out[-300:], probs)
    b.set(activeAgo=120, burst=3)
    rc, out = b.run(B, "update", "--apply", "--restart")
    expect(rc == 1 and "allows 3 starts" in out, "small burst not refused: %s" % out[-300:], probs)
    b.set(burst=5, noRescue=True)
    rc, out = b.run(B, "update", "--apply", "--restart")
    expect(rc == 1 and "sumi-lock-rescue.service loaded" in out, "no rescue not refused: %s" % out[-300:], probs)
    # una instancia fuera de la unidad (exec-once): --restart no es nuestro
    b.set(noRescue=False)
    b.shell("stop-all")
    b.shell("start")
    rc, out = b.run(B, "update", "--apply", "--restart")
    expect(rc == 1 and "needs sumi-shell.service running" in out, "exec-once restart not refused: %s" % out[-300:],
           probs)
    expect(not any(c[:3] == ["systemctl", "--user", "restart"] for c in b.calls()), "something was restarted", probs)


def s_same_version_two_builds(b, probs):
    A = b.src("A")
    installed(b, A)
    a_build = b.man()["tree"]["buildId"]
    # el mismo contenido: idempotente, nada cambia (ni el manifiesto)
    A2 = b.src("A2")
    before = snapshot(b.h)
    rc, out = b.run(A2, "update", "--apply", "--reload")
    expect(rc == 0 and "Already up to date" in out, "same content not idempotent: %s" % out[-300:], probs)
    expect(diff_snap(before, snapshot(b.h)) == [], "an idempotent update changed the HOME", probs)
    # otra revisión con la MISMA versión: otra construcción, se actualiza y se comprueba que corre ESA
    B = b.src("B", mutate=REV)
    rc, out = b.run(B, "update", "--apply", "--reload")
    want = b.man()["tree"]["buildId"]
    expect(rc == 0 and want != a_build, "same-version revision not applied: %s" % out[-300:], probs)
    expect(b.man()["tree"]["version"] == b.man()["update"]["from"]["version"], "versions differ?", probs)
    coherent(b, probs, want, want, "verified")


def s_load_failure_keeps_old(b, probs):
    A = b.src("A")
    installed(b, A)
    a_build = b.man()["tree"]["buildId"]
    pid0 = list(b.running())[0]
    B = b.src("B", mutate=REV, extra={".kt-broken": "x\n"})
    rc, out = b.run(B, "update", "--apply", "--reload")
    expect(rc == 1 and "rolled-back" in out and "Failed to load configuration" in out, "load failure: %s" % out[-500:],
           probs)
    coherent(b, probs, a_build, a_build, "rolled-back")
    expect(list(b.running()) == [pid0], "the instance changed", probs)
    expect(not b.man().get("previous"), "a failed update kept a 'previous'", probs)
    # lo mismo con --restart: systemd reintenta, el árbol de antes vuelve a tiempo y la unidad no agota su límite
    rc, out = b.run(B, "update", "--apply", "--restart")
    expect(rc == 1 and "rolled-back" in out, "restart load failure: %s" % out[-500:], probs)
    coherent(b, probs, a_build, a_build, "rolled-back")
    u = b.sh()["unit"]
    expect(u["active"] == "active" and u["mainpid"], "unit not active after the way back: %s" % u, probs)


def s_crash_on_reload(b, probs):
    """Durante una recarga el proceso cae y systemd levanta otro: una recarga NUNCA cambia de proceso, así que es un
    fallo aunque el nuevo diga la construcción esperada; vuelta atrás y el proceso que quede, comprobado."""
    A = b.src("A")
    installed(b, A)
    a_build = b.man()["tree"]["buildId"]
    pid0 = list(b.running())[0]
    B = b.src("B", mutate=REV, extra={".kt-crash-on-reload": "x\n"})
    rc, out = b.run(B, "update", "--apply", "--reload")
    expect(rc == 1 and "changed" in out and "during a reload" in out and "rolled-back" in out, "crash: %s" % out[-400:],
           probs)
    coherent(b, probs, a_build, a_build, "rolled-back")
    expect(list(b.running()) != [pid0], "the bench didn't change the process", probs)


def s_slow_ipc_after_reload(b, probs):
    """Medido en el anidado: tras cargar, el IPC dice «Not ready» ~2,5 s y no ejecuta órdenes. Ni la comprobación ni la
    vuelta atrás pueden tomar eso por un fallo, ni dar por pedida una recarga que no se aceptó."""
    b.set(notReady=3)
    A = b.src("A")
    installed(b, A)
    a_build = b.man()["tree"]["buildId"]
    B = b.src("B", mutate=REV)
    rc, out = b.run(B, "update", "--apply", "--reload")
    want = b.man()["tree"]["buildId"]
    expect(rc == 0 and "Updated:" in out, "slow IPC update: %s" % out[-300:], probs)
    coherent(b, probs, want, want, "verified")
    C = b.src("C", mutate=touch_qml("services/Clip.qml", "    // C"), extra={".kt-noshow": "x\n"})
    rc, out = b.run(C, "update", "--apply", "--reload")
    expect(rc == 1 and "rolled-back" in out, "slow IPC rollback: %s" % out[-300:], probs)
    coherent(b, probs, want, want, "rolled-back")


def s_load_ok_check_fails(b, probs):
    """La carga sale bien pero falta un consumidor crítico (lockNow): vuelta atrás automática."""
    A = b.src("A")
    installed(b, A)
    a_build = b.man()["tree"]["buildId"]
    B = b.src("B", mutate=REV, extra={".kt-noshow": "x\n"})
    rc, out = b.run(B, "update", "--apply", "--reload")
    expect(rc == 1 and "lockNow" in out and "rolled-back" in out, "missing verb not caught: %s" % out[-400:], probs)
    coherent(b, probs, a_build, a_build, "rolled-back")


def s_static_checks(b, probs):
    """Lo que se ve sin ejecutar: sintaxis QML (qmllint), bash, Python, JSON; y los consumidores del árbol nuevo."""
    A = b.src("A")
    installed(b, A)
    before = snapshot(b.h)
    for name, extra, mutate, needle in (
            ("Bq", None, touch_qml("services/Clip.qml", "    property int = ;"), "QML"),
            ("Bb", {"scripts/kt-bench.sh": "#!/bin/bash\nif then fi\n"}, REV, "kt-bench.sh"),
            ("Bp", {"scripts/kt_bench.py": "def (:\n"}, REV, "kt_bench.py"),
            ("Bj", {"kt-bench.json": "{nope"}, REV, "kt-bench.json")):
        S = b.src(name, extra=extra, mutate=mutate)
        rc, out = b.run(S, "update", "--apply", "--reload")
        expect(rc == 1 and "checks made without running it" in out and needle in out, "%s: %s" % (name, out[-300:]),
               probs)
    def no_rescue_mode(tree):
        p = os.path.join(tree, "scripts", "sumi-lock")
        open(p, "w").write(open(p).read().replace("    rescue-request)", "    rescue_request_gone)"))
    S = b.src("Bh", mutate=no_rescue_mode)
    rc, out = b.run(S, "update", "--apply", "--reload")
    expect(rc == 1 and "rescue-request" in out, "helper mode not checked: %s" % out[-300:], probs)
    expect(diff_snap(before, snapshot(b.h)) == [], "a refused update changed the HOME", probs)


# ---- settings.json ----------------------------------------------------------------------------------------------------

def s_settings_migration_then_failure(b, probs):
    A = b.src("A", settings_schema=3)
    pre = b.write_settings(3)
    installed(b, A)
    a_build = b.man()["tree"]["buildId"]
    B = b.src("B", mutate=REV, settings_schema=4, extra={".kt-noshow": "x\n"})
    rc, out = b.run(B, "update", "--apply", "--reload")
    expect(rc == 1 and "--accept-settings-migration" in out, "migration not announced: %s" % out[-300:], probs)
    rc, out = b.run(B, "update", "--apply", "--reload", "--accept-settings-migration")
    expect(rc == 1 and "rolled-back" in out and "restored from its verified copy" in out, "out: %s" % out[-500:], probs)
    coherent(b, probs, a_build, a_build, "rolled-back")
    expect(sha_file(b.settings) == pre, "settings.json isn't the one from before", probs)
    m = b.man()
    s = m["update"]["settings"]
    disp = os.path.join(b.state, s["displaced"])
    expect(s["state"] == "restored" and os.path.isfile(disp) and json.load(open(disp))["schemaVersion"] == 4,
           "the converted file wasn't kept: %s" % s, probs)
    copy = os.path.join(b.state, s["pre"]["copy"])
    expect(stat.S_IMODE(os.stat(copy).st_mode) == 0o600 and sha_file(copy) == pre, "pre copy not 0600/identical", probs)
    st = b.sh()["instances"]
    expect(all(i["schema"] == 3 for i in st.values()), "running code isn't the old one", probs)


def s_settings_concurrent_edit(b, probs):
    """El usuario edita settings.json justo después de que la versión nueva lo convierta, y la comprobación falla: no se
    repone nada, no se vuelve a un código que no entiende el archivo, estado de conflicto y nunca éxito."""
    A = b.src("A", settings_schema=3)
    b.write_settings(3)
    installed(b, A)
    B = b.src("B", mutate=REV, settings_schema=4, extra={".kt-noshow": "x\n", ".kt-touch-settings": "x\n"})
    rc, out = b.run(B, "update", "--apply", "--reload", "--accept-settings-migration")
    expect(rc == 1 and "settings-conflict" in out, "no conflict: %s" % out[-500:], probs)
    m = b.man()
    expect(m["update"]["state"] == "settings-conflict" and m["update"]["inPlace"] == "new", "state %s" % m["update"], probs)
    expect(json.load(open(b.settings)).get("userEdit") is True, "the user's edit was lost", probs)
    expect(m["transaction"] is None and tree_build(b) == m["tree"]["buildId"], "disk/manifest incoherent", probs)
    rc, out = b.run(B, "update", "--apply", "--reload", "--accept-settings-migration")
    expect(rc == 1 and "settings-conflict" in out, "a new update was allowed over a conflict: %s" % out[-300:], probs)
    rc, out = b.run(B, "update", "--rollback", "--reload")
    expect(rc == 1 and "changed" in out, "rollback over a user edit not refused: %s" % out[-300:], probs)
    expect(json.load(open(b.settings)).get("userEdit") is True, "the user's edit was lost (rollback)", probs)
    rc, out = b.run(A, "uninstall")
    expect(rc == 1 and "settings-conflict" in out, "uninstall allowed with a conflict: %s" % out[-300:], probs)


def s_rollback_incompatible_settings(b, probs):
    """Tras una actualización verificada que convirtió settings.json: --rollback lo repone sólo si sigue tal cual; si el
    usuario lo cambió después, se niega sin tocar nada."""
    A = b.src("A", settings_schema=3)
    pre = b.write_settings(3)
    installed(b, A)
    a_build = b.man()["tree"]["buildId"]
    B = b.src("B", mutate=REV, settings_schema=4)
    rc, out = b.run(B, "update", "--apply", "--reload", "--accept-settings-migration")
    expect(rc == 0, "update: %s" % out[-300:], probs)
    expect(json.load(open(b.settings))["schemaVersion"] == 4, "not converted", probs)
    expect(b.man()["update"]["settings"]["state"] == "converted", "post not recorded as converted", probs)
    rc, out = b.run(B, "update", "--rollback", "--reload")
    expect(rc == 0 and "restored from its verified copy" in out, "rollback: %s" % out[-500:], probs)
    coherent(b, probs, a_build, a_build, "rolled-back")
    expect(sha_file(b.settings) == pre, "settings.json not restored", probs)
    expect(not b.man().get("previous"), "previous still recorded after using it", probs)
    expect(all(i["schema"] == 3 for i in b.sh()["instances"].values()), "old code not running", probs)
    # otra vez hacia delante; el usuario cambia un ajuste; --rollback se niega
    rc, out = b.run(B, "update", "--apply", "--reload", "--accept-settings-migration")
    expect(rc == 0, "update again: %s" % out[-300:], probs)
    d = json.load(open(b.settings)); d["shell"]["x"] = 2
    open(b.settings, "w").write(json.dumps(d, indent=2) + "\n")
    edited = sha_file(b.settings)
    before = snapshot(b.h)
    rc, out = b.run(B, "update", "--rollback", "--reload")
    expect(rc == 1 and "changed after the new version converted it" in out, "edited rollback: %s" % out[-300:], probs)
    expect(sha_file(b.settings) == edited and diff_snap(before, snapshot(b.h)) == [], "a refused rollback changed things",
           probs)


def s_settings_newer_refused(b, probs):
    """Una versión más vieja que el esquema del archivo: se niega (sin --downgrade) y con --downgrade también (no hay
    restauración posible)."""
    A = b.src("A", version="0.5.0")
    b.write_settings(5)
    installed(b, A)
    B = b.src("B", mutate=REV, settings_schema=4)
    rc, out = b.run(B, "update", "--apply", "--reload")
    expect(rc == 1 and "--downgrade" in out and "newer than what" in out, "downgrade: %s" % out[-400:], probs)
    rc, out = b.run(B, "update", "--apply", "--reload", "--downgrade")
    expect(rc == 1 and "newer than what" in out, "--downgrade over newer settings: %s" % out[-400:], probs)


# ---- la sesión, la instancia y la recuperación ------------------------------------------------------------------------

def s_lock_during_update(b, probs):
    A = b.src("A")
    installed(b, A)
    a_build = b.man()["tree"]["buildId"]
    B = b.src("B", mutate=REV)
    # se bloquea antes del intercambio: nada cambió
    before = snapshot(b.h, skip=(".local/state/sumi-shell/install/manifest.json",))
    b.set(lockOnNth=2)
    rc, out = b.run(B, "update", "--apply", "--reload")
    expect(rc == 1 and "before swapping" in out, "lock before swap: %s" % out[-300:], probs)
    after = snapshot(b.h, skip=(".local/state/sumi-shell/install/manifest.json",))
    expect(diff_snap(before, after) == [], "lock before swap changed the HOME: %s" % diff_snap(before, after)[:4], probs)
    expect(b.man()["transaction"] is None and tree_build(b) == a_build, "pending after an abandoned update", probs)
    # se bloquea tras el intercambio: disco nuevo, proceso viejo, estado propio; ni éxito ni carga
    json.dump(dict(b.sh(), lockCalls=0), open(os.path.join(b.fix, "shell.json"), "w"))
    b.set(lockOnNth=3)
    rc, out = b.run(B, "update", "--apply", "--reload")
    expect(rc == 1 and "swapped-not-loaded" in out, "lock after swap: %s" % out[-300:], probs)
    m = b.man()
    expect(m["update"]["state"] == "swapped-not-loaded" and tree_build(b) == m["tree"]["buildId"] != a_build,
           "disk/manifest after lock: %s" % m["update"]["state"], probs)
    pid, inst = only_instance(b)
    expect(inst["build"] == a_build, "the running shell was reloaded while locked", probs)
    rc, out = b.run(B, "status")
    expect("swapped-not-loaded" in out and "running" in out, "status doesn't say it: %s" % out[-400:], probs)
    rc, out = b.run(B, "update", "--finish", "--reload")
    expect(rc == 1 and "isn't unlocked" in out, "finish while locked: %s" % out[-300:], probs)
    open(os.path.join(b.fix, "unlocked"), "w").close()
    rc, out = b.run(B, "update", "--finish", "--reload")
    expect(rc == 0 and "Updated:" in out, "finish: %s" % out[-400:], probs)
    want = b.man()["tree"]["buildId"]
    coherent(b, probs, want, want, "verified")


def s_lock_then_session_restart(b, probs):
    """Bloqueada a mitad (swapped-not-loaded) y la sesión se reinicia: la shell nueva arranca desde el disco; --finish sólo
    la comprueba (no hace falta cargar nada) y cierra."""
    A = b.src("A")
    installed(b, A)
    B = b.src("B", mutate=REV)
    b.set(lockOnNth=3)
    rc, out = b.run(B, "update", "--apply", "--reload")
    expect(rc == 1 and "swapped-not-loaded" in out, "lock after swap: %s" % out[-300:], probs)
    b.shell("stop-all")
    open(os.path.join(b.fix, "unlocked"), "w").close()
    b.shell("unit-start")
    rc, out = b.run(B, "update", "--finish", "--reload")
    want = b.man()["tree"]["buildId"]
    expect(rc == 0 and "Updated:" in out, "finish after restart: %s" % out[-300:], probs)
    expect(not any(c[:4] == ["qs", "ipc", "--pid"] and c[-1:] == ["reload"] for c in b.calls()), "it reloaded", probs)
    coherent(b, probs, want, want, "verified")


def s_lock_then_rollback(b, probs):
    A = b.src("A")
    installed(b, A)
    a_build = b.man()["tree"]["buildId"]
    B = b.src("B", mutate=REV)
    b.set(lockOnNth=3)
    rc, out = b.run(B, "update", "--apply", "--reload")
    open(os.path.join(b.fix, "unlocked"), "w").close()
    rc, out = b.run(B, "update", "--rollback", "--reload")
    expect(rc == 0 and "back to" in out, "rollback of swapped-not-loaded: %s" % out[-400:], probs)
    coherent(b, probs, a_build, a_build, "rolled-back")


def s_interrupt_then_session_restart(b, probs):
    """Corte justo tras el intercambio (SIGKILL), y la sesión se reinicia: la shell arranca desde el disco (la nueva).
    recover la comprueba y termina hacia delante; sin shell, recover deja el árbol de antes en su sitio."""
    A = b.src("A")
    installed(b, A)
    a_build = b.man()["tree"]["buildId"]
    B = b.src("B", mutate=REV)
    rc, out = b.run(B, "update", "--apply", "--reload", extra={"SUMI_INSTALL_FAULT": "exchange:after:SIGKILL"})
    expect(rc != 0, "the fault didn't fire", probs)
    m = b.man()
    expect(m["transaction"] and m["transaction"]["op"] == "update", "no pending transaction", probs)
    b.shell("stop-all")
    b.shell("unit-start")            # «nueva sesión»: la shell arranca con lo que hay en disco
    rc, out = b.run(B, "recover")
    expect(rc == 3 and "new tree is in place" in out, "recover preview: %s" % out[-300:], probs)
    rc, out = b.run(B, "recover", "--apply", "--reload")
    want = b.man()["tree"]["buildId"]
    expect(rc == 0 and want != a_build, "recover forward: %s" % out[-400:], probs)
    coherent(b, probs, want, want, "verified")


def s_interrupt_no_shell(b, probs):
    A = b.src("A")
    installed(b, A)
    a_build = b.man()["tree"]["buildId"]
    B = b.src("B", mutate=REV)
    rc, out = b.run(B, "update", "--apply", "--reload", extra={"SUMI_INSTALL_FAULT": "exchange:after:SIGKILL"})
    b.shell("stop-all")
    rc, out = b.run(B, "recover", "--apply")
    expect(rc == 0 and "undone on disk" in out, "recover without shell: %s" % out[-400:], probs)
    coherent(b, probs, a_build, False, "installed-unverified")
    b.shell("unit-start")
    rc, out = b.run(B, "update", "--verify")
    expect(rc == 0 and b.man()["update"]["state"] == "verified", "verify after recover: %s" % out[-300:], probs)
    # corte ANTES del intercambio: recover sólo retira el staging; el estado anterior vuelve
    rc, out = b.run(B, "update", "--apply", "--reload", extra={"SUMI_INSTALL_FAULT": "stage:after:SIGKILL"})
    expect(stagings(b), "no staging to recover", probs)
    rc, out = b.run(B, "recover", "--apply", "--reload")
    expect(rc == 0 and "nothing had been swapped" in out, "recover before swap: %s" % out[-300:], probs)
    coherent(b, probs, a_build, a_build, "verified")


def s_install_without_instance(b, probs):
    A = b.src("A")
    installed(b, A, start=None)
    B = b.src("B", mutate=INLINE)
    rc, out = b.run(B, "update")
    expect(rc == 0 and "isn't running" in out, "preview without instance: %s" % out[-300:], probs)
    rc, out = b.run(B, "update", "--apply")
    want = b.man()["tree"]["buildId"]
    expect(rc == 0 and "installed-unverified" in out, "apply without instance: %s" % out[-300:], probs)
    coherent(b, probs, want, False, "installed-unverified")
    rc, out = b.run(B, "update", "--apply")
    expect(rc == 1 and "installed-unverified" in out, "a second update over unverified: %s" % out[-300:], probs)
    b.shell("unit-start")
    rc, out = b.run(B, "update", "--verify")
    expect(rc == 0 and b.man()["update"]["state"] == "verified", "verify: %s" % out[-300:], probs)
    coherent(b, probs, want, want, "verified")


def s_verify_mismatch_then_rollback(b, probs):
    """Sin instancia al actualizar; luego corre OTRA construcción (una copia vieja cargada por otro lado): verify-failed,
    nunca «verificado»; --rollback vuelve a la anterior."""
    A = b.src("A")
    installed(b, A, start=None)
    a_build = b.man()["tree"]["buildId"]
    B = b.src("B", mutate=REV)
    rc, out = b.run(B, "update", "--apply")
    b.set(buildAware=False)                  # la instancia no dice su construcción (código anterior a F6f)
    b.shell("unit-start")
    rc, out = b.run(B, "update", "--verify")
    expect(rc == 1 and b.man()["update"]["state"] == "verify-failed", "mismatch accepted: %s" % out[-300:], probs)
    b.set(buildAware=True)
    rc, out = b.run(B, "update", "--rollback", "--restart")
    expect(rc == 0, "rollback: %s" % out[-400:], probs)
    coherent(b, probs, a_build, a_build, "rolled-back")


def s_other_copy_refused(b, probs):
    A = b.src("A")
    installed(b, A)
    b.set(otherInstances=[{"config_path": "/etc/xdg/quickshell/sumi/shell.qml", "pid": 7777, "id": "y",
                           "shell_id": "y"}])
    B = b.src("B", mutate=REV)
    rc, out = b.run(B, "update", "--apply", "--reload")
    expect(rc == 1 and "another copy" in out, "other copy: %s" % out[-300:], probs)


def s_modified_and_foreign(b, probs):
    A = b.src("A")
    installed(b, A)
    a_build = b.man()["tree"]["buildId"]
    B = b.src("B", mutate=REV)
    p = os.path.join(b.tree, "services", "Media.qml")
    open(p, "a").write("// mine\n")
    mine = sha_file(p)
    rc, out = b.run(B, "update", "--apply", "--restart")
    expect(rc == 1 and "--replace-modified" in out, "modified not refused: %s" % out[-300:], probs)
    rc, out = b.run(B, "update", "--apply", "--restart", "--replace-modified")
    expect(rc == 0, "replace-modified: %s" % out[-400:], probs)
    copies = b.man()["update"]["copies"]
    expect(copies and sha_file(os.path.join(b.state, copies[0]["kept"])) == mine, "copy of the change missing", probs)
    prev = b.man()["previous"]
    expect(sha_file(os.path.join(b.state, prev["rel"], "services", "Media.qml")) == mine, "previous lost the change",
           probs)
    rc, out = b.run(B, "update", "--rollback", "--restart")
    expect(rc == 0 and sha_file(p) == mine, "rollback didn't bring back exactly what was there: %s" % out[-300:], probs)
    m = b.man()
    expect(m["files"]["services/Media.qml"][0] != mine, "the manifest now claims the user's file", probs)
    # un archivo ajeno en el árbol: siempre se niega
    open(os.path.join(b.tree, "notes.txt"), "w").write("mine\n")
    rc, out = b.run(B, "update", "--apply", "--restart", "--replace-modified")
    expect(rc == 1 and "notes.txt" in out, "foreign file not refused: %s" % out[-300:], probs)


def s_versions_and_api(b, probs):
    A = b.src("A", version="0.4.0")
    installed(b, A)
    B = b.src("B", version="0.6.0", min_from="0.5.0", mutate=REV)
    rc, out = b.run(B, "update", "--apply", "--reload")
    expect(rc == 1 and "intermediate release" in out, "minUpdateFrom: %s" % out[-300:], probs)
    C = b.src("C", version="0.5.0", mutate=REV)
    vp = os.path.join(C, "sumi", "version.json")
    v = json.load(open(vp)); v["apiVersion"] = 2
    open(vp, "w").write(json.dumps(v))
    rc, out = b.run(C, "update", "--apply", "--reload")
    expect(rc == 1 and "--accept-api 2" in out, "api change: %s" % out[-300:], probs)
    D = b.src("D", version="0.3.9", mutate=REV)
    rc, out = b.run(D, "update", "--apply", "--reload")
    expect(rc == 1 and "--downgrade" in out, "downgrade: %s" % out[-300:], probs)
    def unit_change(tree):
        p = os.path.join(tree, "systemd", "sumi-shell.service")
        open(p, "a").write("# changed\n")
    E = b.src("E", version="0.4.1", mutate=unit_change)
    rc, out = b.run(E, "update", "--apply", "--reload")
    expect(rc == 1 and "changes the systemd units" in out, "unit change: %s" % out[-300:], probs)


def s_prerelease_versions(b, probs):
    """SemVer 2.0.0 (2026-11-07): prereleases en version.json/minUpdateFrom con la precedencia de semver.org; antes el
    actualizador sólo aceptaba X.Y.Z y se negaba con 0.5.0-beta.1 («no valid version»)."""
    A = b.src("A", version="0.4.0")
    installed(b, A, units=False, start="exec")
    b.shell("stop-all")
    B = b.src("B", version="0.5.0-alpha.1", min_from="0.4.0", mutate=REV)
    rc, out = b.run(B, "update", "--apply")
    expect(rc == 0 and "installed-unverified" in out, "0.4.0 → 0.5.0-alpha.1: %s" % out[-400:], probs)
    expect(b.man()["tree"]["version"] == "0.5.0-alpha.1", "installed version: %s" % b.man()["tree"].get("version"), probs)
    b.shell("start")
    rc, out = b.run(B, "update", "--verify")
    expect(rc == 0 and b.man()["update"]["state"] == "verified", "verify alpha.1: %s" % out[-300:], probs)
    b.shell("stop-all")
    C = b.src("C", version="0.4.0", min_from="0.4.0", mutate=REV)
    rc, out = b.run(C, "update", "--apply")
    expect(rc == 1 and "--downgrade" in out, "0.4.0 after 0.5.0-alpha.1 must be a downgrade: %s" % out[-300:], probs)
    D = b.src("D", version="0.5.0-alpha.3", min_from="0.5.0-alpha.2", mutate=REV)
    rc, out = b.run(D, "update", "--apply")
    expect(rc == 1 and "intermediate release" in out, "minUpdateFrom alpha.2 over alpha.1: %s" % out[-300:], probs)
    E = b.src("E", version="0.5.0-beta.10", min_from="0.5.0-alpha.1", mutate=REV)
    rc, out = b.run(E, "update", "--apply")
    expect(rc == 0 and "installed-unverified" in out, "alpha.1 → beta.10: %s" % out[-400:], probs)
    b.shell("start")
    rc, out = b.run(E, "update", "--verify")
    expect(rc == 0 and b.man()["update"]["state"] == "verified", "verify beta.10: %s" % out[-300:], probs)
    b.shell("stop-all")
    F = b.src("F", version="0.5.0-beta.2", min_from="0.5.0-alpha.1", mutate=REV)
    rc, out = b.run(F, "update", "--apply")
    expect(rc == 1 and "--downgrade" in out, "beta.2 after beta.10 (numeric order) must be a downgrade: %s" % out[-300:],
           probs)
    G = b.src("G", version="0.5", min_from="0.4.0", mutate=REV)
    rc, out = b.run(G, "update", "--apply")
    expect(rc == 1 and "no valid version" in out, "invalid version: %s" % out[-300:], probs)
    H = b.src("H", version="0.5.0", min_from="0.5.0-beta.10", mutate=REV)
    rc, out = b.run(H, "update", "--apply")
    expect(rc == 0 and "installed-unverified" in out, "beta.10 → 0.5.0 (final over its prereleases): %s" % out[-400:],
           probs)


def s_two_updates_previous(b, probs):
    """A → B → C: sólo una generación conservada (B); la de A se retira por sha al verificar C. Desinstalar retira la
    conservada y deja el HOME como estaba (salvo las copias, que se dicen)."""
    A = b.src("A")
    before = snapshot(b.h)
    installed(b, A)
    B = b.src("B", mutate=REV)
    C = b.src("C", mutate=touch_qml("services/Clip.qml", "    // third"))
    rc, out = b.run(B, "update", "--apply", "--reload")
    b_build = b.man()["tree"]["buildId"]
    first = b.man()["previous"]["rel"]
    rc, out = b.run(C, "update", "--apply", "--reload")
    m = b.man()
    expect(rc == 0 and m["previous"]["build"] == b_build, "the kept generation isn't B: %s" % out[-300:], probs)
    expect(not os.path.exists(os.path.join(b.state, first)), "the older generation wasn't retired", probs)
    expect(len(os.listdir(os.path.join(b.state, "sumi-shell", "install", "previous"))) == 1, "more than one kept",
           probs)
    b.shell("stop-all")
    rc, out = b.run(C, "uninstall")
    expect(rc == 0, "uninstall: %s" % out[-400:], probs)
    left = diff_snap(before, snapshot(b.h))
    expect(left == [], "HOME not back after uninstall: %s" % left[:6], probs)


def s_no_units_offline(b, probs):
    """An exec-once shell must be stopped; the offline build is verified later."""
    A = b.src("A")
    installed(b, A, units=False, start="exec")
    old = b.man()["tree"]["buildId"]
    B = b.src("B", mutate=REV)
    rc, out = b.run(B, "update", "--apply", "--reload")
    expect(rc == 1 and "stop the shell while unlocked" in out, "running direct update: %s" % out[-400:], probs)
    expect(b.man()["tree"]["buildId"] == old, "refused update changed the tree", probs)
    b.shell("stop-all")
    rc, out = b.run(B, "update", "--apply")
    expect(rc == 0 and "installed-unverified" in out, "offline update: %s" % out[-400:], probs)
    new = b.man()["tree"]["buildId"]
    expect(new != old, "offline update did not change the build", probs)
    b.shell("start")
    rc, out = b.run(B, "update", "--verify")
    expect(rc == 0 and b.man()["update"]["state"] == "verified", "verify after start: %s" % out[-400:], probs)
    b.shell("stop-all")
    rc, out = b.run(B, "update", "--rollback")
    expect(rc == 0 and b.man()["tree"]["buildId"] == old, "offline rollback: %s" % out[-400:], probs)


# ---- manifiestos de otras versiones -----------------------------------------------------------------------------------

def s_format2_converted(b, probs):
    """Un manifiesto de F6e (formato 2, sin `tree`) se convierte al escribir, con su anotación; la construcción en
    ejecución no se conoce → frío obligatorio."""
    A = b.src("A")
    installed(b, A)
    m = b.man()
    m["formatVersion"] = 2
    for k in ("tree", "formatHistory"):
        m.pop(k, None)
    body = {k: v for k, v in m.items() if k != "bodySha256"}
    m["bodySha256"] = hashlib.sha256(json.dumps(body, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    open(b.man_path, "w").write(json.dumps(m, indent=1, sort_keys=True) + "\n")
    os.unlink(os.path.join(b.tree, "build.json"))                          # el árbol de antes no tenía construcción
    m = b.man(); m["files"].pop("build.json", None)
    body = {k: v for k, v in m.items() if k != "bodySha256"}
    m["bodySha256"] = hashlib.sha256(json.dumps(body, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    open(b.man_path, "w").write(json.dumps(m, indent=1, sort_keys=True) + "\n")
    b.shell("stop-all"); b.shell("unit-start")
    B = b.src("B", mutate=REV)
    rc, out = b.run(B, "update")
    expect("format 2" in out and "needs: --restart" in out and "isn't known" in out, "format 2 preview: %s" % out[-500:],
           probs)
    rc, out = b.run(B, "update", "--apply", "--restart")
    m = b.man()
    expect(rc == 0 and m["formatVersion"] == 3 and m["formatHistory"][-1]["from"] == 2, "conversion: %s" % out[-300:],
           probs)
    expect(m["previous"]["build"] is None, "unknown build invented", probs)
    rc, out = b.run(B, "update", "--rollback", "--restart")
    expect(rc == 0, "rollback to a build-less tree: %s" % out[-300:], probs)
    coherent(b, probs, None, None, "rolled-back")


def s_old_installers_refuse_format_3(b, probs):
    """El instalador de F6e (4ed6786, git) ante un manifiesto formato 3: se niega sin tocar nada (status y uninstall)."""
    old = os.path.join(b.tmp, "old")
    os.makedirs(old)
    # Es historial de este repositorio (7d99a78 en dotfiles, antes de separarlo el 2026-11-23); su árbol se llama
    # kitasan/ (antes del cambio de nombre, 2026-11-07). Se extrae bajo quickshell/ como siempre.
    ar = subprocess.run(["git", "-C", ROOT, "archive", "--prefix=quickshell/", F6E_REV, "install.sh", "packaging",
                         "kitasan", "api"], capture_output=True, timeout=60)
    if ar.returncode != 0:
        probs.append("git archive %s failed: %s" % (F6E_REV[:7], ar.stderr[-200:]))
        return
    subprocess.run(["tar", "-x", "-C", old], input=ar.stdout, check=True)
    oldsrc = os.path.join(old, "quickshell")
    A = b.src("A")
    installed(b, A)
    b.shell("stop-all")
    before = snapshot(b.h)
    # Desde el cambio de nombre, el instalador de antes ni siquiera VE esta instalación (otro árbol, otro manifiesto: Kitasan-
    # Shell). Lo que se garantiza: su status/uninstall no tocan nada de Sumi Shell. Su `install` instalaría un Kitasan-Shell
    # aparte (riesgo residual: `install.sh check` lo señala como former.copy / former.running); no se ejecuta aquí.
    for args in (("status",), ("uninstall",)):
        rc, out = b.run(oldsrc, *args)
        expect("sumi" not in out.lower() or "unknown format" in out, "F6e %s: rc %d %s" % (args[0], rc, out[-300:]), probs)
    expect(diff_snap(before, snapshot(b.h)) == [], "the old installer changed the HOME", probs)


# ---- migraciones F1 -------------------------------------------------------------------------------------------------

def s_migrations(b, probs):
    A = b.src("A")
    installed(b, A, units=False, start=None)
    hypr = os.path.join(b.cfg, "hypr")
    os.makedirs(hypr)
    open(os.path.join(hypr, ".current-wallpaper"), "w").write("/home/x/a.png\n")
    open(os.path.join(hypr, ".current-wallpaper-outputs"), "w").write("DP-1=/home/x/b.png\n")
    mat = os.path.join(b.cfg, "matugen")
    os.makedirs(mat)
    for n, v in (("scheme", "scheme-tonal-spot\n"), ("mode", "dark\n")):
        open(os.path.join(mat, n), "w").write(v)
    legacy = snapshot(b.h, skip=(".local",))
    rc, out = b.run(A, "migrate")
    expect(rc == 0 and re.search(r"wallpaper-state-v1\s+pending", out) and re.search(r"theme-state-v1\s+pending", out)
           and "settings-schema" in out, "listing: %s" % out, probs)
    b.shell("start")
    rc, out = b.run(A, "migrate", "wallpaper-state-v1", "--apply")
    expect(rc == 1 and "stop it first" in out, "running shell not refused: %s" % out[-200:], probs)
    b.shell("stop-all")
    # corte entre publicar y registrar (F1 no lo recuperaba): parcial → se completa
    rc, out = b.run(A, "migrate", "wallpaper-state-v1", "--apply",
                    extra={"SUMI_INSTALL_FAULT": "migrate-current-wallpaper-outputs:before:SIGKILL"})
    rc, out = b.run(A, "migrate")
    expect(re.search(r"wallpaper-state-v1\s+partial", out), "partial not recognised: %s" % out, probs)
    rc, out = b.run(A, "migrate", "wallpaper-state-v1", "--apply")
    expect(rc == 0 and "completed an interrupted import" in out, "complete partial: %s" % out[-300:], probs)
    st = os.path.join(b.state, "sumi-shell")
    rec = json.load(open(os.path.join(st, "wallpaper-migration-v1.json")))
    expect(rec["version"] == 1 and rec["files"]["current-wallpaper"]["present"], "record format", probs)
    expect(open(os.path.join(st, "current-wallpaper-outputs")).read() == "DP-1=/home/x/b.png\n", "content", probs)
    rc, out = b.run(A, "migrate", "wallpaper-state-v1", "--apply")
    expect(rc == 0 and "already imported" in out, "done twice: %s" % out[-200:], probs)
    # conflicto: estado del tema que no viene de lo legado
    th = os.path.join(st, "theme")
    os.makedirs(th)
    open(os.path.join(th, "mode"), "w").write("light\n")
    rc, out = b.run(A, "migrate", "theme-state-v1", "--apply")
    expect(rc == 1 and "conflict" in out, "conflict not refused: %s" % out[-300:], probs)
    expect(open(os.path.join(th, "mode")).read() == "light\n", "conflicting state touched", probs)
    os.unlink(os.path.join(th, "mode"))
    rc, out = b.run(A, "migrate", "theme-state-v1", "--apply")
    expect(rc == 0, "theme import: %s" % out[-300:], probs)
    # deshacer: sólo sin cambios desde la importación
    rc, out = b.run(A, "migrate", "theme-state-v1", "--revert")
    expect(rc == 0 and not os.path.exists(os.path.join(th, "scheme")) and not os.path.exists(
        os.path.join(th, "theme-migration-v1.json")), "revert: %s" % out[-300:], probs)
    rc, out = b.run(A, "migrate", "theme-state-v1", "--apply")
    open(os.path.join(th, "mode"), "w").write("light\n")
    rc, out = b.run(A, "migrate", "theme-state-v1", "--revert")
    expect(rc == 1 and "yours now" in out and os.path.exists(os.path.join(th, "scheme")), "revert with changes: %s" %
           out[-300:], probs)
    expect(snapshot(b.h, skip=(".local",)) == legacy, "legacy files were touched", probs)
    # Antes del cambio de nombre (2026-11-07) se comprobaba aquí que la herramienta HISTÓRICA de F1
    # (Quickshell/tools/f1/migrate-wallpaper-state.py) reconocía el registro. Esa herramienta escribe el estado del nombre de
    # antes (…/kitasan-shell): ya no comparte directorio con `install.sh migrate`, así que la comparación no aplica.
    print("    (skipped: F1's historical tool works on the former name's state, not comparable after the rename)")
    # update nunca migra: con theme-state-v1 otra vez pendiente, la vista previa lo dice y --apply no lo toca
    open(os.path.join(th, "mode"), "w").write("dark\n")          # vuelve a ser lo importado: se puede deshacer
    rc, out = b.run(A, "migrate", "theme-state-v1", "--revert")
    expect(rc == 0, "revert again: %s" % out[-200:], probs)
    keep = lambda: {k: v for k, v in snapshot(b.h).items() if not k.startswith((".config/quickshell",
                                                                               ".local/state/sumi-shell/install"))}
    before = keep()
    B = b.src("B", mutate=REV)
    rc, out = b.run(B, "update")
    expect("theme-state-v1 is pending" in out and "never runs it" in out, "preview: %s" % out[-300:], probs)
    rc, out = b.run(B, "update", "--apply")
    expect(rc == 0 and "installed-unverified" in out, "update: %s" % out[-300:], probs)
    expect(diff_snap(before, keep()) == [], "update touched migration state: %s" % diff_snap(before, keep())[:4], probs)


def s_settings_old_load_fails(b, probs):
    """La vuelta atrás no puede restaurar ajustes mientras siga vivo el código nuevo."""
    A = b.src("A", settings_schema=3)
    b.write_settings(3)
    installed(b, A)
    B = b.src("B", settings_schema=4, extra={".kt-noshow": "x\n"})
    b.set(failReloadSchema=3)
    rc, out = b.run(B, "update", "--apply", "--reload", "--accept-settings-migration")
    s = b.man()["update"]["settings"]
    expect(rc != 0, "failed rollback reported success", probs)
    expect(s.get("state") != "restored" and not s.get("displaced"),
           "settings were restored before the old code loaded: %s" % out[-500:], probs)
    d = json.load(open(b.settings))
    expect(d["schemaVersion"] == 4 and len(d.get("migrations", [])) == 1,
           "new code reconverted restored settings: %s" % d, probs)
    expect(b.man()["transaction"] is not None, "failed old load lost its recovery record", probs)
    b.set(failReloadSchema=None)
    rc, out = b.run(B, "recover", "--apply", "--reload")
    expect(rc == 0, "recover old load: %s" % out[-500:], probs)
    expect(json.load(open(b.settings))["schemaVersion"] == 3, "recovery didn't restore old settings", probs)
    want = b.man()["tree"]["buildId"]
    coherent(b, probs, want, want, "rolled-back")


def s_lock_during_rollback(b, probs, mode="reload"):
    """Bloqueo después del intercambio inverso: no recargar; recover tras desbloquear."""
    A = b.src("A")
    installed(b, A)
    a_build = tree_build(b)
    B = b.src("B", mutate=REV)
    rc, out = b.run(B, "update", "--apply", "--reload")
    expect(rc == 0, "setup update failed: %s" % out[-300:], probs)
    sh = b.sh(); sh["lockCalls"] = 0
    json.dump(sh, open(os.path.join(b.fix, "shell.json"), "w"))
    b.set(lockOnNth=3)
    calls = len(b.calls())
    rc, out = b.run(B, "update", "--rollback", "--" + mode)
    expect(rc != 0, "rollback reported success while locking: %s" % out[-300:], probs)
    expect(not any(c[0] == "qs" and c[-1] == "reload" for c in b.calls()[calls:]),
           "rollback reloaded a locked shell", probs)
    expect(not any(c[0] == "systemctl" and any(x in c for x in ("restart", "start", "reset-failed"))
                   for c in b.calls()[calls:]), "rollback restarted a locked shell", probs)
    expect(b.man()["transaction"] is not None, "no recoverable transaction", probs)
    open(os.path.join(b.fix, "unlocked"), "w").close()
    rc, out = b.run(B, "recover", "--apply", "--reload")
    expect(rc == 0, "recover: %s" % out[-500:], probs)
    coherent(b, probs, a_build, a_build, "rolled-back")


def s_lock_during_automatic_rollback(b, probs, nth=5, no_shell=False):
    A = b.src("A", settings_schema=3)
    b.write_settings(3)
    installed(b, A)
    a_build = tree_build(b)
    B = b.src("B", settings_schema=4, extra={".kt-noshow": "x\n"})
    b.set(lockOnNth=nth)
    rc, out = b.run(B, "update", "--apply", "--reload", "--accept-settings-migration")
    expect(rc != 0 and b.man()["transaction"] is not None, "rollback didn't pause: %s" % out[-500:], probs)
    calls = [c for c in b.calls() if c[0] == "qs" and c[-1] == "reload"]
    expect(len(calls) == 1, "rollback reloaded while locked: %s" % calls, probs)
    expect(json.load(open(b.settings))["schemaVersion"] == 4, "settings restored before unlock", probs)
    open(os.path.join(b.fix, "unlocked"), "w").close()
    if no_shell:
        b.shell("stop-all")
    rc, out = b.run(B, "recover", "--apply", *([] if no_shell else ["--reload"]))
    expect(rc == 0, "recover automatic rollback: %s" % out[-500:], probs)
    coherent(b, probs, a_build, False if no_shell else a_build, "installed-unverified" if no_shell else "rolled-back")
    expect(json.load(open(b.settings))["schemaVersion"] == 3, "recovery didn't restore old settings", probs)


def s_interrupt_keep(b, probs, fault="keep:after:SIGKILL", running=True, prior=False):
    """Corte después de conservar el árbol anterior, antes de registrar el paso."""
    A = b.src("A")
    installed(b, A, start="unit" if running else None)
    if prior:
        intermediate = b.src("intermediate", version="0.4.1")
        rc, out = b.run(intermediate, "update", "--apply", "--reload")
        expect(rc == 0, "prior update: %s" % out[-300:], probs)
    a_build = tree_build(b)
    B = b.src("B", mutate=REV)
    flags = ["--reload"] if running else []
    rc, out = b.run(B, "update", "--apply", "--downgrade", *flags,
                    extra={"SUMI_INSTALL_FAULT": fault})
    expect(rc != 0 and b.man()["transaction"], "fault didn't fire", probs)
    rc, out = b.run(B, "recover", "--apply", *flags)
    expect(rc == 0, "recover after keep: %s" % out[-700:], probs)
    if rc == 0:
        want = tree_build(b)
        coherent(b, probs, want, want if running else False, "verified" if running else "installed-unverified")
        rc, out = b.run(B, "update", "--rollback", *flags)
        expect(rc == 0, "rollback after recovered keep: %s" % out[-500:], probs)
        coherent(b, probs, a_build, a_build if running else False, "rolled-back" if running else "installed-unverified")


CASES = [
    ("settings-old-load-fails", s_settings_old_load_fails),
    ("lock-during-rollback", s_lock_during_rollback),
    ("lock-during-rollback-restart", lambda b, p: s_lock_during_rollback(b, p, mode="restart")),
    ("lock-before-auto-rollback", s_lock_during_automatic_rollback),
    ("lock-after-auto-rollback-swap", lambda b, p: s_lock_during_automatic_rollback(b, p, nth=6)),
    ("lock-auto-rollback-no-shell", lambda b, p: s_lock_during_automatic_rollback(b, p, nth=6, no_shell=True)),
    ("interrupt-keep", s_interrupt_keep),
    ("interrupt-keep-before-move", lambda b, p: s_interrupt_keep(b, p, "keep-move:before:SIGKILL")),
    ("interrupt-keep-after-move", lambda b, p: s_interrupt_keep(b, p, "keep-move:after:SIGKILL")),
    ("interrupt-keep-no-shell", lambda b, p: s_interrupt_keep(b, p, "keep-move:after:SIGKILL", running=False)),
    ("interrupt-keep-older-previous", lambda b, p: s_interrupt_keep(b, p, "keep-move:after:SIGKILL", prior=True)),
    ("reload-compatible", s_reload_compatible),
    ("catalog-added-by-update", s_catalog_added_by_update),
    ("reload-incompatible", s_reload_incompatible),
    ("restart-new-pid", s_restart_new_pid),
    ("restart-budget", s_restart_budget),
    ("same-version-two-builds", s_same_version_two_builds),
    ("load-failure-keeps-old", s_load_failure_keeps_old),
    ("crash-on-reload", s_crash_on_reload),
    ("slow-ipc-after-reload", s_slow_ipc_after_reload),
    ("load-ok-check-fails", s_load_ok_check_fails),
    ("static-checks", s_static_checks),
    ("settings-migration-then-failure", s_settings_migration_then_failure),
    ("settings-concurrent-edit", s_settings_concurrent_edit),
    ("rollback-incompatible-settings", s_rollback_incompatible_settings),
    ("settings-newer-refused", s_settings_newer_refused),
    ("lock-during-update", s_lock_during_update),
    ("lock-then-session-restart", s_lock_then_session_restart),
    ("lock-then-rollback", s_lock_then_rollback),
    ("interrupt-then-session-restart", s_interrupt_then_session_restart),
    ("interrupt-no-shell", s_interrupt_no_shell),
    ("install-without-instance", s_install_without_instance),
    ("verify-mismatch-then-rollback", s_verify_mismatch_then_rollback),
    ("other-copy-refused", s_other_copy_refused),
    ("modified-and-foreign", s_modified_and_foreign),
    ("versions-and-api", s_versions_and_api),
    ("prerelease-versions", s_prerelease_versions),
    ("two-updates-previous", s_two_updates_previous),
    ("no-units-offline", s_no_units_offline),
    ("format2-converted", s_format2_converted),
    ("old-installers-refuse-format-3", s_old_installers_refuse_format_3),
    ("migrations-f1", s_migrations),
]


def main():
    want = sys.argv[1:]
    fails = 0
    for name, fn in CASES:
        if want and name not in want:
            continue
        b = Bench()
        probs = []
        t = time.monotonic()
        try:
            fn(b, probs)
        except Exception as e:
            import traceback
            probs.append("exception: %s: %s\n%s" % (type(e).__name__, e, traceback.format_exc()[-800:]))
        dt = time.monotonic() - t
        if probs:
            fails += 1
            print("%-36s FAIL (%.0f s)" % (name, dt))
            for p in probs:
                print("    " + p.replace("\n", "\n    "))
        else:
            print("%-36s PASS (%.0f s)" % (name, dt))
        if os.environ.get("KT_KEEP") and probs:
            print("    kept: " + b.tmp)
        else:
            b.close()
    print("failed: %d" % fails)
    return fails


if __name__ == "__main__":
    sys.exit(main())
