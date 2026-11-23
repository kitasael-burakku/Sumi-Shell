pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * El calendario LOCAL (2026-10-27): escrituras en `scripts/calendar-store.py`, un proceso
 * por petición (JSON por stdin, una línea por stdout), sin daemon. La base SQLite vive en
 * `$XDG_DATA_HOME/sumi-shell/calendar/events.sqlite3`; aquí no se decide nada de fechas:
 * valida el helper, que es quien sabe de zonas IANA y cambios de horario.
 *
 * Una escritura a la vez, en orden. `then(result)` recibe siempre un objeto `{ ok, … }`:
 * también si Python no arranca, si la salida no es JSON o si vence el plazo (15 s). Un
 * fallo NUNCA se convierte en éxito ni en silencio: quien llama conserva su borrador.
 * Tras una escritura válida que cambia la agenda (crear, editar, borrar, importar), `changed`
 * avisa a `Agenda` para que relea el rango. También lleva los avisos (`due`/`fire`) y la
 * exportación/importación ICS (2026-10-28), en la misma cola.
 *
 * Las lecturas del rango las hace `Agenda` (la consulta del mes ya existía allí).
 */
Singleton {
    id: root

    readonly property string helper: Quickshell.shellDir + "/scripts/calendar-store.py"
    readonly property var argv: ["python3", "-I", root.helper]

    /** Escrituras confirmadas y fallidas desde que arrancó la shell (para las pruebas). */
    property int writes: 0
    property int failures: 0
    property var lastResult: null
    readonly property bool busy: proc.running || root.queue.length > 0

    signal changed(string uuid, string op)
    readonly property var mutatingOps: ["create", "update", "delete", "import"]

    property var queue: []

    function submit(req, then) {
        root.queue = root.queue.concat([{ req: req, then: then || null }]);
        if (!proc.running && !root.job && !root.draining) root.pump();
    }
    function create(uuid, event, then) { root.submit({ op: "create", uuid: uuid, event: event }, then); }
    function update(uuid, revision, event, then) { root.submit({ op: "update", uuid: uuid, revision: revision, event: event }, then); }
    function remove(uuid, revision, then) { root.submit({ op: "delete", uuid: uuid, revision: revision }, then); }

    /** Un UUID v4 para un borrador nuevo: reenviar el mismo borrador no duplica la cita. */
    function newUuid() {
        const h = "0123456789abcdef";
        let s = "";
        for (let i = 0; i < 36; i++) {
            if (i === 8 || i === 13 || i === 18 || i === 23) { s += "-"; continue; }
            if (i === 14) { s += "4"; continue; }
            const r = Math.floor(Math.random() * 16);
            s += h[i === 19 ? (r & 3) | 8 : r];
        }
        return s;
    }

    property var job: null
    property bool started: false

    function pump() {
        if (root.queue.length === 0 || root.job || root.draining) return;
        root.job = root.queue[0];
        root.queue = root.queue.slice(1);
        root.started = false;
        proc.stdinEnabled = true;           // hay que reabrirlo en cada arranque (memoria del proyecto)
        proc.command = root.argv;
        proc.running = true;
        deadline.restart();
    }

    /** Cierra el trabajo en curso UNA vez; tras un plazo vencido espera a que el proceso salga. */
    function finish(result) {
        deadline.stop();
        const job = root.job;
        root.job = null;
        root.lastResult = result;
        // Sólo lo que cambia la agenda cuenta como escritura y la hace releer (no una vista previa,
        // una exportación o el registro de un aviso).
        const mutating = job !== null && root.mutatingOps.indexOf(job.req.op) >= 0;
        if (result.ok && mutating) root.writes++;
        else if (!result.ok) root.failures++;
        if (result.ok && mutating) root.changed(job.req.uuid || (result.event ? result.event.uuid : ""), job.req.op);
        if (job && job.then) {
            try { job.then(result); } catch (e) { console.warn("calendar: " + e); }
        }
        if (!root.draining) Qt.callLater(root.pump);
    }
    /** Tras vencer el plazo, el proceso viejo aún puede emitir `exited`: no se lanza otro hasta entonces. */
    property bool draining: false
    function settled() {
        if (!root.draining) return false;
        root.draining = false;
        Qt.callLater(root.pump);
        return true;
    }

    Process {
        id: proc
        stdout: StdioCollector { id: out }
        stderr: StdioCollector { id: err }
        onStarted: {
            root.started = true;
            if (root.job) proc.write(JSON.stringify(root.job.req));
            proc.stdinEnabled = false;
        }
        onExited: (code) => {
            if (root.settled() || !root.job) return;
            const lines = String(out.text).trim().split("\n");
            let r = null;
            try { r = JSON.parse(lines[lines.length - 1]); } catch (e) { r = null; }
            if (!r || typeof r.ok !== "boolean")
                r = { ok: false, error: { code: "internal", message: "The calendar helper failed (" + code + ")"
                    + (String(err.text).trim().length > 0 ? ": " + String(err.text).trim().split("\n").pop().substring(0, 160) : "") } };
            root.finish(r);
        }
        // Un binario que no existe no emite `exited`: sólo `running` vuelve a false sin `started`.
        onRunningChanged: if (!running) {
            if (root.settled()) return;
            if (!root.started && root.job)
                root.finish({ ok: false, error: { code: "unavailable", message: "python3 is not available to save calendar events" } });
        }
    }

    Timer {
        id: deadline
        interval: 15000
        onTriggered: {
            if (!root.job) return;
            root.draining = true;
            root.finish({ ok: false, error: { code: "timeout", message: "The calendar helper didn't answer in 15 s; your changes are kept" } });
            proc.running = false;
        }
    }

    function summary() {
        return { helper: root.helper, busy: root.busy, queued: root.queue.length, writes: root.writes,
                 failures: root.failures, last: root.lastResult };
    }
}
