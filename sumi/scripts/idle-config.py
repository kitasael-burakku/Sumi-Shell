#!/usr/bin/env python3
"""Los plazos de hypridle, editables desde Settings → System → Power (fase 14E).

Decisión del usuario (2026-09-29, recomendación 5; hypridle sí es editable tras el cambio de
decisión de la 14C): `hypridle.conf` conserva su bloque `general` y lo que tenga a mano; sus dos
listeners (bloquear y apagar la pantalla) pasan, UNA vez y con copia, a `hypridle-sumi.conf`,
que el usuario no edita y Settings reescribe, incluido con `source =`. Sin suspensión automática en
esta máquina (el despertar del hardware es firmware): no se ofrece.

    idle-config.py status                 dónde está, si está gestionado, plazos, servicio
    idle-config.py enable                 activar: mover los dos listeners al archivo gestionado
    idle-config.py set <lock> <screenOff> segundos (0 = nunca); reescribe el archivo gestionado
    idle-config.py disable                devolver los listeners a hypridle.conf (exacto si no se tocó)

Cada cambio: valida los tipos y el ORDEN (bloquear antes de apagar la pantalla), prueba el
candidato con una instancia de hypridle APARTE (comandos cambiados por `true`, sin inhibidor de
suspensión, 1,5 s: sólo se lee lo que registra), escribe con copia, reinicia SÓLO hypridle.service y
comprueba en su journal que registró exactamente esos plazos. Si no, vuelve a lo anterior y lo dice.

Medido el 2026-09-29 (hypridle 0.1.8):
  · Al arrancar escribe «Registered timeout rule for Ns» por listener y «found N rules».
  · `source =` acepta `~`. Con el archivo incluido AUSENTE o con un valor inválido escribe
    «Config has errors» y SIGUE corriendo con 0 reglas: no bloquearía nunca, en silencio. Por eso el
    archivo gestionado se escribe antes que la línea `source` y va versionado (dotbackup lo lleva).
  · Sólo lee su configuración al arrancar: aplicar = reiniciar la unidad (~1 s sin su inhibidor).
  · Una segunda instancia con Wayland y el bus de sesión choca con la real por el nombre D-Bus
    org.freedesktop.ScreenSaver; la de prueba va aislada (sin Wayland ni bus) y sale al instante.

Salida: JSON; código 1 si ok es false. Entorno para pruebas: SUMI_IDLE_DIR (fuerza la carpeta),
SUMI_HYPRIDLE, SUMI_SYSTEMCTL, SUMI_JOURNALCTL, SUMI_IDLE_STATE, SUMI_HYPR_DIALECT (F5a: fuerza el dialecto).
"""
import fcntl
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True   # F5a: no dejar __pycache__ en el árbol de la shell (puede ser de sólo lectura)
# F5f: los módulos hermanos también cuando este archivo se IMPORTA (las pruebas de la 14E lo hacen); antes sólo valía
# ejecutándolo, y quien lo importaba fallaba con ModuleNotFoundError.
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
import hypr_dialect   # F5a: el apagado de pantalla depende del dialecto de la config de Hyprland
import hypridle_conf  # F5f: dónde corre hypridle (su proceso) y su config
from xdg_paths import base_dir

HOME = os.path.expanduser("~")
_state = base_dir("XDG_STATE_HOME", ".local/state")
STATE = os.path.expanduser(os.environ.get("SUMI_IDLE_STATE", os.path.join(_state, "sumi-shell", "idle")))
RUN = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
HYPRIDLE = os.environ.get("SUMI_HYPRIDLE", "hypridle")
SYSTEMCTL = os.environ.get("SUMI_SYSTEMCTL", "systemctl")
JOURNALCTL = os.environ.get("SUMI_JOURNALCTL", "journalctl")
# F5f (H-23, HC-47): la unidad ya no es fija. Si hypridle corre en un servicio de usuario (cualquier nombre: el del autor es
# hypridle.service; con uwsm puede ser otro), se reinicia ESE servicio. Si lo lanzó Hyprland (`exec-once`) u otro programa,
# vive en un scope: no hay unidad que reiniciar y los plazos no se pueden aplicar desde aquí (sólo lectura, con el motivo);
# la shell no mata ni relanza un proceso ajeno. Para pruebas: SUMI_IDLE_RUNNER = unit:<nombre> · process:<scope> · none;
# con SUMI_IDLE_DIR y sin él, unit:hypridle.service (las pruebas de la 14E, como antes).
_RUNNER = []


