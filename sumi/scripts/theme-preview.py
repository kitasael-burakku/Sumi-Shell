#!/usr/bin/env python3
"""Preview reversible del tema de matugen (rediseño 12A, 2026-09-28).

rediseno/docs/futurevisual-profilesurface.md §«Previsualización y aplicación»: la preview
toca TODAS las salidas de `~/.config/matugen/config.toml`, pero no el esquema persistido ni el
sentinel `enabled`. Este helper es la parte que toca archivos; el estado, la serialización y
el propietario viven en `services/ThemePreview.qml`.

    stage    --work W --profile P [--mode dark|light] [--contrast C]
             genera las salidas en W/out con una config DERIVADA (cada output_path en W, sin
             post_hook): matugen no toca ni un archivo real ni lanza un hook. «static» copia el
             conjunto de `apply-static-colors.sh --list`. Verifica que estén completas.
    snapshot --snap S      copia exacta de lo vigente, sólo en la PRIMERA preview (si S ya
                           tiene un registro, no se toca: la referencia es lo confirmado).
    install  --work W --snap S   apunta los hashes que va a instalar ANTES de tocar nada,
                           reemplaza de forma atómica y lanza las recargas del modo previsto.
    restore  --snap S      repone sólo lo que sigue llevando la preview (hash instalado); lo que
                           otro escribió después (un fondo nuevo → matugen) no se pisa.
    keep     --snap S --profile P   persiste esquema/sentinel como el flujo del rice, tras
                           comprobar que lo que hay en disco es exactamente la preview.
    recover  --snap S      al arrancar el shell: una preview que quedó a medias se restaura
                           (o, si murió confirmando y ya estaba persistida, se da por buena).
    status   --snap S
    samples  --profiles a,b --cache C   muestras de las tarjetas, sin aplicar (12B)

Paletas estáticas (F-b, 2026-11-04): el perfil `preset:<id>` (sumi/palettes/<id>.json, scripts/palette_presets.py)
se renderiza con `matugen json` y la MISMA config del proveedor, todas las salidas o ninguna; la de kitty toma después
el bloque `terminal` del preset (sustitución por destino, sin tocar la plantilla del usuario). Sin matugen, sólo la
paleta de la shell (mismos 16 tokens, mismo archivo). Keep escribe `theme/preset` y quita el sentinel. «static» sigue
copiando los pares de la lista estática; los destinos de la config SIN par se renderizan ahora desde
palettes/static/minimaru-dark.json (antes se quedaban con los últimos colores dinámicos; D0-2).

Cada orden imprime UNA línea JSON (`ok`, y lo demás). Rutas por entorno, con los mismos
nombres que `matugen_reload.sh` para las suyas (las pruebas las apuntan a /tmp):
MATUGEN_CONFIG, MATUGEN_SENTINEL, MATUGEN_SCHEME_FILE, KT_WALL_STATE, KT_STATIC_LIST,
KT_HOOK_TIMEOUT, MATUGEN_BIN.

Portabilidad F4d (2026-10-08): la config y la lista estática son del PROVEEDOR de tema, no rutas del rice.
La shell pasa MATUGEN_CONFIG (la del proveedor: la del autor declarada en providers.json, o la mínima del
proyecto) y KT_STATIC_LIST_ARGV (el argv JSON del verbo staticList, ya con su «--list»). Sin ellos: la config
mínima del proyecto y la lista estática propia (sólo la paleta de la shell). KT_STATIC_LIST (una ruta de
script) se conserva para las pruebas. KT_DESKTOP_SYNC (off · colorScheme · full; por defecto full, lo de
siempre) dice qué claves de gsettings se tocan; lo que la shell cambia queda en un registro
(KT_DESKTOP_LEDGER, por defecto theme/desktop-ledger.json) para poder devolverlo (`desktop-restore`) sin pisar
lo que el usuario cambiara después.
"""
import argparse
import ast
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import tomllib

# El código puede estar instalado sin permiso de escritura (F1a).
sys.dont_write_bytecode = True
from theme_paths import expand_path, load_matugen_config
from xdg_paths import base_dir
from theme_xsettings import Adapter
import palette_presets

THEME_DIR = base_dir("XDG_STATE_HOME", ".local/state") + "/sumi-shell/theme"
SHELL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG = os.environ.get("MATUGEN_CONFIG") or os.path.join(SHELL_DIR, "templates", "matugen-config.toml")
SENTINEL = os.environ.get("MATUGEN_SENTINEL", THEME_DIR + "/enabled")
SCHEME_FILE = os.environ.get("MATUGEN_SCHEME_FILE", THEME_DIR + "/scheme")
WALL_STATE = os.environ.get("KT_WALL_STATE", base_dir("XDG_STATE_HOME", ".local/state") + "/sumi-shell/current-wallpaper")
STATIC_LIST = os.environ.get("KT_STATIC_LIST", "")
STATIC_LIST_ARGV = os.environ.get("KT_STATIC_LIST_ARGV", "")
HOOK_TIMEOUT = float(os.environ.get("KT_HOOK_TIMEOUT", "5"))
MATUGEN = os.environ.get("MATUGEN_BIN", "matugen")
# 12F: los ajustes que `matugen_reload.sh` lee junto a `scheme` (mismos nombres y validación)
MODE_FILE = os.environ.get("MATUGEN_MODE_FILE", THEME_DIR + "/mode")
CONTRAST_FILE = os.environ.get("MATUGEN_CONTRAST_FILE", THEME_DIR + "/contrast")
SOURCE_FILE = os.environ.get("MATUGEN_SOURCE_FILE", THEME_DIR + "/source")
# F-b: el preset confirmado (sin archivo = Minimaru o dinámico). Vale sólo sin el sentinel.
PRESET_FILE = os.environ.get("MATUGEN_PRESET_FILE", THEME_DIR + "/preset")
# F-d: lo último que se CONFIRMÓ (Keep o una transacción de theme-provider.py): qué CSS de GTK cambió y el modo de
# antes y de después. La shell lo vigila y avisa de reabrir las apps GTK que no recargan solas.
LAST_CHANGE = os.environ.get("MATUGEN_LAST_CHANGE", THEME_DIR + "/last-change.json")
# Preferencias fuera de matugen, para consumidores de GSettings/portal. GTK sobre X11
# necesita su vía XSettings: tener portal no la sustituye. No se modifican settings.ini.
GSETTINGS = os.environ.get("KT_GSETTINGS", "gsettings")
ALL_DESKTOP_KEYS = {"color-scheme": {"light": "prefer-light", "dark": "prefer-dark"},
                "gtk-theme": {"light": "Adwaita", "dark": "Adwaita-dark"}}
