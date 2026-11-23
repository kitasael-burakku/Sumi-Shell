"""Resuelve bases XDG de uso normal. Las herramientas que editan configuración aplican sus propias guardas."""
import os


def base_dir(variable, suffix, env=None):
    env = os.environ if env is None else env
    value = env.get(variable, "")
    if os.path.isabs(value):
        return value
    return os.path.join(env.get("HOME") or os.path.expanduser("~"), suffix)
