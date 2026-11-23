#!/usr/bin/env python3
"""Sumi Shell — `install.sh check` against fixtures (portabilidad F6c, 2026-10-13).

Uso: python3 -B tests/install/check-test.py            (desde la raíz del repo: install.sh y sumi/ al lado)

Cada escenario arma un entorno AISLADO en un directorio temporal: HOME, XDG_*, XDG_RUNTIME_DIR, un /proc falso
(KT_CAPS_PROC_DIR), servicios D-Bus (KT_CHECK_DBUS_DIRS), pilas PAM (SUMI_PAM_DIRS), módulos QML (QML_IMPORT_PATH,
sin qtpaths: KT_CHECK_QTPATHS vacío) y un PATH con sólo lo imprescindible más un programa FALSO que hace de qs, hyprctl,
Hyprland, systemctl, busctl y fc-list (y, si el escenario lo pide, de find o python3) y responde según el escenario.
El árbol que se comprueba es el de este repositorio, sin copiarlo; nada de la sesión real interviene.

En todos: el código de salida esperado, los hallazgos esperados (id → nivel) y que el comprobador NO escribió: el
árbol igual por sha, el HOME del escenario igual, sin __pycache__, y ninguna orden mutante en lo que anotó el falso.
Salida: una línea por escenario; código = escenarios fallidos.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TREE = os.path.join(ROOT, "sumi")
INSTALL = os.path.join(ROOT, "install.sh")
ESSENTIAL = ["bash", "sh", "python3", "dirname", "env", "find", "stat", "timeout", "true", "false", "cat", "ls",
             "readlink", "basename", "grep", "sed", "sort", "head", "tail", "tr", "awk", "uname"]
FAKE_NAMES = ["qs", "hyprctl", "Hyprland", "systemctl", "busctl", "fc-list"]
SIG = "kt6c_fixture_signature"
READ_ONLY = {"systemctl": {"show", "show-environment", "is-active", "list-unit-files"},
             "busctl": {"NameHasOwner", "GetConnectionUnixProcessID", "ListNames", "ListActivatableNames", "ListInhibitors"}}

FAKE = r'''#!@PYTHON@
import json, os, sys
name = os.path.basename(sys.argv[0]); a = sys.argv[1:]
fix = os.environ["KT_FIX"]; spec = json.load(open(os.path.join(fix, "spec.json")))
open(os.path.join(fix, "argv.log"), "a").write(json.dumps([name] + a) + "\n")
def out(s, rc=0):
    sys.stdout.write(s); sys.exit(rc)
if name == "qs":
    q = spec.get("qs") or {}
    if a[:1] == ["--version"]:
        out("Quickshell %s (revision , distributed by fixture)\n" % q.get("version", "0.3.2"))
    if a[:1] == ["--help"]:
        out("qs [OPTIONS]\n" + ("  -n, --no-duplicate  Exit immediately if …\n" if q.get("noDup", True) else ""))
    if a[:3] == ["ipc", "call", "--help"]:
        out("Call an IpcHandler function.\n", 0 if q.get("ipc", True) else 109)
    if a[:1] == ["list"]:
        inst = q.get("instances", [])
        out((json.dumps(inst) if inst else "No running instances.") + "\n")
    out("", 1)
if name == "hyprctl":
    h = spec.get("hypr") or {}
    if not h.get("session"):
        out("", 1)
    if a == ["-j", "version"]:
        out(json.dumps({"version": h.get("version", "0.56.2"), "tag": "v" + h.get("version", "0.56.2")}))
    if a[:3] == ["-j", "getoption", "misc:allow_session_lock_restore"]:
        out(json.dumps({"option": a[2], "bool": h.get("restore", True), "set": True}))
    if a[:1] == ["eval"]:
        out("ok\n")
    if a == ["-j", "plugin", "list"]:
        out("[]")
    out("{}", 0)
if name == "Hyprland":
    h = spec.get("hypr") or {}
    out("Hyprland %s built from fixture\n" % h.get("binVersion", h.get("version", "0.56.2")))
if name == "fc-list":
    if a and a[0].startswith("--format="):
        out("IosevkaTerm Nerd Font Propo,Noto Sans,Noto Sans Mono,Inter\te000-10ffff\n" if spec.get("font", True) else "")
    out(("%s\n" % a[0]) if spec.get("font", True) else "")
if name == "timeout":
    out("", 127)
if name == "find":
    if "-printf" in a:
        out("find: unknown predicate `-printf'\n", 1)
    os.execv("/usr/bin/find", ["find"] + a)
if name == "python3":
    if a[:1] == ["-c"] and "sys.exit" in a[1]:
        sys.exit(1)
    out("3.9.2\n")
if name == "systemctl":
    s = spec.get("systemd") or {}
    units = s.get("units", {})
    if a[:2] == ["--user", "show-environment"]:
        out("".join("%s=%s\n" % kv for kv in s.get("env", {}).items()))
    if a[:2] == ["--user", "is-active"]:
        st = s.get("active", {}).get(a[2], "inactive")
        out(st + "\n", 0 if st == "active" else 3)
    if a[:2] == ["--user", "list-unit-files"]:
        out("".join("%s enabled enabled\n" % u for u in s.get("enabled", [])))
    if a[:2] == ["--user", "show"]:
        if a[2] == "-p":                       # capabilities.py: varias unidades, un bloque cada una
            res = []
            for u in a[4:]:
                p = units.get(u, {})
                res.append("Id=%s\nLoadState=%s\nActiveState=%s\nUnitFileState=%s\n" % (
                    u, p.get("LoadState", "not-found"), p.get("ActiveState", "inactive"), p.get("UnitFileState", "")))
            out("\n".join(res))
        u = a[2]; p = units.get(u, {"LoadState": "not-found"})
        keys = [a[i + 1] for i in range(3, len(a) - 1) if a[i] == "-p"]
        out("".join("%s=%s\n" % (k, p.get(k, "")) for k in keys))
    out("", 1)
if name == "busctl":
    b = spec.get("bus") or {}
    if "NameHasOwner" in a:
        out("b %s\n" % ("true" if b.get("notifOwner") else "false"))
    if "GetConnectionUnixProcessID" in a:
        out("u %d\n" % b.get("notifOwner", 0))
    if "--user" in a and "ListActivatableNames" in a:
        if b.get("failActivatable"):
            out("Failed to connect to bus\n", 1)
        out(json.dumps({"type": "as", "data": [["org.freedesktop.Notifications"] if b.get("activatable") else []]}))
    if "--user" in a and "ListNames" in a:
        out(json.dumps({"type": "as", "data": [[] if b.get("noManager") else ["org.freedesktop.systemd1"]]}))
    if "ListNames" in a or "ListActivatableNames" in a:
        out(json.dumps({"type": "as", "data": [b.get("system", ["org.freedesktop.DBus", "org.freedesktop.login1"])]}))
    if "ListInhibitors" in a:
        out(json.dumps({"type": "a(ssssuu)", "data": [[]]}))
    out("", 1)
out("", 1)
'''


def sha_tree(path):
    h = hashlib.sha256()
    for folder, dirs, files in sorted(os.walk(path)):
        dirs.sort()
        for n in sorted(files):
            p = os.path.join(folder, n)
            h.update(p.encode())
            with open(p, "rb") as f:
                h.update(f.read())
    return h.hexdigest()


def listing(path):
    res = {}
    for folder, dirs, files in os.walk(path):
        for n in files:
            p = os.path.join(folder, n)
            st = os.lstat(p)
            res[p] = (st.st_size, st.st_mtime_ns)
    return res


def required_modules():
    import importlib.util
    spec = importlib.util.spec_from_file_location("sumi_check", os.path.join(ROOT, "packaging", "check.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return sorted(m.qml_requirements.required_modules(TREE))


MODULES = required_modules()


def copy_stub(path, version="0.4.0"):
    """Una copia de mentira: shell.qml, version.json y los tres auxiliares de las unidades, ejecutables."""
    os.makedirs(os.path.join(path, "scripts"), exist_ok=True)
    open(os.path.join(path, "shell.qml"), "w").write("// fixture\n")
    if version:
        json.dump({"version": version, "apiVersion": 1}, open(os.path.join(path, "version.json"), "w"))
    for s in ("session-check", "wait-for-hyprland", "sumi-lock"):
        p = os.path.join(path, "scripts", s)
        open(p, "w").write("#!/bin/sh\nexit 0\n")
        os.chmod(p, 0o755)


def unit_text(copy, fakebin, session_check=True, exec_ok=True):
    sc = os.path.join(copy, "scripts", "session-check" if exec_ok else "gone-session-check")
    return ("[Unit]\nOnFailure=sumi-lock-rescue.service\n[Service]\n" +
            ("ExecCondition=%s\n" % sc if session_check else "") +
            "ExecStartPre=%s/scripts/wait-for-hyprland\nExecStart=%s/qs -c sumi --no-duplicate\n"
            "ExecStopPost=-%s/scripts/sumi-lock rescue-request\n" % (copy, fakebin, copy))


def scenario(name, expect_exit, expect, s=None, forbid_levels=None, **opts):
    """expect: {id: level}; forbid_levels: niveles que NO pueden aparecer (el escenario positivo)."""
    s = dict(s or {})
    tmp = tempfile.mkdtemp(prefix="kt6c-")
    try:
        D = {k: os.path.join(tmp, k) for k in ("h", "state", "data", "cache", "run", "etcxdg", "proc", "dbus", "pam",
                                               "qml", "fake", "shim", "fix")}
        for d in D.values():
            os.makedirs(d)
        os.chmod(D["run"], 0o700)
        cfg = os.path.join(D["h"], ".config")
        user_copy = os.path.join(cfg, "quickshell", "sumi")
        sys_copy = os.path.join(D["etcxdg"], "quickshell", "sumi")
        if opts.get("user_copy", True):
            copy_stub(user_copy)
        if opts.get("sys_copy"):
            copy_stub(sys_copy)
        if opts.get("user_default"):
            os.makedirs(os.path.join(cfg, "quickshell"), exist_ok=True)
            open(os.path.join(cfg, "quickshell", "shell.qml"), "w").write("// another shell\n")
        # módulos QML: todos los que importa el árbol, menos los que el escenario quita
        for mod in MODULES:
            if mod in opts.get("drop_modules", ()):
                continue
            d = os.path.join(D["qml"], *mod.split("."))
            os.makedirs(d, exist_ok=True)
            open(os.path.join(d, "qmldir"), "w").write("module %s\n" % mod)
        if opts.get("pam", True):
            open(os.path.join(D["pam"], "login"), "w").write("auth required pam_unix.so\naccount required pam_unix.so\n")
        # la shell que corre (pid 4242) y los procesos del escenario
        running = opts.get("running", ["user"] if opts.get("user_copy", True) else [])
        paths = {"user": user_copy, "system": sys_copy}
        s.setdefault("qs", {})["instances"] = [{"config_path": os.path.join(paths[r], "shell.qml"), "pid": 4242 + i,
                                                "shell_id": "x", "id": "x"} for i, r in enumerate(running)]
        procs = {4242 + i: ("qs", "qs -c sumi") for i in range(len(running))}
        procs.update(opts.get("procs", {}))
        for pid, (comm, cmd) in procs.items():
            pd = os.path.join(D["proc"], str(pid))
            os.makedirs(pd)
            open(os.path.join(pd, "comm"), "w").write(comm + "\n")
            open(os.path.join(pd, "cmdline"), "wb").write(cmd.replace(" ", "\0").encode() + b"\0")
        if opts.get("notif_owner_running", True) and running:
            s.setdefault("bus", {}).setdefault("notifOwner", 4242)
        # ajustes de la shell
        st = opts.get("settings", {"notificationServer": True, "polkitAgent": True})
        if st is not None:
            os.makedirs(os.path.join(cfg, "sumi-shell"))
            json.dump({"schemaVersion": 4, "shell": {"integrations": st}},
                      open(os.path.join(cfg, "sumi-shell", "settings.json"), "w"))
        s.setdefault("bus", {}).setdefault("activatable", bool(opts.get("activation", ["sumi"])))
        for f in opts.get("activation", ["sumi"]):
            body = ("[D-BUS Service]\nName=org.freedesktop.Notifications\nExec=/bin/false\nSystemdService=sumi-shell.service\n"
                    if f == "sumi" else "[D-BUS Service]\nName=org.freedesktop.Notifications\nExec=/usr/bin/dunst\n")
            open(os.path.join(D["dbus"], "org.freedesktop.Notifications.%s.service" % f), "w").write(body)
        # unidades
        if opts.get("units", True):
            ud = os.path.join(cfg, "systemd", "user")
            os.makedirs(ud)
            open(os.path.join(ud, "sumi-shell.service"), "w").write(
                unit_text(user_copy, D["fake"], opts.get("session_check", True), opts.get("exec_ok", True)))
            units = {"sumi-shell.service": {"LoadState": "loaded", "UnitFileState": "enabled", "ActiveState": "active",
                                               "FragmentPath": os.path.join(ud, "sumi-shell.service"),
                                               "OnFailure": "sumi-lock-rescue.service", "MainPID": "4242"}}
            if opts.get("rescue", True):
                open(os.path.join(ud, "sumi-lock-rescue.service"), "w").write(
                    "[Service]\nExecCondition=%s/scripts/session-check --rescue\nExecStart=%s/scripts/sumi-lock rescue\n"
                    % (user_copy, user_copy))
                units["sumi-lock-rescue.service"] = {"LoadState": "loaded", "UnitFileState": "static",
                                                        "FragmentPath": os.path.join(ud, "sumi-lock-rescue.service")}
            s.setdefault("systemd", {}).setdefault("units", units)
        s.setdefault("systemd", {}).setdefault("env", {"WAYLAND_DISPLAY": "wayland-1", "HYPRLAND_INSTANCE_SIGNATURE": SIG})
        s["systemd"].setdefault("active", {"graphical-session.target": "active"})
        s.setdefault("hypr", {"session": True, "version": "0.56.2", "restore": True})
        for rel, body in opts.get("state_files", {}).items():
            p = os.path.join(D["state"], rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, "w").write(body)
        for rel, body in opts.get("files", {}).items():
            p = os.path.join(D["h"], rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, "w").write(body)
        json.dump(s, open(os.path.join(D["fix"], "spec.json"), "w"))
        # PATH: el falso delante y lo imprescindible real; nada más
        fake = os.path.join(D["fix"], "fake.py")
        open(fake, "w").write(FAKE.replace("@PYTHON@", os.path.realpath(sys.executable)))
        os.chmod(fake, 0o755)
        names = FAKE_NAMES + opts.get("fake_also", [])
        for n in names:
            if n not in opts.get("absent", ()):
                os.symlink(fake, os.path.join(D["fake"], n))
        for n in ESSENTIAL:
            if n in names or n in opts.get("absent", ()):
                continue
            real = shutil.which(n)
            if real:
                os.symlink(real, os.path.join(D["shim"], n))
        env = {"HOME": D["h"], "XDG_CONFIG_HOME": cfg, "XDG_STATE_HOME": D["state"], "XDG_DATA_HOME": D["data"],
               "XDG_CACHE_HOME": D["cache"], "XDG_RUNTIME_DIR": D["run"], "XDG_CONFIG_DIRS": D["etcxdg"],
               "XDG_DATA_DIRS": os.path.join(tmp, "nodata"), "PATH": D["fake"] + ":" + D["shim"], "KT_FIX": D["fix"],
               "KT_CAPS_PROC_DIR": D["proc"], "KT_CHECK_DBUS_DIRS": D["dbus"], "SUMI_PAM_DIRS": D["pam"],
               "KT_CHECK_QTPATHS": "", "LANG": "C.UTF-8"}
        if opts.get("qml_path", True):
            env["QML_IMPORT_PATH"] = D["qml"]
        if s["hypr"].get("session"):
            env["HYPRLAND_INSTANCE_SIGNATURE"] = SIG
            env["WAYLAND_DISPLAY"] = "wayland-1"
        env.update(opts.get("env", {}))
        home_before, tree_before = listing(D["h"]), sha_tree(TREE)
        args = opts.get("args", ["check", "--json"])
        p = subprocess.run(["/usr/bin/env", "bash", INSTALL] + args, capture_output=True, text=True, env=env, timeout=120,
                           cwd=tmp)
        problems = []
        if p.returncode != expect_exit:
            problems.append("exit %d (want %d)" % (p.returncode, expect_exit))
        found = {}
        if "--json" in args and p.returncode in (0, 1):
            try:
                doc = json.loads(p.stdout)
                for f in doc["findings"]:
                    found.setdefault(f["id"], set()).add(f["level"])
                if doc["exit"] != p.returncode:
                    problems.append("json exit %s ≠ %d" % (doc["exit"], p.returncode))
            except (ValueError, KeyError) as e:
                problems.append("bad json: %s · %s" % (e, (p.stdout + p.stderr)[-300:]))
        for fid, level in expect.items():
            if level not in found.get(fid, set()):
                problems.append("missing %s %s (got %s)" % (level, fid, sorted(found.get(fid, [])) or "nothing"))
        for level in forbid_levels or ():
            bad = sorted(k for k, v in found.items() if level in v)
            if bad:
                problems.append("unexpected %s: %s" % (level, ", ".join(bad)))
        # sólo lectura
        if listing(D["h"]) != home_before:
            problems.append("HOME changed")
        if sha_tree(TREE) != tree_before:
            problems.append("tree changed")
        log = os.path.join(D["fix"], "argv.log")
        for line in (open(log).read().splitlines() if os.path.exists(log) else []):
            argv = json.loads(line)
            allowed = READ_ONLY.get(argv[0])
            if allowed is not None and not (set(argv[1:]) & allowed):
                problems.append("non read-only call: " + " ".join(argv))
        if opts.get("stderr_has") and opts["stderr_has"] not in p.stderr:
            problems.append("stderr lacks %r: %s" % (opts["stderr_has"], p.stderr[-200:]))
        return problems
    finally:
        shutil.rmtree(tmp)


HCONF, HLUA = ".config/hypr/hyprland.conf", ".config/hypr/hyprland.lua"
CONF_BODY = "general {\n    gaps_in = 3\n}\n"

CASES = [
    # (nombre, salida, {id: nivel}, spec, niveles prohibidos, opciones)
    ("healthy session (user copy, units, notifications and polkit by the shell)", 0,
     {"quickshell.version": "info", "modules.found": "info", "install.resolved": "info", "units.shell": "info",
      "notifications.owner": "info"}, None, ("error", "warning"), {}),
    ("Quickshell missing", 1, {"quickshell.missing": "error"}, None, None, {"absent": ["qs"]}),
    ("Quickshell older than tested (a warning, not incompatible)", 0, {"quickshell.version": "warning"},
     {"qs": {"version": "0.3.0"}}, None, {}),
    ("Quickshell without `qs ipc call`", 1, {"quickshell.capabilities": "error"}, {"qs": {"ipc": False}}, None, {}),
    ("Quickshell newer than tested", 0, {"quickshell.version": "warning"}, {"qs": {"version": "0.4.0"}}, None, {}),
    ("a required QML module is missing", 1, {"modules.missing": "error"}, None, None,
     {"drop_modules": ["Quickshell.Services.Pipewire"]}),
    ("only QtMultimedia missing (optional)", 0, {"modules.optional": "warning"}, None, None,
     {"drop_modules": ["QtMultimedia"]}),
    ("no QML module path known", 0, {"modules.unknown": "warning"}, None, None, {"qml_path": False}),
    ("Quickshell's modules not where Qt looks (not a confirmed absence)", 0, {"modules.unknown": "warning"}, None,
     ("error",), {"drop_modules": ["Quickshell"]}),
    ("find without -printf (not GNU)", 0, {"tools.gnu": "warning"}, None, None, {"fake_also": ["find"]}),
    ("timeout doesn't work (the lock helper needs it)", 1, {"tools.timeout": "error"}, None, None,
     {"fake_also": ["timeout"]}),
    ("outside Hyprland and Hyprland not installed", 1, {"hyprland.missing": "error", "hyprland.session": "info"},
     {"hypr": {"session": False}}, None, {"absent": ["Hyprland", "hyprctl"]}),
    ("outside Hyprland, installed", 0, {"hyprland.session": "info", "hyprland.version": "info"},
     {"hypr": {"session": False}}, None, {}),
    ("Hyprland older than tested", 0, {"hyprland.version": "warning"},
     {"hypr": {"session": True, "version": "0.54.0", "restore": True}}, None, {}),
    # Hyprland 0.57 sólo lee Lua (2026-10-30): avisar si la config sigue en hyprland.conf; nada si es Lua o ≤ 0.56
    ("Hyprland 0.57 with only hyprland.conf", 0, {"hyprland.config-lua": "warning"},
     {"hypr": {"session": True, "version": "0.57.0", "restore": True}}, ("error",), {"files": {HCONF: CONF_BODY}}),
    ("Hyprland 0.57: generated hyprland.lua beside hyprland.conf", 0, {"hyprland.config-lua": "warning"},
     {"hypr": {"session": True, "version": "0.57.0", "restore": True}}, ("error",),
     {"files": {HCONF: CONF_BODY, HLUA: "-- AUTOGENERATED HYPRLAND CONFIG.\nhl.config({ autogenerated = true })\n"}}),
    ("Hyprland 0.56 running, 0.57 installed, hyprland.conf", 0, {"hyprland.config-lua": "warning"},
     {"hypr": {"session": True, "version": "0.56.2", "binVersion": "0.57.0", "restore": True}}, ("error",),
     {"files": {HCONF: CONF_BODY}}),
    ("Hyprland 0.57 outside the session, hyprland.conf", 0, {"hyprland.config-lua": "warning"},
     {"hypr": {"session": False, "version": "0.57.0"}}, ("error",), {"files": {HCONF: CONF_BODY}}),
    ("Hyprland 0.57 with hyprland.lua (an old hyprland.conf beside it)", 0, {"hyprland.version": "info"},
     {"hypr": {"session": True, "version": "0.57.0", "restore": True}}, ("error", "warning"),
     {"files": {HCONF: CONF_BODY, HLUA: "hl.config({ general = { gaps_in = 3 } })\n"}}),
    ("Hyprland 0.56 with hyprland.conf", 0, {"hyprland.version": "info"},
     {"hypr": {"session": True, "version": "0.56.2", "restore": True}}, ("error", "warning"), {"files": {HCONF: CONF_BODY}}),
    ("allow_session_lock_restore off", 0, {"hyprland.lock-restore": "warning"},
     {"hypr": {"session": True, "version": "0.56.2", "restore": False}}, None, {}),
    ("a default config hides the only (user) copy", 1, {"install.hidden": "error"}, None, None,
     {"user_default": True, "running": []}),
    ("a default config would hide a user install", 0, {"install.default-config": "warning", "install.copy": "info"},
     None, None, {"user_copy": False, "sys_copy": True, "user_default": True, "running": ["system"], "units": False}),
    ("user copy added while the system copy runs", 0, {"install.unreachable": "warning"}, None, None,
     {"sys_copy": True, "running": ["system"]}),
    ("two shells at once", 0, {"install.multiple": "warning"}, None, None,
     {"sys_copy": True, "running": ["system", "user"]}),
    ("nothing installed, nothing running", 0, {"install.none": "info", "units.none": "info"}, None, None,
     {"user_copy": False, "running": [], "units": False, "activation": [], "settings": None,
      "procs": {77: ("hyprpolkitagent", "/usr/lib/hyprpolkitagent")}}),
    ("confirmed absent user manager", 0, {"units.no-systemd": "info", "login1.python-dbus": "info"},
     {"bus": {"noManager": True}}, None, {}),
    ("unit runs a helper that doesn't exist", 1, {"units.exec-missing": "error"}, None, None, {"exec_ok": False}),
    ("older unit without the session check", 0, {"units.outdated": "warning"}, None, None, {"session_check": False}),
    ("rescue unit missing", 1, {"units.no-rescue": "error"}, None, None, {"rescue": False}),
    ("manager lacks this Hyprland's environment", 1, {"units.env": "error"},
     {"systemd": {"env": {"WAYLAND_DISPLAY": "wayland-1"}}}, None, {}),
    ("graphical-session.target inactive", 0, {"units.target": "warning"},
     {"systemd": {"active": {"graphical-session.target": "inactive"}}}, None, {}),
    ("another notification server holds the name", 1, {"notifications.conflict": "error"},
     {"bus": {"notifOwner": 777}}, None, {"procs": {777: ("dunst", "/usr/bin/dunst")}, "notif_owner_running": False}),
    ("activation points at the shell, server off", 1, {"notifications.stale-activation": "error"}, {"bus": {}}, None,
     {"settings": {"notificationServer": False, "polkitAgent": True}, "notif_owner_running": False}),
    ("activation file the bus hasn't loaded", 0, {"notifications.stale-activation": "warning"},
     {"bus": {"activatable": False}}, None,
     {"settings": {"notificationServer": False, "polkitAgent": True}, "notif_owner_running": False}),
    ("bus doesn't answer ListActivatableNames", 0, {"notifications.unverified": "info"},
     {"bus": {"failActivatable": True}}, None,
     {"settings": {"notificationServer": False, "polkitAgent": True}, "activation": [], "notif_owner_running": False}),
    ("no notification server at all", 0, {"notifications.none": "warning"}, {"bus": {}}, None,
     {"settings": {"notificationServer": False, "polkitAgent": True}, "activation": [], "notif_owner_running": False}),
    ("another polkit agent seems to be running", 0, {"polkit.conflict": "warning"}, None, None,
     {"procs": {88: ("polkit-gnome-au", "/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1")}}),
    ("another polkit agent enabled as a unit", 0, {"polkit.unit": "warning"}, {"systemd": {"enabled": ["polkit-agent.service"]}},
     None, {}),
    ("no polkit agent", 0, {"polkit.none": "warning"}, None, None,
     {"settings": {"notificationServer": True, "polkitAgent": False}}),
    ("legacy wallpaper and theme not migrated", 0, {"legacy.wallpaper": "warning", "legacy.theme": "warning"}, None, None,
     {"files": {".config/hypr/.current-wallpaper": "/x.png", ".config/matugen/scheme": "scheme-vibrant"}}),
    ("legacy state migrated", 0, {"legacy.wallpaper": "info", "legacy.theme": "info"}, None, None,
     {"files": {".config/hypr/.current-wallpaper": "/x.png", ".config/matugen/scheme": "scheme-vibrant"},
      "state_files": {"sumi-shell/wallpaper-migration-v1.json": "{}",
                      "sumi-shell/theme/theme-migration-v1.json": "{}"}}),
    ("font missing (starts, icons empty)", 0, {"caps.ui.font": "warning"}, {"font": False}, None, {}),
    ("PAM service missing", 1, {"caps.lock.pam": "error"}, None, None, {"pam": False}),
    ("relative XDG path and HYPRLAND_NO_SD_VARS", 0, {"env.relative": "warning", "env.no-sd-vars": "warning"}, None, None,
     {"env": {"XDG_CACHE_HOME": "relative/cache", "HYPRLAND_NO_SD_VARS": "1"}}),
    ("python3 missing (bash reports it)", 1, {"python.missing": "error"}, None, None, {"absent": ["python3"]}),
    ("python3 too old (bash reports it)", 1, {"python.missing": "error"}, None, None, {"fake_also": ["python3"]}),
    ("checker failure: unknown option", 2, {}, None, None, {"args": ["check", "--bogus"]}),
    ("a verb that doesn't exist", 2, {}, None, None, {"args": ["upgrade"], "stderr_has": "Usage:"}),
]


def main():
    fails = 0
    for name, code, expect, spec, forbid, opts in CASES:
        try:
            probs = scenario(name, code, expect, spec, forbid, **opts)
        except Exception as e:
            probs = ["harness: %s: %s" % (type(e).__name__, e)]
        fails += 1 if probs else 0
        print("%-72s %s%s" % (name, "PASS" if not probs else "FAIL", ("  " + "; ".join(probs)) if probs else ""))
    leftovers = [d for d, _, _ in os.walk(ROOT) if os.path.basename(d) == "__pycache__"]
    if leftovers:
        fails += 1
        print("__pycache__ left in the repo: %s" % leftovers)
    print("failed: %d of %d" % (fails, len(CASES)))
    return fails


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    sys.exit(main())
