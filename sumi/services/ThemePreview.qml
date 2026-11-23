pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Preview reversible del tema global (rediseño 12A, 2026-09-28).
 *
 * rediseno/docs/futurevisual-profilesurface.md: enfocar un perfil sólo selecciona; **Preview**
 * pone el tema en TODAS las salidas de matugen sin tocar el esquema persistido ni el sentinel;
 * **Keep changes** confirma exactamente lo que se previsualizó; **Revert** (y Esc, cerrar sin
 * confirmar…) vuelve a la copia de lo confirmado. Los archivos los toca
 * `scripts/theme-preview.py`; aquí vive el estado, el orden y el propietario:
 *
 *   - una operación GLOBAL de `Operations` (recurso `theme`): el traslado a otra pantalla
 *     conserva la misma preview (`claim`), sin snapshot nuevo ni restauración;
 *   - serializada: pedir Preview varias veces descarta la generación pendiente y aplica sólo
 *     la ÚLTIMA petición; un install ya empezado termina antes (es atómico por archivo);
 *   - un cambio externo (fondo, esquema o sentinel movidos por otro: un Apply, `minimaru theme`,
 *     la rotación) la termina: se repone sólo lo que siga llevando la preview (hash), lo que
 *     otro escribió después no se pisa;
 *   - el registro pendiente vive en disco: si el shell muere, al volver se restaura.
 *
 * Perfiles: los nueve esquemas cortos de `Colors.schemes`, «static» (Minimaru) y, desde F-c de las paletas
 * estáticas (2026-11-04), «preset:<id>»: las paletas congeladas de sumi/palettes/ (scripts/palette_presets.py
 * list). Un preset no depende del fondo: Mode cambia a su variante hermana (claro ↔ oscuro); Contrast y Colour
 * source no se aplican. Keep deja su id en theme/preset y apaga el dinámico.
 */