def runner():
    """{mode: unit|process|none|unknown, unit, scope, pid, from} del hypridle de este usuario (una vez por proceso)."""
    if _RUNNER:
        return _RUNNER[0]
    forced = os.environ.get("SUMI_IDLE_RUNNER")
    if forced:
        mode, _, name = forced.partition(":")
        r = {"mode": mode, "unit": name if mode == "unit" else "", "scope": name if mode == "process" else "", "pid": 0,
             "from": "override"}
    elif os.environ.get("SUMI_IDLE_DIR"):
        r = {"mode": "unit", "unit": "hypridle.service", "scope": "", "pid": 0, "from": "test"}
    else:
        procs = hypridle_conf.processes(("hypridle",))
        if procs is None:
            r = {"mode": "unknown", "unit": "", "scope": "", "pid": 0, "from": "proc"}
        elif not procs:
            r = {"mode": "none", "unit": "", "scope": "", "pid": 0, "from": "proc"}
        else:
            pid = procs[0][0]
            cg = ""
            try:
                with open(os.path.join(hypridle_conf.PROC, str(pid), "cgroup")) as f:
                    for line in f:
                        if line.startswith("0::"):
                            cg = line.strip()[3:]
            except OSError:
                pass
            last = cg.rstrip("/").rsplit("/", 1)[-1] if cg else ""
            if last.endswith(".service"):
                r = {"mode": "unit", "unit": last, "scope": "", "pid": pid, "from": "cgroup"}
            else:
                r = {"mode": "process", "unit": "", "scope": last, "pid": pid, "from": "cgroup"}
    _RUNNER.append(r)
    return r


def unit():
    return runner()["unit"] or "hypridle.service"


def need_unit():
    """Sólo con hypridle en un servicio de usuario se pueden aplicar plazos: hypridle lee su config al arrancar."""
    r = runner()
    if r["mode"] == "unit":
        return
    if r["mode"] == "process":
        raise Refused("hypridle runs outside a user service (%s, e.g. Hyprland's exec-once): it only reads its config when it "
                      "starts, so the times can't be applied from here · run it as a systemd user service, or edit "
                      "hypridle.conf and restart it yourself" % (r["scope"] or "no unit"))
    if r["mode"] == "none":
        raise Refused("hypridle isn't running")
    raise Refused("Couldn't tell how hypridle runs")
MANAGED_NAME = "hypridle-sumi.conf"
HEADER = "# Generated by Sumi Shell Settings"
LOCK_CMD = "loginctl lock-session"
# F5a: apagar/encender la pantalla es un dispatch y cambia con el dialecto (scripts/hypr_dialect.py). Con Lua (y si
# no se sabe) es el texto de siempre: hyprctl dispatch 'hl.dsp.dpms({ action = "disable" })' / "enable".
_DIALECT = []


def dialect():
    if not _DIALECT:
        _DIALECT.append(hypr_dialect.detect())
    return _DIALECT[0]


def off_cmd(d=None):
    return hypr_dialect.dpms_command(d or dialect(), False)


def on_cmd(d=None):
    return hypr_dialect.dpms_command(d or dialect(), True)


def screen_off_dialect(b):
    """lua | hyprlang si el listener `b` es el apagado de pantalla de ese dialecto; None si no lo es."""
    k = b["keys"]
    for d in ("lua", "hyprlang"):
        if k.get("on-timeout") == off_cmd(d) and k.get("on-resume", on_cmd(d)) == on_cmd(d):
            return d
    return None
