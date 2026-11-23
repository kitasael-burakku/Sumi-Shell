#!/usr/bin/env python3
"""Sumi Shell — `install.sh install/uninstall/recover` en HOMEs temporales (portabilidad F6d, 2026-10-13).

Uso: python3 -B tests/install/installer-test.py [nombre…]       (desde la raíz del repo; sin nombres, todos)

Cada escenario arma un HOME temporal bajo /tmp (con .config, .local/state, .cache), un runtime 0700 propio
(SUMI_INSTALL_RUNTIME_DIR, sólo en modo de prueba), XDG_CONFIG_DIRS/XDG_DATA_DIRS vacíos, un /proc vacío para la
detección de hypridle (o una config de fixture) y un PATH con FALSOS delante: systemctl CON ESTADO (unidades cargadas,
enlaces de enable creados de verdad en el HOME, stop, daemon-reload; `disable` prohibido), qs (`list`) y hyprctl
(`locked`). Nada toca la sesión real. Los fallos se inyectan con SUMI_INSTALL_FAULT (sólo en modo de prueba).

En todos: el código de salida, los mensajes clave y, donde toca, que el HOME vuelve a ser idéntico (ruta, tipo, sha,
modo, destino de enlaces). Salida: una línea por escenario; código = escenarios fallidos.
"""
import hashlib
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
INSTALL = os.path.join(ROOT, "install.sh")
SIG = "kt6d_fixture_signature"

FAKE = r'''#!@PYTHON@
import json, os, re, sys, time
name = os.path.basename(sys.argv[0]); a = sys.argv[1:]
fix = os.environ["KT_FIX"]
open(os.path.join(fix, "argv.log"), "a").write(json.dumps([name] + a) + "\n")
spec = json.load(open(os.path.join(fix, "spec.json")))
def out(s="", rc=0):
    sys.stdout.write(s); sys.exit(rc)
if name == "ldd":
    out("", 0 if a == [os.path.join(os.path.dirname(sys.argv[0]), "hyprlock")] else 1)
if name == "qs":
    if a == ["--help"]:
        out("--no-duplicate\n")
    if a == ["ipc", "call", "--help"]:
        out()
    if a == ["--version"]:
        out("Quickshell 0.3.2\n")
    if a[:1] == ["list"]:
        inst = spec.get("instances", [])
        stf = os.path.join(fix, "systemd.json")
        if spec.get("mainpid") and os.path.exists(stf) and json.load(open(stf))["active"].get("sumi-shell.service") != "active":
            inst = [i for i in inst if i.get("pid") != spec["mainpid"]]
        out((json.dumps(inst) if inst else "No running instances.") + "\n")
    out("", 1)
if name == "hyprctl":
    if a[:1] == ["--instance"]:
        a = a[2:]
    if spec.get("hyprctlDead") and a != ["locked"]:
        out("", 1)
    if a == ["-j", "instances"]:
        out(json.dumps(spec.get("hyprInstances", [])) + "\n")
    if a == ["-j", "binds"]:
        out(json.dumps(spec.get("hyprBinds", [])) + "\n")
    if a == ["-j", "version"] and spec.get("hyprVersion"):
        out(json.dumps({"version": spec["hyprVersion"], "tag": "v" + spec["hyprVersion"]}) + "\n")
    if a[:2] == ["-j", "getoption"]:
        out(json.dumps({"option": a[2], "bool": bool(spec.get("disableAutoreload"))}) + "\n")
    if a == ["eval", "local _ = 0"]:
        out("ok\n" if spec.get("hyprDialect", "lua") == "lua" else "eval is only supported with the lua config manager\n")
    if a == ["configerrors"]:
        out(spec.get("configErrors", "") + "\n")
    if a == ["reload"] and spec.get("reloadFails"):
        out("error: Hyprland couldn't reload (bench)\n", 1)
    if a == ["reload"]:
        # como Hyprland: relee el principal POR SU NOMBRE y lo que incluya; los binds = los del usuario + los del fragmento
        spec["reloads"] = spec.get("reloads", 0) + 1
        main = spec.get("hyprMain", "")
        txt = open(main).read() if main and os.path.exists(main) else ""
        binds = list(spec.get("hyprUserBinds", []))
        frag = None
        if re.search(r'^\s*require\("sumi-shell"\)', txt, re.M):
            frag = os.path.join(os.path.dirname(main), "sumi-shell.lua")
        m = re.search(r"^\s*source\s*=\s*(\S*sumi-shell\.conf)\s*$", txt, re.M)
        if m:
            frag = m.group(1)
        mask = {"SHIFT": 1, "CTRL": 4, "ALT": 8, "SUPER": 64}
        if frag and os.path.exists(frag) and not spec.get("reloadBreaks"):
            n = 100
            for line in open(frag):
                lm = re.match(r'hl\.bind\("([^"]+)", hl\.dsp\.global\("([^"]+)"\), \{ description = "([^"]+)" \}\)', line)
                cm = re.match(r"bindd = ([^,]*), ([^,]+), ([^,]+), global, (\S+)", line)
                if lm:
                    parts = [x.strip() for x in lm.group(1).split("+")]
                    n += 1
                    # `__lua` hasta Hyprland 0.56; 0.57 da `HL.Dispatcher(global)` (el banco lo elige con hyprLuaDispatcher)
                    binds.append({"modmask": sum(mask[x] for x in parts[:-1]), "key": parts[-1],
                                  "dispatcher": spec.get("hyprLuaDispatcher", "__lua"),
                                  "arg": str(n), "description": lm.group(3)})
                elif cm:
                    binds.append({"modmask": sum(mask[x] for x in cm.group(1).split()), "key": cm.group(2).strip(),
                                  "dispatcher": "global", "arg": cm.group(4), "description": cm.group(3).strip()})
        spec["hyprBinds"] = binds
        json.dump(spec, open(os.path.join(fix, "spec.json"), "w"))
        out("ok\n")
    if a == ["locked"]:
        locked = spec.get("locked")
        stf = os.path.join(fix, "systemd.json")
        if spec.get("lockAfterStop") and os.path.exists(stf):
            locked = json.load(open(stf))["active"].get("sumi-shell.service") != "active"
        out(("true" if locked else "false") + "\n")
    out("", 1)
if name == "systemctl":
    stf = os.path.join(fix, "systemd.json")
    st = json.load(open(stf)) if os.path.exists(stf) else {"loaded": {}, "active": {}}
    if spec.get("noManager"):
        out("", 1)
    udir = os.path.join(os.environ["XDG_CONFIG_HOME"], "systemd", "user")
    def save():
        json.dump(st, open(stf, "w"))
    if a[:2] == ["--user", "daemon-reload"]:
        st["loaded"] = {n: os.path.join(udir, n) for n in (os.listdir(udir) if os.path.isdir(udir) else [])
                        if n.endswith(".service") and os.path.isfile(os.path.join(udir, n))}
        save(); out()
    if a[:2] == ["--user", "show-environment"]:
        out("WAYLAND_DISPLAY=wayland-1\n")
    if a[:2] == ["--user", "reset-failed"]:
        out()
    if a[:2] == ["--user", "show"]:
        u = a[2]
        keys = [a[i + 1] for i in range(3, len(a) - 1) if a[i] == "-p"]
        frag = st["loaded"].get(u, "")
        wants = any(os.path.islink(os.path.join(udir, d, u)) for d in (os.listdir(udir) if os.path.isdir(udir) else [])
                    if d.endswith(".wants"))
        vals = {"LoadState": "loaded" if frag else "not-found", "FragmentPath": frag,
                "ActiveState": st["active"].get(u, "inactive"), "MainPID": str(spec.get("mainpid", 0)) if st["active"].get(u) == "active" else "0",
                "UnitFileState": ("enabled" if wants else "static") if frag else ""}
        out("".join("%s=%s\n" % (k, vals.get(k, "")) for k in keys))
    if a[:2] == ["--user", "enable"]:
        u = a[2]; frag = st["loaded"].get(u)
        if not frag:
            out("Failed to enable unit: Unit file %s does not exist.\n" % u, 1)
        wanted = [l.split("=", 1)[1].strip() for l in open(frag) if l.startswith("WantedBy=")]
        for w in wanted:
            d = os.path.join(udir, w + ".wants"); os.makedirs(d, exist_ok=True)
            link = os.path.join(d, u)
            if not os.path.islink(link):
                os.symlink(frag, link)
                print("Created symlink '%s' → '%s'." % (link, frag))
        out()
    if a[:2] == ["--user", "restart"]:
        if a[2] == "hypridle.service":
            # el proceso falso «arranca» ahora: su stat en el /proc falso, y el spec para las órdenes siguientes
            start = time.time() + 0.05
            spec["hypridleStart"] = start
            json.dump(spec, open(os.path.join(fix, "spec.json"), "w"))
            proc = os.environ["SUMI_PROC"]
            btime = int([l for l in open(os.path.join(proc, "stat")) if l.startswith("btime")][0].split()[1])
            ticks = int((start - btime) * os.sysconf("SC_CLK_TCK")) + 1
            st = os.path.join(proc, "5151", "stat")
            if os.path.exists(st):
                open(st, "w").write("5151 (hypridle) S %s %d 0 0\n" % (" ".join(["0"] * 18), ticks))
        out()
    if a[:2] == ["--user", "stop"]:
        st["active"][a[2]] = "inactive"; save(); out()
    if a[:2] == ["--user", "disable"]:
        out("disable is forbidden in the bench\n", 1)
    out("", 1)
out("", 1)
'''


def snapshot(home):
    res = {}
    for folder, dirs, files in os.walk(home):
        for n in sorted(dirs + files):
            p = os.path.join(folder, n)
            st = os.lstat(p)
            rel = os.path.relpath(p, home)
            if stat.S_ISLNK(st.st_mode):
                res[rel] = ("link", os.readlink(p))
            elif stat.S_ISDIR(st.st_mode):
                res[rel] = ("dir", oct(stat.S_IMODE(st.st_mode)))
            else:
                res[rel] = ("file", hashlib.sha256(open(p, "rb").read()).hexdigest(), oct(stat.S_IMODE(st.st_mode)))
    return res


