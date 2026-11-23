#!/usr/bin/env python3
"""Sumi Shell — packaging/semver.py: SemVer 2.0.0 precedence, the project's policy and the pacman translation (2026-11-07).

Uso: python3 -B tests/install/semver-test.py        (desde la raíz del repo)

Sin escribir nada. La parte de pacman usa `vercmp` REAL (sólo compara cadenas): para cada par de una serie de versiones
(finales y prereleases, subidas y bajadas) el signo del comparador de SemVer tiene que ser el de vercmp sobre la
traducción; también pkgrel y las versiones -git. Sin vercmp, esa parte sale como SKIPPED (nunca como aprobada).
"""
import importlib.util
import itertools
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
spec = importlib.util.spec_from_file_location("sumi_semver", os.path.join(ROOT, "packaging", "semver.py"))
S = importlib.util.module_from_spec(spec)
spec.loader.exec_module(S)
results = []


def check(name, cond, detail=""):
    results.append((name, "PASS" if cond else "FAIL", detail))


def sign(x):
    return (x > 0) - (x < 0)


# ---- gramática ------------------------------------------------------------------------------------------------------
for v in ("0.4.0", "0.5.0-alpha.1", "1.0.0-0.3.7", "1.0.0-x.7.z.92", "1.0.0-x-y-z.--", "1.0.0+20130313144700",
          "1.0.0-beta+exp.sha.5114f85", "1.0.0+21AF26D3----117B344092BD", "10.20.30"):
    check("valid: " + v, S.parse(v) is not None)
for v in ("1.0", "v1.0.0", "01.0.0", "1.01.0", "1.0.0-", "1.0.0-01", "1.0.0+", "1.0.0-alpha..1", " 1.0.0", "1.0.0 ",
          "1.0.0-beta.1\n", "", None, "1.0.0.0", "-1.0.0"):
    check("invalid: %r" % (v,), S.parse(v) is None)

# ---- precedencia: la cadena del propio semver.org (§11) y más ---------------------------------------------------------
chain = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11",
         "1.0.0-rc.1", "1.0.0", "2.0.0", "2.1.0", "2.1.1"]
ok = all(S.compare(a, b) == -1 and S.compare(b, a) == 1 for a, b in zip(chain, chain[1:]))
check("semver.org §11 precedence chain", ok)
check("transitive over the whole chain", all(S.compare(a, b) == -1 for a, b in itertools.combinations(chain, 2)))
check("build metadata ignored", S.compare("1.0.0+a", "1.0.0+b") == 0 and S.compare("1.0.0-rc.1+x", "1.0.0-rc.1") == 0)
check("numeric identifiers by value (beta.2 < beta.10)", S.compare("0.5.0-beta.2", "0.5.0-beta.10") == -1)
check("numeric < alphanumeric identifier", S.compare("1.0.0-1", "1.0.0-a") == -1)
check("prerelease < its release", S.compare("0.5.0-rc.9", "0.5.0") == -1)
check("release < next prerelease core", S.compare("0.5.0", "0.5.1-alpha.1") == -1)
check("equal", S.compare("0.4.0", "0.4.0") == 0)
try:
    S.compare("0.4", "0.4.0")
    check("compare rejects invalid", False)
except ValueError:
    check("compare rejects invalid", True)

# ---- política del proyecto -------------------------------------------------------------------------------------------
for v in ("0.4.0", "0.5.0", "0.5.0-alpha.1", "0.5.0-beta.2", "0.5.0-beta.10", "0.5.0-rc.1", "1.0.0"):
    check("policy accepts " + v, S.policy(v) == [], S.policy(v))
for v in ("0.5.0-beta", "0.5.0-beta.0", "0.5.0-dev.1", "0.5.0-beta.1.1", "0.5.0-pre.1", "0.5.0-Beta.1",
          "0.5.0+build.7", "0.5.0-alpha.01", "v0.5.0"):
    check("policy rejects " + v, S.policy(v) != [])

# ---- traducción a pacman ---------------------------------------------------------------------------------------------
for v, want in (("0.4.0", "0.4.0"), ("0.5.0-alpha.1", "0.5.0alpha1"), ("0.5.0-beta.2", "0.5.0beta2"),
                ("0.5.0-beta.10", "0.5.0beta10"), ("0.5.0-rc.1", "0.5.0rc1"), ("1.0.0", "1.0.0")):
    check("pkgver %s → %s" % (v, want), S.to_pkgver(v) == want, S.to_pkgver(v))
