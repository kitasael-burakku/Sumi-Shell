#!/usr/bin/env python3
"""Sumi Shell — pruebas de `install.sh theme-apps` (paletas estáticas F-e, 2026-11-04).

Uso (desde dotfiles/quickshell o la raíz de sumi-shell):
    python3 -B tests/install/theme-apps-test.py [--json ARCHIVO] [escenario…]

Reutiliza el banco de integration-test.py (HOME temporal con la shell INSTALADA por install.sh, PATH reducido, systemctl/
qs/hyprctl FALSOS con estado). Herramientas REALES sin efectos fuera del HOME temporal: matugen (siempre con la config del
banco: nunca la del usuario) y Hyprland --verify-config/luac del fragmento. kitty es un binario falso (`true`): sólo se
comprueba que existe. Nada de la sesión del autor se toca.
"""
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("integration_test", os.path.join(HERE, "integration-test.py"))
IT = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(IT)
T = IT.T
expect = T.expect
MARK = "Sumi Shell —"
MATUGEN = shutil.which("matugen")
PRESETS = os.path.join(T.ROOT, "sumi", "palettes")


class Bench(IT.Bench):
    def __init__(self, kitty=True, qt=None, hyprland_integration=False, **kw):
        self.qt = qt
        super().__init__(**kw)
        if MATUGEN:
            os.symlink(MATUGEN, os.path.join(self.shim, "matugen"))
        if kitty:
            os.symlink(shutil.which("true"), os.path.join(self.bin, "kitty"))
        if hyprland_integration:
            rc, out = self.run("hyprland", "--apply", "--reload")
            assert rc == 0, out

    def env(self, extra=None):
        e = super().env(extra)
        if self.qt:
            e["QT_QPA_PLATFORMTHEME"] = self.qt
        else:
            e.pop("QT_QPA_PLATFORMTHEME", None)
        return e

    def p(self, rel):
        return os.path.join(self.cfg, rel)

    def read(self, rel):
        try:
            return open(self.p(rel), "rb").read()
        except OSError:
            return None

    def theme(self):
        return (self.integ("theme-apps") or {})

    def cfgsnap(self):
        return T.snapshot(self.cfg)


def sha(b):
    return hashlib.sha256(b).hexdigest()


def roles(pid):
    return json.load(open(os.path.join(PRESETS, pid + ".json")))


def set_preset(b, pid):
    th = os.path.join(b.state, "sumi-shell", "theme")
    os.makedirs(th, exist_ok=True)
    open(os.path.join(th, "preset"), "w").write(pid)


def provider(b, *args):
    """El proveedor de tema propio de la shell INSTALADA, con la config que dejó theme-apps (lo que hace la shell)."""
    tp = os.path.join(b.cfg, "quickshell", "sumi", "scripts", "theme-provider.py")
    cfg = os.path.join(b.cfg, "sumi-shell", "matugen-apps.toml")
    p = subprocess.run(["python3", "-B", tp, "--config", cfg] + list(args), env=b.env(), capture_output=True, text=True,
                       timeout=180)
    return p.returncode, p.stdout + p.stderr


# ---- escenarios -----------------------------------------------------------------------------------------------------

def s_preview(b, probs):
    before = b.cfgsnap()
    rc, out = b.run("theme-apps")
    expect(rc == 0 and "kitty" in out and "GTK 3" in out and "Hyprland border" in out, "preview: %d %s" % (rc, out[-400:]),
           probs)
    expect("Qt 6 (qt6ct)" in out and "not possible" in out, "qt without qt6ct should say why: %s" % out[-400:], probs)
    expect(b.cfgsnap() == before, "the preview wrote something: %s" % T.diff_snap(before, b.cfgsnap())[:5], probs)


