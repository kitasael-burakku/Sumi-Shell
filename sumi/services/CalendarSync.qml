pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Cuentas CalDAV y sincronización del calendario local (2026-10-28). Vive desde el arranque
 * (`shell.qml` lo toca). Local-first: la base es la fuente de trabajo; la red sólo se usa aquí,
 * siempre en un proceso aparte y con su propia cola, así que la interfaz y las escrituras
 * locales (`CalendarStore`) nunca esperan a un servidor caído.
 *
 * Disparadores: a mano (Sync now), al arrancar la shell (la sesión; 20 s después), al volver la
 * red (`Net.connectivity` pasa a Full, o conectado si NetworkManager no comprueba) y cada N
 * minutos (el menor intervalo de las cuentas activas; 0 = sólo a mano). Una sincronización a la
 * vez: el helper además tiene su cerrojo. La contraseña sólo pasa por stdin al añadir la cuenta
 * y se guarda en el llavero (Secret Service); aquí no se conserva.
 *
 * Pruebas: `checkConnectivity(bool)` simula el cambio de red; `autoDelayMs` y `minuteMs`.
 */
Singleton {
    id: root

    readonly property bool ready: true
    property var accounts: []
    property var conflicts: []
    property var local: ({ id: "local", name: "On this computer", visible: true })
    property bool loaded: false
    property bool syncing: false
    property string lastResult: ""
    /** La última sincronización no llegó a ningún servidor (no se deduce de NetworkManager: puede no estar). */
    property bool offline: false
    property var lastSummary: null
    property string panelError: ""
    property int syncs: 0
    property int autoSyncs: 0
    /** Formulario de alta: sin la contraseña (vive sólo en el campo hasta enviarse). */
    property bool adding: false
    property var addError: null
    property bool open: false
    property int autoDelayMs: 20000
    property int minuteMs: 60000

    readonly property int interval: {
        let m = 0;
        for (const a of root.accounts)
            if (a.enabled && a.interval > 0) m = m === 0 ? a.interval : Math.min(m, a.interval);
        return m;
    }
    readonly property int pendingTotal: {
        let n = 0;
        for (const a of root.accounts) for (const c of a.calendars) n += c.pending;
        return n;
    }

    function show() { root.open = true; root.refresh(); return true; }
    function close() { if (root.adding) return false; root.open = false; root.addError = null; return true; }

    // ---- lecturas y escrituras locales (cola de CalendarStore) ----
    function refresh() {
        CalendarStore.submit({ op: "accounts" }, function (r) {
            root.loaded = true;
            if (!r.ok) { root.panelError = r.error ? r.error.message : "Could not read the accounts"; return; }
            root.panelError = "";
            root.accounts = r.accounts || [];
            root.local = r.local || root.local;
            root.loadConflicts();
        });
    }
    function loadConflicts() {
        if (root.accounts.length === 0) { root.conflicts = []; return; }
        CalendarStore.submit({ op: "conflicts" }, function (r) { if (r.ok) root.conflicts = r.conflicts || []; });
    }
    function after(r) {
        if (!r.ok) root.panelError = r.error ? r.error.message : "Calendar helper failed";
        Agenda.refreshLocal();
        root.refresh();
    }
    function setVisible(calendarId, visible) {
        CalendarStore.submit({ op: "calendar-update", id: calendarId, visible: visible === true }, root.after);
        return true;
    }
    function setInterval(accountId, minutes) {
        CalendarStore.submit({ op: "account-update", id: accountId, interval: Number(minutes) }, root.after);
        return true;
    }
    function removeAccount(accountId) {
        CalendarStore.submit({ op: "account-remove", id: accountId }, function (r) {
            root.after(r);
            if (r.ok) CalendarEdit.say(r.unsyncedLost > 0 ? "Account removed · " + r.unsyncedLost + " unsynced changes discarded" : "Account removed from this computer");
        });
        return true;
    }
    function resolve(conflictId, choice) {
        CalendarStore.submit({ op: "resolve", id: conflictId, choice: choice }, function (r) {
            root.after(r);
            if (r.ok) root.sync("");      // lo elegido sube cuanto antes
        });
        return true;
    }

    // ---- red: cola propia (alta de cuenta y sincronización) ----
    property var netQueue: []
    property var netJob: null
    function net(req, then) {
        root.netQueue = root.netQueue.concat([{ req: req, then: then }]);
        if (!root.netJob) root.netPump();
    }
    function netPump() {
        if (root.netJob || root.netQueue.length === 0) return;
        root.netJob = root.netQueue[0];
        root.netQueue = root.netQueue.slice(1);
        netProc.started_ = false;
        netProc.stdinEnabled = true;
        netProc.command = CalendarStore.argv;
        netProc.running = true;
        netDeadline.restart();
    }
    function netDone(r) {
        netDeadline.stop();
        const j = root.netJob;
        root.netJob = null;
        if (j && j.then) { try { j.then(r); } catch (e) { console.warn("calendar sync: " + e); } }
        Qt.callLater(root.netPump);
    }
    Process {
        id: netProc
        property bool started_: false
        stdout: StdioCollector { id: netOut }
        onStarted: {
            netProc.started_ = true;
            if (root.netJob) netProc.write(JSON.stringify(root.netJob.req));
            netProc.stdinEnabled = false;
        }
        onExited: (code) => {
            if (!root.netJob) return;
            const lines = String(netOut.text).trim().split("\n");
            let r = null;
            try { r = JSON.parse(lines[lines.length - 1]); } catch (e) { r = null; }
            root.netDone(r && typeof r.ok === "boolean" ? r : { ok: false, error: { code: "internal", message: "The calendar helper failed (" + code + ")" } });
        }
        onRunningChanged: if (!running && !netProc.started_ && root.netJob)
            root.netDone({ ok: false, error: { code: "unavailable", message: "python3 is not available" } });
    }
    Timer {
        id: netDeadline
        interval: 180000
        onTriggered: { if (root.netJob) { netProc.running = false; root.netDone({ ok: false, error: { code: "timeout", message: "Sync took longer than 3 minutes; it will retry" } }); } }
    }

    function addAccount(url, username, password, interval, name) {
        if (root.adding) return false;
        root.adding = true;
        root.addError = null;
        root.net({ op: "account-add", url: url, username: username, password: password, interval: Number(interval), name: name || "" }, function (r) {
            root.adding = false;
            if (!r.ok) { root.addError = r.error || { code: "internal", message: "Could not add the account" }; return; }
            CalendarEdit.say("Account added · " + r.calendars + (r.calendars === 1 ? " calendar" : " calendars"));
            root.refresh();
            // La lista de cuentas llega después (otra cola): sincronizar la nueva sin esperarla.
            root.sync(r.account, true);
        });
        return true;
    }

    function sync(accountId, force) {
        if (root.syncing || root.accounts.length === 0 && root.loaded && force !== true) return false;
        root.syncing = true;
        root.syncs++;
        root.net({ op: "sync", account: accountId || "" }, function (r) {
            root.syncing = false;
            root.lastSummary = r.ok ? r : null;
            root.offline = r.ok && !r.busy && (r.accounts || []).length > 0 && r.accounts.every(a => a.result === "offline");
            if (!r.ok) root.lastResult = r.error ? r.error.message : "Sync failed";
            else if (r.busy) root.lastResult = "Another sync is running";
            else {
                const bad = (r.accounts || []).filter(a => a.result !== "ok");
                const c = (r.accounts || []).reduce((n, a) => n + (a.conflicts || 0), 0);
                root.lastResult = bad.length > 0 ? bad[0].error || bad[0].result
                    : c > 0 ? c + (c === 1 ? " conflict to resolve" : " conflicts to resolve") : "Synced";
            }
            Agenda.refreshLocal();
            CalendarReminders.refresh();
            root.refresh();
        });
        return true;
    }

    // ---- disparadores ----
    Timer { id: startup; interval: root.autoDelayMs; running: true; onTriggered: root.auto("startup") }
    Timer { id: periodic; interval: Math.max(1, root.interval) * root.minuteMs; repeat: true; running: root.interval > 0; onTriggered: root.auto("periodic") }
    function auto(reason) {
        if (root.accounts.length === 0) { root.refresh(); return; }
        root.autoSyncs++;
        root.lastAuto = reason;
        root.sync("");
    }
    property string lastAuto: ""
    property bool online: Net.connectivity === "Full" || (Net.connectivity === "Unknown" && Net.connected)
    onOnlineChanged: root.checkConnectivity(root.online)
    property bool wasOnline: true
    function checkConnectivity(on) {
        const back = on && !root.wasOnline;
        root.wasOnline = on;
        if (back) root.auto("network");
        return back;
    }
    Component.onCompleted: { root.wasOnline = root.online; root.refresh(); }

    function summary() {
        return { accounts: root.accounts, conflicts: root.conflicts, syncing: root.syncing, lastResult: root.lastResult, syncs: root.syncs,
                 autoSyncs: root.autoSyncs, lastAuto: root.lastAuto, interval: root.interval, adding: root.adding, addError: root.addError,
                 open: root.open, online: root.online, offline: root.offline, panelError: root.panelError, pendingTotal: root.pendingTotal };
    }
}
