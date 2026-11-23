"""Non-activating user-manager selection for standalone provider scripts."""

import shutil
import fcntl
import os
import subprocess


def backend():
    from capabilities import q_bus
    bus = q_bus("user")
    if "error" in bus:
        raise RuntimeError("could not check the user service manager: " + bus["error"])
    name = "org.freedesktop.systemd1"
    if name in bus["names"]:
        if not shutil.which("systemd-run"):
            raise RuntimeError("systemd-run is required with a user service manager")
        return "systemd"
    if name not in bus["activatable"]:
        return "direct"
    raise RuntimeError("user service manager is activatable but not running")


def start_direct_once(argv, lock_path):
    """Keep one short-lived job alive outside the shell, with its lock in the child."""
    os.makedirs(os.path.dirname(lock_path), exist_ok=True)
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_CLOEXEC, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return False
        subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True, pass_fds=(fd,))
        return True
    finally:
        os.close(fd)
