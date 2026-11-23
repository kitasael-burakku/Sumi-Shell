#!/usr/bin/env python3
"""El proveedor de fondos propio de Sumi Shell (portabilidad F4b, 2026-10-07; H-10, HC-01, HC-08).

Es el que usa la shell con `providers.wallpaper` = auto, awww o hyprpaper. Tiene el MISMO contrato que el
`apply-wallpaper.sh` del rice del autor (que sigue siendo su proveedor `script`), para que la shell
llame a los dos igual:

    wallpaper-provider.py [--backend B] <ruta>            todas las salidas; borra las excepciones
    wallpaper-provider.py [--backend B] <ruta> <salida>   sólo esa salida (con una sola, es «todas»)
    wallpaper-provider.py [--backend B]                   restaurar lo guardado (al arrancar la shell)
    wallpaper-provider.py [--backend B] --sync            reconciliar con las salidas de AHORA; no escribe
    wallpaper-provider.py [--backend B] --clear <salida>  esa salida vuelve al fondo común
    wallpaper-provider.py [--backend B] pause status --json | pause restore <json>   (los Modos)
    wallpaper-provider.py [--backend B] --resolve         qué backend toca y su estado (JSON); no arranca nada

B = auto (awww → swww → hyprpaper, en ese orden, el primero instalado) · awww · hyprpaper. Un backend
elegido por su nombre que falta es un error con su motivo: nunca se cambia a otro en silencio. Los
vídeos van siempre con mpvpaper (sobre el fondo de imagen). `swww` es el nombre antiguo de awww (awww lo
reemplaza en Arch): se acepta como el mismo backend.

Estado: el de F1, mismos archivos y formatos ($XDG_STATE_HOME/sumi-shell/current-wallpaper y
current-wallpaper-outputs). El fondo quieto del Lock (HC-05) NO se genera aquí (es de F5).

Procesos (decisiones del usuario, 2026-10-07):
  · el daemon de imagen (awww-daemon o hyprpaper) se arranca SÓLO al pintar (apply, restore, clear),
    nunca al mirar (--resolve) ni en --sync; si ya hay una instancia que responde, se usa aunque no sea
    nuestra, y no se duplica;
  · con gestor de usuario, cada proceso va en su scope de systemd (`app-sumi-wallpaper-*.scope`,
    PartOf la sesión gráfica). Sin él, sólo tras confirmar su ausencia por D-Bus, se inicia en una
    sesión de proceso propia y se registra PID + start tick + identidad del ejecutable. Una recarga de
    la shell no se lleva el fondo; nunca se señala un PID cuya identidad haya cambiado;
  · lo que arrancamos queda anotado en $XDG_RUNTIME_DIR/sumi-wallpaper/started.json;
  · sólo se paran los mpvpaper de NUESTROS scopes; si hay otro mpvpaper (de otro programa) se dice y no
    se pinta encima.
Los mensajes de error (stderr, una línea) los enseña la shell tal cual: en inglés.
"""
import sys
sys.dont_write_bytecode = True   # 2026-11-07: sin __pycache__ en el árbol de la shell (desinstalar lo dejaba a medias)
import fcntl
import glob
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
from xdg_paths import base_dir

RUN = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
STATE_DIR = os.path.join(base_dir("XDG_STATE_HOME", ".local/state"), "sumi-shell")
STATE_FILE = os.path.join(STATE_DIR, "current-wallpaper")
OUTPUTS_FILE = os.path.join(STATE_DIR, "current-wallpaper-outputs")
MODE_FILE = os.path.join(base_dir("XDG_CACHE_HOME", ".cache"), "sumi-desktop-mode")
WORK = os.path.join(RUN, "sumi-wallpaper")
REGISTRY = os.path.join(WORK, "started.json")
# El prefijo de las unidades: las pruebas del banco ponen el suyo para no tocar nunca las de la sesión real
PREFIX = os.environ.get("SUMI_WALL_UNIT_PREFIX") or "app-sumi-wallpaper-"
VIDEO = ("mp4", "mkv", "mov", "webm")
IMAGE = ("jpg", "jpeg", "png", "webp", "gif")
TRANSITIONS = ("none", "simple", "fade", "left", "right", "top", "bottom", "wipe", "wave", "grow", "center",
               "any", "outer", "random")
