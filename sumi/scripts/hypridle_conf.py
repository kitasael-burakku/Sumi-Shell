"""Quién atiende `loginctl lock-session` en esta sesión (portabilidad F5d, 2026-10-10; H-07, HC-46/60).

logind no dice quién escucha su señal Lock: se mira a los demonios conocidos. Con hypridle (el caso de Hyprland) se
lee su configuración real —la de su proceso: `-c`, o la carpeta XDG de SU entorno— siguiendo `source =`, y se clasifica
su `lock_cmd`:
  shell     el helper de la shell (`sumi-lock`) o un envoltorio suyo (las marcas `sumi-lock-helper` y
            `sumi-lock-wrapper` en los primeros 4 KB del script)
  hyprlock  menciona hyprlock (p. ej. `pidof hyprlock || hyprlock`, lo que trae hypridle de ejemplo)
  other     otra cosa (también `loginctl lock-session`, que sería un bucle)
  none      hypridle sin `lock_cmd`: recibe la señal y no hace nada
Sin hypridle: `other` si corre otro demonio conocido que escucha a logind (swayidle, xss-lock, xidlehook), `none`
si no hay ninguno. `unknown` si no se pudo leer.

Sólo lee (/proc, archivos). F5f lo usa también para saber cómo corre hypridle. Para pruebas: SUMI_PROC (otra raíz
de /proc) y SUMI_HYPRIDLE_CONF (fuerza la config, sin mirar procesos).
"""
import os
import re
import shlex

from xdg_paths import base_dir

PROC = os.environ.get("SUMI_PROC", "/proc")
OTHER_DAEMONS = ("swayidle", "xss-lock", "xidlehook")
MARKERS = (b"sumi-lock-helper", b"sumi-lock-wrapper")


def _read(path, mode="r", limit=None):
    try:
        with open(path, mode) as f:
            return f.read(limit) if limit else f.read()
    except (OSError, UnicodeDecodeError):
        return None


def processes(names):
    """[(pid, comm)] de los procesos de ESTE usuario cuyo comm está en `names`."""
    uid = os.getuid()
    out = []
    try:
        pids = [int(d) for d in os.listdir(PROC) if d.isdigit()]
    except OSError:
        return None
    for pid in pids:
        comm = _read(os.path.join(PROC, str(pid), "comm"))
        if comm is None or comm.strip() not in names:
            continue
        try:
            if os.stat(os.path.join(PROC, str(pid))).st_uid != uid:
                continue
        except OSError:
            continue
        out.append((pid, comm.strip()))
    return sorted(out)


def locate(pid):
    """{main, dir, from}: la config del hypridle `pid` (su -c, su XDG_CONFIG_HOME o HOME/.config/hypr)."""
    forced = os.environ.get("SUMI_HYPRIDLE_CONF")
    if forced:
        m = os.path.expanduser(forced)
        return {"main": m, "dir": os.path.dirname(m), "from": "override"}
    raw = _read(os.path.join(PROC, str(pid), "cmdline"), "rb") or b""
    args = raw.decode("utf-8", "replace").split("\0")
    env = {}
    for kv in (_read(os.path.join(PROC, str(pid), "environ"), "rb") or b"").split(b"\0"):
        k, _, v = kv.decode("utf-8", "replace").partition("=")
        if k:
            env[k] = v
    for i, a in enumerate(args):
        val = None
        if a in ("-c", "--config") and i + 1 < len(args):
            val = args[i + 1]
        elif a.startswith("--config="):
            val = a.split("=", 1)[1]
        if val:
            m = os.path.expanduser(val)
            if not os.path.isabs(m):
                cwd = ""
                try:
                    cwd = os.readlink(os.path.join(PROC, str(pid), "cwd"))
                except OSError:
                    pass
                m = os.path.normpath(os.path.join(cwd or os.getcwd(), m))
            return {"main": m, "dir": os.path.dirname(m), "from": "cmdline"}
    cfg = base_dir("XDG_CONFIG_HOME", ".config", env)
    d = os.path.join(cfg, "hypr")
    return {"main": os.path.join(d, "hypridle.conf"), "dir": d,
            "from": "environment" if os.path.isabs(env.get("XDG_CONFIG_HOME", "")) else "default"}


