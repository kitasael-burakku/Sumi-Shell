#!/usr/bin/env python3
"""Ecualizador por salida sobre filter-chain de PipeWire (rediseño 13D, 2026-09-28).

Decisión del usuario (rediseno/PREPARACION.md §Fase 13): el EQ vive en `filter-chain.service`
—el que trae PipeWire— con un archivo generado en `~/.config/pipewire/filter-chain.conf.d/`;
cada salida con perfil tiene su propio filtro «smart» de WirePlumber
(`filter.smart.target = { node.name = <salida> }`), que se interpone solo en todo lo que va a
esa salida. Si el shell no corre, el audio sigue ecualizado; si el filtro cae, suena directo
(medido con sonda el 2026-09-28).

Los perfiles son del shell: `~/.config/sumi-shell/audio-eq.json`. La config del filtro se
GENERA de ellos (nunca se edita a mano; lleva una cabecera que lo dice).

    render                    la config que saldría, por stdout
    write                     perfiles por stdin → valida → los guarda (atómico, con copia) → sync
    sync                      genera; si cambió, guarda la anterior y escribe (atómico); reinicia
                              el servicio SÓLO si cambió la estructura (qué salidas tienen filtro):
                              las ganancias se cambian en vivo (pw-cli) y el archivo sólo tiene
                              que decir lo mismo para el próximo arranque
    service start|stop|restart|status
    remove                    la vuelta atrás completa: quita la config, para y deshabilita el
                              servicio (sin prueba, ~/.config/pipewire queda como estaba)
    restore                   la config anterior vuelve y reinicia

`--root R` es la raíz de PRUEBAS: config en R/config, estado en R/state, y el servicio es un
`pipewire -c filter-chain.conf` propio con XDG_CONFIG_HOME=R/config (pid en R/filter-chain.pid);
ni systemd ni ~/.config se tocan. Una línea JSON por orden.
"""
import argparse
import json
import math
import os
import re
import signal
import subprocess
import sys
import time

