#!/usr/bin/env python3
"""Qué puede hacer la shell en esta máquina (portabilidad F2a, 2026-10-05).

    capabilities.py report [--cache F] [--human] [--shell-dir D]

Una sola pasada, de sólo lectura: binarios en el PATH heredado (el mismo que verán los `Process`
de la shell), archivos del rice que el código actual usa de verdad, unidades de usuario
(`systemctl --user show`), nombres en los buses (`ListNames`/`ListActivatableNames`), procesos en
/proc, fuentes (`fc-list`) y plugins de Hyprland. **Detectar no es activar:** no arranca daemons,
no reclama nombres D-Bus, no pide contraseñas ni escribe configuración. Lo único que escribe es la
caché opcional (`--cache`), regenerable.

Contrato (portabilidad/ROADMAP.md §F2): cada capacidad trae
    state     available | degraded | unavailable | unknown
    provider  quién la da hoy (el proveedor que el código usa, no uno hipotético de F4)
    reason    en inglés, para la UI; vacío si está disponible
    facts     installed / active / accessible / sessionCompatible: true, false o null (no se supo)
Sólo hay `unavailable` con prueba positiva de la ausencia. Una consulta denegada, caducada o sin
herramienta para hacerla da `unknown`, nunca «no instalado» (PL-01/03).

Sirve también sin la shell (diagnóstico previo, p. ej. si no carga): `--human` imprime una tabla.
Salida normal: una línea JSON en stdout, siempre con código 0 si llegó a informar.
"""
import argparse
import concurrent.futures
import datetime
import glob
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import time

# El código puede estar instalado sin permiso de escritura (F1a).
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from xdg_paths import base_dir

FORMAT = "sumi-capabilities"
VERSION = 1
PROBE_TIMEOUT = float(os.environ.get("KT_CAPS_PROBE_TIMEOUT", "2"))

HOME = os.path.expanduser("~")
CONFIG = base_dir("XDG_CONFIG_HOME", ".config")
STATE = base_dir("XDG_STATE_HOME", ".local/state")
# F4e (2026-10-08): ya no hay rutas del rice aquí: fondos, miniaturas, tema y actualizaciones siguen al proveedor
# elegido (providers.* + providers.json). La antigua RICE (KT_CAPS_RICE_SCRIPTS) se retiró.
# F4d: la config de matugen la da el proveedor de tema (theme_config); MATUGEN_CONFIG sigue valiendo en pruebas
FONT = "IosevkaTerm Nerd Font Propo"     # theme/Typography.qml
PROC = os.environ.get("KT_CAPS_PROC_DIR", "/proc")   # sustituible en pruebas (tools/f2)


# ---- primitivas -------------------------------------------------------------------------------

def run(argv, timeout=PROBE_TIMEOUT):
    """(rc, stdout, stderr); rc None = no se pudo ejecutar o caducó (eso es «no se sabe»)."""
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL)
    except FileNotFoundError:
        return None, "", "not found: " + argv[0]
    except subprocess.TimeoutExpired:
        return None, "", "timed out: " + argv[0]
    except OSError as e:
        return None, "", str(e)
    return p.returncode, p.stdout, p.stderr


def which(name):
    return shutil.which(name)


def is_file(path):
    return os.path.isfile(path) and os.access(path, os.R_OK)


def cap(state, provider="", reason="", installed=None, active=None, accessible=None,
        session=None, **detail):
    c = {"state": state, "provider": provider, "reason": reason if state != "available" else "",
         "facts": {"installed": installed, "active": active, "accessible": accessible,
                   "sessionCompatible": session}}
    if detail:
        c["detail"] = detail
    return c


def missing_bins(names):
    return [n for n in names if not which(n)]


def not_installed(names):
    return " and ".join(names) + (" is" if len(names) == 1 else " are") + " not installed"


# ---- consultas compartidas (cada una, una vez) --------------------------------------------------

UNITS = ("filter-chain.service", "cliphist-text.service", "cliphist-image.service",
         "thumbs-refresh.service", "updates-check.timer", "updates-check.service", "awww.service")


def q_units():
    """{unit: {LoadState, ActiveState, UnitFileState}} o {"error": …}. `show` no arranca nada."""
    if not which("systemctl"):
        return {"error": "systemctl not found"}
    rc, out, err = run(["systemctl", "--user", "show", "-p", "Id,LoadState,ActiveState,UnitFileState"]
                       + list(UNITS))
    if rc != 0:
        return {"error": (err.strip().splitlines() or ["systemctl --user failed"])[0]}
    units, cur = {}, {}
    for line in out.splitlines() + [""]:
        if not line.strip():
            if cur.get("Id"):
                units[cur["Id"]] = cur
            cur = {}
            continue
        k, _, v = line.partition("=")
        cur[k] = v
    return units


def q_bus(bus):
    """{"names": set, "activatable": set} o {"error": …}. ListNames no activa ningún servicio."""
    if not which("busctl"):
        return {"error": "busctl not found"}
    res = {}
    for key, method in (("names", "ListNames"), ("activatable", "ListActivatableNames")):
        rc, out, err = run(["busctl", "--" + bus, "--json=short", "call", "org.freedesktop.DBus",
                            "/org/freedesktop/DBus", "org.freedesktop.DBus", method])
        if rc != 0:
            return {"error": (err.strip().splitlines() or [method + " failed"])[0]}
        try:
            res[key] = set(json.loads(out)["data"][0])
        except (ValueError, KeyError, IndexError, TypeError):
            return {"error": "unexpected busctl output"}
    return res


def q_notif_owner():
    """Quién atiende org.freedesktop.Notifications: {"pid", "name"}, {"pid": 0} si nadie, o error."""
    if not which("busctl"):
        return {"error": "busctl not found"}
    base = ["busctl", "--user", "call", "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus"]
    rc, out, err = run(base + ["NameHasOwner", "s", "org.freedesktop.Notifications"])
    if rc != 0:
        return {"error": (err.strip().splitlines() or ["busctl failed"])[0]}
    if out.split()[-1:] != ["true"]:
        return {"pid": 0}
    rc, out, err = run(base + ["GetConnectionUnixProcessID", "s", "org.freedesktop.Notifications"])
    if rc != 0:
        return {"error": (err.strip().splitlines() or ["busctl failed"])[0]}
    try:
        pid = int(out.split()[1])
    except (IndexError, ValueError):
        return {"error": "unexpected busctl output"}
    try:
        with open(os.path.join(PROC, str(pid), "comm")) as f:
            name = f.read().strip()
    except OSError:
        name = ""
    return {"pid": pid, "name": name, "shell": str(pid) == os.environ.get("KT_CAPS_SHELL_PID", "")}


def q_procs():
    """[(pid, comm, cmdline)] leyendo /proc; error si /proc no se puede listar."""
    try:
        pids = [int(d) for d in os.listdir(PROC) if d.isdigit()]
    except OSError as e:
        return {"error": str(e)}
    out = []
    for pid in pids:
        try:
            with open(os.path.join(PROC, str(pid), "comm")) as f:
                comm = f.read().strip()
            with open(os.path.join(PROC, str(pid), "cmdline"), "rb") as f:
                cmd = f.read().replace(b"\0", b" ").decode("utf-8", "replace").strip()
        except OSError:
            continue   # terminó entretanto o no es nuestro: no es noticia
        out.append((pid, comm, cmd))
    return {"list": out}


def q_hypr():
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    res = {"signature": bool(sig), "desktop": os.environ.get("XDG_CURRENT_DESKTOP", "")}
    if not which("hyprctl"):
        res["error"] = "hyprctl not found"
        return res
    if not sig:
        return res
    rc, out, err = run(["hyprctl", "-j", "version"])
    if rc != 0:
        res["error"] = (err.strip() or out.strip() or "hyprctl did not answer")[:160]
        return res
    try:
        res["version"] = json.loads(out).get("version") or json.loads(out).get("tag", "")
    except ValueError:
        res["error"] = "unexpected hyprctl output"
        return res
    rc, out, err = run(["hyprctl", "-j", "plugin", "list"])
    try:
        res["plugins"] = sorted(p.get("name", "") for p in json.loads(out)) if rc == 0 else None
    except (ValueError, AttributeError):
        res["plugins"] = None
    # F5a: el dialecto de la config, con la misma sonda inofensiva que services/HyprCtl (lee la respuesta:
    # el código es 0 en los dos casos)
    rc, out, err = run(["hyprctl", "eval", "local _ = 0"])
    res["dialectReply"] = (out.strip() or err.strip())[:120]
    res["dialect"] = ("lua" if res["dialectReply"] == "ok" else
                      "hyprlang" if "only supported with the lua config manager" in res["dialectReply"] else "unknown")
    return res


def q_font():
    # Catalog, aliases, requested values and icon charset coverage share one helper.
    return {"diagnostic": _sibling("font_diagnostics").detect()}


SLEEP_HOLDERS = ("hypridle", "swayidle", "xss-lock")


def _sibling(name):
    """Un módulo de scripts/ (hypridle_conf, pam_stack), también si este archivo se importa en vez de ejecutarse."""
    sys.dont_write_bytecode = True
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    return importlib.import_module(name)


