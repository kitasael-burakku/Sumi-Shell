#!/usr/bin/env python3
"""Lectura de la configuración de Hyprland para Settings → System (fases 14A y 14C).

Sólo LEE: desde el 2026-09-29 Hyprland, Input y Displays son INFORMACIÓN (decisión del usuario:
Settings dice qué vale cada cosa y en qué archivo y línea vive; se edita a mano). Tres partes:

  dónde  La configuración no se da por supuesta: se BUSCA la del Hyprland que corre. Su proceso
         (`hyprctl instances` → pid) dice si arrancó con `--config` / `-c`; si no, su entorno dice
         XDG_CONFIG_HOME (o HOME/.config) y dentro, `hypr/hyprland.lua` o `hypr/hyprland.conf`.
         Los `require` se resuelven desde la carpeta de ese archivo (el package.path medido de
         Hyprland 0.56.2 es `<carpeta>/?.lua;<carpeta>/?/init.lua`).

  scan   Recorre hyprland.lua siguiendo sus `require` (y `pcall(require, …)`) en el orden en
         que Hyprland los ejecuta y apunta, para cada clave de `hl.config`, `hl.device` y
         `hl.monitor`, el archivo, la línea y el valor LITERAL escrito. No ejecuta nada del Lua:
         lo tokeniza. Un valor que no es literal (una llamada, una concatenación) se apunta como
         expresión, sin evaluarlo.
  read   Lo mismo más lo EFECTIVO: un solo `hyprctl --batch` con getoption de las claves pedidas,
         monitores (todos), dispositivos y versión.

Uso:
  hypr-config.py where
  hypr-config.py scan
  hypr-config.py read general:gaps_out input:sensitivity …

Salida: un JSON en stdout. Errores: {"error": "…"} y código 1.
Entorno para pruebas: SUMI_HYPR_DIR (fuerza la carpeta, sin buscar), SUMI_HYPRCTL (hyprctl
falso), SUMI_PROC (un /proc falso).

Medido en Hyprland 0.56.2 (2026-09-28/29): `getoption` no conoce las opciones por dispositivo y
`hl.get_config` las da como nil, así que lo de un `hl.device` sólo se puede saber leyendo el
archivo: por eso este escaneo existe.
"""
import json
import os
import re
import subprocess
import sys

HYPRCTL = os.environ.get("SUMI_HYPRCTL", "hyprctl")
PROC = os.environ.get("SUMI_PROC", "/proc")
HYPR = ""          # la carpeta de la configuración; la fija locate()


# ---- dónde vive la configuración -----------------------------------------------------------

def _read(path, mode="r"):
    try:
        with open(path, mode) as f:
            return f.read()
    except OSError:
        return None


def hyprland_pid():
    """El pid del Hyprland de esta sesión (hyprctl instances, casando la firma)."""
    try:
        out = subprocess.run([HYPRCTL, "instances", "-j"], capture_output=True, text=True, timeout=3).stdout
        inst = json.loads(out)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return 0
    if not isinstance(inst, list) or not inst:
        return 0
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    mine = [i for i in inst if isinstance(i, dict) and i.get("instance") == sig] or inst
    try:
        return int(mine[0].get("pid", 0))
    except (TypeError, ValueError):
        return 0


def locate():
    """{main, dir, kind: lua|conf|missing, from: override|cmdline|environment|default, pid}."""
    forced = os.environ.get("SUMI_HYPR_DIR")
    pid, how, main, base = 0, "", "", ""
    if forced:
        how, base = "override", os.path.expanduser(forced)
    else:
        pid = hyprland_pid()
        raw = _read(os.path.join(PROC, str(pid), "cmdline"), "rb") if pid else None
        args = raw.decode("utf-8", "replace").split("\0") if raw else []
        for i, a in enumerate(args):
            val = None
            if a in ("--config", "-c") and i + 1 < len(args):
                val = args[i + 1]
            elif a.startswith("--config="):
                val = a.split("=", 1)[1]
            if val:
                if not os.path.isabs(val):
                    cwd = ""
                    try:
                        cwd = os.readlink(os.path.join(PROC, str(pid), "cwd"))
                    except OSError:
                        pass
                    val = os.path.join(cwd or os.getcwd(), val)
                how, main = "cmdline", os.path.normpath(os.path.expanduser(val))
                break
        if not main:
            env = {}
            rawenv = _read(os.path.join(PROC, str(pid), "environ"), "rb") if pid else None
            for kv in (rawenv or b"").split(b"\0"):
                k, _, v = kv.decode("utf-8", "replace").partition("=")
                if k:
                    env[k] = v
            if env.get("XDG_CONFIG_HOME"):
                how, cfg = "environment", env["XDG_CONFIG_HOME"]
            else:
                how = "default"
                cfg = os.path.join(env.get("HOME") or os.path.expanduser("~"), ".config")
            base = os.path.join(cfg, "hypr")
    if main:
        base = os.path.dirname(main)
    else:
        lua, conf = os.path.join(base, "hyprland.lua"), os.path.join(base, "hyprland.conf")
        main = lua if os.path.isfile(lua) or not os.path.isfile(conf) else conf
    kind = "missing" if not os.path.isfile(main) else "lua" if main.endswith(".lua") else "conf"
    return {"main": main, "dir": base, "kind": kind, "from": how, "pid": pid,
            "home": os.path.expanduser("~")}

