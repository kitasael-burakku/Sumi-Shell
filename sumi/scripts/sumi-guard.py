#!/usr/bin/env python3
"""Watchdog de las pruebas de sistema (fase 14B): aplicar → verificar → esperar → mantener o revertir.

Vive FUERA del shell: el shell lo lanza como unidad transitoria de systemd
(`systemd-run --user`) y desde ese momento el compromiso de revertir no depende de que QML siga
vivo (futureSettingssurface §14: «su compromiso de revertir no depende de que QML siga vivo»).
Cerrar Settings, recargar o reiniciar el shell, o matarlo, no para la cuenta.

    sumi-guard.py launch <kind> <propuesta JSON> [--timeout S] [--only REGEX]
        Valida, escribe la transacción y arranca la unidad `sumi-guard-<id>`. Imprime
        {"ok": true, "id": …} o {"ok": false, "error": …}. Vuelve enseguida.
    sumi-guard.py run <id>        (la unidad) aplica, verifica y espera.
    sumi-guard.py post <id>       (ExecStopPost de la unidad) si la transacción no terminó —el
                                     guard murió, incluso con SIGKILL, o systemd lo paró por
                                     RuntimeMaxSec—, revierte.
    sumi-guard.py check <kind> <propuesta JSON> [--only REGEX]
        Sólo valida contra las salidas reales: {"ok": …, "error": …}. No lanza nada.
    sumi-guard.py decide <id> keep|revert
    sumi-guard.py list            las transacciones (las viejas terminadas se borran).
    sumi-guard.py ack <id>…       el shell ya enseñó su resultado (una o varias).

Estados: starting → applying → testing → kept | reverting → reverted | failed.
Archivos en $XDG_RUNTIME_DIR/sumi-guard/ (<id>.json, <id>.decision), escritos por renombrado.

Tipos: `displays` (fase 14B). La propuesta: {"<salida>": {"mode": "WxH@R", "position": "XxY",
"scale": n, "transform": 0-7}}. Nada de lo recibido se concatena como texto: cada valor se valida
contra su tipo y el Lua se construye desde esos tipos (futureSettingssurface §15).

`audio-profile` (fase 14F): {"card": <nombre ALSA>, "profile": <perfil>} con pactl: el perfil tiene que
existir y estar disponible (decisión 6). Revertir = el perfil de antes y, si la salida o la entrada
predeterminadas se movieron, devolverlas. Medido: el cambio tarda ~0,1 s; WirePlumber recuerda el
perfil de cada tarjeta (default-profile) y al revertir recuerda el de antes. Medido en la prueba real
del usuario (HDMI → Off, 2026-09-29): el reproductor (mpv/maly) se PAUSA cuando su salida desaparece y
no se reanuda al volver; revertir apunta los reproductores MPRIS que sonaban y reanuda los que la
prueba dejó en pausa.

`network` (fase 14D): {"uuid": …, "props": {…}} (las de scripts/nm_edit.py) sobre un perfil ACTIVO.
starting → authorizing (checkpoint de NetworkManager sólo sobre SUS interfaces: aquí polkit pide la
contraseña) → applying (`modify --temporary` + `device reapply`, y verificar la interfaz) → testing →
kept (destruir el checkpoint y guardar en disco) | reverted (rollback de NetworkManager). El
checkpoint lleva su propio plazo: si este proceso muere, NetworkManager revierte solo, y `post` sólo
espera a que lo haga, lo comprueba y lo apunta (no puede pedir otra contraseña).

Medido (Hyprland 0.56.2, 2026-09-29): una regla que `hyprctl eval` rechaza aplica igualmente sus
campos válidos, una escala no válida se ajusta en silencio y una salida headless acepta cualquier
modo. Por eso: se valida todo ANTES, se revierte también si eval falla, y el resultado se juzga
leyendo el estado real, no por la respuesta de eval.
"""
import json
import os
import re
import select
import signal
import socket
import subprocess
import sys
import time

sys.dont_write_bytecode = True   # F5a: no dejar __pycache__ en el árbol de la shell (puede ser de sólo lectura)
# F5f: los módulos hermanos también cuando este archivo se IMPORTA (las pruebas de la 14E lo hacen); antes sólo valía
# ejecutándolo, y quien lo importaba fallaba con ModuleNotFoundError.
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
import hypr_dialect   # F5a: la forma del monitor según el dialecto de la config (scripts/hypr_dialect.py)

RUN = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "sumi-guard")
HERE = os.path.dirname(os.path.abspath(__file__))
KINDS = ("displays", "network", "audio-profile")
PACTL = os.environ.get("SUMI_PACTL", "pactl")
CARD = re.compile(r"^[A-Za-z0-9_.:+-]{1,128}$")
LIVE = ("starting", "authorizing", "applying", "testing", "reverting")
HYPRCTL = os.environ.get("SUMI_HYPRCTL", "hyprctl")
FINAL = ("kept", "reverted", "failed")
UNIT_PREFIX = "sumi-guard-"
NAME = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
MODE = re.compile(r"^(\d{3,5})x(\d{3,5})@(\d{1,3}(?:\.\d{1,3})?)$")
POS = re.compile(r"^(-?\d{1,5})x(-?\d{1,5})$")
ID = re.compile(r"^[a-z0-9-]{6,40}$")