def q_lock():
    """F5d: quién atiende `lock-session` (scripts/hypridle_conf.py), si Hyprland deja retomar un bloqueo y quién retiene
    la suspensión (un inhibidor sleep/delay de un demonio de bloqueo)."""
    hypridle_conf = _sibling("hypridle_conf")
    try:
        res = hypridle_conf.report()
    except Exception as e:      # una config rara no tumba el informe
        res = {"listener": "unknown", "error": "%s: %s" % (type(e).__name__, e)}
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") and which("hyprctl"):
        rc, out, _ = run(["hyprctl", "-j", "getoption", "misc:allow_session_lock_restore"])
        try:
            o = json.loads(out)
            v = o.get("bool", o.get("int"))
            res["restore"] = bool(v) if v is not None else None
        except ValueError:
            res["restore"] = None
    if which("busctl"):
        rc, out, _ = run(["busctl", "--system", "--json=short", "call", "org.freedesktop.login1", "/org/freedesktop/login1",
                          "org.freedesktop.login1.Manager", "ListInhibitors"])
        try:
            rows = json.loads(out)["data"][0]
            res["sleepHeldBy"] = sorted({r[1] for r in rows if r[1] in SLEEP_HOLDERS and r[3] == "delay"
                                         and "sleep" in str(r[0]).split(":") and r[4] == os.getuid()})
        except (ValueError, KeyError, IndexError, TypeError):
            res["sleepHeldBy"] = None
    return res


# ---- instalación (F6b) ---------------------------------------------------------------------------
#
# Medido en F6a (portabilidad/REGISTRO.md §F6a): `qs -c sumi` busca <dir>/quickshell/sumi/shell.qml en
# $XDG_CONFIG_HOME y después en cada $XDG_CONFIG_DIRS (por defecto /etc/xdg); un <dir>/quickshell/shell.qml (config
# «default») hace que en ESE directorio no se miren subdirectorios. La instancia se identifica por la RUTA de su
# shell.qml (sin resolver enlaces): un cliente (`qs -c sumi ipc …`, `-n`) sólo encuentra la instancia cuya ruta
# coincide con la que él resuelve. Por eso lo que cuenta es la instancia viva (`qs list`), no qué directorios existen.

SHELL_DIR = ""       # --shell-dir: el árbol de la shell que pidió el informe (Quickshell.shellDir); vacío = sin shell


def tree_version(tree):
    try:
        with open(os.path.join(tree, "version.json")) as f:
            d = json.load(f)
        return d.get("version"), d.get("apiVersion")
    except (OSError, ValueError, AttributeError):
        return None, None


def q_install():
    home_cfg = CONFIG
    dirs = [d for d in (os.environ.get("XDG_CONFIG_DIRS") or "/etc/xdg").split(":") if os.path.isabs(d)]
    copies, resolved = [], None
    for i, d in enumerate([home_cfg] + dirs):
        qdir = os.path.join(d, "quickshell")
        default = os.path.join(qdir, "shell.qml")
        tree = os.path.join(qdir, "sumi")
        has_default = os.path.isfile(default)
        if os.path.isfile(os.path.join(tree, "shell.qml")):
            copies.append({"path": tree, "scope": "user" if i == 0 else "system",
                           "hiddenBy": default if has_default else "",
                           "link": os.path.realpath(tree) if os.path.islink(tree) else ""})
            if resolved is None and not has_default:
                resolved = tree
        elif has_default and i == 0:
            copies.append({"path": tree, "scope": "user", "hiddenBy": default, "absent": True, "link": ""})
    rc, out, err = run(["qs", "list", "-a", "-j"])
    if rc is None or rc != 0:
        return {"copies": copies, "resolved": resolved, "error": (err or out).strip()[:160] or "qs list failed"}
    out = out.strip()
    if not out.startswith("["):
        instances = []         # «No running instances.»
    else:
        try:
            instances = json.loads(out)
        except ValueError:
            return {"copies": copies, "resolved": resolved, "error": "qs list printed something unexpected"}
    shells = [{"path": os.path.dirname(i.get("config_path", "")), "pid": i.get("pid")}
              for i in instances if i.get("config_path", "").endswith("/sumi/shell.qml")]
    # Sumi Shell (2026-11-07): la shell con su nombre de antes (quickshell/kitasan). Con ella viva, instalar, migrar o
    # arrancar ésta dejaría DOS shells (dos juegos de atajos, dos servidores de notificaciones, dos agentes polkit).
    legacy = [{"path": os.path.dirname(i.get("config_path", "")), "pid": i.get("pid")}
              for i in instances if i.get("config_path", "").endswith("/kitasan/shell.qml")]
    legacy_copies = [os.path.join(d, "quickshell", "kitasan") for d in [home_cfg] + dirs
                     if os.path.isfile(os.path.join(d, "quickshell", "kitasan", "shell.qml"))]
    return {"copies": copies, "resolved": resolved, "instances": shells, "legacyInstances": legacy,
            "legacyCopies": legacy_copies}


def _sd_value(v):
    """Un valor de `systemctl show-environment`: los que llevan caracteres especiales salen como $'…'."""
    if not (v.startswith("$'") and v.endswith("'")):
        return v
    try:
        raw = v[2:-1].encode("latin-1", "backslashreplace").decode("unicode_escape")
        return raw.encode("latin-1").decode("utf-8", "replace")
    except (UnicodeError, ValueError):
        return v


# 2026-11-09: el del gestor de usuario, para `apps.folders` (lo que heredará la shell si se reinicia).
def q_session_env():
    """El entorno del gestor de usuario (`systemctl --user show-environment`: sólo lee) o {"error": …}."""
    if not which("systemctl"):
        return {"error": "systemctl not found"}
    rc, out, err = run(["systemctl", "--user", "show-environment"])
    if rc != 0:
        return {"error": (err.strip().splitlines() or ["systemctl --user show-environment failed"])[0]}
    env = {}
    for line in out.splitlines():
        k, sep, v = line.partition("=")
        if sep and k:
            env[k] = _sd_value(v)
    return {"env": env}



QUERIES = {"units": q_units, "system": lambda: q_bus("system"), "user": lambda: q_bus("user"),
           "procs": q_procs, "hypr": q_hypr, "font": q_font, "notif": q_notif_owner, "lock": q_lock,
           "install": q_install, "sessionEnv": q_session_env}


# ---- capacidades --------------------------------------------------------------------------------

def unit_facts(q, name):
    """(installed, active, error) de una unidad de usuario."""
    u = q["units"]
    if "error" in u:
        return None, None, u["error"]
    d = u.get(name)
    if not d:
        return None, None, "no answer for " + name
    loaded = d.get("LoadState") == "loaded"
    return loaded, (d.get("ActiveState") == "active") if loaded else False, ""


def bus_facts(q, bus, name):
    b = q[bus]
    if "error" in b:
        return None, None, b["error"]
    return (name in b["activatable"] or name in b["names"]), name in b["names"], ""


def proc_running(q, pred):
    p = q["procs"]
    if "error" in p:
        return None
    return any(pred(comm, cmd) for _, comm, cmd in p["list"])


def c_dialect(q):
    """F5a: con qué dialecto hay que hablarle a Hyprland (dispatch y config en caliente; H-03)."""
    h = q["hypr"]
    if not h["signature"]:
        return cap("unavailable", "", "Not running under Hyprland", installed=bool(which("hyprctl")), session=False)
    if "error" in h:
        return cap("unknown", "", "Couldn't reach Hyprland: " + h["error"], installed=bool(which("hyprctl")), session=True)
    d = h.get("dialect")
    if d == "lua":
        return cap("available", "Lua config", installed=True, active=True, accessible=True, session=True, dialect="lua")
    if d == "hyprlang":
        # hyprlang sólo existe hasta Hyprland 0.56 (0.57 ya no lee hyprland.conf); el estado no cambia, sólo la nota
        return cap("available", "hyprland.conf", installed=True, active=True, accessible=True, session=True,
                   dialect="hyprlang", note="Legacy config, Hyprland ≤ 0.56 only; hot display tests need the Lua config")
    return cap("unknown", "", "Couldn't tell the config dialect (" + (h.get("dialectReply") or "no answer") + ")",
               installed=True, session=True, dialect="unknown")


def c_lock_pam(q):
    """F5e (H-26): la pila PAM del Lock (`shell.lock.pamService`, auto = login) y si cuenta intentos con pam_faillock."""
    svc = "auto"
    try:
        with open(os.path.join(CONFIG, "sumi-shell", "settings.json")) as f:
            v = ((json.load(f).get("shell") or {}).get("lock") or {}).get("pamService")
            if isinstance(v, str) and v:
                svc = v
    except (OSError, ValueError, AttributeError):
        pass
    name = "login" if svc == "auto" else svc
    pam_stack = _sibling("pam_stack")
    try:
        r = pam_stack.report(name)
    except Exception as e:
        return cap("unknown", name, "Couldn't read the PAM stack: %s" % e)
    detail = {"service": name, "setting": svc, "dir": r.get("dir"), "faillock": r["faillock"]["present"] if r.get("exists") else None,
              "faillockArgs": r["faillock"].get("args"), "files": r.get("files")}
    if not r.get("exists"):
        return cap("unavailable", name, "The PAM service %s doesn't exist: Sumi needs a usable PAM service to lock" % name,
                   installed=False, **detail)
    prov = name + (" · pam_faillock" if r["faillock"]["present"] else "")
    if not r["faillock"]["present"]:
        return cap("degraded", prov, "No pam_faillock in this stack: failed attempts aren't limited, so no lockout warnings",
                   installed=True, accessible=True, **detail)
    return cap("available", prov, installed=True, accessible=True, **detail)