def s_apply_revert_fresh(b, probs):
    """Sin kitty.conf ni gtk.css: se crean sólo con el bloque; revert los quita y ~/.config queda como antes."""
    before = b.cfgsnap()
    rc, out = b.run("theme-apps", "kitty", "gtk3", "gtk4", "--apply")
    expect(rc == 0 and "Applied: kitty, GTK 3, GTK 4" in out, "apply: %d %s" % (rc, out[-500:]), probs)
    for rel in ("kitty/sumi-shell-colors.conf", "gtk-3.0/sumi-shell-colors.css", "gtk-4.0/sumi-shell-colors.css"):
        body = b.read(rel) or b""
        expect(body.decode().startswith("# " + MARK) or body.decode().startswith("/* " + MARK), "%s not ours" % rel, probs)
        expect(b"{{" not in body and b"<*" not in body, "%s not rendered" % rel, probs)
    # Minimaru trae su bloque terminal (la misma sustitución que un preset): el fondo de kitty es el suyo
    glass = json.load(open(os.path.join(b.cfg, "quickshell", "sumi", "palettes", "static", "minimaru-dark.json")))
    glass = glass["terminal"]["background"]
    expect(("background            %s" % glass).encode() in (b.read("kitty/sumi-shell-colors.conf") or b""),
           "kitty colours aren't Minimaru (the confirmed static palette)", probs)
    kc = b.read("kitty/kitty.conf") or b""
    expect(kc.startswith(b"# >>> sumi-shell theme-apps") and b"include sumi-shell-colors.conf" in kc,
           "kitty.conf block: %r" % kc[:200], probs)
    g3 = b.read("gtk-3.0/gtk.css") or b""
    expect(b'@import url("sumi-shell-colors.css");' in g3, "gtk.css import", probs)
    cfg = (b.read("sumi-shell/matugen-apps.toml") or b"").decode()
    expect("[templates.kitty]" in cfg and "[templates.gtk3]" in cfg and "[templates.sumi_shell]" in cfg
           and "[templates.qt6]" not in cfg, "apps config: %s" % cfg[:300], probs)
    rec = b.theme()
    expect(rec.get("status") == "applied" and sorted(a for a, r in rec["apps"].items() if r["status"] == "applied")
           == ["gtk3", "gtk4", "kitty"], "manifest: %s" % json.dumps(rec)[:300], probs)
    rc, out = b.run("status")
    expect("theme-apps · applied: kitty, GTK 3, GTK 4" in out, "status: %s" % out[-400:], probs)
    rc, out = b.run("theme-apps", "--verify")
    expect(rc == 0 and out.count("applied") >= 3, "verify: %d %s" % (rc, out[-300:]), probs)
    rc, out = b.run("theme-apps", "kitty", "--apply")
    expect(rc == 0 and "Already applied" in out, "second apply: %d %s" % (rc, out[-200:]), probs)
    rc, out = b.run("uninstall", "--yes")
    expect(rc == 1 and "theme-apps --revert" in out, "uninstall must refuse while applied: %d %s" % (rc, out[-300:]), probs)
    rc, out = b.run("theme-apps", "--revert")
    expect(rc == 0 and "Reverted: kitty, GTK 3, GTK 4" in out, "revert: %d %s" % (rc, out[-400:]), probs)
    after = b.cfgsnap()
    expect(after == before, "~/.config differs after revert: %s" % T.diff_snap(before, after)[:6], probs)
    expect(b.theme().get("status") == "reverted", "status after revert", probs)


def s_user_files_preserved(b, probs):
    """kitty.conf sin salto final y gtk.css con reglas propias: el bloque va al final/principio y revert es byte a byte."""
    k = b"font_size 11\nmap ctrl+n new_window"
    g = b"/* mine */\n@define-color accent_color #ff0000;\nwindow { padding: 1px; }\n"
    b.write(".config/kitty/kitty.conf", k.decode())
    b.write(".config/gtk-4.0/gtk.css", g.decode())
    rc, out = b.run("theme-apps", "kitty", "gtk4", "--apply")
    expect(rc == 0, "apply: %d %s" % (rc, out[-300:]), probs)
    kc, gc = b.read("kitty/kitty.conf"), b.read("gtk-4.0/gtk.css")
    expect(kc.startswith(k + b"\n# >>> sumi-shell theme-apps"), "kitty block not appended after a newline", probs)
    expect(gc.startswith(b"/* >>> sumi-shell theme-apps") and gc.endswith(g), "gtk block not prepended", probs)
    rec = b.theme()
    expect(any("kitty.conf before theme-apps" in x["why"] for x in rec.get("kept", [])), "no kept copy of kitty.conf", probs)
    rc, out = b.run("theme-apps", "--revert")
    expect(rc == 0, "revert: %d %s" % (rc, out[-300:]), probs)
    expect(b.read("kitty/kitty.conf") == k and b.read("gtk-4.0/gtk.css") == g, "user files not byte for byte", probs)