MPV_OPTS = "--loop-file=inf --no-audio --hwdec=auto"
ORDER = ("awww", "swww", "hyprpaper")


class Fail(Exception):
    pass


def ext_of(p):
    return p.rsplit(".", 1)[-1].lower() if "." in os.path.basename(p) else ""


def run(argv, timeout=5, env=None):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, env=env)
        return p.returncode, p.stdout, p.stderr
    except (OSError, subprocess.TimeoutExpired) as e:
        return 127, "", str(e)


# ---- qué backend ---------------------------------------------------------------------------

def resolve(choice="auto"):
    """El backend de imagen para `choice` (sin arrancar ni consultar nada: sólo qué hay instalado)."""
    have = {n: shutil.which(n) for n in ("awww", "awww-daemon", "swww", "swww-daemon", "hyprpaper", "hyprctl", "mpvpaper")}
    pairs = {"awww": ("awww", "awww-daemon"), "swww": ("swww", "swww-daemon"), "hyprpaper": ("hyprctl", "hyprpaper")}
    found = [b for b in ORDER if have[pairs[b][0]] and have[pairs[b][1]]]
    out = {"choice": choice, "backend": None, "found": found, "video": bool(have["mpvpaper"]), "why": ""}
    if choice == "auto":
        if found:
            out["backend"] = found[0]
        else:
            out["why"] = "No wallpaper backend: install awww or hyprpaper"
    elif choice == "awww":
        b = "awww" if "awww" in found else "swww" if "swww" in found else None
        out["backend"] = b
        if not b:
            out["why"] = "awww is not installed"
    elif choice == "hyprpaper":
        out["backend"] = "hyprpaper" if "hyprpaper" in found else None
        if not out["backend"]:
            out["why"] = "hyprpaper is not installed" if not have["hyprpaper"] else "hyprctl is not installed"
    else:
        out["why"] = "Unknown wallpaper backend: " + str(choice)
    return out


def family(backend):
    return "hyprpaper" if backend == "hyprpaper" else "awww"


def hypr_socket(name):
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    return os.path.join(RUN, "hypr", sig, name) if sig else ""


def daemon_socket(backend):
    """El socket del daemon de ESTA pantalla: awww y swww lo llaman <WAYLAND_DISPLAY>-<nombre>-daemon.sock
    (espacio de nombres por defecto; medido con awww 0.12.1); hyprpaper, el de la instancia de Hyprland."""
    if family(backend) == "awww":
        wl = os.environ.get("WAYLAND_DISPLAY", "")
        return os.path.join(RUN, "%s-%s-daemon.sock" % (wl, backend)) if wl else ""
    return hypr_socket(".hyprpaper.sock")


def daemon_running(backend):
    """Hay un daemon que contesta en esta pantalla (sea nuestro o no). Sin su socket, no. Con él: awww se
    pregunta con su propio cliente (`query`): conectar y cerrar sin hablar su protocolo TUMBA awww-daemon
    (medido en el banco, 0.12.1); hyprpaper (hyprwire) sí admite una conexión de prueba."""
    path = daemon_socket(backend)
    if not path or not os.path.exists(path):
        return False
    if family(backend) == "awww":
        rc, _o, _e = run([backend, "query"], timeout=3)
        return rc == 0
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(1.0)
    try:
        s.connect(path)
        return True
    except OSError:
        return False
    finally:
        s.close()


# ---- registro de lo que arrancamos -------------------------------------------------------------

def unit_active(unit):
    rc, out, _ = run(["systemctl", "--user", "is-active", unit], timeout=5)
    return out.strip() in ("active", "activating", "deactivating")


_manager = None


def manager_backend():
    """Choose only from a successful, non-activating session-bus query."""
    global _manager
    if _manager is None:
        from user_manager import backend
        try:
            _manager = backend()
        except RuntimeError as e:
            raise Fail(str(e))
    return _manager


