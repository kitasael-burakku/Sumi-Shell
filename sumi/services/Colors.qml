pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/xdg.js" as Xdg

/**
 * Colour tokens, read from disk. Named `Colors`, not `Palette`: QtQuick already
 * exports a `Palette` type, and a local singleton with that name loses — the
 * binding resolves to the type and every token reads back undefined. The shell does NOT compute colours and has no
 * theme mode of its own (ADR-1, ADR-12): the rice's matugen pipeline decides
 * what is in `colors.json` — matugen writes it while the sentinel
 * `$XDG_STATE_HOME/sumi-shell/theme/enabled` is on, `apply-static-colors.sh` copies the
 * static palette over it when the toggle goes off — and the shell just
 * follows the file.
 *
 * F1a: primero $XDG_STATE_HOME/sumi-shell/colors.json; si falta o no es JSON,
 * el colors.json antiguo junto al código (transición); después colors.static.json
 * por token y finalmente magenta de diagnóstico. El shell sólo lee estas paletas.
 *
 * A missing file, a truncated write, an unparseable body or a single bad hex
 * all fall back to the static value instead of dropping the whole palette.
 * A token missing from BOTH files renders magenta on purpose: that is a
 * template/static parity break, which `check-template-parity.sh` reports.
 */
Singleton {
    id: root

    // F1a: el generado vive en estado; el archivo junto al código sólo es transición.
    readonly property string stateDir: Xdg.base(Quickshell.env("XDG_STATE_HOME"), Quickshell.env("HOME") + "/.local/state") + "/sumi-shell"
    // F1d: estado del tema; las plantillas/config.toml siguen siendo configuración.
    readonly property string themeDir: root.stateDir + "/theme"
    property bool themeStateReady: false
    readonly property string dynamicPath: root.stateDir + "/colors.json"
    readonly property string legacyPath: Quickshell.shellDir + "/colors.json"
    readonly property string staticPath: Quickshell.shellDir + "/colors.static.json"

    readonly property var dyn: dynFile.palette !== null ? dynFile.palette : (legacyFile.palette || {})
    readonly property string activePath: dynFile.palette !== null ? root.dynamicPath
        : legacyFile.palette !== null ? root.legacyPath : Object.keys(root.sta).length > 0 ? root.staticPath : ""
    property var sta: ({})

    /** Where the colours on screen actually came from; shown by the IPC status. */
    readonly property string source: {
        if (Object.keys(root.dyn).length === 0)
            return Object.keys(root.sta).length === 0 ? "builtin" : "static-file";
        if (JSON.stringify(root.dyn) === JSON.stringify(root.sta)) return "static";
        return root.presetActive ? "preset" : "dynamic";      // F-c: una paleta estática no es «dynamic»
    }

    readonly property var hexRe: /^#[0-9a-fA-F]{6}$/

    function parse(text) {
        try {
            const o = JSON.parse(text);
            return (o && typeof o === "object" && !Array.isArray(o)) ? o : null;
        } catch (e) {
            return null;
        }
    }

    /** Dynamic value if it is a valid hex, else the static one, else magenta. */
    function tok(key) {
        const d = root.dyn[key];
        if (typeof d === "string" && root.hexRe.test(d))
            return d;
        const s = root.sta[key];
        if (typeof s === "string" && root.hexRe.test(s))
            return s;
        return "#ff00ff";
    }

    readonly property color surface:                 tok("surface")
    readonly property color surfaceContainerLowest:  tok("surface_container_lowest")
    readonly property color surfaceContainerLow:     tok("surface_container_low")
    readonly property color surfaceContainer:        tok("surface_container")
    readonly property color surfaceContainerHigh:    tok("surface_container_high")
    readonly property color fg:                      tok("on_surface")
    readonly property color fgVariant:               tok("on_surface_variant")
    readonly property color outline:                 tok("outline")
    readonly property color primary:                 tok("primary")
    readonly property color fgOnPrimary:             tok("on_primary")
    readonly property color tertiary:                tok("tertiary")
    readonly property color errorColor:              tok("error")

    /**
     * Roles de Material que la paleta ya generaba y el shell no leía. Se añaden
     * para tintar la iconografía (2026-09-16): en un esquema oscuro los cuatro
     * primeros caen a la MISMA claridad —medido con `matugen --dry-run --json`
     * sobre el wallpaper actual: luminancia 0,77 los cuatro— así que se
     * distinguen por tono y no por brillo, que es justo lo que hace falta para
     * que una fila de glifos siga leyéndose como una fila.
     */
    readonly property color secondaryRole:           tok("secondary")
    readonly property color primaryFixed:            tok("primary_fixed")
    readonly property color secondaryFixed:          tok("secondary_fixed")
    readonly property color tertiaryFixed:           tok("tertiary_fixed")

    // ---- the rice's switches, reflected (never duplicated) -------------

    /**
     * The shell has no theme mode of its own (ADR-12); these mirror the rice's
     * own switches so a settings page can show the state and press the same
     * button, rather than keeping a second answer to the same question.
     */
    readonly property string riceDir: Quickshell.env("HOME") + "/.config"
    property bool dynamicEnabled: false
    property string scheme: "scheme-tonal-spot"
    /** F-c: el preset confirmado (theme/preset); sólo cuenta sin el sentinel. */
    property string preset: ""
    readonly property bool presetActive: !root.dynamicEnabled && /^[a-z0-9]+(-[a-z0-9]+)+$/.test(root.preset)
    /**
     * 10B: `scheme` y `dynamicEnabled` ya valen lo del rice (no los defaults de arriba). Lo mira
     * `WallpaperMeta` antes de apuntar el contexto de tema de un fondo.
     */
    property bool contextReady: false
    Component.onCompleted: Qt.callLater(() => root.contextReady = true)

    readonly property var schemes: [
        "content", "expressive", "fidelity", "fruit-salad", "monochrome",
        "neutral", "rainbow", "tonal-spot", "vibrant"
    ]
    readonly property string schemeShort: root.scheme.indexOf("scheme-") === 0
        ? root.scheme.substring(7) : root.scheme

    /**
     * Flip dynamic theming. F4d: el `toggle` del proveedor de tema (el del autor: su matugen_toggle.sh, los
     * mismos argv, que lo hace para todo el escritorio; el propio: sólo la paleta de la shell).
     */
    function toggleDynamic() {
        const argv = Providers.command("theme", "toggle", {});
        if (!argv) { console.warn("colors: the theme provider can't toggle ·", Providers.whyNot("theme", "toggle")); return false; }
        Quickshell.execDetached(argv);
        return true;
    }

    /**
     * Persiste el esquema y regenera. Llama a `scripts/apply-scheme` (que hace
     * lo mismo que la rama con argumento de `minimaru theme`: escribe
     * `matugen/scheme`, pone el sentinel, corre `matugen_reload.sh`) y **no** a
     * `minimaru theme` — desde 10.d ese verbo rutea de vuelta a `ipc themeSet`,
     * que llama aquí: sería un bucle. No calcula color (ADR-12/ADR-28).
     */
    function setScheme(shortName) {
        if (root.schemes.indexOf(shortName) < 0) {
            console.warn("colors: unknown scheme", shortName);
            return false;
        }
        // F2c: `apply-scheme` regenera con matugen; sin él, nada a medias
        const why = ThemePreview.whyNot(shortName);
        if (why.length > 0) { console.warn("colors: scheme not set ·", why); return false; }
        // F4d: apply-scheme escribe y luego ejecuta la orden de regenerar del proveedor (la del autor: la
        // misma que antes estaba fija dentro de apply-scheme)
        const reload = Providers.command("theme", "reload", { wall: "x" });
        Quickshell.execDetached([Quickshell.shellDir + "/scripts/apply-scheme", "scheme-" + shortName]
            .concat(reload ? ["--"].concat(reload.slice(0, -1)) : []));
        return true;
    }

    /**
     * "Ir a estatico", explicito e idempotente (ADR-28) — no un toggle. Si el
     * dinamico esta puesto, `matugen_toggle.sh` lo apaga y restaura los
     * `*.static`. Si ya esta estatico, nada. Es la rama `static` del
     * `rofi/scripts/theme.sh`.
     */
    function setStatic() {
        // F2c: `matugen_toggle.sh` pone la paleta estática con `apply-static-colors.sh`
        const why = ThemePreview.whyNot("static");
        if (why.length > 0) { console.warn("colors: static palette not set ·", why); return false; }
        if (root.dynamicEnabled)
            return root.toggleDynamic();
        // F-c: con un preset puesto, «static» es volver a Minimaru (el verbo staticApply del proveedor)
        if (root.presetActive) {
            const argv = Providers.command("theme", "staticApply", {});
            if (!argv) { console.warn("colors: the theme provider can't apply the static palette ·", Providers.whyNot("theme", "staticApply")); return false; }
            Quickshell.execDetached(argv);
        }
        return true;
    }

    /**
     * F-c: poner un preset de una vez, sin preview (IPC `themePreset`): `theme-provider.py preset <id>`, que pasa por
     * la misma transacción que la preview (todas las salidas o ninguna). El resultado se ve en `preset`/colors.json.
     */
    function setPreset(id) {
        const p = "preset:" + String(id || "");
        if (!/^[a-z0-9]+(-[a-z0-9]+)+$/.test(String(id || ""))) { console.warn("colors: not a palette id", id); return false; }
        const why = ThemePreview.whyNot(p);
        if (why.length > 0) { console.warn("colors: palette not set ·", why); return false; }
        if (ThemePreview.presetsLoaded && !ThemePreview.presetOf(p)) { console.warn("colors: unknown palette", id); return false; }
        if (root.presetActive && root.preset === id) return true;
        const argv = Providers.command("theme", "preset", { preset: String(id) });
        if (!argv) { console.warn("colors: the theme provider can't set palettes ·", Providers.whyNot("theme", "preset")); return false; }
        Quickshell.execDetached(argv);
        return true;
    }

    FileView {
        id: sentinel
        path: root.themeDir + "/enabled"
        blockLoading: true
        watchChanges: true
        printErrors: false
        onLoaded: root.dynamicEnabled = true
        onLoadFailed: root.dynamicEnabled = false
        onFileChanged: reload()
    }

    FileView {
        id: schemeFile
        path: root.themeDir + "/scheme"
        blockLoading: true
        watchChanges: true
        printErrors: false
        onLoaded: {
            const s = text().trim();
            root.scheme = s.length > 0 ? s : "scheme-tonal-spot";
        }
        onLoadFailed: root.scheme = "scheme-tonal-spot"
        onFileChanged: reload()
    }

    FileView {
        id: presetFile
        path: root.themeDir + "/preset"
        blockLoading: true
        watchChanges: true
        printErrors: false
        onLoaded: root.preset = text().trim()
        onLoadFailed: root.preset = ""
        onFileChanged: reload()
    }

    // Matugen puede truncar antes de escribir. Conservar la última lectura durante
    // tres reintentos evita un destello al estático; después se aplica el fallback.
    function readPalette(file, retryTimer) {
        const parsed = root.parse(file.text());
        if (parsed !== null) {
            file.retries = 0;
            retryTimer.stop();
            file.palette = parsed;
        } else if (file.retries < 3) {
            file.retries++;
            retryTimer.restart();
        } else {
            console.warn("colors: invalid palette, using fallback:", file.path);
            file.palette = null;
        }
    }

    // FileView no vigila la creación de un padre inexistente. Crear sólo el
    // directorio de estado y rearmar la vigilancia una vez; nunca escribir paletas.
    Process {
        command: ["mkdir", "-p", "--", root.themeDir]
        running: true
        onExited: (code, status) => {
            if (code !== 0) {
                console.warn("colors: cannot create state directory:", root.stateDir);
                return;
            }
            dynFile.watchChanges = false;
            dynFile.watchChanges = true;
            dynFile.reload();
            sentinel.watchChanges = false;
            sentinel.watchChanges = true;
            sentinel.reload();
            schemeFile.watchChanges = false;
            schemeFile.watchChanges = true;
            schemeFile.reload();
            presetFile.watchChanges = false;
            presetFile.watchChanges = true;
            presetFile.reload();
            root.themeStateReady = true;
        }
    }

    Timer { id: retry; interval: 150; onTriggered: dynFile.reload() }
    Timer { id: legacyRetry; interval: 150; onTriggered: legacyFile.reload() }

    FileView {
        id: dynFile
        property var palette: null
        property int retries: 0
        path: root.dynamicPath
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: { retries = 0; reload(); }
        onLoaded: root.readPalette(dynFile, retry)
        onLoadFailed: { retry.stop(); palette = null; }
    }

    FileView {
        id: legacyFile
        property var palette: null
        property int retries: 0
        path: root.legacyPath
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: { retries = 0; reload(); }
        onLoaded: root.readPalette(legacyFile, legacyRetry)
        onLoadFailed: { legacyRetry.stop(); palette = null; }
    }

    FileView {
        id: staticFile
        path: root.staticPath
        blockLoading: true
        watchChanges: true
        printErrors: false

        onFileChanged: reload()
        onLoaded: {
            const parsed = root.parse(text());
            root.sta = parsed !== null ? parsed : ({});
        }
        onLoadFailed: {
            console.warn("colors: colors.static.json missing — tokens without a dynamic value render magenta");
            root.sta = ({});
        }
    }
}
