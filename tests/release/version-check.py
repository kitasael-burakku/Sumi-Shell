#!/usr/bin/env python3
"""Sumi Shell — the release consistency check (docs/sumi-shell/RELEASE-POLICY.md §4, 2026-11-07). READ ONLY.

Uso: python3 -B tests/release/version-check.py [DIST] [--srcinfo] [--json]
     DIST = la raíz de la distribución (por defecto, la de este archivo: install.sh, sumi/, packaging/…)

`sumi/version.json` es la ÚNICA fuente de la versión; aquí se comprueba que todo lo demás la sigue:
  1  version: SemVer 2.0.0 y la política (prerelease sólo alpha.N/beta.N/rc.N; sin +BUILD)
  2  minUpdateFrom: SemVer válido y ≤ version
  3  PKGBUILD estable: pkgver = la traducción a pacman y el tarball lleva la versión
  4  .SRCINFO: mismo pkgver/pkgrel que su PKGBUILD (con --srcinfo además = `makepkg --printsrcinfo`, si hay makepkg)
  5  README.md y API.md nombran la misma versión y apiVersion
  6  CHANGELOG.md (Keep a Changelog): «## [Unreleased]» y una sección «## [version]»
  7  si HEAD tiene un tag v*: es exactamente «v» + version
  8  apiVersion respecto del tag anterior: sólo INFORMA (decisión del 2026-11-07: un aumento no exige MAJOR por sí solo)
Salida 0 sin errores, 1 con errores, 2 si la comprobación no pudo hacerse.
"""
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

args = [a for a in sys.argv[1:] if not a.startswith("--")]
DIST = os.path.abspath(args[0]) if args else os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WANT_SRCINFO = "--srcinfo" in sys.argv
findings = []


def add(level, cid, msg):
    findings.append({"level": level, "id": cid, "message": msg})


