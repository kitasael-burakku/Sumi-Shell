"""Sumi Shell installer — `install.sh theme-apps` (static palettes F-e, 2026-11-04).

Comentarios en español, textos en inglés. Para quien NO tiene su propia config de matugen: el proveedor de tema propio de
la shell sólo genera su paleta; esto añade, a petición y con vuelta atrás, los colores de la shell a kitty, GTK 3, GTK 4,
Qt 5/6 (qt5ct/qt6ct) y al borde de las ventanas de Hyprland. Mismo modelo que `install.sh hyprland` (integrations.py):

  · Sin --apply/--revert, VISTA PREVIA: no escribe nada.
  · Por app, dos recursos: un archivo de colores GENERADO (lo reescribe el proveedor de tema en cada cambio; su primera
    línea empieza por «Sumi Shell —»: así se reconoce como nuestro) y el cambio mínimo que lo carga en la config de la
    app: un bloque delimitado al final de kitty.conf, al principio de gtk-3.0/gtk.css y gtk-4.0/gtk.css (un @import va
    antes que cualquier regla), dos claves de qt5ct.conf/qt6ct.conf (color_scheme_path, custom_palette) guardando las de
    antes. Hyprland no se toca: el fragmento de `install.sh hyprland --apply` ya carga el archivo del borde si existe.
  · La config de matugen del proveedor propio: ~/.config/sumi-shell/matugen-apps.toml (la paleta de la shell + las apps
    aplicadas, con sus recargas). La shell la usa si existe y es tuya (services/Providers.qml).
  · Los principales existentes se cambian con renameat2(RENAME_EXCHANGE) y las versiones anteriores se conservan
    (integrations.replace_file); lo que el usuario cambió después nunca se pisa: revert sólo quita lo que reconoce.
  · Los colores iniciales salen del `stage` de la preview (theme-preview.py) con el tema confirmado, sin aplicarlo.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
import uuid

I = None          # installer
G = None          # integrations
KIND = "theme-apps"
MARK = "Sumi Shell —"           # primera línea de templates/apps/*: el archivo generado es nuestro
APPS = ("kitty", "gtk3", "gtk4", "qt5", "qt6", "hyprland")
NAMES = {"kitty": "kitty", "gtk3": "GTK 3", "gtk4": "GTK 4", "qt5": "Qt 5 (qt5ct)", "qt6": "Qt 6 (qt6ct)",
         "hyprland": "Hyprland border"}
CONFIG_NAME = "matugen-apps.toml"
# el fragmento de `install.sh hyprland` que sabe cargar el archivo del borde (integrations.render_hyprland)
HYPR_COLORS_MARK = "sumi-shell-colors.lua"


def sha(b):
    return hashlib.sha256(b).hexdigest()


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return None


def is_ours(path):
    """¿El archivo generado es nuestro? Su primera línea lleva la marca de templates/apps/."""
    data = read(path)
    if data is None:
        return None
    # en las tres primeras líneas: la paleta de qt*ct tiene que empezar por [ColorScheme]
    head = b"\n".join(data.split(b"\n", 3)[:3]).decode("utf-8", "replace")
    return MARK in head


class Spec:
    """Qué toca cada app (rutas reales bajo el XDG_CONFIG_HOME de la instalación)."""

    def __init__(self, app, roots, tree, hypr_frag=None):
        """`hypr_frag`: el fragmento de `install.sh hyprland` (el archivo del borde va a su lado, con la ruta que ese
        fragmento lleva escrita: no depende del entorno de Hyprland ni de dónde viva su config)."""
        cfg = roots.real["config"]
        self.app, self.tree = app, tree
        self.way, self.main, self.body, self.comment = None, None, None, None
        if app == "kitty":
            self.way, self.main = "end", os.path.join(cfg, "kitty", "kitty.conf")
            self.gen = os.path.join(cfg, "kitty", "sumi-shell-colors.conf")
            self.tpl, self.body, self.comment = "kitty-colors.conf", "include sumi-shell-colors.conf", ("#", "")
            # pkill (procps) o killall (psmisc): cualquiera de los dos, según la distribución
            self.hook = "(timeout 5 pkill -USR1 -x kitty || timeout 5 killall -USR1 kitty) >/dev/null 2>&1 || true"
        elif app in ("gtk3", "gtk4"):
            d = os.path.join(cfg, "gtk-3.0" if app == "gtk3" else "gtk-4.0")
            self.way, self.main = "start", os.path.join(d, "gtk.css")
            self.gen = os.path.join(d, "sumi-shell-colors.css")
            self.tpl, self.body, self.comment = "gtk-colors.css", '@import url("sumi-shell-colors.css");', ("/*", " */")
            self.hook = ""
        elif app in ("qt5", "qt6"):
            n = app[2]
            d = os.path.join(cfg, "qt%sct" % n)
            self.way, self.main = "ini", os.path.join(d, "qt%sct.conf" % n)
            self.gen = os.path.join(d, "colors", "sumi-shell.conf")
            self.tpl = "qt-colors.conf"
            self.hook = ("timeout 5 python3 -B %s --config %s --palette %s || true"
                         % (os.path.join(tree, "scripts", "qt-palette-notify.py"), self.main, self.gen))
        else:
            self.way = "hypr"
            self.gen = G.colors_path(hypr_frag) if hypr_frag else os.path.join(cfg, "hypr", HYPR_COLORS_MARK)
            self.tpl = "hypr-colors.lua"
            self.hook = ("timeout 5 hyprctl eval 'local ok, c = pcall(dofile, \"%s\"); if ok and type(c) == \"table\" "
                         "then hl.config({ general = { col = c } }) end' >/dev/null 2>&1 || true" % self.gen)

    def block(self, mid):
        o, c = self.comment
        return ("%s >>> sumi-shell theme-apps (install %s): added by `install.sh theme-apps --apply`; remove it with "
                "`install.sh theme-apps --revert`%s\n%s\n%s <<< sumi-shell theme-apps (install %s)%s\n"
                % (o, mid, c, self.body, o, mid, c))


# ---- qt*ct.conf: dos claves de [Appearance] ---------------------------------------------------------------------

def ini_set(text, values):
    """(texto nuevo, valores de antes {clave: valor o None}) con `values` puestos en [Appearance]."""
    lines = text.split("\n")
    start = next((i for i, l in enumerate(lines) if l.strip() == "[Appearance]"), None)
    prev = {k: None for k in values}
    if start is None:
        if lines and lines[-1] == "":
            lines.pop()
        lines += (["" ] if lines else []) + ["[Appearance]"] + ["%s=%s" % kv for kv in values.items()] + [""]
        return "\n".join(lines), prev
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("[")), len(lines))
    seen = set()
    for i in range(start + 1, end):
        m = re.match(r"^([A-Za-z_]+)=(.*)$", lines[i])
        if m and m.group(1) in values and m.group(1) not in seen:
            prev[m.group(1)] = m.group(2)
            lines[i] = "%s=%s" % (m.group(1), values[m.group(1)])
            seen.add(m.group(1))
    missing = ["%s=%s" % (k, v) for k, v in values.items() if k not in seen]
    lines[end:end] = missing
    return "\n".join(lines), prev


def ini_get(text, key):
    lines = text.split("\n")
    start = next((i for i, l in enumerate(lines) if l.strip() == "[Appearance]"), None)
    if start is None:
        return None
    for l in lines[start + 1:]:
        if l.startswith("["):
            break
        m = re.match(r"^([A-Za-z_]+)=(.*)$", l)
        if m and m.group(1) == key:
            return m.group(2)
    return None


def ini_restore(text, ours, prev):
    """Devuelve a `prev` sólo las claves que siguen valiendo lo nuestro. (texto, claves cambiadas por el usuario)."""
    lines = text.split("\n")
    start = next((i for i, l in enumerate(lines) if l.strip() == "[Appearance]"), None)
    changed = []
    if start is None:
        return text, list(ours)
    i = start + 1
    done = set()
    while i < len(lines) and not lines[i].startswith("["):
        m = re.match(r"^([A-Za-z_]+)=(.*)$", lines[i])
        if m and m.group(1) in ours and m.group(1) not in done:
            k = m.group(1)
            done.add(k)
            if m.group(2) != ours[k]:
                changed.append(k)
            elif prev.get(k) is None:
                del lines[i]
                continue
            else:
                lines[i] = "%s=%s" % (k, prev[k])
        i += 1
    changed += [k for k in ours if k not in done]
    return "\n".join(lines), changed


# ---- el módulo ----------------------------------------------------------------------------------------------------

class ThemeApps:
    def __init__(self, inst):
        self.inst, self.roots, self.man, self.args = inst, inst.roots, inst.man, inst.args
        self.tree = os.path.join(self.roots.real["config"], *I.TREE_REL)
        self.config = os.path.join(self.roots.real["config"], "sumi-shell", CONFIG_NAME)
        self.it = G.Integrations(inst)

    def say(self, m):
        self.inst.say(m)

    def spec(self, app):
        hy = (((self.man.load() or {}).get("integrations") or {}).get("hyprland") or {}) if app == "hyprland" else {}
        return Spec(app, self.roots, self.tree, hy.get("fragment"))

    def wanted(self):
        apps = list(getattr(self.args, "apps", None) or [])
        bad = [a for a in apps if a not in APPS]
        if bad:
            raise I.Refused(["unknown app: %s (one of %s)" % (", ".join(bad), ", ".join(APPS))])
        return apps

    # -- por qué no --
    def provider_problems(self):
        """La config de matugen que decide qué apps reciben color tiene que ser la de la shell."""
        why = []
        try:
            st = json.load(open(os.path.join(self.roots.real["config"], "sumi-shell", "settings.json")))
            setting = ((st.get("providers") or {}).get("theme")) or "auto"
        except (OSError, ValueError):
            setting = "auto"
        if setting not in ("auto", "matugen", "static"):
            why.append("the theme provider is set to «%s» in Settings (Shell → Apps): theme-apps only works with the "
                       "shell's own provider" % setting)
        try:
            pj = json.load(open(os.path.join(self.roots.real["config"], "sumi-shell", "providers.json")))
            if isinstance(pj.get("theme"), dict) and pj["theme"].get("matugenConfig"):
                why.append("your providers.json declares your own matugen configuration (%s): it already decides which "
                           "apps get colours; add templates there instead" % pj["theme"]["matugenConfig"])
        except (OSError, ValueError, AttributeError):
            pass
        if not shutil.which("matugen"):
            why.append("matugen isn't installed: without it the shell only colours itself")
        return why

    def app_problems(self, spec, doc):
        why = []
        if spec.app == "kitty" and not shutil.which("kitty"):
            why.append("kitty isn't installed")
        if spec.way in ("end", "start", "ini") and os.path.lexists(spec.main):
            why += [w for w in G.file_policy(spec.main, self.roots) if "doesn't exist" not in w]
        if spec.way == "ini":
            if not os.path.exists(spec.main):
                why.append("%s doesn't exist (open qt%sct once and press OK)" % (spec.main, spec.app[2]))
            pt = os.environ.get("QT_QPA_PLATFORMTHEME", "")
            if not re.search(r"qt[56]ct", pt):
                why.append("Qt apps here don't use qt5ct/qt6ct (QT_QPA_PLATFORMTHEME is «%s»): they wouldn't see the "
                           "palette" % pt)
        if spec.way == "hypr":
            rec = ((doc or {}).get("integrations") or {}).get("hyprland") or {}
            if rec.get("status") not in ("loaded", "written"):
                why.append("needs the Hyprland integration first: `install.sh hyprland --apply --reload`")
            elif rec.get("dialect") != "lua":
                why.append("the window border is only set up for Lua configurations (Hyprland 0.57+)")
            else:
                frag = read(rec.get("fragment", "")) or b""
                if G.lua_string(spec.gen).encode() not in frag:
                    why.append("the Hyprland integration was set up by an older installer: run `install.sh hyprland "
                               "--revert --reload` and `install.sh hyprland --apply --reload` once")
        if os.path.lexists(spec.gen) and not is_ours(spec.gen):
            why.append("%s already exists and isn't written by the shell" % spec.gen)
        return why

    # -- la config de matugen del proveedor --
    def render_config(self, apps, mid):
        st = self.roots.real["state"]
        lines = ["# Sumi Shell — the matugen configuration of the shell's theme provider, written by",
                 "# `install.sh theme-apps` (install %s). Do not edit: `install.sh theme-apps --apply/--revert` rewrites it;" % mid,
                 "# if you change it, the installer stops managing it. Without this file the shell only colours itself.",
                 "[config]", 'prefer = "saturation"', "",
                 "[templates.sumi_shell]",
                 "input_path = %s" % json.dumps(os.path.join(self.tree, "templates", "matugen-colors.json")),
                 "output_path = %s" % json.dumps(os.path.join(st, "sumi-shell", "colors.json"))]
        for a in APPS:
            if a not in apps:
                continue
            s = self.spec(a)
            lines += ["", "[templates.%s]" % a,
                      "input_path = %s" % json.dumps(os.path.join(self.tree, "templates", "apps", s.tpl)),
                      "output_path = %s" % json.dumps(s.gen)]
            if s.hook:
                lines.append("post_hook = %s" % json.dumps(s.hook))
        return ("\n".join(lines) + "\n").encode()

    def current_profile(self):
        """El perfil confirmado, como lo entiende theme-preview.py stage (con sus opciones)."""
        th = os.path.join(self.roots.real["state"], "sumi-shell", "theme")
        txt = lambda n: ((read(os.path.join(th, n)) or b"").decode().strip())
        if os.path.exists(os.path.join(th, "enabled")):
            scheme = txt("scheme") or "scheme-tonal-spot"
            args = ["--profile", scheme[7:] if scheme.startswith("scheme-") else scheme,
                    "--mode", "light" if txt("mode") == "light" else "dark"]
            if txt("contrast"):
                args += ["--contrast", txt("contrast")]
            if txt("source"):
                args += ["--source", txt("source")]
            return args
        p = txt("preset")
        if re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)+", p or ""):
            return ["--profile", "preset:" + p]
        return ["--profile", "static"]

    def render_outputs(self, apps):
        """{app: bytes} — los colores de ahora para esas apps, por el `stage` de la preview (no instala nada)."""
        work = tempfile.mkdtemp(prefix="sumi-theme-apps-", dir=os.environ.get("XDG_RUNTIME_DIR") or None)
        try:
            cfg = os.path.join(work, "config.toml")
            body = self.render_config(apps, "preview").decode()
            # sólo las apps: la paleta de la shell no se toca aquí
            body = re.sub(r"\[templates\.sumi_shell\]\n[^\[]*", "", body)
            open(cfg, "w").write(body)
            env = dict(os.environ, MATUGEN_CONFIG=cfg, KT_DESKTOP_SYNC="off", KT_XSETTINGS_CONFIG="")
            env.pop("KT_STATIC_LIST_ARGV", None)
            helper = os.path.join(self.tree, "scripts", "theme-preview.py")
            out = None
            for prof in (self.current_profile(), ["--profile", "static"]):
                p = subprocess.run([shutil.which("python3") or "python3", "-B", helper, "stage", "--work",
                                    os.path.join(work, "w")] + prof, capture_output=True, text=True, env=env, timeout=120)
                try:
                    out = json.loads((p.stdout.strip().splitlines() or ["{}"])[-1])
                except ValueError:
                    out = {}
                if out.get("ok"):
                    break
            if not out or not out.get("ok"):
                raise I.Refused(["the theme provider couldn't render the colours: %s %s" % (
                    (out or {}).get("error", ""), (out or {}).get("detail", ""))])
            res = {}
            for a in apps:
                data = read(os.path.join(work, "w", "out", a))
                if not data or MARK.encode() not in b"\n".join(data.split(b"\n", 3)[:3]):
                    raise I.Refused(["the theme provider didn't render %s" % NAMES[a]])
                res[a] = data
            return res
        finally:
            shutil.rmtree(work, ignore_errors=True)

    # -- archivos --
    def ensure_parent(self, path, dirs):
        """Crea las carpetas que falten (sin seguir enlaces) y apunta en `dirs` las que creó: revert las quita si
        se quedan vacías."""
        rel = os.path.relpath(os.path.dirname(path), self.roots.real["config"])
        made = []
        fd = self.roots.chain("config", tuple(rel.split("/")), create=True, created=made)
        os.close(fd)
        if dirs is not None:
            dirs += [m[1] for m in made if m[1] not in dirs]

    def remove_dirs(self, dirs):
        """Las carpetas que creó theme-apps, de la más honda a la menos, sólo si están vacías y siguen siendo carpetas."""
        base = self.roots.real["config"]
        left = []
        for rel in sorted(dirs or [], key=lambda x: -x.count("/")):
            p = os.path.join(base, rel)
            try:
                if os.path.islink(p) or not os.path.isdir(p):
                    continue
                os.rmdir(p)
            except OSError:
                left.append(rel)
        return left

    def write_or_replace(self, path, new, doc, kept_name, want=None, dirs=None):
        """Crea `path` (si no existe) o lo sustituye si sigue siendo `want` (sha). («created»|«done»|«changed»|«conflict»)"""
        cur = read(path)
        if cur is None:
            self.ensure_parent(path, dirs)
            G.create_fragment(path, self.roots, new, doc["createdDirs"])
            return "created", None
        if want is not None and sha(cur) != want:
            return "changed", None
        st = os.lstat(path)
        r, info = G.replace_file(path, self.roots, st.st_ino, sha(cur), new, doc["transaction"]["id"], kept_name,
                                 doc["createdDirs"])
        return r, info

    def remove_ours(self, path):
        """Borra un archivo generado sólo si sigue siendo nuestro (marca) y no cambió mientras."""
        data = read(path)
        if data is None:
            return "absent"
        if not is_ours(path):
            return "kept"
        return G.remove_fragment(path, self.roots, sha(data))

    # -- vista previa --
    def preview(self, doc, rec, apps):
        prov = self.provider_problems()
        applied = (rec or {}).get("apps") or {}
        self.say("Theme colours for other apps (nothing is changed without --apply):")
        if prov:
            for w in prov:
                self.say("  ! " + w)
        for a in apps or APPS:
            s = self.spec(a)
            if (applied.get(a) or {}).get("status") == "applied":
                self.say("  %-16s applied · %s" % (NAMES[a], self.where(s)))
                continue
            why = self.app_problems(s, doc)
            self.say("  %-16s %s" % (NAMES[a], ("not possible: " + "; ".join(why)) if why else "can be applied · " + self.where(s)))
        self.say("Apply with `install.sh theme-apps --apply <app>…` (kitty gtk3 gtk4 qt5 qt6 hyprland); undo with --revert.")
        return I.EXIT_OK

    def where(self, s):
        if s.way == "end":
            return "a line at the end of %s, colours in %s" % (s.main, s.gen)
        if s.way == "start":
            return "a line at the start of %s, colours in %s" % (s.main, s.gen)
        if s.way == "ini":
            return "color_scheme_path and custom_palette in %s (the old values are kept), palette %s" % (s.main, s.gen)
        return "colours in %s (the Hyprland integration loads them)" % s.gen

    # -- aplicar --
    def apply(self, doc, rec, apps):
        doc = self.it.need_install()
        mid = doc["id"]
        prov = self.provider_problems()
        if prov:
            raise I.Refused(prov)
        rec = rec or {"kind": KIND, "status": "reverted", "apps": {}, "config": self.config, "configSha": None,
                      "kept": [], "history": []}
        applied = {a for a, r in rec["apps"].items() if r.get("status") == "applied"}
        todo = [a for a in (apps or []) if a not in applied]
        if not apps:
            raise I.Refused(["name the apps to set up: kitty gtk3 gtk4 qt5 qt6 hyprland (`install.sh theme-apps` "
                             "shows which are possible here)"])
        if not todo:
            self.say("Already applied: " + ", ".join(NAMES[a] for a in apps))
            return I.EXIT_OK
        probs = []
        specs = {a: self.spec(a) for a in todo}
        for a, s in specs.items():
            probs += ["%s: %s" % (NAMES[a], w) for w in self.app_problems(s, doc)]
        cur_cfg = read(self.config)
        if cur_cfg is not None and (rec.get("configSha") is None or sha(cur_cfg) != rec["configSha"]):
            probs.append("%s exists and isn't the installer's (or you edited it): move it away first" % self.config)
        if probs:
            raise I.Refused(probs)
        gen = self.render_outputs(todo)
        plan = {}
        for a, s in specs.items():
            if s.way == "hypr":
                plan[a] = None
                continue
            old = read(s.main)
            if s.way == "ini":
                new, prev = ini_set(old.decode(), {"color_scheme_path": s.gen, "custom_palette": "true"})
                plan[a] = {"old": old, "new": new.encode(), "prev": prev, "block": None,
                           "ours": {"color_scheme_path": s.gen, "custom_palette": "true"}}
            else:
                o = old or b""
                block = s.block(mid)
                if block.encode() in o or (">>> sumi-shell theme-apps").encode() in o:
                    raise I.Refused(["%s already has sumi-shell theme-apps lines: remove them by hand" % s.main])
                if s.way == "end":
                    new = o + (b"\n" if o and not o.endswith(b"\n") else b"") + block.encode()
                else:
                    new = block.encode() + o
                plan[a] = {"old": old, "new": new, "block": block, "addedNewline": bool(o) and not o.endswith(b"\n")}
        all_apps = sorted(applied | set(todo), key=APPS.index)
        cfg_new = self.render_config(all_apps, mid)
        rec["pending"] = {"op": "apply", "apps": todo}
        return self.run_tx(doc, "theme-apps-apply", rec,
                           lambda tx: self.apply_steps(doc, rec, specs, plan, gen, cfg_new))

    def apply_steps(self, doc, rec, specs, plan, gen, cfg_new):
        for a, s in specs.items():
            r = {"status": "applying", "main": s.main, "gen": s.gen, "way": s.way, "dirs": [],
                 "at": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
            rec["apps"][a] = r
            self.it.step(doc, "gen-" + a, lambda s=s, a=a, r=r: self.write_or_replace(s.gen, gen[a], doc, s.app + ".gen",
                                                                                       dirs=r["dirs"]))
            p = plan[a]
            if p is not None:
                res = {}

                # lo previsto, apuntado ANTES de escribir: si el proceso muere justo después, `recover` sabe qué bloque
                # buscar y si el archivo era nuevo (entonces se borra, no se deja vacío)
                r.update(created=p["old"] is None, shaAfter=sha(p["new"]), block=p.get("block"),
                         addedNewline=p.get("addedNewline", False), prev=p.get("prev"), ours=p.get("ours"))

                def main(s=s, p=p, res=res):
                    res["r"], res["info"] = self.write_or_replace(
                        s.main, p["new"], doc, os.path.basename(s.main) + ".before",
                        want=sha(p["old"]) if p["old"] is not None else None, dirs=r["dirs"])
                self.it.step(doc, "main-" + a, main)
                if res["r"] in ("changed", "conflict"):
                    self.remove_ours(s.gen)
                    rec["apps"].pop(a, None)
                    raise I.Refused(["%s changed while it was being written: nothing was changed for %s, run it again"
                                     % (s.main, NAMES[a])] + (["both versions are kept: %s" % json.dumps(res["info"])]
                                                              if res["r"] == "conflict" else []))
                if res["r"] == "done":
                    rec["kept"].append({"rel": res["info"], "sha": sha(p["old"]), "why": "%s before theme-apps" % s.main})
                r["created"] = res["r"] == "created"
            r["status"] = "applied"
        self.it.step(doc, "config", lambda: self.put_config(doc, rec, cfg_new))
        rec["status"] = "applied"
        rec.pop("pending", None)
        self.reload(specs, applying=True)
        self.say("Applied: %s. The shell's theme provider now keeps them in step with the theme (%s)." % (
            ", ".join(NAMES[a] for a in specs), self.config))
        if any(a in ("gtk3", "gtk4") for a in specs):
            self.say("GTK apps already open keep their colours until reopened (GTK 4 follows light/dark on its own).")
        return I.EXIT_OK

    def put_config(self, doc, rec, cfg_new):
        if cfg_new is None:
            r = G.remove_fragment(self.config, self.roots, rec.get("configSha")) if rec.get("configSha") else "absent"
            rec["configSha"] = None if r in ("removed", "absent") else rec.get("configSha")
            if rec["configSha"] is None:
                rec["dirs"] = self.remove_dirs(rec.get("dirs"))
            return
        rec.setdefault("dirs", [])
        r, info = self.write_or_replace(self.config, cfg_new, doc, CONFIG_NAME + ".before", want=rec.get("configSha"),
                                        dirs=rec["dirs"])
        if r in ("changed", "conflict"):
            raise I.Refused(["%s was edited: it is left as it is (the installer stops managing it)" % self.config])
        rec["configSha"] = sha(cfg_new)

    def reload(self, specs, applying):
        """Las recargas que no esperan al siguiente cambio de tema: kitty, Qt y (al aplicar) el borde."""
        for a, s in specs.items():
            if s.way == "hypr" and not applying:
                self.say("  %s: the border goes back to your configuration at the next Hyprland reload" % NAMES[a])
                continue
            if s.hook and (s.way != "ini" or os.path.exists(s.main)):
                try:
                    subprocess.run(["sh", "-c", s.hook], capture_output=True, timeout=10)
                except (OSError, subprocess.TimeoutExpired):
                    pass

    # -- revertir --
    def revert(self, doc, rec, apps):
        doc = self.it.need_install()
        rec = (doc.get("integrations") or {}).get(KIND)
        applied = [a for a, r in ((rec or {}).get("apps") or {}).items() if r.get("status") == "applied"]
        todo = sorted((a for a in (apps or applied) if a in applied), key=APPS.index)
        if not todo:
            self.say("Nothing to revert for theme-apps.")
            return I.EXIT_OK
        rest = [a for a in applied if a not in todo]
        cfg_new = self.render_config(sorted(rest, key=APPS.index), doc["id"]) if rest else None
        rec["pending"] = {"op": "revert", "apps": todo}
        return self.run_tx(doc, "theme-apps-revert", rec, lambda tx: self.revert_steps(doc, rec, todo, cfg_new))

    def revert_steps(self, doc, rec, todo, cfg_new):
        problems = []
        specs = {}
        for a in todo:
            r = rec["apps"][a]
            s = self.spec(a)
            specs[a] = s
            res = {"r": "ok"}

            def main(r=r, s=s, res=res):
                if r.get("way") == "hypr":
                    return
                cur = read(r["main"])
                if cur is None:
                    res["r"] = "gone"
                    return
                if r["way"] == "ini":
                    new, changed = ini_restore(cur.decode(), r.get("ours") or {}, r.get("prev") or {})
                    if changed:
                        res["note"] = "%s: you changed %s after it was set up: left as you set it" % (r["main"], ", ".join(changed))
                    new = new.encode()
                else:
                    block = r["block"].encode()
                    n = cur.count(block)
                    if n == 0:
                        res["r"] = "edited" if b">>> sumi-shell theme-apps" in cur else "absent"
                        return
                    if n > 1:
                        res["r"] = "many"
                        return
                    if r.get("created") and cur == block:
                        res["r"] = G.remove_fragment(r["main"], self.roots, sha(cur))
                        return
                    full = (b"\n" + block) if r.get("addedNewline") and r["way"] == "end" else block
                    new = cur.replace(full, b"", 1) if cur.count(full) == 1 else cur.replace(block, b"", 1)
                if new == cur:
                    return
                st = os.lstat(r["main"])
                rr, info = G.replace_file(r["main"], self.roots, st.st_ino, sha(cur), new, doc["transaction"]["id"],
                                          os.path.basename(r["main"]) + ".with-theme-apps", doc["createdDirs"])
                res["r"] = rr
                if rr == "done":
                    rec["kept"].append({"rel": info, "sha": sha(cur), "why": "%s with theme-apps, before reverting" %
                                        r["main"], "redundant": True})
                elif rr == "conflict":
                    res["info"] = info
            self.it.step(doc, "main-" + a, main)
            if res["r"] == "edited":
                problems.append("the sumi-shell lines in %s were edited: left as they are; remove them by hand" % r["main"])
                continue
            if res["r"] == "many":
                problems.append("%s has the sumi-shell lines more than once: remove them by hand" % r["main"])
                continue
            if res["r"] in ("changed", "conflict"):
                problems.append("%s changed while it was being written: run it again%s" % (
                    r["main"], (" (both versions kept: %s)" % json.dumps(res.get("info"))) if res["r"] == "conflict" else ""))
                continue
            if res["r"] in ("absent", "gone"):
                self.say("  %s: the sumi-shell lines are no longer in %s: left as it is" % (NAMES[a], r["main"]))
            if res.get("note"):
                self.say("  " + res["note"])
            g = {}
            self.it.step(doc, "gen-" + a, lambda r=r, g=g: g.update(r=self.remove_ours(r.get("gen") or s.gen)))
            if g.get("r") == "kept":
                self.say("  %s was replaced by another file: it is kept" % (r.get("gen") or s.gen))
            r["dirs"] = self.remove_dirs(r.get("dirs"))
            r["status"] = "reverted"
        if problems:
            rest = [a for a, r in rec["apps"].items() if r.get("status") == "applied"]
            cfg_new = self.render_config(sorted(rest, key=APPS.index), doc["id"]) if rest else None
        self.it.step(doc, "config", lambda: self.put_config(doc, rec, cfg_new))
        rec["status"] = "applied" if any(r.get("status") == "applied" for r in rec["apps"].values()) else "reverted"
        rec.pop("pending", None)
        self.it.prune_kept(rec)
        self.reload({a: s for a, s in specs.items() if rec["apps"][a].get("status") == "reverted"}, applying=False)
        if problems:
            raise I.Refused(problems)
        self.say("Reverted: %s." % ", ".join(NAMES[a] for a in todo))
        return I.EXIT_OK

    # -- transacción (la de F6d, como integrations.run_tx) --
    def run_tx(self, doc, op, rec, body):
        lock = I.take_lock()
        try:
            fresh = self.man.load()
            if fresh is None or fresh.get("transaction"):
                raise I.Refused(["the installation changed meanwhile: run it again"])
            doc.update(fresh)
            doc.setdefault("integrations", {})[KIND] = rec
            doc["transaction"] = {"id": uuid.uuid4().hex[:12], "op": op, "pid": os.getpid(), "steps": {}, "staging": "",
                                  "linksBefore": None}
            self.man.save(doc)
            try:
                rc = body(doc["transaction"])
            except I.Interrupted as e:
                self.say("Interrupted (%s): run `install.sh recover`." % e)
                return I.EXIT_PENDING
            except I.Refused:
                doc["transaction"] = None
                rec.pop("pending", None)
                rec["apps"] = {a: r for a, r in rec["apps"].items() if r.get("status") != "applying"}
                if not rec["apps"]:
                    doc["integrations"].pop(KIND, None)
                self.man.save(doc)
                raise
            rec["history"].append({"op": op, "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "result": rec["status"],
                                   "apps": sorted(a for a, r in rec["apps"].items() if r.get("status") == "applied")})
            doc["transaction"] = None
            self.man.save(doc)
            return rc
        finally:
            os.close(lock)

    # -- comprobar --
    def verify(self, doc, rec):
        if not rec:
            self.say("No theme-apps integration recorded.")
            return I.EXIT_OK
        probs = []
        for a, r in sorted(rec.get("apps", {}).items(), key=lambda x: APPS.index(x[0])):
            if r.get("status") != "applied":
                continue
            line = []
            if not is_ours(r["gen"]):
                line.append("%s is missing or not the shell's" % r["gen"])
            cur = read(r["main"]) if r.get("main") else b""
            if r.get("way") in ("end", "start") and (cur is None or r["block"].encode() not in cur):
                line.append("the sumi-shell lines are no longer in %s" % r["main"])
            if r.get("way") == "ini":
                for k, v in (r.get("ours") or {}).items():
                    if ini_get((cur or b"").decode(), k) != v:
                        line.append("%s in %s is no longer the shell's" % (k, r["main"]))
            self.say("  %-16s %s" % (NAMES[a], "; ".join(line) if line else "applied"))
            probs += line
        if rec.get("configSha") and sha(read(self.config) or b"") != rec["configSha"]:
            probs.append("%s was changed or removed" % self.config)
            self.say("  ! " + probs[-1])
        return I.EXIT_OK if not probs else I.EXIT_REFUSED

    # -- recuperar --
    def recover(self, doc, tx, apply):
        rec = (doc.get("integrations") or {}).get(KIND) or {}
        pend = rec.get("pending") or {}
        self.say("Pending %s for %s (steps: %s)." % (tx["op"], ", ".join(pend.get("apps") or []) or "?",
                                                     json.dumps(tx["steps"])))
        if not apply:
            self.say("Recovery undoes a half-applied theme-apps and finishes a half-reverted one, by evidence (only the "
                     "lines and files it recognises). Run `install.sh recover --apply`.")
            return I.EXIT_PENDING
        apps = [a for a in pend.get("apps") or [] if a in rec.get("apps", {})]
        for a in apps:
            rec["apps"][a]["status"] = "applied"
            r = rec["apps"][a]
            s = self.spec(a)
            r.setdefault("way", s.way)
            r.setdefault("gen", s.gen)
            r.setdefault("main", s.main)
            if r.get("block") is None and s.way in ("end", "start"):
                r["block"] = s.block(doc["id"])
            if s.way == "ini" and r.get("ours") is None:
                r["ours"] = {"color_scheme_path": s.gen, "custom_palette": "true"}
                r["prev"] = r.get("prev") or {}
        rest = [a for a, r in rec.get("apps", {}).items() if r.get("status") == "applied" and a not in apps]
        cfg_new = self.render_config(sorted(rest, key=APPS.index), doc["id"]) if rest else None
        doc["transaction"] = dict(tx, steps={})
        self.man.save(doc)
        try:
            rc = self.revert_steps(doc, rec, apps, cfg_new)
        except I.Refused as e:
            for r_ in e.reasons:
                self.say("  " + r_)
            rc = I.EXIT_REFUSED
        doc["transaction"] = None
        rec.setdefault("history", []).append({"op": "recover", "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                                              "result": rec.get("status")})
        self.man.save(doc)
        self.say(state_line(rec))
        return rc


def state_line(rec):
    on = [NAMES[a] for a in APPS if ((rec.get("apps") or {}).get(a) or {}).get("status") == "applied"]
    return "theme-apps · %s" % (("applied: " + ", ".join(on) + " · config " + rec.get("config", "")) if on else
                                rec.get("status", "reverted"))


def run(installer_module, integrations_module, inst):
    global I, G
    I, G = installer_module, integrations_module
    G.I = installer_module
    t = ThemeApps(inst)
    doc = t.man.load()
    rec = ((doc or {}).get("integrations") or {}).get(KIND)
    apps = t.wanted()
    if inst.args.verify:
        return t.verify(doc, rec)
    if inst.args.revert:
        return t.revert(doc, rec, apps)
    if inst.args.apply:
        return t.apply(doc, rec, apps)
    return t.preview(doc, rec, apps)


def recover(installer_module, integrations_module, inst, doc, tx, apply):
    global I, G
    I, G = installer_module, integrations_module
    G.I = installer_module
    return ThemeApps(inst).recover(doc, tx, apply)
