pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Apariencia (2026-11-13): temas de iconos y de cursor en la shell y en las apps (Settings → Appearance → Icons).
 *
 * Todo lo que toca archivos lo hace `scripts/appearance.py` en su propio proceso; aquí sólo se pide y se enseña:
 *   overview      temas instalados (rutas XDG), lo que usa cada app, lo gestionado y GTK/Qt/XSettings
 *   draft         lo ELEGIDO en Settings: un borrador en memoria. Elegir no escribe nada (ni settings.json ni apps)
 *   plan          qué cambiaría el borrador en cada app (sólo lectura), con un token
 *   apply()       aplica SÓLO si el plan sigue siendo el enseñado; si sale bien, Settings guarda lo deseado
 *   undoLast() / undoAll()   vuelta atrás del helper (no pisa lo que cambiaste después)
 *
 * Coste: nada corre hasta que algo lo pide. Con la página abierta (`watching`), cada 4 s una consulta de la huella
 * de las carpetas de temas (un stat por carpeta; la respuesta es «unchanged» si nadie instaló ni quitó nada). Las
 * vistas previas son rutas de archivo (iconos del tema elegido, PNG de los cursores) y se guardan las últimas.
 * Colloid como predeterminado de Minimaru se retiró el 2026-11-13 a petición del autor (no le gustaron los iconos).
 * Al arrancar la shell: `session-start` da a Hyprland el cursor aplicado (una vez por sesión, diferido).
 * Seguir claro/oscuro: si el tema aplicado es la mitad de un par y cambia el modo CONFIRMADO del tema de colores,
 * se aplica la otra mitad (nunca con una preview de colores a medias).
 */
