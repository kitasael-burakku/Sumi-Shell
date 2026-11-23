pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/xdg.js" as Xdg

/**
 * Wallpapers. The shell never runs awww or mpvpaper itself: every apply goes
 * through the rice's `apply-wallpaper.sh`, the same door rofi, fish and
 * `wallpaper.service` use (ADR-3). That script owns the backend flags, writes
 * `.current-wallpaper` and regenerates hyprlock's background; matugen is
 * kicked afterwards exactly as `wallpaper_grid.sh` does it.
 *
 * 10A (rediseño): UN inventario para Wallpaper List y Settings → Theme → Wallpaper, sobre
 * las carpetas de Sources (`Settings.wallpaperSources`; por defecto las dos de siempre,
 * `~/Pictures/Wallpapers` y `~/Videos/Wallpapers`). Cada carpeta se escanea a UN nivel y el
 * tipo lo da la extensión (antes lo daba la carpeta; con las dos de siempre sale lo mismo:
 * ninguna tenía archivos del otro tipo, medido el 2026-09-26). La lista se deja en
 * `$XDG_STATE_HOME/sumi-shell/wallpaper-sources` para que `generate-thumbs.sh` genere y
 * pode las miniaturas de las mismas carpetas: el shell sigue sin escribir ninguna.
 */
