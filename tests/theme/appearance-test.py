#!/usr/bin/env python3
"""Apariencia (2026-11-13) · pruebas de scripts/appearance.py en un HOME privado.

Nada toca la sesión real: HOME/XDG privados, GSettings con el backend keyfile (sin dconf ni bus:
DBUS_SESSION_BUS_ADDRESS=disabled:), `hyprctl` falso al frente del PATH (se comprueba antes) y temas de prueba hechos
a mano. Se comprueba descubrimiento, plan/token, aplicar, idempotencia, conflictos con cambios del usuario, vuelta
atrás exacta (byte a byte), creación y retirada de gtk-4.0/settings.ini, corte a mitad + recover, tema inexistente o
borrado, registro dañado, la reaplicación del cursor al arrancar la shell y que la vista previa de 24 px distinga
las variantes claro/oscuro que heredan sus iconos grandes (Colloid se retiró el 2026-11-13: ya no hay orden `colloid`).

    python3 appearance-test.py SHELL_TREE
"""
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
TREE = os.path.abspath(sys.argv[1])
HELPER = os.path.join(TREE, "scripts", "appearance.py")
REAL_CURSOR = "/usr/share/icons/Adwaita/cursors"
fails, passes = [], []


def check(name, cond, detail=""):
    (passes if cond else fails).append(name)
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  →  " + str(detail)[:600]))


def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


def make_home():
    root = tempfile.mkdtemp(prefix="aptest-", dir=os.environ.get("TMPDIR") or "/tmp")
    h = os.path.join(root, "h")
    env = {
        "HOME": h, "XDG_CONFIG_HOME": h + "/.config", "XDG_STATE_HOME": h + "/.local/state",
        "XDG_DATA_HOME": h + "/.local/share", "XDG_CACHE_HOME": h + "/.cache", "XDG_RUNTIME_DIR": root + "/run",
        "XDG_DATA_DIRS": root + "/sys", "GSETTINGS_BACKEND": "keyfile", "DBUS_SESSION_BUS_ADDRESS": "disabled:",
        "QT_QPA_PLATFORMTHEME": "qt6ct", "HYPRLAND_INSTANCE_SIGNATURE": "fake-test", "PATH": root + "/bin:/usr/bin:/bin",
        "HYPRCURSOR_THEME": "Login-Cursor", "HYPRCURSOR_SIZE": "20", "XCURSOR_THEME": "Login-Cursor", "XCURSOR_SIZE": "20",
        "LANG": "C.UTF-8", "KT_FONT_SYNC_TEST": "1", "GSETTINGS_SCHEMA_DIR": "/usr/share/glib-2.0/schemas",
    }
    for d in (h + "/.config/gtk-4.0", h + "/.config/qt6ct", h + "/.local/share/icons", root + "/sys/icons", root + "/bin"):
        os.makedirs(d, exist_ok=True)
    os.makedirs(root + "/run", mode=0o700)
    # hyprctl falso: anota y contesta «ok»
    with open(root + "/bin/hyprctl", "w") as f:
        f.write("#!/bin/sh\necho \"$@\" >> '%s/hyprctl.log'\necho ok\n" % root)
    os.chmod(root + "/bin/hyprctl", 0o755)
    # temas de iconos: un par claro/oscuro del usuario y uno del sistema, todos heredan hicolor
    def icon_theme(base, name, inherits="hicolor", icons=("folder",)):
        d = os.path.join(base, name)
        os.makedirs(d + "/48x48/places", exist_ok=True)
        with open(d + "/index.theme", "w") as f:
            f.write("[Icon Theme]\nName=%s\nInherits=%s\nDirectories=48x48/places\n\n[48x48/places]\nSize=48\n"
                    "Context=Places\nType=Fixed\n" % (name, inherits))
        for i in icons:
            open(d + "/48x48/places/%s.svg" % i, "w").write("<svg xmlns='http://www.w3.org/2000/svg'/>")
    icon_theme(h + "/.local/share/icons", "Testa-Dark")
    icon_theme(h + "/.local/share/icons", "Testa-Light")
    icon_theme(root + "/sys/icons", "SysIcons", icons=("folder", "user-home"))
    icon_theme(root + "/sys/icons", "hicolor", inherits="", icons=("text-x-generic",))
    # par como Papirus/Papirus-Light: la variante sólo trae sus iconos de barra (24 px) y hereda carpetas y apps
    def glyph_theme(name, inherits, big):
        d = os.path.join(root, "sys/icons", name)
        dirs = ["24x24/panel"] + (["48x48/places"] if big else [])
        os.makedirs(d + "/24x24/panel")
        idx = "[Icon Theme]\nName=%s\nInherits=%s\nDirectories=%s\n\n[24x24/panel]\nSize=24\nContext=Status\nType=Fixed\n" % (
            name, inherits, ",".join(dirs))
        open(d + "/24x24/panel/battery-good.svg", "w").write("<svg xmlns='http://www.w3.org/2000/svg' id='%s'/>" % name)
        if big:
            os.makedirs(d + "/48x48/places")
            idx += "\n[48x48/places]\nSize=48\nContext=Places\nType=Fixed\n"
            open(d + "/48x48/places/folder.svg", "w").write("<svg xmlns='http://www.w3.org/2000/svg'/>")
        open(d + "/index.theme", "w").write(idx)
    glyph_theme("Glyph", "hicolor", True)
    # como deja Steam ~/.local/share/icons/hicolor: iconos sin index.theme propio (vale el del sistema)
    os.makedirs(h + "/.local/share/icons/hicolor/48x48/places")
    open(h + "/.local/share/icons/hicolor/48x48/places/steam_icon_1.svg", "w").write("<svg xmlns='http://www.w3.org/2000/svg'/>")
    open(h + "/.local/share/icons/hicolor/48x48/places/text-x-generic.svg", "w").write("<svg xmlns='http://www.w3.org/2000/svg'/>")
    glyph_theme("Glyph-Light", "Glyph,hicolor", False)
    # cursores: copias de los XCursor de Adwaita (sistema) con dos nombres
    for name in ("Login-Cursor", "Pick-Cursor"):
        d = os.path.join(root, "sys/icons", name)
        os.makedirs(d + "/cursors")
        for c in ("left_ptr", "default", "hand2", "xterm", "watch", "fleur"):
            src = os.path.join(REAL_CURSOR, c)
            if os.path.exists(src):
                shutil.copy(os.path.realpath(src), d + "/cursors/" + c)
        open(d + "/index.theme", "w").write("[Icon Theme]\nName=%s\n" % name)
    gtk4 = "[Settings]\ngtk-theme-name=Adwaita\ngtk-icon-theme-name=SysIcons\ngtk-font-name=Sans 11\n"
    open(h + "/.config/gtk-4.0/settings.ini", "w").write(gtk4)
    qt6 = ("[Appearance]\ncolor_scheme_path=/x/minimaru.conf\ncustom_palette=true\nicon_theme=SysIcons\nstyle=Fusion\n\n"
           "[Fonts]\nfixed=\"Mono,12,-1,5,400,0,0,0,0,0,0,0,0,0,0,1\"\n")
    open(h + "/.config/qt6ct/qt6ct.conf", "w").write(qt6)
    return root, h, env