class Bench:
    def __init__(self, spec=None, home_extra=None):
        self.tmp = tempfile.mkdtemp(prefix="kt6d-")
        self.h = os.path.join(self.tmp, "h")
        for d in (".config", ".local/state", ".local/share", ".cache"):
            os.makedirs(os.path.join(self.h, d))
        self.run_dir = os.path.join(self.tmp, "run")
        os.makedirs(self.run_dir, mode=0o700)
        os.chmod(self.run_dir, 0o700)
        self.fix = os.path.join(self.tmp, "fix")
        self.bin = os.path.join(self.tmp, "bin")
        self.proc = os.path.join(self.tmp, "proc")
        for d in (self.fix, self.bin, self.proc, os.path.join(self.tmp, "etcxdg"), os.path.join(self.tmp, "nodata")):
            os.makedirs(d)
        self.spec = dict(spec or {})
        self.save_spec()
        fake = os.path.join(self.fix, "fake.py")
        open(fake, "w").write(FAKE.replace("@PYTHON@", os.path.realpath(sys.executable)))
        os.chmod(fake, 0o755)
        for n in ("systemctl", "qs", "hyprctl"):
            os.symlink(fake, os.path.join(self.bin, n))
        # PATH reducido: lo imprescindible real (sin hyprlock, salvo que el escenario lo pida)
        self.shim = os.path.join(self.tmp, "shim")
        os.makedirs(self.shim)
        for n in ("bash", "sh", "python3", "env", "dirname", "ldd", "timeout", "sleep", "cat", "true", "false", "uname"):
            real = shutil.which(n)
            if real:
                os.symlink(real, os.path.join(self.shim, n))
        if self.spec.get("hyprlock"):
            # No depende de cómo el namespace represente al propietario de los binarios del host.
            locker = os.path.join(self.bin, "hyprlock")
            with open(locker, "w") as f:
                f.write("#!/bin/sh\nexit 0\n")
            os.chmod(locker, 0o755)
            os.symlink(fake, os.path.join(self.bin, "ldd"))
        self.pam = os.path.join(self.tmp, "pam")
        os.makedirs(self.pam)
        if self.spec.get("hyprlockPam", True):
            open(os.path.join(self.pam, "hyprlock"), "w").write("auth required pam_unix.so\n")
        self.cfg = os.path.join(self.h, ".config")
        self.state = os.path.join(self.h, ".local", "state")
        self.units = os.path.join(self.tmp, "units")
        os.makedirs(self.units)
        self.btime = int(time.time()) - 100000
        for rel, body in (home_extra or {}).items():
            p = os.path.join(self.h, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, "w").write(body)

    def set_active(self, on=True, pid=4242):
        """La unidad de la shell activa (en el systemctl falso) y la instancia de qs que corre desde el árbol."""
        stf = os.path.join(self.fix, "systemd.json")
        st = json.load(open(stf)) if os.path.exists(stf) else {"loaded": {}, "active": {}}
        st["active"]["sumi-shell.service"] = "active" if on else "inactive"
        json.dump(st, open(stf, "w"))
        self.spec["mainpid"] = pid
        self.spec["instances"] = ([{"config_path": os.path.join(self.cfg, "quickshell", "sumi", "shell.qml"),
                                    "pid": pid, "shell_id": "x", "id": "x"}] if on else [])
        self.save_spec()

    def write(self, rel, body, mode=0o644):
        p = os.path.join(self.h, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write(body)
        os.chmod(p, mode)
        return p

    def save_spec(self):
        json.dump(self.spec, open(os.path.join(self.fix, "spec.json"), "w"))

    def env(self, extra=None):
        e = {"HOME": self.h, "XDG_CONFIG_HOME": self.cfg, "XDG_STATE_HOME": self.state,
             "XDG_CACHE_HOME": os.path.join(self.h, ".cache"), "XDG_DATA_HOME": os.path.join(self.h, ".local", "share"),
             "XDG_CONFIG_DIRS": os.path.join(self.tmp, "etcxdg"), "XDG_DATA_DIRS": os.path.join(self.tmp, "nodata"),
             "XDG_RUNTIME_DIR": self.run_dir, "SUMI_INSTALL_TEST": "1", "SUMI_INSTALL_RUNTIME_DIR": self.run_dir,
             "SUMI_PROC": self.proc, "KT_CAPS_PROC_DIR": self.proc, "KT_FIX": self.fix,
             "HYPRLAND_INSTANCE_SIGNATURE": SIG, "PATH": self.bin + ":" + self.shim, "LANG": "C.UTF-8",
             "SUMI_PAM_DIRS": self.pam}
        e["SUMI_UNIT_DIRS"] = self.units
        self.spec = json.load(open(os.path.join(self.fix, "spec.json")))   # los falsos pueden haberlo cambiado
        self.fake_procs()
        e.update(extra or {})
        return e

    def fake_procs(self):
        """hypridle (y Hyprland) en el /proc falso. Sin `hypridleStart`, hypridle «arrancó» justo antes de cada orden (su
        config cargada = la del disco); con él, arrancó entonces (G1: lo que cambió después no lo cargó)."""
        tck = os.sysconf("SC_CLK_TCK")
        open(os.path.join(self.proc, "stat"), "w").write("cpu 0 0 0 0\nbtime %d\n" % self.btime)
        for pid, comm, on in ((5151, "hypridle", self.spec.get("hypridle")), (6161, "Hyprland", self.spec.get("hyprProc"))):
            d = os.path.join(self.proc, str(pid))
            if not on:
                shutil.rmtree(d, ignore_errors=True)
                continue
            os.makedirs(d, exist_ok=True)
            start = self.spec.get("%sStart" % comm.lower()) or time.time() + 0.05
            ticks = int((start - self.btime) * tck) + 1
            open(os.path.join(d, "comm"), "w").write(comm + "\n")
            open(os.path.join(d, "stat"), "w").write("%d (%s) S %s %d 0 0\n" % (pid, comm, " ".join(["0"] * 18), ticks))
            args = self.spec.get("%sArgs" % comm.lower()) or [comm.lower()]
            open(os.path.join(d, "cmdline"), "wb").write(b"\0".join(a.encode() for a in args) + b"\0")
            env = {"HOME": self.h, "XDG_CONFIG_HOME": self.cfg, "PATH": self.bin + ":" + self.shim}
            open(os.path.join(d, "environ"), "wb").write(b"\0".join(("%s=%s" % kv).encode() for kv in env.items()) + b"\0")
            unit = self.spec.get("%sCgroup" % comm.lower()) or "/user.slice/user-1000.slice/user@1000.service/app.slice/%s.service" % comm.lower()
            open(os.path.join(d, "cgroup"), "w").write("0::%s\n" % unit)
            cwd = os.path.join(d, "cwd")
            if not os.path.lexists(cwd):
                os.symlink(self.h, cwd)

    def run(self, *args, extra=None, timeout=120, wait=True):
        cmd = ["bash", INSTALL] + list(args)
        if not wait:
            return subprocess.Popen(cmd, env=self.env(extra), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True)
        p = subprocess.run(cmd, env=self.env(extra), capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout + p.stderr

    def calls(self):
        log = os.path.join(self.fix, "argv.log")
        return [json.loads(l) for l in open(log)] if os.path.exists(log) else []

    def snap(self):
        return snapshot(self.h)

    def close(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


def diff_snap(a, b):
    keys = sorted(set(a) | set(b))
    return [k for k in keys if a.get(k) != b.get(k)]


# ---- escenarios ------------------------------------------------------------------------------------------------------

def expect(cond, msg, probs):
    if not cond:
        probs.append(msg)


def s_install_basic(b, probs):
    before = b.snap()
    rc, out = b.run("install", "--no-units")
    expect(rc == 0, "install rc %d: %s" % (rc, out[-300:]), probs)
    tree = os.path.join(b.cfg, "quickshell", "sumi")
    expect(os.path.isfile(os.path.join(tree, "shell.qml")), "no shell.qml installed", probs)
    expect(os.path.isfile(os.path.join(tree, ".sumi-install")), "no marker", probs)
    expect(not os.path.exists(os.path.join(tree, "README.md")) and not os.path.exists(os.path.join(tree, "lock-preview.qml")),
           "runtime-excludes not applied", probs)
    src = os.path.join(ROOT, "sumi", "scripts", "sumi-lock")
    expect(os.access(os.path.join(tree, "scripts", "sumi-lock"), os.X_OK) == os.access(src, os.X_OK),
           "exec bit not kept", probs)
    m = json.load(open(os.path.join(b.state, "sumi-shell", "install", "manifest.json")))
    expect(m["status"] == "installed" and m["transaction"] is None, "manifest status %s" % m["status"], probs)
    expect(os.path.exists(os.path.join(b.run_dir, "sumi-install.lock")), "no lock file in the runtime dir", probs)
    b.installed = b.snap()
    b.before = before


def s_install_twice(b, probs):
    s_install_basic(b, probs)
    rc, out = b.run("install", "--no-units")
    expect(rc == 0 and "already installed" in out, "second install: rc %d %s" % (rc, out[-200:]), probs)
    expect(diff_snap(b.installed, b.snap()) == [], "second install changed HOME: %s" % diff_snap(b.installed, b.snap())[:5],
           probs)
    # Lo pedido distinto de lo instalado no se añade en silencio: se niega sin tocar nada
    for extra, word in ((("--no-units", "--enable"), "--enable"), ((), "--no-units")):
        rc, out = b.run("install", *extra)
        expect(rc == 1 and word in out, "install %s over --no-units: rc %d %s" % (" ".join(extra), rc, out[-200:]), probs)
        no_change(b, b.installed, probs, "install %s over --no-units" % " ".join(extra))


def s_install_uninstall(b, probs):
    s_install_basic(b, probs)
    rc, out = b.run("uninstall")
    expect(rc == 0, "uninstall rc %d: %s" % (rc, out[-300:]), probs)
    d = diff_snap(b.before, b.snap())
    expect(d == [], "HOME differs after uninstall: %s" % d[:8], probs)
    rc, out = b.run("uninstall")
    expect(rc == 0 and "nothing to do" in out, "second uninstall: rc %d %s" % (rc, out[-200:]), probs)


TREE_REL = os.path.join(".config", "quickshell", "sumi")
MANIFEST = os.path.join(".local", "state", "sumi-shell", "install", "manifest.json")


def tree(b, *rel):
    return os.path.join(b.cfg, "quickshell", "sumi", *rel)


def no_change(b, ref, probs, what):
    d = diff_snap(ref, b.snap())
    expect(d == [], "%s changed HOME: %s" % (what, d[:6]), probs)


# -- desinstalación -------------------------------------------------------------------------------------------------

def s_modified(b, probs):
    s_install_basic(b, probs)
    f = tree(b, "core", "Ipc.qml")
    open(f, "a").write("// user edit\n")
    rc, out = b.run("uninstall")
    expect(rc == 1 and "changed after installing" in out and "core/Ipc.qml" in out, "1st uninstall: %d %s" % (rc, out[-300:]), probs)
    expect(os.path.exists(f) and os.path.exists(tree(b, ".sumi-install")), "modified file or marker not kept", probs)
    rc, out = b.run("uninstall")
    expect(rc == 1, "2nd uninstall with the file still modified must not succeed: %d" % rc, probs)
    os.remove(f)                                         # el usuario lo aparta
    rc, out = b.run("uninstall")
    expect(rc == 0, "uninstall after moving the file away: %d %s" % (rc, out[-300:]), probs)
    no_change(b, b.before, probs, "the completed uninstall")


def s_restored(b, probs):
    s_install_basic(b, probs)
    f = tree(b, "core", "Ipc.qml")
    orig = open(f).read()
    open(f, "a").write("// user edit\n")
    rc, out = b.run("uninstall")
    expect(rc == 1, "uninstall with a modified file: %d" % rc, probs)
    open(f, "w").write(orig)                             # el usuario lo restaura
    rc, out = b.run("uninstall")
    expect(rc == 0, "uninstall after restoring: %d %s" % (rc, out[-300:]), probs)
    no_change(b, b.before, probs, "uninstall after restoring")


def s_keep_modified(b, probs):
    s_install_basic(b, probs)
    f = tree(b, "core", "Ipc.qml")
    open(f, "a").write("// user edit\n")
    rc, out = b.run("uninstall", "--keep-modified")
    expect(rc == 0 and "now yours" in out and "core/Ipc.qml" in out, "keep-modified: %d %s" % (rc, out[-300:]), probs)
    expect(os.path.exists(f) and not os.path.exists(tree(b, ".sumi-install")), "kept file or marker wrong", probs)
    expect(not os.path.exists(os.path.join(b.h, MANIFEST)), "manifest left", probs)
    snap = b.snap()
    rc, out = b.run("install", "--no-units")
    expect(rc == 1 and "won't be replaced" in out, "install over the kept file must refuse: %d" % rc, probs)
    no_change(b, snap, probs, "the refused install")


def s_added_file(b, probs):
    s_install_basic(b, probs)
    extra = tree(b, "mine.txt")
    open(extra, "w").write("mine\n")
    rc, out = b.run("uninstall")
    expect(rc == 0 and "left in place" in out, "uninstall with an added file: %d %s" % (rc, out[-300:]), probs)
    expect(open(extra).read() == "mine\n", "the user's file was touched", probs)
    expect(sorted(os.listdir(tree(b))) == ["mine.txt"], "more than the user's file left: %s" % os.listdir(tree(b)), probs)


def s_tree_deleted(b, probs):
    s_install_basic(b, probs)
    shutil.rmtree(tree(b))
    rc, out = b.run("uninstall")
    expect(rc == 0, "uninstall after the user deleted the tree: %d %s" % (rc, out[-200:]), probs)
    no_change(b, b.before, probs, "uninstall")


def s_marker_swapped(b, probs):
    s_install_basic(b, probs)
    open(tree(b, ".sumi-install"), "w").write('{"id":"someone else"}\n')
    snap = b.snap()
    rc, out = b.run("uninstall")
    expect(rc == 1 and "marker" in out, "uninstall with another marker: %d %s" % (rc, out[-200:]), probs)
    no_change(b, snap, probs, "the refused uninstall")


def s_marker_missing(b, probs):
    s_install_basic(b, probs)
    os.remove(tree(b, ".sumi-install"))
    snap = b.snap()
    rc, out = b.run("uninstall")
    expect(rc == 1 and "marker" in out, "uninstall without the marker: %d" % rc, probs)
    no_change(b, snap, probs, "the refused uninstall")


# -- manifiesto -----------------------------------------------------------------------------------------------------

def s_manifest_corrupt(b, probs):
    s_install_basic(b, probs)
    m = os.path.join(b.h, MANIFEST)
    data = open(m).read()
    for label, body in (("truncated", data[: len(data) // 2]), ("edited", data.replace('"installed"', '"installing"')),
                        ("version", data.replace('"formatVersion": 3', '"formatVersion": 0'))):
        expect(body != data, "%s: the corruption didn't apply (the bench is stale)" % label, probs)
        open(m, "w").write(body)
        snap = b.snap()
        for verb in (("uninstall",), ("install", "--no-units"), ("recover", "--apply")):
            rc, out = b.run(*verb)
            expect(rc == 1 and "damaged" in out, "%s manifest, %s: %d %s" % (label, verb[0], rc, out[-150:]), probs)
        no_change(b, snap, probs, "operations on a %s manifest" % label)
    open(m, "w").write(data)


def s_manifest_other_root(b, probs):
    s_install_basic(b, probs)
    other = os.path.join(b.h, ".config2")
    os.makedirs(other)
    snap = b.snap()
    rc, out = b.run("uninstall", extra={"XDG_CONFIG_HOME": other})
    expect(rc == 1 and "belongs to another" in out, "manifest of another config root: %d %s" % (rc, out[-200:]), probs)
    no_change(b, snap, probs, "the refused uninstall")


# -- conflictos al instalar -----------------------------------------------------------------------------------------

def refused_install(b, probs, args, needle, what):
    before = b.snap()
    rc, out = b.run("install", *args)
    expect(rc == 1 and needle in out, "%s: %d %s" % (what, rc, out[-250:]), probs)
    no_change(b, before, probs, what)
    expect(not os.path.exists(os.path.join(b.run_dir, "sumi-install.lock")), "%s left a lock file" % what, probs)


def s_foreign_tree(b, probs):
    b.write(".config/quickshell/sumi/shell.qml", "// the user's own copy\n")
    refused_install(b, probs, (), "won't be replaced", "install over a foreign tree")


def s_foreign_unit(b, probs):
    b.write(".config/systemd/user/sumi-shell.service", "[Service]\nExecStart=/bin/true\n")
    refused_install(b, probs, (), "not this installer's", "install over a foreign unit")
    rc, out = b.run("install", "--no-units")
    expect(rc == 0, "--no-units next to a foreign unit: %d %s" % (rc, out[-200:]), probs)
    rc, out = b.run("uninstall")
    expect(rc == 0 and os.path.exists(os.path.join(b.cfg, "systemd", "user", "sumi-shell.service")),
           "the foreign unit must survive uninstall: %d" % rc, probs)


def s_foreign_link(b, probs):
    d = os.path.join(b.cfg, "systemd", "user", "default.target.wants")
    os.makedirs(d)
    os.symlink("/nowhere/sumi-shell.service", os.path.join(d, "sumi-shell.service"))
    refused_install(b, probs, (), "isn't this installer's", "install with a foreign link to the unit")


def s_package_copy(b, probs):
    p = os.path.join(b.tmp, "etcxdg", "quickshell", "sumi")
    os.makedirs(p)
    open(os.path.join(p, "shell.qml"), "w").write("// package\n")
    refused_install(b, probs, ("--no-units",), "system copy", "install next to a system copy")


def s_default_config(b, probs):
    b.write(".config/quickshell/shell.qml", "// another shell\n")
    refused_install(b, probs, ("--no-units",), "default Quickshell config", "install under a default config")


def s_running_other(b, probs):
    b.spec["instances"] = [{"config_path": "/somewhere/else/sumi/shell.qml", "pid": 99, "shell_id": "x", "id": "x"}]
    b.save_spec()
    refused_install(b, probs, ("--no-units",), "is running from", "install while another copy runs")


# -- rutas y enlaces ------------------------------------------------------------------------------------------------

def s_config_outside_home(b, probs):
    out_dir = os.path.join(b.tmp, "outside-config")
    os.makedirs(out_dir)
    before = b.snap()
    rc, out = b.run("install", "--no-units", extra={"XDG_CONFIG_HOME": out_dir})
    expect(rc == 1 and "outside your home" in out, "config outside HOME: %d %s" % (rc, out[-200:]), probs)
    expect(os.listdir(out_dir) == [], "something was written outside HOME", probs)
    no_change(b, before, probs, "the refused install")


def s_quickshell_link(b, probs):
    elsewhere = os.path.join(b.h, "dotfiles", "quickshell")
    os.makedirs(elsewhere)
    os.symlink(elsewhere, os.path.join(b.cfg, "quickshell"))
    refused_install(b, probs, ("--no-units",), "symbolic link", "install through a linked ~/.config/quickshell")
    expect(os.listdir(elsewhere) == [], "something was written through the link", probs)


def s_config_base_link(b, probs):
    real = os.path.join(b.h, "sync", "config")
    os.makedirs(real)
    shutil.rmtree(b.cfg)
    os.symlink(real, b.cfg)
    before = b.snap()
    rc, out = b.run("install", "--no-units")
    expect(rc == 0 and os.path.isfile(os.path.join(real, "quickshell", "sumi", "shell.qml")),
           "install with ~/.config as a link inside HOME: %d %s" % (rc, out[-200:]), probs)
    rc, out = b.run("uninstall")
    expect(rc == 0, "uninstall: %d %s" % (rc, out[-200:]), probs)
    no_change(b, before, probs, "install + uninstall through a linked base")


def s_subdir_swapped(b, probs):
    s_install_basic(b, probs)
    outside = os.path.join(b.tmp, "outside-core")
    shutil.copytree(tree(b, "core"), outside)
    shutil.rmtree(tree(b, "core"))
    os.symlink(outside, tree(b, "core"))                # mismos nombres y sha, fuera
    snap_out = snapshot(outside)
    rc, out = b.run("uninstall")
    expect(rc == 1 and "core" in out, "uninstall with a subdir swapped for a link: %d %s" % (rc, out[-250:]), probs)
    expect(snapshot(outside) == snap_out, "files outside were deleted through the link", probs)
    expect(os.path.islink(tree(b, "core")), "the user's link was removed", probs)


def s_swap_midway(b, probs):
    s_install_basic(b, probs)
    outside = os.path.join(b.tmp, "outside-svc")
    shutil.copytree(tree(b, "services"), outside)
    snap_out = snapshot(outside)
    p = b.run("uninstall", extra={"SUMI_INSTALL_FAULT": "tree:before:SLEEP2"}, wait=False)
    time.sleep(1.0)
    shutil.rmtree(tree(b, "services"))
    os.symlink(outside, tree(b, "services"))            # el cambio llega a mitad de la operación
    outp, _ = p.communicate(timeout=60)
    expect(snapshot(outside) == snap_out, "files outside were deleted after a mid-run swap", probs)
    expect(p.returncode == 1, "uninstall after a mid-run swap must not succeed: %d %s" % (p.returncode, outp[-200:]),
           probs)


# -- interrupciones y recuperación ----------------------------------------------------------------------------------

INSTALL_STEPS = ("dirs", "stage", "rename", "units", "reload", "enable")
UNINSTALL_STEPS = ("stop", "relock", "links", "units", "tree", "marker", "dirs")
SIGNALS = ("SIGINT", "SIGTERM", "SIGKILL")
LOCK_HELPER_FAKES = {"hyprctl": "echo false\n", "logger": "", "systemctl": "", "pgrep": "exit 1\n", "qs": "exit 1\n"}


def setup_lock_chain(b, cmd=None):
    """hypridle (fixture) con el envoltorio real del rice como lock_cmd y before_sleep_cmd."""
    wrapper = os.path.join(b.cfg, "hypr", "scripts", "lock.sh")
    os.makedirs(os.path.dirname(wrapper), exist_ok=True)
    shutil.copy(os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "lock.sh"), wrapper)
    os.chmod(wrapper, 0o755)
    c = cmd or wrapper
    b.write(".config/hypr/hypridle.conf", "general {\n    lock_cmd = %s\n    before_sleep_cmd = %s instant\n}\n" % (c, c))
    return wrapper


def lock_still_works(b, wrapper):
    """El envoltorio, con el estado del HOME tal como esté, acaba en hyprlock (session e instant)."""
    tmp = tempfile.mkdtemp(prefix="kt6d-lock-")
    try:
        log = os.path.join(tmp, "log")
        for n, body in dict(LOCK_HELPER_FAKES, hyprlock='echo "hyprlock $*" >> "%s"\n' % log).items():
            f = os.path.join(tmp, n)
            open(f, "w").write("#!/bin/sh\n" + body)
            os.chmod(f, 0o755)
        env = {"HOME": b.h, "XDG_CONFIG_HOME": b.cfg, "PATH": tmp + ":/usr/bin:/bin"}
        ok = True
        for mode in ("session", "instant"):
            open(log, "w").close()
            subprocess.run(["bash", wrapper, mode], env=env, capture_output=True, timeout=30)
            ok = ok and open(log).read().startswith("hyprlock")
        return ok
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def s_install_interrupted(b, probs):
    for step in INSTALL_STEPS:
        for when in ("before", "after"):
            for sig in SIGNALS:
                c = Bench({"hyprlock": True})
                try:
                    before = c.snap()
                    rc, out = c.run("install", "--enable", extra={"SUMI_INSTALL_FAULT": "%s:%s:%s" % (step, when, sig)})
                    want = -9 if sig == "SIGKILL" else 3
                    tag = "%s:%s:%s" % (step, when, sig)
                    if rc != want:
                        probs.append("%s rc %d (want %d) %s" % (tag, rc, want, out[-120:]))
                        continue
                    rc2, out2 = c.run("install", "--enable")
                    if rc2 != 1 or "pending" not in out2:
                        probs.append("%s: install with a pending one: %d" % (tag, rc2))
                    rc3, out3 = c.run("recover")
                    if rc3 != 3:
                        probs.append("%s: recover (describe) rc %d" % (tag, rc3))
                    rc4, out4 = c.run("recover", "--apply")
                    if rc4 != 0:
                        probs.append("%s: recover --apply rc %d %s" % (tag, rc4, out4[-200:]))
                    d = diff_snap(before, c.snap())
                    if d:
                        probs.append("%s: HOME differs after recover: %s" % (tag, d[:4]))
                    rc5, out5 = c.run("install", "--enable")
                    if rc5 != 0:
                        probs.append("%s: install after recover rc %d" % (tag, rc5))
                finally:
                    c.close()


def s_uninstall_interrupted(b, probs):
    for step in UNINSTALL_STEPS:
        for when in ("before", "after"):
            for sig in SIGNALS:
                c = Bench({"hyprlock": True, "hypridle": True})
                try:
                    before = c.snap()
                    wrapper = setup_lock_chain(c)
                    before = c.snap()
                    rc, out = c.run("install", "--enable")
                    if rc != 0:
                        probs.append("install rc %d %s" % (rc, out[-200:]))
                        continue
                    c.set_active(True)
                    tag = "%s:%s:%s" % (step, when, sig)
                    rc, out = c.run("uninstall", extra={"SUMI_INSTALL_FAULT": "%s:%s:%s" % (step, when, sig)})
                    want = -9 if sig == "SIGKILL" else 3
                    if rc != want:
                        probs.append("%s rc %d (want %d) %s" % (tag, rc, want, out[-150:]))
                        continue
                    if sig == "SIGKILL" and not lock_still_works(c, wrapper):
                        probs.append("%s: the lock chain no longer reaches hyprlock" % tag)
                    rc2, out2 = c.run("recover", "--apply")
                    if rc2 != 0:
                        probs.append("%s: recover --apply rc %d %s" % (tag, rc2, out2[-200:]))
                    d = diff_snap(before, c.snap())
                    if d:
                        probs.append("%s: HOME differs after recover: %s" % (tag, d[:4]))
                    if not lock_still_works(c, wrapper):
                        probs.append("%s: no lock after the completed uninstall" % tag)
                    if any(x[0] == "systemctl" and "disable" in x for x in c.calls()):
                        probs.append("%s: disable called" % tag)
                finally:
                    c.close()


def s_relogin(b, probs):
    """Interrumpida; se cierra la sesión (el runtime, con su cerrojo, desaparece) y se recupera en la siguiente."""
    before = b.snap()
    rc, out = b.run("install", "--enable", extra={"SUMI_INSTALL_FAULT": "units:after:SIGKILL"})
    expect(rc == -9, "faulted install rc %d" % rc, probs)
    shutil.rmtree(b.run_dir)
    os.makedirs(b.run_dir, mode=0o700)
    os.chmod(b.run_dir, 0o700)
    rc, out = b.run("recover", "--apply")
    expect(rc == 0, "recover after a new login: %d %s" % (rc, out[-200:]), probs)
    no_change(b, before, probs, "install interrupted + new login + recover")
    rc, out = b.run("install", "--enable")
    expect(rc == 0, "install again: %d" % rc, probs)
    b.set_active(True)
    rc, out = b.run("uninstall", extra={"SUMI_INSTALL_FAULT": "tree:after:SIGKILL"})
    expect(rc == -9, "faulted uninstall rc %d" % rc, probs)
    shutil.rmtree(b.run_dir)
    os.makedirs(b.run_dir, mode=0o700)
    rc, out = b.run("uninstall")
    expect(rc == 0, "uninstall (finishing) after a new login: %d %s" % (rc, out[-200:]), probs)
    no_change(b, before, probs, "uninstall interrupted + new login + uninstall")


def s_concurrent(b, probs):
    before = b.snap()
    a = b.run("install", "--no-units", extra={"SUMI_INSTALL_FAULT": "stage:before:SLEEP3"}, wait=False)
    time.sleep(1.2)
    rc, out = b.run("install", "--no-units")
    expect(rc == 1 and "another install.sh is running" in out, "second concurrent install: %d %s" % (rc, out[-200:]), probs)
    rc, out = b.run("uninstall")
    expect(rc == 1, "concurrent uninstall must not run: %d %s" % (rc, out[-200:]), probs)
    outa, _ = a.communicate(timeout=60)
    expect(a.returncode == 0, "the first install: %d %s" % (a.returncode, outa[-200:]), probs)
    rc, out = b.run("status")
    expect(rc == 0 and "status installed" in out, "manifest after the race: %d %s" % (rc, out[-200:]), probs)
    expect(os.path.exists(os.path.join(b.run_dir, "sumi-install.lock")), "the lock file was deleted", probs)
    rc, out = b.run("uninstall")
    expect(rc == 0, "uninstall: %d" % rc, probs)
    no_change(b, before, probs, "race + uninstall")


# -- systemd, Lock y D-Bus ------------------------------------------------------------------------------------------

def s_units_cycle(b, probs):
    before = b.snap()
    rc, out = b.run("install", "--enable")
    expect(rc == 0, "install --enable: %d %s" % (rc, out[-200:]), probs)
    link = os.path.join(b.cfg, "systemd", "user", "graphical-session.target.wants", "sumi-shell.service")
    expect(os.path.islink(link), "no wants link", probs)
    m = json.load(open(os.path.join(b.h, MANIFEST)))
    expect(m["links"] == {"graphical-session.target.wants/sumi-shell.service": os.readlink(link)},
           "links not recorded: %s" % m["links"], probs)
    b.set_active(True)
    rc, out = b.run("uninstall")
    expect(rc == 0, "uninstall: %d %s" % (rc, out[-300:]), probs)
    verbs = [c[2] for c in b.calls() if c[0] == "systemctl" and len(c) > 2]
    expect("stop" in verbs and "disable" not in verbs, "systemctl verbs: %s" % sorted(set(verbs)), probs)
    no_change(b, before, probs, "install --enable + uninstall")


def s_foreign_link_uninstall(b, probs):
    rc, out = b.run("install", "--enable")
    d = os.path.join(b.cfg, "systemd", "user", "default.target.wants")
    os.makedirs(d)
    os.symlink(os.path.join(b.cfg, "systemd", "user", "sumi-shell.service"), os.path.join(d, "sumi-shell.service"))
    snap = b.snap()
    rc, out = b.run("uninstall")
    expect(rc == 1 and "isn't this installer's" in out, "uninstall with a foreign link: %d %s" % (rc, out[-200:]), probs)
    no_change(b, snap, probs, "the refused uninstall")


def s_locked(b, probs):
    b.run("install", "--enable")
    b.set_active(True)
    b.spec["locked"] = True
    b.save_spec()
    snap = b.snap()
    rc, out = b.run("uninstall")
    expect(rc == 1 and "locked" in out, "uninstall while locked: %d %s" % (rc, out[-200:]), probs)
    no_change(b, snap, probs, "the refused uninstall")
    expect(not any(c[0] == "systemctl" and "stop" in c for c in b.calls()), "the shell was stopped while locked", probs)


def s_lock_after_stop(b, probs):
    before = b.snap()
    b.run("install", "--enable")
    b.set_active(True)
    b.spec["lockAfterStop"] = True
    b.save_spec()
    rc, out = b.run("uninstall")
    expect(rc == 1 and "locked while uninstalling" in out, "lock after stop: %d %s" % (rc, out[-300:]), probs)
    for f in (tree(b, "scripts", "sumi-lock"), os.path.join(b.cfg, "systemd", "user", "sumi-lock-rescue.service"),
              tree(b, "shell.qml")):
        expect(os.path.exists(f), "%s was removed although the session locked" % f, probs)
    b.spec["lockAfterStop"] = False
    b.save_spec()
    rc, out = b.run("uninstall")
    expect(rc == 0, "uninstall once unlocked: %d %s" % (rc, out[-300:]), probs)
    no_change(b, before, probs, "the finished uninstall")


def s_lock_unknown(b, probs):
    b.run("install", "--enable")
    b.set_active(True)
    snap = b.snap()
    rc, out = b.run("uninstall", extra={"HYPRLAND_INSTANCE_SIGNATURE": ""})
    expect(rc == 1 and "lock state can't be read" in out, "uninstall without knowing the lock state: %d" % rc, probs)
    no_change(b, snap, probs, "the refused uninstall")


def s_exec_once(b, probs):
    b.run("install", "--no-units")
    b.spec["instances"] = [{"config_path": tree(b, "shell.qml"), "pid": 777, "shell_id": "x", "id": "x"}]
    b.save_spec()
    snap = b.snap()
    rc, out = b.run("uninstall")
    expect(rc == 1 and "outside its unit" in out, "uninstall with an exec-once shell: %d %s" % (rc, out[-200:]), probs)
    no_change(b, snap, probs, "the refused uninstall")


def lock_case(b, probs, what, setup, allowed, needle=""):
    before = b.snap()
    rc, out = b.run("install", "--enable")
    if rc != 0:
        probs.append("%s: install %d %s" % (what, rc, out[-200:]))
        return
    setup()
    b.set_active(True)
    snap = b.snap()
    rc, out = b.run("uninstall")
    if allowed:
        expect(rc == 0, "%s: uninstall should be allowed: %d %s" % (what, rc, out[-300:]), probs)
    else:
        expect(rc == 1 and needle in out, "%s: uninstall should be refused (%r): %d %s" % (what, needle, rc, out[-300:]),
               probs)
        no_change(b, snap, probs, "%s: the refused uninstall" % what)


def s_lock_helper_direct(b, probs):
    lock_case(b, probs, "lock_cmd = the helper", lambda: setup_lock_chain(b, tree(b, "scripts", "sumi-lock")), False,
              "lock helper")


def s_lock_wrapper_ok(b, probs):
    lock_case(b, probs, "the known wrapper + hyprlock", lambda: setup_lock_chain(b), True)


def s_lock_wrapper_no_hyprlock(b, probs):
    lock_case(b, probs, "the wrapper without hyprlock", lambda: setup_lock_chain(b), False, "hyprlock is not installed")


def s_lock_wrapper_no_pam(b, probs):
    lock_case(b, probs, "the wrapper without hyprlock's PAM", lambda: setup_lock_chain(b), False, "PAM")


def s_lock_wrapper_modified(b, probs):
    def setup():
        w = setup_lock_chain(b)
        open(w, "a").write("# local change\n")
    lock_case(b, probs, "a modified wrapper", setup, False, "unrecognised version")


def s_lock_unknown_script(b, probs):
    def setup():
        p = b.write(".local/bin/mylock", "#!/bin/sh\nqs -c sumi ipc call sumi lockNow session || hyprlock\n", 0o755)
        setup_lock_chain(b, p)
    lock_case(b, probs, "an unknown script naming sumi", setup, False, "refers to Sumi Shell")


def s_lock_conf_unreadable(b, probs):
    lock_case(b, probs, "hypridle config unreadable", lambda: None, False, "can't be read")


def s_lock_hypr_bind(b, probs):
    def setup():
        b.write(".config/hypr/hyprland.conf", "bind = SUPER, L, exec, %s session\n" % tree(b, "scripts", "sumi-lock"))
    lock_case(b, probs, "a Hyprland bind to the helper", setup, False, "refers to the shell's lock helper")


def s_lock_hyprlock_only(b, probs):
    lock_case(b, probs, "lock_cmd = hyprlock", lambda: setup_lock_chain(b, "pidof hyprlock || hyprlock"), True)



# -- la cadena del bloqueo en memoria y en disco (F6e: G1–G4, G1-H) ---------------------------------------------------

def stale(b, seconds=60):
    """hypridle arrancó ANTES de los cambios que el escenario haga después (no los cargó)."""
    b.spec["hypridleStart"] = time.time() - seconds
    b.save_spec()


def s_g1_changed_after_start(b, probs):
    """El usuario apuntó hypridle a hyprlock en el archivo, pero hypridle no se reinició: puede seguir con el helper."""
    def setup():
        setup_lock_chain(b, tree(b, "scripts", "sumi-lock"))
        stale(b, 30)
        time.sleep(0.05)
        setup_lock_chain(b, "pidof hyprlock || hyprlock")
    lock_case(b, probs, "G1: changed after hypridle started", setup, False, "started before its configuration last changed")


def s_g1_restarted(b, probs):
    """Lo mismo, pero reiniciado después (su arranque es posterior): se permite."""
    def setup():
        setup_lock_chain(b, tree(b, "scripts", "sumi-lock"))
        setup_lock_chain(b, "pidof hyprlock || hyprlock")
        b.spec.pop("hypridleStart", None)
        b.save_spec()
    lock_case(b, probs, "G1: restarted after the change", setup, True)


def s_g1_included_gone(b, probs):
    """Un `source` cuyo archivo ya no está (el principal no cambió): no se sabe qué cargó → se niega."""
    def setup():
        b.write(".config/hypr/extra.conf", "general {\n    lock_cmd = pidof hyprlock || hyprlock\n}\n")
        b.write(".config/hypr/hypridle.conf", "source = %s\n" % os.path.join(b.cfg, "hypr", "extra.conf"))
        stale(b, 1)
        time.sleep(0.05)
        os.unlink(os.path.join(b.cfg, "hypr", "extra.conf"))
    lock_case(b, probs, "G1: an included file was deleted", setup, False, "names nothing")


def s_g1_alt_path(b, probs):
    """hypridle con -c (ruta alternativa) que apunta al helper; la config por defecto, limpia."""
    def setup():
        alt = b.write(".local/share/myidle/idle.conf", "general {\n    lock_cmd = %s\n}\n" % tree(b, "scripts", "sumi-lock"))
        setup_lock_chain(b, "pidof hyprlock || hyprlock")
        b.spec["hypridleArgs"] = ["hypridle", "-c", alt]
        b.save_spec()
    lock_case(b, probs, "G1: -c to another path", setup, False, "names Sumi Shell")


def s_g1_relative_alt_path(b, probs):
    """-c relativo: se resuelve desde el cwd del proceso (su HOME en el banco)."""
    def setup():
        b.write("idle-rel.conf", "general {\n    lock_cmd = %s\n}\n" % tree(b, "scripts", "sumi-lock"))
        setup_lock_chain(b, "pidof hyprlock || hyprlock")
        b.spec["hypridleArgs"] = ["hypridle", "--config", "idle-rel.conf"]
        b.save_spec()
    lock_case(b, probs, "G1: relative -c", setup, False, "names Sumi Shell")


def s_g2_not_running_default(b, probs):
    """hypridle parado; su config por defecto usa el helper: el próximo arranque fallaría."""
    def setup():
        setup_lock_chain(b, tree(b, "scripts", "sumi-lock"))
        b.spec["hypridle"] = False
        b.save_spec()
    lock_case(b, probs, "G2: not running, default config", setup, False, "next start")


def s_g2_unit_alt(b, probs):
    """hypridle parado; una unidad lo lanza con -c a otra config que usa el helper."""
    def setup():
        alt = b.write(".local/share/myidle/idle.conf", "general {\n    lock_cmd = %s\n}\n" % tree(b, "scripts", "sumi-lock"))
        b.write("../units/hypridle.service", "[Service]\nExecStart=/usr/bin/hypridle -c %s\n" % alt)
        b.spec["hypridle"] = False
        b.save_spec()
    lock_case(b, probs, "G2: unit with -c", setup, False, "next start")


def s_g2_exec_once_alt(b, probs):
    """hypridle parado; Hyprland lo lanza con exec-once y -c a una config que usa el helper."""
    def setup():
        alt = b.write(".local/share/myidle/idle.conf", "general {\n    before_sleep_cmd = %s instant\n}\n" % tree(b, "scripts", "sumi-lock"))
        b.write(".config/hypr/hyprland.conf", "exec-once = hypridle -c %s\n" % alt)
        b.spec["hypridle"] = False
        b.save_spec()
    lock_case(b, probs, "G2: exec-once with -c", setup, False, "next start")


def s_g2_unit_dynamic(b, probs):
    """Una unidad que lanza hypridle con una ruta calculada: no se puede saber qué cargaría."""
    def setup():
        b.write("../units/hypridle.service", "[Service]\nExecStart=/usr/bin/hypridle -c ${IDLE_CONF}\n")
        b.spec["hypridle"] = False
        b.save_spec()
    lock_case(b, probs, "G2: unit with a computed -c", setup, False, "can't be read safely")


def s_g3_nested_scripts(b, probs):
    """lock_cmd → script de HOME → otro script de HOME que llama a la shell."""
    def setup():
        b.write(".local/bin/inner", "#!/bin/sh\nexec qs -c sumi ipc call sumi lockNow session\n", 0o755)
        outer = b.write(".local/bin/outer", "#!/bin/sh\n~/.local/bin/inner || hyprlock\n", 0o755)
        setup_lock_chain(b, outer)
    lock_case(b, probs, "G3: script calling a script", setup, False, "refers to Sumi Shell")


def s_g3_dynamic_script(b, probs):
    def setup():
        p = b.write(".local/bin/dynlock", "#!/bin/sh\nLOCKER=$(cat ~/.locker)\n\"$LOCKER\" session\n", 0o755)
        setup_lock_chain(b, p)
    lock_case(b, probs, "G3: a script that computes what it runs", setup, False, "computes at run time")


def s_g3_variable_cmd(b, probs):
    lock_case(b, probs, "G3: lock_cmd with a shell variable",
              lambda: setup_lock_chain(b, "$MY_LOCKER --now"), False, "shell variables")


def s_g3_binary_in_home(b, probs):
    def setup():
        p = os.path.join(b.h, ".local", "bin", "elflock")
        os.makedirs(os.path.dirname(p), exist_ok=True)
        shutil.copy(shutil.which("true"), p)
        setup_lock_chain(b, p)
    lock_case(b, probs, "G3: a program in HOME", setup, False, "can't be inspected")


def s_g3_sh_c(b, probs):
    lock_case(b, probs, "G3: sh -c around the helper",
              lambda: setup_lock_chain(b, "sh -c '%s session || hyprlock'" % tree(b, "scripts", "sumi-lock")),
              False, "names Sumi Shell")


def s_g3_requester(b, probs):
    """before_sleep_cmd = loginctl lock-session (sólo lo pide) y lock_cmd = hyprlock: se permite."""
    def setup():
        b.write(".config/hypr/hypridle.conf", "general {\n    lock_cmd = pidof hyprlock || hyprlock\n"
                "    before_sleep_cmd = loginctl lock-session\n}\n")
    lock_case(b, probs, "G3: requester before sleep", setup, True)


def s_g4_listener(b, probs):
    """Un listener que lanza el helper directamente al quedar inactivo: bloquea."""
    def setup():
        setup_lock_chain(b, "pidof hyprlock || hyprlock")
        b.write(".config/hypr/hypridle.conf", open(os.path.join(b.cfg, "hypr", "hypridle.conf")).read() +
                "listener {\n    timeout = 300\n    on-timeout = %s session\n}\n" % tree(b, "scripts", "sumi-lock"))
    lock_case(b, probs, "G4: listener on-timeout", setup, False, "on-timeout")


def s_g4_resume_warn(b, probs):
    """on-resume con la shell: no bloquea (no es un bloqueador), pero se avisa."""
    def setup():
        setup_lock_chain(b, "pidof hyprlock || hyprlock")
        b.write(".config/hypr/hypridle.conf", open(os.path.join(b.cfg, "hypr", "hypridle.conf")).read() +
                "listener {\n    timeout = 300\n    on-timeout = loginctl lock-session\n"
                "    on-resume = qs -c sumi ipc call sumi status\n}\n")
    before = b.snap()
    rc, out = b.run("install", "--enable")
    setup()
    b.set_active(True)
    rc, out = b.run("uninstall")
    expect(rc == 0 and "would fail after uninstalling" in out, "G4 on-resume: allowed with a warning: %d %s" % (rc, out[-300:]),
           probs)


def s_gh_exec_bind(b, probs):
    """Hyprland en marcha con un bind exec (acción VISIBLE) al helper, aunque los archivos ya no lo digan: effective."""
    def setup():
        setup_lock_chain(b, "pidof hyprlock || hyprlock")
        b.spec.update(hyprProc=True, hyprInstances=[{"instance": SIG, "time": int(time.time()) - 600, "pid": 6161}],
                      hyprBinds=[{"modmask": 64, "key": "L", "dispatcher": "exec",
                                  "arg": "%s session" % tree(b, "scripts", "sumi-lock")}])
        b.save_spec()
    lock_case(b, probs, "G1-H: effective exec bind", setup, False, "Hyprland key binding")


def s_gh_lua_autoreload_off(b, probs):
    """Binds Lua (acción invisible), autorecarga apagada y un archivo cambiado tras el arranque: unknown."""
    def setup():
        setup_lock_chain(b, "pidof hyprlock || hyprlock")
        b.write(".config/hypr/hyprland.lua", 'hl.bind("SUPER + L", hl.dsp.exec_cmd("hyprlock"))\n')
        b.spec.update(hyprProc=True, disableAutoreload=True,
                      hyprInstances=[{"instance": SIG, "time": int(time.time()) - 600, "pid": 6161}],
                      hyprBinds=[{"modmask": 64, "key": "L", "dispatcher": "__lua", "arg": "5"}])
        b.save_spec()
    lock_case(b, probs, "G1-H: Lua binds, autoreload off, changed", setup, False, "automatic reload is off")


def s_gh_lua_autoreload_on(b, probs):
    def setup():
        setup_lock_chain(b, "pidof hyprlock || hyprlock")
        b.write(".config/hypr/hyprland.lua", 'hl.bind("SUPER + L", hl.dsp.exec_cmd("hyprlock"))\n')
        b.spec.update(hyprProc=True, hyprInstances=[{"instance": SIG, "time": int(time.time()) - 600, "pid": 6161}],
                      hyprBinds=[{"modmask": 64, "key": "L", "dispatcher": "__lua", "arg": "5"}])
        b.save_spec()
    lock_case(b, probs, "G1-H: Lua binds, autoreload on", setup, True)


def s_gh_hyprctl_dead(b, probs):
    def setup():
        setup_lock_chain(b, "pidof hyprlock || hyprlock")
        b.spec.update(hyprProc=True, hyprctlDead=True)
        b.save_spec()
    lock_case(b, probs, "G1-H: Hyprland running, hyprctl silent", setup, False, "doesn't answer")


def s_gh_tty_two_instances(b, probs):
    """Fuera de la sesión (sin firma) y con dos Hyprland: no se sabe cuál es el suyo → se niega y dice qué hacer."""
    b.run("install", "--enable")
    setup_lock_chain(b, "pidof hyprlock || hyprlock")
    b.spec.update(hyprProc=True, hyprInstances=[{"instance": "a_1_1", "time": 1, "pid": 6161},
                                                {"instance": "b_2_2", "time": 2, "pid": 6162}])
    b.save_spec()
    snap = b.snap()
    rc, out = b.run("uninstall", extra={"HYPRLAND_INSTANCE_SIGNATURE": ""})
    expect(rc == 1 and "none is this session's" in out, "two instances from a TTY: %d %s" % (rc, out[-300:]), probs)
    expect(b.snap() == snap, "the refused uninstall changed something", probs)


def s_chain_states_dry_run(b, probs):
    """`uninstall --dry-run` enseña el estado de cada pieza (disk / probable / effective / unknown)."""
    b.run("install", "--enable")
    setup_lock_chain(b, "pidof hyprlock || hyprlock")
    b.spec.update(hyprProc=True, hyprInstances=[{"instance": SIG, "time": int(time.time()) - 600, "pid": 6161}],
                  hyprBinds=[{"modmask": 64, "key": "L", "dispatcher": "exec", "arg": "hyprlock"}])
    b.save_spec()
    b.set_active(True)
    rc, out = b.run("uninstall", "--dry-run")
    for want in ("Lock chain", "hypridle pid 5151", "probable", "next start", "disk", "Hyprland: effective"):
        expect(want in out, "dry-run doesn't say %r: %s" % (want, out[-600:]), probs)


def s_notif_activation(b, probs):
    b.run("install", "--no-units")
    act = b.write(".local/share/dbus-1/services/org.freedesktop.Notifications.service",
                  "[D-BUS Service]\nName=org.freedesktop.Notifications\nExec=/bin/false\nSystemdService=sumi-shell.service\n")
    snap = b.snap()
    rc, out = b.run("uninstall")
    expect(rc == 1 and "notif-server direct-off" in out, "uninstall with an activation to the shell: %d %s" % (rc, out[-250:]),
           probs)
    no_change(b, snap, probs, "the refused uninstall")
    open(act, "w").write("[D-BUS Service]\nName=org.freedesktop.Notifications\nExec=/usr/bin/dunst\n")
    body = open(act).read()
    rc, out = b.run("uninstall")
    expect(rc == 0 and open(act).read() == body, "another server's activation must be kept: %d" % rc, probs)


def s_purge(b, probs):
    rc, out = b.run("install", "--no-units")
    data = {".config/sumi-shell/settings.json": "{}", ".local/state/sumi-shell/notifications.json": "[]",
            ".cache/sumi-shell/x": "x", ".cache/sumi-weather.json": "{}", ".cache/sumi-theme-samples/s": "s"}
    keep = {".cache/sumi-shell-old/z": "z", ".cache/sumi-wallpapers.bak/q": "q",
            ".cache/minimaru-doctor-summary": "d", ".cache/sumi-wallpapers/thumbs/t": "t",
            ".cache/sumi-desktop-mode/m": "m", ".cache/quickshell/qmlcache": "c"}
    for k, v in list(data.items()) + list(keep.items()):
        b.write(k, v)
    rc, out = b.run("uninstall", "--purge")
    expect(rc == 1 and "confirmation" in out, "purge without a terminal must ask: %d %s" % (rc, out[-200:]), probs)
    expect(all(os.path.exists(os.path.join(b.h, k)) for k in data), "data deleted without confirmation", probs)
    rc, out = b.run("uninstall", "--purge", "--yes")
    expect(rc == 0 and "Purged" in out, "purge --yes: %d %s" % (rc, out[-300:]), probs)
    for k in data:
        expect(not os.path.exists(os.path.join(b.h, k)), "%s survived the purge" % k, probs)
    for k in keep:
        expect(os.path.exists(os.path.join(b.h, k)), "%s (not the shell's, or shared) was purged" % k, probs)


def s_purge_link(b, probs):
    outside = os.path.join(b.tmp, "outside-cache")
    os.makedirs(outside)
    open(os.path.join(outside, "keep"), "w").write("k")
    os.symlink(outside, os.path.join(b.h, ".cache", "sumi-shell"))
    b.write(".config/sumi-shell/settings.json", "{}")
    rc, out = b.run("uninstall", "--purge", "--yes")
    expect(rc == 1 and "symbolic link" in out, "purge with a linked data dir: %d %s" % (rc, out[-200:]), probs)
    expect(os.path.exists(os.path.join(outside, "keep")), "the purge followed the link", probs)
    expect(os.path.exists(os.path.join(b.h, ".config/sumi-shell/settings.json")), "partial purge", probs)


def s_fault_guard(b, probs):
    """D7: la inyección de fallos sólo con SUMI_INSTALL_TEST=1 Y un HOME temporal."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("inst", os.path.join(ROOT, "packaging", "installer.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    saved = dict(os.environ)
    try:
        os.environ["HOME"] = b.h
        os.environ.pop("SUMI_INSTALL_TEST", None)
        expect(not m.test_mode(), "test mode without SUMI_INSTALL_TEST", probs)
        os.environ["SUMI_INSTALL_TEST"] = "1"
        expect(m.test_mode(), "no test mode with the variable and a temporary HOME", probs)
        os.environ["HOME"] = os.path.expanduser("~" + __import__("pwd").getpwuid(os.getuid()).pw_name)
        expect(not m.test_mode(), "test mode with a real HOME", probs)
        os.environ["SUMI_INSTALL_FAULT"] = "stage:before:SIGKILL"
        m.fault("stage", "before")                        # tiene que ignorarse (si no, este proceso moriría)
    finally:
        os.environ.clear()
        os.environ.update(saved)


def s_race_tree(b, probs):
    before = b.snap()
    a = b.run("install", "--no-units", extra={"SUMI_INSTALL_FAULT": "rename:before:SLEEP2"}, wait=False)
    time.sleep(1.0)
    foreign = b.write(".config/quickshell/sumi/shell.qml", "// appeared meanwhile\n")
    out, _ = a.communicate(timeout=60)
    expect(a.returncode == 1 and "appeared while installing" in out, "race on the tree: %d %s" % (a.returncode, out[-250:]),
           probs)
    expect(open(foreign).read() == "// appeared meanwhile\n", "the foreign tree was touched", probs)
    left = sorted(os.listdir(os.path.join(b.cfg, "quickshell")))
    expect(left == ["sumi"], "staging or other leftovers: %s" % left, probs)
    expect(not os.path.exists(os.path.join(b.h, MANIFEST)), "manifest left after the undone install", probs)


def s_race_unit(b, probs):
    a = b.run("install", extra={"SUMI_INSTALL_FAULT": "units:before:SLEEP2"}, wait=False)
    time.sleep(1.0)
    foreign = b.write(".config/systemd/user/sumi-lock-rescue.service", "[Service]\nExecStart=/bin/true\n")
    out, _ = a.communicate(timeout=60)
    expect(a.returncode == 1 and "appeared while installing" in out, "race on a unit: %d %s" % (a.returncode, out[-250:]),
           probs)
    expect(open(foreign).read().startswith("[Service]\nExecStart=/bin/true"), "the foreign unit was touched", probs)
    expect(not os.path.exists(tree(b)), "the tree was not undone", probs)
    expect(not os.path.exists(os.path.join(b.cfg, "systemd", "user", "sumi-shell.service")),
           "our own unit was not undone", probs)


def s_no_noreplace(b, probs):
    before = b.snap()
    rc, out = b.run("install", "--no-units", extra={"SUMI_INSTALL_FAULT": "rename:einval"})
    expect(rc == 1 and "RENAME_NOREPLACE" in out, "filesystem without NOREPLACE: %d %s" % (rc, out[-250:]), probs)
    no_change(b, before, probs, "the refused install")



# -- otro proceso cambia un archivo mientras se desinstala (carrera determinista) ---------------------------------------
# El instalador se detiene en un punto de la retirada de shell.qml (SUMI_INSTALL_RACE, sólo en modo prueba) y avisa;
# este proceso hace el cambio y le deja seguir. Puntos: checked (sha comprobado, aún en su sitio), moved (apartado como
# .sumi-rm.shell.qml), verified (sha repetido sobre lo apartado, justo antes de borrar).

USER_BODY = b"// the user's own shell.qml\n"


def race_uninstall(b, point, act, kill=False):
    """Desinstala parando en `point` para shell.qml; `act(path)` es el cambio ajeno. Devuelve (rc, salida)."""
    sync = os.path.join(b.tmp, "race")
    os.mkdir(sync)
    p = b.run("uninstall", extra={"SUMI_INSTALL_RACE": "shell.qml:%s:%s" % (point, sync)}, wait=False)
    end = time.monotonic() + 30
    while not os.path.exists(os.path.join(sync, "ready")):
        if time.monotonic() > end or p.poll() is not None:
            p.kill()
            return -1, "never reached %s: %s" % (point, p.communicate()[0][-300:])
        time.sleep(0.01)
    act(tree(b, "shell.qml"))
    if kill:
        os.kill(p.pid, signal.SIGKILL)       # install.sh hace exec: el pid es el del instalador
    open(os.path.join(sync, "go"), "x").close()
    o, _ = p.communicate(timeout=60)
    return p.returncode, o


def body(path):
    with open(path, "rb") as f:
        return f.read()


def aside_left(b):
    return [os.path.join(d, n) for d, _, fs in os.walk(os.path.join(b.cfg, "quickshell")) for n in fs
            if n.startswith(".sumi-rm.")]


def s_race_combined(b, probs):
    """Caso combinado (pedido al cerrar F6d): el archivo apartado CAMBIA (escritura por un descriptor abierto antes), otro
    proceso crea un archivo nuevo con el nombre original y el instalador muere (SIGKILL) antes de terminar. recover tiene
    que conservar LOS DOS, sin sobrescribir ninguno, y decir dónde está cada uno."""
    s_install_basic(b, probs)
    installed = body(tree(b, "shell.qml"))
    held = open(tree(b, "shell.qml"), "ab")

    def act(path):
        held.write(b"// late write\n")
        held.flush()
        with open(path, "xb") as f:
            f.write(USER_BODY)
    rc, o = race_uninstall(b, "moved", act, kill=True)
    held.close()
    expect(rc == -9, "not killed (rc %d)" % rc, probs)
    aside = tree(b, ".sumi-rm.shell.qml")
    for cmd in (("recover", "--apply"), ("uninstall",), ("recover", "--apply")):
        rc, o = b.run(*cmd)
        expect(rc in (0, 1), "%s rc %d %s" % (" ".join(cmd), rc, o[-200:]), probs)
        expect(body(tree(b, "shell.qml")) == USER_BODY, "%s: the user's new shell.qml changed" % " ".join(cmd), probs)
        expect(os.path.isfile(aside) and body(aside) == installed + b"// late write\n",
               "%s: the modified set-aside file is gone or changed" % " ".join(cmd), probs)
        if rc == 1:
            expect(".sumi-rm.shell.qml" in o, "%s: the set-aside file isn't reported" % " ".join(cmd), probs)


def s_race(b, probs):
    s_install_basic(b, probs)
    installed = body(tree(b, "shell.qml"))
    cases = []

    def edit(path):
        with open(path, "ab") as f:
            f.write(b"// edited by the user\n")

    def replace(path):                      # como guarda un editor: archivo nuevo y rename encima
        with open(path + ".tmp", "wb") as f:
            f.write(USER_BODY)
        os.rename(path + ".tmp", path)

    def symlink(path):
        os.symlink("/dev/null", path + ".lnk")
        os.rename(path + ".lnk", path)

    def create(path):                       # el nombre está libre (apartado): otro crea uno nuevo
        with open(path, "xb") as f:
            f.write(USER_BODY)

    # (nombre, punto, cambio, rc esperado, qué debe quedar en shell.qml)
    cases = [
        ("edit-after-check", "checked", edit, 1, installed + b"// edited by the user\n"),
        ("replace-after-check", "checked", replace, 1, USER_BODY),
        ("symlink-after-check", "checked", symlink, 1, "link"),
        ("delete-after-check", "checked", os.unlink, 0, None),
        ("create-after-move", "moved", create, 0, USER_BODY),
        ("create-before-unlink", "verified", create, 0, USER_BODY),
    ]
    for tag, point, act, want_rc, want in cases:
        c = Bench()
        try:
            s_install_basic(c, probs)
            rc, o = race_uninstall(c, point, act)
            path = tree(c, "shell.qml")
            if rc != want_rc:
                probs.append("%s: rc %d (want %d) %s" % (tag, rc, want_rc, o[-200:]))
            if want == "link":
                ok = os.path.islink(path)
            elif want is None:
                ok = not os.path.lexists(path)
            else:
                ok = os.path.isfile(path) and not os.path.islink(path) and body(path) == want
            if not ok:
                probs.append("%s: shell.qml not what the user left" % tag)
            if aside_left(c):
                probs.append("%s: set-aside file left: %s" % (tag, aside_left(c)))
            if want_rc == 1 and "shell.qml" not in o:
                probs.append("%s: the kept file isn't reported" % tag)
            if want_rc == 0 and want is not None and "not installed by this installer" not in o:
                probs.append("%s: the user's new file isn't reported" % tag)
        finally:
            c.close()

    # Un proceso que YA tenía el archivo abierto escribe tras apartarlo: se detecta y vuelve a su nombre
    c = Bench()
    try:
        s_install_basic(c, probs)
        held = open(tree(c, "shell.qml"), "ab")
        rc, o = race_uninstall(c, "moved", lambda _p: (held.write(b"// late write\n"), held.flush()))
        held.close()
        if rc != 1 or body(tree(c, "shell.qml")) != installed + b"// late write\n" or aside_left(c):
            probs.append("held-fd-write-after-move: rc %d, file %s" % (rc, os.path.exists(tree(c, "shell.qml"))))
        # Riesgo residual DOCUMENTADO: la misma escritura después de la última comprobación se pierde (el archivo se
        # borra). La prueba fija ese comportamiento para que nadie lo dé por cubierto.
    finally:
        c.close()
    c = Bench()
    try:
        s_install_basic(c, probs)
        held = open(tree(c, "shell.qml"), "ab")
        rc, o = race_uninstall(c, "verified", lambda _p: (held.write(b"// late write\n"), held.flush()))
        held.close()
        if rc != 0 or os.path.lexists(tree(c, "shell.qml")):
            probs.append("residual (held fd, write after the last check): expected removed, got rc %d" % rc)
    finally:
        c.close()

    # Cortado (SIGKILL) con el archivo apartado: recover lo resuelve por su sha
    for tag, act, want_rc, want in (("killed-aside-intact", lambda _p: None, 0, None),
                                    ("killed-aside-edited", "held", 1, installed + b"// late write\n"),
                                    ("killed-aside-name-taken", create, 1, USER_BODY)):
        c = Bench()
        try:
            s_install_basic(c, probs)
            held = None
            if act == "held":
                held = open(tree(c, "shell.qml"), "ab")
                act = lambda _p: (held.write(b"// late write\n"), held.flush())
            rc, o = race_uninstall(c, "moved", act, kill=True)
            if held:
                held.close()
            if rc != -9:
                probs.append("%s: not killed (rc %d)" % (tag, rc))
            rc, o = c.run("recover", "--apply")
            path = tree(c, "shell.qml")
            if rc != want_rc:
                probs.append("%s: recover rc %d (want %d) %s" % (tag, rc, want_rc, o[-200:]))
            if want is None:
                d = diff_snap(c.before, c.snap())
                if d:
                    probs.append("%s: HOME differs after recover: %s" % (tag, d[:4]))
            elif not (os.path.isfile(path) and body(path) == want):
                probs.append("%s: shell.qml not the user's after recover" % tag)
            if aside_left(c):
                probs.append("%s: set-aside file left after recover: %s" % (tag, aside_left(c)))
        finally:
            c.close()


SCENARIOS = {
    "install-basic": (s_install_basic, {}),
    "install-twice": (s_install_twice, {}),
    "install-uninstall": (s_install_uninstall, {}),
    "modified-file": (s_modified, {}),
    "modified-then-restored": (s_restored, {}),
    "keep-modified": (s_keep_modified, {}),
    "user-added-file": (s_added_file, {}),
    "tree-deleted-by-user": (s_tree_deleted, {}),
    "marker-swapped": (s_marker_swapped, {}),
    "marker-missing": (s_marker_missing, {}),
    "manifest-corrupt": (s_manifest_corrupt, {}),
    "manifest-other-root": (s_manifest_other_root, {}),
    "foreign-tree": (s_foreign_tree, {}),
    "foreign-unit": (s_foreign_unit, {}),
    "foreign-link": (s_foreign_link, {}),
    "package-copy": (s_package_copy, {}),
    "default-config": (s_default_config, {}),
    "running-other-copy": (s_running_other, {}),
    "config-outside-home": (s_config_outside_home, {}),
    "quickshell-dir-link": (s_quickshell_link, {}),
    "config-base-link": (s_config_base_link, {}),
    "subdir-swapped-for-link": (s_subdir_swapped, {}),
    "subdir-swapped-midway": (s_swap_midway, {}),
    "install-interrupted (6 steps × 2 × 3 signals)": (s_install_interrupted, {}),
    "uninstall-interrupted (7 steps × 2 × 3 signals)": (s_uninstall_interrupted, {}),
    "recover-after-new-login": (s_relogin, {"spec": {"hyprlock": True}}),
    "concurrent-runs": (s_concurrent, {}),
    "units-enable-stop-no-disable": (s_units_cycle, {}),
    "foreign-link-blocks-uninstall": (s_foreign_link_uninstall, {}),
    "session-locked": (s_locked, {}),
    "locked-right-after-stop": (s_lock_after_stop, {}),
    "lock-state-unknown": (s_lock_unknown, {}),
    "exec-once-shell": (s_exec_once, {}),
    "lock-chain: helper": (s_lock_helper_direct, {"spec": {"hypridle": True, "hyprlock": True}}),
    "lock-chain: known wrapper + hyprlock": (s_lock_wrapper_ok, {"spec": {"hypridle": True, "hyprlock": True}}),
    "lock-chain: wrapper, no hyprlock": (s_lock_wrapper_no_hyprlock, {"spec": {"hypridle": True}}),
    "lock-chain: wrapper, no PAM": (s_lock_wrapper_no_pam, {"spec": {"hypridle": True, "hyprlock": True, "hyprlockPam": False}}),
    "lock-chain: modified wrapper": (s_lock_wrapper_modified, {"spec": {"hypridle": True, "hyprlock": True}}),
    "lock-chain: unknown script": (s_lock_unknown_script, {"spec": {"hypridle": True, "hyprlock": True}}),
    "lock-chain: config unreadable": (s_lock_conf_unreadable, {"spec": {"hypridle": True, "hyprlock": True}}),
    "lock-chain: Hyprland bind": (s_lock_hypr_bind, {}),
    "lock-chain: hyprlock": (s_lock_hyprlock_only, {"spec": {"hypridle": True}}),
    "G1: changed after start": (s_g1_changed_after_start, {"spec": {"hypridle": True, "hyprlock": True}}),
    "G1: restarted after the change": (s_g1_restarted, {"spec": {"hypridle": True, "hyprlock": True}}),
    "G1: included file deleted": (s_g1_included_gone, {"spec": {"hypridle": True, "hyprlock": True}}),
    "G1: -c alternative path": (s_g1_alt_path, {"spec": {"hypridle": True, "hyprlock": True}}),
    "G1: relative -c": (s_g1_relative_alt_path, {"spec": {"hypridle": True, "hyprlock": True}}),
    "G2: not running, default config": (s_g2_not_running_default, {"spec": {"hypridle": True, "hyprlock": True}}),
    "G2: unit with -c": (s_g2_unit_alt, {"spec": {"hypridle": True, "hyprlock": True}}),
    "G2: exec-once with -c": (s_g2_exec_once_alt, {"spec": {"hypridle": True, "hyprlock": True}}),
    "G2: unit with a computed -c": (s_g2_unit_dynamic, {"spec": {"hypridle": True, "hyprlock": True}}),
    "G3: nested scripts": (s_g3_nested_scripts, {"spec": {"hypridle": True, "hyprlock": True}}),
    "G3: dynamic script": (s_g3_dynamic_script, {"spec": {"hypridle": True, "hyprlock": True}}),
    "G3: variable in lock_cmd": (s_g3_variable_cmd, {"spec": {"hypridle": True, "hyprlock": True}}),
    "G3: binary in HOME": (s_g3_binary_in_home, {"spec": {"hypridle": True, "hyprlock": True}}),
    "G3: sh -c": (s_g3_sh_c, {"spec": {"hypridle": True, "hyprlock": True}}),
    "G3: requester": (s_g3_requester, {"spec": {"hypridle": True, "hyprlock": True}}),
    "G4: listener on-timeout": (s_g4_listener, {"spec": {"hypridle": True, "hyprlock": True}}),
    "G4: on-resume warns": (s_g4_resume_warn, {"spec": {"hypridle": True, "hyprlock": True}}),
    "G1-H: exec bind": (s_gh_exec_bind, {"spec": {"hypridle": True, "hyprlock": True}}),
    "G1-H: Lua, autoreload off": (s_gh_lua_autoreload_off, {"spec": {"hypridle": True, "hyprlock": True}}),
    "G1-H: Lua, autoreload on": (s_gh_lua_autoreload_on, {"spec": {"hypridle": True, "hyprlock": True}}),
    "G1-H: hyprctl silent": (s_gh_hyprctl_dead, {"spec": {"hypridle": True, "hyprlock": True}}),
    "lock chain states (dry-run)": (s_chain_states_dry_run, {"spec": {"hypridle": True, "hyprlock": True}}),
    "G1-H: TTY, two instances": (s_gh_tty_two_instances, {"spec": {"hypridle": True, "hyprlock": True}}),
    "dbus-activation": (s_notif_activation, {}),
    "purge": (s_purge, {}),
    "purge-through-link": (s_purge_link, {}),
    "fault-injection-guard": (s_fault_guard, {}),
    "tree-appears-before-rename": (s_race_tree, {}),
    "unit-appears-before-writing": (s_race_unit, {}),
    "filesystem-without-noreplace": (s_no_noreplace, {}),
    "concurrent-change-during-uninstall": (s_race, {}),
    "aside-plus-new-file-plus-kill": (s_race_combined, {}),
}


def main():
    only = sys.argv[1:]
    fails = 0
    for name, (fn, opts) in SCENARIOS.items():
        if only and name not in only:
            continue
        b = Bench(opts.get("spec"), opts.get("home"))
        probs = []
        try:
            fn(b, probs)
            bad = [c for c in b.calls() if c[0] == "systemctl" and "disable" in c]
            expect(not bad, "systemctl disable was called", probs)
        except Exception as e:
            probs.append("harness: %s: %s" % (type(e).__name__, e))
        finally:
            b.close()
        fails += 1 if probs else 0
        print("%-58s %s%s" % (name, "PASS" if not probs else "FAIL", ("  " + "; ".join(probs)) if probs else ""))
    leftovers = [d for d, _, _ in os.walk(ROOT) if os.path.basename(d) == "__pycache__"]
    if leftovers:
        fails += 1
        print("__pycache__ left in the repo: %s" % leftovers)
    print("failed: %d" % fails)
    return fails


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    sys.exit(main())
