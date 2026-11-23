# Pruebas del Lock (fase 15)

Ninguna bloquea la sesión ni usa PAM.

- `hold-probe.py` (LK-12): `HoldButton` en Quickshell offscreen sobre una copia del árbol con un
  `Session` falso. Exige que volver a pulsar empiece de cero y que perder el foco u ocultarse cancele.
  Fallaba hasta la 15C (dispara a 432 ms, y también tras perder el foco u ocultarse); **pasa desde la 15C**.
- `lk11-timing.py <lock.sh>` (LK-11): `lock.sh` con `hyprctl`/`qs`/`hyprlock` falsos; tiempo hasta caer a
  hyprlock con el shell ausente, colgado, y colgado con Hyprland colgado.
- `lk-preview.sh` (LK-01, LK-02, LK-07): la preview interactiva en HDMI-A-1 + una salida headless
  (RP-10). **Toma el teclado unos segundos**; guarda RP-1 (`lockStatus` = unlocked, `hyprctl locked` =
  false y la preview con el foco en la pantalla esperada) antes de cada `wtype`. Deja capturas JPEG en
  `$OUT` (o un directorio temporal).
- `board-captures.sh <dir> "<WxH>:<escala>,…" <escenario>…` (15B): una salida headless por configuración,
  la preview SIN teclado sólo en ella y capturas JPEG q80. `LOCK_PREVIEW_LAYOUT=classic` en el entorno para
  la composición de ADR-30.
- `keyboard-test.sh` (15C): el recorrido de Tab, Mayús+Tab (verbo `step`, que `wtype` no sabe mandar), Esc,
  una tecla sobre un botón que va al campo, Enter en «Show more», el hold de energía (corto, 300 ms, Tab a
  mitad y 800 ms: en la preview disparar sólo anota `power` en el log) y el texto a medias entre dos
  pantallas (LK-02). **Toma el teclado ~30 s** con guarda RP-1 antes de cada `wtype`. Sale con los fallos.
- `notifs-arrival-test.sh` (15D): llegadas y bajas en la lista de notificaciones del panel (preview SIN teclado,
  datos sintéticos): sin leer entra al momento; leyendo (el foco dentro) queda pendiente con la cantidad al día
  y el foco quieto; `adoptNotifications` (lo que hace «New notifications») la trae; si el control enfocado se va,
  el foco pasa al siguiente. Verbos de la preview: `step`, `adoptNotifications`, `state.notifsView`.
- Datos reales sin bloquear (15D): `qs -c sumi ipc call sumi lockDataTest true` y `lockDataState` (renovar
  antes de 10 s); `LOCK_PREVIEW_DATA=live` hace eso mismo desde la preview.
- `calm-test.sh` (15E): A) sin teclado en una headless: calma a los 10 s, una notificación no despierta,
  comprobando y un fallo de energía suspenden y reinician la espera, el foco vuelve al campo al calmarse; mueve el
  puntero a la headless y lo devuelve (el cursor oculto NO se puede comprobar así: `hl.dsp.cursor.move` sólo da la
  entrada en la capa; lo comprueba el usuario con su ratón). B) con teclado ~5 s: la tecla que despierta se
  conserva; un Enter en calma no activa el botón que tenía el foco.
- `choreo-seq.sh <salida> <normal|reduced|off> <island|bar> <orden:ms>…` (15F): secuencias JPEG de la entrada y la
  salida del panel (preview SIN teclado, en una headless, fase inicial `unlocked`); `Motion.override` sólo en la
  preview, sin tocar el ajuste del usuario; `bar` finge el origen del reloj de la barra. Imprime `animating` y los
  tiempos de `entering-done` / `leaving-done`.
- `auth-probe.py` (15G-1): `LockAuth` real con un adaptador PAM FALSO (nunca la pila real) y `faillock.conf` /
  `faillock` falsos, offscreen. LK-03 (la segunda respuesta en la misma conversación), I-8 (buffer vacío al
  responder) y LK-04 (la política leída del archivo; `unlock_time = 0` sin plazo). 8 comprobaciones.
- `session-probe.sh` (15G-1): `LockSession` cargada SOLA en el Wayland real desde una copia del árbol, en un bus
  D-Bus privado y con estado y caché temporales; NUNCA llama a `engage` (la fase `locked` se simula asignando
  `phase`: `WlSessionLock` no bloquea). Contrato completo, visualizador apagado, distribución por índice (LK-14),
  calma desde `locked` (LK-06) y suspendida con un hold. Guarda externa: si `hyprctl locked` se pusiera en true,
  mata la sonda.
