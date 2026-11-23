#!/usr/bin/env bash
# 15F: secuencias de la coreografía del panel (preview SIN teclado, en una headless, fase inicial «unlocked»).
#   choreo-seq.sh <salida> <normal|reduced|off> <island|bar> <orden:ms>...   (orden: enter, success, instant)
# «bar» finge el origen del reloj de la barra (x centrado, 40 px de alto) sin cambiar la presentación del
# usuario. JPEG q80 con guarda de /tmp y de bloqueo; al final `animating` (cero animaciones en reposo).
set -u
OUT=$1; MODE=$2; ORIGIN=$3; shift 3
W=$(cd "$(dirname "$0")/../../sumi" && pwd); P=$W/lock-preview.qml; T=$HOME/Projects/Quickshell/tools/lock
mkdir -p "$OUT"
pv(){ timeout 3 qs -p "$P" ipc call sumi-lock-preview "$@"; }
unlocked(){ [ "$(timeout 3 qs -c sumi ipc call sumi lockStatus | jq -r .phase)" = unlocked ] && [ "$(hyprctl locked)" = false ]; }
PID=""; cleanup(){ [ -n "$PID" ] && { pv quit >/dev/null 2>&1; sleep 0.4; kill "$PID" 2>/dev/null; }; sh "$T/headless.sh" del; }
trap cleanup EXIT
unlocked || { echo ABORT; exit 1; }
H=$(sh "$T/headless.sh" add 1920)
PID=$(LOCK_PREVIEW_PHASE=unlocked sh "$T/preview.sh" "$W" "$OUT/preview.log" "$H")
for i in $(seq 60); do pv state >/dev/null 2>&1 && break; sleep 0.1; done; sleep 1.2
pv set motion "\"$MODE\"" >/dev/null
[ "$ORIGIN" = bar ] && pv set origin '{"x":906,"y":8,"w":108,"h":40,"r":20,"presentation":"bar"}' >/dev/null
pv scenario board >/dev/null; sleep 0.3
echo "origen: $(pv state | jq -c ".origins[\"$H\"]") · movimiento: $(pv state | jq -r .motion)"
for step in "$@"; do
  cmd=${step%%:*}; dur=${step#*:}
  t0=$(date +%s%3N); pv "$cmd" >/dev/null &
  n=0
  while [ $(( $(date +%s%3N) - t0 )) -lt "$dur" ]; do
    [ "$(df --output=pcent /tmp | tail -1 | tr -dc 0-9)" -lt 60 ] || { echo "ABORT: /tmp"; break; }
    unlocked || { echo "ABORT: bloqueada"; exit 1; }
    t=$(( $(date +%s%3N) - t0 )); grim -o "$H" -t jpeg -q 80 "$OUT/$MODE-$ORIGIN-$cmd-$(printf %04d $t).jpg" 2>/dev/null; n=$((n + 1))
  done
  wait; sleep 0.4
  echo "  $cmd: $n fotogramas · $(pv animating)"
done
sed 's/\x1b\[[0-9;]*m//g' "$OUT/preview.log" | grep -E '"ev":"(entering|leaving)-done|phase"|WARN.*lock|cap reached|ERROR' | grep -v "portal\|dropped" | sed 's/^/  log: /'
