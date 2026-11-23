"""Sumi Shell installer — does anything that locks the session still depend on the shell? (portability F6e, G1–G4, G1-H)

Comentarios en español, textos en inglés. Lo usa installer.py antes de desinstalar (y F6e antes de integrar). Sólo lee: /proc,
archivos, `hyprctl -j` y los archivos de unidad. Nunca reinicia ni detiene nada.

Cuatro estados por componente (lo pidió el usuario al aprobar F6e, P7.9):
  disk         lo que hay en disco, sin proceso que lo use ahora (lo cargaría el próximo arranque)
  probable     lo que PROBABLEMENTE cargó un proceso: ningún archivo de su cadena cambió (ctime) desde que arrancó, y la ruta sale
               de su propia línea de órdenes y su entorno. No es una prueba de lo que hay en memoria: es lo más que se puede saber
  effective    comprobado en el proceso (los binds de Hyprland por `hyprctl -j binds`, cuando la acción se ve)
  unknown      no se puede establecer → la desinstalación se niega y se dice cómo resolverlo

Qué cubre:
  G1  cada hypridle en marcha: su config (su -c, su XDG), los `source`, y el ctime de cada archivo frente a su arranque
      (/proc/<pid>/stat + btime). ctime no se puede fijar con touch y cambia con cualquier escritura, rename o chmod.
  G2  lo que cargaría el próximo hypridle: los archivos de unidad que lo lanzan (su -c), las líneas de Hyprland que lo lanzan
      (su -c) y la ruta por defecto.
  G3  dependencias indirectas: cada comando se resuelve; un script de HOME se lee entero y se siguen sus rutas de HOME; lo
      dinámico (variables, eval, source calculado) o un binario de HOME que no se puede leer → unknown.
  G4  todas las órdenes de hypridle: general (lock_cmd, before_sleep_cmd, unlock_cmd, on_lock_cmd, on_unlock_cmd,
      after_sleep_cmd) y on-timeout/on-resume de cada listener. Las que BLOQUEAN deciden; las demás, aviso.
  G1-H Hyprland: binds con acción visible (exec) → effective; binds Lua (`__lua`, acción invisible) → probable sólo si la
      autorecarga está activa o ningún archivo cambió desde su arranque; si no, unknown.
Pruebas: SUMI_PROC (otro /proc), SUMI_UNIT_DIRS (carpetas de unidades de usuario, separadas por «:»).
"""
import glob
import hashlib
import json
import os
import re
import shlex
import shutil
import stat
import subprocess

PROC = os.environ.get("SUMI_PROC", "/proc")
HOME = os.path.expanduser("~")
BLOCKING = ("lock_cmd", "before_sleep_cmd", "on-timeout")
GENERAL_CMDS = ("lock_cmd", "before_sleep_cmd", "unlock_cmd", "on_lock_cmd", "on_unlock_cmd", "after_sleep_cmd")
LISTENER_CMDS = ("on-timeout", "on-resume")
# Sumi Shell 2026-11-07: también las marcas de antes del cambio de nombre (Kitasan-Shell). Un envoltorio o un helper
# viejo sigue siendo «de la shell» (depends/unknown), nunca «independiente»: equivocarse hacia el lado seguro.
WRAPPER_MARKERS = (b"sumi-lock-helper", b"sumi-lock-wrapper", b"kitasan-lock-helper", b"kitasan-lock-wrapper")
WRAPPER_VERSION_MARKERS = (b"sumi-lock-wrapper", b"kitasan-lock-wrapper")
# «sumi» como palabra (no «assuming»/«consumir»), el nombre viejo y el verbo del bloqueo
SHELL_TEXT = re.compile(r"(?<![A-Za-z])sumi(?![a-z])|kitasan|lockNow")
SHELLS = ("sh", "bash", "dash", "zsh", "fish")


def _read(path, mode="r", limit=None):
    try:
        with open(path, mode) as f:
            return f.read(limit) if limit else f.read()
    except (OSError, UnicodeDecodeError):
        return None


# ---- procesos --------------------------------------------------------------------------------------------------------

