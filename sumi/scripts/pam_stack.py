#!/usr/bin/env python3
"""La pila PAM del Lock: dónde está y si cuenta intentos con pam_faillock (portabilidad F5e, 2026-10-10; H-26, HC-53/54).

    pam_stack.py <servicio>   JSON: {service, dir, file, exists, faillock{present, args, conf}, auth[], files[], error}
    pam_stack.py --list       JSON: {candidates: [...]} — los servicios conocidos que existen aquí (para elegir en Settings)

Sólo lee archivos. El servicio se busca en /etc/pam.d y después en los directorios del proveedor (/usr/lib/pam.d,
/usr/share/pam.d), como libpam; `dir` es donde está, y la shell se lo pasa a PamContext como configDirectory. Se siguen
`include` y `substack` (por tipo) y el `@include` de Debian, como mucho 8 niveles. `faillock.present` = algún módulo
`pam_faillock.so` en la parte `auth` (también con `-auth`). Sus argumentos `deny=`, `unlock_time=`, `fail_interval=` y `dir=`
mandan sobre /etc/security/faillock.conf (o el `conf=` que se le dé), como en pam_faillock.

Para pruebas: SUMI_PAM_DIRS (lista separada por «:») sustituye a los directorios del sistema.
"""
import json
import os
import re
import sys

DIRS = [d for d in os.environ.get("SUMI_PAM_DIRS", "/etc/pam.d:/usr/lib/pam.d:/usr/share/pam.d").split(":") if d]
NAME = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,63}$")
CANDIDATES = ("login", "system-local-login", "system-login", "hyprlock", "swaylock", "gtklock", "system-auth",
              "common-auth", "password-auth")


def find(service):
    for d in DIRS:
        p = os.path.join(d, service)
        if os.path.isfile(p):
            return d, p
    return None, None


def tokens(line):
    """Las columnas de una línea PAM, con el control entre corchetes como una sola."""
    out, cur, depth = [], "", 0
    for ch in line:
        if ch == "[":
            depth += 1
        elif ch == "]":
            depth = max(0, depth - 1)
        if ch.isspace() and depth == 0:
            if cur:
                out.append(cur)
                cur = ""
            continue
        cur += ch
    if cur:
        out.append(cur)
    return out


def walk(service, kind, depth, files, entries, errors):
    """Las líneas `kind` (auth, account…) de `service`, siguiendo include/substack/@include."""
    if depth > 8:
        errors.append("include depth > 8 at " + service)
        return
    d, p = find(service)
    if not p:
        errors.append("missing included service " + service)
        return
    if p not in files:
        files.append(p)
    try:
        text = open(p, encoding="utf-8", errors="replace").read()
    except OSError as e:
        errors.append("can't read %s: %s" % (p, e))
        return
    for raw in text.split("\n"):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("@include"):
            parts = line.split()
            if len(parts) > 1:
                walk(parts[1], kind, depth + 1, files, entries, errors)
            continue
        t = tokens(line)
        if len(t) < 3:
            continue
        typ = t[0].lstrip("-")
        if typ != kind:
            continue
        control, module, args = t[1], t[2], t[3:]
        if control in ("include", "substack"):
            walk(module, kind, depth + 1, files, entries, errors)
            continue
        entries.append({"control": control, "module": os.path.basename(module), "args": args,
                        "file": p, "optional": t[0].startswith("-")})


def report(service):
    out = {"service": service, "dir": "", "file": "", "exists": False, "faillock": {"present": False, "args": {}, "conf": ""},
           "auth": [], "files": [], "error": ""}
    if not NAME.match(service or "") or service == "other":
        out["error"] = "not a usable PAM service name"
        return out
    d, p = find(service)
    if not p:
        out["error"] = "no %s in %s" % (service, ", ".join(DIRS))
        return out
    out.update(dir=d, file=p, exists=True)
    entries, errors = [], []
    walk(service, "auth", 0, out["files"], entries, errors)
    out["auth"] = [e["module"] for e in entries]
    fl = [e for e in entries if e["module"] == "pam_faillock.so"]
    if fl:
        args = {}
        for e in fl:
            for a in e["args"]:
                k, eq, v = a.partition("=")
                if eq and k in ("deny", "unlock_time", "fail_interval", "dir", "conf"):
                    args[k] = v
        out["faillock"] = {"present": True, "args": {k: v for k, v in args.items() if k != "conf"},
                           "conf": args.get("conf", "")}
    if errors:
        out["error"] = "; ".join(errors)[:300]
    return out


def main(argv):
    if len(argv) == 2 and argv[1] == "--list":
        print(json.dumps({"candidates": [c for c in CANDIDATES if find(c)[1]]}))
        return 0
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    print(json.dumps(report(argv[1])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