def s_edited_block(b, probs):
    rc, out = b.run("theme-apps", "kitty", "gtk3", "--apply")
    expect(rc == 0, "apply: %d %s" % (rc, out[-300:]), probs)
    p = b.p("kitty/kitty.conf")
    text = open(p).read()
    open(p, "w").write(text.replace("include sumi-shell-colors.conf", "include other.conf"))
    rc, out = b.run("theme-apps", "--revert")
    expect(rc == 1 and "were edited" in out, "revert with an edited block: %d %s" % (rc, out[-400:]), probs)
    expect(b.read("gtk-3.0/gtk.css") is None, "gtk3 (not edited) should be reverted anyway", probs)
    rec = b.theme()
    expect(rec["apps"]["kitty"]["status"] == "applied" and rec["apps"]["gtk3"]["status"] == "reverted",
           "statuses: %s" % {a: r["status"] for a, r in rec["apps"].items()}, probs)
    cfg = (b.read("sumi-shell/matugen-apps.toml") or b"").decode()
    expect("[templates.kitty]" in cfg and "[templates.gtk3]" not in cfg, "config should keep only kitty", probs)


def s_qt(b, probs):
    ini = "[Appearance]\ncolor_scheme_path=/usr/share/qt6ct/colors/darker.conf\ncustom_palette=false\nstyle=Fusion\n\n[Fonts]\n"
    b.write(".config/qt6ct/qt6ct.conf", ini)
    rc, out = b.run("theme-apps", "qt6", "--apply")
    expect(rc == 1 and "QT_QPA_PLATFORMTHEME" in out, "qt6 without qt6ct in use must refuse: %d %s" % (rc, out[-300:]), probs)
    b.qt = "qt6ct"
    rc, out = b.run("theme-apps", "qt6", "--apply")
    expect(rc == 0, "qt6 apply: %d %s" % (rc, out[-300:]), probs)
    now = b.read("qt6ct/qt6ct.conf").decode()
    gen = b.p("qt6ct/colors/sumi-shell.conf")
    expect("color_scheme_path=%s" % gen in now and "custom_palette=true" in now and "style=Fusion" in now
           and now.count("[Fonts]") == 1, "qt6ct.conf: %s" % now, probs)
    body = (b.read("qt6ct/colors/sumi-shell.conf") or b"").decode()
    expect(body.startswith("[ColorScheme]") and "active_colors=#" in body, "qt palette: %s" % body[:200], probs)
    # el usuario elige otra paleta en qt6ct: revert no se la quita
    open(b.p("qt6ct/qt6ct.conf"), "w").write(now.replace("color_scheme_path=%s" % gen, "color_scheme_path=/mine.conf"))
    rc, out = b.run("theme-apps", "--revert")
    expect(rc == 0 and "color_scheme_path" in out, "revert: %d %s" % (rc, out[-300:]), probs)
    after = b.read("qt6ct/qt6ct.conf").decode()
    expect("color_scheme_path=/mine.conf" in after and "custom_palette=false" in after, "qt revert: %s" % after, probs)
    expect(b.read("qt6ct/colors/sumi-shell.conf") is None, "palette left", probs)


def s_qt_missing_conf(b, probs):
    b.qt = "qt5ct"
    rc, out = b.run("theme-apps", "qt5", "--apply")
    expect(rc == 1 and "qt5ct.conf doesn't exist" in out, "qt5 without qt5ct.conf: %d %s" % (rc, out[-300:]), probs)


