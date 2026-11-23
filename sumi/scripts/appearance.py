#!/usr/bin/env python3
"""Apariencia (2026-11-13) · temas de iconos y de cursor en la shell y en otras apps. Salida: UNA línea JSON.

  appearance.py overview [--stamp S]          temas instalados, lo que usa cada app, lo gestionado (sólo lectura).
                                              Con --stamp igual a la huella de lo instalado: {"unchanged": true}
  appearance.py icons --theme T [--names a,b] [--size N]   rutas de iconos reales del tema (herencia incluida) al
                                              tamaño N (48; 24 = los de barra), sin aplicarlo
  appearance.py cursors --theme T --size N    PNG de cinco punteros del tema (caché en ~/.cache/sumi-appearance)
  appearance.py plan [--icons T] [--cursor C] [--size N]
                                              qué cambiaría en cada destino; `token` resume el plan (sólo lectura)
  appearance.py apply --expect TOKEN [--icons T] [--cursor C] [--size N]
                                              aplica SÓLO si el plan sigue siendo el que se enseñó
  appearance.py status                        lo gestionado y si sigue en vigor
  appearance.py rollback (--tx ID | --all)    volver a lo de antes; un cambio tuyo posterior no se pisa
  appearance.py recover                       terminar una aplicación cortada (diario en el registro)
  appearance.py session-start                 volver a dar a Hyprland el cursor aplicado (no guarda nada en su config)

Destinos (cada uno por separado; lo que no existe o no se usa aquí se informa y no se escribe):
  gtk.icons gtk.cursor gtk.cursorSize    GSettings org.gnome.desktop.interface (GTK 3 en Wayland, en vivo)
  gtk4.icons gtk4.cursor gtk4.cursorSize gtk-4.0/settings.ini (GTK 4 lo lee al abrir; sin archivo se crea)
  gtk3.icons gtk3.cursor gtk3.cursorSize gtk-3.0/settings.ini (GTK 3 por X11/XWayland sin XSettings; sólo si existe)
  qt6.icons / qt5.icons                  [Appearance] icon_theme de qt6ct/qt5ct, sólo si esa sesión los usa
  hyprland.cursor                        `hyprctl setcursor`: en vivo y sólo en ESTA sesión; la shell lo repite al
                                         arrancar. Tu configuración de Hyprland (XCURSOR_THEME…) no se toca.
No se gestionan (se informa): XSettings (xsettingsd), ~/.icons/default (lo escribe nwg-look), el entorno de login.

Modelo de font-sync.py (mismo núcleo, font_sync_core): rutas sólo bajo XDG_CONFIG_HOME sin seguir enlaces,
sustitución atómica con guarda de inodo + sha, registro {before, set} por destino, diario antes de escribir y vuelta
atrás que se niega ante un valor que ya no es el nuestro.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import font_sync_core as core              # noqa: E402
import appearance_themes as themes          # noqa: E402

GSCHEMA = "org.gnome.desktop.interface"
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+ -]{0,100}$")
SIZES = (16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 96)
WHAT_LABEL = {"icons": "icons", "cursor": "cursor", "cursorSize": "cursor size"}

# slot: (adaptador, qué, clave, etiqueta, cuándo se nota)
SLOTS = [
    ("gtk.icons", "gsettings", "icons", "icon-theme", "GTK 3 icons (GSettings)", "live"),
    ("gtk.cursor", "gsettings", "cursor", "cursor-theme", "GTK 3 cursor (GSettings)", "live"),
    ("gtk.cursorSize", "gsettings", "cursorSize", "cursor-size", "GTK 3 cursor size (GSettings)", "live"),
    ("gtk4.icons", "gtk4", "icons", "gtk-icon-theme-name", "GTK 4 icons (settings.ini)", "reopen"),
    ("gtk4.cursor", "gtk4", "cursor", "gtk-cursor-theme-name", "GTK 4 cursor (settings.ini)", "reopen"),
    ("gtk4.cursorSize", "gtk4", "cursorSize", "gtk-cursor-theme-size", "GTK 4 cursor size (settings.ini)", "reopen"),
    ("gtk3.icons", "gtk3", "icons", "gtk-icon-theme-name", "GTK 3 icons over X11 (settings.ini)", "reopen"),
    ("gtk3.cursor", "gtk3", "cursor", "gtk-cursor-theme-name", "GTK 3 cursor over X11 (settings.ini)", "reopen"),
    ("gtk3.cursorSize", "gtk3", "cursorSize", "gtk-cursor-theme-size", "GTK 3 cursor size over X11 (settings.ini)",
     "reopen"),
    ("qt6.icons", "qt6", "icons", "icon_theme", "Qt 6 icons (qt6ct)", "live"),
    ("qt5.icons", "qt5", "icons", "icon_theme", "Qt 5 icons (qt5ct)", "live"),
    ("hyprland.cursor", "hyprland", "cursor", "", "Hyprland cursor (this session)", "live"),
]
SLOT = {s[0]: s for s in SLOTS}
ORDER = [s[0] for s in SLOTS]


def out(doc, code=None):
    print(json.dumps(doc, ensure_ascii=False))
    sys.exit(code if code is not None else (0 if doc.get("ok", True) else 1))


# ---- INI sencillo (settings.ini de GTK, qt*ct.conf): se edita LA línea; el resto, byte a byte igual ------------------

def ini_find(text, section, key):
    lines, sec, hits, last_in_sec, header = text.split("\n"), None, [], None, None
    for i, line in enumerate(lines):
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            sec = s[1:-1]
            if sec == section and header is None:
                header = i
            continue
        if sec != section:
            continue
        if s and not s.startswith(("#", ";")):
            last_in_sec = i
        m = re.match(r"^(\s*%s\s*=\s*)(.*?)(\s*)$" % re.escape(key), line)
        if m:
            hits.append((i, m.group(1), m.group(2), m.group(3)))
    if len(hits) > 1:
        raise core.Refused("[%s] %s appears more than once" % (section, key))
    return (hits[0] if hits else None), header, last_in_sec


def ini_get(text, section, key):
    hit = ini_find(text, section, key)[0]
    if not hit:
        return None
    v = hit[2]
    return v[1:-1] if len(v) >= 2 and v[0] == v[-1] == '"' else v


def ini_set(text, section, key, value):
    hit, header, last = ini_find(text, section, key)
    lines = text.split("\n")
    if hit:
        i, pre, raw, post = hit
        quoted = len(raw) >= 2 and raw[0] == raw[-1] == '"'
        lines[i] = pre + ('"%s"' % value if quoted else str(value)) + post
    elif header is not None:
        lines.insert((last if last is not None else header) + 1, "%s=%s" % (key, value))
    else:
        while lines and lines[-1] == "":
            lines.pop()
        lines += ([""] if lines else []) + ["[%s]" % section, "%s=%s" % (key, value), ""]
    return "\n".join(lines)


def ini_unset(text, section, key):
    hit = ini_find(text, section, key)[0]
    if not hit:
        return text
    lines = text.split("\n")
    del lines[hit[0]]
    return "\n".join(lines)


# ---- contexto -------------------------------------------------------------------------------------------------------

class Ctx:
    def __init__(self):
        self.paths = core.Paths()
        self.paths.sync_state = os.path.join(self.paths.state, "sumi-shell", "appearance-sync")
        self.ledger = core.Ledger(self.paths).load()
        self._scan = None
        self._gs = None

    @property
    def scan(self):
        if self._scan is None:
            self._scan = themes.scan()
        return self._scan

    def icon_names(self):
        return [i["name"] for i in self.scan["icons"]]

    def cursor_names(self):
        return [c["name"] for c in self.scan["cursors"]]

    # -- GSettings --
    def gs(self):
        if self._gs is None:
            try:
                import gi
                gi.require_version("Gio", "2.0")
                from gi.repository import Gio
            except (ImportError, ValueError) as e:
                raise core.Refused("python-gobject (gi) isn't available: %s" % e)
            src = Gio.SettingsSchemaSource.get_default()
            schema = src.lookup(GSCHEMA, True) if src else None
            if schema is None:
                raise core.Refused("the GSettings schema %s isn't installed (gsettings-desktop-schemas)" % GSCHEMA)
            backend = type(Gio.SettingsBackend.get_default()).__name__
            if "Memory" in backend or "Null" in backend:
                raise core.Refused("GSettings has no persistent storage here (%s backend)" % backend)
            self._gio = Gio
            self._gs = Gio.Settings.new(GSCHEMA)
        return self._gs

    def gs_read(self, key):
        s = self.gs()
        v = s.get_int(key) if key == "cursor-size" else s.get_string(key)
        return v, s.get_user_value(key) is not None

    def gs_readback(self, key):
        """Desde OTRO proceso: la caché de este no prueba que se guardó."""
        code = ("import sys,gi\ngi.require_version('Gio','2.0')\nfrom gi.repository import Gio\n"
                "s=Gio.Settings.new(sys.argv[1]);k=sys.argv[2]\nprint(s.get_int(k) if k=='cursor-size' else s.get_string(k))")
        try:
            r = subprocess.run([sys.executable, "-I", "-c", code, GSCHEMA, key], capture_output=True, text=True,
                               timeout=15)
        except (OSError, subprocess.TimeoutExpired):
            return None
        return r.stdout.strip() if r.returncode == 0 else None

    def gs_write(self, key, value):
        s = self.gs()
        ok = s.set_int(key, int(value)) if key == "cursor-size" else s.set_string(key, str(value))
        self._gio.Settings.sync()
        return ok

    def gs_reset(self, key):
        self.gs().reset(key)
        self._gio.Settings.sync()

    # -- archivos --
    def file_of(self, adapter):
        return {"gtk4": os.path.join(self.paths.config, "gtk-4.0", "settings.ini"),
                "gtk3": os.path.join(self.paths.config, "gtk-3.0", "settings.ini"),
                "qt6": os.path.join(self.paths.config, "qt6ct", "qt6ct.conf"),
                "qt5": os.path.join(self.paths.config, "qt5ct", "qt5ct.conf")}[adapter]

    @staticmethod
    def section_of(adapter):
        return "Appearance" if adapter in ("qt6", "qt5") else "Settings"

    def qt_in_use(self, adapter):
        pt = os.environ.get("QT_QPA_PLATFORMTHEME", "")
        if adapter == "qt6":
            return pt == "qt6ct", "QT_QPA_PLATFORMTHEME is «%s», not qt6ct" % pt
        try:
            import font_sync_qt5ct
            keys, src = font_sync_qt5ct.plugin_keys()
        except Exception as e:                       # noqa: BLE001 — sólo informa
            return False, "Qt 5 plugin check failed: %s" % e
        return pt in keys, ("Qt 5 apps don't load qt5ct here (QT_QPA_PLATFORMTHEME «%s»; %s)" % (pt, src))

    # -- Hyprland --
    def hypr_env(self):
        theme = os.environ.get("HYPRCURSOR_THEME") or os.environ.get("XCURSOR_THEME") or ""
        try:
            size = int(os.environ.get("HYPRCURSOR_SIZE") or os.environ.get("XCURSOR_SIZE") or 0)
        except ValueError:
            size = 0
        return theme, size

    def hypr_available(self):
        return bool(os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"))

    def hypr_setcursor(self, theme, size):
        if not NAME_RE.match(theme or "") or " " in theme:
            return False, "the cursor name can't be passed to hyprctl safely"
        try:
            r = subprocess.run(["hyprctl", "setcursor", theme, str(int(size))], capture_output=True, text=True,
                               timeout=10)
        except (OSError, subprocess.TimeoutExpired) as e:
            return False, "hyprctl failed: %s" % e
        txt = (r.stdout + r.stderr).strip()
        return r.returncode == 0 and txt.lower().startswith("ok"), txt[:200]


# ---- lectura de cada destino ---------------------------------------------------------------------------------------

def read_slot(ctx, slot):
    """{"value", "state": available|unavailable|missing-file, "reason", y para archivos "sha"/"ino"/"exists"}."""
    _, ad, what, key, _, _ = SLOT[slot]
    if ad == "gsettings":
        try:
            v, user = ctx.gs_read(key)
        except core.Refused as e:
            return {"state": "unavailable", "reason": str(e)}
        return {"state": "available", "value": v, "userSet": user}
    if ad == "hyprland":
        if not ctx.hypr_available():
            return {"state": "unavailable", "reason": "Hyprland isn't running in this session"}
        e = ctx.ledger.entries.get(slot)
        theme, size = ctx.hypr_env()
        if e:
            return {"state": "available", "value": e["set"]["theme"], "size": e["set"]["size"],
                    "source": "applied by the shell", "login": {"theme": theme, "size": size}}
        return {"state": "available", "value": theme, "size": size, "source": "session start",
                "login": {"theme": theme, "size": size}}
    if ad in ("qt6", "qt5"):
        ok, why = ctx.qt_in_use(ad)
        if not ok:
            return {"state": "unavailable", "reason": why}
    path = ctx.file_of(ad)
    probs = core.file_problems(ctx.paths, path, must_exist=False)
    if probs:
        return {"state": "unavailable", "reason": probs[0], "path": path}
    st, data = core.read_file(ctx.paths, path)
    if data is None:
        return {"state": "missing-file", "path": path, "value": None, "exists": False}
    try:
        v = ini_get(data.decode("utf-8"), ctx.section_of(ad), key)
    except (core.Refused, UnicodeDecodeError) as e:
        return {"state": "unavailable", "reason": str(e), "path": path}
    if what == "cursorSize" and v is not None:
        try:
            v = int(v)
        except ValueError:
            pass
    return {"state": "available", "value": v, "path": path, "exists": True, "sha": core.sha(data), "ino": st.st_ino}


# ---- plan ----------------------------------------------------------------------------------------------------------

def want_of(a):
    return {"icons": a.icons or None, "cursor": a.cursor or None, "cursorSize": a.size or None}


def validate_want(ctx, want):
    errs = {}
    if want["icons"] is not None:
        if not NAME_RE.match(want["icons"]) or want["icons"] != want["icons"].strip():
            errs["icons"] = "«%s» isn't a valid theme name" % want["icons"]
        elif want["icons"] not in ctx.icon_names():
            errs["icons"] = "The icon theme «%s» isn't installed" % want["icons"]
    if want["cursor"] is not None:
        if not NAME_RE.match(want["cursor"]) or " " in want["cursor"]:
            errs["cursor"] = "«%s» isn't a valid cursor theme name" % want["cursor"]
        elif want["cursor"] not in ctx.cursor_names():
            errs["cursor"] = "The cursor theme «%s» isn't installed" % want["cursor"]
    if want["cursorSize"] is not None and not (8 <= int(want["cursorSize"]) <= 256):
        errs["cursorSize"] = "Cursor size must be between 8 and 256"
    return errs


def plan_slot(ctx, slot, want, errs):
    _, ad, what, key, label, restart = SLOT[slot]
    base = {"slot": slot, "target": ad, "what": what, "label": label, "restart": restart, "notes": []}
    w = want[what]
    if ad == "hyprland":
        w = want["cursor"] if (want["cursor"] or want["cursorSize"]) else None
    if w is None:
        return dict(base, action="off")
    if what in errs or (ad == "hyprland" and ("cursor" in errs or "cursorSize" in errs)):
        return dict(base, action="blocked", reason=errs.get(what) or errs.get("cursor") or errs.get("cursorSize"))
    cur = read_slot(ctx, slot)
    if cur["state"] == "unavailable":
        return dict(base, action="unavailable", reason=cur["reason"])
    if ad == "hyprland":
        theme = want["cursor"] or cur["value"]
        size = int(want["cursorSize"] or cur.get("size") or 24)
        if not theme:
            return dict(base, action="blocked", reason="No cursor theme to give Hyprland")
        base.update(current="%s · %s" % (cur["value"] or "default", cur.get("size") or "?"),
                    fingerprint={"theme": cur["value"], "size": cur.get("size")})
        info = next((c for c in ctx.scan["cursors"] if c["name"] == theme), {})
        notes = ["Not kept by Hyprland after you log out: the shell gives it again each time it starts",
                 "Your Hyprland config is not changed: at login it still sets %s %s"
                 % (cur["login"]["theme"] or "its default", cur["login"]["size"] or "")]
        if info and not info.get("hyprcursor"):
            notes.append("XCursor theme: Hyprland draws it without hyprcursor (fine; slightly less sharp when scaled)")
        notes.append("XWayland apps take XCURSOR_THEME from your login environment until they restart after a new login")
        if cur["value"] == theme and int(cur.get("size") or 0) == size and cur.get("source") == "applied by the shell":
            return dict(base, action="unchanged", reason="Already %s · %d" % (theme, size), notes=notes)
        return dict(base, action="change", proposed="%s · %d" % (theme, size), proposedRaw={"theme": theme, "size": size},
                    notes=notes)
    value = int(w) if what == "cursorSize" else w
    if cur["state"] == "missing-file":
        if ad == "gtk3":
            return dict(base, action="skip", reason="No gtk-3.0/settings.ini: GTK 3 reads GSettings on Wayland")
        if ad in ("qt6", "qt5"):
            tool = "qt6ct" if ad == "qt6" else "qt5ct"
            return dict(base, action="unavailable", reason="%s has no configuration yet: open %s once and press OK"
                        % (tool, tool))
        base.update(current=None, fingerprint={"exists": False})
        return dict(base, action="change", proposed=value, proposedRaw=value,
                    notes=["%s doesn't exist yet: it will be created with only this setting" % cur["path"]])
    if ad in ("gtk4", "gtk3", "qt6", "qt5"):
        base["fingerprint"] = {"exists": True, "sha": cur["sha"], "ino": cur["ino"]}
        if ad in ("qt6", "qt5") and cur["value"] is None:
            base["notes"].append("%s has no icon theme yet: it will be added" % os.path.basename(cur["path"]))
    else:
        base["fingerprint"] = {"value": cur["value"], "userSet": cur.get("userSet")}
    base["current"] = cur["value"]
    if str(cur["value"]) == str(value):
        return dict(base, action="unchanged", reason="Already %s" % value)
    return dict(base, action="change", proposed=value, proposedRaw=value)


def make_plan(ctx, want):
    errs = validate_want(ctx, want)
    slots = [plan_slot(ctx, s, want, errs) for s in ORDER]
    sig = [[p["slot"], p["action"], p.get("fingerprint"), p.get("proposedRaw")] for p in slots]
    token = hashlib.sha256(json.dumps([want, sig], sort_keys=True).encode()).hexdigest()[:24]
    return {"ok": not errs, "want": want, "errors": errs, "slots": slots, "token": token,
            "changes": sum(1 for p in slots if p["action"] == "change")}


# ---- aplicar -------------------------------------------------------------------------------------------------------

def take_lock(paths):
    import fcntl
    d = os.path.join(paths.runtime, "sumi-shell")
    os.makedirs(d, mode=0o700, exist_ok=True)
    st = os.stat(d, follow_symlinks=False)
    if not os.path.isdir(d) or st.st_uid != os.getuid() or st.st_mode & 0o022:
        raise core.Refused("%s is not a folder only you can write to" % d)
    fd = os.open(os.path.join(d, "appearance-sync.lock"), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        raise core.Refused("another appearance change is running")
    return fd


def pending(ctx, slot, entry):
    ctx.ledger.doc.setdefault("pending", {})[slot] = entry
    ctx.ledger.save()


def settle(ctx, slot, entry):
    ctx.ledger.doc.setdefault("pending", {}).pop(slot, None)
    if entry is None:
        return
    if entry["set"] == entry["before"] and entry.get("kind") != "hyprland":
        ctx.ledger.entries.pop(slot, None)
    else:
        ctx.ledger.entries[slot] = entry


def apply_gsettings(ctx, p, tx):
    key = SLOT[p["slot"]][3]
    cur, user = ctx.gs_read(key)
    if cur != p["fingerprint"]["value"]:
        return {"result": "changed", "reason": "Changed since the preview: review again"}, None
    prev = ctx.ledger.entries.get(p["slot"])
    entry = {"kind": "gsettings", "key": key, "tx": tx, "before": prev["before"] if prev else cur,
             "beforeUserSet": prev["beforeUserSet"] if prev else user, "set": p["proposedRaw"]}
    pending(ctx, p["slot"], entry)
    ok = ctx.gs_write(key, p["proposedRaw"])
    back = ctx.gs_readback(key)
    if ok and back == str(p["proposedRaw"]):
        return {"result": "applied", "verified": "stored", "readback": back}, entry
    if ctx.gs_read(key)[0] == p["proposedRaw"]:
        ctx.gs_write(key, cur) if user else ctx.gs_reset(key)
    return {"result": "failed", "reason": "GSettings didn't keep the value (read back %r)" % back}, None


def apply_file(ctx, ad, plans, tx, txdir):
    """Todas las claves del mismo archivo en UNA sustitución atómica (o una creación)."""
    path = ctx.file_of(ad)
    sec = ctx.section_of(ad)
    st, data = core.read_file(ctx.paths, path)
    fp = plans[0]["fingerprint"]
    if any(p["fingerprint"] != fp for p in plans) or (data is None) != (not fp.get("exists")) \
            or (data is not None and (core.sha(data) != fp["sha"] or st.st_ino != fp["ino"])):
        return [(p, {"result": "changed", "reason": "%s changed since the preview" % path}, None) for p in plans]
    text = data.decode("utf-8") if data is not None else ""
    if data is not None:
        core.keep_copy(txdir, "%s-%s" % (ad, os.path.basename(path)), st, data)
    entries = []
    new = text
    for p in plans:
        key = SLOT[p["slot"]][3]
        prev = ctx.ledger.entries.get(p["slot"])
        before = prev["before"] if prev else ini_get(text, sec, key)
        entries.append({"kind": "ini", "file": path, "section": sec, "key": key, "tx": tx, "before": before,
                        "set": str(p["proposedRaw"]), "created": (prev or {}).get("created", data is None)})
        new = ini_set(new, sec, key, p["proposedRaw"])
    if data is None:
        new = "[%s]\n" % sec + "".join("%s=%s\n" % (SLOT[p["slot"]][3], p["proposedRaw"]) for p in plans)
    for p, e in zip(plans, entries):
        pending(ctx, p["slot"], e)
    blob = new.encode("utf-8")
    try:
        if data is None:
            created = []
            r = core.create(ctx.paths, path, blob, 0o644, created)
            for e in entries:
                e["createdDirs"] = created
                e["createdSha"] = core.sha(blob)
        else:
            r = core.replace(ctx.paths, path, st.st_ino, core.sha(data), blob)
    except core.Refused as e:
        return [(p, {"result": "failed", "reason": str(e)}, None) for p in plans]
    if r != "done":
        return [(p, {"result": "changed" if r in ("changed", "exists") else "conflict",
                     "reason": "%s changed while writing: nothing was changed" % path}, None) for p in plans]
    _, back = core.read_file(ctx.paths, path)
    res = []
    for p, e in zip(plans, entries):
        ok = back is not None and ini_get(back.decode("utf-8"), sec, e["key"]) == e["set"]
        res.append((p, {"result": "applied" if ok else "failed", "verified": "file" if ok else "",
                        "reason": "" if ok else "the value isn't in the file after writing"}, e if ok else None))
    return res


def apply_hypr(ctx, p, tx):
    prev = ctx.ledger.entries.get(p["slot"])
    theme, size = ctx.hypr_env()
    before = prev["before"] if prev else {"theme": p["fingerprint"]["theme"] or theme,
                                          "size": p["fingerprint"]["size"] or size}
    entry = {"kind": "hyprland", "tx": tx, "before": before, "set": p["proposedRaw"]}
    pending(ctx, p["slot"], entry)
    ok, txt = ctx.hypr_setcursor(p["proposedRaw"]["theme"], p["proposedRaw"]["size"])
    if ok:
        sig = re.sub(r"[^A-Za-z0-9_-]", "_", os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", ""))[:120]
        try:
            with open(os.path.join(ctx.paths.runtime, "sumi-shell", "appearance-cursor-" + sig), "w") as f:
                f.write("%s %s" % (p["proposedRaw"]["theme"], p["proposedRaw"]["size"]))
        except OSError:
            pass
        return {"result": "applied", "verified": "hyprctl", "readback": txt,
                "reason": "Hyprland doesn't report its cursor back: check it on screen"}, entry
    return {"result": "failed", "reason": "hyprctl setcursor: %s" % txt}, None


def cmd_apply(ctx, a):
    want = want_of(a)
    plan = make_plan(ctx, want)
    if plan["token"] != a.expect:
        out({"ok": False, "error": "plan-changed", "reason": "Something changed since the preview", "plan": plan})
    if not plan["ok"]:
        out({"ok": False, "error": "invalid", "reason": "; ".join(plan["errors"].values())})
    lock = take_lock(ctx.paths)
    try:
        ctx.ledger = core.Ledger(ctx.paths).load()
        if ctx.ledger.doc.get("pending"):
            out({"ok": False, "error": "pending", "reason": "A previous change was interrupted: recover first"})
        todo = [p for p in plan["slots"] if p["action"] == "change"]
        if not todo:
            out({"ok": True, "results": [], "tx": None, "want": want})
        tx, txdir = core.new_tx(ctx.paths)
        results = []
        for p in [p for p in todo if p["target"] == "gsettings"]:
            try:
                r, e = apply_gsettings(ctx, p, tx)
            except core.Refused as ex:
                r, e = {"result": "failed", "reason": str(ex)}, None
            settle(ctx, p["slot"], e)
            results.append(dict(r, slot=p["slot"], label=p["label"]))
        for ad in ("gtk4", "gtk3", "qt6", "qt5"):
            group = [p for p in todo if p["target"] == ad]
            if not group:
                continue
            for p, r, e in [(p, r, e) for p, r, e in apply_file(ctx, ad, group, tx, txdir)]:
                settle(ctx, p["slot"], e)
                results.append(dict(r, slot=p["slot"], label=p["label"]))
        for p in [p for p in todo if p["target"] == "hyprland"]:
            r, e = apply_hypr(ctx, p, tx)
            settle(ctx, p["slot"], e)
            results.append(dict(r, slot=p["slot"], label=p["label"]))
        ctx.ledger.doc["last"] = tx
        ctx.ledger.doc["want"] = {k: v for k, v in want.items() if v is not None} | \
            {k: v for k, v in (ctx.ledger.doc.get("want") or {}).items() if want.get(k) is None}
        ctx.ledger.note("apply", tx=tx, want=want, results=[{"slot": r["slot"], "result": r["result"]} for r in results])
        ctx.ledger.save()
        bad = [r for r in results if r["result"] != "applied"]
        out({"ok": not bad, "tx": tx, "results": results, "want": want, "partial": bool(bad) and len(bad) < len(results)})
    finally:
        os.close(lock)


# ---- volver atrás --------------------------------------------------------------------------------------------------

def classify(ctx, slot, e):
    """'set' (sigue lo nuestro) · 'before' (ya es lo de antes) · 'other' (cambio ajeno) · 'unknown'."""
    if e["kind"] == "hyprland":
        return "set"                               # Hyprland no informa: lo último aplicado es lo vigente
    cur = read_slot(ctx, slot)
    if cur["state"] not in ("available", "missing-file"):
        return "unknown"
    v = cur.get("value")
    if str(v) == str(e["set"]):
        return "set"
    if (v is None and e["before"] is None) or (v is not None and str(v) == str(e["before"])):
        return "before"
    return "other"


def rollback_entries(ctx, slots):
    res = []
    files = {}
    for slot in slots:
        e = ctx.ledger.entries.get(slot)
        if not e:
            continue
        c = classify(ctx, slot, e)
        label = SLOT[slot][4]
        if c == "before":
            ctx.ledger.entries.pop(slot, None)
            res.append({"slot": slot, "label": label, "result": "before"})
            continue
        if c != "set":
            res.append({"slot": slot, "label": label, "result": "conflict" if c == "other" else "failed",
                        "reason": "Changed by you since: left as it is" if c == "other" else "Can't read it now"})
            if c == "other":
                ctx.ledger.entries.pop(slot, None)
            continue
        if e["kind"] == "gsettings":
            try:
                ctx.gs_write(e["key"], e["before"]) if e["beforeUserSet"] else ctx.gs_reset(e["key"])
                ok = str(ctx.gs_read(e["key"])[0]) == str(e["before"])
            except core.Refused as ex:
                res.append({"slot": slot, "label": label, "result": "failed", "reason": str(ex)})
                continue
            if ok:
                ctx.ledger.entries.pop(slot, None)
            res.append({"slot": slot, "label": label, "result": "restored" if ok else "failed"})
        elif e["kind"] == "hyprland":
            b = e["before"]
            ok, txt = ctx.hypr_setcursor(b["theme"], b["size"] or 24) if b.get("theme") else (True, "nothing to give back")
            if ok:
                ctx.ledger.entries.pop(slot, None)
            res.append({"slot": slot, "label": label, "result": "restored" if ok else "failed", "reason": txt})
        else:
            files.setdefault(e["file"], []).append((slot, e))
    for path, items in files.items():
        st, data = core.read_file(ctx.paths, path)
        if data is None:
            for slot, e in items:
                ctx.ledger.entries.pop(slot, None)
                res.append({"slot": slot, "label": SLOT[slot][4], "result": "before"})
            continue
        text = data.decode("utf-8")
        new = text
        for slot, e in items:
            new = ini_unset(new, e["section"], e["key"]) if e["before"] is None else ini_set(new, e["section"], e["key"],
                                                                                            e["before"])
        created = items[0][1].get("created")
        blob = new.encode("utf-8")
        whole = len([1 for s, x in ctx.ledger.entries.items() if x.get("file") == path]) == len(items)
        if created and whole and new.strip() in ("", "[%s]" % items[0][1]["section"]):
            r = core.remove(ctx.paths, path, core.sha(data))
            core.remove_dirs(ctx.paths, items[0][1].get("createdDirs"))
        else:
            r = core.replace(ctx.paths, path, st.st_ino, core.sha(data), blob)
        for slot, e in items:
            if r in ("done", "absent"):
                ctx.ledger.entries.pop(slot, None)
            res.append({"slot": slot, "label": SLOT[slot][4], "result": "restored" if r in ("done", "absent") else "failed",
                        "reason": "" if r in ("done", "absent") else "%s changed while writing: try again" % path})
    return res


def cmd_rollback(ctx, a):
    lock = take_lock(ctx.paths)
    try:
        ctx.ledger = core.Ledger(ctx.paths).load()
        if a.all:
            slots = [s for s in ORDER if s in ctx.ledger.entries]
        else:
            slots = [s for s in ORDER if (ctx.ledger.entries.get(s) or {}).get("tx") == a.tx]
        res = rollback_entries(ctx, slots)
        if a.all and not any(r["result"] == "failed" for r in res):
            ctx.ledger.doc.pop("want", None)
        elif not ctx.ledger.entries:
            ctx.ledger.doc.pop("want", None)
        ctx.ledger.doc["last"] = max((e["tx"] for e in ctx.ledger.entries.values()), default=None)
        ctx.ledger.note("rollback", tx=a.tx, all=bool(a.all), results=[{"slot": r["slot"], "result": r["result"]} for r in res])
        ctx.ledger.save()
        out({"ok": not any(r["result"] == "failed" for r in res), "results": res})
    finally:
        os.close(lock)


def cmd_recover(ctx):
    lock = take_lock(ctx.paths)
    try:
        ctx.ledger = core.Ledger(ctx.paths).load()
        pend = ctx.ledger.doc.get("pending") or {}
        done = []
        for slot, e in list(pend.items()):
            c = classify(ctx, slot, e) if slot in SLOT else "unknown"
            if c == "set":
                settle(ctx, slot, e)
                done.append({"slot": slot, "result": "kept"})
            else:
                pend.pop(slot, None)
                done.append({"slot": slot, "result": "dropped"})
        ctx.ledger.doc["pending"] = {}
        ctx.ledger.note("recover", results=done)
        ctx.ledger.save()
        out({"ok": True, "results": done})
    finally:
        os.close(lock)


# ---- estado --------------------------------------------------------------------------------------------------------

def status_doc(ctx):
    managed = []
    icons, cursors = set(ctx.icon_names()), set(ctx.cursor_names())
    for slot in ORDER:
        e = ctx.ledger.entries.get(slot)
        if not e:
            continue
        what = SLOT[slot][2]
        c = classify(ctx, slot, e)
        val = e["set"]["theme"] if e["kind"] == "hyprland" else e["set"]
        missing = (what == "icons" and val not in icons) or (what == "cursor" and val not in cursors)
        managed.append({"slot": slot, "label": SLOT[slot][4], "tx": e["tx"], "set": e["set"], "before": e["before"],
                        "state": "missing-theme" if missing else {"set": "in-effect", "before": "back-to-before",
                                                                   "other": "changed-by-you"}.get(c, "unknown")})
    return {"managed": managed, "last": ctx.ledger.doc.get("last"), "want": ctx.ledger.doc.get("want") or {},
            "pending": sorted((ctx.ledger.doc.get("pending") or {}).keys())}


def desktop_doc():
    """Lo que no es tema de iconos ni de cursor, sólo para enseñarlo (GTK, Qt, XSettings)."""
    home = os.path.expanduser("~")
    cfg = os.environ.get("XDG_CONFIG_HOME") or os.path.join(home, ".config")
    gtk_themes = set()
    for d in [os.path.join(home, ".themes"), os.path.join(os.environ.get("XDG_DATA_HOME") or home + "/.local/share",
                                                          "themes")] + \
            [os.path.join(x, "themes") for x in (os.environ.get("XDG_DATA_DIRS") or "/usr/share").split(":") if x]:
        try:
            for n in os.listdir(d):
                if os.path.isdir(os.path.join(d, n, "gtk-3.0")) or os.path.isdir(os.path.join(d, n, "gtk-4.0")):
                    gtk_themes.add(n)
        except OSError:
            pass
    doc = {"gtkThemes": sorted(gtk_themes, key=str.casefold), "qtPlatformTheme": os.environ.get("QT_QPA_PLATFORMTHEME", "")}
    for tool in ("qt6ct", "qt5ct"):
        try:
            t = open(os.path.join(cfg, tool, tool + ".conf"), encoding="utf-8").read()
            doc[tool] = {"style": ini_get(t, "Appearance", "style"), "iconTheme": ini_get(t, "Appearance", "icon_theme"),
                         "customPalette": ini_get(t, "Appearance", "custom_palette")}
        except (OSError, UnicodeDecodeError, core.Refused):
            doc[tool] = None
    for v in ("gtk-3.0", "gtk-4.0"):
        try:
            t = open(os.path.join(cfg, v, "settings.ini"), encoding="utf-8").read()
            doc[v] = {"theme": ini_get(t, "Settings", "gtk-theme-name")}
        except (OSError, UnicodeDecodeError, core.Refused):
            doc[v] = None
    try:
        xs = {}
        for line in open(os.path.join(cfg, "xsettingsd", "xsettingsd.conf"), encoding="utf-8"):
            m = re.match(r'^\s*(\S+)\s+"?([^"]*)"?\s*$', line)
            if m and m.group(1) in ("Net/ThemeName", "Net/IconThemeName", "Gtk/CursorThemeName", "Gtk/CursorThemeSize"):
                xs[m.group(1)] = m.group(2)
        doc["xsettings"] = xs
    except OSError:
        doc["xsettings"] = None
    doc["kvantum"] = os.path.isdir(os.path.join(cfg, "Kvantum"))
    return doc


def cmd_overview(ctx, a):
    st = themes.stamp()
    if a.stamp and a.stamp == st:
        out({"ok": True, "unchanged": True, "stamp": st})
    targets = {}
    for slot in ORDER:
        r = read_slot(ctx, slot)
        r.pop("sha", None)
        r.pop("ino", None)
        targets[slot] = dict(r, label=SLOT[slot][4], what=SLOT[slot][2], restart=SLOT[slot][5])
    gtk_theme = None
    try:
        gtk_theme = ctx.gs().get_string("gtk-theme")
        scheme = ctx.gs().get_string("color-scheme")
    except core.Refused:
        scheme = None
    d = desktop_doc()
    d.update(gtkTheme=gtk_theme, colorScheme=scheme)
    out({"ok": True, "stamp": st, "scan": ctx.scan, "targets": targets, "status": status_doc(ctx), "desktop": d,
         "fallback": themes.FALLBACK})


def cmd_session_start(ctx):
    e = ctx.ledger.entries.get("hyprland.cursor")
    if not e:
        out({"ok": True, "applied": False, "reason": "nothing managed"})
    if not ctx.hypr_available():
        out({"ok": False, "applied": False, "reason": "Hyprland isn't running"})
    if e["set"]["theme"] not in ctx.cursor_names():
        out({"ok": False, "applied": False, "reason": "missing-theme", "theme": e["set"]["theme"]})
    # una vez por instancia de Hyprland: una recarga de la shell no lo repite (la marca vive en el runtime)
    sig = re.sub(r"[^A-Za-z0-9_-]", "_", os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", ""))[:120]
    mark = os.path.join(ctx.paths.runtime, "sumi-shell", "appearance-cursor-" + sig)
    want = "%s %s" % (e["set"]["theme"], e["set"]["size"])
    try:
        if open(mark).read() == want:
            out({"ok": True, "applied": False, "reason": "already given in this session"})
    except OSError:
        pass
    ok, txt = ctx.hypr_setcursor(e["set"]["theme"], e["set"]["size"])
    if ok:
        try:
            os.makedirs(os.path.dirname(mark), mode=0o700, exist_ok=True)
            with open(mark, "w") as f:
                f.write(want)
        except OSError:
            pass
    out({"ok": ok, "applied": ok, "theme": e["set"]["theme"], "size": e["set"]["size"], "hyprctl": txt})


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    o = sub.add_parser("overview")
    o.add_argument("--stamp", default="")
    i = sub.add_parser("icons")
    i.add_argument("--theme", required=True)
    i.add_argument("--names", default="")
    i.add_argument("--size", type=int, default=48)
    c = sub.add_parser("cursors")
    c.add_argument("--theme", required=True)
    c.add_argument("--size", type=int, default=32)
    for n in ("plan", "apply"):
        x = sub.add_parser(n)
        x.add_argument("--icons", default="")
        x.add_argument("--cursor", default="")
        x.add_argument("--size", type=int, default=0)
        if n == "apply":
            x.add_argument("--expect", required=True)
    sub.add_parser("status")
    r = sub.add_parser("rollback")
    g = r.add_mutually_exclusive_group(required=True)
    g.add_argument("--tx")
    g.add_argument("--all", action="store_true")
    sub.add_parser("recover")
    sub.add_parser("session-start")
    a = p.parse_args()
    try:
        if a.cmd == "icons":
            names = [x for x in a.names.split(",") if x] or themes.ICON_SAMPLES
            out({"ok": True, "theme": a.theme, "icons": themes.icon_preview(a.theme, names[:24], a.size)})
        if a.cmd == "cursors":
            cache = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
                                 "sumi-appearance", "cursors")
            out({"ok": True, "theme": a.theme, "size": a.size,
                 "cursors": themes.cursor_preview(a.theme, max(8, min(a.size, 256)), cache)})
        ctx = Ctx()
        if a.cmd == "overview":
            cmd_overview(ctx, a)
        if a.cmd == "plan":
            out(make_plan(ctx, want_of(a)), code=0)
        if a.cmd == "apply":
            cmd_apply(ctx, a)
        if a.cmd == "status":
            out(dict(status_doc(ctx), ok=True))
        if a.cmd == "rollback":
            cmd_rollback(ctx, a)
        if a.cmd == "recover":
            cmd_recover(ctx)
        if a.cmd == "session-start":
            cmd_session_start(ctx)
    except core.Refused as e:
        out({"ok": False, "error": "refused", "reason": str(e)})


if __name__ == "__main__":
    main()
