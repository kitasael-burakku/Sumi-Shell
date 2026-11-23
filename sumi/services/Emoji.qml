pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/glyph-search.js" as Search
import "../lib/terminal.js" as Terminal
import "../lib/xdg.js" as Xdg

/**
 * Selector de emojis y glifos (2026-11-17; informe docs/SUMI-EMOJI-2026-11-17.md).
 *
 * Datos: `lib/emoji/{emoji,kaomoji,symbols,nerdfont}.json`, generados por
 * `tools/emoji/build-data.py` desde Unicode Emoji 17.0 + CLDR 48 (en/es) y la cmap de
 * IosevkaTerm Nerd Font. Se leen BAJO DEMANDA: una pestaña sólo se carga cuando alguien la
 * pide (`want(tab)`), y todo se suelta un rato después de que nadie reclame (`claim`), como
 * `Clip`. Los 700 kB de Nerd Font no viven en memoria si no se usan.
 *
 * Uso: `emoji-usage.json` en el directorio de estado, `{usage: {"<pestaña>:<carácter>": {n, t}},
 * tab}`; único escritor (no se vigila, como `launcher-usage.json` de `Apps`).
 *
 * Elegir (`pick`): copia con `wl-copy` (texto plano por stdin) y, si se pidió pegar, envía
 * Ctrl+V (Ctrl+Shift+V en una terminal, `lib/terminal.js`) a la ventana que tenía el foco al
 * abrir, con `hl.dsp.send_shortcut` (sin wtype). El envío espera a que la capa se cierre:
 * mientras el layer-shell tiene el teclado, Hyprland no entrega la tecla (mismo plazo de 130 ms
 * que el Launcher y el minimizador). El temporizador vive aquí y no en la superficie, que puede
 * descargarse.
 */