def c_lock_entry(q):
    """F5d (H-07): quién atiende el botón Lock. La shell lo usa con `shell.lock.entry = auto` (services/LockEntry)."""
    L = q["lock"]
    listener = L.get("listener", "unknown")
    detail = {k: L.get(k) for k in ("listener", "daemon", "config", "lockCmd", "beforeSleepCmd", "inhibitSleep", "restore",
                                     "sleepHeldBy") if k in L}
    if "error" in L and listener == "unknown":
        return cap("unknown", "", "Couldn't tell who handles lock requests: " + str(L["error"])[:120], **detail)
    notes = []
    if L.get("restore") is False:
        notes.append("misc:allow_session_lock_restore is off: a crash while locked can't be taken over")
    if listener == "shell":
        prov = L.get("daemon", "hypridle") + " → Sumi Shell"
        if notes:
            return cap("degraded", prov, "; ".join(notes), installed=True, active=True, **detail)
        return cap("available", prov, installed=True, active=True, accessible=True, **detail)
    if listener == "hyprlock":
        return cap("degraded", L.get("daemon", "hypridle") + " → hyprlock",
                   "; ".join(["Lock requests and idle locking use hyprlock (hypridle's lock_cmd)"] + notes),
                   installed=True, active=True, **detail)
    if listener == "other":
        what = L.get("lockCmd") or L.get("daemon") or "another program"
        return cap("degraded", (L.get("daemon") or "?") + " → " + str(what)[:60],
                   "; ".join(["Lock requests go to another program"] + notes), installed=True, active=True, **detail)
    if listener == "none":
        why = "hypridle has no lock_cmd" if L.get("daemon") == "hypridle" else "Nothing listens for lock requests"
        return cap("degraded", "Sumi Shell (direct)",
                   "; ".join([why + ": the Lock button locks directly; nothing locks on idle or before sleep"] + notes),
                   installed=True, active=False, **detail)
    return cap("unknown", "", "Couldn't tell who handles lock requests", **detail)


def pretty_tree(p):
    return p.replace(HOME, "~", 1) if p.startswith(HOME + "/") else p


def c_install(q):
    """F6b: qué copia de la shell corre, cuáles hay, cuál resolvería un cliente desde este entorno y quién tapa a quién."""
    i = q["install"]
    copies, resolved = i.get("copies", []), i.get("resolved")
    present = [c for c in copies if not c.get("absent")]
    me = os.path.normpath(SHELL_DIR) if SHELL_DIR else ""
    scope_of = {os.path.normpath(c["path"]): c["scope"] for c in present}
    detail = {"copies": [dict(c, path=pretty_tree(c["path"])) for c in copies],
              "resolved": pretty_tree(resolved) if resolved else ""}
    if "error" in i:
        return cap("unknown", "", "Couldn't list the running shells: " + i["error"], **detail)
    shells = i["instances"]
    # La propia shell se reconoce por la ruta REAL (shellDir podría venir resuelto y qs list no resuelve enlaces); que un
    # cliente la alcance se decide con la ruta EXACTA, que es como busca qs.
    real_me = os.path.realpath(me) if me else ""
    running = [dict(s, scope=scope_of.get(os.path.normpath(s["path"]), "other"),
                    self=bool(me) and os.path.realpath(s["path"]) == real_me) for s in shells]
    detail["running"] = [dict(r, path=pretty_tree(r["path"])) for r in running]
    # La copia que hace este informe: la propia shell (--shell-dir) o, sin ella, la única que corre
    mine = [r for r in running if r["self"]]
    current = (os.path.normpath(mine[0]["path"]) if mine else me
               or (os.path.normpath(running[0]["path"]) if len(running) == 1 else ""))
    vt = current or (os.path.normpath(resolved) if resolved else "")
    if vt:
        v, api = tree_version(vt)
        detail.update(version=v or "", apiVersion=api)
    hidden = [c for c in present if c["hiddenBy"]]
    shadowed = [c for c in present if resolved and os.path.normpath(c["path"]) != os.path.normpath(resolved)
                and not c["hiddenBy"]]
    detail["hidden"] = [pretty_tree(c["path"]) for c in hidden]
    detail["shadowed"] = [pretty_tree(c["path"]) for c in shadowed]
    reachable = bool(current and resolved and os.path.normpath(resolved) == current)
    detail["reachable"] = reachable
    where = pretty_tree(current or resolved or "")
    scope = scope_of.get(current or (os.path.normpath(resolved) if resolved else ""), "other")
    ver = (" · %s (API %s)" % (detail["version"], detail.get("apiVersion"))) if detail.get("version") else ""
    provider = ("%s (%s)%s" % (where, scope, ver)) if where else ""
    if not present and not running:
        return cap("unavailable", "", "No Sumi Shell copy found in the config directories", installed=False, **detail)
    if len(running) > 1:
        return cap("degraded", provider, "%d shells are running at once: %s" % (
            len(running), ", ".join(pretty_tree(r["path"]) for r in running)), installed=True, active=True, **detail)
    if current and not reachable:
        # La shell informa con SU entorno: el remedio es reiniciarla. Un informe suelto (install.sh check, una terminal)
        # puede tener otro XDG_CONFIG_HOME/XDG_CONFIG_DIRS que la shell: también puede ser eso.
        fix = "restart the shell" if me else "restart the shell, or run this with the shell's XDG_CONFIG_HOME/XDG_CONFIG_DIRS"
        if resolved:
            why = "Commands from this session reach %s, not the running copy: %s" % (pretty_tree(resolved), fix)
        else:
            why = "Commands from this session find no Sumi Shell copy: %s" % fix
        return cap("degraded", provider, why, installed=True, active=bool(running), accessible=False, **detail)
    if hidden:
        c0 = hidden[0]
        return cap("degraded", provider, "%s is hidden by %s" % (pretty_tree(c0["path"]), pretty_tree(c0["hiddenBy"])),
                   installed=True, active=bool(running), accessible=reachable or None, **detail)
    if not running:
        return cap("available", provider + " · not running", "", installed=True, active=False, **detail)
    if shadowed:
        provider += " · hides " + ", ".join(pretty_tree(c["path"]) for c in shadowed)
    return cap("available", provider, "", installed=True, active=True, accessible=True, **detail)


def c_session(q):
    h = q["hypr"]
    if not h["signature"]:
        desk = h["desktop"] or "unknown desktop"
        return cap("unavailable", "", "Not running under Hyprland (" + desk + ")",
                   installed=bool(which("hyprctl")), active=False, session=False)
    if "error" in h:
        return cap("unknown", "Hyprland", "Couldn't reach Hyprland: " + h["error"],
                   installed=bool(which("hyprctl")), session=True)
    return cap("available", "Hyprland " + str(h.get("version", "")).strip(), installed=True,
               active=True, accessible=True, session=True)


def c_systemd(q):
    u = q["units"]
    if "error" in u:
        # F8b: sólo un bus consultado con éxito, sin dueño NI activación, prueba
        # que no hay gestor. Faltar systemctl o perder acceso al bus no lo prueba.
        b = q.get("user", {"error": "session bus not checked"})
        name = "org.freedesktop.systemd1"
        if "error" not in b and name not in b["names"] and name not in b["activatable"]:
            return cap("unavailable", "systemd (user)", "No user service manager on the session bus",
                       installed=bool(which("systemctl")), active=False, accessible=True,
                       managerAbsent=True, scope="user")
        return cap("unknown", "systemd", "Couldn't query the user service manager: " + u["error"],
                   installed=bool(which("systemctl")))
    return cap("available", "systemd (user)", installed=True, active=True, accessible=True)


def c_systemd_system(q):
    """El gestor del sistema es independiente del gestor de usuario y de elogind."""
    b = q["system"]
    name = "org.freedesktop.systemd1"
    if "error" in b:
        return cap("unknown", "systemd (system)", "Couldn't query D-Bus: " + b["error"])
    if name in b["names"]:
        return cap("available", "systemd (system)", installed=True, active=True, accessible=True)
    if name not in b["activatable"]:
        return cap("unavailable", "systemd (system)", "No system service manager on the system bus",
                   installed=False, active=False, accessible=True, managerAbsent=True, scope="system")
    return cap("unknown", "systemd (system)", "System service manager is activatable but not running",
               installed=True, active=False, accessible=True)


def c_bus_service(q, bus, names, provider, missing):
    """Un servicio del bus: activo = alguien tiene el nombre; instalado = activable o activo."""
    err = ""
    installed = active = False
    for n in names:
        i, a, e = bus_facts(q, bus, n)
        if e:
            err = e
            break
        installed, active = installed or i, active or a
    if err:
        return cap("unknown", provider, "Couldn't query D-Bus: " + err)
    if active:
        return cap("available", provider, installed=True, active=True, accessible=True)
    return cap("unavailable", provider, missing if not installed else provider + " is not running",
               installed=installed, active=False)


def c_python(q):
    v = sys.version_info
    ver = "%d.%d.%d" % (v.major, v.minor, v.micro)
    if v < (3, 11):
        return cap("degraded", "Python " + ver, OLD_PYTHON,
                   installed=True, active=True, version=ver)
    return cap("available", "Python " + ver, installed=True, active=True, version=ver)


def c_power_profiles(q):
    """El binding de Quickshell usa la API moderna, no el antiguo alias de hadess."""
    current = c_bus_service(q, "system", ("org.freedesktop.UPower.PowerProfiles",),
                            "power-profiles-daemon", "No power profiles daemon is installed")
    if current["state"] == "unavailable":
        installed, active, error = bus_facts(q, "system", "net.hadess.PowerProfiles")
        if not error and (installed or active):
            return cap("unavailable", "power-profiles-daemon",
                       "This Quickshell backend needs the org.freedesktop.UPower.PowerProfiles API; update the power daemon",
                       installed=True, active=active)
    return current


