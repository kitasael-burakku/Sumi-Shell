#!/usr/bin/env bash
# 15C: teclado del panel en la preview (sin PAM ni bloqueo): recorrido de Tab, Mayús+Tab (verbo step: wtype
# no lo manda), Esc, texto redirigido, un dueño del texto entre dos pantallas (LK-02), comprobación que rechaza,
# y el hold de energía (en la preview sólo se anota). TOMA EL TECLADO unos segundos; guarda RP-1 antes de
# cada wtype: shell unlocked, `hyprctl locked` false y la preview con el foco en la pantalla esperada.
set -u
OUT=${OUT:-$(mktemp -d)}; W=$(cd "$(dirname "$0")/../../sumi" && pwd); P=$W/lock-preview.qml
T=$HOME/Projects/Quickshell/tools/lock
pv(){ timeout 3 qs -p "$P" ipc call sumi-lock-preview "$@"; }
st(){ pv state | jq -r "$1"; }
guard(){
  [ "$(timeout 3 qs -c sumi ipc call sumi lockStatus | jq -r .phase)" = unlocked ] || { echo "ABORT: shell no unlocked"; exit 1; }
  [ "$(hyprctl locked)" = false ] || { echo "ABORT: sesión bloqueada"; exit 1; }
  [ "$(st .focusScreen)" = "$1" ] && [ "$(st .heroActive)" = true ] || { echo "ABORT: la preview no tiene el foco en $1"; exit 1; }
}
k(){ guard "$1"; shift; wtype "$@"; sleep 0.25; }
fail=0; check(){ if [ "$2" = "$3" ]; then echo "OK    $1"; else echo "FALLA $1: «$2» ≠ «$3»"; fail=$((fail+1)); fi; }
PID=""; cleanup(){ [ -n "$PID" ] && { pv quit >/dev/null 2>&1; sleep 0.4; kill "$PID" 2>/dev/null; }; sh "$T/headless.sh" del; }
trap cleanup EXIT
[ "$(timeout 3 qs -c sumi ipc call sumi lockStatus | jq -r .phase)" = unlocked ] || { echo "ABORT"; exit 1; }
H=$(sh "$T/headless.sh" add 1920)
PID=$(LOCK_PREVIEW_INTERACTIVE=1 sh "$T/preview.sh" "$W" "$OUT/preview.log" "HDMI-A-1,$H")
for i in $(seq 60); do [ "$(st .heroActive 2>/dev/null)" = true ] && break; sleep 0.1; done
pv scenario board >/dev/null; sleep 0.6
k HDMI-A-1 abc
check "texto en el campo" "$(st .bufferLength)" 3
check "foco inicial" "$(st .focus)" "Password"
names=""
for i in $(seq 12); do k HDMI-A-1 -k Tab; names="$names|$(st .focus)"; done
echo "Tab ×12: $names"
check "Tab vuelve al campo tras la vuelta completa" "$(st .focus)" "Password"
pv step 1 >/dev/null; pv step 1 >/dev/null; sleep 0.2      # en «Previous track»
k HDMI-A-1 d
check "tecla sobre un botón va al campo" "$(st .bufferLength)" 4
check "…y el foco vuelve al campo" "$(st .focus)" "Password"
check "Mayús+Tab (step -1) desde el campo va a la energía" "$(pv step -1)" "Hold to shut down"
k HDMI-A-1 -k Escape
check "Esc en un botón devuelve el foco al campo" "$(st .focus)" "Password"
check "…sin borrar lo escrito" "$(st .bufferLength)" 4
# expandir por teclado
for i in $(seq 12); do [ "$(st .focus)" = "Show more · Discord" ] && break; pv step 1 >/dev/null; done
k HDMI-A-1 -k Return
check "Enter en Show more lo abre (el control pasa a Show less)" "$(st .focus)" "Show less · Discord"
grim -o HDMI-A-1 -t jpeg -q 80 "$OUT/15c-expanded.jpg"
# hold de energía por teclado (preview: disparar sólo anota «power» en el log)
for i in $(seq 16); do [ "$(st .focus)" = "Hold to shut down" ] && break; pv step 1 >/dev/null; done
check "foco en Shut down" "$(st .focus)" "Hold to shut down"
k HDMI-A-1 -k Return
k HDMI-A-1 -P Return -s 300 -p Return
k HDMI-A-1 -P Return -s 200 -k Tab -s 600 -p Return
sleep 0.8
check "Enter corto, 300 ms y Tab a mitad: ningún disparo" "$(grep -c '"ev":"power' "$OUT/preview.log")" 0
for i in $(seq 16); do [ "$(st .focus)" = "Hold to shut down" ] && break; pv step 1 >/dev/null; done
k HDMI-A-1 -P Return -s 800 -p Return
sleep 0.3
check "sostener 800 ms dispara una vez (sólo en la preview)" "$(grep -c '"ev":"power' "$OUT/preview.log")" 1
# LK-02: el texto a medias pasa de pantalla
check "tras el disparo el foco sigue en Shut down" "$(st .focus)" "Hold to shut down"
k HDMI-A-1 -k Escape
pv set focusScreen "\"$H\"" >/dev/null; sleep 0.8
check "tras cambiar de pantalla, lo escrito sigue" "$(st .bufferLength)" 4
k "$H" e
check "LK-02: la tecla en la otra pantalla se AÑADE" "$(st .bufferLength)" 5
pv set focusScreen '"HDMI-A-1"' >/dev/null; sleep 0.8
k HDMI-A-1 f
check "…y al volver, también" "$(st .bufferLength)" 6
# comprobando: lo tecleado se rechaza y el campo no se desincroniza
pv set auth '{"state":"checking"}' >/dev/null; sleep 0.2
k HDMI-A-1 g
check "comprobando: la tecla no entra" "$(st .bufferLength)" 6
pv set auth '{"state":"idle"}' >/dev/null; sleep 0.2
k HDMI-A-1 h
check "…y después sigue donde estaba" "$(st .bufferLength)" 7
k HDMI-A-1 -k Escape
check "Esc en el campo borra" "$(st .bufferLength)" 0
echo "fallos: $fail · capturas y log en $OUT"
exit $fail