FREQS = [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
Q = 1.41                      # peaking de octava
BAND_MIN, BAND_MAX = -12.0, 12.0
PRE_MIN, PRE_MAX = -12.0, 0.0
NAME_RE = re.compile(r"^[A-Za-z0-9._:@+-]{1,200}$")
MAX_BYTES = 256 * 1024
UNIT = "filter-chain.service"
CONF_NAME = "kitasan-eq.conf"


def out(ok, **kw):
    kw["ok"] = ok
    print(json.dumps(kw))
    return 0 if ok else 1


class Paths:
    def __init__(self, root):
        self.test = bool(root)
        if root:
            self.config = os.path.join(root, "config")
            self.state = os.path.join(root, "state")
        else:
            home = os.path.expanduser("~")
            self.config = os.environ.get("XDG_CONFIG_HOME") or os.path.join(home, ".config")
            self.state = os.environ.get("XDG_STATE_HOME") or os.path.join(home, ".local", "state")
        self.root = root
        self.confdir = os.path.join(self.config, "pipewire", "filter-chain.conf.d")
        self.conf = os.path.join(self.confdir, CONF_NAME)
        self.profiles = os.path.join(self.config, "sumi-shell", "audio-eq.json")
        # Las copias NO van en conf.d: filter-chain cargaría cualquier *.conf de ahí.
        self.backup = os.path.join(self.state, "sumi-shell", "audio-eq")
        self.pidfile = os.path.join(root, "filter-chain.pid") if root else ""
        self.logfile = os.path.join(root, "filter-chain.log") if root else ""


# ---- perfiles ------------------------------------------------------------------------

def num(v, lo, hi, what):
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
        raise ValueError(what + " is not a number")
    if v < lo - 1e-9 or v > hi + 1e-9:
        raise ValueError("%s out of range (%g…%g)" % (what, lo, hi))
    return round(float(v), 2)


def validate(doc):
    """Devuelve los perfiles normalizados o lanza ValueError con el motivo."""
    if not isinstance(doc, dict) or doc.get("version") != 1:
        raise ValueError("not an audio-eq v1 document")
    devs = doc.get("devices")
    if not isinstance(devs, dict):
        raise ValueError("devices must be an object")
    clean = {}
    for name, p in devs.items():
        if not NAME_RE.match(name):
            raise ValueError("bad device name: %r" % name)
        if not isinstance(p, dict):
            raise ValueError(name + ": profile must be an object")
        bands = p.get("bands")
        if not isinstance(bands, list) or len(bands) != len(FREQS):
            raise ValueError(name + ": bands must be %d numbers" % len(FREQS))
        q = dict(p)   # lo que no es del filtro (preset, curva Custom…) se conserva tal cual
        q["bands"] = [num(b, BAND_MIN, BAND_MAX, name + " band") for b in bands]
        q["preamp"] = num(p.get("preamp", 0), PRE_MIN, PRE_MAX, name + " preamp")
        q["enabled"] = p.get("enabled") is True
        label = p.get("label", "")
        q["label"] = label if isinstance(label, str) else ""
        clean[name] = q
    return {"version": 1, "devices": clean}


def read_profiles(paths):
    try:
        with open(paths.profiles, "rb") as f:
            raw = f.read(MAX_BYTES + 1)
    except FileNotFoundError:
        return {"version": 1, "devices": {}}
    if len(raw) > MAX_BYTES:
        raise ValueError("profiles file too large")
    return validate(json.loads(raw.decode("utf-8")))


# ---- config de filter-chain ------------------------------------------------------------

def spa_str(s):
    """Cadena SPA-JSON segura: sin comillas ni barras (etiqueta legible, no un nombre)."""
    return '"' + re.sub(r'["\\\n\r\t]', "", s)[:80] + '"'


def render(profiles):
    lines = [
        "# GENERADO por Sumi Shell (scripts/audio-eq.py) desde ~/.config/sumi-shell/audio-eq.json.",
        "# No lo edites a mano: se reescribe con cada cambio del ecualizador. Para quitarlo:",
        "#   audio-eq.py remove    (o borra este archivo y `systemctl --user restart filter-chain`)",
        "context.modules = [",
    ]
    for name in sorted(profiles["devices"]):
        p = profiles["devices"][name]
        label = p["label"] or name
        mult = 10 ** (p["preamp"] / 20.0)
        nodes = ['        { type = builtin name = pre label = linear control = { "Mult" = %.6f "Add" = 0.0 } }' % mult]
        links = []
        prev = "pre"
        for i, (f, g) in enumerate(zip(FREQS, p["bands"])):
            b = "b%d" % (i + 1)
            nodes.append('        { type = builtin name = %s label = bq_peaking control = { "Freq" = %.1f "Q" = %.2f "Gain" = %.2f } }'
                         % (b, f, Q, g))
            links.append('        { output = "%s:Out" input = "%s:In" }' % (prev, b))
            prev = b
        lines += [
            "  { name = libpipewire-module-filter-chain",
            # nofail: el filtro de una salida que no arranca no se lleva a los demás
            "    flags = [ nofail ]",
            "    args = {",
            "      node.description = " + spa_str("Equalizer · " + label),
            "      media.name = " + spa_str("Equalizer · " + label),
            "      filter.graph = {",
            "        nodes = [",
        ] + ["  " + n for n in nodes] + [
            "        ]",
            "        links = [",
        ] + ["  " + l for l in links] + [
            "        ]",
            "      }",
            "      audio.channels = 2",
            "      audio.position = [ FL FR ]",
            "      capture.props = {",
            '        node.name = "kitasan_eq.%s"' % name,
            "        media.class = Audio/Sink",
            "        filter.smart = true",
            '        filter.smart.name = "kitasan-eq.%s"' % name,
            '        filter.smart.target = { node.name = "%s" }' % name,
            "        filter.smart.disabled = %s" % ("false" if p["enabled"] else "true"),
            '        kitasan.equalizer = "%s"' % name,
            "      }",
            "      playback.props = {",
            '        node.name = "kitasan_eq_out.%s"' % name,
            "        node.passive = true",
            # sin su salida, esperar a que vuelva en vez de irse al predeterminado
            "        node.dont-fallback = true",
            "        node.linger = true",
            '        kitasan.equalizer = "%s"' % name,
            "      }",
            "    }",
            "  }",
        ]
    lines.append("]")
    return "\n".join(lines) + "\n"


def structure(profiles):
    return sorted(profiles["devices"].keys())


def atomic_write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".sumi-tmp"          # no termina en .conf: filter-chain no lo carga
    with open(tmp, "w") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def backup_file(paths, src, tag):
    if not os.path.exists(src):
        return
    os.makedirs(paths.backup, exist_ok=True)
    with open(src) as f:
        data = f.read()
    atomic_write(os.path.join(paths.backup, tag + ".prev"), data)


# ---- servicio ------------------------------------------------------------------------

def test_pid(paths):
    try:
        pid = int(open(paths.pidfile).read().strip())
        os.kill(pid, 0)
        return pid
    except Exception:
        return 0


def service(paths, action):
    if paths.test:
        pid = test_pid(paths)
        if action == "status":
            return "active" if pid else "inactive"
        if action in ("stop", "restart") and pid:
            os.kill(pid, signal.SIGTERM)
            for _ in range(40):
                if not test_pid(paths):
                    break
                time.sleep(0.05)
        if action in ("start", "restart"):
            env = dict(os.environ, XDG_CONFIG_HOME=paths.config)
            log = open(paths.logfile, "a")
            p = subprocess.Popen(["pipewire", "-c", "filter-chain.conf"], env=env, stdout=log,
                                 stderr=log, stdin=subprocess.DEVNULL, start_new_session=True)
            with open(paths.pidfile, "w") as f:
                f.write(str(p.pid))
            time.sleep(0.3)
            if p.poll() is not None:
                return "failed"
        return "active" if test_pid(paths) else "inactive"
    if action == "status":
        r = subprocess.run(["systemctl", "--user", "is-active", UNIT], capture_output=True, text=True)
        return r.stdout.strip() or "unknown"
    if action == "start":
        subprocess.run(["systemctl", "--user", "enable", "--now", UNIT], capture_output=True)
    elif action == "restart":
        subprocess.run(["systemctl", "--user", "enable", UNIT], capture_output=True)
        subprocess.run(["systemctl", "--user", "restart", UNIT], capture_output=True)
    elif action == "stop":
        subprocess.run(["systemctl", "--user", "disable", "--now", UNIT], capture_output=True)
    return service(paths, "status")


# ---- órdenes -------------------------------------------------------------------------

def current_conf(paths):
    try:
        return open(paths.conf).read()
    except FileNotFoundError:
        return None


def conf_devices(text):
    return sorted(re.findall(r'node\.name = "kitasan_eq\.([^"]+)"', text or ""))


def do_sync(paths, profiles, restart="auto"):
    text = render(profiles)
    old = current_conf(paths)
    devices = structure(profiles)
    structural = conf_devices(old) != devices
    changed = old != text
    if changed:
        backup_file(paths, paths.conf, CONF_NAME)
        if devices:
            atomic_write(paths.conf, text)
        elif old is not None:
            os.remove(paths.conf)
    state = service(paths, "status")
    restarted = False
    if devices and (restart == "always" or (restart == "auto" and (structural or state != "active"))):
        state = service(paths, "restart" if state == "active" else "start")
        restarted = True
    elif not devices and state == "active" and structural:
        # sin perfiles no hace falta el servicio: parar (y deshabilitar) deja el audio directo
        state = service(paths, "stop")
        restarted = True
    return out(state in ("active", "inactive") and (state == "active" or not devices),
               changed=changed, structural=structural, restarted=restarted, service=state,
               devices=devices, error="" if state == "active" or not devices else "The equalizer service is " + state)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd")
    ap.add_argument("arg", nargs="?")
    ap.add_argument("--root", default="")
    ap.add_argument("--restart", default="auto", choices=["auto", "always", "never"])
    a = ap.parse_args()
    paths = Paths(a.root)
    try:
        if a.cmd == "render":
            sys.stdout.write(render(read_profiles(paths)))
            return 0
        if a.cmd == "write":
            raw = sys.stdin.read(MAX_BYTES + 1)
            if len(raw) > MAX_BYTES:
                return out(False, error="profiles too large")
            profiles = validate(json.loads(raw))
            backup_file(paths, paths.profiles, "audio-eq.json")
            atomic_write(paths.profiles, json.dumps(profiles, indent=2) + "\n")
            return do_sync(paths, profiles, a.restart)
        if a.cmd == "sync":
            return do_sync(paths, read_profiles(paths), a.restart)
        if a.cmd == "service":
            if a.arg not in ("start", "stop", "restart", "status"):
                return out(False, error="service start|stop|restart|status")
            st = service(paths, a.arg)
            return out(True, service=st, conf=os.path.exists(paths.conf))
        if a.cmd == "remove":
            existed = os.path.exists(paths.conf)
            if existed:
                backup_file(paths, paths.conf, CONF_NAME)
                os.remove(paths.conf)
            st = service(paths, "stop")
            # Deja ~/.config/pipewire como estaba si lo creamos nosotros y quedó vacío.
            for d in (paths.confdir, os.path.dirname(paths.confdir)):
                try:
                    os.rmdir(d)
                except OSError:
                    break
            return out(True, removed=existed, service=st)
        if a.cmd == "restore":
            prev = os.path.join(paths.backup, CONF_NAME + ".prev")
            if not os.path.exists(prev):
                return out(False, error="no previous configuration")
            atomic_write(paths.conf, open(prev).read())
            return out(True, service=service(paths, "restart"))
        return out(False, error="unknown command " + a.cmd)
    except (ValueError, json.JSONDecodeError) as e:
        return out(False, error=str(e))
    except OSError as e:
        return out(False, error=e.strerror or str(e))


if __name__ == "__main__":
    sys.exit(main())
