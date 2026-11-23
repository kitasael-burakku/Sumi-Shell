#!/usr/bin/env python3
"""Grabador de pantalla de la shell (2026-10-29): wf-recorder supervisado FUERA del shell.

La shell lo lanza en su propio scope (`Apps.spawn`, como cualquier app) y desde ahí la grabación
no depende de QML: recargar o reiniciar la shell no la corta, y al volver se recupera leyendo el
estado. Un solo supervisor a la vez (cerrojo); se controla con señales.

    screen-recorder.py probe [--dir DIR]
        Capacidades: herramientas, codificadores que FUNCIONAN aquí, contenedores, fuentes de audio, pantallas
        (con su refresco), carpeta de salida y lo fijo del backend (pausa por tramos, cursor siempre).
    screen-recorder.py run --token T --mode screen|region|output [--output NAME] [--geometry "x,y WxH"] …(plan)…
        El supervisor (en primer plano, dentro de su scope). Escribe el estado y sale al terminar.
    screen-recorder.py plan …(las mismas opciones que run)…
        Lo que se grabaría: codificador, fps, tamaño, audio, archivo, avisos y el motivo si no se puede. No graba.
        La surface y Settings enseñan esto: la resolución vive SÓLO aquí.
    screen-recorder.py pause|resume|stop|cancel
        Señal al supervisor vivo: {"ok": true} o {"ok": false, "error": …}.
    screen-recorder.py status
        El estado; si dice «vivo» y el supervisor ya no existe, lo corrige a «error».
    screen-recorder.py recover --work DIR
        Une los tramos que dejó un supervisor muerto o un guardado fallido: {"ok", "file"} o {"ok": false, "error"}.
    screen-recorder.py windows
        Los rectángulos de las ventanas visibles que se le dan a slurp (pruebas).
    screen-recorder.py copy FILE [--as uri|path]
        La grabación al portapapeles como archivo (text/uri-list) o su ruta como texto.

Opciones de run/plan (Grabador 2.0): --preset standard|high|custom, --encoder auto|<id> (Custom), --fps N (Custom;
0 = automático), --rate-control balanced|high|veryhigh|bitrate y --bitrate MBPS (Custom), --height N (Custom; 0 =
nativa), --format mp4|mkv|webm, --audio none|system|mic|both, --system-source/--mic-source NAME ("" = la
predeterminada), --audio-codec aac|opus, --audio-bitrate KBPS, --sample-rate HZ, --name PATRÓN, --dir, --delay.
De antes siguen valiendo --quality standard|high (= el preset) y --encoder gpu|cpu (pruebas; cpu = x264).

Estados: selecting (slurp) → countdown → starting → recording ⇄ paused → saving → done,
y cancelled / error. Archivo: $XDG_RUNTIME_DIR/sumi-shell/recorder/state.json, por renombrado.

PAUSA POR TRAMOS. wf-recorder no tiene pausa: pausar cierra el tramo actual (SIGINT, que lo deja
completo) y reanudar abre otro con los mismos argumentos. Los tramos son Matroska en una carpeta
oculta junto a la salida (no en tmpfs: el vídeo crece) y al parar se unen sin recodificar en el contenedor
elegido. Matroska y no MP4 en los tramos: un tramo cortado de golpe sigue siendo legible (y `recover` lo une).

Medido (wf-recorder 0.6.0, Hyprland anidado, 2026-10-29):
  · con fotogramas llegando, SIGINT cierra el tramo en 0,07–0,26 s; unir dos tramos con el demuxer
    concat y `-c copy` da 173 fotogramas en 5,73 s (CFR 30), sin recodificar;
  · si la salida no cambió NI UNA VEZ desde que arrancó, wf-recorder no recibe ningún fotograma e
    ignora SIGINT y SIGTERM: el tramo está vacío. Por eso parar escala a SIGKILL y los tramos sin
    vídeo se descartan;
  · una región recibe fotogramas aunque el cambio caiga fuera de ella (el daño es por salida);
  · el tamaño del archivo no sirve para saber cuándo empezó: el muxer no escribe hasta tarde.

Sistema + micrófono: wf-recorder admite UNA fuente de audio. Con las dos, el sistema va con el vídeo y
el micrófono se graba aparte (ffmpeg, mismo tramo) y se mezcla al guardar. No se cuelga nada del PipeWire del
usuario (un sumidero de mezcla y dos bucles quedarían en el estado de WirePlumber y junto a su ecualizador).

Segunda entrega (2026-10-29, «empieza por esas 4»):
  · CODIFICAR CON LA GPU (VAAPI) cuando se pueda. Medido en el banco (1440×1000, ventana animada): x264 gastaba
    71 % de un núcleo en Standard y 110 % en High; VAAPI, 1,4 % y 1,9 %. Misma nitidez que x264 (SSIM sobre la
    misma grabación: CRF 23 ≈ QP 29, CRF 18 ≈ QP 24), archivos ~1,24× más grandes. Si VAAPI no arranca (sin
    nodo de render, controlador, tamaño: la RX 7600 no codifica por debajo de 128×128) falla en < 0,1 s y el
    primer tramo se repite con x264 sin que se note. Sólo el PRIMERO: los tramos de una grabación se unen sin
    recodificar y deben salir del mismo codificador; si la GPU falla al reanudar, se guarda lo que había,
    como cualquier fallo al reanudar. Las regiones pequeñas van directas a x264 (ahí cuesta poco).
  · UNA VENTANA CON UN CLIC: en Region, slurp recibe por stdin los rectángulos de las ventanas visibles
    (`hyprctl -j`, sólo lectura) y los resalta; un clic elige una, arrastrar sigue dibujando un área y un clic
    en un hueco cancela (medido con un puntero virtual en el banco). Es «ventana» si slurp devuelve justo su
    rectángulo (su `%l` no vale: un arrastre que empieza encima de una ventana lo conserva). slurp elige el rectángulo más pequeño
    bajo el puntero: una flotante grande sobre una pequeña en mosaico da la pequeña. El área queda fija:
    si la ventana se mueve después, no la sigue.
  · reanudar ya no pasa por «starting» (la pieza y la barra enseñaban «Starting…» y Cancel, que tiraba
    toda la grabación): sigue en «paused» hasta que el tramo nuevo graba.

Grabador 2.0 (2026-10-29, Settings → Screen recording):
  · CAPACIDADES REALES. Que ffmpeg tenga un codificador compilado no dice que funcione: cada uno se prueba
    codificando un fotograma (~55 ms; caché por arranque y dispositivo en el runtime). Aquí (RX 7600): H.264,
    HEVC y AV1 por VAAPI, VP9 no. NVENC/QSV/AMF/Vulkan están compilados pero NO se ofrecen: no se han probado con
    wf-recorder (en una máquina sin VAAPI, Automatic usa x264).
  · CALIDAD POR CODIFICADOR, no el mismo número para todos: x264 CRF, H.264/HEVC VAAPI QP (0–51), AV1 VAAPI
    `global_quality` (0–255). Cada nivel con la nitidez (SSIM) del nivel de x264, medida sobre la misma
    referencia (`QUALITY`). Sin «lossless»: x264 en yuv420p no lo es frente a la pantalla RGB.
  · CURSOR: wf-recorder 0.6.0 pide `overlay_cursor = 1` fijo (desensamblado): el puntero se graba siempre.
  · FPS: wf-recorder da tasa CONSTANTE repitiendo fotogramas; por encima del refresco de la pantalla no hay
    fotogramas nuevos (avisa el plan). Los presets no pasan del refresco.
  · ESCALADO: `-F scale=W:H` (x264) o `-F scale_vaapi=…` (VAAPI), nunca hacia arriba, lados pares, proporción
    de la fuente (medido en el banco: el tamaño pedido exacto).

Fluidez (2026-11-12, docs/GRABADORA-FLUIDEZ-2026-11-12.md; medido en la pantalla real, 1920×1080 a 200 Hz, con un
patrón que lleva su número de fotograma en código de barras):
  · La captura NO pierde nada: sin `-r`, wf-recorder recibe los 200 fotogramas por segundo, a 5,000 ms exactos.
  · `-r N` es un filtro `fps=N` sobre esa cadencia. Si N no divide el refresco, los pasos son desiguales (60 sobre
    200 Hz: 3,3,4 fotogramas; 120: 2,2,1) y el movimiento tiembla. Los presets y Automatic toman el divisor exacto
    más cercano a su objetivo (`smooth_fps`: en 200 Hz, 30 → 25 y 60 → 50); en Custom manda lo elegido, con aviso.
  · Aun dividiendo, `fps` redondea los timestamps a su rejilla, y la mitad de los fotogramas caía JUSTO en el límite
    del redondeo: 100 fps sobre 200 Hz daba un 7 % de pasos 1/3 en vez de 2 según la fluctuación de microsegundos.
    `phase_filter` corre los timestamps lo justo para que el primer fotograma quede a ¼ de periodo de la rejilla
    (con audio el vídeo empieza en una fase cualquiera, de ahí `STARTPTS`): desplaza el vídeo ≤ 1 periodo.
    Con eso 50/100/200 fps salieron sin un solo paso irregular. Queda la deriva del reloj de la pantalla
    (−16 ppm medidos: un cruce del límite cada ~62 s), inevitable con fps constantes.
"""
import argparse
import datetime
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.parse

