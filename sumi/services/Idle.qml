pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/xdg.js" as Xdg

/**
 * Plazos de inactividad de hypridle (Settings → System → Power; lectura 14A, edición 14E).
 *
 * 14E: editarlos es opt-in y lo hace `scripts/idle-config.py`: la primera vez mueve los dos
 * listeners de hypridle.conf (bloquear, apagar la pantalla) a `hypridle-sumi.conf`, incluido con
 * `source =`; después reescribe sólo ése. Cada cambio se prueba con una instancia aparte, reinicia
 * SÓLO hypridle y se comprueba en su journal. Sin suspensión automática en esta máquina.
 *
 * hypridle es el dueño (futureSettingssurface §7 «Power y About»): este servicio lee
 * `~/.config/hypr/hypridle.conf` y lo que incluya con `source =` (medido el 2026-09-29: hypridle
 * 0.1.8 registra los listeners de un archivo incluido), clasifica cada listener por lo que hace
 * y comprueba el ORDEN: bloquear antes de apagar la pantalla o suspender. Editar los plazos es de
 * la 14G, con un archivo gestionado.
 *
 * Lo que puede tenerlo en pausa sin cambiar ningún plazo (se dice, no se esconde):
 *   · Keep awake (Session: inhibidor logind idle:sleep);
 *   · Gaming y Cinema (Modes → Session: inhibidor logind idle, 11D-1).
 * Focus ya no toca idle (11D-1); `hypridle-focus.conf`, huérfano desde entonces, se retiró en la 14E.
 *
 * Coste: nada en reposo; el archivo se vigila y el servicio se consulta sólo reclamado.
 */
