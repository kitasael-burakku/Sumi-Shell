#!/usr/bin/env python3
"""Las miniaturas propias de Sumi Shell (portabilidad F4c, 2026-10-08; HC-04).

Lo usa la shell con `providers.thumbnails` = auto o builtin. Hace lo mismo que el `generate-thumbs.sh` del
rice del autor (que sigue siendo su proveedor `script`, por `thumbs-refresh.service`), con los MISMOS
nombres, tamaño y órdenes, para que la caché sea la misma con uno u otro:

    $XDG_CACHE_HOME/sumi-wallpapers/thumbs/<archivo-con-extensión>.jpg

    thumbnail-provider.py             genera lo que falte o esté viejo y poda lo huérfano (en primer plano)
    thumbnail-provider.py --detach    unidad transitoria con systemd; sin gestor confirmado, proceso
                                      propio con lock heredado. Sobrevive a una recarga y no se duplica
    thumbnail-provider.py --resolve   qué herramientas hay (JSON); no genera nada

Carpetas: las de `$XDG_STATE_HOME/sumi-shell/wallpaper-sources` (las escribe la shell: una por línea,
imágenes y vídeos en cada una), o sin esa lista las dos de siempre (~/Pictures/Wallpapers imágenes,
~/Videos/Wallpapers vídeos). Un nombre repetido en dos carpetas: gana la primera (como el rice).
Imágenes con ImageMagick (`magick`, o `convert`); vídeos con ffmpegthumbnailer, o ffmpeg si no está.
Cada miniatura se escribe en un temporal y se renombra: una generación cortada a medias no deja un JPEG
roto que, por ser más nuevo que el fondo, nunca se rehiciera. El cerrojo es el del rice (`.generate.lock`
en la caché, flock no bloqueante): nunca corren dos generadores sobre la misma caché.
"""
import sys
sys.dont_write_bytecode = True   # 2026-11-07: sin __pycache__ en el árbol de la shell (desinstalar lo dejaba a medias)
import fcntl
import glob
import json
import os
import shutil
import subprocess
import sys
import time
from xdg_paths import base_dir

HOME = os.path.expanduser("~")
RUN = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
CACHE = base_dir("XDG_CACHE_HOME", ".cache")
STATE = base_dir("XDG_STATE_HOME", ".local/state")
THUMB_DIR = os.environ.get("THUMB_DIR") or os.path.join(CACHE, "sumi-wallpapers", "thumbs")
THUMB_SIZE = os.environ.get("THUMB_SIZE") or "320"
SOURCES_FILE = os.environ.get("WALLPAPER_SOURCES_FILE") or os.path.join(STATE, "sumi-shell", "wallpaper-sources")
DIR_IMG = os.environ.get("WALLPAPER_DIR_IMG") or os.path.join(HOME, "Pictures", "Wallpapers")
DIR_VID = os.environ.get("WALLPAPER_DIR_VIDEO") or os.path.join(HOME, "Videos", "Wallpapers")
LOG = os.path.join(RUN, "sumi-thumbs.log")
PREFIX = os.environ.get("SUMI_WALL_UNIT_PREFIX") or "app-sumi-wallpaper-"
IMG = ("jpg", "jpeg", "png", "webp", "gif")
VID = ("mp4", "mkv", "mov", "webm")


def tools():
    im = shutil.which("magick") or shutil.which("convert")
    vid = "ffmpegthumbnailer" if shutil.which("ffmpegthumbnailer") else "ffmpeg" if shutil.which("ffmpeg") else None
    why = "" if im else "ImageMagick is not installed"
    return {"images": os.path.basename(im) if im else None, "imagesBin": im, "videos": vid,
            "why": why, "videosWhy": "" if vid else "ffmpegthumbnailer and ffmpeg are not installed · no video thumbnails"}


def log(msg):
    try:
        with open(LOG, "a") as f:
            f.write("%s %s\n" % (time.strftime("%c"), msg))
    except OSError:
        pass


def sources():
    """[(carpeta, qué)] con qué = img · vid · all, en el orden de Sources."""
    try:
        with open(SOURCES_FILE) as f:
            return [(d, "all") for d in (l.rstrip("\n") for l in f) if d]
    except OSError:
        return [(DIR_IMG, "img"), (DIR_VID, "vid")]


def listing(d, kind):
    """Los archivos de `d` como los ve el rice: un nivel, por extensión sin distinguir mayúsculas."""
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return []
    out = []
    for n in names:
        p = os.path.join(d, n)
        e = n.rsplit(".", 1)[-1].lower() if "." in n else ""
        if not os.path.isfile(p):
            continue
        if e in IMG and kind != "vid":
            out.append((p, "img"))
        elif e in VID and kind != "img":
            out.append((p, "vid"))
    return out


def newer(a, b):
    """`a` más nuevo que `b` (el `-nt` de bash)."""
    try:
        return os.stat(a).st_mtime_ns > os.stat(b).st_mtime_ns
    except OSError:
        return False