def proc_start(pid):
    """Hora de arranque (epoch) de un proceso: /proc/<pid>/stat (campo 22, en ticks desde el arranque) + btime.
    btime va en segundos enteros (medido en F6e): el resultado puede quedarse hasta 1 s CORTO. Por eso un cambio hecho menos
    de un segundo antes de arrancar cuenta como posterior → «unknown»: se equivoca hacia el lado seguro, nunca al revés."""
    st = _read(os.path.join(PROC, str(pid), "stat"))
    btime = None
    for line in (_read(os.path.join(PROC, "stat")) or "").splitlines():
        if line.startswith("btime "):
            btime = int(line.split()[1])
    if not st or btime is None:
        return None
    try:
        ticks = int(st.rsplit(")", 1)[1].split()[19])
    except (IndexError, ValueError):
        return None
    return btime + ticks / os.sysconf("SC_CLK_TCK")


def proc_origin(pid):
    """La unidad o el scope del proceso (cgroup v2), para decir de dónde salió."""
    cg = (_read(os.path.join(PROC, str(pid), "cgroup")) or "").strip().split("::")[-1]
    leaf = cg.rsplit("/", 1)[-1]
    if leaf.endswith(".service"):
        return "unit:" + leaf
    if leaf.endswith(".scope"):
        return "scope:" + leaf
    return "unknown"


def proc_env(pid):
    env = {}
    for kv in (_read(os.path.join(PROC, str(pid), "environ"), "rb") or b"").split(b"\0"):
        k, _, v = kv.decode("utf-8", "replace").partition("=")
        if k:
            env[k] = v
    return env


def processes(name):
    """[(pid)] de los procesos de ESTE usuario con ese comm; None si no se puede listar /proc."""
    uid = os.getuid()
    try:
        pids = [int(d) for d in os.listdir(PROC) if d.isdigit()]
    except OSError:
        return None
    out = []
    for pid in sorted(pids):
        if (_read(os.path.join(PROC, str(pid), "comm")) or "").strip() != name:
            continue
        try:
            if os.stat(os.path.join(PROC, str(pid))).st_uid != uid:
                continue
        except OSError:
            continue
        out.append(pid)
    return out


# ---- config de hypridle (hyprlang): general, listener, source, $variables --------------------------------------------

def _strip_comment(line):
    out, i = [], 0
    while i < len(line):
        if line[i] == "#":
            if i + 1 < len(line) and line[i + 1] == "#":
                out.append("#")
                i += 2
                continue
            break
        out.append(line[i])
        i += 1
    return "".join(out)


def read_hypridle(main, _depth=0, _seen=None, _vars=None):
    """{general: {k: v} (la última gana, MP-1), listeners: [{k: v}], files: [...], error} siguiendo `source =`."""
    seen = _seen if _seen is not None else []
    vars_ = _vars if _vars is not None else {}
    res = {"general": {}, "listeners": [], "files": seen, "error": ""}
    if _depth > 8:
        res["error"] = "too many nested `source` lines"
        return res
    if main in seen:
        return res
    text = _read(main)
    if text is None:
        res["error"] = main + " can't be read"
        return res
    seen.append(main)
    stack, cur = [], None
    for raw in text.split("\n"):
        line = _strip_comment(raw).strip()
        if not line:
            continue
        m = re.match(r"^([\w-]+)\s*\{$", line)
        if m:
            stack.append(m.group(1))
            if stack == ["listener"]:
                cur = {}
                res["listeners"].append(cur)
            continue
        if line == "}":
            if stack:
                stack.pop()
            continue
        k, eq, v = line.partition("=")
        if not eq:
            continue
        k, v = k.strip(), v.strip()
        for name, val in sorted(vars_.items(), key=lambda kv: -len(kv[0])):
            v = v.replace("$" + name, val)
        if not stack and k.startswith("$"):
            vars_[k[1:]] = v
        elif not stack and k == "source":
            pat = os.path.expanduser(v)
            if not os.path.isabs(pat):
                pat = os.path.join(os.path.dirname(main), pat)
            hits = sorted(glob.glob(pat)) if any(c in pat for c in "*?[") else ([pat] if os.path.exists(pat) else [])
            if not hits:
                res["error"] = res["error"] or "`source = %s` in %s names nothing" % (v, main)
            for h in hits:
                sub = read_hypridle(h, _depth + 1, seen, vars_)
                res["general"].update(sub["general"])
                res["listeners"] += sub["listeners"]
                res["error"] = res["error"] or sub["error"]
        elif stack == ["general"]:
            res["general"][k] = v
        elif stack == ["listener"] and cur is not None:
            cur[k] = v
    return res


