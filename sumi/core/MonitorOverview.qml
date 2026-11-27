import QtQuick
import "../theme"
import "../lib/accent-zones.js" as Zones
import "../services"
import "../lib/monitor.js" as Monitor

/**
 * Overview: decidir qué mirar después. Avisos primero (sólo si los hay), cifras que llevan a su
 * sección, tres gráficas de la ventana elegida y los mayores consumidores. No repite las tarjetas
 * de la surface: cada cosa una vez y con enlace a su detalle.
 */
Flickable {
    id: root
    property real s: 1
    readonly property var cur: MonitorUi.current
    readonly property var cpu: root.cur ? root.cur.cpu || {} : {}
    readonly property var mem: root.cur ? root.cur.memory || {} : {}
    readonly property var gpu: root.cur && root.cur.gpus && root.cur.gpus.length ? root.cur.gpus[0] : null
    readonly property var net: root.cur ? root.cur.network || {} : {}
    readonly property var io: {
        let r = null, w = null;
        for (const d of (root.cur && root.cur.disks) || []) for (const x of d.io || []) {
            if (typeof x.readBps === "number") r = (r || 0) + x.readBps;
            if (typeof x.writeBps === "number") w = (w || 0) + x.writeBps;
        }
        return {r: r, w: w};
    }
    contentWidth: width
    contentHeight: col.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
        id: col
        width: root.width
        spacing: 14 * root.s

        // ---- avisos (sólo condiciones sostenidas: lib/monitor-alerts.js) ------------------
        Column {
            width: parent.width
            spacing: 6 * root.s
            visible: MonitorUi.alerts.length > 0
            MonitorHeading { s: root.s; text: "Needs attention"; aside: MonitorUi.alerts.length + (MonitorUi.alerts.length === 1 ? " condition" : " conditions"); warning: true }
            Repeater {
                model: MonitorUi.alerts
                Rectangle {
                    id: alertRow
                    required property var modelData
                    width: col.width
                    height: 40 * root.s
                    radius: Metrics.rSm * root.s
                    color: alertArea.containsMouse ? Theme.hoverBg : Qt.alpha(alertRow.modelData.level === "critical" ? Theme.errorColor : Theme.warn, 0.10)
                    border.width: 1
                    border.color: Qt.alpha(alertRow.modelData.level === "critical" ? Theme.errorColor : Theme.warn, 0.45)
                    Text {
                        x: 12 * root.s; anchors.verticalCenter: parent.verticalCenter
                        width: parent.width * 0.45; elide: Text.ElideRight
                        text: alertRow.modelData.title
                        color: alertRow.modelData.level === "critical" ? Theme.errorColor : Theme.warn
                        font.family: Typography.ui; font.pixelSize: Typography.body * root.s; font.weight: Typography.wStrong
                    }
                    Text {
                        anchors.right: parent.right; anchors.rightMargin: 12 * root.s; anchors.verticalCenter: parent.verticalCenter
                        width: parent.width * 0.5; horizontalAlignment: Text.AlignRight; elide: Text.ElideRight
                        text: alertRow.modelData.detail
                        color: Theme.fgVariant
                        font.family: Typography.ui; font.pixelSize: Typography.label * root.s
                    }
                    MouseArea { id: alertArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: MonitorUi.section = alertRow.modelData.domain
                        Accessible.role: Accessible.Button; Accessible.name: alertRow.modelData.title; Accessible.description: alertRow.modelData.detail
                        Accessible.onPressAction: MonitorUi.section = alertRow.modelData.domain }
                }
            }
        }

        // ---- cifras ----------------------------------------------------------------------
        Grid {
            id: stats
            width: parent.width
            // Mantener legible el total de memoria con ventana estrecha o escala grande.
            columns: Math.max(1, Math.min(3, Math.floor((width + spacing) / (220 * root.s * Typography.grow + spacing))))
            spacing: 10 * root.s
            readonly property real cell: (width - (columns - 1) * spacing) / columns
            MonitorStat {
                width: stats.cell; s: root.s; link: true; onActivated: MonitorUi.section = "cpu"
                palette.accent: Theme.zone(Zones.of("cpu"))
                label: "CPU"; value: Monitor.cpuUsage(root.cur)
                sub: Monitor.tempText(root.cpu.temperatureC, Sysmon.tempUnits) + "  ·  " + Monitor.freq(root.cpu.frequencyMHz)
                warning: MonitorUi.alerts.some(a => a.id === "temp:cpu.temp")
            }
            MonitorStat {
                width: stats.cell; s: root.s; link: true; onActivated: MonitorUi.section = "gpu"
                palette.accent: Theme.zone(Zones.of("gpu"))
                label: root.cur && root.cur.gpus && root.cur.gpus.length > 1 ? "GPU · " + root.gpu.card + " (+" + (root.cur.gpus.length - 1) + ")" : "GPU"
                value: root.gpu ? Monitor.number(root.gpu.usagePct, "%") : "None"
                sub: root.gpu ? Monitor.tempText(root.gpu.temperatureC, Sysmon.tempUnits) + "  ·  VRAM " + Monitor.bytes(root.gpu.vramUsedB) : "No GPU detected"
                warning: !!root.gpu && MonitorUi.alerts.some(a => a.id === "temp:gpu/" + root.gpu.id + "/temp")
            }
            MonitorStat {
                width: stats.cell; s: root.s; link: true; onActivated: MonitorUi.section = "memory"
                palette.accent: Theme.zone(Zones.of("memory"))
                label: "Memory"; value: Monitor.bytes(root.mem.usedB) + " / " + Monitor.bytes(root.mem.totalB)
                sub: Monitor.bytes(root.mem.availableB) + " available" + (root.mem.swap && root.mem.swap.present ? "  ·  swap " + Monitor.bytes(root.mem.swap.usedB) : "")
            }
            MonitorStat {
                width: stats.cell; s: root.s; link: true; onActivated: MonitorUi.section = "network"
                palette.accent: Theme.zone(Zones.of("network"))
                label: "Network"; value: "↓ " + Monitor.bytes(root.net.rxBps, true)
                sub: "↑ " + Monitor.bytes(root.net.txBps, true) + "  ·  " + ((root.net.interfaces || []).map(i => i.name).join(", ") || "No active interface")
            }
            MonitorStat {
                width: stats.cell; s: root.s; link: true; onActivated: MonitorUi.section = "disks"
                palette.accent: Theme.zone(Zones.of("disks"))
                label: "Disks"; value: "R " + Monitor.bytes(root.io.r, true)
                sub: "W " + Monitor.bytes(root.io.w, true) + "  ·  " + (((root.cur && root.cur.disks) || []).length) + " devices"
            }
            MonitorStat {
                width: stats.cell; s: root.s
                palette.accent: Theme.zone(Zones.of("uptime"))
                label: "Uptime"; value: Monitor.duration(root.cur && root.cur.system ? root.cur.system.uptimeS : null)
                sub: root.cur && root.cur.system ? "Load " + [root.cur.system.load1, root.cur.system.load5, root.cur.system.load15].map(x => Monitor.number(x, "", 2)).join(" · ") : ""
            }
        }

        // ---- tendencia ---------------------------------------------------------------------
        MonitorHeading { s: root.s; text: "Activity"; aside: MonitorUi.warmingUp ? "Filling · " + Monitor.duration(MonitorUi.coveredMs / 1000) + " recorded" : "" }
        MonitorGraph {
            width: parent.width; s: root.s; plotHeight: 64; title: "CPU & GPU"; unit: "%"; max: 100
            series: [{key: "cpu.usage", label: "CPU"}].concat(root.gpu ? [{key: "gpu/" + root.gpu.id + "/usage", label: "GPU"}] : [])
        }
        MonitorGraph {
            palette.accent: Theme.zone(Zones.of("memory"))
            width: parent.width; s: root.s; plotHeight: 56; title: "Memory"; unit: "B"; max: root.mem.totalB || 0
            series: [{key: "mem.used", label: "Used"}]
        }
        MonitorGraph {
            width: parent.width; s: root.s; plotHeight: 56; title: "Network"; unit: "B/s"
            series: [{key: "net.rx", label: "Receive"}, {key: "net.tx", label: "Send"}]
        }

        // ---- consumidores ------------------------------------------------------------------
        Grid {
            width: parent.width
            columns: width >= 680 * root.s ? 2 : 1
            spacing: 16 * root.s
            Column {
                width: (parent.width - (parent.columns - 1) * parent.spacing) / parent.columns
                spacing: 6 * root.s
                MonitorHeading { s: root.s; text: "Top CPU" }
                MonitorTopList { width: parent.width; s: root.s; kind: "cpu"; count: 5 }
            }
            Column {
                width: (parent.width - (parent.columns - 1) * parent.spacing) / parent.columns
                spacing: 6 * root.s
                MonitorHeading { s: root.s; text: "Top memory" }
                MonitorTopList { width: parent.width; s: root.s; kind: "memory"; count: 5 }
            }
        }
        Item { width: 1; height: 4 * root.s }
    }
}
