pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/providers-schema.js" as ProvidersSchema

/**
 * Los proveedores de fondos, tema, miniaturas y actualizaciones (portabilidad F4a, 2026-10-07;
 * H-10, H-11, H-15, HC-01…10).
 *
 *   settings.json  `providers.<tipo>` elige: auto · un backend · script · none   (Settings.provider*)
 *   $XDG_CONFIG_HOME/sumi-shell/providers.json   formato v1 (lib/providers-schema.js): las órdenes
 *                                                   de `script`, con los verbos que admite cada una
 *
 * providers.json es configuración EJECUTABLE, con las reglas de tasks.json:
 *   · la shell sólo lo LEE (la migración v3 → v4 lo sembró una vez, si no existía);
 *   · se ignora entero si no es del usuario o lo pueden escribir el grupo u otros (`stat -L`, en cada
 *     cambio); un tipo inválido se descarta con su motivo y los demás siguen; la shell funciona igual;
 *   · argv en lista, sin interpolar nada en una línea de shell; sólo se llama a un verbo declarado;
 *   · no se exporta ni se importa (Portability no lo conoce).
 *
 * F4a: resuelve qué proveedor toca y compone su argv (IPC `providers`, en seco).
 * F4b: el proveedor propio de FONDOS (auto, awww, hyprpaper) es `scripts/wallpaper-provider.py`, con el
 * mismo contrato que el script del autor; se compone aquí como si estuviera declarado (mismo esquema,
 * mismos verbos) y lo usan Wallpaper y Modes. F4c: las MINIATURAS propias (scripts/thumbnail-provider.py).
 * F4d: el TEMA propio (scripts/theme-provider.py) con la config mínima del proyecto, o con la config de
 * matugen que el usuario declare en providers.json (`theme.matugenConfig`, con o sin órdenes); `static` = sólo
 * la paleta estática. F4e: las ACTUALIZACIONES propias (scripts/updates-provider.py, pacman + AUR). Ya no queda
 * ningún tipo en «pending».
 *
 * `status`: loading · none (no hay archivo) · ready · invalid · ignored (dueño o permisos) · unreadable.
 */
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string path: Settings.configDir + "/providers.json"
    readonly property var kinds: ProvidersSchema.KINDS

    property string status: "loading"
    /** Por qué no hay proveedores declarados (inglés, para la UI); "" en ready/none. */
    property string reason: ""
    /** { tipo: proveedor normalizado } — sólo los válidos. */
    property var providers: ({})
    /** [{ kind, error }] lo descartado. */
    property var errors: []
    property int reads: 0

    /** La elección de settings.json para `kind`. */
    function settingOf(kind) {
        switch (kind) {
        case "wallpaper": return Settings.providerWallpaper;
        case "theme": return Settings.providerTheme;
        case "thumbnails": return Settings.providerThumbnails;
        case "updates": return Settings.providerUpdates;
        }
        return "";
    }

    /**
     * F4b: el proveedor propio de un tipo, con el formato de providers.json (validado por el mismo
     * esquema), o null si ese tipo aún no tiene propio. `setting` = auto · awww · hyprpaper.
     */
    function builtin(kind, setting) {
        // F4c: las miniaturas propias (scripts/thumbnail-provider.py, en una unidad transitoria)
        if (kind === "thumbnails" && (setting === "auto" || setting === "builtin")) {
            const t = ProvidersSchema.validate({ version: 1, thumbnails: { label: "Sumi Shell",
                scripts: [{ argv: ["python3", Quickshell.shellDir + "/scripts/thumbnail-provider.py", "--detach"],
                            supports: ["refresh"] }] } }, root.home);
            return t.providers.thumbnails || null;
        }
        // F4d: el tema propio. Config: la que declare el usuario en providers.json, o la mínima del proyecto
        if (kind === "theme" && ["auto", "matugen", "static"].indexOf(setting) >= 0) {
            const tp = Quickshell.shellDir + "/scripts/theme-provider.py";
            const decl = root.declared("theme");
            const cfg = decl && typeof decl.matugenConfig === "string" ? decl.matugenConfig : root.ownMatugenConfig;
            // D0-2 (paletas estáticas, 2026-11-04): si providers.json declara una lista estática (la del autor:
            // apply-static-colors.sh), Static la usa también con el propio, para devolver TODO el escritorio a
            // Minimaru y no sólo la shell. Sin ella, la lista propia (sólo la paleta de la shell).
            const declList = decl && decl.verbs.staticList !== undefined ? decl.scripts[decl.verbs.staticList].argv : null;
            const listArg = declList ? ["--static-list", JSON.stringify(declList.concat(["--list"]))] : [];
            const scripts = [{ argv: declList || ["python3", tp, "static"], supports: ["staticList"] },
                             { argv: ["python3", tp, "--config", cfg].concat(listArg, ["toggle"]), supports: ["toggle"] },
                             // F-b: los presets (también con «Static only»: son paletas estáticas)
                             { argv: ["python3", tp, "--config", cfg].concat(listArg, ["preset"]), supports: ["preset", "presetList"] },
                             // F-c: volver de un preset a Minimaru (themeSet static) por la misma transacción
                             { argv: ["python3", tp, "--config", cfg].concat(listArg, ["static"]), supports: ["staticApply"] }];
            if (setting !== "static")
                scripts.push({ argv: ["python3", tp, "--config", cfg, "reload"], supports: ["reload"] });
            const theme = { label: "Sumi Shell", scripts: scripts, matugenConfig: cfg };
            // El proveedor propio conserva el transporte XSettings opcional declarado.
            if (decl && typeof decl.xsettingsConfig === "string")
                theme.xsettingsConfig = decl.xsettingsConfig;
            const th = ProvidersSchema.validate({ version: 1, theme: theme }, root.home);
            return th.providers.theme || null;
        }
        // F4e: las actualizaciones propias (scripts/updates-provider.py: pacman + AUR; misma caché que updates.sh)
        if (kind === "updates" && (setting === "auto" || setting === "pacman")) {
            const up = Quickshell.shellDir + "/scripts/updates-provider.py";
            const u = ProvidersSchema.validate({ version: 1, updates: { label: "Sumi Shell", scripts: [
                { argv: ["python3", up, "--check", "--detach"], supports: ["check"] },
                { argv: ["python3", up], supports: ["list"] }] } }, root.home);
            return u.providers.updates || null;
        }
        if (kind !== "wallpaper" || ["auto", "awww", "hyprpaper"].indexOf(setting) < 0) return null;
        const base = ["python3", Quickshell.shellDir + "/scripts/wallpaper-provider.py", "--backend", setting];
        const r = ProvidersSchema.validate({ version: 1, wallpaper: {
            label: "Sumi Shell",
            scripts: [{ argv: base, supports: ["apply", "applyOutput", "clear", "sync", "restore", "transition"] },
                      { argv: base.concat(["pause"]), supports: ["pauseStatus", "pauseRestore"] }] } }, root.home);
        return r.providers.wallpaper || null;
    }

    /** El proveedor declarado en providers.json para `kind` (null si no hay o no vale). */
    function declared(kind) { return root.providers[kind] || null; }
    /**
     * F4d: la config mínima de matugen del proyecto (sólo la paleta de la shell). F-e (paletas estáticas, 2026-11-04):
     * si `install.sh theme-apps` dejó la suya (la paleta de la shell + kitty, GTK, Qt o el borde de Hyprland), ésa, con
     * las reglas de providers.json: tuya y no escribible por otros; si no, la mínima.
     */
    readonly property string ownMatugenConfig: root.appsConfigOk ? root.appsConfig
        : Quickshell.shellDir + "/templates/matugen-config.toml"
    readonly property string appsConfig: Settings.configDir + "/matugen-apps.toml"
    property bool appsConfigOk: false
    onAppsConfigOkChanged: if (root.settled) capsLater.restart()
    /**
     * 2026-11-21 (docs/MINIMARU-CLIS-2026-11-20.md §13), como en services/Tasks: el `stat` ya no se interrumpe
     * (el interrumpido salía ≠ 0 y dejaba appsConfigOk en false un instante: una detección de capacidades de más)
     * y una lectura de asentamiento 150 ms después del último aviso recoge una segunda escritura inmediata que
     * FileView descartaba.
     */
    property int appsGen: 0
    property int appsPermGen: -1
    property bool appsLastOk: false
    function appsStartPerm() {
        if (appsPerm.running) return;
        root.appsPermGen = root.appsGen;
        appsPerm.running = true;
    }
    Timer { id: appsSettle; interval: 150; onTriggered: appsFile.reload() }
    FileView {
        id: appsFile
        path: root.appsConfig
        watchChanges: true
        printErrors: false
        onFileChanged: {
            reload();
            Qt.callLater(function () { appsFile.watchChanges = false; appsFile.watchChanges = true; });
            appsSettle.restart();
        }
        onLoaded: { root.appsGen++; root.appsLastOk = true; root.appsStartPerm(); }
        onLoadFailed: { root.appsGen++; root.appsLastOk = false; root.appsConfigOk = false; }
    }
    Process {
        id: appsPerm
        command: ["sh", "-c", "stat -L -c '%u %a' -- \"$1\" && id -u", "sh", root.appsConfig]
        stdout: StdioCollector { id: appsPermOut }
        onExited: (code) => {
            if (root.appsPermGen !== root.appsGen) {      // hubo otra lectura mientras corría: no vale
                if (root.appsLastOk) Qt.callLater(root.appsStartPerm);
                return;
            }
            const lines = String(appsPermOut.text || "").trim().split("\n");
            const st = (lines[0] || "").split(" ");
            const me = (lines[1] || "").trim();
            const ok = code === 0 && st.length >= 2 && st[0] === me && (parseInt(st[1], 8) & 18) === 0;
            if (!ok && code === 0) console.warn("providers: matugen-apps.toml is ignored: it isn't yours or others can change it");
            root.appsConfigOk = ok;
        }
    }

    /** Por qué providers.json no aporta `kind` ("" si lo declara). */
    function whyUndeclared(kind) {
        if (root.declared(kind)) return "";
        if (root.status === "loading") return "";
        if (root.status === "none") return "providers.json is not set up";
        if (root.status !== "ready") return root.reason;
        for (let i = 0; i < root.errors.length; i++)
            if (root.errors[i].kind === kind) return "providers.json: " + kind + " is invalid (" + root.errors[i].error + ")";
        return "providers.json does not declare a " + kind + " provider";
    }

    /**
     * Qué proveedor toca ahora para `kind`:
     *   { setting, mode, label, why }
     *   mode  script (la orden de providers.json) · builtin (el propio de la shell: F4b, fondos) ·
     *         none (la función no existe aquí) · pending (propio que aún no existe: F4c–F4e) ·
     *         unavailable (script sin orden válida) · loading (aún no se ha leído providers.json)
     */
    function resolve(kind) {
        const setting = root.settingOf(kind);
        if (setting === "none") return { setting: setting, mode: "none", label: "", why: "Turned off in Settings" };
        if (setting === "script") {
            if (root.status === "loading") return { setting: setting, mode: "loading", label: "", why: "" };
            const p = root.declared(kind);
            if (p) return { setting: setting, mode: "script", label: p.label, why: "" };
            return { setting: setting, mode: "unavailable", label: "", why: root.whyUndeclared(kind) };
        }
        if (root.builtin(kind, setting))
            return { setting: setting, mode: "builtin", label: "Sumi Shell (" + setting + ")", why: "" };
        return { setting: setting, mode: "pending", label: setting,
                 why: "The shell's own " + kind + " provider is not available yet" };
    }

    /** El proveedor activo: el script de providers.json o el propio (null si ninguno). */
    function active(kind) {
        const r = root.resolve(kind);
        return r.mode === "script" ? root.declared(kind) : r.mode === "builtin" ? root.builtin(kind, r.setting) : null;
    }

    /** Si el proveedor activo hace `verb`. */
    function supports(kind, verb) {
        const p = root.active(kind);
        return !!p && p.verbs[verb] !== undefined;
    }

    /** Por qué no se puede hacer `verb` de `kind` aquí ("" = sí). */
    function whyNot(kind, verb) {
        const r = root.resolve(kind);
        if (r.mode === "loading") return "";
        if (r.mode !== "script" && r.mode !== "builtin") return r.why;
        if (!root.supports(kind, verb)) {
            // F4d: con «Static only» el propio no regenera: decirlo como lo que es
            if (kind === "theme" && r.mode === "builtin" && r.setting === "static" && verb === "reload")
                return "Colours from the wallpaper are turned off in Settings (Shell → Apps)";
            return "The " + kind + " provider " + (r.mode === "script" ? "in providers.json " : "") + "does not do " + verb;
        }
        return "";
    }
    /** Si el proveedor activo de `kind` ya se sabe (Settings leído y sin migrar; providers.json leído si toca). */
    readonly property bool settled: Settings.loaded && Settings.status !== "upgrading"
    function isSettled(kind) { return root.settled && root.resolve(kind).mode !== "loading"; }

    /**
     * F4b: cambiar de proveedor (o editar providers.json) cambia lo que se puede hacer: redetectar. Nunca
     * durante una migración (los valores de entonces no son los que quedarán).
     */
    Connections {
        target: Settings
        function onProviderWallpaperChanged() { if (root.settled) capsLater.restart(); }
        function onProviderThumbnailsChanged() { if (root.settled) capsLater.restart(); }
        function onProviderThemeChanged() { if (root.settled) capsLater.restart(); }
        function onProviderUpdatesChanged() { if (root.settled) capsLater.restart(); }
    }
    onProvidersChanged: if (root.settled) capsLater.restart()
    Timer { id: capsLater; interval: 300; onTriggered: Capabilities.refresh("providers") }

    /** El argv de `verb` con `args` ({ path, output, json, wall, preset }), o null. */
    function command(kind, verb, args) {
        const p = root.active(kind);
        return p ? ProvidersSchema.command(p, verb, args) : null;
    }
    /** El entorno extra de `verb` (WALL_TRANSITION con la marca `transition`). */
    function env(kind, verb, args) {
        const p = root.active(kind);
        return p ? ProvidersSchema.env(p, verb, args) : ({});
    }
    /** Una ruta que declara el proveedor activo (lockStill, matugenConfig, cache), o "". */
    function pathOf(kind, key) {
        const p = root.active(kind);
        return p && typeof p[key] === "string" ? p[key] : "";
    }

    // ---- leer (como Tasks: dueño y permisos antes de usar lo leído) ---------------------------

    property string pendingText: ""
    property bool retried: false
    Timer { id: retry; interval: 200; onTriggered: file.reload() }
    /** La lectura de asentamiento (ver onFileChanged): una por ráfaga de cambios, nunca periódica. */
    Timer { id: settle; interval: 150; onTriggered: file.reload() }

    FileView {
        id: file
        path: root.path
        watchChanges: true
        printErrors: false
        // un editor que sustituye el archivo: el vigilante sigue al inodo viejo (como en Settings).
        // 2026-11-21 (§13 del informe, como en services/Tasks): una segunda escritura inmediata podía no leerse
        // (FileView descarta lecturas pedidas casi a la vez): lectura de asentamiento 150 ms tras el último aviso.
        onFileChanged: {
            reload();
            Qt.callLater(function () { file.watchChanges = false; file.watchChanges = true; });
            settle.restart();
        }
        onLoaded: {
            root.pendingText = file.text();
            root.loadGen++;
            root.lastLoadOk = true;
            root.startPerm();
        }
        onLoadFailed: (error) => {
            root.loadGen++;
            root.lastLoadOk = false;
            root.reads++;
            if (error === FileViewError.FileNotFound) root.set("none", "", {}, []);
            else root.set("unreadable", "providers.json could not be read", {}, []);
        }
    }

    /** Un vigilante no sigue un directorio que aún no existe (F3d-1): asegurarlo y rearmar. */
    Process {
        id: ensureDir
        command: ["mkdir", "-p", "--", Settings.configDir]
        onExited: { file.watchChanges = false; file.watchChanges = true; file.reload(); }
    }
    Component.onCompleted: ensureDir.running = true

    /**
     * Dueño y permisos: una orden fija con la ruta como argumento (nada se interpola).
     * 2026-11-21 (§13, como en services/Tasks): ya no se interrumpe; cada lectura sube `loadGen` y un resultado de
     * una lectura ya superada se descarta (y se repite si la última fue buena). Antes, el interrumpido salía ≠ 0 y
     * marcaba «Could not check who owns providers.json» (`unreadable`) un instante.
     */
    property int loadGen: 0
    property int permGen: -1
    property bool lastLoadOk: false
    function startPerm() {
        if (perm.running) return;
        root.permGen = root.loadGen;
        perm.running = true;
    }
    Process {
        id: perm
        command: ["sh", "-c", "stat -L -c '%u %a' -- \"$1\" && id -u", "sh", root.path]
        stdout: StdioCollector { id: permOut }
        onExited: (code) => {
            if (root.permGen !== root.loadGen) {
                if (root.lastLoadOk) Qt.callLater(root.startPerm);
                return;
            }
            root.judge(code, permOut.text);
        }
    }

    function judge(code, out) {
        root.reads++;
        const lines = String(out || "").trim().split("\n");
        const st = (lines[0] || "").split(" ");
        const me = (lines[1] || "").trim();
        if (code !== 0 || st.length < 2 || me.length === 0) {
            root.set("unreadable", "Could not check who owns providers.json", {}, []);
            return;
        }
        const mode = parseInt(st[1], 8);
        if (st[0] !== me) {
            root.set("ignored", "providers.json is ignored: it does not belong to you", {}, []);
            return;
        }
        if ((mode & 18) !== 0      /* 0o022: escribible por grupo u otros */) {
            root.set("ignored", "providers.json is ignored: other users can change it (chmod go-w)", {}, []);
            return;
        }
        let doc;
        try { doc = JSON.parse(root.pendingText); }
        catch (e) {
            // un editor que escribe en el sitio deja un hueco vacío (F3e): se relee una vez
            if (!root.retried) { root.retried = true; retry.restart(); return; }
            root.set("invalid", "providers.json is not valid JSON", {}, []);
            return;
        }
        root.retried = false;
        const r = ProvidersSchema.validate(doc, root.home);
        if (r.structure.length > 0) { root.set("invalid", "providers.json: " + r.structure, {}, []); return; }
        root.set("ready", "", r.providers, r.errors);
        if (r.errors.length > 0)
            console.warn("providers: ignored " + r.errors.map(e => e.kind + " (" + e.error + ")").join(", "));
    }

    function set(status, reason, providers, errors) {
        root.providers = providers;
        root.errors = errors;
        root.reason = reason;
        root.status = status;
        if (reason.length > 0) console.warn("providers: " + reason);
    }

    // ---- en seco (IPC `providers`) -----------------------------------------------------------

    /**
     * Qué se ejecutaría para cada verbo, con argumentos de muestra (`samples`: { path, output, json,
     * wall, transition }). No ejecuta nada. La comparan tools/f4/ con la tabla de antes.
     */
    function dryRun(samples) {
        const out = {};
        for (let i = 0; i < root.kinds.length; i++) {
            const kind = root.kinds[i];
            const r = root.resolve(kind);
            const verbs = {};
            const all = Object.keys(ProvidersSchema.VERBS[kind]);
            for (let j = 0; j < all.length; j++) {
                const why = root.whyNot(kind, all[j]);
                verbs[all[j]] = why.length > 0 ? { why: why }
                    : { argv: root.command(kind, all[j], samples), env: root.env(kind, all[j], samples) };
            }
            const paths = {};
            const keys = ProvidersSchema.PATHS[kind];
            for (let k = 0; k < keys.length; k++) paths[keys[k]] = root.pathOf(kind, keys[k]);
            out[kind] = { setting: r.setting, mode: r.mode, label: r.label, why: r.why, verbs: verbs, paths: paths };
        }
        return out;
    }

    function summary() {
        const declared = {};
        for (const k in root.providers)
            declared[k] = { label: root.providers[k].label, scripts: root.providers[k].scripts.map(s => s.supports) };
        return { status: root.status, reason: root.reason, path: root.path, reads: root.reads,
                 declared: declared, errors: root.errors,
                 settings: { wallpaper: Settings.providerWallpaper, theme: Settings.providerTheme,
                             thumbnails: Settings.providerThumbnails, updates: Settings.providerUpdates,
                             desktopSync: Settings.themeDesktopSync },
                 settingsStatus: Settings.status, seeded: [] };   // nada se siembra desde 14e07e8; se conserva la clave
    }
}
