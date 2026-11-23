#!/usr/bin/env python3
"""F8b: iniciar apps directas y alternar sólo la agenda que inició esta sesión.

start -- ARGV       despega el proceso; confirma que arrancó antes de salir
calcurse -- ARGV    abre o cierra únicamente el terminal registrado por este helper

Sin shell de comandos, sin señales por nombre y sin procesos auxiliares duraderos.
"""
import fcntl
import hashlib
import json
import os
import select
import signal
import stat
import subprocess
import sys
import time
import uuid


def launch(argv):
    if not argv or not argv[0]:
        raise ValueError("No application command")
    proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
    # Detectar ejecutable inexistente y fallos de inicio, sin esperar a una app normal.
    try:
        code = proc.wait(timeout=0.2)
    except subprocess.TimeoutExpired:
        code = None
    if code is not None and code != 0:
        raise RuntimeError("Application exited during startup (%d): %s" % (code, argv[0]))
    return proc, code


def start_ticks(pid):
    try:
        with open("/proc/%d/stat" % pid) as f:
            return int(f.read().rsplit(")", 1)[1].split()[19])
    except (OSError, ValueError, IndexError):
        return None


def boot_id():
    with open("/proc/sys/kernel/random/boot_id") as f:
        return f.read().strip()


def _safe_dir():
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    if not runtime.startswith("/") or not runtime:
        raise RuntimeError("XDG_RUNTIME_DIR is missing")
    base = os.open(runtime, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        s = os.fstat(base)
        if s.st_uid != os.getuid() or s.st_mode & 0o022:
            raise RuntimeError("XDG_RUNTIME_DIR has an unsafe owner or mode")
        try:
            os.mkdir("sumi-shell", mode=0o700, dir_fd=base)
        except FileExistsError:
            pass
        d = os.open("sumi-shell", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=base)
        s = os.fstat(d)
        if s.st_uid != os.getuid() or s.st_mode & 0o077:
            os.close(d)
            raise RuntimeError("sumi-shell runtime directory has an unsafe owner or mode")
        return d
    finally:
        os.close(base)


def _open_lock(d, name):
    fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=d)
    s = os.fstat(fd)
    if s.st_uid != os.getuid() or not stat.S_ISREG(s.st_mode) or s.st_mode & 0o077:
        os.close(fd)
        raise RuntimeError("Agenda lock has an unsafe owner, type or mode")
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def _marker(d, name):
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=d)
    except FileNotFoundError:
        return None
    try:
        s = os.fstat(fd)
        if s.st_uid != os.getuid() or not stat.S_ISREG(s.st_mode) or s.st_mode & 0o077 or s.st_size > 4096:
            raise RuntimeError("Agenda marker has an unsafe owner, type or mode")
        with os.fdopen(os.dup(fd)) as f:
            obj = json.load(f)
        if not isinstance(obj, dict) or not isinstance(obj.get("pid"), int) or not isinstance(obj.get("start"), int):
            raise RuntimeError("Agenda marker is invalid")
        return obj
    finally:
        os.close(fd)


def _write_marker(d, name, value):
    tmp = ".%s-%s" % (name, uuid.uuid4().hex)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=d)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(value, f)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, name, src_dir_fd=d, dst_dir_fd=d)
        os.fsync(d)
    except BaseException:
        try:
            os.unlink(tmp, dir_fd=d)
        except FileNotFoundError:
            pass
        raise


def _living(obj):
    if obj["boot"] != boot_id():
        return None
    try:
        fd = os.pidfd_open(obj["pid"])
    except ProcessLookupError:
        return None
    if start_ticks(obj["pid"]) != obj["start"]:
        os.close(fd)
        return None
    return fd


def calcurse(argv):
    signature = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    if not signature:
        raise RuntimeError("No Hyprland session identity for agenda toggle")
    key = hashlib.sha256(signature.encode()).hexdigest()[:24]
    marker = "calcurse-%s.json" % key
    d = _safe_dir()
    try:
        lock = _open_lock(d, "calcurse-%s.lock" % key)
        try:
            prev = _marker(d, marker)
            fd = _living(prev) if prev else None
            if fd is not None:
                try:
                    if not hasattr(signal, "pidfd_send_signal"):
                        raise RuntimeError("pidfd_send_signal is required to stop the tracked agenda safely")
                    signal.pidfd_send_signal(fd, signal.SIGTERM)
                    poll = select.poll()
                    poll.register(fd, select.POLLIN)
                    if not poll.poll(2000):
                        raise RuntimeError("Tracked agenda did not exit; left its marker for retry")
                finally:
                    os.close(fd)
                os.unlink(marker, dir_fd=d)
                return "stopped"
            proc, code = launch(argv)
            if code is not None:
                raise RuntimeError("Agenda terminal exited immediately; cannot safely track it")
            ticks = start_ticks(proc.pid)
            if ticks is None:
                raise RuntimeError("Cannot identify the agenda process")
            _write_marker(d, marker, {"pid": proc.pid, "start": ticks, "boot": boot_id()})
            return "started"
        finally:
            os.close(lock)
    finally:
        os.close(d)


def main(args):
    if len(args) < 3 or args[0] not in ("start", "calcurse") or args[1] != "--":
        raise ValueError("Usage: app-launch.py start|calcurse -- COMMAND [ARGS...]")
    if args[0] == "start":
        launch(args[2:])
        return "started"
    return calcurse(args[2:])


if __name__ == "__main__":
    try:
        print(main(sys.argv[1:]))
    except (OSError, ValueError, RuntimeError) as e:
        print("app-launch: " + str(e), file=sys.stderr)
        sys.exit(1)
