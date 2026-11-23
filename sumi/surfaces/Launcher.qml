pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../theme"
import "../services"
import "../components"
import "../lib/calc.js" as Calc
import "../lib/fuzzy.js" as Fuzzy

/**
 * Application launcher: a query, a ranked list, and a calculator row when the
 * query happens to be arithmetic.
 *
 * The calculator parses with a hand-written recursive descent parser, never
 * `eval`, so a typed query cannot run code (lib/calc.js). Ukishima's launcher
 * also installs whatever you drop on it — packages via `pkexec`, AppImages it
 * runs to unpack; that whole path is deliberately absent (SECURITY.md H2).
 *
 * MODO ARCHIVO (Fase 10.c.2): teclear una ruta (`/…` o `~…`) cambia la lista a
 * un navegador de archivos — el modi `filebrowser` que rofi tenía en
 * `config.rasi` y aquí no. La ruta es la navegación: `⏎` sobre una carpeta la
 * añade a la ruta, `⏎` sobre un archivo lo abre con `xdg-open` (argv, sin
 * shell) y cierra. Retroceder = borrar la ruta. `rofi -show filebrowser` **no
 * se retira** (ADR-18): sigue accesible con la tecla de modo dentro de
 * `SUPER+SPACE`.
 *
 * ACCIONES (QS-FUNC-010): una app con acciones en su `.desktop` («New Private
 * Window», los verbos de Steam) lleva un `›` a la derecha. `Tab` o `Ctrl+→` la
 * abre y la lista pasa a ser sus acciones; `Ctrl+←` o `Esc` vuelve a la app,
 * y teclear tambien. Es el mismo gesto que entrar/salir de carpetas en el modo
 * archivo, y no `→` a secas como proponia la auditoria: aqui el teclado lo
 * tiene el campo, y `→` mueve el cursor del texto.
 *
 * VENTANAS VIVAS (QS-FUNC-012a, decision del usuario del 2026-09-14): una app
 * con ventanas abiertas lleva un punto. `⏎` sigue lanzando una instancia nueva,
 * como siempre; **`Ctrl+⏎` enfoca** su ultima ventana (restaurandola si estaba
 * minimizada). No se cambio `⏎`, que era la propuesta de la auditoria, para no
 * tocar lo que ya esta en los dedos.
 */
