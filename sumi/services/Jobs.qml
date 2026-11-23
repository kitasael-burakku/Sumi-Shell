pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/ansi.js" as Ansi

/**
 * Trabajos del shell (fase 6B, 2026-09-25).
 *
 * Hasta aquí `diskbackup` y `dotbackup` eran `Process` DENTRO de
 * `surfaces/Dashboard`: cerrar el panel (o que el host lo descargara) mataba la
 * copia a medias y su salida. Ahora viven aquí; la vista sólo mira.
 *
 * Cada tipo es un `Runner` con un trabajo a la vez (exclusión por recurso: dos
 * dotbackup sobre el mismo repo no tienen sentido). Estados:
 *
 *   idle         nunca corrió desde que se guarda registro
 *   running      el proceso está vivo
 *   needs-input  dotbackup espera una respuesta (y/n o texto)
 *   succeeded    salió con 0 Y la salida dice que hizo lo pedido
 *   cancelled    lo cancelaste (o dijiste «no» al primer paso): salida 0, nada hecho
 *   failed       salió con otro código, o no pudo arrancar
 *   unknown      el shell se reinició mientras corría: el resultado NO se observó
 *
 * EVIDENCIA, NO SUPOSICIÓN. `dotbackup` sale con 0 tanto si hace push como si
 * lo cancelas: el estado final se decide por el camino que recorrió (qué
 * preguntas se contestaron y cómo), y `summary` lo dice con palabras.
 *
 * CANCELAR sólo donde el propio script sabe parar limpio: en una pregunta
 * y/n que tiene salida de «no» (empezar, commit, push). Se contesta «n»; no se
 * mata nada a mitad de un rsync o de un commit. `diskbackup` no se cancela.
 *
 * PERSISTENCIA. El registro (sin la salida completa: sólo las últimas líneas en
 * texto plano) se escribe en cada cambio de estado —`onDestruction` no corre
 * con `systemctl restart`— y al cargar, lo que estaba vivo pasa a `unknown`.
 *
 * F3d-1 (portabilidad, 2026-10-06; H-14, HC-20…28): los tipos YA NO son fijos. Hay un Runner por tarea
 * `runs: panel` de tasks.json (services/Tasks), creado cuando la tarea aparece; su argv, su título y
 * su protocolo (`prompts: dotbackup` = el diálogo de dotbackup; `output: jsonl-report` = el informe de
 * health/doctor; `successText`) salen de la tarea, no del nombre. Sin tasks.json no hay trabajos. Los
 * registros de jobs.json se restauran aunque Tasks llegue después, y los de tareas que aún no se han
 * cargado se conservan al guardar. Un tipo no declarado devuelve un Runner vacío e inactivo
 * (`idleRunner`), nunca null. (F3d-2: ya sin las propiedades fijas dotbackup/diskbackup/health/doctor.)
 */
