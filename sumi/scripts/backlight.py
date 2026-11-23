#!/usr/bin/env python3
"""Brillo por backlight (portabilidad F5g, H-18): leer de sysfs y escribir por logind, sin root ni brightnessctl.

Uso:
  backlight.py list              {devices: [{name, type, connector, brightness, actual, max}], outputs: {<salida>: <name>}}
  backlight.py get <name>        {ok, name, brightness, actual, max}
  backlight.py set <name> <raw>  {ok, name, raw, brightness, max, error?}

Leer: /sys/class/backlight/<name>/{brightness,actual_brightness,max_brightness,type}. La salida (el conector DRM sin el
`cardN-`, como la llama Hyprland) sale de `device`:
  · un conector (`intel_backlight` → card0-eDP-1): ése;
  · una tarjeta PCI (`amdgpu_bl0`, `nvidia_0`): el panel interno (eDP/LVDS/DSI) de ESA tarjeta, si tiene uno;
  · si no (`acpi_video0`, firmware/platform): el único panel interno conectado de la máquina, si hay exactamente uno.
Si dos dispositivos dan la misma salida, gana firmware > platform > raw (el orden de gnome-settings-daemon y systemd).

Escribir: `SetBrightness("backlight", name, raw)` de la sesión de logind (`/org/freedesktop/login1/session/auto`), con
busctl: logind sólo lo permite a la sesión activa. Después se LEE `brightness` hasta 0,5 s: efectivo = lo leído.

Pruebas: SUMI_SYSFS (otra raíz en vez de /sys), SUMI_BUSCTL (otro busctl).
"""
import json
import os
import re
import subprocess
import sys
import time

SYSFS = os.environ.get("SUMI_SYSFS", "/sys")
BUSCTL = os.environ.get("SUMI_BUSCTL", "busctl")
CLASS = os.path.join(SYSFS, "class", "backlight")
DRM = os.path.join(SYSFS, "class", "drm")
INTERNAL = re.compile(r"^(eDP|LVDS|DSI)-")
RANK = {"firmware": 0, "platform": 1, "raw": 2}
NAME = re.compile(r"^[A-Za-z0-9_.:-]{1,64}$")


def _read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def _int(path):
    v = _read(path)
    try:
        return int(v) if v is not None else None
    except ValueError:
        return None


def connectors():
    """[(salida, pci real, conectado)] de los conectores DRM."""
    out = []
    try:
        names = sorted(os.listdir(DRM))
    except OSError:
        return out
    for n in names:
        m = re.match(r"^card\d+-(.+)$", n)
        if not m:
            continue
        real = os.path.realpath(os.path.join(DRM, n))
        pci = os.path.dirname(os.path.dirname(os.path.dirname(real)))     # …/<pci>/drm/cardN/cardN-X
        out.append((m.group(1), pci, _read(os.path.join(DRM, n, "status")) == "connected"))
    return out


def devices():
    try:
        names = sorted(os.listdir(CLASS))
    except OSError:
        return []
    conns = None
    out = []
    for n in names:
        d = os.path.join(CLASS, n)
        mx = _int(os.path.join(d, "max_brightness"))
        if not mx or mx <= 0:
            continue
        dev = os.path.realpath(os.path.join(d, "device"))
        base = os.path.basename(dev)
        conn, how = "", ""
        m = re.match(r"^card\d+-(.+)$", base)
        if m:
            conn, how = m.group(1), "connector"
        else:
            if conns is None:
                conns = connectors()
            same = [c for c, pci, _ in conns if pci == dev and INTERNAL.match(c)]
            if len(same) == 1:
                conn, how = same[0], "card"
            else:
                live = [c for c, _, on in conns if on and INTERNAL.match(c)]
                if len(live) == 1:
                    conn, how = live[0], "only-panel"
        out.append({"name": n, "type": _read(os.path.join(d, "type")) or "raw", "connector": conn, "how": how,
                    "brightness": _int(os.path.join(d, "brightness")), "actual": _int(os.path.join(d, "actual_brightness")),
                    "max": mx})
    return out


def listing():
    devs = devices()
    outputs = {}
    for d in sorted(devs, key=lambda d: (RANK.get(d["type"], 3), d["name"])):
        if d["connector"] and d["connector"] not in outputs:
            outputs[d["connector"]] = d["name"]
    return {"sysfs": SYSFS, "devices": devs, "outputs": outputs}


def find(name):
    if not NAME.match(name or "") or "/" in name or name in (".", ".."):
        return None
    for d in devices():
        if d["name"] == name:
            return d
    return None


def get(name):
    d = find(name)
    if not d:
        return {"ok": False, "name": name, "error": "No backlight called " + str(name)}
    return {"ok": d["brightness"] is not None, "name": name, "brightness": d["brightness"], "actual": d["actual"],
            "max": d["max"]}


def set_(name, raw):
    d = find(name)
    if not d:
        return {"ok": False, "name": name, "error": "No backlight called " + str(name)}
    try:
        raw = int(raw)
    except ValueError:
        return {"ok": False, "name": name, "error": "Not a number"}
    if raw < 0 or raw > d["max"]:
        return {"ok": False, "name": name, "error": "Out of range (0-%d)" % d["max"]}
    argv = [BUSCTL, "call", "org.freedesktop.login1", "/org/freedesktop/login1/session/auto",
            "org.freedesktop.login1.Session", "SetBrightness", "ssu", "backlight", name, str(raw)]
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired) as e:
        return {"ok": False, "name": name, "raw": raw, "max": d["max"], "error": "logind: " + type(e).__name__}
    if p.returncode != 0:
        msg = (p.stderr or p.stdout).strip().splitlines()
        msg = msg[-1] if msg else "error %d" % p.returncode
        if "Access denied" in msg or "not permitted" in msg.lower() or "NotInControl" in msg:
            msg = "logind refused it (only the active session may change it)"
        return {"ok": False, "name": name, "raw": raw, "max": d["max"], "error": msg[:200]}
    got = None
    end = time.monotonic() + 0.5
    while True:
        got = _int(os.path.join(CLASS, name, "brightness"))
        if got == raw or time.monotonic() >= end:
            break
        time.sleep(0.05)
    if got != raw:
        return {"ok": False, "name": name, "raw": raw, "brightness": got, "max": d["max"],
                "error": "The panel kept %d%%" % round(100 * (got or 0) / d["max"]) if got is not None else "Could not read it back"}
    return {"ok": True, "name": name, "raw": raw, "brightness": got, "max": d["max"]}


def main(argv):
    if len(argv) >= 2 and argv[1] == "list":
        r = listing()
    elif len(argv) == 3 and argv[1] == "get":
        r = get(argv[2])
    elif len(argv) == 4 and argv[1] == "set":
        r = set_(argv[2], argv[3])
    else:
        print(__doc__, file=sys.stderr)
        return 2
    print(json.dumps(r))
    return 0 if r.get("ok", True) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
