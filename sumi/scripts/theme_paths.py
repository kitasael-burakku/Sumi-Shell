#!/usr/bin/env python3
"""Rutas de matugen compartidas por generación y preview (portabilidad F1a).

Matugen expande ~, pero no $VARIABLE. Su config conserva una ruta por defecto
válida; sólo esa salida convencional de Minimaru se adapta a XDG_STATE_HOME.
Una salida explícita distinta se respeta. No escribe la configuración original.
Uso: python3 -B theme_paths.py CONFIG > CONFIG_TEMPORAL
"""
import json
import os
import sys
import tomllib
from xdg_paths import base_dir


def expand_path(path):
    return os.path.expanduser(path)


def load_matugen_config(path):
    with open(path, "rb") as f:
        cfg = tomllib.load(f)
    base = os.path.dirname(os.path.abspath(path))
    default = os.path.expanduser("~/.local/state/sumi-shell/colors.json")
    state = base_dir("XDG_STATE_HOME", ".local/state")
    for key, template in cfg.get("templates", {}).items():
        for field in ("input_path", "output_path"):
            if field not in template:
                continue
            value = expand_path(template[field])
            if key == "sumi_shell" and field == "output_path" and value == default:
                value = os.path.join(state, "sumi-shell", "colors.json")
            # Al cambiar la ubicación de config.toml, sus rutas relativas siguen
            # referidas a la carpeta original, como las interpreta matugen.
            template[field] = os.path.normpath(os.path.join(base, value))
    return cfg


def toml_value(value):
    """Tablas inline: conserva tablas anidadas, listas, opciones y hooks."""
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, list):
        return "[" + ", ".join(toml_value(v) for v in value) + "]"
    if isinstance(value, dict):
        return "{ " + ", ".join(json.dumps(k) + " = " + toml_value(v)
                                for k, v in value.items()) + " }"
    raise ValueError("Unsupported matugen config value: %r" % (value,))


if __name__ == "__main__":
    try:
        cfg = load_matugen_config(sys.argv[1])
        for key, value in cfg.items():
            print(json.dumps(key) + " = " + toml_value(value))
    except (OSError, ValueError, IndexError) as e:
        print("matugen config: " + str(e), file=sys.stderr)
        sys.exit(1)
