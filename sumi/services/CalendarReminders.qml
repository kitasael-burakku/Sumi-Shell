pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Avisos de los eventos locales (2026-10-28). Vive desde el arranque (`shell.qml` lo toca).
 *
 * Sin sondeo de procesos: lee del helper (`due`) los avisos de una ventana [−48 h, +26 h]
 * al arrancar, tras cada cambio de la agenda, cada 6 h y al detectar un SALTO del reloj (un
 * tic de 30 s que llega tarde = la máquina estuvo suspendida o el reloj cambió). El tic sólo
 * compara horas en memoria.
 *
 * Cada aviso vencido se REGISTRA en la base (`fire`) antes de enseñarse: si ya estaba (otro
 * arranque, otra instancia, la misma sesión tras recargar) no se repite. Al volver de una
 * suspensión: un aviso cuyo evento aún no terminó sale ahora («Started 09:00»); los de eventos
 * ya terminados se registran como perdidos y, si su hora cayó DENTRO del hueco (la suspensión,
 * o las 12 h previas al arranque), se resumen en UN aviso. Uno de un evento creado ya pasado no
 * cayó en ningún hueco: se registra sin avisar. Si la base no admite escribir, se avisa igual
 * y la sesión evita repetirlo.
 *
 * Los avisos salen por `notify-send`, o sea por el servidor de notificaciones de la propia
 * shell (o el que haya), con la app «Calendar».
 *
 * Pruebas: `testNow` (ms; 0 = el reloj real) y `checkNow()`; los pone la sonda del banco.
 */