# plazos admitidos (segundos); 0 = nunca
LOCK_RANGE = (60, 3600)
OFF_RANGE = (60, 7200)
KEEP = 10


class Refused(Exception):
    pass


# ---- dónde vive ----------------------------------------------------------------------------------

def run(argv, timeout=10):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except (OSError, subprocess.TimeoutExpired) as e:
        return 127, "", str(e)


def main_pid():
    rc, out, _ = run([SYSTEMCTL, "--user", "show", unit(), "-p", "MainPID", "--value"])
    try:
        return int(out.strip()) if rc == 0 else 0
    except ValueError:
        return 0


def locate():
    """{main, dir, from}: la configuración que usa el hypridle que corre (su -c, o su XDG_CONFIG_HOME,
    o HOME/.config/hypr/hypridle.conf), como la de Hyprland en la 14C."""
    forced = os.environ.get("SUMI_IDLE_DIR")
    if forced:
        d = os.path.expanduser(forced)
        return {"main": os.path.join(d, "hypridle.conf"), "dir": d, "from": "override"}
    # F5f: el PID del hypridle detectado (en modo proceso no hay MainPID de unidad); su -c o su XDG, como hypridle_conf.
    # Sin hypridle no se pregunta a ninguna unidad: la config sería la de por defecto.
    r = runner()
    pid = r["pid"] or (main_pid() if r["mode"] in ("unit", "unknown") else 0)
    if pid:
        return hypridle_conf.locate(pid)
    d = os.path.join(base_dir("XDG_CONFIG_HOME", ".config"), "hypr")
    return {"main": os.path.join(d, "hypridle.conf"), "dir": d, "from": "default"}


def tilde(p):
    return "~" + p[len(HOME):] if p.startswith(HOME + "/") else p


# ---- leer y escribir el formato de hypridle (hyprlang, lo justo) --------------------------------

def blocks(text):
    """Los bloques de primer nivel: [{name, start, end, keys: {k: v}}] (líneas 0-based, incluidas)."""
    out, cur = [], None
    lines = text.split("\n")
    for i, raw in enumerate(lines):
        line = raw.split("#", 1)[0].strip() if not raw.strip().startswith("#") else ""
        if cur is None:
            m = re.match(r"^([\w-]+)\s*\{$", line)
            if m:
                cur = {"name": m.group(1), "start": i, "end": i, "keys": {}}
            continue
        if line == "}":
            cur["end"] = i
            out.append(cur)
            cur = None
            continue
        m = re.match(r"^([\w.-]+)\s*=\s*(.*)$", raw.strip())
        if m:
            cur["keys"][m.group(1)] = m.group(2).strip()
    return out


def kind_of(b):
    """lock | screenOff | None (otro listener: se queda donde está)."""
    k = b["keys"]
    if b["name"] != "listener":
        return None
    if k.get("on-timeout") == LOCK_CMD and "on-resume" not in k:
        return "lock"
    if screen_off_dialect(b):        # F5a: en cualquiera de los dos dialectos
        return "screenOff"
    return None


def timeout_of(b):
    try:
        return int(b["keys"].get("timeout", ""))
    except ValueError:
        return -1


def render(lock, off):
    out = [HEADER + " · Settings → System → Power lo reescribe; no lo edites a mano.",
           "# sumi-idle lock=%d screenOff=%d" % (lock, off),
           "# Lo incluye hypridle.conf con `source =` (su bloque general sigue allí).", ""]
    if lock:
        out += ["listener {", "    timeout = %d" % lock, "    on-timeout = " + LOCK_CMD, "}", ""]
    if off:
        out += ["listener {", "    timeout = %d" % off, "    on-timeout = " + off_cmd(),
                "    on-resume = " + on_cmd(), "}", ""]
    if not lock and not off:
        out += ["# Nada: ni bloquear ni apagar la pantalla por inactividad.", ""]
    return "\n".join(out)


