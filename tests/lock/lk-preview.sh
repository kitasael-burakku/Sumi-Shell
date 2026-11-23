#!/usr/bin/env bash
# 15A: LK-01, LK-02, LK-07, LK-09 en la preview (sin PAM ni bloqueo). Guarda RP-1 antes de cada wtype.
set -u
SP=${OUT:-$(mktemp -d)}; W=$(cd "$(dirname "$0")/../../sumi" && pwd); P=$W/lock-preview.qml
T=$HOME/Projects/Quickshell/tools/lock
pv(){ timeout 3 qs -p "$P" ipc call sumi-lock-preview "$@"; }
st(){ pv state | jq -c "$1"; }
guard(){ # $1 = pantalla que debe tener el foco de la preview
  [ "$(timeout 3 qs -c sumi ipc call sumi lockStatus | jq -r .phase)" = unlocked ] || { echo "ABORT: shell no unlocked"; return 1; }
  [ "$(hyprctl locked)" = false ] || { echo "ABORT: sesión bloqueada"; return 1; }
  [ "$(st .focusScreen)" = "\"$1\"" ] && [ "$(st .heroActive)" = true ] || { echo "ABORT: la preview no tiene el foco en $1"; return 1; }
}
cleanup(){ pv quit >/dev/null 2>&1; sleep 0.5; kill "$PID" 2>/dev/null; sh $T/headless.sh del; }
guard0(){ [ "$(timeout 3 qs -c sumi ipc call sumi lockStatus | jq -r .phase)" = unlocked ] && [ "$(hyprctl locked)" = false ]; }
guard0 || { echo "ABORT: bloqueada"; exit 1; }
[ "$(df --output=avail /tmp | tail -1)" -gt 500000 ] || { echo "ABORT: /tmp lleno"; exit 1; }
H=$(sh $T/headless.sh add 1920); echo "headless: $H"
PID=$(LOCK_PREVIEW_INTERACTIVE=1 sh $T/preview.sh "$W" "$SP/preview.log" "HDMI-A-1,$H"); trap cleanup EXIT
for i in $(seq 50); do [ "$(st .heroActive 2>/dev/null)" = true ] && break; sleep 0.1; done
echo "inicio: $(st '{focusScreen,heroActive,bufferLength,shown}')"
guard HDMI-A-1 && wtype abc; sleep 0.3; echo "tras 'abc': $(st .bufferLength)"
# LK-01: Tab no sale del campo -> la tecla siguiente sigue entrando en él
guard HDMI-A-1 && wtype -k Tab; sleep 0.2; guard HDMI-A-1 && wtype d; sleep 0.3; echo "LK-01 tras Tab + 'd': bufferLength $(st .bufferLength) (4 = el foco no salió del campo)"
# LK-02: la composición pasa a la otra pantalla con 4 caracteres a medias
pv set focusScreen "\"$H\"" >/dev/null; sleep 0.8
echo "tras mover el foco: $(st '{focusScreen,heroActive,bufferLength}')"
guard "$H" && wtype e; sleep 0.3; echo "LK-02 tras 'e' en la otra pantalla: bufferLength $(st .bufferLength) (5 = conservado; 1 = sustituido)"
# LK-07 + LK-09: fallo de energía y comprobación a la vez; captura del HDMI
pv set focusScreen '"HDMI-A-1"' >/dev/null; pv set powerError '"Couldn'"'"'t shut down"' >/dev/null
pv set auth '{"state":"checking"}' >/dev/null; sleep 0.8
guard0 && grim -o HDMI-A-1 -t jpeg -q 80 "$SP/lk07-checking-vs-power.jpg" && echo "captura lk07"
pv set powerError '""' >/dev/null; pv set auth '{"state":"failed","failed":1}' >/dev/null; pv set powerError '"Couldn'"'"'t shut down"' >/dev/null; sleep 0.6
guard0 && grim -o HDMI-A-1 -t jpeg -q 80 "$SP/lk07-failed-vs-power.jpg" && echo "captura lk07b"
