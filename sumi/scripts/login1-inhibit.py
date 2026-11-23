#!/usr/bin/env python3
"""Hold a login1 inhibitor until the shell releases stdin or its PID exits.

This is the direct backend for F8c. The Unix FD returned by Inhibit remains
owned by this short-lived helper; no systemd-inhibit process is required.
"""
import argparse
import os
import select
import sys


DEST = "org.freedesktop.login1"
PATH = "/org/freedesktop/login1"
IFACE = "org.freedesktop.login1.Manager"


def hold(what, who, why, owner_pid):
    try:
        import dbus
    except ImportError as exc:
        raise RuntimeError("python-dbus is required for direct login1 inhibition") from exc

    if what not in ("idle", "idle:sleep") or not who or not why or owner_pid < 1:
        raise ValueError("Invalid inhibitor request")
    owner_fd = os.pidfd_open(owner_pid)
    bus = dbus.SystemBus(private=True)
    dbus_obj = dbus.Interface(bus.get_object("org.freedesktop.DBus", "/org/freedesktop/DBus",
                                             introspect=False), "org.freedesktop.DBus")
    login_owner = str(dbus_obj.GetNameOwner(DEST, timeout=2))
    login = dbus.Interface(bus.get_object(DEST, PATH, introspect=False), IFACE)
    inhibitor = login.Inhibit(what, who, why, "block", timeout=3)
    if not isinstance(inhibitor, dbus.types.UnixFd):
        raise RuntimeError("login1 did not return a Unix FD")
    fd = inhibitor.take()
    try:
        print("READY", flush=True)
        watcher = select.poll()
        watcher.register(sys.stdin.fileno(), select.POLLIN | select.POLLHUP | select.POLLERR)
        watcher.register(owner_fd, select.POLLIN)
        while True:
            for ready, _ in watcher.poll(500):
                if ready == owner_fd:
                    return
                if ready == sys.stdin.fileno() and not os.read(ready, 4096):
                    return
            # A restart invalidates the old daemon's FD even if our copy stays
            # open. Exit so Session can reconnect and acquire a new inhibitor.
            if str(dbus_obj.GetNameOwner(DEST, timeout=1)) != login_owner:
                raise RuntimeError("login1 owner changed; reacquire inhibitor")
    finally:
        os.close(fd)
        os.close(owner_fd)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("what", choices=("idle", "idle:sleep"))
    parser.add_argument("who")
    parser.add_argument("why")
    parser.add_argument("owner_pid", type=int)
    args = parser.parse_args()
    hold(args.what, args.who, args.why, args.owner_pid)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, Exception) as exc:
        # D-Bus errors are Exception subclasses and should be visible to QML.
        print("login1-inhibit: " + str(exc), file=sys.stderr)
        sys.exit(1)
