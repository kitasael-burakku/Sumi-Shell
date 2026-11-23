import QtQuick
import "../theme"
import "../services"
import "../lib/monitor.js" as Monitor

/**
 * Memoria: usada, disponible, caché y swap, separadas. La caché de Linux es reclamable: se pinta
 * como parte de lo disponible, nunca como memoria «perdida» ni como aviso.
 */
Flickable {
    id: root
    property real s: 1
    readonly property var m: MonitorUi.current ? MonitorUi.current.memory || {} : {}
    readonly property var sw: root.m.swap || {}
    readonly property real total: Monitor.known(root.m.totalB) ? root.m.totalB : 0
    function frac(x) { return root.total > 0 && Monitor.known(x) ? Math.max(0, Math.min(1, x / root.total)) : 0; }
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
            MonitorStat { width: stats.cell; s: root.s; label: "Used"; value: Monitor.bytes(root.m.usedB); sub: Monitor.number(root.m.usedPct, "%") + " of " + Monitor.bytes(root.m.totalB) }
            MonitorStat { width: stats.cell; s: root.s; label: "Available"; value: Monitor.bytes(root.m.availableB); sub: "Free plus reclaimable cache" }
            MonitorStat { width: stats.cell; s: root.s; label: "Cache & buffers"; value: Monitor.bytes(root.m.cacheB); sub: "Reclaimable · shared " + Monitor.bytes(root.m.shmemB) }
            MonitorStat {
                width: stats.cell; s: root.s; label: "Swap"
                value: root.sw.present === false ? "Off" : Monitor.bytes(root.sw.usedB)
                sub: root.sw.present === false ? "Not configured" : "of " + Monitor.bytes(root.sw.totalB) + " · in " + Monitor.bytes(root.sw.inBps, true) + " · out " + Monitor.bytes(root.sw.outBps, true)
            }
        }

        // reparto: en uso | caché (reclamable) | libre — sobre el total
        Column {
            width: parent.width
            spacing: 6 * root.s
            Rectangle {
                id: bar
                width: parent.width
                height: 12 * root.s
                radius: Metrics.pill(height)
                color: Theme.hair
                clip: true
                readonly property real usedW: bar.width * root.frac(root.m.usedB)
                readonly property real cacheW: Math.min(bar.width - bar.usedW, bar.width * root.frac(root.m.cacheB))
                Rectangle { width: bar.usedW; height: parent.height; color: Theme.fam(palette.accent).fill }
                Rectangle { x: bar.usedW; width: bar.cacheW; height: parent.height; color: Qt.alpha(Theme.fam(palette.accent).fill, 0.32) }
            }
            Flow {
                width: parent.width
                spacing: 14 * root.s
                Repeater {
                    model: [{c: Theme.fam(palette.accent).fill, t: "In use " + Monitor.bytes(root.m.usedB)},
                            {c: Qt.alpha(Theme.fam(palette.accent).fill, 0.32), t: "Cache " + Monitor.bytes(root.m.cacheB)},
                            {c: Theme.hair, t: "Free " + Monitor.bytes(Monitor.known(root.m.availableB) && Monitor.known(root.m.cacheB) ? Math.max(0, root.m.availableB - root.m.cacheB) : null)}]
                    Row {
                        required property var modelData
                        spacing: 6 * root.s
                        Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 10 * root.s; height: 10 * root.s; radius: Metrics.r(3) * root.s; color: modelData.c }
                        Text { text: modelData.t; color: Theme.fgVariant; font.family: Typography.mono; font.pixelSize: Typography.micro * root.s }
                    }
                }
            }
            Text {
                width: parent.width; wrapMode: Text.Wrap
                text: "Pressure (PSI, 10 s): " + Monitor.number(root.m.pressureSomePct, "%", 1) + " some · " + Monitor.number(root.m.pressureFullPct, "%", 1) + " full"
                      + "  ·  dirty " + Monitor.bytes(root.m.dirtyB) + "  ·  anonymous " + Monitor.bytes(root.m.anonB)
                color: Theme.fgVariant
                font.family: Typography.ui; font.pixelSize: Typography.micro * root.s
            }
        }

        MonitorGraph { width: parent.width; s: root.s; title: "Used"; unit: "B"; max: root.total; series: [{key: "mem.used", label: "In use"}, {key: "mem.cache", label: "Cache"}] }
        MonitorGraph {
            visible: root.sw.present !== false
            width: parent.width; s: root.s; plotHeight: 56; title: "Swap used"; unit: "B"; max: root.sw.totalB || 0
            series: [{key: "swap.used", label: "Swap"}]
        }
        MonitorGraph { width: parent.width; s: root.s; plotHeight: 48; title: "Memory pressure"; unit: "%"; max: 100; series: [{key: "mem.psi", label: "Some"}] }

        MonitorHeading { s: root.s; text: "Top processes" }
        MonitorTopList { width: parent.width; s: root.s; kind: "memory"; count: 8 }
        Item { width: 1; height: 4 * root.s }
    }
}
