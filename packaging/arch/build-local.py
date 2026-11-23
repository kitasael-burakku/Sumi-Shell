#!/usr/bin/env python3
"""Prepare both local F6g recipes from an extracted repository, then build without installing.

Usage: build-local.py <distribution-with-packaging/arch> <extracted-git-repo> <new-output>
No commits, tags, downloads, dependency installation or pacman transaction.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

# Página del proyecto; las fuentes de la receta local siguen siendo el repo extraído (compilación local).
UPSTREAM = "https://github.com/kitasael-burakku/Sumi-Shell"


def run(argv, **kw):
    return subprocess.run(argv, check=True, **kw)


def main():
    dist, repo, out = map(lambda x: Path(x).resolve(), sys.argv[1:])
    out.mkdir()
    rev = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    version = json.loads(subprocess.check_output([
        "git", "-C", str(repo), "show", "HEAD:sumi/version.json"]))["version"]
    # SemVer 2.0.0 → pacman (docs/sumi-shell/VERSIONING.md §4): sin «-», el sufijo pegado (0.5.0-beta.1 → 0.5.0beta1)
    spec = importlib.util.spec_from_file_location("sumi_semver", dist / "packaging" / "semver.py")
    semver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(semver)
    pkgver_value = semver.to_pkgver(version)          # ValueError si la versión no cumple la política
    archive = out / ("sumi-shell-" + version + ".tar")
    with archive.open("wb") as f:
        run(["git", "-C", str(repo), "archive", "--prefix=sumi-shell/", "HEAD"], stdout=f)
    deps = """depends=('quickshell>=0.3.1' 'qt6-declarative' 'qt6-wayland' 'hyprland' 'python>=3.11' 'systemd' 'bash'
         'coreutils' 'findutils' 'procps-ng' 'util-linux' 'sed' 'grep' 'dbus' 'fontconfig'
         'pipewire' 'wireplumber' 'ttf-iosevkaterm-nerd')
optdepends=('qt6-multimedia: wallpaper video previews'
            'lua: luac for Lua integration (must match the compositor Lua version)'
            'binutils: readelf for automatic Lua integration'
            'hypridle: idle locking and suspend coordination'
            'hyprlock: fallback when the shell cannot hold the lock'
            'networkmanager: network controls' 'libnm: NetworkManager helper'
            'python-gobject: NetworkManager helper'
            'bluez: Bluetooth' 'upower: battery status' 'power-profiles-daemon: power profiles'
            'matugen: dynamic palettes' 'hyprpaper: image wallpapers'
            'awww: animated image wallpapers' 'mpvpaper: video wallpapers'
            'imagemagick: thumbnails' 'ffmpeg: video thumbnails'
            'cliphist: clipboard history' 'wl-clipboard: clipboard copy and paste'
            'calcurse: calendar' 'ddcutil: external monitor brightness'
            'curl: downloads and online services' 'grim: screenshots'
            'pciutils: graphics hardware information' 'xdg-utils: opening files and URLs'
            'pacman-contrib: package update checks' 'fakeroot: required by checkupdates' 'jq: helper JSON queries'
            'python-dbus: inhibitors and power through login1 without systemd'
            'wf-recorder: screen recording' 'slurp: region selection for recording'
            'libpulse: pactl for recording audio and profile tests' 'playerctl: audio profile tests'
            'libnotify: optional desktop notifications from helpers'
            'libsecret: secret-tool for CalDAV credentials (requires Secret Service)'
            'cava: live audio spectrum'
            'gsettings-desktop-schemas: optional GTK theme synchronisation'
            'xsettingsd: optional X11 theme transport'
            'python-fonttools: advanced font metrics' 'python-cbor2: Qt 5 platform plugin diagnostics'
            'sumi-sddm: optional login screen management (separate project)')"""
    for variant in ("sumi-shell", "sumi-shell-git"):
        d = out / variant
        d.mkdir()
        for name in ("package.py", "ARCH.md", "sumi-shell.install"):
            shutil.copy2(dist / "packaging/arch" / name, d / name)
        hashes = [hashlib.sha256((d / name).read_bytes()).hexdigest() for name in ("package.py", "ARCH.md")]
        if variant.endswith("-git"):
            src = "sumi-shell::git+" + repo.as_uri()
            first_hash = "SKIP"
            extra = "makedepends=('git')\nprovides=('sumi-shell')\nconflicts=('sumi-shell')\n"
            version_check = 'python -B sumi-shell/packaging/semver.py check "$version"'
            pkgver = """
pkgver() {
    cd "$srcdir/sumi-shell"
    local version
    version=$(python -c 'import json; print(json.load(open("sumi/version.json"))["version"])')
    printf '%s.r%s.g%s' "$(python -B packaging/semver.py pkgver "$version")" "$(git rev-list --count HEAD)" \\
        "$(git rev-parse --short HEAD)"
}
"""
        else:
            shutil.copy2(archive, d / archive.name)
            src = archive.name
            first_hash = hashlib.sha256(archive.read_bytes()).hexdigest()
            extra = "conflicts=('sumi-shell-git')\n"
            version_check = '[[ "$pkgver" == "$(python -B sumi-shell/packaging/semver.py pkgver "$version")" ]]'
            pkgver = ""
        recipe = f"""# Maintainer: Kitasa-elburakku
# Local F6g candidate. Generated by packaging/arch/build-local.py; no release tag yet.
# Upstream snapshot: {rev}; application version comes from version.json.
pkgname={variant}
pkgver={pkgver_value}
pkgrel=1
pkgdesc='Hyprland desktop shell built with Quickshell'
url='{UPSTREAM}'
arch=('any')
license=('MIT')
{deps}
{extra}options=('!strip' '!debug')
install=sumi-shell.install
source=('{src}' 'package.py' 'ARCH.md')
sha256sums=('{first_hash}' '{hashes[0]}' '{hashes[1]}')
{pkgver}
prepare() {{
    local version
    version=$(python -c 'import json; print(json.load(open("sumi-shell/sumi/version.json"))["version"])')
    {version_check}
}}

package() {{
    python -B "$srcdir/package.py" "$srcdir/sumi-shell" "$pkgdir" --pkgname "$pkgname"
}}
"""
        (d / "PKGBUILD").write_text(recipe)
        env = dict(os.environ, PKGDEST=str(d), SRCDEST=str(d), BUILDDIR=str(d))
        # -d avoids installing anything and permits optional local provider names.
        # This is a local payload build, not dependency validation in a clean Arch.
        with (d / "build.log").open("w") as log:
            run(["makepkg", "--nodeps", "--noconfirm"], cwd=d, env=env, stdout=log, stderr=subprocess.STDOUT)
        with (d / ".SRCINFO").open("w") as f:
            run(["makepkg", "--printsrcinfo"], cwd=d, stdout=f)
        print(variant, "built", flush=True)
    (out / "source.json").write_text(json.dumps({"repository": str(repo), "commit": rev, "version": version}, indent=2) + "\n")


if __name__ == "__main__":
    main()
