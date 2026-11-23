import QtQuick
import "../theme"

/** On/off switch: the knob slides, the track takes the accent when on. */
Rectangle {
    id: root

    /** La familia de acento de la zona (Theme.fam; lib/accent-zones.js). */
    readonly property var acc: Theme.fam(palette.accent)
    property real s: 1
    property bool on: false
    /** El foco de teclado lo lleva quien contiene el Toggle; esto sólo lo pinta. */
    property bool focused: false
    /** Nombre accesible: el de la fila que lo lleva. */
    property string label: ""
    signal toggled()
    /** Dónde está el pomo ahora; para las pruebas de movimiento (preview-components). */
    readonly property real knobX: knob.x

    Accessible.role: Accessible.CheckBox
    Accessible.name: root.label
    Accessible.checkable: true
    Accessible.checked: root.on
    Accessible.onToggleAction: if (root.enabled) root.toggled()
    Accessible.onPressAction: if (root.enabled) root.toggled()

    opacity: root.enabled ? 1 : Theme.disabledOpacity

    /*
     * Terminal (ADR-34): una caja `[■ ON ]` / `[OFF ■]`, más ancha para que quepa el estado escrito; mismo alto, misma
     * zona de clic. La pista apagada es hueca (sólo el marco); encendida, del acento, como en soft.
     */
    width: (Style.terminal ? 42 : 30) * s
    height: 17 * s
    radius: Metrics.pill(height)
    readonly property bool pointed: root.enabled && area.containsMouse
    readonly property color fill: root.on ? Theme.activeBg(pointed, pointed && area.pressed, root.acc)
        : Theme.controlBg(Style.terminal ? "transparent" : Theme.tileBg, pointed, pointed && area.pressed, false, root.acc)
    // El texto sigue al estado de la pista, también durante la pulsación.
    readonly property color ink: root.on ? Theme.activeText(fill, root.acc) : Theme.fgVariant
    color: fill
    border.width: root.on ? 0 : 1
    border.color: Style.terminal ? root.acc.frame : Theme.hair
    Behavior on color { ColorAnimation { duration: Motion.fast } }

    /** Anillo de foco por fuera: dentro se perdería sobre la pista encendida (mismo color). */
    Rectangle {
        anchors.fill: parent
        anchors.margins: -(Metrics.focusGap + Metrics.focusWidth) * root.s
        radius: Metrics.pill(height)
        color: "transparent"
        visible: root.enabled && root.focused
        border.width: Metrics.focusWidth * root.s
        border.color: root.acc.ring
    }

    Rectangle {
        id: knob
        anchors.verticalCenter: parent.verticalCenter
        width: 11 * root.s
        height: 11 * root.s
        radius: Metrics.pill(width)
        color: root.ink
        x: knobSpring.value
        SpringValue { id: knobSpring; target: root.on ? root.width - knob.width - 3 * root.s : 3 * root.s; soft: true }
        Behavior on color { ColorAnimation { duration: Motion.fast } }
    }

    /** El estado escrito de terminal, al otro lado del bloque. Con soft no existe. */
    Loader {
        objectName: "styleMarks"
        active: Style.terminal
        anchors.verticalCenter: parent.verticalCenter
        x: root.on ? 4 * root.s : root.width - width - 4 * root.s
        sourceComponent: Text {
            text: root.on ? "ON" : "OFF"
            color: root.ink
            font.family: Typography.mono
            font.pixelSize: 9 * root.s
            font.weight: Typography.wStrong
        }
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        // Objetivo de clic de al menos `hitMin` de alto (DESIGN §5); antes medía 38 × 25.
        anchors.margins: -Math.max(4, (Metrics.hitMin - 17) / 2) * root.s
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggled()
    }
}