def managed_times(text):
    m = re.search(r"^# sumi-idle lock=(\d+) screenOff=(\d+)\s*$", text or "", re.M)
    return (int(m.group(1)), int(m.group(2))) if m else None


def source_line(path):
    return "source = " + tilde(path)


def is_our_source(line, path):
    s = line.strip()
    return s.startswith("source") and s.split("=", 1)[-1].strip() in (tilde(path), path)


def validate_times(lock, off):
    for v, (lo, hi), what in ((lock, LOCK_RANGE, "Lock"), (off, OFF_RANGE, "Screen off")):
        if not isinstance(v, int) or isinstance(v, bool) or (v != 0 and not lo <= v <= hi):
            raise Refused("%s must be never or from %d to %d minutes" % (what, lo // 60, hi // 60))
    if lock and off and off < lock:
        raise Refused("The screen would turn off before the session locks")


def expected_rules(main_text, managed_text):
    """Los plazos que hypridle debería registrar con esos dos archivos."""
    t = [timeout_of(b) for b in blocks(main_text) if b["name"] == "listener"]
    t += [timeout_of(b) for b in blocks(managed_text or "") if b["name"] == "listener"]
    return sorted(x for x in t)


# ---- probar un candidato con una instancia aparte -------------------------------------------------

CMD_KEYS = ("lock_cmd", "unlock_cmd", "before_sleep_cmd", "after_sleep_cmd", "on_lock_cmd", "on_unlock_cmd",
            "on-timeout", "on-resume")


def sanitize(text, managed_path, test_managed):
    """Lo mismo, pero sin efectos: comandos → `true`, sin inhibidor de suspensión, y el `source`
    apuntando a la copia de prueba del gestionado."""
    out = []
    for raw in text.split("\n"):
        s = raw.strip()
        m = re.match(r"^([\w.-]+)\s*=", s)
        if m and m.group(1) in CMD_KEYS:
            out.append("    %s = true" % m.group(1))
        elif m and m.group(1) == "inhibit_sleep":
            out.append("    inhibit_sleep = 0")
        elif is_our_source(raw, managed_path):
            out.append("source = " + test_managed)
        else:
            out.append(raw)
    return "\n".join(out)


def parse_log(text):
    errs = [l for l in text.splitlines() if "[ERR]" in l or "Config error" in l]
    rules = sorted(int(x) for x in re.findall(r"Registered timeout rule for (\d+)s", text))
    return rules, errs


def try_candidate(main_text, managed_text, managed_path):
    with tempfile.TemporaryDirectory(prefix="sumi-idle-") as tmp:
        tm = os.path.join(tmp, "managed.conf")
        open(tm, "w").write(sanitize(managed_text or "", managed_path, tm))
        mm = os.path.join(tmp, "main.conf")
        open(mm, "w").write(sanitize(main_text, managed_path, tm))
        # AISLADA (medido 2026-09-29): sin Wayland ni bus de sesión, hypridle lee la configuración,
        # apunta sus reglas y errores y sale en milisegundos. Con ellos tocaría el idle de Wayland y
        # pelearía por org.freedesktop.ScreenSaver con el hypridle real («Is hypridle already running?»).
        env = {k: v for k, v in os.environ.items() if k not in ("WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE")}
        env.update(XDG_RUNTIME_DIR=tmp, DBUS_SESSION_BUS_ADDRESS="unix:path=%s/no-bus" % tmp)
        try:
            p = subprocess.run(["timeout", "1.5", HYPRIDLE, "-c", mm, "-v"], capture_output=True, text=True,
                               timeout=6, env=env)
            log = p.stdout + p.stderr
        except (OSError, subprocess.TimeoutExpired) as e:
            raise Refused("Could not test hypridle: %s" % e)
    rules, errs = parse_log(log)
    want = expected_rules(main_text, managed_text)
    if errs:
        raise Refused("hypridle rejects it: " + errs[-1][-160:])
    if rules != want:
        raise Refused("hypridle would register %s instead of %s" % (rules, want))
    return rules


# ---- aplicar: reiniciar sólo hypridle y comprobarlo ----------------------------------------------

def cursor():
    rc, out, _ = run([JOURNALCTL, "--user", "-u", unit(), "-n", "0", "--show-cursor", "-o", "cat"])
    m = re.search(r"-- cursor: (\S+)", out)
    return m.group(1) if m else ""


def restart_and_verify(want):
    """(ok, detalle): reinicia hypridle.service y espera a leer en su journal las reglas `want`."""
    before = main_pid()
    cur = cursor()
    rc, _, err = run([SYSTEMCTL, "--user", "restart", unit()], timeout=30)
    if rc != 0:
        return False, {"error": "Could not restart hypridle: " + err.strip()[:120]}
    end = time.time() + 10
    rules, errs, log = [], [], ""
    while time.time() < end:
        argv = [JOURNALCTL, "--user", "-u", unit(), "-o", "cat", "--no-pager"]
        argv += ["--after-cursor", cur] if cur else ["-n", "200"]
        _, log, _ = run(argv)
        rules, errs = parse_log(log)
        if "found " in log and "rules" in log:
            break
        time.sleep(0.25)
    active = run([SYSTEMCTL, "--user", "is-active", unit()])[1].strip()
    pid = main_pid()
    det = {"rules": rules, "want": want, "errors": errs[-2:], "active": active, "pid": pid, "oldPid": before}
    ok = active == "active" and pid != before and not errs and rules == want
    if not ok:
        det["error"] = ("hypridle is not running" if active != "active" else
                        "hypridle reported errors" if errs else
                        "hypridle registered %s instead of %s" % (rules, want))
    return ok, det


# ---- archivos ------------------------------------------------------------------------------------

def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeDecodeError):
        return None


def write_atomic(path, data, mode=0o644):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix="." + os.path.basename(path) + ".", dir=d)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def backup(path, tag):
    data = read(path)
    if data is None:
        return ""
    os.makedirs(STATE, exist_ok=True)
    dst = os.path.join(STATE, "%s.%d" % (tag, int(time.time() * 1000)))
    write_atomic(dst, data, 0o600)
    for n in sorted((n for n in os.listdir(STATE) if n.startswith(tag + ".")), reverse=True)[KEEP:]:
        try:
            os.remove(os.path.join(STATE, n))
        except OSError:
            pass
    return dst