def s_refusals(b, probs):
    before = b.cfgsnap()
    b.write(".config/gtk-3.0/sumi-shell-colors.css", "/* the user's own file */\n")
    rc, out = b.run("theme-apps", "gtk3", "--apply")
    expect(rc == 1 and "isn't written by the shell" in out, "a user's file at the target: %d %s" % (rc, out[-300:]), probs)
    os.remove(b.p("gtk-3.0/sumi-shell-colors.css"))
    b.write(".config/sumi-shell/providers.json", json.dumps({"version": 1, "theme": {"matugenConfig": "~/m.toml"}}),
            mode=0o600)
    rc, out = b.run("theme-apps", "kitty", "--apply")
    expect(rc == 1 and "your own matugen configuration" in out, "declared matugen config: %d %s" % (rc, out[-300:]), probs)
    os.remove(b.p("sumi-shell/providers.json"))
    st = json.load(open(b.p("sumi-shell/settings.json"))) if os.path.exists(b.p("sumi-shell/settings.json")) else {}
    st.setdefault("providers", {})["theme"] = "script"
    b.write(".config/sumi-shell/settings.json", json.dumps(st), mode=0o600)
    rc, out = b.run("theme-apps", "kitty", "--apply")
    expect(rc == 1 and "«script»" in out, "script provider: %d %s" % (rc, out[-300:]), probs)
    st["providers"]["theme"] = "auto"
    b.write(".config/sumi-shell/settings.json", json.dumps(st), mode=0o600)
    rc, out = b.run("theme-apps", "nope", "--apply")
    expect(rc == 1 and "unknown app" in out, "unknown app: %d %s" % (rc, out[-200:]), probs)
    rc, out = b.run("theme-apps", "--apply")
    expect(rc == 1 and "name the apps" in out, "no apps: %d %s" % (rc, out[-200:]), probs)
    os.unlink(os.path.join(b.shim, "matugen"))
    rc, out = b.run("theme-apps", "kitty", "--apply")
    expect(rc == 1 and "matugen isn't installed" in out, "no matugen: %d %s" % (rc, out[-200:]), probs)
    os.unlink(os.path.join(b.bin, "kitty"))
    os.symlink(MATUGEN, os.path.join(b.shim, "matugen"))
    rc, out = b.run("theme-apps", "kitty", "--apply")
    expect(rc == 1 and "kitty isn't installed" in out, "no kitty: %d %s" % (rc, out[-200:]), probs)
    after = b.cfgsnap()
    expect(after == T.snapshot(b.cfg), "noop", probs)
    expect(not os.path.exists(b.p("sumi-shell/matugen-apps.toml")), "a refused apply left the config", probs)


def s_stow_symlink(b, probs):
    real = os.path.join(b.h, "dots", "kitty.conf")
    os.makedirs(os.path.dirname(real))
    open(real, "w").write("font_size 11\n")
    os.makedirs(b.p("kitty"), exist_ok=True)
    os.symlink(real, b.p("kitty/kitty.conf"))
    rc, out = b.run("theme-apps", "kitty", "--apply")
    expect(rc == 1 and "symbolic link" in out, "symlinked kitty.conf (Stow): %d %s" % (rc, out[-300:]), probs)
    expect(open(real).read() == "font_size 11\n", "the link target changed", probs)


def s_interrupted_recover(b, probs):
    before = b.cfgsnap()
    rc, out = b.run("theme-apps", "kitty", "gtk3", "--apply", extra={"SUMI_INSTALL_FAULT": "main-gtk3:after:SIGKILL"})
    expect(rc != 0, "the fault didn't cut it: %d %s" % (rc, out[-300:]), probs)
    rc, out = b.run("status")
    expect("theme-apps-apply" in out or "pending" in out.lower(), "status should show the pending run: %s" % out[-300:], probs)
    rc, out = b.run("recover", "--apply")
    expect(rc == 0, "recover: %d %s" % (rc, out[-400:]), probs)
    after = b.cfgsnap()
    expect(after == before, "after recover ~/.config differs: %s" % T.diff_snap(before, after)[:6], probs)
    rc, out = b.run("theme-apps", "kitty", "--apply")
    expect(rc == 0, "apply after recover: %d %s" % (rc, out[-300:]), probs)


