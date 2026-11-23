import QtQuick
import "../theme"

/** Scoped radio heading: readable title, independent status line and existing controls. */
Item {
    id: root
    /** La familia de acento de la zona (Theme.fam; lib/accent-zones.js). */
    readonly property var acc: Theme.fam(palette.accent)
    property real s: 1
    property string title: ""
    property string aside: ""
    property string glyph: "wifi"
    property bool scanning: false
    default property alias extra: controls.data
    height: 64 * root.s

    Rectangle {
        id: badge
        x:0; y:3 * root.s
        width:36 * root.s; height:36 * root.s; radius:Metrics.r(11) * root.s
        color:root.acc.sel
        Icon {
            id: radioIcon
            anchors.centerIn:parent; name:root.glyph; size:20 * root.s; color:root.acc.accent
            readonly property bool pulsing:root.scanning && Motion.mode === "normal"
            SequentialAnimation on opacity {
                running:radioIcon.pulsing; loops:Animation.Infinite
                NumberAnimation { to:0.35; duration:900; easing.type:Easing.InOutSine }
                NumberAnimation { to:1; duration:900; easing.type:Easing.InOutSine }
            }
            onPulsingChanged:if(!pulsing)opacity=1
        }
    }
    Text {
        id: heading
        anchors.left:badge.right; anchors.leftMargin:10 * root.s
        anchors.right:controls.left; anchors.rightMargin:10 * root.s
        y:2 * root.s
        text:root.title; elide:Text.ElideRight
        color:Theme.fg; font.family:Typography.ui; font.pixelSize:Typography.title * 1.1 * root.s
        font.weight:Typography.wStrong
        Accessible.role:Accessible.Heading; Accessible.name:text
    }
    Text {
        anchors.left:heading.left; anchors.right:parent.right
        anchors.top:heading.bottom; anchors.topMargin:4 * root.s
        text:root.aside; elide:Text.ElideRight
        color:Theme.fgVariant; font.family:Typography.ui; font.pixelSize:Typography.caption * root.s
        font.features:({"tnum":1})
    }
    Row {
        id: controls
        anchors.right:parent.right; y:4 * root.s
        spacing:6 * root.s
    }
    Rectangle { anchors.left:parent.left; anchors.right:parent.right; anchors.bottom:parent.bottom; height:1; color:Theme.hair }
}
