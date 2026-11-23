pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Los asuntos del Overview del Dashboard (rediseño 11A-2; futureDashboardsurface
 * «Prioridades de contenido» y «Mantenimiento y actividad reciente»).
 *
 * Responde «¿hay algo que atender?» a partir de lo que ya leen otros servicios —no lanza
 * comprobaciones propias salvo la edad de los dos backups— y lo reparte en FUENTES, cada una con
 * su estado:
 *
 *   loading     aún no hay lectura
 *   ok          comprobado, nada que atender
 *   issue       requiere acción (unidad caída, actualizaciones, hallazgos, backup vencido)
 *   error       NO se pudo comprobar: se conserva el dato viejo, marcado como antiguo, y Retry
 *   unchecked   nunca se comprobó en esta sesión (updates antes de su primer timer)
 *   info        sólo informa (health/doctor nunca corridos, backups sin frecuencia)
 *
 * «Ausencia de datos nunca equivale a cero o éxito»: All clear sólo cuando TODAS las fuentes que
 * cuentan están en ok (o info) y ninguna en loading, error o unchecked. La hora de All clear es la
 * de la comprobación más reciente.
 *
 * Cada fuente lleva `at` (cuándo se COMPROBÓ: lo que dice «checked» y «Last checked») y, en los
 * backups y health/doctor, `dataAt` (la fecha del propio dato: la copia, la pasada).
 *
 * Sin sondeo: `refresh()` lo llama el Overview al hacerse visible (y Retry); las unidades se
 * releen además cada 5 s mientras el Overview reclama `Units`.
 */
