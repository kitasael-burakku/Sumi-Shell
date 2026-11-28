import QtQuick
import "../theme"

// Realce visual. La zona de clic y el anillo de teclado conservan su tamaño.
Rectangle {
    id: plate

    property real s: 1
    property bool hovered: false
    property bool down: false
    property bool focused: false
    property bool selected: false
    property color rest: "transparent"
    property color rim: "transparent"

    color: Theme.controlBg(plate.rest, plate.hovered, plate.down, plate.selected || plate.focused, null)
    border.width: plate.focused ? Metrics.focusWidth * plate.s : plate.rim.a > 0 ? 1 : 0
    border.color: plate.focused ? Theme.focusRing : plate.rim
    scale: plate.down && !plate.focused && !Motion.still ? 0.94 : 1

    Behavior on color { ColorAnimation { duration: Motion.fast; easing.type: Easing.OutCubic } }
    Behavior on scale {
        enabled: !Motion.still
        NumberAnimation { duration: plate.down ? Motion.snap : Motion.fast; easing.type: Easing.OutCubic }
    }
}