# F4d (PL-04): alcance de theme.desktopSync; los temas GTK ajenos se conservan al aplicar.
DESKTOP_SYNC = os.environ.get("KT_DESKTOP_SYNC", "full")
DESKTOP_KEYS = {k: v for k, v in ALL_DESKTOP_KEYS.items()
                if DESKTOP_SYNC == "full" or (DESKTOP_SYNC == "colorScheme" and k == "color-scheme")}
LEDGER = os.environ.get("KT_DESKTOP_LEDGER") or os.path.join(THEME_DIR, "desktop-ledger.json")

# La lista blanca de matugen_reload.sh (scheme-smart, nuevo en 4.2.0, queda fuera: 12, decisión)
SCHEMES = ["content", "expressive", "fidelity", "fruit-salad", "monochrome",
           "neutral", "rainbow", "tonal-spot", "vibrant"]
VIDEO = ("mp4", "mkv", "mov", "webm")


def out(ok, **kw):
    kw["ok"] = ok
    print(json.dumps(kw))
    sys.exit(0 if ok else 1)


def expand(p):
    return expand_path(p) if isinstance(p, str) else p


def sha(path):
    try:
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None


def read_text(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def write_atomic(path, data, mode=None):
    """Temporal en el mismo directorio, fsync y rename: nadie lee nunca media salida."""
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    if mode is None:
        try:
            mode = os.stat(path).st_mode & 0o7777
        except OSError:
            mode = 0o644
    tmp = os.path.join(d, ".%s.kt-%d" % (os.path.basename(path), os.getpid()))
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def write_json(path, obj):
    write_atomic(path, (json.dumps(obj, indent=1) + "\n").encode(), 0o600)


def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


# ---- lo que dice el rice -----------------------------------------------------

def load_config():
    """config.toml, leído en cada orden: la lista de templates no se cablea (spec)."""
    return load_matugen_config(CONFIG)


def templates(cfg):
    """[(clave, input, output, post_hook)] en el orden del archivo."""
    res = []
    for key, t in (cfg.get("templates") or {}).items():
        if not isinstance(t, dict) or "output_path" not in t:
            continue
        res.append((key, expand(t.get("input_path", "")), expand(t["output_path"]),
                    t.get("post_hook") or ""))
    return res


def static_argv():
    """F4d: el argv que lista lo estático: el del proveedor (KT_STATIC_LIST_ARGV, ya con «--list»), el
    script de pruebas (KT_STATIC_LIST) o la lista propia de la shell (scripts/theme-provider.py)."""
    if STATIC_LIST_ARGV:
        argv = json.loads(STATIC_LIST_ARGV)
        if not isinstance(argv, list) or not argv or not all(isinstance(x, str) for x in argv):
            raise RuntimeError("KT_STATIC_LIST_ARGV is not an argv")
        return argv
    if STATIC_LIST:
        return ["bash", STATIC_LIST, "--list"]
    return [sys.executable or "python3", "-B", os.path.join(SHELL_DIR, "scripts", "theme-provider.py"), "static", "--list"]


def static_list():
    """(pares [(origen, destino)], scripts) de lo estático del proveedor (`… --list`)."""
    argv = static_argv()
    # Un apply-static-colors.sh anterior a la 12A ignora el argumento y HACE la copia estática
    # sobre las salidas reales (pasó el 2026-09-28 con el script vivo sin desplegar): un script
    # de shell que no declare `--list` no se ejecuta.
    for x in argv:
        if x.endswith(".sh") and os.path.isfile(x):
            try:
                with open(x) as f:
                    if '"--list"' not in f.read():
                        raise RuntimeError(os.path.basename(x) + " has no --list (older version): not run")
            except OSError as e:
                raise RuntimeError("%s unreadable: %s" % (os.path.basename(x), e))
    r = subprocess.run(argv, capture_output=True, text=True, timeout=10)
    if r.returncode != 0:
        raise RuntimeError("the static list exited %d" % r.returncode)
    pairs, scripts = [], []
    for line in r.stdout.splitlines():
        f = line.split("\t")
        if f[0] == "copy" and len(f) == 3:
            pairs.append((f[1], f[2]))
        elif f[0] == "script" and len(f) == 2:
            scripts.append(f[1])
    if not pairs:
        raise RuntimeError("the static list printed no pairs")
    return pairs, scripts


def norm_mode(v):
    return "light" if str(v).strip() == "light" else "dark"


def norm_contrast(v):
    """-1 … 1 con hasta dos decimales, como la lista blanca de matugen_reload.sh; si no, 0."""
    t = str(v).strip()
    if re.fullmatch(r"-?(0(\.[0-9]{1,2})?|1(\.0{1,2})?)", t):
        return round(float(t), 2)
    return 0.0


def norm_source(v):
    t = str(v).strip()
    return t.lower() if re.fullmatch(r"#[0-9a-fA-F]{6}", t) else "wallpaper"


def persisted():
    """Lo confirmado del rice (lo que un cambio externo movería): sentinel, esquema, fondo y, desde
    la 12F, modo, contraste y color de origen."""
    scheme = read_text(SCHEME_FILE) or "scheme-tonal-spot"
    preset = read_text(PRESET_FILE)
    return {"enabled": os.path.exists(SENTINEL), "scheme": scheme,
            "wallpaper": read_text(WALL_STATE), "lightness": norm_mode(read_text(MODE_FILE)),
            "contrast": norm_contrast(read_text(CONTRAST_FILE) or "0"),
            "source": norm_source(read_text(SOURCE_FILE)),
            "preset": preset if palette_presets.ID_RE.match(preset) else ""}


def confirmed_mode(base):
    return "dynamic" if base["enabled"] else ("preset" if base.get("preset") else "static")


def gs_get(key):
    try:
        r = subprocess.run([GSETTINGS, "get", "org.gnome.desktop.interface", key],
                           capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout.strip().strip("'") if r.returncode == 0 else None


def gs_set(key, value):
    try:
        r = subprocess.run([GSETTINGS, "set", "org.gnome.desktop.interface", key, value],
                           capture_output=True, text=True, timeout=5)
        # Un backend puede devolver 0 sin persistir (p. ej. fallo de dconf).
        return r.returncode == 0 and gs_get(key) == value
    except (OSError, subprocess.TimeoutExpired):
        return False


def ledger_load():
    d = load_json(LEDGER)
    return d if isinstance(d, dict) and isinstance(d.get("keys"), dict) else {"version": 1, "keys": {}}


def ledger_note(key, before, now):
    """F4d (PL-04): anotar que la shell puso `now` en `key`, que antes valía `before`. El primer «antes» se
    conserva; si vuelve a él, la entrada sobra."""
    if before is None:
        return
    d = ledger_load()
    e = d["keys"].get(key)
    if e is None:
        if before == now:
            return
        d["keys"][key] = {"before": before, "set": now, "at": time.time()}
    elif now == e.get("before"):
        del d["keys"][key]
    else:
        e["set"] = now
    write_json(LEDGER, d)


def gs_set_noted(key, value):
    before = gs_get(key)
    ok = gs_set(key, value)
    if ok:
        ledger_note(key, before, value)
    return ok


def xs(action="sync", target=None):
    adapter = Adapter(THEME_DIR, write_json, write_atomic)
    if action in ("sync", "start") and adapter.config and DESKTOP_SYNC == "full" and os.path.isfile(CONFIG):
        try:
            if any(os.path.realpath(t[2]) == os.path.realpath(adapter.config) for t in templates(load_config())):
                return {"status": "skipped", "reason": "matugen-target-conflict"}
        except (OSError, ValueError):
            return {"status": "failed", "reason": "matugen-config-unreadable"}
    theme = gs_get("gtk-theme") if action in ("sync", "start") and adapter.config and DESKTOP_SYNC == "full" else None
    return adapter.call(action, theme, target)


def xs_result(result, failures, skipped, restoring=False):
    status = result.get("status")
    if status == "failed" or (restoring and status == "unavailable"):
        failures.append("xsettings:" + result.get("reason", status))
    elif status in ("unavailable", "skipped"):
        skipped["xsettings"] = result.get("reason", status)


def desktop_skip(key, current):
    """No inventar un tema para otra instalación ni sustituir uno personalizado."""
    if current is None:
        return "unavailable"
    if key == "gtk-theme" and current not in ALL_DESKTOP_KEYS["gtk-theme"].values():
        return "custom-theme"
    return ""


def reload_set(mode, cfg, pairs, scripts, rendered=()):
    """Las recargas del modo: en dinámico y con un preset, los post_hook de config.toml; en estático, los de
    las salidas que tienen par estático o que se renderizaron desde Minimaru (`rendered`), más el script
    de Hyprland (lo de apply-static-colors)."""
    hooks = []
    if mode in ("dynamic", "preset"):
        for key, _i, _o, hook in templates(cfg):
            if hook:
                hooks.append({"kind": "hook", "key": key, "cmd": hook})
    else:
        dsts = set(os.path.realpath(d) for _s, d in pairs) | set(os.path.realpath(d) for d in rendered)
        for key, _i, o, hook in templates(cfg):
            if hook and os.path.realpath(o) in dsts:
                hooks.append({"kind": "hook", "key": key, "cmd": hook})
        for s in scripts:
            hooks.append({"kind": "script", "key": os.path.basename(s), "cmd": s})
    return hooks


def run_reloads(hooks):
    """Acotadas (la regla de los post_hook de config.toml): un hook colgado no cuelga la
    preview. El texto del hook es del usuario, de su config.toml: nada de aquí lo compone."""
    res = []
    for h in hooks:
        t0 = time.monotonic()
        argv = ["sh", "-c", h["cmd"]] if h["kind"] == "hook" else ["bash", h["cmd"]]
        try:
            # grupo propio: al vencer el plazo se mata el hook entero, no sólo su `sh`
            p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
            try:
                rc = p.wait(timeout=HOOK_TIMEOUT)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, 9)
                p.wait()
                rc = "timeout"
        except OSError as e:
            rc = str(e)
        res.append({"key": h["key"], "rc": rc, "ms": round((time.monotonic() - t0) * 1000)})
    return res


def all_targets(cfg, pairs):
    seen, res = set(), []
    for _k, _i, o, _h in templates(cfg):
        if o not in seen:
            seen.add(o)
            res.append(o)
    for _s, d in pairs:
        if d not in seen:
            seen.add(d)
            res.append(d)
    return res


# ---- órdenes ----------------------------------------------------------------

def dump_toml_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, list):
        return "[" + ", ".join(dump_toml_value(x) for x in v) + "]"
    raise ValueError("unsupported value in config.toml: %r" % (v,))