def meta():
    try:
        return json.load(open(os.path.join(STATE, "migration.json")))
    except (OSError, ValueError):
        return {}


def sha(t):
    return hashlib.sha256((t or "").encode()).hexdigest()


# ---- estado --------------------------------------------------------------------------------------

def status():
    loc = locate()
    main = read(loc["main"])
    managed_path = os.path.join(loc["dir"], MANAGED_NAME)
    managed = read(managed_path)
    if main is None:
        # F5h: también sin archivo se dice cómo corre hypridle (sin hypridle ni archivo, Settings da el motivo de F5f)
        return {"ok": False, "error": "hypridle.conf was not found in " + tilde(loc["dir"]), "config": loc,
                "runner": runner(), "editable": runner()["mode"] == "unit"}
    ours = any(is_our_source(l, managed_path) for l in main.split("\n"))
    generated = managed is not None and managed.startswith(HEADER)
    times = managed_times(managed) if generated else None
    listeners = [{"timeout": timeout_of(b), "kind": kind_of(b)} for b in blocks(main) if b["name"] == "listener"]
    state = ("on" if ours and generated and times else "broken" if ours else
             "off" if not (managed is not None and not generated) else "foreign")
    if not ours:
        lk = [b for b in blocks(main) if kind_of(b) == "lock"]
        of = [b for b in blocks(main) if kind_of(b) == "screenOff"]
        times = (timeout_of(lk[0]) if lk else 0, timeout_of(of[0]) if of else 0)
    return {"ok": True, "state": state, "config": dict(loc, main=tilde(loc["main"]), dir=tilde(loc["dir"])),
            "managedFile": tilde(managed_path), "lock": times[0] if times else 0, "screenOff": times[1] if times else 0,
            "otherListeners": [l for l in listeners if l["kind"] is None],
            "migratable": not ours and len([b for b in blocks(main) if kind_of(b) == "lock"]) <= 1
                          and len([b for b in blocks(main) if kind_of(b) == "screenOff"]) <= 1,
            "service": (run([SYSTEMCTL, "--user", "is-active", unit()])[1].strip() if runner()["mode"] == "unit"
                        else {"process": "running", "none": "inactive"}.get(runner()["mode"], "unknown")),
            # F5f: cómo corre hypridle (unit → se pueden aplicar plazos; process/none → sólo lectura, con el motivo)
            "runner": runner(), "editable": runner()["mode"] == "unit",
            # F5a: el dialecto de la sesión y el del apagado de pantalla escrito (otro dialecto = no apagaría)
            "dialect": dialect(), "screenOffDialect": written_off_dialect(main, managed if generated else None)}


