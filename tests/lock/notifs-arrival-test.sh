#!/usr/bin/env bash
# 15D: llegadas y bajas de notificaciones en el panel (preview SIN teclado, en una headless, datos sintéticos).
set -u
OUT=${OUT:-$(mktemp -d)}; W=$(cd "$(dirname "$0")/../../sumi" && pwd); P=$W/lock-preview.qml
T=$HOME/Projects/Quickshell/tools/lock
pv(){ timeout 3 qs -p "$P" ipc call sumi-lock-preview "$@"; }
st(){ pv state | jq -c "$1"; }
fail=0; check(){ if [ "$2" = "$3" ]; then echo "OK    $1"; else echo "FALLA $1: $2 ≠ $3"; fail=$((fail+1)); fi; }
PID=""; cleanup(){ [ -n "$PID" ] && { pv quit >/dev/null 2>&1; sleep 0.4; kill "$PID" 2>/dev/null; }; sh "$T/headless.sh" del; }
trap cleanup EXIT
H=$(sh "$T/headless.sh" add 1920)
PID=$(sh "$T/preview.sh" "$W" "$OUT/preview.log" "$H")
for i in $(seq 60); do pv state >/dev/null 2>&1 && break; sleep 0.1; done; sleep 1
pv scenario board >/dev/null; sleep 0.5
now=$(( $(date +%s) * 1000 ))
# cada grupo con dos mensajes: tiene su «Show more», que es donde se pone el foco para «leer»
g(){ printf '{"app":"%s","name":"%s","count":2,"items":[{"id":"%s","title":"%s","body":"b","time":%s},{"id":"%s-2","title":"older","body":"b","time":%s}]}' "$1" "$2" "$3" "$4" "$5" "$3" "$(( $5 - 1 ))"; }
BASE="$(g discord Discord d1 Yani $now),$(g thunderbird Thunderbird t1 Invoice $((now-60000))),$(g sumi Sumi Shell k1 Updates $((now-120000)))"
pv set notifs "{\"state\":\"ok\",\"count\":3,\"groups\":[$BASE]}" >/dev/null; sleep 0.4
check "sin leer: la lista se enseña" "$(st '.notifsView.shown')" '["Discord","Thunderbird","Sumi Shell"]'
NEW="$(g steam Steam s1 Sale $((now+1000)))"
pv set notifs "{\"state\":\"ok\",\"count\":4,\"groups\":[$NEW,$BASE]}" >/dev/null; sleep 0.4
check "sin leer: una llegada entra al momento" "$(st '.notifsView | [.pending, .shown[0]]')" '[false,"Steam"]'
# leyendo: el foco en «Show more · Sumi Shell»
pv set notifs "{\"state\":\"ok\",\"count\":2,\"groups\":[$(g sumi Sumi Shell k1 Updates $now)]}" >/dev/null; sleep 0.3
for i in $(seq 14); do [ "$(st .focus)" = '"Show more · Sumi Shell"' ] && break; pv step 1 >/dev/null; done
echo "foco antes de la llegada: $(st .focus)"
F0=$(st .focus)
NEW2="$(g telegram Telegram tg1 Hi $((now+2000)))"
pv set notifs "{\"state\":\"ok\",\"count\":4,\"groups\":[$NEW2,$(g sumi Sumi Shell k1 Updates $now)]}" >/dev/null; sleep 0.4
echo "estado: $(st '.notifsView')"
check "leyendo: la llegada NO reordena (pendiente)" "$(st '.notifsView.pending')" true
check "leyendo: la cantidad sí sigue a lo vivo" "$(st '.notifsView.count')" 4
check "leyendo: el foco no se mueve" "$(st .focus)" "$F0"
pv adoptNotifications >/dev/null; sleep 0.4
check "New notifications trae la lista" "$(st '.notifsView | [.pending, .shown]')" '[false,["Telegram","Sumi Shell"]]'
# baja del control enfocado
for i in $(seq 14); do [ "$(st .focus)" = '"Show more · Sumi Shell"' ] && break; pv step 1 >/dev/null; done
echo "foco en: $(st .focus)"
pv set notifs "{\"state\":\"ok\",\"count\":1,\"groups\":[$NEW2]}" >/dev/null; sleep 0.3
pv adoptNotifications >/dev/null; sleep 0.5
echo "tras la baja: foco $(st .focus) · lista $(st '.notifsView.shown')"
check "tras la baja el foco no se queda en nada" "$( [ "$(st .focus)" != '""' ] && echo yes)" yes
echo "fallos: $fail"; exit $fail
