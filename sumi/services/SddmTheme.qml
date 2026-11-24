pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Pantalla de inicio de sesión (Sumi SDDM, 2026-11-22): Settings → Desktop tools → Login screen y, desde el
 * 2026-11-23, su ventana propia (core/LoginLayer, services/LoginUi). Las dos son clientes de este servicio.
 *
 * La configuración es de Sumi SDDM, no de la shell (un dueño por dato): vive en ~/.config/sumi-sddm y NO entra en
 * settings.json, presets ni Export/Import. Aquí sólo se pide y se enseña; todo lo hace la orden `sumi-sddm` del
 * PATH (contrato JSON api 1, docs/CLI-JSON.md de Sumi SDDM), con verbos fijos y `argv` (nunca un shell). La CLI
 * vuelve a validar todo con su lectura estricta.
 *
 * Sistema (Fase 5 de Sumi SDDM): `system status` dice si el tema está instalado y activo y si lo aplicado coincide
 * con lo guardado. Apply / Use / Restore lanzan `sumi-sddm system apply|activate|deactivate`, que pasan por pkexec:
 * la contraseña la pide el agente de polkit (el de la shell). Corren en su propio proceso para que esperar la
 * contraseña no bloquee la cola. Use y Restore piden dos pulsaciones.
 * Avatar: `sumi-sddm avatar info|set|clear` (AccountsService; sin contraseña).
 *
 *   claim()      con la página a la vista se carga (versión → esquema → valores) y vive la vista previa; cerrada,
 *                no corre nada
 *   set(k, v)    cambio al momento en la vista; se escribe agrupado (300 ms quieto) con `--expect <stamp>`, así
 *                que un cambio hecho desde la terminal entre medias no se pisa: se recarga y se avisa
 *   preview      600 ms después del último cambio, una a la vez
 *
 * Se lanza como `/usr/bin/env sumi-sddm …`: si la orden no existe, env sale con 127 y `exited` llega igual (un
 * binario inexistente en `Process` no lo emite). Un proceso a la vez, en cola.
 */
