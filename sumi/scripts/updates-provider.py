#!/usr/bin/env python3
"""Las actualizaciones propias de Sumi Shell (portabilidad F4e, 2026-10-08; H-15, HC-09, HC-10).

Lo usa la shell con `providers.updates` = auto o pacman. Hace lo mismo que el `updates.sh` del rice del autor
(que sigue siendo su proveedor `script`, por `updates-check.service`), con la MISMA caché, para que Updates,
Issues y el Dashboard la lean igual con uno u otro:

    $XDG_RUNTIME_DIR/sumi-updates.cache   {"text": "󰚰 N" | "󰄬", "tooltip": …, "class": [pending|critical|updated, error?],
                                           "risk": "" | texto, "risk_packages": […], "risk_ignore": […]}
    $XDG_RUNTIME_DIR/sumi-updates.pkgs    origen<TAB>paquete<TAB>versión<TAB>nueva (para la lista)

    updates-provider.py --check [--detach]  comprobar y escribir la caché (--detach: unidad transitoria
                                          o proceso directo con lock heredado; la shell no espera y una
                                          recarga no corta la comprobación)
    updates-provider.py --list              la lista legible (se abre en la terminal del usuario)
    updates-provider.py --upgrade [--ignore GLOBS]
                                            actualizar en la terminal (sysupdate si está; si no, el gestor de
                                            AUR o `sudo pacman -Syu`), volver a comprobar y esperar ⏎.
                                            --ignore (sólo con sysupdate) retiene esos paquetes (`-i`)
    updates-provider.py --resolve           qué hay (JSON); no comprueba nada

Backends: pacman (`checkupdates` de pacman-contrib: no toca la base real) más AUR con yay o paru si están.
Los demás gestores (apt, dnf, zypper, flatpak) son de F7: aquí, `auto` en un sistema sin pacman dice que no hay
proveedor para él. A diferencia de updates.sh, no manda notificaciones: lo enseña la shell.

sysupdate (2026-11-25, opcional): si está en el PATH, `--check` le pide su comprobación de riesgo
(`sysupdate check --json --no-sync --no-aur`, sólo lectura) y la deja en la caché con los mismos campos que
updates.sh: `risk` (el texto; "" = sin riesgo) y, además, `risk_packages` y `risk_ignore` (lo que sysupdate
propone retener). La watchlist es de sysupdate (ADR-13): aquí sólo se copia su veredicto. `--upgrade` lo
ejecuta en vez de yay / `sudo pacman -Syu`. Sin sysupdate, todo sigue como antes.
"""
import sys
sys.dont_write_bytecode = True   # 2026-11-07: sin __pycache__ en el árbol de la shell (desinstalar lo dejaba a medias)
import json
import os
import re
import shutil
import subprocess
import sys
import time

RUN = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
CACHE = os.environ.get("KT_UPDATES_CACHE") or os.path.join(RUN, "sumi-updates.cache")
PKGS = CACHE[:-len(".cache")] + ".pkgs" if CACHE.endswith(".cache") else CACHE + ".pkgs"
PREFIX = os.environ.get("SUMI_WALL_UNIT_PREFIX") or "app-sumi-"
FEW, MANY = 12, 50
SYSUPDATE_TIMEOUT = 60
# lo que se acepta como glob de --ignore (nombres de paquete de pacman más comodines); nunca rutas
GLOB = re.compile(r"^[A-Za-z0-9@._+*?\[\]-]+$")


def resolve():
    have = {n: bool(shutil.which(n)) for n in ("pacman", "checkupdates", "yay", "paru")}
    aur = "yay" if have["yay"] else "paru" if have["paru"] else ""
    out = {"backend": None, "aur": aur, "why": "", "label": ""}
    if have["pacman"]:
        if have["checkupdates"]:
            out["backend"] = "pacman"
            out["label"] = "pacman + AUR (%s)" % aur if aur else "pacman"
        else:
            out["why"] = "checkupdates (pacman-contrib) is not installed"
    else:
        out["why"] = "No update provider for this system yet (pacman only; others come later)"
    return out


def one_line(text):
    import re
    text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text or "")
    return " ".join(text.replace("\r", " ").replace("\t", " ").split())


def is_kernel(n):
    if not (n == "linux" or n.startswith("linux-")):
        return False
    return not any(x in n for x in ("headers", "firmware", "api", "docs", "tools"))


def run_check(r):
    """[(origen, nombre, vieja, nueva)], error ("" si fue bien)."""
    pkgs, errors = [], []
    p = subprocess.run(["checkupdates"], capture_output=True, text=True, timeout=180)
    if p.returncode not in (0, 2):        # 2 = nada que actualizar (no es un fallo)
        errors.append("checkupdates: " + one_line(p.stderr))
    for line in p.stdout.splitlines():
        f = line.split()
        if len(f) >= 4:
            pkgs.append(("pacman", f[0], f[1], f[3]))
    if r["aur"]:
        a, err = query_aur(r["aur"])
        if err:
            # Un reintento, como updates.sh: el RPC del AUR corta conexiones de vez en cuando (visto el
            # 2026-11-25, «connection reset by peer») y un solo tropiezo marcaba toda la comprobación como fallida.
            time.sleep(3)
            a, err = query_aur(r["aur"])
        if err:
            errors.append(err)
        for line in (a.stdout if a else "").splitlines():
            f = line.split()
            if len(f) >= 4:
                pkgs.append(("aur", f[0], f[1], f[3]))
    return pkgs, "; ".join(errors)