def c_font(q):
    f = q["font"]
    if "error" in f:
        return cap("unknown", FONT, "Couldn't check fonts: " + f["error"])
    diagnostic = f.get("diagnostic", {})
    if diagnostic:
        provider = "UI / code / icons"
        if diagnostic.get("state") == "unknown" or diagnostic.get("settings") == "unknown":
            return cap("unknown", provider, "Font diagnostics unavailable; preferences preserved", detail=diagnostic)
        if diagnostic.get("state") == "unavailable":
            return cap("unavailable", provider, "No font covers all Icon.qml glyphs; text fallback active", installed=False, detail=diagnostic)
        missing = [role for role, value in diagnostic.get("roles", {}).items() if not value["available"]]
        if missing:
            return cap("degraded", provider, "Requested " + ", ".join(missing) + " font absent; fallback active", detail=diagnostic)
        return cap("available", provider, installed=True, detail=diagnostic)
    if f["found"]:
        return cap("available", FONT, installed=True)
    return cap("unavailable", FONT, FONT + " is not installed · icons will show as empty boxes",
               installed=False)


OLD_PYTHON = "Python 3.11 or newer is needed for the theme tools"


# F4d: el tema sigue al proveedor elegido (providers.theme). `script` = las órdenes de providers.json (las del
# autor: matugen_reload.sh y apply-static-colors.sh, con su config de matugen); `static` = sólo la paleta
# estática; `auto`/`matugen` = el propio (scripts/theme-provider.py) con la config que el usuario declare en
# providers.json o, si no, la mínima del proyecto (sólo la paleta de la shell).
def theme_choice():
    v = os.environ.get("KT_CAPS_PROVIDER_THEME")
    return v if v else provider_settings()["theme"]


def theme_declared():
    pv = load_providers(with_raw=True)
    return pv, pv["raw"].get("theme")


def theme_script(prov, verb):
    """El argv del script que hace `verb` (sin «~/» expandido), o None."""
    for sc in (prov or {}).get("scripts", []):
        if verb in sc["supports"]:
            return [expand_home(a) for a in sc["argv"]]
    return None


def argv_missing(argv):
    a0 = argv[0]
    if not (resolve_bin(a0) if (a0.startswith("/") or PROGRAM.match(a0)) else None):
        return os.path.basename(a0) + " (from providers.json) is not installed"
    for a in argv[1:]:
        if a.startswith("/") and not os.path.exists(a):
            return a.replace(HOME, "~") + " (from providers.json) is missing"
    return ""


def theme_config(prov):
    if os.environ.get("MATUGEN_CONFIG"):
        return os.environ["MATUGEN_CONFIG"]
    if prov and isinstance(prov.get("matugenConfig"), str):
        return expand_home(prov["matugenConfig"])
    return os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "templates", "matugen-config.toml")


def c_theme_dynamic(q):
    choice = theme_choice()
    pv, prov = theme_declared()
    if sys.version_info < (3, 11):      # theme-preview.py y theme_paths.py usan tomllib
        return cap("unavailable", "matugen", OLD_PYTHON, installed=bool(which("matugen")))
    if choice == "static":
        return cap("unavailable", "", "Colours from the wallpaper are turned off in Settings (Shell → Apps)", installed=False)
    if choice == "script":
        argv = theme_script(prov, "reload")
        if not argv:
            why = pv["reason"] or ("providers.json is not set up" if pv["status"] == "none"
                                   else "providers.json does not declare a theme reload")
            return cap("unavailable", "providers.json", why, installed=False)
        miss = argv_missing(argv)
        if miss:
            return cap("unavailable", "providers.json", miss, installed=False)
        provider = (prov.get("label") if prov else "") or "script"
    else:
        provider = "matugen"
    if not which("matugen"):
        return cap("unavailable", "matugen", "matugen is not installed", installed=False)
    cfg_path = theme_config(prov)
    if not is_file(cfg_path):
        return cap("unavailable", provider, "No matugen config at " + cfg_path.replace(HOME, "~"), installed=True)
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from theme_paths import load_matugen_config
        cfg = load_matugen_config(cfg_path)
    except ImportError as e:
        return cap("unknown", provider, "Couldn't load theme_paths.py: " + str(e)[:120], installed=True)
    except (OSError, ValueError) as e:
        return cap("unavailable", provider, "The matugen config can't be read: " + str(e)[:120],
                   installed=True, accessible=False)
    target = os.path.normpath(os.path.join(STATE, "sumi-shell", "colors.json"))
    outs = [t.get("output_path") for t in cfg.get("templates", {}).values() if isinstance(t, dict)]
    if target not in outs:
        return cap("degraded", provider, "The matugen config has no template for the shell's colours",
                   installed=True, accessible=True)
    own = os.path.basename(cfg_path) == "matugen-config.toml" and os.path.dirname(cfg_path).endswith("templates")
    return cap("available", provider, installed=True, accessible=True, config=cfg_path.replace(HOME, "~"),
               ownConfig=own, kind="script" if choice == "script" else "builtin")


def c_theme_static(q):
    choice = theme_choice()
    if sys.version_info < (3, 11):
        return cap("unavailable", "", OLD_PYTHON)
    if choice == "script":
        pv, prov = theme_declared()
        argv = theme_script(prov, "staticList")
        if not argv:
            why = pv["reason"] or ("providers.json is not set up" if pv["status"] == "none"
                                   else "providers.json does not declare a static palette list")
            return cap("unavailable", "providers.json", why, installed=False)
        miss = argv_missing(argv)
        if miss:
            return cap("unavailable", "providers.json", miss, installed=False)
        script = next((a for a in argv if a.endswith(".sh")), "")
        if script:
            try:
                with open(script) as f:
                    listed = '"--list"' in f.read()
            except OSError:
                listed = False
            if not listed:
                return cap("unavailable", os.path.basename(script), os.path.basename(script) + " is too old (no --list)",
                           installed=True, accessible=False)
        return cap("available", os.path.basename(script) if script else (prov.get("label") or "script"),
                   installed=True, accessible=True, kind="script")
    static = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "colors.static.json")
    if not is_file(static):
        return cap("unavailable", "Sumi Shell", "colors.static.json is missing from the shell", installed=False)
    return cap("available", "Sumi Shell", installed=True, accessible=True, kind="builtin")


def c_gtk(q):
    if which("gsettings"):
        return cap("available", "gsettings", installed=True)
    return cap("degraded", "", "gsettings not found · GTK apps keep their light or dark mode",
               installed=False)


# F4b: los fondos siguen al proveedor elegido (providers.wallpaper): `script` = la orden de
# providers.json (sólo se comprueba que exista: el backend es cosa del script), `none` = apagado, y el
# resto = el proveedor propio (scripts/wallpaper-provider.py, que es quien resuelve el backend: aquí se
# importa su `resolve` para no tener dos listas). Detectar no arranca nada: un daemon parado no
# desactiva, porque el proveedor propio lo arranca al aplicar.
def wall_choice():
    v = os.environ.get("KT_CAPS_PROVIDER_WALLPAPER")
    return v if v else provider_settings()["wallpaper"]


_WP = None


def wall_module():
    global _WP
    if _WP is None:
        spec = importlib.util.spec_from_file_location(
            "kt_wallpaper_provider", os.path.join(os.path.dirname(os.path.abspath(__file__)), "wallpaper-provider.py"))
        _WP = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_WP)
    return _WP


def wall_script(verbs):
    """(proveedor declarado, por qué no) para el tipo wallpaper con alguno de `verbs`."""
    pv = load_providers(with_raw=True)
    prov = pv["raw"].get("wallpaper")
    if not prov:
        err = [e["error"] for e in pv["errors"] if e["kind"] == "wallpaper"]
        why = pv["reason"] or ("providers.json: wallpaper is invalid (%s)" % err[0] if err
                               else "providers.json is not set up" if pv["status"] == "none"
                               else "providers.json does not declare a wallpaper provider")
        return None, why
    script = next((sc for sc in prov["scripts"] if any(v in sc["supports"] for v in verbs)), None)
    if not script:
        return None, "The wallpaper provider in providers.json does not do " + verbs[0]
    a0 = expand_home(script["argv"][0])
    if not (resolve_bin(a0) if (a0.startswith("/") or PROGRAM.match(a0)) else None):
        return None, os.path.basename(a0) + " (from providers.json) is not installed"
    for a in script["argv"][1:]:
        a = expand_home(a)
        if a.startswith("/") and not os.path.exists(a):
            return None, a.replace(HOME, "~") + " (from providers.json) is missing"
    return dict(prov, script=script), ""


def c_wall_apply(q):
    choice = wall_choice()
    if choice == "none":
        return cap("unavailable", "", "Wallpapers are turned off in Settings (Shell → Apps)", installed=False)
    if choice == "script":
        prov, why = wall_script(["apply"])
        if not prov:
            return cap("unavailable", "providers.json", why, installed=False)
        return cap("available", prov.get("label") or "script", installed=True,
                   transitions="transition" in prov["script"]["supports"], kind="script")
    r = wall_module().resolve(choice)
    b = r["backend"]
    if not b:
        return cap("unavailable", choice if choice != "auto" else "", r["why"], installed=False, found=r["found"])
    # ¿contesta un daemon en ESTA pantalla? (su socket; no los procesos de todo el sistema: el de otra
    # sesión o de otro compositor no sirve). No corre: se arranca al aplicar (no es un fallo).
    running = wall_module().daemon_running(b)
    return cap("available", b, installed=True, active=running, kind="builtin", choice=choice, found=r["found"],
               transitions=b != "hyprpaper", startsOnApply=not running)


