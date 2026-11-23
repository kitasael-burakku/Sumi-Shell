pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import "../theme"
import "../services"
import "../components"
import "../lib/ansi.js" as Ansi

/**
 * La capa Tasks (etapa B del Dashboard híbrido, 2026-11-09; `docs/SUMI-DASHBOARD-B-2026-11-09.md`).
 *
 * Antes era la pestaña Tasks del Dashboard (11B). Se muda a una ventana flotante como System Monitor
 * (`MonitorLayer`) porque su trabajo es largo e interactivo: seguir un backup mientras se hace otra cosa,
 * contestar el diálogo de dotbackup, escribir la passphrase SSH o leer un informe. Una superficie del
 * island se cierra con un clic fuera; esta ventana se queda hasta que se cierra. El Dashboard se queda
 * con el vistazo (asuntos, Maintenance, modos) y la abre en la tarea que toque.
 *
 * Lo que hace es lo mismo que hacía la pestaña, con el mismo código portado: el catálogo de tareas
 * (`Commands`, sólo panel y terminal), la consola de `Jobs` con sus preguntas, la confirmación del
 * panel (diskbackup), la passphrase de `SshAgent`, el informe de health/doctor, los trabajos en
 * seguimiento y las descargas de Wallhaven. Nuevo: las últimas ejecuciones de la tarea elegida
 * (`Activity`). Cerrar la ventana no toca ningún trabajo.
 *
 * Teclado: `OnDemand`, con la petición exclusiva corta al abrirse (y 150 ms después de que se cierre la
 * superficie del island que la abrió) de `SettingsLayer`: Hyprland no siempre da el teclado a una capa
 * al mapearla. Escribir busca; ↑↓ eligen; ⏎ ejecuta; Tab pasa a los trabajos; Esc vacía y luego cierra.
 */
