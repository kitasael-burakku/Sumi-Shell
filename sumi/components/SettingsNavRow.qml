pragma ComponentBehavior: Bound
import QtQuick
import "../theme"

/** Una entrada del índice de Settings. El foco y la página abierta son independientes. */
Item {
    id: row
    required property string label
    property string glyph: ""
    property real s: 1
    property bool selected: false
    property bool expanded: false
    property bool focused: false
    readonly property bool heading: glyph !== ""
    readonly property var acc: Theme.fam(palette.accent)
    signal activated()

    height: Math.max((heading ? 40 : 31) * s, title.implicitHeight + 10 * s)
    Accessible.role: heading ? Accessible.Button : Accessible.PageTab
    Accessible.name: label
    Accessible.expandable: heading
    Accessible.expanded: heading && expanded
    Accessible.selected: selected
    Accessible.focusable: true
    Accessible.focused: focused
    Accessible.onPressAction: row.activated()

    Rectangle {
        anchors.fill: parent
        anchors.topMargin: row.s
        anchors.bottomMargin: row.s
        radius: Metrics.r(8) * row.s
        color: Theme.controlBg("transparent", hit.containsMouse, hit.pressed && hit.containsMouse, row.selected, row.acc)
        border.width: row.focused ? Metrics.focusWidth * row.s : 0
        border.color: row.acc.ring
        Behavior on color { ColorAnimation { duration: Motion.fast } }
    }
    Icon {
        visible: row.heading
        anchors.left: parent.left
        anchors.leftMargin: 10 * row.s
        anchors.verticalCenter: parent.verticalCenter
        name: row.glyph
        size: 15 * row.s
        color: row.acc.text
    }
    Rectangle {
        visible: !row.heading && row.selected && !Style.terminal
        x: 12 * row.s
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(2, 3 * row.s)
        height: 14 * row.s
        radius: Metrics.pill(width)
        color: row.acc.fill
    }
    Text {
        visible: !row.heading && row.selected && Style.terminal
        x: 10 * row.s
        anchors.verticalCenter: parent.verticalCenter
        text: ">"
        font.family: Typography.mono
        font.pixelSize: Typography.body * row.s
        color: row.acc.text
    }
    Text {
        id: title
        anchors.left: parent.left
        anchors.leftMargin: (row.heading ? 34 : 26) * row.s
        anchors.right: parent.right
        anchors.rightMargin: (row.heading ? 29 : 8) * row.s
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        text: row.label
        font.family: Typography.ui
        font.pixelSize: Typography.body * row.s
        font.weight: row.heading || row.selected ? Typography.wStrong : Typography.wNormal
        color: row.heading || row.selected ? Theme.fg : Theme.fgVariant
    }
    Icon {
        visible: row.heading && !Style.terminal
        anchors.right: parent.right
        anchors.rightMargin: 10 * row.s
        anchors.verticalCenter: parent.verticalCenter
        name: "chevron-right"
        size: 12 * row.s
        color: row.expanded ? row.acc.text : Theme.fgVariant
        rotation: row.expanded ? 90 : 0
        Behavior on rotation { enabled: !Motion.still; NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic } }
    }
    Text {
        visible: row.heading && Style.terminal
        anchors.right: parent.right
        anchors.rightMargin: 8 * row.s
        anchors.verticalCenter: parent.verticalCenter
        text: row.expanded ? "[-]" : "[+]"
        color: row.acc.text
        font.family: Typography.mono
        font.pixelSize: Typography.caption * row.s
    }
    MouseArea {
        id: hit
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: row.activated()
    }
}
