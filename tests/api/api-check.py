#!/usr/bin/env python3
"""Sumi Shell — comprobar el contrato público (API.md, api/contract-v1.json). Portabilidad F6b, 2026-10-12.

Uso: api-check.py <árbol sumi/> <contract.json> [--live]

Estático (sin shell): lee el código, no lo ejecuta.
  verbs        cada verbo público existe en el IpcHandler `sumi` de core/Ipc.qml con los MISMOS tipos de argumento
               (en orden; los nombres pueden cambiar: el IPC es posicional) y el mismo tipo de retorno
  shortcuts    cada atajo público es un GlobalShortcut de core/Shortcuts.qml con su appid
  catalog      (ayuda de atajos, 2026-10-30) lib/shortcuts.json tiene exactamente los atajos del contrato, cada
               GlobalShortcut toma de él su descripción, y los ejemplos examples/hyprland/sumi.lua y .conf ligan cada
               atajo a SU tecla por defecto, igual que la tabla «Default keys» de API.md (una sola fuente de las teclas:
               el catálogo, que también lee install.sh)
  version      version.json existe, `version` es X.Y.Z y `apiVersion` = la del contrato
  values       los valores garantizados existen en el código: perfiles (services/Modes.qml), esquemas
               (services/Colors.qml), superficies y alias (core/SurfaceHost.qml + core/Screens.qml)
  files        la versión de cada formato público = la VERSION de su esquema
  internal     cada verbo que llaman los scripts, unidades y ejemplos del propio árbol existe (lockNow, notifServer…):
               no es contrato público, pero romperlo rompe la shell
  layers       (vidrio, 2026-11-07) cada namespace de las reglas de capa de examples/hyprland/sumi.lua (las mismas
               que escribe `install.sh hyprland --apply`) existe en una capa del producto, y cada capa visible del producto
               tiene regla: renombrar o añadir una capa sin tocar las reglas la dejaría sin vidrio y sin error
Con --live, además, contra la shell que resuelva `qs -c sumi` en este entorno y SÓLO con verbos de lectura
(api, status, lockStatus, modes): los campos JSON garantizados con su tipo, los valores de `phase`, que `api` diga la
versión de version.json y que los nombres de `open` estén entre las superficies que la shell enseña (más los alias).

Los verbos que no están en el contrato pueden cambiar o desaparecer sin que esto falle (son internos o de diagnóstico).
Salida: una línea por control; código = número de controles fallidos.
"""
import json
import os
import re
import subprocess
import sys

QS_TYPES = {"string", "bool", "int", "real", "void"}
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")


def read(tree, rel):
    with open(os.path.join(tree, rel), encoding="utf-8") as f:
        return f.read()


# Capas del producto que no se ven (o sólo de banco): no llevan regla de vidrio
LAYERS_NOT_DRAWN = {"sumi-shell-reserve", "sumi-shell-inhibit", "sumi-test"}