def s_preset_and_provider(b, probs):
    """Con un preset confirmado: los colores iniciales son los del preset (kitty con su ANSI oficial); y el proveedor
    de la shell, con la config que dejó theme-apps, reescribe todo al cambiar de tema."""
    set_preset(b, "catppuccin-mocha")
    rc, out = b.run("theme-apps", "kitty", "gtk3", "--apply")
    expect(rc == 0, "apply: %d %s" % (rc, out[-300:]), probs)
    m = roles("catppuccin-mocha")
    k = (b.read("kitty/sumi-shell-colors.conf") or b"").decode()
    expect(("color1  %s" % m["terminal"]["color1"]) in k and ("background            %s" % m["terminal"]["background"]) in k,
           "kitty isn't Mocha with its official ANSI: %s" % k[:600], probs)
    expect(m["roles"]["primary"] in (b.read("gtk-3.0/sumi-shell-colors.css") or b"").decode(), "gtk3 isn't Mocha", probs)
    rc, out = provider(b, "preset", "gruvbox-light")
    expect(rc == 0, "provider preset: %d %s" % (rc, out[-400:]), probs)
    g = roles("gruvbox-light")
    k = (b.read("kitty/sumi-shell-colors.conf") or b"").decode()
    expect(("color1  %s" % g["terminal"]["color1"]) in k, "the provider didn't recolour kitty with the preset", probs)
    expect(g["roles"]["primary"] in (b.read("gtk-3.0/sumi-shell-colors.css") or b"").decode(), "gtk3 not Gruvbox", probs)
    shell = json.load(open(os.path.join(b.state, "sumi-shell", "colors.json")))
    expect(shell.get("surface") == g["roles"]["surface"], "the shell palette isn't Gruvbox Light", probs)
    rc, out = provider(b, "static")
    expect(rc == 0, "provider static: %d %s" % (rc, out[-300:]), probs)
    glass = json.load(open(os.path.join(b.cfg, "quickshell", "sumi", "colors.static.json")))
    expect(glass["primary"] in (b.read("gtk-3.0/sumi-shell-colors.css") or b"").decode(),
           "Static didn't paint the apps with Minimaru", probs)
    rc, out = b.run("theme-apps", "--revert")
    expect(rc == 0, "revert: %d %s" % (rc, out[-300:]), probs)


def s_dynamic_without_wallpaper(b, probs):
    th = os.path.join(b.state, "sumi-shell", "theme")
    os.makedirs(th, exist_ok=True)
    open(os.path.join(th, "enabled"), "w").close()
    rc, out = b.run("theme-apps", "kitty", "--apply")
    expect(rc == 0, "dynamic on, no wallpaper: falls back to Minimaru: %d %s" % (rc, out[-300:]), probs)
    expect(MARK in (b.read("kitty/sumi-shell-colors.conf") or b"").decode(), "no kitty colours", probs)
    expect(os.path.exists(os.path.join(th, "enabled")), "the dynamic setting was touched", probs)


def s_hyprland_border(b, probs):
    rc, out = b.run("theme-apps", "hyprland", "--apply")
    expect(rc == 1 and "install.sh hyprland --apply --reload" in out, "border without the integration: %d %s" % (rc, out[-300:]),
           probs)
    rc, out = b.run("hyprland", "--apply", "--reload")
    expect(rc == 0, "hyprland integration: %d %s" % (rc, out[-300:]), probs)
    frag = open(b.frag()).read()
    gen = os.path.join(os.path.dirname(b.frag()), "sumi-shell-colors.lua")
    expect('pcall(dofile, "%s")' % gen in frag, "the fragment doesn't load the border by its absolute path: %s" % frag[:600],
           probs)
    rc, out = b.run("theme-apps", "hyprland", "--apply")
    expect(rc == 0, "border apply: %d %s" % (rc, out[-300:]), probs)
    body = open(gen).read() if os.path.exists(gen) else ""
    expect(body.startswith("-- " + MARK) and "active_border" in body and "{{" not in body, "border file: %s" % body[:300], probs)
    luac = shutil.which("luac") or shutil.which("luac5.4") or shutil.which("luac5.5")
    if luac:
        p = subprocess.run([luac, "-p", gen], capture_output=True, text=True)
        expect(p.returncode == 0, "the border file isn't valid Lua: %s" % p.stderr, probs)
    evals = [c for c in b.calls() if c[:1] == ["hyprctl"] and "eval" in c]
    expect(any(gen in " ".join(c) for c in evals), "the border wasn't applied live (hyprctl eval): %s" % evals[-2:], probs)
    rc, out = b.run("theme-apps", "--revert")
    expect(rc == 0 and "next Hyprland reload" in out and not os.path.exists(gen), "border revert: %d %s" % (rc, out[-300:]),
           probs)
    rc, out = b.run("hyprland", "--revert", "--reload")
    expect(rc == 0, "hyprland revert: %d %s" % (rc, out[-300:]), probs)