Singleton {
    id: root

    readonly property var tabs: [
        { key: "emoji", title: "Emoji" },
        { key: "kaomoji", title: "Kaomoji" },
        { key: "symbols", title: "Symbols" },
        { key: "nerdfont", title: "Nerd Font" }
    ]
    function tabIndex(key) {
        for (let i = 0; i < root.tabs.length; i++) if (root.tabs[i].key === key) return i;
        return -1;
    }

    // ---- reclamación con nombre (el patrón de Clip) -------------------------------------------------

    property var claims: ({})
    readonly property bool wanted: Object.keys(root.claims).length > 0

    function claim(who, on) {
        if (on === !!root.claims[who]) return;
        const c = Object.assign({}, root.claims);
        if (on) c[who] = true; else delete c[who];
        root.claims = c;
        if (root.wanted) dropTimer.stop(); else dropTimer.restart();
    }

    /** Un minuto sin nadie: se sueltan los datos (volver a abrir los relee, ~20 ms). */
    Timer {
        id: dropTimer
        interval: 60000
        onTriggered: if (!root.wanted) root.drop()
    }

    // ---- datos por pestaña --------------------------------------------------------------------------

    /** Pestañas pedidas: { clave: true }. Sólo éstas tienen ruta en su FileView. */
    property var requested: ({})
    /** Conjuntos preparados (`Search.prepare`), o ausentes. */
    property var sets: ({})
    /** Sube cada vez que llega o se va un conjunto: las vistas leen `void Emoji.dataRev`. */
    property int dataRev: 0
    property var errors: ({})

    function want(tab) {
        if (root.tabIndex(tab) < 0 || root.requested[tab]) return;
        const r = Object.assign({}, root.requested);
        r[tab] = true;
        root.requested = r;
    }
    function setOf(tab) { void root.dataRev; return root.sets[tab] || null; }
    function loaded(tab) { void root.dataRev; return !!root.sets[tab]; }
    function errorOf(tab) { void root.dataRev; return root.errors[tab] || ""; }

    function drop() {
        root.requested = ({});
        root.sets = ({});
        root.errors = ({});
        root.dataRev++;
    }

    function _take(tab, text) {
        const s = Object.assign({}, root.sets);
        const e = Object.assign({}, root.errors);
        try {
            const data = JSON.parse(text);
            if (!data || data.format !== 1 || !Array.isArray(data.items)) throw new Error("bad format");
            s[tab] = Search.prepare(data);
            delete e[tab];
        } catch (err) {
            console.warn("emoji: could not read", tab, String(err));
            e[tab] = "Could not read the " + tab + " list";
        }
        root.sets = s;
        root.errors = e;
        root.dataRev++;
    }
    function _fail(tab) {
        const e = Object.assign({}, root.errors);
        e[tab] = "The " + tab + " list is missing";
        root.errors = e;
        root.dataRev++;
    }
    function _path(tab) {
        return root.wanted && root.requested[tab] ? Quickshell.shellPath("lib/emoji/" + tab + ".json") : "";
    }

    // Uno por pestaña, declarados (sin componente en línea: la recarga en caliente no los crea).
    FileView {
        path: root._path("emoji")
        printErrors: false
        onLoaded: root._take("emoji", text())
        onLoadFailed: root._fail("emoji")
    }
    FileView {
        path: root._path("kaomoji")
        printErrors: false
        onLoaded: root._take("kaomoji", text())
        onLoadFailed: root._fail("kaomoji")
    }
    FileView {
        path: root._path("symbols")
        printErrors: false
        onLoaded: root._take("symbols", text())
        onLoadFailed: root._fail("symbols")
    }
    FileView {
        path: root._path("nerdfont")
        printErrors: false
        onLoaded: root._take("nerdfont", text())
        onLoadFailed: root._fail("nerdfont")
    }

    // ---- búsqueda -----------------------------------------------------------------------------------

    /** Resultados de `query` en `tab` (lista de { c, n, g, … }), ordenados; [] sin consulta. */
    function search(tab, query, limit) {
        const set = root.setOf(tab);
        if (!set) return [];
        return Search.search(set, query, root.usage, tab + ":", limit || 0);
    }
    function recent(tab, n) {
        const set = root.setOf(tab);
        return set ? Search.recent(set, root.usage, tab + ":", n) : [];
    }
    function frequent(tab, n) {
        const set = root.setOf(tab);
        return set ? Search.frequent(set, root.usage, tab + ":", n) : [];
    }
    function group(tab, g) {
        const set = root.setOf(tab);
        return set && set.byGroup[g] ? set.byGroup[g] : [];
    }
    function groups(tab) {
        const set = root.setOf(tab);
        return set ? set.groups : [];
    }

    // ---- uso y pestaña recordada --------------------------------------------------------------------

    readonly property string stateDir: Xdg.base(Quickshell.env("XDG_STATE_HOME"), Quickshell.env("HOME") + "/.local/state") + "/sumi-shell"
    property var usage: ({})
    property string lastTab: "emoji"

    function rememberTab(tab) {
        if (root.tabIndex(tab) < 0 || tab === root.lastTab) return;
        root.lastTab = tab;
        root._save();
    }
    function _save() {
        usageFile.setText(JSON.stringify({ usage: root.usage, tab: root.lastTab }));
    }

    /** No se vigila: la shell es la única que escribe, y releer lo propio compite con el texto en caché. */
    FileView {
        id: usageFile
        path: root.stateDir + "/emoji-usage.json"
        blockLoading: true
        printErrors: false
        onLoadFailed: function (error) {
            if (error === FileViewError.FileNotFound) usageFile.setText("{}");
        }
    }
    Component.onCompleted: {
        try {
            const saved = JSON.parse(usageFile.text());
            if (saved && typeof saved.usage === "object" && !Array.isArray(saved.usage)) root.usage = saved.usage;
            if (saved && root.tabIndex(saved.tab) >= 0) root.lastTab = saved.tab;
        } catch (e) {
            root.usage = ({});
        }
    }

    // ---- elegir: copiar y, si se pide, pegar --------------------------------------------------------

    /** Lo que hay que hacer con lo elegido según el ajuste; `invert` (Shift+⏎) da lo contrario. */
    function actionFor(invert) {
        const paste = Settings.emojiAction === "paste";
        return (paste !== !!invert) ? "paste" : "copy";
    }

    /**
     * La ventana que tenía el foco al abrir el selector: { address, appId } o null. La pone la
     * superficie al abrirse (`target()`), antes de que nada cambie el foco.
     */
    function target() {
        const w = Toplevels.activeWindow;
        return w && w.address ? { address: w.address, appId: w.appId || "" } : null;
    }

    /** Elegir en vuelo: la revisión, 0 si ninguna. `settled(rev, ok, reason)` la resuelve. */
    property int rev: 0
    property int pickRev: 0
    property string pickMode: "copy"
    property var pickTarget: null
    readonly property bool busy: root.pickRev > 0
    property string lastError: ""
    signal settled(int rev, bool ok, string reason)

    /**
     * items: [{ tab, c }], en orden; mode: "copy" | "paste"; tgt: de `target()`. Devuelve la
     * revisión (0 si se rechaza: vacío u otro en vuelo). Kaomoji juntos llevan un espacio entre
     * ellos; lo demás va pegado (🔥🎉, →←).
     */
    function pick(items, mode, tgt) {
        if (!items || items.length === 0 || root.pickRev > 0) return 0;
        let text = "";
        let now = Date.now();
        let u = root.usage;
        for (let i = 0; i < items.length; i++) {
            const it = items[i];
            if (i > 0 && (it.tab === "kaomoji" || items[i - 1].tab === "kaomoji")) text += " ";
            text += it.c;
            u = Search.bump(u, it.tab + ":" + it.c, now++);
        }
        root.usage = u;
        root._save();
        root.rev++;
        root.pickRev = root.rev;
        root.pickMode = mode === "paste" ? "paste" : "copy";
        root.pickTarget = tgt || null;
        root.lastError = "";
        copyProc.running = false;
        copyProc.command = ["wl-copy", "--type", "text/plain;charset=utf-8"];
        // Reabrir stdin ANTES de cada arranque (Clip.qml, 2026-09-14): cerrarlo es el fin del contenido.
        copyProc.stdinEnabled = true;
        copyProc.running = true;
        copyProc.write(text);
        copyProc.stdinEnabled = false;
        return root.pickRev;
    }

    Process {
        id: copyProc
        stdinEnabled: true
        onExited: (code) => {
            const r = root.pickRev;
            if (r === 0) return;
            root.pickRev = 0;
            if (code !== 0) {
                root.lastError = "Could not write to the clipboard";
                root.settled(r, false, root.lastError);
                return;
            }
            // Pegar: la superficie se cierra al recibir `settled`; la tecla sale cuando la capa ya soltó el teclado.
            if (root.pickMode === "paste" && root.pickTarget) {
                root.pendingPaste = root.pickTarget;
                pasteTimer.restart();
            }
            root.settled(r, true, "");
        }
        // wl-copy ausente: `running` cae sin `exited` (memoria del proyecto)
        onRunningChanged: if (!running && root.pickRev > 0) Qt.callLater(function () {
            if (root.pickRev === 0 || copyProc.running) return;
            const r = root.pickRev;
            root.pickRev = 0;
            root.lastError = "wl-copy is not available";
            root.settled(r, false, root.lastError);
        })
    }

    property var pendingPaste: null
    /** Lo último enviado (diagnóstico y banco): { form, appId, at } o null. */
    property var lastPaste: null

    Timer {
        id: pasteTimer
        interval: 130
        onTriggered: {
            const t = root.pendingPaste;
            root.pendingPaste = null;
            if (!t) return;
            // En el cierre la ventana pudo irse: no se pega en otra.
            if (!Toplevels.windows.some(function (x) { return x.address === t.address; })) {
                console.warn("emoji: target window gone before paste");
                return;
            }
            const args = { mods: Terminal.pasteMods(t.appId), key: "V", address: t.address };
            const form = HyprCtl.form("sendShortcut", args);
            if (form === null) {
                console.warn("emoji: paste needs the Lua config (Hyprland 0.57+)");
                return;
            }
            HyprCtl.dispatch("sendShortcut", args);
            root.lastPaste = { form: form, appId: t.appId, at: Date.now() };
        }
    }

    function summary() {
        void root.dataRev;
        const loadedTabs = [];
        for (let i = 0; i < root.tabs.length; i++) if (root.sets[root.tabs[i].key]) loadedTabs.push(root.tabs[i].key);
        return { wanted: root.wanted, claims: Object.keys(root.claims), loaded: loadedTabs,
                 errors: root.errors, usageKeys: Object.keys(root.usage).length, lastTab: root.lastTab,
                 busy: root.busy, lastError: root.lastError, lastPaste: root.lastPaste };
    }
}