sys.dont_write_bytecode = True

RUN = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "sumi-shell", "recorder")
STATE = os.path.join(RUN, "state.json")
LOCK = os.path.join(RUN, "lock")
LOG = os.path.join(RUN, "recorder.log")
LIVE = ("selecting", "countdown", "starting", "recording", "paused", "saving")
GEOMETRY = re.compile(r"^(-?\d+),(-?\d+) (\d+)x(\d+)$")
OUTPUT = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
TOKEN = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
MIN_FREE = 300 * 1024 * 1024
# Por debajo de esto (lado lógico) una región va con x264: cuesta poco y no todas las GPU la aceptan
VAAPI_MIN = 256
ENC_CACHE = os.path.join(RUN, "encoders.json")
# slurp con el aspecto del grabador: todo atenuado y lo que se va a grabar limpio, con el borde rojo (el de la
# privacidad). Las ventanas no elegidas se pintan con -B (no con el fondo): atenuadas igual, o la elegida sólo
# se distinguía por el borde (comparado en el banco). Por defecto, lo elegido apenas se veía.
SLURP_STYLE = ["-b", "#00000066", "-c", "#ff453a", "-s", "#00000000", "-B", "#00000066", "-w", "2"]

# ---- lo que se puede elegir -----------------------------------------------------------------------------

# Los codificadores que se OFRECEN (cada uno con su prueba de un fotograma). El orden es el de la UI.
ENCODERS = {
    "h264_vaapi": {"codec": "h264", "label": "H.264", "kind": "gpu", "api": "VAAPI"},
    "hevc_vaapi": {"codec": "hevc", "label": "HEVC", "kind": "gpu", "api": "VAAPI"},
    "av1_vaapi": {"codec": "av1", "label": "AV1", "kind": "gpu", "api": "VAAPI"},
    "libx264": {"codec": "h264", "label": "H.264", "kind": "cpu", "api": "x264"},
}
NOT_OFFERED = "NVENC, Quick Sync, AMF and Vulkan encoders are not offered: not verified with wf-recorder"
CONTAINERS = {
    "mp4": {"ext": ".mp4", "muxer": "mp4", "video": ("h264", "hevc", "av1"), "audio": ("aac", "opus"), "label": "MP4"},
    "mkv": {"ext": ".mkv", "muxer": "matroska", "video": ("h264", "hevc", "av1"), "audio": ("aac", "opus"), "label": "MKV"},
    "webm": {"ext": ".webm", "muxer": "webm", "video": ("av1",), "audio": ("opus",), "label": "WebM"},
}
AUDIO_CODECS = {"aac": {"encoder": "aac", "rates": (44100, 48000), "label": "AAC"},
                "opus": {"encoder": "libopus", "rates": (48000,), "label": "Opus"}}
TIERS = ("balanced", "high", "veryhigh")
# Calidad por codificador y nivel: el valor menos costoso con una nitidez (SSIM) igual o mejor que la del nivel de x264
# (CRF 23 / 18 / 13 = 0,98964 / 0,9952 / 0,99795) sobre la MISMA referencia: banco re01, 1440×1000 a 60 fps, ventana
# animada + terminal volcando texto, RX 7600 (docs/GRABADOR-2.0-2026-10-29.md, «Calidad»). H.264 VAAPI conserva 29/24
# de la segunda entrega (medidos allí sobre otra referencia; aquí 31/26 bastarían). Medido también: en esta GPU HEVC y
# AV1 por VAAPI dan archivos MÁS grandes que H.264 con la misma nitidez en contenido de pantalla (10,2 y 11,2 MB frente
# a 7,5 MB en Balanced): Automatic usa H.264.
QUALITY = {
    "libx264": {"balanced": 23, "high": 18, "veryhigh": 13},
    "h264_vaapi": {"balanced": 29, "high": 24, "veryhigh": 21},
    "hevc_vaapi": {"balanced": 33, "high": 29, "veryhigh": 25},
    "av1_vaapi": {"balanced": 130, "high": 100, "veryhigh": 55},
}
# Un codificador por GPU que RELLENA el fotograma (AV1 en la RX 7600: 1440×1000 → 1472×1002, 1920×1080 → 1920×1082,
# en negro; los reproductores que no aplican el «render size» enseñan esa banda) sólo se usa con tamaños que no rellena.
PAD_W, PAD_H = 64, 16
# Standard y High: lo de las entregas anteriores, ahora sin pasar del refresco de la pantalla
PRESETS = {"standard": {"fps": 30, "quality": "balanced", "height": 0, "encoder": "auto"},
           "high": {"fps": 60, "quality": "high", "height": 0, "encoder": "auto"}}
DEFAULT_NAME = "Recording {date} {time}"


def now_ms():
    return int(time.time() * 1000)


def log(*parts):
    try:
        with open(LOG, "a") as f:
            f.write(time.strftime("%H:%M:%S ") + " ".join(str(p) for p in parts) + "\n")
    except OSError:
        pass


def which(name):
    return shutil.which(name) is not None


def run_quiet(argv, timeout=3):
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip() if r.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


# ---- carpeta y audio ------------------------------------------------------------------------------

def videos_dir():
    """XDG_VIDEOS_DIR de user-dirs.dirs, o ~/Videos (xdg-user-dir devuelve HOME si no está puesto)."""
    home = os.path.expanduser("~")
    cfg = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(home, ".config"), "user-dirs.dirs")
    try:
        for line in open(cfg, encoding="utf-8"):
            m = re.match(r'\s*XDG_VIDEOS_DIR="(.*)"\s*$', line)
            if m:
                v = m.group(1).replace("$HOME", home)
                if v.startswith("/") and os.path.realpath(v) != os.path.realpath(home):
                    return v
    except OSError:
        pass
    return os.path.join(home, "Videos")


def default_dir():
    return os.path.join(videos_dir(), "Recordings")


def out_dir(d):
    """La carpeta pedida (con ~ expandido) o la predeterminada."""
    d = (d or "").strip()
    return os.path.expanduser(d) if d else default_dir()


def dir_check(d):
    """¿Se puede grabar ahí? {path, exists, writable, free, error, kind}. No crea nada."""
    path = out_dir(d)
    r = {"path": path, "exists": os.path.isdir(path), "writable": False, "free": -1, "error": "", "kind": ""}
    if not path.startswith("/"):
        r.update(error="The folder must be an absolute path", kind="folder")
        return r
    # lo que ya existe del camino: ahí se crearía la carpeta
    probe = path
    while not os.path.exists(probe) and probe not in ("/", ""):
        probe = os.path.dirname(probe)
    if os.path.exists(probe) and not os.path.isdir(probe):
        r.update(error=probe + " is a file, not a folder", kind="folder")
        return r
    r["writable"] = os.access(probe, os.W_OK | os.X_OK)
    try:
        r["free"] = shutil.disk_usage(probe).free
    except OSError:
        pass
    if not r["writable"]:
        r.update(error="No permission to write in " + probe, kind="folder")
    elif 0 <= r["free"] < MIN_FREE:
        r.update(error="Not enough free space in " + probe, kind="space")
    return r


def pulse_sources():
    """[{name, label, monitor}] de pactl (JSON si lo admite; si no, la lista corta sin descripciones)."""
    if not which("pactl"):
        return []
    out = []
    try:
        for s in json.loads(run_quiet(["pactl", "-f", "json", "list", "sources"]) or "[]"):
            props = s.get("properties") or {}
            name = str(s.get("name") or "")
            if name:
                out.append({"name": name, "label": str(s.get("description") or name),
                            "monitor": props.get("device.class") == "monitor" or name.endswith(".monitor")})
        return out
    except (ValueError, AttributeError):
        pass
    for line in run_quiet(["pactl", "list", "short", "sources"]).splitlines():
        cols = line.split("\t")
        if len(cols) > 1:
            out.append({"name": cols[1], "label": cols[1], "monitor": cols[1].endswith(".monitor")})
    return out


def audio_sources(system_pref="", mic_pref="", sources=None):
    """{"system": <monitor elegido o el de la salida predeterminada>, "mic": <entrada elegida o una real>,
    "warnings": [...]} ("" si no hay). Un monitor no es un micrófono: aquí la fuente predeterminada ES el monitor
    del HDMI (sin micro)."""
    if sources is None:
        if not which("pactl"):
            return {"system": "", "mic": "", "warnings": []}
        sources = pulse_sources()
    names = [s["name"] for s in sources]
    monitors = [s["name"] for s in sources if s["monitor"]]
    real = [s["name"] for s in sources if not s["monitor"]]
    warn = []
    sink = run_quiet(["pactl", "get-default-sink"]) if which("pactl") else ""
    system = sink + ".monitor" if sink and (sink + ".monitor") in names else (monitors[0] if monitors else "")
    if system_pref:
        if system_pref in monitors:
            system = system_pref
        else:
            warn.append("The chosen system audio source is not connected: using the default output")
    src = run_quiet(["pactl", "get-default-source"]) if which("pactl") else ""
    mic = src if src in real else (real[0] if real else "")
    if mic_pref:
        if mic_pref in real:
            mic = mic_pref
        elif mic:
            warn.append("The chosen microphone is not connected: using the default input")
    return {"system": system, "mic": mic, "warnings": warn}


# ---- pantallas ----------------------------------------------------------------------------------------

