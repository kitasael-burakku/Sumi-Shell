#!/usr/bin/env python3
"""Importar y exportar preferencias (rediseño 12E, 2026-09-28; futureSettingssurface §12).

Sólo mueve bytes; QUÉ se exporta y qué vale al importar lo decide `services/Portability.qml`
contra el catálogo. Un import nunca ejecuta nada del archivo: se lee como datos.

    write  --out F            (JSON por stdin) nunca pisa: si F existe, error `exists`
    read   --file F           ≤ 256 KB, JSON → {doc}
    exists                    (lista JSON de rutas por stdin, `~` admitido) → {ruta: bool}
    backup --src S --dir D    copia de S en D/settings.pre-import-<ms>.json → {file}

Una línea JSON por orden (`ok` y lo demás).
"""
import argparse
import json
import os
import sys
import time

MAX_BYTES = 256 * 1024


def out(ok, **kw):
    kw["ok"] = ok
    print(json.dumps(kw))
    sys.exit(0 if ok else 1)


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    x = sub.add_parser("write")
    x.add_argument("--out", required=True)
    x = sub.add_parser("read")
    x.add_argument("--file", required=True)
    sub.add_parser("exists")
    x = sub.add_parser("backup")
    x.add_argument("--src", required=True)
    x.add_argument("--dir", required=True)
    a = p.parse_args()

    if a.cmd == "write":
        path = os.path.expanduser(a.out)
        if os.path.exists(path):
            out(False, error="exists", path=path)
        data = sys.stdin.buffer.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            out(False, error="too-large")
        try:
            json.loads(data)
            d = os.path.dirname(path) or "."
            os.makedirs(d, exist_ok=True)
            tmp = os.path.join(d, ".%s.kt-%d" % (os.path.basename(path), os.getpid()))
            with open(tmp, "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, 0o644)
            # link + unlink: si alguien lo creó entretanto, no se pisa (a diferencia de replace)
            os.link(tmp, path)
            os.unlink(tmp)
        except FileExistsError:
            os.unlink(tmp)
            out(False, error="exists", path=path)
        except (OSError, ValueError) as e:
            out(False, error="write-failed", detail=str(e))
        out(True, path=path)

    if a.cmd == "read":
        path = os.path.expanduser(a.file)
        if not os.path.isfile(path):
            out(False, error="not-found", path=path)
        if os.path.getsize(path) > MAX_BYTES:
            out(False, error="too-large", path=path)
        try:
            with open(path, "rb") as f:
                doc = json.loads(f.read())
        except ValueError:
            out(False, error="not-json", path=path)
        except OSError as e:
            out(False, error="unreadable", detail=str(e), path=path)
        out(True, path=path, doc=doc)

    if a.cmd == "exists":
        try:
            paths = json.loads(sys.stdin.read(MAX_BYTES))
        except ValueError:
            out(False, error="bad-input")
        res = {}
        for q in paths if isinstance(paths, list) else []:
            if isinstance(q, str):
                res[q] = os.path.isdir(os.path.expanduser(q)) or os.path.isfile(os.path.expanduser(q))
        out(True, exists=res)

    if a.cmd == "backup":
        try:
            os.makedirs(a.dir, mode=0o700, exist_ok=True)
            dst = os.path.join(a.dir, "settings.pre-import-%d.json" % int(time.time() * 1000))
            with open(a.src, "rb") as f:
                data = f.read()
            with open(dst, "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
        except OSError as e:
            out(False, error="backup-failed", detail=str(e))
        out(True, file=dst)


if __name__ == "__main__":
    main()