def read(rel):
    try:
        with open(os.path.join(DIST, rel), encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


try:
    spec = importlib.util.spec_from_file_location("sumi_semver", os.path.join(DIST, "packaging", "semver.py"))
    S = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(S)
    vj = json.loads(read("sumi/version.json"))
except (OSError, ValueError, TypeError, AttributeError) as e:
    print("version-check: can't read the distribution (%s)" % e, file=sys.stderr)
    sys.exit(2)

version, api = vj.get("version"), vj.get("apiVersion")
# 1
for e in S.policy(version):
    add("error", "version", e)
ok_version = not S.policy(version)
# 2
mu = vj.get("minUpdateFrom")
if S.parse(mu or "") is None:
    add("error", "minUpdateFrom", "minUpdateFrom %r is not a SemVer version" % (mu,))
elif ok_version and S.compare(mu, version) > 0:
    add("error", "minUpdateFrom", "minUpdateFrom %s is newer than version %s" % (mu, version))
if not isinstance(api, int) or api < 1:
    add("error", "apiVersion", "apiVersion %r is not a positive integer" % (api,))
if not isinstance(vj.get("settingsSchema"), int):
    add("error", "settingsSchema", "settingsSchema %r is not an integer" % (vj.get("settingsSchema"),))


def field(text, name):
    m = re.search(r"^\s*%s\s*=\s*['\"]?([^'\"\s)]+)" % re.escape(name), text or "", re.M)
    return m.group(1) if m else None


# 3 y 4
if ok_version:
    want = S.to_pkgver(version)
    for variant in ("sumi-shell", "sumi-shell-git"):
        pb = read("packaging/arch/%s/PKGBUILD" % variant)
        si = read("packaging/arch/%s/.SRCINFO" % variant)
        if pb is None:
            add("error", "pkgbuild", "packaging/arch/%s/PKGBUILD is missing" % variant)
            continue
        pv = field(pb, "pkgver")
        if variant == "sumi-shell":
            if pv != want:
                add("error", "pkgbuild", "%s pkgver is %s; version %s translates to %s" % (variant, pv, version, want))
            if "sumi-shell-%s.tar" % version not in pb:
                add("error", "pkgbuild", "%s: the source tarball isn't named after version %s" % (variant, version))
        elif not (pv or "").startswith(want + ".r"):
            add("info", "pkgbuild-git", "%s pkgver %s comes from an older build (pkgver() derives it: %s.r<n>.g<hash>)"
                % (variant, pv, want))
        if si is None:
            add("error", "srcinfo", "packaging/arch/%s/.SRCINFO is missing" % variant)
        else:
            for k in ("pkgver", "pkgrel"):
                if field(si, k) != field(pb, k):
                    add("error", "srcinfo", "%s/.SRCINFO %s %s ≠ PKGBUILD %s" % (variant, k, field(si, k), field(pb, k)))
            if WANT_SRCINFO:
                if not shutil.which("makepkg"):
                    add("info", "srcinfo", "makepkg is not installed: .SRCINFO was only compared field by field")
                else:
                    with tempfile.TemporaryDirectory(prefix="sumi-vc-") as t:
                        shutil.copy2(os.path.join(DIST, "packaging/arch", variant, "PKGBUILD"), t)
                        shutil.copy2(os.path.join(DIST, "packaging/arch/sumi-shell.install"), t)
                        r = subprocess.run(["makepkg", "--printsrcinfo"], cwd=t, capture_output=True, text=True)
                        if r.returncode != 0 or r.stdout != si:
                            add("error", "srcinfo", "%s/.SRCINFO ≠ makepkg --printsrcinfo" % variant)
# 5
readme, apimd = read("README.md") or "", read("API.md") or ""
m = re.search(r"Application version: \*\*([^*]+)\*\*\. Public API: \*\*(\d+)\*\*", readme)
if not m:
    add("error", "readme", "README.md doesn't state «Application version: **X**. Public API: **N**»")
elif (m.group(1), int(m.group(2))) != (version, api):
    add("error", "readme", "README.md says %s / API %s; version.json says %s / API %s" % (m.group(1), m.group(2), version,
                                                                                          api))
m = re.search(r"\*\*API version (\d+)\*\* · shell version \*\*([^*]+)\*\*", apimd)
if not m:
    add("error", "api-md", "API.md doesn't state «**API version N** · shell version **X**»")
elif (int(m.group(1)), m.group(2)) != (api, version):
    add("error", "api-md", "API.md says API %s / %s; version.json says API %s / %s" % (m.group(1), m.group(2), api, version))
m = re.search(r'\{"apiVersion":(\d+),"version":"([^"]+)"', apimd)
if m and (int(m.group(1)), m.group(2)) != (api, version):
    add("error", "api-md", "API.md's `api` example shows %s / API %s" % (m.group(2), m.group(1)))
# 6
cl = read("CHANGELOG.md")
if cl is None:
    add("error", "changelog", "CHANGELOG.md is missing")
else:
    if not re.search(r"^## \[Unreleased\]\s*$", cl, re.M):
        add("error", "changelog", "CHANGELOG.md has no «## [Unreleased]» section")
    if not re.search(r"^## \[%s\]" % re.escape(version or ""), cl, re.M):
        add("error", "changelog", "CHANGELOG.md has no «## [%s]» section" % version)
# 7 y 8 (sólo en un repositorio git; los tags que no empiezan por v, como el «1.0» del rice, no cuentan)
def git(*a):
    r = subprocess.run(["git", "-C", DIST] + list(a), capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


if git("rev-parse", "--is-inside-work-tree") == "true":
    here = [t for t in (git("tag", "--points-at", "HEAD") or "").split() if re.match(r"^v\d", t)]
    for t in here:
        if t != "v" + str(version):
            add("error", "tag", "HEAD is tagged %s but version.json says %s" % (t, version))
    prev = git("describe", "--tags", "--abbrev=0", "--match", "v[0-9]*", "HEAD^") if git("rev-parse", "HEAD^") else None
    if prev:
        root = git("rev-parse", "--show-prefix") or ""
        old = git("show", "%s:%ssumi/version.json" % (prev, root))
        try:
            old_api = json.loads(old).get("apiVersion") if old else None
        except ValueError:
            old_api = None
        if old_api is not None and old_api != api:
            add("info", "apiVersion", "apiVersion %s → %s since %s: say in the changelog whether the public contract broke "
                "(only a break needs MAJOR from 1.0.0)" % (old_api, api, prev))

errors = [f for f in findings if f["level"] == "error"]
if "--json" in sys.argv:
    print(json.dumps({"version": version, "apiVersion": api, "findings": findings}, indent=1))
else:
    print("Sumi Shell %s · API %s · pkgver %s" % (version, api, S.to_pkgver(version) if ok_version else "?"))
    for f in findings:
        print("  %-5s %-14s %s" % (f["level"].upper(), f["id"], f["message"]))
    print("version-check: %s" % ("OK" if not errors else "%d error(s)" % len(errors)))
sys.exit(1 if errors else 0)
