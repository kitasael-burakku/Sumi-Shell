pragma ComponentBehavior: Bound

import QtQuick
import "../theme"

/**
 * Dónde salen los popups de notificación (2026-11-19, pedido del autor): un monitor en miniatura con la isla arriba al
 * centro y una tarjetita en cada sitio posible (cuatro esquinas y abajo al centro; arriba al centro no, ahí viven la
 * isla y el notch). La elegida va rellena del acento; el ratón elige con un clic. Teclado: lo lleva la fila de
 * Settings (←/→ recorren los sitios en este orden, el del esquema).
 *
 * Sólo dibujo con tokens (Theme, Metrics): radios rectos en Terminal, sin textos que crezcan con Text size; el nombre
 * del sitio va en el pie de la fila.
 */
Item {
    id: root

    property real s: 1
    property string value: "bottom-right"
    property bool focused: false
    property string name: ""
    signal picked(string value)

    /** Mismo orden que `shell.notifications.position` en lib/settings-schema.js. */
    readonly property var places: [
        { value: "top-left", label: "Top left", fx: 0, fy: 0 },
        { value: "top-right", label: "Top right", fx: 1, fy: 0 },
        { value: "bottom-left", label: "Bottom left", fx: 0, fy: 1 },
        { value: "bottom-center", label: "Bottom center", fx: 0.5, fy: 1 },
        { value: "bottom-right", label: "Bottom right", fx: 1, fy: 1 }
    ]

    readonly property real screenW: Math.round(184 * root.s)
    readonly property real screenH: Math.round(112 * root.s)
    readonly property real cardW: Math.round(46 * root.s)
    readonly property real cardH: Math.round(16 * root.s)
    readonly property real inset: Math.round(8 * root.s)
    /** Las de arriba, por debajo de la isla (como en la pantalla real). */
    readonly property real islandH: Math.round(10 * root.s)

    Accessible.role: Accessible.Grouping
    Accessible.name: root.name

    implicitWidth: root.screenW
    implicitHeight: root.screenH

    // el monitor
    Rectangle {
        id: frame
        anchors.fill: parent
        radius: Metrics.r(10) * root.s
        color: Theme.tileBg
        border.width: Math.max(1, root.s)
        border.color: root.focused ? Theme.selBorder : Theme.hair
        Behavior on border.color { ColorAnimation { duration: Motion.fast } }

        // la isla, arriba al centro
        Rectangle {
            width: Math.round(48 * root.s)
            height: root.islandH
            x: (frame.width - width) / 2
            y: Math.round(5 * root.s)
            radius: Metrics.pill(height)
            color: Qt.alpha(Theme.fg, 0.28)
        }
    }

    Repeater {
        model: root.places
        delegate: Rectangle {
            id: spot
            required property var modelData
            readonly property bool current: spot.modelData.value === root.value
            readonly property real topY: root.inset + root.islandH + Math.round(2 * root.s)

            width: root.cardW
            height: root.cardH
            x: Math.round(root.inset + spot.modelData.fx * (root.screenW - 2 * root.inset - root.cardW))
            y: spot.modelData.fy === 0 ? spot.topY : root.screenH - root.inset - root.cardH
            radius: Metrics.r(4) * root.s
            color: spot.current ? Theme.primary : (area.containsMouse ? Theme.hoverBg : "transparent")
            border.width: Math.max(1, root.s)
            border.color: spot.current ? Theme.primary : (area.containsMouse ? Theme.selBorder : Theme.hair)
            Behavior on color { ColorAnimation { duration: Motion.fast } }

            // dos renglones de «texto», como una notificación
            Column {
                x: Math.round(5 * root.s)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Math.round(2 * root.s)
                Repeater {
                    model: [0.62, 0.40]
                    delegate: Rectangle {
                        required property real modelData
                        width: Math.round((root.cardW - 10 * root.s) * modelData)
                        height: Math.max(1, Math.round(2 * root.s))
                        radius: height / 2
                        color: spot.current ? Theme.fgOnPrimary : Qt.alpha(Theme.fg, 0.35)
                    }
                }
            }

            Accessible.role: Accessible.RadioButton
            Accessible.name: spot.modelData.label
            Accessible.checkable: true
            Accessible.checked: spot.current
            Accessible.onPressAction: root.picked(spot.modelData.value)

            MouseArea {
                id: area
                // un poco más de zona que la tarjetita, sin pisar a las vecinas
                anchors.centerIn: parent
                width: parent.width + 8 * root.s
                height: parent.height + 8 * root.s
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.picked(spot.modelData.value)
            }
        }
    }
}