def locate_hypridle(pid):
    """La config que leyó un hypridle: su -c (relativo a su cwd) o $XDG_CONFIG_HOME/hypr de SU entorno."""
    args = (_read(os.path.join(PROC, str(pid), "cmdline"), "rb") or b"").decode("utf-8", "replace").split("\0")
    env = proc_env(pid)
    for i, a in enumerate(args):
        val = None
        if a in ("-c", "--config") and i + 1 < len(args):
            val = args[i + 1]
        elif a.startswith("--config="):
            val = a.split("=", 1)[1]
        if val:
            p = os.path.expanduser(val)
            if not os.path.isabs(p):
                try:
                    cwd = os.readlink(os.path.join(PROC, str(pid), "cwd"))
                except OSError:
                    return None, "its -c path is relative and its working directory can't be read"
                p = os.path.join(cwd, p)
            return os.path.normpath(p), "its -c argument"
    home = env.get("HOME") or HOME
    cfg = env.get("XDG_CONFIG_HOME") or os.path.join(home, ".config")
    return os.path.join(cfg, "hypr", "hypridle.conf"), "its environment (XDG_CONFIG_HOME/hypr)"


def changed_since(files, start):
    """Los archivos (o el destino de su enlace) cuyo ctime no es anterior al arranque del proceso."""
    out = []
    for f in files:
        try:
            ts = [os.lstat(f).st_ctime]
            if os.path.islink(f):
                ts.append(os.stat(f).st_ctime)
        except OSError:
            out.append(f + " (gone)")
            continue
        if max(ts) >= start:
            out.append(f)
    return out


# ---- órdenes: ¿dependen de la shell? (G3) ----------------------------------------------------------------------------

def _program(tok, path_env):
    p = os.path.expanduser(tok)
    if "/" in p:
        return p if os.path.exists(p) else None
    for d in (path_env or os.environ.get("PATH", "")).split(":"):
        c = os.path.join(d, p)
        if d and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


def _in_home(p):
    r = os.path.realpath(p)
    return r == os.path.realpath(HOME) or r.startswith(os.path.realpath(HOME) + "/")


def classify_file(path, ctx, depth=0):
    """(verdict, why) de un ejecutable o script: independent | depends | unknown | wrapper."""
    real = os.path.realpath(path)
    if ctx["tree"] and (real == ctx["tree"] or real.startswith(ctx["tree"] + "/")):
        return "depends", "%s is inside the installed shell" % path
    if os.path.basename(real) == "sumi-lock":
        return "depends", "%s is the shell's lock helper" % path
    try:
        st = os.stat(real)
    except OSError:
        return "independent", "%s doesn't exist (the command already fails; the shell isn't involved)" % path
    system = not _in_home(real) and st.st_uid == 0 and not (st.st_mode & 0o022)
    if system:
        return "independent", ""
    data = _read(real, "rb", 1 << 20)
    if data is None:
        return "unknown", "%s can't be read" % path
    if hashlib.sha256(data).hexdigest() in ctx["knownWrappers"]:
        return "wrapper", real
    if any(m in data[:4096] for m in WRAPPER_VERSION_MARKERS):
        return "unknown", "%s is an unrecognised version of the lock wrapper: can't establish that it still locks " \
                          "without the shell" % path
    if b"\0" in data[:4096]:
        return "unknown", "%s is a program in your home that can't be inspected" % path
    if any(m in data for m in WRAPPER_MARKERS) or SHELL_TEXT.search(data.decode("utf-8", "replace")) or (
            ctx["tree"] and ctx["tree"].encode() in data):
        return "depends", "%s refers to Sumi Shell" % path
    text = data.decode("utf-8", "replace")
    dyn = re.search(r"(^|[;&|(]\s*)(eval|source|\.)\s|(^|[;&|(]\s*)\"?\$[\w{(]", text, re.M)
    if dyn:
        return "unknown", "%s runs something it computes at run time (%s): can't follow it" % (path, dyn.group(0).strip())
    if depth >= 4:
        return "unknown", "%s calls scripts nested too deep to follow" % path
    worst = ("independent", "")
    for m in re.finditer(r"(~|\$HOME|\$\{HOME\}|" + re.escape(os.path.realpath(HOME)) + r")(/[^\s\"'`;|&)<>]+)", text):
        sub = os.path.realpath(HOME) + m.group(2)
        if os.path.isfile(sub):
            v = classify_file(sub, ctx, depth + 1)
            worst = _worse(worst, v)
    return worst


