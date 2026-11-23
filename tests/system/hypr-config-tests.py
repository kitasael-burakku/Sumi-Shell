#!/usr/bin/env python3
"""Pruebas de scripts/hypr-config.py (fases 14A y 14C) sobre un árbol falso y un hyprctl falso.

No toca Hyprland: SUMI_HYPR_DIR apunta a un directorio temporal y SUMI_HYPRCTL a un
script que imprime respuestas fijas. La búsqueda de la configuración (14C) se prueba con un /proc
falso (SUMI_PROC). Uso: python3 hypr-config-tests.py
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
# F5f: SUMI_SCRIPTS prueba otra carpeta de scripts sin desplegar
SCRIPT = os.path.join(os.environ.get("SUMI_SCRIPTS") or os.path.join(HERE, "..", "..", "sumi", "scripts"), "hypr-config.py")

MAIN = '''-- cabecera con { llaves } y "comillas" en un comentario
--[[ comentario largo
hl.config({ general = { gaps_in = 99 } })
]]
require("modules.a")
require "modules.b"
local ok = pcall(require, "modules.missing")
pcall(require, "modules.late")
'''
A = '''hl.config({
    general = {
        gaps_in = 5,
        gaps_out = { top = 8, right = 15, bottom = 15, left = 15 },
        col = { active_border = "rgba(7ab8b8cc)" },
    },
    decoration = { rounding = 12, shadow = { offset = { 0, 5 } } },
    input = { sensitivity = -0.5, kb_layout = "us,es", repeat_rate = 0x32 },
    misc = { thing = os.getenv("HOME") .. "/x", text = [[a { b } c]] },
})
hl.device({ name = "mouse-one", sensitivity = -0.25, accel_profile = "flat" })
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
'''
B = '''hl.config({ general = { gaps_in = 7 } })
hl.monitor({ output = "desc:ACME X1 123", mode = "1920x1080@60", position = "0x0", scale = 1.25 })
'''
LATE = '''-- cargado el último
hl.config({ decoration = { rounding = 4 } })
'''

FAKE_HYPRCTL = r'''#!/bin/sh
# responde a --batch con respuestas separadas por dos líneas en blanco, como el real
printf '{"option": "general:gaps_out", "css": "8 15 15 15", "set": true }\n\n\n'
printf 'no such option\n\n\n'
printf '{"option": "input:kb_variant", "str": "[[EMPTY]]", "set": false }\n\n\n'
printf '[{"name":"HDMI-A-1","availableModes":["1920x1080@60.00Hz"]}]\n\n\n'
printf '{"mice":[],"keyboards":[]}\n\n\n'
printf '{"version":"0.56.2"}\n\n\n'
printf '["require(\\"x\\"): error loading module", ""]\n'
'''

fails = 0


def check(name, cond, detail=""):
    global fails
    print(("OK   " if cond else "FAIL ") + name + ("" if cond else "  →  " + str(detail)))
    if not cond:
        fails += 1


def run(root, *args, hyprctl=None):
    env = dict(os.environ, SUMI_HYPR_DIR=root)
    if hyprctl:
        env["SUMI_HYPRCTL"] = hyprctl
    p = subprocess.run([sys.executable, SCRIPT] + list(args), capture_output=True, text=True, env=env)
    return p.returncode, json.loads(p.stdout)


with tempfile.TemporaryDirectory() as root:
    os.makedirs(os.path.join(root, "modules"))
    for name, body in (("hyprland.lua", MAIN), ("modules/a.lua", A), ("modules/b.lua", B)):
        with open(os.path.join(root, name), "w") as f:
            f.write(body)

    rc, s = run(root, "scan")
    check("scan termina", rc == 0, s)
    check("orden de carga", s["files"] == ["hyprland.lua", "modules/a.lua", "modules/b.lua"], s["files"])
    check("el comentario largo no cuenta", all(x["value"] != 99 for x in s["options"].get("general.gaps_in", [])))
    g = s["options"]["general.gaps_in"]
    check("gaps_in: dos sitios, el último gana", [x["value"] for x in g] == [5, 7] and g[-1]["file"] == "modules/b.lua", g)
    check("gaps_out por lados", s["options"]["general.gaps_out.right"][0]["value"] == 15)
    check("negativo", s["options"]["input.sensitivity"][0]["value"] == -0.5)
    check("hexadecimal", s["options"]["input.repeat_rate"][0]["value"] == 50)
    check("lista posicional", s["options"]["decoration.shadow.offset"][0]["value"] == [0, 5])
    check("expresión sin evaluar", isinstance(s["options"]["misc.thing"][0]["value"], dict)
          and "expr" in s["options"]["misc.thing"][0]["value"])
    check("cadena larga con llaves", s["options"]["misc.text"][0]["value"] == "a { b } c")
    check("línea de la clave", s["options"]["decoration.rounding"][0]["line"] == 7, s["options"]["decoration.rounding"])
    d = s["devices"].get("mouse-one", {})
    check("dispositivo", d.get("sensitivity", [{}])[0].get("value") == -0.25 and d.get("accel_profile", [{}])[0].get("value") == "flat", d)
    check("dos reglas de monitor en orden", [m["fields"]["output"] for m in s["monitors"]] == ["", "desc:ACME X1 123"], s["monitors"])
    miss = [r for r in s["requires"] if r["module"] == "modules.missing"]
    check("require protegido que falta", miss and miss[0]["protected"] and not miss[0]["found"], miss)
    late = [r for r in s["requires"] if r["module"] == "modules.late"]
    check("pcall(require) de un módulo que aún no existe", late and late[0]["protected"] and not late[0]["found"], late)
    check("dónde: forzado por SUMI_HYPR_DIR", s["config"]["from"] == "override" and s["config"]["kind"] == "lua", s["config"])

    # el módulo aparece: se carga el último y su valor gana
    with open(os.path.join(root, "modules", "late.lua"), "w") as f:
        f.write(LATE)
    rc, s = run(root, "scan")
    r = s["options"]["decoration.rounding"]
    check("módulo tardío presente y último en ganar", r[-1]["file"] == "modules/late.lua" and r[-1]["value"] == 4, r)

    # tabla sin cerrar → error apuntado, sin caerse
    with open(os.path.join(root, "modules", "b.lua"), "w") as f:
        f.write("hl.config({ general = { gaps_in = 7 }\n")
    rc, s = run(root, "scan")
    check("tabla rota: error por archivo", rc == 0 and s["errors"] and s["errors"][0]["file"] == "modules/b.lua", s["errors"])

    # read con hyprctl falso
    fake = os.path.join(root, "hyprctl")
    with open(fake, "w") as f:
        f.write(FAKE_HYPRCTL)
    os.chmod(fake, 0o755)
    rc, r = run(root, "read", "general:gaps_out", "kt:nope", "input:kb_variant", hyprctl=fake)
    check("read termina", rc == 0, r)
    e = r["effective"]
    check("css → lados", e["general:gaps_out"] == {"type": "sides", "value": [8, 15, 15, 15], "set": True}, e["general:gaps_out"])
    check("opción inexistente → missing", e["kt:nope"]["type"] == "missing", e["kt:nope"])
    check("[[EMPTY]] → cadena vacía", e["input:kb_variant"]["value"] == "" and not e["input:kb_variant"]["set"])
    check("monitores, dispositivos y versión", r["monitorsAll"][0]["name"] == "HDMI-A-1" and r["version"]["version"] == "0.56.2" and "mice" in r["inputDevices"] and "mouse-one" not in r["inputDevices"])
    check("configerrors sin vacíos", r.get("configErrors") == ['require("x"): error loading module'], r.get("configErrors"))
    rc, r = run(root, "read", "general:gaps_out; exec rm", hyprctl=fake)
    check("nombre de opción inseguro rechazado", rc == 1 and "bad option" in r.get("error", ""), r)


# ---- 14C: dónde vive la configuración (el Hyprland que corre, por su /proc) ----------------
INSTANCES = r'''#!/bin/sh
[ "$1" = "instances" ] && printf '[{"instance": "otra", "pid": 11}, {"instance": "yo", "pid": 42}]\n'
'''


def where(tmp, cmdline, environ, cwd=None):
    proc = os.path.join(tmp, "proc", "42")
    os.makedirs(proc, exist_ok=True)
    with open(os.path.join(proc, "cmdline"), "wb") as f:
        f.write(b"\0".join(x.encode() for x in cmdline) + b"\0")
    with open(os.path.join(proc, "environ"), "wb") as f:
        f.write(b"\0".join(("%s=%s" % kv).encode() for kv in environ.items()) + b"\0")
    link = os.path.join(proc, "cwd")
    if os.path.lexists(link):
        os.remove(link)
    if cwd:
        os.symlink(cwd, link)
    fake = os.path.join(tmp, "instances")
    with open(fake, "w") as f:
        f.write(INSTANCES)
    os.chmod(fake, 0o755)
    env = {k: v for k, v in os.environ.items() if k != "SUMI_HYPR_DIR"}
    env.update(SUMI_PROC=os.path.join(tmp, "proc"), SUMI_HYPRCTL=fake, HYPRLAND_INSTANCE_SIGNATURE="yo")
    p = subprocess.run([sys.executable, SCRIPT, "where"], capture_output=True, text=True, env=env)
    return json.loads(p.stdout)


def put(path, body="-- x\n"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(body)


with tempfile.TemporaryDirectory() as tmp:
    home = os.path.join(tmp, "home")
    put(os.path.join(home, ".config", "hypr", "hyprland.lua"))
    w = where(tmp, ["Hyprland", "--watchdog-fd", "4"], {"HOME": home})
    check("dónde: por defecto, del HOME de Hyprland, la instancia que casa", w["from"] == "default" and w["pid"] == 42
          and w["main"] == os.path.join(home, ".config", "hypr", "hyprland.lua") and w["kind"] == "lua", w)
    put(os.path.join(tmp, "xdg", "hypr", "hyprland.lua"))
    w = where(tmp, ["Hyprland"], {"HOME": home, "XDG_CONFIG_HOME": os.path.join(tmp, "xdg")})
    check("dónde: XDG_CONFIG_HOME del proceso", w["from"] == "environment" and w["dir"] == os.path.join(tmp, "xdg", "hypr"), w)
    put(os.path.join(tmp, "otra", "mi.lua"))
    w = where(tmp, ["Hyprland", "--config", os.path.join(tmp, "otra", "mi.lua")], {"HOME": home})
    check("dónde: --config absoluto", w["from"] == "cmdline" and w["main"] == os.path.join(tmp, "otra", "mi.lua")
          and w["dir"] == os.path.join(tmp, "otra"), w)
    w = where(tmp, ["Hyprland", "-c", "mi.lua"], {"HOME": home}, cwd=os.path.join(tmp, "otra"))
    check("dónde: -c relativo al directorio del proceso", w["main"] == os.path.join(tmp, "otra", "mi.lua"), w)
    w = where(tmp, ["Hyprland", "--config=" + os.path.join(tmp, "otra", "mi.lua")], {"HOME": home})
    check("dónde: --config=ruta", w["from"] == "cmdline" and w["kind"] == "lua", w)
    home2 = os.path.join(tmp, "home2")
    put(os.path.join(home2, ".config", "hypr", "hyprland.conf"), "general { gaps_in = 5 }\n")
    w = where(tmp, ["Hyprland"], {"HOME": home2})
    check("dónde: sólo hyprland.conf → conf", w["kind"] == "conf" and w["main"].endswith("hyprland.conf"), w)
    w = where(tmp, ["Hyprland"], {"HOME": os.path.join(tmp, "nadie")})
    check("dónde: nada → missing", w["kind"] == "missing", w)

print("\n%d fallo(s)" % fails)
sys.exit(1 if fails else 0)
