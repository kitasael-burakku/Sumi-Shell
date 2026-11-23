import QtQuick
import "../theme"
import "../services"
import "../components"
import "../lib/monitor.js" as Monitor

/**
 * Network: tráfico agregado y por interfaz activa, picos de la ventana elegida y totales desde el
 * arranque (los contadores del kernel). No analiza paquetes; la conexión se gestiona en Wi-Fi/Wired.
 */
Flickable {
    id: root
    property real s: 1
    readonly property var net: MonitorUi.current ? MonitorUi.current.network : null
    readonly property var ifs: root.net ? root.net.interfaces || [] : []
    /** Pico de la ventana visible (máximo de los cubos o de las muestras). */
    function peak(key) {
        let p = null;
        const from = MonitorUi.rows.length ? MonitorUi.rows[MonitorUi.rows.length - 1].monoMs - MonitorUi.rangeMs : 0;
        for (const r of MonitorUi.rows) {
            if (r.monoMs < from) continue;
            const o = MonitorUi.usesTrend ? r.hi : r.v, x = o ? o[key] : null;
            if (typeof x === "number" && (p === null || x > p)) p = x;
        }
        return p;
    }
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
            MonitorStat { width: stats.cell; s: root.s; label: "Receive"; value: Monitor.bytes(root.net ? root.net.rxBps : null, true); sub: "Peak " + Monitor.bytes(root.peak("net.rx"), true) + " in " + MonitorUi.ranges.find(r => r.id === MonitorUi.range).label }
            MonitorStat { width: stats.cell; s: root.s; label: "Send"; value: Monitor.bytes(root.net ? root.net.txBps : null, true); sub: "Peak " + Monitor.bytes(root.peak("net.tx"), true) + " in " + MonitorUi.ranges.find(r => r.id === MonitorUi.range).label }
            MonitorStat {
                width: stats.cell; s: root.s; label: "Interfaces"
                value: String(root.ifs.length)
                sub: root.ifs.length ? root.ifs.map(i => i.name).join(", ") : "None active"
                warning: !!root.net && root.ifs.length === 0
            }
            MonitorStat {
                width: stats.cell; s: root.s; label: "State"
                value: !root.net ? "No data" : root.ifs.length === 0 ? "Offline" : (Monitor.known(root.net.rxBps) && root.net.rxBps + (root.net.txBps || 0) < 2048 ? "Idle" : "Active")
                sub: "Link state only · no connectivity test"
            }
        }

        MonitorGraph { width: parent.width; s: root.s; title: "All interfaces"; unit: "B/s"; series: [{key: "net.rx", label: "Receive"}, {key: "net.tx", label: "Send"}] }

        Empty {
            visible: !!root.net && root.ifs.length === 0
            width: parent.width; s: root.s; maxWidth: parent.width
            glyph: "net-off"
            text: "No active network interface"
            hint: "Loopback and interfaces that are down are not listed"
        }
        Repeater {
            model: root.ifs
            Column {
                id: iface
                required property var modelData
                width: col.width
                spacing: 8 * root.s
                MonitorHeading {
                    s: root.s
                    text: iface.modelData.name
                    aside: ({wired: "Wired", wireless: "Wireless", virtual: "Virtual"})[iface.modelData.kind] + " · " + iface.modelData.state
                           + (iface.modelData.speedMbps ? " · " + iface.modelData.speedMbps + " Mb/s link" : "")
                           + " · since boot ↓ " + Monitor.bytes(iface.modelData.rxTotalB) + "  ↑ " + Monitor.bytes(iface.modelData.txTotalB)
                }
                MonitorGraph {
                    width: parent.width; s: root.s; plotHeight: 48; title: "Traffic"; unit: "B/s"
                    series: [{key: "if/" + iface.modelData.name + "/rx", label: "↓"}, {key: "if/" + iface.modelData.name + "/tx", label: "↑"}]
                }
            }
        }
        Item { width: 1; height: 4 * root.s }
    }
}