def hypr_monitors():
    try:
        m = json.loads(run_quiet(["hyprctl", "-j", "monitors"]) or "[]")
        return m if isinstance(m, list) else []
    except ValueError:
        return []


def screens_of(monitors):
    """[{name, x, y, width, height (físicos, ya girados), scale, refresh}] de `hyprctl -j monitors`."""
    out = []
    for m in monitors if isinstance(monitors, list) else []:
        if m.get("disabled") or not m.get("name"):
            continue
        w, h = int(m.get("width") or 0), int(m.get("height") or 0)
        if int(m.get("transform") or 0) % 2:
            w, h = h, w
        out.append({"name": m["name"], "x": int(m.get("x") or 0), "y": int(m.get("y") or 0), "width": w, "height": h,
                    "scale": float(m.get("scale") or 1) or 1.0, "refresh": round(float(m.get("refreshRate") or 0), 2)})
    return out


def source_size(mode, target, screens):
    """(ancho, alto, refresco) FÍSICOS de lo que se graba, o (0, 0, 0) si aún no se sabe (región sin elegir)."""
    if mode == "region":
        m = GEOMETRY.match(target or "")
        if not m:
            return 0, 0, 0
        x, y, w, h = (int(v) for v in m.groups())
        for s in screens:
            lw, lh = s["width"] / s["scale"], s["height"] / s["scale"]
            if s["x"] <= x < s["x"] + lw and s["y"] <= y < s["y"] + lh:
                return round(w * s["scale"]), round(h * s["scale"]), s["refresh"]
        return w, h, 0
    for s in screens:
        if s["name"] == target:
            return s["width"], s["height"], s["refresh"]
    return 0, 0, 0


def even(v):
    return max(2, int(v) - int(v) % 2)


def smooth_rates(refresh, lo=24):
    """Los fps que toman un fotograma de cada k de la pantalla (divisores exactos del refresco redondeado), de `lo`
    al refresco: los únicos con pasos iguales. [] si no se sabe el refresco."""
    hz = int(round(refresh or 0))
    return [d for d in range(max(1, lo), hz + 1) if hz % d == 0] if hz >= 1 else []


def smooth_fps(target, refresh):
    """El divisor exacto del refresco más cercano a `target` (empate: el menor; nunca por encima del refresco).
    Sin refresco conocido, `target`."""
    rates = smooth_rates(refresh, 1)
    if not rates:
        return target
    return min(rates, key=lambda d: (abs(d - target), d))


def scaled_size(w, h, height):
    """El tamaño de salida: el de la fuente con lados pares, o reducido a `height` (nunca hacia arriba),
    con su proporción."""
    if w <= 0 or h <= 0:
        return 0, 0
    if height and h > height:
        return even(round(w * height / h)), even(height)
    return even(w), even(h)


# ---- codificadores -----------------------------------------------------------------------------------

def render_node():
    """El primer nodo de render (/dev/dri/renderD*), o "" si no hay."""
    try:
        nodes = sorted(n for n in os.listdir("/dev/dri") if n.startswith("renderD"))
    except OSError:
        return ""
    return "/dev/dri/" + nodes[0] if nodes else ""


TEST_W, TEST_H = 336, 200     # ni múltiplo de 64 ni de 16: deja ver el relleno; ≥ 128 (mínimo de VAAPI en AMD)


def test_encoder(eid, device):
    """(funciona, motivo, rellena). Un fotograma con el ffmpeg del sistema (la misma libavcodec que wf-recorder) a un
    archivo del runtime, y ffprobe dice el tamaño DECODIFICADO: si no es el pedido, el codificador rellena."""
    os.makedirs(RUN, mode=0o700, exist_ok=True)
    tmp = os.path.join(RUN, "enc-test-%s-%d.mkv" % (eid, os.getpid()))
    src = ["-f", "lavfi", "-i", "color=c=black:s=%dx%d:d=0.1" % (TEST_W, TEST_H)]
    if ENCODERS[eid]["kind"] == "gpu":
        if not device:
            return False, "No GPU render node", False
        argv = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-vaapi_device", device, *src,
                "-vf", "format=nv12,hwupload", "-c:v", eid, "-rc_mode", "CQP", "-f", "matroska", tmp]
    else:
        argv = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y", *src, "-c:v", eid, "-pix_fmt", "yuv420p",
                "-f", "matroska", tmp]
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=8)
        # un codificador que no produce nada (VP9 en esta GPU) sale con 0 y lo dice: no vale
        err = (r.stderr or "").strip()
        if r.returncode != 0 or "no packets" in err or "Nothing was written" in err or not probe_ok(tmp, "v"):
            line = [l for l in err.splitlines() if l.strip()]
            return False, (line[-1][:160] if line else "The encoder did not work"), False
        size = run_quiet(["ffprobe", "-v", "error", "-select_streams", "v", "-read_intervals", "%+#1",
                          "-show_entries", "frame=width,height", "-of", "csv=p=0", tmp], timeout=8)
        dims = [int(x) for x in re.findall(r"\d+", size)[:2]]
        return True, "", len(dims) == 2 and dims != [TEST_W, TEST_H]
    except (OSError, subprocess.SubprocessError, ValueError) as e:
        return False, str(e)[:120], False
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def encoder_status(device=None, fresh=False):
    """{id: {"ok", "why"}} de todos los ofrecidos, una vez por arranque y dispositivo (caché en el runtime)."""
    device = render_node() if device is None else device
    if not fresh:
        try:
            with open(ENC_CACHE) as f:
                c = json.load(f)
            if c.get("device") == device and isinstance(c.get("results"), dict) \
                    and all(k in c["results"] for k in ENCODERS) and c.get("ffmpeg") == which("ffmpeg"):
                return c["results"]
        except (OSError, ValueError):
            pass
    res = {}
    for eid in ENCODERS:
        if not which("ffmpeg"):
            res[eid] = {"ok": False, "why": "ffmpeg is not installed", "pads": False}
            continue
        ok, why, pads = test_encoder(eid, device)
        res[eid] = {"ok": ok, "why": why, "pads": pads}
    try:
        os.makedirs(RUN, mode=0o700, exist_ok=True)
        tmp = ENC_CACHE + ".%d.tmp" % os.getpid()
        with open(tmp, "w") as f:
            json.dump({"device": device, "results": res, "ffmpeg": which("ffmpeg"), "at": now_ms()}, f)
        os.replace(tmp, ENC_CACHE)
    except OSError:
        pass
    log("encoders", device, " ".join(k for k, v in res.items() if v["ok"]))
    return res


def encoder_label(eid):
    e = ENCODERS.get(eid)
    return e["label"] + (" (GPU)" if e["kind"] == "gpu" else " (CPU)") if e else eid


def small_region(mode, target):
    m = GEOMETRY.match(target or "") if mode == "region" else None
    return bool(m) and min(int(m.group(3)), int(m.group(4))) < VAAPI_MIN


def choose_encoder(want, fmt, mode, target, device, works, size=(0, 0)):
    """(id, dispositivo, avisos, error). `want`: auto · un id · gpu (H.264 por GPU sin prueba: pruebas) · cpu (x264).
    `works(id)` → (ok, motivo, rellena); `size`: el tamaño de salida si ya se sabe (0, 0 si no)."""
    allowed = CONTAINERS[fmt]["video"]
    label = CONTAINERS[fmt]["label"]
    small = small_region(mode, target)

    def why_not(eid):
        """Por qué NO se usa aquí este codificador ("" = se puede)."""
        e = ENCODERS[eid]
        if e["kind"] == "gpu" and small:
            return "Regions under %d px are encoded on the CPU" % VAAPI_MIN
        if e["kind"] == "gpu" and not device:
            return encoder_label(eid) + " needs a GPU render node"
        w = works(eid)
        if not w[0]:
            return encoder_label(eid) + " isn't available here" + (" (" + w[1] + ")" if w[1] else "")
        if len(w) > 2 and w[2] and size[0] and (size[0] % PAD_W or size[1] % PAD_H):
            return "%s would add a black edge to %d×%d (it pads to multiples of %d×%d)" % (
                encoder_label(eid), size[0], size[1], PAD_W, PAD_H)
        return ""

    if want == "cpu":
        want = "libx264"
    if want == "gpu" and "h264" in allowed:
        return ("h264_vaapi", device, [], "") if device and not small else ("libx264", "", [], "")
    if want == "gpu":
        want = "auto"           # WebM: la GPU con lo único que cabe (AV1)
    if want == "auto" or want not in ENCODERS:
        reasons = []
        for eid in (("av1_vaapi",) if fmt == "webm" else ("h264_vaapi", "libx264")):
            r = why_not(eid)
            if not r:
                return eid, device if ENCODERS[eid]["kind"] == "gpu" else "", [], ""
            reasons.append(r)
        if fmt == "webm":
            return "", "", [], "WebM needs AV1 and it can't be used here (%s): choose MP4 or MKV" % reasons[0]
        return "", "", [], "No video encoder works here: install ffmpeg with libx264"
    e = ENCODERS[want]
    if e["codec"] not in allowed:
        return "", "", [], "%s can't hold %s: choose another format or encoder" % (label, e["label"])
    why = why_not(want)
    if not why:
        return want, device if e["kind"] == "gpu" else "", [], ""
    # lo elegido no se puede: H.264 (GPU si se puede, si no CPU), si el contenedor lo admite, y se dice
    for eid in ("h264_vaapi", "libx264"):
        if eid != want and "h264" in allowed and not why_not(eid):
            return eid, device if ENCODERS[eid]["kind"] == "gpu" else "", [why + ": using " + encoder_label(eid)], ""
    return "", "", [], why


