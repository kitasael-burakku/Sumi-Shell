import QtQuick
import "../theme"

/**
 * Una cifra de la UI de inspección: rótulo, valor y una línea de apoyo. Alto fijo y cifras en mono:
 * que un valor pase de 9 % a 10 % no mueve nada alrededor.
 */
Rectangle {
    id: root
    /** La familia de acento de la zona (Theme.fam; lib/accent-zones.js). */
    readonly property var acc: Theme.fam(palette.accent)
    property real s: 1
    property string label: ""
    property string value: ""
    property string sub: ""
    property bool warning: false
    /** El llamante sólo colorea cifras con un significado; el resto mantiene tinta neutra. */
    property color valueColor: Theme.fg
    /** Pulsable (el Overview lleva a su sección). */
    property bool link: false
    signal activated()
    // rótulo, cifra y dos renglones de apoyo: el alto del diseño o el que pidan (auditoría tipográfica 2026-11-18)
    implicitHeight: Typography.box(100, [Typography.label, Typography.display, Typography.caption, Typography.caption], root.s)
    radius: Metrics.rSm * root.s
    color: Theme.controlBg(root.acc.container, area.containsMouse && root.link, area.pressed && area.containsMouse && root.link, false, root.acc)
    border.width: 1
    border.color: root.warning ? Qt.alpha(Theme.warn, 0.6) : area.containsMouse && root.link ? root.acc.selBorder : Theme.cardBorder
    Behavior on color { ColorAnimation { duration: Motion.fast } }
    Behavior on border.color { ColorAnimation { duration: Motion.fast } }
    scale: area.pressed && !Motion.still ? 0.98 : 1
    Behavior on scale { NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic } }
    Accessible.role: root.link ? Accessible.Button : Accessible.StaticText
    Accessible.name: root.label + " " + root.value + " " + root.sub
    Column {
        anchors.fill: parent
        anchors.margins: 12 * root.s
        spacing: 4 * root.s
        Text {
            width: parent.width; elide: Text.ElideRight
            text: root.label
            // el rótulo lleva el color de su zona (lib/accent-zones.js): cada cifra se distingue de la vecina
            color: root.acc.text
            font.family: Typography.ui; font.pixelSize: Typography.label * root.s
            font.weight: Typography.wStrong
        }
        Text {
            width: parent.width; elide: Text.ElideRight
            text: root.value
            color: root.warning ? Theme.warningText : root.valueColor
            font.family: Typography.mono; font.pixelSize: Typography.display * root.s; font.weight: Typography.wStrong
        }
        Text {
            width: parent.width; elide: Text.ElideRight
            height: Typography.box(32, [Typography.caption, Typography.caption], root.s); wrapMode: Text.Wrap; maximumLineCount: 2
            text: root.sub
            color: Theme.fgVariant
            font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
        }
    }
    MouseArea {
        id: area
        anchors.fill: parent
        enabled: root.link
        hoverEnabled: root.link
        cursorShape: root.link ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.activated()
    }
}
