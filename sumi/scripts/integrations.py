#!/usr/bin/env python3
"""Quién es dueño de las integraciones del escritorio (Settings, fase 14A; sólo lectura).

    integrations.py read <pid del shell>

  · notificaciones: el dueño del nombre org.freedesktop.Notifications en el bus de sesión
    (su pid y su ejecutable), y si es el shell;
  · polkit: agentes de autenticación conocidos que estén corriendo aparte del shell.

El agente de polkit no se puede preguntar por D-Bus (polkit no publica la lista de agentes), así
que se buscan procesos por nombre de ejecutable conocido. Sólo se lee /proc; no se manda nada.
Salida: JSON en stdout.
"""
import json
import os
import subprocess
import sys

KNOWN_AGENTS = (
    "polkit-kde-authentication-agent-1", "polkit-kde-auth", "polkit-gnome-authentication-agent-1",
    "hyprpolkitagent", "lxpolkit", "lxqt-policykit-agent", "mate-polkit", "polkit-mate-authentication-agent-1",
    "xfce-polkit", "polkit-efl-authentication-agent-1", "soteria", "polkit-agent-helper-1",
)
KNOWN_NOTIFIERS = ("swaync", "mako", "dunst", "fnott", "notification-daemon", "xfce4-notifyd")


def comm(pid):
    try:
        with open("/proc/%d/comm" % pid) as f:
            return f.read().strip()
    except OSError:
        return ""


def exe_name(pid):
    try:
        return os.path.basename(os.readlink("/proc/%d/exe" % pid))
    except OSError:
        return ""


def owner_pid(name):
    try:
        p = subprocess.run(["busctl", "--user", "call", "org.freedesktop.DBus", "/org/freedesktop/DBus",
                            "org.freedesktop.DBus", "GetConnectionUnixProcessID", "s", name],
                           capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if p.returncode != 0:
        return 0      # nadie tiene el nombre
    try:
        return int(p.stdout.split()[1])
    except (IndexError, ValueError):
        return None


def processes():
    out = []
    for d in os.listdir("/proc"):
        if d.isdigit():
            pid = int(d)
            out.append((pid, comm(pid), exe_name(pid)))
    return out


def main(argv):
    if len(argv) != 3 or argv[1] != "read" or not argv[2].isdigit():
        print("usage: integrations.py read <shell pid>", file=sys.stderr)
        return 2
    shell = int(argv[2])
    pid = owner_pid("org.freedesktop.Notifications")
    procs = processes()
    agents = [{"pid": p, "name": e or c} for p, c, e in procs
              if p != shell and (c in KNOWN_AGENTS or e in KNOWN_AGENTS) and e != "polkit-agent-helper-1"]
    notifiers = [{"pid": p, "name": e or c} for p, c, e in procs if c in KNOWN_NOTIFIERS or e in KNOWN_NOTIFIERS]
    res = {
        "notifications": {"pid": pid, "name": (exe_name(pid) or comm(pid)) if pid else "",
                          "shell": pid == shell, "others": notifiers},
        "polkit": {"others": agents},
    }
    json.dump(res, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