# ---- tokenizador de Lua (lo justo para tablas literales) -----------------------------------

TOKEN = re.compile(r"""
    (?P<ws>[ \t\r]+)
  | (?P<nl>\n)
  | (?P<lcomment>--\[(?P<leq>=*)\[)
  | (?P<comment>--[^\n]*)
  | (?P<lstring>\[(?P<seq>=*)\[)
  | (?P<string>"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')
  | (?P<number>0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)
  | (?P<name>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<op>\.\.\.|\.\.|==|~=|<=|>=|::|[{}()\[\]=,;.:+\-*/%^#<>~&|])
""", re.VERBOSE)


def tokenize(text):
    out, i, line = [], 0, 1
    while i < len(text):
        m = TOKEN.match(text, i)
        if not m:
            raise ValueError("line %d: unexpected character %r" % (line, text[i]))
        kind = m.lastgroup
        if kind in ("leq", "seq"):
            kind = "lcomment" if m.group("lcomment") else "lstring"
        if kind == "nl":
            line += 1
        elif kind in ("lcomment", "lstring"):
            eq = m.group("leq") if kind == "lcomment" else m.group("seq")
            close = "]" + (eq or "") + "]"
            end = text.find(close, m.end())
            if end < 0:
                raise ValueError("line %d: unterminated long bracket" % line)
            body = text[m.end():end]
            if kind == "lstring":
                out.append(("string", body, line))
            line += body.count("\n")
            i = end + len(close)
            continue
        elif kind not in ("ws", "comment"):
            out.append((kind, m.group(0), line))
        i = m.end()
    return out


def unquote(tok):
    s = tok[1]
    if tok[0] != "string" or s[:1] not in "\"'":
        return s
    body = s[1:-1]
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), body)


class Parser:
    def __init__(self, toks):
        self.t = toks
        self.i = 0

    def peek(self, k=0):
        j = self.i + k
        return self.t[j] if j < len(self.t) else ("eof", "", 0)

    def skip_expr(self):
        """Salta una expresión hasta `,` `;` o el cierre de su nivel; devuelve su texto."""
        depth, parts = 0, []
        while True:
            k, v, _ = self.peek()
            if k == "eof":
                break
            if depth == 0 and (v in (",", ";") or v in ("}", ")", "]")):
                break
            if v in ("{", "(", "["):
                depth += 1
            elif v in ("}", ")", "]"):
                depth -= 1
            parts.append(v)
            self.i += 1
        return " ".join(parts)

    def value(self):
        k, v, line = self.peek()
        if v == "{":
            return self.table()
        # literal simple (o con signo), sólo si lo siguiente cierra el campo
        start = self.i
        neg = False
        if v == "-" and self.peek(1)[0] == "number":
            neg = True
            self.i += 1
            k, v, line = self.peek()
        nk = self.peek(1)[1]
        if k in ("number", "string") or (k == "name" and v in ("true", "false", "nil")):
            if nk in (",", ";", "}", ")"):
                self.i += 1
                if k == "number":
                    n = int(v, 16) if v.lower().startswith("0x") else float(v)
                    if isinstance(n, float) and n.is_integer() and "." not in v and "e" not in v.lower():
                        n = int(n)
                    return {"lit": -n if neg else n}
                if k == "string":
                    return {"lit": unquote(self.t[self.i - 1])}
                return {"lit": {"true": True, "false": False, "nil": None}[v]}
        self.i = start
        return {"expr": self.skip_expr()}

    def table(self):
        """Tabla literal → {"table": {clave: valor}, "list": [valores], "line": n}."""
        _, _, line = self.peek()
        self.i += 1  # {
        fields, items = {}, []
        while True:
            k, v, l = self.peek()
            if k == "eof":
                raise ValueError("line %d: unterminated table" % line)
            if v == "}":
                self.i += 1
                break
            if v in (",", ";"):
                self.i += 1
                continue
            if k == "name" and self.peek(1)[1] == "=" and self.peek(2)[1] != "=":
                self.i += 2
                val = self.value()
                val["line"] = l
                fields[v] = val
            elif v == "[":
                # [expr] = valor: la clave no es literal, se salta
                self.i += 1
                self.skip_expr()
                if self.peek()[1] == "]":
                    self.i += 1
                if self.peek()[1] == "=":
                    self.i += 1
                    self.value()
            else:
                val = self.value()
                val["line"] = l
                items.append(val)
        out = {"table": fields, "line": line}
        if items:
            out["list"] = items
        return out


