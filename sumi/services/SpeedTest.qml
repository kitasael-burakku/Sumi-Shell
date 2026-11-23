pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Prueba de velocidad (Network → Speed test, 2026-11-14). Plan: `.claude/plans`, informe al entregar.
 *
 * LA PRUEBA ES DEL SERVICIO, NO DE LA VISTA (como `Jobs`): cerrar la superficie no la cancela; dura como mucho
 * ~25 s y está acotada en datos. Al reabrir se ve el estado vivo o el resultado.
 *
 * Quien mide es `scripts/speedtest.py` (stdlib, contra el borde de Cloudflare), con un protocolo de líneas JSON y
 * códigos de error estables: aquí no se lee ni una palabra de texto localizado. Dos invocaciones:
 *   path   sin HTTP: por dónde saldría el tráfico y si NetworkManager lo marca como medido → si lo está, la fase
 *          `confirm` espera a que el usuario acepte el gasto ANTES de mandar un byte.
 *   run    latencia → bajada → subida, con parciales cada 250 ms.
 *
 * MÁQUINA DE ESTADOS (una sola autoridad: `receive`/`finish`/`cancel`; nada más escribe `phase`):
 *   idle ─start→ preflight ─(medida)→ confirm ─confirm→ latency → download → upload → done
 *                     └─────────(no medida)────────────────┘
 *   activa ─cancel / cambio de red / bloqueo→ cancelled      activa ─error / fin sin `end` / sin respuesta→ failed
 *
 * UN SOLO TEST: un worker con ÉPOCA (patrón de `Sysmon`); las líneas de otra época se tiran. Al cancelar, la fase
 * cambia YA (la vista no espera al proceso) y el worker viejo se despide con `cancel` → SIGTERM → SIGKILL; mientras
 * se va (`stopping`) no se puede empezar otro, así nunca hay dos midiendo a la vez.
 *
 * LIMPIEZA. Recarga en caliente: `onDestruction` cierra stdin (EOF) y el helper sale. Reinicio o caída de la shell:
 * el cgroup de la unidad y PR_SET_PDEATHSIG del helper. El helper tiene además su propio plazo absoluto.
 *
 * Ausencia nunca es cero: las cifras sin medir son NaN (JSON null en `summary()`).
 */
