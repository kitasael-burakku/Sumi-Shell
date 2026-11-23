#!/usr/bin/env bash
# sumi-lock-wrapper
# ============================================================================
#  lock.sh — envoltorio del camino al bloqueo (portabilidad F5b, 2026-10-10)
# ----------------------------------------------------------------------------
#  La lógica vive ahora en el proyecto de la shell:
#  ~/.config/quickshell/sumi/scripts/sumi-lock (session | instant |
#  rescue). Este archivo se queda con su ruta porque la llaman hypridle
#  (lock_cmd, before_sleep_cmd) y sumi-lock-rescue.service: así ningún
#  llamador cambia y no hay que reiniciar hypridle.
#
#  Si el helper falta o no es ejecutable (shell desinstalada o movida), NO se
#  queda sin bloqueo: cae a hyprlock, la red de seguridad, con la misma regla
#  que el helper (rescue sólo sobre un bloqueo que nadie sostiene). Antes de F5b,
#  sin este archivo no había ningún bloqueo.
#
#  Sumi Shell (2026-11-07, antes Kitasan-Shell): mientras dure la transición se
#  busca el helper nuevo y, si falta, el del árbol viejo
#  (quickshell/kitasan/scripts/kitasan-lock); sin ninguno, hyprlock. El rescate
#  pide la unidad nueva y, si no existe, la vieja. Retirar las dos vías viejas
#  cuando el árbol y las unidades viejas ya no estén.
#
#  Argv puro: `$1` sólo se compara contra literales y se pasa tal cual.
# ============================================================================
set -u

cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
helper="$cfg/quickshell/sumi/scripts/sumi-lock"
legacy="$cfg/quickshell/kitasan/scripts/kitasan-lock"
if [ -x "$helper" ]; then
    exec "$helper" "$@"
fi
if [ -x "$legacy" ]; then
    exec "$legacy" "$@"
fi

locked() {
    [ "$(timeout 1 hyprctl locked 2>/dev/null)" = "true" ]
}

case "${1:-}" in
    rescue-request)
        [ "${SERVICE_RESULT:-}" = "exec-condition" ] && exit 0
        systemctl --user start --no-block sumi-lock-rescue.service 2>/dev/null && exit 0
        exec systemctl --user start --no-block kitasan-lock-rescue.service
        ;;
    rescue)
        locked || exit 0
        pgrep -x hyprlock >/dev/null 2>&1 && exit 0
        logger -t sumi-lock "helper missing ($helper); rescue with hyprlock"
        exec hyprlock
        ;;
    *)
        locked && exit 0
        logger -t sumi-lock "helper missing ($helper); locking with hyprlock"
        exec hyprlock
        ;;
esac
