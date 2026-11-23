import QtQuick
import "../theme"

/**
 * Una acción que sólo dispara MANTENIENDO pulsado (docs/lock/COMPONENTES.md §4).
 *
 * Para lo peligroso y raro: apagar, reiniciar o suspender desde la pantalla de
 * bloqueo, donde no se pide contraseña (decisión del usuario, docs/lock/ENTREVISTA.md
 * preguntas 8 y 13). Un clic suelto no hace nada salvo pedir que se enseñe la
 * pista; hay que sostener `holdMs` para que dispare.
 *
 * El relleno es PROGRESO, no desplazamiento: crece lineal de 0 a 1 mientras se
 * sostiene y, si se suelta antes, se vacía en 180 ms. Con reduce motion se queda
 * igual (ANIMACIONES §11): quitarlo dejaría el botón sin decir cuánto falta.
 *
 * El teclado lo maneja quien tenga el foco: llama a `pressKey()` al pulsar `⏎` y a
 * `releaseKey()` al soltarlo, y descarta él la autorrepetición.
 *
 * La pista NO la pinta el botón: la esquina de energía tiene tres y una sola línea
 * de pista para todos (`hintVisible` + `label`), para que no se pisen.
 */
Item {
    id: root

    /** La familia de acento de la zona (Theme.fam; lib/accent-zones.js). */
    readonly property var acc: Theme.fam(palette.accent)
    property real s: 1
    property string glyph: ""
    /** La pista: «Hold to shut down». */
    property string label: ""
    property int holdMs: Motion.holdMs
    /** `normal` · `danger`: el color del relleno. */
    property string tone: "normal"

    signal fired()

    // 16A-2: sin onPressAction a propósito — la acción exige sostener (LK-12), también para un lector
    Accessible.role: Accessible.Button
    Accessible.name: root.label
    Accessible.description: "Hold to confirm"
    Accessible.focusable: root.enabled

    /** 0 → 1 mientras se sostiene. */
    property real fill: 0
    readonly property bool holding: fillAnim.running
    /** Un clic suelto enciende la pista un momento. */
    property bool hinting: false
    readonly property bool hovered: mouse.containsMouse
    readonly property bool hintVisible: root.enabled && (root.hinting || root.holding || root.activeFocus || root.hovered)

    readonly property color toneColor: root.tone === "danger" ? Theme.danger : root.acc.fill

    /** Diámetro lógico (32 en las esquinas; el Lock pone la energía mediana bajo el panel, 2026-10-01). */
    property real diameter: 32
    implicitWidth: root.diameter * root.s
    implicitHeight: root.diameter * root.s
    /**
     * En la cadena de Tab de Qt. El Lock del rediseño lo apaga: su recorrido es explícito (15C) y la cadena
     * de Qt, que actúa ANTES de que la tecla suba a la superficie, iría en el orden del árbol.
     */
    property bool tabStop: true
    activeFocusOnTab: root.enabled && root.tabStop
    /** El recorrido de teclado del Lock (fase 15) lo recoge por esta marca. */
    readonly property bool lockFocusable: root.enabled
    readonly property string lockFocusName: root.label

    /**
     * Cada pulsación empieza DE CERO (fase 15, LK-12, futurelocksurface §9): antes retomaba el relleno
     * que aún se vaciaba y una segunda pulsación disparaba a ~440 ms.
     */
    function press() {
        if (!root.enabled || root.holding)
            return;
        drainAnim.stop();
        root.hinting = false;
        root.fill = 0;
        fillAnim.duration = root.holdMs;
        fillAnim.start();
    }

    /** Se abandona el intento sin disparar: foco perdido, oculto, deshabilitado (LK-12). */
    function cancel() {
        if (!root.holding)
            return;
        fillAnim.stop();
        drainAnim.start();
    }

    function release() {
        if (!root.holding)
            return;
        fillAnim.stop();
        if (root.fill < 1) {
            drainAnim.start();
            root.hinting = true;
            hintTimer.restart();
        }
    }

    property bool keyHolding: false
    function pressKey() { root.keyHolding = true; root.press(); }
    function releaseKey() { root.keyHolding = false; root.release(); }

    /** El foco se fue a mitad de un hold de teclado: la tecla ya no llegará aquí al soltarse. */
    onActiveFocusChanged: if (!root.activeFocus && root.keyHolding) { root.keyHolding = false; root.cancel(); }
    /** Oculto (calma, otra pantalla con el foco, el panel se retira): nunca dispara a ciegas. */
    onVisibleChanged: if (!root.visible) root.cancel()

    onEnabledChanged: if (!root.enabled) {
        fillAnim.stop();
        drainAnim.stop();
        root.fill = 0;
    }

    NumberAnimation {
        id: fillAnim
        target: root
        property: "fill"
        to: 1
        easing.type: Easing.Linear
        onFinished: if (root.fill >= 1) {
            root.fill = 0;
            root.fired();
        }
    }

    NumberAnimation {
        id: drainAnim
        target: root
        property: "fill"
        to: 0
        duration: 180
        easing.type: Easing.OutCubic
    }

    Timer {
        id: hintTimer
        interval: 1600
        onTriggered: root.hinting = false
    }

    /** Fondo y anillo de foco: el `selBorder` sobre `selBg` de todo el shell. */
    Rectangle {
        anchors.fill: parent
        radius: Metrics.pill(width)
        color: Theme.controlBg(Theme.tileBg, root.hovered && root.enabled, root.holding || root.keyHolding, false, root.acc)
        border.width: root.activeFocus ? 1 : 0
        border.color: root.acc.ring
        opacity: root.enabled ? 1 : 0.45
    }

    /** El relleno: un disco que crece desde el centro con el progreso. */
    Rectangle {
        anchors.centerIn: parent
        width: parent.width
        height: parent.height
        radius: Metrics.pill(width)
        scale: root.fill
        visible: root.fill > 0
        color: Qt.alpha(root.toneColor, 0.35)
        border.width: 1
        border.color: Qt.alpha(root.toneColor, 0.8)
    }

    Icon {
        anchors.centerIn: parent
        name: root.glyph
        size: Math.round(root.diameter * 0.47) * root.s
        color: root.fill > 0 ? root.toneColor : Theme.fgVariant
        opacity: root.enabled ? 1 : 0.45
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        enabled: root.enabled
        cursorShape: Qt.PointingHandCursor
        onPressed: root.press()
        onReleased: root.release()
        onCanceled: root.release()
    }

    Keys.onPressed: (e) => {
        if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) {
            if (!e.isAutoRepeat)
                root.pressKey();
            e.accepted = true;
        }
    }
    Keys.onReleased: (e) => {
        if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) {
            if (!e.isAutoRepeat)
                root.releaseKey();
            e.accepted = true;
        }
    }
}
