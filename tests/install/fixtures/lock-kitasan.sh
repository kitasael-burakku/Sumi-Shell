#!/usr/bin/env bash
# kitasan-lock-wrapper
# ============================================================================
#  lock.sh — envoltorio del camino al bloqueo (portabilidad F5b, 2026-10-10)
# ----------------------------------------------------------------------------
#  La lógica vive ahora en el proyecto de la shell:
#  ~/.config/quickshell/kitasan/scripts/kitasan-lock (session | instant |
#  rescue). Este archivo se queda con su ruta porque la llaman hypridle
#  (lock_cmd, before_sleep_cmd) y kitasan-lock-rescue.service: así ningún
#  llamador cambia y no hay que reiniciar hypridle.
#
#  Si el helper falta o no es ejecutable (shell desinstalada o movida), NO se
#  queda sin bloqueo: cae a hyprlock, la red de seguridad, con la misma regla
#  que el helper (rescue sólo sobre un bloqueo que nadie sostiene). Antes de F5b,
#  sin este archivo no había ningún bloqueo.
#
#  Argv puro: `$1` sólo se compara contra literales y se pasa tal cual.
# ============================================================================
set -u

helper="${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/kitasan/scripts/kitasan-lock"
if [ -x "$helper" ]; then
    exec "$helper" "$@"
fi

locked() {
    [ "$(timeout 1 hyprctl locked 2>/dev/null)" = "true" ]
}

case "${1:-}" in
    rescue-request)
        [ "${SERVICE_RESULT:-}" = "exec-condition" ] && exit 0
        exec systemctl --user start --no-block kitasan-lock-rescue.service
        ;;
    rescue)
        locked || exit 0
        pgrep -x hyprlock >/dev/null 2>&1 && exit 0
        logger -t kitasan-lock "helper missing ($helper); rescue with hyprlock"
        exec hyprlock
        ;;
    *)
        locked && exit 0
        logger -t kitasan-lock "helper missing ($helper); locking with hyprlock"
        exec hyprlock
        ;;
esac
