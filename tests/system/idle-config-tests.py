#!/usr/bin/env python3
"""Pruebas de scripts/idle-config.py (fase 14E) sin tocar el hypridle real.

La carpeta es temporal (SUMI_IDLE_DIR) con una copia del hypridle.conf del usuario más un
listener propio. systemctl y journalctl son falsos: «reiniciar» ejecuta el hypridle REAL, saneado
(comandos → true, sin inhibidor), sobre los archivos de la carpeta y guarda su salida como journal;
con el archivo `fail` presente, el journal lleva un error. Uso: python3 idle-config-tests.py
"""
import json
import os
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
# F5f: SUMI_IDLE_SCRIPT prueba otra copia (la de desarrollo) sin desplegar
SCRIPT = os.environ.get("SUMI_IDLE_SCRIPT") or os.path.join(HERE, "..", "..", "sumi", "scripts", "idle-config.py")

REAL = '''general {
    lock_cmd = ~/.config/hypr/scripts/lock.sh
    before_sleep_cmd = ~/.config/hypr/scripts/lock.sh instant
    after_sleep_cmd = hyprctl dispatch 'hl.dsp.dpms({ action = "enable" })'
    # R3: comentario del usuario
    inhibit_sleep = 3
}

listener {
    timeout = 300
    on-timeout = loginctl lock-session
}

listener {
    timeout = 900
    on-timeout = notify-send hola
}

listener {
    timeout = 600
    on-timeout = hyprctl dispatch 'hl.dsp.dpms({ action = "disable" })'
    on-resume = hyprctl dispatch 'hl.dsp.dpms({ action = "enable" })'
}'''

FAKE_SYSTEMCTL = r'''#!/usr/bin/env python3
import os, subprocess, sys, importlib.util
d = os.environ["KT_DIR"]
a = sys.argv[1:]
pidf = os.path.join(d, "pid")
pid = int(open(pidf).read()) if os.path.exists(pidf) else 100
if "show" in a:
    print(pid); sys.exit(0)
if "is-active" in a:
    print("active"); sys.exit(0)
if "restart" in a:
    open(pidf, "w").write(str(pid + 1))
    spec = importlib.util.spec_from_file_location("ic", os.environ["KT_SCRIPT"])
    ic = importlib.util.module_from_spec(spec); spec.loader.exec_module(ic)
    conf = os.path.join(os.environ["SUMI_IDLE_DIR"], "hypridle.conf")
    managed = os.path.join(os.environ["SUMI_IDLE_DIR"], "hypridle-sumi.conf")
    tm = os.path.join(d, "run-managed.conf")
    open(tm, "w").write(ic.sanitize(open(managed).read() if os.path.exists(managed) else "", managed, tm))
    mm = os.path.join(d, "run-main.conf")
    open(mm, "w").write(ic.sanitize(open(conf).read(), managed, tm))
    p = subprocess.run(["timeout", "1.5", "hypridle", "-c", mm, "-v"], capture_output=True, text=True)
    log = p.stdout + p.stderr
    if os.path.exists(os.path.join(d, "fail")):
        log += "\n[ERR] Config has errors: simulated\n"
    with open(os.path.join(d, "journal"), "a") as f:
        f.write(log)
    sys.exit(0)
sys.exit(1)
'''
FAKE_JOURNALCTL = r'''#!/usr/bin/env python3
import os, sys
j = os.path.join(os.environ["KT_DIR"], "journal")
lines = open(j).read().splitlines() if os.path.exists(j) else []
a = sys.argv[1:]
if "--show-cursor" in a:
    print("-- cursor: %d" % len(lines)); sys.exit(0)
if "--after-cursor" in a:
    n = int(a[a.index("--after-cursor") + 1])
    print("\n".join(lines[n:])); sys.exit(0)
print("\n".join(lines[-200:]))
'''

fails = 0


def check(name, cond, detail=""):
    global fails
    print(("OK   " if cond else "FAIL ") + name + ("" if cond else "  →  " + str(detail)))
    if not cond:
        fails += 1


