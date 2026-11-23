#!/usr/bin/env python3
"""Sumi Shell — compatibilidad con el nombre de antes (Kitasan-Shell), sin sesión ni shell (2026-11-07).

Uso: python3 -B tests/install/compat-test.py        (desde la raíz del repo)

Cada caso comprueba un EFECTO, en directorios temporales y con falsos; nada toca la sesión, el llavero ni el bus reales:
  · lock.sh del rice (el real del repo): helper nuevo → helper viejo → hyprlock; rescate: unidad nueva → vieja.
  · lockchain: envoltorios/helpers nuevos y viejos son «de la shell» (nunca independientes); los dos sha conocidos.
  · notif-server-direct: la activación vieja es «legacy» (se sustituye/quita), otra cualquiera sigue siendo ajena.
  · notif-server (bash): la activación vieja byte a byte se reconoce; con un byte distinto, no.
  · calendar-store: secret-tool falso; se lee el atributo nuevo y, si falta, el viejo; se escribe y borra sólo el nuevo.
  · font_sync_kitty: un kitty con el bloque/fragmento viejo se sigue gestionando con esos nombres; uno nuevo, con los nuevos.
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TREE = os.path.join(ROOT, "sumi")
FIX = os.path.join(ROOT, "tests", "install", "fixtures")
# lock.sh es del rice (Minimaru); aquí se prueba su copia fija. Desde que la shell vive en su propio repositorio
# (2026-11-23), compararla con la del rice es opcional: SUMI_RICE_LOCK=<ruta a hypr/scripts/lock.sh>.
LOCK = os.path.join(FIX, "lock.sh")
RICE_LOCK = os.environ.get("SUMI_RICE_LOCK")
results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))


def load(name, path, extra_path=None):
    if extra_path:
        sys.path.insert(0, extra_path)
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def script(path, body):
    with open(path, "w") as f:
        f.write("#!/bin/bash\n" + body)
    os.chmod(path, 0o755)


# ---- lock.sh del rice ----------------------------------------------------------------------------------------------

def lock_sh(tmp, have_new, have_old, rescue_units):
    """Ejecuta el lock.sh real con helpers y systemctl falsos; devuelve el registro de lo que se llamó."""
    cfg = os.path.join(tmp, "cfg")
    bin_ = os.path.join(tmp, "bin")
    log = os.path.join(tmp, "log")
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(bin_)
    for name, on in (("sumi/scripts/sumi-lock", have_new), ("kitasan/scripts/kitasan-lock", have_old)):
        p = os.path.join(cfg, "quickshell", name)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        if on:
            script(p, 'echo "helper %s $*" >> %s\n' % (name.split("/")[-1], log))
    units = " ".join(rescue_units)
    script(os.path.join(bin_, "systemctl"), 'u="${@: -1}"; for k in %s; do [ "$u" = "$k" ] && { echo "start $u" >> %s; '
           'exit 0; }; done; echo "no $u" >> %s; exit 5\n' % (units or "_", log, log))
    script(os.path.join(bin_, "hyprctl"), 'echo false\n')
    script(os.path.join(bin_, "hyprlock"), 'echo "hyprlock" >> %s\n' % log)
    script(os.path.join(bin_, "logger"), 'true\n')
    script(os.path.join(bin_, "pgrep"), 'exit 1\n')
    out = {}
    for arg in ("session", "rescue-request"):
        open(log, "w").close()
        env = {"PATH": bin_ + ":/usr/bin:/bin", "XDG_CONFIG_HOME": cfg, "HOME": tmp}
        subprocess.run(["bash", LOCK, arg], env=env, timeout=10)
        out[arg] = open(log).read().strip().splitlines()
    return out


def t_lock_sh():
    tmp = tempfile.mkdtemp(prefix="sumi-compat-lock-")
    try:
        r = lock_sh(os.path.join(tmp, "a"), True, True, ["sumi-lock-rescue.service"])
        check("lock.sh: new helper first", r["session"] == ["helper sumi-lock session"], r)
        r = lock_sh(os.path.join(tmp, "b"), False, True, ["kitasan-lock-rescue.service"])
        check("lock.sh: old helper when the new one is missing", r["session"] == ["helper kitasan-lock session"], r)
        r = lock_sh(os.path.join(tmp, "c"), False, False, ["sumi-lock-rescue.service"])
        check("lock.sh: hyprlock with no helper", r["session"] == ["hyprlock"], r)
        check("lock.sh: rescue asks the new unit", r["rescue-request"] == ["start sumi-lock-rescue.service"], r)
        r = lock_sh(os.path.join(tmp, "d"), False, False, ["kitasan-lock-rescue.service"])
        check("lock.sh: rescue falls back to the old unit",
              r["rescue-request"] == ["no sumi-lock-rescue.service", "start kitasan-lock-rescue.service"], r)
        if RICE_LOCK:
            check("lock.sh: the rice copy is the test fixture", open(RICE_LOCK, "rb").read() ==
                  open(LOCK, "rb").read())
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ---- lockchain -------------------------------------------------------------------------------------------------------

def t_lockchain():
    lc = load("sumi_lockchain_t", os.path.join(ROOT, "packaging", "lockchain.py"))
    I = load("sumi_installer_t", os.path.join(ROOT, "packaging", "installer.py"))
    tmp = tempfile.mkdtemp(prefix="sumi-compat-lc-", dir=os.path.expanduser("~") if False else None)
    try:
        known = I.KNOWN_WRAPPERS
        import hashlib
        for fx in ("lock.sh", "lock-kitasan.sh"):
            check("lockchain: %s is a known wrapper" % fx,
                  hashlib.sha256(open(os.path.join(FIX, fx), "rb").read()).hexdigest() in known)
        ctx = {"tree": "", "knownWrappers": {}}
        cases = {"new-wrapper": "#!/bin/sh\n# sumi-lock-wrapper\nexec hyprlock\n",
                 "old-wrapper": "#!/bin/sh\n# kitasan-lock-wrapper\nexec hyprlock\n",
                 "new-ipc": "#!/bin/sh\nqs -c sumi ipc call sumi lockNow x\n",
                 "old-ipc": "#!/bin/sh\nqs -c kitasan ipc call kitasan lockNow x\n",
                 "independent": "#!/bin/sh\n# assuming nothing; consumir nada\nexec hyprlock\n"}
        got = {}
        for k, body in cases.items():
            p = os.path.join(tmp, k)
            open(p, "w").write(body)
            os.chmod(p, 0o755)
            got[k] = lc.classify_file(p, ctx, 0)[0] if hasattr(lc, "classify_file") else None
        check("lockchain: unrecognised wrapper versions (new and old marker) are unknown, never independent",
              got["new-wrapper"] == "unknown" and got["old-wrapper"] == "unknown", got)
        check("lockchain: scripts naming either shell depend on it", got["new-ipc"] == "depends" and
              got["old-ipc"] == "depends", got)
        check("lockchain: «assuming»/«consumir» are not «sumi»", got["independent"] == "independent", got)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ---- notificaciones ------------------------------------------------------------------------------------------------

def t_notif_direct():
    nd = load("sumi_notif_direct_t", os.path.join(TREE, "scripts", "notif-server-direct.py"),
              extra_path=os.path.join(TREE, "scripts"))
    tmp = tempfile.mkdtemp(prefix="sumi-compat-nd-")
    try:
        p = __import__("pathlib").Path(tmp) / "org.freedesktop.Notifications.service"
        p.write_text(nd.LEGACY_MARK + "[D-BUS Service]\nName=org.freedesktop.Notifications\nExec=/usr/bin/qs -c kitasan "
                     "--no-duplicate\n")
        check("notif-direct: old activation is legacy, not ours", nd.legacy_owned(p) and not nd.owned(p))
        p.write_text(nd.MARK + "[D-BUS Service]\nName=org.freedesktop.Notifications\nExec=/usr/bin/qs -c sumi "
                     "--no-duplicate\n")
        check("notif-direct: new activation is ours", nd.owned(p) and not nd.legacy_owned(p))
        p.write_text("[D-BUS Service]\nName=org.freedesktop.Notifications\nExec=/usr/bin/dunst\n")
        check("notif-direct: someone else's stays foreign", not nd.owned(p) and not nd.legacy_owned(p))
        p.write_text(nd.LEGACY_MARK + "[D-BUS Service]\nName=org.freedesktop.Notifications\nExec=/usr/bin/qs -c kitasan "
                     "--no-duplicate\n# edited\n")
        check("notif-direct: an edited old one is foreign", not nd.legacy_owned(p))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def t_notif_bash():
    src = open(os.path.join(TREE, "scripts", "notif-server")).read()
    tmp = tempfile.mkdtemp(prefix="sumi-compat-ns-")
    try:
        start = src.index("owned_systemd_act() {")
        end = src.index("setting_on_disk()")
        funcs = src[start:end]
        for label, body, want in (
                ("old exact", "[D-BUS Service]\nName=org.freedesktop.Notifications\nExec=/bin/false\n"
                              "SystemdService=kitasan-shell.service\n", "legacy"),
                ("new exact", "[D-BUS Service]\nName=org.freedesktop.Notifications\nExec=/bin/false\n"
                              "SystemdService=sumi-shell.service\n", "owned"),
                ("old edited", "[D-BUS Service]\nName=org.freedesktop.Notifications\nExec=/bin/false\n"
                               "SystemdService=kitasan-shell.service\n\n", "none")):
            act = os.path.join(tmp, "act")
            open(act, "w").write(body)
            r = subprocess.run(["bash", "-c", 'ACT="$1"\n' + funcs + '\nif owned_systemd_act; then echo owned; '
                                'elif legacy_systemd_act; then echo legacy; else echo none; fi', "_", act],
                               capture_output=True, text=True, timeout=10)
            check("notif-server: %s → %s" % (label, want), r.stdout.strip() == want, r.stdout + r.stderr)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ---- llavero ---------------------------------------------------------------------------------------------------------

def t_keyring():
    tmp = tempfile.mkdtemp(prefix="sumi-compat-kr-")
    try:
        log = os.path.join(tmp, "calls")
        store = os.path.join(tmp, "store.json")
        script(os.path.join(tmp, "secret-tool"), '''exec python3 -I - "$@" <<'PY'
import json, sys
a = sys.argv[1:]
log, store = %r, %r
open(log, "a").write(json.dumps(a) + "\\n")
try:
    s = json.load(open(store))
except Exception:
    s = {}
key = lambda kv: json.dumps(kv[a.index("application") + 1 if "application" in a else 0:])
if a[0] == "lookup":
    app = a[a.index("application") + 1]; acc = a[a.index("account") + 1]
    v = s.get(app + "/" + acc)
    if v is None:
        sys.exit(1)
    sys.stdout.write(v); sys.exit(0)
PY
''' % (log, store))
        old = dict(os.environ)
        os.environ["PATH"] = tmp + ":" + os.environ["PATH"]
        try:
            cs = load("sumi_calendar_store_t", os.path.join(TREE, "scripts", "calendar-store.py"),
                      extra_path=os.path.join(TREE, "scripts"))
            json.dump({"kitasan-shell/acc1": "old-pw"}, open(store, "w"))
            got = cs.secret_lookup("acc1")
            calls = [json.loads(l) for l in open(log)]
            check("keyring: only the old entry → it's read", got == "old-pw", got)
            check("keyring: new attribute asked first, then the old one",
                  [c[c.index("application") + 1] for c in calls] == ["sumi-shell", "kitasan-shell"], calls)
            open(log, "w").close()
            json.dump({"kitasan-shell/acc1": "old-pw", "sumi-shell/acc1": "new-pw"}, open(store, "w"))
            check("keyring: both → the new one wins", cs.secret_lookup("acc1") == "new-pw")
            open(log, "w").close()
            json.dump({}, open(store, "w"))
            try:
                cs.secret_lookup("acc1")
                ok = False
            except Exception as e:
                ok = "not in the keyring" in str(e)
            check("keyring: none → the usual keyring error", ok)
            open(log, "w").close()
            cs.secret_clear("acc1")
            cs.secret_store("acc2", "label", "pw")
            calls = [json.loads(l) for l in open(log)]
            check("keyring: clear and store only ever use the new attribute",
                  all(c[c.index("application") + 1] == "sumi-shell" for c in calls) and len(calls) == 2, calls)
        finally:
            os.environ.clear()
            os.environ.update(old)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ---- fuentes en kitty ------------------------------------------------------------------------------------------------

def t_kitty_names():
    sys.path.insert(0, os.path.join(TREE, "scripts"))
    fk = load("sumi_font_sync_kitty_t", os.path.join(TREE, "scripts", "font_sync_kitty.py"))
    tmp = tempfile.mkdtemp(prefix="sumi-compat-fk-")
    try:
        class P:
            config = tmp

        class Ctx:
            paths = P()
        kd = os.path.join(tmp, "kitty")
        os.makedirs(kd)
        open(os.path.join(kd, "kitty.conf"), "w").write("font_size 12\n")
        a = fk.Adapter(Ctx())
        check("kitty: a fresh kitty gets the new names", a.fragment == "sumi-shell-fonts.conf" and a.block == fk.BLOCK
              and a.frag.endswith("/sumi-shell-fonts.conf"), (a.fragment, a.frag))
        open(os.path.join(kd, "kitty.conf"), "w").write("font_size 12\n" + fk.LEGACY_BLOCK)
        a = fk.Adapter(Ctx())
        check("kitty: kitty.conf with the old block keeps the old names", a.fragment == "kitasan-shell-fonts.conf"
              and a.block == fk.LEGACY_BLOCK and a.mark == fk.LEGACY_MARK, a.fragment)
        open(os.path.join(kd, "kitty.conf"), "w").write("font_size 12\n")
        open(os.path.join(kd, "kitasan-shell-fonts.conf"), "w").write(fk.fragment_text("Iosevka", fk.LEGACY_MARK))
        a = fk.Adapter(Ctx())
        check("kitty: the old fragment alone also keeps the old names", a.fragment == "kitasan-shell-fonts.conf")
        check("kitty: the old fragment text is byte-identical to what the former name wrote",
              fk.fragment_text("X", fk.LEGACY_MARK) == "# KitasanShell — typography sync. Generated: changing it stops "
              "the shell from managing it.\nfont_family X\n")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    for t in (t_lock_sh, t_lockchain, t_notif_direct, t_notif_bash, t_keyring, t_kitty_names):
        try:
            t()
        except Exception as e:
            check(t.__name__ + " raised", False, repr(e))
    failed = 0
    for name, ok, detail in results:
        print("%-80s %s" % (name, "PASS" if ok else "FAIL"))
        if not ok:
            failed += 1
            print("    · %s" % (detail,))
    print("failed: %d of %d" % (failed, len(results)))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
