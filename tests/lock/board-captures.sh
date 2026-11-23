#!/usr/bin/env bash
# 15B: capturas del panel en la preview (sin teclado, sin PAM, sin bloqueo) sobre salidas headless.
#   board-captures.sh <salida-dir> "<WxH>:<escala>[,…]" <escenario>...
# Cada configuración crea UNA salida headless (RP-10: escala 1 de Hyprland, fuera del HDMI), lanza la
# preview sólo en ella y captura en JPEG q80 con guarda de /tmp y de bloqueo (RP-7).
set -u
OUT=$1; CONFS=$2; shift 2
W=$(cd "$(dirname "$0")/../../sumi" && pwd); P=$W/lock-preview.qml
mkdir -p "$OUT"
pv(){ timeout 3 qs -p "$P" ipc call sumi-lock-preview "$@"; }
unlocked(){ [ "$(timeout 3 qs -c sumi ipc call sumi lockStatus | jq -r .phase)" = unlocked ] && [ "$(hyprctl locked)" = false ]; }
addh(){ # $1 = WxH
  local before H
  before=$(hyprctl monitors -j | jq -r '[.[].name] | join(" ")')
  hyprctl output create headless >/dev/null
  timeout 5 sh -c "until [ \"\$(hyprctl monitors -j | jq -r '[.[].name] | join(\" \")')\" != \"$before\" ]; do sleep 0.05; done"
  H=$(hyprctl monitors -j | jq -r '.[] | select(.name|startswith("HEADLESS")) | .name' | tail -1)
  hyprctl eval "hl.monitor({ output = \"$H\", mode = \"$1@60\", position = \"4000x0\", scale = 1 })" >/dev/null
  timeout 5 sh -c "until hyprctl monitors -j | jq -e '.[] | select(.name==\"$H\" and .x==4000 and .scale==1)' >/dev/null; do sleep 0.05; done" || echo "AVISO: $H sin colocar" >&2
  echo "$H"
}
delh(){ for h in $(hyprctl monitors -j | jq -r '.[] | select(.name|startswith("HEADLESS")) | .name'); do hyprctl output remove "$h" >/dev/null; done; }
PID=""
cleanup(){ [ -n "$PID" ] && { pv quit >/dev/null 2>&1; sleep 0.4; kill "$PID" 2>/dev/null; }; delh; }
trap cleanup EXIT
IFS=, read -ra LIST <<< "$CONFS"
for conf in "${LIST[@]}"; do
  mode=${conf%%:*}; scale=${conf##*:}
  unlocked || { echo "ABORT: sesión bloqueada"; exit 1; }
  H=$(addh "$mode")
  ST=$(mktemp -d)
  SHELL=/usr/bin/fish LOCK_PREVIEW_SCREENS=$H LOCK_PREVIEW_SCALE=$scale XDG_STATE_HOME=$ST \
    qs -p "$P" > "$OUT/preview-$mode-$scale.log" 2>&1 &
  PID=$!
  for i in $(seq 60); do pv state >/dev/null 2>&1 && break; sleep 0.1; done
  sleep 1.2
  for sc in "$@"; do
    [ "$(df --output=avail /tmp | tail -1)" -gt 300000 ] || { echo "ABORT: /tmp"; exit 1; }
    pv scenario "$sc" >/dev/null; sleep 0.9
    unlocked || { echo "ABORT: sesión bloqueada"; exit 1; }
    f="$OUT/$sc-$mode-s$scale.jpg"; grim -o "$H" -t jpeg -q 80 "$f"
    echo "$f $(pv state | jq -c '.narrow')"
  done
  pv quit >/dev/null 2>&1; sleep 0.4; kill "$PID" 2>/dev/null; PID=""
  delh; rm -rf "$ST"
done
