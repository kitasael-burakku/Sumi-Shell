import QtQuick
import "../theme"

/**
 * Un control de texto del Lock («Show more», «Expand message»): enfocable con Tab, Enter/Espacio lo
 * activan sin autorrepetición, foco visible distinto del hover (futurelocksurface §9). El hover sólo
 * informa: nunca expande.
 */
Item {
    id: root

    property real s: 1
    property string text: ""
    /** Qué abre, para el nombre accesible y el recorrido («Show more · Discord»). */
    property string subject: ""
    signal activated()

    readonly property bool lockFocusable: root.enabled
    readonly property string lockFocusName: root.text + (root.subject.length > 0 ? " · " + root.subject : "")

    implicitWidth: label.implicitWidth + Metrics.sp2 * 2 * root.s
    implicitHeight: Math.max(label.implicitHeight + 4 * root.s, 22 * root.s)
    // fuera de la cadena de Tab de Qt: el recorrido lo lleva la superficie (15C)
    activeFocusOnTab: false

    Accessible.role: Accessible.Button
    Accessible.name: root.lockFocusName
    Accessible.onPressAction: root.activated()

    Rectangle {
        anchors.fill: parent
        radius: Metrics.rXs * root.s
        color: root.activeFocus ? Theme.selBg : area.containsMouse ? Theme.hoverBg : "transparent"
        border.width: root.activeFocus ? Metrics.focusWidth * root.s : 0
        border.color: Theme.focusRing
    }

    Text {
        id: label
        anchors.centerIn: parent
        text: root.text
        color: Theme.primary
        font.family: Typography.uiChosen
        font.weight: Typography.wMedium
        font.pixelSize: Typography.caption * root.s
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.activated()
    }

    Keys.onPressed: (e) => {
        if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) {
            if (!e.isAutoRepeat)
                root.activated();
            e.accepted = true;
        }
    }
}
