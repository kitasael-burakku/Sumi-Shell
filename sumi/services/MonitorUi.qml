pragma Singleton

import QtQuick
import Quickshell

/**
 * La UI de inspección de System Monitor (antes de la fase 12, `rediseno/Antes-de-fase-12.md`): el
 * ESTADO de su vista. Los datos no viven aquí: son de `Sysmon`, el mismo recolector que usan la
 * barra y la surface compacta (nivel "inspect" mientras esta UI está abierta).
 *
 * Una sola instancia lógica, como la tienda de Wallhaven: `open` + `screen`. La abren Super+Ctrl+Y,
 * los Details de la surface, el Dashboard y el IPC, todos por `core/Screens.monitorOn`; pedirla en
 * otra pantalla la LLEVA allí. Cerrarla suelta la reclamación (Sysmon baja a detail o se para) pero
 * conserva sección, rango y búsqueda.
 *
 * Live / Paused: pausar CONGELA LA VISTA (una copia por referencia de lo publicado: Sysmon reasigna
 * sus listas en cada muestra, nunca las muta), no el muestreo. La barra, la surface y el historial
 * siguen avanzando; Resume live vuelve al presente. Cerrar la UI también reanuda.
 */
Singleton {
    id: root

    property bool open: false
    property string screen: ""
    property var positions: ({})
    property var layer: null
    property int opens: 0

    readonly property var sections: [
        {id: "overview", label: "Overview", glyph: "gauge"},
        {id: "cpu", label: "CPU", glyph: "gauge"},
        {id: "gpu", label: "GPU", glyph: "tv"},
        {id: "memory", label: "Memory", glyph: "server"},
        {id: "processes", label: "Processes", glyph: "window"},
        {id: "disks", label: "Disks", glyph: "hibernate"},
        {id: "network", label: "Network", glyph: "ethernet"},
        {id: "sensors", label: "Sensors", glyph: "alert"}
    ]
    property string section: "overview"
    /** Ventana temporal: 60 s = muestras de 1 s; el resto, cubos de 5 s de la tendencia. */
    readonly property var ranges: [
        {id: "60s", label: "60 s", ms: 60000}, {id: "5m", label: "5 m", ms: 300000},
        {id: "15m", label: "15 m", ms: 900000}, {id: "1h", label: "1 h", ms: 3600000}
    ]
    property string range: "60s"
    readonly property real rangeMs: (root.ranges.find(r => r.id === root.range) || root.ranges[0]).ms

    // ---- live / paused --------------------------------------------------------------------
    property bool paused: false
    property var frozen: null
    function pause() {
        if (root.paused || !Sysmon.current) return false;
        root.frozen = {current: Sysmon.current, history: Sysmon.history, trend: Sysmon.trend,
            processList: Sysmon.processList, processListInfo: Sysmon.processListInfo,
            sensors: Sysmon.sensors, sensorPeaks: Sysmon.sensorPeaks, alerts: Sysmon.alerts, focus: Sysmon.focus};
        root.paused = true;
        return true;
    }
    function resume() { root.paused = false; root.frozen = null; return true; }
    function togglePause() { return root.paused ? root.resume() : root.pause(); }

    /** Lo que pinta la vista: lo congelado en pausa, lo publicado en vivo. */
    readonly property var current: root.paused ? root.frozen.current : Sysmon.current
    readonly property var history: root.paused ? root.frozen.history : Sysmon.history
    readonly property var trend: root.paused ? root.frozen.trend : Sysmon.trend
    readonly property var processList: root.paused ? root.frozen.processList : Sysmon.processList
    readonly property var processListInfo: root.paused ? root.frozen.processListInfo : Sysmon.processListInfo
    readonly property var sensors: root.paused ? root.frozen.sensors : Sysmon.sensors
    readonly property var sensorPeaks: root.paused ? root.frozen.sensorPeaks : Sysmon.sensorPeaks
    readonly property var alerts: root.paused ? root.frozen.alerts : Sysmon.alerts
    readonly property var focus: root.paused ? root.frozen.focus : Sysmon.focus
    /** Las filas de la ventana elegida: muestras (60 s) o cubos (5 m…1 h). */
    readonly property bool usesTrend: root.range !== "60s"
    readonly property var rows: root.usesTrend ? root.trend : root.history
    /** Lo que ya cubre la tendencia: la ventana larga se va llenando desde que se abrió un monitor. */
    readonly property real coveredMs: {
        const r = root.rows;
        if (!r.length) return 0;
        return r[r.length - 1].monoMs - (r[0].startMs !== undefined ? r[0].startMs : r[0].monoMs);
    }
    readonly property bool warmingUp: root.coveredMs < root.rangeMs - (root.usesTrend ? 10000 : 2000)

    // ---- procesos --------------------------------------------------------------------------
    property string query: ""
    /** "cpu" | "memory" | "pid" | "name" */
    property string sortKey: "cpu"
    property bool showKernel: false
    /** El proceso elegido, por identidad (pid + arranque): un PID reutilizado no hereda la selección. */
    property int selectedPid: 0
    property int selectedStart: 0
    function select(pid, startTicks) {
        root.selectedPid = pid; root.selectedStart = startTicks;
        return true;
    }
    readonly property var selectedRow: {
        if (!root.selectedPid) return null;
        return root.processList.find(r => r.pid === root.selectedPid && r.startTicks === root.selectedStart) || null;
    }
    /** El recolector sólo lee /proc/PID del elegido, y sólo con la UI abierta. */
    readonly property string focusWanted: root.open && root.selectedPid ? root.selectedPid + ":" + root.selectedStart : ""
    onFocusWantedChanged: Sysmon.setFocus(root.focusWanted ? root.selectedPid : 0, root.selectedStart)

    /**
     * La UI abierta (y no tapada por el bloqueo) pide inspect; cerrada, nada. Sin `Claim` (es de
     * components/, que importa servicios): el singleton vive lo que el shell, basta reaccionar.
     */
    readonly property bool claiming: root.open && !Lock.engaged
    onClaimingChanged: Sysmon.claim("monitor-ui", root.claiming ? "inspect" : "")

    // ---- abrir / cerrar ---------------------------------------------------------------------
    function show(name, section) {
        if (!name) return false;
        if (section && root.sections.some(s => s.id === section)) root.section = section;
        root.screen = name;
        if (!root.open) root.opens++;
        root.open = true;
        return true;
    }
    function close() {
        root.open = false;
        root.resume();
        return true;
    }
    /** Mismo sitio, abierta y sin sección pedida (o la misma) → cierra; si no, se muestra allí. */
    function toggle(name, section) {
        if (root.open && root.screen === name && (!section || section === root.section)) return root.close();
        return root.show(name, section);
    }
    function positionOf(name) { return root.positions[name] || null; }
    function remember(name, x, y) {
        const p = Object.assign({}, root.positions);
        p[name] = {x: Math.round(x), y: Math.round(y)};
        root.positions = p;
    }

    function summary() {
        return {open: root.open, screen: root.screen, opens: root.opens, section: root.section, range: root.range,
            paused: root.paused, frozenId: root.frozen && root.frozen.current ? root.frozen.current.id : "",
            shownId: root.current ? root.current.id : "", rows: root.rows.length, coveredS: Math.round(root.coveredMs / 1000),
            warmingUp: root.warmingUp, query: root.query, sortKey: root.sortKey, showKernel: root.showKernel,
            selected: root.selectedPid ? {pid: root.selectedPid, startTicks: root.selectedStart, present: !!root.selectedRow} : null,
            positions: root.positions, layer: root.layer ? root.layer.geometry() : null};
    }
}
