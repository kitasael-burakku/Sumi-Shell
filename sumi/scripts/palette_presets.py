#!/usr/bin/env python3
"""Paletas estáticas (presets congelados), F-a del plan de 2026-11-01 (docs del proyecto: PALETAS-ESTATICAS-*).

Cada preset es `sumi/palettes/<familia>-<variante>.json` (formato 1): los 50 roles de Material 3 que emite matugen,
`dark`, un bloque `terminal` (color0–15, fondo, texto, cursor y selección oficiales de la paleta) y de dónde sale
cada valor (`source`, `mapping`, `derived`). Los construye una vez `tools/palettes/build-presets.py` (proyecto
Quickshell) desde la fuente oficial; aquí NO se deriva ningún color (ADR-12): sólo se carga, se valida y se
traduce.

    palette_presets.py list                   [{id, name, family, variant, dark, sibling}] de los válidos
    palette_presets.py validate [id …]        {"ok", "presets": {id: [errores]}}; sale 1 si alguno falla
    palette_presets.py matugen-json <id>      el JSON que lee `matugen json` (roles en default/dark/light + is_dark_mode)
    palette_presets.py shell-colors <id>      el colors.json de la shell (los 16 tokens de su plantilla), SIN matugen
    palette_presets.py terminal <id>          el bloque terminal

KT_PALETTES_DIR cambia la carpeta (pruebas). Nada de esto escribe archivos: quien instala es theme-preview.py.
"""
import json
import os
import re
import sys

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
SHELL_DIR = os.path.dirname(HERE)
PALETTES = os.environ.get("KT_PALETTES_DIR") or os.path.join(SHELL_DIR, "palettes")
SHELL_TEMPLATE = os.path.join(SHELL_DIR, "templates", "matugen-colors.json")
FORMAT = 1
ID_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)+$")
HEX_RE = re.compile(r"^#[0-9a-f]{6}$")

# Los 50 roles que emite matugen 4.2.0 (`matugen color … --dry-run -j hex`, medido el 2026-11-04).
ROLES = ("background", "error", "error_container", "inverse_on_surface", "inverse_primary", "inverse_surface",
         "on_background", "on_error", "on_error_container", "on_primary", "on_primary_container", "on_primary_fixed",
         "on_primary_fixed_variant", "on_secondary", "on_secondary_container", "on_secondary_fixed",
         "on_secondary_fixed_variant", "on_surface", "on_surface_variant", "on_tertiary", "on_tertiary_container",
         "on_tertiary_fixed", "on_tertiary_fixed_variant", "outline", "outline_variant", "primary", "primary_container",
         "primary_fixed", "primary_fixed_dim", "scrim", "secondary", "secondary_container", "secondary_fixed",
         "secondary_fixed_dim", "shadow", "source_color", "surface", "surface_bright", "surface_container",
         "surface_container_high", "surface_container_highest", "surface_container_low", "surface_container_lowest",
         "surface_dim", "surface_tint", "surface_variant", "tertiary", "tertiary_container", "tertiary_fixed",
         "tertiary_fixed_dim")
TERMINAL = ("foreground", "background", "cursor", "cursor_text_color", "selection_foreground",
            "selection_background") + tuple("color%d" % i for i in range(16))
# Mínimos (WCAG): texto, texto sobre el acento y contorno.
CONTRAST = (("on_surface", "surface", 4.5), ("on_primary", "primary", 4.5), ("outline", "surface", 3.0))


class PresetError(Exception):
    pass


# ---- color ---------------------------------------------------------------------------------------------------------

def rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))


def luminance(h):
    def ch(c):
        c = c / 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (ch(x) for x in rgb(h))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def hsl_lightness(h):
    """La misma medida que `Theme.light` (QColor.hslLightness > 0,5 = paleta clara)."""
    c = [x / 255 for x in rgb(h)]
    return (max(c) + min(c)) / 2


# ---- cargar y validar ----------------------------------------------------------------------------------------------

def path_of(pid):
    if not isinstance(pid, str) or not ID_RE.match(pid):
        raise PresetError("not a preset id: %r" % (pid,))
    return os.path.join(PALETTES, pid + ".json")


def list_ids():
    try:
        names = sorted(os.listdir(PALETTES))
    except OSError:
        return []
    return [n[:-5] for n in names if n.endswith(".json") and ID_RE.match(n[:-5])]


def read(pid):
    p = path_of(pid)
    try:
        with open(p) as f:
            return json.load(f)
    except FileNotFoundError:
        raise PresetError("no preset named %s" % pid)
    except (OSError, ValueError) as e:
        raise PresetError("%s: unreadable (%s)" % (pid, e))


