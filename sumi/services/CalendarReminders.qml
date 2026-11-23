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

    function refresh() {
        if (root.fetching) { root.fetchAgain = true; return; }
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
        return Qt.formatTime(new Date(ms), Settings.clockFormat === "12h" ? "h:mm AP" : "HH:mm");
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
