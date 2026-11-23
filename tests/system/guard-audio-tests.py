#!/usr/bin/env python3
"""Pruebas de la validación del tipo `audio-profile` de scripts/sumi-guard.py (fase 14F) con un
pactl FALSO. Aplicar, plazo, Keep, Revert y kill -9 se probaron en vivo sobre la tarjeta Ryzen
(rediseno/PREPARACION.md §14F). Uso: python3 guard-audio-tests.py
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
# F5f: SUMI_SCRIPTS prueba otra carpeta de scripts (la copia de desarrollo o el vivo) sin desplegar
GUARD = os.path.join(os.environ.get("SUMI_SCRIPTS") or os.path.join(HERE, "..", "..", "sumi", "scripts"), "sumi-guard.py")
CARDS = [{"name": "alsa_card.pci-0000_03_00.1", "active_profile": "output:hdmi-stereo",
          "properties": {"device.description": "HDMI"},
          "profiles": {"off": {"available": True}, "output:hdmi-stereo": {"available": True},
                       "output:hdmi-surround-extra1": {"available": False}, "pro-audio": {"available": True}}}]
FAKE = r'''#!/usr/bin/env python3
import os, sys
if sys.argv[1:4] == ["-f", "json", "list"]:
    print(open(os.environ["KT_CARDS"]).read())
    sys.exit(0)
sys.exit(1)
'''
fails = 0


def check(name, cond, detail=""):
    global fails
    print(("OK   " if cond else "FAIL ") + name + ("" if cond else "  →  " + str(detail)))
    if not cond:
        fails += 1


with tempfile.TemporaryDirectory() as tmp:
    open(os.path.join(tmp, "cards.json"), "w").write(json.dumps(CARDS))
    fake = os.path.join(tmp, "pactl")
    open(fake, "w").write(FAKE)
    os.chmod(fake, 0o755)
    env = dict(os.environ, SUMI_PACTL=fake, KT_CARDS=os.path.join(tmp, "cards.json"), PYTHONDONTWRITEBYTECODE="1")

    def chk(card, prof, only=None):
        argv = [sys.executable, GUARD, "check", "audio-profile", json.dumps({"card": card, "profile": prof})]
        if only is not None:
            argv += ["--only", only]
        return json.loads(subprocess.run(argv, capture_output=True, text=True, env=env).stdout)

    H = "alsa_card.pci-0000_03_00.1"
    check("perfil disponible", chk(H, "off").get("ok") is True)
    check("pro-audio (disponible) vale", chk(H, "pro-audio").get("ok") is True)
    check("no disponible", "not available" in chk(H, "output:hdmi-surround-extra1").get("error", ""))
    check("el que ya está", "already in use" in chk(H, "output:hdmi-stereo").get("error", ""))
    check("perfil inexistente", "no profile" in chk(H, "output:nada").get("error", ""))
    check("tarjeta desconectada", "not connected" in chk("alsa_card.otra", "off").get("error", ""))
    check("nombre con caracteres raros", chk("x; rm -rf ~", "off").get("error") == "bad proposal")
    check("fuera del filtro de pruebas", "outside this test" in chk(H, "off", "7c_00").get("error", ""))

print("\n%d fallo(s)" % fails)
sys.exit(1 if fails else 0)