def validate(doc, pid=None):
    """Lista de errores (vacía = válido). Estricta: un rol o clave de terminal de más o de menos invalida."""
    errs = []
    if not isinstance(doc, dict):
        return ["not a JSON object"]
    if doc.get("format") != FORMAT:
        return ["unknown format %r (this shell reads %d)" % (doc.get("format"), FORMAT)]
    if not isinstance(doc.get("id"), str) or not ID_RE.match(doc["id"]):
        errs.append("bad id")
    elif pid is not None and doc["id"] != pid:
        errs.append("id %s does not match the file name %s" % (doc["id"], pid))
    for k in ("name", "family", "variant"):
        if not isinstance(doc.get(k), str) or not doc[k].strip() or len(doc[k]) > 80:
            errs.append("%s must be text" % k)
    if not isinstance(doc.get("dark"), bool):
        errs.append("dark must be true or false")
    sib = doc.get("sibling")
    if sib is not None and (not isinstance(sib, str) or not ID_RE.match(sib)):
        errs.append("bad sibling")
    src = doc.get("source")
    # la paleta sale de una URL pública o (Minimaru) de un archivo del propio proyecto
    where = src.get("palette") if isinstance(src, dict) else None
    if not isinstance(where, dict) or not (str(where.get("url", "")).startswith("https://") or str(where.get("path", "")).strip()) \
            or not str(src.get("license", "")).strip():
        errs.append("source must name the palette URL and its licence")
    roles = doc.get("roles")
    if not isinstance(roles, dict):
        return errs + ["roles missing"]
    missing = [r for r in ROLES if r not in roles]
    extra = [r for r in roles if r not in ROLES]
    if missing:
        errs.append("roles missing: " + ", ".join(missing))
    if extra:
        errs.append("unknown roles: " + ", ".join(sorted(extra)))
    bad = [r for r in ROLES if r in roles and not (isinstance(roles[r], str) and HEX_RE.match(roles[r]))]
    if bad:
        errs.append("not #rrggbb: " + ", ".join(bad))
    term = doc.get("terminal")
    if not isinstance(term, dict):
        errs.append("terminal missing")
    else:
        tm = [k for k in TERMINAL if not (isinstance(term.get(k), str) and HEX_RE.match(term[k]))]
        tx = [k for k in term if k not in TERMINAL]
        if tm:
            errs.append("terminal missing or not #rrggbb: " + ", ".join(tm))
        if tx:
            errs.append("terminal: unknown keys " + ", ".join(sorted(tx)))
    if errs:
        return errs
    light = hsl_lightness(roles["surface"]) > 0.5
    if isinstance(doc.get("dark"), bool) and doc["dark"] == light:
        errs.append("dark is %s but surface %s is %s" % (str(doc["dark"]).lower(), roles["surface"],
                                                          "light" if light else "dark"))
    for fg, bg, want in CONTRAST:
        c = contrast(roles[fg], roles[bg])
        if c < want:
            errs.append("%s on %s is %.2f:1 (needs %.1f)" % (fg, bg, c, want))
    return errs


def load(pid):
    """El preset validado, o PresetError con el motivo."""
    doc = read(pid)
    errs = validate(doc, pid)
    if errs:
        raise PresetError("%s: %s" % (pid, "; ".join(errs)))
    return doc


def load_static(name):
    """Los roles completos de un perfil estático propio (palettes/static/<name>.json: hoy sólo minimaru-dark, para
    los destinos que la lista estática no cubre). Mismo formato y validación que un preset; no se lista como preset."""
    if not ID_RE.match(name):
        raise PresetError("not a palette id: %r" % (name,))
    p = os.path.join(PALETTES, "static", name + ".json")
    try:
        with open(p) as f:
            doc = json.load(f)
    except (OSError, ValueError) as e:
        raise PresetError("%s: unreadable (%s)" % (name, e))
    errs = validate(doc, name)
    if errs:
        raise PresetError("%s: %s" % (name, "; ".join(errs)))
    return doc


def sibling_of(doc):
    """La variante hermana válida (claro ↔ oscuro) o None: un hermano roto no impide usar éste."""
    sib = doc.get("sibling")
    if not sib:
        return None
    try:
        s = load(sib)
    except PresetError:
        return None
    return s if s.get("dark") != doc.get("dark") else None


# ---- traducir --------------------------------------------------------------------------------------------------

def matugen_doc(doc, sibling=None):
    """Lo que lee `matugen json`: cada rol con su color en default (el del preset), dark y light (el de la variante de
    ese modo si existe; si no, el del preset) + `is_dark_mode` (las plantillas lo exigen; medido el 2026-11-01)."""
    dark_roles = doc["roles"] if doc["dark"] or sibling is None else sibling["roles"]
    light_roles = doc["roles"] if not doc["dark"] or sibling is None else sibling["roles"]
    colors = {r: {"default": {"color": doc["roles"][r]}, "dark": {"color": dark_roles[r]},
                  "light": {"color": light_roles[r]}} for r in ROLES}
    return {"colors": colors, "is_dark_mode": bool(doc["dark"])}


