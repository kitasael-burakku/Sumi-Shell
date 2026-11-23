import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "../core"
import "../services"
import "../theme"

/**
 * El dueño del bloqueo (docs/lock/ESTADO.md). Sostiene `WlSessionLock`, la
 * persistencia a través de una recarga, `lock.json`, las fases y `LockAuth`
 * (AUTENTICACION.md), e implementa el contrato de sólo lectura que consume
 * `LockSurface` (ESTADO §7) — la misma pieza que monta `lock-preview.qml`
 * sobre un contexto falso.
 *
 * I-1 / I-6: el único archivo del árbol que escribe `WlSessionLock.locked`
 * (nunca llama a `.unlock()`: sólo existe `persist.locked = false`, en
 * `finishUnlock()`) y que instancia `WlSessionLock`. `PamContext` vive en
 * `LockAuth`, que sólo este archivo instancia (ARQUITECTURA §4).
 *
 * I-4 (la recarga no desbloquea, S2 medido en INVESTIGACION §9): `persist`
 * está declarado ANTES que `wl` en este mismo archivo — el orden de
 * declaración decide en qué orden `PersistentProperties` y `WlSessionLock`
 * se restauran tras una recarga (diseño A). No lo reordenes.
 *
 * ARQUITECTURA §4, regla 1: sólo importa `theme/`, `components/` (vía
 * `LockSurface`), de `services/` lo que lista SERVICIOS.md §2 y de `core/`
 * sólo `Screens` y `Hypr` — nunca `core/Screen`, `core/Island` ni `surfaces/`.
 *
 * Fase 15 (15G-1, rediseño): monta `LockBoardSurface` (el panel de tres columnas) en lugar de
 * `LockSurface`; la calma es de `LockCalm` (LK-06), los datos del panel de `services/LockData` (uno por
 * sesión, reclamando sólo con el panel a la vista), la ventana es transparente sólo al entrar y al salir
 * (LK-05), la cápsula sale de `Screen.lockOrigin` (island, dock o reloj de la barra) y la distribución se
 * lee por su índice (LK-14). NADA de lo que sostiene el bloqueo cambia: `persist` antes de `wl`, sólo
 * `finishUnlock` suelta, sólo `PamResult.Success` llega a `finishUnlock`.
 */
