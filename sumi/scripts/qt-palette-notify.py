#!/usr/bin/env python3
"""Notify an existing qt5ct/qt6ct profile after its selected palette is ready.

The platform plugins reload settings after their filesystem watcher settles
(about three seconds). Updating the selected palette alone does not notify
them. No settings are rewritten and absent/unrelated profiles are left alone.
"""
import argparse
import configparser
import json
import os
import time
from pathlib import Path


def notify(config, palette):
    config = Path(config).expanduser()
    palette = Path(palette).expanduser()
    if not config.is_file() or not palette.is_file():
        return {"status": "skipped", "reason": "missing-file"}
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    with config.open() as stream:
        parser.read_file(stream)
    if not parser.getboolean("Appearance", "custom_palette", fallback=False):
        return {"status": "skipped", "reason": "custom-palette-disabled"}
    selected = parser.get("Appearance", "color_scheme_path", fallback="").strip()
    # QSettings can quote paths. Expand variables without interpreting shell code.
    if len(selected) >= 2 and selected[0] == selected[-1] == '"':
        selected = selected[1:-1]
    if not selected:
        return {"status": "skipped", "reason": "no-selected-palette"}
    selected = Path(os.path.expandvars(os.path.expanduser(selected)))
    # Do not guess how another plugin/version resolves a relative scheme path.
    if not selected.is_absolute() or selected.resolve() != palette.resolve():
        return {"status": "skipped", "reason": "different-palette"}
    # No creation, truncation or configuration rewrite; preserve atime and contents.
    stat = config.stat()
    if stat.st_uid != os.getuid():
        return {"status": "skipped", "reason": "not-owned"}
    os.utime(config, ns=(stat.st_atime_ns, max(time.time_ns(), stat.st_mtime_ns + 1)))
    return {"status": "notified", "config": str(config), "palette": str(palette)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--palette", required=True)
    args = parser.parse_args()
    try:
        result = notify(args.config, args.palette)
    except (OSError, ValueError, configparser.Error) as error:
        print(json.dumps({"status": "failed", "reason": str(error)}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