def c_wall_video(q):
    choice = wall_choice()
    if choice == "none":
        return cap("unavailable", "", "Wallpapers are turned off in Settings (Shell → Apps)", installed=False)
    if choice == "script":
        prov, why = wall_script(["apply"])
        if not prov:
            return cap("unavailable", "providers.json", why, installed=False)
        return cap("available", prov.get("label") or "script", installed=True, kind="script")
    r = wall_module().resolve(choice)
    if not r["backend"]:
        return cap("unavailable", "", r["why"], installed=False)
    if not which("mpvpaper"):
        return cap("unavailable", "mpvpaper", "mpvpaper is not installed · videos can't be applied",
                   installed=False)
    return cap("available", "mpvpaper", installed=True, kind="builtin")


# F4c: las miniaturas siguen al proveedor elegido (providers.thumbnails): `script` = la orden declarada (la
# del autor: systemctl --user start thumbs-refresh.service), `none` = apagado, y si no, el generador propio
# (scripts/thumbnail-provider.py: ImageMagick para imágenes; ffmpegthumbnailer o ffmpeg para vídeos).
def thumbs_choice():
    v = os.environ.get("KT_CAPS_PROVIDER_THUMBNAILS")
    return v if v else provider_settings()["thumbnails"]


def c_wall_thumbs(q):
    choice = thumbs_choice()
    if choice == "none":
        return cap("unavailable", "", "Thumbnails are turned off in Settings (Shell → Apps)", installed=False)
    if choice == "script":
        pv = load_providers(with_raw=True)
        prov = pv["raw"].get("thumbnails")
        if not prov:
            why = pv["reason"] or ("providers.json is not set up" if pv["status"] == "none"
                                   else "providers.json does not declare a thumbnails provider")
            return cap("unavailable", "providers.json", why, installed=False)
        a0 = expand_home(prov["scripts"][0]["argv"][0])
        if not (resolve_bin(a0) if (a0.startswith("/") or PROGRAM.match(a0)) else None):
            return cap("unavailable", "providers.json", os.path.basename(a0) + " (from providers.json) is not installed",
                       installed=False)
        return cap("available", prov.get("label") or "script", installed=True, kind="script")
    im = which("magick") or which("convert")
    if not im:
        return cap("unavailable", "ImageMagick", "ImageMagick is not installed", installed=False)
    vid = "ffmpegthumbnailer" if which("ffmpegthumbnailer") else "ffmpeg" if which("ffmpeg") else ""
    if not vid:
        return cap("degraded", os.path.basename(im), "ffmpegthumbnailer and ffmpeg are not installed · no video thumbnails",
                   installed=True, kind="builtin")
    return cap("available", os.path.basename(im) + " + " + vid, installed=True, kind="builtin")


def c_wall_video_pause(q):
    choice = wall_choice()
    if choice == "none":
        return cap("unavailable", "", "Wallpapers are turned off in Settings (Shell → Apps)", installed=False)
    if choice == "script":
        prov, why = wall_script(["pauseStatus", "pauseRestore"])
        if not prov or not all(v in prov["script"]["supports"] for v in ("pauseStatus", "pauseRestore")):
            return cap("unavailable", "providers.json", why or "The wallpaper provider in providers.json does not pause videos",
                       installed=False)
        return cap("available", os.path.basename(expand_home(prov["script"]["argv"][-1])), installed=True, kind="script")
    if not which("mpvpaper"):
        return cap("unavailable", "", "mpvpaper is not installed · no video wallpaper to pause", installed=False)
    return cap("available", "mpvpaper", installed=True, kind="builtin")


def c_downloads(q):
    miss = missing_bins(("curl", "identify"))
    if miss:
        return cap("unavailable", "curl + ImageMagick", not_installed(miss), installed=False)
    return cap("available", "curl + ImageMagick", installed=True)


# F4e: las actualizaciones siguen al proveedor elegido (providers.updates): `script` = las órdenes de
# providers.json (las del autor: updates-check.service y updates.sh), `none` = no hay fuente, y si no el propio
# (scripts/updates-provider.py: pacman + AUR). Detectar no comprueba nada.
def updates_choice():
    v = os.environ.get("KT_CAPS_PROVIDER_UPDATES")
    return v if v else provider_settings()["updates"]


def c_updates(q):
    choice = updates_choice()
    if choice == "none":
        return cap("unavailable", "", "Updates are turned off in Settings (Shell → Apps)", installed=False)
    if choice == "script":
        pv = load_providers(with_raw=True)
        prov = pv["raw"].get("updates")
        if not prov:
            why = pv["reason"] or ("Updates are not set up (providers.json is not set up)" if pv["status"] == "none"
                                   else "providers.json does not declare an updates provider")
            return cap("unavailable", "providers.json", why, installed=False)
        for sc in prov.get("scripts", []):
            miss = argv_missing([expand_home(a) for a in sc["argv"]])
            if miss:
                return cap("unavailable", "providers.json", miss, installed=False)
        # sysupdate (opcional): con él la shell ofrece «Safe upgrade» cuando la caché trae un riesgo
        return cap("available", prov.get("label") or "script", installed=True, kind="script",
                   sysupdate=bool(which("sysupdate")))
    spec = importlib.util.spec_from_file_location(
        "kt_updates_provider", os.path.join(os.path.dirname(os.path.abspath(__file__)), "updates-provider.py"))
    up = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(up)
    r = up.resolve()
    if not r["backend"]:
        return cap("unavailable", "", r["why"], installed=False)
    return cap("available", r["label"], installed=True, kind="builtin", aur=r["aur"],
               sysupdate=bool(which("sysupdate")))


# F3b (H-28): las terminales que se buscan con apps.terminal = auto, en orden (lib/terminal.js LIST)
TERMINALS = ("foot", "kitty", "alacritty", "wezterm", "ghostty", "konsole", "gnome-terminal")
TERMINAL_HINT = "choose one in Settings → Shell → Apps"


def app_setting(key, env):
    """apps.<key>. La shell la pasa en el entorno (lo que tiene en memoria, sin esperar al guardado);
    fuera de la shell, se lee de settings.json. Sin nada: auto."""
    v = os.environ.get(env)
    if v is None:
        try:
            with open(os.path.join(CONFIG, "sumi-shell", "settings.json")) as f:
                v = (json.load(f).get("apps") or {}).get(key)
        except (OSError, ValueError, AttributeError):
            v = None
    return v if isinstance(v, str) and v else "auto"


def terminal_setting():
    return app_setting("terminal", "KT_CAPS_TERMINAL")


def resolve_bin(v):
    if v.startswith("/"):
        return v if os.path.isfile(v) and os.access(v, os.X_OK) else None
    return which(v)


def c_terminal(q):
    """F3b: la terminal del usuario. Explícita: tiene que existir. auto: xdg-terminal-exec → $TERMINAL
    (su primera palabra; bajo systemd no suele llegar) → TERMINALS. `found` = las de la lista instaladas."""
    setting = terminal_setting()
    found = [n for n in TERMINALS if which(n)]
    if setting != "auto":
        name = os.path.basename(setting)
        if resolve_bin(setting):
            return cap("available", name, installed=True, bin=setting, name=name, source="settings",
                       setting=setting, found=found)
        return cap("unavailable", name, name + " is not installed · " + TERMINAL_HINT, installed=False,
                   bin=setting, name=name, source="settings", setting=setting, found=found)
    if which("xdg-terminal-exec"):
        return cap("available", "xdg-terminal-exec", installed=True, bin="xdg-terminal-exec",
                   name="xdg-terminal-exec", source="xdg-terminal-exec", setting="auto", found=found)
    env = (os.environ.get("TERMINAL") or "").split()
    if env and resolve_bin(env[0]):
        name = os.path.basename(env[0])
        return cap("available", name, installed=True, bin=env[0], name=name, source="TERMINAL",
                   setting="auto", found=found)
    if found:
        return cap("available", found[0], installed=True, bin=found[0], name=found[0], source="list",
                   setting="auto", found=found)
    return cap("unavailable", "terminal", "No terminal was found · install one (foot, kitty, alacritty…)",
               installed=False, setting="auto", found=[])


# F3c (HC-13): los navegadores que se ofrecen en Settings si están instalados. La detección «auto» NO
# los recorre: auto = $BROWSER (bajo systemd no suele llegar) → xdg-open, como antes.
BROWSERS = ("firefox", "zen-browser", "librewolf", "chromium", "google-chrome-stable", "brave",
            "vivaldi-stable", "epiphany", "falkon", "qutebrowser")


def c_browser(q):
    """F3c: el navegador del web hub. Explícito: tiene que existir. auto: $BROWSER (tal cual, como lo
    lanza la shell) → xdg-open."""
    setting = app_setting("browser", "KT_CAPS_BROWSER")
    found = [n for n in BROWSERS if which(n)]
    if setting != "auto":
        name = os.path.basename(setting)
        if resolve_bin(setting):
            return cap("available", name, installed=True, bin=setting, name=name, source="settings",
                       setting=setting, found=found)
        return cap("unavailable", name, name + " is not installed · choose one in Settings → Shell → Apps",
                   installed=False, bin=setting, name=name, source="settings", setting=setting, found=found)
    env = os.environ.get("BROWSER") or ""
    if env and resolve_bin(env):
        name = os.path.basename(env)
        return cap("available", name, installed=True, bin=env, name=name, source="BROWSER",
                   setting="auto", found=found)
    if which("xdg-open"):
        return cap("available", "xdg-open", installed=True, bin="xdg-open", name="xdg-open", source="xdg-open",
                   setting="auto", found=found)
    return cap("unavailable", "browser", "Neither $BROWSER nor xdg-open is available · choose a browser in "
               "Settings → Shell → Apps", installed=False, setting="auto", found=found)


