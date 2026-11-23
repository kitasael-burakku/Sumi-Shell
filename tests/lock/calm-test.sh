#!/usr/bin/env bash
# 15E: calma y despertar del panel en la preview (sin PAM ni bloqueo).
#  A) SIN teclado, en una headless: 10 s hasta la calma, una notificación no despierta, comprobando y un fallo
#     de energía suspenden y reinician la espera, el foco vuelve al campo al calmarse, cursor oculto (mueve el
#     puntero a la headless y lo devuelve).
#  B) CON teclado unos segundos en el HDMI (guarda RP-1): la tecla que despierta se conserva; un Enter en calma
#     con el foco que estaba en un botón no lo activa.
set -u
OUT=${OUT:-$(mktemp -d)}; W=$(cd "$(dirname "$0")/../../sumi" && pwd); P=$W/lock-preview.qml
T=$HOME/Projects/Quickshell/tools/lock
pv(){ timeout 3 qs -p "$P" ipc call sumi-lock-preview "$@"; }
st(){ pv state | jq -r "$1"; }
fail=0; check(){ if [ "$2" = "$3" ]; then echo "OK    $1"; else echo "FALLA $1: «$2» ≠ «$3»"; fail=$((fail+1)); fi; }
unlocked(){ [ "$(timeout 3 qs -c sumi ipc call sumi lockStatus | jq -r .phase)" = unlocked ] && [ "$(hyprctl locked)" = false ]; }
CUR=$(hyprctl cursorpos | tr -d ' ')
PID=""; cleanup(){ [ -n "$PID" ] && { pv quit >/dev/null 2>&1; sleep 0.4; kill "$PID" 2>/dev/null; }
  hyprctl dispatch "hl.dsp.cursor.move({ x = ${CUR%,*}, y = ${CUR#*,} })" >/dev/null; sh "$T/headless.sh" del; }
trap cleanup EXIT
unlocked || { echo ABORT; exit 1; }
# ── A ────────────────────────────────────────────────────────────────────
H=$(sh "$T/headless.sh" add 1920)
PID=$(sh "$T/preview.sh" "$W" "$OUT/preview-a.log" "$H")
for i in $(seq 60); do pv state >/dev/null 2>&1 && break; sleep 0.1; done; sleep 0.5
pv scenario board >/dev/null; t0=$(date +%s.%N)
for i in $(seq 30); do [ "$(st .calm)" = true ] && break; sleep 0.5; done
t=$(echo "$(date +%s.%N) - $t0" | bc); echo "calma a los ${t%.*}.${t#*.} s"; check "calma a los 10 s (±1)" "$(echo "$t >= 9.5 && $t <= 11" | bc)" 1
pv set notifs '{"state":"ok","count":1,"groups":[{"app":"x","name":"X","count":1,"items":[{"id":"x1","title":"New","body":"b","time":0}]}]}' >/dev/null; sleep 1
check "una notificación nueva no despierta" "$(st .calm)" true
pv set calm false >/dev/null; pv set auth '{"state":"checking"}' >/dev/null; sleep 12
check "comprobando 12 s: sin calma" "$(st .calm)" false
pv set auth '{"state":"failed","failed":1}' >/dev/null; sleep 8.5
check "tras el fallo, a los 8,5 s todavía se lee" "$(st .calm)" false
sleep 2.5; check "…y a los 11 s, calma" "$(st .calm)" true
pv set calm false >/dev/null; sleep 6; pv set powerError '"Couldn'"'"'t shut down"' >/dev/null; sleep 6
check "un fallo de energía reinicia la espera (6+6 s: sin calma)" "$(st .calm)" false
sleep 5; check "…y llega después" "$(st .calm)" true
pv set calm false >/dev/null; pv set powerError '""' >/dev/null; pv step 1 >/dev/null; pv step 1 >/dev/null; pv step 1 >/dev/null
echo "foco antes de la calma: $(st .focus)"
pv set calm true >/dev/null; sleep 0.4
check "al calmarse, el foco vuelve al campo" "$(st .focus)" "Password"
# cursor: a la headless, vacío abajo a la izquierda
pv set calm false >/dev/null
X=$((1920 + 150)); Y=950
for d in 100 60 30 10 0; do hyprctl dispatch "hl.dsp.cursor.move({ x = $((X - d)), y = $Y })" >/dev/null; sleep 0.05; done
sleep 0.5; unlocked && grim -o "$H" -t jpeg -q 90 "$OUT/cur-visible.jpg"
sleep 3.8; unlocked && grim -o "$H" -t jpeg -q 90 "$OUT/cur-hidden.jpg"
diff=$(python3 - "$OUT" <<'PY'
import sys; from PIL import Image, ImageChops
a = Image.open(sys.argv[1] + '/cur-visible.jpg').crop((130, 930, 180, 990)).convert('L')
b = Image.open(sys.argv[1] + '/cur-hidden.jpg').crop((130, 930, 180, 990)).convert('L')
print(sum(1 for p in ImageChops.difference(a, b).getdata() if p > 40))
PY
)
echo "píxeles distintos alrededor del puntero (visible → 3,8 s quieto): $diff"
# `hl.dsp.cursor.move` sólo da la ENTRADA en la capa, sin movimiento: Qt no recalcula el cursor y aquí sale
# visible siempre (medido 2026-09-29, también en calma). Lo comprueba el usuario con su ratón.
echo "INFO  cursor oculto: no comprobable con cursor.move (diferencia $diff px); comprobado por el usuario con su ratón (2026-09-29)"
pv quit >/dev/null 2>&1; sleep 0.4; kill "$PID" 2>/dev/null; PID=""; sh "$T/headless.sh" del
hyprctl dispatch "hl.dsp.cursor.move({ x = ${CUR%,*}, y = ${CUR#*,} })" >/dev/null
# ── B ────────────────────────────────────────────────────────────────────
H=$(sh "$T/headless.sh" add 1920)
PID=$(LOCK_PREVIEW_INTERACTIVE=1 sh "$T/preview.sh" "$W" "$OUT/preview-b.log" "HDMI-A-1,$H")
for i in $(seq 60); do [ "$(st .heroActive 2>/dev/null)" = true ] && break; sleep 0.1; done
pv scenario board >/dev/null; sleep 0.4
guard(){ unlocked || { echo ABORT; exit 1; }; [ "$(st .focusScreen)" = HDMI-A-1 ] && [ "$(st .heroActive)" = true ] || { echo "ABORT: foco"; exit 1; }; }
pv set calm true >/dev/null; sleep 0.3
guard; wtype x; sleep 0.3
check "la tecla que despierta se conserva" "$(st '[.calm, .bufferLength] | @csv')" "false,1"
guard; wtype -k Escape; sleep 0.2
pv step 1 >/dev/null; pv step 1 >/dev/null; pv step 1 >/dev/null   # Pause
echo "foco: $(st .focus)"
pv set calm true >/dev/null; sleep 0.3
guard; wtype -k Return; sleep 0.4
check "Enter en calma despierta y no activa el botón" "$(st .calm),$(grep -c '"ev":"media' "$OUT/preview-b.log"),$(st .auth.state)" "false,0,idle"
echo "fallos: $fail · $OUT"; exit $fail