def direct_key(name):
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    if not sig:
        raise Fail("Hyprland instance identity is missing")
    return PREFIX + sig + "-" + name + ".direct"


def proc_identity(pid):
    """PID reuse guard: owner UID, kernel start tick and executable."""
    try:
        with open("/proc/%d/stat" % pid) as f:
            stat = f.read().rsplit(") ", 1)[1].split()
        if stat[0] == "Z":
            return None
        exe = os.stat("/proc/%d/exe" % pid)
        return {"pid": pid, "start": stat[19], "exe": os.readlink("/proc/%d/exe" % pid),
                "exeDev": exe.st_dev, "exeIno": exe.st_ino,
                "uid": os.stat("/proc/%d" % pid).st_uid}
    except (OSError, IndexError, ValueError):
        return None


def direct_alive(entry):
    pid = entry.get("pid")
    if type(pid) is not int or pid < 2:
        return False
    now = proc_identity(pid)
    return bool(now and now["uid"] == os.getuid() and now["start"] == entry.get("start")
                and now["exeDev"] == entry.get("exeDev") and now["exeIno"] == entry.get("exeIno"))


def owned_active(key):
    if key.endswith(".scope"):
        return manager_backend() == "systemd" and unit_active(key)
    return direct_alive(registry_load().get(key, {}))


def stop_owned(key):
    if key.endswith(".scope"):
        if manager_backend() == "systemd" and unit_active(key):
            run(["systemctl", "--user", "stop", key], timeout=10)
        return
    entry = registry_load().get(key, {})
    if not direct_alive(entry):
        return
    try:
        fd = os.pidfd_open(entry["pid"])
    except OSError as e:
        raise Fail("could not identify owned wallpaper process: " + str(e))
    try:
        if not direct_alive(entry):
            return
        try:
            signal.pidfd_send_signal(fd, signal.SIGTERM)
        except ProcessLookupError:
            return
        for _ in range(30):
            if not direct_alive(entry):
                return
            time.sleep(0.1)
        try:
            signal.pidfd_send_signal(fd, signal.SIGKILL)
        except ProcessLookupError:
            return
    finally:
        os.close(fd)


def registry_load():
    try:
        with open(REGISTRY) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def registry_save(d):
    os.makedirs(WORK, exist_ok=True)
    tmp = REGISTRY + ".%d" % os.getpid()
    with open(tmp, "w") as f:
        json.dump(d, f, indent=1)
    os.replace(tmp, REGISTRY)


def registry_note(key, what, **kw):
    d = registry_prune()
    d[key] = dict(kw, what=what, at=int(time.time()))
    registry_save(d)


def registry_prune():
    d = registry_load()
    live = {u: v for u, v in d.items() if owned_active(u)}
    if live != d:
        registry_save(live)
    return live


def scope_start(unit, argv, log):
    """`argv` en su propio scope de usuario, desligado de quien lo pide. Devuelve el Popen."""
    os.makedirs(WORK, exist_ok=True)
    f = open(os.path.join(WORK, log), "ab")
    cmd = ["systemd-run", "--user", "--scope", "--quiet", "--collect", "--unit", unit,
           "-p", "PartOf=graphical-session.target", "-p", "TimeoutStopSec=3", "--"] + argv
    return subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=f, stderr=f, start_new_session=True)


def owned_start(name, argv, log, **details):
    """Start once under systemd, or own an exact process identity without it."""
    if manager_backend() == "systemd":
        key = PREFIX + name + ".scope"
        p = scope_start(key, argv, log)
        registry_note(key, argv[0], **details)
        return p, key
    key = direct_key(name)
    os.makedirs(WORK, exist_ok=True)
    with open(os.path.join(WORK, log), "ab") as f:
        p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=f, stderr=f, start_new_session=True)
    identity = proc_identity(p.pid)
    if not identity:
        raise Fail(argv[0] + " exited before its process identity could be recorded")
    registry_note(key, argv[0], **details, **identity)
    return p, key


