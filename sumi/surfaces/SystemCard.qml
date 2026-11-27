import QtQuick
import "../theme"
import "../components"
import "../lib/monitor.js" as Monitor

/**
 * Tarjeta de la surface compacta (antes de la fase 12, M4): se lee en un segundo. Nombre, valor
 * principal, uno o dos secundarios, la micrográfica de 60 s y «Details», que abre la UI de
 * inspección en su sección. Alto fijo por tipo: las cifras cambian sin mover la rejilla.
 */
Rectangle {
    id: root
    property real s: 1
    property var dataRow: ({})
    property var samples: []
    property bool selected: false
    property bool painting: true
    signal details()
    signal picked()
    readonly property bool linked: !!root.dataRow.section
    /** El alto de la otra tarjeta de la fila: las dos miden lo mismo (Energía junto a Discos era más baja). */
    property real peerHeight: 0
    implicitHeight: content.implicitHeight + 24 * root.s
    height: Math.max(root.implicitHeight, root.peerHeight)
    radius: Metrics.r(12) * root.s
    color: Theme.controlBg(Theme.tileBg, cardHover.hovered, false, false)
    Behavior on color { ColorAnimation { duration: Motion.fast } }
    border.width: root.selected ? Metrics.focusWidth * root.s : 1
    border.color: root.selected ? Theme.focusRing : root.dataRow.warning ? Qt.alpha(Theme.warn, 0.55)
        : cardHover.hovered ? Qt.alpha(Theme.primary, 0.45) : Theme.hair
    Behavior on border.color { ColorAnimation { duration: Motion.fast } }
    HoverHandler { id: cardHover }
    Accessible.role: Accessible.Button
    Accessible.name: root.dataRow.title + ", " + root.dataRow.headline + ", " + root.dataRow.aside + (root.linked ? ", Details" : "")
    Accessible.focusable: true
    Accessible.focused: root.selected
    Accessible.onPressAction: if (root.linked) root.details()

    // fondo: elegir la tarjeta (debajo de «Details», que va encima y se lleva su clic)
    MouseArea { anchors.fill: parent; onClicked: root.picked() }

    Column {
        id: content
        x: 12 * root.s; y: 12 * root.s
        width: parent.width - 24 * root.s
        spacing: 5 * root.s
        Item {
            width: parent.width
            height: 20 * root.s
            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6 * root.s
                Text {
                    text: root.dataRow.title
                    color: Theme.fgVariant
                    font.family: Typography.ui; font.pixelSize: Typography.label * root.s; font.weight: Typography.wStrong
                }
                Rectangle {
                    visible: !!root.dataRow.warning
                    anchors.verticalCenter: parent.verticalCenter
                    width: 6 * root.s; height: 6 * root.s; radius: Metrics.r(3) * root.s
                    color: Theme.warn
                }
            }
            Text {
                visible: root.linked
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "Details ↗"
                color: detailsArea.containsMouse || root.selected ? Theme.primary : Theme.fgVariant
                font.family: Typography.ui; font.pixelSize: Typography.caption * root.s; font.weight: Typography.wStrong
                MouseArea {
                    id: detailsArea
                    anchors.fill: parent
                    anchors.margins: -6 * root.s
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.details()
                }
            }
        }
        Item {
            width: parent.width
            height: 28 * root.s
            Text {
                id: head
                anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, parent.width * 0.74); elide: Text.ElideRight
                text: root.dataRow.headline
                color: root.dataRow.warning ? Theme.warn : Theme.fg
                font.family: Typography.mono; font.pixelSize: Typography.display * root.s; font.weight: Typography.wStrong
            }
            Text {
                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                width: parent.width - head.width - 12 * root.s; horizontalAlignment: Text.AlignRight; elide: Text.ElideRight
                text: root.dataRow.aside || ""
                color: Theme.fg
                font.family: Typography.mono; font.pixelSize: Typography.body * root.s
            }
        }
        Text {
            visible: !!root.dataRow.sub
            width: parent.width; elide: Text.ElideRight
            text: root.dataRow.sub || ""
            color: Theme.fgVariant
            font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
        }
        SystemGraph {
            visible: !!root.dataRow.graph
            width: parent.width
            height: implicitHeight
            s: root.s
            spec: root.dataRow.graph || ({})
            samples: root.samples
            painting: root.painting && visible
        }
        // discos: capacidad del volumen más lleno primero, una línea cada uno
        Repeater {
            model: root.dataRow.volumes || []
            Item {
                id: vol
                required property var modelData
                readonly property bool low: vol.modelData.totalB > 0 && vol.modelData.availableB / vol.modelData.totalB < .1
                width: content.width
                height: 18 * root.s
                Text {
                    anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                    width: parent.width * 0.34; elide: Text.ElideRight
                    text: vol.modelData.label || vol.modelData.mounts[0] || vol.modelData.device
                    color: Theme.fgVariant
                    font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                }
                Rectangle {
                    x: parent.width * 0.36; anchors.verticalCenter: parent.verticalCenter
                    // la barra cede lo que pida la cifra de la derecha (2026-11-18)
                    width: Math.max(parent.width * 0.1, Math.min(parent.width * 0.3, freeText.x - 6 * root.s - x)); height: 4 * root.s; radius: Metrics.pill(height); color: Theme.hair
                    Rectangle {
                        height: parent.height; radius: parent.radius
                        width: parent.width * (Monitor.known(vol.modelData.usedPct) ? Math.max(0, Math.min(1, vol.modelData.usedPct / 100)) : 0)
                        color: vol.low ? Theme.warn : Theme.secondary
                    }
                }
                Text {
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    id: freeText
                    width: Math.min(parent.width * 0.5, Math.max(parent.width * 0.32, implicitWidth))
                    horizontalAlignment: Text.AlignRight; elide: Text.ElideRight
                    text: Monitor.bytes(vol.modelData.availableB) + " free"
                    color: vol.low ? Theme.warn : Theme.fgVariant
                    font.family: Typography.mono; font.pixelSize: Typography.caption * root.s
                }
            }
        }
        Text {
            visible: (root.dataRow.moreVolumes || 0) > 0
            text: "+" + root.dataRow.moreVolumes + " more volumes in Details"
            color: Theme.fgVariant
            font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
        }
        // energía: contexto breve (perfil, batería, periféricos); los controles están en Performance
        Repeater {
            model: root.dataRow.lines || []
            Text {
                required property var modelData
                width: content.width; elide: Text.ElideRight
                text: modelData.label + " · " + modelData.text
                color: modelData.warning ? Theme.warn : Theme.fgVariant
                font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
            }
        }
    }
}
