pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Actividad reciente del Dashboard (rediseño 11A-2; futureDashboardsurface «Mantenimiento y
 * actividad reciente»): un historial LOCAL y breve de lo que se ejecutó DESDE el shell —
 * dotbackup, diskbackup y lo que se entrega a una terminal (`update`, `clean`, `health`,
 * `doctor`)—, con hora y resultado.
 *
 *   result  succeeded · failed · cancelled · unknown (el shell se reinició y no lo vio)
 *           · opened (se abrió una terminal: «Opened in terminal», NUNCA «Completed»)
 *
 * Archivo propio (`activity.json`, las 20 más recientes) y no un campo de `jobs.json`: volver
 * a una entrega anterior reescribiría `jobs.json` sin él (lo que perdió la 7A). Una lista vacía
 * no afirma que no se hiciera nada: sólo que el shell no lo lanzó.
 *
 * `record()` antes de cargar el archivo se guarda en cola y se añade al cargar. La primera vez
 * (sin archivo) se siembra con lo que `Jobs` ya recordaba (su último trabajo de cada tipo y sus
 * lanzamientos a terminal), que también se lanzaron desde el shell.
 */
Singleton {
    id: root

    /** Pruebas (IPC `activityTestPath`): otro archivo; "" = el real. */
    property string testPath: ""
    readonly property string path: root.testPath.length > 0 ? root.testPath : Settings.stateDir + "/activity.json"
    onPathChanged: { root.loaded = false; root.entries = []; file.reload(); }
    readonly property int keep: 20

    /** Más reciente primero: [{ id, kind, label, result, summary, at, jobId }] */
    property var entries: []
    property bool loaded: false
    property var _queue: []
    property bool _seedPending: false
    property int _seq: 0

    function record(e) {
        root._seq++;
        const x = {
            id: "act-" + Date.now().toString(36) + "-" + root._seq,
            kind: String(e.kind || ""), label: String(e.label || e.kind || ""),
            result: String(e.result || "unknown"), summary: String(e.summary || ""),
            at: e.at || Date.now(), jobId: String(e.jobId || "")
        };
        if (!root.loaded) { root._queue = root._queue.concat([x]); return x.id; }
        root._add([x]);
        return x.id;
    }

    function _add(list) {
        // Un mismo trabajo no entra dos veces (una recarga que vuelve a ver su final).
        const seen = {};
        for (const e of root.entries) if (e.jobId) seen[e.jobId + ":" + e.result] = true;
        const fresh = list.filter(e => !(e.jobId && seen[e.jobId + ":" + e.result]));
        if (fresh.length === 0) return;
        root.entries = fresh.concat(root.entries).map(e => Object.assign({}, e, {
            // un registro viejo sin nombre legible toma el de Jobs
            label: e.label === e.kind && Jobs.terminalLabels[e.kind] ? Jobs.terminalLabels[e.kind] : e.label
        })).sort((a, b) => b.at - a.at).slice(0, root.keep);
        root.save();
    }

    function clear() { root.entries = []; root.save(); }

    function save() {
        if (!root.loaded) return;
        file.setText(JSON.stringify({ version: 1, entries: root.entries }, null, 1));
    }

    /** Siembra desde el registro de Jobs (una sola vez, sin archivo previo). */
    function _seed() {
        if (!Jobs.loaded) { root._seedPending = true; return; }
        root._seedPending = false;
        const out = [];
        for (const r of Jobs.runners) {
            if (r.state === "idle" || r.busy || !r.endedAt) continue;
            out.push({ id: "act-seed-" + r.kind, kind: r.kind, label: r.label, result: r.state,
                       summary: r.summary, at: r.endedAt, jobId: r.jobId });
        }
        for (const x of Jobs.external)
            out.push({ id: "act-seed-" + x.kind + "-" + x.at, kind: x.kind, label: Jobs.terminalLabels[x.kind] || x.kind,
                       result: "opened", summary: "Opened in terminal", at: x.at, jobId: "" });
        root._add(out);
    }
    Connections {
        target: Jobs
        enabled: root._seedPending
        function onLoadedChanged() { if (Jobs.loaded) root._seed(); }
    }

    function _flush() {
        const q = root._queue;
        root._queue = [];
        if (q.length > 0) root._add(q);
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
                root.entries = Array.isArray(d.entries) ? d.entries : [];
            } catch (e) {
                console.warn("activity: record unreadable, starting empty");
                root.entries = [];
            }
            root.loaded = true;
            root._flush();
        }
        onLoadFailed: (error) => {
            root.loaded = true;
            root._flush();
            root._seed();
        }
    }

    function summary() {
        return { loaded: root.loaded, count: root.entries.length,
                 entries: root.entries.slice(0, 8).map(e => ({ kind: e.kind, result: e.result, summary: e.summary, at: e.at })) };
    }
}