def s_old_fragment(b, probs):
    """Una integración de Hyprland hecha por un instalador anterior (fragmento sin la línea del borde): se explica."""
    rc, out = b.run("hyprland", "--apply", "--reload")
    expect(rc == 0, "hyprland: %d %s" % (rc, out[-200:]), probs)
    p = b.frag()
    lines = [l for l in open(p).read().splitlines(True) if "sumi-shell-colors.lua" not in l]
    open(p, "w").write("".join(lines))          # lo que escribía el instalador de antes (sin la línea del borde)
    rc, out = b.run("theme-apps", "hyprland", "--apply")
    expect(rc == 1 and "older installer" in out, "old fragment: %d %s" % (rc, out[-300:]), probs)


def s_custom_xdg(b, probs):
    """XDG_CONFIG_HOME fuera de ~/.config: todo va allí (rutas del manifiesto y de la config de matugen)."""
    rc, out = b.run("theme-apps", "kitty", "gtk4", "--apply")
    expect(rc == 0, "apply: %d %s" % (rc, out[-300:]), probs)
    cfg = (b.read("sumi-shell/matugen-apps.toml") or b"").decode()
    expect(b.cfg in cfg and "/.config/" not in cfg.replace(b.cfg, ""), "paths not under XDG_CONFIG_HOME: %s" % cfg[:400], probs)
    expect(os.path.exists(os.path.join(b.cfg, "kitty", "sumi-shell-colors.conf")), "kitty colours not under XDG", probs)
    rc, out = b.run("theme-apps", "--revert")
    expect(rc == 0, "revert: %d %s" % (rc, out[-200:]), probs)


def s_hyprland_056_conf(b, probs):
    """Hyprland ≤ 0.56 con hyprland.conf (falso 0.56.2): el borde no se ofrece (sólo Lua), el resto sí funciona."""
    b.close()
    c = Bench(dialect="conf", version="0.56.2", binary="0.56.2")
    try:
        rc, out = c.run("hyprland", "--apply", "--reload")
        expect(rc == 0, "conf integration on 0.56: %d %s" % (rc, out[-300:]), probs)
        expect("sumi-shell-colors" not in open(c.frag()).read(), "the hyprland.conf fragment got the Lua border line", probs)
        rc, out = c.run("theme-apps", "hyprland", "--apply")
        expect(rc == 1 and "only set up for Lua" in out, "border on hyprland.conf: %d %s" % (rc, out[-300:]), probs)
        rc, out = c.run("theme-apps", "kitty", "gtk3", "--apply")
        expect(rc == 0, "kitty/GTK on a 0.56 hyprland.conf setup: %d %s" % (rc, out[-300:]), probs)
        rc, out = c.run("theme-apps", "--revert")
        expect(rc == 0, "revert: %d %s" % (rc, out[-200:]), probs)
    finally:
        c.close()


def s_no_hyprland_running(b, probs):
    """Sin Hyprland en marcha (desde una TTY, otro compositor): kitty/GTK/Qt no dependen de él; el borde se niega."""
    b.close()
    c = Bench(hyprland=False)
    try:
        before = c.cfgsnap()
        rc, out = c.run("theme-apps", "kitty", "gtk4", "--apply")
        expect(rc == 0, "apply without Hyprland: %d %s" % (rc, out[-300:]), probs)
        rc, out = c.run("theme-apps", "hyprland", "--apply")
        expect(rc == 1 and "install.sh hyprland" in out, "border without Hyprland: %d %s" % (rc, out[-200:]), probs)
        rc, out = c.run("theme-apps", "--revert")
        expect(rc == 0 and c.cfgsnap() == before, "revert without Hyprland: %d %s" % (rc, out[-200:]), probs)
    finally:
        c.close()


