import QtQuick
import "../theme"
import "../services"

/** El contorno del foco del teclado (DESIGN §5: foco = contorno), sólo tras usar el teclado. */
Rectangle {
    property bool on: false
    property real s: 1
    anchors.fill: parent
    anchors.margins: -4 * s
    radius: Metrics.r(8) * s
    color: "transparent"
    border.width: Metrics.focusWidth * s
    border.color: Theme.fam(palette.accent).selBorder
    visible: on && AudioUi.keyNav
}
