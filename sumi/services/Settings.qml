pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/settings-schema.js" as Schema
import "../lib/providers-schema.js" as ProvidersSchema
import "../lib/surface-materials.js" as SurfaceMaterials
import "../lib/xdg.js" as Xdg

/**
 * Las preferencias del shell — el CONFIGSTORE del rediseño (fase 3,
 * rediseno/docs/futureSettingssurface.md §9-11).
 *
 *   $XDG_CONFIG_HOME/sumi-shell/settings.json   anidado, con schemaVersion (v2)
 *
 * Hasta el 2026-09-24 era un JSON plano en $XDG_STATE_HOME/sumi-shell/settings.json
 * (v1). Se migra UNA vez: si el nuevo no existe, se lee el viejo, se traduce clave a
 * clave (lib/settings-schema.js), se escribe el nuevo de forma atómica y se relee. El
 * viejo NO se toca ni se vuelve a observar: queda de backup.
 *
 * Un escritor: este singleton. Las superficies siguen leyendo y asignando
 * `Settings.<prop>` como siempre (los nombres no cambian); cada cambio se guarda tras
 * 300 ms, antes copiando la revisión anterior a backups/settings/ (cinco rotativas).
 *
 * Lo que NO hace nunca:
 *   · sobrescribir un archivo corrupto o de una versión futura porque se movió un
 *     control: esos estados bloquean la escritura hasta que el usuario elige;
 *   · pisar una edición externa llegada mientras había un cambio local sin guardar
 *     (estado `conflict`: Use file / Keep mine);
 *   · guardar secretos, borradores ni estado observado de otros servicios.
 *
 * Scripts: `scripts/notif-server` lee `.shell.integrations.notificationServer` de aquí.
 *
 * Al leer v2 o v3, se respalda el documento y sólo se convierte settings.json a v4.
 * Un providers.json existente determina los proveedores declarados. Importar datos
 * del escritorio anterior se pide explícitamente al instalador.
 */
