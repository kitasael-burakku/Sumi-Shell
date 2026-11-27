import QtQuick
import "../theme"
import "../services"
import "../components"
import "../lib/monitor.js" as Monitor

/** CPU: uso, temperatura con su límite, frecuencia y carga; gráficas; núcleos plegados; consumidores. */
Flickable {
    id: root
    property real s: 1
    readonly property var cpu: MonitorUi.current ? MonitorUi.current.cpu || {} : {}
    readonly property var sys: MonitorUi.current ? MonitorUi.current.system || {} : {}
    readonly property var t: Monitor.temp(root.cpu, Sysmon.tempUnits)
    property bool coresOpen: false
    contentWidth: width
    contentHeight: col.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
        id: col
        width: root.width
        spacing: 14 * root.s

        Grid {
            id: stats
            width: parent.width
            columns: width >= 640 * root.s * Typography.grow ? 4 : 2
            spacing: 10 * root.s
            readonly property real cell: (width - (columns - 1) * spacing) / columns
            MonitorStat { width: stats.cell; s: root.s; label: "Usage"; value: Monitor.cpuUsage(MonitorUi.current); sub: (root.cpu.logicalCount || "?") + " logical cores" }
            MonitorStat { width: stats.cell; s: root.s; label: "Temperature"; value: root.t.text; sub: root.t.limit + (root.cpu.temperatureSensor ? " · " + root.cpu.temperatureSensor : ""); warning: MonitorUi.alerts.some(a => a.id === "temp:cpu.temp") }
            MonitorStat { width: stats.cell; s: root.s; label: "Frequency"; value: Monitor.freq(root.cpu.frequencyMHz); sub: "Average · highest " + Monitor.freq(root.cpu.frequencyMaxMHz) }
            MonitorStat { width: stats.cell; s: root.s; label: "Load"; value: Monitor.number(root.sys.load1, "", 2); sub: "5 m " + Monitor.number(root.sys.load5, "", 2) + " · 15 m " + Monitor.number(root.sys.load15, "", 2) }
        }

        MonitorGraph { width: parent.width; s: root.s; title: "Usage"; unit: "%"; max: 100; series: [{key: "cpu.usage", label: "CPU"}] }
        MonitorGraph { width: parent.width; s: root.s; plotHeight: 64; title: "Temperature"; unit: "°C"; series: [{key: "cpu.temp", label: "Package"}] }
        MonitorGraph { width: parent.width; s: root.s; plotHeight: 56; title: "Frequency"; unit: "MHz"; series: [{key: "cpu.freq", label: "Average"}] }

        // núcleos: plegados por defecto (DESIGN: no métricas por núcleo permanentes si sólo son ruido)
        Disclosure {
            s: root.s
            label: "Per-core usage"
            summary: (root.cpu.cores || []).length + " cores"
            expanded: root.coresOpen
            onToggled: root.coresOpen = !root.coresOpen
        }
        Grid {
            id: cores
            visible: root.coresOpen
            width: parent.width
            columns: 4
            spacing: 6 * root.s
            Repeater {
                model: root.coresOpen ? root.cpu.cores || [] : []
                Rectangle {
                    id: core
                    required property var modelData
                    width: (cores.width - 3 * cores.spacing) / 4
                    height: 28 * root.s
                    radius: Metrics.r(6) * root.s
                    color: Theme.tileBg
                    border.width: 1
                    border.color: Theme.hair
                    Rectangle {
                        height: parent.height; radius: parent.radius
                        width: parent.width * (Monitor.known(core.modelData.usagePct) ? Math.min(1, core.modelData.usagePct / 100) : 0)
                        color: Qt.alpha(Theme.fam(palette.accent).fill, 0.18)
                    }
                    Text {
                        x: 8 * root.s; anchors.verticalCenter: parent.verticalCenter
                        text: core.modelData.id.replace("cpu", "#")
                        color: Theme.fgVariant
                        font.family: Typography.mono; font.pixelSize: Typography.micro * root.s
                    }
                    Text {
                        anchors.right: parent.right; anchors.rightMargin: 8 * root.s; anchors.verticalCenter: parent.verticalCenter
                        text: Monitor.number(core.modelData.usagePct, "%") + "  " + Monitor.freq(core.modelData.frequencyMHz)
                        color: Theme.fg
                        font.family: Typography.mono; font.pixelSize: Typography.micro * root.s
                    }
                }
            }
        }

        MonitorHeading { s: root.s; text: "Top processes"; aside: "Throttling is not detectable reliably here" }
        MonitorTopList { width: parent.width; s: root.s; kind: "cpu"; count: 8 }
        Item { width: 1; height: 4 * root.s }
    }
}