Scope {
    id: root

    // ── el contrato de sólo lectura (ESTADO §7) ──────────────────────────────

    property string phase: "unlocked"   // unlocked · entering · locked · leaving
    property bool instant: false
    readonly property bool secure: wl.secure
    property real since: 0
    property string reason: ""
    property string focusScreen: ""
    readonly property bool calm: calmCtl.calm
    property string powerError: ""

    readonly property string buffer: authCtl.buffer
    readonly property int bufferLength: authCtl.bufferLength
    readonly property var auth: authCtl.auth

    property string layoutCode: ""
    property int layoutCount: 1
    property bool capsLock: false
    property bool numLock: false

    readonly property string userName: SystemInfo.userName
    /** Rutas locales ya comprobadas con `test -r` por LockData (sin «Cannot open» en el journal). */
    readonly property string avatarSource: lockData.avatarSource
    readonly property string fetchImageSource: lockData.fetchImageSource

    // ── los datos del panel (15D): de LockData, sin Cava (LOCK-D13) y sin la cámara como pantalla (LK-14) ──
    readonly property var music: lockData.music
    readonly property var privacy: lockData.privacy
    readonly property var fetch: lockData.fetch
    readonly property var weather: lockData.weather
    readonly property var metrics: lockData.metrics
    readonly property var notifs: lockData.notifs
    readonly property int notifications: lockData.notifs.count || 0
    readonly property bool suspendOk: Power.suspendOk
    readonly property string suspendNote: Power.suspendNote

    signal failedAttempt()
    signal bufferCleared()

    function setBuffer(text) { root.touch(); authCtl.setBuffer(text); }
    function clearBuffer() { root.touch(); authCtl.clearBuffer(); }
    function submit() { root.touch(); authCtl.submit(); }

    /** Actividad del usuario: despierta y reinicia la espera de la calma (LockCalm). */
    function touch() { calmCtl.activity(); }
    /** Un hold de energía en curso: la calma espera (15E). */
    function setHolding(on) { calmCtl.holding = on; }

    function setFocusScreen(name) { root.focusScreen = name; }

    function power(action) {
        root.powerError = "";
        if (action === "suspend") {
            if (!Power.suspendOk) { root.powerError = "Couldn't suspend — " + Power.suspendNote; return; }
            Power.suspend();
        } else if (action === "reboot") {
            Power.reboot();
        } else if (action === "shutdown") {
            Power.shutdown();
        } else {
            console.warn("lock: unknown power action", action);
        }
    }

    function media(action) {
        root.touch();
        if (action === "previous") Media.previous();
        else if (action === "toggle") Media.toggle();
        else if (action === "next") Media.next();
    }

    /** Geometría del island de esa pantalla al bloquear (ISLAND §3). */
    function snapshot(screenName) {
        return root.homes[screenName] || root.restTarget(screenName);
    }
    /** El origen de la cápsula (15F): el island, el dock o el tramo del reloj de la barra. */
    function originOf(sc) { return sc.lockOrigin ? sc.lockOrigin() : sc.islandGeometry(); }

    /** Geometría de reposo ACTUAL del island, para volver (ISLAND §4): lectura en vivo. */
    function restTarget(screenName) {
        const sc = Screens.byName(screenName);
        if (sc)
            return root.originOf(sc);
        const s = Settings.uiScale;
        return { x: 0, y: Math.round(Metrics.topGap * s), w: Math.round(Metrics.restW * s),
                 h: Math.round(Metrics.restH * s), r: Math.round(Metrics.restCorner * s) };
    }

    function enterDone(screenName) { root.reportPhase(screenName, "entering", "locked"); }
    function leaveDone(screenName) { root.reportPhase(screenName, "leaving", "unlocked"); }

    // ── fachada para servicios/IPC (ESTADO §8, vía services/Lock) ────────────

    /** `session` o `instant`; `restore` = arranque en frío con `lock.json` (ESTADO §5). */
    function engage(newReason) {
        if (root.phase !== "unlocked" || root.capturing)
            return true;
        const r = (newReason === "instant" || newReason === "restore" || newReason === "session") ? newReason : "session";
        const doInstant = r === "instant" || r === "restore";
        /*
         * F5e (H-26): con una pila PAM que se SABE ausente (pam_stack.py), la shell no bloquea: no podría desbloquear.
         * `lockNow` devuelve false y el helper (o hypridle) cae a hyprlock. `restore` sí sigue: negarse dejaría un bloqueo
         * muerto sin nadie que lo sostenga (y sin el archivo de la pila, hyprlock tampoco tendría con qué).
         */
        if (LockPam.missing && r !== "restore") {
            console.warn("lock: the PAM service \"" + LockPam.service + "\" is missing; not locking (hyprlock will)");
            return false;
        }
        /*
         * EL FONDO (2026-10-01, pedido del usuario: no el wallpaper, sino la pantalla desenfocada hasta
         * ser ilegible). Con el bloqueo puesto el compositor ya no enseña lo de debajo, así que se
         * fotografía ANTES: `grim` a un 8 % del tamaño (ilegible ya antes del desenfoque) y, al acabar
         * o a los `captureMs` como mucho, se bloquea. Sólo en `session`: `instant` (suspensión) y
         * `restore` no esperan nada — su fondo es el respaldo opaco, sin imagen. lock.sh espera 1,5 s
         * antes de recurrir a hyprlock: el tope cabe de sobra.
         */
        if (!doInstant) {
            root.capturing = true;
            root.pendingReason = r;
            root.captured = ({});
            captureProc.command = ["sh", "-c", root.captureScript, "sh", root.captureDir]
                .concat(Screens.list.filter(function (sc) { return !!sc; }).map(function (sc) { return sc.name; }));
            captureProc.running = true;
            captureWait.restart();
            return true;
        }
        return root.engageNow(r);
    }

    // ── la captura del fondo (2026-10-01) ──────────────────────────────────────
    property bool capturing: false
    property string pendingReason: ""
    /** { pantalla: ruta } de la captura de ESTE bloqueo; vacío = sin imagen (respaldo opaco). */
    property var captured: ({})
    property int captureGen: 0
    readonly property int captureMs: 350
    readonly property string captureDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/sumi-lock"
    /** Una captura por pantalla, en paralelo; imprime el nombre de cada una que salió. Sólo literales. */
    readonly property string captureScript: 'd="$1"; shift; mkdir -p -m 700 "$d" || exit 1; '
        + 'for o in "$@"; do ( grim -o "$o" -s 0.08 -t png "$d/$o.png.new" 2>/dev/null '
        + '&& mv -f "$d/$o.png.new" "$d/$o.png" && echo "$o" ) & done; wait'
    function captureFor(screenName) { return root.captured[screenName] || ""; }
    function captureDone(text) {
        if (!root.capturing)
            return;
        root.capturing = false;
        captureWait.stop();
        const got = {};
        const names = (text || "").split("\n");
        for (let i = 0; i < names.length; i++) {
            const n = names[i].trim();
            if (n.length > 0) got[n] = root.captureDir + "/" + n + ".png";
        }
        root.captured = got;
        root.captureGen++;
        root.engageNow(root.pendingReason || "session");
    }
    Process {
        id: captureProc
        stdout: StdioCollector { id: captureOut }
        onExited: root.captureDone(captureOut.text)
    }
    /** Tope: si `grim` tarda o no arranca (un Process que no arranca no emite `exited`), se bloquea igual. */
    Timer {
        id: captureWait
        interval: root.captureMs
        onTriggered: {
            if (!root.capturing) return;
            console.warn("lock: background capture took longer than", root.captureMs, "ms; locking without it");
            captureProc.running = false;
            root.captureDone("");
        }
    }
    /** Al desbloquear la captura sobra: fuera del disco (es la pantalla, aunque a un 8 %). */
    Process { id: captureClean }
    function dropCapture() {
        root.captured = ({});
        captureClean.command = ["sh", "-c", 'rm -f "$1"/*.png "$1"/*.png.new', "sh", root.captureDir];
        captureClean.running = true;
    }

    function engageNow(r) {
        if (root.phase !== "unlocked")
            return true;
        const doInstant = r === "instant" || r === "restore";

        root.reason = r;
        root.since = Date.now() / 1000;
        root.powerError = "";
        root.focusScreen = Hypr.focusedName;
        authCtl.reset();

        // 1. lock.json ANTES de pedir el bloqueo (ESTADO §5)
        root.writeLockJson(true);

        // 2. geometría de cada pantalla ANTES de que Screen reaccione y cierre nada (ISLAND §3)
        const list = Screens.list;
        const snap = {};
        const expect = [];
        for (let i = 0; i < list.length; i++) {
            const sc = list[i];
            if (!sc) continue;
            snap[sc.name] = root.originOf(sc);
            expect.push(sc.name);
        }
        root.homes = snap;
        root.expectedScreens = expect;
        root.reported = {};

        // 3. congelar la recarga mientras dure (defensa 2 de I-4, ESTADO §4)
        Quickshell.watchFiles = false;

        // 4. persist primero, LUEGO la fase (I-4: el orden de declaración de abajo es la otra mitad)
        root.instant = doInstant;
        root.phase = doInstant ? "locked" : "entering";
        persist.reason = r;
        persist.locked = true;

        if (!doInstant)
            capTimer.restart();

        devicesProbe.running = true;
        lockData.checkImages();
        SystemInfo.load();
        return true;
    }

    function summary() {
        // layoutCode/layoutCount/capsLock/numLock: diagnóstico, no texto tecleado (I-8) —
        // S8/L6 los necesita observables desde fuera (docs/lock/PRUEBAS.md §4).
        return { phase: root.phase, secure: root.secure, since: root.since, reason: root.reason,
                 failed: root.auth.failed || 0, calm: root.calm, focusScreen: root.focusScreen,
                 layoutCode: root.layoutCode, layoutCount: root.layoutCount,
                 capsLock: root.capsLock, numLock: root.numLock };
    }

    // ── fases (ESTADO §3) ─────────────────────────────────────────────────────

    property var homes: ({})
    property var expectedScreens: []
    property var reported: ({})

    function reportPhase(screenName, from, to) {
        if (root.phase !== from)
            return;
        const r = Object.assign({}, root.reported);
        r[screenName] = true;
        root.reported = r;
        const allIn = root.expectedScreens.length === 0
            || root.expectedScreens.every(function (n) { return r[n] === true; });
        if (allIn) {
            capTimer.stop();
            root.advancePhase(to);
        }
    }

    /** El tope que no deja a nadie atrapado por una animación que no avisa (ESTADO §3). */
    Timer {
        id: capTimer
        interval: Motion.lockCap
        onTriggered: {
            const to = root.phase === "entering" ? "locked" : root.phase === "leaving" ? "unlocked" : root.phase;
            if (to !== root.phase) {
                console.warn("lock: lockCap reached in phase", root.phase, "— forcing", to);
                root.advancePhase(to);
            }
        }
    }

    function advancePhase(to) {
        root.phase = to;
        if (to === "unlocked")
            root.finishUnlock();
    }

    function beginLeave() {
        if (root.phase !== "locked")
            return;
        root.reported = {};
        root.phase = "leaving";
        capTimer.restart();
    }

    function finishUnlock() {
        root.dropCapture();
        persist.locked = false;
        persist.reason = "";
        root.writeLockJson(false);
        Quickshell.watchFiles = true;
        root.homes = {};
        root.expectedScreens = [];
        root.reported = {};
        root.instant = false;
    }

    // ── calma (15E, LockCalm; LK-06) ──────────────────────────────────────────
    LockCalm {
        id: calmCtl
        phase: root.phase
        checking: root.auth.state === "checking"
    }
    /** Un fallo de energía se lee entero: espera completa desde que aparece. */
    onPowerErrorChanged: if (root.powerError.length > 0) calmCtl.holdMessage()
    onAuthChanged: {
        // `lock.json.failed` sigue al vivo: tras un SIGSEGV se sigue viendo «N failed attempts» (ESTADO §5)
        if (root.phase !== "unlocked")
            root.writeLockJson(true);
    }

    // ── los datos del panel (15D): uno por sesión, reclamando sólo con el panel a la vista ──
    LockData {
        id: lockData
        who: "session"
        active: (root.phase === "entering" || root.phase === "locked") && !root.calm
    }

    // ── LockAuth, dentro de LockSession (I-6) ─────────────────────────────────

    LockAuth { id: authCtl }

    Connections {
        target: authCtl
        function onSuccess() { root.beginLeave(); }
        function onFailedAttempt() { root.failedAttempt(); }
        function onBufferCleared() { root.bufferCleared(); }
    }

    // ── persistencia a través de una recarga (I-4) — DECLARADA ANTES DE `wl` ──

    PersistentProperties {
        id: persist
        reloadableId: "sumi-lock"
        property bool locked: false
        property string reason: ""

        onLoaded: {
            if (persist.locked) {
                // recarga en caliente con la sesión bloqueada, o el gestor de
                // caídas relanzó el proceso y algo retomó el bloqueo muerto
                // (allow_session_lock_restore): en ambos casos, `persist` ya
                // trae `locked = true` y esta generación entra DIRECTAMENTE en
                // `locked`, sin animación (ESTADO §4: lo que se pierde en una
                // recarga es aceptable)
                root.phase = "locked";
                root.instant = true;
                Quickshell.watchFiles = false;
                Qt.callLater(root.afterLockedLoad);
            } else {
                // arranque en frío de verdad: puede que `lock.json` diga que
                // había un bloqueo del shell que este proceso nuevo no conoce
                // (ESTADO §5)
                Qt.callLater(root.afterUnlockedLoad);
            }
        }
    }

    function afterLockedLoad() {
        lockJsonFile.reload();
        let st = null;
        try { st = JSON.parse(lockJsonFile.text()); } catch (e) {}
        root.since = (st && st.locked && st.since) ? st.since : (Date.now() / 1000);
        root.reason = persist.reason.length > 0 ? persist.reason : ((st && st.reason) || "session");
        root.focusScreen = Hypr.focusedName;
        root.homes = {};
        root.expectedScreens = [];
        root.reported = {};
        devicesProbe.running = true;
        lockData.checkImages();
        SystemInfo.load();
        authCtl.reset();
    }

    function afterUnlockedLoad() {
        lockJsonFile.reload();
        let st = null;
        try { st = JSON.parse(lockJsonFile.text()); } catch (e) {}
        if (!st || !st.locked)
            return;
        root.pendingRestoreReason = st.reason || "session";
        restoreLockedProbe.running = true;
    }

    property string pendingRestoreReason: "session"

    /** `hyprctl locked` — ¿sigue de verdad bloqueada la sesión que `lock.json` dice que dejamos? */
    Process {
        id: restoreLockedProbe
        command: ["hyprctl", "locked"]
        stdout: StdioCollector { id: restoreLockedOut }
        onExited: {
            if (restoreLockedOut.text.trim() !== "true") {
                // alguien desbloqueó ya (hyprlock de rescate): lock.json queda limpio
                root.writeLockJson(false);
                return;
            }
            restoreHyprlockProbe.running = true;
        }
    }

    /** Dos lockers no compiten por la sesión (R8): si hyprlock ya la sostiene, se deja como está. */
    Process {
        id: restoreHyprlockProbe
        command: ["pgrep", "-x", "hyprlock"]
        onExited: (code) => {
            if (code === 0)
                root.writeLockJson(false);
            else
                root.engage("restore");
        }
    }

    // ── el bloqueo real (I-1, I-6) ─────────────────────────────────────────────

    WlSessionLock {
        id: wl
        locked: persist.locked

        surface: Component {
            WlSessionLockSurface {
                id: surf
                // LK-05: transparente SÓLO al entrar y al salir (lo que el xray deja ver), opaca en `locked`
                // (I-7); sin superficie aún, negra. Antes era negra siempre y la entrada nunca veía el escritorio.
                color: view.item && view.item.wantsOpaque === false ? "transparent" : "black"

                // `surf.screen` nace `null` (S1, INVESTIGACION §9): enlace, no lectura única.
                readonly property string scrName: surf.screen ? surf.screen.name : ""
                readonly property bool hero: surf.scrName.length > 0
                    && (root.focusScreen === surf.scrName || root.focusScreen.length === 0)

                Item {
                    id: frame
                    anchors.fill: parent
                    focus: true
                    readonly property bool winActive: Window.active

                    onWinActiveChanged: {
                        if (!frame.winActive)
                            return;
                        if (surf.scrName.length > 0)
                            root.setFocusScreen(surf.scrName);
                        if (view.item)
                            view.item.focusField();
                    }

                    /**
                     * Despierta la calma con cualquier movimiento REAL (ENTRADA §6): patrón de
                     * `core/Island` — la primera lectura sólo guarda la referencia, porque
                     * `onPositionChanged` también dispara cuando el contenido se mueve bajo un
                     * cursor quieto. `Qt.NoButton` para no robar ningún clic de lo que hay encima.
                     */
                    MouseArea {
                        id: pointerArea
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.NoButton
                        property bool armed: false
                        property real lastX: -1
                        property real lastY: -1
                        onPositionChanged: (m) => {
                            // sólo un cambio REAL: Qt reenvía el hover en cada repintado con el ratón quieto
                            // (15G-2: la calma no llegaba con el cursor encima)
                            if (Math.abs(m.x - pointerArea.lastX) < 1 && Math.abs(m.y - pointerArea.lastY) < 1) return;
                            pointerArea.lastX = m.x; pointerArea.lastY = m.y;
                            if (!pointerArea.armed) { pointerArea.armed = true; return; }
                            root.touch();
                        }
                    }

                    /**
                     * Bloq Mayús / Bloq Num: se consulta AL SOLTAR (S8, INVESTIGACION §9 — al
                     * pulsar da el estado viejo en quien apaga). El resto de la navegación de
                     * teclado (Tab entre cápsula/música/energía, distribución en vivo) es S8/L6
                     * (PRUEBAS §7): aquí sólo lo imprescindible para que el lock sea seguro y usable.
                     */
                    Keys.onPressed: (e) => root.touch()
                    Keys.onReleased: (e) => {
                        root.touch();
                        if (e.key === Qt.Key_CapsLock || e.key === Qt.Key_NumLock)
                            root.refreshDevices();
                    }

                    Loader {
                        id: view
                        anchors.fill: parent
                        sourceComponent: LockBoardSurface {
                            context: root
                            s: Settings.uiScale
                            screenName: surf.scrName
                            hero: surf.hero
                            focused: frame.winActive
                            // la pantalla de antes de bloquear, desenfocada; sin ella, el respaldo opaco (no el wallpaper)
                            backdropSource: root.captureFor(surf.scrName)
                            backdropGeneration: root.captureGen
                            home: root.phase === "leaving" ? root.restTarget(surf.scrName) : root.snapshot(surf.scrName)
                        }
                    }
                }
            }
        }
    }

    /**
     * Bloqueo denegado o retirado sin pasar por `finishUnlock` (ESTADO §3, R2). `lockStateChanged`
     * llega DOS VECES con `locked: false` al soltar (S1): idempotente por `phase !== "unlocked"`.
     */
    Connections {
        target: wl
        function onLockStateChanged() {
            if (wl.locked || root.phase === "unlocked")
                return;
            console.warn("lock: WlSessionLock.locked se puso a false fuera de finishUnlock, fase era", root.phase);
            persist.locked = false;
            persist.reason = "";
            root.writeLockJson(false);
            Quickshell.watchFiles = true;
            root.phase = "unlocked";
            root.instant = false;
            root.homes = {};
            root.expectedScreens = [];
            root.reported = {};
            Lock.failed("denied");
        }
    }

    // ── energía: el fallo se enseña, no se traga (R12) ───────────────────────

    Connections {
        target: Power
        function onActionFailed(action, message) {
            if (root.phase === "unlocked")
                return;
            const verb = action === "reboot" ? "restart" : action === "shutdown" ? "shut down" : "suspend";
            root.powerError = "Couldn't " + verb + (message.length > 0 ? " — " + message : "");
        }
    }

    // ── distribución de teclado, Bloq Mayús, Bloq Num (ENTRADA §4-5) ─────────

    function refreshDevices() { devicesProbe.running = true; }

    Process {
        id: devicesProbe
        command: ["hyprctl", "-j", "devices"]
        stdout: StdioCollector { id: devicesOut }
        onExited: root.parseDevices(devicesOut.text)
    }

    function parseDevices(text) {
        let data = null;
        try { data = JSON.parse(text); } catch (e) { return; }
        const kbs = (data && data.keyboards) || [];
        let main = null;
        for (let i = 0; i < kbs.length; i++)
            if (kbs[i] && kbs[i].main) { main = kbs[i]; break; }
        if (!main)
            return;
        root.capsLock = !!main.capsLock;
        root.numLock = !!main.numLock;
        const layouts = String(main.layout || "").split(",").map(function (s) { return s.trim(); })
            .filter(function (s) { return s.length > 0; });
        root.layoutCount = layouts.length;
        // LK-14: el código sale de la distribución CONFIGURADA en el índice activo («us,es» → US / ES), no del
        // nombre largo (antes cualquier «English …», UK incluido, se leía como US)
        const idx = typeof main.active_layout_index === "number" ? main.active_layout_index : -1;
        root.layoutCode = idx >= 0 && idx < layouts.length ? layouts[idx].toUpperCase().slice(0, 3)
            : root.codeForLayout(String(main.active_keymap || ""));
    }

    function codeForLayout(name) {
        if (name.indexOf("English") >= 0) return "US";
        if (name.indexOf("Spanish") >= 0) return "ES";
        const letters = name.replace(/[^A-Za-z]/g, "").toUpperCase();
        return letters.slice(0, 3);
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (root.phase === "unlocked" || event.name !== "activelayout")
                return;
            // el evento sólo trae el nombre largo: se relee el índice (LK-14)
            root.refreshDevices();
        }
    }

    // ── `lock.json` (ESTADO §5) ───────────────────────────────────────────────

    readonly property string lockJsonPath: Settings.stateDir + "/lock.json"

    FileView {
        id: lockJsonFile
        path: root.lockJsonPath
        blockLoading: true
        blockWrites: true
        printErrors: false
    }

    function writeLockJson(locked) {
        const obj = locked
            ? { locked: true, since: root.since, reason: root.reason, failed: root.auth.failed || 0 }
            : { locked: false };
        lockJsonFile.setText(JSON.stringify(obj));
    }

    /** 0600 antes del primer uso: `FileView` crea a 0644 pero conserva el modo existente. */
    Process { id: permsCheckExists; command: ["test", "-e", root.lockJsonPath]
        onExited: (code) => { if (code === 0) permsChmod.running = true; else permsInstall.running = true; } }
    Process { id: permsChmod; command: ["chmod", "600", root.lockJsonPath] }
    Process { id: permsInstall; command: ["install", "-Dm600", "/dev/null", root.lockJsonPath] }

    // ── registro (mismo patrón que core/Screens) ──────────────────────────────

    Component.onCompleted: {
        permsCheckExists.running = true;
        Lock.register(root);
    }
    Component.onDestruction: Lock.unregister(root)
}