Singleton {
    id: root

    readonly property var launcher: ["/usr/bin/env", "sumi-sddm"]
    readonly property int api: 1

    // ---- estado ---------------------------------------------------------------------------------------------------
    /** "" sin comprobar · checking · ready · missing (no hay `sumi-sddm`) · incompatible (otro api) · broken */
    property string status: ""
    property string version: ""
    property string statusDetail: ""
    property var groups: []                  // [{id, label}]
    property var keys: ({})                  // clave → entrada del esquema
    property var order: []                   // claves en el orden del esquema
    property var values: ({})                // clave → {value, default, set}
    property string stamp: ""
    property var warnings: []                // [{key, message}]
    property var fonts: []                   // [{family, system}]
    property string error: ""                // el último error para la persona («» si nada)
    property string notice: ""               // aviso informativo (p. ej. «cambiado en otro sitio»)
    /** Errores por clave de la última escritura rechazada (`fields[]` de la CLI ≥ 0.6.1): clave → mensaje en inglés,
     *  sin el nombre de la clave. Se borra el de una clave al volver a cambiarla o al guardarse. */
    property var fieldErrors: ({})
    readonly property bool ready: root.status === "ready"
    readonly property bool busy: root._running !== null || root._queue.length > 0 || writeTimer.running
    /** Hay escrituras sin terminar (lo pendiente, el agrupado o un `config set` en marcha); leer no cuenta. */
    readonly property bool saving: Object.keys(root._pending).length > 0 || writeTimer.running
                                   || (root._running !== null && root._running.kind === "set")
    readonly property int customCount: root.order.filter(k => root.values[k] && root.values[k].set).length
    /** Claves personalizadas de un grupo del esquema (los puntos del rail de la ventana). */
    function customIn(group) {
        return root.order.filter(k => root.keys[k].group === group && root.values[k] && root.values[k].set).length;
    }
    /** El texto de un error de la CLI para la interfaz: `message` (inglés, desde 0.6.1) y, si falta, `error`. */
    function _msg(doc, fallback) {
        if (doc && doc.message) return String(doc.message);
        if (doc && doc.error) return String(doc.error);
        return fallback;
    }

    // ---- sistema y avatar --------------------------------------------------------------------------------------
    /** `system status` (null mientras no se sabe): installed, active, activeTheme, inSync, version; missing si no
     *  está el paquete. */
    property var system: null
    /** "" · apply · activate · deactivate: una operación con pkexec en marcha (esperando la contraseña o haciéndola). */
    property string systemBusy: ""
    /** `avatar info` (null si no se sabe): iconFile, exists, sddmUses… */
    property var avatar: null
    /** `system log` (null mientras no se pide): greeters [{time, sumi, ok, problems}], sumiOk, logins…; o
     *  {missing: true} si en este arranque no se ha mostrado ninguna pantalla de inicio. Sólo lo pide la página
     *  System de la ventana (refreshLog). La CLI sale con 1 cuando hubo problemas, pero el JSON es el mismo. */
    property var greeterLog: null

    // ---- quién mira ---------------------------------------------------------------------------------------------
    property var claims: ({})
    readonly property bool watching: Object.keys(root.claims).length > 0
    /** La vista previa (un render de ~1,4 s) sólo la enseña la ventana Login screen: sin ella no se genera. */
    readonly property bool previewing: !!root.claims["loginUi"]
    onPreviewingChanged: root.schedulePreview()
    function claim(who, on) {
        if (!!on === !!root.claims[who]) return;
        const c = Object.assign({}, root.claims);
        if (on) c[who] = true; else delete c[who];
        root.claims = c;
    }
    onWatchingChanged: {
        if (root.watching) root.load();
        else { root.tryArmed = false; root.resetArmed = false; root.activateArmed = false; root.deactivateArmed = false; }
    }

    // ---- cola de procesos ----------------------------------------------------------------------------------------
    property var _queue: []
    property var _running: null
    function _enqueue(job) {
        // una carga, una vista previa o un estado ya en cola no se repite
        if (["show", "preview", "system", "avatar", "log"].indexOf(job.kind) >= 0 && root._queue.some(j => j.kind === job.kind))
            return;
        root._queue = root._queue.concat([job]);
        root._pump();
    }
    function _pump() {
        if (root._running !== null || root._queue.length === 0) return;
        const job = root._queue[0];
        root._queue = root._queue.slice(1);
        root._running = job;
        proc.out = "";
        // La huella se toma al LANZAR, no al encolar: una escritura propia anterior ya la habrá actualizado.
        const expect = job.expect === true && root.stamp.length === 32 ? ["--expect", root.stamp] : [];
        proc.command = root.launcher.concat(job.args).concat(expect).concat(["--json"]);
        proc.running = true;
    }
    Process {
        id: proc
        property string out: ""
        property bool gotOut: false
        property bool exited: false
        property int code: 0
        onStarted: { proc.gotOut = false; proc.exited = false; }
        stdout: StdioCollector { onStreamFinished: { proc.out = this.text; proc.gotOut = true; root._done(); } }
        onExited: (code) => { proc.code = code; proc.exited = true; root._done(); }
    }
    function _done() {
        if (!proc.gotOut || !proc.exited) return;
        proc.gotOut = false; proc.exited = false;
        const job = root._running;
        root._running = null;
        let doc = null;
        try { doc = JSON.parse(String(proc.out).trim()); } catch (e) { doc = null; }
        if (job) {
            try { job.done(doc, proc.code); } catch (e) { root.error = "Unexpected reply from sumi-sddm"; }
        }
        root._pump();
    }

    // ---- carga ---------------------------------------------------------------------------------------------------
    function load() {
        root.status = "checking";
        root._enqueue({ kind: "version", args: ["version"], done: (doc, code) => {
            if (code === 127 && !doc) { root.status = "missing"; root.statusDetail = ""; return; }
            if (!doc || doc.ok !== true) {
                root.status = "broken";
                root.statusDetail = root._msg(doc, "sumi-sddm did not answer as expected");
                return;
            }
            if (doc.api !== root.api) {
                root.status = "incompatible";
                root.statusDetail = "sumi-sddm speaks version " + doc.api + " of its interface; this shell expects " + root.api;
                return;
            }
            root.version = String(doc.version || "");
            root._enqueue({ kind: "schema", args: ["config", "schema"], done: root._schemaDone });
        } });
    }
    function _schemaDone(doc) {
        if (!doc || doc.ok !== true || !Array.isArray(doc.keys)) {
            root.status = "broken";
            root.statusDetail = root._msg(doc, "Could not read the settings list");
            return;
        }
        const k = {}, ord = [];
        for (const e of doc.keys) { k[e.key] = e; ord.push(e.key); }
        root.keys = k;
        root.order = ord;
        root.groups = (doc.groups || []).map(g => ({ id: String(g.id), label: String(g.label || g.id) }));
        root.reload();
        if (root.fonts.length === 0)
            root._enqueue({ kind: "fonts", args: ["config", "fonts"], done: (d) => {
                if (d && d.ok === true) root.fonts = d.families || [];
            } });
    }
    /** Relee los valores. Lo que aún espera a escribirse se conserva encima (la vista no salta atrás). */
    function reload() {
        root._enqueue({ kind: "show", args: ["config", "show"], done: (doc) => {
            if (!doc || doc.ok !== true) {
                root.status = "broken";
                root.statusDetail = root._msg(doc, "Could not read the settings");
                return;
            }
            const v = doc.values || {};
            for (const key in root._pending)
                if (v[key]) v[key] = Object.assign({}, v[key], { value: root._pending[key].value, set: true });
            root.values = v;
            root.stamp = String(doc.stamp || "");
            root.warnings = doc.warnings || [];
            root.status = "ready";
            root.schedulePreview();
            root.refreshSystem();
            if (root.avatar === null) root.refreshAvatar();
        } });
    }

    function refreshSystem() {
        root._enqueue({ kind: "system", args: ["system", "status"], done: (doc) => {
            if (doc && doc.ok === true) root.system = doc;
            else root.system = { installed: false, missing: !!(doc && doc.code === "missing"),
                                 error: root._msg(doc, "") };
        } });
    }
    function refreshLog() {
        root._enqueue({ kind: "log", args: ["system", "log"], done: (doc) => {
            if (doc && doc.ok === true) root.greeterLog = doc;
            else root.greeterLog = { missing: !!(doc && doc.code === "missing"), error: root._msg(doc, "") };
        } });
    }
    function refreshAvatar() {
        root._enqueue({ kind: "avatar", args: ["avatar", "info"], done: (doc) => {
            root.avatar = doc && doc.ok === true ? doc : { exists: false, error: root._msg(doc, "") };
        } });
    }
    function setAvatar(path) {
        const p = String(path || "").trim().replace(/^~(?=\/)/, Quickshell.env("HOME") || "~");
        if (!root.ready || p.length === 0) return;
        root.error = ""; root.notice = "";
        root._enqueue({ kind: "avatarSet", args: ["avatar", "set", p], done: (doc) => {
            if (doc && doc.ok === true) { root.avatar = doc; root.notice = "Avatar saved"; root.schedulePreview(); }
            else { root.error = root._msg(doc, "The avatar could not be saved"); root.refreshAvatar(); }
        } });
    }
    function clearAvatar() {
        if (!root.ready) return;
        root._enqueue({ kind: "avatarSet", args: ["avatar", "clear"], done: (doc) => {
            if (!(doc && doc.ok === true)) root.error = root._msg(doc, "The avatar could not be removed");
            root.refreshAvatar();
            root.schedulePreview();
        } });
    }

    // ---- operaciones con pkexec (su propio proceso) ---------------------------------------------------------------
    property bool activateArmed: false
    property bool deactivateArmed: false
    function systemApply() {
        if (!root.ready || root.systemBusy !== "" || !root.system || root.system.installed !== true) return;
        // lo pendiente de escribir va antes: se aplica lo que se ve
        if (Object.keys(root._pending).length > 0 || writeTimer.running || root._running !== null) {
            applyRetry.restart();
            return;
        }
        root._system("apply");
    }
    Timer { id: applyRetry; interval: 250; onTriggered: root.systemApply() }
    function activateSystem() {
        if (!root.ready || root.systemBusy !== "" || !root.system || root.system.installed !== true || root.system.active) return;
        if (!root.activateArmed) { root.activateArmed = true; disarm.restart(); return; }
        root.activateArmed = false;
        root._system("activate");
    }
    function deactivateSystem() {
        if (!root.ready || root.systemBusy !== "" || !root.system || root.system.active !== true) return;
        if (!root.deactivateArmed) { root.deactivateArmed = true; disarm.restart(); return; }
        root.deactivateArmed = false;
        root._system("deactivate");
    }
    function _system(verb) {
        root.error = ""; root.notice = "";
        root.systemBusy = verb;
        sysProc.command = root.launcher.concat(["system", verb, "--json"]);
        sysProc.running = true;
    }
    Process {
        id: sysProc
        property string out: ""
        property bool gotOut: false
        property bool exited: false
        onStarted: { sysProc.gotOut = false; sysProc.exited = false; }
        stdout: StdioCollector { onStreamFinished: { sysProc.out = this.text; sysProc.gotOut = true; root._systemDone(); } }
        onExited: { sysProc.exited = true; root._systemDone(); }
    }
    function _systemDone() {
        if (!sysProc.gotOut || !sysProc.exited) return;
        sysProc.gotOut = false; sysProc.exited = false;
        const verb = root.systemBusy;
        root.systemBusy = "";
        let doc = null;
        try { doc = JSON.parse(String(sysProc.out).trim()); } catch (e) { doc = null; }
        if (doc && doc.ok === true) {
            root.notice = verb === "apply" ? (doc.changed ? "Applied to the login screen" : "The login screen already had these settings")
                : verb === "activate" ? "Sumi will be your login screen the next time it appears"
                : "Back to " + String(doc.activeTheme || "the previous theme") + " the next time the login screen appears";
        } else if (doc && doc.code === "denied") {
            root.notice = "Authentication cancelled · nothing changed";
        } else if (doc && doc.code === "probe") {
            const first = (doc.problems || [])[0];
            root.error = "The theme failed its test with these settings · nothing changed" + (first ? " · " + String(first) : "");
        } else {
            root.error = root._msg(doc, "sumi-sddm could not change the login screen");
        }
        root.refreshSystem();
    }

    // ---- escribir --------------------------------------------------------------------------------------------------
    property var _pending: ({})              // clave → {value, raw}; raw "" = quitar
    function valueOf(key) {
        if (key === "avatar") return root.avatar && root.avatar.exists ? String(root.avatar.iconFile) : "";
        const v = root.values[key];
        return v ? v.value : undefined;
    }
    function isSet(key) {
        if (key === "avatar") return !!(root.avatar && root.avatar.exists);
        const v = root.values[key];
        return !!(v && v.set);
    }

    /** Cambio de una clave. `value` en el tipo del esquema; null = volver al valor por defecto. */
    function set(key, value) {
        const e = root.keys[key];
        if (!e || !root.ready) return;
        const unset = value === null || value === undefined;
        const shown = unset ? e["default"] : value;
        const raw = unset ? "" : root._raw(e, value);
        const p = Object.assign({}, root._pending);
        p[key] = { value: shown, raw: raw };
        root._pending = p;
        const v = Object.assign({}, root.values);
        v[key] = Object.assign({}, v[key] || {}, { value: shown, set: !unset });
        root.values = v;
        if (root.fieldErrors[key] !== undefined) {
            const fe = Object.assign({}, root.fieldErrors);
            delete fe[key];
            root.fieldErrors = fe;
        }
        root.error = "";
        root.notice = "";
        writeTimer.restart();
    }
    function unset(key) { if (key === "avatar") root.clearAvatar(); else root.set(key, null); }
    function _raw(e, value) {
        if (e.type === "bool") return value ? "true" : "false";
        if (e.type === "integer") return String(Math.round(value));
        if (e.type === "number") return String(Math.round(value * 1000) / 1000);
        return String(value);
    }
    Timer { id: writeTimer; interval: 300; onTriggered: root._flush() }
    function _flush() {
        const keys = Object.keys(root._pending);
        if (keys.length === 0) return;
        if (root._running !== null && root._running.kind === "set") { writeTimer.restart(); return; }
        const sent = root._pending;
        root._pending = ({});
        root._write(["config", "set"].concat(keys.map(k => k + "=" + sent[k].raw)), sent);
    }
    function _write(args, sent) {
        root._enqueue({ kind: "set", args: args, expect: true, done: (doc) => root._written(doc, sent) });
    }
    /** Escrituras aceptadas desde que arrancó (diagnóstico y bancos: los cambios seguidos van agrupados). */
    property int writeCount: 0
    function _written(doc, sent) {
        if (doc && doc.ok === true) {
            root.writeCount++;
            root.stamp = String(doc.stamp || root.stamp);
            const fe = Object.assign({}, root.fieldErrors);
            for (const k in sent) delete fe[k];
            root.fieldErrors = fe;
            root.reload();          // y, tras ella, `system status`: lo aplicado deja de coincidir
            return;
        }
        // Lo enviado no se guardó: lo pendiente posterior tampoco vale si la base cambió.
        if (doc && doc.code === "conflict") {
            root._pending = ({});
            writeTimer.stop();
            root.notice = "Changed outside Sumi Shell · reloaded";
        } else {
            root.error = root._msg(doc, "sumi-sddm could not save the change");
            // `config set` es todo o nada: `fields` lista cada clave rechazada (y su mensaje, sin el nombre)
            if (doc && Array.isArray(doc.fields) && doc.fields.length > 0) {
                const fe = Object.assign({}, root.fieldErrors);
                for (const f of doc.fields) if (f && f.key) fe[String(f.key)] = String(f.message || "");
                root.fieldErrors = fe;
                const n = doc.fields.length;
                root.error = n === 1 ? root.error : n + " settings were not saved · see the fields";
            }
        }
        root.reload();
    }

    function setWallpaper(path) {
        const p = String(path || "").trim();
        if (!root.ready || p.length === 0) return;
        root.error = ""; root.notice = "";
        root._write(["wallpaper", "set", p.replace(/^~(?=\/)/, Quickshell.env("HOME") || "~")], {});
    }
    function clearWallpaper() {
        if (!root.ready) return;
        root._write(["wallpaper", "clear"], {});
    }

    /** Reset y Restore piden dos pulsaciones (como Delete en Presets). */
    property bool resetArmed: false
    function resetAll() {
        if (!root.ready || root.customCount === 0) return;
        if (!root.resetArmed) { root.resetArmed = true; disarm.restart(); return; }
        root.resetArmed = false;
        root._pending = ({}); writeTimer.stop();
        root._write(["config", "reset"], {});
    }
    function restorePrevious() {
        if (!root.ready) return;
        root._write(["config", "restore"], {});
    }

    /** La ventana de prueba del greeter real toma el teclado: dos pulsaciones. */
    property bool tryArmed: false
    function openTestWindow() {
        if (!root.ready) return;
        if (!root.tryArmed) { root.tryArmed = true; disarm.restart(); return; }
        root.tryArmed = false;
        Quickshell.execDetached(root.launcher.concat(["try", "--yes"]));
    }
    Timer {
        id: disarm; interval: 4000
        onTriggered: { root.resetArmed = false; root.tryArmed = false; root.activateArmed = false; root.deactivateArmed = false; }
    }

    // ---- vista previa ----------------------------------------------------------------------------------------------
    readonly property var scenarios: [
        { label: "Compact", value: "compact" }, { label: "Password", value: "expanded" },
        { label: "Sessions", value: "sessions" }, { label: "Error", value: "failed" }
    ]
    /** Las 16 escenas de la CLI (`SCENARIOS` de tools/sumi-sddm), agrupadas para el menú «More» de la ventana. */
    readonly property var allScenarios: [
        { label: "Compact", value: "compact", section: "Login Edge" },
        { label: "Password", value: "expanded", section: "Login Edge" },
        { label: "Sessions", value: "sessions", section: "Login Edge" },
        { label: "Error", value: "failed", section: "Login Edge" },
        { label: "Typing", value: "typing", section: "Password" },
        { label: "Caps Lock on", value: "caps", section: "Password" },
        { label: "Signing in", value: "authenticating", section: "Password" },
        { label: "Message", value: "info", section: "Password" },
        { label: "Single user", value: "single", section: "Users" },
        { label: "Many users", value: "many", section: "Users" },
        { label: "Type a user name", value: "manual", section: "Users" },
        { label: "Other user", value: "other", section: "Users" },
        { label: "No password", value: "nopass", section: "Users" },
        { label: "No sessions", value: "nosessions", section: "Sessions and power" },
        { label: "Power confirm", value: "confirm", section: "Sessions and power" },
        { label: "Second monitor", value: "secondary", section: "Screens" }
    ]
    function scenarioLabel(v) {
        const s = root.allScenarios.find(x => x.value === v);
        return s ? s.label : String(v);
    }
    /** La escena que mejor enseña un grupo (la ventana la sigue mientras no se elija una a mano). */
    function sceneFor(group) {
        switch (group) {
        case "notch": return "expanded";
        case "power": return "confirm";
        case "users": return "many";
        case "behaviour": return "failed";
        default: return "compact";
        }
    }
    property string scenario: "expanded"
    onScenarioChanged: root.schedulePreview()
    /** Tamaño de la vista previa, `AnchoxAlto` en píxeles físicos (la ventana pide el de su monitor). */
    property string previewSize: "1280x720"
    onPreviewSizeChanged: root.schedulePreview()
    property string previewUrl: ""
    property string previewStamp: ""
    property bool previewFailed: false
    property int _previewSerial: 0
    readonly property bool previewStale: root.previewStamp !== root.stamp || root._previewScenario !== root.scenario
                                         || root._previewSize !== root.previewSize
    property string _previewScenario: ""
    property string _previewSize: ""
    function schedulePreview() { if (root.previewing && root.ready) previewTimer.restart(); }
    Timer { id: previewTimer; interval: 600; onTriggered: root._preview() }
    function _preview() {
        if (!root.previewing || !root.ready) return;
        if (Object.keys(root._pending).length > 0 || writeTimer.running) { previewTimer.restart(); return; }
        const sc = root.scenario;
        const size = /^[1-9][0-9]{2,4}x[1-9][0-9]{2,4}$/.test(root.previewSize) ? root.previewSize : "1280x720";
        root._enqueue({ kind: "preview", args: ["preview", "--scenario", sc, "--size", size], done: (doc) => {
            if (doc && doc.ok === true && doc.png) {
                root._previewSerial++;
                // otra URL en cada vista previa: la Image no reutiliza la anterior de su caché
                root.previewUrl = "file://" + String(doc.png) + "?v=" + root._previewSerial;
                root.previewStamp = String(doc.stamp || "");
                root._previewScenario = sc;
                root._previewSize = size;
                root.previewFailed = false;
            } else {
                root.previewFailed = true;
                root.error = root._msg(doc, "The preview could not be made");
            }
            // lo pedido cambió mientras se hacía (otra escena u otro tamaño): otra vez
            if (root.scenario !== sc || root.previewSize !== size) root.schedulePreview();
        } });
    }

    // ---- textos de las filas de estado y acciones (Settings y la ventana, 2026-11-23) -----------------------------
    /** Valor a la derecha de las filas de estado: `sddmStatus` (la orden) y `sddmApplied` (el sistema). */
    function infoText(id) {
        if (id === "sddmStatus") {
            switch (root.status) {
            case "ready": return "Version " + root.version;
            case "missing": return "Not installed";
            case "incompatible": return "Incompatible version";
            case "broken": return "Not working";
            default: return "Checking…";
            }
        }
        if (id === "sddmApplied") {
            const sy = root.system;
            if (!root.ready) return "";
            if (!sy) return "Checking…";
            if (sy.installed !== true) return "Not installed";
            return sy.active ? "In use" : "Installed, not in use";
        }
        return "";
    }
    /** Pie de una fila de estado o de acción; "" si el id no es de éstas. */
    function captionText(id) {
        switch (id) {
        case "sddmStatus":
            if (root.status === "missing") return "Install the sumi-sddm package, which provides the command";
            if (root.status === "incompatible" || root.status === "broken") return root.statusDetail;
            if (root.error.length > 0) return root.error;
            if (root.notice.length > 0) return root.notice;
            return root.saving ? "Saving…" : "Changes are saved for Sumi SDDM as you make them";
        case "sddmApplied": {
            const sy = root.system;
            if (root.systemBusy !== "") return "Waiting for your password…";
            if (!sy) return "";
            if (sy.installed !== true)
                return "Install the sumi-sddm package (packaging/arch in Sumi SDDM) to use it as your login screen";
            if (!sy.inSync) return "Your latest changes aren't on the login screen yet · Apply them below";
            return sy.active ? "Shows your current settings" : "Has your current settings · Use it to make it your login screen";
        }
        case "sddmApply": return "Copies your settings and wallpaper into the installed theme · asks for your password";
        case "sddmActivate": return root.activateArmed ? "Press again · it will be used the next time the login screen appears"
                                                       : "Makes Sumi your login screen · asks for your password, nothing restarts";
        case "sddmDeactivate": return root.deactivateArmed ? "Press again to go back to the previous theme"
                                                           : "Goes back to the theme you had before Sumi";
        case "sddmTry": return root.tryArmed ? "Press again to open · it takes the keyboard until you close it"
                                             : "The real login screen in a window, without logging in";
        case "sddmReset": return root.resetArmed ? "Press again to reset " + root.customCount + " settings"
                                                 : "Back to the theme's defaults · a copy is kept";
        case "sddmRestore": return "Brings back the settings from before the last reset";
        }
        return "";
    }
    /** Por qué una acción no se puede usar ahora ("" si se puede). */
    function reasonText(id) {
        if (id === "sddmStatus" || id === "sddmApplied") return "";
        if (!root.ready) return root.status === "checking" || root.status === "" ? "Checking…" : "Sumi SDDM is not available";
        if (id === "sddmReset" && root.customCount === 0) return "Everything is at its default";
        if (id === "sddmApply" || id === "sddmActivate" || id === "sddmDeactivate") {
            const sy = root.system;
            if (root.systemBusy !== "") return "Waiting for your password…";
            if (!sy) return "Checking…";
            if (sy.installed !== true) return "Sumi SDDM is not installed on the system";
            if (id === "sddmApply" && sy.inSync) return "The login screen already has your settings";
            if (id === "sddmActivate" && sy.active) return "Already your login screen";
            if (id === "sddmDeactivate" && !sy.active) return "Sumi isn't your login screen";
        }
        return "";
    }
    /** Lanza la acción de una fila (los mismos ids que Settings). */
    function runAction(id) {
        if (id === "sddmTry") root.openTestWindow();
        else if (id === "sddmReset") root.resetAll();
        else if (id === "sddmRestore") root.restorePrevious();
        else if (id === "sddmApply") root.systemApply();
        else if (id === "sddmActivate") root.activateSystem();
        else if (id === "sddmDeactivate") root.deactivateSystem();
    }
    /** El último arranque de la pantalla de inicio, en una línea: {state: ok|problems|missing|unknown, text, problems}. */
    function logSummary() {
        const g = root.greeterLog;
        if (!g) return { state: "unknown", text: "Checking…", problems: [] };
        if (g.missing) return { state: "missing", text: "No login screen has been shown since this computer started", problems: [] };
        if (g.error) return { state: "unknown", text: String(g.error), problems: [] };
        const ours = (g.greeters || []).filter(x => x.sumi);
        if (ours.length === 0) return { state: "missing", text: "Sumi hasn't been the login screen since this computer started", problems: [] };
        const last = ours[ours.length - 1];
        const when = last.time ? Qt.formatDateTime(new Date(Number(last.time) * 1000), "HH:mm") : "";
        const problems = (last.problems || []).map(String);
        return problems.length === 0
            ? { state: "ok", text: "Shown" + (when ? " at " + when : "") + " · no problems", problems: [] }
            : { state: "problems", text: "Shown" + (when ? " at " + when : "") + " · " + problems.length
                + (problems.length === 1 ? " problem" : " problems"), problems: problems };
    }

    // ---- filas para Settings ----------------------------------------------------------------------------------------
    /** Filas de un grupo del esquema (kind «sddm»: las pinta components/SddmField). */
    function rows(group) {
        if (!root.ready) return [];
        const rows = root.order.filter(k => root.keys[k].group === group).map(k => {
            const e = root.keys[k];
            return { id: "sddm:" + k, prop: "", kind: "sddm", key: k, name: String(e.label || k),
                     caption: root.captionFor(k) };
        });
        // el avatar no es una clave del tema (es de AccountsService): primera fila de Users, pie dinámico
        if (group === "users")
            rows.unshift({ id: "sddm:avatar", prop: "", kind: "sddm", key: "avatar", name: "Avatar" });
        return rows;
    }
    function captionFor(key) {
        if (key === "avatar") {
            const a = root.avatar;
            if (!a) return "";
            if (a.error) return String(a.error);
            if (!a.exists) return "Type the path of a picture · without one, your initials are shown";
            return a.sddmUses ? "Shown on the login screen · cropped to a circle" : "Saved, but the login screen can't read it";
        }
        const fe = root.fieldErrors[key];
        if (fe !== undefined) return fe.length > 0 ? fe : "This value was not saved";
        const w = root.warnings.find(x => x.key === key);
        if (w) return String(w.message);
        const e = root.keys[key];
        return e && e.help ? String(e.help) : "";
    }
    /** Etiqueta de un valor de enum ("top-left" → «Top left», "24h" → «24 h»). */
    function enumLabel(v) {
        const s = String(v);
        if (/^\d+h$/.test(s)) return s.replace("h", " h");
        const t = s.replace(/-/g, " ");
        return t.charAt(0).toUpperCase() + t.slice(1);
    }
    /** Un paso de teclado sobre la clave (←/→, Enter), como `adjust` de Settings. */
    function step(key, dir) {
        const e = root.keys[key];
        if (!e || !root.ready) return;
        const v = root.valueOf(key);
        if (e.type === "bool") root.set(key, dir === 0 ? !v : dir > 0);
        else if (e.type === "enum") {
            const vals = e.values || [];
            let i = Math.max(0, vals.indexOf(v));
            const d = dir === 0 ? 1 : dir;
            root.set(key, vals[((i + d) % vals.length + vals.length) % vals.length]);
        } else if ((e.type === "number" || e.type === "integer") && dir !== 0) {
            const lo = e.allowZero ? 0 : e.min;
            let n = Number(v) + dir * (e.step || 1);
            if (e.allowZero && n > 0 && n < e.min) n = dir > 0 ? e.min : 0;
            root.set(key, Math.max(lo, Math.min(e.max, Math.round(n * 1000) / 1000)));
        }
    }
}
