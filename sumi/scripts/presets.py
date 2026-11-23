#!/usr/bin/env python3
"""Presets personales en disco (rediseño 12D, 2026-09-28).

futureSettingssurface §12: los presets del usuario viven en `~/.config/sumi-shell/presets/`,
uno por archivo; una actualización del shell nunca los toca (los integrados están en el código).
Cada escritura es atómica y la versión anterior se guarda en `backups/presets/` (las cinco
últimas por preset), para «restaurarse desde su propio backup». Lo que VALE un preset lo decide
`services/Presets.qml` contra el catálogo; aquí sólo se guarda y se lee.

    list    --dir D                         → [{file, id, doc | error}]
    write   --dir D --backup B --id ID      (JSON por stdin)
    delete  --dir D --backup B --id ID
    restore --dir D --backup B --id ID      la copia más reciente vuelve a su sitio
    backups --backup B --id ID              cuántas copias hay

Una línea JSON por orden (`ok` y lo demás).
"""
import argparse
import json
import os
import re
import sys
import time

ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,47}$")
MAX_BYTES = 64 * 1024
KEEP = 5


def out(ok, **kw):
    kw["ok"] = ok
    print(json.dumps(kw))
    sys.exit(0 if ok else 1)


def write_atomic(path, data):
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o700, exist_ok=True)
    tmp = os.path.join(d, ".%s.kt-%d" % (os.path.basename(path), os.getpid()))
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def backups(backup, pid):
    try:
        names = [n for n in os.listdir(backup) if n.startswith(pid + ".") and n.endswith(".json")]
    except OSError:
        return []
    return sorted(names, key=lambda n: os.path.getmtime(os.path.join(backup, n)), reverse=True)


def keep_backup(path, backup, pid):
    """La versión que se va a pisar o borrar, a backups/ (las KEEP últimas)."""
    if not os.path.isfile(path):
        return
    with open(path, "rb") as f:
        data = f.read()
    write_atomic(os.path.join(backup, "%s.%d.json" % (pid, int(time.time() * 1000))), data)
    for old in backups(backup, pid)[KEEP:]:
        try:
            os.remove(os.path.join(backup, old))
        except OSError:
            pass


def cmd_list(a):
    res = []
    try:
        names = sorted(n for n in os.listdir(a.dir) if n.endswith(".json") and not n.startswith("."))
    except FileNotFoundError:
        out(True, presets=[])
    except OSError as e:
        out(False, error="unreadable", detail=str(e))
    for n in names:
        p = os.path.join(a.dir, n)
        rec = {"file": n, "id": n[:-5]}
        try:
            if os.path.getsize(p) > MAX_BYTES:
                rec["error"] = "too large"
            else:
                with open(p) as f:
                    rec["doc"] = json.load(f)
        except (OSError, ValueError) as e:
            rec["error"] = "not valid JSON" if isinstance(e, ValueError) else str(e)
        res.append(rec)
    out(True, presets=res)


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    x = sub.add_parser("list")
    x.add_argument("--dir", required=True)
    for name in ("write", "delete", "restore"):
        x = sub.add_parser(name)
        x.add_argument("--dir", required=True)
        x.add_argument("--backup", required=True)
        x.add_argument("--id", required=True)
    x = sub.add_parser("backups")
    x.add_argument("--backup", required=True)
    x.add_argument("--id", required=True)
    a = p.parse_args()

    if a.cmd == "list":
        cmd_list(a)
    if not ID_RE.match(a.id):
        out(False, error="bad-id")
    if a.cmd == "backups":
        out(True, count=len(backups(a.backup, a.id)))
    path = os.path.join(a.dir, a.id + ".json")
    try:
        if a.cmd == "write":
            data = sys.stdin.buffer.read(MAX_BYTES + 1)
            if len(data) > MAX_BYTES:
                out(False, error="too-large")
            json.loads(data)
            keep_backup(path, a.backup, a.id)
            write_atomic(path, data)
            out(True, id=a.id)
        if a.cmd == "delete":
            keep_backup(path, a.backup, a.id)
            if os.path.isfile(path):
                os.remove(path)
            out(True, id=a.id)
        if a.cmd == "restore":
            b = backups(a.backup, a.id)
            if not b:
                out(False, error="no-backup")
            with open(os.path.join(a.backup, b[0]), "rb") as f:
                data = f.read()
            json.loads(data)
            os.remove(os.path.join(a.backup, b[0]))
            keep_backup(path, a.backup, a.id)
            write_atomic(path, data)
            out(True, id=a.id, left=len(b) - 1)
    except (OSError, ValueError) as e:
        out(False, error=a.cmd + "-failed", detail=str(e))


if __name__ == "__main__":
    main()