/*
 * Portabilidad F4b (2026-10-07): «el rice» es ahora un proveedor más. Aplicar, una pantalla, --clear,
 * --sync y restaurar salen de `Providers` (providers.wallpaper): el `apply-wallpaper.sh` del autor como
 * proveedor `script` (mismos argv; tools/f4/argv-before.json) o el propio de la shell
 * (scripts/wallpaper-provider.py, mismo contrato). Con el propio, la shell restaura el fondo al arrancar
 * (el del autor lo hace wallpaper.service) y reconcilia en cada cambio de pantallas (awww deja en negro
 * una salida nueva: medido). Lo de abajo que nombra apply-wallpaper.sh es su historia.
 */
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME")
    /** `~/…` → absoluta; sin barra final. Vacía si no es local. */
    function expand(p) {
        let v = String(p || "").trim();
        if (v === "~") v = root.home;
        else if (v.indexOf("~/") === 0) v = root.home + v.substring(1);
        if (v.charAt(0) !== "/") return "";
        while (v.length > 1 && v.charAt(v.length - 1) === "/") v = v.substring(0, v.length - 1);
        return v;
    }
    /** `$HOME/…` → `~/…`, para enseñar una ruta. */
    function pretty(p) {
        const v = String(p || "");
        return v === root.home ? "~" : v.indexOf(root.home + "/") === 0 ? "~" + v.substring(root.home.length) : v;
    }

    /** Las carpetas de Sources, absolutas y sin repetir, en el orden de Settings. */
    readonly property var sourceDirs: {
        const out = [];
        const l = Settings.wallpaperSources || [];
        for (let i = 0; i < l.length; i++) {
            const d = root.expand(l[i]);
            if (d.length > 0 && out.indexOf(d) < 0) out.push(d);
        }
        return out;
    }
    readonly property string downloadDir: root.expand(Settings.wallpaperDownloadDir)
    /**
     * Temporales de las descargas (fase 10D): FUERA de la biblioteca, para que el escaneo no los
     * vea nunca. Una carpeta de Sources no puede estar dentro.
     */
    readonly property string tempDir: Xdg.base(Quickshell.env("XDG_CACHE_HOME"), root.home + "/.cache") + "/sumi-shell"

    /**
     * Estado de cada carpeta tras el último escaneo:
     * [{ dir, status: ok|missing|notdir|unreadable, writable, images, videos }].
     */
    property var sourceInfo: []
    /** Nombres de archivo repetidos entre carpetas: comparten miniatura (se avisa en Sources). */
    property var collisions: []
    /**
     * La carpeta de descargas: ok · notSource (se retiró de Sources) · notWritable · missing.
     * Las descargas (10D) no empiezan salvo con `ok`.
     */
    readonly property string downloadDirState: {
        if (root.sourceDirs.indexOf(root.downloadDir) < 0) return "notSource";
        const info = root.infoOf(root.downloadDir);
        if (!info) return "ok";
        if (info.status !== "ok") return "missing";
        return info.writable ? "ok" : "notWritable";
    }
    function infoOf(dir) {
        for (let i = 0; i < root.sourceInfo.length; i++)
            if (root.sourceInfo[i].dir === dir) return root.sourceInfo[i];
        return null;
    }
    readonly property string thumbDir: Xdg.base(Quickshell.env("XDG_CACHE_HOME"), home + "/.cache")
        + "/sumi-wallpapers/thumbs"
    /**
     * PRUEBAS (10B, IPC `wallTestRoot`): con `testRoot` puesto (sólo bajo /tmp/), los dos scripts,
     * el `apply-scheme`, los archivos de estado del rice, la bolsa, el resultado de los colores y
     * los metadatos (`WallpaperMeta`) salen de esa carpeta. Un apply de prueba no toca así ni el
     * fondo, ni los colores, ni el Recent del usuario. Vacío = lo real.
     */
    property string testRoot: ""
    readonly property bool testing: root.testRoot.length > 0
    /**
     * F4b: el argv de un verbo del proveedor de fondos (null si no lo hace). En pruebas, el script
     * falso de `testRoot` con el contrato de siempre.
     */
    function cmdOf(verb, args) {
        if (root.testing) {
            const a = args || {};
            const tail = { apply: [a.path], applyOutput: [a.path, a.output], clear: ["--clear", a.output],
                           sync: ["--sync"], restore: [] }[verb];
            return ["bash", root.testRoot + "/apply-wallpaper.sh"].concat(tail);
        }
        return Providers.command("wallpaper", verb, args || {});
    }
    function envOf(verb) {
        return root.testing ? ({ WALL_TRANSITION: Settings.wallTransition })
            : Providers.env("wallpaper", verb, { transition: Settings.wallTransition });
    }
    /** Cómo se llama el proveedor en un error («apply-wallpaper.sh exited 1»). */
    readonly property string providerName: root.testing ? "apply-wallpaper.sh"
        : (Providers.resolve("wallpaper").mode === "builtin" ? "wallpaper-provider.py"
           : (Providers.resolve("wallpaper").label || "the wallpaper provider"))
    // F4d: sólo pruebas (el falso de testRoot); lo real es el `reload` del proveedor de tema
    readonly property string reloadScript: root.testing ? root.testRoot + "/matugen_reload.sh" : ""
    readonly property string themeProviderName: root.testing ? "matugen_reload.sh"
        : Providers.resolve("theme").mode === "builtin" ? "theme-provider.py" : "matugen_reload.sh"
    readonly property string schemeScript: root.testing ? root.testRoot + "/apply-scheme"
        : Quickshell.shellDir + "/scripts/apply-scheme"
    readonly property string stateFile: root.testing ? root.testRoot + "/.current-wallpaper"
        : root.stateDir + "/current-wallpaper"
    readonly property string outputsStateFile: root.testing ? root.testRoot + "/.current-wallpaper-outputs"
        : root.stateDir + "/current-wallpaper-outputs"
    readonly property string colorsStatusPath: (root.testing ? root.testRoot
        : (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp")) + "/sumi-wallpaper-colors"

    function setTestRoot(dir) {
        const d = String(dir || "");
        if (d.length > 0 && (d.indexOf("/tmp/") !== 0 || d.indexOf("..") >= 0)) return false;
        if (applyProc.running || restoreProc.running || schemeProc.running) return false;
        if (d === root.testRoot) return true;
        // primero los metadatos: el cambio de `current` que llega al releer el estado es sólo la referencia
        WallpaperMeta.setTestDir(d);
        root.testRoot = d;
        root.applyState = "idle";
        root.applyReason = "";
        root.colorsState = "";
        root.restoreNote = "";
        return true;
    }
    readonly property string stateDir: Xdg.base(Quickshell.env("XDG_STATE_HOME"), home + "/.local/state") + "/sumi-shell"
    /**
     * El fondo quieto de la pantalla de bloqueo: el mismo PNG que `apply-wallpaper.sh`
     * regenera para hyprlock en cada cambio (también de un fotograma si el fondo es un
     * vídeo). El shell no genera nada: lo lee (docs/lock/FONDO.md §2).
     */
    /**
     * El fondo quieto de la vista previa del Lock (el Lock real fotografía la pantalla con grim). F4b: el que declara el
     * proveedor (el autor: el current.png que su apply-wallpaper.sh deja para hyprlock). F5e (HC-05): sin declarar —el
     * proveedor propio—, el fondo actual si es imagen, o su miniatura si es vídeo (si ya existe); si no, "" (el degradado).
     */
    readonly property string lockStillPath: Providers.pathOf("wallpaper", "lockStill") || root.stillFor(root.current)
    function stillFor(path) {
        if (!path) return "";
        if (!root.isVideo(path)) return path;
        for (let i = 0; i < root.entries.length; i++)
            if (root.entries[i].path === path) return root.entries[i].hasThumb ? root.entries[i].thumb : "";
        return "";
    }

    /** [{ path, name, thumb, video, mtime }], newest first. */
    property var entries: []
    readonly property int count: entries.length

    /**
     * Absolute path of the wallpaper of EVERY screen, straight from the rice's
     * state file. It is also what colours and the lock background follow.
     */
    property string current: ""
    /**
     * 9D-1: cada cambio observado va a Recent (`WallpaperMeta`); la primera lectura del archivo
     * es sólo la referencia (NO desde `Component.onCompleted`: llega antes que la lectura y
     * dejaba la referencia vacía, así que el arranque contaba como aplicación — medido).
     * Aquí y no en WallpaperMeta: este servicio existe desde el arranque, y un singleton que
     * nadie usa no se crea hasta que se abre su página.
     */
    onCurrentChanged: WallpaperMeta.noteApplied(root.current)

    /**
     * Per-output exceptions, `{ "HEADLESS-1": "/path" }`, from the rice's
     * `.current-wallpaper-outputs` (2026-09-23). Empty with one monitor, and
     * whenever the last pick was for every screen: the script empties it then.
     */
    property var outputs: ({})

    /** What `screenName` actually shows: its own pick, or the one of every screen. */
    function currentFor(screenName) {
        const own = root.outputs[String(screenName || "")];
        return own !== undefined ? own : root.current;
    }

    /** A pick for ONE screen only means something with more than one. */
    readonly property bool multiScreen: Quickshell.screens.length > 1

    /** 12G: esta pantalla lleva un fondo propio (una excepción del rice). */
    function hasOwn(screenName) { return root.outputs[String(screenName || "")] !== undefined; }

    /**
     * 12G: devolver una pantalla al fondo de todas (`apply-wallpaper.sh --clear <salida>`). No
     * toca colores ni el fondo del lock: ésos siguen siempre al de todas. El resultado se observa
     * en `outputs` (el FileView vigila el archivo); `clearState` dice si se está haciendo o falló.
     */
    property string clearState: ""
    property string clearScreen: ""
    function clearOutput(screenName) {
        const sc = String(screenName || "");
        if (!root.hasOwn(sc) || clearProc.running || applyProc.running) return false;
        if (root.applyWhy.length > 0) return false;     // F2c: también es apply-wallpaper.sh
        const argv = root.cmdOf("clear", { output: sc });      // F4b
        if (!argv) return false;
        root.clearScreen = sc;
        root.clearState = "clearing";
        clearProc.command = argv;
        clearProc.running = true;
        return true;
    }
    Process {
        id: clearProc
        onExited: (code) => {
            outputsFile.reload();
            root.clearState = code === 0 && !root.hasOwn(root.clearScreen) ? "" : "failed";
            if (root.clearState === "failed")
                console.warn("wallpaper: could not put", root.clearScreen, "back on the shared wallpaper (exit " + code + ")");
        }
    }

    /**
     * 12G: de dónde salen los colores, en palabras (Wallpaper List y Settings). La decisión del
     * rice (2026-09-23) no cambia: matugen sigue al fondo de TODAS las pantallas; desde la 12F,
     * salvo con un color de origen propio, y nunca con la paleta estática.
     */
    readonly property string paletteOrigin: Colors.presetActive ? "the static " + ThemePreview.nameOf("preset:" + Colors.preset) + " palette"
        : !Colors.dynamicEnabled ? "the static Minimaru palette"
        : ThemePreview.confirmedOpts.source !== "wallpaper" ? "your custom colour " + ThemePreview.confirmedOpts.source
        : root.current.length > 0 ? "the wallpaper of all screens (" + root.baseName(root.current) + ")"
        : "the wallpaper of all screens"
    /** Lo mismo, corto, para la ayuda de la tira (el pie no da para el nombre del archivo). */
    readonly property string paletteOriginShort: Colors.presetActive ? ThemePreview.nameOf("preset:" + Colors.preset)
        : !Colors.dynamicEnabled ? "the static palette"
        : ThemePreview.confirmedOpts.source !== "wallpaper" ? ThemePreview.confirmedOpts.source
        : "the shared wallpaper"

    readonly property bool busy: applyProc.running || scanProc.running || verifyProc.running
        || restoreProc.running || schemeProc.running
    property string lastError: ""

    signal applied(string path)
    signal failed(string path, string reason)
    signal scanned()

    function baseName(p) { return String(p || "").substring(String(p || "").lastIndexOf("/") + 1); }

    function isVideo(path) {
        return /\.(mp4|mkv|mov|webm)$/i.test(path);
    }

    function filtered(kind) {
        if (kind === "favorites")
            return root.entries.filter(function (e) { return WallpaperMeta.isFavorite(e.path); });
        if (kind === "images")
            return root.entries.filter(function (e) { return !e.video; });
        if (kind === "videos")
            return root.entries.filter(function (e) { return e.video; });
        return root.entries;
    }

    function indexOfPath(list, path) {
        for (let i = 0; i < list.length; i++)
            if (list[i].path === path)
                return i;
        return -1;
    }

    // ---- scanning ------------------------------------------------------

    function scan() {
        if (scanProc.running) {
            root.rescan = true;
            return;
        }
        scanProc.dirs = root.sourceDirs.slice();
        scanProc.fromPoll = root.polling;
        root.polling = false;
        scanProc.command = ["sh", "-c", root.scanScript, "_", root.thumbDir].concat(scanProc.dirs);
        scanProc.running = true;
    }
    property bool rescan: false

    /**
     * W4 (antes de la fase 11): miniaturas que aún no existen. La tira pedía la imagen igualmente y
     * reintentaba por error (hasta 20 veces por archivo), y cada intento dejaba «Cannot open» en el
     * journal (medido con los archivos recién bajados de la W3). Ahora el escaneo anota qué
     * miniaturas hay (`hasThumb`) y, mientras falte alguna, se reescanea cada 2 s — como mucho 30
     * veces por cada escaneo que no venga de este sondeo: una miniatura que nunca llega no deja un
     * bucle.
     */
    readonly property bool thumbsMissing: root.entries.some(e => !e.hasThumb)
    property int thumbPollLeft: 0
    property bool polling: false
    Timer {
        interval: 2000
        repeat: true
        running: root.thumbPollLeft > 0 && root.thumbsMissing
        onTriggered: {
            root.thumbPollLeft--;
            root.polling = true;
            root.scan();
        }
    }

    /**
     * Mismas extensiones y misma profundidad que `generate-thumbs.sh`, para que la tira y la
     * caché de miniaturas nunca discrepen de qué es un fondo. Una línea `S` por carpeta (estado
     * y si se puede escribir) y una `F` por archivo; se ordena por mtime en JS (lo nuevo delante).
     * Las rutas van como argumentos, nunca dentro del guion.
     */
    readonly property string scanScript: 'td="$1"; shift; i=0; for d in "$@"; do '
        + 'if [ ! -e "$d" ]; then printf "S\\t%s\\tmissing\\t0\\n" "$i"; '
        + 'elif [ ! -d "$d" ]; then printf "S\\t%s\\tnotdir\\t0\\n" "$i"; '
        + 'elif [ ! -r "$d" ] || [ ! -x "$d" ]; then printf "S\\t%s\\tunreadable\\t0\\n" "$i"; '
        + 'else w=0; [ -w "$d" ] && w=1; printf "S\\t%s\\tok\\t%s\\n" "$i" "$w"; '
        + 'find "$d" -maxdepth 1 -type f \\( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" '
        + '-o -iname "*.webp" -o -iname "*.gif" -o -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" '
        + '-o -iname "*.webm" \\) -printf "F\\t$i\\t%T@\\t%p\\n" 2>/dev/null; fi; i=$((i+1)); done; '
        // W4: las miniaturas que existen (una línea `T` por archivo de la caché)
        + 'find "$td" -maxdepth 1 -type f -name "*.jpg" -printf "T\\t%f\\n" 2>/dev/null'

    Process {
        id: scanProc
        property var dirs: []
        property bool fromPoll: false
        stdout: StdioCollector {
            onStreamFinished: {
                const dirs = scanProc.dirs;
                const info = dirs.map(d => ({ dir: d, status: "missing", writable: false, images: 0, videos: 0 }));
                const lines = this.text.split("\n");
                const out = [];
                const seen = {};
                const byName = {};
                const dup = [];
                const thumbs = {};
                for (let i = 0; i < lines.length; i++)
                    if (lines[i].charAt(0) === "T" && lines[i].charAt(1) === "\t") thumbs[lines[i].substring(2)] = true;
                for (let i = 0; i < lines.length; i++) {
                    const f = lines[i].split("\t");
                    const src = info[parseInt(f[1])];
                    if (!src) continue;
                    if (f[0] === "S" && f.length >= 4) {
                        src.status = f[2];
                        src.writable = f[3] === "1";
                        continue;
                    }
                    if (f[0] !== "F" || f.length < 4) continue;
                    // una ruta con tabuladores: todo lo que sigue al tercero es la ruta
                    const path = f.slice(3).join("\t");
                    if (seen[path]) continue;
                    seen[path] = true;
                    const name = path.substring(path.lastIndexOf("/") + 1);
                    const video = root.isVideo(path);
                    if (video) src.videos++; else src.images++;
                    if (byName[name] && dup.indexOf(name) < 0) dup.push(name);
                    byName[name] = true;
                    out.push({
                        path: path,
                        name: name,
                        // generate-thumbs.sh names them "<file-with-extension>.jpg"
                        thumb: root.thumbDir + "/" + name + ".jpg",
                        hasThumb: thumbs[name + ".jpg"] === true,
                        video: video,
                        source: src.dir,
                        mtime: parseFloat(f[2])
                    });
                }
                out.sort((a, b) => b.mtime - a.mtime);
                root.entries = out;
                root.sourceInfo = info;
                root.collisions = dup;
                // falta alguna miniatura y este escaneo no es del sondeo: se vigila un rato
                if (!scanProc.fromPoll && out.some(e => !e.hasThumb)) root.thumbPollLeft = 30;
                root.scanned();
            }
        }
        onRunningChanged: if (!running && root.rescan) {
            root.rescan = false;
            Qt.callLater(root.scan);
        }
    }

    /** Sources cambió: nuevo escaneo y la lista para `generate-thumbs.sh`. */
    onSourceDirsChanged: sourcesDebounce.restart()
    Timer {
        id: sourcesDebounce
        interval: 150
        onTriggered: {
            root.scan();
            root.writeSourcesList();
        }
    }

    /**
     * La lista que lee `generate-thumbs.sh` (una carpeta absoluta por línea). Sólo después de leer
     * los ajustes (si no, un arranque escribiría los defaults encima de la lista buena un instante)
     * y sólo si cambia.
     */
    readonly property string sourcesListPath: root.stateDir + "/wallpaper-sources"
    function writeSourcesList() {
        if (!Settings.loaded) return;
        const text = root.sourceDirs.join("\n") + "\n";
        if (sourcesFile.text() === text) return;
        sourcesFile.setText(text);
        // una carpeta nueva necesita sus miniaturas ya (y una retirada, podarlas): el mismo
        // mecanismo de siempre, que lee esta lista
        root.refreshThumbs();
    }
    Connections {
        target: Settings
        function onLoadedChanged() { if (Settings.loaded) root.writeSourcesList(); }
    }
    FileView {
        id: sourcesFile
        path: root.sourcesListPath
        blockLoading: true
        printErrors: false
    }

    // ---- consulta compartida (Wallpaper List, Settings, IPC) ----------------

    /**
     * La biblioteca filtrada: tipo (all · images · videos), conjunto (library · recent ·
     * favorites) y texto (por nombre de archivo; todas las palabras, sin mayúsculas). Recent y
     * Favorites ordenan por su propia lista (lo más reciente / lo último marcado primero); la
     * biblioteca, por fecha del archivo. `collection` (10E-1b): sólo las de esa colección de
     * Wallhaven, según el índice privado. Nunca hace red.
     */
    function query(kind, set, text, collection) {
        let list = root.filtered(kind);
        // 10E-1b: Collection (independiente del tipo, del conjunto y del texto; se combinan)
        const coll = String(collection || "");
        if (coll.length > 0) list = list.filter(e => WallhavenIndex.inCollection(e.name, coll));
        if (set === "recent" || set === "favorites") {
            const meta = set === "recent" ? WallpaperMeta.recent : WallpaperMeta.favorites;
            const byPath = {};
            for (let i = 0; i < list.length; i++) byPath[list[i].path] = list[i];
            const ordered = [];
            for (let i = 0; i < meta.length; i++)
                if (byPath[meta[i].path]) ordered.push(byPath[meta[i].path]);
            list = ordered;
        }
        const words = String(text || "").toLowerCase().split(/\s+/).filter(w => w.length > 0);
        if (words.length > 0)
            list = list.filter(function (e) {
                const n = e.name.toLowerCase();
                for (let i = 0; i < words.length; i++)
                    if (n.indexOf(words[i]) < 0) return false;
                return true;
            });
        return list;
    }

    // ---- Sources: añadir, quitar, carpeta de descargas -----------------------

    /** El resultado del último intento de añadir: { path, state: checking|added|error, message }. */
    property var sourceNote: ({})

    function sourceError(path, message) {
        root.sourceNote = { path: path, state: "error", message: message };
        return false;
    }

    /**
     * Añadir una carpeta a Sources tras validarla (existe, es carpeta, se puede leer; y cuántos
     * fondos admitidos tiene). Devuelve si la petición se ACEPTÓ para comprobar; el resultado
     * llega a `sourceNote`.
     */
    function addSource(raw) {
        let p = String(raw || "").trim();
        while (p.length > 1 && p.charAt(p.length - 1) === "/") p = p.substring(0, p.length - 1);
        const dir = root.expand(p);
        if (p.length === 0) return root.sourceError(p, "Type a folder path");
        if (dir.length === 0 || p.indexOf("://") >= 0) return root.sourceError(p, "Use a full path (/… or ~/…)");
        if (root.sourceDirs.indexOf(dir) >= 0) return root.sourceError(p, "Already a source");
        if (dir === root.tempDir || dir.indexOf(root.tempDir + "/") === 0)
            return root.sourceError(p, "That folder holds unfinished downloads");
        if ((Settings.wallpaperSources || []).length >= 16) return root.sourceError(p, "At most 16 folders");
        if (checkProc.running) return root.sourceError(p, "Still checking the previous folder");
        root.sourceNote = { path: p, state: "checking", message: "Checking…" };
        checkProc.configured = p;
        // el guion toma primero la carpeta de miniaturas (W4); aquí no importa, pero tiene que ir
        checkProc.command = ["sh", "-c", root.scanScript, "_", root.thumbDir, dir];
        checkProc.running = true;
        return true;
    }

    Process {
        id: checkProc
        property string configured: ""
        stdout: StdioCollector {
            onStreamFinished: {
                const p = checkProc.configured;
                const lines = this.text.split("\n");
                let status = "missing", n = 0;
                for (let i = 0; i < lines.length; i++) {
                    const f = lines[i].split("\t");
                    if (f[0] === "S") status = f[2];
                    else if (f[0] === "F") n++;
                }
                if (status !== "ok") {
                    root.sourceError(p, status === "notdir" ? "Not a folder"
                        : status === "unreadable" ? "Can't read this folder" : "Folder not found");
                    return;
                }
                // otra ruta pudo entrar mientras se comprobaba
                if (root.sourceDirs.indexOf(root.expand(p)) >= 0) { root.sourceError(p, "Already a source"); return; }
                Settings.wallpaperSources = (Settings.wallpaperSources || []).concat([p]);
                root.sourceNote = { path: p, state: "added",
                    message: n === 0 ? "Added · no wallpapers in it yet"
                                     : "Added · " + n + (n === 1 ? " wallpaper" : " wallpapers") };
            }
        }
    }

    /** Quitar una carpeta de Sources (no borra nada del disco). */
    function removeSource(pathOrDir) {
        const dir = root.expand(pathOrDir);
        const l = Settings.wallpaperSources || [];
        const next = l.filter(p => root.expand(p) !== dir);
        if (next.length === l.length) return false;
        Settings.wallpaperSources = next;
        root.sourceNote = {};
        return true;
    }

    /** Elegir la carpeta de descargas: tiene que ser de Sources y escribible. */
    function setDownloadDir(pathOrDir) {
        const dir = root.expand(pathOrDir);
        const info = root.infoOf(dir);
        if (root.sourceDirs.indexOf(dir) < 0 || !info || info.status !== "ok" || !info.writable) return false;
        // se guarda como la escribió el usuario en Sources
        const l = Settings.wallpaperSources || [];
        for (let i = 0; i < l.length; i++)
            if (root.expand(l[i]) === dir) { Settings.wallpaperDownloadDir = l[i]; return true; }
        return false;
    }

    /**
     * Pedir las miniaturas que falten. F4c: al proveedor de miniaturas (el del autor: `systemctl --user start
     * thumbs-refresh.service`, la orden de siempre; el propio: scripts/thumbnail-provider.py --detach, en una
     * unidad transitoria). Lo piden abrir la tira, cambiar Sources y una descarga terminada; nunca un sondeo.
     */
    function refreshThumbs() {
        // F2c: sin generador ni unidad no se pide nada (la tira enseña su icono genérico)
        if (root.testing) {
            Quickshell.execDetached(["systemctl", "--user", "start", "thumbs-refresh.service"]);
            return true;
        }
        if (Providers.whyNot("thumbnails", "refresh").length > 0) return false;      // F4c: Off, script sin declarar…
        if (!Capabilities.can("wallpaper.thumbnails")) return false;
        const argv = Providers.command("thumbnails", "refresh", {});
        if (!argv) return false;
        Quickshell.execDetached(argv);
        return true;
    }

    // ---- portabilidad F2c: qué se puede aplicar aquí ---------------------------------

    /**
     * Por qué no se puede aplicar `path` en esta máquina ("" = sí): sin `apply-wallpaper.sh` o sin
     * awww (y su daemon) no se aplica nada; un vídeo necesita además mpvpaper. Sólo lo detectado
     * con prueba corta (`Capabilities.can`): en la duda se intenta como siempre. Mirar, buscar,
     * favoritos y Wallhaven siguen. Con `testRoot` no aplica: el script es el falso.
     */
    function whyNot(path) {
        if (root.testing) return "";
        const pw = Providers.whyNot("wallpaper", "apply");                 // F4b: none, script sin declarar…
        if (pw.length > 0) return pw;
        if (!Capabilities.can("wallpaper.apply")) return Capabilities.why("wallpaper.apply");
        if (path && root.isVideo(path) && !Capabilities.can("wallpaper.video")) return Capabilities.why("wallpaper.video");
        return "";
    }
    /** Lo mismo sin archivo: el motivo para Random, Restore, Use shared y la rotación. */
    readonly property string applyWhy: root.whyNot("")
    /** Los colores no seguirán al fondo (dinámico encendido, sin matugen…): "" si sí o si es estático. */
    readonly property string colorsWhy: root.testing || !Colors.dynamicEnabled ? ""
        : ThemePreview.whyNot(ThemePreview.confirmed === "static" ? "tonal-spot" : ThemePreview.confirmed)

    /** Un apply rechazado se observa como cualquier fallo (estado, motivo, señal), sin lanzar nada. */
    function refuse(path, why, origin) {
        root.applyState = "failed";
        root.applyPath = path || "";
        root.applyOrigin = origin || "user";
        root.applyReason = why;
        root.lastError = why;
        root.failed(path || "", why);
        return false;
    }

    // ---- applying ------------------------------------------------------

    property string queuedPath: ""
    property string queuedMonitor: ""

    /**
     * Apply `path`, optionally on one monitor only. A pick landing while the
     * previous one is still running is queued (one slot, last wins) instead of
     * stacking a second mpvpaper/awww on top of the first.
     *
     * Returns whether the request was ACCEPTED, not whether it is already on
     * screen: a queued pick returns `true` too, because it runs the moment the
     * one ahead of it finishes. It used to return `false` there, which is what
     * a rejection looks like — and since `qs ipc call` exits 0 while printing
     * "false", a script reading that output (`__minimaru_ipc` does exactly that)
     * called a wallpaper failed that was in fact about to be applied. Real
     * rejections are filtered by `wallSet` before they ever reach this.
     * `status().wallpaper.queued` says whether one is waiting.
     *
     * There is NO cancellation here, and that is deliberate — the functional
     * audit (§10) listed it as an oversight, and it isn't:
     *   · killing `apply-wallpaper.sh` halfway leaves the wallpaper up but
     *     `.current-wallpaper` unwritten, or hyprlock's `current.png` half
     *     rendered — state the rest of the rice reads as truth;
     *   · the colour pipeline runs behind it in a detached process, and a
     *     matugen killed mid-write is precisely the failure the post_hook rule
     *     in `matugen/config.toml` exists to prevent;
     *   · closing the surface is not a reason either: what is in flight is the
     *     last thing the user asked for, and the queued slot holds their most
     *     recent pick. Dropping it would discard the newer choice, not an
     *     unwanted leftover.
     */
    function apply(path, monitor, origin) {
        const mon = monitor === undefined ? "" : monitor;
        const from = origin || "user";
        const why = root.whyNot(path);
        if (why.length > 0) return root.refuse(path, why, from);
        if (applyProc.running || verifyProc.running) {
            root.queuedPath = path;
            root.queuedMonitor = mon;
            root.queuedOrigin = from;
            return true;
        }
        root.applyState = "applying";
        root.applyPath = path;
        root.applyMon = mon;
        root.applyOrigin = from;
        root.applyReason = "";
        root.applyAt = Date.now();
        // los colores son de ESTE apply: el resultado de uno anterior no se arrastra
        root.colorsState = "";
        root.colorsReason = "";
        colorsTimeout.stop();
        applyProc.target = path;
        // With one output the script treats a pick "for that output" as one
        // for every output, colours included; with more it is that screen's
        // alone and colours stay with the wallpaper of every screen.
        applyProc.oneScreen = mon.length > 0 && root.multiScreen;
        // F4b: del proveedor (el del autor: los mismos argv de siempre)
        const verb = mon.length > 0 ? "applyOutput" : "apply";
        const argv = root.cmdOf(verb, { path: path, output: mon });
        if (!argv) return root.refuse(path, Providers.whyNot("wallpaper", verb) || "The wallpaper provider can't do this", from);
        applyProc.command = argv;
        // 10B: la transición de awww (sólo imágenes); el script valida el nombre
        applyProc.environment = root.envOf(verb);
        applyProc.running = true;
        return true;
    }

    // ---- estado observado del último apply (10B) --------------------------

    /**
     * idle · applying · applied · failed. «applied» sólo cuando el ARCHIVO DE ESTADO dice lo
     * pedido tras salir bien el script (DESIGN §7, «no declarar éxito hasta observar el estado
     * efectivo»); `applyOrigin`: user · random · rotation · restore.
     */
    property string applyState: "idle"
    property string applyPath: ""
    property string applyMon: ""
    property string applyOrigin: ""
    property string applyReason: ""
    property real applyAt: 0
    property string queuedOrigin: ""
    /**
     * Los colores del último apply para todas las pantallas: "" · updating · updated · failed ·
     * static (colores del fondo apagados: no hay nada que regenerar) · unknown (no contestó).
     */
    property string colorsState: ""
    property string colorsReason: ""

    function finishApply(ok, path, reason) {
        root.applyState = ok ? "applied" : "failed";
        root.applyReason = ok ? "" : reason;
        root.lastError = ok ? "" : reason;
        if (ok) root.applied(path);
        else {
            console.warn("wallpaper: apply failed for", path, "—", reason);
            root.failed(path, reason);
            // F2c: quizá la máquina cambió desde la detección (daemon caído…): redetectar (≤ 1/10 s)
            if (!root.testing) Capabilities.suspect("wallpaper.apply", reason);
        }
        root.afterApply(ok);
        if (root.queuedPath.length > 0) {
            const next = root.queuedPath;
            const nextMon = root.queuedMonitor;
            const nextFrom = root.queuedOrigin;
            root.queuedPath = "";
            root.queuedMonitor = "";
            root.queuedOrigin = "";
            root.apply(next, nextMon, nextFrom);
        }
    }

    /**
     * Tras salir con 0, leer el estado que dejó el script: el fondo de todas (o el de esa
     * pantalla) tiene que ser lo pedido. Un proceso aparte y no el `FileView`: el vigilante puede
     * llegar después que el `exited`.
     */
    Process {
        id: verifyProc
        property string target: ""
        property string mon: ""
        property bool oneScreen: false
        command: ["sh", "-c", 'cat -- "$1" 2>/dev/null; printf "\\n\\036\\n"; cat -- "$2" 2>/dev/null',
                  "_", root.stateFile, root.outputsStateFile]
        stdout: StdioCollector {
            onStreamFinished: {
                const parts = this.text.split("\n\u001e\n");
                const global = (parts[0] || "").trim();
                const map = {};
                const lines = (parts[1] || "").split("\n");
                for (let i = 0; i < lines.length; i++) {
                    const tab = lines[i].indexOf("\t");
                    if (tab > 0) map[lines[i].substring(0, tab)] = lines[i].substring(tab + 1);
                }
                const path = verifyProc.target;
                const ok = verifyProc.oneScreen ? map[verifyProc.mon] === path : global === path;
                if (!ok) {
                    root.finishApply(false, path, "The wallpaper script finished but did not record "
                        + root.baseName(path));
                    return;
                }
                if (!verifyProc.oneScreen) root.startColors(path);
                root.finishApply(true, path, "");
            }
        }
    }

    /**
     * Colores (matugen) DESPEGADOS como siempre —un matugen muerto a medias es justo lo que hay que
     * evitar, y una recarga del shell mataría a un hijo—, pero con su resultado: el envoltorio
     * escribe «<token> <código>» en un archivo que se vigila.
     */
    property string colorsToken: ""
    function startColors(path) {
        if (!root.testing && !Colors.dynamicEnabled) {
            root.colorsState = "static";
            root.colorsReason = "";
            return;
        }
        // F2c: matugen_reload.sh sale con 0 sin matugen (fallo silencioso): se dice antes
        const why = root.colorsWhy;
        if (why.length > 0) {
            root.colorsState = "failed";
            root.colorsReason = why;
            return;
        }
        // F4d: la orden de regenerar es del proveedor de tema (en pruebas, el falso de testRoot)
        const reload = root.testing ? ["bash", root.reloadScript, path] : Providers.command("theme", "reload", { wall: path });
        if (!reload) {
            root.colorsState = "failed";
            root.colorsReason = Providers.whyNot("theme", "reload") || "The theme provider can't regenerate colours";
            return;
        }
        root.colorsToken = String(Date.now());
        root.colorsState = "updating";
        root.colorsReason = "";
        colorsTimeout.restart();
        // con «bash <script> <fondo>» (el del autor), el envoltorio de siempre, idéntico; con otra orden, el genérico
        const classic = reload.length === 3 && reload[0] === "bash";
        Quickshell.execDetached(classic
            ? ["sh", "-c", 'bash "$1" "$2"; printf "%s %s\\n" "$3" "$?" > "$4"',
               "_", reload[1], reload[2], root.colorsToken, root.colorsStatusPath]
            : ["sh", "-c", 'tok="$1"; st="$2"; shift 2; "$@"; printf "%s %s\\n" "$tok" "$?" > "$st"',
               "_", root.colorsToken, root.colorsStatusPath].concat(reload));
    }
    Timer {
        id: colorsTimeout
        interval: 90000
        onTriggered: if (root.colorsState === "updating") {
            root.colorsState = "unknown";
            root.colorsReason = "The colour update did not report back";
        }
    }
    FileView {
        id: colorsFile
        path: root.colorsStatusPath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            const f = text().trim().split(" ");
            if (f.length < 2 || f[0] !== root.colorsToken || root.colorsState !== "updating") return;
            colorsTimeout.stop();
            const code = parseInt(f[1]);
            root.colorsState = code === 0 ? "updated" : "failed";
            root.colorsReason = code === 0 ? "" : root.themeProviderName + " exited " + code;
        }
    }

    // ---- Restore previous (10B) -------------------------------------------

    /**
     * Vuelve al fondo aplicado antes que el actual (Recent) con su contexto de tema, por el mismo
     * `apply`. Si el archivo falta o algo falla, no cambia nada más y lo dice (`applyReason`).
     * El esquema, si aquel fondo tenía otro y los colores del fondo siguen encendidos, se escribe
     * ANTES (sin regenerar): el `matugen_reload.sh` del apply regenera una sola vez con él.
     */
    property string restoreNote: ""
    property var restoring: null
    property string schemeBefore: ""

    function failRestore(reason) {
        root.applyState = "failed";
        root.applyOrigin = "restore";
        root.applyReason = reason;
        root.restoreNote = "";
        root.restoring = null;
        root.failed(root.applyPath, reason);
    }

    function restorePrevious() {
        if (applyProc.running || verifyProc.running || restoreProc.running || schemeProc.running)
            return false;
        if (root.applyWhy.length > 0) { root.failRestore(root.applyWhy); return false; }
        const prev = WallpaperMeta.previous(root.current);
        root.applyPath = prev ? prev.path : "";
        if (!prev) {
            root.failRestore("Nothing to restore yet");
            return false;
        }
        root.restoring = prev;
        root.applyState = "applying";
        root.applyOrigin = "restore";
        root.applyReason = "";
        restoreProc.command = ["test", "-f", prev.path];
        restoreProc.running = true;
        return true;
    }

    Process {
        id: restoreProc
        onExited: function (code) {
            const prev = root.restoring;
            if (!prev) return;
            if (code !== 0) {
                root.failRestore("The previous wallpaper is missing: " + root.baseName(prev.path));
                return;
            }
            const withScheme = prev.dynamic === true && Colors.dynamicEnabled
                && typeof prev.scheme === "string" && prev.scheme !== Colors.scheme;
            root.restoreNote = prev.scheme === undefined ? "No theme recorded with it · colours follow the wallpaper"
                : withScheme ? "Scheme " + prev.scheme.replace("scheme-", "") + " restored"
                : prev.dynamic === false && Colors.dynamicEnabled ? "Colours from wallpaper were off then · left on"
                : prev.dynamic === true && !Colors.dynamicEnabled ? "Colours from wallpaper were on then · left off"
                // F-c: el preset no se cambia al restaurar un fondo (no depende de él): sólo se dice
                : prev.dynamic === false && prev.preset !== undefined && (prev.preset || "") !== (Colors.presetActive ? Colors.preset : "")
                    ? "Palette then: " + (prev.preset ? ThemePreview.nameOf("preset:" + prev.preset) : "Minimaru") + " · left as it is"
                : "";
            if (withScheme) {
                root.schemeBefore = Colors.scheme;
                schemeProc.reverting = false;
                schemeProc.command = [root.schemeScript, "--write-only", prev.scheme];
                schemeProc.running = true;
            } else {
                root.schemeBefore = "";
                root.apply(prev.path, "", "restore");
            }
        }
    }

    Process {
        id: schemeProc
        property bool reverting: false
        onExited: function (code) {
            if (schemeProc.reverting) return;
            const prev = root.restoring;
            if (!prev) return;
            if (code !== 0) {
                root.failRestore("Could not restore the colour scheme");
                return;
            }
            root.apply(prev.path, "", "restore");
        }
    }

    /** Un Restore que falla al aplicar deja el esquema como estaba (se escribió sin regenerar). */
    function afterApply(ok) {
        if (root.applyOrigin !== "restore" || !root.restoring) return;
        if (!ok && root.schemeBefore.length > 0) {
            schemeProc.reverting = true;
            schemeProc.command = [root.schemeScript, "--write-only", root.schemeBefore];
            schemeProc.running = true;
        }
        if (!ok) root.restoreNote = "";
        root.restoring = null;
        root.schemeBefore = "";
    }

    function applySummary() {
        const prev = WallpaperMeta.previous(root.current);
        return { state: root.applyState, path: root.applyPath, mon: root.applyMon, origin: root.applyOrigin,
                 reason: root.applyReason, colors: root.colorsState, colorsReason: root.colorsReason,
                 restoreNote: root.restoreNote, previous: prev ? prev.path : "",
                 previousScheme: prev && prev.scheme ? prev.scheme : "", testing: root.testing, unavailable: root.applyWhy,
                 transition: Settings.wallTransition,
                 // F4b
                 provider: Providers.resolve("wallpaper"), startupRestore: root.startupRestore };
    }

    Process {
        id: applyProc
        property string target: ""
        property bool oneScreen: false
        stderr: StdioCollector { id: applyErr }
        onExited: function (exitCode) {
            const path = applyProc.target;
            if (exitCode === 0) {
                // 10B: salir con 0 no basta; se mira el estado que dejó el script. Los colores
                // (matugen, sólo con un fondo para todas: siguen a `current`) salen de ahí.
                verifyProc.target = path;
                verifyProc.mon = root.applyMon;
                verifyProc.oneScreen = applyProc.oneScreen;
                verifyProc.running = true;
            } else {
                const msg = applyErr.text.trim();
                // 16D: borrado del disco con la tira abierta (sólo escanea al abrirse): el script
                // sale antes de tocar nada; se dice en palabras de la UI y se reescanea, y la
                // entrada fantasma desaparece (DESIGN §3, «Item no longer available»).
                if (msg.indexOf("doesn't exist") >= 0) {
                    root.finishApply(false, path, "No longer available: the file was removed");
                    root.scan();
                    return;
                }
                root.finishApply(false, path, msg.length > 0 ? msg : (root.providerName + " exited " + exitCode));
            }
        }
    }

    // ---- random, with a bag --------------------------------------------

    /**
     * Shuffled bag: every wallpaper comes up once before any repeats. The bag
     * survives restarts (it is the only reason to have one) and is refilled,
     * reshuffled, when it runs out. Changing `kind` refills too, so a bag of
     * videos never hands back an image.
     */
    property var bag: []
    property string bagKind: ""

    function shuffle(a) {
        const out = a.slice();
        for (let i = out.length - 1; i > 0; i--) {
            const j = Math.floor(Math.random() * (i + 1));
            const t = out[i];
            out[i] = out[j];
            out[j] = t;
        }
        return out;
    }

    function refillBag(kind) {
        const list = root.filtered(kind).map(function (e) { return e.path; });
        let next = root.shuffle(list);
        // Don't open a fresh bag with what is already on screen.
        if (next.length > 1 && next[0] === root.current)
            next.push(next.shift());
        root.bag = next;
        root.bagKind = kind;
    }

    function random(kind, origin) {
        const k = (kind === "images" || kind === "videos" || kind === "favorites") ? kind : "all";
        // F2c: antes de sacar nada de la bolsa (no se gasta una entrada en un apply imposible)
        if (root.applyWhy.length > 0) return root.refuse("", root.applyWhy, origin || "random");
        if (root.entries.length === 0)
            return false;
        if (root.bagKind !== k || root.bag.length === 0)
            root.refillBag(k);
        // Drop entries that vanished since the bag was filled, and (F2c) what can't be applied
        // here — a video without mpvpaper —, so a random pick never fails on purpose.
        const skip = p => root.indexOfPath(root.entries, p) < 0 || root.whyNot(p).length > 0;
        while (root.bag.length > 0 && skip(root.bag[0]))
            root.bag = root.bag.slice(1);
        if (root.bag.length === 0) {
            root.refillBag(k);
            while (root.bag.length > 0 && skip(root.bag[0]))
                root.bag = root.bag.slice(1);
        }
        if (root.bag.length === 0) {
            const w = Capabilities.why("wallpaper.video");
            return k === "videos" && !Capabilities.can("wallpaper.video") ? root.refuse("", w, origin || "random") : false;
        }
        const pick = root.bag[0];
        root.bag = root.bag.slice(1);
        root.persistBag();
        return root.apply(pick, "", origin || "random");
    }

    function persistBag() {
        bagFile.setText(JSON.stringify({ kind: root.bagKind, bag: root.bag }));
    }

    /** Not watched on purpose: the shell is the only writer, and re-reading our own write races the cached text. */
    FileView {
        id: bagFile
        path: (root.testing ? root.testRoot : root.stateDir) + "/wallpaper-bag.json"
        blockLoading: true
        printErrors: false
        onLoaded: {
            try {
                const saved = JSON.parse(bagFile.text());
                if (saved && Array.isArray(saved.bag)) {
                    root.bag = saved.bag;
                    root.bagKind = String(saved.kind || "");
                }
            } catch (e) {
                root.bag = [];
            }
        }
        onLoadFailed: function (error) {
            if (error === FileViewError.FileNotFound)
                bagFile.setText('{"kind":"","bag":[]}');
        }
    }

    // ---- current -------------------------------------------------------

    // El padre debe existir antes de armar los vigilantes: FileView no observa
    // la creación posterior de un directorio ausente (medido en F1a).
    property bool stateReady: false
    Process {
        command: ["mkdir", "-p", root.stateDir]
        running: true
        onExited: code => {
            root.stateReady = code === 0;
            if (code !== 0) console.warn("wallpaper: could not create state directory");
        }
    }

    /**
     * The rice's own state file, watched rather than parsed out of our own
     * process: rofi, fish and `wallpaper.service` write it too, so this stays
     * correct no matter who applied the wallpaper.
     */
    FileView {
        id: currentFile
        path: root.testing || root.stateReady ? root.stateFile : ""
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.current = text().trim()
        // 9D-1: sin archivo no hay cambio de `current` que sirva de referencia a Recent: se da aquí
        onLoadFailed: {
            // La ruta vacía mientras se prepara el padre aún no es una lectura.
            if (currentFile.path.length === 0) return;
            root.current = "";
            WallpaperMeta.noteApplied("");
        }
    }

    FileView {
        id: outputsFile
        path: root.testing || root.stateReady ? root.outputsStateFile : ""
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            const map = {};
            const lines = text().split("\n");
            for (let i = 0; i < lines.length; i++) {
                const tab = lines[i].indexOf("\t");
                if (tab > 0)
                    map[lines[i].substring(0, tab)] = lines[i].substring(tab + 1);
            }
            root.outputs = map;
        }
        // Applying to every screen deletes the file: that is "no exceptions".
        onLoadFailed: root.outputs = {}
    }

    // ---- hotplug ---------------------------------------------------------

    /**
     * A screen that comes back gets its own wallpaper again, and one that goes
     * away takes its mpvpaper with it: `apply-wallpaper.sh --sync` reconciles
     * the saved state with the outputs there are now, and writes nothing. Only
     * with exceptions saved — without them awww and the '*' mpvpaper already
     * cover a new output on their own. Never at startup: wallpaper.service
     * restores then, and the script's lock would only make one of them wait.
     */
    Connections {
        target: Quickshell
        function onScreensChanged() {
            // F4b: con el proveedor propio, siempre (awww deja en negro una salida nueva: medido el
            // 2026-10-07); con el del autor, como siempre: sólo con excepciones guardadas
            if (Object.keys(root.outputs).length > 0 || root.builtinProvider)
                syncDebounce.restart();
        }
    }

    Timer {
        id: syncDebounce
        interval: 800
        onTriggered: {
            if (syncProc.running || root.applyWhy.length > 0) return;
            const argv = root.cmdOf("sync");
            if (!argv) return;
            syncProc.command = argv;
            syncProc.running = true;
        }
    }

    Process { id: syncProc }

    // ---- F4b: restaurar al arrancar, sólo con el proveedor propio --------------------------

    readonly property bool builtinProvider: !root.testing && Providers.resolve("wallpaper").mode === "builtin"
    /**
     * Con el proveedor propio nadie más restaura el fondo al entrar (al autor se lo hace wallpaper.service,
     * y con su `script` esto no corre). Una vez por arranque de la shell, cuando Settings ya está leído y
     * migrado; el proveedor es idempotente (una recarga con el fondo puesto no cambia nada) y sin estado
     * guardado no hace nada. Arranca el daemon si hace falta: es un Restore, no abrir la interfaz.
     */
    property bool restoredOnce: false
    property string startupRestore: ""          // "" · running · done · failed: <motivo> · skipped
    Timer {
        id: restoreAtStart
        interval: 1500
        onTriggered: root.tryStartupRestore()
    }
    function tryStartupRestore() {
        if (root.restoredOnce) return;
        if (!Providers.isSettled("wallpaper")) { restoreAtStart.restart(); return; }
        root.restoredOnce = true;
        if (!root.builtinProvider) { root.startupRestore = "skipped"; return; }
        if (root.current.length === 0 && Object.keys(root.outputs).length === 0) { root.startupRestore = "skipped"; return; }
        if (root.applyWhy.length > 0) { root.startupRestore = "failed: " + root.applyWhy; return; }
        const argv = root.cmdOf("restore");
        if (!argv) { root.startupRestore = "skipped"; return; }
        startupProc.command = argv;
        root.startupRestore = "running";
        startupProc.running = true;
    }
    Process {
        id: startupProc
        stderr: StdioCollector { id: startupErr }
        onExited: (code) => {
            root.startupRestore = code === 0 ? "done" : "failed: " + (startupErr.text.trim() || "exit " + code);
            if (code !== 0) console.warn("wallpaper: could not restore the wallpaper at start —", startupErr.text.trim());
        }
    }

    Component.onCompleted: { root.scan(); restoreAtStart.start(); }
}