def start_daemon(backend):
    """El daemon de imagen, si no hay ya uno que responda. Error si no llega a responder."""
    if daemon_running(backend):
        return False
    name = family(backend)
    key = PREFIX + name + ".scope" if manager_backend() == "systemd" else direct_key(name)
    if owned_active(key):
        # nuestro, todavía arrancando (u otro apply en paralelo): esperar a que responda
        argv = None
    elif family(backend) == "awww":
        argv = [backend + "-daemon"]
    else:
        sock = hypr_socket(".hyprpaper.sock")
        if len(sock.encode()) > 107:
            # un socket Unix no admite una ruta más larga: hyprpaper arrancaría sin IPC (medido en el banco)
            raise Fail("the runtime path is too long for hyprpaper's socket (%d bytes)" % len(sock.encode()))
        conf = os.path.join(WORK, "hyprpaper.conf")
        os.makedirs(WORK, exist_ok=True)
        with open(conf, "w") as f:
            # vacía a propósito: lo pinta todo el IPC (nunca se lee ni se escribe la config del usuario)
            f.write("# Sumi Shell: hyprpaper started by the shell; wallpapers are set over IPC\n")
        argv = ["hyprpaper", "-c", conf]
    if argv:
        p, key = owned_start(name, argv, name + ".log", backend=backend)
    for _ in range(100):
        if daemon_running(backend):
            return True
        if argv and p.poll() is not None and not owned_active(key):
            break
        time.sleep(0.1)
    # El nuestro no contesta (p. ej. hyprpaper deja su IPC apagado si Hyprland tarda en contestarle al
    # arrancar: medido en el banco bajo carga): se para SU scope, que nadie más usa, para no dejar un daemon
    # inútil que bloquee los siguientes intentos; el siguiente Apply arranca uno nuevo.
    if owned_active(key):
        stop_owned(key)
    raise Fail("%s could not be started (see %s)" % (argv[0] if argv else backend,
                                                     os.path.join(WORK, family(backend) + ".log")))


# ---- salidas y estado ----------------------------------------------------------------------

def outputs():
    rc, out, err = run(["hyprctl", "-j", "monitors"], timeout=3)
    try:
        names = [m["name"] for m in json.loads(out)] if rc == 0 else []
    except (ValueError, KeyError, TypeError):
        names = []
    if not names:
        raise Fail("no outputs (is Hyprland up?)")
    return names


def read_global():
    try:
        with open(STATE_FILE) as f:
            g = f.read().strip()
    except OSError:
        return ""
    return g if g and os.path.isfile(g) else ""


def read_overrides():
    out = {}
    try:
        with open(OUTPUTS_FILE) as f:
            for line in f:
                o, sep, p = line.rstrip("\n").partition("\t")
                if sep and o:
                    out[o] = p
    except OSError:
        pass
    return out


def write_global(path):
    # en el sitio, como apply-wallpaper.sh: lo vigilan la shell y otros lectores
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(STATE_FILE, "w") as f:
        f.write(path)


def write_overrides(d):
    os.makedirs(STATE_DIR, exist_ok=True)
    if not d:
        try:
            os.unlink(OUTPUTS_FILE)
        except FileNotFoundError:
            pass
        return
    tmp = OUTPUTS_FILE + ".%d" % os.getpid()
    with open(tmp, "w") as f:
        f.write("".join("%s\t%s\n" % kv for kv in d.items()))
    os.replace(tmp, OUTPUTS_FILE)


# ---- mpvpaper -------------------------------------------------------------------------------

def mpv_name(output):
    return "all" if output == "*" else re.sub(r"[^A-Za-z0-9_.-]", "_", output)


def cgroup_pids(unit):
    rc, cg, _ = run(["systemctl", "--user", "show", "-p", "ControlGroup", "--value", unit], timeout=5)
    cg = cg.strip()
    if rc != 0 or not cg:
        return []
    try:
        with open("/sys/fs/cgroup" + cg + "/cgroup.procs") as f:
            return [int(x) for x in f.read().split()]
    except (OSError, ValueError):
        return []


