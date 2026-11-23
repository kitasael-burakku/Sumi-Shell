#!/usr/bin/env python3
"""Sumi Shell — tests/release/version-check.py against copies of the distribution (2026-11-07).

Uso: python3 -B tests/release/version-check-test.py      (desde la raíz del repo)

Cada caso copia lo que lee la comprobación (sumi/version.json, packaging/, README.md, API.md, CHANGELOG.md) a un
directorio temporal, cambia UNA cosa y exige el resultado: el árbol tal cual pasa; cada discrepancia falla con su id;
un estado 0.5.0-alpha.1 coherente en todas partes pasa (sin tocar la versión real). Nada se escribe en el repo.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CHECK = os.path.join(ROOT, "tests", "release", "version-check.py")
results = []


def copy():
    t = tempfile.mkdtemp(prefix="sumi-vct-")
    os.makedirs(os.path.join(t, "sumi"))
    shutil.copy2(os.path.join(ROOT, "sumi", "version.json"), os.path.join(t, "sumi"))
    shutil.copytree(os.path.join(ROOT, "packaging"), os.path.join(t, "packaging"),
                    ignore=shutil.ignore_patterns("__pycache__"))
    for f in ("README.md", "API.md", "CHANGELOG.md"):
        shutil.copy2(os.path.join(ROOT, f), t)
    return t


def edit(t, rel, fn):
    p = os.path.join(t, rel)
    s = open(p, encoding="utf-8").read()
    n = fn(s)
    assert n != s, "edit of %s changed nothing" % rel
    open(p, "w", encoding="utf-8").write(n)


def setver(t, **kw):
    p = os.path.join(t, "sumi", "version.json")
    d = json.load(open(p))
    d.update(kw)
    json.dump(d, open(p, "w"))


def run(t):
    r = subprocess.run([sys.executable, "-B", CHECK, t, "--json"], capture_output=True, text=True)
    try:
        doc = json.loads(r.stdout)
    except ValueError:
        doc = {"findings": [{"level": "error", "id": "crash", "message": r.stderr[-300:]}]}
    return r.returncode, {f["id"] for f in doc["findings"] if f["level"] == "error"}


def case(name, mutate, want_rc, want_ids=()):
    t = copy()
    try:
        mutate(t)
        rc, ids = run(t)
        ok = rc == want_rc and set(want_ids) <= ids and (want_rc != 0 or not ids)
        results.append((name, ok, "rc %d, errors %s" % (rc, sorted(ids))))
    finally:
        shutil.rmtree(t, ignore_errors=True)


def coherent(t, version, pkgver):
    """La misma versión en todos los sitios: lo que haría una alpha preparada como es debido."""
    setver(t, version=version, minUpdateFrom=version)
    old = json.load(open(os.path.join(ROOT, "sumi", "version.json")))["version"]
    edit(t, "packaging/arch/sumi-shell/PKGBUILD",
         lambda s: re.sub(r"^pkgver=.*$", "pkgver=" + pkgver, s, flags=re.M).replace("sumi-shell-%s.tar" % old,
                                                                                     "sumi-shell-%s.tar" % version))
    edit(t, "packaging/arch/sumi-shell/.SRCINFO", lambda s: re.sub(r"pkgver = .*", "pkgver = " + pkgver, s))
    edit(t, "README.md", lambda s: s.replace("Application version: **%s**" % old, "Application version: **%s**" % version))
    edit(t, "API.md", lambda s: s.replace("shell version **%s**" % old, "shell version **%s**" % version)
         .replace('"version":"%s"' % old, '"version":"%s"' % version))
    edit(t, "CHANGELOG.md", lambda s: s.replace("## [Unreleased]\n", "## [Unreleased]\n\n## [%s] - 2026-11-08\n" % version, 1))


case("the tree as it is passes", lambda t: None, 0)
case("a consistent 0.5.0-alpha.1 passes", lambda t: coherent(t, "0.5.0-alpha.1", "0.5.0alpha1"), 0)
case("a consistent 0.5.0-beta.10 passes", lambda t: coherent(t, "0.5.0-beta.10", "0.5.0beta10"), 0)
case("invalid version", lambda t: setver(t, version="0.5"), 1, ["version"])
case("prerelease outside the policy", lambda t: coherent(t, "0.5.0-dev.1", "0.5.0dev1"), 1, ["version"])
case("build metadata in version.json", lambda t: setver(t, version="0.4.0+abc"), 1, ["version"])
case("minUpdateFrom newer than version", lambda t: setver(t, minUpdateFrom="0.5.0"), 1, ["minUpdateFrom"])
case("minUpdateFrom invalid", lambda t: setver(t, minUpdateFrom="latest"), 1, ["minUpdateFrom"])
case("a prerelease minUpdateFrom ≤ a final version passes", lambda t: setver(t, minUpdateFrom="0.4.0-rc.1"), 0)
case("PKGBUILD pkgver not the translation", lambda t: coherent(t, "0.5.0-alpha.1", "0.5.0-alpha.1"), 1, ["pkgbuild"])
case("PKGBUILD with a separator (sorts after the release)", lambda t: coherent(t, "0.5.0-alpha.1", "0.5.0.alpha1"), 1,
     ["pkgbuild"])
case(".SRCINFO out of date", lambda t: edit(t, "packaging/arch/sumi-shell/.SRCINFO",
                                            lambda s: re.sub(r"pkgver = .*", "pkgver = 0.3.9", s)), 1, ["srcinfo"])
case("README out of date", lambda t: edit(t, "README.md", lambda s: s.replace("Application version: **", "Application version: **9", 1)),
     1, ["readme"])
case("API.md out of date", lambda t: edit(t, "API.md", lambda s: s.replace("shell version **", "shell version **9", 1)), 1,
     ["api-md"])
case("apiVersion changed only in version.json", lambda t: setver(t, apiVersion=2), 1, ["readme", "api-md"])
case("no changelog section for the version", lambda t: setver(t, version="0.4.1", minUpdateFrom="0.4.0") or edit(
    t, "README.md", lambda s: s.replace("**0.4.0**", "**0.4.1**", 1)) or edit(
    t, "API.md", lambda s: s.replace("shell version **0.4.0**", "shell version **0.4.1**").replace('"version":"0.4.0"', '"version":"0.4.1"'))
     or edit(t, "packaging/arch/sumi-shell/PKGBUILD", lambda s: s.replace("pkgver=0.4.0", "pkgver=0.4.1")
             .replace("sumi-shell-0.4.0.tar", "sumi-shell-0.4.1.tar"))
     or edit(t, "packaging/arch/sumi-shell/.SRCINFO", lambda s: s.replace("pkgver = 0.4.0", "pkgver = 0.4.1")),
     1, ["changelog"])
case("no Unreleased section", lambda t: edit(t, "CHANGELOG.md", lambda s: s.replace("## [Unreleased]", "## Next")), 1,
     ["changelog"])


def tagged(t, tag):
    for a in (["init", "-q"], ["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "x"],
              ["tag", tag]):
        subprocess.run(["git", "-C", t] + a, check=True, capture_output=True)


case("a v-tag that isn't the version", lambda t: tagged(t, "v0.9.0"), 1, ["tag"])
case("the right v-tag passes", lambda t: tagged(t, "v0.4.0"), 0)
case("a tag that isn't v* (like the rice's 1.0) is ignored", lambda t: tagged(t, "1.0"), 0)

failed = 0
for name, ok, detail in results:
    print("%-60s %s" % (name, "PASS" if ok else "FAIL"))
    if not ok:
        failed += 1
        print("    · " + detail)
print("failed: %d of %d" % (failed, len(results)))
sys.exit(1 if failed else 0)
