#!/usr/bin/env python3
"""Opt-in D-Bus notification activation for an exec-once Sumi Shell.

Only changes an existing settings file and an activation file it created. The
shell must be stopped: there is no safe restart/rescue manager in this mode.
"""

import sys
sys.dont_write_bytecode = True   # 2026-11-07: sin __pycache__ en el árbol de la shell (desinstalar lo dejaba a medias)
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile

from capabilities import q_bus, q_install, q_notif_owner


NAME = "org.freedesktop.Notifications"
MARK = "# sumi-notif-server direct v1\n"


def fail(message):
    raise RuntimeError(message)


def run(*argv):
    return subprocess.run(argv, text=True, capture_output=True, timeout=5, check=False)


def paths():
    home = Path.home()
    config = Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config")
    data = Path(os.environ.get("XDG_DATA_HOME") or home / ".local/share")
    return config / "sumi-shell/settings.json", data / "dbus-1/services/org.freedesktop.Notifications.service"


def regular(path):
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        return False
    if not stat.S_ISREG(mode):
        fail(f"{path} is not a regular file")
    return True


def owned(path):
    if not regular(path):
        return False
    return bool(re.fullmatch(re.escape(MARK + f"[D-BUS Service]\nName={NAME}\n") +
                             r"Exec=/\S+/qs -c sumi --no-duplicate\n", path.read_text()))


LEGACY_MARK = "# kitasan-notif-server direct v1\n"


def legacy_owned(path):
    """La que escribía esta herramienta antes del cambio de nombre (Kitasan-Shell, 2026-11-07): `qs -c kitasan`. Es nuestra:
    se sustituye (on) o se quita (off); nunca se confunde con la de otro servicio."""
    if not regular(path):
        return False
    return bool(re.fullmatch(re.escape(LEGACY_MARK + f"[D-BUS Service]\nName={NAME}\n") +
                             r"Exec=/\S+/qs -c kitasan --no-duplicate\n", path.read_text()))


def activation_body():
    qs = shutil.which("qs")
    if not qs or not os.path.isabs(qs) or any(c.isspace() for c in qs):
        fail("qs needs an absolute executable path without spaces for D-Bus Exec")
    return MARK + f"[D-BUS Service]\nName={NAME}\nExec={qs} -c sumi --no-duplicate\n"


def stopped(require_tree):
    q = q_install()
    if q.get("error"):
        fail("could not list shell instances: " + q["error"])
    if require_tree and not q.get("resolved"):
        fail("qs -c sumi does not resolve an installed shell")
    if q.get("instances"):
        fail("stop Sumi Shell while unlocked before changing direct notifications")
    owner = q_notif_owner()
    if owner.get("error"):
        fail("could not query the notification owner: " + owner["error"])
    if owner.get("pid"):
        fail("another process owns notifications; stop it before switching")


def bus_names():
    bus = q_bus("user")
    if bus.get("error"):
        fail("could not query the session bus: " + bus["error"])
    return bus


def reload_bus():
    p = run("busctl", "--user", "call", "org.freedesktop.DBus", "/org/freedesktop/DBus",
            "org.freedesktop.DBus", "ReloadConfig")
    if p.returncode:
        fail("D-Bus ReloadConfig failed: " + (p.stderr.strip() or str(p.returncode)))


def settings(path, value):
    if not regular(path):
        fail(f"{path} is missing; start the shell once to create its settings, then stop it")
    doc = json.loads(path.read_text())
    if not isinstance(doc, dict):
        fail("settings.json is not an object")
    shell = doc.setdefault("shell", {})
    if not isinstance(shell, dict):
        fail("settings.json shell is not an object")
    integ = shell.setdefault("integrations", {})
    if not isinstance(integ, dict):
        fail("settings.json shell.integrations is not an object")
    if integ.get("notificationServer") is value:
        return
    integ["notificationServer"] = value
    fd, tmp = tempfile.mkstemp(prefix=".settings-f8e-", dir=path.parent)
    try:
        os.fchmod(fd, stat.S_IMODE(path.stat().st_mode))
        with os.fdopen(fd, "w") as f:
            json.dump(doc, f, ensure_ascii=False, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def main(verb):
    setting, activation = paths()
    body = activation_body()
    if verb == "status":
        print(json.dumps({"activation": "ours" if owned(activation) else "legacy" if legacy_owned(activation) else
                          "foreign" if regular(activation) else "absent",
                          "setting": json.loads(setting.read_text()).get("shell", {}).get("integrations", {}).get(
                              "notificationServer") if regular(setting) else None}))
        return
    stopped(verb == "on")
    bus = bus_names()
    if verb == "on":
        if NAME in bus["names"]:
            fail("notification owner appeared during preflight")
        if legacy_owned(activation):
            activation.unlink()             # la del nombre viejo, comprobada entera: se sustituye por la nueva
            reload_bus()
            bus = bus_names()
        if regular(activation) and not owned(activation):
            fail(f"{activation} belongs to another service; it was not replaced")
        if owned(activation) and activation.read_text() != body:
            fail("the existing activation uses another qs path; run direct-off before changing it")
        if NAME in bus["activatable"] and not owned(activation):
            fail("another D-Bus activation provides notifications; it was not replaced")
        was_on = json.loads(setting.read_text()).get("shell", {}).get("integrations", {}).get("notificationServer") is True
        settings(setting, True)
        made = False
        try:
            activation.parent.mkdir(parents=True, exist_ok=True)
            if not owned(activation):
                fd = os.open(activation, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
                made = True
                with os.fdopen(fd, "w") as f:
                    f.write(body)
                    f.flush()
                    os.fsync(f.fileno())
            reload_bus()
            if NAME not in bus_names()["activatable"]:
                fail("D-Bus did not load the activation file")
        except Exception:
            if made and owned(activation):
                activation.unlink()
                try:
                    reload_bus()
                except Exception:
                    pass
            if not was_on:
                settings(setting, False)
            raise
        print(f"Ready: {activation}. A notification can start the shell; exec-once covers login.")
    elif verb == "off":
        if regular(activation):
            if not owned(activation) and not legacy_owned(activation):
                fail(f"{activation} belongs to another service; it was not removed")
            activation.unlink()
            reload_bus()
        settings(setting, False)
        print("Direct notification activation removed; the shell server is off on its next start.")
    else:
        fail("use on, off or status")


if __name__ == "__main__":
    try:
        main(sys.argv[1] if len(sys.argv) == 2 else "")
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print("notif-server direct: " + str(exc), file=sys.stderr)
        sys.exit(1)