Singleton {
    id: root

    readonly property string path: Settings.stateDir + "/jobs.json"

    /** Hook de pruebas (IPC `jobTestCommand`): sustituye el argv de un tipo. */
    property var testCommands: ({})

    /** F3d-1: id de tarea → Runner (sólo las `panel`; los que dejan de declararse se quedan aquí). */
    property var runnersById: ({})
    /** Los Runners de las tareas declaradas ahora (o que siguen corriendo). */
    readonly property var runners: {
        void Tasks.tasks;
        const out = [];
        for (const k in root.runnersById) {
            const r = root.runnersById[k];
            if (Tasks.has(k) || r.busy) out.push(r);
        }
        return out;
    }

    function runner(kind) {
        const r = root.runnersById[kind];
        return r && (Tasks.has(kind) || r.busy) ? r : idleRunner;
    }
    /** ¿Hay un trabajo de verdad para `kind`? (runner() nunca devuelve null). */
    function declared(kind) { return root.runner(kind) !== idleRunner; }


    readonly property bool anyBusy: root.runners.some(r => r.busy)

    /** Crea (o pone al día) un Runner por tarea `panel`. Uno ocupado no se toca hasta que acaba. */
    function syncRunners() {
        const next = Object.assign({}, root.runnersById);
        let changed = false;
        for (const t of Tasks.tasks) {
            if (t.runs !== "panel") continue;
            let r = next[t.id];
            if (!r) {
                r = runnerComp.createObject(root, { kind: t.id, label: t.console, command: t.argv,
                                                    interactive: t.prompts === "dotbackup", task: t, store: root });
                next[t.id] = r;
                changed = true;
                if (root.saved[t.id]) { root.restore(r, root.saved[t.id]); delete root.saved[t.id]; }
            } else if (!r.busy) {
                r.label = t.console;
                r.command = t.argv;
                r.interactive = t.prompts === "dotbackup";
                r.task = t;
            }
        }
        if (changed) root.runnersById = next;
    }
    Connections {
        target: Tasks
        function onTasksChanged() { root.syncRunners(); }
    }
    Component.onCompleted: root.syncRunners()

    /**
     * Arranca un trabajo. Devuelve su id, o "" si ese recurso ya está ocupado.
     * `owner`: la pantalla que lo lanza. Desde la 6D cada trabajo es también una
     * operación global (`Operations`, tipo "job", recurso "job:<kind>", control
     * «dashboard»): quien lleva su pregunta es esa pantalla, y abrir el Dashboard
     * de forma explícita en otra se la lleva.
     */
    /**
     * Portabilidad F2d → F3d-1: lo que cada tarea necesita en ESTA máquina. La capacidad `tasks.<id>`
     * (scripts/capabilities.py: argv[0] y `requires`), la terminal si se abre en una, y la tubería de
     * actualizaciones si es la del botón Upgrade (como antes: sin ella, tampoco; F4 la generaliza).
     * Sin la tarea declarada, el motivo lo da Tasks («Not set up in tasks.json»).
     */
    function needsOf(kind) {
        const t = Tasks.byId(kind);
        if (!t) return [];
        const ids = [];
        // F4e: la tarea de Upgrade necesita la fuente de actualizaciones salvo que esté apagada (providers.updates
        // = none): entonces la tarea sigue siendo tuya, en la paleta, sin depender de nada
        if (t.role === "system-upgrade" && Providers.resolve("updates").mode !== "none") ids.push("system.updates");
        ids.push("tasks." + kind);
        if (t.runs === "terminal") ids.push("apps.terminal");
        return ids;
    }
    function whyNot(kind) {
        const m = Tasks.whyMissing(kind);
        return m.length > 0 ? m : Capabilities.whyFirst(root.needsOf(kind));
    }

    function start(kind, env, owner) {
        const r = root.runner(kind);
        if (r === idleRunner || r.busy) return "";
        if (root.whyNot(kind).length > 0) return "";
        // 11C: soltar la operación del trabajo ANTERIOR antes de arrancar. `begin()` pasa el estado a
        // running y `syncOp` actualizaba esa operación ya terminada: revivía, la nueva chocaba con
        // ella (conflict) y quedaba viva para siempre. Aparecía al lanzar dos veces el mismo tipo.
        const prev = Object.assign({}, root.opIds);
        delete prev[kind];
        root.opIds = prev;
        const id = r.begin(env || {});
        const op = Operations.begin("job", "job:" + kind, "dashboard", "", owner || "",
                                    { state: "running", snapshot: { jobId: id } });
        const t = Object.assign({}, root.opIds);
        t[kind] = op.id;
        root.opIds = t;
        return id;
    }

    /** kind → id de su operación (la del último arranque). */
    property var opIds: ({})
    function opIdOf(kind) { return root.opIds[kind] || ""; }

    /** El estado del trabajo manda sobre el de su operación. */
    function syncOp(kind, state, summary) {
        const id = root.opIdOf(kind);
        if (id.length === 0) return;
        if (state === "running" || state === "needs-input") Operations.update(id, { state: state });
        else Operations.end(id, state, summary);
    }
    function answer(kind, text) { const r = root.runner(kind); return r ? r.reply(text) : false; }
    function cancel(kind) { const r = root.runner(kind); return r ? r.cancel() : false; }
    /** La vista lo ha enseñado: un resultado ya visto no se vuelve a abrir solo. */
    function markSeen(kind) {
        const r = root.runner(kind);
        if (r && !r.busy && !r.seen) { r.seen = true; root.save(); }
    }

    /**
     * Lanzamientos a terminal (`minimaru clean`, `health`, `doctor`): el shell
     * sólo sabe que abrió la ventana. Se registran como «Opened in terminal»,
     * nunca como terminados.
     */
    property var external: []
    /** F3d-1: el nombre legible de cada tarea (antes, una tabla fija con cuatro). */
    readonly property var terminalLabels: {
        const m = {};
        for (const t of Tasks.tasks) m[t.id] = t.label;
        return m;
    }
    function launchTerminal(kind, argv) {
        if (root.whyNot(kind).length > 0) return false;      // F2d
        return Apps.spawn(argv, Apps.terminalName, (ok, why) => {
            if (!ok) return; // No registrar "Opened" si el helper rechazó el arranque.
            const e = { kind: kind, state: "external", summary: "Opened in terminal", at: Date.now() };
            root.external = [e].concat(root.external).slice(0, 5);
            root.save();
            Activity.record({ kind: kind, label: root.terminalLabels[kind] || kind, result: "opened",
                              summary: "Opened in terminal", at: e.at });
        });
    }

    /**
     * El registro: los Runners que hay más lo leído de jobs.json para tareas que aún no tienen Runner
     * (Tasks puede llegar después; si no, guardar los borraría).
     */
    function snapshot() {
        const out = { loaded: root.loaded };
        for (const k in root.saved) out[k] = root.saved[k];
        for (const k in root.runnersById) out[k] = root.runnersById[k].record();
        out.external = root.external;
        return out;
    }
    /** Lo leído de jobs.json y aún no aplicado: id → registro. */
    property var saved: ({})

    // ---- un tipo de trabajo -------------------------------------------------

    component Runner: QtObject {
        id: r
        required property string kind
        required property string label
        required property var command
        /** El singleton: un componente en línea no ve los ids del archivo. */
        required property var store
        /** F3d-1: la tarea declarada (protocolo, textos); null en `idleRunner`. */
        property var task: null
        /** dotbackup pregunta por stdin; diskbackup NO debe tener stdin abierto (un `read` colgaría). */
        property bool interactive: false
        /** Líneas de salida guardadas en memoria (las de la vista). */
        property int maxLines: 600

        property string jobId: ""
        property string state: "idle"
        property int exitCode: -1
        property string summary: ""
        property double startedAt: 0
        property double endedAt: 0
        property bool seen: true
        /** "" | "yn" | "text": qué respuesta espera. */
        property string ask: ""
        property string askLabel: ""
        /** Si la pregunta actual tiene salida limpia con «n». */
        property bool askCancels: false
        property var lines: []
        property var tail: []          // texto plano, para el registro persistente
        property var pending: []       // buffer sin binding (BUG-10a-1)
        property bool started: false
        property var answers: ({})     // paso -> respuesta, para decidir el estado final
        property int step: 0
        property bool sawMsg: false

        readonly property bool busy: r.state === "running" || r.state === "needs-input"
        onStateChanged: store.syncOp(r.kind, r.state, r.summary)
        readonly property bool canCancel: r.state === "needs-input" && r.askCancels

        function record() {
            return { id: r.jobId, kind: r.kind, label: r.label, state: r.state,
                     exit: r.exitCode, summary: r.summary, startedAt: r.startedAt,
                     endedAt: r.endedAt, seen: r.seen, ask: r.ask, askLabel: r.askLabel,
                     canCancel: r.canCancel, tail: r.tail };
        }

        function begin(env) {
            store.seq++;
            r.jobId = r.kind + "-" + Date.now().toString(36) + "-" + store.seq;
            r.state = "running";
            r.exitCode = -1;
            r.summary = "";
            r.startedAt = Date.now();
            r.endedAt = 0;
            r.seen = false;
            r.ask = ""; r.askLabel = ""; r.askCancels = false;
            r.lines = []; r.tail = []; r.pending = [];
            r.answers = ({}); r.step = 0; r.sawMsg = false;
            r.started = false;
            r.process.command = store.testCommands[r.kind] || r.command;
            r.process.environment = env;
            r.process.stdinEnabled = r.interactive;   // no se reabre solo: antes de cada arranque
            r.process.running = true;
            store.save();
            return r.jobId;
        }

        function append(raw) {
            // Una barra de progreso con \r: en una terminal sólo queda lo último.
            const cr = raw.lastIndexOf("\r");
            const line = cr >= 0 ? raw.slice(cr + 1) : raw;
            const segs = Ansi.parse(line);
            r.pending.push(segs);
            const plain = segs.map(function (s) { return s.text; }).join("");
            r.tail.push(plain);
            if (r.tail.length > 40) r.tail.shift();
            if (!r.flushTimer.running) r.flushTimer.start();
            return plain;
        }
        function note(text) { r.append("  → " + text); }

        function flushLines() {
            if (r.pending.length === 0) return;
            let next = r.lines.concat(r.pending);
            r.pending = [];
            if (next.length > r.maxLines) next = next.slice(next.length - r.maxLines);
            r.lines = next;
        }

        function reply(text) {
            if (r.state !== "needs-input") return false;
            r.process.write(text + "\n");
            r.note(r.ask === "text" ? (text.length ? text : "(default message)") : text);
            r.answers[store.dotPrompts[r.step].id] = text;
            r.ask = ""; r.askLabel = ""; r.askCancels = false;
            r.state = "running";
            r.step++;
            store.save();
            return true;
        }

        function cancel() {
            if (!r.canCancel) return false;
            r.answers.cancelled = true;
            return r.reply("n");
        }

        function finish(code) {
            r.flushLines();
            r.exitCode = code;
            r.endedAt = Date.now();
            r.ask = ""; r.askLabel = ""; r.askCancels = false;
            const v = store.verdict(r, code);
            // El resumen ANTES que el estado: `onStateChanged` lo pasa a su operación (6D).
            r.summary = v.summary;
            r.state = v.state;
            r.append("");
            r.append((v.state === "succeeded" ? "  ✓ " : v.state === "cancelled" ? "  · " : "  ✗ ") + v.summary);
            r.flushLines();
            store.save();
            // 11A-2: la actividad reciente del Dashboard (un trabajo de prueba también: su resumen lo dice)
            Activity.record({ kind: r.kind, label: r.label, result: r.state, summary: r.summary,
                              at: r.endedAt, jobId: r.jobId });
        }

        property Timer flushTimer: Timer { interval: 50; onTriggered: r.flushLines() }

        property Process process: Process {
            stdout: SplitParser { onRead: (l) => store.onLine(r, l) }
            stderr: SplitParser { onRead: (l) => store.onLine(r, l) }
            onStarted: r.started = true
            onExited: (code) => r.finish(code)
            // Un binario que no existe no emite `exited`: sólo `running` → false.
            onRunningChanged: {
                if (!r.process.running && !r.started && r.busy) {
                    r.append("  " + r.kind + ": could not start");
                    r.finish(127);
                }
            }
        }
    }

    property int seq: 0

    /**
     * F3d-1: los Runners salen de las tareas (`syncRunners`). Hasta aquí eran cuatro fijos:
     * dotbackup (`dotbackup → GitHub`, interactivo), diskbackup (`diskbackup → /mnt/storage`) y, desde
     * la 11C, health y doctor en el panel con `--json` (registros JSON Lines y un veredicto al final,
     * fish/conf.d/report-ui.fish `_rui_rec`). Hoy esas mismas órdenes vienen de tasks.json.
     */
    Component { id: runnerComp; Runner { } }
    /** Lo que devuelve `runner()` para un tipo no declarado: nunca arranca ni cambia. */
    Runner { id: idleRunner; kind: ""; label: ""; command: []; store: root }

    /**
     * El informe de health / doctor, de su salida (`tail`, que se guarda en jobs.json: sobrevive
     * a cerrar la vista y a reiniciar el shell). { records: [...], verdict: {...} | null, bad: n }
     * `bad` = líneas que no eran JSON (avisos de fish): se enseñan aparte, no se tragan.
     */
    function report(kind) {
        const r = root.runner(kind);
        const out = { records: [], verdict: null, bad: [] };
        if (!r) return out;
        for (const l of r.tail) {
            const t = String(l).trim();
            if (t.length === 0) continue;
            if (t.charAt(0) !== "{") { if (!/^[✓✗·] /.test(t)) out.bad.push(t); continue; }
            try {
                const d = JSON.parse(t);
                if (d.type === "verdict") out.verdict = d;
                else if (d.type === "record") out.records.push(d);
            } catch (e) { out.bad.push(t); }
        }
        return out;
    }
    function findingsText(v) {
        if (!v) return "";
        const f = v.findings || 0, u = v.unknown || 0;
        if (f === 0 && u === 0) return "No findings";
        return (f > 0 ? f + (f === 1 ? " finding" : " findings") : "")
             + (f > 0 && u > 0 ? " · " : "") + (u > 0 ? u + " could not answer" : "");
    }

    // ---- dotbackup: las preguntas del script -------------------------------

    /**
     * El orden ES el del script (SPIKE-DOTBACKUP.md): se avanza uno a uno, así
     * que una pregunta nueva va en su sitio exacto. `cancels`: contestar «n»
     * ahí es una salida limpia del script.
     */
    readonly property var dotPrompts: [
        { id: "start",  re: /¿Empezar el espejo\? \[y\/N\]/,              kind: "yn",   cancels: true,
          label: "Mirror ~/.config into the dotfiles repo?  Work in progress goes in too." },
        { id: "diff",   re: /¿Ver diff detallado\? \[y\/N\]/,              kind: "yn",   label: "Show the detailed diff?" },
        { id: "readme", re: /editar el README.*\[y\/N\]/,                  kind: "auto", label: "" },
        { id: "msg",    re: /^\s*>\s*$/,                                   kind: "text", need: "msg",
          label: "Commit message  ·  ⏎ empty = default" },
        { id: "commit", re: /¿Confirmar commit local\? \[y\/N\]/,          kind: "yn",   cancels: true, label: "Confirm the local commit?" },
        { id: "push",   re: /¿Hacer push a origin\/main ahora\? \[y\/N\]/, kind: "yn",   cancels: true, label: "Push to origin/main now?" }
    ]

    function onLine(r, raw) {
        const plain = r.append(raw);
        if (!r.task || r.task.prompts !== "dotbackup") return;      // F3d-1: el protocolo, no el nombre
        if (/Mensaje de commit/.test(plain)) r.sawMsg = true;
        if (r.state !== "running" || r.step >= root.dotPrompts.length) return;
        const p = root.dotPrompts[r.step];
        if (p.need === "msg" && !r.sawMsg) return;
        if (!p.re.test(plain)) return;
        if (p.kind === "auto") {                    // editar el README: siempre «n»
            r.process.write("n\n");
            r.note("README left unedited (edit it in a terminal if needed)");
            r.answers[p.id] = "n";
            r.step++;
            return;
        }
        r.ask = p.kind;
        r.askLabel = p.label;
        r.askCancels = !!p.cancels;
        r.state = "needs-input";
        root.save();
    }

    /** Estado final por evidencia: el código Y el camino recorrido. */
    function verdict(r, code) {
        const t = r.task || {};
        // 11C: health / doctor terminan por su veredicto JSON; sin él, no hay informe (fallo).
        // F3d-1: cualquier tarea con `output: jsonl-report`.
        if (t.output === "jsonl-report") {
            const rep = root.report(r.kind);
            if (rep.verdict) return { state: "succeeded", summary: root.findingsText(rep.verdict) };
            return { state: "failed", summary: r.kind + " exited with " + code + " — no report" };
        }
        const a = r.answers;
        const yes = function (k) { return /^y/i.test(a[k] || ""); };
        const said = function (k) { return a[k] !== undefined; };
        // F3d-1: sin el protocolo de dotbackup, el código dice (y `successText` lo pone en palabras)
        if (t.prompts !== "dotbackup")
            return code === 0 ? { state: "succeeded", summary: t.successText || "Finished — see its output" }
                              : { state: "failed", summary: r.kind + " exited with " + code };
        if (code !== 0)
            return { state: "failed", summary: r.kind + " exited with " + code };
        if (said("start") && !yes("start"))
            return { state: "cancelled", summary: "Cancelled before mirroring — no files touched" };
        if (said("commit") && !yes("commit"))
            return { state: "cancelled", summary: "Files mirrored into the repo, no commit made" };
        if (said("push") && !yes("push"))
            return { state: "succeeded", summary: "Committed locally, not pushed" };
        if (yes("push"))
            return { state: "succeeded", summary: "Committed and pushed" };
        // Salió con 0 sin pasar por las preguntas (p. ej. «nada que commitear»):
        // no se inventa qué hizo; lo dice su propia salida.
        return { state: "succeeded", summary: "Finished — see its output" };
    }

    // ---- registro persistente ----------------------------------------------

    property bool loaded: false

    function save() {
        if (!root.loaded) return;
        const d = root.snapshot();
        delete d.loaded;
        file.setText(JSON.stringify(d, null, 1));
    }

    function restore(r, rec) {
        if (!rec || !rec.state || rec.state === "idle") return;
        r.jobId = rec.id || "";
        r.exitCode = rec.exit === undefined ? -1 : rec.exit;
        r.startedAt = rec.startedAt || 0;
        r.endedAt = rec.endedAt || 0;
        r.tail = rec.tail || [];
        r.lines = r.tail.map(function (t) { return Ansi.parse(t); });
        if (rec.state === "running" || rec.state === "needs-input") {
            r.state = "unknown";
            r.summary = "The shell restarted while it ran — its result was not observed";
            r.seen = false;
            Activity.record({ kind: r.kind, label: rec.label || r.label, result: "unknown", summary: r.summary,
                              at: Date.now(), jobId: r.jobId });
        } else {
            r.state = rec.state;
            r.summary = rec.summary || "";
            r.seen = rec.seen !== false;
        }
    }

    FileView {
        id: file
        path: root.path
        blockLoading: true
        blockWrites: true
        printErrors: false
        onLoaded: {
            try {
                const d = JSON.parse(file.text());
                // F3d-1: cada registro va a su Runner si ya existe; si no, espera a que su tarea aparezca
                const keep = {};
                for (const k in d) {
                    if (k === "external" || k === "loaded" || !d[k] || typeof d[k] !== "object") continue;
                    const r = root.runnersById[k];
                    if (r) root.restore(r, d[k]); else keep[k] = d[k];
                }
                root.saved = keep;
                root.external = Array.isArray(d.external) ? d.external : [];
            } catch (e) {
                console.warn("jobs: record unreadable, starting empty");
            }
            root.loaded = true;
            root.save();
        }
        onLoadFailed: (error) => { root.loaded = true; }
    }
}