def _strip_comment(line):
    # hyprlang: «#» empieza un comentario; «##» es un «#» literal
    out, i = [], 0
    while i < len(line):
        if line[i] == "#":
            if i + 1 < len(line) and line[i + 1] == "#":
                out.append("#")
                i += 2
                continue
            break
        out.append(line[i])
        i += 1
    return "".join(out)


def read_general(main, _depth=0, _seen=None):
    """(claves de `general {}` —la última gana—, archivos leídos, error) siguiendo `source =` (como mucho 8 niveles)."""
    seen = _seen if _seen is not None else []
    if _depth > 8 or main in seen:
        return {}, seen, ""
    text = _read(main)
    if text is None:
        return {}, seen, "can't read " + main
    seen.append(main)
    keys, stack, err = {}, [], ""
    for raw in text.split("\n"):
        line = _strip_comment(raw).strip()
        if not line:
            continue
        m = re.match(r"^([\w-]+)\s*\{$", line)
        if m:
            stack.append(m.group(1))
            continue
        if line == "}":
            if stack:
                stack.pop()
            continue
        k, eq, v = line.partition("=")
        if not eq:
            continue
        k, v = k.strip(), v.strip()
        if k == "source" and not stack:
            p = os.path.expanduser(v)
            if not os.path.isabs(p):
                p = os.path.join(os.path.dirname(main), p)
            sub, _, e = read_general(p, _depth + 1, seen)
            keys.update(sub)
            err = err or e
        elif stack == ["general"]:
            keys[k] = v
    return keys, seen, err


def classify(lock_cmd):
    """shell | hyprlock | other | none para un `lock_cmd` de hypridle."""
    cmd = (lock_cmd or "").strip()
    if not cmd:
        return "none"
    if "lock-session" in cmd:
        return "other"                       # pediría otra vez el bloqueo a logind: un bucle
    try:
        first = shlex.split(cmd)[0]
    except (ValueError, IndexError):
        first = cmd.split()[0]
    path = os.path.expanduser(first)
    if os.path.basename(path) == "sumi-lock":
        return "shell"
    if os.path.isfile(path):
        head = _read(path, "rb", 4096) or b""
        if any(m in head for m in MARKERS):
            return "shell"
    if "hyprlock" in cmd:
        return "hyprlock"
    return "other"


def report():
    """{listener, daemon, pid, config, from, lockCmd, beforeSleepCmd, files, error}."""
    if os.environ.get("SUMI_HYPRIDLE_CONF"):
        idle = [(0, "hypridle")]
    else:
        idle = processes(("hypridle",))
    if idle is None:
        return {"listener": "unknown", "error": "can't list processes"}
    if idle:
        pid = idle[0][0]
        loc = locate(pid)
        keys, files, err = read_general(loc["main"])
        if err and not files:
            return {"listener": "unknown", "daemon": "hypridle", "pid": pid, "config": loc["main"], "from": loc["from"],
                    "error": err}
        lock = keys.get("lock_cmd", "")
        return {"listener": classify(lock), "daemon": "hypridle", "pid": pid, "count": len(idle), "config": loc["main"],
                "from": loc["from"], "lockCmd": lock, "beforeSleepCmd": keys.get("before_sleep_cmd", ""),
                "inhibitSleep": keys.get("inhibit_sleep", ""), "files": files, "error": err}
    others = processes(OTHER_DAEMONS) or []
    if others:
        return {"listener": "other", "daemon": others[0][1], "pid": others[0][0]}
    return {"listener": "none", "daemon": ""}