def layer_problems(tree):
    """Las reglas de capa del ejemplo Lua frente a los WlrLayershell.namespace del producto (QML en subcarpetas: los
    preview-*.qml y sondas de la raíz no son producto)."""
    have = set()
    for d, _, files in os.walk(tree):
        if os.path.abspath(d) == os.path.abspath(tree):
            continue
        for f in files:
            if f.endswith(".qml"):
                have |= set(re.findall(r'WlrLayershell\.namespace:\s*"([^"]+)"', open(os.path.join(d, f), encoding="utf-8").read()))
    example = read(tree, "examples/hyprland/sumi.lua")
    # Vidrio: sólo las reglas con blur cuentan para la cobertura (la de movimiento lo cubre todo y la vaciaría)
    pats = re.findall(r'^hl\.layer_rule\(\{.*?namespace\s*=\s*"([^"]+)".*?blur\s*=\s*true', example, re.M)
    probs = [] if pats else ["no blur layer rule in examples/hyprland/sumi.lua"]
    # Movimiento (2026-11-11): el compositor no anima ninguna capa de la shell; las anima QML (y respeta Off)
    still = re.findall(r'^hl\.layer_rule\(\{.*?namespace\s*=\s*"([^"]+)".*?no_anim\s*=\s*true', example, re.M)
    probs += ["layer %s has no no_anim rule (Hyprland would animate it on top of QML)" % n
              for n in sorted(have) if not any(re.fullmatch(p, n) for p in still)]
    for pat in pats:
        m = re.fullmatch(r"\^?([\w-]*)\(([\w|-]+)\)([\w-]*)\$?", pat)
        names = [m.group(1) + a + m.group(3) for a in m.group(2).split("|")] if m else (
            [pat.strip("^$")] if re.fullmatch(r"\^?[\w-]+\$?", pat) else None)
        if names is None:
            probs.append("layer rule %r: not a name or a ^prefix(a|b)$ list" % pat)
            continue
        probs += ["layer rule names %s, which no layer of the shell uses" % n for n in names if n not in have]
    bare = sorted(n for n in have - LAYERS_NOT_DRAWN if not any(re.fullmatch(p, n) for p in pats))
    probs += ["layer %s has no layer rule" % n for n in bare]
    return probs, len(have - LAYERS_NOT_DRAWN)


def ipc_signatures(tree):
    """{verbo: ([tipos de argumento], retorno)} del IpcHandler con target "sumi"."""
    text = read(tree, "core/Ipc.qml")
    m = re.search(r'IpcHandler\s*\{\s*target:\s*"sumi"', text)
    if not m:
        raise SystemExit("core/Ipc.qml: no IpcHandler with target sumi")
    body = text[m.end():]
    sigs = {}
    for fm in re.finditer(r"^\s*function\s+(\w+)\s*\(([^)]*)\)\s*:\s*(\w+)\s*\{", body, re.M):
        args = [a.strip() for a in fm.group(2).split(",") if a.strip()]
        types = [a.split(":", 1)[1].strip() if ":" in a else "?" for a in args]
        sigs[fm.group(1)] = (types, fm.group(3))
    return sigs


def shortcut_names(tree):
    text = read(tree, "core/Shortcuts.qml")
    # el appid de cada GlobalShortcut: un literal o `root.appId` (la propiedad del archivo)
    prop = re.search(r'property\s+string\s+appId:\s*"([^"]+)"', text)
    appids, names = set(), []
    for block in re.findall(r"GlobalShortcut\s*\{([^}]*)\}", text):
        lit = re.search(r'appid:\s*"([^"]+)"', block)
        ref = re.search(r"appid:\s*root\.appId", block)
        n = re.search(r'name:\s*"([^"]+)"', block)
        if n:
            names.append(n.group(1))
            appids.add(lit.group(1) if lit else (prop.group(1) if ref and prop else "?"))
    return appids, names


def combo(mods, key):
    return (tuple(sorted(m.strip().upper() for m in mods if m.strip())), key.strip().upper())