PanelWindow {
    id: win

    required property var targetScreen
    readonly property string name: win.targetScreen ? win.targetScreen.name : ""
    readonly property real s: Settings.uiScale
    readonly property bool shown: TasksUi.open && TasksUi.screen === win.name && !Lock.engaged
    readonly property real margin: Metrics.storeMargin * win.s
    readonly property real topInset: Math.max(Metrics.reservedH(win.s), Metrics.reservedBarH(win.s))
    /** 2026-11-19: la barra permanente abajo o a un lado no se tapa: su franja, además del margen (Screen.barInset). */
    readonly property var barHost: Screens.byName(win.targetScreen ? String(win.targetScreen.name) : "")
    readonly property real leftInset: win.margin + (win.barHost ? win.barHost.barInset("left") : 0)
    readonly property real rightInset: win.margin + (win.barHost ? win.barHost.barInset("right") : 0)
    readonly property real bottomInset: win.margin + (win.barHost ? win.barHost.barInset("bottom") : 0)
    readonly property real areaW: win.targetScreen ? win.targetScreen.width : 0
    readonly property real areaH: win.targetScreen ? win.targetScreen.height : 0

    screen: win.targetScreen
    visible: win.shown || card.appear > 0.001
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "sumi-tasks"
    WlrLayershell.keyboardFocus: !win.shown ? WlrKeyboardFocus.None
        : win.grab ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand
    anchors { top: true; left: true; right: true; bottom: true }
    mask: win.shown ? cardRegion : noRegion
    Region { id: noRegion }
    /**
     * La región de entrada es la geometría de la tarjeta, SIN la transformación de la entrada (escala y subida de
     * `Reveal`): `item: card` la tomaba con la escala/subida del primer fotograma y no se recalculaba al acabar la
     * animación (sólo al mover o redimensionar), así que con Expressive quedaban muertos ~28 px de la cabecera y
     * ~20 px por lado (2026-11-11, tools/sumi-drag/).
     */
    Region { id: cardRegion; x: card.x; y: card.y; width: card.width; height: card.height }

    // ---- teclado del compositor (patrón de SettingsLayer, medido el 2026-11-07) ----------------
    property bool grab: false
    function pulseGrab() {
        win.grab = true;
        regrab.restart();
        if (card.Window.active) release.restart();
    }
    readonly property var hostScreen: Screens.byName(win.name)
    readonly property string islandOpen: win.hostScreen ? win.hostScreen.open : ""
    /** Abierta desde una superficie del island: el teclado se pide cuando ésa se haya cerrado. */
    property bool waitIsland: false
    onIslandOpenChanged: {
        if (win.islandOpen.length > 0) { linkBack.stop(); regrab.stop(); release.stop(); win.grab = false; return; }
        if (win.shown && win.waitIsland) { win.waitIsland = false; linkBack.restart(); }
    }
    Timer { id: linkBack; interval: 150; onTriggered: if (win.shown && win.islandOpen.length === 0) { win.pulseGrab(); win.placeFocus(); } }
    Timer { id: regrab; interval: 1500; onTriggered: win.grab = false }
    Timer { id: release; interval: 120; onTriggered: { regrab.stop(); win.grab = false; } }

    // ---- sitio --------------------------------------------------------------------------------
    function clampX(x) { return Math.max(win.leftInset, Math.min(win.areaW - card.width - win.rightInset, x)); }
    function clampY(y) { return Math.max(win.topInset, Math.min(win.areaH - card.height - win.bottomInset, y)); }
    function place() {
        if (win.areaW <= 0 || win.areaH <= 0) return;
        const p = TasksUi.positionOf(win.name);
        card.x = win.clampX(p ? p.x : (win.areaW - card.width) / 2);
        card.y = win.clampY(p ? p.y : (win.areaH - card.height) / 2);
    }
    onAreaWChanged: if (win.shown) win.place()
    onAreaHChanged: if (win.shown) win.place()

    onShownChanged: {
        if (win.shown) {
            win.place();
            win.cmdQuery = "";
            win.cmdSel = 0;
            win.trackSel = 0;
            win.section = "search";
            win.leaveAsk = false;
            Qt.callLater(() => { if (tkSearch.text.length > 0) tkSearch.clear(); });
            win.pickShown();
            win.takePick();
            if (win.islandOpen.length > 0) win.waitIsland = true;
            else { win.pulseGrab(); Qt.callLater(win.placeFocus); }
        } else {
            win.resetView();          // la vista, no el trabajo
            win.waitIsland = false;
            linkBack.stop();
        }
    }
    Component.onCompleted: {
        TasksUi.layer = win;
        if (win.shown) { win.place(); win.pickShown(); win.takePick(); win.pulseGrab(); Qt.callLater(win.placeFocus); }
    }
    Component.onDestruction: if (TasksUi.layer === win) TasksUi.layer = null

    // ---- lo que pidió quien la abrió ---------------------------------------------------------
    property int pickSeq: 0
    Connections {
        target: TasksUi
        function onPickChanged() { if (win.shown) win.takePick(); }
    }
    /** El encargo de TasksUi (una tarea elegida, y quizá arrancada) y el de la paleta (Commands.request). */
    function takePick() {
        const p = TasksUi.pick;
        if (p.seq > win.pickSeq) {
            win.pickSeq = p.seq;
            if (p.id.length > 0) {
                win.selectCommandIfListed(p.id);
                if (p.start) win.startPanel(p.id);
                else if (Jobs.runner(p.id).state !== "idle") { win.resetView(); win.jobKind = p.id; }
            }
        }
        const want = Commands.take(win.name);
        if (want.length > 0) Qt.callLater(() => { win.selectCommand(want); win.startPanel(want); });
    }

    // ---- cerrar (con la passphrase escrita, se pregunta) -------------------------------------
    property bool leaveAsk: false
    // la pregunta se contesta con el teclado de la ventana, no en el campo (⏎ allí enviaría la passphrase)
    onLeaveAskChanged: if (win.leaveAsk) keys.forceActiveFocus(); else Qt.callLater(win.placeFocus)
    function requestClose() {
        if (win.passAsk && passField.text.length > 0) { win.leaveAsk = true; return false; }
        return win.closeNow();
    }
    function closeNow() {
        passField.clear();
        win.leaveAsk = false;
        return TasksUi.close();
    }

    // =============================================================================================
    // Estado (portado de surfaces/Dashboard.qml, pestaña Tasks, 11B–F3d-2)
    // =============================================================================================

    /** "search" el buscador y el catálogo · "tracked" los trabajos · "jobs" la consola mientras pregunta. */
    property string section: "search"

    // --- descargas (rediseño 10D-2): las de Wallhaven por id, del MISMO gestor que la tienda ---
    readonly property var dlAll: {
        void Downloads.items;
        const rank = { running: 0, queued: 1, paused: 2, failed: 3, interrupted: 4, partial: 5, cancelled: 6, done: 7 };
        return Downloads.jobs.map((j, i) => ({ j: j, i: i, r: rank[Downloads.jobState(j.id)] ?? 7 }))
            .sort((a, b) => a.r - b.r || a.i - b.i).map(x => x.j);
    }
    readonly property bool dlAnyFinished: { void Downloads.items;
        return Downloads.jobs.some(j => ["running", "queued", "paused"].indexOf(Downloads.jobState(j.id)) < 0); }
    function dlAction(j) {
        const st = Downloads.jobState(j.id);
        if (st === "running" || st === "queued") return "cancel";
        if (["failed", "cancelled", "paused", "interrupted", "partial"].indexOf(st) >= 0) return "retry";
        return "";
    }
    function dlStatus(j) {
        void Downloads.items;
        const st = Downloads.jobState(j.id);
        const c = Downloads.jobSummary(j.id);
        const l = Downloads.itemsOf(j.id);
        const got = l.reduce((a, it) => a + (it.state === "done" ? it.bytes : it.got), 0);
        const tot = l.reduce((a, it) => a + it.bytes, 0);
        const pct = tot > 0 ? Math.floor(100 * got / tot) : 0;
        const why = (l.find(it => it.reason && it.state !== "done") || {}).reason || "";
        const files = c.total > 1 ? " · " + Downloads.progressText(j.id) : "";
        switch (st) {
        case "running": return "Downloading " + pct + "%" + files;
        case "queued": return "Queued" + files;
        case "paused": return why || "Paused";
        case "interrupted": return "Interrupted · the shell restarted";
        case "failed": return why || "Failed";
        case "cancelled": return "Cancelled";
        case "partial": return "Cancelled" + files;
        default: return c.exists === c.total ? "Already in your library" : "Downloaded" + files;
        }
    }

    // --- el catálogo: sólo lo que trabaja (etapa A); la navegación es de la paleta ---
    property string cmdQuery: ""
    readonly property var cmdResult: Commands.filter(win.cmdQuery)
    readonly property var cmdRows: win.cmdResult.rows.filter(c => c.runs === "panel" || c.runs === "terminal")
    property int cmdSel: 0
    onCmdRowsChanged: if (win.cmdSel >= win.cmdRows.length) win.cmdSel = Math.max(0, win.cmdRows.length - 1)
    readonly property var cmdCur: win.cmdRows[win.cmdSel] || null
    /** "command" = la orden elegida (y la consola de su trabajo); "job" = un trabajo que no es del catálogo. */
    property string detailMode: "command"
    function userPicked() {
        win.detailMode = "command";
        if (win.consoleAsking || win.prePhase) return;
        const c = win.cmdCur, r = c && c.runs === "panel" ? Jobs.runner(c.id) : null;
        win.jobKind = r && r.state !== "idle" ? c.id : "";
    }
    function cmdMove(d) {
        const n = win.cmdRows.length;
        if (d > 0 && win.cmdSel >= n - 1) { if (win.trackCount > 0) win.section = "tracked"; return; }
        win.cmdSel = Math.max(0, Math.min(n - 1, win.cmdSel + d));
        tkList.positionViewAtIndex(win.cmdSel, ListView.Contain);
        win.userPicked();
    }
    function selectCommand(id) {
        tkSearch.clear();
        win.cmdQuery = "";
        const i = win.cmdRows.findIndex(c => c.id === id);
        if (i >= 0) win.cmdSel = i;
        win.detailMode = "command";
    }
    function selectCommandIfListed(id) { if (Commands.get(id)) win.selectCommand(id); }
    readonly property string cmdButton: {
        const c = win.cmdCur;
        if (!c) return "";
        if (c.runs === "panel") {
            const r = Jobs.runner(c.id);
            return r && r.busy ? "Follow" : r && r.state !== "idle" ? "Run again" : "Start";
        }
        return "Open in " + Apps.terminalLabel;
    }
    readonly property string cmdStatus: {
        const c = win.cmdCur;
        void Activity.entries; void Issues.now;
        if (!c) return "";
        if (c.runs === "panel") {
            const r = Jobs.runner(c.id);
            const also = c.task && c.task.summary
                ? "\nLast report (terminal or panel): " + win.checkLine(Checks.of(c.id)) : "";
            if (!r || r.state === "idle") return "Not run from the shell yet" + also;
            if (r.state === "needs-input") return "Waiting for you — answer below";
            if (r.busy) return "Running since " + win.clockOf(r.startedAt) + " — no result until it finishes";
            return win.resultWord(r.state) + " · " + win.whenOf(r.endedAt) + (r.summary ? " · " + r.summary : "");
        }
        if (c.runs === "terminal") {
            const at = Commands.lastOpened(c.id);
            let t = at > 0 ? "Opened in terminal · " + win.whenOf(at) + " · result not tracked"
                           : "Not opened from the shell yet";
            if (c.task && c.task.summary) t += "\nLast report: " + win.checkLine(Checks.of(c.id));
            return t;
        }
        return "";
    }
    readonly property bool cmdStatusBad: {
        const c = win.cmdCur;
        if (!c || c.runs !== "panel") return false;
        const r = Jobs.runner(c.id);
        return !!r && (r.state === "failed" || r.state === "unknown");
    }
    /** Nuevo: las últimas ejecuciones de la tarea elegida (lo que el Overview ya no puede enseñar entero). */
    readonly property var cmdHistory: {
        const c = win.cmdCur;
        void Activity.entries;
        return c ? Activity.entries.filter(e => e.kind === c.id).slice(0, 5) : [];
    }
    function activityHasOutput(e) {
        const r = Jobs.runner(e.kind);
        return !!r && e.jobId.length > 0 && e.jobId === r.jobId;
    }
    function runSelectedCommand() { const c = win.cmdCur; if (c) win.runCommand(c.id); }
    function runCommand(id) {
        const c = Commands.get(id);
        if (!c) return;
        if (c.runs === "panel") { win.startPanel(id); return; }
        const r = Commands.run(id);
        if (!r.ok) return;
        win.closeNow();               // la terminal nueva necesita el teclado (y no quedar tapada)
    }
    /** Una tarea del panel, por lo que declara (F3d-2): diálogo de dotbackup, confirmación o directa. */
    function startPanel(id) {
        if (Jobs.whyNot(id).length > 0) return;
        const t = Tasks.byId(id);
        if (!t || t.runs !== "panel") return;
        if (Jobs.runner(id).busy) { win.jobKind = id; return; }
        if (t.prompts === "dotbackup") { win.runPrompted(id); return; }
        win.resetView();
        if (t.confirm) { win.askAction = id; return; }
        Jobs.start(id, win.agentEnv(t), win.name);
        win.jobKind = id;
    }
    function agentEnv(t) { return t && t.sshAgent && SshAgent.sock.length > 0 ? ({ "SSH_AUTH_SOCK": SshAgent.sock }) : ({}); }

    // --- trabajos en seguimiento -----------------------------------------------------------
    readonly property var trackRows: {
        void Downloads.items; void Activity.entries;
        const out = [];
        for (const r of Jobs.runners) {
            const k = r.kind;
            if (r.state === "idle") continue;
            out.push({ type: "job", key: k, label: k, state: r.state,
                       status: r.state === "needs-input" ? "Needs input" : r.busy ? "Running"
                             : win.resultWord(r.state) + " · " + win.whenOf(r.endedAt),
                       action: win.jobKind === k ? "" : (r.state === "needs-input" ? "Answer" : "Follow") });
        }
        for (const j of win.dlAll) {
            const a = win.dlAction(j);
            out.push({ type: "dl", key: j.id, label: j.label, state: Downloads.jobState(j.id),
                       status: win.dlStatus(j), action: a === "cancel" ? "Cancel" : a === "retry" ? "Retry" : "" });
        }
        if (win.dlAnyFinished)
            out.push({ type: "clear", key: "clear", label: "downloads", state: "", status: "Clear the finished ones", action: "Clear finished" });
        return out;
    }
    readonly property int trackCount: win.trackRows.length
    property int trackSel: 0
    onTrackCountChanged: {
        if (win.trackSel >= win.trackCount) win.trackSel = Math.max(0, win.trackCount - 1);
        if (win.trackCount === 0 && win.section === "tracked") win.section = "search";
    }
    function trackActivate(i) {
        const t = win.trackRows[i];
        if (!t) return;
        if (t.type === "job") { win.resetView(); win.jobKind = t.key; win.selectCommandIfListed(t.key); return; }
        if (t.type === "clear") { Downloads.clearFinished(); return; }
        const j = win.dlAll.find(x => x.id === t.key);
        if (!j) return;
        const a = win.dlAction(j);
        if (a === "cancel") Downloads.cancel(j.id);
        else if (a === "retry") Downloads.retry(j.id);
    }

    // --- palabras y horas ------------------------------------------------------------------
    function resultWord(r) {
        return ({ succeeded: "Completed", failed: "Failed", cancelled: "Cancelled",
                  unknown: "Result unknown", opened: "Opened in terminal" })[r] || r;
    }
    function resultGlyph(r) {
        return r === "succeeded" ? "check" : r === "failed" ? "alert" : r === "opened" ? "terminal"
             : r === "unknown" ? "x-circle" : "chevron-right";
    }
    function resultColor(r) {
        return r === "succeeded" ? Theme.primary : r === "failed" ? Theme.errorColor
             : r === "unknown" ? Theme.warn : Theme.fgVariant;
    }
    function clockOf(ms) {
        return Qt.formatDateTime(new Date(ms), Settings.clockFormat === "12h" ? "h:mm AP" : "HH:mm");
    }
    function whenOf(ms) {
        if (!(ms > 0)) return "";
        void Issues.now;
        const d = new Date(ms), t = new Date();
        const day = x => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
        const diff = Math.round((day(t) - day(d)) / 86400000);
        const pre = diff === 0 ? "today" : diff === 1 ? "yesterday" : Qt.formatDate(d, "MMM d");
        return pre + " " + win.clockOf(ms);
    }
    function checkLine(d) {
        if (!d || !d.ran || d.ran <= 0 || d.findings < 0) return "not run yet";
        const f = d.findings === 0 ? "no findings" : d.findings + (d.findings === 1 ? " finding" : " findings");
        const u = d.unknown > 0 ? " · " + d.unknown + " could not answer" : "";
        return f + u + " · " + win.whenOf(d.ran * 1000);
    }
    function tokenColor(tok) {
        switch (tok) {
        case "primary":   return Theme.primary;
        case "secondary": return Theme.secondary;
        case "error":     return Theme.errorColor;
        case "fgVariant": return Theme.fgVariant;
        default:          return Theme.fg;
        }
    }

    // --- la consola (fase 6B: los trabajos viven en Jobs; esta vista sólo los mira) -----------
    /** El trabajo que enseña la consola: "" o el id de una tarea del panel. */
    property string jobKind: ""
    readonly property QtObject job: win.jobKind.length > 0 ? Jobs.runner(win.jobKind) : null
    onJobKindChanged: {
        if (win.jobKind === "") return;
        if (Commands.get(win.jobKind)) {
            let i = win.cmdRows.findIndex(c => c.id === win.jobKind);
            if (i < 0) { tkSearch.clear(); win.cmdQuery = ""; i = win.cmdRows.findIndex(c => c.id === win.jobKind); }
            if (i >= 0) win.cmdSel = i;
            win.detailMode = "command";
        } else {
            win.detailMode = "job";
        }
    }
    readonly property bool reportShown: !!(win.job && win.job.task && win.job.task.output === "jsonl-report")
    property double copiedAt: 0
    Timer { id: copiedReset; interval: 2100; onTriggered: win.copiedAt = 0 }
    readonly property var report: { void (win.job ? win.job.tail : null); void (win.job ? win.job.state : "");
        return win.reportShown ? Jobs.report(win.jobKind) : ({ records: [], verdict: null, bad: [] }); }
    function reportText() {
        const lines = [];
        for (const x of win.report.records) {
            lines.push("[" + x.status + "] " + x.section + ": " + x.message);
            for (const d of x.detail || []) lines.push("    " + d);
        }
        if (win.report.verdict) lines.push(win.jobKind + ": " + Jobs.findingsText(win.report.verdict)
            + " · " + win.whenOf(win.report.verdict.ran * 1000));
        return lines.join("\n");
    }
    readonly property string jobLabel: win.job ? win.job.label : ""

    property bool passAsk: false
    property string passLabel: ""
    property bool dotUnlocking: false
    property var preLines: []
    property string preKind: ""

    /** "" | "yn" | "text" | "passphrase" */
    readonly property string dotAsk: win.passAsk ? "passphrase" : (win.job ? win.job.ask : "")
    readonly property string dotAskLabel: win.passAsk ? win.passLabel : (win.job ? win.job.askLabel : "")

    /** Al abrir: el trabajo vivo, o el terminado que aún no se vio. */
    function pickShown() {
        for (const r of Jobs.runners)
            if (r.busy || (!r.seen && r.state !== "idle")) { win.jobKind = r.kind; return; }
        win.jobKind = "";
    }
    Connections {
        target: Jobs
        function onLoadedChanged() { if (win.shown && win.jobKind === "") win.pickShown(); }
    }
    onJobChanged: Qt.callLater(win.markSeen)
    function markSeen() { if (win.shown && win.job && !win.job.busy) Jobs.markSeen(win.jobKind); }
    Connections {
        target: win.job
        ignoreUnknownSignals: true
        function onStateChanged() { Qt.callLater(win.markSeen); }
    }
    /** Limpia la VISTA (pregunta del panel, passphrase). Los trabajos siguen. */
    function resetView() {
        win.askAction = "";
        win.jobKind = "";
        win.passAsk = false;
        win.dotUnlocking = false;
        win.preLines = [];
        passField.clear();
        win.leaveAsk = false;
    }

    // --- dotbackup (F3d-2: cualquier tarea con `prompts: dotbackup`) --------------------------
    function runPrompted(id) {
        if (Jobs.runner(id).busy) { win.jobKind = id; return; }
        const t = Tasks.byId(id);
        if (!t || Jobs.whyNot(id).length > 0) return;
        if (t.sshAgent && !SshAgent.keyLoaded) {
            win.resetView();
            SshAgent.prepare();
            win.preLines = Ansi.parseLines("  The push needs your SSH key: " + SshAgent.keyPath
                + "\n  Unlock it below, or skip the push and do it later.");
            win.passLabel = "SSH key is locked — unlock to allow the push";
            win.passAsk = true;
            win.preKind = id;
            return;
        }
        win.preKind = id;
        win.launchPrompted();
    }
    function launchPrompted() {
        const id = win.preKind;
        win.resetView();
        Jobs.start(id, win.agentEnv(Tasks.byId(id)), win.name);
        win.jobKind = id;
    }
    function submitPassphrase() {
        const p = passField.text;
        passField.clear();
        win.passAsk = false;
        win.dotUnlocking = true;
        SshAgent.unlock(p);
    }
    function skipPush() { passField.clear(); win.passAsk = false; win.launchPrompted(); }
    Connections {
        target: SshAgent
        function onUnlocked() {
            if (!win.shown || !win.dotUnlocking) return;
            win.dotUnlocking = false;
            win.launchPrompted();
        }
        function onUnlockFailed(reason) {
            if (!win.shown || !win.dotUnlocking) return;
            win.dotUnlocking = false;
            win.passLabel = (reason && reason.toLowerCase().indexOf("passphrase") < 0)
                ? "Could not unlock: " + reason : "Wrong passphrase — try again";
            win.passAsk = true;
        }
    }
    function dotAnswer(text) { Jobs.answer(win.jobKind, text); }
    onDotAskChanged: {
        if (!win.shown) return;
        if (win.dotAsk === "yn") { ynGroup.reset(); Qt.callLater(() => keys.forceActiveFocus()); }
        else if (win.dotAsk === "text") {
            if (msgField.text.length === 0 && Drafts.has(win.draftKey)) msgField.text = Drafts.get(win.draftKey);
            Qt.callLater(msgField.focusField);
        } else if (win.dotAsk === "passphrase") Qt.callLater(passField.focusField);
        else Qt.callLater(win.placeFocus);
    }

    /** La confirmación del panel (diskbackup corre sin stdin: su `read` colgaría). */
    property string askAction: ""
    readonly property string askActionLabel: { const t = Tasks.byId(win.askAction); return t && t.confirm ? t.confirm : ""; }
    readonly property string draftKey: (win.jobKind || "dotbackup") + ":message"
    function answerAction(ans) {
        const id = win.askAction;
        win.askAction = "";
        if (ans === "y" && Tasks.has(id)) {
            win.resetView();
            Jobs.start(id, win.agentEnv(Tasks.byId(id)), win.name);
            win.jobKind = id;
        }
    }
    onAskActionChanged: {
        if (win.askAction.length > 0) ynGroup.reset();
        if (win.shown) Qt.callLater(win.placeFocus);
    }

    readonly property bool consoleAsking: win.dotAsk.length > 0 || win.askAction.length > 0
    onConsoleAskingChanged: {
        if (win.consoleAsking) win.section = "jobs";
        else if (win.section === "jobs") win.section = "search";
    }
    readonly property bool prePhase: win.passAsk || win.dotUnlocking
    readonly property bool consoleShown: (win.jobKind.length > 0 && !win.reportShown) || win.prePhase
                                         || win.askAction.length > 0
    readonly property string consoleLabel: win.prePhase ? Jobs.runner(win.preKind).label
        : win.askAction.length > 0 ? Jobs.runner(win.askAction).label : win.jobLabel
    readonly property var consoleLines: win.job ? win.job.lines : win.prePhase ? win.preLines : []
    readonly property bool consoleBusy: (win.job !== null && win.job.busy) || win.dotUnlocking
    readonly property string consoleTone: !win.job ? "neutral"
        : win.job.state === "succeeded" ? "ok"
        : win.job.state === "failed" || win.job.state === "unknown" ? "bad" : "neutral"
    readonly property string consoleStatus: !win.job ? ""
        : win.job.state === "running" ? " — running…"
        : win.job.state === "needs-input" ? " — waiting for you"
        : " — " + win.job.summary

    // --- teclado ------------------------------------------------------------------------------
    onSectionChanged: Qt.callLater(win.placeFocus)
    /** El buscador tiene el teclado sólo con "search"; si no, el Item de teclas (una «y» no se escribe). */
    function placeFocus() {
        if (!win.shown) return;
        if (win.leaveAsk) keys.forceActiveFocus();
        else if (win.dotAsk === "text") msgField.focusField();
        else if (win.dotAsk === "passphrase") passField.focusField();
        else if (win.section === "search" && !win.consoleAsking) tkSearch.focusField();
        else keys.forceActiveFocus();
    }
    readonly property bool typing: win.dotAsk === "text" || win.dotAsk === "passphrase"
    /** El mismo manejo para una tecla real y para el IPC `tasksUiKey`. */
    function handleKey(k, mods) {
        if (win.leaveAsk) {
            if (k === Qt.Key_Escape || k === Qt.Key_N) { win.leaveAsk = false; Qt.callLater(win.placeFocus); return true; }
            if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Y) { win.closeNow(); return true; }
            return true;
        }
        if (win.askAction.length > 0) {
            if (k === Qt.Key_Y) { win.answerAction("y"); return true; }
            if (k === Qt.Key_N || k === Qt.Key_Escape) { win.answerAction("n"); return true; }
            return win.ynKey(k);
        }
        if (win.dotAsk === "yn") {
            if (k === Qt.Key_Y) { win.dotAnswer("y"); return true; }
            if (k === Qt.Key_N) { win.dotAnswer("n"); return true; }
            if (k === Qt.Key_Escape) { win.requestClose(); return true; }   // la pregunta sigue en el trabajo
            return win.ynKey(k);
        }
        if (k === Qt.Key_Escape) {
            if (tkSearch.text.length > 0) { tkSearch.clear(); win.section = "search"; }
            else win.requestClose();
            return true;
        }
        const up = k === Qt.Key_Up, down = k === Qt.Key_Down;
        const enter = k === Qt.Key_Return || k === Qt.Key_Enter;
        if (win.section === "tracked") {
            if (up && win.trackSel > 0) win.trackSel--;
            else if (up || k === Qt.Key_Tab || k === Qt.Key_Backtab) win.section = "search";
            else if (down) win.trackSel = Math.min(win.trackCount - 1, win.trackSel + 1);
            else if (enter) win.trackActivate(win.trackSel);
            else return false;
            return true;
        }
        if (win.section === "search") {
            if (up || down) { win.cmdMove(down ? 1 : -1); return true; }
            if (enter) { win.runSelectedCommand(); return true; }
            if (k === Qt.Key_Tab) { if (win.trackCount > 0) win.section = "tracked"; return true; }
        }
        return false;
    }
    function ynKey(k) {
        const e = { key: k, modifiers: 0, accepted: false };
        return ynGroup.handleKey(e) || true;
    }
    /** IPC (`tasksUiKey`): la misma ruta que una tecla, sin inyectar nada al compositor. */
    function key(name, shift) {
        const map = { Escape: Qt.Key_Escape, Tab: Qt.Key_Tab, Up: Qt.Key_Up, Down: Qt.Key_Down, Left: Qt.Key_Left,
                      Right: Qt.Key_Right, Return: Qt.Key_Return };
        let k = name === "Tab" && shift ? Qt.Key_Backtab : map[name];
        if (!k && /^[A-Z]$/.test(name)) k = Qt.Key_A + name.charCodeAt(0) - 65;
        if (!k) return false;
        // con el buscador enfocado, las teclas que él maneja pasan por sus señales (como en la ventana real)
        if (win.section === "search" && !win.consoleAsking && !win.leaveAsk) {
            if (k === Qt.Key_Up || k === Qt.Key_Down) { win.cmdMove(k === Qt.Key_Down ? 1 : -1); return true; }
            if (k === Qt.Key_Return) { win.runSelectedCommand(); return true; }
            if (k === Qt.Key_Tab) { if (win.trackCount > 0) win.section = "tracked"; return true; }
            if (k === Qt.Key_Escape) { if (tkSearch.text.length > 0) tkSearch.clear(); else win.requestClose(); return true; }
        }
        if (win.typing && k !== Qt.Key_Escape && !win.leaveAsk) return false;
        return win.handleKey(k, 0);
    }
    function setQuery(text) { tkSearch.text = text; win.section = "search"; return true; }

    function state() {
        return { shown: win.shown, section: win.section, cmdQuery: win.cmdQuery, cmd: win.cmdCur ? win.cmdCur.id : "",
                 cmdResult: win.cmdResult.state, cmdRows: win.cmdRows.map(c => c.id), cmdStatus: win.cmdStatus,
                 cmdButton: win.cmdButton, history: win.cmdHistory.map(e => e.label + " · " + e.result),
                 jobKind: win.jobKind, label: win.jobLabel, running: Jobs.anyBusy, ask: win.dotAsk,
                 askAction: win.askAction, askLabel: win.askActionLabel, consoleLabel: win.consoleLabel,
                 consoleShown: win.consoleShown, reportShown: win.reportShown, leaveAsk: win.leaveAsk,
                 trackSel: win.trackSel, trackRows: win.trackRows.map(t => t.label + " · " + t.status + (t.action ? " [" + t.action + "]" : "")),
                 searchFocus: tkSearch.editing, grab: win.grab, windowActive: card.Window.active,
                 layer: { x: Math.round(card.x), y: Math.round(card.y), w: Math.round(card.width), h: Math.round(card.height),
                          screenW: Math.round(win.areaW), screenH: Math.round(win.areaH) } };
    }

    // =============================================================================================
    // La ventana
    // =============================================================================================
    Item {
        id: card
        width: Math.min(Metrics.tasksW * win.s, win.areaW - win.leftInset - win.rightInset)
        height: Math.max(0, Math.min(Metrics.tasksH * win.s, win.areaH - win.topInset - win.bottomInset))
        onWidthChanged: if (win.shown) Qt.callLater(win.place)
        onHeightChanged: if (win.shown) Qt.callLater(win.place)
        Window.onActiveChanged: if (Window.active && win.grab) release.restart()

        // Entrada/salida (2026-11-11, theme/Reveal, estilo de Settings → Animations): opacidad, escala desde
        // el centro y subida; sólo visual (posición, tamaño y región de entrada no cambian).
        Reveal { id: cardReveal; shown: win.shown; s: win.s }
        readonly property real appear: cardReveal.progress
        opacity: cardReveal.opacity
        scale: cardReveal.scale
        transformOrigin: Item.Center
        // sx/sy: Power-on y Mochi (theme/Reveal); 1 con los demás
        transform: [Translate { y: cardReveal.dy }, Scale { origin.x: card.width / 2; origin.y: card.height / 2; xScale: cardReveal.sx; yScale: cardReveal.sy }]
        layer.enabled: card.appear > 0.001 && card.appear < 0.999
        // Bloom, Ink, Scroll y Mist dibujan sobre la capa de la apertura (theme/RevealEffect, ADR-36)
        layer.effect: cardReveal.effect ? cardFx : null
        Component { id: cardFx; RevealEffect { rv: cardReveal; s: win.s } }

        Glass {
            anchors.fill: parent
            s: win.s
            radius: Metrics.rLg * win.s
            surface: "tasks"
            shadowed: !head.drag.active
        }

        Item {
            id: keys
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => { if ((win.leaveAsk || !win.typing) && win.handleKey(event.key, event.modifiers)) event.accepted = true; }
        }

        // ---- cabecera (arrastre) -----------------------------------------------------------
        MouseArea {
            id: head
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 62 * win.s
            cursorShape: head.drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            drag.target: card
            drag.threshold: 2
            drag.minimumX: win.leftInset
            drag.maximumX: win.areaW - card.width - win.rightInset
            drag.minimumY: win.topInset
            drag.maximumY: win.areaH - card.height - win.bottomInset
            onPressed: win.placeFocus()
            onReleased: TasksUi.remember(win.name, card.x, card.y)
        }
        Row {
            anchors.left: parent.left
            anchors.leftMargin: 20 * win.s
            y: 16 * win.s
            spacing: Metrics.sp2 * win.s
            Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 5 * win.s; height: 5 * win.s; radius: Metrics.pill(width); color: Theme.primary }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Tasks"
                color: Theme.fg
                font.family: Typography.ui; font.pixelSize: Typography.display * win.s; font.weight: Typography.wStrong
                Accessible.role: Accessible.Heading
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: {
                    const busy = Jobs.runners.filter(r => r.busy).length;
                    const wait = Jobs.runners.filter(r => r.state === "needs-input").length;
                    return wait > 0 ? wait + " waiting for you" : busy > 0 ? busy + " running"
                         : "Jobs keep running when you close this window";
                }
                color: Jobs.runners.some(r => r.state === "needs-input") ? Theme.warn : Theme.fgVariant
                font.family: Typography.ui; font.pixelSize: Typography.caption * win.s
            }
        }
        Rectangle {
            anchors.right: parent.right
            anchors.rightMargin: 12 * win.s
            y: 14 * win.s
            width: 30 * win.s; height: 30 * win.s; radius: Metrics.pill(width)
            color: closeArea.containsMouse ? Theme.hoverBg : "transparent"
            Accessible.role: Accessible.Button
            Accessible.name: "Close Tasks"
            Icon { anchors.centerIn: parent; name: "close"; size: 15 * win.s; color: closeArea.containsMouse ? Theme.fg : Theme.fgVariant }
            MouseArea { id: closeArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.requestClose() }
        }
        Rectangle {
            id: rule
            anchors.top: head.bottom
            anchors.left: parent.left; anchors.right: parent.right
            anchors.leftMargin: 20 * win.s; anchors.rightMargin: 20 * win.s
            height: 1
            color: Theme.hair
        }

        // ---- izquierda: buscar y elegir; debajo, los trabajos -------------------------------
        Item {
            id: left
            anchors.top: rule.bottom; anchors.topMargin: 12 * win.s
            anchors.bottom: footer.top; anchors.bottomMargin: 8 * win.s
            anchors.left: parent.left; anchors.leftMargin: 16 * win.s
            width: Math.round(card.width * 0.36)

            Rectangle {
                id: tkSearchBox
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: 30 * win.s
                radius: Metrics.r(8) * win.s
                color: Theme.tileBg
                border.width: win.section === "search" && !win.consoleAsking ? Metrics.focusWidth * win.s : 1
                border.color: win.section === "search" && !win.consoleAsking ? Theme.selBorder : Theme.hair
                Icon {
                    id: tkSearchGlyph
                    anchors.left: parent.left
                    anchors.leftMargin: 9 * win.s
                    anchors.verticalCenter: parent.verticalCenter
                    name: "search"
                    size: 12 * win.s
                    color: Theme.fgVariant
                }
                SearchField {
                    id: tkSearch
                    anchors.left: tkSearchGlyph.right
                    anchors.leftMargin: 7 * win.s
                    anchors.right: parent.right
                    anchors.rightMargin: 8 * win.s
                    anchors.verticalCenter: parent.verticalCenter
                    s: win.s
                    placeholder: "Search tasks"
                    onTextChanged: { win.cmdQuery = text; win.cmdSel = 0; if (win.shown) win.userPicked(); }
                    onMoved: (d) => win.cmdMove(d)
                    onAccepted: win.runSelectedCommand()
                    onDismissed: { if (tkSearch.text.length > 0) tkSearch.clear(); else win.requestClose(); }
                    onTabbed: if (win.trackCount > 0) win.section = "tracked"
                }
                MouseArea {
                    anchors.fill: parent
                    z: -1
                    onClicked: { win.section = "search"; tkSearch.focusField(); }
                }
            }

            ListView {
                id: tkList
                anchors.top: tkSearchBox.bottom
                anchors.topMargin: 8 * win.s
                anchors.left: parent.left
                anchors.right: parent.right
                height: Math.min(contentHeight, parent.height - tkSearchBox.height - 8 * win.s - jobsBox.height - 12 * win.s)
                clip: true
                model: win.cmdRows
                currentIndex: win.cmdSel
                boundsBehavior: Flickable.StopAtBounds
                delegate: Item {
                    id: cmdRow
                    required property var modelData
                    required property int index
                    readonly property bool cur: cmdRow.index === win.cmdSel && win.detailMode === "command"
                    readonly property var runner: cmdRow.modelData.runs === "panel" ? Jobs.runner(cmdRow.modelData.id) : null
                    width: tkList.width
                    height: 46 * win.s
                    Accessible.role: Accessible.ListItem
                    Accessible.name: "sumi " + cmdRow.modelData.id
                    Accessible.description: cmdRow.modelData.desc + ". " + Commands.whereLong(cmdRow.modelData)
                    Accessible.selected: cmdRow.cur
                    Rectangle {
                        anchors.fill: parent
                        anchors.topMargin: 1 * win.s
                        anchors.bottomMargin: 1 * win.s
                        radius: Metrics.r(8) * win.s
                        color: cmdRow.cur ? Theme.selBg : (cmdArea.containsMouse ? Theme.hoverBg : "transparent")
                        Behavior on color { ColorAnimation { duration: Motion.fast } }
                    }
                    Rectangle {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        visible: cmdRow.cur
                        width: 2 * win.s
                        height: parent.height * 0.42
                        radius: Metrics.pill(width)
                        color: Theme.primary
                    }
                    Item {
                        id: cmdIcon
                        anchors.left: parent.left
                        anchors.leftMargin: 10 * win.s
                        anchors.verticalCenter: parent.verticalCenter
                        width: 16 * win.s
                        height: width
                        Icon {
                            anchors.centerIn: parent
                            name: cmdRow.modelData.glyph
                            size: 13 * win.s
                            color: cmdRow.cur ? Theme.primary : Theme.fgVariant
                        }
                    }
                    Column {
                        anchors.left: cmdIcon.right
                        anchors.leftMargin: 10 * win.s
                        anchors.right: parent.right
                        anchors.rightMargin: 10 * win.s
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 3 * win.s
                        Text {
                            width: Math.max(0, parent.width - cmdTag.width - 8 * win.s)
                            elide: Text.ElideRight
                            text: cmdRow.modelData.id
                            color: cmdRow.cur ? Theme.fg : Theme.fgVariant
                            font.family: Typography.mono
                            font.pixelSize: Typography.body * win.s
                            font.weight: cmdRow.cur ? Font.DemiBold : Font.Normal
                        }
                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            text: cmdRow.modelData.desc
                            color: Theme.fgVariant
                            font.family: Typography.ui
                            font.pixelSize: Typography.label * win.s
                        }
                    }
                    // dónde corre, o su estado si está vivo
                    Text {
                        id: cmdTag
                        anchors.right: parent.right
                        anchors.rightMargin: 10 * win.s
                        anchors.top: parent.top
                        anchors.topMargin: 7 * win.s
                        text: cmdRow.runner && cmdRow.runner.state === "needs-input" ? "Needs input"
                            : cmdRow.runner && cmdRow.runner.busy ? "Running" : Commands.whereText(cmdRow.modelData)
                        color: cmdRow.runner && (cmdRow.runner.busy || cmdRow.runner.state === "needs-input") ? Theme.primary
                            : cmdRow.cur ? Theme.fgVariant : Theme.outlineText
                        font.family: Typography.ui
                        font.pixelSize: Typography.micro * win.s
                    }
                    MouseArea {
                        id: cmdArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { win.cmdSel = cmdRow.index; win.userPicked(); win.section = "search"; tkSearch.focusField(); }
                        onDoubleClicked: { win.cmdSel = cmdRow.index; win.runSelectedCommand(); }
                    }
                }
            }
            ScrollHint { view: tkList; s: win.s }

            Empty {
                anchors.top: tkSearchBox.bottom
                anchors.topMargin: Metrics.sp5 * win.s
                anchors.horizontalCenter: parent.horizontalCenter
                visible: win.cmdRows.length === 0
                s: win.s
                maxWidth: parent.width
                glyph: win.cmdResult.state === "unavailable" ? "alert" : "search"
                text: win.cmdResult.state === "unavailable" ? "Commands unavailable" : "No matching task"
                hint: win.cmdResult.state === "unavailable" ? "The sumi catalog could not be loaded"
                    : "Search by name or by a word of its description"
            }

            // -- trabajos en seguimiento: abajo, con su propio scroll --
            Column {
                id: jobsBox
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                spacing: 4 * win.s
                height: implicitHeight
                Rectangle { width: parent.width; height: 1; color: Theme.hair }
                Item { width: 1; height: 2 * win.s }
                Text {
                    text: "JOBS"
                    color: Theme.outlineText
                    font.family: Typography.ui
                    font.pixelSize: Typography.micro * win.s
                    font.weight: Typography.wStrong
                    font.letterSpacing: Typography.tracking * win.s
                }
                Text {
                    width: parent.width
                    visible: win.trackRows.length === 0
                    wrapMode: Text.WordWrap
                    text: "No jobs yet. Tasks and downloads appear here when started."
                    color: Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.label * win.s
                }
                Flickable {
                    id: trFlick
                    width: parent.width
                    height: Math.min(trCol.implicitHeight, 5 * 28 * win.s)
                    contentHeight: trCol.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    interactive: contentHeight > height
                    Column {
                        id: trCol
                        width: trFlick.width
                        spacing: 2 * win.s
                        Repeater {
                            id: trRep
                            model: win.trackRows
                            delegate: Item {
                                id: trRow
                                required property var modelData
                                required property int index
                                readonly property bool sel: win.section === "tracked" && win.trackSel === trRow.index
                                readonly property string st: trRow.modelData.state
                                readonly property bool warn: ["failed", "interrupted", "paused", "unknown"].indexOf(trRow.st) >= 0
                                width: trCol.width
                                height: 26 * win.s
                                Accessible.role: Accessible.ListItem
                                Accessible.name: trRow.modelData.label + ", " + trRow.modelData.status
                                onSelChanged: if (trRow.sel) {
                                    if (trRow.y < trFlick.contentY) trFlick.contentY = trRow.y;
                                    else if (trRow.y + trRow.height > trFlick.contentY + trFlick.height)
                                        trFlick.contentY = trRow.y + trRow.height - trFlick.height;
                                }
                                Rectangle {
                                    anchors.fill: parent
                                    radius: Metrics.r(6) * win.s
                                    color: trRow.sel ? Theme.selBg : "transparent"
                                    border.width: trRow.sel ? 1 : 0
                                    border.color: Theme.selBorder
                                }
                                Item {
                                    id: trIcon
                                    anchors.left: parent.left
                                    anchors.leftMargin: 6 * win.s
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 13 * win.s; height: width
                                    Icon {
                                        anchors.centerIn: parent
                                        name: trRow.st === "done" || trRow.st === "succeeded" ? "check"
                                            : trRow.warn ? "alert" : trRow.modelData.type === "dl" ? "wallpaper" : "folder"
                                        size: 11 * win.s
                                        color: trRow.st === "done" || trRow.st === "succeeded" ? Theme.primary
                                            : trRow.warn ? Theme.warn : Theme.fgVariant
                                    }
                                }
                                Text {
                                    id: trName
                                    anchors.left: trIcon.right
                                    anchors.leftMargin: 6 * win.s
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.min(implicitWidth, trCol.width * 0.4)
                                    elide: Text.ElideMiddle
                                    text: trRow.modelData.label
                                    color: Theme.fg
                                    font.family: Typography.mono
                                    font.pixelSize: Typography.caption * win.s
                                }
                                Text {
                                    anchors.left: trName.right
                                    anchors.leftMargin: 8 * win.s
                                    anchors.right: trBtn.visible ? trBtn.left : parent.right
                                    anchors.rightMargin: 8 * win.s
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                    text: trRow.modelData.status
                                    color: trRow.warn ? Theme.warn : Theme.fgVariant
                                    font.family: Typography.ui
                                    font.pixelSize: Typography.caption * win.s
                                }
                                ActionButton {
                                    id: trBtn
                                    anchors.right: parent.right
                                    anchors.rightMargin: 4 * win.s
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: trRow.modelData.action.length > 0
                                    s: win.s
                                    label: trRow.modelData.action
                                    focused: trRow.sel
                                    ringless: true
                                    onTriggered: { win.section = "tracked"; win.trackSel = trRow.index; win.trackActivate(trRow.index); }
                                }
                            }
                        }
                    }
                }
            }
        }

        Rectangle {
            id: midRule
            anchors.top: rule.bottom; anchors.bottom: footer.top
            anchors.topMargin: 12 * win.s; anchors.bottomMargin: 8 * win.s
            anchors.left: left.right; anchors.leftMargin: 14 * win.s
            width: 1
            color: Theme.hair
        }

        // ---- derecha: la tarea elegida, su consola o su informe, y su historial ------------------
        Flickable {
            id: tkFlick
            anchors.top: rule.bottom; anchors.topMargin: 12 * win.s
            anchors.bottom: footer.top; anchors.bottomMargin: 8 * win.s
            anchors.left: midRule.right; anchors.leftMargin: 14 * win.s
            anchors.right: parent.right; anchors.rightMargin: 18 * win.s
            contentWidth: width
            contentHeight: tkCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            Column {
                id: tkCol
                width: tkFlick.width
                spacing: 10 * win.s

                // -- con una passphrase sin enviar, cerrar pregunta (DESIGN §4) --
                Rectangle {
                    width: parent.width
                    visible: win.leaveAsk
                    height: leaveCol.implicitHeight + 20 * win.s
                    radius: Metrics.r(10) * win.s
                    color: Qt.alpha(Theme.warn, 0.10)
                    border.width: 1
                    border.color: Qt.alpha(Theme.warn, 0.45)
                    Column {
                        id: leaveCol
                        x: 12 * win.s; y: 10 * win.s
                        width: parent.width - 24 * win.s
                        spacing: 8 * win.s
                        Text {
                            width: parent.width
                            wrapMode: Text.WordWrap
                            text: "An unsent passphrase — closing discards it."
                            color: Theme.fg
                            font.family: Typography.ui; font.pixelSize: Typography.body * win.s; font.weight: Font.DemiBold
                        }
                        Row {
                            spacing: 8 * win.s
                            ActionButton { s: win.s; label: "Discard and close  ·  ⏎"; danger: true; onTriggered: win.closeNow() }
                            ActionButton { s: win.s; label: "Keep editing  ·  Esc"; onTriggered: { win.leaveAsk = false; win.placeFocus(); } }
                        }
                    }
                }

                // -- la orden elegida: qué hace, dónde acaba y cómo terminó lo último --
                Rectangle {
                    width: parent.width
                    height: commandInfo.implicitHeight + 28 * win.s
                    radius: Metrics.r(12) * win.s
                    color: Qt.alpha(Theme.fg, 0.04)
                    border.width: 1
                    border.color: Qt.alpha(Theme.fg, 0.08)
                    visible: win.cmdCur !== null && win.detailMode === "command"
                    Column {
                        id: commandInfo
                        x: 14 * win.s; y: 14 * win.s
                        width: parent.width - 28 * win.s
                        spacing: 10 * win.s
                        Item {
                            width: parent.width
                            height: commandTitle.implicitHeight
                            Row {
                                id: commandTitle
                                anchors.left: parent.left
                                anchors.right: commandRun.left
                                anchors.rightMargin: Metrics.sp2 * win.s
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 8 * win.s
                                Icon {
                                    id: commandGlyph
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: win.cmdCur ? win.cmdCur.glyph : ""
                                    size: 18 * win.s
                                    color: Theme.primary
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.max(0, commandTitle.width - commandGlyph.width - commandTitle.spacing)
                                    elide: Text.ElideRight
                                    text: win.cmdCur ? "sumi " + win.cmdCur.id : ""
                                    color: Theme.fg
                                    font.family: Typography.mono
                                    font.pixelSize: Typography.title * win.s
                                    font.weight: Typography.wStrong
                                }
                            }
                            ActionButton {
                                id: commandRun
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                s: win.s
                                label: win.cmdButton
                                primary: true
                                enabled: !win.cmdCur || Jobs.whyNot(win.cmdCur.id).length === 0
                                onTriggered: win.runSelectedCommand()
                            }
                        }
                        Text {
                            width: parent.width
                            wrapMode: Text.WordWrap
                            text: win.cmdCur ? win.cmdCur.desc + "\n" + (Jobs.whyNot(win.cmdCur.id) || Commands.whereLong(win.cmdCur)) : ""
                            color: Theme.fgVariant
                            font.family: Typography.ui
                            font.pixelSize: Typography.body * win.s
                        }
                        Text {
                            width: parent.width
                            wrapMode: Text.WordWrap
                            visible: text.length > 0
                            text: win.cmdStatus
                            color: win.cmdStatusBad ? Theme.errorColor : Theme.fg
                            font.family: Typography.ui
                            font.pixelSize: Typography.body * win.s
                        }
                    }
                }

                // -- consola de un trabajo del panel --
                Column {
                    width: parent.width
                    spacing: 6 * win.s
                    visible: win.consoleShown

                    Row {
                        spacing: 6 * win.s
                        Icon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: win.consoleBusy ? "cog" : win.consoleTone === "ok" ? "check"
                                : win.consoleTone === "bad" ? "alert" : "chevron-right"
                            size: 11 * win.s
                            color: win.consoleBusy || win.consoleTone === "neutral" ? Theme.fgVariant
                                : win.consoleTone === "ok" ? Theme.primary : Theme.errorColor
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.min(implicitWidth, tkCol.width - 20 * win.s)
                            elide: Text.ElideRight
                            text: win.consoleLabel + (win.dotUnlocking ? " — running…" : win.consoleStatus)
                            color: Theme.fgVariant
                            font.family: Typography.ui
                            font.pixelSize: Typography.caption * win.s
                            font.weight: Font.DemiBold
                        }
                    }

                    Rectangle {
                        width: parent.width
                        // la consola ocupa lo que queda: aquí sí cabe una salida de verdad
                        height: Math.max(160 * win.s, tkFlick.height - 230 * win.s)
                        radius: Metrics.r(8) * win.s
                        color: Theme.tileBg
                        clip: true
                        Flickable {
                            id: logFlick
                            anchors.fill: parent
                            anchors.margins: 10 * win.s
                            // la barra, fuera del texto a 6·s, a 5·s del borde de la caja
                            anchors.rightMargin: 14 * win.s
                            contentWidth: logCol.width
                            contentHeight: logCol.height
                            boundsBehavior: Flickable.StopAtBounds
                            onContentHeightChanged: contentY = Math.max(0, contentHeight - height)
                            Column {
                                id: logCol
                                spacing: 0
                                Repeater {
                                    model: win.consoleLines
                                    delegate: Text {
                                        required property var modelData
                                        textFormat: Text.RichText
                                        text: {
                                            let h = "";
                                            for (let i = 0; i < modelData.length; i++) {
                                                const seg = modelData[i];
                                                const esc = String(seg.text)
                                                    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
                                                const w = seg.bold ? "font-weight:600;" : "";
                                                h += "<span style=\"color:" + win.tokenColor(seg.token)
                                                   + ";" + w + "\">" + esc + "</span>";
                                            }
                                            return h.length ? h : "&nbsp;";
                                        }
                                        font.family: Typography.mono
                                        font.pixelSize: Typography.caption * win.s
                                    }
                                }
                            }
                        }
                        ScrollHint { view: logFlick; s: win.s }
                    }

                    // -- respuesta a un prompt de dotbackup, o a una confirmación del panel --
                    Column {
                        width: parent.width
                        spacing: 6 * win.s
                        visible: win.dotAsk.length > 0 || win.askAction.length > 0

                        Text {
                            width: parent.width
                            wrapMode: Text.WordWrap
                            text: win.dotAsk.length > 0 ? win.dotAskLabel : win.askActionLabel
                            color: Theme.fg
                            font.family: Typography.ui
                            font.pixelSize: Typography.body * win.s
                            font.weight: Font.DemiBold
                        }
                        ActionGroup {
                            id: ynGroup
                            visible: win.dotAsk === "yn" || win.askAction.length > 0
                            width: parent.width
                            s: win.s
                            orientation: "horizontal"
                            stretch: false
                            spacing: 8 * win.s
                            actions: [
                                { id: "y", label: "Yes  ·  y", primary: true },
                                { id: "n", label: "No  ·  n" }
                            ]
                            onTriggered: (id) => win.dotAsk.length > 0 ? win.dotAnswer(id) : win.answerAction(id)
                        }
                        Rectangle {
                            visible: win.dotAsk === "text"
                            width: parent.width
                            height: 30 * win.s
                            radius: Metrics.r(6) * win.s
                            color: Theme.tileBg
                            border.width: 1
                            border.color: Theme.hair
                            SearchField {
                                id: msgField
                                anchors.fill: parent
                                anchors.leftMargin: 8 * win.s
                                anchors.rightMargin: 8 * win.s
                                s: win.s
                                placeholder: "dotfiles: backup <date>"
                                onTextChanged: if (win.dotAsk === "text") Drafts.set(win.draftKey, msgField.text)
                                onAccepted: { const t = msgField.text; msgField.clear(); Drafts.discard(win.draftKey); win.dotAnswer(t); }
                                onDismissed: { msgField.clear(); win.dotAnswer(""); }
                            }
                        }
                        Rectangle {
                            visible: win.dotAsk === "passphrase"
                            width: parent.width
                            height: 30 * win.s
                            radius: Metrics.r(6) * win.s
                            color: Theme.tileBg
                            border.width: 1
                            border.color: Theme.hair
                            SearchField {
                                id: passField
                                anchors.fill: parent
                                anchors.leftMargin: 8 * win.s
                                anchors.rightMargin: 8 * win.s
                                s: win.s
                                secret: true
                                placeholder: "SSH key passphrase"
                                onAccepted: win.submitPassphrase()
                                onDismissed: win.skipPush()
                            }
                        }
                        Row {
                            visible: win.dotAsk === "passphrase"
                            spacing: 8 * win.s
                            ActionButton { s: win.s; label: "Unlock  ·  ⏎"; primary: true; onTriggered: win.submitPassphrase() }
                            ActionButton { s: win.s; label: "Skip push  ·  Esc"; onTriggered: win.skipPush() }
                        }
                    }

                    Row {
                        width: parent.width
                        spacing: 6 * win.s
                        visible: win.dotUnlocking
                        Icon { anchors.verticalCenter: parent.verticalCenter; name: "cog"; size: 11 * win.s; color: Theme.fgVariant }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "unlocking SSH key…"
                            color: Theme.fgVariant
                            font.family: Typography.ui
                            font.pixelSize: Typography.caption * win.s
                        }
                    }
                }

                // -- informe de health / doctor (11C): la salida estructurada --
                Column {
                    id: reportCol
                    width: parent.width
                    spacing: 5 * win.s
                    visible: win.reportShown

                    Item {
                        width: parent.width
                        height: 24 * win.s
                        Row {
                            anchors.left: parent.left
                            anchors.right: copyBtn.left
                            anchors.rightMargin: 8 * win.s
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 6 * win.s
                            Icon {
                                id: repIcon
                                anchors.verticalCenter: parent.verticalCenter
                                name: win.job && win.job.busy ? "reload"
                                    : win.report.verdict ? (win.report.verdict.status === "ok" ? "check" : "alert") : "x-circle"
                                size: 12 * win.s
                                color: win.job && win.job.busy ? Theme.fgVariant
                                    : win.report.verdict && win.report.verdict.status === "ok" ? Theme.primary
                                    : win.report.verdict ? Theme.warn : Theme.errorColor
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - repIcon.width - parent.spacing
                                elide: Text.ElideRight
                                text: !win.job ? ""
                                    : win.job.busy ? win.job.label + " — running…"
                                    : win.report.verdict ? win.job.label + " — " + Jobs.findingsText(win.report.verdict)
                                                            + " · " + win.whenOf(win.report.verdict.ran * 1000)
                                    : win.job.label + " — " + win.resultWord(win.job.state).toLowerCase()
                                color: Theme.fg
                                font.family: Typography.ui
                                font.pixelSize: Typography.caption * win.s
                                font.weight: Font.DemiBold
                            }
                        }
                        ActionButton {
                            id: copyBtn
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            visible: win.report.records.length > 0
                            s: win.s
                            label: win.copiedAt > 0 && Date.now() - win.copiedAt < 2000 ? "Copied" : "Copy"
                            onTriggered: { Quickshell.clipboardText = win.reportText(); win.copiedAt = Date.now(); copiedReset.restart(); }
                        }
                    }
                    Repeater {
                        model: win.report.records
                        delegate: Column {
                            id: recRow
                            required property var modelData
                            readonly property string st: recRow.modelData.status
                            readonly property bool loud: recRow.st === "finding" || recRow.st === "unknown"
                            width: reportCol.width
                            spacing: 1 * win.s
                            Row {
                                spacing: 7 * win.s
                                Icon {
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: recRow.st === "ok" ? "check" : recRow.st === "finding" ? "alert"
                                        : recRow.st === "unknown" ? "x-circle" : "info"
                                    size: 11 * win.s
                                    color: recRow.st === "ok" ? Theme.primary : recRow.st === "finding" ? Theme.errorColor
                                        : recRow.st === "unknown" ? Theme.warn : Theme.fgVariant
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: recRow.modelData.section
                                    width: 150 * win.s
                                    elide: Text.ElideRight
                                    color: Theme.fgVariant
                                    font.family: Typography.ui
                                    font.pixelSize: Typography.caption * win.s
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: reportCol.width - 180 * win.s
                                    elide: Text.ElideRight
                                    text: recRow.modelData.message
                                    color: recRow.loud ? Theme.fg : Theme.fgVariant
                                    font.family: Typography.ui
                                    font.pixelSize: Typography.caption * win.s
                                    font.weight: recRow.loud ? Font.DemiBold : Font.Normal
                                }
                            }
                            Repeater {
                                model: recRow.loud ? (recRow.modelData.detail || []).slice(0, 8) : []
                                delegate: Text {
                                    required property var modelData
                                    x: 18 * win.s
                                    width: reportCol.width - 18 * win.s
                                    elide: Text.ElideRight
                                    text: modelData
                                    color: Theme.fgVariant
                                    font.family: Typography.mono
                                    font.pixelSize: Typography.micro * win.s
                                }
                            }
                        }
                    }
                    Text {
                        visible: win.report.bad.length > 0
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: "Other output: " + win.report.bad.slice(0, 3).join(" · ")
                        color: Theme.warn
                        font.family: Typography.mono
                        font.pixelSize: Typography.micro * win.s
                    }
                    Text {
                        visible: win.job !== null && !win.job.busy && !win.report.verdict
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: "No report came back — " + (win.job ? win.job.summary : "")
                        color: Theme.errorColor
                        font.family: Typography.ui
                        font.pixelSize: Typography.caption * win.s
                    }
                }

                // -- últimas ejecuciones de la tarea elegida (Activity) --
                Column {
                    width: parent.width
                    spacing: 3 * win.s
                    visible: win.detailMode === "command" && win.cmdCur !== null && !win.consoleShown && !win.reportShown
                    Text {
                        text: "RECENT RUNS"
                        color: Theme.outlineText
                        font.family: Typography.ui
                        font.pixelSize: Typography.micro * win.s
                        font.weight: Typography.wStrong
                        font.letterSpacing: Typography.tracking * win.s
                    }
                    Text {
                        visible: win.cmdHistory.length === 0
                        text: Activity.loaded ? "Nothing run from the shell yet" : "Loading…"
                        color: Theme.fgVariant
                        font.family: Typography.ui
                        font.pixelSize: Typography.caption * win.s
                    }
                    Repeater {
                        model: win.cmdHistory
                        delegate: Item {
                            id: hiRow
                            required property var modelData
                            width: tkCol.width
                            height: 24 * win.s
                            Accessible.role: Accessible.ListItem
                            Accessible.name: win.resultWord(hiRow.modelData.result) + ", " + win.whenOf(hiRow.modelData.at)
                            Item {
                                id: hiIcon
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                width: 13 * win.s; height: width
                                Icon { anchors.centerIn: parent; name: win.resultGlyph(hiRow.modelData.result); size: 11 * win.s; color: win.resultColor(hiRow.modelData.result) }
                            }
                            Text {
                                id: hiResult
                                anchors.left: hiIcon.right
                                anchors.leftMargin: 8 * win.s
                                anchors.verticalCenter: parent.verticalCenter
                                width: 150 * win.s
                                elide: Text.ElideRight
                                text: win.resultWord(hiRow.modelData.result)
                                color: win.resultColor(hiRow.modelData.result)
                                font.family: Typography.ui
                                font.pixelSize: Typography.caption * win.s
                            }
                            Text {
                                anchors.left: hiResult.right
                                anchors.leftMargin: 8 * win.s
                                anchors.right: hiBtn.visible ? hiBtn.left : parent.right
                                anchors.rightMargin: 8 * win.s
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                                text: win.whenOf(hiRow.modelData.at) + (hiRow.modelData.summary ? " · " + hiRow.modelData.summary : "")
                                color: Theme.fgVariant
                                font.family: Typography.ui
                                font.pixelSize: Typography.caption * win.s
                                font.features: ({ "tnum": 1 })
                            }
                            ActionButton {
                                id: hiBtn
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                visible: win.activityHasOutput(hiRow.modelData)
                                s: win.s
                                label: "Output"
                                ringless: true
                                onTriggered: { win.resetView(); win.jobKind = hiRow.modelData.kind; }
                            }
                        }
                    }
                }
            }
        }
        ScrollHint { view: tkFlick; s: win.s }

        // ---- pie ------------------------------------------------------------------------------
        Text {
            id: footer
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 12 * win.s
            anchors.left: parent.left; anchors.right: parent.right
            anchors.leftMargin: 20 * win.s; anchors.rightMargin: 20 * win.s
            elide: Text.ElideRight
            text: win.leaveAsk ? "⏎ discard and close · Esc keep editing"
                : win.askAction.length > 0 || win.dotAsk === "yn" ? "y yes · n no · ← → ⏎ choose · Esc " + (win.askAction.length > 0 ? "cancel" : "close — the question waits")
                : win.typing ? "⏎ send · Esc " + (win.dotAsk === "passphrase" ? "skip the push" : "use the default")
                : win.section === "tracked" ? "↑↓ pick · ⏎ its action · Tab tasks · Esc close — jobs keep running"
                : "type to search · ↑↓ pick · ⏎ run · Tab jobs · drag the title to move · Esc clear / close"
            color: Theme.fgVariant
            font.family: Typography.ui
            font.pixelSize: Typography.caption * win.s
        }
        // interferencia de terminal (2026-11-15): al abrir y al cambiar de vista; encima de todo (z), sin
        // recibir clics. Último hijo de la tarjeta: no corre los índices de los demás
        Interference { anchors.fill: parent; s: win.s; open: win.shown; key: win.section }
    }
}