# ---- carpetas de aplicaciones (2026-11-09) ---------------------------------------------------------------
# El lanzador lista lo que da `DesktopEntries` de Quickshell, que busca los .desktop en las carpetas XDG del
# ENTORNO DEL PROCESO, fijado al arrancar. Si después cambia el del gestor de usuario (el caso medido: instalar
# flatpak con la shell en marcha; su generador `60-flatpak` añade /var/lib/flatpak/exports/share a XDG_DATA_DIRS
# con el daemon-reload del hook de pacman), las apps de las carpetas nuevas no aparecen hasta reiniciar la shell.
# Las altas y bajas DENTRO de las carpetas ya conocidas sí llegan solas (medido con qs 0.3.2).
XDG_DATA_DIRS_DEFAULT = "/usr/local/share:/usr/share"


def xdg_app_dirs(env):
    """Las carpetas de datos donde se buscan aplicaciones según `env`, en el orden de la especificación XDG Base
    Directory: XDG_DATA_HOME y después XDG_DATA_DIRS; vacías o ausentes, sus valores por defecto. Las relativas
    no valen (la especificación manda ignorarlas). Normalizadas y sin repetir."""
    home = env.get("HOME") or HOME
    data_home = env.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share")
    out = []
    for d in [data_home] + (env.get("XDG_DATA_DIRS") or XDG_DATA_DIRS_DEFAULT).split(":"):
        if d and os.path.isabs(d):
            d = os.path.normpath(d)
            if d not in out:
                out.append(d)
    return out


def read_environ(pid):
    """El entorno con el que arrancó `pid` (/proc/<pid>/environ) o None si no se puede leer."""
    try:
        with open(os.path.join(PROC, str(pid), "environ"), "rb") as f:
            raw = f.read()
    except OSError:
        return None
    env = {}
    for item in raw.split(b"\0"):
        k, sep, v = item.partition(b"=")
        if sep and k:
            env[k.decode("utf-8", "replace")] = v.decode("utf-8", "replace")
    return env


def count_desktop_files(data_dir):
    n = 0
    for _dirpath, _dirs, files in os.walk(os.path.join(data_dir, "applications")):
        n += sum(1 for f in files if f.endswith(".desktop"))
    return n


def c_app_folders(q):
    """¿Ve la shell en marcha las carpetas de aplicaciones que la sesión tiene ahora? Compara su entorno de
    arranque (/proc/<pid>/environ: desde la shell, KT_CAPS_SHELL_PID; desde `install.sh check`, la instancia
    que corre) con el del gestor de usuario. Sólo si la shell es un servicio de usuario (INVOCATION_ID): lanzada
    fuera de systemd, el entorno del gestor no es el suyo y no hay nada que comparar."""
    pid = os.environ.get("KT_CAPS_SHELL_PID", "")
    if not pid:
        inst = q["install"].get("instances") or []
        mine = [i for i in inst if SHELL_DIR and i.get("path") == SHELL_DIR] or inst
        if len(mine) != 1:
            if not mine and "error" not in q["install"]:
                return cap("available", "shell not running", installed=True, active=False)
            return cap("unknown", "", "Couldn't tell which running shell to check", installed=True)
        pid = str(mine[0].get("pid") or "")
    shell_env = read_environ(pid) if pid.isdigit() else None
    if shell_env is None:
        return cap("unknown", "", "Couldn't read the running shell's environment", installed=True)
    shell_dirs = xdg_app_dirs(shell_env)
    if not shell_env.get("INVOCATION_ID"):
        return cap("available", "%d app folders" % len(shell_dirs), installed=True, active=True,
                   folders=shell_dirs, compared=False)
    s = q["sessionEnv"]
    if "error" in s:
        return cap("unknown", "%d app folders" % len(shell_dirs),
                   "Couldn't read the user service manager's environment: " + s["error"], installed=True,
                   folders=shell_dirs)
    session_dirs = xdg_app_dirs(s["env"])
    missing = [d for d in session_dirs if d not in shell_dirs]
    if not missing:
        return cap("available", "%d app folders" % len(shell_dirs), installed=True, active=True,
                   accessible=True, folders=shell_dirs, compared=True)
    apps = sum(count_desktop_files(d) for d in missing)
    what = ("%d app there is" % apps if apps == 1 else "%d apps there are" % apps) if apps else "apps installed there will be"
    return cap("degraded", "%d of %d app folders" % (len(session_dirs) - len(missing), len(session_dirs)),
               "The shell started before %s joined the session's app folders: %s missing from the launcher "
               "until the shell restarts" % (", ".join(pretty(d) for d in missing), what),
               installed=True, active=True, accessible=False, folders=shell_dirs, sessionFolders=session_dirs,
               missing=missing, missingApps=apps, compared=True)


# ---- F3d-1: las tareas declaradas (tasks.json) -----------------------------------------------------
TASK_ID = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
PROGRAM = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._+-]{0,127}$")


def tasks_path():
    return os.environ.get("KT_CAPS_TASKS") or os.path.join(CONFIG, "sumi-shell", "tasks.json")


def expand_home(p):
    return HOME + p[1:] if p.startswith("~/") else p


def pretty(p):
    return "~" + p[len(HOME):] if p.startswith(HOME + "/") else p


def load_tasks():
    """Las tareas de tasks.json que la shell aceptaría, con la MISMA regla que services/Tasks.qml: sólo
    si el archivo es del usuario y nadie más puede escribirlo. La validación completa es la de
    lib/tasks-schema.js; aquí basta lo necesario para comprobar su orden y sus requisitos.
    Devuelve (tareas, motivo por el que se ignora el archivo o "")."""
    p = tasks_path()
    try:
        st = os.stat(p)
    except FileNotFoundError:
        return [], ""
    except OSError:
        return [], "tasks.json could not be read"
    if st.st_uid != os.getuid():
        return [], "tasks.json is ignored: it does not belong to you"
    if st.st_mode & 0o022:
        return [], "tasks.json is ignored: other users can change it (chmod go-w)"
    try:
        with open(p) as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return [], "tasks.json is not valid JSON"
    raw = doc.get("tasks") if isinstance(doc, dict) else None
    out, seen = [], set()
    for t in raw if isinstance(raw, list) else []:
        if not isinstance(t, dict) or not isinstance(t.get("id"), str) or not TASK_ID.match(t["id"]):
            continue
        argv = t.get("argv")
        if t["id"] in seen or not isinstance(argv, list) or not argv or not isinstance(argv[0], str):
            continue
        seen.add(t["id"])
        out.append(t)
    return out, ""


# F4a: providers.json, con la MISMA regla y el mismo esquema que services/Providers.qml y
# lib/providers-schema.js (que mandan). Aquí es diagnóstico: qué declara y por qué se ignora, también
# cuando la shell no arranca. Las capacidades wallpaper.*, theme.* y system.updates siguen al proveedor
# elegido desde F4b–F4e; en F4a no cambian.
PROVIDER_VERBS = {
    "wallpaper": ("apply", "applyOutput", "clear", "sync", "restore", "pauseStatus", "pauseRestore"),
    "theme": ("reload", "toggle", "staticList"),
    "thumbnails": ("refresh",),
    "updates": ("check", "list"),
}
PROVIDER_FLAGS = {"wallpaper": ("transition",)}
PROVIDER_PATHS = {"wallpaper": ("lockStill",), "theme": ("matugenConfig", "xsettingsConfig"), "updates": ("cache",)}
PATH_RE = re.compile(r"^(/|~/)")


def providers_path():
    return os.environ.get("KT_CAPS_PROVIDERS") or os.path.join(CONFIG, "sumi-shell", "providers.json")


def check_provider(kind, p):
    """"" si el tipo vale; si no, el motivo (el mismo criterio que checkKind en providers-schema.js)."""
    if not isinstance(p, dict):
        return "must be an object"
    for k in p:
        if k not in ("label", "scripts") + PROVIDER_PATHS.get(kind, ()):
            return "unknown key «%s»" % k
    if "label" in p and (not isinstance(p["label"], str) or not p["label"].strip() or len(p["label"]) > 80):
        return "label must be text of at most 80 characters"
    for k in PROVIDER_PATHS.get(kind, ()):
        v = p.get(k)
        if v is not None and (not isinstance(v, str) or not PATH_RE.match(v) or re.search(r"(^|/)\.\.(/|$)", v)):
            return k + " must be an absolute path"
    sc = p.get("scripts")
    if kind == "theme" and sc is None and any(isinstance(p.get(k), str) for k in PROVIDER_PATHS["theme"]):
        return ""                       # Configuración declarativa del proveedor propio.
    if not isinstance(sc, list) or not 1 <= len(sc) <= 8:
        return "scripts must be a list of 1 to 8 commands"
    seen = set()
    for i, s in enumerate(sc):
        where = "scripts[%d]" % i
        if not isinstance(s, dict):
            return where + " must be an object"
        for k in s:
            if k not in ("argv", "supports"):
                return where + ": unknown key «%s»" % k
        argv = s.get("argv")
        if not isinstance(argv, list) or not 1 <= len(argv) <= 32 or not all(isinstance(x, str) and "\0" not in x and len(x) <= 4096 for x in argv):
            return where + ".argv must be a list of 1 to 32 entries"
        if not (PROGRAM.match(argv[0]) or (PATH_RE.match(argv[0]) and not re.search(r"(^|/)\.\.(/|$)", argv[0]))):
            return where + ".argv[0] must be a program name or an absolute path"
        sup = s.get("supports")
        if not isinstance(sup, list) or not sup:
            return where + ".supports must list what it does"
        mine = []
        for v in sup:
            verb = v in PROVIDER_VERBS[kind]
            flag = v in PROVIDER_FLAGS.get(kind, ())
            if not verb and not flag:
                return where + ": «%s» is not something a %s provider does" % (v, kind)
            if v in mine:
                return where + ": «%s» is listed twice" % v
            if verb and v in seen:
                return "«%s» is declared by two commands" % v
            mine.append(v)
        for v in mine:
            if v in PROVIDER_FLAGS.get(kind, ()) and "apply" not in mine and "applyOutput" not in mine:
                return where + ": «%s» needs apply or applyOutput in the same command" % v
        seen.update(v for v in mine if v in PROVIDER_VERBS[kind])
    return ""