Singleton {
    id: root

    readonly property string helper: Quickshell.shellDir + "/scripts/speedtest.py"

    /** SÓLO PRUEBAS (IPC `speedtestTestCommand`): opciones extra del helper, p. ej. `--fake slow --secs 2`. */
    property var testArgs: []

    // ---- estado plano (lo que leen la vista, el cohete y el IPC) ------------------------------------

    property string phase: "idle"
    readonly property var runningPhases: ["preflight", "latency", "download", "upload"]
    readonly property bool busy: root.runningPhases.indexOf(root.phase) >= 0
    /** Hay algo en curso que pide atención: midiendo o esperando la confirmación. */
    readonly property bool active: root.busy || root.phase === "confirm"
    /** El worker anterior aún se está yendo (cancelado o con la fase ya cerrada). */
    property bool stopping: false
    readonly property bool canStart: !root.active && !root.stopping

    /** Mb/s de la ventana de 1 s de la fase en curso (lo que mueve el cohete). */
    property real liveMbps: NaN
    property int pings: 0
    property real latencyMs: NaN
    property real jitterMs: NaN
    property real downMbps: NaN
    property real upMbps: NaN
    property real phaseProgress: 0
    property bool capped: false
    /** El servidor cortó una fase (429/403) con medida suficiente: el resultado vale, de una ventana más corta. */
    property bool limited: false
    property bool cpuBound: false
    /** { dev, kind, metered, family, colo } del helper. `kind`: ethernet · wifi · vpn · loopback · other. */
    property var path: null
    property string errorCode: ""
    property string errorDetail: ""
    property double startedAt: 0
    property double endedAt: 0

    /** 0-1 de toda la prueba: latencia 10 %, bajada y subida 45 % cada una. */
    readonly property real progress: {
        switch (root.phase) {
        case "latency": return 0.1 * root.pings / 10;
        case "download": return 0.1 + 0.45 * root.phaseProgress;
        case "upload": return 0.55 + 0.45 * root.phaseProgress;
        case "done": return 1;
        default: return 0;
        }
    }

    readonly property var messages: ({
        "offline": "You're offline. Connect to a network and try again.",
        "dns": "Couldn't find the test server. Check your connection or DNS.",
        "connect": "Couldn't reach the test server.",
        "tls": "The secure connection to the test server failed.",
        "timeout": "The test server took too long to answer.",
        "stalled": "The transfer stalled. Try again.",
        "refused": "The test server refused the test. Try again later.",
        "ratelimited": "Cloudflare is limiting tests for now. Try again in a few minutes.",
        "http": "The test server gave an unexpected answer.",
        "internal": "The speed test couldn't run.",
        "unresponsive": "The speed test stopped responding.",
        "network-changed": "The network changed during the test.",
        "locked": "The test stopped when the session locked."
    })
    /** Segundos que pidió esperar el servidor (`Retry-After` de un 429); -1 si no lo dijo. */
    property int retryAfterS: -1
    readonly property string errorText: {
        if (root.errorCode.length === 0) return "";
        if (root.errorCode === "ratelimited" && root.retryAfterS > 0)
            return "Cloudflare is limiting tests for now. Try again in about "
                + Math.max(1, Math.round(root.retryAfterS / 60)) + " min.";
        return root.messages[root.errorCode] || root.messages.internal;
    }

    // ---- el último resultado (sólo uno; nada de historial) -----------------------------------------

    readonly property string resultPath: Settings.stateDir + "/speedtest.json"
    property var lastResult: null

    FileView {
        id: resultFile
        path: root.resultPath
        blockLoading: true
        blockWrites: true
        printErrors: false
        onLoaded: {
            try {
                const d = JSON.parse(resultFile.text());
                root.lastResult = (d && d.v === 1 && typeof d.down === "number") ? d : null;
            } catch (e) {
                root.lastResult = null;
            }
        }
    }

    function saveResult() {
        const d = {
            v: 1, at: root.endedAt, latency: root.latencyMs, jitter: root.jitterMs,
            down: root.downMbps, up: root.upMbps, capped: root.capped, limited: root.limited,
            kind: root.path ? root.path.kind : "", colo: root.path ? (root.path.colo || "") : ""
        };
        root.lastResult = d;
        // Escritura inmediata: con SIGTERM la shell no destruye el QML (nada de «guardar al salir»).
        resultFile.setText(JSON.stringify(d, null, 1));
    }

    // ---- la red con la que empezó (para cancelar si cambia) ------------------------------------------

    property string startKind: ""
    property string startIf: ""

    function networkMoved() {
        if (!root.active) return;
        if (Net.kind !== root.startKind || Net.ifname !== root.startIf)
            root.cancel("network-changed");
    }

    Connections {
        target: Net
        function onKindChanged() { root.networkMoved(); }
        function onIfnameChanged() { root.networkMoved(); }
    }

    Connections {
        target: Lock
        function onEngagedChanged() { if (Lock.engaged && root.active) root.cancel("locked"); }
    }

    // ---- órdenes -----------------------------------------------------------------------------------

    function clearNumbers() {
        root.liveMbps = NaN;
        root.pings = 0;
        root.latencyMs = NaN;
        root.jitterMs = NaN;
        root.downMbps = NaN;
        root.upMbps = NaN;
        root.phaseProgress = 0;
        root.capped = false;
        root.limited = false;
        root.cpuBound = false;
        root.path = null;
        root.errorCode = "";
        root.errorDetail = "";
        root.retryAfterS = -1;
    }

    /** Empezar (o repetir). false si ya hay una en curso o la anterior aún se está yendo. */
    function start() {
        if (!root.canStart) return false;
        root.clearNumbers();
        root.startedAt = Date.now();
        root.endedAt = 0;
        root.startKind = Net.kind;
        root.startIf = Net.ifname;
        if (Net.ready && !Net.connected) {
            root.errorCode = "offline";
            root.endedAt = Date.now();
            root.phase = "failed";
            return true;
        }
        root.phase = "preflight";
        root.spawn("path");
        return true;
    }

    /** El usuario acepta gastar datos en una conexión medida. */
    function confirm() {
        if (root.phase !== "confirm" || root.stopping) return false;
        root.phase = "latency";
        root.spawn("run");
        return true;
    }

    /** Cancelar: la fase cambia ya; el proceso se despide por detrás. `reason` vacío = lo pidió el usuario. */
    function cancel(reason) {
        if (!root.active) return false;
        const why = reason || "";
        root.retire();
        root.errorCode = why;
        root.errorDetail = "";
        root.liveMbps = NaN;
        root.endedAt = Date.now();
        root.phase = "cancelled";
        return true;
    }

    /** Volver a reposo desde un resultado (la vista lo usa al descartar un error). */
    function dismiss() {
        if (root.active) return false;
        root.phase = "idle";
        return true;
    }

    // ---- el worker ---------------------------------------------------------------------------------

    property int epoch: 0
    property var worker: null
    property string stage: ""

    function spawn(stage) {
        root.epoch++;
        root.stage = stage;
        const argv = ["python3", "-u", root.helper, stage].concat(root.testArgs);
        const w = workerFactory.createObject(root, { epoch: root.epoch, command: argv });
        root.worker = w;
        w.stdinEnabled = true;          // antes de cada arranque (lección de Clip: si no, EOF no llega)
        w.running = true;
        watchdog.restart();
    }

    /**
     * Soltar el worker actual: nadie más lee sus líneas (otra época) y se le pide que se vaya. `stopping` dura
     * hasta que su proceso sale de verdad; si no sale, SIGTERM y luego SIGKILL.
     */
    function retire() {
        watchdog.stop();
        const w = root.worker;
        root.worker = null;
        root.epoch++;
        if (!w) return;
        if (!w.running) { w.destroy(); return; }
        root.stopping = true;
        try { w.write("cancel\n"); } catch (e) {}
        w.retired = true;
        w.stdinEnabled = false;         // EOF: el helper sale aunque no haya leído «cancel»
        w.escalate.start();
    }

    function finish(state, code, detail) {
        root.retire();
        root.liveMbps = NaN;
        root.endedAt = Date.now();
        root.errorCode = state === "failed" ? (code || "internal") : (code || "");
        root.errorDetail = detail || "";
        root.phase = state;
        if (state === "done") root.saveResult();
    }

    function num(v) { return typeof v === "number" && isFinite(v) ? v : NaN; }

    function receive(text, ep) {
        if (ep !== root.epoch) return;
        let o;
        try { o = JSON.parse(text); } catch (e) { return; }      // una línea rota no tumba la prueba
        if (!o || typeof o.t !== "string") return;
        watchdog.restart();
        switch (o.t) {
        case "hello":
            if (o.v !== 1) root.finish("failed", "internal", "Unknown speed test protocol");
            return;
        case "path":
            root.path = { dev: String(o.dev || ""), kind: String(o.kind || "other"), metered: o.metered === true,
                          family: root.num(o.family), colo: String(o.colo || "") };
            if (root.stage === "path") {
                if (o.metered === true) {
                    root.retire();
                    root.phase = "confirm";
                } else {
                    root.phase = "latency";
                    root.spawn("run");
                }
            }
            return;
        case "phase":
            if (o.name === "latency" || o.name === "download" || o.name === "upload") {
                root.phase = o.name;
                root.phaseProgress = 0;
                root.liveMbps = NaN;
            }
            return;
        case "ping":
            root.pings = Math.max(0, Math.min(10, o.i | 0));
            return;
        case "latency":
            root.latencyMs = root.num(o.ms);
            root.jitterMs = root.num(o.jitter);
            return;
        case "down":
        case "up":
            root.liveMbps = root.num(o.mbps);
            root.phaseProgress = Math.max(0, Math.min(1, root.num(o.progress) || 0));
            return;
        case "downDone":
            root.downMbps = root.num(o.mbps);
            root.capped = root.capped || o.capped === true;
            root.limited = root.limited || o.limited === true;
            root.cpuBound = root.cpuBound || o.cpuBound === true;
            return;
        case "upDone":
            root.upMbps = root.num(o.mbps);
            root.capped = root.capped || o.capped === true;
            root.limited = root.limited || o.limited === true;
            root.cpuBound = root.cpuBound || o.cpuBound === true;
            return;
        case "error":
            root.errorCode = String(o.code || "internal");
            root.errorDetail = String(o.detail || "");
            root.retryAfterS = typeof o.retryAfter === "number" && isFinite(o.retryAfter) ? Math.round(o.retryAfter) : -1;
            return;
        case "end":
            if (o.state === "done") root.finish("done", "", "");
            else if (o.state === "cancelled") root.finish("cancelled", root.errorCode, "");
            else root.finish("failed", String(o.code || root.errorCode || "internal"), root.errorDetail);
            return;
        }
    }

    /** El proceso de esta época terminó. Si fue `path` y ya se pasó a `run`, la época es otra y no llega aquí. */
    function exited(ep, started) {
        if (ep !== root.epoch || !root.active) return;
        if (!started) { root.finish("failed", "internal", "The speed test helper couldn't start"); return; }
        if (root.stage === "path" && root.phase === "confirm") return;
        root.finish("failed", root.errorCode || "internal", root.errorDetail || "The speed test stopped unexpectedly");
    }

    Component {
        id: workerFactory
        Process {
            id: proc
            property int epoch: -1
            property bool began: false
            property bool retired: false
            property bool gone: false
            stdout: SplitParser { onRead: data => root.receive(data, proc.epoch) }
            stderr: StdioCollector {}
            onStarted: proc.began = true
            onRunningChanged: if (!running) Qt.callLater(proc.ended)
            function ended() {
                if (proc.gone || proc.running) return;
                proc.gone = true;
                proc.escalate.stop();
                if (proc.retired) root.stopping = false;     // nunca hay dos retirados: start() espera a éste
                else root.exited(proc.epoch, proc.began);
                proc.destroy();
            }
            /** cancel/EOF → 1,5 s → SIGTERM → 1,5 s → SIGKILL. */
            property Timer escalate: Timer {
                interval: 1500
                property int step: 0
                onTriggered: {
                    if (!proc.running) return;
                    proc.signal(step === 0 ? 15 : 9);
                    step++;
                    if (step < 2) restart();
                }
            }
        }
    }

    /** Sin una línea en 8 s con la prueba en marcha: el helper se colgó (la prueba en sí emite cada 250 ms). */
    Timer {
        id: watchdog
        interval: 8000
        onTriggered: if (root.busy) root.finish("failed", "unresponsive", "")
    }

    Component.onDestruction: {
        const w = root.worker;
        if (w) w.stdinEnabled = false;      // EOF: el helper sale con la recarga
    }

    // ---- IPC ---------------------------------------------------------------------------------------

    /**
     * SÓLO PRUEBAS: opciones del helper como `fake=slow secs=2` (sin guiones: `qs ipc call` se come los argumentos
     * que empiezan por `--`). "" las quita. Sólo claves conocidas y valores sin espacios ni comillas.
     */
    function setTestArgs(text) {
        const parts = String(text || "").trim().split(/\s+/).filter(s => s.length > 0);
        const keys = ["fake", "secs", "streams", "base", "family", "budget-down-mb", "budget-up-mb", "deadline"];
        const vals = /^[A-Za-z0-9_.:\/\[\]-]+$/;
        const argv = [];
        for (const p of parts) {
            const i = p.indexOf("=");
            const k = i > 0 ? p.slice(0, i) : "", v = i > 0 ? p.slice(i + 1) : "";
            if (keys.indexOf(k) < 0 || !vals.test(v)) return false;
            argv.push("--" + k, v);
        }
        root.testArgs = argv;
        return true;
    }

    function summary() {
        return {
            phase: root.phase, busy: root.busy, active: root.active, stopping: root.stopping,
            canStart: root.canStart, progress: root.progress, liveMbps: root.liveMbps, pings: root.pings,
            latencyMs: root.latencyMs, jitterMs: root.jitterMs, downMbps: root.downMbps, upMbps: root.upMbps,
            capped: root.capped, limited: root.limited, cpuBound: root.cpuBound, path: root.path,
            errorCode: root.errorCode, errorText: root.errorText, errorDetail: root.errorDetail,
            retryAfterS: root.retryAfterS,
            startedAt: root.startedAt, endedAt: root.endedAt, epoch: root.epoch, stage: root.stage,
            worker: !!root.worker, lastResult: root.lastResult, testArgs: root.testArgs
        };
    }
}
