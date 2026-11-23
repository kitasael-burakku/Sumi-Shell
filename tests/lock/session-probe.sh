#!/usr/bin/env bash
# 15G-1: LockSession cargada SOLA en el Wayland real, desde una copia del árbol, en un bus D-Bus privado, con
# XDG_STATE_HOME y XDG_CACHE_HOME temporales. NUNCA llama a engage: el bloqueo no se pide. Una guarda de fuera
# comprueba cada 0,5 s que `hyprctl locked` siga en false y, si no, mata la sonda (y deja la línea en el log).
set -u
HERE=$(cd "$(dirname "$0")" && pwd); SRC=$(cd "$HERE/../../sumi" && pwd)
D=$(mktemp -d /tmp/kt-sess.XXXX); trap 'rm -rf "$D"' EXIT
cp -a "$SRC" "$D/k"; cp "$HERE/probe-session.qml" "$D/k/"
mkdir -p "$D/st" "$D/cache"
[ "$(hyprctl locked)" = false ] || { echo "ABORT: bloqueada"; exit 1; }
XDG_STATE_HOME=$D/st XDG_CACHE_HOME=$D/cache dbus-run-session --config-file="$HOME/Projects/Quickshell/tools/private-bus.conf" -- \
  qs -p "$D/k/probe-session.qml" --no-color > "$D/log" 2>&1 &
PID=$!
while kill -0 $PID 2>/dev/null; do
  if [ "$(hyprctl locked)" != false ]; then echo "GUARDA: la sesión apareció bloqueada; mato la sonda"; kill $PID; break; fi
  sleep 0.5
done
grep -E "PROBE|ERROR|WARN|Error" "$D/log" | grep -v "portal\|dropped operation" | sed "s/.*PROBE //"
echo "hyprctl locked al final: $(hyprctl locked)"