SHELL_TOKEN = re.compile(r"\{\{\s*colors\.([a-z_]+)\.default\.hex\s*\}\}")


def shell_colors(doc, template=SHELL_TEMPLATE):
    """El colors.json de la shell con su MISMA plantilla, sin matugen (proveedor sin matugen instalado). La plantilla
    sólo usa `{{colors.<rol>.default.hex}}`; cualquier otra sintaxis se rechaza (mejor nada que medio archivo)."""
    with open(template) as f:
        text = f.read()

    def sub(m):
        if m.group(1) not in doc["roles"]:
            raise PresetError("the shell template uses an unknown role: " + m.group(1))
        return doc["roles"][m.group(1)]
    out = SHELL_TOKEN.sub(sub, text)
    if "{{" in out or "<*" in out:
        raise PresetError("the shell template uses syntax this renderer does not know")
    # el comentario de la plantilla habla de Minimaru y de matugen: aquí no es ninguno de los dos
    out = re.sub(r'"_comment":\s*"(?:[^"\\]|\\.)*"', lambda m: '"_comment": %s' % json.dumps(
        "%s (static palette preset of Sumi Shell, written without matugen)" % doc["name"], ensure_ascii=False), out, count=1)
    json.loads(out)
    return out


# ---- sustituciones por destino (D0-3: el ANSI fiel del preset sin tocar la plantilla del usuario) --------------

def substitution_kind(target):
    """Qué sustitución lleva un destino: «kitty» para un .conf bajo una carpeta kitty/ (colores de kitty); None."""
    parts = os.path.normpath(target).split(os.sep)
    if target.endswith(".conf") and "kitty" in parts[:-1]:
        return "kitty"
    return None


KITTY_LINE = re.compile(r"^(\s*)([a-z_0-9]+)(\s+)(#[0-9a-fA-F]{6})(\s*(?:#.*)?)$")


def substitute(kind, text, terminal):
    """Reescribe los colores de terminal en la salida ya renderizada. kitty: cada línea `clave #hex` de TERMINAL toma
    el valor del preset; las que falten se añaden al final. Lo demás (extendidos, comentarios) queda igual."""
    if kind != "kitty":
        return text
    seen, lines = set(), []
    for line in text.splitlines():
        m = KITTY_LINE.match(line)
        if m and m.group(2) in terminal:
            seen.add(m.group(2))
            line = m.group(1) + m.group(2) + m.group(3) + terminal[m.group(2)] + m.group(5)
        lines.append(line)
    rest = [k for k in TERMINAL if k not in seen]
    if rest:
        lines.append("# terminal colours of the preset (Sumi Shell)")
        lines += ["%s %s" % (k, terminal[k]) for k in rest]
    return "\n".join(lines) + "\n"


# Los roles que enseña una tarjeta del carrusel (los mismos que SAMPLE_ROLES de theme-preview.py)
SAMPLE_ROLES = ("surface", "surface_container", "surface_container_high", "on_surface", "on_surface_variant",
                "primary", "on_primary", "secondary", "tertiary", "outline", "error")


def summary(doc):
    """Lo que lista la shell (F-c): nombre, familia, variante, hermana y las muestras de su tarjeta."""
    return {"id": doc["id"], "name": doc["name"], "family": doc["family"], "familyName": doc.get("familyName", doc["family"]),
            "variant": doc["variant"], "variantName": doc.get("variantName", doc["variant"]), "dark": doc["dark"],
            "sibling": doc.get("sibling"), "samples": {r: doc["roles"][r] for r in SAMPLE_ROLES}}


def main(argv):
    cmd = argv[0] if argv else ""
    if cmd == "list" and len(argv) == 1:
        out = []
        for pid in list_ids():
            try:
                out.append(summary(load(pid)))
            except PresetError:
                continue
        print(json.dumps(out))
        return 0
    if cmd == "validate":
        ids = argv[1:] or list_ids()
        res = {}
        for pid in ids:
            try:
                res[pid] = validate(read(pid), pid)
            except PresetError as e:
                res[pid] = [str(e)]
        ok = bool(ids) and not any(res.values())
        print(json.dumps({"ok": ok, "presets": res}))
        return 0 if ok else 1
    if cmd in ("matugen-json", "shell-colors", "terminal") and len(argv) == 2:
        doc = load(argv[1])
        if cmd == "matugen-json":
            print(json.dumps(matugen_doc(doc, sibling_of(doc)), indent=1))
        elif cmd == "shell-colors":
            sys.stdout.write(shell_colors(doc))
        else:
            print(json.dumps(doc["terminal"]))
        return 0
    raise PresetError("usage: palette_presets.py list | validate [id…] | matugen-json ID | shell-colors ID | terminal ID")


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except PresetError as e:
        print("palette-presets: " + str(e), file=sys.stderr)
        sys.exit(1)
