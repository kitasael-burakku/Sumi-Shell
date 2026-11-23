"""Sumi Shell — Semantic Versioning 2.0.0 (https://semver.org/spec/v2.0.0.html) for the installer, the updater, the
release check and the packaging (docs/sumi-shell/VERSIONING.md, 2026-11-07).

Comentarios en español, textos en inglés. Sin dependencias: la biblioteca estándar.

    parse(v)        → Version o None (gramática oficial de semver.org; nada de «v», espacios ni ceros a la izquierda)
    compare(a, b)   → -1 · 0 · 1 por la PRECEDENCIA de SemVer (§11); los metadatos +BUILD no cuentan
    policy(v)       → [errores]: además de SemVer válido, la política del proyecto (prerelease sólo alpha.N/beta.N/rc.N)
    to_pkgver(v)    → la versión para pacman (sin «-»; el sufijo PEGADO: 0.5.0-beta.1 → 0.5.0beta1, medido con vercmp:
                      con «.», «_» o «~» delante pacman la ordena DESPUÉS de 0.5.0)

Uso desde la línea de órdenes (pruebas y recetas): `python3 semver.py pkgver 0.5.0-beta.1`, `… compare A B`,
`… check V` (salida 0 si cumple la política).
"""
import re
import sys

# La expresión regular que publica semver.org (sección «Is there a suggested regular expression…»)
SEMVER_RE = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?"
    r"(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$")
# Política del proyecto: la única forma de prerelease admitida (alpha < beta < rc por orden ASCII, como en SemVer)
PRERELEASE_RE = re.compile(r"^(alpha|beta|rc)\.([1-9]\d*)$")


class Version:
    __slots__ = ("major", "minor", "patch", "pre", "build", "text")

    def __init__(self, major, minor, patch, pre, build, text):
        self.major, self.minor, self.patch, self.pre, self.build, self.text = major, minor, patch, pre, build, text

    @property
    def core(self):
        return (self.major, self.minor, self.patch)

    def __str__(self):
        return self.text

    def __repr__(self):
        return "Version(%r)" % self.text


def parse(text):
    if not isinstance(text, str):
        return None
    m = SEMVER_RE.fullmatch(text)          # fullmatch: «$» de Python acepta un \n final
    if not m:
        return None
    pre = tuple(m.group(4).split(".")) if m.group(4) else ()
    build = tuple(m.group(5).split(".")) if m.group(5) else ()
    return Version(int(m.group(1)), int(m.group(2)), int(m.group(3)), pre, build, text)


def _cmp(x, y):
    return (x > y) - (x < y)


def _cmp_ident(a, b):
    """§11.4.1–3: numéricos por valor; alfanuméricos en ASCII; un numérico va SIEMPRE antes que uno alfanumérico."""
    an, bn = a.isdigit(), b.isdigit()
    if an and bn:
        return _cmp(int(a), int(b))
    if an != bn:
        return -1 if an else 1
    return _cmp(a, b)


def compare(a, b):
    """Precedencia de SemVer entre dos versiones (texto o Version). ValueError si alguna no es SemVer válido."""
    va = a if isinstance(a, Version) else parse(a)
    vb = b if isinstance(b, Version) else parse(b)
    if va is None or vb is None:
        raise ValueError("not a SemVer version: %r" % (a if va is None else b,))
    c = _cmp(va.core, vb.core)
    if c:
        return c
    # §11.3: sin prerelease tiene MAYOR precedencia que con prerelease
    if not va.pre or not vb.pre:
        return _cmp(not va.pre, not vb.pre) if (va.pre or vb.pre) else 0
    for x, y in zip(va.pre, vb.pre):
        c = _cmp_ident(x, y)
        if c:
            return c
    return _cmp(len(va.pre), len(vb.pre))          # §11.4.4: más identificadores = mayor, si el resto es igual


def policy(text):
    """Errores de la política del proyecto (lista vacía = válida). Los metadatos +BUILD no van en version.json."""
    v = parse(text)
    if v is None:
        return ["%r is not a SemVer 2.0.0 version (MAJOR.MINOR.PATCH[-PRERELEASE][+BUILD])" % (text,)]
    errs = []
    if v.pre and not PRERELEASE_RE.fullmatch(".".join(v.pre)):
        errs.append("%s: the prerelease must be alpha.N, beta.N or rc.N (N ≥ 1)" % text)
    if v.build:
        errs.append("%s: build metadata (+…) is informational and is not written in version.json" % text)
    return errs


def to_pkgver(text):
    """La versión de pacman para una versión que cumple la política. ValueError si no la cumple."""
    errs = policy(text)
    if errs:
        raise ValueError(errs[0])
    v = parse(text)
    core = "%d.%d.%d" % v.core
    if not v.pre:
        return core
    label, n = PRERELEASE_RE.fullmatch(".".join(v.pre)).groups()
    return core + label + n


def main(argv):
    if len(argv) == 3 and argv[1] == "pkgver":
        try:
            print(to_pkgver(argv[2]))
            return 0
        except ValueError as e:
            print(e, file=sys.stderr)
            return 1
    if len(argv) == 4 and argv[1] == "compare":
        try:
            print(compare(argv[2], argv[3]))
            return 0
        except ValueError as e:
            print(e, file=sys.stderr)
            return 2
    if len(argv) == 3 and argv[1] == "check":
        errs = policy(argv[2])
        for e in errs:
            print(e, file=sys.stderr)
        return 1 if errs else 0
    print("usage: semver.py pkgver V | compare A B | check V", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