Singleton {
    id: root

    readonly property string dir: Quickshell.env("SUMI_IDLE_DIR")
        || (Xdg.base(Quickshell.env("XDG_CONFIG_HOME"), Quickshell.env("HOME") + "/.config") + "/hypr")
    // la que usa el hypridle que corre (idle-config.py la busca por su proceso); hasta leerla, la de siempre
    readonly property string mainPath: root.cfg.config && root.cfg.config.main ? root.expand(root.cfg.config.main)
                                                                               : root.dir + "/hypridle.conf"

    property var claims: ({})
    readonly property bool active: Object.keys(root.claims).length > 0
    function claim(who, on) {
        if (!!on === !!root.claims[who]) return;
        const c = Object.assign({}, root.claims);
        if (on) c[who] = true; else delete c[who];
        root.claims = c;
    }
    onActiveChanged: if (root.active) { svc.running = true; root.refreshCfg(); }

    /** { general: {k: v}, listeners: [{timeout, onTimeout, onResume, kind, file, line}], sources: [path] } */
    property var parsed: ({ general: {}, listeners: [], sources: [] })
    property var sourced: ({})          // ruta → texto de un archivo incluido
    property string error: ""
    property bool loaded: false
    property string service: ""         // active | inactive | failed | …

    FileView {
        id: mainFile
        path: root.active ? root.mainPath : ""
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: { root.error = ""; root.reparse(); svc.running = true; }
        onLoadFailed: { root.error = "hypridle.conf could not be read"; root.loaded = false; }
    }
    // Un solo archivo incluido (el gestionado de la 14G); más de uno se lee igual, de uno en uno.
    FileView {
        id: srcFile
        path: root.active && root.parsed.sources.length > 0 ? root.expand(root.parsed.sources[0]) : ""
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: { const s = {}; s[path] = text(); root.sourced = s; root.reparse(); }
        onLoadFailed: { root.sourced = ({}); root.reparse(); }
    }
    /**
     * F5f (H-23): cómo corre hypridle, según idle-config.py: unit (un servicio de usuario; el del autor, hypridle.service),
     * process (lanzado por Hyprland con exec-once u otro programa: sólo lectura) o none. Sin respuesta todavía, como antes.
     */
    readonly property var runner: root.cfg.runner || null
    readonly property bool editable: root.cfg.editable !== false
    /** En modo proceso, por qué no se pueden aplicar plazos (inglés, para Settings). */
    readonly property string notEditable: !root.runner || root.editable ? ""
        : root.runner.mode === "process" ? "hypridle runs outside a user service" + (root.runner.scope ? " (" + root.runner.scope + ")" : "")
            + ": it reads its config only at start · run it as a user service to edit the times here"
        : root.runner.mode === "none" ? "hypridle isn't running" : "Couldn't tell how hypridle runs"
    Process {
        id: svc
        // F5f: la unidad detectada (antes, hypridle.service fijo); en modo proceso no hay unidad que preguntar
        command: ["systemctl", "--user", "is-active", root.runner && root.runner.unit ? root.runner.unit : "hypridle.service"]
        stdout: StdioCollector {
            onStreamFinished: { if (!root.runner || root.runner.mode === "unit") root.service = this.text.trim(); }
        }
    }

    function expand(p) { return String(p).replace(/^~(?=\/)/, Quickshell.env("HOME")).replace(/\$HOME/g, Quickshell.env("HOME")); }

    /** Lo que hace un listener, por su orden. */
    function kindOf(cmd) {
        const c = String(cmd);
        if (/lock-session|lock\.sh|hyprlock/.test(c)) return "lock";
        if (/dpms/.test(c) && /disable|off/.test(c)) return "screenOff";
        if (/suspend|hibernate|hybrid-sleep/.test(c)) return "suspend";
        return "custom";
    }
    function parseText(text, file, out) {
        const lines = String(text).split("\n");
        let block = "", cur = null;
        for (let i = 0; i < lines.length; i++) {
            const raw = lines[i].replace(/(^|[^#])#(?!#).*$/, "$1").trim();
            if (raw.length === 0) continue;
            let m;
            if ((m = /^(\w+)\s*\{$/.exec(raw))) {
                block = m[1];
                if (block === "listener") cur = { timeout: -1, onTimeout: "", onResume: "", file: file, line: i + 1 };
                continue;
            }
            if (raw === "}") {
                if (block === "listener" && cur) out.listeners.push(cur);
                block = ""; cur = null;
                continue;
            }
            if (!(m = /^([\w.-]+)\s*=\s*(.*)$/.exec(raw))) continue;
            const k = m[1], v = m[2];
            if (block === "" && k === "source") out.sources.push(v);
            else if (block === "general") out.general[k] = v;
            else if (block === "listener" && cur) {
                if (k === "timeout") cur.timeout = parseInt(v);
                else if (k === "on-timeout") cur.onTimeout = v;
                else if (k === "on-resume") cur.onResume = v;
            }
        }
    }
    function reparse() {
        const out = { general: {}, listeners: [], sources: [] };
        root.parseText(mainFile.text(), "hypridle.conf", out);
        for (const p of Object.keys(root.sourced))
            root.parseText(root.sourced[p], p.substring(p.lastIndexOf("/") + 1), out);
        for (const l of out.listeners) l.kind = root.kindOf(l.onTimeout);
        root.parsed = out;
        root.loaded = true;
    }

    function first(kind) {
        const l = root.parsed.listeners.filter(x => x.kind === kind && x.timeout > 0);
        l.sort((a, b) => a.timeout - b.timeout);
        return l.length ? l[0] : null;
    }
    readonly property var lock: root.first("lock")
    readonly property var screenOff: root.first("screenOff")
    readonly property var suspend: root.first("suspend")

    /** Bloquear primero: antes de apagar la pantalla y antes de suspender (§7). "" si está bien. */
    readonly property string orderProblem: {
        if (!root.loaded) return "";
        if (!root.lock && (root.screenOff || root.suspend)) return "Nothing locks the session before the screen goes off";
        if (root.lock && root.screenOff && root.screenOff.timeout < root.lock.timeout)
            return "The screen turns off before the session locks";
        if (root.lock && root.suspend && root.suspend.timeout <= root.lock.timeout)
            return "The computer suspends before the session locks";
        return "";
    }
    /** Lo que tiene los plazos en pausa ahora, sin cambiarlos. */
    readonly property string pausedBy: Settings.keepAwake ? "Keep awake"
        : Session.modeInhibited && Modes.activeMode.length > 0 ? Modes.activeMode.charAt(0).toUpperCase() + Modes.activeMode.slice(1)
        : Session.modeInhibited ? "A system mode" : ""

    /** Ruta con ~ de un archivo de la configuración de hypridle. */
    function where(file) {
        const d = root.cfg.config && root.cfg.config.dir ? root.cfg.config.dir : root.dir;
        return String(file).indexOf("/") >= 0 ? String(file) : d + "/" + file;
    }
    function minutes(sec) {
        if (!(sec > 0)) return "Never";
        if (sec % 60 === 0) return (sec / 60) + " min";
        return sec >= 60 ? Math.floor(sec / 60) + " min " + (sec % 60) + " s" : sec + " s";
    }

    // ---- 14E: editar ------------------------------------------------------------------------------

    /** status de idle-config.py: {state: on|off|broken|foreign, lock, screenOff, config, managedFile, …} */
    property var cfg: ({})
    readonly property bool managed: root.cfg.state === "on"
    /** "enable" | "disable" | "set" mientras corre. */
    property string busy: ""
    property var result: null
    property string opId: ""
    /** Lo pedido y aún no aplicado (se aplica tras 0,9 s sin cambios: ←/→ no reinicia cada paso). */
    property var pending: null
    function refreshCfg() { if (!cfgProc.running) cfgProc.running = true; }
    Process {
        id: cfgProc
        command: ["python3", Quickshell.shellPath("scripts/idle-config.py"), "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.cfg = JSON.parse(this.text); } catch (e) { root.cfg = ({}); }
                // F5f: fuera de un servicio, systemctl no sabe de hypridle; lo que corre lo dice idle-config.py
                if (root.runner && root.runner.mode !== "unit") root.service = root.runner.mode === "process" ? "active" : "inactive";
            }
        }
    }
    /** El valor que se enseña: lo pedido si hay, si no el del archivo. */
    function shown(key) {
        if (root.pending && root.pending[key] !== undefined) return root.pending[key];
        const l = key === "lock" ? root.lock : root.screenOff;
        return l ? l.timeout : 0;
    }
    function setTime(key, sec, owner) {
        if (!root.managed || root.busy.length > 0) return false;
        const t = { lock: root.shown("lock"), screenOff: root.shown("screenOff") };
        t[key] = sec;
        root.pending = t;
        root.pendingOwner = owner || "";
        applyTimer.restart();
        return true;
    }
    property string pendingOwner: ""
    Timer {
        id: applyTimer
        interval: 900
        onTriggered: {
            const t = root.pending;
            if (!t) return;
            root.run("set", [String(t.lock), String(t.screenOff)], root.pendingOwner);
        }
    }
    function manage(on, owner) { return root.run(on ? "enable" : "disable", [], owner); }
    function undo(owner) {
        const r = root.result;
        if (!r || !r.ok || !r.undo || r.undone) return false;
        root.pending = { lock: r.undo.lock, screenOff: r.undo.screenOff };
        return root.run("set", [String(r.undo.lock), String(r.undo.screenOff)], owner, true);
    }
    function run(verb, args, owner, undoing) {
        if (root.busy.length > 0) return false;
        const b = Operations.begin("idle-config", "idle", "settings", verb, owner || "", {});
        if (!b.id) { root.result = { ok: false, error: "Another change is in progress", action: verb, at: Date.now() }; return false; }
        root.opId = b.id;
        root.busy = verb;
        runner.undoing = !!undoing;
        runner.command = ["python3", Quickshell.shellPath("scripts/idle-config.py"), verb].concat(args);
        runner.running = true;
        return true;
    }
    Process {
        id: runner
        property bool undoing: false
        stdout: StdioCollector {
            onStreamFinished: {
                let r;
                try { r = JSON.parse(this.text); } catch (e) { r = { ok: false, error: "The helper gave no answer" }; }
                if (!r.action) r.action = root.busy;
                if (runner.undoing) { r.undone = true; r.undo = null; }
                root.result = r;
                if (root.opId.length > 0) Operations.end(root.opId, r.ok ? "succeeded" : "failed", r.error || "");
                root.opId = "";
                root.busy = "";
                root.pending = null;
                root.refreshCfg();
                svc.running = true;
                mainFile.reload();
            }
        }
    }
    /** El último cambio en una línea (inglés). */
    function resultText(r) {
        if (!r) return "";
        if (!r.ok) return (r.error || "Could not apply") + (r.restored ? (r.restoredOk ? " · hypridle is back as it was" : " · check hypridle: it may not be running as before") : "");
        if (r.already) return r.action === "enable" ? "Already on" : "Already off";
        if (r.unchanged) return "Nothing to change";
        if (r.action === "enable") return "Editing on · hypridle restarted with the same times";
        if (r.action === "disable") return "Back in hypridle.conf · hypridle restarted";
        return (r.undone ? "Undone · " : "Saved · ") + "lock " + root.minutes(r.lock).toLowerCase()
            + ", screen off " + root.minutes(r.screenOff).toLowerCase() + " · hypridle restarted";
    }

    function summary() {
        return {
            active: root.active, loaded: root.loaded, error: root.error, service: root.service,
            runner: root.runner, editable: root.editable, notEditable: root.notEditable,
            general: root.parsed.general, sources: root.parsed.sources,
            listeners: root.parsed.listeners, lock: root.lock ? root.lock.timeout : 0,
            screenOff: root.screenOff ? root.screenOff.timeout : 0, suspend: root.suspend ? root.suspend.timeout : 0,
            orderProblem: root.orderProblem, pausedBy: root.pausedBy,
            cfg: root.cfg, managed: root.managed, busy: root.busy, pending: root.pending, result: root.result,
            resultText: root.resultText(root.result)
        };
    }
}