with tempfile.TemporaryDirectory(prefix="kt14e-") as tmp:
    conf_dir = os.path.join(tmp, "hypr")
    os.makedirs(conf_dir)
    conf = os.path.join(conf_dir, "hypridle.conf")
    managed = os.path.join(conf_dir, "hypridle-sumi.conf")
    open(conf, "w").write(REAL)
    for n, body in (("systemctl", FAKE_SYSTEMCTL), ("journalctl", FAKE_JOURNALCTL)):
        open(os.path.join(tmp, n), "w").write(body)
        os.chmod(os.path.join(tmp, n), 0o755)
    env = dict(os.environ, SUMI_IDLE_DIR=conf_dir, SUMI_SYSTEMCTL=os.path.join(tmp, "systemctl"),
               SUMI_JOURNALCTL=os.path.join(tmp, "journalctl"), SUMI_IDLE_STATE=os.path.join(tmp, "state"),
               KT_DIR=tmp, KT_SCRIPT=SCRIPT, XDG_RUNTIME_DIR=tmp, PYTHONDONTWRITEBYTECODE="1")

    def run(*args):
        p = subprocess.run([sys.executable, SCRIPT] + list(args), capture_output=True, text=True, env=env)
        try:
            return p.returncode, json.loads(p.stdout)
        except ValueError:
            return p.returncode, {"raw": p.stdout + p.stderr}

    rc, s = run("status")
    check("status: sin gestionar, 300/600 leídos del archivo", s.get("state") == "off" and s["lock"] == 300
          and s["screenOff"] == 600 and s["migratable"], s)
    rc, r = run("enable")
    check("enable: ok, verificado en el journal", rc == 0 and r["ok"] and r["details"]["rules"] == [300, 600, 900], r)
    text = open(conf).read()
    check("enable: general intacto (con su comentario)", "# R3: comentario del usuario" in text and "inhibit_sleep = 3" in text)
    check("enable: el listener propio se queda", "notify-send hola" in text)
    check("enable: los dos movidos, y la línea source", "lock-session" not in text and "dpms" not in text.split("general")[1].split("}")[1]
          and text.rstrip().endswith("source = " + managed), text[-200:])
    check("enable: gestionado con cabecera y plazos", open(managed).read().startswith("# Generated by Sumi Shell")
          and "lock=300 screenOff=600" in open(managed).read())
    rc, s = run("status")
    check("status: on", s["state"] == "on" and s["lock"] == 300, s)
    rc, r = run("enable")
    check("enable otra vez: ya estaba", rc == 0 and r.get("already"), r)

    rc, r = run("set", "120", "0")
    check("set 2 min y nunca apagar", rc == 0 and r["ok"] and r["details"]["rules"] == [120, 900]
          and r["undo"] == {"lock": 300, "screenOff": 600}, r)
    for args, text_ in ((("600", "300"), "before the session locks"), (("30", "600"), "Lock must be"),
                        (("300", "99999"), "Screen off must be"), (("abc", "1"), "usage")):
        rc, r = run("set", *args)
        check("set rechaza %s" % (args,), rc == 1 and text_ in r.get("error", ""), r)
    check("rechazos: el gestionado no cambió", "lock=120 screenOff=0" in open(managed).read())

    open(os.path.join(tmp, "fail"), "w").write("1")
    rc, r = run("set", "300", "600")
    check("hypridle con error al reiniciar: vuelve a lo anterior y lo verifica", rc == 1 and r.get("restored")
          and "lock=120 screenOff=0" in open(managed).read(), r)
    os.remove(os.path.join(tmp, "fail"))
    rc, r = run("set", "300", "600")
    check("después, sí", rc == 0 and r["details"]["rules"] == [300, 600, 900], r)

    rc, r = run("disable")
    check("disable: hypridle.conf EXACTO al de antes", rc == 0 and open(conf).read() == REAL and not os.path.exists(managed), r)
    rc, s = run("status")
    check("status: off otra vez", s["state"] == "off", s)

    # activar, editar a mano hypridle.conf, retirar: vuelven los listeners y se queda la edición
    run("enable")
    open(conf, "a").write("# mi nota\n")
    rc, r = run("disable")
    text = open(conf).read()
    check("disable tras editarlo: listeners dentro y la nota se queda", rc == 0 and "# mi nota" in text
          and "loginctl lock-session" in text and "source" not in text and r["details"]["rules"] == [300, 600, 900], r)

    open(managed, "w").write("listener {\n    timeout = 5\n    on-timeout = true\n}\n")
    rc, r = run("enable")
    check("gestionado ajeno: rechazado e intacto", rc == 1 and r.get("refused") and "timeout = 5" in open(managed).read(), r)
    os.remove(managed)

    import importlib.util
    spec = importlib.util.spec_from_file_location("ic", SCRIPT)
    ic = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ic)
    try:
        ic.try_candidate(REAL + "\nsource = /nonexistent/x.conf\n", None, "/nonexistent/y.conf")
        check("candidato con source roto rechazado", False)
    except ic.Refused as e:
        check("candidato con source roto rechazado", "rejects" in str(e), e)

print("\n%d fallo(s)" % fails)
sys.exit(1 if fails else 0)
