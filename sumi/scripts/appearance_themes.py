"""Apariencia (2026-11-13) · descubrir temas de iconos y de cursor instalados, sin escribir nada fuera de la caché.

  · Rutas XDG en el orden de GTK/Qt: $XDG_DATA_HOME/icons, ~/.icons y $XDG_DATA_DIRS/icons. Un nombre que aparece en
    varias es UN tema (manda la primera, como en las apps) y se informa de las demás: así se ven las instalaciones
    duplicadas (una copia del usuario que tapa la del sistema).
  · Tema de iconos: index.theme con [Icon Theme] y `Directories` (no oculto). Tema de cursor: carpeta `cursors/` con
    `left_ptr` o `default` (XCursor) o un manifiesto de hyprcursor (manifest.hl/manifest.toml). Un mismo directorio
    puede ser las dos cosas (Adwaita). «default» es el puntero de reserva de XCursor: se describe, no se elige.
  · Familias: los nombres que sólo difieren en el sufijo claro/oscuro (Papirus, Papirus-Dark, Papirus-Light), en el
    tono en medio (Slot-Light-Icons, Slot-Dark-Icons → familia «Slot-Icons», 2026-11-20) o, en Colloid, en
    acento/esquema/claro-oscuro, se agrupan para elegir la VARIANTE aparte.
  · Vista previa: los iconos se buscan siguiendo la herencia del tema (Inherits → … → hicolor) y se devuelven como
    rutas de archivo, sin pasar por el tema de Qt de la shell (que es el que está en uso, no el elegido). Los cursores
    XCursor se convierten a PNG (caché en ~/.cache/sumi-appearance), sin herramientas externas.
"""
import configparser
import hashlib
import os
import re
import struct
import zipfile
import zlib

COLLOID_ACCENTS = ["Purple", "Pink", "Red", "Orange", "Yellow", "Green", "Teal", "Grey"]
COLLOID_SCHEMES = ["Nord", "Dracula", "Gruvbox", "Everforest", "Catppuccin"]
COLLOID_RE = re.compile(r"^Colloid(?:-(%s))?(?:-(%s))?(?:-(Light|Dark))?$"
                        % ("|".join(COLLOID_ACCENTS), "|".join(COLLOID_SCHEMES)))
TONE_RE = re.compile(r"^(.*?)([-_ ])(Light|Dark|light|dark)$")
# El tono como palabra en medio («Slot-Dark-Icons»); sólo si no hay sufijo, que manda (2026-11-20)
TONE_MID_RE = re.compile(r"^(.+?)([-_ ])(Light|Dark|light|dark)([-_ ].+)$")
CURSOR_SAMPLES = [("default", ["left_ptr", "default", "arrow"]), ("pointer", ["pointer", "hand2", "hand1", "pointing_hand"]),
                  ("text", ["text", "xterm", "ibeam"]), ("wait", ["wait", "watch", "progress", "left_ptr_watch"]),
                  ("move", ["grabbing", "fleur", "move", "all-scroll"])]
FALLBACK = "Adwaita"            # el tema de reserva: lo trae GTK (adwaita-icon-theme) y es el que usan sin elección
ICON_SAMPLES = ["folder", "user-home", "text-x-generic", "image-x-generic", "audio-x-generic", "utilities-terminal",
                "web-browser", "preferences-system"]


def data_dirs(env=None):
    env = env or os.environ
    home = env.get("HOME") or os.path.expanduser("~")
    dh = env.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share")
    dirs = [os.path.join(dh, "icons"), os.path.join(home, ".icons")]
    for d in (env.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":"):
        if d:
            dirs.append(os.path.join(d, "icons"))
    out, seen = [], set()
    for d in dirs:
        r = os.path.realpath(d)
        if r not in seen:
            seen.add(r)
            out.append(d)
    return out


def user_dirs(env=None):
    """Las rutas del usuario (las dos primeras): lo que hay ahí es suyo, lo demás es del sistema/paquetes."""
    return data_dirs(env)[:2]


def stamp(env=None):
    """Huella barata de lo instalado: mtime de cada carpeta base (instalar o quitar un tema la cambia)."""
    h = hashlib.sha256()
    for d in data_dirs(env):
        try:
            st = os.stat(d)
            h.update(("%s:%d:%d\n" % (d, st.st_mtime_ns, st.st_ino)).encode())
        except OSError:
            h.update(("%s:-\n" % d).encode())
    return h.hexdigest()[:16]


