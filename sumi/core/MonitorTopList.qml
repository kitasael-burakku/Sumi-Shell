import QtQuick
import "../theme"
import "../services"
import "../lib/monitor.js" as Monitor

/**
 * Los mayores consumidores de un recurso, de la lista entera de procesos (inspect). Una fila lleva a
 * Processes con ese proceso elegido. Sin lista todavía: lo dice, no inventa un cero.
 */
Column {
    id: root
    property real s: 1
    /** "cpu" | "memory" */
    property string kind: "cpu"
    property int count: 6
    readonly property var rows: {
        const list = MonitorUi.processList.filter(r => root.kind === "cpu" ? typeof r.cpuPct === "number" : true);
        list.sort((a, b) => root.kind === "cpu" ? b.cpuPct - a.cpuPct : b.memoryB - a.memoryB);
        return list.slice(0, root.count);
    }
    spacing: 2 * root.s
    Text {
        visible: root.rows.length === 0
        width: parent.width; wrapMode: Text.Wrap
        text: !MonitorUi.processListInfo ? "Reading processes…"
              : root.kind === "cpu" && MonitorUi.processListInfo.cpuState !== "ok" ? "CPU use needs a second reading…" : "No processes"
        color: Theme.fgVariant
        font.family: Typography.ui; font.pixelSize: Typography.label * root.s
    }
    Repeater {
        model: root.rows
        Rectangle {
            id: row
            required property var modelData
            width: root.width
            height: 34 * root.s
            radius: Metrics.r(6) * root.s
            color: Theme.controlBg(Theme.tileBg, rowArea.containsMouse, rowArea.pressed && rowArea.containsMouse, false, Theme.fam(palette.accent))
            Behavior on color { ColorAnimation { duration: Motion.fast } }
            Text {
                x: 8 * root.s; width: 64 * root.s; anchors.verticalCenter: parent.verticalCenter
                text: row.modelData.pid
                color: Theme.fgVariant
                font.family: Typography.mono; font.pixelSize: Typography.label * root.s
            }
            Text {
                x: 76 * root.s; width: Math.max(0, parent.width - x - 150 * root.s); anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                text: row.modelData.name
                color: Theme.fg
                font.family: Typography.ui; font.pixelSize: Typography.label * root.s
            }
            Text {
                anchors.right: parent.right; anchors.rightMargin: 8 * root.s; anchors.verticalCenter: parent.verticalCenter
                width: 140 * root.s; horizontalAlignment: Text.AlignRight
                text: root.kind === "cpu" ? Monitor.number(row.modelData.cpuPct, "%", 1) + "  ·  " + Monitor.bytes(row.modelData.memoryB)
                                          : Monitor.bytes(row.modelData.memoryB) + "  ·  " + Monitor.number(row.modelData.memoryPct, "%", 1)
                color: Theme.fg
                font.family: Typography.mono; font.pixelSize: Typography.label * root.s
            }
            MouseArea {
                id: rowArea
                Accessible.role: Accessible.ListItem
                Accessible.name: String(row.modelData.name || "")
                Accessible.onPressAction: { MonitorUi.select(row.modelData.pid, row.modelData.startTicks); MonitorUi.section = "processes"; }
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { MonitorUi.select(row.modelData.pid, row.modelData.startTicks); MonitorUi.section = "processes"; }
            }
        }
    }
    Text {
        visible: root.rows.length > 0
        text: root.kind === "cpu" ? "CPU: 100% = one logical core" : "Resident memory (RSS)"
        color: Theme.fgVariant
        font.family: Typography.ui; font.pixelSize: Typography.micro * root.s
    }
}
