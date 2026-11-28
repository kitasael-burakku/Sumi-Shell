import QtQuick
import "../components"
import "../services"
import "../theme"

/**
 * Composición visual compartida por el bloqueo y sus vistas previas. Recibe la fase
 * y el estado por el contexto, y sólo reporta cuándo termina cada transición.
 */
Item {
    id: root

    property var context
    property real s: 1
    property string screenName: ""
    property bool hero: true
    property string backdropSource: ""
    property int backdropGeneration: 0
    property real backdropDim: 0.62
    property real backdropBrightness: -0.25
    property bool focused: false
    property bool interactive: true
    /** Geometría del island (la usa la coreografía de la 15F). */
    property var home: ({ x: width / 2 - 72, y: 8, w: 144, h: 34, r: 16 })

    readonly property var auth: root.context ? root.context.auth : ({})
    readonly property string authState: root.auth.state || "idle"
    readonly property string phase: root.context ? root.context.phase : "locked"
    readonly property bool instant: root.context ? root.context.instant : false
    readonly property bool calm: root.context ? root.context.calm : false
    readonly property bool leaving: root.phase === "leaving"
    readonly property bool wantsOpaque: root.phase === "locked" || (root.instant && !root.leaving)

    // El centro aparece primero. Cada lateral entra hacia su sitio y sale hacia el centro.
    // La fase y el foco pertenecen al bloqueo, con independencia del movimiento.
    readonly property bool animatedEntry: root.phase === "entering" && !root.instant && !Motion.off
    property real veil: root.animatedEntry ? 0 : 1
    property real core: root.animatedEntry ? 0 : 1
    property real details: root.animatedEntry ? 0 : 1
    readonly property int detailDelay: Motion.still ? 0 : Math.round(Motion.lockOpen * 0.20)
    readonly property int coreMs: Math.round(Motion.lockOpen * (Motion.still ? 1 : 0.68))
    property bool started: false
    property bool enterReported: false
    property bool leaveReported: false
    readonly property bool secureOk: !root.context || root.context.secure !== false

    function finalState() {
        entryAnim.stop();
        root.veil = 1;
        root.core = 1;
        root.details = 1;
    }
    function maybeStart() {
        if (root.started || root.phase !== "entering" || !root.secureOk)
            return;
        root.started = true;
        if (root.animatedEntry) {
            entryAnim.start();
        } else {
            root.finalState();
            root.reportEnter();
        }
    }
    Component.onCompleted: {
        Qt.callLater(root.focusField);
        Qt.callLater(root.maybeStart);
    }
    onHeroChanged: if (root.hero && root.focused) Qt.callLater(root.focusField)
    onSecureOkChanged: root.maybeStart()

    onPhaseChanged: {
        if (root.phase === "leaving") {
            entryAnim.stop();
            if (Motion.off)
                root.reportLeave();
            else
                exitAnim.start();
        } else if (root.phase === "locked") {
            root.finalState();
        }
    }

    ParallelAnimation {
        id: entryAnim
        NumberAnimation { target: root; property: "veil"; to: 1; duration: Motion.lockOpen; easing.type: Easing.OutCubic }
        NumberAnimation { target: root; property: "core"; to: 1; duration: root.coreMs; easing.type: Easing.OutCubic }
        SequentialAnimation {
            PauseAnimation { duration: root.detailDelay }
            NumberAnimation {
                target: root; property: "details"; to: 1
                duration: Math.max(0, Motion.lockOpen - root.detailDelay)
                easing.type: Easing.OutCubic
            }
        }
        onFinished: root.reportEnter()
    }
    ParallelAnimation {
        id: exitAnim
        NumberAnimation { target: root; property: "veil"; to: 0; duration: Motion.lockClose; easing.type: Easing.InCubic }
        NumberAnimation { target: root; property: "core"; to: 0; duration: Motion.lockClose; easing.type: Easing.InCubic }
        NumberAnimation {
            target: root; property: "details"; to: 0
            duration: Math.round(Motion.lockClose * (Motion.still ? 1 : 0.85))
            easing.type: Easing.InCubic
        }
        onFinished: root.reportLeave()
    }
    function reportEnter() {
        if (root.enterReported || !root.context) return;
        root.enterReported = true;
        Qt.callLater(function () { root.context.enterDone(root.screenName); });
    }
    function reportLeave() {
        if (root.leaveReported || !root.context) return;
        root.leaveReported = true;
        Qt.callLater(function () { root.context.leaveDone(root.screenName); });
    }
    /** Para medir «cero animaciones en reposo». */
    readonly property bool animating: entryAnim.running || exitAnim.running

    // ── cuenta atrás de faillock: sólo corre mientras se ve ──────────────────
    property real nowSec: Date.now() / 1000
    readonly property string lockoutText: {
        // unlock_time = 0 (LK-04): no hay plazo que enseñar
        if ((root.auth.lockoutUntil || 0) < 0) return "";
        const left = Math.max(0, Math.round((root.auth.lockoutUntil || 0) - root.nowSec));
        return Math.floor(left / 60) + ":" + String(left % 60).padStart(2, "0");
    }
    Timer {
        interval: 1000
        repeat: true
        running: root.authState === "lockedOut" && root.hero && !root.calm && root.visible
        triggeredOnStart: true
        onTriggered: root.nowSec = Date.now() / 1000
    }

    // ── fallo: el canto del campo en `danger` 600 ms (el texto y el glifo son la otra señal) ──
    property bool failFlash: false
    Timer { id: failTimer; interval: 600; onTriggered: root.failFlash = false }
    Connections {
        target: root.context
        ignoreUnknownSignals: true
        function onFailedAttempt() { root.failFlash = true; failTimer.restart(); }
    }
    readonly property color fieldEdge: {
        if (root.leaving) return Theme.ok;
        if (root.failFlash) return Theme.danger;
        if (root.authState === "error") return Theme.warn;
        return root.focused ? Theme.focusRing : Theme.hair;
    }

    function focusField() {
        if (root.hero && root.interactive && !root.leaving)
            board.focusField();
    }

    // ── calma y despertar (15E; la lógica es de LockCalm, en quien sostiene el contrato) ──
    function activity() { if (root.context && root.context.touch) root.context.touch(); }
    /**
     * Al calmarse, el foco vuelve al campo (§9: «el foco lógico del campo no se destruye»): así la tecla
     * que despierta es texto y se conserva, y nunca activa un botón invisible (un Enter sobre la energía,
     * un Espacio sobre el transporte).
     */
    onCalmChanged: if (root.calm) root.focusField()
    onAuthStateChanged: {
        if (["failed", "error", "prompt", "lockedOut"].indexOf(root.authState) >= 0)
            Qt.callLater(root.focusField);
    }
    /** Un hold en curso suspende la calma (§9). */
    readonly property bool holding: powerCorner.holding
    onHoldingChanged: if (root.context && root.context.setHolding) root.context.setHolding(root.holding)

    /**
     * El puntero: movimiento REAL despierta (la primera lectura sólo arma: la superficie aparece bajo un
     * cursor quieto) y oculta el cursor a los 3 s quieto y en calma (LK-08). Pasivo: no roba nada a los
     * controles, que siguen poniendo su propio cursor.
     */
    property bool pointerArmed: false
    property bool cursorIdle: false
    readonly property bool cursorHidden: root.calm || root.cursorIdle
    // arranca ya: tras bloquear, el cursor se oculta aunque no se mueva el ratón
    Timer { id: cursorTimer; interval: 3000; running: true; onTriggered: root.cursorIdle = true }
    /**
     * El cursor lo pone una MouseArea de fondo, no el HoverHandler: el cursorShape de un handler sólo se
     * aplica con el siguiente evento del puntero, y un ratón QUIETO no manda ninguno (medido en 15E:
     * seguía visible a los 3,8 s). La MouseArea no acepta botones: todo le pasa a los controles.
     */
    MouseArea {
        anchors.fill: parent
        z: -1
        acceptedButtons: Qt.NoButton
        cursorShape: root.cursorHidden ? Qt.BlankCursor : Qt.ArrowCursor
    }
    /**
     * Sólo cuenta un CAMBIO de posición: con el puntero encima, Qt reenvía un hover en cada fotograma que se
     * repinta (métricas, hora) aunque el ratón esté quieto. Medido en la 15G-2: sin esta comparación la calma
     * no llegaba nunca con el cursor sobre el panel.
     */
    property real lastPx: -1
    property real lastPy: -1
    HoverHandler {
        id: hover
        onPointChanged: {
            if (!hover.hovered) return;
            const p = hover.point.position;
            if (Math.abs(p.x - root.lastPx) < 1 && Math.abs(p.y - root.lastPy) < 1) return;
            root.lastPx = p.x; root.lastPy = p.y;
            root.cursorIdle = false;
            cursorTimer.restart();
            if (!root.pointerArmed) { root.pointerArmed = true; return; }
            root.activity();
        }
    }
    /** Un clic o una pulsación en cualquier sitio (no la toma: los controles siguen recibiéndola). */
    PointHandler {
        acceptedButtons: Qt.AllButtons
        onActiveChanged: if (active) root.activity()
    }
    WheelHandler { onWheel: root.activity() }

    // ── teclado (15C, futurelocksurface §9 «Teclado y ratón», LK-01) ──────────
    /**
     * El recorrido es EXPLÍCITO y no el orden del árbol (que pondría la música antes que el campo):
     * campo → Unlock → transporte → privacidad → notificaciones (sus «Show more» y «Expand message»)
     * → energía, y vuelta. Se recoge en cada paso lo que se ve y está habilitado y lleva la marca
     * `lockFocusable`: un control que aparece o desaparece (reproductor, mensajes) entra o sale solo.
     */
    function focusChain() {
        const out = [];
        const roots = board.focusRoots().concat([power]);
        for (let i = 0; i < roots.length; i++)
            root.collect(roots[i], out);
        return out;
    }
    function collect(item, out) {
        if (!item || !item.visible || item.enabled === false)
            return;
        if (item.lockFocusable === true)
            out.push(item);
        const kids = item.children || [];
        for (let i = 0; i < kids.length; i++)
            root.collect(kids[i], out);
    }
    /** El control del recorrido que tiene el foco (o que lo contiene: el TextInput está dentro del campo). */
    readonly property Item focusItem: Window.activeFocusItem
    function owning(item) {
        for (let it = item; it; it = it.parent)
            if (it.lockFocusable !== undefined && it.lockFocusName !== undefined)
                return it;
        return null;
    }
    /** Para las pruebas y el nombre accesible: «Password», «Show more · Discord», «Hold to shut down». */
    readonly property string focusName: { const o = root.owning(root.focusItem); return o ? o.lockFocusName : ""; }

    /** Para las pruebas: lo que enseña la lista frente a lo vivo (15D). */
    readonly property var notifsView: {
        const n = board.notifsRoot();
        return n ? { pending: n.pending, reading: n.reading, shown: n.groups.map(function (g) { return g.name; }),
                     count: n.count } : null;
    }
    /** Lo que hace «New notifications». */
    function adoptNotifications() { const n = board.notifsRoot(); if (n) n.adopt(); }

    function stepFocus(dir) {
        const chain = root.focusChain();
        if (chain.length === 0)
            return;
        const cur = chain.indexOf(root.owning(root.focusItem));
        const next = cur < 0 ? (dir > 0 ? 0 : chain.length - 1) : (cur + dir + chain.length) % chain.length;
        const it = chain[next];
        if (it.lockTakeFocus) it.lockTakeFocus(); else it.forceActiveFocus(dir > 0 ? Qt.TabFocusReason : Qt.BacktabFocusReason);
        root.reveal(it);
    }
    /** Si el control está dentro de una región con scroll, se desplaza lo justo para verlo. */
    function reveal(item) {
        for (let f = item.parent; f; f = f.parent) {
            // el primero que DESBORDA: en estrecho las notificaciones tienen un Flickable sin scroll
            if (f.contentItem !== undefined && f.contentY !== undefined && f.contentHeight !== undefined
                    && f.contentHeight > f.height + 1) {
                const p = item.mapToItem(f.contentItem, 0, 0);
                const pad = Metrics.sp2 * root.s;
                if (p.y - pad < f.contentY)
                    f.contentY = Math.max(0, p.y - pad);
                else if (p.y + item.height + pad > f.contentY + f.height)
                    f.contentY = Math.min(Math.max(0, f.contentHeight - f.height), p.y + item.height + pad - f.height);
                return;
            }
        }
    }

    /**
     * Lo que ningún control consume sube hasta aquí: Tab / Mayús+Tab recorren; Esc devuelve el foco al
     * campo (nunca cierra el Lock); y una tecla imprimible con el foco en un botón va al campo, al final
     * de lo escrito (no se pierde). Enter y Espacio los consume el botón enfocado.
     */
    Keys.onPressed: (e) => {
        if (!root.hero || !root.interactive || !root.context)
            return;
        if (root.leaving) { e.accepted = true; return; }
        const mods = e.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier);
        if (e.key === Qt.Key_Backtab || (e.key === Qt.Key_Tab && (e.modifiers & Qt.ShiftModifier))) {
            root.stepFocus(-1); e.accepted = true;
        } else if (e.key === Qt.Key_Tab && !mods) {
            root.stepFocus(1); e.accepted = true;
        } else if (e.key === Qt.Key_Escape) {
            board.focusField(); e.accepted = true;
        } else if (!mods && e.text.length === 1 && e.text >= " " && e.text !== "\x7f") {
            // Supr trae \x7f en event.text (memoria del proyecto): no es texto
            root.context.setBuffer((root.context.buffer || "") + e.text);
            board.focusField();
            e.accepted = true;
        }
        if (e.accepted && root.context.touch)
            root.context.touch();
    }

    // ── composición ─────────────────────────────────────────────────────────
    LockBackdrop {
        anchors.fill: parent
        s: root.s
        source: root.backdropSource
        generation: root.backdropGeneration
        dim: root.backdropDim
        brightness: root.backdropBrightness
        opacity: root.veil
    }

    /**
     * La energía va DEBAJO del panel, centrada y mediana (2026-10-01, pedido del usuario; antes abajo a la
     * derecha, pequeña). El panel y la energía se centran juntos en el alto disponible; el panel cede a la
     * energía su alto más un hueco (en estrecho el panel ocupa el resto, sin taparla: LK-07).
     */
    readonly property real margin: Metrics.lockMargin * root.s
    readonly property real powerGap: Metrics.sp5 * root.s
    readonly property real stackH: board.height + root.powerGap + power.height
    readonly property real areaH: root.height - root.margin * 2 - root.powerGap - power.height

    LockBoard {
        id: board
        visible: root.hero
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.round(root.margin + Math.max(0, (root.height - root.margin * 2 - root.stackH) / 2))
        availW: root.width - root.margin * 2
        availH: root.areaH
        context: root.context
        s: root.s
        focused: root.focused
        calm: root.calm
        lockoutText: root.lockoutText
        fieldEdge: root.fieldEdge
        owner: root.interactive && root.hero && root.focused
        accepted: root.leaving
        centerProgress: root.core
        around: root.details
        sideTravel: Motion.still ? 0 : Metrics.sp5 * root.s * (1 - root.details)
        onStep: (dir) => root.stepFocus(dir)
        // el control enfocado se fue con la lista nueva: al primero que quede ahí, o al campo (§8)
        onInteracted: root.activity()
        onNotifsFocusLost: {
            const left = [];
            root.collect(board.notifsRoot(), left);
            if (left.length > 0) { left[0].forceActiveFocus(); root.reveal(left[0]); }
            else board.focusField();
        }
    }
    readonly property bool narrow: board.narrow

    // pantallas sin foco: fondo, hora y fecha
    Column {
        visible: !root.hero
        anchors.centerIn: parent
        spacing: Metrics.sp2 * root.s
        opacity: root.core
        Text {
            id: nhClock
            anchors.horizontalCenter: parent.horizontalCenter
            text: Clock.time
            color: Theme.fg
            font.family: Typography.uiChosen
            font.weight: Typography.wStrong
            font.pixelSize: Typography.lockBoardTime * root.s
            font.features: { "tnum": 1 }
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Clock.longDate.toUpperCase()
            color: Theme.fgVariant
            font.family: Typography.uiChosen
            font.weight: Typography.wMedium
            font.pixelSize: Typography.lockDate * root.s
            font.letterSpacing: Typography.tracking * root.s
        }
    }

    // energía: bajo el panel, centrada, con su propio mensaje (LK-07: no tapa la autenticación)
    Column {
        id: power
        anchors.horizontalCenter: parent.horizontalCenter
        y: board.y + board.height + root.powerGap
        spacing: Metrics.sp1 * root.s
        visible: root.hero
        // con el popup, y fuera en calma
        opacity: root.calm ? 0 : root.details
        Behavior on opacity {
            enabled: !entryAnim.running && !exitAnim.running
            NumberAnimation { duration: root.calm && !Motion.off ? Motion.lockCalmFade : Motion.fast; easing.type: Easing.InOutCubic }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: text.length > 0
            text: root.context ? (root.context.powerError || "") : ""
            color: Theme.danger
            font.family: Typography.uiChosen
            font.weight: Typography.wMedium
            font.pixelSize: Typography.caption * root.s
            Accessible.role: Accessible.AlertMessage
            Accessible.name: text
        }
        PowerCorner {
            id: powerCorner
            anchors.horizontalCenter: parent.horizontalCenter
            context: root.context
            s: root.s
            centered: true
            buttonSize: 44
            locked: root.authState === "checking" || root.leaving
            tabStops: false
        }
    }

    /**
     * En calma, el clic que despierta es SÓLO eso: se lo traga esta capa, y ningún control que vaya a
     * aparecer bajo el cursor se activa (§9). La rueda también despierta. El cursor, oculto.
     */
    MouseArea {
        anchors.fill: parent
        z: 1000
        enabled: root.calm
        visible: root.calm
        acceptedButtons: Qt.AllButtons
        cursorShape: Qt.BlankCursor
        onPressed: (m) => { m.accepted = true; root.activity(); }
        onWheel: (w) => { w.accepted = true; root.activity(); }
    }
}