def derived_config(cfg, work):
    """La misma config con cada salida en W/out/<clave> y sin hooks."""
    lines = ["[config]"]
    for k, v in (cfg.get("config") or {}).items():
        if isinstance(v, dict):
            raise ValueError("config.toml [config.%s] is a table: not supported by the preview" % k)
        lines.append("%s = %s" % (k, dump_toml_value(v)))
    for key, t in (cfg.get("templates") or {}).items():
        if not isinstance(t, dict) or "output_path" not in t:
            continue
        lines.append("")
        lines.append("[templates.%s]" % json.dumps(key))
        for k, v in t.items():
            if k in ("post_hook", "pre_hook"):
                continue
            if k == "output_path":
                v = os.path.join(work, "out", key)
            elif k == "input_path":
                v = expand(v)
            if isinstance(v, dict):
                continue
            lines.append("%s = %s" % (k, dump_toml_value(v)))
    return "\n".join(lines) + "\n"


def render_preset(cfg, tpls, work, doc, sibling, keys=None):
    """F-b: `matugen json` del preset con la config del proveedor (derivada: salidas en W/out, sin hooks), sólo las
    plantillas `keys` si se dan. Devuelve las entradas o termina con el error. Después, sustituciones por destino."""
    sub = dict(cfg)
    if keys is not None:
        sub["templates"] = {k: v for k, v in (cfg.get("templates") or {}).items() if k in keys}
    cfg_path = os.path.join(work, "config.toml")
    try:
        with open(cfg_path, "w") as f:
            f.write(derived_config(sub, work))
    except ValueError as e:
        out(False, error="config-unsupported", detail=str(e))
    js = os.path.join(work, "preset.json")
    with open(js, "w") as f:
        json.dump(palette_presets.matugen_doc(doc, sibling), f)
    try:
        r = subprocess.run([MATUGEN, "--config", cfg_path, "json", js, "-q"], capture_output=True, text=True,
                           timeout=60, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        out(False, error="matugen-timeout")
    except OSError as e:
        out(False, error="matugen-failed", detail=str(e))
    if r.returncode != 0:
        # p. ej. ResolveError: la plantilla pide un rol que el preset no trae
        out(False, error="matugen-failed", detail=(r.stderr or r.stdout)[-400:])
    entries = []
    for key, _i, o, _h in tpls:
        if keys is not None and key not in keys:
            continue
        staged = os.path.join(work, "out", key)
        kind = palette_presets.substitution_kind(o)
        if kind and os.path.isfile(staged):
            with open(staged) as f:
                text = f.read()
            with open(staged, "w") as f:
                f.write(palette_presets.substitute(kind, text, doc["terminal"]))
        entries.append({"key": key, "target": o, "staged": staged, "rendered": True,
                        "substituted": kind or ""})
    return entries


def have_matugen():
    return shutil.which(MATUGEN) is not None


def shell_target(tpls):
    """La salida de la paleta de la shell: la plantilla de la shell de la config, o colors.json de su estado."""
    shell_tpl = os.path.realpath(palette_presets.SHELL_TEMPLATE)
    for key, i, o, _h in tpls:
        # Sumi Shell (2026-11-07): una config de matugen de antes del cambio de nombre aún llama a la plantilla `kitasan_shell`
        if key in ("sumi_shell", "kitasan_shell") or (i and os.path.realpath(i) == shell_tpl):
            return key, o
    state = base_dir("XDG_STATE_HOME", ".local/state")
    return "sumi_shell", os.path.join(state, "sumi-shell", "colors.json")


def cmd_stage(a):
    t0 = time.monotonic()
    work = a.work
    cfg = load_config()
    pairs, scripts = static_list()
    if os.path.isdir(os.path.join(work, "out")):
        shutil.rmtree(os.path.join(work, "out"))
    os.makedirs(os.path.join(work, "out"), exist_ok=True)
    tpls = templates(cfg)
    entries = []
    wall = read_text(WALL_STATE)
    preset, renderer = "", ""

    if a.profile.startswith("preset:"):
        preset = a.profile[7:]
        try:
            doc = palette_presets.load(preset)
        except palette_presets.PresetError as e:
            out(False, error="preset-invalid", detail=str(e))
        mode, scheme = "preset", ""
        if have_matugen():
            renderer = "matugen"
            entries = render_preset(cfg, tpls, work, doc, palette_presets.sibling_of(doc))
        else:
            # sin matugen: sólo la paleta de la shell, con su misma plantilla (la shell siempre funciona)
            renderer = "shell-only"
            key, target = shell_target(tpls)
            staged = os.path.join(work, "out", key)
            try:
                text = palette_presets.shell_colors(doc)
            except (palette_presets.PresetError, OSError, ValueError) as e:
                out(False, error="preset-invalid", detail=str(e))
            with open(staged, "w") as f:
                f.write(text)
            entries = [{"key": key, "target": target, "staged": staged, "rendered": True, "substituted": ""}]
    elif a.profile == "static":
        mode, scheme = "static", ""
        by_dst = {os.path.realpath(d): s for s, d in pairs}
        unpaired = [key for key, _i, o, _h in tpls if os.path.realpath(o) not in by_dst]
        glass = None
        if unpaired and have_matugen():
            try:
                glass = palette_presets.load_static("minimaru-dark")
            except palette_presets.PresetError:
                glass = None
        rendered = {}
        if glass is not None:
            # D0-2: lo que la lista estática no cubre se pinta con Minimaru, no se queda en dinámico
            renderer = "matugen"
            rendered = {e["key"]: e for e in render_preset(cfg, tpls, work, glass, None, set(unpaired))}
        for key, _i, o, _h in tpls:
            src = by_dst.pop(os.path.realpath(o), None)
            if src is None and key in rendered:
                entries.append(rendered[key])
                continue
            # sin par estático ni matugen: el archivo no cambia (hypr_live: lo recolorea el script)
            src = src if src is not None else o
            if not os.path.exists(src):
                out(False, error="static-missing", detail=src)
            staged = os.path.join(work, "out", key)
            shutil.copyfile(src, staged)
            entries.append({"key": key, "target": o, "staged": staged})
        for i, (real_dst, src) in enumerate(by_dst.items()):
            staged = os.path.join(work, "out", "static-%d" % i)
            shutil.copyfile(src, staged)
            dst = next(d for s, d in pairs if os.path.realpath(d) == real_dst)
            entries.append({"key": "static-%d" % i, "target": dst, "staged": staged})
    else:
        if a.profile not in SCHEMES:
            out(False, error="unknown-profile", detail=a.profile)
        mode, scheme = "dynamic", "scheme-" + a.profile
        source = norm_source(a.source)
        if source == "wallpaper" and (not wall or not os.path.isfile(wall)):
            out(False, error="no-wallpaper")
        src = wall
        if source == "wallpaper" and wall.rsplit(".", 1)[-1].lower() in VIDEO:
            # el mismo fotograma que matugen_reload.sh (segundo 1): la misma paleta que Keep
            src = os.path.join(work, "frame.png")
            r = subprocess.run(["ffmpeg", "-y", "-ss", "00:00:01", "-i", wall, "-vframes", "1",
                                "-update", "1", src], capture_output=True, timeout=30)
            if r.returncode != 0:
                out(False, error="frame-failed", detail=wall)
        cfg_path = os.path.join(work, "config.toml")
        try:
            with open(cfg_path, "w") as f:
                f.write(derived_config(cfg, work))
        except ValueError as e:
            out(False, error="config-unsupported", detail=str(e))
        # 12F: con color de origen, la paleta sale de ese color (como matugen_reload.sh)
        what = ["color", "hex", source] if source != "wallpaper" else ["image", src]
        argv = [MATUGEN, "--config", cfg_path] + what + ["-m", a.mode, "-t", scheme, "-q"]
        if a.contrast is not None and norm_contrast(a.contrast) != 0:
            argv += ["--contrast", str(norm_contrast(a.contrast))]
        try:
            r = subprocess.run(argv, capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired:
            out(False, error="matugen-timeout")
        if r.returncode != 0:
            out(False, error="matugen-failed", detail=(r.stderr or r.stdout)[-400:])
        for key, _i, o, _h in tpls:
            entries.append({"key": key, "target": o, "staged": os.path.join(work, "out", key)})

    # verificar el conjunto antes de que nada llegue a su sitio
    bad = []
    for e in entries:
        p = e["staged"]
        if not os.path.isfile(p) or os.path.getsize(p) == 0:
            bad.append(e["key"])
            continue
        if mode == "dynamic" or e.get("rendered"):
            with open(p, "rb") as f:
                body = f.read()
            if b"{{" in body:
                bad.append(e["key"])
                continue
        if e["target"].endswith(".json"):
            if load_json(p) is None:
                bad.append(e["key"])
                continue
        e["sha256"] = sha(p)
    if bad:
        out(False, error="incomplete", detail=bad)

    # Static sólo existe en oscuro; un preset trae su modo; contraste y origen son de los perfiles dinámicos
    lightness = norm_mode(a.mode) if mode == "dynamic" else (
        ("dark" if doc["dark"] else "light") if mode == "preset" else "dark")
    rendered_targets = [e["target"] for e in entries if e.get("rendered")]
    write_json(os.path.join(work, "manifest.json"), {
        "profile": a.profile, "mode": mode, "scheme": scheme, "wallpaper": wall, "preset": preset,
        "contrast": norm_contrast(a.contrast if a.contrast is not None else 0) if mode == "dynamic" else 0.0,
        "lightness": lightness, "source": norm_source(a.source) if mode == "dynamic" else "wallpaper",
        "desktop": {k: v[lightness] for k, v in DESKTOP_KEYS.items()},
        "entries": entries, "reloads": reload_set(mode, cfg, pairs, scripts, rendered_targets)})
    out(True, profile=a.profile, entries=len(entries), renderer=renderer,
        substituted=[e["key"] for e in entries if e.get("substituted")], ms=round((time.monotonic() - t0) * 1000))


def pending_path(snap):
    return os.path.join(snap, "pending.json")


def cmd_snapshot(a):
    snap = a.snap
    if load_json(pending_path(snap)) is not None:
        out(True, existing=True)
    if os.path.isdir(snap):
        shutil.rmtree(snap)
    os.makedirs(os.path.join(snap, "files"), mode=0o700)
    cfg = load_config()
    pairs, _scripts = static_list()
    base = persisted()
    files = []
    for i, t in enumerate(all_targets(cfg, pairs)):
        rec = {"target": t, "exists": os.path.isfile(t), "sha256": None, "mode": 0o644,
               "copy": os.path.join(snap, "files", str(i))}
        if rec["exists"]:
            shutil.copyfile(t, rec["copy"])
            rec["sha256"] = sha(rec["copy"])
            rec["mode"] = os.stat(t).st_mode & 0o7777
        files.append(rec)
    desktop = {k: gs_get(k) for k in DESKTOP_KEYS}
    write_json(pending_path(snap), {
        "createdAt": time.time(), "phase": "snapshot", "base": base, "desktop": desktop,
        "desktopSet": {}, "xsettings": xs("snapshot"),
        "confirmed": {"mode": confirmed_mode(base), "scheme": base["scheme"], "preset": base.get("preset", "")},
        "preview": None, "files": files, "installed": {}})
    out(True, existing=False, files=len(files))


def gtk_kind(target):
    """«gtk3»/«gtk4» para un CSS de GTK del usuario (~/.config/gtk-3.0|gtk-4.0/…css), si no None."""
    parts = os.path.normpath(target).split(os.sep)
    if not target.endswith(".css"):
        return None
    return "gtk3" if "gtk-3.0" in parts[:-1] else "gtk4" if "gtk-4.0" in parts[:-1] else None


def base_lightness(base):
    """El modo de lo confirmado antes de la preview: el del dinámico, el del preset o oscuro (Minimaru)."""
    if base.get("enabled"):
        return base.get("lightness", "dark")
    if base.get("preset"):
        try:
            return "dark" if palette_presets.load(base["preset"])["dark"] else "light"
        except palette_presets.PresetError:
            return "dark"
    return "dark"


def cmd_install(a):
    man = load_json(os.path.join(a.work, "manifest.json"))
    pend = load_json(pending_path(a.snap))
    if man is None:
        out(False, error="no-manifest")
    if pend is None:
        out(False, error="no-snapshot")
    # primero se apunta lo que se va a poner: si el proceso muere a medias, `recover` sabe
    # qué archivos llevan la preview
    inst = pend.get("installed") or {}
    for e in man["entries"]:
        lst = inst.get(e["target"], [])
        if e["sha256"] not in lst:
            lst.append(e["sha256"])
        inst[e["target"]] = lst
    pend["installed"] = inst
    pend["phase"] = "installing"
    pend["preview"] = {"profile": man["profile"], "mode": man["mode"], "scheme": man["scheme"],
                       "preset": man.get("preset", ""),
                       "wallpaper": man["wallpaper"], "lightness": man.get("lightness", "dark"),
                       "contrast": man.get("contrast", 0.0), "source": man.get("source", "wallpaper")}
    # apuntado ANTES de tocarlos, como los archivos
    dset = pend.get("desktopSet") or {}
    skipped = {}
    wanted = {}
    for k, v in (man.get("desktop") or {}).items():
        reason = desktop_skip(k, gs_get(k))
        if reason:
            skipped[k] = reason
        elif (pend.get("desktop") or {}).get(k) is not None:
            dset[k] = v
            wanted[k] = v
    pend["desktopSet"] = dset
    write_json(pending_path(a.snap), pend)
    changed = 0
    gtk = dict(pend.get("gtk") or {})
    for e in man["entries"]:
        if sha(e["target"]) == e["sha256"]:
            continue
        with open(e["staged"], "rb") as f:
            write_atomic(e["target"], f.read())
        changed += 1
        k = gtk_kind(e["target"])
        if k:
            gtk[k] = True
    # F-d: acumulado desde la copia (lo que las apps GTK abiertas aún no han visto)
    pend["gtk"] = gtk
    failures = []
    for k, v in wanted.items():
        if gs_get(k) != v and not gs_set_noted(k, v):
            failures.append(k)
    pend["phase"] = "installed"
    pend["last"] = {e["target"]: e["sha256"] for e in man["entries"]}
    write_json(pending_path(a.snap), pend)
    hooks = run_reloads(man["reloads"])
    pend["xsettingsSet"] = gs_get("gtk-theme")
    write_json(pending_path(a.snap), pend)
    xr = xs() if "gtk-theme" not in failures else {"status": "skipped", "reason": "gsettings-failed"}
    xs_result(xr, failures, skipped)
    out(True, xsettings=xr, profile=man["profile"], changed=changed, hooks=hooks,
        hookFailures=[h["key"] for h in hooks if h["rc"] != 0],
        desktopFailures=failures, desktopSkipped=skipped,
        gtk=pend.get("gtk") or {}, lightnessBefore=base_lightness(pend.get("base") or {}),
        lightness=man.get("lightness", "dark"))


def do_restore(snap):
    pend = load_json(pending_path(snap))
    if pend is None:
        if os.path.isdir(snap):
            shutil.rmtree(snap)
        return {"nothing": True}
    pend["phase"] = "restoring"
    write_json(pending_path(snap), pend)
    inst = pend.get("installed") or {}
    restored, outside, same = [], [], 0
    for rec in pend["files"]:
        t = rec["target"]
        cur = sha(t)
        if cur == rec["sha256"]:
            same += 1
            continue
        if cur is not None and cur in inst.get(t, []):
            if rec["exists"]:
                with open(rec["copy"], "rb") as f:
                    write_atomic(t, f.read(), rec["mode"])
            else:
                os.remove(t)
            restored.append(t)
        else:
            # otro escribió después (un fondo nuevo regeneró): lo suyo gana
            outside.append(t)
    # claro/oscuro del escritorio: se devuelve sólo si sigue siendo lo que puso la preview
    failures = []
    for k, v in (pend.get("desktopSet") or {}).items():
        was = (pend.get("desktop") or {}).get(k)
        cur = gs_get(k)
        if was is not None and cur is None:
            failures.append(k)
        elif was is not None and cur == v and cur != was:
            if gs_set_noted(k, was):
                restored.append("gsettings:" + k)
            else:
                failures.append(k)
        elif was is not None and cur != v and cur != was:
            outside.append("gsettings:" + k)
    hooks = []
    files_back = [r for r in restored if not r.startswith("gsettings:")]
    if files_back:
        cfg = load_config()
        pairs, scripts = static_list()
        hooks = run_reloads(reload_set(confirmed_mode(persisted()), cfg, pairs, scripts, files_back))
    xr = {"status": "unchanged"}
    if pend.get("xsettings"):
        if "gsettings:gtk-theme" in outside:
            xr = {"status": "skipped", "reason": "gtk-theme-changed-by-user"}
        elif "gtk-theme" in failures:
            xr = {"status": "failed", "reason": "gsettings-restore-failed"}
        elif pend.get("xsettingsSet"):
            xr = xs("restore", {**pend["xsettings"], "expected": pend["xsettingsSet"]})
    xskipped = {}
    xs_result(xr, failures, xskipped, restoring=True)
    if xskipped:
        outside.append("xsettings:Net/ThemeName")
    if not failures:
        shutil.rmtree(snap)
    return {"restored": restored, "changedOutside": outside, "same": same, "hooks": hooks,
            "desktopFailures": failures, "desktopSkipped": xskipped, "xsettings": xr,
            "hookFailures": [h["key"] for h in hooks if h["rc"] != 0]}


def cmd_restore(a):
    result = do_restore(a.snap)
    if result.get("desktopFailures"):
        out(False, error="desktop-restore-failed", detail=", ".join(result["desktopFailures"]), **result)
    out(True, **result)


def cmd_keep(a):
    pend = load_json(pending_path(a.snap))
    if pend is None or pend.get("phase") != "installed" or not pend.get("preview"):
        out(False, error="not-previewing")
    pv = pend["preview"]
    if pv["profile"] != a.profile:
        out(False, error="other-profile", detail=pv["profile"])
    base, now = pend["base"], persisted()
    if any(base.get(k, "") != now.get(k, "") for k in ("enabled", "scheme", "wallpaper", "lightness", "contrast", "source",
                                                      "preset")):
        out(False, error="changed-outside", detail="persisted theme or wallpaper changed")
    moved = [t for t, h in (pend.get("last") or {}).items() if sha(t) != h]
    if moved:
        out(False, error="changed-outside", detail=moved)
    pend["phase"] = "keeping"
    write_json(pending_path(a.snap), pend)
    # lo que persiste el rice, en su formato: `apply-scheme --write-only` + sentinel, o
    # `matugen_toggle.sh` apagando (el sentinel fuera; el esquema se conserva)
    if pv["mode"] == "dynamic":
        write_atomic(SCHEME_FILE, pv["scheme"].encode(), 0o644)
        # 12F: sólo lo que no es el default deja archivo (sin ellos, matugen_reload hace lo de antes)
        persist_opt(MODE_FILE, pv.get("lightness", "dark"), "dark")
        persist_opt(CONTRAST_FILE, fmt_contrast(pv.get("contrast", 0.0)), "0")
        persist_opt(SOURCE_FILE, pv.get("source", "wallpaper"), "wallpaper")
        if not os.path.exists(SENTINEL):
            write_atomic(SENTINEL, b"", 0o644)
        persist_opt(PRESET_FILE, "", "")
    else:
        # F-b: preset → su id en theme/preset; static (Minimaru) → sin archivo. El sentinel fuera: un fondo
        # nuevo no regenera (Wallpaper.startColors y `reload` lo miran)
        if pv["mode"] == "preset":
            write_atomic(PRESET_FILE, pv["preset"].encode(), 0o644)
        else:
            persist_opt(PRESET_FILE, "", "")
        if os.path.exists(SENTINEL):
            os.remove(SENTINEL)
    now = persisted()
    ok = done_as(now, pv)
    if not ok:
        out(False, error="persist-failed")
    change = {"at": time.time(), "profile": pv["profile"], "gtk": pend.get("gtk") or {},
              "lightnessBefore": base_lightness(pend.get("base") or {}), "lightness": pv.get("lightness", "dark")}
    try:
        write_json(LAST_CHANGE, change)
    except OSError:
        pass                      # sólo informa: no deshace un Keep ya persistido
    shutil.rmtree(a.snap)
    out(True, kept=pv["profile"], mode=pv["mode"], scheme=pv["scheme"], change=change)


def fmt_contrast(c):
    c = norm_contrast(c)
    return "0" if c == 0 else ("%.2f" % c).rstrip("0").rstrip(".")


def persist_opt(path, value, default):
    if value == default:
        if os.path.exists(path):
            os.remove(path)
    else:
        write_atomic(path, value.encode(), 0o644)


def done_as(now, pv):
    """¿Lo persistido es ya lo que la preview enseñaba?"""
    if pv.get("mode") == "preset":
        return not now["enabled"] and now.get("preset") == pv.get("preset")
    if pv.get("mode") != "dynamic":
        return not now["enabled"] and not now.get("preset")
    return (now["enabled"] and now["scheme"] == pv.get("scheme")
            and now["lightness"] == pv.get("lightness", "dark")
            and now["contrast"] == norm_contrast(pv.get("contrast", 0.0))
            and now["source"] == pv.get("source", "wallpaper"))


def cmd_recover(a):
    pend = load_json(pending_path(a.snap))
    if pend is None:
        if os.path.isdir(a.snap):
            shutil.rmtree(a.snap)
        out(True, recovered="none")
    pv = pend.get("preview") or {}
    if pend.get("phase") == "keeping" and pv:
        if done_as(persisted(), pv):
            shutil.rmtree(a.snap)
            out(True, recovered="kept", profile=pv.get("profile"))
    result = do_restore(a.snap)
    if result.get("desktopFailures"):
        out(False, error="desktop-restore-failed", detail=", ".join(result["desktopFailures"]), **result)
    out(True, recovered="restored", phase=pend.get("phase"), **result)


# Los roles que enseña una tarjeta (12B): fondo, texto, acentos y contorno.
SAMPLE_ROLES = ["surface", "surface_container", "surface_container_high", "on_surface",
                "on_surface_variant", "primary", "on_primary", "secondary", "tertiary",
                "outline", "error"]


def cmd_samples(a):
    """Muestras de las tarjetas (12B) SIN aplicar: `matugen --dry-run -j hex` con la misma
    config (no escribe templates ni lanza hooks), el mismo fondo o fotograma y modo oscuro.
    Una línea JSON por perfil según termina, para que el carrusel las pinte sin esperar a
    todas. Caché en disco por fondo (+ mtime y tamaño), esquema y config de generación: al
    cambiar cualquiera, la clave es otra. El shell descarta las de un fondo que ya no es."""
    wall = read_text(WALL_STATE)
    source = norm_source(a.source)
    contrast = norm_contrast(a.contrast)
    if source == "wallpaper" and (not wall or not os.path.isfile(wall)):
        for p in a.profiles.split(","):
            print(json.dumps({"profile": p, "wall": wall, "error": "no-wallpaper"}), flush=True)
        return
    if source == "wallpaper":
        st = os.stat(wall)
        mt, sz = st.st_mtime_ns, st.st_size
    else:
        mt, sz = 0, 0
    try:
        cfg = load_config()
    except (OSError, tomllib.TOMLDecodeError) as e:
        for p in a.profiles.split(","):
            print(json.dumps({"profile": p, "wall": wall, "error": "config: %s" % e}), flush=True)
        return
    gen = json.dumps(cfg.get("config") or {}, sort_keys=True)
    os.makedirs(a.cache, exist_ok=True)
    src = wall
    if source == "wallpaper" and wall.rsplit(".", 1)[-1].lower() in VIDEO:
        fk = hashlib.sha256(("%s|%d|%d" % (wall, mt, sz)).encode()).hexdigest()[:24]
        src = os.path.join(a.cache, "frame-%s.png" % fk)
        if not os.path.isfile(src):
            r = subprocess.run(["ffmpeg", "-y", "-ss", "00:00:01", "-i", wall, "-vframes", "1",
                                "-update", "1", src], capture_output=True, timeout=30)
            if r.returncode != 0:
                for p in a.profiles.split(","):
                    print(json.dumps({"profile": p, "wall": wall, "error": "frame-failed"}), flush=True)
                return
    for p in a.profiles.split(","):
        if p not in SCHEMES:
            print(json.dumps({"profile": p, "wall": wall, "error": "unknown-profile"}), flush=True)
            continue
        key = hashlib.sha256(("%s|%d|%d|%s|%s|%s|%s|%s" % (wall if source == "wallpaper" else "",
                                                            mt, sz, p, a.mode, gen,
                                                            contrast, source)).encode()).hexdigest()[:32]
        cpath = os.path.join(a.cache, key + ".json")
        cached = load_json(cpath)
        if cached is not None:
            print(json.dumps({"profile": p, "wall": wall, "roles": cached, "cached": True}), flush=True)
            continue
        try:
            what = ["color", "hex", source] if source != "wallpaper" else ["image", src]
            extra = ["--contrast", str(contrast)] if contrast != 0 else []
            r = subprocess.run([MATUGEN, "--config", CONFIG] + what + ["-m", a.mode,
                                "-t", "scheme-" + p, "--dry-run", "-j", "hex", "-q"] + extra,
                               capture_output=True, text=True, timeout=30)
            d = json.loads(r.stdout)["colors"] if r.returncode == 0 else None
            roles = {k: d[k][a.mode]["color"] for k in SAMPLE_ROLES}
        except (subprocess.TimeoutExpired, ValueError, KeyError, TypeError):
            print(json.dumps({"profile": p, "wall": wall, "error": "sample-failed"}), flush=True)
            continue
        write_json(cpath, roles)
        print(json.dumps({"profile": p, "wall": wall, "roles": roles, "cached": False}), flush=True)


def cmd_desktop(a):
    """12F: alinear el claro/oscuro del escritorio (gsettings) con el modo CONFIRMADO. Lo pide el
    shell cuando lo confirmado cambia sin prueba abierta (p. ej. SUPER+SHIFT+W a Static)."""
    want = {k: v[norm_mode(a.lightness)] for k, v in DESKTOP_KEYS.items()}
    changed, failures, skipped = [], [], {}
    for k, v in want.items():
        cur = gs_get(k)
        reason = desktop_skip(k, cur)
        if reason:
            skipped[k] = reason
        elif cur != v:
            if gs_set_noted(k, v):
                changed.append(k)
            else:
                failures.append(k)
    xr = xs() if "gtk-theme" not in failures else {"status": "skipped", "reason": "gsettings-failed"}
    xs_result(xr, failures, skipped)
    out(not failures, xsettings=xr, changed=changed, sync=DESKTOP_SYNC,
        desktopFailures=failures, desktopSkipped=skipped)


def cmd_desktop_restore(a):
    """F4d (PL-04): devolver lo que la shell cambió en el escritorio. Una clave que el usuario cambió
    después (no vale ni lo que puso la shell ni lo de antes) se deja como está y se dice."""
    d = ledger_load()
    restored, already, kept, unknown = [], [], [], []
    for k, e in list(d["keys"].items()):
        cur = gs_get(k)
        if cur is None:
            unknown.append(k)
            continue
        if cur == e.get("before"):
            already.append(k)
        elif cur == e.get("set"):
            if not gs_set(k, e["before"]):
                unknown.append(k)
                continue
            restored.append(k)
        else:
            kept.append(k)
        del d["keys"][k]
    write_json(LEDGER, d)
    xr = ({"status": "skipped", "reason": "gtk-theme-changed-by-user"} if "gtk-theme" in kept
          else {"status": "failed", "reason": "gsettings-restore-failed"} if "gtk-theme" in unknown
          else xs("restore"))
    xskipped = {}
    xs_result(xr, unknown, xskipped, restoring=True)
    if xskipped:
        kept.append("xsettings:Net/ThemeName")
    out(not unknown, desktopSkipped=xskipped, xsettings=xr, restored=restored, already=already, changedByYou=kept, unknown=unknown)


def cmd_desktop_ledger(a):
    d = ledger_load()
    now = {k: gs_get(k) for k in d["keys"]}
    extra = xs("ledger")
    if extra:
        d["keys"]["xsettings:Net/ThemeName"] = extra
        now["xsettings:Net/ThemeName"] = xs("status")
    out(True, sync=DESKTOP_SYNC, keys=d["keys"], now=now)


def app_name(key, target):
    """El nombre de una salida de la config de matugen para la UI (F-e: «Applied to»)."""
    parts = os.path.normpath(target).split(os.sep)
    name = os.path.basename(target)
    if target.endswith(os.path.join("sumi-shell", "colors.json")):
        return "the shell"
    for d, label in (("kitty", "kitty"), ("gtk-3.0", "GTK 3"), ("gtk-4.0", "GTK 4"), ("qt5ct", "Qt 5"), ("qt6ct", "Qt 6"),
                     ("hyprlock", "hyprlock"), ("fish", "fish"), ("maly", "maly")):
        if d in parts[:-1]:
            return label
    if "hypr" in parts[:-1]:
        return "Hyprland"
    if name.startswith("starship"):
        return "starship"
    return key


def cmd_targets(a):
    """F-e: qué alcanza la config de matugen del proveedor (sólo lectura): [{key, target, app}]."""
    try:
        tpls = templates(load_config())
    except (OSError, ValueError, tomllib.TOMLDecodeError) as e:
        out(False, error="config", detail=str(e))
    res = [{"key": k, "target": o, "app": app_name(k, o)} for k, _i, o, _h in tpls]
    names = []
    for r in res:
        if r["app"] not in names:
            names.append(r["app"])
    out(True, config=CONFIG, targets=res, apps=names)


def cmd_status(a):
    pend = load_json(pending_path(a.snap))
    if pend is None:
        out(True, pending=False, persisted=persisted())
    out(True, pending=True, phase=pend.get("phase"), preview=pend.get("preview"),
        confirmed=pend.get("confirmed"), base=pend.get("base"), persisted=persisted())


def dispatch():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("stage")
    s.add_argument("--work", required=True)
    s.add_argument("--profile", required=True)
    s.add_argument("--mode", default="dark", choices=["dark", "light"])
    s.add_argument("--contrast", default=None)
    s.add_argument("--source", default="wallpaper")
    for name in ("snapshot", "restore", "recover", "status"):
        x = sub.add_parser(name)
        x.add_argument("--snap", required=True)
    x = sub.add_parser("install")
    x.add_argument("--work", required=True)
    x.add_argument("--snap", required=True)
    x = sub.add_parser("samples")
    x.add_argument("--profiles", required=True)
    x.add_argument("--cache", required=True)
    x.add_argument("--mode", default="dark", choices=["dark", "light"])
    x.add_argument("--contrast", default="0")
    x.add_argument("--source", default="wallpaper")
    x = sub.add_parser("desktop")
    x.add_argument("--lightness", required=True)
    sub.add_parser("desktop-restore")          # F4d
    sub.add_parser("targets")                  # F-e
    sub.add_parser("desktop-ledger")
    for verb in ("xsettings-start", "xsettings-stop", "xsettings-status"):
        sub.add_parser(verb)
    x = sub.add_parser("keep")
    x.add_argument("--snap", required=True)
    x.add_argument("--profile", required=True)
    a = p.parse_args()

    if a.cmd.startswith("xsettings-"):
        result = xs(a.cmd.split("-", 1)[1])
        out(result.get("status") != "failed", xsettings=result)
    if a.cmd == "samples":
        cmd_samples(a)
        return
    if a.cmd == "desktop":
        cmd_desktop(a)
        return
    if a.cmd == "desktop-restore":
        cmd_desktop_restore(a)
        return
    if a.cmd == "targets":
        cmd_targets(a)
        return
    if a.cmd == "desktop-ledger":
        cmd_desktop_ledger(a)
        return
    if a.cmd == "stage":
        # la generación no toca nada compartido: sin cerrojo (se puede cancelar a mitad)
        try:
            cmd_stage(a)
        except (OSError, RuntimeError, tomllib.TOMLDecodeError, subprocess.TimeoutExpired) as e:
            out(False, error="stage-failed", detail=str(e))
        return
    snap = a.snap
    os.makedirs(os.path.dirname(os.path.abspath(snap)), exist_ok=True)
    with open(os.path.join(os.path.dirname(os.path.abspath(snap)), ".theme-preview.lock"), "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        try:
            {"snapshot": cmd_snapshot, "install": cmd_install, "restore": cmd_restore,
             "keep": cmd_keep, "recover": cmd_recover, "status": cmd_status}[a.cmd](a)
        except (OSError, RuntimeError, tomllib.TOMLDecodeError, subprocess.TimeoutExpired) as e:
            out(False, error=a.cmd + "-failed", detail=str(e))


def main():
    # Serializa también desktop/restore con las previews: una respuesta tardía
    # no debe publicar un tema anterior. Leer/generar no crea recursos al iniciar.
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command in ("", "-h", "--help", "stage", "samples", "status", "desktop-ledger", "xsettings-status", "targets"):
        dispatch()
        return
    lockpath = os.path.join(THEME_DIR, ".desktop-sync.lock")
    if command == "recover" and not os.path.exists(lockpath) and "--snap" in sys.argv:
        i = sys.argv.index("--snap") + 1
        if i < len(sys.argv) and not os.path.exists(sys.argv[i]):
            out(True, recovered="none")
    # Primer inicio sin trabajo pendiente: ni siquiera crear un cerrojo nuevo.
    if command == "desktop" and not os.path.exists(lockpath) and "--lightness" in sys.argv:
        i = sys.argv.index("--lightness") + 1
        mode = norm_mode(sys.argv[i]) if i < len(sys.argv) else "dark"
        wanted = {k: v[mode] for k, v in DESKTOP_KEYS.items()}
        if all(gs_get(k) == v for k, v in wanted.items()) and not xs("ledger"):
            xr = xs("status") if os.environ.get("KT_XSETTINGS_CONFIG") and DESKTOP_SYNC == "full" else {"status": "disabled"}
            if xr.get("status") != "running":
                skipped = {}; xs_result(xr, [], skipped)
                out(True, changed=[], sync=DESKTOP_SYNC, desktopFailures=[], desktopSkipped=skipped, xsettings=xr)
    os.makedirs(THEME_DIR, exist_ok=True)
    with open(lockpath, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        dispatch()


if __name__ == "__main__":
    main()
