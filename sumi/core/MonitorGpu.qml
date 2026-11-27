import QtQuick
import "../theme"
import "../services"
import "../components"
import "../lib/monitor.js" as Monitor

/**
 * GPU: un bloque por GPU detectada (ninguna, una o varias). Lo que el driver no publica queda en
 * No data; los clientes por proceso no se atribuyen (no hay fuente fiable en esta interfaz).
 */
Flickable {
    id: root
    property real s: 1
    readonly property var gpus: MonitorUi.current && MonitorUi.current.gpus ? MonitorUi.current.gpus : []
    contentWidth: width
    contentHeight: col.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
        id: col
        width: root.width
        spacing: 14 * root.s

        Empty {
            visible: root.gpus.length === 0
            width: parent.width
            s: root.s
            glyph: "tv"
            text: MonitorUi.current ? "No GPU detected" : "Waiting for samples…"
            hint: MonitorUi.current ? "No DRM device with a driver was found. This is not an error." : ""
        }

        Repeater {
            model: root.gpus
            Column {
                id: block
                required property var modelData
                required property int index
                readonly property var t: Monitor.temp(block.modelData, Sysmon.tempUnits)
                readonly property string k: "gpu/" + block.modelData.id + "/"
                width: col.width
                spacing: 12 * root.s

                MonitorHeading {
                    s: root.s
                    text: "GPU · " + block.modelData.card
                    aside: block.modelData.name + " · " + (block.modelData.driver || "driver unknown") + " · " + block.modelData.id
                }
                Grid {
                    id: stats
                    width: parent.width
                    columns: width >= 640 * root.s * Typography.grow ? 4 : 2
                    spacing: 10 * root.s
                    readonly property real cell: (width - (columns - 1) * spacing) / columns
                    MonitorStat { width: stats.cell; s: root.s; label: "Usage"; value: Monitor.number(block.modelData.usagePct, "%"); sub: "Clock " + Monitor.freq(block.modelData.frequencyMHz) }
                    MonitorStat { width: stats.cell; s: root.s; label: "Temperature"; value: block.t.text; sub: block.t.limit; warning: MonitorUi.alerts.some(a => a.id === "temp:" + block.k + "temp") }
                    MonitorStat {
                        width: stats.cell; s: root.s; label: "VRAM"
                        value: Monitor.bytes(block.modelData.vramUsedB)
                        sub: "of " + Monitor.bytes(block.modelData.vramTotalB) + (Monitor.known(block.modelData.vramTotalB) && block.modelData.vramTotalB > 0 ? " · " + Math.round(block.modelData.vramUsedB * 100 / block.modelData.vramTotalB) + "%" : "")
                    }
                    MonitorStat {
                        width: stats.cell; s: root.s; label: "Power"
                        value: Monitor.number(block.modelData.powerW, " W", 1)
                        sub: "Cap " + Monitor.number(block.modelData.powerCapW, " W") + " · fan " + Monitor.number(block.modelData.fanRpm, " RPM")
                    }
                }
                MonitorGraph { width: parent.width; s: root.s; title: "Usage"; unit: "%"; max: 100; series: [{key: block.k + "usage", label: "Usage"}] }
                MonitorGraph { width: parent.width; s: root.s; plotHeight: 56; title: "Temperature"; unit: "°C"; series: [{key: block.k + "temp", label: "Edge"}] }
                MonitorGraph { width: parent.width; s: root.s; plotHeight: 56; title: "VRAM used"; unit: "B"; max: block.modelData.vramTotalB || 0; series: [{key: block.k + "vram", label: "Used"}] }
                MonitorGraph { width: parent.width; s: root.s; plotHeight: 48; title: "Power"; unit: "W"; max: block.modelData.powerCapW || 0; series: [{key: block.k + "power", label: "Average"}] }
                Text {
                    width: parent.width; wrapMode: Text.Wrap
                    text: "Processes using this GPU: unavailable · " + (block.modelData.processReason || "no reliable attribution")
                    color: Theme.fgVariant
                    font.family: Typography.ui; font.pixelSize: Typography.label * root.s
                }
            }
        }
        Item { width: 1; height: 4 * root.s }
    }
}
