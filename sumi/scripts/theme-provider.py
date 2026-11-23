#!/usr/bin/env python3
"""El proveedor de tema propio de Sumi Shell (portabilidad F4d, 2026-10-08; H-11, HC-02, HC-06, HC-07).

Lo usa la shell con `providers.theme` = auto, matugen o static. Tiene el MISMO contrato que los scripts del
rice del autor (que siguen siendo su proveedor `script`): matugen_reload.sh, matugen_toggle.sh y
apply-static-colors.sh. La diferencia es de alcance: por defecto genera SÓLO la paleta de la shell, con la
config mínima del proyecto (templates/matugen-config.toml); la config de matugen del usuario —que puede
tocar GTK, Qt, terminales…— sólo se usa si la declara en providers.json (`theme.matugenConfig`). Nunca
escribe la config de matugen ni las plantillas de otros programas.

    theme-provider.py [--config CFG] reload <fondo>   regenerar con los cinco ajustes de theme/ (como
                                                      matugen_reload.sh): sin el sentinel `enabled`, nada
    theme-provider.py [--config CFG] toggle           encender/apagar los colores del fondo (matugen_toggle.sh)
    theme-provider.py static                          la paleta estática de la shell (apply-static-colors.sh)
    theme-provider.py static --list                   qué copia lo estático: `copy<TAB>origen<TAB>destino`
    theme-provider.py [--config CFG] preset <id>      poner un preset (sumi/palettes/<id>.json) de una vez
    theme-provider.py [--config CFG] preset --list    los presets válidos (JSON)
    theme-provider.py [--config CFG] --resolve        qué hay (JSON); no genera nada

Paletas estáticas (F-b, 2026-11-04): `static` (aplicar), `toggle` al apagar y `preset <id>` ya no copian a mano:
pasan por la MISMA transacción que la preview de la shell (theme-preview.py stage → snapshot → install → keep, con
restore si algo falla), así que todas las salidas de la config o ninguna, y un preset sólo se renderiza en su `stage`.
`--static-list JSON` (después de --config) = el argv de la lista estática que declara el usuario (D0-2: con `auto`,
Static devuelve también sus *.static.*); sin ella, la propia (sólo la shell). `reload` toma el cerrojo de la preview y
vuelve a mirar el sentinel con él puesto: un fondo nuevo que llega mientras se confirma un preset ya no lo pisa.

Estado: el de F1 ($XDG_STATE_HOME/sumi-shell/theme/{enabled,scheme,mode,contrast,source} y colors.json),
mismos formatos y validación que matugen_reload.sh. A diferencia del script del rice, un fallo de matugen
(o que falte) sale con 1 y lo dice: la shell lo enseña («matugen_reload.sh sale con 0 sin matugen»).
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import fcntl

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
sys.path.insert(0, HERE)
from theme_paths import load_matugen_config, toml_value  # noqa: E402
from xdg_paths import base_dir

RUN = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
STATE = os.path.join(base_dir("XDG_STATE_HOME", ".local/state"), "sumi-shell")
THEME = os.path.join(STATE, "theme")
SENTINEL = os.path.join(THEME, "enabled")
COLORS = os.path.join(STATE, "colors.json")
WALL_STATE = os.path.join(STATE, "current-wallpaper")
SHELL_DIR = os.path.dirname(HERE)
STATIC = os.path.join(SHELL_DIR, "colors.static.json")
DEFAULT_CONFIG = os.path.join(SHELL_DIR, "templates", "matugen-config.toml")
MATUGEN = os.environ.get("MATUGEN_BIN", "matugen")
LOG = os.path.join(RUN, "sumi-theme.log")
SCHEMES = ("scheme-content", "scheme-expressive", "scheme-fidelity", "scheme-fruit-salad", "scheme-monochrome",
           "scheme-neutral", "scheme-rainbow", "scheme-tonal-spot", "scheme-vibrant")
VIDEO = ("mp4", "mkv", "mov", "webm")
PRESET_FILE = os.path.join(THEME, "preset")
PREVIEW = os.path.join(HERE, "theme-preview.py")
# el cerrojo que serializa las órdenes de theme-preview.py que escriben (su main())
LOCK = os.path.join(THEME, ".desktop-sync.lock")


class Fail(Exception):
    pass


def read(path):
    try:
        with open(path) as f:
            return "".join(f.read().split())
    except OSError:
        return ""


def log(msg):
    try:
        with open(LOG, "a") as f:
            f.write(msg + "\n")
    except OSError:
        pass


def settings():
    """Los cinco ajustes, con la lista blanca y los defaults de matugen_reload.sh."""
    scheme = read(os.path.join(THEME, "scheme"))
    mode = read(os.path.join(THEME, "mode"))
    contrast = read(os.path.join(THEME, "contrast"))
    source = read(os.path.join(THEME, "source"))
    return {"scheme": scheme if scheme in SCHEMES else "scheme-tonal-spot",
            "mode": "light" if mode == "light" else "dark",
            "contrast": contrast if re.fullmatch(r"-?(0(\.[0-9]{1,2})?|1(\.0{1,2})?)", contrast or "") and contrast != "0" else "",
            "source": source if re.fullmatch(r"#[0-9a-fA-F]{6}", source or "") else ""}


def write_atomic(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".kt-")
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def resolved_config(cfg_path):
    """Una copia temporal de la config con las rutas resueltas (matugen no expande variables)."""
    cfg = load_matugen_config(cfg_path)
    fd, tmp = tempfile.mkstemp(dir=RUN, prefix="sumi-matugen.", suffix=".toml")
    with os.fdopen(fd, "w") as f:
        for key, value in cfg.items():
            f.write(json.dumps(key) + " = " + toml_value(value) + "\n")
    return tmp


def dynamic_on():
    return os.path.exists(SENTINEL) or os.environ.get("ENABLE_DYNAMIC_COLORS") == "1"


def reload(cfg_path, wall):
    if not dynamic_on():
        print("dynamic colours are off: nothing to do")
        return 0
    if not shutil.which(MATUGEN):
        raise Fail("matugen is not installed")
    os.makedirs(THEME, exist_ok=True)
    with open(LOCK, "a") as lk:
        # F-b: con el cerrojo de la preview; mientras se esperaba, un Keep pudo quitar el sentinel (un preset)
        fcntl.flock(lk, fcntl.LOCK_EX)
        if not dynamic_on():
            print("dynamic colours were turned off meanwhile: nothing to do")
            return 0
        return reload_locked(cfg_path, wall)


def reload_locked(cfg_path, wall):
    if not shutil.which(MATUGEN):
        raise Fail("matugen is not installed")
    s = settings()
    tmp = resolved_config(cfg_path)
    frame = None
    try:
        if s["source"]:
            what = ["color", "hex", s["source"]]
        else:
            if not wall or not os.path.isfile(wall):
                print("no wallpaper: the scheme is saved; colours come with the next one")
                return 0
            src = wall
            if wall.rsplit(".", 1)[-1].lower() in VIDEO:
                # el mismo fotograma que matugen_reload.sh (segundo 1)
                frame = os.path.join(RUN, "sumi-theme-frame.png")
                r = subprocess.run(["ffmpeg", "-y", "-ss", "00:00:01", "-i", wall, "-vframes", "1", "-update", "1", frame],
                                   capture_output=True, timeout=30)
                if r.returncode != 0:
                    raise Fail("could not take a frame of " + os.path.basename(wall))
                src = frame
            what = ["image", src]
        argv = [MATUGEN, "--config", tmp] + what + ["-m", s["mode"], "-t", s["scheme"]]
        if s["contrast"]:
            argv += ["--contrast", s["contrast"]]
        r = subprocess.run(argv, capture_output=True, text=True, timeout=90, stdin=subprocess.DEVNULL)
        log("matugen %s → %d" % (" ".join(argv[3:]), r.returncode))
        if r.returncode != 0:
            raise Fail("matugen failed: " + ((r.stderr or r.stdout).strip().splitlines() or ["exit %d" % r.returncode])[-1])
    finally:
        os.unlink(tmp)
    print("ok")
    return 0


def preview(env, *args):
    r = subprocess.run([sys.executable or "python3", "-B", PREVIEW] + list(args), capture_output=True, text=True,
                       env=env, timeout=180, stdin=subprocess.DEVNULL)
    try:
        res = json.loads((r.stdout.strip().splitlines() or ["{}"])[-1])
    except ValueError:
        res = {}
    if not isinstance(res, dict):
        res = {}
    res.setdefault("ok", r.returncode == 0)
    if r.returncode != 0:
        res["ok"] = False
    return res


def transact(cfg_path, static_list, profile):
    """Una preview que se confirma sola: stage → snapshot → install → keep; si algo falla después de la copia,
    restore. Carpetas propias (no las de la preview de la shell: si hay una abierta, la ve como cambio de fuera y se
    retira sin pisar esto). El escritorio (gsettings) lo alinea la shell con lo confirmado: aquí, off por defecto."""
    env = dict(os.environ, MATUGEN_CONFIG=cfg_path)
    env.setdefault("KT_DESKTOP_SYNC", "off")
    env.setdefault("KT_XSETTINGS_CONFIG", "")
    if static_list:
        env["KT_STATIC_LIST_ARGV"] = static_list
    else:
        env.pop("KT_STATIC_LIST_ARGV", None)
    work = tempfile.mkdtemp(dir=RUN, prefix="sumi-theme-apply.")
    snap = os.path.join(STATE, "theme-apply")
    try:
        r = preview(env, "recover", "--snap", snap)       # una transacción anterior cortada a medias
        if not r["ok"]:
            raise Fail("an earlier theme change could not be undone: %s" % (r.get("error") or r.get("detail")))
        r = preview(env, "stage", "--work", work, "--profile", profile)
        if not r["ok"]:
            raise Fail("%s: %s %s" % (profile, r.get("error", "stage failed"), r.get("detail", "")))
        for step in (("snapshot", "--snap", snap), ("install", "--work", work, "--snap", snap),
                     ("keep", "--snap", snap, "--profile", profile)):
            r = preview(env, *step)
            if not r["ok"]:
                back = preview(env, "restore", "--snap", snap)
                raise Fail("%s failed (%s %s); %s" % (step[0], r.get("error", ""), r.get("detail", ""),
                                                      "undone" if back["ok"] else "could NOT be undone"))
            log("apply %s: %s ok" % (profile, step[0]))
        return r
    finally:
        shutil.rmtree(work, ignore_errors=True)


def static(list_only, cfg_path=DEFAULT_CONFIG, static_list=""):
    if list_only:
        print("copy\t%s\t%s" % (STATIC, COLORS))
        return 0
    if not os.path.isfile(STATIC):
        raise Fail("the static palette is missing: " + STATIC)
    transact(cfg_path, static_list, "static")
    print("static")
    return 0


def preset(cfg_path, static_list, which):
    if which == "--list":
        r = subprocess.run([sys.executable or "python3", "-B", os.path.join(HERE, "palette_presets.py"), "list"],
                           capture_output=True, text=True, timeout=20)
        if r.returncode != 0:
            raise Fail("could not list the presets")
        sys.stdout.write(r.stdout)
        return 0
    if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)+", which or ""):
        raise Fail("not a preset id: " + which)
    transact(cfg_path, static_list, "preset:" + which)
    print("preset " + which)
    return 0


def toggle(cfg_path, static_list=""):
    if os.path.exists(SENTINEL):
        # apagar = Minimaru (la transacción quita el sentinel y theme/preset al confirmar)
        static(False, cfg_path, static_list)
        print("off")
        return 0
    if os.path.exists(PRESET_FILE):
        os.remove(PRESET_FILE)
    write_atomic(SENTINEL, b"")
    wall = read(WALL_STATE)
    reload(cfg_path, wall)
    print("on")
    return 0


def main(argv):
    cfg = DEFAULT_CONFIG
    if argv[:1] == ["--config"]:
        if len(argv) < 2:
            raise Fail("--config needs a path")
        cfg, argv = os.path.expanduser(argv[1]), argv[2:]
    static_list = ""
    if argv[:1] == ["--static-list"]:
        if len(argv) < 2:
            raise Fail("--static-list needs an argv (JSON)")
        try:
            sl = json.loads(argv[1])
        except ValueError:
            sl = None
        if not isinstance(sl, list) or not sl or not all(isinstance(x, str) for x in sl):
            raise Fail("--static-list is not an argv")
        static_list, argv = argv[1], argv[2:]
    if argv[:1] == ["--resolve"]:
        print(json.dumps({"matugen": bool(shutil.which(MATUGEN)), "config": cfg, "configExists": os.path.isfile(cfg),
                          "own": os.path.abspath(cfg) == os.path.abspath(DEFAULT_CONFIG), "static": os.path.isfile(STATIC)}))
        return 0
    cmd = argv[0] if argv else ""
    if cmd == "reload":
        return reload(cfg, argv[1] if len(argv) > 1 else "")
    if cmd == "toggle" and len(argv) == 1:
        return toggle(cfg, static_list)
    if cmd == "static" and argv[1:] in ([], ["--list"]):
        return static(argv[1:] == ["--list"], cfg, static_list)
    if cmd == "preset" and len(argv) == 2:
        return preset(cfg, static_list, argv[1])
    # una orden desconocida NO hace nada (al revés que apply-static-colors.sh, que copiaba: trampa de la 12A)
    raise Fail("unknown command: " + " ".join(argv) if argv else "a command is needed: reload, toggle, static or preset")


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Fail as e:
        print("theme-provider: " + str(e), file=sys.stderr)
        sys.exit(1)