def _worse(a, b):
    order = {"independent": 0, "requester": 0, "wrapper": 1, "unknown": 2, "depends": 3}
    return b if order[b[0]] > order[a[0]] else a


def classify_command(cmd, ctx, path_env=None, depth=0):
    """(verdict, why) de una orden de hypridle (la ejecuta `sh -c`). requester = sólo pide el bloqueo a logind."""
    cmd = (cmd or "").strip()
    if not cmd:
        return "independent", ""
    if SHELL_TEXT.search(cmd) or (ctx["tree"] and ctx["tree"] in cmd):
        return "depends", "`%s` names Sumi Shell" % cmd
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    try:
        toks = list(lex)
    except ValueError:
        return "unknown", "`%s` can't be parsed" % cmd
    if re.search(r"\$(?!HOME\b|\{HOME\})|`", cmd):
        return "unknown", "`%s` uses shell variables or substitutions: what it runs depends on run time" % cmd
    segs, cur = [], []
    for t in toks:
        if t in (";", "&&", "||", "|", "&", "(", ")", ";;"):
            if cur:
                segs.append(cur)
            cur = []
        else:
            cur.append(t.replace("${HOME}", HOME).replace("$HOME", HOME))
    if cur:
        segs.append(cur)
    worst = ("independent", "")
    for seg in segs:
        while seg and re.match(r"^\w+=", seg[0]):
            seg = seg[1:]
        if not seg:
            continue
        name = os.path.basename(seg[0])
        if name == "loginctl" and seg[1:2] == ["lock-session"]:
            worst = _worse(worst, ("requester", ""))
            continue
        if name in SHELLS and "-c" in seg and seg.index("-c") + 1 < len(seg):
            if depth >= 3:
                return "unknown", "`%s` nests shells too deep" % cmd
            worst = _worse(worst, classify_command(seg[seg.index("-c") + 1], ctx, path_env, depth + 1))
            continue
        # el programa y cualquier ruta que aparezca como argumento (envoltorios como env/setsid/systemd-run)
        cands = [seg[0]] + [t for t in seg[1:] if "/" in t or t.startswith("~")]
        for t in cands:
            p = _program(t, path_env) if t is seg[0] else (os.path.expanduser(t) if os.path.exists(os.path.expanduser(t)) else None)
            if p is None:
                continue
            worst = _worse(worst, classify_file(p, ctx))
    return worst


# ---- informe ---------------------------------------------------------------------------------------------------------

def _commands(conf):
    out = [(k, conf["general"][k]) for k in GENERAL_CMDS if conf["general"].get(k)]
    for i, l in enumerate(conf["listeners"]):
        for k in LISTENER_CMDS:
            if l.get(k):
                out.append(("%s (listener %d, timeout %s)" % (k, i + 1, l.get("timeout", "?")), l[k]))
    return out


def judge(conf, ctx, path_env=None):
    """[(key, cmd, verdict, why, blocking)] de una config ya leída."""
    res = []
    for key, cmd in _commands(conf):
        v, why = classify_command(cmd, ctx, path_env)
        res.append((key, cmd, v, why, key.split(" ")[0] in BLOCKING))
    return res


def unit_dirs():
    forced = os.environ.get("SUMI_UNIT_DIRS")
    if forced:
        return [d for d in forced.split(":") if d]
    cfg = os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config")
    return [os.path.join(cfg, "systemd", "user"), "/etc/systemd/user", "/usr/lib/systemd/user"]


