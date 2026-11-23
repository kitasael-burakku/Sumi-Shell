#!/usr/bin/env python3
"""Build the pacman payload in an empty staging directory; never install it."""
import argparse
import importlib.util
from pathlib import Path
import sys

sys.dont_write_bytecode = True


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("source", type=Path)
    p.add_argument("destination", type=Path)
    p.add_argument("--pkgname", choices=("sumi-shell", "sumi-shell-git"), default="sumi-shell")
    args = p.parse_args()
    source = args.source.resolve()
    dest = args.destination.resolve()
    if dest == Path("/") or (dest.exists() and any(dest.iterdir())):
        p.error("destination must be an empty staging directory")
    if dest == source or source in dest.parents or dest in source.parents:
        p.error("source and destination must be separate")
    spec = importlib.util.spec_from_file_location("installer", source / "packaging/installer.py")
    inst = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(inst)

    def put(rel, data, mode=0o644):
        path = dest / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(mode)

    # Same runtime, permissions and build identity as the user installer.
    runtime = "etc/xdg/quickshell/sumi"
    for rel, _, mode, data in inst.with_build(inst.source_files()):
        put(f"{runtime}/{rel}", data, mode)
    for unit in inst.UNITS:
        body = (source / "sumi/systemd" / unit).read_text()
        body = body.replace("%h/.config/quickshell/sumi", "/" + runtime)
        body = body.replace("Documentation=file:///" + runtime + "/README.md",
                            "Documentation=file:///usr/share/doc/sumi-shell/ARCH.md")
        put("usr/lib/systemd/user/" + unit, body.encode())
    for name, src in (("LICENSE", source / "LICENSE"),
                      ("LICENSE-ukishima", source / "sumi/lib/LICENSE-ukishima")):
        put("usr/share/licenses/" + args.pkgname + "/" + name, src.read_bytes())
    put("usr/share/doc/sumi-shell/API.md", (source / "API.md").read_bytes())
    # This file belongs to the recipe, so -git can package an older source commit.
    put("usr/share/doc/sumi-shell/ARCH.md", Path(__file__).with_name("ARCH.md").read_bytes())
    for path in sorted((source / "sumi/examples").rglob("*")):
        if path.is_file():
            body = path.read_text().replace("~/.config/quickshell/sumi", "/" + runtime)
            put("usr/share/doc/sumi-shell/examples/" + str(path.relative_to(source / "sumi/examples")),
                body.encode())


if __name__ == "__main__":
    main()
