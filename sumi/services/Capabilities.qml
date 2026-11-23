pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/xdg.js" as Xdg

/**
 * Qué puede hacer la shell en esta máquina (portabilidad F2a, 2026-10-05; contrato en
 * portabilidad/ROADMAP.md §F2). Un solo auxiliar, `scripts/capabilities.py`, de sólo lectura.
 *
 *   Cuándo  una vez al arrancar (diferido) y después sólo a petición: IPC `capsRefresh`, el Refresh
 *           de Environment (F2b) o `suspect()` cuando una acción no pudo lanzarse (F2c/F2d). Sin
 *           sondeo. Una petición con la detección en curso no lanza otra: la repite al terminar.
 *   Caché   `$XDG_CACHE_HOME/sumi-shell/capabilities.json` (la escribe el auxiliar): sólo para
 *           pintar algo antes de la primera detección. Lo de caché va marcado `stale` y NO desactiva.
 *   Regla   `can(id)` es false sólo con `unavailable` fresco (prueba positiva). `unknown` (consulta
 *           denegada, caducada, sin herramienta) y todo lo que aún no se sabe deja la acción como hoy.
 *   Forzar  `force(id, state)` por IPC, sin persistir (decisión del usuario, 2026-10-05): se pierde al
 *           recargar y se ve como `forced` con lo detectado al lado.
 *
 * Sin imports opcionales de Quickshell (H-02): sólo Io, que ya carga toda la shell.
 */
