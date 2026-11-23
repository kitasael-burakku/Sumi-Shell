import QtQuick
import "../theme"

/**
 * Los cuatro medidores del Lock en 2 × 2 (fase 15, LOCK-D09): CPU, temperatura de CPU, RAM y disco
 * raíz. Fijos: no hay selector de métricas (§12). `metrics` = { cpu, cpuTemp, ram, disk }, cada uno
 * con el contrato de `MetricTile`.
 */
Item {
    id: root

    property real s: 1
    property var metrics: ({})

    readonly property var m: root.metrics || ({})
    readonly property real spacing: Metrics.sp2 * root.s
    readonly property real tileW: (root.width - root.spacing) / 2
    readonly property real tileH: 64 * root.s

    implicitHeight: root.tileH * 2 + root.spacing

    Grid {
        columns: 2
        columnSpacing: root.spacing
        rowSpacing: root.spacing

        MetricTile { width: root.tileW; height: root.tileH; s: root.s; label: "CPU"; metric: root.m.cpu }
        MetricTile { width: root.tileW; height: root.tileH; s: root.s; label: "CPU TEMP"; metric: root.m.cpuTemp }
        MetricTile { width: root.tileW; height: root.tileH; s: root.s; label: "RAM"; metric: root.m.ram }
        MetricTile { width: root.tileW; height: root.tileH; s: root.s; label: "DISK  /"; metric: root.m.disk }
    }
}
