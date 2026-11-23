pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/monitor-alerts.js" as Alerts

// Una sola fuente de muestras. El detalle posee historial y procesos; summary no.
// Tres niveles (antes de la fase 12, M1): summary (barra, 5 s), detail (la surface compacta, 1 s,
// 60 s de historial) e inspect (la UI de inspección: además lista entera de procesos, sensores,
// frecuencia por núcleo y el proceso elegido). detail ↔ inspect no reinicia el recolector: sólo
// cambia lo que se pide, y el historial sigue. La tendencia de 1 h (cubos de 5 s) existe mientras
// haya una vista de monitor abierta (detail o inspect), por decisión del usuario del 2026-09-27.
Singleton {
    id: root
    property var claims: ({})
    readonly property int watchers: Object.keys(root.claims).length
    readonly property var ranks: ({summary: 1, detail: 2, inspect: 3})
    readonly property string wanted: {
        let level = "";
        for (const who in root.claims)
            if ((root.ranks[root.claims[who]] || 0) > (root.ranks[level] || 0)) level = root.claims[who];
        return level;
    }
    /**
     * Lo que reclama la pantalla de bloqueo (`lock:…`, fase 15D, LK-13). Con la sesión bloqueada el
     * usuario está en reposo por definición, y `Session.idle` congelaría las métricas del panel a la
     * vista. En reposo sólo cuenta ESTO: el resto de consumidores no cambia de política (con un Lock
     * reclamando summary, un detail ajeno no sube el nivel mientras dura el reposo).
     */
    readonly property string pinned: {
        let level = "";
        for (const who in root.claims)
            if (who.indexOf("lock:") === 0 && (root.ranks[root.claims[who]] || 0) > (root.ranks[level] || 0))
                level = root.claims[who];
        return level;
    }
    readonly property string level: Session.idle ? root.pinned : root.wanted
    readonly property bool active: root.level !== ""
    readonly property bool detail: root.level === "detail" || root.level === "inspect"
    readonly property bool inspect: root.level === "inspect"
    property string lastLevel: ""
    property string testRoot: ""
    readonly property bool testing: root.testRoot !== ""
    property int generation: 0
    property int ticks: 0
    property var current: null
    property var history: []
    property var processSamples: []
    property var worker: null
    property bool pending: false
    property string error: ""
    property bool initialized: false

    // ---- M1: tendencia, inspección y alertas -------------------------------------------------
    /** Cubos cerrados de 5 s (media `v` y máximo `hi` por métrica), hasta 720 = 1 h. */
    property var trend: []
    property var bucket: null
    readonly property int bucketMs: 5000
    readonly property int trendLimit: 720
    /** Claves que alguna vez tuvieron valor en esta generación (para «lectura perdida»). */
    property var seen: ({})
    property var alerts: []
    /** inspect: la última lista entera de procesos (nunca en el historial) y su paquete. */
    property var processList: []
    property var processListInfo: null
    property var sensors: null
    /** Máximo visto por sensor desde que se abrió la inspección. */
    property var sensorPeaks: ({})
    /** El proceso elegido en la UI ({pid, startTicks}) y lo leído de él en la última muestra. */
    property var focusTarget: null
    property var focus: null

    function claim(who, level) {
        if (!who) return;
        const value = level === "summary" || level === "detail" || level === "inspect" ? level : level ? "detail" : "";
        if ((root.claims[who] || "") === value) return;
        const next = Object.assign({}, root.claims);
        if (value) next[who] = value; else delete next[who];
        root.claims = next;
    }
    function setTestRoot(path) {
        if (root.watchers || root.worker || root.pending) return false;
        if (path !== "" && (!/^\/tmp\/[A-Za-z0-9_./-]+$/.test(path) || path.split("/").indexOf("..") >= 0)) return false;
        root.testRoot = path;
        root.reset();
        return true;
    }
    function reset(start) {
        root.generation++;
        deadline.stop(); restart.stop(); root.pending = false;
        const old = root.worker; root.worker = null;
        // EOF termina también al recargar; no dejamos un recolector huérfano.
        if (old) { old.stdinEnabled = false; old.running = false; old.destroy(); }
        root.current = null; root.error = "";
        root.clearHistory();
        if (start !== false && root.active && root.initialized) {
            root.worker = workerFactory.createObject(root, {
                command: ["python3", "-u", Quickshell.shellDir + "/scripts/sysmon-collect.py", root.testRoot]});
            root.worker.running = true;
        }
    }
    function clearHistory() {
        root.history = []; root.processSamples = [];
        root.trend = []; root.bucket = null; root.seen = {}; root.alerts = [];
        root.dropInspect();
    }
    function dropInspect() {
        root.processList = []; root.processListInfo = null; root.sensors = null;
        root.sensorPeaks = {}; root.focus = null;
    }
    /**
     * Esperar a los bindings derivados: active/detail aún pueden llevar el valor anterior. Entre
     * detail e inspect el recolector y el historial siguen (abrir la UI con la surface abierta no
     * vacía las gráficas); lo propio de inspect se suelta al bajar a detail.
     */
    function levelMoved() {
        if (!root.initialized) return;
        const was = root.lastLevel, now = root.level;
        root.lastLevel = now;
        if (was === now) return;
        if (was && now && root.worker && root.worker.running) {
            if (was === "summary" || now === "summary") {
                // Una nueva ventana de historial, con la CPU y su última muestra continuas.
                root.generation++;
                root.clearHistory();
                root.poll();
            } else if (now !== "inspect") root.dropInspect();
            return;
        }
        root.reset();
    }
    onLevelChanged: Qt.callLater(root.levelMoved)
    Component.onCompleted: { root.initialized = true; root.levelMoved(); }
    Component.onDestruction: if (root.worker) root.worker.stdinEnabled = false

    function poll() {
        if (!root.active || !root.worker || !root.worker.running || root.pending) return false;
        root.pending = true;
        deadline.restart();
        const request = {level: root.level, generation: root.generation};
        if (root.inspect && root.focusTarget) request.focus = root.focusTarget;
        root.worker.requestGeneration = root.generation;
        root.worker.write(JSON.stringify(request) + "\n");
        return true;
    }
    function receive(text, owner) {
        if (owner !== root.worker) return;
        deadline.stop(); root.pending = false;
        if (!root.active) return;
        let packet;
        try { packet = JSON.parse(text); } catch (e) { root.fail("Could not read system metrics"); return; }
        if (!packet.sample || packet.generation !== owner.requestGeneration) { root.fail("Could not read system metrics"); return; }
        // La petición anterior aún estaba en vuelo cuando cambió el nivel.
        if (packet.generation !== root.generation) { root.poll(); return; }
        const sample = packet.sample;
        sample.id = root.generation + ":" + sample.id;
        if (sample.processSampleId !== null) sample.processSampleId = root.generation + ":" + sample.processSampleId;
        const processes = sample.processes;
        if (processes) processes.sampleId = sample.id;
        // Un solo paquete de procesos por intervalo, sin duplicarlo dentro del historial.
        delete sample.processes;
        const all = processes && processes.all ? processes.all : null;
        if (processes) delete processes.all;
        const sensors = sample.sensors, focus = sample.focus;
        delete sample.sensors; delete sample.focus;
        // detail e inspect comparten recolector: una respuesta pedida con el otro nivel vale.
        const deep = l => l === "detail" || l === "inspect";
        if (sample.level !== root.level && !(deep(sample.level) && deep(root.level))) return;
        root.error = "";
        sample.v = root.flatten(sample);
        // Publicación única: el número actual y la última muestra son el mismo objeto.
        root.current = sample; root.ticks++;
        if (root.detail) {
            root.history = root.history.filter(s => s.monoMs > sample.monoMs - 60000).concat([sample]).slice(-60);
            let packets = root.processSamples.filter(p => p.atMonoMs > sample.monoMs - 60000);
            if (processes) packets = packets.concat([processes]);
            root.processSamples = packets.slice(-21);
            root.addTrend(sample);
            const seen = root.seen;
            for (const k in sample.v) if (sample.v[k] !== null) seen[k] = true;
            root.alerts = Alerts.evaluate(root.history, seen);
        }
        if (root.inspect) {
            if (all) {
                root.processList = all;
                root.processListInfo = {sampleId: processes.sampleId, atMonoMs: processes.atMonoMs, at: sample.at,
                    state: processes.state, scanned: processes.scanned, truncated: processes.truncated,
                    unreadable: processes.unreadable, cpuState: processes.cpuState};
            }
            if (sensors && (!root.sensors || sensors.atMonoMs !== root.sensors.atMonoMs)) {
                root.sensors = sensors;
                const peaks = Object.assign({}, root.sensorPeaks);
                for (const chip of sensors.chips) for (const t of chip.temps)
                    if (!(peaks[t.id] >= t.c)) peaks[t.id] = t.c;
                root.sensorPeaks = peaks;
            }
            root.focus = root.focusTarget ? focus || null : null;
        }
    }
    /**
     * Métricas planas de una muestra, con las mismas unidades que el recolector (%, °C, MHz, B,
     * B/s). Las claves son la única forma en que las gráficas de 60 s y la tendencia nombran una
     * métrica; ids con «:» o «.» (PCI, UUID) van entre barras, nunca se parten.
     */
    function flatten(sample) {
        const v = {};
        const n = x => typeof x === "number" && isFinite(x) ? x : null;
        const c = sample.cpu || {}, m = sample.memory || {}, sw = m.swap || {};
        v["cpu.usage"] = n(c.usagePct); v["cpu.temp"] = n(c.temperatureC); v["cpu.freq"] = n(c.frequencyMHz);
        v["mem.used"] = n(m.usedB); v["mem.avail"] = n(m.availableB); v["mem.cache"] = n(m.cacheB);
        v["mem.psi"] = n(m.pressureSomePct);
        v["swap.used"] = n(sw.usedB); v["swap.in"] = n(sw.inBps); v["swap.out"] = n(sw.outBps);
        const net = sample.network;
        if (net) {
            v["net.rx"] = n(net.rxBps); v["net.tx"] = n(net.txBps);
            for (const i of net.interfaces || []) { v["if/" + i.name + "/rx"] = n(i.rxBps); v["if/" + i.name + "/tx"] = n(i.txBps); }
        }
        for (const g of sample.gpus || []) {
            const k = "gpu/" + g.id + "/";
            v[k + "usage"] = n(g.usagePct); v[k + "temp"] = n(g.temperatureC); v[k + "vram"] = n(g.vramUsedB);
            v[k + "power"] = n(g.powerW); v[k + "freq"] = n(g.frequencyMHz);
        }
        // io.read / io.write: todos los dispositivos (la micrográfica de la surface). Sin ninguno medido, null.
        let reads = null, writes = null;
        for (const d of sample.disks || []) {
            v["disk/" + d.id + "/temp"] = n(d.temperatureC);
            for (const io of d.io || []) {
                const k = "io/" + io.device + "/";
                v[k + "read"] = n(io.readBps); v[k + "write"] = n(io.writeBps); v[k + "busy"] = n(io.busyPct);
                if (n(io.readBps) !== null) reads = (reads || 0) + io.readBps;
                if (n(io.writeBps) !== null) writes = (writes || 0) + io.writeBps;
            }
        }
        if (sample.disks) { v["io.read"] = reads; v["io.write"] = writes; }
        return v;
    }
    /** Cubos de 5 s: media y máximo. Sólo el cubo cerrado entra en `trend` (el abierto aún cambia). */
    function addTrend(sample) {
        let b = root.bucket;
        if (b && (sample.monoMs - b.startMs >= root.bucketMs || sample.monoMs < b.lastMs)) {
            const v = {}, hi = {};
            for (const k in b.sum) { v[k] = b.cnt[k] ? b.sum[k] / b.cnt[k] : null; hi[k] = b.cnt[k] ? b.hi[k] : null; }
            root.trend = root.trend.concat([{monoMs: b.lastMs, startMs: b.startMs, at: b.at, n: b.n, v: v, hi: hi}]).slice(-root.trendLimit);
            b = null;
        }
        if (!b) b = {startMs: sample.monoMs, lastMs: sample.monoMs, at: sample.at, n: 0, sum: {}, cnt: {}, hi: {}};
        for (const k in sample.v) {
            const x = sample.v[k];
            if (!(k in b.sum)) { b.sum[k] = 0; b.cnt[k] = 0; b.hi[k] = null; }
            if (x === null) continue;
            b.sum[k] += x; b.cnt[k]++;
            if (b.hi[k] === null || x > b.hi[k]) b.hi[k] = x;
        }
        b.lastMs = sample.monoMs; b.at = sample.at; b.n++;
        root.bucket = b;
    }
    /** Proceso elegido en la UI; null lo suelta. Sólo se lee con inspect. */
    function setFocus(pid, startTicks) {
        root.focusTarget = pid > 0 ? {pid: pid, startTicks: startTicks} : null;
        root.focus = null;
    }
    function fail(reason) {
        root.reset(false);
        root.error = reason;
        // Un fallo repetido no crea un bucle de procesos sin espera.
        if (root.active) restart.restart();
    }
    function sampleAt(id) {
        if (root.current && root.current.id === id) return root.current;
        return root.history.find(s => s.id === id) || null;
    }
    function processesAt(id) {
        const sample = root.sampleAt(id);
        if (!sample || sample.processSampleId === null) return null;
        return root.processSamples.find(p => p.sampleId === sample.processSampleId
            && p.atMonoMs <= sample.monoMs && sample.monoMs - p.atMonoMs < 4000) || null;
    }
    function historyPage(before, count) {
        const end = before ? root.history.findIndex(s => s.id === before) : root.history.length;
        if (end < 0) return {state: "expired", samples: [], nextBefore: ""};
        let start = Math.max(0, end - Math.max(1, Math.min(8, count)));
        let rows = root.history.slice(start, end);
        // El IPC de qs corta la conexión con respuestas grandes: páginas acotadas.
        while (rows.length > 1 && JSON.stringify(rows).length > 32768) { start++; rows = root.history.slice(start, end); }
        if (JSON.stringify(rows).length > 32768) return {state: "too-large", samples: [], nextBefore: ""};
        return {state: rows.length ? "ok" : "empty", samples: rows,
            nextBefore: start > 0 && rows.length ? rows[0].id : ""};
    }
    function summary(withHistory) {
        return {level: root.level, wanted: root.wanted, claims: root.claims, testing: root.testing,
            testRoot: root.testRoot, generation: root.generation, ticks: root.ticks, pending: root.pending,
            running: !!root.worker && root.worker.running, error: root.error,
            current: root.current, history: withHistory ? root.historyPage("", 8).samples : [], historyCount: root.history.length,
            historyIds: root.history.map(s => s.id), oldestMonoMs: root.history.length ? root.history[0].monoMs : null,
            processSampleCount: root.processSamples.length,
            inspect: root.inspect, trendCount: root.trend.length, trendSpanS: root.trend.length ? Math.round((root.trend[root.trend.length-1].monoMs - root.trend[0].startMs) / 1000) : 0,
            processListCount: root.processList.length, processListInfo: root.processListInfo,
            sensorChips: root.sensors ? root.sensors.chips.length : 0, sensorPeakCount: Object.keys(root.sensorPeaks).length,
            focusTarget: root.focusTarget, focus: root.focus, alerts: root.alerts,
            processSamples: withHistory ? root.processSamples.map(p => ({sampleId: p.sampleId, atMonoMs: p.atMonoMs, state: p.state})) : []};
    }
    function stopped(owner) {
        if (owner !== root.worker || !root.active) return;
        root.pending = false; deadline.stop(); root.current = null;
        root.clearHistory();
        root.error = "System metrics collector stopped";
        restart.restart();
    }
    Component {
        id: workerFactory
        Process {
            id: process
            property int requestGeneration: -1
            stdinEnabled: true
            stdout: SplitParser { onRead: data => root.receive(data, process) }
            stderr: StdioCollector {}
            onStarted: if (process === root.worker) root.poll()
            onExited: code => root.stopped(process)
            onRunningChanged: if (!running) Qt.callLater(() => {
                if (process && !process.running) root.stopped(process);
            })
        }
    }
    Timer { id: restart; interval: 1000; onTriggered: if (root.active) root.reset() }
    Timer { id: deadline; interval: 3500; onTriggered: root.fail("System metrics timed out") }
    Timer { interval: root.detail ? 1000 : 5000; running: root.active; repeat: true; onTriggered: root.poll() }

    // Compatibilidad de los consumidores existentes hasta la 11E-2. Ausencia nunca es cero.
    function metric(o, key) { return o && typeof o[key] === "number" ? o[key] : NaN; }
    readonly property var cpu: root.current ? root.current.cpu : null
    readonly property var memory: root.current ? root.current.memory : null
    readonly property var gpu: root.current && root.current.gpus && root.current.gpus.length ? root.current.gpus[0] : null
    readonly property var volume: {
        if (!root.current || !root.current.disks) return null;
        for (const d of root.current.disks) for (const v of d.volumes) if (v.mounts.indexOf("/") >= 0) return v;
        return null;
    }
    readonly property real cpuPct: root.metric(root.cpu, "usagePct")
    readonly property real cpuTempC: root.metric(root.cpu, "temperatureC")
    readonly property real memTotalKb: root.metric(root.memory, "totalB") / 1024
    readonly property real memAvailKb: root.metric(root.memory, "availableB") / 1024
    readonly property real memUsedKb: root.metric(root.memory, "usedB") / 1024
    readonly property real memPct: root.metric(root.memory, "usedPct")
    readonly property real diskUsedB: root.metric(root.volume, "usedB")
    readonly property real diskTotalB: root.metric(root.volume, "totalB")
    readonly property real diskAvailB: root.metric(root.volume, "availableB")
    readonly property real diskPct: root.metric(root.volume, "usedPct")
    readonly property real gpuPct: root.metric(root.gpu, "usagePct")
    readonly property real gpuTempC: root.metric(root.gpu, "temperatureC")
    readonly property real gpuVramUsedGb: root.metric(root.gpu, "vramUsedB") / 1073741824
    readonly property real gpuVramTotalGb: root.metric(root.gpu, "vramTotalB") / 1073741824
    readonly property real gpuPowerW: root.metric(root.gpu, "powerW")
    readonly property real gpuPowerCapW: root.metric(root.gpu, "powerCapW")
    readonly property bool gpuOk: !!root.gpu
    readonly property string gpuFan: root.gpu && root.gpu.fanRpm !== null ? root.gpu.fanRpm + " RPM" : ""
    readonly property string gpuName: root.gpu ? root.gpu.name : ""

}