Singleton {
    id: root

    // ---- rutas (y sustitutos de prueba) --------------------------------------

    /**
     * PRUEBAS (IPC `themePreviewTestRoot`, sólo bajo /tmp/): config, sentinel, esquema, fondo y
     * lista estática salen de esa carpeta (`config.toml`, `matugen/enabled`, `matugen/scheme`,
     * `wall`, `static-list.sh`); nada toca el tema real. Vacío = lo real.
     */
    property string testRoot: ""
    readonly property bool testing: root.testRoot.length > 0

    readonly property string helper: Quickshell.shellDir + "/scripts/theme-preview.py"
    readonly property string snapDir: root.testing ? root.testRoot + "/state/theme-preview"
        : Settings.stateDir + "/theme-preview"
    readonly property string workBase: root.testing ? root.testRoot + "/work"
        : (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/sumi-theme-preview"
    readonly property var env: root.testing ? ({
        MATUGEN_CONFIG: root.testRoot + "/config.toml",
        MATUGEN_SENTINEL: root.testRoot + "/matugen/enabled",
        MATUGEN_SCHEME_FILE: root.testRoot + "/matugen/scheme",
        KT_WALL_STATE: root.testRoot + "/wall",
        KT_STATIC_LIST: root.testRoot + "/static-list.sh",
        KT_HOOK_TIMEOUT: "2",
        MATUGEN_MODE_FILE: root.testRoot + "/matugen/mode",
        MATUGEN_CONTRAST_FILE: root.testRoot + "/matugen/contrast",
        MATUGEN_SOURCE_FILE: root.testRoot + "/matugen/source",
        MATUGEN_PRESET_FILE: root.testRoot + "/matugen/preset",
        MATUGEN_LAST_CHANGE: root.testRoot + "/matugen/last-change.json",
        KT_GSETTINGS: root.testRoot + "/gsettings.sh",
        KT_XSETTINGS_CONFIG: ""
    }) : root.providerEnv
    /**
     * F4d: lo real sale del PROVEEDOR de tema: su config de matugen (la del autor por providers.json, o la
     * mínima del proyecto), el argv de su lista estática (ya con «--list») y qué se sincroniza con el
     * escritorio (theme.desktopSync). Para el autor: la misma config y el mismo argv que antes, y `full`.
     */
    readonly property var providerEnv: {
        const e = { KT_DESKTOP_SYNC: Settings.themeDesktopSync };
        const cfg = Providers.pathOf("theme", "matugenConfig");
        if (cfg.length > 0) e.MATUGEN_CONFIG = cfg;
        e.KT_XSETTINGS_CONFIG = Providers.pathOf("theme", "xsettingsConfig");
        const sl = Providers.command("theme", "staticList", {});
        if (sl) e.KT_STATIC_LIST_ARGV = JSON.stringify(sl);
        return e;
    }

    function setTestRoot(dir) {
        const d = String(dir || "");
        if (d.length > 0 && (d.indexOf("/tmp/") !== 0 || d.indexOf("..") >= 0)) return false;
        if (root.live || proc.running) return false;
        root.testRoot = d;
        root.error = "";
        root.lastResult = null;
        Qt.callLater(root.recover);
        return true;
    }

    // ---- lo confirmado (observado, nunca escrito aquí salvo en Keep) --------

    /** En pruebas, del árbol de prueba; en real, de `Colors` y `Wallpaper` (los mismos archivos). */
    property bool tEnabled: false
    property string tScheme: ""
    property string tWall: ""
    readonly property bool baseEnabled: root.testing ? root.tEnabled : Colors.dynamicEnabled
    readonly property string baseScheme: root.testing ? root.tScheme : Colors.scheme
    readonly property string baseWall: root.testing ? root.tWall : Wallpaper.current

    /** El perfil confirmado: el que lleva la marca Applied. Sin el sentinel, el preset de theme/preset o Glass. */
    readonly property string confirmed: !root.baseEnabled
        ? (root.presetIdRe.test(root.fPreset) ? "preset:" + root.fPreset : "static")
        : (root.baseScheme.indexOf("scheme-") === 0 ? root.baseScheme.substring(7) : root.baseScheme)

    readonly property var profiles: Colors.schemes.concat(["static"]).concat(root.presetIds)
    function valid(p) { return root.profiles.indexOf(p) >= 0; }

    // ---- F-c: las paletas estáticas (presets) ---------------------------------------

    readonly property var presetIdRe: /^[a-z0-9]+(-[a-z0-9]+)+$/
    /** [{ id, name, family, familyName, variant, variantName, dark, sibling, samples }], por familia y oscuro primero. */
    property var presets: []
    property bool presetsLoaded: false
    readonly property var presetIds: root.presets.map(p => "preset:" + p.id)
    function isPreset(p) { return String(p).indexOf("preset:") === 0; }
    /** Minimaru o un preset: colores fijos, sin fondo, contraste ni color de origen. */
    function isStatic(p) { return p === "static" || root.isPreset(p); }
    function presetOf(p) {
        const id = String(p).indexOf("preset:") === 0 ? String(p).substring(7) : String(p);
        for (const x of root.presets) if (x.id === id) return x;
        return null;
    }
    /** El perfil de la misma familia en ese modo (él mismo, su hermana o "" si no hay variante). */
    function variantFor(p, lightness) {
        const x = root.presetOf(p);
        if (!x) return "";
        if ((x.dark ? "dark" : "light") === lightness) return "preset:" + x.id;
        const s = x.sibling ? root.presetOf(x.sibling) : null;
        return s && s.dark !== x.dark ? "preset:" + s.id : "";
    }
    Process {
        id: presetsProc
        command: ["python3", Quickshell.shellDir + "/scripts/palette_presets.py", "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                let l = [];
                try { l = JSON.parse(this.text); } catch (e) { l = []; }
                if (!Array.isArray(l)) l = [];
                l.sort((a, b) => a.family === b.family ? (a.dark === b.dark ? (a.name < b.name ? -1 : 1) : (a.dark ? -1 : 1))
                                                       : (a.family < b.family ? -1 : 1));
                root.presets = l;
                root.presetsLoaded = true;
            }
        }
    }

    /**
     * Portabilidad F2c: por qué no se puede probar ni aplicar `profile` en esta máquina ("" = sí).
     * Dinámico = matugen con su config y `matugen_reload.sh`; static = `apply-static-colors.sh`;
     * los dos, `theme-preview.py` (python3 ≥ 3.11). Sólo lo detectado con prueba desactiva
     * (`Capabilities.can`). Revert, Keep de lo ya puesto y la recuperación NUNCA se cortan: devuelven
     * lo que había. Con `testRoot` no aplica: el proveedor es el árbol falso.
     */
    function whyNot(profile) {
        if (root.testing) return "";
        // F-c: un preset = el verbo `preset` del proveedor y python3 (sin matugen, sólo la paleta de la shell)
        if (root.isPreset(profile)) {
            if (root.presetsLoaded && !root.presetOf(profile)) return "This palette isn't installed";
            const pp = Providers.whyNot("theme", "preset");
            if (pp.length > 0) return pp;
            return Capabilities.can("runtime.python") ? "" : Capabilities.why("runtime.python");
        }
        // F4d: primero el proveedor (Off/estático elegido, script sin declarar…), después lo detectado
        const pw = Providers.whyNot("theme", profile === "static" ? "staticList" : "reload");
        if (pw.length > 0) return pw;
        if (!Capabilities.can("runtime.python")) return Capabilities.why("runtime.python");
        const id = profile === "static" ? "theme.static" : "theme.dynamic";
        return Capabilities.can(id) ? "" : Capabilities.why(id);
    }

    // ---- 12F: modo, contraste y color de origen -----------------------------------

    /**
     * Junto al esquema, tres archivos que `matugen_reload.sh` lee (misma validación que allí y
     * que el helper): `mode` (dark | light), `contrast` (-1 … 1) y `source` (wallpaper | #rrggbb).
     * Sin archivo, el default. Static sólo existe en oscuro: sus opciones no cuentan.
     */
    readonly property string matugenDir: root.testing ? root.testRoot + "/matugen" : Colors.themeDir
    property string fMode: ""
    property string fContrast: ""
    property string fSource: ""
    function normMode(v) { return String(v).trim() === "light" ? "light" : "dark"; }
    function normContrast(v) {
        const t = String(v).trim();
        return /^-?(0(\.[0-9]{1,2})?|1(\.0{1,2})?)$/.test(t) ? Math.round(parseFloat(t) * 100) / 100 : 0;
    }
    function normSource(v) {
        const t = String(v).trim();
        return /^#[0-9a-fA-F]{6}$/.test(t) ? t.toLowerCase() : "wallpaper";
    }
    function normOpts(profile, o) {
        if (profile === "static") return { lightness: "dark", contrast: 0, source: "wallpaper" };
        if (root.isPreset(profile)) {
            const x = root.presetOf(profile);
            return { lightness: x && !x.dark ? "light" : "dark", contrast: 0, source: "wallpaper" };
        }
        const x = o || {};
        return { lightness: root.normMode(x.lightness), contrast: root.normContrast(x.contrast === undefined ? 0 : x.contrast),
                 source: root.normSource(x.source === undefined ? "wallpaper" : x.source) };
    }
    function keyOf(profile, o) {
        if (!profile) return "";
        const n = root.normOpts(profile, o);
        return profile + "|" + n.lightness + "|" + n.contrast + "|" + n.source;
    }
    readonly property var confirmedOpts: root.normOpts(root.confirmed,
        { lightness: root.fMode, contrast: root.fContrast || "0", source: root.fSource || "wallpaper" })
    readonly property string confirmedKey: root.keyOf(root.confirmed, root.confirmedOpts)
    property var requestedOpts: ({})
    property var previewingOpts: ({})
    readonly property string requestedKey: root.keyOf(root.requested, root.requestedOpts)
    readonly property string previewingKey: root.keyOf(root.previewing, root.previewingOpts)
    /** Las opciones con que se dibujan las muestras: las de la prueba en curso o las confirmadas. */
    readonly property var sampleOpts: root.live && root.requested.length > 0 && !root.isStatic(root.requested)
        ? root.normOpts(root.requested, root.requestedOpts) : root.normOpts("tonal-spot", root.confirmedOpts)
    function describe(profile, o) {
        const n = root.normOpts(profile, o);
        if (root.isStatic(profile)) return root.nameOf(profile);
        return root.nameOf(profile) + (n.lightness === "light" ? " · light" : "")
            + (n.contrast !== 0 ? " · contrast " + (n.contrast > 0 ? "+" : "") + n.contrast : "")
            + (n.source !== "wallpaper" ? " · from " + n.source : "");
    }

    FileView {
        id: modeFile
        path: root.matugenDir + "/mode"
        watchChanges: true
        printErrors: false
        onLoaded: root.fMode = text().trim()
        onLoadFailed: root.fMode = ""
        onFileChanged: reload()
    }
    FileView {
        id: contrastFile
        path: root.matugenDir + "/contrast"
        watchChanges: true
        printErrors: false
        onLoaded: root.fContrast = text().trim()
        onLoadFailed: root.fContrast = ""
        onFileChanged: reload()
    }
    FileView {
        id: sourceFile
        path: root.matugenDir + "/source"
        watchChanges: true
        printErrors: false
        onLoaded: root.fSource = text().trim()
        onLoadFailed: root.fSource = ""
        onFileChanged: reload()
    }
    /** F-c: el preset confirmado (lo escribe Keep de un preset; vale sólo sin el sentinel). */
    property string fPreset: ""
    FileView {
        id: presetFile
        path: root.matugenDir + "/preset"
        watchChanges: true
        printErrors: false
        onLoaded: root.fPreset = text().trim()
        onLoadFailed: root.fPreset = ""
        onFileChanged: reload()
    }

    // F1d: si el padre faltaba al cargar, Colors lo crea; rearmar los vigilantes.
    Connections {
        target: Colors
        function onThemeStateReadyChanged() {
            if (root.testing || !Colors.themeStateReady) return;
            for (const file of [modeFile, contrastFile, sourceFile, presetFile, lastChangeFile]) {
                file.watchChanges = false;
                file.watchChanges = true;
                file.reload();
            }
        }
    }

    /** Nombres de producto de los perfiles (carrusel y Settings). */
    readonly property var names: ({
        "content": "Content", "expressive": "Expressive", "fidelity": "Fidelity",
        "fruit-salad": "Fruit Salad", "monochrome": "Monochrome", "neutral": "Neutral",
        "rainbow": "Rainbow", "tonal-spot": "Tonal Spot", "vibrant": "Vibrant",
        "static": "Minimaru"
    })
    function nameOf(p) {
        if (root.isPreset(p)) { const x = root.presetOf(p); return x ? x.name : String(p).substring(7); }
        return root.names[p] || p;
    }

    /**
     * 12C, Regenerate palette: rehace las salidas con el fondo y esquema CONFIRMADOS por el flujo
     * de siempre (`Wallpaper.startColors` → `matugen_reload.sh`, con su estado observado). No
     * con una prueba abierta: se pisaría. En pruebas, matugen sobre el árbol falso.
     */
    function regenerate() {
        if (root.live || !root.baseEnabled) return false;
        if (root.whyNot(root.confirmed).length > 0) return false;
        if (root.baseWall.length === 0 && root.confirmedOpts.source === "wallpaper") return false;
        if (root.testing) {
            const e = [];
            for (const k in root.env) e.push(k + "=" + root.env[k]);
            // Sólo se ejecuta el sustituto que proporciona el banco.
            Quickshell.execDetached(["env"].concat(e).concat(["bash", root.testRoot + "/matugen_reload.sh",
                                                               root.baseWall]));
            return true;
        }
        Wallpaper.startColors(Wallpaper.current);
        return true;
    }

    // ---- estado -------------------------------------------------------------

    /**
     * idle        nada en prueba
     * preparing   generando o instalando `preparing` (la tarjeta: «Preparing preview»)
     * active      `previewing` está puesto en todas las salidas; Keep / Revert
     * restoring   reponiendo la copia
     * keeping     persistiendo
     * recovering  al arrancar, una preview que quedó de antes
     */
    property string phase: "idle"
    property string opId: ""
    readonly property bool live: root.opId.length > 0
    property string requested: ""
    property string preparing: ""
    property string previewing: ""
    /** Último fallo visible (Could not preview…), con su detalle; se limpia al pedir otra cosa. */
    property string error: ""
    property string errorDetail: ""
    /** Resultado del último cierre: { kind: kept|reverted|external|recovered, … }. */
    property var lastResult: null
    /** Recargas que fallaron o vencieron en la última instalación (se dicen, no se esconden). */
    property var hookFailures: []
    property var desktopSyncResult: null
    readonly property string desktopWarning: {
        const r = root.desktopSyncResult;
        if (!r) return "";
        const parts = [];
        if ((r.desktopFailures || []).length) parts.push("Desktop sync failed: " + r.desktopFailures.join(", "));
        const skipped = r.desktopSkipped || {};
        for (const key of Object.keys(skipped)) parts.push(key + ": " + skipped[key]);
        return parts.join(" · ");
    }
    property int seq: 0

    signal ended(string kind, bool ok)
    /** F-d: un aviso para el island (Osd), p. ej. que las apps GTK abiertas siguen con los colores de antes. */
    signal notice(string text, string glyph, string tone)

    // ---- F-d: apps GTK que no recargan solas -------------------------------------------------

    /**
     * Medido el 2026-10-24: GTK 3 nunca relee su CSS en una app abierta; GTK 4/libadwaita sólo al cambiar
     * claro ↔ oscuro (si la shell sincroniza el escritorio). `gtk` = { gtk3, gtk4 }: qué CSS cambió (lo dice el
     * helper); `before`/`after` = el modo de lo confirmado antes y el de ahora.
     */
    function reopenApps(gtk, before, after) {
        const l = [];
        if (gtk && gtk.gtk3) l.push("GTK 3");
        if (gtk && gtk.gtk4 && (before === after || Settings.themeDesktopSync === "off")) l.push("GTK 4");
        return l;
    }
    /** La frase completa (línea de estado). Medido en la sesión el 2026-11-04: al cambiar claro ↔ oscuro, una app
     *  GTK 3 abierta sí cambia de tema (Adwaita ↔ Adwaita-dark), pero conserva los colores de la paleta anterior. */
    function reopenText(l, modeChanged) {
        if (!l || l.length === 0) return "";
        if (modeChanged && l.length === 1 && l[0] === "GTK 3")
            return "Open GTK 3 apps switch light/dark but keep old accents until reopened";
        return l.join(" and ") + " apps already open keep the old colours until reopened";
    }
    /** La frase del island (cabe en la banda): «Reopen GTK 3 and 4 apps for the new colours». */
    function reopenShort(l) {
        if (!l || l.length === 0) return "";
        return "Reopen " + (l.length > 1 ? "GTK 3 and 4" : l[0]) + " apps for the new colours";
    }
    /** Lo de la prueba en curso (acumulado desde la copia). */
    property var gtkPending: ({})
    property string lightnessFrom: "dark"
    property string lightnessTo: "dark"
    readonly property var reopenNow: root.phase === "active" ? root.reopenApps(root.gtkPending, root.lightnessFrom, root.lightnessTo) : []
    /** Lo del último cambio confirmado (Keep, themePreset, themeSet static…): theme/last-change.json. */
    property var lastReopen: []
    property bool lastReopenModeChanged: false
    property string lastChangeSeen: ""
    property bool lastChangePrimed: false
    onTestRootChanged: { root.lastChangePrimed = false; root.lastChangeSeen = ""; }
    FileView {
        id: lastChangeFile
        path: root.matugenDir + "/last-change.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoadFailed: root.lastChangePrimed = true
        onLoaded: {
            let d = null;
            try { d = JSON.parse(text()); } catch (e) { return; }
            if (!d || d.at === undefined) return;
            const at = String(d.at);
            // al arrancar (o al cambiar de árbol) lo que ya había no se anuncia
            if (!root.lastChangePrimed) { root.lastChangePrimed = true; root.lastChangeSeen = at; return; }
            if (at === root.lastChangeSeen) return;
            root.lastChangeSeen = at;
            const l = root.reopenApps(d.gtk, d.lightnessBefore, d.lightness);
            root.lastReopen = l;
            root.lastReopenModeChanged = d.lightnessBefore !== d.lightness;
            if (l.length > 0) root.notice(root.reopenShort(l), "palette", "info");
        }
    }
    /** La restauración falló (la vista puede estar ya cerrada): `core/Screens` lo dice en el island. */
    signal restoreFailed(string screen)

    readonly property string owner: root.live ? Operations.ownerOf(root.opId) : ""

    /**
     * Empezar o cambiar la prueba. `screen` = la pantalla desde la que se pide: la primera vez
     * es el propietario; después, pedir desde otra traslada el control (acción explícita).
     */
    function preview(profile, screen, opts) {
        // F-c: con un preset, el modo pedido elige la variante de su familia (Mocha ↔ Latte)
        if (root.isPreset(profile) && opts && opts.lightness !== undefined) {
            const v = root.variantFor(profile, root.normMode(opts.lightness));
            if (v.length > 0) profile = v;
        }
        if (!root.valid(profile)) return false;
        // F2c: sin proveedor no se empieza (ni se cambia a) una prueba que fallaría a medias
        if (root.whyNot(profile).length > 0) return false;
        if (root.phase === "restoring" || root.phase === "keeping" || root.phase === "recovering")
            return false;
        // 12F: sin opciones, las de la prueba en curso o las confirmadas (el carrusel sólo elige perfil)
        const o = root.normOpts(profile, opts !== undefined ? opts
            : (root.live && root.requested.length > 0 ? root.requestedOpts : root.confirmedOpts));
        if (!root.live) {
            if (root.keyOf(profile, o) === root.confirmedKey) return false;   // nada que probar
            const r = Operations.begin("theme-preview", "theme", "theme", profile, screen || "", {});
            if (r.conflict.length > 0) return false;
            root.opId = r.id;
            root.lastResult = null;
        } else if (screen && screen !== root.owner) {
            Operations.claim(root.opId, screen);
        }
        root.error = "";
        root.errorDetail = "";
        root.requestedOpts = o;
        root.requested = profile;
        Operations.update(root.opId, { key: root.describe(profile, o) });
        root.kick();
        return true;
    }

    /** Confirmar lo que TERMINÓ de previsualizarse; nunca otra selección posterior. */
    function keep() {
        if (root.phase !== "active" || root.requestedKey !== root.previewingKey) return false;
        root.phase = "keeping";
        root.run("keep", ["keep", "--snap", root.snapDir, "--profile", root.previewing]);
        return true;
    }

    /** Volver a lo confirmado. `why` queda en la operación («Reverted», «Closed without keeping»…). */
    function revert(why) {
        if (!root.live || root.phase === "restoring" || root.phase === "keeping") return false;
        root.requested = "";
        root.closeReason = why || "Reverted";
        if (proc.running && proc.step === "stage") {
            proc.running = false;              // la generación pendiente ya no vale
            return true;                       // onExited sigue con la restauración
        }
        if (proc.running) return true;         // un install termina y después se restaura
        root.startRestore();
        return true;
    }
    property string closeReason: ""

    /**
     * «Use when wallpaper is available» (sin fondo no hay preview posible): guarda el esquema
     * dinámico por el flujo del rice; sus colores llegan con el siguiente fondo. En pruebas,
     * sólo en el árbol falso.
     */
    function saveForLater(profile) {
        if (root.live || Colors.schemes.indexOf(profile) < 0) return false;
        if (root.whyNot(profile).length > 0) return false;
        if (!root.testing) return Colors.setScheme(profile);
        Quickshell.execDetached(["sh", "-c", 'printf %s "$1" > "$2" && touch "$3"', "_", "scheme-" + profile,
                                 root.testRoot + "/matugen/scheme", root.testRoot + "/matugen/enabled"]);
        return true;
    }

    /**
     * 12C: las vistas que son CONTROL de la prueba (el carrusel y Settings → Theme → Colors),
     * por pantalla. Pasar de una a otra en la misma pantalla no es «cerrar sin confirmar»;
     * cerrar la última sí: entonces se vuelve a lo confirmado. Un traslado llega con el
     * propietario ya cambiado, y la pantalla vieja no revierte nada.
     */
    property var views: ({})
    function viewOpened(screen, who) {
        const t = Object.assign({}, root.views);
        const l = (t[screen] || []).filter(w => w !== who);
        l.push(who);
        t[screen] = l;
        root.views = t;
    }
    function viewClosed(screen, who) {
        const t = Object.assign({}, root.views);
        t[screen] = (t[screen] || []).filter(w => w !== who);
        root.views = t;
        closeCheck.screen = screen;
        closeCheck.restart();
    }
    Timer {
        id: closeCheck
        property string screen: ""
        // el relevo entre controles (carrusel → Settings) cambia de surface en dos pasos
        interval: 250
        onTriggered: {
            if (root.live && root.owner === closeCheck.screen
                    && (root.views[closeCheck.screen] || []).length === 0)
                root.revert("Closed without keeping");
        }
    }

    /** Retomar el control desde otra pantalla (clic, atajo, IPC): la misma operación. */
    function claim(screen) {
        return root.live && Operations.claim(root.opId, screen);
    }

    // ---- la cadena de procesos -----------------------------------------------

    function kick() {
        if (proc.running) {
            // una generación de algo que ya no se pide se descarta; un install, se espera
            if (proc.step === "stage" && proc.profile !== root.requestedKey) proc.running = false;
            return;
        }
        if (!root.live) return;
        if (root.requested.length === 0) { root.restoreWhenFree(); return; }
        if (root.requestedKey === root.previewingKey && root.phase === "active") return;
        root.phase = "preparing";
        root.preparing = root.requested;
        root.seq++;
        const o = root.normOpts(root.requested, root.requestedOpts);
        root.run("stage", ["stage", "--work", root.workBase + "/" + root.seq, "--profile", root.requested,
                           "--mode", o.lightness, "--contrast", String(o.contrast), "--source", o.source],
                 root.requestedKey);
    }

    /** Un cambio externo espera a que termine quien escribe (`settle`); lo demás, ya. */
    function restoreWhenFree() {
        if (settle.running) return;
        root.startRestore();
    }

    function startRestore() {
        root.phase = "restoring";
        root.preparing = "";
        root.run("restore", ["restore", "--snap", root.snapDir]);
    }

    function run(step, args, profile) {
        proc.step = step;
        proc.profile = profile || "";
        proc.work = step === "stage" ? root.workBase + "/" + root.seq : proc.work;
        proc.command = ["python3", root.helper].concat(args);
        proc.environment = root.env;
        proc.running = true;
    }

    Process {
        id: proc
        property string step: ""
        property string profile: ""
        property string work: ""
        stdout: StdioCollector { id: collector }
        onExited: (code, status) => root.stepDone(proc.step, proc.profile, code, collector.text)
    }

    function parse(text) {
        const lines = String(text || "").trim().split("\n");
        try { return JSON.parse(lines[lines.length - 1]); } catch (e) { return null; }
    }

    function fail(message, detail) {
        root.error = message;
        root.errorDetail = String(detail || "");
        console.warn("theme-preview:", message, root.errorDetail);
        if (!root.testing) Capabilities.suspect("theme", message);     // F2c
    }

    function stepDone(step, profile, code, text) {
        const r = root.parse(text);
        const ok = code === 0 && r && r.ok === true;
        if (step === "desktop") {
            root.desktopSyncResult = r || { desktopFailures: ["helper exited " + code] };
            if (ok) root.lastDesktopKey = profile;
            ledgerAgain.restart();
            if (root.live) root.kick();
        } else if (step === "stage") {
            if (root.requested.length === 0) { root.restoreWhenFree(); return; }     // Revert a mitad
            if (profile !== root.requestedKey) { root.kick(); return; }              // ya no se pide
            if (!ok) {
                const e = r ? r.error : "helper exited " + code;
                root.fail(e === "no-wallpaper" ? "No wallpaper: dynamic colours need one"
                          : e === "incomplete" ? "Matugen left some theme files incomplete"
                          : "Could not prepare the preview", r ? (r.detail || e) : e);
                root.preparing = "";
                // lo anterior sigue puesto (si había): la prueba sigue viva en ese estado
                root.phase = root.previewing.length > 0 ? "active" : "idle";
                if (root.previewing.length === 0) root.finish("failed", root.error);
                return;
            }
            root.run("snapshot", ["snapshot", "--snap", root.snapDir], profile);
        } else if (step === "snapshot") {
            if (!ok) {
                root.fail("Could not save the current theme", r ? r.detail || r.error : code);
                root.preparing = "";
                root.phase = root.previewing.length > 0 ? "active" : "idle";
                if (root.previewing.length === 0) root.finish("failed", root.error);
                return;
            }
            if (root.requested.length === 0) { root.restoreWhenFree(); return; }
            if (profile !== root.requestedKey) { root.kick(); return; }
            root.run("install", ["install", "--work", proc.work, "--snap", root.snapDir], profile);
        } else if (step === "install") {
            root.desktopSyncResult = r;
            root.preparing = "";
            if (!ok) {
                // a medias: lo instalado está apuntado; se vuelve a lo confirmado entero
                root.fail("Could not install the preview", r ? r.detail || r.error : code);
                root.requested = "";
                root.closeReason = "Preview failed";
                root.startRestore();
                return;
            }
            // `profile` es la clave instalada: perfil|modo|contraste|origen
            const parts = profile.split("|");
            root.previewingOpts = { lightness: parts[1], contrast: parseFloat(parts[2]), source: parts[3] };
            root.previewing = parts[0];
            root.hookFailures = r.hookFailures || [];
            root.gtkPending = r.gtk || ({});                  // F-d
            root.lightnessFrom = r.lightnessBefore || "dark";
            root.lightnessTo = r.lightness || "dark";
            root.phase = "active";
            if (root.requested.length === 0) root.restoreWhenFree();     // Revert mientras
            else if (root.requestedKey !== profile) root.kick();         // otra petición mientras
        } else if (step === "restore") {
            root.desktopSyncResult = r;
            root.previewing = "";
            if (!ok) {
                // el registro sigue en disco: Retry vuelve a intentarlo; no se afirma éxito
                root.fail("Could not restore the confirmed theme", r ? r.detail || r.error : code);
                root.phase = "failed";
                root.restoreFailed(root.owner);
                return;
            }
            root.hookFailures = r.hookFailures || [];
            const outside = (r.changedOutside || []).length;
            root.lastResult = { kind: root.closeReason === "Changed outside the preview" ? "external" : "reverted",
                                restored: (r.restored || []).length, changedOutside: outside,
                                reason: root.closeReason };
            root.finish("cancelled", root.closeReason);
        } else if (step === "keep") {
            if (!ok) {
                if (r && r.error === "changed-outside") {
                    root.closeReason = "Changed outside the preview";
                    root.startRestore();
                    return;
                }
                root.fail("Could not keep the preview", r ? r.detail || r.error : code);
                root.phase = "active";
                return;
            }
            const ch = r.change || {};
            root.lastResult = { kind: "kept", profile: r.kept, label: root.describe(root.previewing, root.previewingOpts),
                                reopen: root.reopenApps(ch.gtk, ch.lightnessBefore, ch.lightness),
                                modeChanged: ch.lightnessBefore !== ch.lightness };
            // F-c: el install de la preview ya puso el escritorio en este modo: es lo último sincronizado (si no, un
            // cambio posterior AL modo de antes —un themePreset oscuro tras Keep de uno claro— no se sincronizaba)
            root.lastDesktopKey = root.desktopKeyFor(root.previewingOpts.lightness || "dark");
            root.previewing = "";
            root.finish("completed", "Kept " + r.kept);
        } else if (step === "recover") {
            root.desktopSyncResult = r;
            root.phase = "idle";
            if (ok && r.recovered !== "none") {
                root.lastResult = { kind: "recovered", how: r.recovered,
                                    restored: (r.restored || []).length,
                                    changedOutside: (r.changedOutside || []).length };
                console.info("theme-preview: recovered a preview left by a previous run:", r.recovered);
            } else if (!ok) {
                root.fail("Could not recover the previous theme preview", r ? r.detail || r.error : code);
                root.phase = "failed";
            }
        }
    }

    function finish(state, reason) {
        if (root.live) Operations.end(root.opId, state, reason);
        const kind = state === "completed" ? "kept" : "reverted";
        root.opId = "";
        root.requested = "";
        root.preparing = "";
        root.gtkPending = ({});
        root.phase = root.phase === "failed" ? "failed" : "idle";
        // las generaciones de esta prueba ya no sirven (el registro va aparte, en snapDir)
        Quickshell.execDetached(["rm", "-rf", root.workBase]);
        root.ended(kind, state === "completed");
    }

    /** Tras un fallo de restauración: volver a intentarlo (el registro sigue en disco). */
    function retry() {
        if (root.phase !== "failed" || proc.running) return false;
        root.error = "";
        if (root.live) { root.startRestore(); return true; }
        root.phase = "recovering";
        root.run("recover", ["recover", "--snap", root.snapDir]);
        return true;
    }

    // ---- cambios externos ---------------------------------------------------

    /**
     * Fondo, esquema o sentinel cambiados por otro mientras hay prueba: no se sigue encima de
     * ellos. Se espera a que el que escribe termine (el matugen del Apply) y se repone sólo lo
     * que sigue siendo nuestro. Keep escribe esquema y sentinel: su fase lo excluye.
     */
    property string baseKey: root.baseEnabled + "|" + root.baseScheme + "|" + root.baseWall + "|" + root.confirmedKey
    onBaseKeyChanged: {
        if (!root.live || root.phase === "keeping" || root.phase === "restoring") return;
        console.info("theme-preview: changed outside the preview →", root.baseKey);
        root.requested = "";
        root.closeReason = "Changed outside the preview";
        if (proc.running && proc.step === "stage") proc.running = false;
        settle.waited = 0;
        settle.restart();
    }
    Timer {
        id: settle
        property int waited: 0
        interval: 1500
        onTriggered: {
            // el matugen de un Apply de Wallpaper todavía escribiendo: esperar (hasta 15 s)
            if (!root.testing && Wallpaper.colorsState === "updating" && settle.waited < 10) {
                settle.waited++;
                settle.restart();
                return;
            }
            if (proc.running) { settle.restart(); return; }
            if (root.live) root.startRestore();
        }
    }

    // ---- 12F: el claro/oscuro del escritorio sigue a lo confirmado ------------------

    /**
     * Si lo confirmado cambia sin prueba abierta (Keep ya lo hace; esto cubre `minimaru theme`,
     * SUPER+SHIFT+W a Static…), gsettings se alinea con su modo. Sólo en ese cambio: no se vigila
     * gsettings, así que no se pelea con quien lo cambie por otro lado. No en el arranque.
     */
    property string lastDesktopKey: ""
    readonly property string desktopLightness: root.confirmed === "static" ? "dark" : root.confirmedOpts.lightness
    onDesktopLightnessChanged: desktopSync.restart()

    // ---- F-e: a qué apps llegan los colores (la config de matugen del proveedor) -----------------------------

    /** { apps: ["kitty", "GTK 3", …], origin: own | apps | minimal } — sólo lectura (`theme-preview.py targets`). */
    property var targets: ({ apps: [], origin: "" })
    readonly property string targetsKey: JSON.stringify(root.env)
    onTargetsKeyChanged: targetsLater.restart()
    Timer { id: targetsLater; interval: 400; onTriggered: root.refreshTargets() }
    function refreshTargets() {
        if (targetsProc.running) { targetsLater.restart(); return; }
        targetsProc.command = ["env"].concat(Object.keys(root.env).map(x => x + "=" + root.env[x]))
            .concat(["python3", root.helper, "targets"]);
        targetsProc.running = true;
    }
    Process {
        id: targetsProc
        stdout: StdioCollector {
            onStreamFinished: {
                let d = null;
                try { d = JSON.parse(this.text.trim().split("\n").pop()); } catch (e) { d = null; }
                if (!d || !d.ok) { root.targets = { apps: [], origin: "" }; return; }
                const cfg = String(d.config || "");
                root.targets = { apps: d.apps || [],
                                 origin: cfg === Providers.appsConfig ? "apps"
                                       : cfg.indexOf(Quickshell.shellDir + "/templates/") === 0 ? "minimal" : "own" };
            }
        }
    }
    onProviderEnvChanged: desktopSync.restart()
    Timer {
        id: desktopSync
        interval: 800
        onTriggered: {
            const k = root.desktopKeyFor(root.desktopLightness);
            if (root.lastDesktopKey.length === 0) { root.lastDesktopKey = k; return; }   // arranque
            if (k === root.lastDesktopKey) return;
            // F-c: ocupado (un paso de la preview, un recover…) → otra vuelta; antes se perdía el turno y un
            // cambio de lo confirmado hecho fuera de la preview (themePreset) dejaba el escritorio en el modo viejo
            if (root.live) return;
            if (root.phase !== "idle" || proc.running) { desktopSync.restart(); return; }
            // El mismo proceso serializado: recoger el resultado y no perder cambios mientras está ocupado.
            root.run("desktop", ["desktop", "--lightness", root.desktopLightness], k);
        }
    }
    onTestingChanged: root.lastDesktopKey = ""        // cambiar de árbol cuenta como arrancar
    function desktopKeyFor(lightness) {
        return lightness + (root.testing ? "|t" : "") + "|" + Settings.themeDesktopSync + "|" + root.providerEnv.KT_XSETTINGS_CONFIG;
    }

    // ---- F4d (PL-04): lo que la shell cambió en el escritorio, y devolverlo ------------------

    /**
     * El registro de theme-preview.py: { sync, keys: { clave: { before, set } }, now }. Se lee al arrancar y
     * después de cada cambio del escritorio. «Restore desktop settings» devuelve cada clave a su valor de
     * antes SÓLO si sigue valiendo lo que puso la shell: lo que el usuario cambió después se queda.
     */
    property var desktopLedger: ({ keys: {} })
    property var desktopRestoreResult: null
    readonly property int desktopChanged: Object.keys(root.desktopLedger.keys || {}).length
    function refreshDesktopLedger() {
        if (ledgerProc.running) { ledgerAgain.restart(); return; }
        ledgerProc.command = ["env"].concat(Object.keys(root.env).map(x => x + "=" + root.env[x]))
            .concat(["python3", root.helper, "desktop-ledger"]);
        ledgerProc.running = true;
    }
    Timer { id: ledgerAgain; interval: 500; onTriggered: root.refreshDesktopLedger() }
    Process {
        id: ledgerProc
        stdout: StdioCollector {
            onStreamFinished: { try { root.desktopLedger = JSON.parse(this.text); } catch (e) {} }
        }
    }
    function restoreDesktop() {
        if (restoreDesktopProc.running || root.live || root.phase !== "idle") return false;
        restoreDesktopProc.command = ["env"].concat(Object.keys(root.env).map(x => x + "=" + root.env[x]))
            .concat(["python3", root.helper, "desktop-restore"]);
        restoreDesktopProc.running = true;
        return true;
    }
    Process {
        id: restoreDesktopProc
        stdout: StdioCollector {
            onStreamFinished: { try { root.desktopRestoreResult = JSON.parse(this.text); } catch (e) {} }
        }
        onExited: root.refreshDesktopLedger()
    }
    onPhaseChanged: if (root.phase === "idle") { ledgerAgain.restart(); desktopSync.restart(); }

    // ---- arranque: una preview que quedó de antes -----------------------------

    function recover() {
        if (proc.running) return;
        root.phase = "recovering";
        root.run("recover", ["recover", "--snap", root.snapDir]);
    }
    Component.onCompleted: { Qt.callLater(root.recover); desktopSync.restart(); ledgerAgain.restart(); presetsProc.running = true;
                             targetsLater.restart(); }

    // ---- el árbol de prueba -----------------------------------------------------

    FileView {
        path: root.testing ? root.testRoot + "/matugen/enabled" : ""
        watchChanges: true
        printErrors: false
        onLoaded: root.tEnabled = true
        onLoadFailed: root.tEnabled = false
        onFileChanged: reload()
    }
    FileView {
        path: root.testing ? root.testRoot + "/matugen/scheme" : ""
        watchChanges: true
        printErrors: false
        onLoaded: root.tScheme = text().trim()
        onFileChanged: reload()
    }
    FileView {
        path: root.testing ? root.testRoot + "/wall" : ""
        watchChanges: true
        printErrors: false
        onLoaded: root.tWall = text().trim()
        onFileChanged: reload()
    }

    function summary() {
        return {
            phase: root.phase, opId: root.opId, owner: root.owner, confirmed: root.confirmed,
            confirmedKey: root.confirmedKey, requestedKey: root.requestedKey, previewingKey: root.previewingKey,
            requested: root.requested, preparing: root.preparing, previewing: root.previewing,
            error: root.error, errorDetail: root.errorDetail, hookFailures: root.hookFailures,
            lastResult: root.lastResult, testing: root.testing, running: proc.running ? proc.step : "",
            views: root.views,
            // F2c: por qué no se puede ahora (vacío = se puede)
            unavailable: { dynamic: root.whyNot("tonal-spot"), static: root.whyNot("static"),
                           preset: root.presets.length > 0 ? root.whyNot(root.presetIds[0]) : "no palettes" },
            // F-c
            presets: root.presetIds, presetsLoaded: root.presetsLoaded, confirmedPreset: root.fPreset,
            // F-d
            reopenNow: root.reopenNow, lastReopen: root.lastReopen, gtkPending: root.gtkPending,
            // F-e
            targets: root.targets,
            // F4d
            provider: Providers.resolve("theme"), desktopSync: Settings.themeDesktopSync,
            desktopLedger: root.desktopLedger, desktopRestore: root.desktopRestoreResult,
            desktopKey: root.lastDesktopKey, desktopLightness: root.desktopLightness,
            desktopResult: root.desktopSyncResult
        };
    }
}