def read_index(path):
    """[Icon Theme] de un index.theme como dict (claves tal cual), o None si no se puede leer."""
    cp = configparser.RawConfigParser(strict=False, interpolation=None, delimiters=("=",), comment_prefixes=("#", ";"))
    cp.optionxform = str
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            cp.read_file(f)
    except (OSError, configparser.Error, UnicodeDecodeError):
        return None
    if not cp.has_section("Icon Theme"):
        return None
    out = dict(cp.items("Icon Theme"))
    out["_sections"] = {s: dict(cp.items(s)) for s in cp.sections() if s != "Icon Theme"}
    return out


def split_list(v):
    return [x.strip() for x in str(v or "").split(",") if x.strip()]


def has_xcursor(d):
    c = os.path.join(d, "cursors")
    return os.path.isdir(c) and any(os.path.exists(os.path.join(c, n)) for n in ("left_ptr", "default", "arrow"))


def has_hyprcursor(d):
    return os.path.isfile(os.path.join(d, "manifest.hl")) or os.path.isfile(os.path.join(d, "manifest.toml"))


def tone_parts(name):
    """(raíz, separador, tono tal cual, resto) si el nombre lleva Light/Dark como sufijo o como palabra en medio;
    si no, None. «Papirus-Dark» → ("Papirus", "-", "Dark", ""); «Slot-Dark-Icons» → ("Slot", "-", "Dark", "-Icons")."""
    m = TONE_RE.match(name)
    if m:
        return m.group(1), m.group(2), m.group(3), ""
    m = TONE_MID_RE.match(name)
    if m:
        return m.group(1), m.group(2), m.group(3), m.group(4)
    return None


def family_of(name):
    """(familia, variante legible, tono 'light'|'dark'|'') para agrupar y elegir la variante aparte."""
    m = COLLOID_RE.match(name)
    if m:
        accent, scheme, tone = m.group(1), m.group(2), m.group(3)
        bits = [accent or "Default"] + ([scheme] if scheme else []) + ([tone] if tone else ["Mixed"])
        return "Colloid", " ".join(bits), (tone or "").lower()
    t = tone_parts(name)
    if t:
        stem, _sep, tone, rest = t
        return stem + rest, tone.capitalize(), tone.lower()
    return name, "Default", ""


def scan(env=None):
    """{"stamp", "dirs", "icons": [...], "cursors": [...], "families": {...}, "defaultCursor": {...}}."""
    env = env or os.environ
    dirs = data_dirs(env)
    mine = set(os.path.realpath(d) for d in user_dirs(env))
    found = {}
    for base in dirs:
        try:
            names = sorted(os.listdir(base))
        except OSError:
            continue
        for n in names:
            if n.startswith("."):
                continue
            d = os.path.join(base, n)
            if not os.path.isdir(d):
                continue
            e = found.setdefault(n, {"name": n, "paths": []})
            e["paths"].append({"dir": d, "user": os.path.realpath(base) in mine})
    icons, cursors, default_cursor = [], [], None
    for n, e in sorted(found.items(), key=lambda kv: kv[0].casefold()):
        first = e["paths"][0]["dir"]
        idx = None
        for p in e["paths"]:                       # el primer index.theme manda (como en las apps)
            idx = read_index(os.path.join(p["dir"], "index.theme"))
            if idx is not None:
                break
        xc = any(has_xcursor(p["dir"]) for p in e["paths"])
        hc = any(has_hyprcursor(p["dir"]) for p in e["paths"])
        where = "user" if e["paths"][0]["user"] else "system"
        dup = [p["dir"] for p in e["paths"][1:]]
        if n == "default":
            default_cursor = {"inherits": split_list((idx or {}).get("Inherits")), "dir": first,
                              "paths": [p["dir"] for p in e["paths"]]}
            continue
        # Adwaita se marca oculto (es la reserva de GTK) pero se puede elegir; los demás ocultos, no
        if idx is not None and split_list(idx.get("Directories")) and n != "hicolor" \
                and (str(idx.get("Hidden", "")).lower() != "true" or n == FALLBACK):
            fam, variant, tone = family_of(n)
            icons.append({"name": n, "title": idx.get("Name") or n, "inherits": split_list(idx.get("Inherits")),
                          "where": where, "dir": first, "duplicates": dup, "family": fam, "variant": variant,
                          "tone": tone, "dirCount": len(split_list(idx.get("Directories")))})
        if xc or hc:
            sizes = cursor_sizes(e["paths"])
            cursors.append({"name": n, "title": (idx or {}).get("Name") or n, "where": where, "dir": first,
                            "duplicates": dup, "xcursor": xc, "hyprcursor": hc, "sizes": sizes})
    families = {}
    for i in icons:
        families.setdefault(i["family"], []).append(i["name"])
    return {"stamp": stamp(env), "dirs": dirs, "icons": icons, "cursors": cursors, "families": families,
            "defaultCursor": default_cursor, "hicolor": "hicolor" in found}