# ---- el plan: lo que se grabará -----------------------------------------------------------------------------

def resolve(o, target="", screens=None, works=None, sources=None):
    """Todo lo que decide la grabación, en UN sitio (run, plan, la surface y Settings lo leen de aquí)."""
    screens = screens if screens is not None else screens_of(hypr_monitors())
    if works is None:
        cache = {}

        def works(eid):
            if not cache:
                cache.update(encoder_status())
            r = cache.get(eid) or {"ok": False, "why": "unknown"}
            return r["ok"], r["why"], bool(r.get("pads"))
    warn, err, kind = [], "", ""
    preset = o.preset if o.preset in ("standard", "high", "custom") else ("high" if o.quality == "high" else "standard")
    fmt = o.format if o.format in CONTAINERS else "mp4"
    spec = PRESETS.get(preset) or {"fps": o.fps, "quality": o.rate_control, "height": o.height, "encoder": o.encoder}
    # pruebas de las entregas anteriores: --encoder gpu|cpu también con un preset
    want = o.encoder if o.encoder in ("gpu", "cpu") else spec["encoder"]
    device = o.vaapi_device or render_node()
    src_w, src_h, refresh = source_size(o.mode, target, screens)
    height = int(spec["height"] or 0)
    out_w, out_h = scaled_size(src_w, src_h, height)
    eid, device, w, why = choose_encoder(want, fmt, o.mode, target, device, works, (out_w, out_h))
    warn += w
    if why:
        err, kind = why, "format" if " can't hold " in why else "encoder"
    fps = int(spec["fps"] or 0)
    if fps <= 0:
        fps = smooth_fps(60, refresh)
    elif preset != "custom" and refresh >= 1:
        fps = smooth_fps(fps, refresh)
    elif refresh >= 1 and fps > refresh + 0.5:
        warn.append("This screen refreshes at %g Hz: above that, frames repeat" % refresh)
    elif refresh >= 1 and int(round(refresh)) % fps:
        smooth = [d for d in smooth_rates(refresh) if d >= 24][-3:]
        warn.append("%d fps doesn't divide this screen's %g Hz: motion will step unevenly%s" % (
            fps, refresh, " (smooth here: " + ", ".join(str(d) for d in smooth) + ")" if smooth else ""))
    tier = spec["quality"] if spec["quality"] in TIERS + ("bitrate",) else "balanced"
    if eid == "libx264" and fps > 60 and out_w * out_h > 2_100_000:
        warn.append("H.264 on the CPU at %d fps is heavy at this size" % fps)
    codec = o.audio_codec if o.audio_codec in AUDIO_CODECS else "aac"
    if codec not in CONTAINERS[fmt]["audio"]:
        codec = "opus"
    rate = o.sample_rate if o.sample_rate in AUDIO_CODECS[codec]["rates"] else AUDIO_CODECS[codec]["rates"][-1]
    a = audio_sources(o.system_source, o.mic_source, sources) if o.audio != "none" else {"system": "", "mic": "", "warnings": []}
    wf_audio, mic_dev, why = audio_plan(o.audio, a)
    if why and not err:
        err, kind = why, "audio"
    warn += a["warnings"] if o.audio != "none" else []
    return {
        "preset": preset, "format": fmt, "ext": CONTAINERS[fmt]["ext"], "muxer": CONTAINERS[fmt]["muxer"],
        "encoder": eid, "encoderLabel": encoder_label(eid) if eid else "", "device": device,
        "codec": ENCODERS[eid]["codec"] if eid else "", "quality": tier,
        "value": (int(o.bitrate) if tier == "bitrate" else QUALITY[eid][tier]) if eid else 0,
        "fps": fps, "refresh": refresh, "smooth": smooth_rates(refresh), "source": [src_w, src_h], "size": [out_w, out_h], "height": height,
        "audio": o.audio, "wfAudio": wf_audio, "micDevice": mic_dev, "audioCodec": codec,
        "audioEncoder": AUDIO_CODECS[codec]["encoder"], "audioBitrate": int(o.audio_bitrate), "sampleRate": rate,
        "name": o.name if (o.name or "").strip() else DEFAULT_NAME, "dir": out_dir(o.dir),
        "warnings": warn, "error": err, "errorKind": kind,
    }


def params_of(plan):
    """Lo que la UI enseña de una grabación en curso o hecha (sin rutas de dispositivo)."""
    return {k: plan.get(k) for k in ("preset", "format", "encoder", "encoderLabel", "codec", "quality", "value", "fps",
                                      "size", "audio", "audioCodec", "audioBitrate", "sampleRate")}


# ---- ventanas para slurp ------------------------------------------------------------------------------

def window_boxes(monitors, clients):
    """Los rectángulos «x,y WxH clase» de las ventanas que se ven ahora (su espacio activo o el especial
    abierto de cada pantalla), recortados a su pantalla en coordenadas lógicas, como las de slurp y -g."""
    shown, screens = set(), {}
    for m in monitors if isinstance(monitors, list) else []:
        if m.get("disabled"):
            continue
        for k in ("activeWorkspace", "specialWorkspace"):
            ws = m.get(k) or {}
            if ws.get("id"):
                shown.add(ws["id"])
        scale = float(m.get("scale") or 1) or 1
        w, h = round(m.get("width", 0) / scale), round(m.get("height", 0) / scale)
        if int(m.get("transform") or 0) % 2:
            w, h = h, w
        screens[m.get("id")] = (m.get("x", 0), m.get("y", 0), w, h)
    out = []
    for c in clients if isinstance(clients, list) else []:
        if not c.get("mapped") or c.get("hidden") or (c.get("workspace") or {}).get("id") not in shown:
            continue
        s = screens.get(c.get("monitor"))
        at, size = c.get("at") or [0, 0], c.get("size") or [0, 0]
        if not s or len(at) != 2 or len(size) != 2:
            continue
        x1, y1 = max(at[0], s[0]), max(at[1], s[1])
        x2, y2 = min(at[0] + size[0], s[0] + s[2]), min(at[1] + size[1], s[1] + s[3])
        if x2 - x1 < 2 or y2 - y1 < 2:
            continue
        label = re.sub(r"[^A-Za-z0-9._-]", "", str(c.get("class") or ""))[:40] or "window"
        out.append("%d,%d %dx%d %s" % (x1, y1, x2 - x1, y2 - y1, label))
    return out


def hypr_windows():
    try:
        return window_boxes(hypr_monitors(), json.loads(run_quiet(["hyprctl", "-j", "clients"]) or "[]"))
    except ValueError:
        return []


def parse_pick(out, boxes):
    """Lo que devuelve slurp: (geometría par, clase de la ventana o "" si se arrastró un área). Es una ventana
    sólo si coincide EXACTAMENTE con uno de sus rectángulos: `%l` no sirve (medido: un arrastre que empieza
    sobre una ventana conserva su etiqueta)."""
    pick = " ".join(out.strip().split(" ")[:2])
    label = ""
    for b in boxes:
        parts = b.split(" ", 2)
        if " ".join(parts[:2]) == pick:
            label = parts[2] if len(parts) > 2 else "window"
            break
    return even_geometry(pick), label


def cmd_windows(args):
    print(json.dumps(hypr_windows()))
    return 0


# ---- copiar --------------------------------------------------------------------------------------------

def file_uri(path):
    return "file://" + urllib.parse.quote(os.path.abspath(path))