def next_start_configs(hypr_dirs):
    """(config, de dónde) que cargaría un hypridle al arrancar: unidades que lo lanzan, líneas de Hyprland, la por defecto."""
    found, unknown = [], []
    exe = re.compile(r"(?:^|[\s/=\"'])hypridle(?:\s|$|\")")
    for d in unit_dirs():
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for n in names:
            if not n.endswith(".service"):
                continue
            text = _read(os.path.join(d, n)) or ""
            for line in text.splitlines():
                if line.strip().startswith("ExecStart") and exe.search(line):
                    found.append((_config_arg(line.split("=", 1)[1]), "unit %s" % os.path.join(d, n)))
    for hd in hypr_dirs:
        for folder, dirs, files in os.walk(hd):
            for n in files:
                if n.endswith((".lua", ".conf")) and "hypridle" not in n:
                    p = os.path.join(folder, n)
                    for line in (_read(p) or "").splitlines():
                        s = _strip_comment(line) if n.endswith(".conf") else line.split("--", 1)[0]
                        if exe.search(s) and re.search(r"exec|spawn|exec_cmd", s):
                            found.append((_config_arg(s), "%s" % p))
    cfg = os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config")
    default = os.path.join(cfg, "hypr", "hypridle.conf")
    out = []
    for c, src in found:
        if c == "?":
            unknown.append(src)
        else:
            out.append((c or default, src))
    out.append((default, "the default location"))
    seen, uniq = set(), []
    for c, src in out:
        if c not in seen:
            seen.add(c)
            uniq.append((c, src))
    return uniq, unknown


def _config_arg(text):
    """La ruta del -c de una línea que lanza hypridle; "" si no tiene; "?" si no se puede leer con seguridad."""
    m = re.search(r"hypridle\b(.*)", text)
    rest = (m.group(1) if m else "").strip().strip("\"')")
    m2 = re.search(r"(?:-c|--config)[\s=]+([^\s\"')]+)", rest)
    if not m2:
        return ""
    p = m2.group(1).replace("%h", HOME)
    if "$" in p or "%" in p:
        return "?"
    p = os.path.expanduser(p)
    return p if os.path.isabs(p) else "?"


