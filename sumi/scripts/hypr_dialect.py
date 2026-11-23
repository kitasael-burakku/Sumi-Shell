"""El dialecto de la config de Hyprland para los helpers de Python (portabilidad F5a, 2026-10-10; H-03).

La misma regla que `lib/hypr-dialect.js` (la que usa la shell), para lo que escriben o ejecutan los helpers:
el comando de apagar/encender la pantalla del archivo gestionado de hypridle (`idle-config.py`) y las
salidas que prueba el watchdog (`sumi-guard.py`). `tools/f5/dialect-vectors.json` comprueba que las dos
implementaciones dan lo mismo.

Detección: la sonda inofensiva `hyprctl eval 'local _ = 0'`, leyendo la RESPUESTA (el código es 0 en los dos
casos): «ok» → lua; «eval is only supported with the lua config manager» → hyprlang; otra cosa → unknown, que
se trata como lua (lo de antes de F5). El dialecto lo fija Hyprland al arrancar: añadir el otro archivo y
recargar no lo cambia (medido en F5a).

Hyprland 0.57 (2026-10-30) ya no lee hyprland.conf: la sonda da «lua» (medido). La rama hyprlang queda CONGELADA
para Hyprland ≤ 0.56: se conserva tal cual y no se le añade nada nuevo. Su retirada: portabilidad/ROADMAP.md.

Entorno para pruebas: SUMI_HYPR_DIALECT (lua|hyprlang|unknown) fuerza el resultado sin preguntar;
SUMI_HYPRCTL cambia el ejecutable.
"""
import os
import re
import subprocess

HYPRCTL = os.environ.get("SUMI_HYPRCTL", "hyprctl")


def classify(reply):
    t = (reply or "").strip()
    if t == "ok":
        return "lua"
    if "only supported with the lua config manager" in t:
        return "hyprlang"
    return "unknown"


def detect(timeout=3):
    """'lua' | 'hyprlang' | 'unknown' del Hyprland de esta sesión (HYPRLAND_INSTANCE_SIGNATURE)."""
    forced = os.environ.get("SUMI_HYPR_DIALECT")
    if forced in ("lua", "hyprlang", "unknown"):
        return forced
    if not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        return "unknown"
    try:
        p = subprocess.run([HYPRCTL, "eval", "local _ = 0"], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"
    return classify(p.stdout or p.stderr)


def norm(dialect):
    return "hyprlang" if dialect == "hyprlang" else "lua"


def dpms_command(dialect, on):
    """La orden de shell que hypridle ejecuta para encender (on) o apagar la pantalla."""
    if norm(dialect) == "hyprlang":
        return "hyprctl dispatch dpms " + ("on" if on else "off")
    return "hyprctl dispatch 'hl.dsp.dpms({ action = \"%s\" })'" % ("enable" if on else "disable")


def is_dpms_command(cmd, dialect):
    """¿Es `cmd` una de las dos órdenes de dpms del dialecto? (para avisar de un archivo de otro dialecto)."""
    return cmd.strip() in (dpms_command(dialect, True), dpms_command(dialect, False))


NAME = re.compile(r"^[A-Za-z0-9_.\-]+$")


def monitor_argv(dialect, name, cfg):
    """argv de hyprctl para aplicar una salida YA VALIDADA, o None si el dialecto no lo permite.

    Con hyprlang, Hyprland 0.56.2 sólo aplica la PRIMERA regla `keyword monitor` en caliente de cada salida:
    las siguientes (también volver a `preferred`) responden «ok» y no cambian nada (medido en F5a sobre una
    salida headless del anidado). Una prueba con vuelta atrás no puede fiarse de eso: None.
    """
    if norm(dialect) == "hyprlang" or not NAME.match(name or ""):
        return None
    if cfg == "preferred":
        return ["eval", 'hl.monitor({ output = "%s", mode = "preferred", position = "auto", scale = 1 })' % name]
    parts = ['output = "%s"' % name, 'mode = "%s"' % cfg["mode"], 'position = "%s"' % cfg["position"],
             "scale = %s" % repr(float(cfg["scale"])), "transform = %d" % int(cfg.get("transform", 0))]
    if "vrr" in cfg:
        parts.append("vrr = %d" % int(cfg["vrr"]))
    if "bitdepth" in cfg:
        parts.append("bitdepth = %d" % int(cfg["bitdepth"]))
    return ["eval", "hl.monitor({ %s })" % ", ".join(parts)]
