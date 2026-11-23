pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import "../theme"
import "../lib/modes.js" as Logic
import "../lib/xdg.js" as Xdg

// Motor único de la sesión. Las vistas sólo piden y muestran su resultado.
Singleton {
    id: root
    readonly property var modes: ["normal", "focus", "gaming", "cinema"]
    property string testRoot: Quickshell.env("SUMI_MODES_TEST_ROOT") || ""
    readonly property bool testing: root.testRoot !== ""
    readonly property string sessionKey: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || Quickshell.env("XDG_SESSION_ID")
    readonly property string runtime: Quickshell.env("XDG_RUNTIME_DIR")
    readonly property string path: root.testing ? root.testRoot + "/mode-state.json" : root.runtime + "/sumi-modes.json"
    readonly property string cachePath: root.testing ? root.testRoot + "/mode-cache"
        : Xdg.base(Quickshell.env("XDG_CACHE_HOME"), Quickshell.env("HOME") + "/.cache") + "/sumi-desktop-mode"
    property var data: ({mode: "normal", state: "loading", effects: {}})
    property var engine: null
    property bool busy: false
    property bool loaded: false
    readonly property string mode: root.data.mode
    readonly property string state: root.data.state
    readonly property string activeMode: root.loaded && !root.busy && root.state === "applied" && root.data.checkedAt > 0 ? root.mode : ""
    readonly property string statusText: root.state === "partial" ? "Partially applied"
        : root.state === "unavailable" ? "Unavailable" : root.state === "applying" ? "Applying…"
        : root.state === "checking" || root.state === "loading" ? "Checking…"
        : root.state === "error" ? (root.data.reason || "Could not read the mode snapshot") : "Applied"
    property var saveCallback: null
    property bool initialized: false
    property int recordError: 0
    readonly property bool dependenciesReady: root.testing || (Settings.loaded && NotifHistory.loaded)
    onDependenciesReadyChanged: if (root.dependenciesReady && !root.loaded) Qt.callLater(root.restore)
    Connections {
        target: Settings
        function onMotionModeChanged() {
            // Elegir movimiento en Settings durante un modo retira su override temporal.
            const r = root.data.effects.motion;
            if (!root.testing && r && r.owned && r.last && Motion.override === r.last.override)
                Motion.override = "";
        }
    }

    /**
     * Portabilidad F2d (H-13): qué efectos de `mode` no se aplicarían en esta máquina, ANTES de
     * elegirlo: {efecto: motivo}. El motor ya marca `unavailable` al aplicar; esto lo adelanta.
     * Sólo lo detectado con prueba; con `testRoot`, nada (los binarios son los del banco).
     */
    readonly property var effectCaps: ({glass: "modes.glass", cursors: "modes.cursors",
        power: "power.profiles", video: "modes.videoPause"})
    function wontApply(mode) {
        const out = {};
        if (root.testing) return out;
        for (const k of Object.keys(Logic.targets(mode))) {
            const cap = root.effectCaps[k];
            if (cap && !Capabilities.can(cap)) out[k] = Capabilities.why(cap);
        }
        return out;
    }
    function summary() { return Object.assign({}, root.data, {activeMode: root.activeMode,
        busy: root.busy, testing: root.testing, testRoot: root.testRoot, loaded: root.loaded,
        statusText: root.statusText,
        // F2d: lo que no se aplicaría aquí, por modo (antes de elegir)
        wontApply: {focus: root.wontApply("focus"), gaming: root.wontApply("gaming"), cinema: root.wontApply("cinema")}}); }
    function set(m) { return root.loaded && root.engine ? root.engine.run(m, false, false) : false; }
    function refresh() { return root.loaded && root.engine ? root.engine.run(root.mode, true, false) : false; }
    function retry() { return root.set(root.mode); }
    function setTestRoot(p) {
        if (root.busy || (root.testing && root.mode !== "normal") || (!root.testing && root.mode !== "normal")) return false;
        if (p !== "" && (!/^\/tmp\/[A-Za-z0-9_./-]+$/.test(p) || p.indexOf("/../") >= 0 || p.endsWith("/.."))) return false;
        if (p === root.testRoot) return true;
        root.loaded = false; root.engine = null; root.testRoot = p;
        Qt.callLater(root.restore); return true;
    }
    function restore() {
        if (!root.initialized || !root.dependenciesReady || root.loaded) return;
        let value = null;
        root.recordError = 0;
        record.reload();
        const raw = record.text();
        if (root.recordError && root.recordError !== FileViewError.FileNotFound) {
            root.data = {mode: "normal", state: "error", effects: {}, reason: "Could not read the mode snapshot"};
            return;
        }
        if (raw.trim()) {
            try {
                value = JSON.parse(raw);
                if (value.version !== 1 || root.modes.indexOf(value.mode) < 0 || !value.effects || typeof value.effects !== "object"
                    || Array.isArray(value.effects) || Object.keys(value.effects).some(k =>
                        ["dnd", "motion", "blur", "animations", "glass", "cursors", "power", "video", "idle"].indexOf(k) < 0
                        || !value.effects[k] || typeof value.effects[k] !== "object"))
                    throw new Error("Invalid mode record");
                if (value.session !== root.sessionKey) value = null;
            } catch (e) {
                root.data = {mode: "normal", state: "error", effects: {}, reason: "Could not read the mode snapshot"};
                return;
            }
        }
        root.engine = new Logic.Engine({read: root.readEffect, write: root.writeEffect,
            desired: root.desired, save: root.save, publish: (d, b) => { root.data = d; root.busy = b; }}, value);
        root.loaded = true;
        root.engine.run(value ? value.mode : "normal", true, !!value);
    }
    function save(d, done) {
        d.session = root.sessionKey;
        root.saveCallback = done;
        record.setText(JSON.stringify(d));
    }
    FileView {
        id: record
        path: root.path
        preload: false
        blockAllReads: true
        blockWrites: true
        atomicWrites: true
        printErrors: false
        onLoadFailed: error => root.recordError = error
        onSaved: {
            const cb = root.saveCallback; root.saveCallback = null;
            // La caché es compatibilidad para apply-wallpaper, nunca la fuente del modo.
            cache.setText(root.engine.data.mode);
            if (cb) Qt.callLater(() => cb(true));
        }
        onSaveFailed: { const cb = root.saveCallback; root.saveCallback = null; if (cb) Qt.callLater(() => cb(false)); }
    }
    FileView { id: cache; path: root.cachePath; preload: false; blockWrites: true; printErrors: false }
    Component.onCompleted: { root.initialized = true; Qt.callLater(root.restore); }

    // Un proceso acotado por lectura/escritura; nunca se interpreta salida vacía como éxito.
    Component {
        id: commandFactory
        Process {
            id: proc
            property var callback
            property bool completed: false
            stdout: StdioCollector { id: output }
            stderr: StdioCollector { id: errors }
            function finish(code) {
                if (completed) return;
                completed = true;
                const cb = callback, out = output.text, err = errors.text;
                Qt.callLater(() => { cb(code, out, err); proc.destroy(); });
            }
            onExited: (code) => finish(code)
            onRunningChanged: if (!running && !completed) Qt.callLater(() => { if (!proc.running) proc.finish(127); })
        }
    }
    function command(argv, cb) {
        const p = commandFactory.createObject(root, {command: ["timeout", "5"].concat(argv), callback: cb});
        p.running = true;
    }
    function bin(name) { return root.testing ? root.testRoot + "/" + name : name; }
    function failure(done, text, unavailable) { done({ok: false, reason: text, unavailable: !!unavailable}); }
    function desired(key, value, got) {
        if (key === "dnd") return {on: value, source: "mode"};
        if (key === "motion") return {override: value, preference: got.preference};
        if (key === "video") {
            const next = {}; for (const name of Object.keys(got)) next[name] = value;
            return next;
        }
        return value;
    }
    readonly property var options: ({blur: "decoration:blur:enabled", animations: "animations:enabled",
        cursors: "plugin:dynamic_cursors:enabled"})
    function option(name, done) {
        root.command([root.bin("hyprctl"), "-j", "getoption", name], (code, out) => {
            try {
                const o = JSON.parse(out), v = o.bool !== undefined ? o.bool : o.int;
                if (code !== 0 || v === undefined) throw new Error();
                done({ok: true, value: v});
            } catch (e) { root.failure(done, "Hyprland option unavailable: " + name, true); }
        });
    }
    function readEffect(key, done) {
        if (root.testing && ["dnd", "motion", "idle"].indexOf(key) >= 0) {
            root.command([root.bin("qs"), "read", key], (code, out) => {
                try { if (code !== 0) throw new Error(); done({ok: true, value: JSON.parse(out)}); }
                catch (e) { root.failure(done, "Session effect unavailable", true); }
            }); return;
        }
        if (key === "dnd") {
            if (!NotifHistory.loaded || !Notifs.enabled) { root.failure(done, "Notification server unavailable", true); return; }
            done({ok: true, value: {on: NotifHistory.dnd, source: NotifHistory.dndSource}}); return;
        }
        if (key === "motion") { done({ok: true, value: {override: Motion.override, preference: Settings.motionMode}}); return; }
        if (key === "idle") { done({ok: true, value: Session.modeInhibited}); return; }
        if (root.options[key]) { root.option(root.options[key], r => { if (r.ok) r.value = !!r.value; done(r); }); return; }
        if (key === "glass") {
            root.option("plugin:hyprglass:enabled", a => {
                if (!a.ok) { done(a); return; }
                root.option("plugin:hyprglass:manage_window_blur", b => {
                    if (!b.ok) { done(b); return; }
                    done({ok: true, value: {enabled: Number(a.value), blur: Number(b.value)}});
                });
            }); return;
        }
        if (key === "power") {
            root.command([root.bin("powerprofilesctl"), "get"], (code, out) => {
                const value = out.trim();
                if (code !== 0 || ["balanced", "performance", "power-saver"].indexOf(value) < 0)
                    root.failure(done, "Power profiles unavailable", true);
                else root.command([root.bin("powerprofilesctl"), "list"], (listCode, listing) => {
                    const allowed = ["balanced", "performance", "power-saver"].filter(n => new RegExp("(?:^|\\n)\\s*\\*?\\s*" + n + ":").test(listing));
                    if (listCode !== 0 || !allowed.length) root.failure(done, "Could not read available power profiles", false);
                    else done({ok: true, value: value, allowed: allowed});
                });
            }); return;
        }
        if (key === "video") {
            const argv = root.videoArgv("pauseStatus");
            if (!argv) { root.failure(done, Providers.whyNot("wallpaper", "pauseStatus") || "No video wallpaper pause", true); return; }
            root.command(argv, (code, out) => {
                try {
                    const obj = JSON.parse(out);
                    if (code !== 0 || obj === null || Array.isArray(obj)) throw new Error();
                    if (!Object.keys(obj).length) { root.failure(done, "No video wallpaper with IPC", true); return; }
                    done({ok: true, value: obj});
                } catch (e) { root.failure(done, "Could not read video wallpaper pause state", code === 127); }
            }); return;
        }
        root.failure(done, "Unknown effect", true);
    }
    readonly property string videoScript: root.testing ? root.testRoot + "/wallpaper-video-pause.sh" : ""
    /**
     * F4b: la pausa del vídeo de fondo es del proveedor de fondos (el wallpaper-video-pause.sh del autor
     * como `script`, mismos argv; o el propio). En pruebas, el script falso de siempre. null = no la hace.
     */
    function videoArgv(verb, json) {
        if (root.testing) return ["bash", root.videoScript].concat(verb === "pauseStatus" ? ["status", "--json"] : ["restore", json]);
        return Providers.command("wallpaper", verb, { json: json });
    }
    function writeEffect(key, value, done) {
        if (root.testing && ["dnd", "motion", "idle"].indexOf(key) >= 0) {
            root.command([root.bin("qs"), "write", key, JSON.stringify(value)], code => done({ok: code === 0})); return;
        }
        if (key === "dnd") { NotifHistory.restoreDnd(value.on, value.source); done({ok: true}); return; }
        if (key === "motion") { Motion.override = value.override; done({ok: true}); return; }
        if (key === "idle") { Session.claimModeIdle(value, done); return; }
        if (key === "power") {
            if (root.testing) root.command([root.bin("powerprofilesctl"), "set", value], code => done({ok: code === 0}));
            else {
                const rev = PowerProfile.setProfile(value);
                if (rev <= 0) done({ok: rev === 0});
                else { root.powerCallback = done; root.powerRev = rev; powerDeadline.restart(); }
            }
            return;
        }
        if (key === "video") {
            const argv = root.videoArgv("pauseRestore", JSON.stringify(value));
            if (!argv) { done({ok: false}); return; }
            root.command(argv, code => done({ok: code === 0}));
            return;
        }
        // F5a: la forma la da el dialecto (HyprCtl): `eval "hl.config({…})"` con Lua, `keyword` con hyprland.conf.
        // Con Lua, los argv son los de antes (tools/f5/argv-before.json M1–M4). Lo que cuenta es la lectura de
        // después (lib/modes.js): con hyprlang, `keyword` responde «ok» aunque la opción no exista.
        if (["blur", "animations", "cursors", "glass"].indexOf(key) < 0) { root.failure(done, "Unknown effect", false); return; }
        const args = HyprCtl.hotConfigArgs(key, value);
        if (!args) { root.failure(done, "Invalid value for " + key, false); return; }
        root.command([root.bin("hyprctl")].concat(args), (code, out, err) =>
            done({ok: code === 0, reason: code ? (err.trim() || out.trim() || "Hyprland refused the change") : ""}));
    }
    Connections {
        target: Session
        function onModeInhibitedChanged() {
            if (!root.testing && root.loaded && !root.busy && root.data.effects.idle)
                Qt.callLater(root.refresh);
        }
    }
    property var powerCallback: null
    property int powerRev: 0
    Connections {
        target: PowerProfile.ops
        function onSettled(key, rev, state) {
            if (!root.powerCallback || rev !== root.powerRev) return;
            const cb = root.powerCallback; root.powerCallback = null; powerDeadline.stop();
            cb({ok: state === "ok", reason: PowerProfile.opReason});
        }
    }
    Timer {
        id: powerDeadline
        interval: 5000
        onTriggered: { const cb = root.powerCallback; root.powerCallback = null;
            if (cb) cb({ok: false, reason: "Power profile verification timed out"}); }
    }
}