def counterpart(name, tone, names):
    """El tema hermano con el tono pedido ('light'|'dark') si está instalado; si no, ""."""
    want = tone.capitalize()
    m = COLLOID_RE.match(name)
    if m:
        cand = "Colloid" + "".join("-" + x for x in (m.group(1), m.group(2)) if x) + "-" + want
        return cand if cand in names else ""
    t = tone_parts(name)
    stem, sep, _tone, rest = t if t else (name, "-", "", "")
    for c in (stem + sep + want + rest, stem + sep + want.lower() + rest):
        if c in names:
            return c
    # «Papirus» (sin sufijo) hace de claro si existe «Papirus-Dark»
    if tone == "light" and t and stem + rest in names:
        return stem + rest
    return ""


# ---- vista previa de iconos ---------------------------------------------------------------------------------------

def _theme_dirs(name, env):
    return [os.path.join(b, name) for b in data_dirs(env) if os.path.isdir(os.path.join(b, name))]


def _theme_index(dirs):
    """El index.theme del tema: el de la PRIMERA carpeta base que lo tenga (especificación de freedesktop), y vale para
    todas sus carpetas. Steam deja ~/.local/share/icons/hicolor sin índice propio: sus iconos se encuentran con el de
    /usr/share/icons/hicolor (corregido el 2026-11-14; antes cada carpeta exigía el suyo y la vista previa salía vacía)."""
    for d in dirs:
        idx = read_index(os.path.join(d, "index.theme"))
        if idx:
            return idx
    return None


def lookup_chain(name, env=None, limit=12):
    """El tema y sus herencias (en anchura, sin repetir), terminando en hicolor."""
    env = env or os.environ
    out, queue = [], [name]
    while queue and len(out) < limit:
        n = queue.pop(0)
        if n in out:
            continue
        dirs = _theme_dirs(n, env)
        if not dirs:
            continue
        out.append(n)
        idx = _theme_index(dirs)
        for p in split_list((idx or {}).get("Inherits")):
            if p not in out:
                queue.append(p)
    if "hicolor" not in out:
        out.append("hicolor")
    return out


def _subdirs_by_fit(idx, size):
    """Los subdirectorios del tema, primero los que mejor encajan con `size` (algoritmo de la especificación, simple)."""
    out = []
    secs = (idx or {}).get("_sections", {})
    for sd in split_list((idx or {}).get("Directories")) + split_list((idx or {}).get("ScaledDirectories")):
        s = secs.get(sd, {})
        try:
            nominal = int(s.get("Size", "0"))
            scale = int(s.get("Scale", "1"))
        except ValueError:
            continue
        typ = s.get("Type", "Threshold")
        lo, hi = nominal, nominal
        if typ == "Scalable":
            lo, hi = int(s.get("MinSize", nominal) or nominal), int(s.get("MaxSize", nominal) or nominal)
        elif typ == "Threshold":
            t = int(s.get("Threshold", "2") or 2)
            lo, hi = nominal - t, nominal + t
        dist = 0 if lo <= size <= hi else min(abs(size - lo), abs(size - hi))
        out.append((dist + (0 if scale == 1 else 1000), sd))
    return [sd for _, sd in sorted(out)]


def find_icon(theme, icon, size=48, env=None):
    env = env or os.environ
    for t in lookup_chain(theme, env):
        dirs = _theme_dirs(t, env)
        # como la especificación: subcarpeta (de la que mejor encaja a la peor) y, dentro, cada carpeta base en orden
        for sd in _subdirs_by_fit(_theme_index(dirs), size):
            for d in dirs:
                for ext in (".svg", ".png"):
                    p = os.path.join(d, sd, icon + ext)
                    if os.path.exists(p):
                        return {"path": os.path.realpath(p), "theme": t}
    for ext in (".svg", ".png", ".xpm"):
        p = "/usr/share/pixmaps/" + icon + ext
        if os.path.exists(p):
            return {"path": p, "theme": "pixmaps"}
    return None


def icon_preview(theme, names, size=48, env=None):
    out = []
    for n in names:
        if not re.match(r"^[A-Za-z0-9._+-]{1,120}$", n or ""):
            continue
        hit = find_icon(theme, n, size, env)
        out.append({"name": n, "path": hit["path"] if hit else "", "from": hit["theme"] if hit else ""})
    return out


# ---- cursores -----------------------------------------------------------------------------------------------------

def _xcursor_file(dirs, names):
    for d in dirs:
        for n in names:
            p = os.path.join(d, "cursors", n)
            if os.path.exists(p):
                return os.path.realpath(p)
    return ""


