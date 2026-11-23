#!/usr/bin/env python3
"""Suelta la inhibición al cerrar el pipe o al morir la instancia propietaria."""
import os
import select
import sys

owner = int(sys.argv[1])
try:
    pidfd = os.pidfd_open(owner)
except ProcessLookupError:
    sys.exit(0)
# systemd-inhibit sólo lanza este hijo cuando ya posee el descriptor de logind.
print("READY", flush=True)
while True:
    ready, _, _ = select.select([sys.stdin.fileno(), pidfd], [], [])
    if pidfd in ready or not os.read(sys.stdin.fileno(), 4096):
        break
os.close(pidfd)