def load_providers(with_raw=False):
    """{status, reason, path, declared: {tipo: [verbos]}, errors: [{kind, error}]} (none/ready/invalid/
    ignored/unreadable, como Providers.qml). No ejecuta ni comprueba las órdenes: sólo el archivo."""
    p = providers_path()
    out = {"status": "none", "reason": "", "path": p, "declared": {}, "errors": []}
    if with_raw:
        out["raw"] = {}
    try:
        st = os.stat(p)
    except FileNotFoundError:
        return out
    except OSError:
        return dict(out, status="unreadable", reason="providers.json could not be read")
    if st.st_uid != os.getuid():
        return dict(out, status="ignored", reason="providers.json is ignored: it does not belong to you")
    if st.st_mode & 0o022:
        return dict(out, status="ignored", reason="providers.json is ignored: other users can change it (chmod go-w)")
    try:
        with open(p) as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return dict(out, status="invalid", reason="providers.json is not valid JSON")
    if not isinstance(doc, dict):
        return dict(out, status="invalid", reason="providers.json: the file is not a JSON object")
    v = doc.get("version")
    if v != 1:
        why = ("made for a newer version of the shell (version %s)" % v) if isinstance(v, int) and not isinstance(v, bool) and v > 1 \
            else "missing or invalid version"
        return dict(out, status="invalid", reason="providers.json: " + why)
    out["status"] = "ready"
    for kind, prov in doc.items():
        if kind == "version":
            continue
        if kind not in PROVIDER_VERBS:
            out["errors"].append({"kind": kind, "error": "unknown provider type"})
            continue
        err = check_provider(kind, prov)
        if err:
            out["errors"].append({"kind": kind, "error": err})
        else:
            out["declared"][kind] = [v for s in prov.get("scripts", []) for v in s["supports"]]
            if with_raw:
                out["raw"][kind] = prov
    return out


def provider_settings():
    """`providers.*` de settings.json (auto si falta; la shell manda sobre esto: es diagnóstico)."""
    try:
        with open(os.path.join(CONFIG, "sumi-shell", "settings.json")) as f:
            pv = json.load(f).get("providers") or {}
    except (OSError, ValueError, AttributeError):
        pv = {}
    return {k: (pv.get(k) if isinstance(pv, dict) and isinstance(pv.get(k), str) else "auto") for k in PROVIDER_VERBS}


def c_task(t):
    """Una tarea se puede si existe su argv[0] y lo que pide `requires` (nombres en el PATH o archivos)."""
    def f(q):
        label = t["label"] if isinstance(t.get("label"), str) else t["id"]
        argv0 = expand_home(t["argv"][0])
        prog = os.path.basename(argv0)
        found = resolve_bin(argv0) if (argv0.startswith("/") or PROGRAM.match(argv0)) else None
        if not found:
            return cap("unavailable", prog, prog + " is not installed", installed=False, label=label)
        for r in t.get("requires") or []:
            if not isinstance(r, str):
                continue
            if r.startswith("/") or r.startswith("~/"):
                if not is_file(expand_home(r)):
                    return cap("unavailable", prog, "Needs " + pretty(expand_home(r)), installed=True, label=label)
            elif not which(r):
                return cap("unavailable", prog, r + " is not installed", installed=True, label=label)
        return cap("available", prog, installed=True, label=label)
    return f


def c_bin(name, provider=None, reason=None):
    def f(q):
        if which(name):
            return cap("available", provider or name, installed=True)
        return cap("unavailable", provider or name, reason or name + " is not installed", installed=False)
    return f


def c_eq(q):
    if c_systemd(q)["state"] == "unavailable":
        return cap("unavailable", "filter-chain.service", "Equalizer needs a systemd user service manager",
                   installed=bool(which("pw-cli")), active=False)
    # Un binario ausente es prueba; la unidad sólo se pregunta si hace falta (F2d)
    if not which("pw-cli"):
        return cap("unavailable", "filter-chain.service", "pw-cli is not installed")
    inst, active, err = unit_facts(q, "filter-chain.service")
    if err:
        return cap("unknown", "filter-chain.service", "Couldn't check filter-chain.service: " + err)
    if not inst:
        return cap("unavailable", "filter-chain.service", "PipeWire's filter-chain.service is not installed",
                   installed=False)
    return cap("available", "filter-chain.service", installed=True, active=active)


def c_rollback(q):
    """La vuelta atrás corre en una unidad transitoria (`systemd-run --user`, sumi-guard.py)."""
    if c_systemd(q)["state"] == "unavailable":
        return cap("unavailable", "systemd-run", "Card profile test needs a systemd user service manager",
                   installed=bool(which("systemd-run")), active=False)
    miss = missing_bins(("systemd-run", "pactl", "playerctl"))
    if miss:
        return cap("unavailable", "systemd-run", not_installed(miss), installed=False)
    if "error" in q["units"]:
        return cap("unknown", "systemd-run", "Couldn't reach the user service manager: " + q["units"]["error"],
                   installed=True)
    return cap("available", "systemd-run", installed=True, accessible=True)


def c_clipboard(q):
    miss = missing_bins(("cliphist", "wl-paste", "wl-copy"))
    if miss:
        return cap("unavailable", "cliphist", not_installed(miss), installed=False)
    store = proc_running(q, lambda comm, cmd: "wl-paste" in cmd and "--watch" in cmd and "cliphist" in cmd
                         and "store" in cmd)
    if store is None:
        return cap("unknown", "cliphist", "Couldn't check whether the history is being recorded", installed=True)
    if not store:
        return cap("degraded", "cliphist", "Clipboard history is not being recorded (no cliphist store running)",
                   installed=True, active=False)
    return cap("available", "cliphist", installed=True, active=True)


def typelib(name):
    dirs = [d for d in os.environ.get("GI_TYPELIB_PATH", "").split(":") if d]
    dirs += ["/usr/lib/girepository-1.0", "/usr/lib64/girepository-1.0"]
    dirs += glob.glob("/usr/lib/*-linux-gnu*/girepository-1.0")
    return any(os.path.isfile(os.path.join(d, name)) for d in dirs)


def c_network_edit(q):
    # Sin importar gi (44 ms medidos): basta saber que el módulo y el typelib están.
    if importlib.util.find_spec("gi") is None:
        return cap("unavailable", "libnm", "PyGObject is not installed · profiles can't be edited",
                   installed=False)
    if not typelib("NM-1.0.typelib"):
        return cap("unavailable", "libnm", "libnm is not installed · profiles can't be edited", installed=False)
    if not which("nmcli"):
        return cap("degraded", "libnm", "nmcli is not installed", installed=True)
    return cap("available", "libnm", installed=True)


def c_speedtest(q):
    """Speed test (2026-11-14): el helper (`scripts/speedtest.py`) sólo usa la biblioteca estándar. `ip` dice por qué
    conexión sale la prueba y `nmcli` si NetworkManager la marca como medida: sin él no se puede pedir confirmación
    antes de gastar datos, y eso se dice. Proveedor: el borde de Cloudflare."""
    if sys.version_info < (3, 11):
        return cap("unavailable", "Cloudflare", "Python 3.11 or newer is needed for the speed test", installed=False)
    if not which("nmcli"):
        return cap("degraded", "Cloudflare", "Can't tell whether the connection is metered (nmcli is not installed)",
                   installed=True)
    if not which("ip"):
        return cap("degraded", "Cloudflare", "Can't tell which connection is measured (ip is not installed)",
                   installed=True)
    return cap("available", "Cloudflare", installed=True)


def c_sddm_theme(q):
    """Sumi SDDM (2026-11-22): Settings → Login screen habla con la orden `sumi-sddm` del PATH (contrato JSON api 1).
    Es otro proyecto, opcional: sin ella la página lo explica y nada más cambia."""
    if not which("sumi-sddm"):
        return cap("unavailable", "Sumi SDDM", "Sumi SDDM is not installed", installed=False)
    rc, out, err = run(["sumi-sddm", "version", "--json"])
    if rc is None:
        return cap("unknown", "Sumi SDDM", err or "sumi-sddm did not answer", installed=True)
    try:
        doc = json.loads(out)
    except ValueError:
        doc = {}
    if rc != 0 or doc.get("ok") is not True:
        return cap("unavailable", "Sumi SDDM", "sumi-sddm is installed but does not work", installed=True)
    if doc.get("api") != 1:
        return cap("unavailable", "Sumi SDDM", "This version of Sumi SDDM is not compatible", installed=True,
                   api=doc.get("api"))
    return cap("available", "Sumi SDDM", installed=True, version=str(doc.get("version", "")))