Singleton {
    id: root

    readonly property bool ready: true

    property var overview: null
    property string stamp: ""
    property var plan: null
    property string planKey: ""
    property var last: null
    property string error: ""
    property string busy: ""                     // "" · apply · rollback · recover
    /** Quién mira la página (Settings, con Claim): con alguien mirando se vigila la huella y vive el borrador. */
    property var claims: ({})
    readonly property bool watching: Object.keys(root.claims).length > 0
    function claim(who, on) {
        if (!!on === !!root.claims[who]) return;
        const c = Object.assign({}, root.claims);
        if (on) c[who] = true; else delete c[who];
        root.claims = c;
    }

    // ---- borrador -------------------------------------------------------------------------------------------------
    property var draft: ({ icons: "", cursor: "", size: 0 })
    property bool draftOpen: false

    readonly property var scan: root.overview ? root.overview.scan : null
    readonly property var targets: root.overview ? root.overview.targets : ({})
    readonly property var status: root.overview ? root.overview.status : null
    readonly property var desktop: root.overview ? root.overview.desktop : null
    readonly property var applied: root.status ? (root.status.want || {}) : ({})

    function _val(slot) { const t = root.targets[slot]; return t && t.state === "available" ? t.value : null; }
    /** Lo que usan las apps ahora (GTK 3 manda: es el que ven casi todas en Wayland). */
    readonly property string effectiveIcons: String(root._val("gtk.icons") || root._val("qt6.icons") || root._val("gtk4.icons") || "")
    readonly property string effectiveCursor: String(root._val("hyprland.cursor") || root._val("gtk.cursor") || "")
    readonly property int effectiveSize: {
        const h = root.targets["hyprland.cursor"];
        return Number(h && h.size ? h.size : (root._val("gtk.cursorSize") || 24));
    }

    property bool _draftSeeded: false
    function beginDraft(keepLast) {
        root.draft = { icons: Settings.iconTheme || root.effectiveIcons, cursor: Settings.cursorTheme || root.effectiveCursor,
                       size: Settings.cursorSize || root.effectiveSize };
        root._draftSeeded = root.overview !== null;
        root.draftOpen = true;
        if (keepLast !== true) root.last = null;
        root.requestPreviews();
        root.replan();
    }
    function endDraft() { root.draftOpen = false; root.plan = null; root.planKey = ""; }
    function setDraft(key, value) {
        if (root.draft[key] === value) return;
        const d = Object.assign({}, root.draft);
        d[key] = value;
        root.draft = d;
        root.last = null;
        root.requestPreviews();
        root.replan();
    }
    readonly property bool draftDirty: root.draftOpen && (root.draft.icons !== (Settings.iconTheme || root.effectiveIcons)
        || root.draft.cursor !== (Settings.cursorTheme || root.effectiveCursor)
        || root.draft.size !== (Settings.cursorSize || root.effectiveSize))

    // ---- familias y variantes -------------------------------------------------------------------------------------
    function iconInfo(name) { return root.scan ? (root.scan.icons.find(i => i.name === name) || null) : null; }
    function cursorInfo(name) { return root.scan ? (root.scan.cursors.find(c => c.name === name) || null) : null; }
    readonly property var familyNames: root.scan ? Object.keys(root.scan.families).sort((a, b) => a.localeCompare(b)) : []
    readonly property string draftFamily: { const i = root.iconInfo(root.draft.icons); return i ? i.family : ""; }
    readonly property var draftVariants: root.scan && root.draftFamily ? (root.scan.families[root.draftFamily] || []) : []
    /** El tono del modo de colores confirmado (una preview a medias no cuenta). */
    readonly property string mode: ThemePreview.confirmedOpts ? String(ThemePreview.confirmedOpts.lightness || "dark") : "dark"

    function pickFamily(fam) {
        const vs = root.scan ? (root.scan.families[fam] || []) : [];
        if (!vs.length) return;
        // el del mismo tono que el modo, si lo hay (Papirus-Dark con el modo oscuro); si no, el primero
        const want = Settings.iconFollowMode ? root.mode : "";
        const hit = vs.find(n => { const i = root.iconInfo(n); return i && i.tone === want; });
        root.setDraft("icons", hit || vs[0]);
    }
    /** El hermano con el otro tono (o ""), con la misma regla que el helper (appearance_themes.counterpart). */
    function counterpart(name, tone) {
        const i = root.iconInfo(name);
        if (!i || !root.scan) return "";
        const fam = root.scan.families[i.family] || [];
        const base = i.variant.replace(/ ?(Light|Dark|Mixed)$/, "");
        return fam.find(n => { const x = root.iconInfo(n); return x && x.tone === tone
                               && x.variant.replace(/ ?(Light|Dark|Mixed)$/, "") === base; }) || "";
    }

    // ---- vistas previas -------------------------------------------------------------------------------------------
    property var iconPreviews: ({})               // tema → [{name, path, from}]
    property var cursorPreviews: ({})             // "tema|tamaño" → [{name, path}]
    property var _iconOrder: []
    property var _cursorOrder: []
    readonly property var draftIconPreview: root.iconPreviews[root.draft.icons] || []
    /**
     * Iconos pequeños (barra y barras de herramientas, 24 px). Las variantes claro/oscuro de un tema casi nunca
     * traen carpetas ni iconos de apps propios (Papirus-Dark/-Light los heredan de Papirus: los mismos archivos), así
     * que la muestra grande no cambia entre variantes; éstos sí: Papirus-Light cambia los de estado y Papirus-Dark
     * los de acciones (medido el 2026-11-13).
     */
    readonly property var glyphNames: ["network-wireless-signal-excellent", "battery-good", "edit-copy", "document-save", "edit-find"]
    readonly property var draftGlyphPreview: root.iconPreviews[root.draft.icons + "|24"] || []
    readonly property var draftCursorPreview: root.cursorPreviews[root.draft.cursor + "|" + root.previewSize] || []
    readonly property int previewSize: Math.max(24, Math.min(64, root.draft.size || 24))
    /** Iconos de muestra: carpetas y tipos de archivo, más las apps que más abres en el lanzador. */
    readonly property var sampleNames: {
        const base = ["folder", "user-home", "folder-download", "text-x-generic", "image-x-generic", "utilities-terminal"];
        const u = Apps.usage || {};
        const ranked = Object.keys(u).sort((a, b) => u[b] - u[a]);
        const extra = [];
        for (const k of ranked) {
            const e = Apps.entries.find(x => x.id === k);
            const ic = e ? String(e.icon || "") : "";
            if (ic.length && ic[0] !== "/" && /^[A-Za-z0-9._+-]+$/.test(ic) && extra.indexOf(ic) < 0) extra.push(ic);
            if (extra.length >= 5) break;
        }
        return base.concat(extra);
    }
    function _remember(mapName, orderName, key, value) {
        const m = Object.assign({}, root[mapName]);
        const order = root[orderName].filter(k => k !== key).concat([key]);
        m[key] = value;
        while (order.length > 16) delete m[order.shift()];         // 8 temas × (muestra + iconos pequeños)
        root[orderName] = order;
        root[mapName] = m;
    }
    function requestPreviews() { previewTimer.restart(); }
    Timer {
        id: previewTimer
        interval: 120
        onTriggered: {
            const ic = root.draft.icons, cu = root.draft.cursor;
            if (ic && root.iconPreviews[ic] === undefined)
                root._preview("icons", ["icons", "--theme", ic, "--names", root.sampleNames.join(",")], ic);
            if (ic && root.iconPreviews[ic + "|24"] === undefined)
                root._preview("glyphs", ["icons", "--theme", ic, "--names", root.glyphNames.join(","), "--size", "24"], ic + "|24");
            if (cu && root.cursorPreviews[cu + "|" + root.previewSize] === undefined)
                root._preview("cursors", ["cursors", "--theme", cu, "--size", String(root.previewSize)], cu + "|" + root.previewSize);
        }
    }
    property var _previewQueue: []
    property bool _pvOut: false
    property bool _pvExit: false
    function _preview(kind, args, key) {
        if (previewProc.running || root._pvOut || root._pvExit) {
            root._previewQueue = root._previewQueue.filter(q => q.kind !== kind).concat([{kind, args, key}]);
            return;
        }
        previewProc.kind = kind; previewProc.key = key;
        previewProc.command = ["python3", "-B", Quickshell.shellPath("scripts/appearance.py")].concat(args);
        previewProc.running = true;
    }
    Process {
        id: previewProc
        property string kind: ""
        property string key: ""
        property string out: ""
        onStarted: { root._pvOut = false; root._pvExit = false; }
        stdout: StdioCollector { onStreamFinished: { previewProc.out = this.text; root._pvOut = true; root._previewDone(); } }
        onExited: { root._pvExit = true; root._previewDone(); }
    }
    function _previewDone() {
        if (!root._pvOut || !root._pvExit) return;
        root._pvOut = false; root._pvExit = false;
        let doc = null;
        try { doc = JSON.parse(previewProc.out.trim().split("\n").pop()); } catch (e) { doc = null; }
        if (doc && doc.ok === true) {
            if (previewProc.kind === "icons" || previewProc.kind === "glyphs")
                root._remember("iconPreviews", "_iconOrder", previewProc.key, doc.icons || []);
            else root._remember("cursorPreviews", "_cursorOrder", previewProc.key, doc.cursors || []);
        }
        const q = root._previewQueue;
        if (q.length) { const n = q[0]; root._previewQueue = q.slice(1); root._preview(n.kind, n.args, n.key); }
    }

    // ---- plan y aplicar -------------------------------------------------------------------------------------------
    readonly property string wantKey: root.draft.icons + "|" + root.draft.cursor + "|" + root.draft.size
    function _wantArgs() {
        const a = [];
        if (root.draft.icons) a.push("--icons", root.draft.icons);
        if (root.draft.cursor) a.push("--cursor", root.draft.cursor);
        if (root.draft.size) a.push("--size", String(root.draft.size));
        return a;
    }
    function replan() { planTimer.restart(); }
    Timer { id: planTimer; interval: 200; onTriggered: if (root.draftOpen) root._run("plan", ["plan"].concat(root._wantArgs()), root.wantKey) }
    readonly property bool fresh: root.plan !== null && root.planKey === root.wantKey && root.busy === ""
    readonly property int changes: root.plan ? root.plan.changes : 0
    readonly property bool canApply: root.fresh && root.plan.ok === true && Settings.writable
        && (root.changes > 0 || root.draft.icons !== Settings.iconTheme || root.draft.cursor !== Settings.cursorTheme
            || root.draft.size !== Settings.cursorSize)
    readonly property bool canUndo: root.busy === "" && root.status !== null && (root.status.managed || []).length > 0
    readonly property bool interrupted: root.status !== null && (root.status.pending || []).length > 0

    function slotPlan(slot) { return root.plan ? (root.plan.slots || []).find(s => s.slot === slot) || null : null; }

    function apply() {
        if (!root.canApply) return false;
        if (root.changes === 0) { root._savePrefs(root.draft); root.last = { ok: true, prefsOnly: true, results: [] }; return true; }
        root._run("apply", ["apply", "--expect", root.plan.token].concat(root._wantArgs()), JSON.stringify(root.draft));
        return true;
    }
    function undoLast() {
        if (!root.canUndo || !root.status.last) return false;
        root._run("rollback", ["rollback", "--tx", root.status.last]);
        return true;
    }
    function undoAll() {
        if (!root.canUndo) return false;
        root._run("rollback", ["rollback", "--all"]);
        return true;
    }
    function recover() { root._run("recover", ["recover"]); }
    function _savePrefs(w) {
        Settings.iconTheme = w.icons || "";
        Settings.cursorTheme = w.cursor || "";
        Settings.cursorSize = [16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 96].indexOf(w.size) >= 0 ? w.size : 0;
    }

    /** Una línea con el resultado de la última orden que escribió (o su error). */
    readonly property string lastLine: {
        const l = root.last;
        if (!l) return "";
        if (l.prefsOnly) return "Saved · the apps already used this";
        if (l.error === "plan-changed") return "Not applied: something changed since the preview · check again";
        if (!l.results) return l.reason ? "Not done: " + l.reason : "";
        const by = k => l.results.filter(r => k.indexOf(r.result) >= 0).map(r => r.label);
        const parts = [];
        const ok = by(["applied"]), back = by(["restored", "before"]), kept = by(["conflict"]);
        const bad = l.results.filter(r => ["applied", "restored", "before", "conflict"].indexOf(r.result) < 0);
        if (ok.length) parts.push("Applied: " + ok.join(", "));
        if (back.length) parts.push("Undone: " + back.join(", "));
        if (kept.length) parts.push("Left as you changed it: " + kept.join(", "));
        if (bad.length) parts.push("Failed: " + bad.map(r => r.label + (r.reason ? " (" + r.reason + ")" : "")).join(", "));
        if (!parts.length) return "Nothing to change";
        return parts.join(" · ");
    }
    readonly property bool lastBad: root.last !== null && root.last.ok !== true

    // ---- orden única ----------------------------------------------------------------------------------------------
    property var _queued: ({})
    function refresh(force) {
        root._run("overview", ["overview"].concat(force === true || !root.overview || !root.stamp ? [] : ["--stamp", root.stamp]));
    }
    function _run(kind, args, key) {
        if (proc.running || root._gotOut || root._exited) { const q = Object.assign({}, root._queued); q[kind] = {args: args, key: key || ""}; root._queued = q; return; }
        root.error = "";
        root.busy = ["apply", "rollback", "recover"].indexOf(kind) >= 0 ? kind : "";
        proc.kind = kind;
        proc.key = key || "";
        proc.command = ["python3", "-B", Quickshell.shellPath("scripts/appearance.py")].concat(args);
        proc.running = true;
    }
    /**
     * La salida y el fin del proceso llegan en cualquier orden: la orden se da por terminada sólo con las dos (si
     * no, la respuesta de una se leía como la de la siguiente, medido en el banco con «Restore»).
     */
    property bool _gotOut: false
    property bool _exited: false
    property string _outText: ""
    Process {
        id: proc
        property string kind: ""
        property string key: ""
        onStarted: { root._gotOut = false; root._exited = false; root._outText = ""; }
        stdout: StdioCollector {
            onStreamFinished: { root._outText = this.text; root._gotOut = true; root._finish(); }
        }
        onExited: { root._exited = true; root._finish(); }
    }
    function _finish() {
        if (!root._gotOut || !root._exited) return;
        root._gotOut = false; root._exited = false;
        const kind = proc.kind;
        let doc = null;
        try { doc = JSON.parse(root._outText.trim().split("\n").pop()); } catch (e) { doc = null; }
        root.busy = "";
        if (!doc) root.error = "The appearance helper didn't answer";
        else if (kind === "overview") {
            if (doc.unchanged !== true && doc.ok === true) { root.overview = doc; root.stamp = doc.stamp; }
            else if (doc.ok !== true) root.error = doc.reason || "";
        } else if (kind === "plan") { root.plan = doc; root.planKey = proc.key; }
        else if (kind !== "sessionStart") {
            root.last = doc;
            if (kind === "apply" && doc.results && doc.results.some(r => r.result === "applied")) {
                try { root._savePrefs(JSON.parse(proc.key)); } catch (e) {}
            }
            if (kind === "rollback") root._afterRollback = true;
            if (doc.ok !== true && !doc.results) root.error = doc.reason || doc.error || "";
        }
        if (kind !== "overview" && kind !== "plan" && kind !== "sessionStart") {
            // lo que escribe deja viejos el estado y el plan: se piden de nuevo (overview completo; sin huella, para
            // que la vigilancia periódica no lo cambie por un «unchanged»: las carpetas de temas no cambiaron)
            root.plan = null;
            root.stamp = "";
            const q = Object.assign({}, root._queued);
            q.overview = {args: ["overview"], key: ""};
            root._queued = q;
            Qt.callLater(root.replan);
        }
        const q = root._queued;
        for (const k of ["apply", "rollback", "recover", "overview", "plan", "sessionStart"]) {
            if (q[k]) { const item = q[k]; const n = Object.assign({}, q); delete n[k]; root._queued = n;
                        root._run(k, item.args, item.key); return; }
        }
    }
    /** Tras deshacer, Settings vuelve a lo que el registro dice que sigue aplicado (o a «no gestionado»). */
    property bool _afterRollback: false
    onOverviewChanged: {
        // diferido: en este aviso las propiedades derivadas (effectiveIcons…) aún pueden tener el valor viejo
        if (root.draftOpen && !root._draftSeeded && root.overview) { root._draftSeeded = true; Qt.callLater(() => root.beginDraft(true)); }
        // root.overview, no root.status: en este aviso la derivada aún puede ser la vieja
        if (root._afterRollback && root.overview && root.overview.status) {
            root._afterRollback = false;
            const w = root.overview.status.want || {};
            root._savePrefs({ icons: w.icons || "", cursor: w.cursor || "", size: w.cursorSize || 0 });
            if (root.draftOpen) Qt.callLater(() => root.beginDraft(true));
        }
        if (root._autoFollow) { root._autoFollow = false; Qt.callLater(root._followStep); }
    }

    // ---- vigilancia con la página abierta -------------------------------------------------------------------------
    Timer {
        interval: 4000
        repeat: true
        running: root.watching
        onTriggered: if (!proc.running) root.refresh(false)
    }
    onWatchingChanged: {
        if (root.watching) { root.refresh(root.overview === null); root.beginDraft(); }
        else root.endDraft();
    }

    // ---- seguir claro/oscuro --------------------------------------------------------------------------------------
    property bool _autoFollow: false
    property string _followTo: ""
    onModeChanged: {
        if (!Settings.iconFollowMode || !Settings.iconTheme || ThemePreview.phase === "active") return;
        if (root.applied.icons !== Settings.iconTheme) return;          // sólo si lo deseado está aplicado
        root._autoFollow = true;
        root.refresh(true);
    }
    function _followStep() {
        root._autoFollow = false;
        const to = root.counterpart(Settings.iconTheme, root.mode);
        if (!to || to === Settings.iconTheme) return;
        root._followTo = to;
        followPlan.command = ["python3", "-B", Quickshell.shellPath("scripts/appearance.py"), "plan", "--icons", to];
        followPlan.running = true;
    }
    Process {
        id: followPlan
        stdout: StdioCollector {
            onStreamFinished: {
                let doc = null;
                try { doc = JSON.parse(text.trim().split("\n").pop()); } catch (e) { doc = null; }
                if (!doc || doc.ok !== true || !doc.changes) return;
                const w = { icons: root._followTo, cursor: Settings.cursorTheme, size: Settings.cursorSize };
                root._run("apply", ["apply", "--expect", doc.token, "--icons", root._followTo], JSON.stringify(w));
            }
        }
    }

    // ---- arranque -------------------------------------------------------------------------------------------------
    Timer {
        interval: 3000
        running: true
        onTriggered: root._run("sessionStart", ["session-start"])
    }
}