Singleton {
    id: root

    readonly property bool ready: true
    property real testNow: 0
    function now() { return root.testNow > 0 ? root.testNow : Date.now(); }

    /** [{ uuid, rid, offset, fire, start, end, allDay, title }] de la ventana leída. */
    property var cache: []
    property real fetchedAt: 0
    property real windowEnd: 0
    property real lastTick: 0
    /** Inicio del último hueco (suspensión o antes de arrancar): lo perdido desde ahí se resume. */
    property real gapFrom: 0
    property bool fetching: false
    property bool fetchAgain: false
    property var lastError: null
    property var handled: ({})
    property int shown: 0
    property int missed: 0
    property int resumes: 0
    property int notifyFailures: 0
    /** Lo enviado en esta sesión (para las pruebas): [{ title, body }]. */
    property var sent: []

    readonly property int hour: 3600000

    function iso(ms) { return new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z"); }
    function key(d) { return d.uuid + "|" + d.rid + "|" + d.offset; }

    /*
     * F10 (2026-11-27, ADR-42): el próximo evento para el tooltip del reloj (barra y cara hover). Los recordatorios
     * sólo traen eventos con aviso, así que se pide el `range` de hoy y mañana al mismo almacén, con la misma cadencia
     * que la caché (cambios, vuelta de suspensión, cada 6 h) y al cambiar de día. Un proceso por lectura, no por minuto.
     */
    property var upcoming: []
    function refreshUpcoming() {
        const d = new Date(root.now());
        const day = d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0");
        CalendarStore.submit({ op: "range", from: day, days: 2 }, function (r) {
            if (r && r.ok) root.upcoming = (r.items || []).filter(it => !it.allDay && /^\d{1,2}:\d{2}$/.test(it.start || ""));
        });
    }
    Connections { target: Clock; function onDateChanged() { root.refreshUpcoming(); } }
    /** { title, at (ms), end (ms), now (bool) } del evento en curso o el siguiente de hoy y mañana; null si no hay. */
    readonly property var nextEvent: {
        const n = Clock.now.getTime();
        const ms = (date, hm) => { const p = date.split("-"), h = hm.split(":");
            return new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]), Number(h[0]), Number(h[1])).getTime(); };
        let best = null;
        // por índice: una lista que llega de otro contexto (IPC, el almacén) puede ser una secuencia de Qt sin iterador
        const list = root.upcoming || [];
        for (let i = 0; i < list.length; i++) {
            const it = list[i];
            const at = ms(it.date, it.start);
            const end = /^\d{1,2}:\d{2}$/.test(it.end || "") ? ms(it.date, it.end) : at;
            if (end <= n && at <= n) continue;
            if (!best || at < best.at) best = { title: it.title || it.message || "Event", at: at, end: end, now: at <= n };
        }
        return best;
    }
    /** «Design review at 10:30» · «Now: Design review until 11:00» · «Tomorrow: Standup at 9:00»; "" sin evento. */
    readonly property string nextText: {
        const e = root.nextEvent;
        if (!e) return "";
        if (e.now) return "Now: " + e.title + " until " + Clock.fmt(e.end);
        const tomorrow = new Date(e.at).getDate() !== Clock.now.getDate();
        return (tomorrow ? "Tomorrow: " : "") + e.title + " at " + Clock.fmt(e.at);
    }

    function refresh() {
        if (root.fetching) { root.fetchAgain = true; return; }
        root.refreshUpcoming();
        const n = root.now();
        root.fetching = true;
        CalendarStore.submit({ op: "due", from: root.iso(n - 48 * root.hour), to: root.iso(n + 26 * root.hour) }, function (r) {
            root.fetching = false;
            if (r.ok) {
                root.cache = r.due || [];
                root.fetchedAt = n;
                root.windowEnd = n + 26 * root.hour;
                root.lastError = null;
            } else {
                root.lastError = r.error || null;
            }
            if (root.fetchAgain) { root.fetchAgain = false; root.refresh(); return; }
            root.check(false);
        });
    }

    /** `fromTimer`: el tic de 30 s; un tic tardío es una vuelta de suspensión o un cambio de reloj. */
    function check(fromTimer) {
        const n = root.now();
        const jumped = fromTimer && root.lastTick > 0 && Math.abs(n - root.lastTick) > 90000;
        if (jumped) { root.resumes++; root.gapFrom = root.lastTick; }
        if (fromTimer) root.lastTick = n;
        // Una lectura fallida conserva la caché. El próximo tic reintenta, también
        // si falló al volver de suspensión y la caché anterior todavía parecía reciente.
        if (fromTimer && !root.fetching && (jumped || root.lastError !== null || root.fetchedAt === 0
                || n > root.fetchedAt + 6 * root.hour || n > root.windowEnd - 2 * root.hour)) {
            root.refresh();
            return;
        }
        for (const d of root.cache) {
            const k = root.key(d);
            if (root.handled[k] || Date.parse(d.fire) > n) continue;
            // El IPC enumera las claves bajo demanda. Marcar una no necesita copiar las anteriores.
            root.handled[k] = true;
            const ended = Date.parse(d.end) <= n;
            const fire = Date.parse(d.fire);
            root.record(d, ended ? "missed" : "shown", ended && fire >= root.gapFrom && fire <= n);
        }
    }
    function checkNow() { root.check(true); return true; }

    function record(d, state, announce) {
        CalendarStore.submit({ op: "fire", uuid: d.uuid, rid: d.rid, offset: d.offset, fire: d.fire, state: state }, function (r) {
            if (r.ok && !r.inserted) return;     // ya registrado: otro arranque u otra instancia lo hizo
            if (state === "shown") { root.shown++; root.notify(d.title, root.when(d)); }
            else {
                root.missed++;
                if (announce) { root.missedTitles = root.missedTitles.concat([d.title]); missedTimer.restart(); }
            }
        });
    }
    property var missedTitles: []
    Timer {
        id: missedTimer
        interval: 1500
        onTriggered: {
            const t = root.missedTitles;
            root.missedTitles = [];
            if (t.length === 0) return;
            root.notify(t.length === 1 ? "Missed reminder" : t.length + " missed reminders",
                        "While the computer was away: " + t.slice(0, 4).join(", ") + (t.length > 4 ? " and " + (t.length - 4) + " more" : ""));
        }
    }

    function clock(ms) {
        return Clock.fmt(ms);
    }
    function when(d) {
        const n = root.now(), s = Date.parse(d.start);
        if (d.allDay) return "All day · " + Qt.formatDate(new Date(s), "ddd d MMM");
        const mins = Math.round((s - n) / 60000);
        if (mins > 1) return "In " + (mins >= 120 ? Math.round(mins / 60) + " h" : mins + " min") + " · " + root.clock(s) + "–" + root.clock(Date.parse(d.end));
        if (mins >= -1) return "Now · " + root.clock(s) + "–" + root.clock(Date.parse(d.end));
        return "Started " + root.clock(s) + " · until " + root.clock(Date.parse(d.end));
    }

    // ---- notify-send, uno a uno ----
    property var queue: []
    function notify(title, body) {
        root.sent = root.sent.concat([{ title: title, body: body }]).slice(-20);
        root.queue = root.queue.concat([[ "notify-send", "--app-name=Calendar", "--icon=x-office-calendar", title, body ]]);
        if (!sender.running) root.pump();
    }
    function pump() {
        if (root.queue.length === 0) return;
        sender.started_ = false;
        sender.command = root.queue[0];
        root.queue = root.queue.slice(1);
        sender.running = true;
    }
    Process {
        id: sender
        property bool started_: false
        onStarted: sender.started_ = true
        onExited: (code) => { if (code !== 0) root.notifyFailures++; Qt.callLater(root.pump); }
        onRunningChanged: if (!running && !sender.started_) { root.notifyFailures++; Qt.callLater(root.pump); }
    }

    Timer { id: tick; interval: 30000; running: true; repeat: true; onTriggered: root.check(true) }
    Component.onCompleted: { root.lastTick = root.now(); root.gapFrom = root.lastTick - 12 * root.hour; Qt.callLater(root.refresh); }
    Connections {
        target: CalendarStore
        function onChanged(uuid, op) { root.refresh(); }
    }

    function summary() {
        return { cache: root.cache.length, fetchedAt: root.fetchedAt, shown: root.shown, missed: root.missed, resumes: root.resumes,
                 notifyFailures: root.notifyFailures, sent: root.sent, lastError: root.lastError, testNow: root.testNow,
                 handled: Object.keys(root.handled).length };
    }
}