def hyprctl_json(*args, instance=None):
    exe = shutil.which("hyprctl")
    if not exe:
        return None
    try:
        p = subprocess.run([exe] + (["--instance", instance] if instance else []) + ["-j"] + list(args),
                           capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    try:
        return json.loads(p.stdout)
    except ValueError:
        return None


def hyprland_state(hypr_dir, ctx):
    """G1-H: lo que Hyprland tiene cargado, en la medida en que se puede saber."""
    procs = processes("Hyprland") or []
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    inst = hyprctl_json("instances")
    if not procs and not inst:
        return {"state": "disk", "why": "Hyprland isn't running: its configuration on disk is what it will load"}
    if not isinstance(inst, list) or not inst:
        return {"state": "unknown", "why": "Hyprland is running but `hyprctl` doesn't answer: its loaded key bindings "
                                           "can't be read"}
    me = [i for i in inst if i.get("instance") == sig]
    if not me and len(inst) == 1:
        me = inst                                   # fuera de la sesión (TTY): la única instancia que hay
    if not me:
        return {"state": "unknown", "why": "%d Hyprland instances run and none is this session's: run it from inside "
                                           "your Hyprland session" % len(inst)}
    which = None if me[0].get("instance") == sig else me[0].get("instance")
    binds = hyprctl_json("binds", instance=which)
    if not isinstance(binds, list):
        return {"state": "unknown", "why": "`hyprctl binds` doesn't answer"}
    deps = []
    for b in binds:
        if b.get("dispatcher") in ("exec", "execr"):
            v, why = classify_command(b.get("arg", ""), ctx)
            if v in ("depends", "unknown"):
                deps.append((b.get("modmask"), b.get("key"), b.get("arg"), v, why))
    lua = [b for b in binds if b.get("dispatcher") == "__lua"]
    res = {"state": "effective", "binds": len(binds), "luaBinds": len(lua), "dependent": deps}
    if lua:
        opt = hyprctl_json("getoption", "misc:disable_autoreload", instance=which) or {}
        off = bool(opt.get("bool", opt.get("int", 0)))
        start = min((i.get("time") or 0) for i in me)
        files = [os.path.join(f, n) for f, _, ns in os.walk(hypr_dir) for n in ns if n.endswith((".lua", ".conf"))]
        newer = changed_since(files, start) if start else files
        if off and newer:
            res.update(state="unknown", why="automatic reload is off and %d of its files changed after Hyprland started "
                                            "(%s): what its Lua key bindings run now can't be known" % (
                                                len(newer), ", ".join(newer[:3])))
        else:
            res.update(state="probable", why="%d Lua key bindings: their actions aren't visible; with automatic reload %s "
                                             "they follow the files on disk" % (len(lua), "on," if not off else
                                                                                "off and no file changed since start,"))
    return res


def report(tree_real, hypr_dir, known_wrappers):
    """El informe completo: hypridle en marcha (G1/G4), el próximo arranque (G2) y Hyprland (G1-H)."""
    ctx = {"tree": os.path.realpath(tree_real) if tree_real else "", "knownWrappers": known_wrappers}
    rep = {"hypridle": [], "nextStart": [], "hyprland": None, "errors": []}
    pids = processes("hypridle")
    if pids is None:
        rep["errors"].append("the process list can't be read: can't tell what hypridle has loaded")
        pids = []
    for pid in pids:
        start = proc_start(pid)
        main, how = locate_hypridle(pid)
        e = {"pid": pid, "origin": proc_origin(pid), "config": main, "from": how, "commands": []}
        if start is None or main is None:
            e.update(state="unknown", why=how if main is None else "its start time can't be read")
        else:
            conf = read_hypridle(main)
            newer = changed_since(conf["files"], start)
            if conf["error"]:
                e.update(state="unknown", why=conf["error"])
            elif newer:
                e.update(state="unknown", why="it started before its configuration last changed (%s): it may still run "
                                              "the old commands. Restart it (%s) and try again" % (
                                                  ", ".join(newer), restart_hint(e["origin"])))
            else:
                e.update(state="probable", why="no file of its configuration changed since it started; config from %s"
                                               % how, files=conf["files"])
            e["commands"] = judge(conf, ctx, proc_env(pid).get("PATH"))
        rep["hypridle"].append(e)
    cfgs, unknown = next_start_configs([hypr_dir])
    for src in unknown:
        rep["nextStart"].append({"config": "?", "from": src, "state": "unknown",
                                 "why": "%s starts hypridle with a configuration path that can't be read safely" % src,
                                 "commands": []})
    for c, src in cfgs:
        if not os.path.exists(c):
            continue
        conf = read_hypridle(c)
        e = {"config": c, "from": src, "state": "disk", "why": "what hypridle would load at its next start",
             "commands": judge(conf, ctx)}
        if conf["error"]:
            e.update(state="unknown", why=conf["error"])
        rep["nextStart"].append(e)
    rep["hyprland"] = hyprland_state(hypr_dir, ctx)
    return rep


def restart_hint(origin):
    if origin.startswith("unit:"):
        return "`systemctl --user restart %s`, or log out and back in" % origin[5:]
    return "log out and back in (it isn't run by a unit the installer can name)"


def problems(rep):
    """(rechazos, avisos) a partir del informe. Un wrapper se devuelve aparte para que installer.py lo compruebe."""
    refuse, warn, wrappers = list(rep["errors"]), [], []
    for e in rep["hypridle"] + rep["nextStart"]:
        who = "hypridle (pid %s, %s)" % (e["pid"], e["origin"]) if "pid" in e else \
            "hypridle at its next start (%s, from %s)" % (e["config"], e["from"])
        if e["state"] == "unknown":
            refuse.append("%s: %s" % (who, e["why"]))
        for key, cmd, v, why, blocking in e.get("commands", []):
            if v == "wrapper":
                wrappers.append((who, key, cmd, why))
            elif v in ("depends", "unknown"):
                msg = "%s %s = `%s`: %s" % (who, key, cmd, why or v)
                (refuse if blocking else warn).append(msg if blocking else msg + " (it would fail after uninstalling)")
    h = rep["hyprland"] or {}
    if h.get("state") == "unknown":
        refuse.append("Hyprland: " + h["why"])
    for mod, key, arg, v, why in h.get("dependent", []):
        refuse.append("Hyprland key binding (modmask %s, %s) runs `%s`: %s" % (mod, key, arg, why))
    return refuse, warn, wrappers


def describe(rep):
    """Líneas legibles con el estado de cada componente (disk / probable / effective / unknown)."""
    out = []
    for e in rep["hypridle"]:
        out.append("hypridle pid %s (%s), config %s: %s — %s" % (e["pid"], e["origin"], e["config"], e["state"], e["why"]))
    for e in rep["nextStart"]:
        out.append("hypridle at its next start, %s (%s): %s" % (e["config"], e["from"], e["state"]))
    h = rep["hyprland"] or {}
    out.append("Hyprland: %s%s" % (h.get("state", "?"), (" — " + h["why"]) if h.get("why") else ""))
    return out