def s_lua_paths(b, probs):
    """El literal Lua de la ruta del borde: espacios, comillas, barras inversas y acentos se leen tal cual en Lua."""
    import importlib.util as iu
    sp = iu.spec_from_file_location("kt_integr", os.path.join(T.ROOT, "packaging", "integrations.py"))
    G = iu.module_from_spec(sp)
    sp.loader.exec_module(G)
    lua = shutil.which("lua") or shutil.which("lua5.4") or shutil.which("lua5.5")
    for path in ('/home/a b/.config/hypr/sumi-shell-colors.lua', '/home/o"q/x\\y/sumi-shell-colors.lua',
                 "/home/josé/.config/hypr/sumi-shell-colors.lua"):
        lit = G.lua_string(path)
        if lua:
            p = subprocess.run([lua, "-e", "io.write(%s)" % lit], capture_output=True, text=True)
            expect(p.returncode == 0 and p.stdout == path, "Lua reads %r as %r (%s)" % (path, p.stdout, p.stderr.strip()), probs)
    G.I = T.__dict__.get("I") or type("X", (), {"Refused": Exception})
    try:
        G.lua_string("/bad\npath")
        expect(False, "a path with a newline was accepted", probs)
    except Exception:
        pass
    if not lua:
        print("  (lua isn't installed: the Lua literals were not executed)")


class XdgBench(Bench):
    """El mismo banco con XDG_CONFIG_HOME = ~/cfg (no ~/.config): el banco base toma XDG_CONFIG_HOME de `cfg`."""

    @property
    def cfg(self):
        d = os.path.join(self.h, "cfg")
        os.makedirs(d, exist_ok=True)
        return d

    @cfg.setter
    def cfg(self, value):
        pass


SCENARIOS = {
    "preview changes nothing": (s_preview, {}),
    "apply/revert on a fresh home (kitty, GTK 3/4)": (s_apply_revert_fresh, {}),
    "user files kept byte for byte": (s_user_files_preserved, {}),
    "an edited block is left; the rest is reverted": (s_edited_block, {}),
    "qt6ct: only when in use; revert keeps the user's choice": (s_qt, {}),
    "qt5ct.conf missing": (s_qt_missing_conf, {}),
    "refusals (own file, own matugen, script, no matugen/kitty)": (s_refusals, {}),
    "Stow symlink refused": (s_stow_symlink, {}),
    "interrupted apply + recover": (s_interrupted_recover, {}),
    "preset colours + the shell's provider uses the config": (s_preset_and_provider, {}),
    "dynamic without a wallpaper": (s_dynamic_without_wallpaper, {}),
    "Hyprland border (Lua)": (s_hyprland_border, {}),
    "Hyprland integration from an older installer": (s_old_fragment, {}),
    "Hyprland 0.56 with hyprland.conf": (s_hyprland_056_conf, {}),
    "no Hyprland running": (s_no_hyprland_running, {}),
    "Lua literal of odd paths": (s_lua_paths, {}),
}


def main():
    args = sys.argv[1:]
    out_json = None
    if args[:1] == ["--json"]:
        out_json, args = args[1], args[2:]
    if not MATUGEN:
        print("matugen isn't installed: nothing can be tested")
        return 1
    fails, rows = 0, []
    plan = list(SCENARIOS.items()) + [("custom XDG_CONFIG_HOME", (s_custom_xdg, {"xdg": True}))]
    for name, (fn, opt) in plan:
        if args and name not in args:
            continue
        probs = []
        b = None
        try:
            b = XdgBench() if opt.get("xdg") else Bench()
            fn(b, probs)
        except Exception:
            import traceback
            probs.append("harness: %s" % traceback.format_exc()[-800:])
        finally:
            if b:
                b.close()
        fails += 1 if probs else 0
        rows.append({"scenario": name, "result": "fail" if probs else "pass", "problems": probs})
        print("%-64s %s%s" % (name, "PASS" if not probs else "FAIL", ("  " + "; ".join(probs)) if probs else ""))
    leftovers = [d for d, _, _ in os.walk(T.ROOT) if os.path.basename(d) == "__pycache__"]
    if leftovers:
        fails += 1
        print("__pycache__ left in the repo: %s" % leftovers)
    print("failed: %d of %d" % (fails, len(rows)))
    if out_json:
        json.dump({"failed": fails, "scenarios": rows}, open(out_json, "w"), indent=1, ensure_ascii=False)
    return fails


if __name__ == "__main__":
    sys.exit(main())
