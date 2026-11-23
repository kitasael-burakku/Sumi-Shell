pragma ComponentBehavior: Bound
import QtQuick
import "../components"
import "../theme"

/**
 * Micrófono y pantalla en uso (fase 15, LOCK-D20): esquina superior derecha del panel, separados del
 * estado de la autenticación. Sólo existen con actividad; sin controles para detener nada. La ayuda
 * aparece con hover o con foco (§8 «Mapa final»), nunca hace nada.
 *
 * `privacy` = { mic, screen }. La cámara NO se pinta como pantalla (LK-14): el contexto real la
 * separará en la 15D; aquí sólo se leen `mic` y `screen`.
 */
Row {
    id: root

    property real s: 1
    property var privacy: ({ mic: false, screen: false })

    readonly property var active: [
        { on: root.privacy && root.privacy.mic === true, icon: "mic", help: "Microphone in use" },
        { on: root.privacy && root.privacy.screen === true, icon: "screenshare", help: "Screen is being shared" }
    ].filter(function (x) { return x.on; })

    spacing: Metrics.sp1 * root.s
    visible: root.active.length > 0
    layoutDirection: Qt.RightToLeft

    Repeater {
        model: root.active
        delegate: Item {
            id: chip
            required property var modelData
            width: 26 * root.s
            height: 26 * root.s
            activeFocusOnTab: false   // recorrido explícito de la superficie (15C)
            readonly property bool lockFocusable: true
            readonly property string lockFocusName: chip.modelData.help
            Accessible.role: Accessible.StaticText
            Accessible.name: chip.modelData.help

            Rectangle {
                anchors.fill: parent
                radius: Metrics.pill(width)
                color: Qt.alpha(Theme.tintDanger, 0.16)
                border.width: chip.activeFocus ? Metrics.focusWidth * root.s : 0
                border.color: Theme.focusRing
            }
            Icon {
                anchors.centerIn: parent
                name: chip.modelData.icon
                size: 14 * root.s
                color: Theme.tintDanger
            }
            MouseArea { id: hover; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }

            Rectangle {
                visible: hover.containsMouse || chip.activeFocus
                anchors.top: parent.bottom
                anchors.topMargin: Metrics.sp1 * root.s
                anchors.right: parent.right
                width: helpText.implicitWidth + Metrics.sp2 * 2 * root.s
                height: helpText.implicitHeight + Metrics.sp1 * 2 * root.s
                radius: Metrics.rXs * root.s
                color: Theme.surfaceContainerHigh
                z: 10
                Text {
                    id: helpText
                    anchors.centerIn: parent
                    text: chip.modelData.help
                    color: Theme.fg
                    font.family: Typography.uiChosen
                    font.pixelSize: Typography.caption * root.s
                }
            }
        }
    }
}