def written_off_dialect(main, managed):
    for b in blocks(managed if managed is not None else main):
        if kind_of(b) == "screenOff":
            return screen_off_dialect(b)
    return None


# ---- operaciones ---------------------------------------------------------------------------------

def install(loc, new_main, new_managed, managed_path, want):
    """Escribe (gestionado primero: una línea `source` sin su archivo dejaría hypridle sin reglas),
    reinicia y verifica; si falla, vuelve a lo anterior. Devuelve el resultado."""
    old_main = read(loc["main"])
    old_managed = read(managed_path)
    b1 = backup(loc["main"], "hypridle.conf")
    b2 = backup(managed_path, MANAGED_NAME) if old_managed is not None else ""
    if new_managed is not None:
        write_atomic(managed_path, new_managed)
    if new_main is not None and new_main != old_main:
        write_atomic(loc["main"], new_main)
    ok, det = restart_and_verify(want)
    if ok:
        return {"ok": True, "details": det, "backup": b1, "backupManaged": b2}
    # volver a lo de antes y comprobarlo también
    if new_main is not None and new_main != old_main:
        write_atomic(loc["main"], old_main)
    if old_managed is None:
        if new_managed is not None:
            os.remove(managed_path)
    else:
        write_atomic(managed_path, old_managed)
    back_ok, back = restart_and_verify(expected_rules(old_main, old_managed if any(
        is_our_source(l, managed_path) for l in old_main.split("\n")) else None))
    return {"ok": False, "error": det.get("error", "Could not apply"), "restored": True, "restoredOk": back_ok,
            "details": det, "back": back}


def enable():
    need_unit()                                   # F5f: sin servicio de usuario no hay cómo aplicar
    loc = locate()
    st = status()
    if not st.get("ok"):
        raise Refused(st["error"])
    if st["state"] == "on":
        return {"ok": True, "already": True, "state": "on"}
    if st["state"] == "foreign":
        raise Refused(MANAGED_NAME + " exists and Settings did not write it · it was left untouched")
    if st["state"] == "broken":
        raise Refused("hypridle.conf already sources the managed file, but it is not Settings' · check it by hand")
    if not st["migratable"]:
        raise Refused("hypridle.conf has more than one lock or screen-off timer · edit it by hand")
    main = read(loc["main"])
    managed_path = os.path.join(loc["dir"], MANAGED_NAME)
    lines = main.split("\n")
    drop = set()
    for b in blocks(main):
        if kind_of(b) in ("lock", "screenOff"):
            drop.update(range(b["start"], b["end"] + 1))
            if b["start"] > 0 and not lines[b["start"] - 1].strip():
                drop.add(b["start"] - 1)
    kept = [l for i, l in enumerate(lines) if i not in drop]
    while kept and not kept[-1].strip():
        kept.pop()
    new_main = "\n".join(kept) + "\n\n# Plazos de inactividad: los escribe Settings → System → Power (Sumi Shell)\n" \
        + source_line(managed_path) + "\n"
    lock, off = st["lock"], st["screenOff"]
    validate_times(lock, off)
    new_managed = render(lock, off)
    want = try_candidate(new_main, new_managed, managed_path)
    res = install(loc, new_main, new_managed, managed_path, want)
    if res["ok"]:
        os.makedirs(STATE, exist_ok=True)
        write_atomic(os.path.join(STATE, "migration.json"),
                     json.dumps({"original": res["backup"], "migratedSha": sha(new_main), "at": int(time.time())}), 0o600)
    res.update({"state": "on" if res["ok"] else "off", "lock": lock, "screenOff": off})
    return res


