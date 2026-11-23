import QtQuick
import "../theme"

/**
 * Botón de sólo glifo (rediseño del Centro de control, 2026-11-15): Settings `⚙` y Clear all `≡` en rojo.
 *
 * El nombre accesible es obligatorio (`label`): el glifo no se lee. `danger` lo pinta en rojo (Clear all del boceto).
 * Zona de clic de `Metrics.hitMin`; el foco de teclado lo lleva quien lo contiene. En terminal el marco es recto
 * (tokens de Metrics) y no hay más diferencia.
 */
Item {
    id: btn

    /** La familia de acento de la zona (Theme.fam; lib/accent-zones.js). */
    readonly property var acc: Theme.fam(palette.accent)
    property real s: 1
    property string glyph: ""
    property string label: ""
    property bool danger: false
    property bool focused: false
    property bool enabled: true
    property real glyphSize: 16
    signal triggered()

    implicitWidth: Metrics.hitMin * btn.s
    implicitHeight: Metrics.hitMin * btn.s
    Accessible.role: Accessible.Button
    Accessible.name: btn.label
    Accessible.focusable: btn.enabled
    Accessible.focused: btn.focused
    Accessible.onPressAction: if (btn.enabled) btn.triggered()

    readonly property color ink: !btn.enabled ? Theme.disabledFg
        : btn.danger ? Theme.dangerText : area.containsMouse ? Theme.fg : Theme.fgVariant

    Rectangle {
        anchors.fill: parent
        anchors.margins: 2 * btn.s
        radius: Metrics.rSm * btn.s
        color: !btn.enabled || !area.containsMouse ? "transparent"
             : area.pressed ? Theme.pressedBg : btn.danger ? Theme.errorBg : Theme.hoverBg
        border.width: !btn.enabled ? 0 : btn.focused ? Metrics.focusWidth : Style.terminal ? 1 : 0
        border.color: btn.focused ? btn.acc.ring : Qt.alpha(btn.ink, 0.3)
        Behavior on color { ColorAnimation { duration: Motion.fast } }
    }
    Icon {
        x: Math.round((parent.width - width) / 2); y: Math.round((parent.height - height) / 2)
        name: btn.glyph
        size: btn.glyphSize * btn.s
        color: btn.ink
    }
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        enabled: btn.enabled
        cursorShape: Qt.PointingHandCursor
        onClicked: btn.triggered()
    }
}
