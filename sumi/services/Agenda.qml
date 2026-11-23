pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * La agenda del calendario: DOS fuentes en una sola lista (2026-10-27).
 *
 *   · **local** — los eventos propios de la shell, editables, en SQLite por
 *     `scripts/calendar-store.py` (ver `CalendarStore`). Es la que se crea y edita.
 *   · **calcurse** — la agenda de `calcurse`, en SÓLO LECTURA como desde la fase 7C.
 *     Se sigue mostrando: añadir el calendario local no oculta ni migra estas citas, ni
 *     las importa, modifica o borra. Sin calcurse instalado, la local funciona igual.
 *
 * Cada ocurrencia lleva `source` ("local"/"calcurse") y `editable`. Las locales llevan
 * además `uuid`, `revision` y el `event` completo para el editor; su identidad es
 * `local:<uuid>@<día>`, estable al cambiar el título. Las de calcurse conservan la suya.
 *
 * calcurse, como antes (rediseño, fase 7C; spec de Calendar, «Calendario y agenda»):
 *
 *   calcurse --input-datefmt 4 -Q --from AAAA-MM-DD --days 42
 *            --output-datefmt %Y-%m-%d --format-*=…
 *
 * Medido el 2026-09-25 (calcurse 4.8.2, datos de prueba con -D):
 *   · Sale una cabecera `AAAA-MM-DD:` por día y, debajo, sus elementos.
 *   · Una cita que cruza la medianoche sale en los DOS días, con `..:..` en el
 *     extremo que no cae en ese día. (El helper local imita esa forma.)
 *   · `%N` es el TEXTO de la nota (varias líneas; sin nota, «No note file
 *     found»); `%n`, el nombre del archivo («(null)» sin nota). Cada registro va
 *     entre marcadores para poder partirlos aunque la nota tenga saltos.
 *
 * Una consulta por fuente a la vez; la última petición gana (`rev`) y una respuesta
 * vieja se descarta. `state` combina las dos: loading hasta que contestan ambas;
 * ready si al menos una dio datos válidos; error sólo si fallan las dos. El estado de
 * cada fuente (`calcurseState`, `localState`) y `issues` dicen QUÉ falló: un fallo
 * nunca se presenta como «No events». calcurse ausente (`missing`) no es un fallo:
 * es una instalación sin calcurse. 5 s de plazo por fuente. Sin sondeo: se consulta
 * al pedir un rango (abrir, cambiar de mes o Retry) y, tras una escritura local
 * válida, se relee sólo la parte local.
 *
 * Pruebas: `testDir` (datos -D de calcurse) y `testBinary` (un binario inexistente
 * simula que no está instalado); los pone el IPC.
 */