Singleton {
    id: root

    // ---- las preferencias (nombres de siempre; defaults del catálogo) -------------

    property real uiScale: Schema.def("uiScale")
    property string density: Schema.def("density")
    property bool autoHide: Schema.def("autoHide")
    property bool reserveSpace: Schema.def("reserveSpace")
    /** Las piezas laterales del island y de la muesca (2026-11-12): Música y Red, cada una por su lado. */
    property bool islandMusicCircle: Schema.def("islandMusicCircle")
    property bool islandNetCircle: Schema.def("islandNetCircle")
    /** Gestos sobre la island y el notch (2026-11-17): rueda = volumen y clic medio = reproducir/pausar. */
    property string islandWheel: Schema.def("islandWheel")
    property string islandMiddleClick: Schema.def("islandMiddleClick")
    /** Notch en vivo (2026-11-17): forma, color y reposo de la muesca; y qué actividades enseña en sus orejas. */
    property string notchRest: Schema.def("notchRest")
    property string notchColor: Schema.def("notchColor")
    property string notchCorners: Schema.def("notchCorners")
    property string notchFlare: Schema.def("notchFlare")
    property bool notchActMusic: Schema.def("notchActMusic")
    /** Ondas de la oreja de música: fps de cava (0 = sintéticas). `services/Cava` lo lee. */
    property int notchVisualizerFps: Schema.def("notchVisualizerFps")
    property bool notchActRecording: Schema.def("notchActRecording")
    property bool notchActSpeed: Schema.def("notchActSpeed")
    property bool notchActWork: Schema.def("notchActWork")
    property bool notchActPower: Schema.def("notchActPower")
    property bool notchActCopy: Schema.def("notchActCopy")
    property bool notchActBluetooth: Schema.def("notchActBluetooth")
    property bool notchActWorkspace: Schema.def("notchActWorkspace")
    /** Fase 4C: el hover de un icono abre su panel en vista previa (sin teclado). */
    property bool hoverPreview: Schema.def("hoverPreview")
    /** outside · top (8G-1): el OSD con un panel abierto. */
    property string osdPlacement: Schema.def("osdPlacement")
    property int workspaceCount: Schema.def("workspaceCount")
    /** normal · reduced · off. `theme/Motion` lo lee (y su `override` de pruebas manda sobre él). */
    property string motionMode: Schema.def("motionMode")
    /** 9C-1: Global speed (0,75–1,5; >1 más rápido). `theme/Motion` lo lee. */
    property real motionSpeed: Schema.def("motionSpeed")
    /** 2026-11-11: minimalist · expressive, el estilo de las ventanas flotantes con Normal. `theme/Motion` lo lee. */
    property string windowStyle: Schema.def("windowStyle")
    /** 2026-11-19: cómo salen los paneles de la barra permanente (core/Island `drawer`); 2026-11-21, ocho estilos (ADR-40). */
    property string barPanels: Schema.def("barPanels")
    /** 2026-11-21 (ADR-40): cómo se abre la forma en la island y el notch, sin la barra. `theme/Motion` los lee. */
    property string islandStyle: Schema.def("islandStyle")
    /** 9C-2: Calendar (primer día: locale · monday · sunday; reloj 24h · 12h). */
    property string calendarFirstDay: Schema.def("calendarFirstDay")
    property string clockFormat: Schema.def("clockFormat")
    /** 9C-2: segundos de vida de un popup normal (baja urgencia: uno más). */
    property int notifPopupSec: Schema.def("notifPopupSec")
    /** 2026-11-19: dónde salen los popups (esquinas y abajo al centro) y su distancia a los bordes, en px. */
    property string notifPosition: Schema.def("notifPosition")
    property int notifMargin: Schema.def("notifMargin")
    /** 9C-2: OSD de nivel — cuánto se queda (ms) y si enseña el número. */
    property int osdMs: Schema.def("osdMs")
    property bool osdShowValue: Schema.def("osdShowValue")
    /** 9C-2: lado de la barra de desplazamiento del Launcher (left · right). */
    property string launcherScrollbar: Schema.def("launcherScrollbar")
    property string emojiAction: Schema.def("emojiAction")
    /** 9D-1: factor del tamaño del texto (Theme → Typography). */
    property real textScale: Schema.def("textScale")
    property string fontPreset: Schema.def("fontPreset")
    property string fontUi: Schema.def("fontUi")
    property string fontMono: Schema.def("fontMono")
    /** T4: destinos externos de la tipografía (todos apagados por defecto; services/FontSync los lee). */
    property bool fontSyncQt5Interface: Schema.def("fontSyncQt5Interface")
    property bool fontSyncQt5Fixed: Schema.def("fontSyncQt5Fixed")
    property bool fontSyncGtkInterface: Schema.def("fontSyncGtkInterface")
    property bool fontSyncGtkMonospace: Schema.def("fontSyncGtkMonospace")
    property bool fontSyncGtk4Interface: Schema.def("fontSyncGtk4Interface")
    property bool fontSyncQt6Interface: Schema.def("fontSyncQt6Interface")
    property bool fontSyncQt6Fixed: Schema.def("fontSyncQt6Fixed")
    property bool fontSyncKitty: Schema.def("fontSyncKitty")
    property bool fontSyncKittyReload: Schema.def("fontSyncKittyReload")
    property bool fontSyncVscodium: Schema.def("fontSyncVscodium")
    readonly property var typographySelection: ({preset:root.fontPreset, ui:root.fontUi, mono:root.fontMono})
    readonly property string typographySignature: JSON.stringify(root.typographySelection)

    // External targets have their own draft; merely browsing the panel must not save them.
    readonly property var fontSyncSelection: ({
        fontSyncGtkInterface: root.fontSyncGtkInterface, fontSyncGtkMonospace: root.fontSyncGtkMonospace,
        fontSyncGtk4Interface: root.fontSyncGtk4Interface, fontSyncQt6Interface: root.fontSyncQt6Interface,
        fontSyncQt6Fixed: root.fontSyncQt6Fixed, fontSyncKitty: root.fontSyncKitty,
        fontSyncKittyReload: root.fontSyncKittyReload, fontSyncVscodium: root.fontSyncVscodium,
        fontSyncQt5Interface: root.fontSyncQt5Interface, fontSyncQt5Fixed: root.fontSyncQt5Fixed
    })
    readonly property string fontSyncSignature: JSON.stringify(root.fontSyncSelection)
    function applyFontSync(expected, next) {
        if (!root.loaded || !root.writable || expected !== root.fontSyncSignature) return false;
        const props = Object.keys(root.fontSyncSelection);
        if (!next || Object.keys(next).length !== props.length) return false;
        for (const prop of props)
            if (!Schema.check(Schema.entryByProp(prop), next[prop]).ok) return false;
        root.applying = true;
        for (const prop of props) root[prop] = next[prop];
        root.applying = false;
        saveTimer.restart();
        return true;
    }

    // Compare the selection captured on entry; never overwrite an external font edit.
    function applyTypography(expected, next) {
        if (!root.loaded || !root.writable || expected !== root.typographySignature) return false;
        for (const pair of [["fontPreset",next.preset],["fontUi",next.ui],["fontMono",next.mono]])
            if (!Schema.check(Schema.entryByProp(pair[0]),pair[1]).ok) return false;
        root.applying = true;
        root.fontPreset = next.preset;
        root.fontUi = next.ui;
        root.fontMono = next.mono;
        root.applying = false;
        saveTimer.restart();
        return true;
    }
    /** 12D: opacidad del vidrio de las surfaces (Theme.glassBg). */
    property real glassOpacity: Schema.def("glassOpacity")
    /** Acabado independiente de la opacidad y de la paleta. */
    property string material: Schema.def("material")
    property string materialEdge: Schema.def("materialEdge")
    property bool materialShadow: Schema.def("materialShadow")
    /** 2026-10-28: { "<superficie>": { material?, opacity? } } — lo que no está se hereda de los dos de arriba. */
    property var surfaceMaterials: Schema.def("surfaceMaterials")
    /** 2026-11-14 (ADR-34): soft · terminal, y lo propio de terminal. `theme/Style` los lee. */
    property string interfaceStyle: Schema.def("interfaceStyle")
    property string termFrame: Schema.def("termFrame")
    property string termDecor: Schema.def("termDecor")
    property bool termMono: Schema.def("termMono")
    // efectos de terminal (F5, ADR-34 y ADR-23): apagados de serie; sólo cuentan con el estilo terminal (Style.fx)
    property string fxGlitch: Schema.def("fxGlitch")
    property bool fxScanlines: Schema.def("fxScanlines")
    property bool fxGlow: Schema.def("fxGlow")
    property real unloadSec: Schema.def("unloadSec")
    /** QS-FUNC-016: miniaturas en el minimizador. Apagado por defecto (ADR-14). */
    property bool minimizerThumbs: Schema.def("minimizerThumbs")
    /** Hold the idle inhibitors across restarts; mirrored into Session at startup. */
    property bool keepAwake: Schema.def("keepAwake")
    /** QS-FUNC-017: agente de polkit del shell. */
    property bool polkitAgent: Schema.def("polkitAgent")
    /**
     * ADR-29: el shell como servidor de notificaciones. SOLO SE LEE AL ARRANCAR
     * (`Notifs.enabled`); lo cambia `scripts/notif-server`, que reinicia el shell.
     */
    property bool notificationServer: Schema.def("notificationServer")
    property string lockAvatar: Schema.def("lockAvatar")
    // F5d: cómo se pide el bloqueo y la pila PAM (lib/settings-schema.js; sin migración: default «auto»)
    property string lockEntry: Schema.def("lockEntry")
    property string lockPamService: Schema.def("lockPamService")
    property string lockFetchImage: Schema.def("lockFetchImage")
    property string lockLayout: Schema.def("lockLayout")
    property bool lockWeather: Schema.def("lockWeather")
    property bool lockFetch: Schema.def("lockFetch")
    property bool lockMusic: Schema.def("lockMusic")
    property bool lockMetrics: Schema.def("lockMetrics")
    property string lockNotifications: Schema.def("lockNotifications")
    property bool wallpaperVideoPreview: Schema.def("wallpaperVideoPreview")
    /** 10A: carpetas de la biblioteca (Theme → Wallpaper → Sources) y la de descargas. */
    property var wallpaperSources: Schema.def("wallpaperSources")
    property string wallpaperDownloadDir: Schema.def("wallpaperDownloadDir")
    /** 10B: rotación (apagada por defecto) y transición de awww. */
    property bool wallRotation: Schema.def("wallRotation")
    property int wallRotationMinutes: Schema.def("wallRotationMinutes")
    property string wallRotationFrom: Schema.def("wallRotationFrom")
    property bool wallRotationPauseFullscreen: Schema.def("wallRotationPauseFullscreen")
    property bool wallRotationPauseBattery: Schema.def("wallRotationPauseBattery")
    property bool batteryAlerts: Schema.def("batteryAlerts")
    property int batteryLow: Schema.def("batteryLow")
    property int batteryVeryLow: Schema.def("batteryVeryLow")
    property int batteryCritical: Schema.def("batteryCritical")
    property bool wallRotationPauseModes: Schema.def("wallRotationPauseModes")
    property string wallTransition: Schema.def("wallTransition")
    /** 10E-1a: usuario de Wallhaven (la clave NO: va en secrets/, WallhavenAccount). */
    property string wallhavenUser: Schema.def("wallhavenUser")
    /** Destino de un atajo cuando no se sabe qué pantalla tiene el foco (fase 4D). */
    property string preferredDisplay: Schema.def("preferredDisplay")
    /** { "<modelo|serie>": { presentation: "island"|"bar", dock: bool } } — fases 8 y 9. */
    property var monitors: Schema.def("monitors")
    /** Clima (7D): apagado por defecto; ciudad `{ name, admin, country, lat, lon, tz }` o `{}`. */
    property bool weatherEnabled: Schema.def("weatherEnabled")
    property var weatherLocation: Schema.def("weatherLocation")
    property string weatherUnits: Schema.def("weatherUnits")
    /** F3a: programas del usuario («auto» = detectar). Sin consumidor hasta la F3b/F3c. */
    property string appTerminal: Schema.def("appTerminal")
    property string appTerminalExec: Schema.def("appTerminalExec")
    property string appBrowser: Schema.def("appBrowser")
    property string appLaunchScope: Schema.def("appLaunchScope")
    /** F3a: frecuencia esperada por id de tarea de tasks.json: { id: días } (sin la clave = 0). */
    property var taskEveryDays: Schema.def("taskEveryDays")
    /** F4a: el proveedor de cada función (enums; con `script`, la orden está en providers.json). */
    property string providerWallpaper: Schema.def("providerWallpaper")
    property string providerTheme: Schema.def("providerTheme")
    property string providerThumbnails: Schema.def("providerThumbnails")
    property string providerUpdates: Schema.def("providerUpdates")
    /** F4a (PL-04): off · colorScheme · full. Consumidor en F4d. */
    property string themeDesktopSync: Schema.def("themeDesktopSync")
    /** Apariencia (2026-11-13): iconos y cursor que la shell quiere en las apps; se escriben tras un Apply (Appearance). */
    property string iconTheme: Schema.def("iconTheme")
    property bool iconFollowMode: Schema.def("iconFollowMode")
    property string cursorTheme: Schema.def("cursorTheme")
    property int cursorSize: Schema.def("cursorSize")
    /** Grabador 2.0 (2026-10-29): Settings → Screen recording; la surface edita los mismos (ver el catálogo). */
    property string recPreset: Schema.def("recPreset")
    property string recEncoder: Schema.def("recEncoder")
    property int recFps: Schema.def("recFps")
    property string recQuality: Schema.def("recQuality")
    property int recBitrate: Schema.def("recBitrate")
    property int recHeight: Schema.def("recHeight")
    property string recFormat: Schema.def("recFormat")
    property bool recSystemAudio: Schema.def("recSystemAudio")
    property bool recMic: Schema.def("recMic")
    property string recSystemSource: Schema.def("recSystemSource")
    property string recMicSource: Schema.def("recMicSource")
    property string recAudioCodec: Schema.def("recAudioCodec")
    property int recAudioBitrate: Schema.def("recAudioBitrate")
    property int recSampleRate: Schema.def("recSampleRate")
    property string recDir: Schema.def("recDir")
    property string recName: Schema.def("recName")
    property int recDelay: Schema.def("recDelay")
    property bool recIndicator: Schema.def("recIndicator")
    property bool recTimer: Schema.def("recTimer")
    property bool recIslandControls: Schema.def("recIslandControls")
    property bool recBarControls: Schema.def("recBarControls")
    property bool recNotify: Schema.def("recNotify")
    property bool recOpenFolder: Schema.def("recOpenFolder")
    property bool recRememberMode: Schema.def("recRememberMode")
    /** El reproductor del Mixer (2026-11-09): fondo, forma de la carátula y tiempo final. */
    property string mediaBackdrop: Schema.def("mediaBackdrop")
    property string mediaCoverShape: Schema.def("mediaCoverShape")
    property string mediaEndTime: Schema.def("mediaEndTime")

    // ---- F3a: la frecuencia de una tarea (F3d-2: ya sin las dos propiedades de antes) ----
    function taskEvery(id) {
        const v = root.taskEveryDays ? root.taskEveryDays[id] : undefined;
        return typeof v === "number" ? v : 0;
    }
    function setTaskEvery(id, days) {
        if (root.taskEvery(id) === days) return;
        const next = Object.assign({}, root.taskEveryDays);
        if (days > 0) next[id] = days;
        else delete next[id];
        root.taskEveryDays = next;
    }

    // ---- material por superficie (Theme → Material → Surfaces) ---------------------
    /** Lo propio de una superficie: { material?, opacity? } ({} = hereda las dos). */
    function surfaceOverride(key) { return SurfaceMaterials.overrideOf(root.surfaceMaterials, key); }
    /** Pone (o quita, con `undefined`) una propiedad de una superficie; las demás no se tocan. */
    function setSurfaceMaterial(key, field, value) {
        if (field !== "material" && field !== "opacity") return;
        if (JSON.stringify(root.surfaceOverride(key)[field]) === JSON.stringify(value)) return;
        root.surfaceMaterials = SurfaceMaterials.withField(root.surfaceMaterials, key, field, value);
    }
    function resetSurface(key) {
        if (root.surfaceOverride(key).material === undefined && root.surfaceOverride(key).opacity === undefined) return;
        root.surfaceMaterials = SurfaceMaterials.without(root.surfaceMaterials, key);
    }

    /** Compatibilidad: quien preguntaba «¿reduce motion?» sigue pudiendo. Sólo lectura. */
    readonly property bool reduceMotion: root.motionMode !== "normal"

    /**
     * El documento ya se leyó (o migró) y las propiedades valen lo guardado. Sólo lo
     * necesita quien lee un ajuste UNA vez (`Notifs.enabled`).
     */
    property bool loaded: false

    // ---- dónde -------------------------------------------------------------------

    readonly property string stateDir: Xdg.base(Quickshell.env("XDG_STATE_HOME"), Quickshell.env("HOME") + "/.local/state") + "/sumi-shell"
    readonly property string configHome: Xdg.base(Quickshell.env("XDG_CONFIG_HOME"), Quickshell.env("HOME") + "/.config")
    readonly property string configDir: root.configHome + "/sumi-shell"
    readonly property string configPath: root.configDir + "/settings.json"
    readonly property string legacyPath: root.stateDir + "/settings.json"
    readonly property string backupDir: root.stateDir + "/backups/settings"
    /** Configuración de proveedores externos (lib/providers-schema.js), administrada por el usuario. */
    readonly property string providersPath: root.configDir + "/providers.json"

    // ---- estado del almacén --------------------------------------------------------

    /**
     * ready · invalid (no se puede leer: JSON roto, estructura, permisos) · newer (versión
     * futura: sólo lectura) · conflict (edición externa con un cambio local pendiente) ·
     * saveFailed · upgrading (F3a/F4a: copiando el v2 o el v3 antes de actualizarlo). Todo lo que no es
     * `ready` o `saveFailed` bloquea la escritura.
     */
    property string status: "ready"
    /** Frase para la UI (inglés), vacía en `ready`. */
    property string statusText: ""
    /** Lo rechazado campo a campo: [{ id, error }]. */
    property var fieldErrors: []
    /** Aviso informativo de una vez (la migración). */
    property string note: ""
    readonly property bool writable: root.status === "ready" || root.status === "saveFailed"

    /** El último documento válido que se leyó o escribió, en texto y parseado. */
    property string lastGoodText: ""
    property var baseDoc: null

    property bool applying: false
    property bool retried: false
    property string conflictText: ""
    property string pendingText: ""

    // ---- API -----------------------------------------------------------------------

    function values() {
        const v = {};
        for (let i = 0; i < Schema.CATALOG.length; i++) {
            const p = Schema.CATALOG[i].prop;
            v[p] = root[p];
        }
        return v;
    }

    function isCustom(prop) {
        return !Schema.isDefault(prop, root[prop]);
    }

    function resetField(prop) {
        const d = Schema.def(prop);
        if (d !== undefined) root[prop] = d;
    }

    /** Todos los de una sección de la página Shell. Devuelve cuántos cambió. */
    function resetSection(section) {
        const props = Schema.propsInSection(section);
        let n = 0;
        for (let i = 0; i < props.length; i++)
            if (root.isCustom(props[i])) { root.resetField(props[i]); n++; }
        return n;
    }

    function customInSection(section) {
        const props = Schema.propsInSection(section);
        let n = 0;
        for (let i = 0; i < props.length; i++) if (root.isCustom(props[i])) n++;
        return n;
    }

    /** Identidad estable de una salida: modelo|serie; el conector sólo si no hay más. */
    function monitorId(screen) {
        if (!screen) return "";
        const model = screen.model || "";
        const serial = screen.serialNumber || "";
        return (model.length > 0 || serial.length > 0) ? model + "|" + serial : (screen.name || "");
    }
    function monitorPref(screen, key, fallback) {
        const m = root.monitors[root.monitorId(screen)];
        return (m && m[key] !== undefined) ? m[key] : fallback;
    }
    function setMonitorPref(screen, key, value) {
        const id = root.monitorId(screen);
        if (id.length === 0) return;
        const next = JSON.parse(JSON.stringify(root.monitors));
        next[id] = next[id] || {};
        next[id][key] = value;
        root.monitors = next;
    }
    /** Quitar claves de una salida (vuelven a las de serie): Reset de la barra en Settings → Shell → Layout. */
    function clearMonitorPrefs(screen, keys) {
        const id = root.monitorId(screen);
        if (id.length === 0 || !root.monitors[id]) return;
        const next = JSON.parse(JSON.stringify(root.monitors));
        for (let i = 0; i < keys.length; i++) delete next[id][keys[i]];
        root.monitors = next;
    }

    /** Volver a leer el archivo (Retry). */
    function retry() {
        root.retried = false;
        file.reload();
    }

    /** Escribir la última revisión válida conocida (en memoria) encima de lo que haya. */
    function restoreLastGood() {
        if (root.lastGoodText.length === 0) return false;
        root.handleValid(root.lastGoodText, JSON.parse(root.lastGoodText));
        root.forceWrite(root.lastGoodText, "Restored the last good settings");
        return true;
    }

    /** La revisión anterior guardada en backups/settings/ (la más reciente). */
    function restorePrevious() {
        const slot = root.backupOrder.length > 0 ? root.backupOrder[0] : 0;
        if (slot === 0) { root.note = "No previous revision to restore"; return false; }
        backupReader.path = root.backupDir + "/settings." + slot + ".json";
        backupReader.reload();
        let t = backupReader.text();
        let d;
        try { d = JSON.parse(t); } catch (e) { root.note = "The previous revision is not valid JSON"; return false; }
        if (Schema.validate(d).structure.length > 0) { root.note = "The previous revision is not usable"; return false; }
        // F3a/F4a: una revisión v2 o v3 se actualiza en memoria (lo que pisa ya va a la copia rotativa),
        // con los tipos que declara HOY providers.json (aquí no se siembra nada)
        if (d.schemaVersion === 2 || d.schemaVersion === 3) {
            d = root.upgradeDoc(d, backupReader.path, root.declaredProviders()).doc;
            t = Schema.serialize(d);
        }
        root.handleValid(t, d);
        root.forceWrite(t, "Restored the previous revision");
        return true;
    }

    /** Defaults. El archivo que hubiera (aunque esté roto) se copia antes a backups. */
    function restoreDefaults() {
        const t = Schema.serialize(Schema.defaults());
        root.handleValid(t, JSON.parse(t));
        root.forceWrite(t, "Restored the default settings");
    }

    /** Conflicto: adoptar lo que hay en disco y descartar el cambio local. */
    function useFile() {
        saveTimer.stop();
        const t = root.conflictText;
        root.conflictText = "";
        root.status = "ready";
        root.handleText(t, true);
    }
    /** Conflicto: guardar lo mío encima (lo de disco va antes a backups). */
    function keepMine() {
        root.conflictText = "";
        const t = Schema.serialize(Schema.build(root.baseDoc, root.values()));
        root.forceWrite(t, "");
    }

    // ---- leer ----------------------------------------------------------------------

    function applyValues(v) {
        root.applying = true;
        for (const p in v) if (root[p] !== undefined || p in root) root[p] = v[p];
        root.applying = false;
    }

    function setStatus(s, text) {
        root.status = s;
        root.statusText = text;
    }

    /** Un documento v2 que se puede usar: valores, base para reescribir, estado. */
    function handleValid(text, doc) {
        const r = Schema.validate(doc);
        root.applyValues(r.values);
        root.baseDoc = doc;
        root.fieldErrors = r.errors;
        if (r.newer) {
            root.setStatus("newer", "Configuration from a newer version — read only");
        } else {
            root.lastGoodText = text;
            root.setStatus("ready", "");
        }
        if (r.errors.length > 0)
            console.warn("settings: rejected " + r.errors.map(e => e.id + " (" + e.error + ")").join(", "));
    }

    function handleText(text, adopt) {
        if (root.queuedText && text === root.expectedDiskText) return;  // se releyó la misma revisión
        if (!adopt && text === root.lastGoodText && root.status === "ready") return;   // el eco de nuestra propia escritura
        if (saveTimer.running || root.queuedText.length > 0 || root.status === "conflict") {
            // Hay un cambio local sin guardar y el archivo cambió por fuera: no se pisa.
            root.queuedText = "";
            root.conflictText = text;
            root.setStatus("conflict", "Settings changed on disk while you were editing");
            return;
        }
        let doc;
        try { doc = JSON.parse(text); } catch (e) { root.handleInvalid(text, "not valid JSON"); return; }
        const r = Schema.validate(doc);
        if (r.structure.length > 0) { root.handleInvalid(text, r.structure); return; }
        root.retried = false;
        if (doc.schemaVersion === 2 || doc.schemaVersion === 3) { root.upgradeFromDisk(text, doc); return; }     // F3a/F4a
        root.handleValid(text, doc);
    }

    // ---- F3a: v2 → v3; F4a: v3 → v4 ---------------------------------------------------

    property var upgradeJob: null
    property int upgradeAttempt: 0

    function upgradeDoc(doc, backup, declared) {
        return Schema.upgrade(doc, {
            at: new Date().toISOString(), backup: backup, declared: declared
        });
    }

    function pad2(n) { return (n < 10 ? "0" : "") + n; }

    /**
     * El archivo en disco es v2. Mientras se copia: los valores del v2 (la shell funciona igual) y
     * nada se escribe. Si la copia no sale, el archivo se queda como estaba y Settings lo dice.
     * F4a: lo mismo con un v3. Mientras dura (`status` = upgrading), providers.* y desktopSync valen sus
     * defaults de v4 (auto, off), no lo que dejará la migración: un consumidor de esos ajustes (F4b–F4e)
     * no actúa hasta que `status` deja de ser «upgrading».
     */
    function upgradeFromDisk(text, doc) {
        const r = Schema.validate(doc);
        root.applyValues(r.values);
        root.baseDoc = doc;
        if (upgradeCopy.running) return;      // otra lectura mientras copiamos: la copia lo comprueba
        root.setStatus("upgrading", "Upgrading the settings file…");
        const d = new Date();
        const stamp = d.getFullYear() + root.pad2(d.getMonth() + 1) + root.pad2(d.getDate()) + "-"
            + root.pad2(d.getHours()) + root.pad2(d.getMinutes()) + root.pad2(d.getSeconds());
        const backup = root.backupDir + "/settings.v" + doc.schemaVersion + "-premigration-" + stamp
            + "-" + Quickshell.processId + "-" + (++root.upgradeAttempt) + ".json";
        root.upgradeJob = { text: text, doc: doc, backup: backup };
        upgradeCopy.command = ["install", "-D", "-m", "0600", root.configPath, backup];
        upgradeCopy.running = true;
    }

    Process {
        id: upgradeCopy
        onExited: (code) => {
            const job = root.upgradeJob;
            root.upgradeJob = null;
            if (!job) return;
            if (code !== 0) {
                console.warn("settings: could not copy the v" + job.doc.schemaVersion + " file before upgrading it (" + code + "); left as it was");
                root.setStatus("invalid", "Couldn't back up settings before upgrading; the file is untouched");
                return;
            }
            // La copia tiene que ser lo que leímos: si el archivo cambió entretanto, se relee y vuelta a empezar
            backupReader.path = job.backup;
            backupReader.reload();
            if (backupReader.text() !== job.text) {
                console.warn("settings: the file changed while it was being copied; reading it again");
                root.retried = false;
                file.reload();
                return;
            }
            migrationInput.reload();
            if (migrationInput.text() !== job.text) {
                root.retried = false;
                file.reload();
                return;
            }
            const declared = root.declaredProviders();
            const from = job.doc.schemaVersion;
            const up = root.upgradeDoc(job.doc, job.backup, declared);
            const v = Schema.validate(up.doc);
            if (!up.changed || v.structure.length > 0 || v.newer) {
                root.setStatus("invalid", "Could not upgrade the settings file; it was left as it was");
                return;
            }
            const t4 = Schema.serialize(up.doc);
            root.handleValid(t4, up.doc);
            root.fieldErrors = root.fieldErrors.concat(up.errors);
            root.note = "Settings upgraded to version " + Schema.VERSION + " · the previous file was copied to " + job.backup;
            console.log("settings: upgraded v" + from + " → v" + Schema.VERSION + "; copy at " + job.backup
                        + (declared.length > 0 ? "; providers from providers.json: " + declared.join(", ") : ""));
            root.pendingText = t4;
            file.setText(t4);
        }
    }

    readonly property string home: Quickshell.env("HOME") || ""

    FileView {
        id: migrationInput
        path: root.configPath
        preload: false
        blockAllReads: true
        watchChanges: false
        printErrors: false
    }

    /** Los tipos válidos de providers.json en disco, leídos ahora (sin permisos: eso lo juzga Providers). */
    property bool providersMissing: false
    function declaredProviders() {
        providersProbe.reload();
        const t = providersProbe.text() || "";      // con blockAllReads la lectura ocurre aquí
        if (root.providersMissing || t.length === 0) return [];
        let doc;
        try { doc = JSON.parse(t); } catch (e) { return []; }
        const r = ProvidersSchema.validate(doc, root.home);
        return r.structure.length > 0 ? [] : Object.keys(r.providers);
    }
    FileView {
        id: providersProbe
        path: root.providersPath
        preload: false
        blockAllReads: true
        watchChanges: false
        printErrors: false
        onLoaded: root.providersMissing = false
        onLoadFailed: root.providersMissing = true
    }

    // ---- F3a: carpetas de una configuración nueva (H-33) ------------------------------

    property bool userDirsMissing: false
    FileView {
        id: userDirs
        path: root.configHome + "/user-dirs.dirs"
        preload: false
        blockAllReads: true
        watchChanges: false
        printErrors: false
        onLoaded: root.userDirsMissing = false
        onLoadFailed: root.userDirsMissing = true
    }

    /** XDG_PICTURES_DIR / XDG_VIDEOS_DIR de user-dirs.dirs como ~/… ("" si no hay). Sin procesos. */
    function userDir(text, key) {
        const m = new RegExp("^\\s*" + key + "\\s*=\\s*\"([^\"]*)\"", "m").exec(text);
        if (!m) return "";
        let v = m[1];
        if (v.indexOf("$HOME/") === 0) v = "~/" + v.substring(6);
        else if (v.charAt(0) !== "/") return "";
        return v.replace(/\/+$/, "");
    }

    /** Sólo cambia lo que siga en el default compilado; el resto lo ha decidido alguien. */
    function seedUserDirs(doc) {
        userDirs.reload();
        const t = userDirs.text() || "";          // leer antes de mirar el indicador (ver migrate)
        if (root.userDirsMissing) return;
        const pics = root.userDir(t, "XDG_PICTURES_DIR");
        const vids = root.userDir(t, "XDG_VIDEOS_DIR");
        const srcId = "theme.wallpaper.sources", dlId = "theme.wallpaper.downloadDir";
        const src = Schema.getPath(doc, srcId);
        if (JSON.stringify(src) === JSON.stringify(Schema.def("wallpaperSources"))) {
            const next = [pics.length > 0 ? pics + "/Wallpapers" : src[0], vids.length > 0 ? vids + "/Wallpapers" : src[1]];
            Schema.setPath(doc, srcId, next);
        }
        if (pics.length > 0 && Schema.getPath(doc, dlId) === Schema.def("wallpaperDownloadDir"))
            Schema.setPath(doc, dlId, pics + "/Wallpapers");
    }

    /**
     * Ilegible. Primero se reintenta una vez (puede ser una escritura a medias de otro);
     * si sigue, se guarda una copia de diagnóstico y se sigue con lo último válido.
     */
    function handleInvalid(text, why) {
        if (!root.retried) {
            root.retried = true;
            retryTimer.restart();
            return;
        }
        console.warn("settings: " + root.configPath + " is invalid (" + why + "); keeping the last good values");
        root.setStatus("invalid", "Settings file could not be read: " + why);
        diagCopy.command = ["install", "-D", "-m", "0600", root.configPath,
                            root.backupDir + "/settings.invalid-" + Date.now() + ".json"];
        diagCopy.running = true;
        root.loaded = true;
    }

    Timer { id: retryTimer; interval: 150; onTriggered: file.reload() }
    Process { id: diagCopy }

    /** v1 → v2, una vez: el archivo nuevo no existe. */
    function migrate() {
        legacy.reload();
        // F3a: con blockAllReads la lectura (y su onLoaded/onLoadFailed) ocurre al pedir text(), no
        // en reload(): hay que leer ANTES de mirar `legacyMissing`. Antes se miraba primero y una
        // configuración nueva decía «The old settings file could not be read» (medido en el banco).
        const legacyText = legacy.text() || "";
        let doc = null;
        if (root.legacyMissing) {
            doc = Schema.defaults();
            root.note = "";
            root.seedUserDirs(doc);      // F3a (H-33): una configuración nueva usa las carpetas del idioma
        } else {
            let old = null;
            try { old = JSON.parse(legacyText); } catch (e) { old = null; }
            if (old === null) {
                doc = Schema.defaults();
                root.note = "Couldn't read the old settings file; using defaults (file untouched)";
            } else {
                const m = Schema.migrateFlat(old);
                doc = m.doc;
                root.seedUserDirs(doc);
                root.fieldErrors = m.errors;
                root.note = "Settings moved to ~/.config/sumi-shell/settings.json";
            }
        }
        const text = Schema.serialize(doc);
        root.applyValues(Schema.validate(doc).values);
        root.baseDoc = doc;
        root.loaded = true;
        console.log("settings: migrated " + root.legacyPath + " → " + root.configPath);
        root.pendingText = text;
        file.setText(text);
    }

    property bool legacyMissing: false
    property bool migrateQueued: false

    /**
     * El archivo desapareció con la sesión en marcha: reintentos cortos (~1,5 s) por si lo
     * están sustituyendo, y después se recrea desde los valores en memoria, con aviso. Nunca
     * desde el v1.
     */
    property int missingTries: 0
    Timer { id: missingTimer; interval: 250; onTriggered: file.reload() }
    function fileMissing() {
        if (root.missingTries < 6) {
            root.missingTries++;
            missingTimer.restart();
            return;
        }
        root.missingTries = 0;
        console.warn("settings: " + root.configPath + " went missing; recreating it from the values in use");
        root.forceWrite(Schema.serialize(Schema.build(root.baseDoc, root.values())),
                        "The settings file was missing; it was recreated from the values in use");
    }

    FileView {
        id: legacy
        path: root.legacyPath
        preload: false
        blockAllReads: true
        watchChanges: false
        printErrors: false
        onLoaded: root.legacyMissing = false
        onLoadFailed: root.legacyMissing = true
    }

    FileView {
        id: file
        path: root.configPath
        blockLoading: true
        watchChanges: true
        atomicWrites: true
        printErrors: false

        // La escritura atómica (la nuestra, la de un editor, el `mv` de notif-server)
        // SUSTITUYE el inodo, y el vigilante sigue al viejo (memoria del proyecto: «la
        // recarga pierde archivos sustituidos»). Medido en la sonda de la fase 3: tras el
        // primer guardado, una edición externa ya no se veía. Se rearma cada vez.
        onFileChanged: { reload(); root.rearm(); }
        onLoaded: {
            root.missingTries = 0;
            const text = file.text();
            root.diskText = text;
            root.handleText(text);
            root.loaded = true;
        }
        onLoadFailed: (error) => {
            if (error === FileViewError.FileNotFound) {
                root.diskText = null;
                // La migración v1 → v2 es SÓLO de la primera carga. Si el archivo desaparece
                // con los ajustes ya cargados (un `install` o un editor que borra y vuelve a
                // crear; el vigilante recarga justo en el hueco), migrar escribía el v1
                // CONGELADO encima de los ajustes del usuario (pasó el 2026-09-26, tras la
                // fase 9). Ahora se espera a que vuelva y, si no vuelve, se recrea con los
                // valores en uso.
                // F3b: un ciclo DESPUÉS, fuera de este aviso. Escribir el archivo nuevo desde dentro de
                // la carga fallida de esta misma FileView perdía su operación («dropped operation»): no
                // llegaba `saved`, el vigilante no se rearmaba y una configuración NUEVA no veía nunca
                // una edición externa hasta el primer guardado propio (medido en el banco, también con
                // el código anterior a F3). Aplazado: llega `saved` y las ediciones externas se aplican.
                if (!root.loaded) {
                    if (!root.migrateQueued) { root.migrateQueued = true; Qt.callLater(root.migrate); }
                    return;
                }
                root.fileMissing();
                return;
            }
            root.setStatus("invalid", error === FileViewError.PermissionDenied
                ? "Settings file could not be read: permission denied"
                : "Settings file could not be read");
            root.loaded = true;
        }
        onSaved: {
            root.rearm();
            root.diskText = root.pendingText;
            root.lastGoodText = root.pendingText;
            root.baseDoc = JSON.parse(root.pendingText);
            if (root.status === "saveFailed" || root.status === "invalid" || root.status === "conflict")
                root.setStatus("ready", "");
        }
        onSaveFailed: (error) => {
            root.setStatus("saveFailed", error === FileViewError.PermissionDenied
                ? "Could not save settings: permission denied" : "Could not save settings");
            console.warn("settings: save failed (" + error + ")");
        }
    }

    function rearm() {
        Qt.callLater(function () {
            file.watchChanges = false;
            file.watchChanges = true;
        });
    }

    // ---- escribir ------------------------------------------------------------------

    /**
     * Cualquier cambio de valor pasa por aquí (un binding sobre todos). Sale del CATÁLOGO: era
     * una lista escrita a mano y un ajuste nuevo que no se añadiera no se guardaba nunca (le pasó
     * a `glassOpacity` en la 12D: cambiaba en pantalla y no llegaba al archivo).
     */
    readonly property var snapshot: Schema.CATALOG.map(e => root[e.prop])
    onSnapshotChanged: {
        if (root.applying || !root.loaded) return;
        saveTimer.restart();
    }

    /** Los sliders y los toggles repetidos se agrupan: 300 ms sin cambios y se guarda. */
    Timer {
        id: saveTimer
        interval: 300
        onTriggered: root.save()
    }

    function save() {
        if (!root.writable) return;   // inválido / versión futura / conflicto: no se escribe
        const text = Schema.serialize(Schema.build(root.baseDoc, root.values()));
        if (text === root.lastGoodText && root.diskText === text) {
            root.queuedText = "";   // se deshizo el cambio mientras corría su copia
            return;
        }
        root.startWrite(text);
    }

    /** Escribir aunque el estado bloquee: sólo por una acción explícita del usuario. */
    function forceWrite(text, message) {
        saveTimer.stop();
        root.note = message;
        root.startWrite(text);
    }

    // Copia de la revisión en disco antes de reemplazarla: 1…5, rotando por antigüedad.
    property var backupOrder: []   // ranuras, la más reciente primero
    property string queuedText: ""
    // Texto observado en disco, también si es inválido. Una restauración puede
    // haber cambiado lastGoodText en memoria antes de que acabe la copia.
    property var diskText: null
    property var expectedDiskText: null

    function nextSlot() {
        for (let s = 1; s <= 5; s++) if (root.backupOrder.indexOf(s) < 0) return s;
        return root.backupOrder[root.backupOrder.length - 1];
    }

    function startWrite(text) {
        root.queuedText = text;
        root.expectedDiskText = root.diskText;
        if (backupProc.running) return;
        const slot = root.nextSlot();
        backupProc.began = false;
        backupProc.slot = slot;
        backupProc.sourceText = root.expectedDiskText;
        backupProc.command = ["install", "-D", "-m", "0600", root.configPath,
                              root.backupDir + "/settings." + slot + ".json"];
        backupProc.running = true;
    }

    Process {
        id: backupProc
        property int slot: 0
        property var sourceText: null
        property bool began: false
        onStarted: began = true
        onRunningChanged: if (!running && !began && root.queuedText) {
            root.queuedText = "";
            root.setStatus("saveFailed", "Could not start the settings backup");
        }
        onExited: (code) => {
            if (code === 0)
                root.backupOrder = [backupProc.slot].concat(root.backupOrder.filter(s => s !== backupProc.slot));
            const text = root.queuedText;
            root.queuedText = "";
            if (!text) return;   // una lectura externa canceló esta escritura
            if (root.expectedDiskText !== backupProc.sourceText) {
                // Keep mine pudo llegar mientras aún se copiaba otra revisión.
                root.startWrite(text);
                return;
            }
            diskCheck.reload();
            const current = diskCheck.text();
            if (diskCheck.errorCode !== FileViewError.Success && diskCheck.errorCode !== FileViewError.FileNotFound) {
                root.setStatus("saveFailed", "Could not verify the settings on disk");
                return;
            }
            if (diskCheck.errorCode === FileViewError.FileNotFound) {
                if (root.expectedDiskText !== null) { file.reload(); return; }
            } else {
                if (current !== root.expectedDiskText) {
                    root.diskText = current;
                    root.conflictText = current;
                    root.setStatus("conflict", "Settings changed on disk while you were editing");
                    return;
                }
                if (code !== 0) {
                    root.setStatus("saveFailed", "Could not back up the current settings");
                    return;
                }
            }
            root.pendingText = text;
            file.setText(text);
        }
    }

    FileView {
        id: diskCheck
        path: root.configPath
        preload: false
        blockAllReads: true
        printErrors: false
        property int errorCode: FileViewError.Success
        onLoaded: errorCode = FileViewError.Success
        onLoadFailed: (error) => errorCode = error
    }

    Process {
        id: backupList
        // Sin shell: la ruta es un argumento. Si el directorio no existe, `ls` falla y no hay ranuras.
        command: ["ls", "-1t", "--", root.backupDir]
        stdout: StdioCollector {
            onStreamFinished: {
                const order = [];
                const lines = this.text.split("\n");
                for (let i = 0; i < lines.length; i++) {
                    const m = /^settings\.([1-5])\.json$/.exec(lines[i]);
                    if (m) order.push(parseInt(m[1]));
                }
                root.backupOrder = order;
            }
        }
    }

    FileView {
        id: backupReader
        preload: false
        blockAllReads: true
        printErrors: false
    }

    Component.onCompleted: backupList.running = true

    function summary() {
        return {
            status: root.status, statusText: root.statusText, note: root.note,
            configPath: root.configPath, fieldErrors: root.fieldErrors,
            backups: root.backupOrder, motionMode: root.motionMode,
            // F3a
            schemaVersion: root.baseDoc ? root.baseDoc.schemaVersion : 0,
            migrations: root.baseDoc && Array.isArray(root.baseDoc.migrations) ? root.baseDoc.migrations : [],
            seeded: [], apps: { terminal: root.appTerminal, terminalExec: root.appTerminalExec,
                                         browser: root.appBrowser, launchScope: root.appLaunchScope },
            taskEveryDays: root.taskEveryDays,
            // F4a
            seededProviders: [],
            providers: { wallpaper: root.providerWallpaper, theme: root.providerTheme, thumbnails: root.providerThumbnails,
                         updates: root.providerUpdates, desktopSync: root.themeDesktopSync }
        };
    }
}
