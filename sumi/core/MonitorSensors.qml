import QtQuick
import "../theme"
import "../services"
import "../components"
import "../lib/monitor.js" as Monitor

/**
 * Sensors: los chips hwmon que el sistema publica, por tipo, con el máximo visto desde que se abrió
 * la UI. Clase media (se leen cada 2 s). Un sensor ausente es falta de soporte, no un error: sólo se
 * lista lo que existe. Ventiladores a 0 RPM se resumen (parados o sin conectar); voltajes plegados.
 */
Flickable {
    id: root
    property real s: 1
    readonly property var chips: MonitorUi.sensors ? MonitorUi.sensors.chips : []
    readonly property var order: ["cpu", "gpu", "storage", "memory", "board", "network", "other"]
    readonly property var names: ({cpu: "CPU", gpu: "GPU", storage: "Storage", memory: "Memory modules", board: "Motherboard", network: "Network adapters", other: "Other"})
    readonly property var sorted: root.chips.slice().sort((a, b) => root.order.indexOf(a.kind) - root.order.indexOf(b.kind))
    property var voltsOpen: ({})
    contentWidth: width
    contentHeight: col.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    component Line: Item {
        id: line
        property string label: ""
        property string value: ""
        property string aside: ""
        property bool warning: false
        width: parent ? parent.width : 0
        height: 22 * root.s
        // la fila bajo el puntero: lleva el ojo de la etiqueta a su cifra y a su pico, que están lejos
        HoverHandler { id: lineHover }
        Rectangle {
            anchors.fill: parent
            radius: Metrics.r(6) * root.s
            color: lineHover.hovered ? Theme.hoverBg : "transparent"
            Behavior on color { ColorAnimation { duration: Motion.fast } }
        }
        Text {
            x: 8 * root.s; anchors.verticalCenter: parent.verticalCenter
            width: parent.width * 0.4; elide: Text.ElideRight
            text: line.label
            color: Theme.fgVariant
            font.family: Typography.ui; font.pixelSize: Typography.label * root.s
        }
        Text {
            x: parent.width * 0.42; anchors.verticalCenter: parent.verticalCenter
            width: 90 * root.s; horizontalAlignment: Text.AlignRight
            text: line.value
            color: line.warning ? Theme.warn : Theme.fg
            font.family: Typography.mono; font.pixelSize: Typography.label * root.s
        }
        Text {
            anchors.right: parent.right; anchors.rightMargin: 8 * root.s; anchors.verticalCenter: parent.verticalCenter
            width: parent.width * 0.4; horizontalAlignment: Text.AlignRight; elide: Text.ElideRight
            text: line.aside
            color: Theme.fgVariant
            font.family: Typography.mono; font.pixelSize: Typography.micro * root.s
        }
    }

    Column {
        id: col
        width: root.width
        spacing: 12 * root.s

        Empty {
            visible: root.chips.length === 0
            width: parent.width; s: root.s; maxWidth: parent.width
            glyph: "alert"
            loading: !MonitorUi.sensors
            text: !MonitorUi.sensors ? "Reading sensors…" : "No hardware sensors exposed"
            hint: MonitorUi.sensors ? "No hwmon sensors on this system: not supported, not a fault." : ""
        }
        Text {
            visible: root.chips.length > 0
            text: "Peak = highest value since this window opened · read every 2 s" + (MonitorUi.sensors ? " · " + Qt.formatDateTime(new Date(MonitorUi.current ? MonitorUi.current.at - (MonitorUi.current.monoMs - MonitorUi.sensors.atMonoMs) : 0), "hh:mm:ss") : "")
            color: Theme.fgVariant
            font.family: Typography.ui; font.pixelSize: Typography.micro * root.s
        }

        Repeater {
            model: root.sorted
            Column {
                id: chip
                required property var modelData
                required property int index
                readonly property bool firstOfKind: chip.index === 0 || root.sorted[chip.index - 1].kind !== chip.modelData.kind
                readonly property var spinning: chip.modelData.fans.filter(f => f.rpm > 0)
                readonly property int stopped: chip.modelData.fans.length - chip.spinning.length
                width: col.width
                spacing: 2 * root.s

                Item { visible: chip.firstOfKind && chip.index > 0; width: 1; height: 6 * root.s }
                MonitorHeading { visible: chip.firstOfKind; s: root.s; text: root.names[chip.modelData.kind] || chip.modelData.kind }
                Text {
                    text: chip.modelData.name + (chip.modelData.device ? "  ·  " + chip.modelData.device : "")
                    color: Theme.fg
                    font.family: Typography.ui; font.pixelSize: Typography.label * root.s; font.weight: Typography.wStrong
                }
                Repeater {
                    model: chip.modelData.temps
                    Line {
                        required property var modelData
                        readonly property real limit: Monitor.known(modelData.critC) ? modelData.critC : Monitor.known(modelData.maxC) ? modelData.maxC : NaN
                        label: modelData.label
                        value: Monitor.number(modelData.c, " °C", 1)
                        warning: Monitor.known(limit) && modelData.c >= limit
                        aside: "peak " + Monitor.number(MonitorUi.sensorPeaks[modelData.id], " °C", 1) + (Monitor.known(limit) ? " · limit " + Monitor.number(limit, " °C") : "")
                    }
                }
                Repeater {
                    model: chip.spinning
                    Line { required property var modelData; label: modelData.label; value: Monitor.number(modelData.rpm, " RPM") }
                }
                Line { visible: chip.stopped > 0; label: chip.stopped + (chip.stopped === 1 ? " fan" : " fans") + " at 0 RPM"; aside: "stopped or not connected" }
                Repeater {
                    model: chip.modelData.power
                    Line { required property var modelData; label: modelData.label; value: Monitor.number(modelData.w, " W", 1) }
                }
                Disclosure {
                    visible: chip.modelData.volts.length > 0
                    s: root.s
                    label: "Voltages"
                    summary: chip.modelData.volts.length + " readings"
                    expanded: !!root.voltsOpen[chip.modelData.id]
                    onToggled: { const o = Object.assign({}, root.voltsOpen); o[chip.modelData.id] = !o[chip.modelData.id]; root.voltsOpen = o; }
                }
                Repeater {
                    model: root.voltsOpen[chip.modelData.id] ? chip.modelData.volts : []
                    Line { required property var modelData; label: modelData.label; value: Monitor.volts(modelData.v) }
                }
            }
        }
        Item { width: 1; height: 4 * root.s }
    }
}