def argv_of(pid):
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            return [a.decode("utf-8", "replace") for a in f.read().split(b"\0") if a]
    except OSError:
        return []


def comm_of(pid):
    try:
        with open("/proc/%d/comm" % pid) as f:
            return f.read().strip()
    except OSError:
        return ""


def mpv_ours():
    """[{unit, output, path}] de nuestros scopes o procesos directos verificados."""
    if manager_backend() == "direct":
        prefix = direct_key("mpvpaper-")[:-7]
        return [{"unit": key, "pid": item["pid"], "output": item["output"], "path": item["path"]}
                for key, item in registry_prune().items()
                if key.startswith(prefix) and item.get("what") == "mpvpaper"
                and item.get("output") and item.get("path")]
    rc, out, _ = run(["systemctl", "--user", "list-units", "--type=scope", "--all", "--plain", "--no-legend",
                      PREFIX + "mpvpaper-*"], timeout=5)
    res = []
    for line in out.splitlines():
        unit = line.split()[0] if line.split() else ""
        if not unit.endswith(".scope") or not unit_active(unit):
            continue
        for pid in cgroup_pids(unit):
            if comm_of(pid) == "mpvpaper":
                a = argv_of(pid)
                if len(a) >= 3:
                    res.append({"unit": unit, "pid": pid, "output": a[-2], "path": a[-1]})
    return res


def mpv_foreign(ours):
    mine = {m["pid"] for m in ours}
    out = []
    for d in glob.glob("/proc/[0-9]*"):
        pid = int(d.rsplit("/", 1)[1])
        if pid not in mine and comm_of(pid) == "mpvpaper":
            out.append(pid)
    return out


def mpv_stop(m):
    stop_owned(m["unit"])


def mpv_start(output, path):
    name = mpv_name(output)
    owner = "mpvpaper-" + name
    unit = PREFIX + owner + ".scope" if manager_backend() == "systemd" else direct_key(owner)
    if owned_active(unit):
        stop_owned(unit)
    opts = MPV_OPTS + " --input-ipc-server=" + os.path.join(RUN, "sumi-mpvpaper-%s.sock" % name)
    try:
        with open(MODE_FILE) as f:
            if f.read().strip() in ("gaming", "cinema"):
                opts += " --pause"          # un vídeo que arranca con Gaming/Cinema puestos, en pausa
    except OSError:
        pass
    # <salida> <ruta> los DOS últimos: así los lee mpv_ours (y el wallpaper-video-pause del rice)
    p, unit = owned_start(owner, ["mpvpaper", "-p", "-a", "FULL", "-o", opts, output, path],
                          "mpvpaper-%s.log" % name, output=output, path=path)
    for _ in range(20):
        time.sleep(0.1)
        if p.poll() is not None and not owned_active(unit):
            raise Fail("mpvpaper could not play %s (see %s)" % (os.path.basename(path),
                                                               os.path.join(WORK, "mpvpaper-%s.log" % name)))
    return unit


# ---- imágenes -------------------------------------------------------------------------------

def awww_showing(backend):
    """{salida: ruta} de lo que enseña awww (sólo imágenes)."""
    rc, out, _ = run([backend, "query"], timeout=3)
    res = {}
    for line in out.splitlines():
        m = re.match(r"^[^:]*:\s*([^:]+):.*currently displaying: image: (.*)$", line)
        if m:
            res[m.group(1).strip()] = m.group(2)
    return res


def paint(backend, path, outs, all_outputs):
    """`path` en `outs` (todas si all_outputs). Error con el motivo del backend."""
    if family(backend) == "awww":
        t = os.environ.get("WALL_TRANSITION") or "any"
        if t not in TRANSITIONS:
            t = "any"
        argv = [backend, "img"] + ([] if all_outputs else ["-o", ",".join(outs)]) + \
               [path, "--transition-type", t, "--transition-fps", "60"]
        rc, out, err = run(argv, timeout=15)
        if rc != 0:
            raise Fail("%s img failed: %s" % (backend, (err or out).strip().splitlines()[-1:] or ["exit %d" % rc]))
        return
    # hyprpaper no dice qué enseña: «todas» = el comodín (cubre salidas nuevas, medido) y además cada
    # salida, para que una regla anterior de una salida no gane al comodín
    for o in (([""] + list(outs)) if all_outputs else outs):
        rc, out, err = run(["hyprctl", "hyprpaper", "wallpaper", o + "," + path], timeout=10)
        if rc != 0:
            raise Fail("hyprpaper: " + ((out or err).strip().replace("error: ", "") or "exit %d" % rc))


