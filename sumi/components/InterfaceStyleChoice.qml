pragma ComponentBehavior: Bound

import QtQuick
import "../theme"

/**
 * Selector del estilo de interfaz (F4 del estilo, 2026-11-14; ADR-34): una tarjeta por estilo, con su miniatura
 * (`InterfaceStylePreview`, dibujada con la tabla de ese estilo), su nombre y una línea. Los estilos, sus nombres y sus
 * líneas salen de `Style.styles` (una sola fuente). Teclado: lo lleva la fila de Settings (←/→ cambian, Enter
 * alterna); el ratón elige con un clic. Mismo patrón que `WindowStyleChoice`.
 */
Item {
    id: root

    property real s: 1
    property string value: "soft"
    property bool focused: false
    property string name: ""
    signal picked(string value)

    Accessible.role: Accessible.Grouping
    Accessible.name: root.name

    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight

    Row {
        id: row
        spacing: 8 * root.s

        Repeater {
            model: Style.names
            delegate: Rectangle {
                id: card
                required property string modelData
                readonly property var info: Style.params(card.modelData)
                readonly property bool current: card.modelData === root.value

                width: Math.round(152 * root.s * Typography.textScale)
                height: col.implicitHeight + 16 * root.s
                radius: Metrics.r(12) * root.s
                color: card.current ? Theme.selBg : (area.containsMouse ? Theme.hoverBg : "transparent")
                border.width: Math.max(1, root.s)
                border.color: card.current ? Theme.selBorder : Theme.hair
                Behavior on color { ColorAnimation { duration: Motion.fast } }

                Accessible.role: Accessible.RadioButton
                Accessible.name: card.info.label
                Accessible.description: card.info.note
                Accessible.checkable: true
                Accessible.checked: card.current
                Accessible.onPressAction: root.picked(card.modelData)

                Column {
                    id: col
                    x: 8 * root.s
                    y: 8 * root.s
                    width: card.width - 16 * root.s
                    spacing: 6 * root.s

                    InterfaceStylePreview {
                        s: root.s
                        width: parent.width
                        style: card.modelData
                    }
                    Text {
                        width: parent.width
                        text: card.info.label
                        elide: Text.ElideRight
                        color: card.current ? Theme.primary : Theme.fg
                        font.family: Typography.ui
                        font.pixelSize: Typography.body * root.s
                        font.weight: Font.DemiBold
                    }
                    Text {
                        width: parent.width
                        text: card.info.note
                        wrapMode: Text.WordWrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
                        color: Theme.fgVariant
                        font.family: Typography.ui
                        font.pixelSize: Typography.caption * root.s
                    }
                }

                MouseArea {
                    id: area
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.picked(card.modelData)
                }
            }
        }
    }
}