Singleton {
    id: root

    readonly property string format: "sumi-capabilities"
    readonly property int formatVersion: 1
    readonly property var states: ["available", "degraded", "unavailable", "unknown"]

    readonly property string cachePath: Xdg.base(Quickshell.env("XDG_CACHE_HOME"), Quickshell.env("HOME") + "/.cache")
        + "/sumi-shell/capabilities.json"
    readonly property string helperPath: Quickshell.shellPath("scripts/capabilities.py")

    /** PRUEBAS (IPC `capsTestPython`, sólo bajo /tmp/): otro intérprete para simular su falta o un cuelgue. */
    property string testPython: ""
    readonly property string python: root.testPython.length > 0 ? root.testPython : "python3"
    function setTestPython(p) {
        const s = String(p || "");
        if (s.length > 0 && (s.indexOf("/tmp/") !== 0 || s.indexOf("..") >= 0)) return false;
        root.testPython = s;
        return true;
    }
    readonly property int timeoutMs: 8000

    /** El último informe aceptado (fresco o de caché); null si aún no hay ninguno. */
    property var report: null
    /** none · cache · fresh */
    property string source: "none"
    /** idle · ok · no-python · timeout · error: cómo acabó la ÚLTIMA detección. */
    property string helper: "idle"
    property string helperError: ""
    property bool checking: false
    property real checkedAt: 0
    property int durationMs: -1
    property int runs: 0
    property string lastWhy: ""
    property var overrides: ({})
    /** Para que shell.qml lo cree al cargar (los singletons son perezosos). */
    readonly property bool ready: root.source === "fresh" || (root.helper !== "idle" && !root.checking)

    // ---- vista efectiva --------------------------------------------------------------------------

    readonly property var caps: root.compose(root.report, root.overrides, root.source, root.helper)

    /** F8d: only the unforced, fresh detector may enable systemd-only work. */
    function managerState(id) {
        if (root.source !== "fresh" || root.helper !== "ok" || !root.report || !root.report.caps)
            return "unknown";
        const c = root.report.caps[id];
        if (!c) return "unknown";
        if (c.state === "available") return "available";
        if (c.state === "unavailable" && c.detail && c.detail.managerAbsent === true) return "absent";
        return "unknown";
    }
    readonly property string userManagerState: root.managerState("session.systemd")
    readonly property string systemManagerState: root.managerState("session.systemdSystem")

    function compose(rep, ov, src, hlp) {
        const out = {};
        const base = rep && rep.caps ? rep.caps : {};
        const stale = src !== "fresh";
        for (const id in base)
            out[id] = Object.assign({}, base[id], { id: id, stale: stale, forced: false });
        // Sin intérprete no hay informe, pero eso mismo es una prueba: se dice.
        if (hlp === "no-python" && src !== "fresh")
            out["runtime.python"] = { id: "runtime.python", group: "session", state: "unavailable", provider: "python3",
                reason: "python3 was not found · capabilities can't be checked", stale: false, forced: false,
                facts: { installed: false, active: null, accessible: null, sessionCompatible: null } };
        for (const id in ov) {
            const b = out[id] || { id: id, group: "", provider: "", facts: {} };
            out[id] = Object.assign({}, b, { state: ov[id].state, reason: ov[id].reason, forced: true,
                                             detected: b.state || "", stale: false });
        }
        return out;
    }

    /** La capacidad efectiva; para un id sin dato, `checking` mientras se detecta y `unknown` después. */
    function get(id) {
        const c = root.caps[id];
        if (c) return c;
        const pendingNow = root.checking || root.helper === "idle";
        return { id: id, group: "", state: pendingNow ? "checking" : "unknown", provider: "", stale: false, forced: false,
                 reason: pendingNow ? "Checking…" : (root.helperError || "Not checked"),
                 facts: { installed: null, active: null, accessible: null, sessionCompatible: null } };
    }
    /** false SÓLO con `unavailable` fresco o forzado: en la duda, la acción se ofrece como hoy. */
    function can(id) {
        const c = root.get(id);
        return !(c.state === "unavailable" && !c.stale);
    }
    /** F2d: el motivo de la primera de `ids` que no se puede ("" si todas se pueden). */
    function whyFirst(ids) {
        for (const id of ids || [])
            if (!root.can(id)) return root.why(id) || (root.label(id) + " is unavailable");
        return "";
    }
    /** El motivo en inglés de lo que no está del todo disponible; "" si lo está o no se sabe aún. */
    function why(id) {
        const c = root.get(id);
        return c.state === "unavailable" || c.state === "degraded" ? (c.reason || "") : "";
    }

    // ---- textos (F2b: Settings → System → Environment; los comparten los consumidores) -----------

    /** Grupos del informe, en el orden de la página, con su título. */
    readonly property var groups: [
        { id: "session", title: "Session" }, { id: "theme", title: "Theme" },
        { id: "wallpaper", title: "Wallpaper" }, { id: "apps", title: "Apps" },
        { id: "audio", title: "Audio" }, { id: "devices", title: "Devices" },
        { id: "desktop", title: "Desktop" }, { id: "modes", title: "Desktop modes" },
        { id: "system", title: "Updates and maintenance" }
    ]
    readonly property var labels: ({
        "shell.install": "Shell installation", "session.hyprland": "Hyprland session", "hypr.dialect": "Hyprland config dialect", "lock.entry": "Lock requests", "lock.pam": "Lock authentication (PAM)", "session.systemd": "User services (systemd)",
        "session.systemdSystem": "System services (systemd)",
        "session.logind": "Login manager (logind)", "runtime.python": "Python", "ui.font": "Shell font",
        "theme.dynamic": "Colours from the wallpaper", "theme.static": "Static palette for apps",
        "theme.gtk": "GTK light and dark mode",
        "wallpaper.apply": "Apply wallpapers", "wallpaper.video": "Video wallpapers",
        "wallpaper.thumbnails": "Thumbnails", "wallpaper.download": "Wallhaven downloads",
        "apps.terminal": "Terminal",
        "apps.browser": "Browser",
        "apps.folders": "App folders",
        "system.updates": "Update check",
        "audio.equalizer": "Equalizer", "audio.profileTest": "Card profile test",
        "clipboard.history": "Clipboard history", "desktop.notifications": "Notifications",
        "agenda.calcurse": "Agenda",
        "network.manager": "Network", "network.editProfiles": "Edit saved networks",
        "network.speedtest": "Speed test", "bluetooth": "Bluetooth",
        "login.sddmTheme": "Login screen theme",
        "power.battery": "Battery service", "power.profiles": "Power profiles",
        "brightness.external": "External monitor brightness",
        "brightness.backlight": "Built-in screen brightness",
        "modes.glass": "Glass effect", "modes.cursors": "Cursor effects", "modes.videoPause": "Pause video wallpapers"
    })
    /** F3d-1: una tarea de tasks.json se llama como la tarea («Back up to /mnt/storage»). */
    function label(id) {
        if (root.labels[id]) return root.labels[id];
        const c = root.caps[id];
        return c && c.detail && c.detail.label ? c.detail.label : id;
    }
    function stateText(state) {
        return ({ available: "Available", degraded: "Limited", unavailable: "Unavailable", unknown: "Unknown",
                  checking: "Checking…" })[state] || state;
    }
    /** Las capacidades de un grupo, en el orden del informe. */
    function inGroup(group) {
        const out = [];
        for (const id in root.caps)
            if (root.caps[id].group === group) out.push(root.caps[id]);
        return out;
    }
    /** Cómo acabó la última detección, en palabras (para la fila de estado). */
    readonly property string helperText: root.checking ? "Checking…"
        : root.helper === "no-python" ? "python3 was not found"
        : root.helper === "timeout" ? "The check took too long"
        : root.helper === "error" ? "The check failed" + (root.helperError ? " · " + root.helperError : "")
        : root.helper === "idle" ? "Not checked yet" : ""

    // ---- detección -------------------------------------------------------------------------------

    property bool pending: false
    property bool started: false
    property bool timedOut: false
    property int exitCode: -999
    property bool outDone: false

    function refresh(why) {
        root.lastWhy = String(why || "");
        if (root.checking) { root.pending = true; return true; }
        root.started = false;
        root.timedOut = false;
        root.exitCode = -999;
        root.outDone = false;
        root.checking = true;
        root.runs++;
        // F6b: el árbol que corre, para que `shell.install` sepa cuál de las copias es ésta
        proc.command = [root.python, root.helperPath, "report", "--cache", root.cachePath, "--shell-dir", Quickshell.shellDir];
        proc.running = true;
        limit.restart();
        return true;
    }

    /** Una acción no pudo lanzarse (F2c/F2d): redetectar, como mucho una vez cada 10 s. */
    property real lastSuspectAt: 0
    function suspect(id, why) {
        if (Date.now() - root.lastSuspectAt < 10000) return false;
        root.lastSuspectAt = Date.now();
        return root.refresh("suspect " + id + (why ? ": " + why : ""));
    }

    function force(id, state) {
        const s = String(state || "");
        if (!/^[A-Za-z][A-Za-z0-9._-]*$/.test(String(id || ""))) return false;      // F3d-1: tasks.<id> con - y _
        const o = Object.assign({}, root.overrides);
        if (s.length === 0) delete o[id];
        else if (root.states.indexOf(s) < 0) return false;
        else o[id] = { state: s, reason: s === "available" ? "" : "Forced over IPC" };
        root.overrides = o;
        return true;
    }

    function accept(doc, src) {
        if (!doc || doc.format !== root.format || doc.version !== root.formatVersion || typeof doc.caps !== "object")
            return false;
        root.report = doc;
        root.source = src;
        root.checkedAt = doc.generatedAtMs || 0;
        root.durationMs = typeof doc.durationMs === "number" ? doc.durationMs : -1;
        return true;
    }

    function finish(state, error) {
        limit.stop();
        root.helper = state;
        root.helperError = error || "";
        root.checking = false;
        if (state !== "ok")
            console.warn("capabilities:", state, root.helperError);
        if (root.pending) {
            root.pending = false;
            Qt.callLater(() => root.refresh(root.lastWhy));
        }
    }

    function tryFinish() {
        if (!root.checking || root.exitCode === -999 || !root.outDone) return;
        if (root.timedOut) { root.finish("timeout", "The capability check took longer than " + root.timeoutMs / 1000 + " s"); return; }
        let doc = null;
        try { doc = JSON.parse(out.text); } catch (e) { doc = null; }
        if (root.exitCode === 0 && root.accept(doc, "fresh")) { root.finish("ok", ""); return; }
        const err = (errOut.text || "").trim().split("\n").pop();
        root.finish("error", err || ("capabilities.py exited " + root.exitCode));
    }

    Process {
        id: proc
        // Para decir si el dueño de las notificaciones es esta misma shell (PL-03). F3b: la terminal
        // elegida, la de memoria (settings.json se guarda 300 ms después).
        // F4b: el proveedor de fondos elegido, el de memoria; mientras Settings no se ha leído o migra, vacío
        // (capabilities.py lee entonces settings.json del disco)
        environment: ({ KT_CAPS_SHELL_PID: String(Quickshell.processId), KT_CAPS_TERMINAL: Settings.appTerminal,
                        KT_CAPS_BROWSER: Settings.appBrowser,
                        KT_CAPS_PROVIDER_WALLPAPER: Settings.loaded && Settings.status !== "upgrading" ? Settings.providerWallpaper : "",
                        KT_CAPS_PROVIDER_THUMBNAILS: Settings.loaded && Settings.status !== "upgrading" ? Settings.providerThumbnails : "",
                        KT_CAPS_PROVIDER_THEME: Settings.loaded && Settings.status !== "upgrading" ? Settings.providerTheme : "",
                        KT_CAPS_PROVIDER_UPDATES: Settings.loaded && Settings.status !== "upgrading" ? Settings.providerUpdates : "" })
        stdout: StdioCollector { id: out; onStreamFinished: { root.outDone = true; root.tryFinish(); } }
        stderr: StdioCollector { id: errOut }
        onStarted: root.started = true
        onExited: (code) => { root.exitCode = code; root.tryFinish(); }
        // Un intérprete que no existe no emite `exited`: sólo `running` → false sin `started`.
        onRunningChanged: {
            if (!proc.running && !root.started && root.checking)
                root.finish("no-python", "Couldn't start " + root.python);
        }
    }

    Timer {
        id: limit
        interval: root.timeoutMs
        onTriggered: { if (proc.running) { root.timedOut = true; proc.signal(9); } }
    }

    // Diferido: la primera detección no compite con la carga de la shell.
    Timer { interval: 2500; running: true; onTriggered: root.refresh("startup") }

    /**
     * F3b: cambiar `apps.terminal` cambia lo que hay que comprobar. Sólo cuando ya hubo una detección
     * (la carga de Settings también «cambia» el valor, del default al guardado, y para eso está la de
     * arranque). Una sola detección: refresh() junta las que lleguen mientras corre.
     */
    Connections {
        target: Settings
        function onAppTerminalChanged() { if (root.runs > 0) root.refresh("settings"); }
        function onAppBrowserChanged() { if (root.runs > 0) root.refresh("settings"); }      // F3c
    }

    /**
     * caps-sync (2026-11-20): las tareas de tasks.json son capacidades (`tasks.<id>`, F3d-1) que
     * capabilities.py juzga por su id, su etiqueta, argv[0] y `requires`, en el orden del archivo, y sólo si
     * el archivo se puede usar. Si cambia algo de eso, se redetecta: una tarea añadida no se queda «unknown»,
     * un `requires` corregido desbloquea la suya y una tarea quitada sale de Environment.
     *   · Una relectura igual (el vigilante de Tasks lee más de una vez cada escritura) no cambia la clave.
     *   · Tasks cambia `tasks` y `status` uno tras otro (al borrar el archivo, al volver): la clave se compara
     *     una vez por vuelta del bucle (`Qt.callLater` junta las llamadas) con la última detectada, así un
     *     estado intermedio no encola una segunda detección. Medido en tools/caps-sync/harness.py.
     *   · Sólo tras la primera detección (la de arranque cubre la carga inicial), como con la terminal.
     * Tasks no lee Capabilities: no hay ciclo.
     */
    readonly property string tasksKey: Tasks.status + "|"
        + JSON.stringify(Tasks.tasks.map(t => [t.id, t.label, t.argv[0], t.requires]))
    property string tasksSeen: ""
    onTasksKeyChanged: Qt.callLater(root.tasksSettled)
    function tasksSettled() {
        if (root.tasksKey === root.tasksSeen) return;
        root.tasksSeen = root.tasksKey;
        if (root.runs > 0) root.refresh("tasks");
    }

    /** La caché, una vez, sólo si todavía no hay nada mejor. */
    FileView {
        path: root.cachePath
        printErrors: false
        onLoaded: {
            if (root.source !== "none") return;
            try { root.accept(JSON.parse(text()), "cache"); } catch (e) { }
        }
    }

    function summary() {
        const counts = { available: 0, degraded: 0, unavailable: 0, unknown: 0 };
        for (const id in root.caps) counts[root.caps[id].state] = (counts[root.caps[id].state] || 0) + 1;
        return { source: root.source, helper: root.helper, helperError: root.helperError, checking: root.checking,
                 pending: root.pending, checkedAt: root.checkedAt, durationMs: root.durationMs, runs: root.runs,
                 lastWhy: root.lastWhy, cachePath: root.cachePath, testPython: root.testPython,
                 overrides: Object.keys(root.overrides), counts: counts, caps: root.caps };
    }
}
