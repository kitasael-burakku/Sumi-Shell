import QtQuick
import "../theme"
import "../components"

/** Una fila de calendario en Accounts & sync (2026-10-28): color, nombre, detalle y visibilidad. */
Item {
    id: root

    property real s: 1
    property string name: ""
    property string color_: ""
    property string detail: ""
    property bool shown: true
    signal toggled()

    implicitHeight: Math.max(Metrics.hitMin * root.s, texts.implicitHeight + 6 * root.s)
    Accessible.role: Accessible.CheckBox
    Accessible.name: root.name
    Accessible.description: root.detail
    Accessible.checked: root.shown

    Rectangle {
        id: dot
        anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
        width: 10 * root.s; height: width; radius: Metrics.pill(width)
        color: root.color_.length > 0 ? root.color_ : Theme.fgVariant
        opacity: root.shown ? 1 : 0.35
    }
    Column {
        id: texts
        anchors.left: dot.right; anchors.leftMargin: 10 * root.s
        anchors.right: toggle.left; anchors.rightMargin: 10 * root.s
        anchors.verticalCenter: parent.verticalCenter
        spacing: 1 * root.s
        Text {
            width: parent.width
            text: root.name
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.shown ? Theme.fg : Theme.fgVariant
            font.family: Typography.ui; font.pixelSize: Typography.label * root.s
        }
        Text {
            width: parent.width
            visible: root.detail.length > 0
            text: root.detail
            elide: Text.ElideRight
            color: Theme.outlineText
            font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
        }
    }
    Toggle {
        id: toggle
        anchors.right: parent.right; anchors.rightMargin: 4 * root.s; anchors.verticalCenter: parent.verticalCenter
        s: root.s; on: root.shown; label: "Show " + root.name
        onToggled: root.toggled()
    }
}