for bad in ("0.5.0-dev.1", "0.5.0+b.1", "0.5"):
    try:
        S.to_pkgver(bad)
        check("pkgver refuses " + bad, False)
    except ValueError:
        check("pkgver refuses " + bad, True)
check("pkgver never contains '-' or ':'", all("-" not in S.to_pkgver(v) and ":" not in S.to_pkgver(v)
                                             for v in ("0.5.0-alpha.1", "0.5.0-rc.3", "2.0.0")))

# ---- contraste con vercmp (pacman) -----------------------------------------------------------------------------------
series = ["0.4.0", "0.4.1", "0.5.0-alpha.1", "0.5.0-alpha.2", "0.5.0-beta.1", "0.5.0-beta.2", "0.5.0-beta.10",
          "0.5.0-rc.1", "0.5.0-rc.2", "0.5.0", "0.5.1", "0.6.0-beta.1", "0.6.0", "0.10.0", "1.0.0-alpha.1",
          "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0-beta.1", "1.1.0", "2.0.0-rc.1", "2.0.0", "10.0.0"]
vercmp = shutil.which("vercmp")
if not vercmp:
    results.append(("vercmp cross-check", "SKIPPED", "vercmp (pacman) is not installed"))
else:
    def vc(a, b):
        return sign(int(subprocess.run([vercmp, a, b], capture_output=True, text=True, check=True).stdout.strip()))
    bad = []
    pairs = 0
    for a, b in itertools.permutations(series, 2):          # subidas Y bajadas: (a,b) y (b,a)
        pairs += 1
        if sign(S.compare(a, b)) != vc(S.to_pkgver(a), S.to_pkgver(b)):
            bad.append("%s vs %s" % (a, b))
    check("vercmp agrees with SemVer on %d ordered pairs (upgrades and downgrades)" % pairs, not bad, bad[:5])
    # pkgrel: misma versión, otra revisión del paquete; nunca salta por encima de otra versión
    check("pkgrel orders only within one version",
          vc("0.5.0beta1-2", "0.5.0beta1-1") == 1 and vc("0.5.0beta1-9", "0.5.0beta2-1") == -1
          and vc("0.5.0-1", "0.5.0rc2-9") == 1)
    # -git: VERSIÓN.r<commits>.g<hash> queda entre la versión de la que sale y la siguiente
    check("-git builds sit between their base and the next release",
          vc("0.5.0alpha1.r12.gabc1234", "0.5.0alpha1") == 1 and vc("0.5.0alpha1.r12.gabc1234", "0.5.0alpha2") == -1
          and vc("0.5.0alpha1.r12.gabc1234", "0.5.0") == -1 and vc("0.4.0.r88.g1feaa2d", "0.5.0alpha1.r1.gdeadbee") == -1
          and vc("0.5.0.r3.gabc", "0.5.1alpha1") == -1)
    # las formas descartadas siguen descartadas (si pacman cambiara, la prueba lo diría)
    check("separators before the label sort AFTER the release (kept rejected)",
          all(vc(x, "0.5.0") == 1 for x in ("0.5.0.beta1", "0.5.0_beta1", "0.5.0~beta1")))
    check("epoch overrides everything (not used)", vc("1:0.4.0", "0.5.0") == 1)

# ---- línea de órdenes ------------------------------------------------------------------------------------------------
cli = os.path.join(ROOT, "packaging", "semver.py")
r = subprocess.run([sys.executable, "-B", cli, "pkgver", "0.5.0-alpha.1"], capture_output=True, text=True)
check("cli pkgver", r.returncode == 0 and r.stdout.strip() == "0.5.0alpha1", r.stdout + r.stderr)
r = subprocess.run([sys.executable, "-B", cli, "check", "0.5.0-dev.1"], capture_output=True, text=True)
check("cli check refuses outside the policy", r.returncode == 1)
r = subprocess.run([sys.executable, "-B", cli, "compare", "0.5.0-beta.2", "0.5.0-beta.10"], capture_output=True, text=True)
check("cli compare", r.stdout.strip() == "-1")

failed = 0
for name, state, detail in results:
    print("%-78s %s" % (name, state))
    if state == "FAIL":
        failed += 1
        print("    · %s" % (detail,))
skipped = sum(1 for _, s, _ in results if s == "SKIPPED")
print("failed: %d of %d%s" % (failed, len(results), " · skipped: %d" % skipped if skipped else ""))
sys.exit(1 if failed else 0)
