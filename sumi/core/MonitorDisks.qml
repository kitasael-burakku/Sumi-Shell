import QtQuick
import "../theme"
import "../services"
import "../components"
import "../lib/monitor.js" as Monitor

/**
 * Disks: un bloque por dispositivo físico (o grupo, si un volumen ocupa varios), con sus volúmenes
 * (capacidad, montajes, sistema de archivos), su temperatura si hay sensor, la E/S actual y su
 * gráfica. Sin SMART: la salud dice «Not checked», no «OK».
 */
Flickable {
    id: root
    property real s: 1
    readonly property var disks: MonitorUi.current && MonitorUi.current.disks ? MonitorUi.current.disks : []
    contentWidth: width
    contentHeight: col.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
        id: col
        width: root.width
        spacing: 14 * root.s

        Empty {
            visible: root.disks.length === 0
            width: parent.width
            s: root.s
            maxWidth: parent.width
            glyph: "hibernate"
            text: !MonitorUi.current ? "Waiting for samples…" : MonitorUi.current.disks === null ? "Disk inventory unavailable" : "No local disks mounted"
            hint: MonitorUi.current && MonitorUi.current.disks === null ? "lsblk or the mount table could not be read" : ""
        }

        Repeater {
            model: root.disks
            Column {
                id: disk
                required property var modelData
                readonly property var ioRows: disk.modelData.io || []
                width: col.width
                spacing: 10 * root.s

                MonitorHeading {
                    s: root.s
                    text: disk.modelData.devices.join(" + ")
                    aside: (disk.ioRows.length === 1 ? "" : "Temperature " + Monitor.tempText(disk.modelData.temperatureC, Sysmon.tempUnits) + "  ·  ")
                        + "health not checked (no SMART)"
                }
                Grid {
                    id: stats
                    width: parent.width
                    columns: width >= 640 * root.s * Typography.grow ? 4 : 2
                    spacing: 10 * root.s
                    readonly property real cell: (width - (columns - 1) * spacing) / columns
                    /**
                     * Un solo dispositivo (lo normal): cuatro cifras que llenan la fila (2026-10-01; antes
                     * una tarjeta sola, a un cuarto de ancho, repetía el nombre del rótulo de encima).
                     */
                    Repeater {
                        model: disk.ioRows.length === 1 ? [
                            {label: "Read", value: Monitor.bytes(disk.ioRows[0].readBps, true), sub: disk.ioRows[0].device},
                            {label: "Write", value: Monitor.bytes(disk.ioRows[0].writeBps, true), sub: disk.ioRows[0].device},
                            {label: "Busy", value: Monitor.number(disk.ioRows[0].busyPct, "%"), sub: "Time with I/O in flight"},
                            {label: "Temperature", value: Monitor.tempText(disk.modelData.temperatureC, Sysmon.tempUnits), sub: "Drive sensor"}
                        ] : []
                        MonitorStat {
                            required property var modelData
                            width: stats.cell; s: root.s
                            label: modelData.label
                            value: modelData.value
                            sub: modelData.sub
                        }
                    }
                    Repeater {
                        model: disk.ioRows.length === 1 ? [] : disk.ioRows
                        MonitorStat {
                            required property var modelData
                            width: stats.cell; s: root.s
                            label: modelData.device
                            value: "R " + Monitor.bytes(modelData.readBps, true)
                            sub: "W " + Monitor.bytes(modelData.writeBps, true) + " · busy " + Monitor.number(modelData.busyPct, "%")
                        }
                    }
                }
                // volúmenes: capacidad siempre visible, montajes y tipo en una línea
                Repeater {
                    model: disk.modelData.volumes || []
                    Column {
                        id: vol
                        required property var modelData
                        readonly property real availPct: Monitor.known(vol.modelData.availableB) && vol.modelData.totalB > 0 ? vol.modelData.availableB * 100 / vol.modelData.totalB : NaN
                        width: disk.width
                        spacing: 4 * root.s
                        Item {
                            width: parent.width
                            height: 18 * root.s
                            Text {
                                anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                width: parent.width * 0.55; elide: Text.ElideRight
                                text: (vol.modelData.label || vol.modelData.device) + "  ·  " + vol.modelData.fsType + "  ·  " + vol.modelData.mounts.join(", ")
                                color: Theme.fg
                                font.family: Typography.ui; font.pixelSize: Typography.label * root.s
                            }
                            Text {
                                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                text: Monitor.bytes(vol.modelData.availableB) + " available of " + Monitor.bytes(vol.modelData.totalB)
                                color: vol.availPct < 10 ? Theme.warn : Theme.fgVariant
                                font.family: Typography.mono; font.pixelSize: Typography.label * root.s
                            }
                        }
                        Rectangle {
                            width: parent.width; height: 6 * root.s; radius: Metrics.pill(height); color: Theme.hair
                            Rectangle {
                                height: parent.height; radius: parent.radius
                                width: parent.width * (Monitor.known(vol.modelData.usedPct) ? Math.max(0, Math.min(1, vol.modelData.usedPct / 100)) : 0)
                                color: vol.availPct < 10 ? Theme.warn : Theme.fam(palette.accent).fill
                            }
                        }
                        Text {
                            visible: vol.modelData.ioDevice === null
                            text: "Spans several devices: I/O is shown per device above, not per volume"
                            color: Theme.fgVariant
                            font.family: Typography.ui; font.pixelSize: Typography.micro * root.s
                        }
                    }
                }
                Repeater {
                    model: disk.ioRows
                    MonitorGraph {
                        required property var modelData
                        width: disk.width; s: root.s; plotHeight: 56
                        title: modelData.device + " · I/O"; unit: "B/s"
                        series: [{key: "io/" + modelData.device + "/read", label: "Read"}, {key: "io/" + modelData.device + "/write", label: "Write"}]
                    }
                }
                Item { width: 1; height: 4 * root.s }
            }
        }
    }
}