def plain(v):
    """Un valor del parser a JSON simple (tablas → dict/list; expresiones → {"expr": …})."""
    if "lit" in v:
        return v["lit"]
    if "expr" in v:
        return {"expr": v["expr"]}
    if v.get("list") and not v["table"]:
        return [plain(x) for x in v["list"]]
    return {k: plain(x) for k, x in v["table"].items()}


def flatten(prefix, v, out):
    """Hojas de una tabla de hl.config → [(ruta, valor, línea)]. Listas y literales son hojas."""
    if "table" in v and v["table"] and not v.get("list"):
        for k, x in v["table"].items():
            flatten(prefix + "." + k if prefix else k, x, out)
    else:
        out.append((prefix, plain(v), v.get("line", 0)))


# ---- recorrido en orden de require -------------------------------------------------------

def module_path(mod):
    base = os.path.join(HYPR, *mod.split("."))
    for cand in (base + ".lua", os.path.join(base, "init.lua")):
        if os.path.isfile(cand):
            return cand
    return None


def rel(path):
    return os.path.relpath(path, HYPR)


class Scan:
    def __init__(self):
        self.order = 0
        self.files = []        # en orden de carga
        self.loaded = set()
        self.options = {}      # ruta → [{file, line, value, order}]
        self.devices = {}      # nombre → {clave: [{file, line, value, order}]}
        self.monitors = []     # [{file, line, fields, order}]
        self.requires = []     # [{file, line, module, protected, found}]
        self.errors = []

    def event(self):
        self.order += 1
        return self.order

    def load(self, path):
        if path in self.loaded:
            return
        self.loaded.add(path)
        self.files.append(rel(path))
        try:
            with open(path, encoding="utf-8") as f:
                toks = tokenize(f.read())
        except (OSError, ValueError) as e:
            self.errors.append({"file": rel(path), "error": str(e)})
            return
        p = Parser(toks)
        while p.i < len(toks):
            k, v, line = p.peek()
            # require("x") / require "x" / pcall(require, "x")
            if k == "name" and v == "require":
                j = 1
                if p.peek(1)[1] == "(":
                    j = 2
                if p.peek(j)[0] == "string":
                    self.do_require(path, line, unquote(p.peek(j)), False)
                p.i += 1
                continue
            if k == "name" and v == "pcall" and p.peek(1)[1] == "(" and p.peek(2)[1] == "require" \
                    and p.peek(3)[1] == "," and p.peek(4)[0] == "string":
                self.do_require(path, line, unquote(p.peek(4)), True)
                p.i += 5
                continue
            # hl.config({…}) / hl.device({…}) / hl.monitor({…})
            if k == "name" and v == "hl" and p.peek(1)[1] == "." and p.peek(2)[1] in ("config", "device", "monitor") \
                    and p.peek(3)[1] == "(" and p.peek(4)[1] == "{":
                what = p.peek(2)[1]
                p.i += 4
                try:
                    tbl = p.table()
                except ValueError as e:
                    self.errors.append({"file": rel(path), "error": str(e)})
                    return
                self.record(path, what, tbl)
                continue
            p.i += 1

    def do_require(self, path, line, mod, protected):
        target = module_path(mod)
        self.requires.append({"file": rel(path), "line": line, "module": mod, "protected": protected,
                              "found": target is not None})
        if target:
            self.load(target)

    def record(self, path, what, tbl):
        order = self.event()
        where = {"file": rel(path), "line": tbl["line"], "order": order}
        if what == "config":
            leaves = []
            flatten("", tbl, leaves)
            for key, val, line in leaves:
                self.options.setdefault(key, []).append(dict(where, line=line or tbl["line"], value=val))
        elif what == "device":
            fields = {k: plain(x) for k, x in tbl["table"].items()}
            name = fields.pop("name", None)
            if not isinstance(name, str):
                name = {"expr": "name"}
            dev = self.devices.setdefault(name if isinstance(name, str) else json.dumps(name), {})
            for k, val in fields.items():
                dev.setdefault(k, []).append(dict(where, line=tbl["table"][k].get("line", tbl["line"]), value=val))
        else:
            self.monitors.append(dict(where, fields={k: plain(x) for k, x in tbl["table"].items()}))

    def result(self):
        return {
            "root": HYPR,
            "files": self.files,
            "options": self.options,
            "devices": self.devices,
            "monitors": self.monitors,
            "requires": self.requires,
            "errors": self.errors,
        }