def c_ddc(q):
    if not which("ddcutil"):
        return cap("unavailable", "ddcutil", "ddcutil is not installed", installed=False)
    devs = glob.glob("/dev/i2c-*")
    if not devs:
        return cap("unavailable", "ddcutil", "No I2C devices (load the i2c-dev module)", installed=True)
    if not any(os.access(d, os.R_OK | os.W_OK) for d in devs):
        return cap("unavailable", "ddcutil", "No permission on /dev/i2c-* (i2c group)", installed=True,
                   accessible=False)
    return cap("available", "ddcutil", installed=True, accessible=True)


def c_backlight(q):
    """F5g (H-18): el brillo de un panel (portátil) por /sys/class/backlight y SetBrightness de logind."""
    backlight = _sibling("backlight")
    try:
        r = backlight.listing()
    except Exception as e:
        return cap("unknown", "backlight", "Couldn't read /sys/class/backlight: %s" % e)
    devs, outs = r["devices"], r["outputs"]
    detail = {"devices": [{k: d[k] for k in ("name", "type", "connector", "how", "max")} for d in devs], "outputs": outs}
    if not devs:
        return cap("unavailable", "backlight", "No backlight here (an external monitor uses DDC/CI)", installed=False, **detail)
    names = ", ".join(sorted(set(outs.values()))) or devs[0]["name"]
    i, a, e = bus_facts(q, "system", "org.freedesktop.login1")
    if e:
        return cap("unknown", "logind · " + names, "Couldn't query D-Bus: " + e, installed=True, **detail)
    if not a:
        return cap("unavailable", "logind · " + names, "logind isn't running: the brightness can't be changed without root",
                   installed=True, active=False, **detail)
    if not outs:
        return cap("degraded", "logind · " + names, "Couldn't tell which screen %s lights" % devs[0]["name"],
                   installed=True, active=True, **detail)
    return cap("available", "logind · " + names, installed=True, active=True, accessible=True, **detail)


def c_plugin(name, provider):
    def f(q):
        h = q["hypr"]
        if not h["signature"] or "error" in h or h.get("plugins") is None:
            return cap("unknown", provider, "Couldn't list Hyprland plugins")
        if name in h["plugins"]:
            return cap("available", provider, installed=True, active=True)
        return cap("unavailable", provider, "The " + name + " Hyprland plugin is not loaded", active=False)
    return f


def c_notifications(q):
    """PL-03: quién atiende, no sólo si alguien atiende. Otro dueño no es un fallo: se dice."""
    n = q["notif"]
    if "error" in n:
        return cap("unknown", "", "Couldn't query D-Bus: " + n["error"])
    if not n["pid"]:
        return cap("unavailable", "", "Nobody is showing notifications", active=False)
    who = "the shell" if n.get("shell") else (n.get("name") or "pid %d" % n["pid"])
    return cap("available", who, installed=True, active=True, owner=n.get("name", ""), pid=n["pid"],
               shell=bool(n.get("shell")))


# id → (grupo, sonda). El grupo es para la vista (F2b); el orden, el de la tabla de --human.
CAPS = [
    ("shell.install", "session", c_install),
    ("session.hyprland", "session", c_session),
    ("hypr.dialect", "session", c_dialect),
    ("lock.entry", "session", c_lock_entry),
    ("lock.pam", "session", c_lock_pam),
    ("session.systemd", "session", c_systemd),
    ("session.systemdSystem", "session", c_systemd_system),
    ("session.logind", "session", lambda q: c_bus_service(q, "system", ("org.freedesktop.login1",), "logind",
                                                          "logind is not available")),
    ("runtime.python", "session", c_python),
    ("ui.font", "session", c_font),
    ("theme.dynamic", "theme", c_theme_dynamic),
    ("theme.static", "theme", c_theme_static),
    ("theme.gtk", "theme", c_gtk),
    ("wallpaper.apply", "wallpaper", c_wall_apply),
    ("wallpaper.video", "wallpaper", c_wall_video),
    ("wallpaper.thumbnails", "wallpaper", c_wall_thumbs),
    ("wallpaper.download", "wallpaper", c_downloads),
    ("apps.terminal", "apps", c_terminal),
    ("apps.browser", "apps", c_browser),
    ("apps.folders", "apps", c_app_folders),
    ("system.updates", "system", c_updates),
    # F3d-1: system.upgrade y maintenance.{dotbackup,diskbackup,sumiCli} describían las herramientas del
    # autor; ahora cada tarea de tasks.json tiene la suya, `tasks.<id>` (report() las añade).
    ("audio.equalizer", "audio", c_eq),
    ("audio.profileTest", "audio", c_rollback),
    ("clipboard.history", "desktop", c_clipboard),
    ("desktop.notifications", "desktop", c_notifications),
    ("agenda.calcurse", "desktop", c_bin("calcurse")),
    ("network.manager", "devices", lambda q: c_bus_service(
        q, "system", ("org.freedesktop.NetworkManager",), "NetworkManager", "NetworkManager is not installed")),
    ("network.editProfiles", "devices", c_network_edit),
    ("network.speedtest", "devices", c_speedtest),
    ("login.sddmTheme", "desktop", c_sddm_theme),
    ("bluetooth", "devices", lambda q: c_bus_service(q, "system", ("org.bluez",), "BlueZ",
                                                     "BlueZ is not installed")),
    ("power.battery", "devices", lambda q: c_bus_service(q, "system", ("org.freedesktop.UPower",), "UPower",
                                                         "UPower is not installed")),
    ("power.profiles", "devices", c_power_profiles),
    ("brightness.external", "devices", c_ddc),
    ("brightness.backlight", "devices", c_backlight),
    ("modes.glass", "modes", c_plugin("hyprglass", "hyprglass")),
    ("modes.cursors", "modes", c_plugin("dynamic-cursors", "dynamic-cursors")),
    ("modes.videoPause", "modes", c_wall_video_pause),
]


def report():
    t0 = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(QUERIES)) as ex:
        futs = {k: ex.submit(f) for k, f in QUERIES.items()}
        q = {}
        for k, fut in futs.items():
            try:
                q[k] = fut.result()
            except Exception as e:     # una sonda rota no tumba el informe
                q[k] = {"error": "%s: %s" % (type(e).__name__, e)}
    if "signature" not in q["hypr"]:
        q["hypr"].update(signature=bool(os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")),
                         desktop=os.environ.get("XDG_CURRENT_DESKTOP", ""))
    caps = {}
    for cid, group, probe in CAPS:
        try:
            c = probe(q)
        except Exception as e:
            c = cap("unknown", "", "The check failed: %s" % type(e).__name__)
        c["group"] = group
        caps[cid] = c
    # F3d-1: una capacidad por tarea declarada, en el orden del archivo
    tasks, _why = load_tasks()
    for t in tasks:
        try:
            c = c_task(t)(q)
        except Exception as e:
            c = cap("unknown", "", "The check failed: %s" % type(e).__name__)
        c["group"] = "system"
        caps["tasks." + t["id"]] = c
    now = datetime.datetime.now(datetime.timezone.utc)
    return {"format": FORMAT, "version": VERSION,
            "generatedAt": now.isoformat(timespec="milliseconds"),
            "generatedAtMs": int(now.timestamp() * 1000),
            "durationMs": int((time.monotonic() - t0) * 1000),
            "env": {"desktop": os.environ.get("XDG_CURRENT_DESKTOP", ""),
                    "hyprland": bool(os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")),
                    "python": "%d.%d.%d" % sys.version_info[:3]},
            "caps": caps,
            "providers": dict(load_providers(), settings=provider_settings())}


def write_cache(path, doc):
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, ".%s.kt-%d" % (os.path.basename(path), os.getpid()))
    with open(tmp, "w") as f:
        json.dump(doc, f)
        f.write("\n")
    os.replace(tmp, path)


def human(doc):
    lines = ["Sumi Shell capabilities · %s · %d ms" % (doc["generatedAt"], doc["durationMs"])]
    w = max(len(k) for k in doc["caps"])
    for cid, c in doc["caps"].items():
        lines.append("  %-*s  %-11s %s%s" % (w, cid, c["state"], c["provider"],
                                            (" · " + c["reason"]) if c["reason"] else ""))
    pv = doc.get("providers")
    if pv:
        lines.append("  providers.json  %s%s" % (pv["status"], (" · " + pv["reason"]) if pv["reason"] else ""))
        for k, choice in pv["settings"].items():
            lines.append("    %-10s %-8s %s" % (k, choice, ", ".join(pv["declared"].get(k, [])) or "-"))
        for e in pv["errors"]:
            lines.append("    %s: %s" % (e["kind"], e["error"]))
    return "\n".join(lines)


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("report")
    r.add_argument("--cache", default="")
    r.add_argument("--human", action="store_true")
    r.add_argument("--shell-dir", default="", help="the running shell's tree (Quickshell.shellDir)")
    a = p.parse_args()
    global SHELL_DIR
    SHELL_DIR = a.shell_dir
    doc = report()
    if a.cache:
        try:
            write_cache(a.cache, doc)
        except OSError as e:
            doc["cacheError"] = str(e)[:160]
    print(human(doc) if a.human else json.dumps(doc, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