def catalog_problems(tree, c):
    """Lo que no cuadra entre el catálogo de atajos, el contrato, core/Shortcuts.qml y los dos ejemplos."""
    probs = []
    try:
        cat = json.loads(read(tree, "lib/shortcuts.json"))
        acts = cat["shortcuts"]
        names = [s["name"] for s in acts]
        defaults = {}
        aliases = {}
        for s in acts:
            # etapa C del Dashboard (2026-11-10): un alias no tiene tecla por defecto (ni fila en los ejemplos ni en API.md)
            if s.get("alias"):
                aliases[s["name"]] = s["alias"]
                if s["defaultKeys"].strip():
                    raise ValueError("alias %s has a default key" % s["name"])
                continue
            parts = [x.strip() for x in s["defaultKeys"].split("+")]
            defaults[s["name"]] = combo(parts[:-1], parts[-1])
        bad_alias = sorted(n for n, t in aliases.items() if t not in defaults)
        if bad_alias:
            raise ValueError("alias of an action without a default key: " + ", ".join(bad_alias))
    except (OSError, ValueError, KeyError, TypeError, IndexError) as e:
        return ["lib/shortcuts.json: %s" % e]
    if sorted(names) != sorted(c["shortcuts"]["names"]) or len(set(names)) != len(names):
        probs.append("catalog names ≠ contract")
    if cat.get("appid") != c["shortcuts"]["appid"]:
        probs.append("catalog appid %r" % cat.get("appid"))
    if len(set(defaults.values())) != len(defaults):
        probs.append("two default keys collide")
    text = read(tree, "core/Shortcuts.qml")
    for block in re.findall(r"GlobalShortcut\s*\{([^}]*)\}", text):
        n = re.search(r'name:\s*"(\w+)"', block)
        if n and not re.search(r'description:\s*Keybinds\.description\("%s"\)' % n.group(1), block):
            probs.append("Shortcuts.qml %s: description not from the catalog" % n.group(1))
    lua = {n: combo(k.split("+")[:-1], k.split("+")[-1]) for k, n in
           re.findall(r'^shell\("([^"]+)", "(\w+)"\)', read(tree, "examples/hyprland/sumi.lua"), re.M)}
    conf = {n: combo(m.split(), k) for m, k, n in
            re.findall(r"^bind\s*=\s*([^,]*),\s*([^,]+),\s*global,\s*sumi:(\w+)\s*$",
                       read(tree, "examples/hyprland/sumi.conf"), re.M)}
    api_md = os.path.join(os.path.dirname(os.path.abspath(tree)), "API.md")
    api = None
    if os.path.exists(api_md):     # la tabla «Default keys» de API.md (en la raíz de la distribución)
        rows = re.findall(r"^\| `(\w+)` \| ([^|]+) \| ([^|]+) \| `([^`]+)` \|$", open(api_md, encoding="utf-8").read(), re.M)
        api = {n: combo(k.split("+")[:-1], k.split("+")[-1]) for n, _, _, k in rows}
        cats = {x["id"]: x["title"] for x in cat.get("categories", [])}
        shown = {s["name"]: (s["title"], cats.get(s["category"])) for s in acts}
        bad = sorted(n for n, ti, ca, _ in rows if shown.get(n) != (ti.strip(), ca.strip()))
        if bad:
            probs.append("API.md titles/categories ≠ catalog: " + ", ".join(bad))
    for label, have in (("sumi.lua", lua), ("sumi.conf", conf)) + ((("API.md", api),) if api is not None else ()):
        bad = sorted(n for n in set(defaults) | set(have) if have.get(n) != defaults.get(n))
        if bad:
            probs.append("%s ≠ catalog: %s" % (label, ", ".join(bad)))
    return probs


def js_array(text, prop):
    m = re.search(r"property\s+var\s+%s:\s*\[([^\]]*)\]" % re.escape(prop), text)
    return re.findall(r'"([^"]+)"', m.group(1)) if m else []


def surfaces(tree):
    host = read(tree, "core/SurfaceHost.qml")
    m = re.search(r"readonly property var registry:\s*\(\{(.*?)\n    \}\)", host, re.S)
    names = re.findall(r"^\s{8}(\w+):\s*\{", m.group(1), re.M) if m else []
    scr = read(tree, "core/Screens.qml")
    am = re.search(r"readonly property var aliases:\s*\(\{([^}]*)\}\)", scr)
    aliases = dict(re.findall(r'(\w+):\s*"(\w+)"', am.group(1))) if am else {}
    # Settings UI (2026-11-07): los tres nombres de Settings dejaron el registro del island y los atiende la
    # ventana flotante (`Screens.isSettings` + el mapa de `settingsOpenOn`); siguen siendo nombres de `open`
    if "function isSettings(" in scr:
        sm = re.search(r"function settingsOpenOn\(.*?\(\{([^}]*)\}\)", scr, re.S)
        names += [n for n in (re.findall(r'\w+:\s*"(\w+)"', sm.group(1)) if sm else []) if n not in names]
    # Etapa B del Dashboard (2026-11-09): `tasks` dejó de ser alias del Dashboard; lo atiende la ventana flotante
    # (`Screens.isTasks` + `Screen.showTasks`) y sigue siendo un nombre de `open`
    if "function isTasks(" in scr and "tasks" not in names:
        names.append("tasks")
    # Login screen (Sumi SDDM, 2026-11-23): `login` es la ventana flotante (`Screens.isLogin` + `Screen.showLogin`)
    if "function isLogin(" in scr and "login" not in names:
        names.append("login")
    return names, aliases