def run(env, *args, expect_ok=None):
    r = subprocess.run([sys.executable, "-B", HELPER, *args], env=env, capture_output=True, text=True, timeout=600)
    try:
        doc = json.loads(r.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        doc = {"_raw": r.stdout + r.stderr, "_code": r.returncode}
    doc["_code"] = r.returncode
    if expect_ok is not None and bool(doc.get("ok")) != expect_ok:
        print("   (unexpected)", json.dumps(doc)[:800], r.stderr[-800:])
    return doc


def gs(env, key):
    code = ("import gi,sys\ngi.require_version('Gio','2.0')\nfrom gi.repository import Gio\n"
            "s=Gio.Settings.new('org.gnome.desktop.interface');k=sys.argv[1]\n"
            "print(s.get_int(k) if k=='cursor-size' else s.get_string(k), s.get_user_value(k) is not None)")
    r = subprocess.run([sys.executable, "-I", "-c", code, key], env=env, capture_output=True, text=True)
    return r.stdout.strip()


def main():
    root, h, env = make_home()
    try:
        w = subprocess.run(["sh", "-c", "command -v hyprctl"], env=env, capture_output=True, text=True).stdout.strip()
        assert w == root + "/bin/hyprctl", "hyprctl falso no va delante: " + w      # nunca el real
        gtk4p, qt6p = h + "/.config/gtk-4.0/settings.ini", h + "/.config/qt6ct/qt6ct.conf"
        orig = {gtk4p: sha(gtk4p), qt6p: sha(qt6p)}
        gs_before = {k: gs(env, k) for k in ("icon-theme", "cursor-theme", "cursor-size")}
        check("gsettings privado (keyfile) con valores por defecto", gs_before["icon-theme"] == "Adwaita False", gs_before)

        o = run(env, "overview", expect_ok=True)
        names = [i["name"] for i in o["scan"]["icons"]]
        check("descubre temas de iconos del usuario y del sistema", {"Testa-Dark", "Testa-Light", "SysIcons"} <= set(names), names)
        check("hicolor no se ofrece como tema", "hicolor" not in names, names)
        check("familia claro/oscuro agrupada", o["scan"]["families"].get("Testa") == ["Testa-Dark", "Testa-Light"],
              o["scan"]["families"])
        curs = {c["name"]: c for c in o["scan"]["cursors"]}
        check("descubre cursores XCursor con tamaños", "Pick-Cursor" in curs and curs["Pick-Cursor"]["sizes"], curs.keys())
        check("lee gtk-4.0 y qt6ct", o["targets"]["gtk4.icons"]["value"] == "SysIcons"
              and o["targets"]["qt6.icons"]["value"] == "SysIcons", o["targets"])
        check("gtk-3.0 sin archivo = missing-file", o["targets"]["gtk3.icons"]["state"] == "missing-file")
        same = run(env, "overview", "--stamp", o["stamp"])
        check("--stamp igual → unchanged (sin escanear)", same.get("unchanged") is True, same)

        ic = run(env, "icons", "--theme", "Testa-Dark", "--names", "folder,user-home,text-x-generic,nope", expect_ok=True)
        got = {x["name"]: x["from"] for x in ic["icons"]}
        check("vista previa sigue la herencia hasta hicolor", got.get("folder") == "Testa-Dark"
              and got.get("text-x-generic") == "hicolor" and got.get("nope") == "", got)
        big = {t: run(env, "icons", "--theme", t, "--names", "folder", expect_ok=True)["icons"][0]["path"] for t in ("Glyph", "Glyph-Light")}
        check("variante que hereda: la muestra grande es el MISMO archivo (por eso no cambiaba)",
              big["Glyph"] and big["Glyph"] == big["Glyph-Light"], big)
        small = {t: run(env, "icons", "--theme", t, "--names", "battery-good", "--size", "24", expect_ok=True)["icons"][0]["path"]
                 for t in ("Glyph", "Glyph-Light")}
        check("iconos de barra a 24 px: cada variante el suyo", small["Glyph"].endswith("/Glyph/24x24/panel/battery-good.svg")
              and small["Glyph-Light"].endswith("/Glyph-Light/24x24/panel/battery-good.svg"), small)
        hc = {x["name"]: x for x in run(env, "icons", "--theme", "SysIcons", "--names", "steam_icon_1,text-x-generic",
                                        expect_ok=True)["icons"]}
        check("hicolor del usuario sin index.theme: se encuentra con el del sistema (iconos de Steam)",
              hc["steam_icon_1"]["path"].startswith(h + "/.local/share/icons/hicolor/") and hc["steam_icon_1"]["from"] == "hicolor", hc)
        check("el mismo icono en el usuario y en el sistema: gana el del usuario",
              hc["text-x-generic"]["path"].startswith(h + "/.local/share/icons/hicolor/"), hc)
        check("overview sin Colloid", "colloid" not in o, list(o))
        cl = subprocess.run([sys.executable, HELPER, "colloid", "status"], env=env, capture_output=True, text=True)
        check("la orden colloid ya no existe", cl.returncode != 0 and "invalid choice" in cl.stderr, cl.stderr[-200:])
        cp = run(env, "cursors", "--theme", "Pick-Cursor", "--size", "24", expect_ok=True)
        check("vista previa del cursor en PNG", any(x["path"].endswith(".png") and os.path.getsize(x["path"]) > 100
                                                    for x in cp["cursors"]), cp)

        # tema inexistente
        bad = run(env, "plan", "--icons", "NoSuchTheme")
        check("tema inexistente: plan inválido", bad.get("ok") is False and "icons" in bad.get("errors", {}), bad)
        evil = run(env, "plan", "--icons", "../../etc")
        check("nombre inseguro rechazado", evil.get("ok") is False, evil)

        want = ["--icons", "Testa-Dark", "--cursor", "Pick-Cursor", "--size", "32"]
        p = run(env, "plan", *want, expect_ok=True)
        acts = {s["slot"]: s["action"] for s in p["slots"]}
        check("plan: cambios en GSettings, GTK 4, qt6ct y Hyprland", all(acts[k] == "change" for k in (
            "gtk.icons", "gtk.cursor", "gtk.cursorSize", "gtk4.icons", "gtk4.cursor", "gtk4.cursorSize", "qt6.icons",
            "hyprland.cursor")), acts)
        check("plan: gtk-3.0 sin archivo se salta", acts["gtk3.icons"] == "skip", acts)
        stale = run(env, "apply", "--expect", "deadbeef", *want)
        check("token viejo → no se aplica", stale.get("error") == "plan-changed", stale)
        check("token viejo no escribió", sha(gtk4p) == orig[gtk4p] and sha(qt6p) == orig[qt6p])

        a = run(env, "apply", "--expect", p["token"], *want, expect_ok=True)
        res = {r["slot"]: r["result"] for r in a.get("results", [])}
        check("apply: todo aplicado", a.get("ok") and set(res.values()) == {"applied"}, res)
        g4 = open(gtk4p).read()
        check("gtk-4.0: claves cambiadas/añadidas y el resto intacto",
              "gtk-icon-theme-name=Testa-Dark" in g4 and "gtk-cursor-theme-name=Pick-Cursor" in g4
              and "gtk-cursor-theme-size=32" in g4 and "gtk-font-name=Sans 11" in g4 and g4.startswith("[Settings]\n"), g4)
        q6 = open(qt6p).read()
        check("qt6ct: sólo icon_theme", q6 == open(qt6p).read() and "icon_theme=Testa-Dark" in q6
              and "custom_palette=true" in q6 and "style=Fusion" in q6 and q6.count("\n") == 8, q6)
        check("GSettings guardado", gs(env, "icon-theme").startswith("Testa-Dark") and gs(env, "cursor-size").startswith("32"),
              {k: gs(env, k) for k in ("icon-theme", "cursor-theme", "cursor-size")})
        log = open(root + "/hyprctl.log").read() if os.path.exists(root + "/hyprctl.log") else ""
        check("hyprctl setcursor Pick-Cursor 32", log.strip().endswith("setcursor Pick-Cursor 32"), log)

        p2 = run(env, "plan", *want, expect_ok=True)
        check("idempotente: segundo plan sin cambios", p2["changes"] == 0, [(s["slot"], s["action"]) for s in p2["slots"]])
        st = run(env, "status", expect_ok=True)
        check("status: gestionado y en vigor", st["managed"] and all(m["state"] == "in-effect" for m in st["managed"]),
              st)
        ss = run(env, "session-start", expect_ok=True)
        check("session-start no repite en la misma sesión (recarga de la shell)", ss.get("applied") is False, ss)
        ss = run(dict(env, HYPRLAND_INSTANCE_SIGNATURE="fake-test-2"), "session-start", expect_ok=True)
        check("session-start da otra vez el cursor a Hyprland en una sesión nueva", ss.get("applied") is True
              and open(root + "/hyprctl.log").read().strip().splitlines()[-1] == "setcursor Pick-Cursor 32", ss)

        # el usuario cambia GTK 4 a mano después: la vuelta atrás no lo pisa
        txt = open(gtk4p).read()
        open(gtk4p, "w").write(txt.replace("gtk-icon-theme-name=Testa-Dark", "gtk-icon-theme-name=Mine"))
        st = run(env, "status", expect_ok=True)
        stmap = {m["slot"]: m["state"] for m in st["managed"]}
        check("status: cambio del usuario detectado", stmap.get("gtk4.icons") == "changed-by-you", stmap)

        # tema borrado durante la sesión
        shutil.rmtree(root + "/sys/icons/Pick-Cursor")
        st = run(env, "status", expect_ok=True)
        stmap = {m["slot"]: m["state"] for m in st["managed"]}
        check("status: tema de cursor borrado → missing-theme", stmap.get("gtk.cursor") == "missing-theme", stmap)
        ss = run(env, "session-start")
        check("session-start no da un cursor que ya no existe", ss.get("applied") is False and ss.get("reason") == "missing-theme", ss)

        rb = run(env, "rollback", "--all")
        rres = {r["slot"]: r["result"] for r in rb.get("results", [])}
        check("rollback: lo del usuario se respeta", rres.get("gtk4.icons") == "conflict", rres)
        check("rollback: lo demás vuelve", all(rres.get(k) == "restored" for k in ("gtk.icons", "gtk.cursor", "qt6.icons",
                                                                                   "hyprland.cursor")), rres)
        check("rollback: qt6ct byte a byte igual", sha(qt6p) == orig[qt6p], open(qt6p).read())
        g4 = open(gtk4p).read()
        check("rollback: gtk-4.0 sin las líneas añadidas y con el cambio del usuario",
              "gtk-cursor-theme-name" not in g4 and "gtk-cursor-theme-size" not in g4 and "gtk-icon-theme-name=Mine" in g4, g4)
        check("rollback: GSettings vuelve a «por defecto»",
              {k: gs(env, k) for k in ("icon-theme", "cursor-theme", "cursor-size")} == gs_before,
              {k: gs(env, k) for k in ("icon-theme", "cursor-theme", "cursor-size")})
        check("rollback: Hyprland vuelve al de la sesión", open(root + "/hyprctl.log").read().strip().splitlines()[-1]
              == "setcursor Login-Cursor 20")
        st = run(env, "status", expect_ok=True)
        check("status vacío tras la vuelta atrás", st["managed"] == [], st)

        # gtk-4.0/settings.ini inexistente: se crea y se retira entera
        shutil.rmtree(h + "/.config/gtk-4.0")
        p = run(env, "plan", "--icons", "Testa-Light", expect_ok=True)
        a = run(env, "apply", "--expect", p["token"], "--icons", "Testa-Light", expect_ok=True)
        check("crea gtk-4.0/settings.ini con sólo esa clave",
              open(gtk4p).read() == "[Settings]\ngtk-icon-theme-name=Testa-Light\n", open(gtk4p).read() if os.path.exists(gtk4p) else "")
        rb = run(env, "rollback", "--tx", a["tx"], expect_ok=True)
        check("rollback retira el archivo y la carpeta creados", not os.path.exists(h + "/.config/gtk-4.0"), rb)

        # corte a mitad (justo antes del intercambio atómico de qt6ct) y recover
        envc = dict(env, KT_FONT_SYNC_TEST_RACE="%s:before-exchange:!crash" % (root + "/x"))
        p = run(env, "plan", "--icons", "Testa-Light", expect_ok=True)
        c = run(envc, "apply", "--expect", p["token"], "--icons", "Testa-Light")
        check("corte simulado a mitad", c["_code"] == 9, c)
        check("qt6ct intacto tras el corte", sha(qt6p) == orig[qt6p])
        again = run(env, "apply", "--expect", run(env, "plan", "--icons", "Testa-Light")["token"], "--icons", "Testa-Light")
        check("con un diario pendiente no se aplica", again.get("error") == "pending", again)
        rc = run(env, "recover", expect_ok=True)
        check("recover resuelve el diario", rc.get("ok") and not run(env, "status")["pending"], rc)
        run(env, "rollback", "--all")
        check("tras recover + rollback, GSettings por defecto",
              {k: gs(env, k) for k in ("icon-theme", "cursor-theme", "cursor-size")} == gs_before)

        # registro dañado: no se escribe nada
        led = h + "/.local/state/sumi-shell/appearance-sync/ledger.json"
        keep = open(led).read()
        open(led, "w").write("{broken")
        d = run(env, "plan", "--icons", "Testa-Dark")
        check("registro dañado → se niega, sin escribir", d.get("ok") is False and "damaged" in d.get("reason", ""), d)
        open(led, "w").write(keep)

        # qt6ct sin configuración: no se inventa
        os.remove(qt6p)
        p = run(env, "plan", "--icons", "Testa-Dark", expect_ok=True)
        q = next(s for s in p["slots"] if s["slot"] == "qt6.icons")
        check("qt6ct sin archivo: no se crea", q["action"] == "unavailable" and not os.path.exists(qt6p), q)
        # sesión sin qt6ct
        p = run(dict(env, QT_QPA_PLATFORMTHEME="gtk3"), "plan", "--icons", "Testa-Dark", expect_ok=True)
        q = next(s for s in p["slots"] if s["slot"] == "qt6.icons")
        check("sin qt6ct en la sesión: no se toca", q["action"] == "unavailable", q)

    finally:
        if root.startswith(tempfile.gettempdir()) or "/aptest-" in root:
            shutil.rmtree(root, ignore_errors=True)
    print("\n%d/%d" % (len(passes), len(passes) + len(fails)))
    sys.exit(1 if fails else 0)



if __name__ == "__main__":
    main()