def make(src, kind, t):
    name = os.path.basename(src)
    thumb = os.path.join(THUMB_DIR, name + ".jpg")
    tmp = os.path.join(THUMB_DIR, ".tmp-%d-%s.jpg" % (os.getpid(), name))
    if kind == "img":
        argv = [t["imagesBin"], src + "[0]", "-thumbnail", THUMB_SIZE + "x", "-quality", "85", tmp]
    elif t["videos"] == "ffmpegthumbnailer":
        argv = ["ffmpegthumbnailer", "-i", src, "-o", tmp, "-s", THUMB_SIZE, "-q", "8", "-t", "10%"]
    elif t["videos"] == "ffmpeg":
        argv = ["ffmpeg", "-v", "error", "-y", "-ss", "1", "-i", src, "-frames:v", "1",
                "-vf", "scale=%s:-2" % THUMB_SIZE, "-q:v", "4", tmp]
    else:
        return "skip"
    try:
        r = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
        ok = r.returncode == 0 and os.path.isfile(tmp) and os.path.getsize(tmp) > 0
    except (OSError, subprocess.TimeoutExpired):
        ok = False
    if ok:
        os.replace(tmp, thumb)
        return "made"
    try:
        os.unlink(tmp)
    except OSError:
        pass
    log("ERROR %s: %s" % ("imagen" if kind == "img" else "video", src))
    return "error"


def generate():
    t = tools()
    if not t["images"]:
        print("thumbnail-provider: " + t["why"], file=sys.stderr)
        return 1
    os.makedirs(THUMB_DIR, exist_ok=True)
    lock = open(os.path.join(THUMB_DIR, ".generate.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("generate: ya hay un escaneo corriendo, salgo")
        return 0
    # temporales de una ejecución cortada (de nadie más: el cerrojo es nuestro)
    for old in glob.glob(os.path.join(THUMB_DIR, ".tmp-*.jpg")):
        try:
            os.unlink(old)
        except OSError:
            pass
    srcs = sources()
    count = {"made": 0, "skipped": 0, "error": 0, "skip": 0}
    seen = set()
    log("=== thumbnail-provider START ===")
    for d, kind in srcs:
        if not os.path.isdir(d):
            continue
        for src, k in listing(d, kind):
            name = os.path.basename(src)
            if name in seen:
                count["skipped"] += 1
                continue
            seen.add(name)
            thumb = os.path.join(THUMB_DIR, name + ".jpg")
            if os.path.isfile(thumb) and newer(thumb, src):
                count["skipped"] += 1
                continue
            count[make(src, k, t)] += 1
    # poda: miniaturas cuyo archivo ya no está en ninguna carpeta
    pruned = 0
    for thumb in glob.glob(os.path.join(THUMB_DIR, "*.jpg")):
        name = os.path.basename(thumb)[:-4]
        if not any(os.path.isfile(os.path.join(d, name)) for d, _k in srcs):
            try:
                os.unlink(thumb)
                pruned += 1
            except OSError:
                pass
    log("=== thumbnail-provider END | generados=%d saltados=%d errores=%d sin-herramienta=%d podados=%d ==="
        % (count["made"], count["skipped"], count["error"], count["skip"], pruned))
    with open(os.path.join(THUMB_DIR, ".last-scan"), "a"):
        os.utime(os.path.join(THUMB_DIR, ".last-scan"))
    print(json.dumps(dict(count, pruned=pruned)))
    return 0


def detach():
    """En una unidad transitoria de usuario (fuera del cgroup de la shell: una recarga o un restart no la
    cortan). Si ya hay una en marcha, no se lanza otra. Sin gestor de usuario, en segundo plano a pelo."""
    unit = PREFIX + "thumbs"
    me = [sys.executable or "python3", "-B", os.path.abspath(__file__)]
    from user_manager import backend, start_direct_once
    try:
        manager = backend()
    except RuntimeError as e:
        log(str(e))
        print("thumbnail-provider: " + str(e), file=sys.stderr)
        return 1
    if manager == "systemd":
        r = subprocess.run(["systemctl", "--user", "is-active", unit + ".service"], capture_output=True, text=True)
        if r.stdout.strip() in ("active", "activating"):
            print("already running")
            return 0
        env = []
        for k in ("HOME", "PATH", "XDG_RUNTIME_DIR", "XDG_CACHE_HOME", "XDG_STATE_HOME", "THUMB_DIR", "THUMB_SIZE",
                  "WALLPAPER_SOURCES_FILE", "WALLPAPER_DIR_IMG", "WALLPAPER_DIR_VIDEO"):
            if os.environ.get(k):
                env += ["--setenv", "%s=%s" % (k, os.environ[k])]
        r = subprocess.run(["systemd-run", "--user", "--quiet", "--collect", "--unit", unit,
                            "-p", "TimeoutStopSec=30"] + env + ["--"] + me,
                           capture_output=True, text=True, timeout=15)
        if r.returncode == 0:
            print("started " + unit)
            return 0
        log("systemd-run failed: " + (r.stderr or "").strip()[:200])
        return 1
    started = start_direct_once(me, os.path.join(RUN, "sumi-thumbs-detach.lock"))
    print("started" if started else "already running")
    return 0


def main(argv):
    if argv[:1] == ["--resolve"]:
        t = tools()
        t.pop("imagesBin")
        print(json.dumps(t))
        return 0
    if argv[:1] == ["--detach"]:
        if not tools()["images"]:
            print("thumbnail-provider: " + tools()["why"], file=sys.stderr)
            return 1
        return detach()
    if argv:
        print("thumbnail-provider: unknown option: " + argv[0], file=sys.stderr)
        return 1
    return generate()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