def set_times(lock, off):
    need_unit()                                   # F5f: sin servicio de usuario no hay cómo aplicar
    loc = locate()
    st = status()
    if not st.get("ok"):
        raise Refused(st["error"])
    if st["state"] != "on":
        raise Refused("Turn on editing the idle times first")
    validate_times(lock, off)
    if (lock, off) == (st["lock"], st["screenOff"]):
        return {"ok": True, "unchanged": True, "lock": lock, "screenOff": off}
    managed_path = os.path.join(loc["dir"], MANAGED_NAME)
    main = read(loc["main"])
    new_managed = render(lock, off)
    want = try_candidate(main, new_managed, managed_path)
    res = install(loc, None, new_managed, managed_path, want)
    res.update({"lock": lock, "screenOff": off, "undo": {"lock": st["lock"], "screenOff": st["screenOff"]}})
    return res


def disable():
    need_unit()                                   # F5f: sin servicio de usuario no hay cómo aplicar
    loc = locate()
    st = status()
    if not st.get("ok"):
        raise Refused(st["error"])
    if st["state"] == "off":
        return {"ok": True, "already": True, "state": "off"}
    if st["state"] != "on":
        raise Refused("The managed file is not Settings' · check hypridle.conf by hand")
    main = read(loc["main"])
    managed_path = os.path.join(loc["dir"], MANAGED_NAME)
    m = meta()
    original = read(m.get("original", "")) if m.get("original") else None
    if original is not None and sha(main) == m.get("migratedSha"):
        new_main = original                           # nadie lo tocó: el archivo de antes, exacto
    else:
        # lo editaste después: la línea `source` se cambia por los listeners, y lo demás se queda
        body = "\n".join(l for l in render(st["lock"], st["screenOff"]).split("\n") if not l.startswith("#")).strip()
        new_main = "\n".join((body if is_our_source(l, managed_path) else l) for l in main.split("\n"))
        new_main = new_main.replace("# Plazos de inactividad: los escribe Settings → System → Power (Sumi Shell)\n", "")
    want = try_candidate(new_main, None, managed_path)
    res = install(loc, new_main, None, managed_path, want)
    if res["ok"]:
        archived = backup(managed_path, MANAGED_NAME)
        os.remove(managed_path)
        res["archived"] = archived
    res["state"] = "off" if res["ok"] else "on"
    return res


def main(argv):
    if len(argv) < 2 or argv[1] not in ("status", "enable", "set", "disable"):
        print(__doc__, file=sys.stderr)
        return 2
    cmd = argv[1]
    try:
        if cmd == "status":
            res = status()
        else:
            for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
                signal.signal(sig, signal.SIG_IGN)   # un reinicio a medias es peor que terminarlo
            lock = open(os.path.join(RUN, "sumi-idle-config.lock"), "w")
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                raise Refused("Another change to the idle times is in progress")
            if cmd == "enable":
                res = enable()
            elif cmd == "disable":
                res = disable()
            else:
                try:
                    res = set_times(int(argv[2]), int(argv[3]))
                except (IndexError, ValueError):
                    raise Refused("usage: set <lock seconds> <screen-off seconds>")
            res["action"] = cmd
            res["at"] = int(time.time() * 1000)
    except Refused as e:
        res = {"ok": False, "error": str(e), "refused": True, "action": cmd}
    except OSError as e:
        res = {"ok": False, "error": "Could not write: %s" % e, "action": cmd}
    json.dump(res, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0 if res.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
