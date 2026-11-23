import QtQuick
import "../theme"

/** Rótulo de bloque dentro de una sección (versalitas pequeñas, como SurfaceHeader) y nota a la derecha. */
Item {
    id: root
    /** La familia de acento de la zona (Theme.fam; lib/accent-zones.js). */
    readonly property var acc: Theme.fam(palette.accent)
    property real s: 1
    property string text: ""
    property string aside: ""
    property bool warning: false
    width: parent ? parent.width : 0
    implicitHeight: 26 * root.s
    Text {
        anchors.left: parent.left; anchors.bottom: parent.bottom
        anchors.right: note.left; anchors.rightMargin: 12 * root.s; elide: Text.ElideRight
        text: root.text
        // el rótulo lleva el color de su zona (2026-11-21)
        color: root.acc.text
        font.family: Typography.ui; font.pixelSize: Typography.body * root.s; font.weight: Typography.wStrong
    }
    Text {
        id: note
        anchors.right: parent.right; anchors.bottom: parent.bottom
        width: Math.min(implicitWidth, parent.width * 0.6); elide: Text.ElideRight
        text: root.aside
        color: root.warning ? Theme.warn : Theme.fgVariant
        font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
    }
}