def now_ms():
    return int(time.time() * 1000)


def path(tid, ext="json"):
    return os.path.join(RUN, "%s.%s" % (tid, ext))


def load(tid):
    try:
        with open(path(tid)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def save(t):
    os.makedirs(RUN, mode=0o700, exist_ok=True)
    t["updated"] = now_ms()
    tmp = path(t["id"], "json.tmp")
    with open(tmp, "w") as f:
        json.dump(t, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path(t["id"]))


def log(t, msg):
    t.setdefault("log", []).append("%d %s" % (now_ms() - t.get("created", now_ms()), msg))
    t["log"] = t["log"][-40:]


def hyprctl(*args, timeout=5):
    try:
        p = subprocess.run([HYPRCTL] + list(args), capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return 127, "", str(e)


# ---- displays ----------------------------------------------------------------------------

def monitors():
    rc, out, _ = hyprctl("monitors", "all", "-j")
    if rc != 0:
        return None
    try:
        return {m["name"]: m for m in json.loads(out)}
    except (ValueError, KeyError, TypeError):
        return None


def mode_of(m):
    return "%dx%d@%.2f" % (m["width"], m["height"], m["refreshRate"])


def snapshot(m):
    """El estado de una salida como configuración que se puede volver a aplicar."""
    s = {"mode": mode_of(m), "position": "%dx%d" % (m["x"], m["y"]),
         "scale": round(float(m["scale"]), 4), "transform": int(m.get("transform", 0))}
    if "vrr" in m:
        s["vrr"] = 1 if m["vrr"] else 0
    if "2101010" in str(m.get("currentFormat", "")):
        s["bitdepth"] = 10
    return s


_DIALECT = []


def dialect():
    """El dialecto de la config de Hyprland, preguntado una vez por proceso."""
    if not _DIALECT:
        _DIALECT.append(hypr_dialect.detect())
    return _DIALECT[0]


def check_output(name, cfg, live, only):
    """Validación de tipo y contra la salida real. Devuelve el cfg normalizado o lanza ValueError."""
    if not NAME.match(name):
        raise ValueError("bad output name")
    # F5a: con hyprland.conf, Hyprland 0.56.2 sólo aplica la primera regla `keyword monitor` en caliente de cada
    # salida (medido): la vuelta atrás no aplicaría. Se niega antes de tocar nada.
    if hypr_dialect.norm(dialect()) == "hyprlang":
        raise ValueError("Display tests need Hyprland's Lua config (hyprland.conf can't undo a hot monitor change)")
    if only and not re.search(only, name):
        raise ValueError("%s is outside this test (only %s)" % (name, only))
    m = live.get(name)
    if m is None:
        raise ValueError("%s is not connected" % name)
    if m.get("disabled"):
        raise ValueError("%s is disabled" % name)
    out = {}
    mm = MODE.match(str(cfg.get("mode", "")))
    if not mm:
        raise ValueError("bad mode for %s" % name)
    w, h, r = int(mm.group(1)), int(mm.group(2)), float(mm.group(3))
    avail = m.get("availableModes") or []
    # una salida virtual (headless: sin fabricante ni modelo) anuncia sólo su modo inicial pero acepta
    # cualquiera (medido); una física, sólo los que anuncia
    virtual = not m.get("make") and not m.get("model")
    if avail and not virtual:
        ok = False
        for a in avail:
            am = re.match(r"^(\d+)x(\d+)@([\d.]+)Hz$", a)
            if am and int(am.group(1)) == w and int(am.group(2)) == h and abs(float(am.group(3)) - r) < 0.02:
                ok = True
                break
        if not ok:
            raise ValueError("%s does not offer %dx%d@%g" % (name, w, h, r))
    elif not (320 <= w <= 7680 and 200 <= h <= 4320 and 1 <= r <= 500):
        raise ValueError("mode out of range for %s" % name)
    out["mode"] = "%dx%d@%.2f" % (w, h, r)
    pm = POS.match(str(cfg.get("position", "")))
    if not pm:
        raise ValueError("bad position for %s" % name)
    out["position"] = "%dx%d" % (int(pm.group(1)), int(pm.group(2)))
    sc = cfg.get("scale")
    if not isinstance(sc, (int, float)) or isinstance(sc, bool) or not (0.25 <= sc <= 4):
        raise ValueError("bad scale for %s" % name)
    out["scale"] = round(float(sc), 4)
    tr = cfg.get("transform", 0)
    if not isinstance(tr, int) or isinstance(tr, bool) or not (0 <= tr <= 7):
        raise ValueError("bad rotation for %s" % name)
    out["transform"] = tr
    return out


def matches(m, cfg):
    mm = MODE.match(cfg["mode"])
    pm = POS.match(cfg["position"])
    return (m["width"] == int(mm.group(1)) and m["height"] == int(mm.group(2))
            and abs(m["refreshRate"] - float(mm.group(3))) < 0.5
            and m["x"] == int(pm.group(1)) and m["y"] == int(pm.group(2))
            and abs(m["scale"] - cfg["scale"]) < 0.01
            and int(m.get("transform", 0)) == int(cfg.get("transform", 0)))


def apply_displays(t, cfgs, label):
    """Aplica y espera hasta 3 s a que el estado real coincida. Devuelve (ok, detalle)."""
    errs = []
    for name, cfg in cfgs.items():
        # F5a: el texto lo da hypr_dialect desde valores ya validados (con Lua, el mismo `hl.monitor` de antes)
        argv = hypr_dialect.monitor_argv(dialect(), name, cfg)
        if argv is None:
            errs.append("%s: display tests need Hyprland's Lua config" % name)
            continue
        rc, out, err = hyprctl(*argv)
        log(t, "%s eval %s rc=%d %s" % (label, name, rc, (out or err)[:120]))
        if rc != 0 or not out.startswith("ok"):
            errs.append("%s: %s" % (name, (out or err)[:120]))
    deadline = time.time() + 3
    last = None
    while time.time() < deadline:
        live = monitors() or {}
        bad = [n for n, c in cfgs.items() if n not in live or not matches(live[n], c)]
        if not bad:
            return (not errs), "; ".join(errs)
        last = {n: live.get(n) for n in bad}
        time.sleep(0.15)
    return False, "; ".join(errs + [differences(n, cfgs[n], m) for n, m in (last or {}).items()])


def differences(name, cfg, m):
    """En palabras, qué no quedó como se pidió (Hyprland ajusta escalas en silencio: medido)."""
    if m is None:
        return "%s is gone" % name
    got = snapshot(m)
    out = []
    for k, label in (("mode", "mode"), ("position", "position"), ("scale", "scale"), ("transform", "rotation")):
        a, b = cfg.get(k), got.get(k)
        if k == "mode":
            mm = MODE.match(a)
            same = (m["width"], m["height"]) == (int(mm.group(1)), int(mm.group(2))) and abs(m["refreshRate"] - float(mm.group(3))) < 0.5
        elif k == "scale":
            same = abs(float(a) - float(b)) < 0.01
        else:
            same = str(a) == str(b)
        if not same:
            out.append("%s %s instead of %s" % (label, b, a))
    return "%s: Hyprland used %s" % (name, ", ".join(out) or "something else")


def fallback_displays(t, names):
    """El último recurso: el modo preferido de cada salida, en automático, escala 1."""
    live = monitors() or {}
    done = []
    for n in names:
        if n not in live:
            continue
        argv = hypr_dialect.monitor_argv(dialect(), n, "preferred")
        if argv is None:
            continue
        rc, out, err = hyprctl(*argv)
        log(t, "fallback %s rc=%d %s" % (n, rc, (out or err)[:80]))
        done.append(n)
    time.sleep(1)
    live = monitors() or {}
    return [n for n in done if n in live and not live[n].get("disabled")]


# ---- ciclo de una transacción ------------------------------------------------------------

class Stop(Exception):
    pass


def revert(t, reason):
    """Volver a `before` para las salidas que siguen conectadas, verificar y, si no, el recurso."""
    t["state"] = "reverting"
    t["reason"] = reason
    save(t)
    live = monitors() or {}
    before = {n: c for n, c in (t.get("before") or {}).items() if n in live}
    gone = [n for n in (t.get("before") or {}) if n not in live]
    ok, detail = apply_displays(t, before, "revert") if before else (True, "")
    t["revertDetail"] = detail
    if ok:
        t["state"] = "reverted"
        t["remained"] = []
    else:
        alive = fallback_displays(t, list(before))
        t["state"] = "failed"
        t["remained"] = ["%s: back to its preferred mode" % n for n in alive] or ["could not restore the displays"]
    if gone:
        t["gone"] = gone
    log(t, "end %s (%s)" % (t["state"], reason))
    save(t)


def socket2():
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    base = os.environ.get("XDG_RUNTIME_DIR", "")
    p = os.path.join(base, "hypr", sig, ".socket2.sock")
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(p)
        s.setblocking(False)
        return s
    except OSError:
        return None


def run(tid):
    t = load(tid)
    if not t or t.get("state") != "starting":
        return 1

    def on_term(signum, frame):
        raise Stop("The guard was stopped")
    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)
    if t.get("kind") == "network":
        return run_network(t)
    if t.get("kind") == "audio-profile":
        return run_audio(t)

    try:
        live = monitors()
        if live is None:
            t["state"] = "failed"
            t["reason"] = "Hyprland is not answering"
            save(t)
            return 1
        try:
            cfgs = {n: check_output(n, c, live, t.get("only", "")) for n, c in t["proposal"].items()}
        except ValueError as e:
            t["state"] = "failed"
            t["reason"] = str(e)
            save(t)
            return 1
        # el snapshot es el estado REAL al empezar, no lo que creyera el shell
        t["before"] = {n: snapshot(live[n]) for n in cfgs}
        t["state"] = "applying"
        save(t)
        ev = socket2()   # antes de aplicar: un monitor que se va durante la prueba se oye
        ok, detail = apply_displays(t, cfgs, "apply")
        if not ok:
            revert(t, "Could not apply: " + detail)
            return 0
        t["state"] = "testing"
        t["deadline"] = now_ms() + int(t["timeoutMs"])
        save(t)
        buf = b""
        while True:
            if now_ms() >= t["deadline"]:
                revert(t, "No confirmation in %d s" % (int(t["timeoutMs"]) // 1000))
                return 0
            if os.path.exists(path(tid, "decision")):
                with open(path(tid, "decision")) as f:
                    d = f.read().strip()
                if d == "keep":
                    t["state"] = "kept"
                    t["reason"] = "Kept"
                    log(t, "end kept")
                    save(t)
                    return 0
                revert(t, "Reverted")
                return 0
            if ev is None:
                time.sleep(0.1)
                continue
            r, _, _ = select.select([ev], [], [], 0.1)
            if not r:
                continue
            try:
                chunk = ev.recv(65536)
            except OSError:
                chunk = b""
            if not chunk:
                ev = None
                continue
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                name, _, data = line.decode("utf-8", "replace").partition(">>")
                if name in ("monitorremoved", "monitorremovedv2"):
                    gone = data if name == "monitorremoved" else (data.split(",") + ["", ""])[1]
                    if gone in t["before"]:
                        revert(t, "%s was disconnected" % gone)
                        return 0
                elif name == "configreloaded":
                    revert(t, "Hyprland reloaded its configuration")
                    return 0
    except Stop as e:
        revert(t, str(e))
        return 0


# ---- perfiles de tarjeta de audio (fase 14F) ----------------------------------------------------

def pactl(*args, timeout=5):
    try:
        p = subprocess.run([PACTL] + list(args), capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return 127, "", str(e)


def cards():
    rc, out, _ = pactl("-f", "json", "list", "cards")
    try:
        return {c["name"]: c for c in json.loads(out)} if rc == 0 else None
    except (ValueError, KeyError, TypeError):
        return None


def players():
    """{instancia MPRIS: estado} de los reproductores (playerctl); {} si no hay playerctl."""
    try:
        p = subprocess.run(["playerctl", "-a", "-f", "{{playerInstance}}|{{status}}", "status"],
                           capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.TimeoutExpired):
        return {}
    out = {}
    for line in p.stdout.splitlines():
        name, _, st = line.partition("|")
        if name and st:
            out[name] = st
    return out


def resume_players(t):
    """Reanudar lo que sonaba antes de la prueba y ahora está en pausa. Devuelve [reanudados]."""
    was = [n for n, st in ((t.get("before") or {}).get("players") or {}).items() if st == "Playing"]
    if not was:
        return []
    time.sleep(0.5)                       # la salida vuelve y el reproductor se engancha
    now = players()
    done = []
    for n in was:
        if now.get(n) == "Paused":
            try:
                subprocess.run(["playerctl", "-p", n, "play"], capture_output=True, timeout=3)
                done.append(n)
            except (OSError, subprocess.TimeoutExpired):
                pass
    if done:
        log(t, "resumed %s" % ", ".join(done))
    return done


def audio_defaults():
    return {"sink": pactl("get-default-sink")[1], "source": pactl("get-default-source")[1]}


def check_audio(proposal, only):
    card, prof = proposal.get("card"), proposal.get("profile")
    if not isinstance(card, str) or not isinstance(prof, str) or not CARD.match(card) or not CARD.match(prof):
        raise ValueError("bad proposal")
    if only and not re.search(only, card):
        raise ValueError("%s is outside this test (only %s)" % (card, only))
    cs = cards()
    if cs is None:
        raise ValueError("PipeWire is not answering")
    c = cs.get(card)
    if c is None:
        raise ValueError("That sound card is not connected")
    p = (c.get("profiles") or {}).get(prof)
    if p is None:
        raise ValueError("The card has no profile %s" % prof)
    if not p.get("available", False):
        raise ValueError("That profile is not available now (nothing connected to it)")
    if c.get("active_profile") == prof:
        raise ValueError("That profile is already in use")
    return c


def set_profile(t, prof, label):
    """Pone el perfil y espera hasta 3 s a verlo activo. (ok, detalle)."""
    card = t["proposal"]["card"]
    rc, out, err = pactl("set-card-profile", card, prof)
    log(t, "%s %s rc=%d %s" % (label, prof, rc, err[:80]))
    if rc != 0:
        return False, err[:160] or "pactl refused"
    end = time.time() + 3
    while time.time() < end:
        c = (cards() or {}).get(card)
        if c and c.get("active_profile") == prof:
            return True, ""
        time.sleep(0.1)
    c = (cards() or {}).get(card)
    return False, "the card stayed on %s" % (c.get("active_profile") if c else "nothing (it is gone)")


def revert_audio(t, reason):
    t["state"] = "reverting"
    t["reason"] = reason
    save(t)
    before = t.get("before") or {}
    remained = []
    card = t["proposal"]["card"]
    if (cards() or {}).get(card) is None:
        remained.append("the card is gone")
    elif before.get("profile"):
        ok, err = set_profile(t, before["profile"], "revert")
        if not ok:
            remained.append("profile: " + err)
    # si la salida o la entrada predeterminadas se movieron (sus nodos desaparecen con el perfil),
    # devolverlas en cuanto vuelvan a existir
    for kind, getter, setter, lister in (("sink", "get-default-sink", "set-default-sink", "sinks"),
                                         ("source", "get-default-source", "set-default-source", "sources")):
        want = (before.get("defaults") or {}).get(kind, "")
        if not want:
            continue
        for _ in range(30):
            if pactl(getter)[1] == want:
                break
            names = [l.split("\t")[1] for l in pactl("list", "short", lister)[1].splitlines() if "\t" in l]
            if want in names:
                pactl(setter, want)
                log(t, "default %s back to %s" % (kind, want))
            time.sleep(0.1)
        if pactl(getter)[1] != want:
            remained.append("default %s is %s" % ("output" if kind == "sink" else "input", pactl(getter)[1] or "none"))
    t["resumed"] = resume_players(t)
    if (t.get("before") or {}).get("players") and not t["resumed"]:
        still = [n for n, st in players().items() if st == "Paused" and (t["before"]["players"].get(n) == "Playing")]
        if still:
            remained.append("paused: " + ", ".join(still))
    t["remained"] = remained
    t["state"] = "failed" if remained else "reverted"
    log(t, "end %s (%s)" % (t["state"], reason))
    save(t)


def run_audio(t):
    try:
        try:
            c = check_audio(t["proposal"], t.get("only", ""))
        except ValueError as e:
            t["state"] = "failed"
            t["reason"] = str(e)
            save(t)
            return 1
        t["before"] = {"profile": c.get("active_profile"), "defaults": audio_defaults(), "players": players()}
        profs = c.get("profiles") or {}
        name = (c.get("properties") or {}).get("device.description") or t["proposal"]["card"]
        t["detail"] = "%s · %s → %s" % (name, (profs.get(c.get("active_profile")) or {}).get("description", c.get("active_profile")),
                                          (profs.get(t["proposal"]["profile"]) or {}).get("description", t["proposal"]["profile"]))
        t["state"] = "applying"
        save(t)
        ok, err = set_profile(t, t["proposal"]["profile"], "apply")
        if not ok:
            revert_audio(t, "Could not apply: " + err)
            return 0
        t["state"] = "testing"
        t["deadline"] = now_ms() + int(t["timeoutMs"])
        save(t)
        while True:
            if now_ms() >= t["deadline"]:
                revert_audio(t, "No confirmation in %d s" % (int(t["timeoutMs"]) // 1000))
                return 0
            if os.path.exists(path(t["id"], "decision")):
                with open(path(t["id"], "decision")) as f:
                    d = f.read().strip()
                if d == "keep":
                    t["state"] = "kept"
                    t["reason"] = "Kept"
                    t["remained"] = []
                    log(t, "end kept")
                    save(t)
                    return 0
                revert_audio(t, "Reverted")
                return 0
            if (cards() or {}).get(t["proposal"]["card"]) is None:
                revert_audio(t, "The sound card was disconnected")
                return 0
            time.sleep(0.2)
    except Stop as e:
        if t.get("state") in ("applying", "testing"):
            revert_audio(t, str(e))
        return 0


# ---- red (fase 14D) ----------------------------------------------------------------------------

def _ne():
    sys.path.insert(0, HERE)
    import nm_edit
    return nm_edit


def prepare_network(proposal, only):
    """Valida la propuesta contra el perfil REAL. Devuelve (uuid, perfil, props, interfaces)."""
    ne = _ne()
    if not isinstance(proposal, dict) or not isinstance(proposal.get("uuid"), str) \
            or not re.match(r"^[0-9a-fA-F-]{36}$", proposal["uuid"]):
        raise ValueError("bad proposal")
    uuid = proposal["uuid"]
    before = ne.read_profile(uuid)
    if before is None:
        raise ValueError("That network profile does not exist")
    if only and not re.search(only, before["name"]):
        raise ValueError("%s is outside this test (only %s)" % (before["name"], only))
    if before["type"] not in ne.EDITABLE_TYPES:
        raise ValueError("This kind of connection can't be edited here")
    try:
        props = ne.validate(proposal.get("props"), before)
    except ne.Invalid as e:
        raise ValueError(str(e))
    if not props:
        raise ValueError("Nothing to change")
    devs = ne.active_devices(uuid)
    if not devs:
        raise ValueError("%s is not connected now · save it without a test" % before["name"])
    return uuid, before, props, devs


def _connectivity():
    ne = _ne()
    rc, out, _ = ne.run(["networking", "connectivity"], timeout=5)
    return out.strip() if rc == 0 else "unknown"


def _dbus_error(e):
    msg = str(getattr(e, "message", e))
    if any(x in msg for x in ("PermissionDenied", "NotAuthorized", "Not authorized", "dismissed", "cancel")):
        return "Authorization was cancelled · nothing changed"
    return "NetworkManager refused: " + msg[:160]


def _settled(ne, dev, want, seconds):
    """Esperar a que la interfaz esté CONECTADA (estado 100) y refleje `want`; [lo que falte]."""
    end = time.time() + seconds
    while True:
        st = ne.device_state(dev)
        bad = ne.matches_device(want, st)
        if st is not None and not str(st.get("state", "")).startswith("100"):
            bad = ["not connected yet (%s)" % st.get("state", "?")] + bad
        if not bad or time.time() >= end:
            return bad
        time.sleep(0.25)


def restore_network(t, reason, cp=None):
    """Volver al perfil y a las interfaces de antes: rollback del checkpoint (si este proceso lo
    tiene), y lo que NetworkManager no dejara igual se escribe y se reaplica (sin permiso extra)."""
    ne = _ne()
    t["state"] = "reverting"
    t["reason"] = reason
    save(t)
    uuid = t["proposal"]["uuid"]
    before = t["before"]["profile"]
    if cp is not None and cp.path:
        try:
            t["rollback"] = cp.rollback()
            log(t, "rollback %s" % t["rollback"])
        except Exception as e:  # noqa: BLE001 — se sigue con la reparación a mano
            log(t, "rollback failed: %s" % e)
    remained = []
    now = ne.read_profile(uuid)
    if now is None:
        remained.append("the profile is gone")
    else:
        diff = {k: before[k] for k in ne.ORDER if now.get(k) != before.get(k)}
        if diff or ne.unsaved(uuid):
            # el disco tenía lo de antes: escribirlo (también si sólo quedó «sin guardar»)
            ok, err = ne.modify(uuid, diff or {"autoconnect": before["autoconnect"]}, temporary=False)
            log(t, "profile back %s %s" % (sorted(diff), err))
            if not ok:
                remained.append("profile: " + err[:120])
    for d in t["before"]["devices"]:
        # Medido en la Wi-Fi (2026-09-29): el rollback REACTIVA la conexión (desasociar, volver a
        # asociar, DHCP: ~6–8 s). No se da por vuelta hasta verla conectada y como antes.
        bad = _settled(ne, d, before, 30)
        if bad:
            ne.reapply(d)
            bad = _settled(ne, d, before, 10)
        if bad:
            remained.append("%s: %s" % (d, "; ".join(bad)))
    t["remained"] = remained
    t["state"] = "failed" if remained else "reverted"
    t["connectivity"] = _connectivity()
    log(t, "end %s (%s)" % (t["state"], reason))
    save(t)


def run_network(t):
    ne = _ne()
    cp = None
    try:
        try:
            uuid, before, props, devs = prepare_network(t["proposal"], t.get("only", ""))
        except ValueError as e:
            t["state"] = "failed"
            t["reason"] = str(e)
            save(t)
            return 1
        t["before"] = {"profile": before, "devices": {d: ne.device_state(d) for d in devs}}
        t["props"] = props
        t["want"] = dict(before, **props)
        t["detail"] = "%s · %s" % (before["name"], ne.describe(props))
        t["state"] = "authorizing"
        save(t)
        try:
            cp = ne.Checkpoint()
            paths = [cp.device_path(d) for d in devs]
            # colchón: aplicar y verificar pueden llevar ~10 s (DHCP); se ajusta al empezar la cuenta
            cp.create(paths, int(t["timeoutMs"]) // 1000 + 60)
        except Exception as e:  # noqa: BLE001 — GLib.Error o sin bus: nada aplicado
            t["state"] = "failed"
            t["reason"] = _dbus_error(e)
            t["remained"] = []
            save(t)
            return 0
        t["checkpoint"] = cp.path
        t["state"] = "applying"
        save(t)
        ok, err = ne.modify(uuid, props, temporary=True)
        if not ok:
            restore_network(t, "Could not apply: " + err[:160], cp)
            return 0
        for d in devs:
            ok, err = ne.reapply(d)
            log(t, "reapply %s %s" % (d, err[:80]))
        bad = []
        for _ in range(48):                       # hasta 12 s (DHCP)
            time.sleep(0.25)
            bad = ["%s: %s" % (d, "; ".join(b)) for d in devs
                   for b in [ne.matches_device(t["want"], ne.device_state(d))] if b]
            if not bad:
                break
        if bad:
            restore_network(t, "Could not apply: " + "; ".join(bad)[:200], cp)
            return 0
        cp.adjust(int(t["timeoutMs"]) // 1000 + 10)
        t["state"] = "testing"
        t["deadline"] = now_ms() + int(t["timeoutMs"])
        t["connectivity"] = _connectivity()
        save(t)
        seen = now_ms()
        while True:
            if now_ms() >= t["deadline"]:
                restore_network(t, "No confirmation in %d s" % (int(t["timeoutMs"]) // 1000), cp)
                return 0
            if os.path.exists(path(t["id"], "decision")):
                with open(path(t["id"], "decision")) as f:
                    d = f.read().strip()
                if d != "keep":
                    restore_network(t, "Reverted", cp)
                    return 0
                try:
                    cp.destroy()
                except Exception as e:  # noqa: BLE001 — sin destruir, NM revertiría: mejor revertir ya
                    restore_network(t, "Could not keep: " + _dbus_error(e), cp)
                    return 0
                cp.path = ""
                ok, err = ne.modify(uuid, props, temporary=False)
                t["state"] = "kept"
                t["reason"] = "Kept"
                t["remained"] = [] if ok and not ne.unsaved(uuid) else ["kept for this session only: " + (err or "not saved")[:120]]
                log(t, "end kept %s" % t["remained"])
                save(t)
                return 0
            if now_ms() - seen > 2000:
                seen = now_ms()
                c = _connectivity()
                if c != t.get("connectivity"):
                    t["connectivity"] = c
                    save(t)
            time.sleep(0.1)
    except Stop as e:
        if t.get("state") in ("applying", "testing"):
            restore_network(t, str(e), cp)
        elif t.get("state") in ("starting", "authorizing"):
            t["state"] = "failed"
            t["reason"] = str(e) + " · nothing changed"
            save(t)
        return 0


def post_network(t):
    """El guard murió a mitad. Si llegó a crear el checkpoint, NetworkManager revierte al vencer su
    plazo (no hace falta otra contraseña): esperar a que desaparezca y comprobar lo demás."""
    ne = _ne()
    cpath = t.get("checkpoint", "")
    if t.get("state") in ("starting", "authorizing") and not cpath:
        t["state"] = "failed"
        t["reason"] = "The guard stopped before applying · nothing changed"
        save(t)
        return 0
    t["state"] = "reverting"
    t["reason"] = "The guard stopped unexpectedly · NetworkManager is rolling back"
    save(t)
    end = time.time() + int(t.get("timeoutMs", 15000)) / 1000 + 75
    while cpath and time.time() < end:
        live = ne.live_checkpoints()
        if live is not None and cpath not in live:
            break
        time.sleep(0.5)
    restore_network(t, "The guard stopped unexpectedly · NetworkManager rolled back")
    return 0


def post(tid):
    """ExecStopPost: la unidad terminó. Si la transacción no llegó a un final, revertir."""
    t = load(tid)
    if not t or t.get("state") in FINAL:
        return 0
    if t.get("kind") == "network":
        return post_network(t)
    if t.get("kind") == "audio-profile":
        if t.get("state") == "starting":
            t["state"] = "failed"
            t["reason"] = "The guard did not start · nothing changed"
            save(t)
        else:
            revert_audio(t, "The guard stopped unexpectedly")
        return 0
    if t.get("state") == "starting":
        t["state"] = "failed"
        t["reason"] = "The guard did not start"
        save(t)
        return 0
    revert(t, "The guard stopped unexpectedly")
    return 0


def unit_active(tid):
    try:
        p = subprocess.run(["systemctl", "--user", "is-active", UNIT_PREFIX + tid], capture_output=True, text=True, timeout=3)
        return p.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"


def all_txns():
    out = []
    try:
        names = os.listdir(RUN)
    except OSError:
        return out
    for n in names:
        if n.endswith(".json"):
            t = load(n[:-5])
            if t:
                out.append(t)
    out.sort(key=lambda t: t.get("created", 0), reverse=True)
    return out


def launch(kind, proposal_text, timeout, only):
    if kind not in KINDS:
        return {"ok": False, "error": "unknown kind"}
    try:
        proposal = json.loads(proposal_text)
        assert isinstance(proposal, dict) and 0 < len(proposal) <= 8
    except (ValueError, AssertionError):
        return {"ok": False, "error": "bad proposal"}
    if not (5 <= timeout <= 60):
        return {"ok": False, "error": "timeout out of range"}
    if only:
        try:
            re.compile(only)
        except re.error:
            return {"ok": False, "error": "bad --only"}
    for t in all_txns():
        if t.get("kind") == kind and t.get("state") not in FINAL and unit_active(t["id"]) in ("active", "activating"):
            return {"ok": False, "error": "Another test is running", "id": t["id"]}
    try:
        if kind == "network":
            prepare_network(proposal, only)
        elif kind == "audio-profile":
            check_audio(proposal, only)
        else:
            live = monitors()
            if live is None:
                return {"ok": False, "error": "Hyprland is not answering"}
            for n, c in proposal.items():
                check_output(n, c, live, only)
    except ValueError as e:
        return {"ok": False, "error": str(e)}
    tid = "%s-%s" % (kind[:4], format(now_ms(), "x"))
    t = {"id": tid, "kind": kind, "created": now_ms(), "timeoutMs": int(timeout * 1000), "only": only,
         "proposal": proposal, "state": "starting", "reason": "", "deadline": 0, "seen": False}
    save(t)
    me = os.path.abspath(__file__)
    py = sys.executable or "/usr/bin/python3"
    env = ["--setenv=%s=%s" % (k, os.environ[k]) for k in ("HYPRLAND_INSTANCE_SIGNATURE", "XDG_RUNTIME_DIR", "SUMI_HYPRCTL",
                                                          "SUMI_NMCLI", "SUMI_PACTL", "PULSE_SERVER") if k in os.environ]
    # red: hasta 2 min escribiendo la contraseña, y `post` espera el rollback de NetworkManager
    extra = 150 if kind == "network" else 0
    cmd = ["systemd-run", "--user", "--quiet", "--collect", "--unit", UNIT_PREFIX + tid,
           "--property=RuntimeMaxSec=%d" % (timeout + 45 + extra),
           "--property=TimeoutStopSec=%d" % (90 + extra),
           "--property=ExecStopPost=%s %s post %s" % (py, me, tid)] + env + [py, me, "run", tid]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired) as e:
        t["state"] = "failed"
        t["reason"] = "Could not start the guard: %s" % e
        save(t)
        return {"ok": False, "error": t["reason"], "id": tid}
    if p.returncode != 0:
        t["state"] = "failed"
        t["reason"] = "Could not start the guard: %s" % p.stderr.strip()[:200]
        save(t)
        return {"ok": False, "error": t["reason"], "id": tid}
    return {"ok": True, "id": tid}


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd = argv[1]
    if cmd == "launch" and len(argv) >= 4:
        timeout, only, rest = 15, "", argv[4:]
        while rest:
            if rest[0] == "--timeout" and len(rest) > 1:
                try:
                    timeout = int(rest[1])
                except ValueError:
                    timeout = -1
                rest = rest[2:]
            elif rest[0] == "--only" and len(rest) > 1:
                only, rest = rest[1], rest[2:]
            else:
                print(json.dumps({"ok": False, "error": "bad argument"}))
                return 2
        print(json.dumps(launch(argv[2], argv[3], timeout, only)))
        return 0
    if cmd == "check" and len(argv) >= 4:
        only = argv[5] if len(argv) > 5 and argv[4] == "--only" else ""
        live = monitors() if argv[2] == "displays" else None
        try:
            prop = json.loads(argv[3])
            assert argv[2] in KINDS and isinstance(prop, dict) and prop
            if argv[2] == "audio-profile":
                check_audio(prop, only)
                print(json.dumps({"ok": True}))
                return 0
            if argv[2] == "network":
                uuid, before, props, devs = prepare_network(prop, only)
                print(json.dumps({"ok": True, "props": props, "devices": devs,
                                  "detail": _ne().describe(props)}))
                return 0
            if live is None:
                raise ValueError("Hyprland is not answering")
            for n, c in prop.items():
                check_output(n, c, live, only)
            print(json.dumps({"ok": True}))
        except (ValueError, AssertionError) as e:
            print(json.dumps({"ok": False, "error": str(e) or "bad proposal"}))
        return 0
    if cmd in ("run", "post", "ack", "decide") and len(argv) >= 3:
        tid = argv[2]
        if not ID.match(tid):
            return 2
        if cmd == "run":
            return run(tid)
        if cmd == "post":
            return post(tid)
        t = load(tid)
        if cmd == "ack":
            n = 0
            for x in argv[2:]:
                tx = load(x) if ID.match(x) else None
                if tx:
                    tx["seen"] = True
                    save(tx)
                    n += 1
            print(json.dumps({"ok": n > 0, "acked": n}))
            return 0
        d = argv[3] if len(argv) > 3 else ""
        if d not in ("keep", "revert") or not t or t.get("state") != "testing":
            print(json.dumps({"ok": False, "error": "no test waiting for a decision"}))
            return 0
        os.makedirs(RUN, mode=0o700, exist_ok=True)
        tmp = path(tid, "decision.tmp")
        with open(tmp, "w") as f:
            f.write(d)
        os.replace(tmp, path(tid, "decision"))
        print(json.dumps({"ok": True}))
        return 0
    if cmd == "list":
        out = []
        for t in all_txns():
            final = t.get("state") in FINAL
            # las terminadas y vistas de hace más de una hora sobran
            if final and t.get("seen") and now_ms() - t.get("updated", 0) > 3600 * 1000:
                for ext in ("json", "decision"):
                    try:
                        os.remove(path(t["id"], ext))
                    except OSError:
                        pass
                continue
            t["unit"] = "" if final else unit_active(t["id"])
            out.append(t)
        print(json.dumps(out))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