def scan():
    global HYPR
    loc = locate()
    HYPR = loc["dir"]
    if loc["kind"] == "missing":
        return {"error": "No Hyprland configuration in " + loc["dir"], "config": loc}
    if loc["kind"] == "conf":
        # hyprlang: se dice dónde está, pero este lector sólo entiende Lua
        return {"root": HYPR, "config": loc, "files": [os.path.basename(loc["main"])], "options": {},
                "devices": {}, "monitors": [], "requires": [], "errors": [], "unsupported": True}
    s = Scan()
    s.load(loc["main"])
    out = s.result()
    out["config"] = loc
    return out


# ---- lo efectivo --------------------------------------------------------------------------

def norm_option(o):
    """getoption -j → {type, value, set}. css → lista de cuatro enteros (arriba, dcha, abajo, izq)."""
    if not isinstance(o, dict):
        return None
    for t in ("int", "float", "str", "bool"):
        if t in o:
            v = o[t]
            if t == "str" and v == "[[EMPTY]]":
                v = ""
            return {"type": t, "value": v, "set": o.get("set", False)}
    if "css" in o:
        try:
            return {"type": "sides", "value": [int(float(x)) for x in str(o["css"]).split()], "set": o.get("set", False)}
        except ValueError:
            return {"type": "raw", "value": o["css"], "set": o.get("set", False)}
    # H-46 (F5a): con hyprland.conf los lados llegan como `custom` («6 6 6 6», medido en F0); con Lua, `css`
    if "custom" in o and re.fullmatch(r"\s*-?\d+(\s+-?\d+){3}\s*", str(o["custom"])):
        return {"type": "sides", "value": [int(x) for x in str(o["custom"]).split()], "set": o.get("set", False)}
    for t in ("gradient", "vec2", "custom"):
        if t in o:
            return {"type": t, "value": o[t], "set": o.get("set", False)}
    return {"type": "raw", "value": o, "set": o.get("set", False)}


SAFE_KEY = re.compile(r"^[a-z0-9_.:\-]+$")


def read(keys):
    for k in keys:
        if not SAFE_KEY.match(k):
            return {"error": "bad option name: " + k}
    cmds = ["j/getoption " + k for k in keys] + ["j/monitors all", "j/devices", "j/version", "j/configerrors"]
    try:
        p = subprocess.run([HYPRCTL, "--batch", ";".join(cmds)], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired) as e:
        return {"error": "hyprctl: " + str(e)}
    if p.returncode != 0 and not p.stdout:
        return {"error": "hyprctl failed: " + p.stderr.strip()}
    parts = [x.strip() for x in p.stdout.split("\n\n\n")]
    parts = [x for x in parts if x]
    if len(parts) != len(cmds):
        return {"error": "hyprctl answered %d of %d" % (len(parts), len(cmds))}

    def js(s):
        try:
            return json.loads(s)
        except ValueError:
            return None
    opts = {}
    for k, raw in zip(keys, parts):
        o = js(raw)
        opts[k] = norm_option(o) if o is not None else {"type": "missing", "value": None, "error": raw[:120]}
    out = scan()
    if "error" in out:
        out = {"scanError": out["error"], "config": out.get("config")}
    out.update({
        "effective": opts,
        "monitorsAll": js(parts[len(keys)]) or [],
        # conectados ahora (hyprctl devices); `devices` son los bloques hl.device escritos
        "inputDevices": js(parts[len(keys) + 1]) or {},
        "version": js(parts[len(keys) + 2]) or {},
        # los que Hyprland enseña en su barra roja (sólo los de la ÚLTIMA evaluación, medido en la 14C)
        "configErrors": [e for e in (js(parts[len(keys) + 3]) or []) if isinstance(e, str) and e.strip()],
    })
    return out


def main(argv):
    if len(argv) < 2 or argv[1] not in ("where", "scan", "read"):
        print(__doc__, file=sys.stderr)
        return 2
    res = locate() if argv[1] == "where" else scan() if argv[1] == "scan" else read(argv[2:])
    json.dump(res, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 1 if "error" in res else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