def query_aur(helper):
    """(proceso | None, error). -Qua sale con 1 también sin novedades: un fallo de verdad escribe en stderr."""
    try:
        a = subprocess.run([helper, "-Qua"], capture_output=True, text=True, timeout=20)
    except subprocess.TimeoutExpired:
        return None, "%s: timeout (20s)" % helper
    except OSError as e:
        return None, "%s: %s" % (helper, e)
    if a.returncode != 0 and a.stderr.strip():
        return a, "%s: %s" % (helper, one_line(a.stderr))
    return a, ""


def clean_globs(items):
    """Los globs de sysupdate que se pueden pasar a `-i` tal cual (sin comas ni rutas); el resto se descarta."""
    out = []
    for g in items or []:
        for part in str(g).split(","):
            part = part.strip()
            if part and GLOB.match(part) and part not in out:
                out.append(part)
    return out


def risk_check():
    """El veredicto de riesgo de sysupdate: {"risk": texto, "risk_packages": [...], "risk_ignore": [...]}.

    Vacío (sin riesgo, sin sysupdate o si no pudo comprobar) = {"risk": ""}. --no-sync reutiliza la base
    temporal que checkupdates acaba de sincronizar (sin red); --no-aur porque del AUR no hay comprobación.
    El texto es el de updates.sh del rice, para que la shell lo enseñe igual con uno u otro proveedor.
    """
    if not shutil.which("sysupdate"):
        return {"risk": ""}
    try:
        p = subprocess.run(["sysupdate", "check", "--json", "--no-sync", "--no-aur"],
                           capture_output=True, text=True, timeout=SYSUPDATE_TIMEOUT)
    except (subprocess.TimeoutExpired, OSError):
        return {"risk": ""}
    if p.returncode not in (0, 10):        # 1 = no pudo comprobar: no se inventa un riesgo
        return {"risk": ""}
    try:
        d = json.loads(p.stdout)
    except ValueError:
        return {"risk": ""}
    if not isinstance(d, dict) or not d.get("risky"):
        return {"risk": ""}
    names = [str(x.get("package")) for x in d.get("risks") or [] if isinstance(x, dict) and x.get("package")]
    ignore = clean_globs(d.get("suggested_ignore"))
    text = (", ".join(names) or "some packages") + " would run against dependencies it was not rebuilt for"
    if ignore:
        text += " — safe: sysupdate -i '" + ",".join(ignore) + "'"
    return {"risk": text, "risk_packages": names, "risk_ignore": ignore}


def table(pkgs):
    if not pkgs:
        return ""
    wn = max(len(p[1]) for p in pkgs)
    wo = max(len(p[2]) for p in pkgs)
    return "\n".join("%-*s  %*s → %s" % (wn, p[1], wo, p[2], p[3]) for p in pkgs)


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def write_atomic(path, text):
    tmp = path + ".%d" % os.getpid()
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def check():
    r = resolve()
    if not r["backend"]:
        print("updates-provider: " + r["why"], file=sys.stderr)
        return 1
    pkgs, error = run_check(r)
    write_atomic(PKGS, "".join("\t".join(p) + "\n" for p in pkgs))
    pac = len([p for p in pkgs if p[0] == "pacman"])
    aur = len(pkgs) - pac
    total = len(pkgs)
    kern = [p[1] for p in pkgs if is_kernel(p[1])]
    if total == 0:
        text, css = "󰄬", "updated"
        tooltip = "System up to date\nLast checked " + time.strftime("%H:%M")
    else:
        text, css = "󰚰 %d" % total, "critical" if total >= MANY else "pending"
        counts = "%d pacman" % pac + (" · %d AUR (%s)" % (aur, r["aur"]) if r["aur"] else "")
        tooltip = "%d update%s available\n%s" % (total, "" if total == 1 else "s", counts)
        if total <= FEW:
            tooltip += "\n\n<tt>" + esc(table(pkgs)) + "</tt>"
        if kern:
            tooltip += "\n\n⚠ Kernel update (%s) — reboot after updating" % ", ".join(kern)
    # como updates.sh: sólo con pendientes de pacman (el riesgo es de los repositorios oficiales)
    risk = risk_check() if pac > 0 else {"risk": ""}
    if risk["risk"]:
        tooltip += "\n\n⚠ Risky: " + esc(risk["risk"])
    classes = [css]
    if error:
        text += " 󰀦 "
        tooltip += "\n\n⚠ " + esc(error)
        classes.append("error")
    write_atomic(CACHE, json.dumps(dict({"text": text, "tooltip": tooltip, "class": classes,
                                         "provider": r["label"]}, **risk), ensure_ascii=False) + "\n")
    print(json.dumps({"total": total, "pacman": pac, "aur": aur, "error": error, "risky": bool(risk["risk"])}))
    return 0