def schema_version(tree, rel):
    m = re.search(r"^var VERSION\s*=\s*(\d+);", read(tree, rel), re.M)
    return int(m.group(1)) if m else None


def internal_calls(tree):
    """Verbos que el propio árbol pide desde fuera de QML (scripts/, systemd/, examples/)."""
    calls = {}
    pat = re.compile(r"(?:ipc\s+call\s+sumi|shell_ipc)\s+[\"']?(\w+)")
    for sub in ("scripts", "systemd", "examples"):
        for folder, _, files in os.walk(os.path.join(tree, sub)):
            for n in files:
                p = os.path.join(folder, n)
                try:
                    text = open(p, encoding="utf-8", errors="replace").read()
                except OSError:
                    continue
                for m in pat.finditer(text):
                    calls.setdefault(m.group(1), set()).add(os.path.relpath(p, tree))
    return calls


def jtype(v):
    return {bool: "boolean", int: "number", float: "number", str: "string"}.get(type(v), type(v).__name__)


def main():
    args = [a for a in sys.argv[1:] if a != "--live"]
    live = "--live" in sys.argv[1:]
    if len(args) != 2:
        raise SystemExit(__doc__)
    tree, contract_path = args
    with open(contract_path) as f:
        c = json.load(f)
    fails = []

    def check(name, ok, detail=""):
        print("%-10s %s %s" % (name, "PASS" if ok else "FAIL", detail))
        if not ok:
            fails.append(name)

    sigs = ipc_signatures(tree)
    for verb, spec in c["ipc"]["verbs"].items():
        want = ([t for _, t in spec["args"]], spec["returns"])
        have = sigs.get(verb)
        check("verbs", have == want, "%s%s → %s" % (verb, want[0], "missing" if have is None else
                                                     ("ok" if have == want else "found %s → %s" % have)))
    print("           (%d verbs in the handler, %d public)" % (len(sigs), len(c["ipc"]["verbs"])))

    appids, names = shortcut_names(tree)
    missing = [n for n in c["shortcuts"]["names"] if n not in names]
    check("shortcuts", c["shortcuts"]["appid"] in appids and not missing,
          "appid %s · %d/%d%s" % (sorted(appids), len(c["shortcuts"]["names"]) - len(missing),
                                  len(c["shortcuts"]["names"]), (" · missing " + ", ".join(missing)) if missing else ""))

    lprobs, nl = layer_problems(tree)
    check("layers", not lprobs, "examples/hyprland/sumi.lua blur rules ↔ %d drawn layers, no_anim on all%s" % (
        nl, (" · " + "; ".join(lprobs)) if lprobs else ""))

    probs = catalog_problems(tree, c)
    check("catalog", not probs, "lib/shortcuts.json = contract, Shortcuts.qml, both examples and API.md%s" % (
        (" · " + "; ".join(probs)) if probs else ""))

    try:
        v = json.loads(read(tree, "version.json"))
        ok = isinstance(v.get("version"), str) and bool(SEMVER.match(v["version"])) and v.get("apiVersion") == c["apiVersion"]
        check("version", ok, "version.json %s · apiVersion %s (contract %s)" % (v.get("version"), v.get("apiVersion"),
                                                                           c["apiVersion"]))
    except (OSError, ValueError) as e:
        v = {}
        check("version", False, "version.json: %s" % e)
    # F6f: los campos que lee `install.sh update`. settingsSchema = el VERSION del ConfigStore (una sola verdad comprobada)
    m = re.search(r"^var VERSION = (\d+);", read(tree, "lib/settings-schema.js") or "", re.M)
    r = v.get("restart")
    ok = (m is not None and v.get("settingsSchema") == int(m.group(1)) and isinstance(v.get("minUpdateFrom"), str)
          and bool(SEMVER.match(v["minUpdateFrom"])) and isinstance(r, dict) and isinstance(r.get("required"), bool))
    check("update", ok, "settingsSchema %s (settings-schema.js %s) · minUpdateFrom %s · restart %s" % (
        v.get("settingsSchema"), m.group(1) if m else "?", v.get("minUpdateFrom"), r))

    modes = js_array(read(tree, "services/Modes.qml"), "modes")
    schemes = js_array(read(tree, "services/Colors.qml"), "schemes") + ["static"]
    reg, aliases = surfaces(tree)
    # paletas estáticas: los presets garantizados son archivos de sumi/palettes/
    try:
        presets = [n[:-5] for n in os.listdir(os.path.join(tree, "palettes")) if n.endswith(".json")]
    except OSError:
        presets = []
    checks_values = [("mode", "profile", modes), ("themeSet", "name", schemes), ("open", "name", reg + list(aliases))]
    if "themePreset" in c["ipc"]["verbs"]:
        checks_values.append(("themePreset", "name", presets))
    for verb, key, have in checks_values:
        want = c["ipc"]["verbs"][verb]["values"][key]
        miss = [x for x in want if x not in have]
        check("values", not miss, "%s %s: %d/%d%s" % (verb, key, len(want) - len(miss), len(want),
                                                       (" · missing " + ", ".join(miss)) if miss else ""))

    for fname, spec in c.get("files", {}).items():
        rel = spec["schema"].split("/", 1)[1] if spec["schema"].startswith("sumi/") else spec["schema"]
        have = schema_version(tree, rel)
        check("files", have == spec["version"], "%s v%s (schema %s)" % (fname, spec["version"], have))

    calls = internal_calls(tree)
    gone = {k: sorted(v) for k, v in calls.items() if k not in sigs}
    check("internal", not gone, "%d verbs used by the tree's own scripts%s" % (
        len(calls), (" · missing " + json.dumps(gone)) if gone else ": " + ", ".join(sorted(calls))))

    if live:
        def call(verb):
            p = subprocess.run(["qs", "-c", "sumi", "ipc", "call", "sumi", verb], capture_output=True, text=True,
                               timeout=10)
            return p.returncode, p.stdout.strip() or p.stderr.strip()
        got = {}
        for verb in ("api", "status", "lockStatus", "modes"):
            rc, out = call(verb)
            try:
                got[verb] = json.loads(out)
            except ValueError:
                check("live", False, "%s: %s" % (verb, out[:120]))
                continue
            spec = c["ipc"]["verbs"][verb]
            bad = [k for k, t in spec.get("json", {}).items() if jtype(got[verb].get(k)) != t]
            check("live", not bad, "%s fields %s%s" % (verb, sorted(spec.get("json", {})),
                                                        (" · wrong " + ", ".join(bad)) if bad else ""))
        if "lockStatus" in got:
            ph = got["lockStatus"].get("phase")
            check("live", ph in c["ipc"]["verbs"]["lockStatus"]["values"]["phase"], "lockStatus phase %r" % ph)
        if "api" in got and v:
            check("live", got["api"].get("version") == v.get("version") and got["api"].get("apiVersion") == c["apiVersion"],
                  "api says %s / %s" % (got["api"].get("version"), got["api"].get("apiVersion")))
        if "status" in got:
            shown = set(got["status"].get("surfaces", [])) | set(aliases)
            miss = [x for x in c["ipc"]["verbs"]["open"]["values"]["name"] if x not in shown]
            check("live", not miss, "open names among the shell's surfaces%s" % ((" · missing " + ", ".join(miss))
                                                                                  if miss else ""))
    print("failed: %d" % len(fails))
    return len(fails)


if __name__ == "__main__":
    sys.exit(main())
