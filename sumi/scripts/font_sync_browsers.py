"""T4 · Zen y Firefox: SÓLO información (decisión T4: sin escritura automática todavía).

Detecta instalaciones (nativa, ~/.var/app de Flatpak con la app de verdad instalada), perfiles (installs.ini
manda sobre el Default=1 de profiles.ini), si el perfil está en uso y las preferencias de fuente. Nunca escribe
prefs.js (se reescribe al cerrar el navegador, medido 2026-11-05) ni user.js (se reaplicaría en cada arranque y
quitarlo no devuelve los valores).

En uso: el enlace `lock` puede quedar apuntando a un PID muerto tras cerrar (medido); se mira además
`.parentlock` con F_GETLK, que pregunta sin tomar el cerrojo.
"""
import configparser
import fcntl
import os
import re
import shutil
import struct

import font_sync_core as core

PREFS = ("font.name.sans-serif.x-western", "font.name.serif.x-western", "font.name.monospace.x-western",
         "font.size.variable.x-western", "font.size.monospace.x-western", "browser.display.use_document_fonts")
F_GETLK, F_WRLCK, F_UNLCK = 5, 1, 2


def ini(path):
    c = configparser.ConfigParser(interpolation=None, strict=False)
    c.optionxform = str
    try:
        with open(path) as f:
            c.read_file(f)
    except (OSError, configparser.Error):
        return None
    return c


def read_prefs(path):
    out = {}
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return out
    for m in re.finditer(r'^\s*user_pref\("([^"]+)",\s*(.+?)\);\s*$', text, re.M):
        if m.group(1) in PREFS:
            v = m.group(2).strip()
            out[m.group(1)] = v[1:-1] if v.startswith('"') and v.endswith('"') else v
    return out


def in_use(profile):
    """'running' · 'stale-lock' · 'closed' · 'unknown' sin tomar ningún cerrojo."""
    lock = os.path.join(profile, "lock")
    pid_alive = False
    if os.path.islink(lock):
        m = re.search(r":\+(\d+)$", os.readlink(lock))
        if m:
            pid_alive = os.path.exists("/proc/" + m.group(1))
    try:
        fd = os.open(os.path.join(profile, ".parentlock"), os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return "running" if pid_alive else "closed"
    except OSError:
        return "unknown"
    try:
        q = struct.pack("hh4xqqi4x", F_WRLCK, 0, 0, 0, 0)
        r = fcntl.fcntl(fd, F_GETLK, q)
        held = struct.unpack("hh4xqqi4x", r)[0] != F_UNLCK
    except OSError:
        return "unknown"
    finally:
        os.close(fd)
    if held:
        return "running"
    return "stale-lock" if os.path.islink(lock) else "closed"


def profiles(base):
    pini = ini(os.path.join(base, "profiles.ini"))
    if pini is None:
        return []
    iini = ini(os.path.join(base, "installs.ini"))
    install_default = set()
    if iini is not None:
        for s in iini.sections():
            if iini.has_option(s, "Default"):
                install_default.add(iini.get(s, "Default"))
    out = []
    for s in pini.sections():
        if not s.startswith("Profile") or not pini.has_option(s, "Path"):
            continue
        rel = pini.get(s, "Path")
        path = os.path.join(base, rel) if pini.get(s, "IsRelative", fallback="1") == "1" else rel
        out.append({"name": pini.get(s, "Name", fallback=rel), "path": path, "exists": os.path.isdir(path),
                    "default": rel in install_default or (not install_default and pini.get(s, "Default",
                                                                                            fallback="0") == "1"),
                    "state": in_use(path) if os.path.isdir(path) else "missing",
                    "prefs": read_prefs(os.path.join(path, "prefs.js")),
                    "userJs": read_prefs(os.path.join(path, "user.js"))})
    return out


def policies(paths_):
    for p in paths_:
        try:
            text = open(p).read()
        except OSError:
            continue
        return {"file": p, "fontPrefsLocked": bool(re.search(r'"font\.', text))}
    return None


def detect(ctx, choices):
    """[{id, label, installed, profiles, recommended, steps}] — nunca escribe."""
    home, cfg = ctx.paths.home, ctx.paths.config
    targets = [
        ("zen", "Zen Browser", shutil.which("zen-browser") or shutil.which("zen"),
         [os.path.join(cfg, "zen"), os.path.join(home, ".zen")],
         ["/opt/zen-browser-bin/distribution/policies.json", "/usr/lib/zen-browser/distribution/policies.json"]),
        ("firefox", "Firefox", shutil.which("firefox"),
         [os.path.join(cfg, "mozilla", "firefox"), os.path.join(home, ".mozilla", "firefox")],
         ["/etc/firefox/policies/policies.json", "/usr/lib/firefox/distribution/policies.json"]),
    ]
    flatpak = shutil.which("flatpak")
    fp = os.path.join(home, ".var", "app", "org.mozilla.firefox", ".mozilla", "firefox")
    out = []
    for tid, label, binp, bases, pol in targets:
        found = []
        for b in bases:
            for p in profiles(b):
                p["base"] = b
                found.append(p)
        if tid == "firefox" and os.path.isdir(fp):
            for p in profiles(fp):
                p["base"] = fp
                p["flatpak"] = True
                p["flatpakInstalled"] = bool(flatpak)
                found.append(p)
        rec = {"sans-serif": choices["interface"].family, "monospace": choices["code"].family}
        out.append({"id": tid, "label": label, "installed": bool(binp), "binary": binp, "profiles": found,
                    "policies": policies(pol), "recommended": rec, "writes": False,
                    "steps": "Settings → General → Fonts → Advanced: Sans-serif %s, Monospace %s (Zen/Firefox closed "
                             "or not, the browser saves it itself)" % (rec["sans-serif"] or "—", rec["monospace"] or "—")})
    return out