# ---- reconciliar ----------------------------------------------------------------------------

def reconcile(backend, may_start):
    """Que cada salida enseñe lo que dice el estado. `may_start`: se puede arrancar el daemon."""
    outs = outputs()
    glob_path = read_global()
    over = read_overrides()
    want = {}
    for o in outs:
        w = over.get(o, "")
        want[o] = w if w and os.path.isfile(w) else glob_path
    if not any(want.values()):
        return "nothing to show"
    ours = mpv_ours()
    foreign = mpv_foreign(ours)
    if foreign:
        raise Fail("another mpvpaper not started by Sumi Shell is running (pid %s); it was left alone"
                   % ", ".join(map(str, foreign)))
    images = [o for o in outs if want[o] and ext_of(want[o]) in IMAGE]
    if images:
        if not daemon_running(backend):
            if not may_start:
                images = []                      # --sync no arranca daemons: sin daemon, nada que pintar
            else:
                start_daemon(backend)
    uniform = len(set(want.values())) == 1 and bool(glob_path)
    if uniform:
        w = glob_path
        if ext_of(w) in VIDEO:
            keep = [m for m in ours if m["output"] == "*" and m["path"] == w]
            if keep and len(ours) == 1:
                return "unchanged"
            for m in ours:
                mpv_stop(m)
            mpv_start("*", w)
            return "video"
        for m in ours:
            mpv_stop(m)
        if images:
            if family(backend) == "awww":
                stale = [o for o, p in awww_showing(backend).items() if o in outs and p != w]
                missing = [o for o in outs if o not in awww_showing(backend)]
                todo = sorted(set(stale + missing))
                if todo:
                    paint(backend, w, todo, len(todo) == len(outs))
            else:
                paint(backend, w, outs, True)
        return "image"
    # por salida: un mpvpaper en «*» pintaría bajo las de cada una
    for m in ours:
        if m["output"] == "*" or m["output"] not in outs:
            mpv_stop(m)
    ours = [m for m in ours if m["output"] != "*" and m["output"] in outs]
    showing = awww_showing(backend) if images and family(backend) == "awww" else {}
    for o in outs:
        w = want[o]
        if not w:
            continue
        mine = [m for m in ours if m["output"] == o]
        if ext_of(w) in VIDEO:
            for m in mine:
                if m["path"] != w:
                    mpv_stop(m)
            if not any(m["path"] == w for m in mine):
                mpv_start(o, w)
        else:
            for m in mine:
                mpv_stop(m)
            if o in images and showing.get(o) != w:
                paint(backend, w, [o], False)
    return "per-output"


def check_file(path, backend, res):
    if not os.path.isfile(path):
        raise Fail("wallpaper doesn't exist: " + path)
    e = ext_of(path)
    if e in VIDEO:
        if not res["video"]:
            raise Fail("mpvpaper is not installed · videos can't be applied")
    elif e in IMAGE:
        if family(backend) == "hyprpaper" and "," in path:
            raise Fail("hyprpaper can't show a file whose path has a comma: " + os.path.basename(path))
    else:
        raise Fail("unsupported extension: " + path)


# ---- pausa de vídeo (Modos) -------------------------------------------------------------------

