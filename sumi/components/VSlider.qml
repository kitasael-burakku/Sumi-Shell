import QtQuick
import "../theme"

/**
 * Deslizador VERTICAL de 0 (abajo) a 1 (arriba), para el Centro de control (rediseño del 2026-11-15).
 *
 * Mismas reglas que `Slider` (el horizontal, compartido por Mixer y Audio, que no se toca):
 *  - `value` no se escribe solo: arrastrar, pulsar o la rueda emiten `moved(v)` y quien manda decide. Lo pintado es
 *    siempre lo que el servicio confirma.
 *  - La animación vive en la FRACCIÓN (`shown`), no en los píxeles (ADR-25): la altura la decide el panel, que se anima.
 *  - Terminal (ADR-34): la pista son segmentos fijos (su número no sigue a la altura) y el pomo es un cursor; nacen sin
 *    radio y no lo cambian nunca (`Style.squareR`).
 *  - `available: false` (sin control, D3): la pista queda atenuada, sin relleno ni pomo, y no acepta nada.
 */
Item {
    id: root

    /** La familia de acento de la zona (Theme.fam; lib/accent-zones.js). */
    readonly property var acc: Theme.fam(palette.accent)
    property real value: 0
    property bool available: true
    property bool muted: false
    property real s: 1
    property real step: 0.02
    property color tint: root.acc.fill
    property bool focused: false
    property bool ring: true
    property string label: ""
    signal moved(real value)

    Accessible.role: Accessible.Slider
    Accessible.name: root.label
    Accessible.focusable: root.available
    Accessible.focused: root.focused
    Accessible.description: !root.available ? "Unavailable" : Math.round(root.value * 100) + " percent"
    Accessible.onIncreaseAction: root.adjust(1)
    Accessible.onDecreaseAction: root.adjust(-1)

    function adjust(direction) {
        if (direction && root.enabled && root.available)
            root.moved(Math.max(0, Math.min(1, root.value + direction * root.step)));
    }

    implicitWidth: 18 * root.s

    /**
     * Medidas ENTERAS y de la misma paridad (2026-11-15, captura del autor: «el pomo está descentrado de la línea»).
     * A escala 0,9 el carril medía 5,4 px y el pomo 12,6: centrados los dos, Qt redondeaba distinto cada borde y el
     * pomo quedaba 1 px a un lado del carril (medido en la captura). Con anchos enteros cuya diferencia es par, los dos
     * comparten el mismo eje al píxel.
     */
    readonly property int trackW: Math.max(4, Math.round(6 * root.s))
    readonly property int knobD: root.trackW + 2 * Math.max(2, Math.round((14 * root.s - root.trackW) / 2))
    readonly property real knobR: root.knobD / 2
    readonly property int inset: Math.ceil(root.knobR * 1.15)

    property real shown: root.available ? Math.max(0, Math.min(1, root.value)) : 0
    Behavior on shown {
        enabled: !area.pressed
        NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic }
    }

    Rectangle {
        id: track
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: root.inset
        anchors.bottomMargin: root.inset
        x: Math.round((root.width - root.trackW) / 2)
        width: root.trackW
        radius: Metrics.pill(width)
        color: Style.terminal ? "transparent" : root.acc.track
        opacity: root.available ? 1 : 0.5

        Rectangle {
            id: fill
            anchors.bottom: parent.bottom
            width: parent.width
            height: root.shown * parent.height
            radius: parent.radius
            visible: !Style.terminal && root.available
            color: root.muted ? Theme.fgVariant : root.tint
            opacity: root.muted ? 0.45 : 1
            Behavior on color { ColorAnimation { duration: Motion.fast } }
        }
    }

    // Terminal: segmentos de abajo arriba; uno se enciende si su centro queda por debajo del valor.
    Item {
        id: segs
        objectName: "styleMarks"
        anchors.fill: track
        visible: Style.terminal
        opacity: !root.available ? 0.5 : root.muted ? 0.45 : 1
        readonly property int segN: 14
        readonly property real gap: Math.max(1, Math.round(2 * root.s))
        readonly property real segH: (height - gap * (segN - 1)) / segN
        Repeater {
            model: Style.terminal ? segs.segN : 0
            Rectangle {
                required property int index
                // bordes en píxel entero, contados desde abajo (el segmento 0 es el de abajo)
                readonly property real lowEdge: Math.round(index * (segs.segH + segs.gap))
                readonly property real highEdge: Math.round((index + 1) * (segs.segH + segs.gap) - segs.gap)
                y: segs.height - highEdge
                height: highEdge - lowEdge
                width: segs.width
                color: root.available && (index + 0.5) / segs.segN <= root.shown
                       ? (root.muted ? Theme.fgVariant : root.tint) : root.acc.track
            }
        }
    }

    Rectangle {
        id: knob
        visible: root.available
        x: track.x - (root.knobD - root.trackW) / 2
        y: Math.round(track.y + track.height - fill.height - height / 2)
        // terminal: un cursor horizontal en vez del pomo redondo
        width: root.knobD
        height: Style.terminal ? Math.max(2, Math.round(3 * root.s)) : root.knobD
        radius: Style.terminal ? Style.squareR : root.knobR
        color: root.muted ? Theme.fgVariant : root.tint
        border.width: Style.terminal ? 0 : 2
        border.color: Theme.surface
        scale: scaleSpring.value
        SpringValue { id: scaleSpring; target: area.containsMouse || area.pressed ? 1.15 : 1; soft: true; epsilon: 0.004 }
    }

    MouseArea {
        id: area
        anchors.fill: parent
        anchors.margins: -4 * root.s
        enabled: root.available
        hoverEnabled: true
        cursorShape: root.available ? Qt.PointingHandCursor : Qt.ArrowCursor

        function emitAt(py) {
            const h = track.height;
            if (h <= 0) return;
            const fromTop = py + area.y - track.y;
            root.moved(Math.max(0, Math.min(1, 1 - fromTop / h)));
        }
        onPressed: (mouse) => area.emitAt(mouse.y)
        onPositionChanged: (mouse) => { if (area.pressed) area.emitAt(mouse.y); }
        onWheel: (wheel) => {
            if (!wheel.angleDelta.y) { wheel.accepted = false; return; }
            root.adjust(Math.sign(wheel.angleDelta.y));
        }
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: -(Metrics.focusGap + Metrics.focusWidth) * root.s
        radius: Metrics.pill(width)
        color: "transparent"
        visible: root.focused && root.ring
        border.width: Metrics.focusWidth * root.s
        border.color: root.acc.ring
    }
}