Surface {
    id: root

    mTop: 12
    mLeft: 14
    mRight: 14
    mBottom: 10

    property string query: ""
    property int selected: 0

    // ---- acciones de una app (QS-FUNC-010) ----------------------------------

    /** La app cuyas acciones se estan mostrando, o null. */
    property var actionEntry: null
    /** Fila de la app al entrar: se vuelve a ella al salir. */
    property int actionReturn: 0

    readonly property var actionRows: {
        const e = root.actionEntry;
        if (!e) return [];
        void Apps.usage;
        return Apps.actionsOf(e).map(function (a) { return { action: a, entry: e, name: a.name }; });
    }

    // ---- ventanas de una app (fase 5A) --------------------------------------

    /**
     * La app cuyas VENTANAS se están mostrando, o null (futureApp-launcher §«Elegir una
     * ventana abierta»). Alt+⏎ o el contador de la fila la abren; ⏎ enfoca (y restaura si
     * está minimizada); Esc o Ctrl+← vuelven sin borrar la consulta.
     */
    property var windowsEntry: null
    property int windowsReturn: 0
    /** La ventana elegida, por dirección: si se cierra, la selección no salta a otra fila. */
    property string winAddr: ""
    readonly property bool subView: root.actionEntry !== null || root.windowsEntry !== null

    readonly property var windowRows: {
        const e = root.windowsEntry;
        if (!e) return [];
        return Toplevels.windowsFor(e.id).map(function (w) { return { win: w, entry: e, name: w.title || w.appId }; });
    }

    function openCountOf(e) {
        return (e && !e.file && e.action === undefined && e.win === undefined && e.id)
            ? Toplevels.windowsFor(e.id).length : 0;
    }

    function enterWindows(i) {
        if (root.fileActive || root.subView) return;
        const idx = i === undefined ? root.selected : i;
        const e = root.results[idx];
        if (root.openCountOf(e) === 0) return;
        root.windowsReturn = idx;
        root.windowsEntry = e;
        root.selected = 0;
        root.winAddr = root.windowRows.length > 0 ? root.windowRows[0].win.address : "";
    }

    function leaveWindows() {
        if (root.windowsEntry === null) return;
        const back = root.windowsReturn;
        root.windowsEntry = null;
        root.selected = Math.max(0, Math.min(root.resultCount - 1, back));
        if (root.selected >= 0) list.positionViewAtIndex(root.selected, ListView.Contain);
    }

    /** La fila elegida es una app con acciones: `Tab` / `Ctrl+→` significan algo. */
    readonly property bool selHasActions: !root.fileActive && !root.subView
        && root.selected >= 0 && root.selected < root.resultCount
        && Apps.hasActions(root.results[root.selected])

    function enterActions() {
        if (!root.selHasActions) return;
        root.actionReturn = root.selected;
        root.actionEntry = root.results[root.selected];
        root.selected = 0;
    }

    function leaveActions() {
        if (root.actionEntry === null) return;
        const back = root.actionReturn;
        root.actionEntry = null;
        root.selected = Math.max(0, Math.min(root.resultCount - 1, back));
        if (root.selected >= 0) list.positionViewAtIndex(root.selected, ListView.Contain);
    }

    readonly property string home: Quickshell.env("HOME") || "/home"

    // ---- modo archivo -------------------------------------------------------

    /** La consulta es una ruta: empieza por `/` o por `~`. */
    readonly property bool fileActive: /^\s*[~/]/.test(root.query)

    // ---- modo emoji (2026-11-17) ---------------------------------------------

    /**
     * `:` delante busca emoji con el mismo motor que el selector (services/Emoji, sólo la pestaña
     * Emoji, en inglés y español). ⏎ hace lo que diga `shell.emoji.action` y ⇧⏎ lo otro; los kaomoji,
     * símbolos y glifos están en el selector (SUPER+.).
     */
    readonly property bool emojiActive: !root.fileActive && !root.subView && /^\s*:/.test(root.query)
    readonly property string emojiQuery: root.query.replace(/^\s*:\s*/, "")
    readonly property string emojiClaimKey: root.screenName.length > 0 ? "launcher@" + root.screenName : ""
    Claim { target: Emoji; key: root.emojiClaimKey; value: root.active && root.emojiActive }
    onEmojiActiveChanged: if (root.emojiActive) Emoji.want("emoji")
    readonly property var emojiRows: {
        void Emoji.dataRev;
        if (!root.emojiActive) return [];
        const found = root.emojiQuery.trim().length > 0 ? Emoji.search("emoji", root.emojiQuery, 8)
            : Emoji.recent("emoji", 8);
        return found.map(function (e) { return { emoji: e.c, name: e.n, id: "" }; });
    }
    property int emojiRev: 0
    Connections {
        target: Emoji
        function onSettled(rev, ok, reason) {
            if (rev !== root.emojiRev) return;
            root.emojiRev = 0;
            if (ok) root.requestClose();
        }
    }

    /** Trozo de la consulta hasta la última `/` (tal cual se tecleó). */
    readonly property string fileDirTyped: {
        const q = root.query.replace(/^\s+/, "");
        const i = q.lastIndexOf("/");
        return i >= 0 ? q.slice(0, i + 1) : q;
    }
    /** Lo de después de la última `/`: el filtro. */
    readonly property string fileFrag: {
        const q = root.query.replace(/^\s+/, "");
        const i = q.lastIndexOf("/");
        return i >= 0 ? q.slice(i + 1) : "";
    }
    /** Ruta real del directorio (con `~` expandido), o "" si no es navegable. */
    readonly property string fileDirReal: {
        if (!root.fileActive) return "";
        let d = root.fileDirTyped;
        if (d === "~" || d === "~/") return root.home + "/";
        if (d.slice(0, 2) === "~/") d = root.home + "/" + d.slice(2);
        return d.charAt(0) === "/" ? d : "";
    }

    /**
     * El listado va por `ls`, no por `Qt.labs.folderlistmodel`: ese mantiene un
     * `QFileInfoList` de TODO el directorio en memoria (medido: `/usr/lib`
     * costaba +27 MB de RSS que no volvían). El `ls` corre **una vez por
     * directorio** —no por tecla, el filtro es JS puro— con tope de 6000
     * entradas, igual que `services/Units` y `Toplevels` salen a un proceso
     * para lo que no tiene fuente nativa barata.
     */
    // Cada carpeta es dueña de su proceso y sus resultados. Al navegar, el objeto
    // viejo desaparece entero; una lectura tardía nunca aporta nombres a otra ruta.
    Instantiator {
        id: listing
        model: root.fileDirReal ? [root.fileDirReal] : []
        delegate: Process {
            id: scan
            required property string modelData
            property var names: []
            property var entries: []
            property bool denied: false
            property bool missing: false
            command: ["env", "LC_ALL=C", "ls", "-1Ap", "--zero", "--group-directories-first", "--", modelData]
            running: true
            stdout: SplitParser {
                splitMarker: "\u0000"
                onRead: (name) => {
                    if (!name.length || scan.names.length >= 6000) return;
                    const dir = name.endsWith("/");
                    scan.names.push({ name: dir ? name.slice(0, -1) : name, isDir: dir });
                }
            }
            stderr: StdioCollector { id: scanError }
            onExited: (code) => {
                scan.denied = code !== 0 && /Permission denied/.test(scanError.text);
                scan.missing = code !== 0 && !scan.denied;
                if (code === 0) scan.entries = scan.names;
            }
            Component.onDestruction: running = false
        }
    }
    readonly property var fileRaw: listing.object ? listing.object.entries : []
    readonly property bool fileListing: !!listing.object && listing.object.running
    readonly property bool fileDirMissing: !!listing.object && listing.object.missing
    readonly property bool fileDirDenied: !!listing.object && listing.object.denied

    /** Tope de filas visibles: más allá, teclear para filtrar es el único camino
     *  razonable, y renderizarlas todas cuesta RSS (medido: `/usr/lib`, 4663
     *  entradas, costaba +45 MB). */
    readonly property int fileCap: 250

    function _fileMatch(e, frag, showHidden) {
        if (!showHidden && e.name.charAt(0) === ".") return false;
        return frag.length === 0 || e.name.toLowerCase().indexOf(frag) >= 0;
    }

    /** El crudo, filtrado por el fragmento y **con tope** (JS puro, sin proceso). */
    readonly property var fileEntries: {
        const frag = root.fileFrag.toLowerCase();
        const showHidden = root.fileFrag.charAt(0) === ".";
        const dir = root.fileDirReal;
        const out = [];
        for (let i = 0; i < root.fileRaw.length && out.length < root.fileCap; i++) {
            const e = root.fileRaw[i];
            if (root._fileMatch(e, frag, showHidden))
                out.push({ file: true, name: e.name, isDir: e.isDir, path: dir + e.name });
        }
        return out;
    }
    /** Hay más coincidencias de las que caben en el tope. */
    readonly property bool fileOverflow: {
        if (root.fileRaw.length <= root.fileCap) return false;
        const frag = root.fileFrag.toLowerCase();
        const showHidden = root.fileFrag.charAt(0) === ".";
        let n = 0;
        for (let i = 0; i < root.fileRaw.length; i++) {
            if (root._fileMatch(root.fileRaw[i], frag, showHidden) && ++n > root.fileCap)
                return true;
        }
        return false;
    }
    readonly property bool fileDirBad: root.fileActive && root.fileDirReal.length === 0


    // ---- secciones y resaltado (2026-09-15) --------------------------------

    /**
     * Cuántas de las primeras filas son «las que usas».
     *
     * `lib/fuzzy` ya ordenaba por uso con la consulta vacía — desde siempre —
     * pero la lista **no lo decía**: se veía igual que un listado alfabético, así
     * que la primera pantalla del lanzador parecía arbitraria. Con el rótulo, el
     * orden se explica solo.
     *
     * Sólo en la lista de aplicaciones: en modo archivo o dentro de las acciones
     * de una app, agrupar no significa nada.
     */
    readonly property int frequentCount: {
        if (root.fileActive || root.subView || root.query.trim().length > 0)
            return 0;
        const u = Apps.usage;
        let n = 0;
        for (let i = 0; i < root.results.length && n < 5; i++) {
            const e = root.results[i];
            if (!e || !e.id || !(u[e.id] > 0)) break;
            n++;
        }
        return n;
    }

    function groupLabelAt(i) {
        if (root.frequentCount === 0)
            return "";
        if (i === 0) return "FREQUENT";
        if (i === root.frequentCount) return "ALL APPS";
        return "";
    }

    /**
     * Escapa el texto y envuelve en el acento el tramo que coincide con lo
     * tecleado. El texto viene de un `.desktop` ajeno: se escapa SIEMPRE, y
     * sólo se añade una etiqueta propia (`StyledText`, no `RichText`, que
     * cargaría HTML entero — SECURITY.md).
     */
    /**
     * El segundo renglón sólo si distingue (futureApp-launcher: «la lista no repite
     * una descripción idéntica al nombre»). Medido en la captura de la fase 0:
     * «Barely Working / Barely Working», «Insect Prision / Insect Prision».
     */
    /** F2e, PRUEBAS (IPC `launcherType`): escribir en el campo como si se tecleara. */
    function typeForTest(t) { search.text = String(t || ""); return true; }

    function secondLine(e) {
        // F2d: una app de terminal sin terminal lo dice antes de pulsar
        if (e && e.runInTerminal && Apps.terminalWhy.length > 0) return "Can't open here · " + Apps.terminalWhy;
        const n = (e.name || "").trim().toLowerCase();
        const g = (e.genericName || "").trim();
        if (g.length > 0 && g.toLowerCase() !== n) return g;
        const c = (e.comment || "").trim();
        if (c.length > 0 && c.toLowerCase() !== n) return c;
        return "";
    }

    function esc(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    function mark(text, needle) {
        const s = String(text);
        const q = String(needle || "").trim();
        if (q.length === 0)
            return root.esc(s);
        const at = s.toLowerCase().indexOf(q.toLowerCase());
        if (at < 0)
            return root.esc(s);   // coincidió por subsecuencia o por keyword
        const tint = String(Theme.primaryText);
        return root.esc(s.slice(0, at))
            + '<font color="' + tint + '">' + root.esc(s.slice(at, at + q.length)) + "</font>"
            + root.esc(s.slice(at + q.length));
    }

    readonly property var results: root.fileActive ? root.fileEntries
        : root.emojiActive ? root.emojiRows
        : root.windowsEntry !== null ? root.windowRows
        : root.actionEntry !== null ? root.actionRows
        : root.shellMatches.concat(Apps.rank(root.query))

    /**
     * Ayuda de atajos (2026-10-30): la tarjeta de los atajos de la shell como un resultado más, SÓLO al buscarla
     * (nombre o palabra clave que empiece o contenga lo escrito; nunca en la lista vacía ni por subsecuencia, para no
     * colarse entre las apps). No es un .desktop: no pasa por Apps.launch ni cuenta en el uso.
     */
    readonly property var shellEntries: [{ shell: "keybinds", id: "", name: "Keyboard shortcuts",
        genericName: "What each shell shortcut opens, and its key",
        keywords: ["keybinds", "keybindings", "hotkeys", "shortcuts", "keys", "bindings", "sumi"] }]
    readonly property var shellMatches: {
        const q = root.query.trim().toLowerCase();
        if (q.length < 2) return [];
        return root.shellEntries.filter(function (e) { return Fuzzy.score(e, q) <= 1; });
    }
    readonly property int resultCount: root.results.length

    /**
     * El alto que pide (paneles que se adaptan, 2026-11-17): de los DATOS, nunca del maquetado de la lista (9.f.2:
     * un destino que sale del layout bajo el morph congeló el shell). Cada fila mide 48·s y la que abre grupo 24·s
     * más, en todos los modos; sin filas, el aviso de vacío. Las demás piezas tienen alto fijo (el pie es un `Flow`
     * de ancho constante). El host lo acota al alto de siempre (`Metrics.launcherH`).
     */
    readonly property real fitH: {
        const s = root.s;
        const cap = Metrics.launcherH * s;
        let rows = 0;
        for (let i = 0; i < root.resultCount && rows < cap; i++)
            rows += 48 * s + (root.groupLabelAt(i).length > 0 ? 24 * s : 0);
        const listH = root.resultCount > 0 ? rows
            : (root.calcActive || root.runActive) ? 0
            : launcherEmpty.implicitHeight + 2 * Metrics.sp5 * s;
        return (root.mTop + root.mBottom) * s + header.height + contextLine.anchors.topMargin + contextLine.height
            + rule.anchors.topMargin + rule.height + calcRow.height + runRow.height
            + list.anchors.topMargin + listH + list.anchors.bottomMargin + footer.height;
    }

    /** Only a real calculation counts: a lone number or an app name falls through to search. */
    readonly property var calc: Calc.evaluate(root.query)
    readonly property bool calcActive: !root.fileActive && !root.subView && root.calc.ok
    property bool calcCopied: false
    onQueryChanged: root.calcCopied = false

    /**
     * Modo `run` (parada tecnica, 2026-09-08). Lo que tenia rofi con
     * `modi: "drun,run,…"` y aqui no habia: un binario sin `.desktop` era
     * inalcanzable desde el shell.
     *
     * El troceo es por espacios y nada mas: **sin comillas, sin expansion, sin
     * shell**. Un `foo "a b"` manda tres argumentos, no dos. Es una limitacion
     * consciente — la alternativa era parsear como un shell, y la regla 3 de
     * `docs/SECURITY.md` dice justo lo contrario.
     */
    readonly property var argv: {
        const q = root.query.trim();
        return q.length === 0 ? [] : q.split(/\s+/);
    }
    /** La calculadora manda: una consulta aritmetica nunca es un nombre de comando. */
    readonly property bool runActive: !root.fileActive && !root.calcActive && !root.subView
        && root.argv.length > 0
        && Apps.hasCommand(root.argv[0])

    /** `-1` es la fila de ejecucion; de 0 en adelante, la lista de aplicaciones. */
    readonly property int firstIndex: root.runActive ? -1 : 0
    function defaultSelection() {
        return (root.resultCount === 0 && root.runActive) ? -1 : 0;
    }

    function move(delta) {
        const hi = root.resultCount - 1;
        if (hi < root.firstIndex)
            return;
        root.selected = Math.max(root.firstIndex, Math.min(hi, root.selected + delta));
        if (root.selected >= 0)
            list.positionViewAtIndex(root.selected, ListView.Contain);
    }

    function activate(modifiers) {
        if (root.emojiActive) {
            const r = root.results[root.selected];
            if (!r || root.emojiRev > 0) return;
            root.emojiRev = Emoji.pick([{ tab: "emoji", c: r.emoji }],
                                       Emoji.actionFor((modifiers & Qt.ShiftModifier) !== 0), Emoji.target());
            return;
        }
        if (root.calcActive) {
            Quickshell.execDetached(["sh", "-c", "printf '%s' \"$1\" | wl-copy", "_", root.calc.display]);
            root.calcCopied = true;
            return;
        }
        if (root.fileActive) {
            if (root.selected < 0 || root.selected >= root.resultCount) return;
            const e = root.results[root.selected];
            if (e.isDir) {
                // navegar dentro: la ruta tecleada + la carpeta + "/"
                search.text = root.fileDirTyped + e.name + "/";
                root.selected = 0;
            } else {
                // abrir con el manejador por defecto (envuelve terminal si hace falta)
                Apps.openPath(e.path);
                root.requestClose();
            }
            return;
        }
        if (root.selected < 0) {
            if (!root.runActive)
                return;
            // F2d: rechazado (⇧⏎ sin terminal) se queda abierto: el pie lo dice
            if (Apps.run(root.argv, (modifiers & Qt.ShiftModifier) !== 0)) root.requestClose();
            return;
        }
        if (root.selected >= root.resultCount)
            return;
        if (root.windowsEntry !== null) {
            const r = root.results[root.selected];
            if (r && r.win) root.focusDeferred(r.win, r.win.minimized ? "restore" : "focus");
            return;
        }
        if (root.actionEntry !== null) {
            const r = root.results[root.selected];
            if (Apps.launchAction(r.entry, r.action)) root.requestClose();
            return;
        }
        const entry = root.results[root.selected];
        if (entry && entry.shell === "keybinds") {
            if (KeybindsUi.show(root.screenName, null)) root.requestClose();
            return;
        }
        if ((modifiers & Qt.ControlModifier) !== 0) {
            const wins = Toplevels.windowsFor(entry.id);
            if (wins.length > 0) {
                root.focusDeferred(wins[0]);
                return;
            }
            // Sin ventana abierta, Ctrl+⏎ lanza: mejor que no hacer nada.
        }
        if (Apps.launch(entry)) root.requestClose();
    }

    /**
     * Enfocar necesita cerrar la capa primero: mientras el layer-shell tiene el
     * teclado, `hl.dsp.focus` no gana. Mismo Timer de 130 ms que el minimizador.
     */
    property var pendingFocus: null
    property string pendingKind: "focus"

    /** `kind`: "focus" o "restore" (una minimizada vuelve al workspace activo y se enfoca). */
    function focusDeferred(w, kind) {
        root.pendingFocus = w;
        root.pendingKind = kind === "restore" ? "restore" : "focus";
        root.requestClose();
        focusTimer.start();
    }

    Timer {
        id: focusTimer
        interval: 130
        onTriggered: {
            const w = root.pendingFocus;
            root.pendingFocus = null;
            if (!w) return;
            // En los 130 ms del cierre la ventana pudo irse: no se actúa sobre otra.
            if (!Toplevels.windows.some(function (x) { return x.address === w.address; })) {
                console.warn("launcher: window gone before", root.pendingKind);
                return;
            }
            if (root.pendingKind === "restore") Toplevels.restore(w);
            else Toplevels.focus(w);
        }
    }

    onOpenChanged: {
        if (open) {
            Toplevels.refreshOrder();   // la ultima ventana enfocada de cada app, fresca
            root.actionEntry = null;
            root.windowsEntry = null;
            root.zone = "field";
            root.query = "";
            search.clear();
            root.selected = 0;
            root.calcCopied = false;
            // Perezoso (ADR-9): la lista de PATH se construye al primer uso.
            Apps.scanPath();
            Qt.callLater(search.focusField);
        }
    }

    onResultsChanged: {
        // Lista de ventanas: la elegida se sigue por dirección (una que se cierra desaparece
        // y la selección queda en una que existe, nunca en otra por índice).
        if (root.windowsEntry !== null) {
            // Vacía puede ser un instante (Toplevels se rehace al refrescar): sólo se sale si
            // SIGUE vacía, y nunca dentro de esta notificación (medido en la 5A: salir aquí
            // era un binding loop y `results` se quedaba enseñando la lista vieja).
            if (root.resultCount === 0) { emptyTimer.restart(); return; }
            emptyTimer.stop();
            let i = root.results.findIndex(function (r) { return r.win.address === root.winAddr; });
            if (i < 0) i = Math.min(root.selected, root.resultCount - 1);
            root.selected = i;
            return;
        }
        if (root.selected >= root.resultCount) root.selected = root.defaultSelection();
    }
    /**
     * La lista de ventanas se reajusta al cambiar `Toplevels.windows`, no sólo con
     * `onResultsChanged`: medido en la 5A, al cerrarse una ventana ese aviso no llegaba
     * (la lista nueva sí se leía) y la selección se quedaba apuntando fuera. Un paso del
     * bucle después, cuando `results` ya es el nuevo.
     */
    Connections {
        target: Toplevels
        function onWindowsChanged() { if (root.windowsEntry !== null) Qt.callLater(root.reconcileWindows); }
    }
    function reconcileWindows() {
        if (root.windowsEntry === null) return;
        const rows = root.results;
        if (rows.length === 0) { emptyTimer.restart(); return; }
        emptyTimer.stop();
        let i = rows.findIndex(function (r) { return r.win && r.win.address === root.winAddr; });
        if (i < 0) i = Math.max(0, Math.min(root.selected, rows.length - 1));
        root.selected = i;
        root.winAddr = rows[i].win.address;
    }

    Timer {
        id: emptyTimer
        interval: 400
        onTriggered: if (root.windowsEntry !== null && root.resultCount === 0) root.leaveWindows()
    }
    onSelectedChanged: if (root.windowsEntry !== null && root.selected >= 0 && root.selected < root.resultCount)
        root.winAddr = root.results[root.selected].win.address
    onRunActiveChanged: if (!root.runActive && root.selected < 0) root.selected = 0

    // ---- la franja de acciones (fase 5A) -----------------------------------

    /**
     * Lo que se puede hacer con la fila elegida, con su atajo (futureApp-launcher
     * §«Resultados y acciones visibles»): sólo lo válido para ESA fila. Tab recorre la
     * franja y Enter/Espacio activan; Tab ya no abre las acciones de la app por su cuenta
     * (siguen en Ctrl+→). Altura estable: la franja está siempre, aunque cambie lo que dice.
     */
    readonly property var footerActions: {
        if (root.windowsEntry !== null) return [{ id: "focus", label: "Focus  ⏎" }, { id: "back", label: "Back  Esc" }];
        if (root.actionEntry !== null) return [{ id: "open", label: "Run action  ⏎" }, { id: "back", label: "Back  Esc" }];
        if (root.calcActive) return [{ id: "open", label: root.calcCopied ? "Copied" : "Copy result  ⏎" }];
        if (root.emojiActive) {
            if (!root.results[root.selected]) return [];
            const paste = Emoji.actionFor(false) === "paste";
            return [{ id: "open", label: (paste ? "Paste" : "Copy") + "  ⏎" },
                    { id: "term", label: (paste ? "Copy" : "Paste") + "  ⇧⏎" }];
        }
        if (root.fileActive) {
            const f = root.results[root.selected];
            const out = [];
            if (f) out.push({ id: "open", label: f.isDir ? "Open folder  ⏎" : "Open  ⏎" });
            out.push({ id: "up", label: "Up  Ctrl←" });
            return out;
        }
        if (root.selected < 0 && root.runActive)
            return [{ id: "open", label: "Run  ⏎" }].concat(Apps.terminalWhy.length > 0 ? []      // F2d
                : [{ id: "term", label: "In terminal  ⇧⏎" }]);
        const e = root.results[root.selected];
        if (!e) return [];
        const out = [{ id: "open", label: "Open  ⏎" }];
        const n = root.openCountOf(e);
        if (n > 0) {
            out.push({ id: "recent", label: "Focus recent  ^⏎" });
            out.push({ id: "wins", label: "Windows (" + n + ")  ⌥⏎" });
        }
        if (root.selHasActions) out.push({ id: "actions", label: "Actions  ^→" });
        return out;
    }

    function footerRun(id) {
        if (id === "open") root.activate(0);
        else if (id === "focus") root.activate(0);
        else if (id === "recent") root.activate(Qt.ControlModifier);
        else if (id === "term") root.activate(Qt.ShiftModifier);
        else if (id === "wins") root.enterWindows();
        else if (id === "actions") root.enterActions();
        else if (id === "up") root.goUpDir();
        else if (id === "back") { if (root.windowsEntry !== null) root.leaveWindows(); else root.leaveActions(); }
        root.setZone("field");
    }

    /** Dónde está el teclado: "field" (el campo) o "footer" (un botón de la franja). */
    property string zone: "field"
    property int footerIdx: 0
    onFooterActionsChanged: if (root.footerIdx >= root.footerActions.length) root.footerIdx = Math.max(0, root.footerActions.length - 1)

    function setZone(z) {
        if (z === "footer" && root.footerActions.length === 0) z = "field";
        root.zone = z;
        if (z === "field") Qt.callLater(search.focusField);
        else root.forceActiveFocus();
    }

    function tabTo(dir) {
        const n = root.footerActions.length;
        if (n === 0) { root.setZone("field"); return; }
        if (search.editing) {
            root.footerIdx = dir > 0 ? 0 : n - 1;
            root.setZone("footer");
            return;
        }
        const next = root.footerIdx + dir;
        if (next < 0 || next >= n) { root.setZone("field"); return; }
        root.footerIdx = next;
    }

    /** The field owns the keyboard while open; the host only sees what it declines. */
    function keyPressed(event) {
        if (search.editing || root.zone !== "footer") return;
        const k = event.key;
        const shift = (event.modifiers & Qt.ShiftModifier) !== 0;
        if (k === Qt.Key_Tab || k === Qt.Key_Backtab) { root.tabTo(k === Qt.Key_Backtab || shift ? -1 : 1); event.accepted = true; return; }
        if (k === Qt.Key_Left)  { root.footerIdx = Math.max(0, root.footerIdx - 1); event.accepted = true; return; }
        if (k === Qt.Key_Right) { root.footerIdx = Math.min(root.footerActions.length - 1, root.footerIdx + 1); event.accepted = true; return; }
        if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) {
            const a = root.footerActions[root.footerIdx];
            if (a) root.footerRun(a.id);
            event.accepted = true;
            return;
        }
        if (k === Qt.Key_Escape) { root.setZone("field"); event.accepted = true; return; }
        // Escribir desde la franja vuelve al campo con esa letra.
        if (event.text.length === 1 && event.text >= " " && !(event.modifiers & Qt.ControlModifier)) {
            search.text = search.text + event.text;
            root.setZone("field");
            event.accepted = true;
        }
    }

    // ---- historial (fase 4): contexto de la visita --------------------------------

    function resultKey(r) {
        if (!r) return "";
        if (r.file === true) return "file:" + r.path;
        if (r.action !== undefined) return "";
        return "app:" + (r.id || r.name);
    }
    function saveContext() {
        const sel = root.selected >= 0 ? root.resultKey(root.results[root.selected]) : "run";
        return { query: root.query, sel: sel, y: list.contentY };
    }
    /** La consulta y la fila elegida; nunca lanza nada. */
    function restoreContext(ctx) {
        if (!ctx) return true;
        search.text = ctx.query || "";
        if (ctx.sel === "run" && root.runActive) root.selected = -1;
        for (let i = 0; i < root.results.length; i++)
            if (root.resultKey(root.results[i]) === ctx.sel) { root.selected = i; break; }
        list.contentY = Math.max(0, Math.min(ctx.y || 0, Math.max(0, list.contentHeight - list.height)));
        return true;
    }

    /** Entrar en el directorio seleccionado sin reteclear la ruta (Ctrl+→ / Tab). */
    function enterSelectedDir() {
        if (!root.fileActive) return;
        if (root.selected < 0 || root.selected >= root.resultCount) return;
        const e = root.results[root.selected];
        if (!e.isDir) return;
        search.text = root.fileDirTyped + e.name + "/";
        root.selected = 0;
    }

    /** Subir un directorio (Ctrl+←). El techo es `~/` o `/`. */
    function goUpDir() {
        if (!root.fileActive) return;
        let d = root.fileDirTyped;
        if (d.length <= 1) return;                 // "/" o "~"
        d = d.replace(/\/$/, "");
        const i = d.lastIndexOf("/");
        let up = i >= 0 ? d.slice(0, i + 1) : "~/";
        if (up.length === 0) up = "~/";
        search.text = up;
        root.selected = 0;
    }

    Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 40 * root.s

        Rectangle {
            anchors.fill: parent
            radius: Metrics.r(10) * root.s
            color: Qt.alpha(Theme.fg, 0.04)
            border.width: 1
            border.color: Theme.hair
        }

        Icon {
            id: glyph
            anchors.left: parent.left
            anchors.leftMargin: 10 * root.s
            anchors.verticalCenter: parent.verticalCenter
            name: root.fileActive ? "folder-open"
                : root.emojiActive ? "emoji"
                : root.calcActive ? "calc"
                : root.runActive ? "terminal" : "search"
            size: 14 * root.s
            color: (root.fileActive || root.emojiActive || root.calcActive || root.runActive) ? Theme.primary : Theme.outline
        }

        SearchField {
            id: search
            anchors.left: glyph.right
            anchors.leftMargin: 10 * root.s
            anchors.right: frameNav.left
            anchors.rightMargin: 8 * root.s
            anchors.verticalCenter: parent.verticalCenter
            height: parent.height
            s: root.s
            placeholder: "Search apps — or type a path"
            // `Ctrl+←/→` solo se roba al salto por palabra cuando significa algo.
            stepping: root.fileActive || root.subView || root.selHasActions
            backtabs: true
            onTextChanged: {
                root.actionEntry = null;   // teclear vuelve a la lista de apps
                root.windowsEntry = null;
                root.query = text;
                root.selected = root.defaultSelection();
            }
            onMoved: (d) => root.move(d)
            // Alt+⏎: las ventanas de la app; el resto, como siempre.
            onAccepted: (mods) => ((mods & Qt.AltModifier) !== 0) ? root.enterWindows() : root.activate(mods)
            onDismissed: root.windowsEntry !== null ? root.leaveWindows()
                : root.actionEntry !== null ? root.leaveActions() : root.requestClose()
            // Tab recorre la franja de acciones (fase 5A); ya no abre las acciones de la app.
            onTabbed: root.tabTo(1)
            onBacktabbed: root.tabTo(-1)
            onStepped: (dir) => root.fileActive
                ? (dir > 0 ? root.enterSelectedDir() : root.goUpDir())
                : root.windowsEntry !== null ? (dir < 0 ? root.leaveWindows() : undefined)
                : (dir > 0 ? root.enterActions() : root.leaveActions())
        }

        /** Back · Forward · Close (fase 4). */
        FrameNav {
            id: frameNav
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            s: root.s
            host: root.host
            onCloseRequested: root.requestClose()
        }

    }

    // Result context has its own line, so app names and counts cannot squeeze the query.
    Item {
        id: contextLine
        anchors.top: header.bottom
        anchors.topMargin: 8 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        height: 22 * root.s
        Text {
            id: contextLabel
            anchors.left: parent.left
            anchors.leftMargin: 8 * root.s
            anchors.verticalCenter: parent.verticalCenter
            text: root.fileActive ? "Files" : root.windowsEntry !== null ? "Windows"
                : root.actionEntry !== null ? "App actions" : "Applications"
            color: Theme.fg
            font.family: Typography.ui
            font.pixelSize: Typography.body * root.s
            font.weight: Typography.wMedium
        }
        Text {
            id: counter
            anchors.left: contextLabel.right
            anchors.leftMargin: 12 * root.s
            anchors.right: parent.right
            anchors.rightMargin: 8 * root.s
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideMiddle
            text: root.fileActive
                ? (root.fileDirDenied ? "permission denied"
                   : root.fileDirBad || root.fileDirMissing ? "no such path"
                   : root.fileListing ? "…"
                   : root.fileOverflow ? root.resultCount + "+ — filter"
                   : root.resultCount + " items")
                : root.windowsEntry !== null ? root.windowsEntry.name + " · " + root.resultCount
                    + (root.resultCount === 1 ? " window" : " windows")
                : root.actionEntry !== null ? root.actionEntry.name + " · " + root.resultCount + " actions"
                : root.resultCount + " / " + Apps.count
            color: Theme.outlineText
            font.family: Typography.mono
            font.pixelSize: Typography.caption * root.s
            font.features: { "tnum": 1 }
        }
    }

    Rectangle {
        id: rule
        anchors.top: contextLine.bottom
        anchors.topMargin: 6 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: Theme.hair
    }

    /** Calculator result, above the list; Enter copies it. */
    Item {
        id: calcRow
        anchors.top: rule.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: root.calcActive ? 34 * root.s : 0
        visible: root.calcActive
        clip: true
        // Empuja la lista hacia abajo: firme, para que las filas no reboten.
        Behavior on height {
            enabled: !Motion.still
            NumberAnimation { duration: Motion.page; easing.type: Easing.OutCubic }
        }

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 8 * root.s
            anchors.verticalCenter: parent.verticalCenter
            text: root.calcActive ? root.calc.display : ""
            color: Theme.primary
            font.family: Typography.ui
            font.pixelSize: Typography.display * root.s
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
        }

        Text {
            anchors.right: parent.right
            anchors.rightMargin: 8 * root.s
            anchors.verticalCenter: parent.verticalCenter
            // El tipo de resultado, por si se confunde con una app (futureApp-launcher §«Resultados»).
            text: root.calcCopied ? "Copied" : "Calculation  ·  ⏎ copy"
            color: root.calcCopied ? Theme.primary : Theme.outlineText
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }
    }

    /**
     * Fila de ejecucion, en el mismo hueco que la calculadora y con el mismo
     * lenguaje visual. Nunca se selecciona sola habiendo aplicaciones: se llega
     * con `↑` desde la primera fila, o es la unica cuando la busqueda no da nada.
     */
    Item {
        id: runRow
        anchors.top: calcRow.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: root.runActive ? 34 * root.s : 0
        visible: root.runActive
        clip: true
        // Empuja la lista hacia abajo: firme, para que las filas no reboten.
        Behavior on height {
            enabled: !Motion.still
            NumberAnimation { duration: Motion.page; easing.type: Easing.OutCubic }
        }

        readonly property bool current: root.selected < 0

        Rectangle {
            anchors.fill: parent
            anchors.topMargin: 1 * root.s
            anchors.bottomMargin: 1 * root.s
            radius: Metrics.r(8) * root.s
            color: runRow.current ? Theme.selBg
                : (runArea.containsMouse ? Theme.hoverBg : "transparent")
            Behavior on color { ColorAnimation { duration: Motion.fast } }
        }

        Rectangle {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            visible: runRow.current
            width: 2 * root.s
            height: parent.height * 0.42
            radius: Metrics.pill(width)
            color: Theme.primary
        }

        Text {
            id: runLabel
            anchors.left: parent.left
            anchors.leftMargin: 10 * root.s
            anchors.right: runHint.left
            anchors.rightMargin: 8 * root.s
            anchors.verticalCenter: parent.verticalCenter
            text: root.query.trim()
            elide: Text.ElideRight
            color: Theme.fg
            font.family: Typography.mono
            font.pixelSize: Typography.body * root.s
            font.weight: runRow.current ? Font.DemiBold : Font.Normal
        }

        Text {
            id: runHint
            anchors.right: parent.right
            anchors.rightMargin: 8 * root.s
            anchors.verticalCenter: parent.verticalCenter
            text: Apps.terminalWhy.length > 0 ? "Command  ·  ⏎ run  ·  no terminal: " + Apps.terminalWhy
                : "Command  ·  ⏎ run  ·  ⇧⏎ terminal"
            color: Theme.outlineText
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }

        MouseArea {
            id: runArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton
            onClicked: {
                root.selected = -1;
                root.activate(0);
            }
        }
    }

    /** La franja de acciones de la fila elegida (fase 5A): botones con su atajo. */
    Flow {
        id: footer
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: Math.max(30 * root.s, implicitHeight)
        spacing: 4 * root.s
        clip: true

        Repeater {
            model: root.footerActions
            delegate: ActionButton {
                required property var modelData
                required property int index
                s: root.s
                label: modelData.label
                focused: root.zone === "footer" && root.footerIdx === index
                onTriggered: root.footerRun(modelData.id)
            }
        }
    }

    ListView {
        id: list
        anchors.top: runRow.bottom
        anchors.topMargin: 4 * root.s
        anchors.left: parent.left
        // El hueco de la barra, del lado que diga Settings (futureApp-launcher §«Barra de
        // desplazamiento»): barra a 6·s de la marca de la fila elegida y a 4·s del borde
        // (2026-11-12: a 3·s la tocaba). Al otro lado, el margen de siempre.
        anchors.leftMargin: launcherHint.leftSide ? launcherHint.gap + launcherHint.width + 4 * root.s : 6 * root.s
        anchors.right: parent.right
        anchors.rightMargin: launcherHint.leftSide ? 0 : launcherHint.gap + launcherHint.width + 4 * root.s
        anchors.bottom: footer.top
        anchors.bottomMargin: 4 * root.s
        clip: true
        model: root.results
        currentIndex: root.selected
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: 0

        delegate: Item {
            id: row
            required property int index
            required property var modelData

            width: list.width
            /** Una fila, más el rótulo de sección si esta fila abre una. */
            height: (row.groupLabel.length > 0 ? 24 * root.s : 0) + 48 * root.s

            readonly property bool current: row.index === root.selected
            /** "FREQUENT" en la primera, "ALL APPS" donde se acaban las usadas. */
            readonly property string groupLabel: root.groupLabelAt(row.index)

            // 16A-2: nombre accesible de la fila (el texto visible lleva el marcado HTML)
            Accessible.role: Accessible.ListItem
            Accessible.name: String(row.modelData.name || "")
            Accessible.description: rowBody.openCount > 0
                ? rowBody.openCount + (rowBody.openCount === 1 ? " window open" : " windows open") : ""
            Accessible.selected: row.current
            Accessible.onPressAction: { root.selected = row.index; root.activate(0); }

            Text {
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.leftMargin: 10 * root.s
                height: 24 * root.s
                verticalAlignment: Text.AlignBottom
                bottomPadding: 3 * root.s
                visible: row.groupLabel.length > 0
                text: row.groupLabel
                color: Theme.outlineText
                font.family: Typography.ui
                font.pixelSize: Typography.label * root.s
                font.weight: Typography.wStrong
                font.letterSpacing: Typography.tracking * root.s
            }

            Item {
                id: rowBody
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                height: 48 * root.s

            Rectangle {
                anchors.fill: parent
                anchors.topMargin: 1 * root.s
                anchors.bottomMargin: 1 * root.s
                radius: Metrics.rSm * root.s
                color: Theme.controlBg("transparent", rowArea.containsMouse, rowArea.pressed && rowArea.containsMouse, row.current)
                Behavior on color { ColorAnimation { duration: Motion.fast } }
            }

            Rectangle {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                visible: row.current
                width: 2 * root.s
                height: parent.height * 0.42
                radius: Metrics.pill(width)
                color: Theme.primary
            }

            readonly property bool isFile: row.modelData.file === true
            readonly property bool isAction: row.modelData.action !== undefined
            readonly property bool isWin: row.modelData.win !== undefined
            readonly property bool isShell: row.modelData.shell !== undefined
            readonly property bool isEmoji: row.modelData.emoji !== undefined

            Image {
                id: icon
                anchors.left: parent.left
                anchors.leftMargin: 10 * root.s
                anchors.verticalCenter: parent.verticalCenter
                width: 28 * root.s
                height: 28 * root.s
                visible: !rowBody.isFile && !rowBody.isShell && !rowBody.isEmoji
                // Casi ninguna accion trae icono propio (medido: solo VSCodium): el de la app.
                source: rowBody.isFile || rowBody.isShell || rowBody.isEmoji ? ""
                    : rowBody.isAction ? Apps.iconSource(row.modelData.action.icon || row.modelData.entry.icon,
                                                     "application-x-executable")
                    : rowBody.isWin ? Apps.iconFor(row.modelData.entry)
                    : Apps.iconFor(row.modelData)
                sourceSize.width: Math.ceil(width * 2)
                sourceSize.height: Math.ceil(height * 2)
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                smooth: true
            }
            Icon {
                anchors.left: parent.left
                anchors.leftMargin: 12 * root.s
                anchors.verticalCenter: parent.verticalCenter
                visible: rowBody.isFile || rowBody.isShell
                name: rowBody.isShell ? "keyboard" : rowBody.isFile && row.modelData.isDir ? "folder" : "file"
                size: (rowBody.isShell ? 18 : 15) * root.s
                color: rowBody.isShell || (rowBody.isFile && row.modelData.isDir) ? Theme.primary : Theme.fgVariant
            }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 10 * root.s
                anchors.verticalCenter: parent.verticalCenter
                width: 28 * root.s
                visible: rowBody.isEmoji
                horizontalAlignment: Text.AlignHCenter
                text: rowBody.isEmoji ? row.modelData.emoji : ""
                color: Theme.fg
                font.family: "Noto Color Emoji"
                font.pixelSize: 22 * root.s
            }

            Column {
                anchors.left: parent.left
                anchors.leftMargin: 48 * root.s
                anchors.right: parent.right
                anchors.rightMargin: ((rowBody.hasActions ? 26 : 10) + (rowBody.openCount > 0 ? 24 : 0)) * root.s
                anchors.verticalCenter: parent.verticalCenter
                spacing: 3 * root.s

                Text {
                    width: parent.width
                    /**
                     * El tramo que has escrito va en el acento (2026-09-15). Sin
                     * esto, con veinte resultados no se ve POR QUÉ está cada uno
                     * en la lista ni por dónde ha coincidido lo que tecleaste.
                     * `StyledText` y no `RichText`: sólo hace falta una etiqueta
                     * y el texto viene de un `.desktop` ajeno, así que se escapa.
                     */
                    textFormat: Text.StyledText
                    text: rowBody.isFile
                        ? root.mark(row.modelData.name + (row.modelData.isDir ? "/" : ""), root.fileFrag)
                        : rowBody.isWin ? root.esc(row.modelData.name)
                        : root.mark(row.modelData.name, root.query)
                    elide: Text.ElideRight
                    color: Theme.fg
                    font.family: rowBody.isFile ? Typography.mono : Typography.ui
                    font.pixelSize: Typography.body * root.s
                    font.weight: row.current ? Typography.wStrong : Typography.wNormal
                }
                Text {
                    width: parent.width
                    visible: !rowBody.isFile && text.length > 0
                    // En la fila elegida de una app abierta, la pista de Ctrl+⏎ (QS-FUNC-012a).
                    text: rowBody.isFile ? ""
                        : rowBody.isWin ? ("Workspace " + row.modelData.win.workspace
                            + (row.modelData.win.monitor.length > 0 ? "  ·  " + row.modelData.win.monitor : "")
                            + (row.modelData.win.minimized ? "  ·  minimized" : ""))
                        : rowBody.isAction ? row.modelData.entry.name
                        : rowBody.isEmoji ? "Emoji"
                        : (row.current && rowBody.openCount > 0)
                          ? rowBody.openCount + (rowBody.openCount === 1 ? " window open" : " windows open") + "  ·  Ctrl+⏎ focus"
                        : root.secondLine(row.modelData)
                    elide: Text.ElideRight
                    color: Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.label * root.s
                }
            }

            /** La app tiene acciones: `Tab` / `Ctrl+→` las abre. */
            readonly property bool hasActions: !rowBody.isFile && !rowBody.isAction && Apps.hasActions(row.modelData)
            /** Ventanas abiertas de esta app (QS-FUNC-012a). */
            readonly property int openCount: root.openCountOf(row.modelData)
            /**
             * Ventanas abiertas: el punto y su número (fase 5A). Clic = la lista de ventanas
             * de la app, lo mismo que Alt+⏎ con el teclado.
             */
            Row {
                id: openBadge
                anchors.right: parent.right
                anchors.rightMargin: (rowBody.hasActions ? 28 : 12) * root.s
                anchors.verticalCenter: parent.verticalCenter
                visible: rowBody.openCount > 0
                spacing: 4 * root.s
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: rowBody.openCount
                    color: Theme.primary
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                    font.features: ({ "tnum": 1 })
                }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 6 * root.s
                    height: 6 * root.s
                    radius: Metrics.r(3) * root.s
                    color: Theme.primary
                }
            }
            Icon {
                anchors.right: parent.right
                anchors.rightMargin: 10 * root.s
                anchors.verticalCenter: parent.verticalCenter
                visible: rowBody.hasActions
                name: "chevron-right"
                size: 12 * root.s
                color: row.current ? Theme.primary : Theme.outline
            }

            MouseArea {
                id: rowArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    root.selected = row.index;
                    root.activate(0);
                }
            }

            MouseArea {
                anchors.fill: openBadge
                anchors.margins: -8 * root.s
                visible: rowBody.openCount > 0
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.selected = row.index; root.enterWindows(row.index); }
            }

            /** Con raton, el `›` abre las acciones en vez de lanzar la app. */
            MouseArea {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: 30 * root.s
                visible: rowBody.hasActions
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    root.selected = row.index;
                    root.enterActions();
                }
            }
            }
        }

        /**
         * El vacío dice qué hacer, no sólo que no hay nada (`components/Empty`).
         * Los tres motivos de estar vacío son distintos y pedían respuestas
         * distintas: aún no hay datos, no encaja nada, o la ruta no existe.
         */
        Empty {
            id: launcherEmpty
            anchors.centerIn: parent
            visible: root.resultCount === 0 && !root.calcActive && !root.runActive
            s: root.s
            loading: root.fileListing || (!root.fileActive && Apps.count === 0)
            glyph: root.fileActive ? "folder" : "search"
            text: root.fileActive
                ? (root.fileDirBad ? "Not a path"
                   : root.fileDirDenied ? "Permission denied"
                   : root.fileDirMissing ? "No such folder"
                   : root.fileListing ? "Reading…"
                   : root.fileFrag.length > 0 ? "Nothing here matches"
                   : "Empty folder")
                : (Apps.count === 0 ? "Loading applications…" : "No results")
            hint: root.fileActive
                ? (root.fileDirBad ? "Paths start with / or ~"
                   : root.fileListing ? ""
                   : "Ctrl+← goes up a level")
                : (Apps.count === 0 ? "" : "Type a path with / or ~, or a command to run")
        }
    }

    /**
     * La barra de desplazamiento (2026-09-15). Hermana de la lista, no hija:
     * un hijo de un `ListView` viaja dentro del contenido y se iria con el scroll.
     */
    // 9C-2: el lado sale de Settings → Shell → Launcher (a la izquierda, como hasta ahora)
    ScrollHint { id: launcherHint; view: list; s: root.s; leftSide: Settings.launcherScrollbar !== "right" }

}