def listing():
    try:
        with open(PKGS) as f:
            pkgs = [tuple(l.rstrip("\n").split("\t")) for l in f if l.count("\t") == 3]
    except OSError:
        print("Checking for updates...", file=sys.stderr)
        check()
        return listing()
    pac = [p for p in pkgs if p[0] == "pacman"]
    aur = [p for p in pkgs if p[0] == "aur"]
    if not pkgs:
        print("\n  System up to date — nothing to update.\n")
    else:
        print("\n  Pending updates — %d total (%d pacman, %d AUR)" % (len(pkgs), len(pac), len(aur)))
        for name, part in (("PACMAN", pac), ("AUR", aur)):
            if part:
                print("\n  %s (%d)\n" % (name, len(part)))
                print("\n".join("    " + l for l in table(part).splitlines()))
        kern = [p[1] for p in pkgs if is_kernel(p[1])]
        if kern:
            print("\n  Kernel update included (%s) — reboot after updating." % ", ".join(kern))
    try:
        print("\n  Cache written: %s\n" % time.strftime("%Y-%m-%d %H:%M", time.localtime(os.stat(PKGS).st_mtime)))
    except OSError:
        pass
    return 0


def upgrade(ignore=None):
    r = resolve()
    if not r["backend"]:
        print("updates-provider: " + r["why"], file=sys.stderr)
        return 1
    if shutil.which("sysupdate"):
        # sysupdate ya enseña lo pendiente, verifica y da un veredicto; su pausa se omite porque aquí
        # se vuelve a comprobar después y se espera ⏎ una sola vez, al final
        argv = ["sysupdate", "--no-pause"] + (["-i", ",".join(ignore)] if ignore else [])
    elif ignore:
        print("updates-provider: --ignore needs sysupdate, which is not installed", file=sys.stderr)
        return 2
    else:
        argv = [r["aur"], "-Syu"] if r["aur"] else ["sudo", "pacman", "-Syu"]
    print("$ " + " ".join(argv), flush=True)
    rc = subprocess.call(argv)
    print("\nChecking again…")
    check()
    try:
        input("\nPress Enter to close")
    except EOFError:
        pass
    return rc


def detach():
    """--check en una unidad transitoria de usuario (fuera del cgroup de la shell). Si ya hay una, nada."""
    unit = PREFIX + "updates-check"
    me = [sys.executable or "python3", "-B", os.path.abspath(__file__), "--check"]
    from user_manager import backend, start_direct_once
    try:
        manager = backend()
    except RuntimeError as e:
        print("updates-provider: " + str(e), file=sys.stderr)
        return 1
    if manager == "systemd":
        a = subprocess.run(["systemctl", "--user", "is-active", unit + ".service"], capture_output=True, text=True)
        if a.stdout.strip() in ("active", "activating"):
            print("already running")
            return 0
        env = []
        for k in ("HOME", "PATH", "XDG_RUNTIME_DIR", "KT_UPDATES_CACHE", "LANG"):
            if os.environ.get(k):
                env += ["--setenv", "%s=%s" % (k, os.environ[k])]
        p = subprocess.run(["systemd-run", "--user", "--quiet", "--collect", "--unit", unit, "-p", "TimeoutStopSec=30"]
                           + env + ["--"] + me, capture_output=True, text=True, timeout=15)
        if p.returncode == 0:
            print("started " + unit)
            return 0
        print("updates-provider: systemd-run failed: " + (p.stderr or "").strip()[:200], file=sys.stderr)
        return 1
    started = start_direct_once(me, os.path.join(RUN, "sumi-updates-detach.lock"))
    print("started" if started else "already running")
    return 0


def main(argv):
    if argv == ["--resolve"]:
        print(json.dumps(resolve()))
        return 0
    if argv == ["--check"]:
        return check()
    if argv in (["--check", "--detach"], ["--detach", "--check"]):
        r = resolve()
        if not r["backend"]:
            print("updates-provider: " + r["why"], file=sys.stderr)
            return 1
        return detach()
    if argv == ["--list"]:
        return listing()
    if argv == ["--upgrade"]:
        return upgrade()
    if len(argv) == 3 and argv[:2] == ["--upgrade", "--ignore"]:
        globs = clean_globs([argv[2]])
        if not globs or len(globs) != len([x for x in argv[2].split(",") if x.strip()]):
            print("updates-provider: --ignore takes package names or globs: " + argv[2], file=sys.stderr)
            return 2
        return upgrade(globs)
    print("updates-provider: unknown option: " + " ".join(argv), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
