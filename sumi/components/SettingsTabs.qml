pragma ComponentBehavior: Bound
import QtQuick
import "../theme"

/** Secciones de la página: se parten en renglones, sin reducir la tipografía. */
Item {
    id: root
    /** La familia de acento de la zona (Theme.fam; lib/accent-zones.js). */
    readonly property var acc: Theme.fam(palette.accent)
    property real s: 1
    property var tabs: []
    property string current: ""
    property bool focused: false
    signal picked(string key)
    implicitHeight: flow.implicitHeight + 12 * root.s

    Flow {
        id: flow
        width: root.width
        spacing: 6 * root.s
        Repeater {
            model: root.tabs
            delegate: Rectangle {
                id: tab
                required property var modelData
                readonly property bool selected: root.current === tab.modelData.key
                width: Math.min(root.width, Math.ceil(label.implicitWidth) + 28 * root.s)
                height: Math.max(36 * root.s, label.implicitHeight + 16 * root.s)
                radius: Metrics.r(8) * root.s
                // terminal (ADR-34): la elegida va invertida; el foco, en el color del texto (el anillo de acento no
                // se vería sobre el relleno de acento)
                readonly property color fill: tab.selected && Style.terminal ? Theme.activeBg(area.containsMouse, area.pressed && area.containsMouse, root.acc)
                    : Theme.controlBg("transparent", area.containsMouse, area.pressed && area.containsMouse, tab.selected, root.acc)
                color: fill
                border.width: root.focused && tab.selected ? Metrics.focusWidth * root.s : 0
                border.color: Style.terminal ? Theme.fg : root.acc.ring
                Accessible.role: Accessible.PageTab
                Accessible.name: tab.modelData.label
                Accessible.selected: tab.selected
                Accessible.focused: root.focused && tab.selected
                Accessible.onPressAction: root.picked(tab.modelData.key)
                Text {
                    id: label
                    anchors.centerIn: parent
                    width: Math.min(implicitWidth, Math.max(0, root.width - 28 * root.s))
                    wrapMode: Text.WordWrap
                    text: tab.modelData.label
                    color: tab.selected ? (Style.terminal ? Theme.activeText(tab.fill, root.acc) : root.acc.text) : Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.body * root.s
                    font.weight: tab.selected ? Typography.wMedium : Typography.wNormal
                }
                MouseArea {
                    id: area
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.picked(tab.modelData.key)
                }
            }
        }
    }
    Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: 1
        color: Theme.hair
    }
}