Singleton {
    id: root

    property string state: "idle"
    property string error: ""
    /** El rango de `items`: primer día (AAAA-MM-DD) y número de días. */
    property string from: ""
    property int days: 0
    /** [{ id, source, editable, date, kind, recurring, allDay, start, end, duration, message, hasNote, note, uuid?, revision?, event? }] */
    property var items: []
    /** Consultas de rango lanzadas (para medir que cambiar de día no consulta). */
    property int queries: 0
    property int rev: 0

    /** Fuente calcurse: idle · loading · ready · error · missing. */
    property string calcurseState: "idle"
    property string calcurseError: ""
    property var calcurseItems: []
    property int calcurseRev: 0
    /** Fuente local: idle · loading · ready · error; `localError` = { code, message }. */
    property string localState: "idle"
    property var localError: null
    property var localItems: []
    property int localRev: 0
    property bool localExists: false
    property int localQueries: 0
    /** La zona IANA con la que el helper calcula los días (la del proceso). */
    property string displayTz: ""
    /** Los calendarios de la base (CalDAV, 2026-10-28): [{ id, kind, name, color, readOnly, visible, accountId }]. */
    property var calendars: [{ id: "local", kind: "local", name: "On this computer", color: "", readOnly: false, visible: true }]
    /** [{ source, message }]: las fuentes que fallaron en el rango cargado. */
    readonly property var issues: {
        const out = [];
        if (root.localState === "error" && root.localError)
            out.push({ source: "local", code: root.localError.code, message: root.localError.message });
        if (root.calcurseState === "error")
            out.push({ source: "calcurse", code: "error", message: root.calcurseError });
        return out;
    }
    /** El calendario local no admite escrituras por cómo está la base (dañada, ajena, más nueva). */
    readonly property bool localWritable: !(root.localState === "error" && root.localError
        && ["corrupt", "foreign", "newer_schema"].indexOf(root.localError.code) >= 0)

    property string testDir: ""
    property string testBinary: ""
    readonly property string binary: root.testBinary.length > 0 ? root.testBinary : "calcurse"

    readonly property string mStart: "@@KT@@"
    readonly property string mSep: "@@|@@"
    readonly property string mEnd: "@@END@@"

    function fmt(kind) {
        const S = root.mSep;
        return root.mStart + kind + S + "%S" + S + "%E" + S + "%(duration)" + S + "%n" + S + "%m" + S + "%N" + root.mEnd + "\\n";
    }

    /**
     * Pide `days` días desde `from` a las dos fuentes. Si ya está cargado ese rango y
     * `force` es false, no consulta. Devuelve la revisión de la petición.
     */
    function request(from, days, force) {
        if (!force && root.state === "ready" && root.from === from && root.days === days)
            return root.rev;
        // El mismo rango ya en vuelo: no se relanza, tampoco forzado — una consulta que
        // acaba de salir es igual de reciente (medido: al abrir, el cambio de mes pedía el
        // rango y la forzada lo relanzaba; 2 consultas).
        if (root.state === "loading" && root.wantFrom === from && root.wantDays === days)
            return root.rev;
        root.rev++;
        root.queries++;
        root.wantFrom = from;
        root.wantDays = days;
        root.state = "loading";
        root.error = "";
        root.askCalcurse({ rev: root.rev, from: from, days: days });
        root.askLocal({ rev: root.rev, from: from, days: days });
        return root.rev;
    }
    property string wantFrom: ""
    property int wantDays: 0

    /** Tras crear, editar o borrar: relee SÓLO lo local del rango cargado, sin «Loading». */
    function refreshLocal() {
        if (root.wantFrom.length === 0) return;
        root.askLocal({ rev: root.rev, from: root.wantFrom, days: root.wantDays, refresh: true });
    }
    Connections {
        target: CalendarStore
        function onChanged(uuid, op) { root.refreshLocal(); }
    }

    /** Junta las dos fuentes cuando las dos contestaron a la petición vigente. */
    function combine() {
        if (root.calcurseRev !== root.rev || root.localRev !== root.rev) return;
        const calOk = root.calcurseState === "ready" || root.calcurseState === "missing";
        const localOk = root.localState === "ready";
        const all = (root.localState === "ready" ? root.localItems : [])
            .concat(root.calcurseState === "ready" ? root.calcurseItems : []);
        root.items = root.sorted(all);
        root.from = root.wantFrom;
        root.days = root.wantDays;
        if (localOk || root.calcurseState === "ready") {
            root.state = "ready";
            root.error = "";
        } else {
            root.state = "error";
            root.error = root.localError ? root.localError.message : "Could not load the agenda";
        }
    }

    function sorted(list) {
        // Por día: primero los de todo el día, luego por hora (lo que viene de ayer, «..:..», antes).
        return list.slice().sort(function (x, y) {
            if (x.date !== y.date) return x.date < y.date ? -1 : 1;
            if (x.allDay !== y.allDay) return x.allDay ? -1 : 1;
            const sx = x.start === "..:.." ? "" : x.start, sy = y.start === "..:.." ? "" : y.start;
            return sx < sy ? -1 : (sx > sy ? 1 : 0);
        });
    }

    // ---- calcurse ------------------------------------------------------------------------

    property var pending: null
    property var current: null
    property bool started: false

    function askCalcurse(p) {
        root.pending = p;
        if (proc.running) {
            proc.running = false;   // la vieja no importa: la nueva arranca al salir
            return;
        }
        root.start();
    }

    function start() {
        const p = root.pending;
        root.pending = null;
        if (!p) return;
        root.current = p;
        root.calcurseState = "loading";
        root.calcurseError = "";
        const argv = [root.binary];
        if (root.testDir.length > 0) argv.push("-D", root.testDir);
        argv.push("--input-datefmt", "4", "-Q", "--from", p.from, "--days", String(p.days),
                  "--output-datefmt", "%Y-%m-%d",
                  "--format-apt", root.fmt("A"), "--format-recur-apt", root.fmt("R"),
                  "--format-event", root.fmt("E"), "--format-recur-event", root.fmt("F"));
        root.started = false;
        proc.command = argv;
        proc.running = true;
        deadline.restart();
    }

    function calcurseDone(p, st, msg, list) {
        if (!p || p.rev !== root.rev) return;
        root.calcurseState = st;
        root.calcurseError = msg;
        root.calcurseItems = list;
        root.calcurseRev = p.rev;
        root.combine();
    }

    Process {
        id: proc
        stdout: StdioCollector { id: out }
        stderr: StdioCollector { id: err }
        onStarted: root.started = true
        onExited: (code) => {
            deadline.stop();
            const p = root.current;
            root.current = null;
            if (root.pending) { root.start(); return; }   // llegó otra petición: ésta ya no cuenta
            if (code !== 0) {
                root.calcurseDone(p, "error", "calcurse exited with " + code + (String(err.text).trim().length > 0
                    ? ": " + String(err.text).trim().split("\n")[0].substring(0, 120) : ""), []);
                return;
            }
            root.calcurseDone(p, "ready", "", root.parse(String(out.text)));
        }
        // Un binario que no existe no emite `exited` (memoria del proyecto): sólo
        // `running` pasa a false sin haber `started`.
        onRunningChanged: if (!running && !root.started && root.current) {
            deadline.stop();
            const p = root.current;
            root.current = null;
            if (root.pending) { root.start(); return; }
            root.calcurseDone(p, "missing", "calcurse is not installed", []);
        }
    }

    Timer {
        id: deadline
        interval: 5000
        onTriggered: {
            const p = root.current;
            root.pending = null;
            root.current = null;
            proc.running = false;
            root.calcurseDone(p, "error", "calcurse did not answer in 5 s", []);
        }
    }

    function fail(msg) {
        root.state = "error";
        root.error = msg;
    }

    /** Parte la salida: cabeceras de día fuera de los registros, registros entre marcadores. */
    function parse(text) {
        const out = [];
        let date = "";
        let pos = 0;
        const seen = {};
        while (pos < text.length) {
            const a = text.indexOf(root.mStart, pos);
            const gap = text.substring(pos, a < 0 ? text.length : a);
            const heads = gap.match(/(\d{4}-\d{2}-\d{2}):/g);
            if (heads) date = heads[heads.length - 1].substring(0, 10);
            if (a < 0) break;
            const b = text.indexOf(root.mEnd, a);
            if (b < 0) break;
            const f = text.substring(a + root.mStart.length, b).split(root.mSep);
            pos = b + root.mEnd.length;
            if (f.length < 7 || date.length === 0) continue;
            const k = f[0];
            const event = k === "E" || k === "F";
            // Sin nota, `%n` escribe «(null)» (medido), no vacío.
            const noteName = f[4].trim();
            const hasNote = noteName.length > 0 && noteName !== "(null)";
            const it = {
                source: "calcurse",
                editable: false,
                date: date,
                kind: event ? "event" : "apt",
                recurring: k === "R" || k === "F",
                allDay: event,
                start: event ? "" : f[1],
                end: event ? "" : f[2],
                duration: event ? 0 : Number(f[3]) || 0,
                hasNote: hasNote,
                message: f[5].substring(0, 512),
                note: hasNote ? f.slice(6).join(root.mSep).trim().substring(0, 4096) : ""
            };
            // Identidad de la OCURRENCIA (spec: el detalle se actualiza por ella, nunca por índice).
            let id = it.date + "|" + k + "|" + it.start + "|" + it.message;
            let n = 2;
            while (seen[id]) id = it.date + "|" + k + "|" + it.start + "|" + it.message + "#" + (n++);
            seen[id] = true;
            it.id = id;
            out.push(it);
        }
        return root.sorted(out);
    }

    // ---- calendario local ------------------------------------------------------------------

    property var localPending: null
    property var localCurrent: null
    property bool localStarted: false

    function askLocal(p) {
        root.localPending = p;
        if (localProc.running) {
            localProc.running = false;
            return;
        }
        root.startLocal();
    }

    function startLocal() {
        const p = root.localPending;
        root.localPending = null;
        if (!p) return;
        root.localCurrent = p;
        if (!p.refresh) root.localState = "loading";
        root.localStarted = false;
        root.localQueries++;
        localProc.stdinEnabled = true;      // reabrirlo en cada arranque
        localProc.command = CalendarStore.argv;
        localProc.running = true;
        localDeadline.restart();
    }

    function localDone(p, r) {
        // Una relectura tras escribir vale si sigue siendo el rango vigente.
        if (!p || p.rev !== root.rev || p.from !== root.wantFrom || p.days !== root.wantDays) return;
        if (r.ok) {
            root.localState = "ready";
            root.localError = null;
            root.localItems = r.items || [];
            root.localExists = r.exists === true;
            if (r.calendars) root.calendars = r.calendars;
            if (r.displayTz) root.displayTz = r.displayTz;
        } else {
            root.localState = "error";
            root.localError = r.error || { code: "internal", message: "Unknown calendar error" };
            root.localItems = [];
        }
        root.localRev = p.rev;
        root.combine();
    }

    Process {
        id: localProc
        stdout: StdioCollector { id: lout }
        stderr: StdioCollector { id: lerr }
        onStarted: {
            root.localStarted = true;
            const p = root.localCurrent;
            if (p) localProc.write(JSON.stringify({ op: "range", from: p.from, days: p.days }));
            localProc.stdinEnabled = false;
        }
        onExited: (code) => {
            localDeadline.stop();
            const p = root.localCurrent;
            root.localCurrent = null;
            if (root.localPending) { root.startLocal(); return; }
            const lines = String(lout.text).trim().split("\n");
            let r = null;
            try { r = JSON.parse(lines[lines.length - 1]); } catch (e) { r = null; }
            if (!r || typeof r.ok !== "boolean")
                r = { ok: false, error: { code: "internal", message: "The calendar helper failed (" + code + ")" } };
            root.localDone(p, r);
        }
        onRunningChanged: if (!running && !root.localStarted && root.localCurrent) {
            localDeadline.stop();
            const p = root.localCurrent;
            root.localCurrent = null;
            if (root.localPending) { root.startLocal(); return; }
            root.localDone(p, { ok: false, error: { code: "unavailable", message: "python3 is not available to read local events" } });
        }
    }

    Timer {
        id: localDeadline
        interval: 5000
        onTriggered: {
            const p = root.localCurrent;
            root.localPending = null;
            root.localCurrent = null;
            localProc.running = false;
            root.localDone(p, { ok: false, error: { code: "timeout", message: "The local calendar did not answer in 5 s" } });
        }
    }

    // ---- consultas -----------------------------------------------------------------------------

    function on(date) {
        return root.items.filter(function (it) { return it.date === date; });
    }
    function find(id) {
        for (let i = 0; i < root.items.length; i++)
            if (root.items[i].id === id) return root.items[i];
        return null;
    }
    /** La primera ocurrencia cargada de un evento local, por su UUID. */
    function findLocal(uuid) {
        for (let i = 0; i < root.items.length; i++)
            if (root.items[i].uuid === uuid) return root.items[i];
        return null;
    }
    /** Cuántos por día del rango: { "AAAA-MM-DD": n }. */
    readonly property var counts: {
        const c = {};
        for (let i = 0; i < root.items.length; i++)
            c[root.items[i].date] = (c[root.items[i].date] || 0) + 1;
        return c;
    }

    function summary() {
        return { state: root.state, error: root.error, from: root.from, days: root.days,
                 items: root.items.length, queries: root.queries, testDir: root.testDir, testBinary: root.testBinary,
                 calcurse: { state: root.calcurseState, error: root.calcurseError, items: root.calcurseItems.length },
                 local: { state: root.localState, error: root.localError, items: root.localItems.length,
                          exists: root.localExists, queries: root.localQueries, displayTz: root.displayTz },
                 issues: root.issues };
    }
}