def xcursor_sizes(path):
    try:
        with open(path, "rb") as f:
            head = f.read(16)
            if head[:4] != b"Xcur":
                return []
            hsize, _, ntoc = struct.unpack("<III", head[4:16])
            f.seek(hsize)
            toc = f.read(12 * ntoc)
    except OSError:
        return []
    sizes = set()
    for i in range(ntoc):
        typ, sub, _ = struct.unpack("<III", toc[12 * i:12 * i + 12])
        if typ == 0xfffd0002:
            sizes.add(sub)
    return sorted(sizes)


def cursor_sizes(paths):
    f = _xcursor_file([p["dir"] for p in paths], CURSOR_SAMPLES[0][1])
    return xcursor_sizes(f) if f else []


def xcursor_image(path, size):
    """(w, h, rgba) de la imagen más cercana a `size` (la primera de una animación), o None."""
    with open(path, "rb") as f:
        data = f.read(8 << 20)
    if data[:4] != b"Xcur":
        return None
    hsize, _, ntoc = struct.unpack("<III", data[4:16])
    best = None
    for i in range(ntoc):
        typ, sub, pos = struct.unpack("<III", data[hsize + 12 * i:hsize + 12 * i + 12])
        if typ != 0xfffd0002:
            continue
        key = (abs(sub - size), -sub)
        if best is None or key < best[0]:
            best = (key, pos)
    if best is None:
        return None
    pos = best[1]
    _, typ, _, _, w, h, _, _, _ = struct.unpack("<IIIIIIIII", data[pos:pos + 36])
    if typ != 0xfffd0002 or not (0 < w <= 512 and 0 < h <= 512):
        return None
    px = data[pos + 36:pos + 36 + 4 * w * h]
    if len(px) != 4 * w * h:
        return None
    out = bytearray(4 * w * h)
    for i in range(w * h):
        b, g, r, a = px[4 * i], px[4 * i + 1], px[4 * i + 2], px[4 * i + 3]   # ARGB little-endian, premultiplicado
        if a and a < 255:
            r, g, b = min(255, r * 255 // a), min(255, g * 255 // a), min(255, b * 255 // a)
        out[4 * i:4 * i + 4] = bytes((r, g, b, a))
    return w, h, bytes(out)


def png_bytes(w, h, rgba):
    raw = b"".join(b"\x00" + rgba[y * 4 * w:(y + 1) * 4 * w] for y in range(h))

    def chunk(tag, body):
        c = struct.pack(">I", len(body)) + tag + body
        return c + struct.pack(">I", zlib.crc32(tag + body) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def _hyprcursor_png(dirs, names):
    """Sólo hyprcursor (sin XCursor): la primera imagen PNG del .hlc (un zip), si la hay."""
    for d in dirs:
        for sub in ("hyprcursors", "cursors"):
            for n in names:
                p = os.path.join(d, sub, n + ".hlc")
                if not os.path.isfile(p):
                    continue
                try:
                    with zipfile.ZipFile(p) as z:
                        pngs = sorted(x for x in z.namelist() if x.lower().endswith(".png"))
                        if pngs and z.getinfo(pngs[-1]).file_size < (4 << 20):
                            return z.read(pngs[-1])
                except (OSError, zipfile.BadZipFile):
                    pass
    return None


def cursor_preview(theme, size, cache, env=None):
    env = env or os.environ
    dirs = _theme_dirs(theme, env)
    os.makedirs(cache, mode=0o700, exist_ok=True)
    out = []
    for label, names in CURSOR_SAMPLES:
        path = _xcursor_file(dirs, names)
        item = {"name": label, "path": ""}
        try:
            if path:
                st = os.stat(path)
                key = hashlib.sha256(("%s|%d|%d|%d" % (path, st.st_mtime_ns, st.st_size, size)).encode()).hexdigest()[:20]
                dst = os.path.join(cache, key + ".png")
                if not os.path.exists(dst):
                    img = xcursor_image(path, size)
                    if img:
                        tmp = dst + ".tmp%d" % os.getpid()
                        with open(tmp, "wb") as f:
                            f.write(png_bytes(*img))
                        os.replace(tmp, dst)
                if os.path.exists(dst):
                    item["path"] = dst
            else:
                data = _hyprcursor_png(dirs, names)
                if data:
                    key = hashlib.sha256(("%s|%s|hlc" % (theme, label)).encode() + data).hexdigest()[:20]
                    dst = os.path.join(cache, key + ".png")
                    if not os.path.exists(dst):
                        with open(dst, "wb") as f:
                            f.write(data)
                    item["path"] = dst
        except (OSError, struct.error, ValueError):
            item["path"] = ""
        out.append(item)
    return out