def cmd_copy(args):
    """text/uri-list: lo pegan como ARCHIVO un chat (Telegram, Discord) o un gestor de archivos; wl-copy lo
    ofrece también como texto. `--as path`: la ruta como texto plano (para una terminal o un campo). wl-copy se
    queda en segundo plano sirviendo la selección: sin tuberías nuestras abiertas, o esto esperaría hasta que otro
    copiara algo."""
    def answer(ok, error=""):
        print(json.dumps({"ok": ok, "error": error} if error else {"ok": ok}))
        return 0 if ok else 1
    if not os.path.isfile(args.file):
        return answer(False, "The recording is no longer there")
    if not which("wl-copy"):
        return answer(False, "Install wl-clipboard to copy")
    path = args.__dict__.get("as") == "path"
    argv = ["wl-copy", "--type", "text/plain;charset=utf-8"] if path else ["wl-copy", "--type", "text/uri-list"]
    data = os.path.abspath(args.file) if path else file_uri(args.file) + "\r\n"
    try:
        r = subprocess.run(argv, input=data, text=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return answer(False, "Could not copy the recording")
    return answer(r.returncode == 0, "" if r.returncode == 0 else "Could not copy the recording")


# ---- estado ------------------------------------------------------------------------------------

def read_state():
    try:
        with open(STATE) as f:
            st = json.load(f)
        return st if isinstance(st, dict) else None
    except (OSError, ValueError):
        return None


def write_state(st):
    os.makedirs(RUN, mode=0o700, exist_ok=True)
    st["updated"] = now_ms()
    tmp = STATE + ".%d.tmp" % os.getpid()
    with open(tmp, "w") as f:
        json.dump(st, f)
    os.replace(tmp, STATE)


def proc_start(pid):
    """El instante de arranque del proceso (campo 22 de /proc/<pid>/stat): distingue un PID reutilizado."""
    try:
        with open("/proc/%d/stat" % pid) as f:
            return f.read().rsplit(")", 1)[1].split()[19]
    except (OSError, IndexError):
        return ""


def supervisor_alive(st):
    pid = st.get("pid") if st else None
    if not isinstance(pid, int) or pid <= 0 or not st.get("pidStart"):
        return False
    if proc_start(pid) != st["pidStart"]:
        return False
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            cmd = f.read().split(b"\0")
    except OSError:
        return False
    return any(c.endswith(b"screen-recorder.py") for c in cmd) and b"run" in cmd


def has_parts(work):
    """¿Quedan tramos CON DATOS? Medido en el banco: Matroska escribe por clusters de ~5 s (y wf-recorder 0.6.0 no
    deja cambiarlo), así que un supervisor/wf-recorder matado antes deja el .mkv en 0 bytes: nada que recuperar. Con
    una grabación más larga se recupera todo salvo, como mucho, los últimos ~5 s de cada tramo."""
    try:
        return bool(work) and os.path.isdir(work) and any(
            n.endswith(".mkv") and os.path.getsize(os.path.join(work, n)) > 4096 for n in os.listdir(work))
    except OSError:
        return False


def cmd_status(args):
    st = read_state() or {"state": "idle"}
    if st.get("state") in LIVE and not supervisor_alive(st):
        parts = has_parts(st.get("work"))
        st["state"] = "error"
        st["errorKind"] = "interrupted"
        st["recoverable"] = parts
        st["error"] = "The recorder stopped unexpectedly" + ("; its parts are in " + st["work"] if parts else "")
        write_state(st)
    print(json.dumps(st))
    return 0


SIGNALS = {"pause": signal.SIGUSR1, "resume": signal.SIGUSR2, "stop": signal.SIGTERM, "cancel": signal.SIGHUP}


def cmd_control(args):
    st = read_state()
    if not st or st.get("state") not in LIVE or not supervisor_alive(st):
        print(json.dumps({"ok": False, "error": "Nothing is being recorded"}))
        return 1
    try:
        os.kill(st["pid"], SIGNALS[args.cmd])
    except OSError as e:
        print(json.dumps({"ok": False, "error": str(e)}))
        return 1
    print(json.dumps({"ok": True}))
    return 0


# ---- lo que se ejecuta ---------------------------------------------------------------------------

def even_geometry(g):
    """libx264 con yuv420p pide lados pares: se recortan hacia abajo (mínimo 2)."""
    m = GEOMETRY.match(g.strip())
    if not m:
        return ""
    x, y, w, h = (int(v) for v in m.groups())
    w, h = max(2, w - w % 2), max(2, h - h % 2)
    return "%d,%d %dx%d" % (x, y, w, h)


def video_args(plan):
    """El códec, su calidad (con el parámetro que entiende ESE codificador), los fps y el escalado."""
    eid, v = plan["encoder"], plan["value"]
    if eid == "libx264":
        argv = ["-c", "libx264", "-x", "yuv420p", "-p", "preset=veryfast"]
        argv += (["-p", "b=%d" % (v * 1000000), "-p", "maxrate=%d" % (v * 1500000), "-p", "bufsize=%d" % (v * 2000000)]
                 if plan["quality"] == "bitrate" else ["-p", "crf=%d" % v])
    else:
        # el formato (nv12) lo pone wf-recorder para VAAPI; con -F se le da también aquí
        argv = ["-c", eid, "-d", plan["device"]]
        if plan["quality"] == "bitrate":
            argv += ["-p", "rc_mode=VBR", "-p", "b=%d" % (v * 1000000), "-p", "maxrate=%d" % (v * 1500000)]
        else:
            argv += ["-p", "rc_mode=CQP", "-p", ("global_quality=%d" if eid == "av1_vaapi" else "qp=%d") % v]
    argv += ["-r", str(plan["fps"])]
    sw, sh = plan["source"]
    ow, oh = plan["size"]
    gpu = ENCODERS[eid]["kind"] == "gpu"
    scaled = bool(ow and oh and (ow, oh) != (sw, sh))
    filters = [phase_filter(plan.get("refresh") or 0)]
    if gpu and (scaled or filters[0]):
        # con -F propio wf-recorder ya no pone su `scale_vaapi=format=nv12:out_range=full`: va aquí (la pantalla puede
        # ser de 10 bits y H.264 no los admite: «No usable encoding profile», medido)
        filters.append("scale_vaapi=" + ("w=%d:h=%d:" % (ow, oh) if scaled else "") + "format=nv12:out_range=full")
    elif scaled:
        filters.append("scale=%d:%d" % (ow, oh))
    filters = [f for f in filters if f]
    if filters:
        argv += ["-F", ",".join(filters)]
    return argv


def phase_filter(refresh):
    """`setpts` que deja el primer fotograma a ¼ de periodo de la rejilla del filtro `fps` (que wf-recorder añade
    detrás): ningún fotograma cae en el límite del redondeo y la fluctuación de microsegundos ya no decide cuál se
    toma (medido: 100 fps sobre 200 Hz, del 7 % de pasos irregulares a 0). Los timestamps de wf-recorder van en µs;
    el desplazamiento es < 1 periodo de la pantalla. "" si no se sabe el refresco."""
    if not refresh or refresh < 1:
        return ""
    period = int(round(1e6 / refresh))
    return "setpts=PTS+mod(%d-mod(STARTPTS\\,%d)+%d\\,%d)" % (period // 4, period, period, period)


def wf_argv(plan, mode, target, path, audio_dev):
    # Con CFR, copy_with_damage puede dejar fotogramas viejos en cola al volver de un período estático
    # (reproducido con contador: >1 s repetido y salto de 229 frames). Captura continua para alimentar fps.
    argv = ["wf-recorder", "-y", "-D"] + video_args(plan)
    argv += ["-g", target] if mode == "region" else ["-o", target]
    if audio_dev:
        # FLAC en los tramos y el códec elegido UNA vez al guardar: wf-recorder 0.6.0 no aplica el bitrate de audio
        # (`-P b=…`: AAC sale a 128 kb/s y Opus a 64 kb/s pida lo que se pida; medido con un PipeWire privado en el
        # banco). La frecuencia (`-R`) sí la respeta.
        argv += ["--audio=" + audio_dev, "-C", "flac", "-R", str(plan["sampleRate"])]
    return argv + ["-f", path]


def mic_argv(dev, path, plan):
    return ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-f", "pulse", "-i", dev,
            "-c:a", "flac", "-ar", str(plan["sampleRate"]), "-y", path]


def audio_plan(audio, sources):
    """(dispositivo para wf-recorder, dispositivo del micro aparte, motivo para no empezar)."""
    want_sys = audio in ("system", "both")
    want_mic = audio in ("mic", "both")
    if want_sys and not sources["system"]:
        return None, None, "System audio is not available"
    if want_mic and not sources["mic"]:
        return None, None, "No microphone found"
    if audio == "both":
        return sources["system"], sources["mic"], ""
    return (sources["system"] if want_sys else sources["mic"] if want_mic else ""), "", ""


def file_base(pattern, at_ms, screen):
    """El nombre sin extensión: {date} {time} {screen}; sin barras ni controles, sin empezar por punto."""
    at = datetime.datetime.fromtimestamp((at_ms or now_ms()) / 1000)
    s = (pattern or "").strip() or DEFAULT_NAME
    s = s.replace("{date}", at.strftime("%Y-%m-%d")).replace("{time}", at.strftime("%H-%M-%S"))
    s = s.replace("{screen}", screen or "Screen")
    s = re.sub(r"[\x00-\x1f\x7f/\\]", "-", s)
    s = re.sub(r"\s+", " ", s).strip().lstrip(".").strip()
    return s[:150] or "Recording"


def unique_path(d, base, ext):
    """Nunca se sobrescribe: «nombre (2)», «nombre (3)»…"""
    path, n = os.path.join(d, base + ext), 2
    while os.path.exists(path):
        path, n = os.path.join(d, "%s (%d)%s" % (base, n, ext)), n + 1
    return path


def clock(ms):
    t = int(ms // 1000)
    return "%d:%02d:%02d" % (t // 3600, t // 60 % 60, t % 60) if t >= 3600 else "%02d:%02d" % (t // 60, t % 60)


def probe_ok(path, kind):
    if not path or not os.path.isfile(path) or os.path.getsize(path) == 0:
        return False
    try:
        r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", kind, "-show_entries", "stream=codec_type",
                            "-of", "csv=p=0", path], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return False
    return r.returncode == 0 and r.stdout.strip() != ""


def duration_ms(path):
    try:
        r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                           capture_output=True, text=True, timeout=20)
        return int(float(r.stdout.strip()) * 1000)
    except (OSError, subprocess.SubprocessError, ValueError):
        return 0


def tail(path):
    try:
        lines = [l.strip() for l in open(path, errors="replace") if l.strip()]
    except OSError:
        return ""
    lines = [l for l in lines if not l.startswith(("[libx264", "[Source @", "[swscaler"))]
    return lines[-1][:200] if lines else ""


def part_end(path):
    """Dónde acaba DE VERDAD un tramo: el mayor pts + duración de sus paquetes (todas las pistas), en s; None si no se
    sabe. Matroska declara como duración el ÚLTIMO pts, sin la duración de ese paquete, y el demuxer concat empezaba el
    tramo siguiente justo ahí: tras una pausa, dos fotogramas con el mismo timestamp (medido 2026-11-12)."""
    d = duration_ms(path) / 1000
    for start in ([d - 5] if d > 5 else []) + [None]:
        argv = ["ffprobe", "-v", "error", "-show_entries", "packet=pts_time,duration_time", "-of", "csv=p=0"]
        argv += (["-read_intervals", "%.3f%%" % start] if start is not None else []) + [path]
        try:
            r = subprocess.run(argv, capture_output=True, text=True, timeout=120)
        except (OSError, subprocess.SubprocessError):
            return None
        end = 0.0
        for line in r.stdout.splitlines():
            f = line.split(",")
            try:
                end = max(end, float(f[0]) + (float(f[1]) if len(f) > 1 and f[1] not in ("", "N/A") else 0.0))
            except ValueError:
                continue
        if end > 0:
            return end
    return None


def join_parts(work, segments, plan, screen, started_ms):
    """Une los tramos con vídeo en el contenedor del plan (vídeo sin recodificar; con micro aparte, el audio se
    mezcla y se codifica con lo elegido). → (archivo, nota) o lanza RuntimeError(motivo, tipo)."""
    segs = [s for s in segments if probe_ok(s["video"], "v")]
    if not segs:
        raise RuntimeError("Nothing was recorded: the screen never changed", "nothing")
    mix = any(s.get("mic") for s in segs) and all(probe_ok(s.get("mic"), "a") for s in segs)
    vlist = os.path.join(work, "video.txt")
    with open(vlist, "w") as f:
        for s in segs:
            f.write("file '%s'\n" % s["video"].replace("'", "'\\''"))
            # con varios tramos, cada uno con su final real: sin esto el siguiente se montaba sobre su último fotograma
            end = part_end(s["video"]) if len(segs) > 1 else None
            if end:
                f.write("duration %.6f\n" % end)
    argv = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-f", "concat", "-safe", "0", "-i", vlist]
    audio_out = ["-c:a", plan["audioEncoder"], "-b:a", "%dk" % plan["audioBitrate"], "-ar", str(plan["sampleRate"])]
    if mix:
        mlist = os.path.join(work, "mic.txt")
        with open(mlist, "w") as f:
            for s in segs:
                f.write("file '%s'\n" % s["mic"].replace("'", "'\\''"))
        argv += ["-f", "concat", "-safe", "0", "-i", mlist, "-filter_complex",
                 "[0:a][1:a]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[a]",
                 "-map", "0:v", "-map", "[a]", "-c:v", "copy"] + audio_out
    else:
        # el vídeo sin recodificar; el audio (FLAC en los tramos), con el códec, bitrate y frecuencia elegidos
        argv += ["-map", "0", "-c:v", "copy"] + audio_out
    if plan["codec"] == "h264":
        # wf-recorder 0.6.0 deja AVCodecContext.framerate sin definir: VAAPI puede declarar nivel 4.0
        # incluso a 1080p100/200. Recalcularlo del SPS (fps, tamaño, DPB y HRD), sin recodificar.
        argv += ["-bsf:v", "h264_metadata=level=auto"]
    if plan["codec"] == "hevc" and plan["format"] == "mp4":
        argv += ["-tag:v", "hvc1"]       # el que esperan los reproductores de Apple y los navegadores
    part = os.path.join(work, "joined" + plan["ext"])
    argv += (["-movflags", "+faststart"] if plan["format"] == "mp4" else []) + ["-f", plan["muxer"], part]
    try:
        r = subprocess.run(argv, capture_output=True, text=True)
    except OSError as e:
        raise RuntimeError("Could not save the recording: " + str(e)[:160], "save")
    if r.returncode != 0 or not probe_ok(part, "v"):
        raise RuntimeError("Could not save the recording: " + (r.stderr.strip().splitlines() or ["ffmpeg failed"])[-1][:160], "save")
    try:
        os.makedirs(plan["dir"], exist_ok=True)
        final = unique_path(plan["dir"], file_base(plan["name"], started_ms, screen), plan["ext"])
        os.replace(part, final)
    except OSError as e:
        # otra partición (la carpeta cambió) o sin permiso: se copia y, si tampoco, se dice
        try:
            final = unique_path(plan["dir"], file_base(plan["name"], started_ms, screen), plan["ext"])
            shutil.copyfile(part, final)
            os.unlink(part)
        except OSError:
            raise RuntimeError("Could not write the recording to " + plan["dir"] + ": " + (e.strerror or str(e)), "save")
    # medido (PipeWire privado del banco): si la entrada desaparece a mitad, su ffmpeg no siempre sale y la pista
    # queda ilegible; el vídeo y el sistema se guardan igual
    note = "" if (not any(s.get("mic") for s in segments) or mix) else \
        "The microphone track could not be added (was the microphone disconnected?)"
    return final, note


def parse(argv):
    p = argparse.ArgumentParser(prog="screen-recorder.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    pr = sub.add_parser("probe")
    pr.add_argument("--dir", default="")
    pr.add_argument("--fresh", action="store_true", help="probar otra vez los codificadores")
    for name in ("run", "plan"):
        r = sub.add_parser(name)
        r.add_argument("--token", default="")
        r.add_argument("--mode", choices=("screen", "region", "output"), required=True)
        r.add_argument("--output", default="")
        r.add_argument("--geometry", default="")
        r.add_argument("--audio", choices=("none", "system", "mic", "both"), default="none")
        r.add_argument("--quality", choices=("standard", "high"), default="standard")
        r.add_argument("--preset", choices=("", "standard", "high", "custom"), default="")
        r.add_argument("--encoder", default="auto")
        r.add_argument("--fps", type=int, default=0)
        r.add_argument("--rate-control", choices=TIERS + ("bitrate",), default="high")
        r.add_argument("--bitrate", type=int, default=12)
        r.add_argument("--height", type=int, default=0)
        r.add_argument("--format", choices=tuple(CONTAINERS), default="mp4")
        r.add_argument("--system-source", default="")
        r.add_argument("--mic-source", default="")
        r.add_argument("--audio-codec", choices=tuple(AUDIO_CODECS), default="aac")
        r.add_argument("--audio-bitrate", type=int, default=160)
        r.add_argument("--sample-rate", type=int, default=48000)
        r.add_argument("--name", default=DEFAULT_NAME)
        r.add_argument("--delay", type=int, default=0)
        r.add_argument("--dir", default="")
        # sólo pruebas: otro nodo de render (uno que no existe obliga a volver a x264)
        r.add_argument("--vaapi-device", default="")
    for name in ("pause", "resume", "stop", "cancel", "status", "windows"):
        sub.add_parser(name)
    c = sub.add_parser("copy")
    c.add_argument("file")
    c.add_argument("--as", choices=("uri", "path"), default="uri")
    rv = sub.add_parser("recover")
    rv.add_argument("--work", required=True)
    a = p.parse_args(argv)
    if a.cmd in ("run", "plan"):
        bad = validate(a)
        if bad:
            p.error(bad)
    return a


def validate(a):
    """Lo que no tiene sentido se rechaza al leerlo (los valores llegan de settings.json, ya validados allí)."""
    if a.fps and not 1 <= a.fps <= 240:
        return "--fps must be 1-240"
    if not 1 <= a.bitrate <= 400:
        return "--bitrate must be 1-400 Mb/s"
    if a.height and not 144 <= a.height <= 4320:
        return "--height must be 144-4320"
    if not 32 <= a.audio_bitrate <= 512:
        return "--audio-bitrate must be 32-512 kb/s"
    if a.sample_rate not in (44100, 48000):
        return "--sample-rate must be 44100 or 48000"
    if not (a.encoder in ("auto", "gpu", "cpu") or a.encoder in ENCODERS):
        return "unknown --encoder"
    if len(a.name) > 200:
        return "--name too long"
    return ""


# ---- el supervisor -------------------------------------------------------------------------------

class Supervisor:
    def __init__(self, opts):
        self.o = opts
        self.requests = []
        self.child = None
        self.mic = None
        self.segments = []
        self.wf_audio = self.mic_dev = self.died = ""
        self.plan = None
        self.fallback_note = ""
        # cuándo dejó de grabar el micro aparte (ms de vídeo; -1 = no pasó): desconectado a mitad
        self.mic_lost = -1
        # `window`: la clase de la ventana elegida con un clic ("" = área arrastrada); `encoder`: el id usado
        self.st = {"v": 2, "token": opts.token, "pid": os.getpid(), "pidStart": proc_start(os.getpid()),
                   "state": "starting", "mode": opts.mode, "target": "", "window": "", "audio": opts.audio,
                   "quality": opts.quality, "encoder": "", "dir": out_dir(opts.dir), "work": "", "file": "",
                   "error": "", "errorKind": "", "note": "", "warnings": [], "params": {}, "startedAt": 0,
                   "segmentStart": 0, "elapsedMs": 0, "countdownUntil": 0, "segments": 0, "bytes": 0, "durationMs": 0}

    def set(self, **kw):
        self.st.update(kw)
        write_state(self.st)
        if "state" in kw:
            log("state", kw["state"], kw.get("error", ""))

    def take(self, *names):
        for i, r in enumerate(self.requests):
            if r in names:
                del self.requests[i]
                return r
        return ""

    def wait_or_request(self, until_ms, *names):
        """Espera hasta `until_ms`; devuelve antes la primera petición de `names` que llegue."""
        while now_ms() < until_ms:
            r = self.take(*names)
            if r:
                return r
            time.sleep(0.05)
        return ""

    # -- tramos --

    def start_segment(self):
        why = self.try_segment()
        if why and ENCODERS[self.plan["encoder"]]["kind"] == "gpu" and len(self.segments) == 1 \
                and "h264" in CONTAINERS[self.plan["format"]]["video"]:
            # la GPU no lo aceptó (controlador, tamaño…): el primer tramo otra vez con x264. En Automatic sin decir
            # nada (como en la segunda entrega); un codificador ELEGIDO lo dice al guardar.
            log("gpu failed, using x264:", why)
            if self.plan["preset"] == "custom" and self.o.encoder not in ("auto", "gpu"):
                self.fallback_note = "%s could not start (%s): recorded with H.264 (CPU)" % (self.plan["encoderLabel"], why[:80])
            self.drop_last_segment()
            tier = self.plan["quality"]
            self.plan.update(encoder="libx264", encoderLabel=encoder_label("libx264"), codec="h264", device="",
                             value=self.plan["value"] if tier == "bitrate" else QUALITY["libx264"][tier])
            self.st["encoder"] = "libx264"
            self.st["params"] = params_of(self.plan)
            self.save_plan()
            why = self.try_segment()
        return why

    def try_segment(self):
        n = len(self.segments) + 1
        video = os.path.join(self.st["work"], "seg-%03d.mkv" % n)
        mic = os.path.join(self.st["work"], "seg-%03d.mic.mka" % n) if self.mic_dev else ""
        errf = open(os.path.join(self.st["work"], "seg-%03d.log" % n), "w")
        self.child = subprocess.Popen(wf_argv(self.plan, self.o.mode, self.st["target"], video, self.wf_audio),
                                      stdin=subprocess.DEVNULL, stdout=errf, stderr=errf)
        self.mic = subprocess.Popen(mic_argv(self.mic_dev, mic, self.plan), stdin=subprocess.DEVNULL, stdout=errf,
                                    stderr=errf) if mic else None
        self.segments.append({"video": video, "mic": mic, "log": errf.name, "encoder": self.plan["encoder"]})
        started = now_ms()
        if self.st["startedAt"] == 0:
            self.set(state="starting", segmentStart=started, segments=len(self.segments))
        else:
            # al reanudar se sigue «en pausa» hasta que el tramo grabe: «starting» enseñaba Cancel (tirar TODO)
            self.set(segments=len(self.segments))
        # vivo medio segundo después = grabando; si sale antes, falló al arrancar (salida, región, códec…)
        for _ in range(10):
            if self.child.poll() is not None:
                return tail(errf.name) or "wf-recorder could not start"
            time.sleep(0.05)
        if self.st["startedAt"] == 0:
            self.st["startedAt"] = started
            self.save_plan()
        self.set(state="recording", segmentStart=started)
        return ""

    def drop_last_segment(self):
        """Quita el tramo que no llegó a grabar (sus archivos y su micro, si arrancó)."""
        self.stop_proc(self.mic)
        self.child = self.mic = None
        seg = self.segments.pop()
        for path in (seg["video"], seg["mic"], seg["log"]):
            if path:
                try:
                    os.unlink(path)
                except OSError:
                    pass

    def stop_proc(self, p):
        if not p or p.poll() is not None:
            return
        for sig, wait in ((signal.SIGINT, 2.0), (signal.SIGTERM, 2.0)):
            try:
                p.send_signal(sig)
                p.wait(wait)
                return
            except subprocess.TimeoutExpired:
                continue
            except OSError:
                return
        p.kill()
        p.wait()

    def end_segment(self):
        """Cierra el tramo en curso y suma lo grabado HASTA LA PETICIÓN (no lo que tarde wf-recorder en salir)."""
        asked = now_ms()
        self.stop_proc(self.child)
        self.stop_proc(self.mic)
        self.child = self.mic = None
        if self.st["segmentStart"]:
            self.st["elapsedMs"] += max(0, asked - self.st["segmentStart"])
        self.st["segmentStart"] = 0

    def save_plan(self):
        """Lo necesario para unir los tramos sin este proceso (`recover`), junto a ellos."""
        if not self.st["work"]:
            return
        try:
            with open(os.path.join(self.st["work"], "plan.json"), "w") as f:
                json.dump({"plan": self.plan, "screen": self.screen_name(), "startedAt": self.st["startedAt"]}, f)
        except OSError:
            pass

    def screen_name(self):
        return self.st["target"] if self.o.mode != "region" else ("Window" if self.st["window"] else "Region")

    # -- guardar --

    def save(self):
        self.set(state="saving")
        try:
            final, note = join_parts(self.st["work"], self.segments, self.plan, self.screen_name(), self.st["startedAt"])
        except RuntimeError as e:
            why, kind = e.args
            if kind == "nothing" and self.died:
                # no es que la pantalla no cambiara: wf-recorder se cortó antes de escribir (Matroska escribe por clusters
                # de ~5 s; medido en el banco matándolo a 1,5 s)
                return self.fail("The recording stopped before anything was written (" + self.died[:120] + ")",
                                 keep=False, kind="interrupted")
            return self.fail(why, keep=kind != "nothing", kind=kind)
        if self.mic_lost >= 0 and note:
            note = "The microphone was disconnected at %s: its track was left out" % clock(self.mic_lost)
        if self.fallback_note:
            note = self.fallback_note + ("; " + note if note else "")
        if self.died:
            note = "The recording ended early: " + self.died
        shutil.rmtree(self.st["work"], ignore_errors=True)
        self.set(state="done", file=final, work="", note=note, segmentStart=0, bytes=os.path.getsize(final),
                 durationMs=duration_ms(final))
        return 0

    def fail(self, why, keep=True, kind="failed"):
        if not keep and self.st["work"]:
            shutil.rmtree(self.st["work"], ignore_errors=True)
            self.st["work"] = ""
        elif self.st["work"] and has_parts(self.st["work"]):
            why += "; its parts are in " + self.st["work"]
        self.set(state="error", error=why, errorKind=kind, recoverable=has_parts(self.st["work"]), segmentStart=0)
        return 1

    def cancel(self, why="Cancelled"):
        self.end_segment()
        if self.st["work"]:
            shutil.rmtree(self.st["work"], ignore_errors=True)
        self.set(state="cancelled", work="", note=why, segmentStart=0)
        return 0

    # -- el recorrido --

    def main(self):
        o = self.o
        for sig, name in ((signal.SIGUSR1, "pause"), (signal.SIGUSR2, "resume"), (signal.SIGTERM, "stop"),
                          (signal.SIGINT, "stop"), (signal.SIGHUP, "cancel")):
            signal.signal(sig, lambda s, f, n=name: self.requests.append(n))
        self.set(state="starting")
        if not which("wf-recorder") or not which("ffmpeg") or not which("ffprobe"):
            return self.fail("Install wf-recorder and ffmpeg to record the screen", kind="tools")
        # audio y formato antes de pedir nada al usuario (sin pantalla aún: el plan definitivo va después)
        early = resolve(o, o.output if o.mode == "screen" else "")
        if early["error"] and early["errorKind"] in ("audio", "format"):
            return self.fail(early["error"], kind=early["errorKind"])
        dc = dir_check(o.dir)
        if dc["error"]:
            return self.fail("Can't use the folder " + dc["path"] + ": " + dc["error"] if dc["kind"] == "folder"
                             else dc["error"], kind=dc["kind"])
        try:
            os.makedirs(self.st["dir"], exist_ok=True)
        except OSError as e:
            return self.fail("Can't use the folder " + self.st["dir"] + ": " + (e.strerror or str(e)), kind="folder")

        # qué grabar: la pantalla dada, una elegida con el ratón o una región
        if o.mode == "region" and o.geometry:
            target = even_geometry(o.geometry)
        elif o.mode == "screen":
            target = o.output if OUTPUT.match(o.output or "") else ""
        else:
            if not which("slurp"):
                return self.fail("Install slurp to choose " + ("a region" if o.mode == "region" else "a screen"), kind="tools")
            # en Region, las ventanas visibles como rectángulos: un clic elige una (con su clase en %l)
            boxes = hypr_windows() if o.mode == "region" else []
            self.set(state="selecting")
            log("selecting", o.mode, "windows:", len(boxes))
            argv = ["slurp", "-d", *SLURP_STYLE] if o.mode == "region" else ["slurp", "-o", "-r", "-f", "%o", *SLURP_STYLE]
            sel = subprocess.Popen(argv, stdin=subprocess.PIPE if boxes else subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, text=True)
            if boxes:
                try:
                    sel.stdin.write("\n".join(boxes) + "\n")
                    sel.stdin.close()
                except OSError:
                    pass
            while sel.poll() is None:
                if self.take("cancel", "stop"):
                    sel.terminate()
                    sel.wait()
                    return self.cancel("Selection cancelled")
                time.sleep(0.05)
            out = sel.stdout.read().strip()
            if sel.returncode != 0 or not out:
                return self.cancel("Selection cancelled")
            if o.mode == "region":
                target, self.st["window"] = parse_pick(out, boxes)
            else:
                target = out if OUTPUT.match(out) else ""
        if not target:
            return self.fail("Nothing to record: no screen or region", kind="screen")
        self.st["target"] = target
        self.plan = resolve(o, target)
        if self.plan["error"]:
            return self.fail(self.plan["error"], kind=self.plan["errorKind"])
        self.wf_audio, self.mic_dev = self.plan["wfAudio"], self.plan["micDevice"]
        self.st.update(encoder=self.plan["encoder"], params=params_of(self.plan), warnings=self.plan["warnings"])

        if o.delay > 0:
            self.set(state="countdown", countdownUntil=now_ms() + o.delay * 1000)
            if self.wait_or_request(self.st["countdownUntil"], "cancel", "stop"):
                return self.cancel()
        self.st["work"] = os.path.join(self.st["dir"], ".recording-" + (o.token or str(os.getpid())))
        try:
            os.makedirs(self.st["work"], exist_ok=True)
        except OSError as e:
            self.st["work"] = ""
            return self.fail("Can't write in " + self.st["dir"] + ": " + (e.strerror or str(e)), kind="folder")
        self.save_plan()
        # pausar o reanudar antes de que haya vídeo no significa nada: sólo parar y cancelar siguen en cola
        self.requests = [r for r in self.requests if r in ("stop", "cancel")]
        why = self.start_segment()
        if why:
            return self.fail(why, keep=False, kind="encoder" if ENCODERS[self.plan["encoder"]]["kind"] == "gpu"
                             or "encod" in why.lower() or "codec" in why.lower() else "failed")

        while True:
            r = self.take("pause", "resume", "stop", "cancel")
            if r == "cancel":
                return self.cancel("Recording discarded")
            if r == "stop":
                # «guardando» ya: cerrar el tramo puede tardar (hasta ~4 s si wf-recorder no recibió ni un fotograma)
                self.set(state="saving")
                self.end_segment()
                return self.save()
            if r == "pause" and self.st["state"] == "recording":
                self.end_segment()
                self.set(state="paused")
            elif r == "resume" and self.st["state"] == "paused":
                why = self.start_segment()
                if why:
                    self.died = why
                    self.end_segment()
                    return self.save()
            if self.st["state"] == "recording" and self.mic and self.mic.poll() is not None and self.mic_lost < 0:
                # el micro aparte se cortó (desconectado): el vídeo y el sistema siguen; se dirá al guardar
                self.mic_lost = self.st["elapsedMs"] + max(0, now_ms() - self.st["segmentStart"])
                log("mic stopped at", self.mic_lost, tail(self.segments[-1]["log"]))
            if self.st["state"] == "recording" and self.child and self.child.poll() is not None:
                # se cortó solo (salida desconectada, audio que desaparece, códec…): se guarda lo que haya. Matado por
                # una señal, su registro no dice nada útil (la última línea es la del flujo): se dice la señal
                rc = self.child.returncode
                self.died = ("wf-recorder was stopped by signal %d" % -rc if rc < 0
                             else tail(self.segments[-1]["log"]) or "wf-recorder stopped")
                self.end_segment()
                return self.save()
            time.sleep(0.05)


def cmd_run(opts):
    if opts.token and not TOKEN.match(opts.token):
        print("bad token", file=sys.stderr)
        return 2
    os.makedirs(RUN, mode=0o700, exist_ok=True)
    import fcntl
    fd = os.open(LOCK, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        # otro supervisor vivo: su estado no se toca
        log("refused: another recording is running")
        return 2
    try:
        open(LOG, "w").close()
    except OSError:
        pass
    sup = Supervisor(opts)
    try:
        return sup.main()
    except Exception as e:  # noqa: BLE001 — nunca dejar el estado «vivo» con el supervisor muerto
        log("crash", repr(e))
        sup.end_segment()
        return sup.fail("The recorder failed: " + str(e)[:160])


def cmd_plan(opts):
    target = even_geometry(opts.geometry) if opts.mode == "region" else opts.output
    plan = resolve(opts, target)
    out = dict(plan)
    out["params"] = params_of(plan)
    out["file"] = file_base(plan["name"], now_ms(), opts.output if opts.mode != "region" else "Region") + plan["ext"]
    out["wf"] = wf_argv(plan, opts.mode, target or "?", "seg-001.mkv", plan["wfAudio"]) if plan["encoder"] else None
    out["mic"] = mic_argv(plan["micDevice"], "seg-001.mic.mka", plan) if plan["micDevice"] else None
    print(json.dumps(out))
    return 0


def cmd_probe(args):
    tools = {t: which(t) for t in ("wf-recorder", "slurp", "ffmpeg", "ffprobe", "pactl", "wl-copy", "notify-send", "xdg-open")}
    d = out_dir(args.dir)
    srcs = pulse_sources()
    a = audio_sources(sources=srcs) if srcs else {"system": "", "mic": "", "warnings": []}
    st = encoder_status(fresh=args.fresh) if tools["ffmpeg"] else {k: {"ok": False, "why": "ffmpeg is not installed",
                                                                         "pads": False} for k in ENCODERS}
    version = ""
    if tools["wf-recorder"]:
        m = re.search(r"(\d+(?:\.\d+)+)", run_quiet(["wf-recorder", "--version"]))
        version = m.group(1) if m else ""
    print(json.dumps({
        "v": 2, "tools": tools, "audio": {"system": a["system"], "mic": a["mic"]}, "dir": d, "dirExists": os.path.isdir(d),
        "dirCheck": dir_check(args.dir), "backend": {"name": "wf-recorder", "version": version},
        "encoders": [dict(id=k, label=encoder_label(k), codec=v["codec"], kind=v["kind"], api=v["api"],
                          ok=st[k]["ok"], why=st[k]["why"], pads=bool(st[k].get("pads"))) for k, v in ENCODERS.items()],
        "notOffered": NOT_OFFERED,
        "containers": {k: {"label": v["label"], "video": list(v["video"]), "audio": list(v["audio"])} for k, v in CONTAINERS.items()},
        "sources": {"system": [{"name": s["name"], "label": s["label"]} for s in srcs if s["monitor"]],
                    "mic": [{"name": s["name"], "label": s["label"]} for s in srcs if not s["monitor"]]},
        "screens": [dict(s, smooth=smooth_rates(s["refresh"])) for s in screens_of(hypr_monitors())],
        "pause": "segments", "cursor": "always", "quality": QUALITY,
    }))
    return 0


def cmd_recover(args):
    """Une los tramos de una carpeta de trabajo con su plan.json. Sólo carpetas `.recording-*` con tramos."""
    def answer(ok, **kw):
        print(json.dumps(dict(ok=ok, **kw)))
        return 0 if ok else 1
    work = os.path.abspath(args.work)
    if not os.path.basename(work).startswith(".recording-") or not has_parts(work):
        return answer(False, error="No recording parts in " + work)
    st = read_state()
    if st and st.get("state") in LIVE and supervisor_alive(st) and os.path.abspath(st.get("work") or "") == work:
        return answer(False, error="That recording is still running")
    try:
        with open(os.path.join(work, "plan.json")) as f:
            saved = json.load(f)
        plan, screen, started = saved["plan"], saved.get("screen", ""), saved.get("startedAt", 0)
    except (OSError, ValueError, KeyError):
        # tramos de antes del Grabador 2.0 (sin plan.json): lo de entonces, MP4 con AAC
        plan = {"format": "mp4", "ext": ".mp4", "muxer": "mp4", "codec": "h264", "audioEncoder": "aac",
                "audioBitrate": 192, "sampleRate": 48000, "name": DEFAULT_NAME, "dir": os.path.dirname(work)}
        screen, started = "Screen", int(os.path.getmtime(work) * 1000)
    plan["dir"] = os.path.dirname(work)
    names = sorted(n for n in os.listdir(work) if re.match(r"^seg-\d{3}\.mkv$", n))
    segs = [{"video": os.path.join(work, n), "mic": os.path.join(work, n[:-4] + ".mic.mka")
             if os.path.exists(os.path.join(work, n[:-4] + ".mic.mka")) else ""} for n in names]
    try:
        final, note = join_parts(work, segs, plan, screen, started)
    except RuntimeError as e:
        return answer(False, error=e.args[0], kind=e.args[1])
    shutil.rmtree(work, ignore_errors=True)
    if st and os.path.abspath(st.get("work") or "") == work:
        st.update(state="done", file=final, work="", note=note or "Recovered from its parts", error="", errorKind="",
                  recoverable=False, bytes=os.path.getsize(final), durationMs=duration_ms(final))
        write_state(st)
    return answer(True, file=final, note=note, bytes=os.path.getsize(final), durationMs=duration_ms(final))


def main(argv):
    a = parse(argv)
    if a.cmd == "probe":
        return cmd_probe(a)
    if a.cmd == "run":
        return cmd_run(a)
    if a.cmd == "plan":
        return cmd_plan(a)
    if a.cmd == "status":
        return cmd_status(a)
    if a.cmd == "windows":
        return cmd_windows(a)
    if a.cmd == "copy":
        return cmd_copy(a)
    if a.cmd == "recover":
        return cmd_recover(a)
    return cmd_control(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