def pause(args):
    """status [--json] | restore <json>: como wallpaper-video-pause.sh, sobre los sockets de mpvpaper."""
    action = args[0] if args else ""
    if action not in ("status", "restore", "on", "off"):
        raise Fail("usage: pause on|off|status [--json]|restore <json>")
    targets = None
    if action == "restore":
        try:
            targets = json.loads(args[1])
        except (IndexError, ValueError):
            raise Fail("Invalid wallpaper snapshot")
        if not isinstance(targets, dict) or any(
                not k.startswith("sumi-mpvpaper-") or not k.endswith(".sock") or "/" in k or type(v) is not bool
                for k, v in targets.items()):
            raise Fail("Invalid wallpaper snapshot")
    paths = [os.path.join(RUN, k) for k in targets] if targets is not None \
        else sorted(glob.glob(os.path.join(RUN, "sumi-mpvpaper-*.sock")))
    result, failed = {}, False
    for path in paths:
        name = os.path.basename(path)
        cmd = ["get_property", "pause"] if action == "status" else \
            ["set_property", "pause", targets[name] if targets is not None else action == "on"]
        try:
            with socket.socket(socket.AF_UNIX) as s:
                s.settimeout(1.5)
                s.connect(path)
                s.sendall((json.dumps({"command": cmd, "request_id": 11}) + "\n").encode())
                pending, reply = b"", None
                while reply is None:
                    chunk = s.recv(4096)
                    if not chunk:
                        raise OSError("No reply from mpv")
                    pending += chunk
                    if len(pending) > 65536:
                        raise OSError("mpv reply is too large")
                    while b"\n" in pending:
                        line, pending = pending.split(b"\n", 1)
                        obj = json.loads(line)
                        if obj.get("request_id") == 11:
                            reply = obj
                            break
                if reply.get("error") != "success":
                    raise OSError(reply.get("error", "Invalid reply"))
                if action == "status":
                    if type(reply.get("data")) is not bool:
                        raise OSError("Invalid pause state")
                    result[name] = reply["data"]
                else:
                    result[name] = cmd[-1]
        except (OSError, ValueError) as e:
            print(name + ": " + str(e), file=sys.stderr)
            failed = True
    if "--json" in args or action == "restore":
        print(json.dumps(result))
    return 1 if failed else 0


# ---- principal ------------------------------------------------------------------------------

def main(argv):
    choice = "auto"
    if argv[:1] == ["--backend"]:
        if len(argv) < 2:
            raise Fail("--backend needs a value")
        choice, argv = argv[1], argv[2:]
    res = resolve(choice)
    if argv[:1] == ["--resolve"]:
        b = res["backend"]
        print(json.dumps(dict(res, running=bool(b) and daemon_running(b), started=registry_prune())))
        return 0
    if argv[:1] == ["pause"]:
        return pause(argv[1:])
    backend = res["backend"]
    if not backend:
        raise Fail(res["why"])
    os.makedirs(WORK, exist_ok=True)
    lock = open(os.path.join(WORK, "lock"), "w")
    for _ in range(150):
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            time.sleep(0.1)
    else:
        raise Fail("another wallpaper change is still running")
    if argv[:1] == ["--sync"]:
        print(reconcile(backend, may_start=False))
        return 0
    if argv[:1] == ["--clear"]:
        if len(argv) < 2 or not argv[1]:
            raise Fail("--clear needs an output")
        over = read_overrides()
        over.pop(argv[1], None)
        write_overrides(over)
        print(reconcile(backend, may_start=True))
        return 0
    if argv and argv[0].startswith("-"):
        raise Fail("unknown option: " + argv[0])
    if not argv:
        if not read_global() and not read_overrides():
            print("nothing to restore")
            return 0
        print(reconcile(backend, may_start=True))
        return 0
    path = argv[0]
    mon = argv[1] if len(argv) > 1 else os.environ.get("WALLPAPER_MONITOR", "")
    check_file(path, backend, res)
    if mon:
        outs = outputs()
        if mon not in outs:
            raise Fail("no such output: " + mon)
        if len(outs) == 1:
            mon = ""
    if mon:
        over = read_overrides()
        over[mon] = path
        write_overrides(over)
    else:
        write_global(path)
        write_overrides({})           # «todas las salidas» es todas
    print(reconcile(backend, may_start=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Fail as e:
        print("wallpaper-provider: " + str(e), file=sys.stderr)
        sys.exit(1)