Singleton {
    id: root

    // ---- edad de las copias (lo único que se lee aquí) --------------------------------------
    /**
     * F3d-1 (portabilidad, 2026-10-06; HC-22/23): era la edad de DOS copias fijas, `~/Projects/dotfiles`
     * (git) y `/mnt/storage/Backups/config-snapshots` (el snapshot más nuevo). Ahora, la de cada tarea de
     * tasks.json con `lastRun`: `git` = el último commit de `repo`; `newest` = el archivo más nuevo de
     * `dir` que case con `glob`. Sin tareas, no hay copias que vigilar.
     *
     * id → { at (ms de la última copia; 0 = no se sabe), error, read, readAt }
     */
    property var ages: ({})
    readonly property var noAge: ({ at: 0, error: "", read: false, readAt: 0 })
    function ageOf(id) { return root.ages[id] || root.noAge; }
    /** Pruebas (IPC `issuesTest`): id → otra ruta (repo o carpeta; una que no existe = error). */
    property var testPaths: ({})
    function setTestPath(id, path) {
        const next = Object.assign({}, root.testPaths);
        if (path.length > 0) next[id] = path; else delete next[id];
        root.testPaths = next;
    }

    /** Las tareas con `lastRun`, en el orden del archivo. */
    readonly property var backupTasks: Tasks.tasks.filter(t => !!t.lastRun)
    /** Las que dejan un resumen (health, doctor): sus fuentes van antes que las copias. */
    readonly property var checkTasks: Tasks.tasks.filter(t => !!t.summary)

    property var probes: ({})
    Component {
        id: probeComp
        Process {
            id: p
            property string taskId: ""
            property string kind: ""
            stdout: StdioCollector { id: pOut }
            onExited: (code) => root.took(p.taskId, p.kind, code, pOut.text)
        }
    }
    function probe(t) {
        const where = root.testPaths[t.id] || (t.lastRun.kind === "git" ? t.lastRun.repo : t.lastRun.dir);
        const cmd = t.lastRun.kind === "git"
            ? ["git", "-C", where, "log", "-1", "--format=%ct"]
            // un snapshot (o lo que case) por pasada: el más nuevo es la última
            : ["find", where, "-maxdepth", "1", "-name", t.lastRun.glob, "-printf", "%T@\n"];
        let p = root.probes[t.id];
        if (!p) {
            p = probeComp.createObject(root, { taskId: t.id });
            const next = Object.assign({}, root.probes);
            next[t.id] = p;
            root.probes = next;
        }
        if (p.running) return;
        p.kind = t.lastRun.kind;
        p.command = cmd;
        p.running = true;
    }
    function took(id, kind, code, out) {
        const a = Object.assign({}, root.ageOf(id), { read: true });
        if (kind === "git") {
            const t = parseInt(String(out).trim(), 10);
            if (code === 0 && t > 0) { a.at = t * 1000; a.error = ""; a.readAt = Date.now(); }
            else a.error = "Could not read the git repository";
        } else {
            const ts = String(out).split("\n").map(x => parseFloat(x)).filter(x => x > 0);
            if (code !== 0) a.error = "The folder is not available (not mounted?)";
            else if (ts.length === 0) a.error = "Nothing found yet";
            else { a.at = Math.max.apply(null, ts) * 1000; a.error = ""; a.readAt = Date.now(); }
        }
        const next = Object.assign({}, root.ages);
        next[id] = a;
        root.ages = next;
    }
    function readAges() { for (const t of root.backupTasks) root.probe(t); }

    function refresh() {
        Units.refreshFailed();
        root.readAges();
    }
    /** Retry de una fuente concreta. */
    function retry(id) {
        if (id === "updates") Updates.recheck();
        else if (id === "units") Units.refreshFailed();
        else root.refresh();
    }
    // Un backup que termina cambia su edad: se relee. (Como antes, la edad no se lee al arrancar: sólo al
    // abrir el Overview —refresh()— o al acabar un trabajo.)
    Connections {
        target: Activity
        function onEntriesChanged() { root.readAges(); }
    }

    /** Un reloj de minuto: las edades («hace 3 h») y el vencimiento cambian sin nueva lectura. */
    property double now: Date.now()
    Timer { interval: 60000; running: true; repeat: true; onTriggered: root.now = Date.now() }

    // ---- las fuentes ----------------------------------------------------------------------

    function ago(ms) {
        if (!(ms > 0)) return "";
        const d = Math.max(0, (root.now - ms) / 1000);
        if (d < 90) return "just now";
        if (d < 5400) return Math.round(d / 60) + " min ago";
        if (d < 172800) return Math.round(d / 3600) + " h ago";
        return Math.round(d / 86400) + " days ago";
    }
    function everyText(days) { return days === 1 ? "daily" : days === 7 ? "weekly" : "every " + days + " days"; }

    function _updates() {
        const s = { id: "updates", label: "Updates", at: Updates.checkedAt, action: "", actionLabel: "" };
        // F2d: sin tubería la fuente no existe aquí: informa y no impide All clear
        if (Updates.notSetUp.length > 0) return Object.assign(s, { state: "info", counts: false,
            text: "Updates are not set up", detail: Updates.notSetUp });
        if (Updates.checking) return Object.assign(s, { state: "loading", text: "Checking for updates…" });
        if (Updates.failed) return Object.assign(s, { state: "error", text: "Could not check for updates",
            detail: Updates.sourceLabel + " or the network did not answer",
            action: "retry", actionLabel: "Retry" });
        if (Updates.stale) return Object.assign(s, { state: "unchecked", text: "Updates not checked yet",
            detail: Updates.recheckStalled ? "the check did not finish" : "the timer has not run in this session",
            action: "retry", actionLabel: "Check now" });
        if (Updates.count > 0) return Object.assign(s, { state: "issue", rank: 2,
            text: Updates.count + (Updates.count === 1 ? " update pending" : " updates pending"),
            detail: Updates.upgradeWhy.length > 0 ? Updates.sourceLabel + " · can't upgrade here: " + Updates.upgradeWhy : Updates.sourceLabel,
            action: Updates.upgradeWhy.length > 0 ? "" : "update", actionLabel: Updates.upgradeWhy.length > 0 ? "" : "Upgrade" });
        return Object.assign(s, { state: "ok", text: "System up to date" });
    }
    function _units() {
        const s = { id: "units", label: "Services", at: Units.failedAt, action: "", actionLabel: "" };
        if (Units.failedError.length > 0) return Object.assign(s, { state: "error", text: "Could not read failed units",
            detail: (Units.failedTotal >= 0 ? "last known: " + Units.failedTotal + " failed · " : "") + Units.failedError.split(" · ")[0],
            action: "retry", actionLabel: "Retry" });
        if (Units.failedTotal < 0) return Object.assign(s, { state: "loading", text: "Reading failed units…" });
        if (Units.failedTotal > 0) {
            const names = Units.failed.map(f => f.unit).slice(0, 2).join(", ") + (Units.failedTotal > 2 ? "…" : "");
            return Object.assign(s, { state: "issue", rank: 0,
                text: Units.failedTotal + (Units.failedTotal === 1 ? " failed unit" : " failed units"),
                detail: names, action: "units", actionLabel: "Details" });
        }
        return Object.assign(s, { state: "ok", text: "No failed units" });
    }
    function _check(id, name, d) {
        const ran = d && d.ran > 0 ? d.ran * 1000 : 0;
        const s = { id: id, label: name, at: ran, dataAt: ran, action: "run-" + id, actionLabel: "Run " + id };
        // F2d: sin la función `sumi` de fish no hay nada que correr: se informa, sin botón
        const why = Jobs.whyNot(id);
        if (why.length > 0) return Object.assign(s, { state: "info", action: "", actionLabel: "",
            text: name + " is not available here", detail: why });
        if (!d || d.ran <= 0 || d.findings < 0) return Object.assign(s, { state: "info", text: name + " has not run yet" });
        const unk = d.unknown || 0;
        if (d.findings > 0 || unk > 0) return Object.assign(s, { state: "issue", rank: 1,
            text: name + ": " + (d.findings > 0 ? d.findings + (d.findings === 1 ? " finding" : " findings") : "")
                + (d.findings > 0 && unk > 0 ? " · " : "") + (unk > 0 ? unk + " could not answer" : ""),
            detail: "ran " + root.ago(ran) });
        return Object.assign(s, { state: "ok", text: name + ": no findings" });
    }
    function _backup(id, label, at, err, read, every, readAt) {
        const s = { id: id, label: label, at: readAt, dataAt: at, action: id, actionLabel: "Back up" };
        const age = at > 0 ? "last " + root.ago(at) : "";
        // F2d: herramienta personal ausente: se informa, nunca vence ni ofrece «Back up»
        const why = Jobs.whyNot(id);
        if (why.length > 0) return Object.assign(s, { state: "info", counts: false, action: "", actionLabel: "",
            text: label + " is not available here", detail: why });
        if (every <= 0) return Object.assign(s, { state: "info", counts: false,
            text: label + (age ? " · " + age : err ? " · " + err.toLowerCase() : ""), detail: "no expected frequency" });
        if (!read) return Object.assign(s, { state: "loading", text: "Reading the last " + label + "…" });
        if (err.length > 0) return Object.assign(s, { state: "error", text: "Could not check " + label,
            detail: (at > 0 ? age + " · " : "") + err, action: "retry", actionLabel: "Retry" });
        const overdue = root.now - at > every * 86400000;
        if (overdue) return Object.assign(s, { state: "issue", rank: 3, text: label + " is overdue",
            detail: age + " · expected " + root.everyText(every) });
        return Object.assign(s, { state: "ok", text: label + " on schedule", detail: age + " · " + root.everyText(every) });
    }

    /**
     * F3d-1: unidades, actualizaciones, las tareas con resumen y las tareas con copia, en el orden del
     * archivo (para el autor, el mismo de antes: health, doctor, dotbackup, diskbackup).
     */
    readonly property var sources: {
        void root.now;
        // F4e: con providers.updates = none la fuente de actualizaciones no existe aquí
        const out = Units.supported ? [root._units()] : [];
        if (!Updates.off) out.push(root._updates());
        for (const t of root.checkTasks) out.push(root._check(t.id, t.id, Checks.of(t.id)));
        for (const t of root.backupTasks) {
            const a = root.ageOf(t.id);
            out.push(root._backup(t.id, t.id, a.at, a.error, a.read, Settings.taskEvery(t.id), a.readAt));
        }
        return out;
    }
    /** Lo que requiere acción, por prioridad: unidades, hallazgos, updates, backups. */
    readonly property var issues: root.sources.filter(x => x.state === "issue").sort((a, b) => a.rank - b.rank)
    /** Lo que no se pudo comprobar (o nunca se comprobó). */
    readonly property var problems: root.sources.filter(x => x.state === "error" || x.state === "unchecked")
    readonly property bool loading: root.sources.some(x => x.state === "loading")
    /** La comprobación más reciente de lo que SÍ se comprobó. */
    readonly property double lastChecked: {
        let m = 0;
        // health/doctor (las tareas con resumen) no son comprobaciones del Overview (se corren a mano):
        // su hora no cuenta
        const manual = root.checkTasks.map(t => t.id);
        for (const x of root.sources)
            if ((x.state === "ok" || x.state === "issue") && manual.indexOf(x.id) < 0 && x.at > m) m = x.at;
        return m;
    }
    /** issues · problems · loading · clear */
    readonly property string headline: root.issues.length > 0 ? "issues"
        : root.problems.length > 0 ? "problems" : root.loading ? "loading" : "clear"

    function summary() {
        return { headline: root.headline, lastChecked: root.lastChecked,
                 issues: root.issues.map(x => x.id + ": " + x.text),
                 problems: root.problems.map(x => x.id + ": " + x.text),
                 sources: root.sources.map(x => ({ id: x.id, state: x.state, text: x.text, detail: x.detail || "", at: x.at })),
                 test: { paths: root.testPaths, updates: Updates.testPath } };
    }
}
