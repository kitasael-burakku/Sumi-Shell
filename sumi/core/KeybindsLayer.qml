pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import "../services"
import "../theme"
import "../components"

/**
 * La ayuda de atajos (2026-10-30): una tarjeta flotante como Calendar/Monitor/Audio, NO una surface. Las acciones de
 * GlobalShortcut de la shell por categorías, búsqueda por título, identificador, descripción o combinación, la tecla
 * EFECTIVA cuando Hyprland deja identificarla y, si no, por qué. La tecla por defecto sólo se enseña rotulada como tal.
 *
 * Sólo lectura (fase 1): Hyprland es el dueño de las combinaciones. El detalle está separado de la lista para que una
 * edición futura sea otra sección del detalle, sin tocar la lista ni el modelo (services/Keybinds).
 *
 * Teclado, en cuatro zonas (Tab / Mayús+Tab las recorren): search (escribir filtra; ↑/↓ mueven la selección; Enter
 * pasa al detalle), chips (←/→ cambian de categoría), list (↑/↓/RePág/AvPág/Inicio/Fin; Enter o → al detalle; escribir
 * vuelve a la búsqueda) y detail (←/→ entre botones, Enter los pulsa). Esc retrocede: confirmación → detalle → lista →
 * borra la búsqueda → cierra. Una acción que cambia algo al momento (wallRandom, barToggle, keepAwake) pide confirmar
 * con Cancel enfocado primero; Power sólo abre su surface, que ya confirma lo suyo.
 */
PanelWindow {
    id: win
    required property var targetScreen
    readonly property string name: win.targetScreen ? win.targetScreen.name : ""
    readonly property real s: Settings.uiScale
    readonly property bool shown: KeybindsUi.open && KeybindsUi.screen === win.name && !Lock.engaged
    readonly property real margin: Metrics.storeMargin * win.s
    readonly property real topInset: Math.max(Metrics.reservedH(win.s), Metrics.reservedBarH(win.s))
    /** 2026-11-19: la barra permanente abajo o a un lado no se tapa: su franja, además del margen (Screen.barInset). */
    readonly property var barHost: Screens.byName(win.targetScreen ? String(win.targetScreen.name) : "")
    readonly property real leftInset: win.margin + (win.barHost ? win.barHost.barInset("left") : 0)
    readonly property real rightInset: win.margin + (win.barHost ? win.barHost.barInset("right") : 0)
    readonly property real bottomInset: win.margin + (win.barHost ? win.barHost.barInset("bottom") : 0)
    readonly property real areaW: win.targetScreen ? win.targetScreen.width : 0
    readonly property real areaH: win.targetScreen ? win.targetScreen.height : 0
    screen: win.targetScreen
    visible: win.shown || card.appear > 0.001
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "sumi-keybinds"
    WlrLayershell.keyboardFocus: win.shown ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    anchors { top: true; left: true; right: true; bottom: true }
    mask: win.shown ? cardRegion : noRegion
    Region { id: noRegion }
    /**
     * La región de entrada es la geometría de la tarjeta, SIN la transformación de la entrada (escala y subida de
     * `Reveal`): `item: card` la tomaba con la escala/subida del primer fotograma y no se recalculaba al acabar la
     * animación (sólo al mover o redimensionar), así que con Expressive quedaban muertos ~28 px de la cabecera y
     * ~20 px por lado (2026-11-11, tools/sumi-drag/).
     */
    Region { id: cardRegion; x: card.x; y: card.y; width: card.width; height: card.height }

    // ---- estado de la vista ------------------------------------------------------------------------------------------
    property string query: ""
    /** "" = todas. */
    property string category: ""
    property string selected: ""
    property string zone: "search"
    property int chipIdx: 0
    property int detailIdx: 0
    /** La acción que espera confirmación ("" = ninguna). */
    property string confirming: ""
    property string doneText: ""
    readonly property bool split: card.width >= 760 * win.s
    /** Con sitio: las categorías en una columna a la izquierda (si no, en una fila que se desplaza). */
    readonly property bool rail: card.width >= 1060 * win.s

    // Escala local de esta ventana de lectura; no cambia la tipografía del resto de la shell.
    readonly property real bodySize: 15 * Typography.textScale * win.s
    readonly property real labelSize: 13 * Typography.textScale * win.s
    readonly property real captionSize: 12 * Typography.textScale * win.s
    // El acento claro no contrasta sobre la baldosa pastel: elegir el tono de la paleta
    // con mayor contraste contra SU fondo (no contra el fondo general de la ventana).
    readonly property color tileGlyph: Theme.contrast(Theme.fgOnPrimary, Theme.tintPrimarySoft)
        >= Theme.contrast(Theme.primary, Theme.tintPrimarySoft) ? Theme.fgOnPrimary : Theme.primary

    /** Las filas visibles, en el orden del catálogo, con una cabecera por categoría: [{kind, …}]. */
    readonly property var items: {
        const res = Keybinds.resolved;      // dependencias explícitas: estado leído, búsqueda y categoría
        const q = win.query, cat = win.category;
        const out = [];
        for (const c of Keybinds.categories) {
            const inCat = Keybinds.actions.filter(a => a.category === c.id && (cat === "" || cat === c.id)
                                                       && Keybinds.matches(q, a.name));
            if (inCat.length === 0) continue;
            out.push({ kind: "header", title: c.title, name: "" });
            for (const a of inCat) out.push({ kind: "row", name: a.name, title: a.title, glyph: a.glyph,
                                              description: a.description, category: c.id });
        }
        return out;
    }
    readonly property var rowNames: win.items.filter(i => i.kind === "row").map(i => i.name)
    readonly property var chips: {
        const res = Keybinds.resolved;
        const q = win.query;
        const all = Keybinds.actions.filter(a => Keybinds.matches(q, a.name));
        const out = [{ id: "", title: "All", count: all.length }];
        for (const c of Keybinds.categories)
            out.push({ id: c.id, title: c.title, count: all.filter(a => a.category === c.id).length });
        return out;
    }
    readonly property var selAction: Keybinds.action(win.selected)
    readonly property var selRow: { const res = Keybinds.resolved; const st = Keybinds.status; return Keybinds.rowOf(win.selected); }
    readonly property string whyNot: win.selAction ? Screens.shortcutWhyNot(win.selected) : ""
    readonly property bool showSnippet: !!win.selAction && win.selRow.state !== "bound"
    /** Los botones del detalle, en orden de teclado. */
    readonly property var detailButtons: {
        if (!win.selAction) return [];
        if (win.confirming.length > 0 && win.confirming === win.selected) return ["cancel", "confirm"];
        const b = [];
        // la propia ayuda no se ofrece a sí misma (Open la cerraría)
        if (win.whyNot.length === 0 && win.selected !== "keybinds") b.push("open");
        if (win.showSnippet) b.push("copy");
        return b;
    }

    onItemsChanged: Qt.callLater(win.ensureSelection)
    onSelectedChanged: { win.confirming = ""; win.doneText = ""; win.copied = false; detail.contentY = 0; Qt.callLater(win.revealSelected); }
    onDetailButtonsChanged: if (win.detailIdx >= win.detailButtons.length) win.detailIdx = Math.max(0, win.detailButtons.length - 1)

    function ensureSelection() {
        if (win.rowNames.length === 0) { win.selected = ""; if (win.zone === "list" || win.zone === "detail") win.setZone("search"); return; }
        if (win.rowNames.indexOf(win.selected) === -1) win.selected = win.rowNames[0];
    }
    function itemIndexOf(name) {
        for (let i = 0; i < win.items.length; i++) if (win.items[i].kind === "row" && win.items[i].name === name) return i;
        return -1;
    }
    function revealSelected() {
        const i = win.itemIndexOf(win.selected);
        if (i < 0) return;
        // la primera y la última fila: al principio o al final de verdad (con alturas distintas, ListView estima)
        if (win.rowNames.indexOf(win.selected) === 0) { list.positionViewAtBeginning(); return; }
        if (win.rowNames.indexOf(win.selected) === win.rowNames.length - 1) { list.positionViewAtEnd(); return; }
        // la cabecera de la primera fila de una categoría también a la vista
        list.positionViewAtIndex(i > 0 && win.items[i - 1].kind === "header" ? i - 1 : i, ListView.Contain);
        list.positionViewAtIndex(i, ListView.Contain);
        // que la fila no quede bajo la cabecera fija: si asoma ahí, subir lo que falta y 1 px más (el borde de la banda
        // cae en fracción de píxel con la escala; pegada a él, la fila podía quedar medio píxel debajo)
        const d = list.itemAtIndex(i), band = sticky.height + 1;
        if (d && list.contentY > 2 && d.y < list.contentY + band)
            list.contentY = Math.max(list.originY, d.y - band);
    }
    function step(delta) {
        const n = win.rowNames;
        if (n.length === 0) return false;
        const at = n.indexOf(win.selected);
        win.selected = n[Math.max(0, Math.min(n.length - 1, (at < 0 ? 0 : at) + delta))];
        return true;
    }
    readonly property int pageRows: Math.max(1, Math.floor(list.height / (80 * win.s)) - 1)

    function setZone(z) {
        if ((z === "list" || z === "detail") && win.rowNames.length === 0) z = "search";
        // ancho: sin botones el detalle ya se ve al lado; estrecho: entrar es la única manera de verlo
        if (z === "detail" && win.detailButtons.length === 0 && win.split) z = "list";
        win.zone = z;
        if (z === "search") { search.focusField(); return; }
        if (z === "chips") win.chipIdx = Math.max(0, win.chips.findIndex(c => c.id === win.category));
        if (z === "detail") win.detailIdx = 0;
        keys.forceActiveFocus();
    }
    function nextZone(dir) {
        const order = ["search", "chips", "list", "detail"].filter(z =>
            (z !== "list" || win.rowNames.length > 0)
            && (z !== "detail" || (win.rowNames.length > 0 && (win.detailButtons.length > 0 || !win.split))));
        const at = Math.max(0, order.indexOf(win.zone));
        win.setZone(order[(at + dir + order.length) % order.length]);
    }
    /** El ancho de las categorías puestas en fila (estrecho): lo mide el Repeater, no el Flow (que envolvería). */
    readonly property real chipRowWidth: {
        let w = 0;
        for (let i = 0; i < chipRep.count; i++) { const c = chipRep.itemAt(i); if (c) w += c.width + 6 * win.s; }
        return w;
    }
    /** La categoría con el foco, a la vista (estrecho: la fila se desplaza). */
    function revealChip() {
        const c = chipRep.itemAt(win.chipIdx);
        if (!c || win.rail) return;
        if (c.x < chipFlick.contentX) chipFlick.contentX = Math.max(0, c.x - 8 * win.s);
        else if (c.x + c.width > chipFlick.contentX + chipFlick.width)
            chipFlick.contentX = Math.min(chipFlick.contentWidth - chipFlick.width, c.x + c.width - chipFlick.width + 8 * win.s);
    }
    /** El botón con el foco, a la vista dentro del detalle (que se desplaza si no cabe). */
    function revealButton() {
        const it = buttonRep.itemAt(win.detailIdx);
        if (!it) return;
        const y = it.mapToItem(detailCol, 0, 0).y;
        if (y < detail.contentY) detail.contentY = Math.max(0, y - 8 * win.s);
        else if (y + it.height > detail.contentY + detail.height)
            detail.contentY = Math.min(Math.max(0, detail.contentHeight - detail.height), y + it.height - detail.height + 8 * win.s);
    }
    onChipIdxChanged: Qt.callLater(win.revealChip)
    onDetailIdxChanged: if (win.zone === "detail") Qt.callLater(win.revealButton)
    onZoneChanged: if (win.zone === "detail") Qt.callLater(win.revealButton)
    function setCategory(id) {
        win.category = id;
        win.chipIdx = Math.max(0, win.chips.findIndex(c => c.id === id));
    }

    // ---- acciones ----------------------------------------------------------------------------------------------------
    property bool copied: false
    function press(button) {
        if (button === "open") return win.runSelected();
        if (button === "copy") return win.copySnippet();
        if (button === "cancel") { win.cancelConfirm(); return true; }
        if (button === "confirm") return win.runSelected();
        return false;
    }
    function cancelConfirm() {
        win.confirming = "";
        // el foco vuelve al botón que abrió la pregunta
        win.zone = "detail"; win.detailIdx = Math.max(0, win.detailButtons.indexOf("open"));
        keys.forceActiveFocus();
    }
    /** Lo mismo que la tecla: Screens.runShortcut. Nunca se simula una pulsación. */
    function runSelected() {
        const a = win.selAction;
        if (!a || Screens.shortcutWhyNot(a.name).length > 0) return false;
        if (a.effect === "change") {
            if (win.confirming !== a.name) {
                win.confirming = a.name; win.zone = "detail"; win.detailIdx = 0;   // Cancel primero
                keys.forceActiveFocus();
                return true;
            }
            win.confirming = "";
            const ok = Screens.runShortcut(a.name, win.name, "keybinds");
            win.doneText = ok ? "Done" : "It didn't run";
            win.detailIdx = Math.max(0, win.detailButtons.indexOf("open"));
            keys.forceActiveFocus();
            return ok;
        }
        // una vista: la ayuda se aparta y se abre lo pedido en esta pantalla (sin volver al origen)
        const n = a.name, scr = win.name;
        KeybindsUi.close(false);
        Qt.callLater(() => Screens.runShortcut(n, scr, "keybinds"));
        return true;
    }
    function copySnippet() {
        if (!win.selAction) return false;
        Quickshell.execDetached(["sh", "-c", "printf '%s' \"$1\" | wl-copy", "_", Keybinds.luaLine(win.selected)]);
        win.copied = true;
        return true;
    }
    /** El estado actual de lo que cambia una acción de «change», en vivo. */
    readonly property string liveState: {
        const n = win.selected;
        if (n === "keybinds") return "This is the window you're in";
        if (n === "keepAwake") return "Keep awake is " + (Session.keepAwake ? "on" : "off");
        if (n === "barToggle" || n === "dockToggle") {
            // nombres públicos (2026-11-24); los valores guardados siguen siendo `bar`/`island` y `dock`
            const bar = Settings.monitorPref(win.targetScreen, "presentation", "island") === "bar";
            const edge = Settings.monitorPref(win.targetScreen, "dock", false) === true;
            return "This screen shows " + (bar ? (edge ? "Bar-Edge" : "the Dynamic Bar") : (edge ? "Edge" : "the Dynamic Capsule"));
        }
        return "";
    }

    // ---- textos ------------------------------------------------------------------------------------------------------
    function badge(st) {
        if (st === "unknown") return "Key not identifiable";
        if (st === "unbound") return "No binding found";
        if (st === "unread") return "Couldn't read Hyprland";
        if (st === "reading") return "Reading…";
        return "";
    }
    readonly property string stateHeadline: {
        const r = win.selRow;
        if (r.state === "bound") return r.keys.length === 1 ? "Your key" : "Your " + r.keys.length + " keys";
        return win.badge(r.state);
    }
    readonly property string stateExplain: {
        const r = win.selRow;
        const sum = Keybinds.resolved ? Keybinds.resolved.summary : null;
        if (r.state === "bound")
            return r.keys.some(k => k.how === "description")
                ? "From your Hyprland config, matched by its description."
                : "From your Hyprland config.";
        if (r.state === "unknown") {
            const n = sum ? sum.unnamedGlobals : 0;
            return n > 0
                ? "Hyprland has " + n + (n === 1 ? " global-shortcut binding" : " global-shortcut bindings")
                  + " without a named action. This may be one of them; its key is unknown."
                : "Its key can't be determined.";
        }
        if (r.state === "unbound") {
            const f = sum ? sum.opaque : 0;
            return "Nothing in Hyprland can be verified to open it." + (f > 0
                ? " " + f + (f === 1 ? " binding runs a Lua function" : " bindings run Lua functions") + ", which Hyprland can't show." : "");
        }
        if (r.state === "unread") return Keybinds.error.length > 0 ? Keybinds.error : "Hyprland's bindings couldn't be read.";
        return "";
    }
    readonly property string statusText: {
        if (!Keybinds.catalogOk) return "The shortcut catalog (lib/shortcuts.json) is missing or unreadable";
        if (Keybinds.status === "reading" || Keybinds.status === "idle") return "Reading Hyprland's bindings…";
        if (Keybinds.status === "error") return "Couldn't read Hyprland's bindings · " + Keybinds.error + " · keys are unknown";
        const sum = Keybinds.resolved.summary;
        const c = sum.counts;
        const parts = [];
        if (c.unknown > 0) parts.push(c.unknown + " shortcuts have a key Hyprland doesn't name");
        if (c.unbound > 0) parts.push(c.unbound + " not bound");
        let t = parts.join(" · ");
        if (sum.unnamedGlobals > 0) t += " · only bindings with their description show their key";
        return t;
    }
    readonly property string statusTone: !Keybinds.catalogOk || Keybinds.status === "error" ? "warn"
        : Keybinds.resolved && Keybinds.resolved.summary.counts.unknown > 0 ? "warn" : "info"
    /** El resumen de la cabecera: cuántos atajos, cuántos con tecla y de qué Hyprland. */
    readonly property string summaryLine: {
        const n = Keybinds.actions.length + " shell shortcuts";
        const v = Keybinds.hyprVersion ? " · Hyprland " + Keybinds.hyprVersion : "";
        if (Keybinds.status === "ready" && Keybinds.resolved)
            return n + " · " + Keybinds.resolved.summary.counts.bound + " with a key" + v;
        if (Keybinds.status === "error") return n + " · keys unknown" + v;
        return n + " · reading Hyprland…";
    }
    /** La sección de lo que asoma arriba de la lista (la cabecera fija). */
    readonly property string topSection: {
        const y = list.contentY;
        const i = list.indexAt(4, y + 2);
        const it = i >= 0 ? win.items[i] : null;
        return it ? (it.kind === "header" ? it.title : Keybinds.categoryTitle(it.category)) : "";
    }
    /** La tecla por defecto es una de las efectivas. */
    readonly property bool defaultSame: {
        const d = Keybinds.defaultCaps(win.selected).join("+").toLowerCase();
        return win.selRow.state === "bound" && win.selRow.keys.some(k => k.caps.join("+").toLowerCase() === d);
    }

    // ---- contexto, teclado e IPC -------------------------------------------------------------------------------------
    function saveContext() {
        return { query: win.query, category: win.category, selected: win.selected,
                 zone: win.zone === "detail" ? "list" : win.zone };
    }
    /** Al reabrir vuelve la fila elegida, no el filtro: una búsqueda vieja escondería acciones sin decir por qué. */
    function restoreContext(ctx) {
        search.text = "";
        win.category = "";
        if (ctx && ctx.selected) win.selected = ctx.selected;
    }
    function handle(k, mods, text) {
        if (!win.shown) return false;
        const ctrl = (mods & Qt.ControlModifier) !== 0;
        const shift = (mods & Qt.ShiftModifier) !== 0;
        if (k === Qt.Key_Escape) {
            if (win.confirming.length > 0) { win.cancelConfirm(); return true; }
            if (win.zone === "detail") { win.setZone("list"); return true; }
            if (win.zone === "chips" || win.zone === "list") { win.setZone("search"); return true; }
            if (win.query.length > 0) { search.clear(); return true; }
            KeybindsUi.close();
            return true;
        }
        if (k === Qt.Key_Tab || k === Qt.Key_Backtab) { win.nextZone(k === Qt.Key_Backtab || shift ? -1 : 1); return true; }
        if (k === Qt.Key_F5 || (ctrl && k === Qt.Key_R)) { Keybinds.refresh("key"); return true; }
        if (ctrl && k === Qt.Key_F) { win.setZone("search"); return true; }
        if (win.zone === "search") {
            if (k === Qt.Key_Up || k === Qt.Key_Down) return win.step(k === Qt.Key_Up ? -1 : 1);
            if (k === Qt.Key_PageUp || k === Qt.Key_PageDown) return win.step((k === Qt.Key_PageUp ? -1 : 1) * win.pageRows);
            if (k === Qt.Key_Return || k === Qt.Key_Enter) { if (win.rowNames.length > 0) win.setZone("detail"); return true; }
            return false;
        }
        if (win.zone === "chips" && win.rail) {
            // la columna de categorías: ↑/↓ las recorren y filtran; → o Enter pasan a la lista
            if (k === Qt.Key_Up || k === Qt.Key_Down) {
                win.chipIdx = Math.max(0, Math.min(win.chips.length - 1, win.chipIdx + (k === Qt.Key_Up ? -1 : 1)));
                win.category = win.chips[win.chipIdx].id;
                return true;
            }
            if (k === Qt.Key_Right || k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) { win.setZone("list"); return true; }
            if (k === Qt.Key_Left) return true;
        }
        if (win.zone === "chips") {
            if (k === Qt.Key_Left || k === Qt.Key_Right) {
                win.chipIdx = Math.max(0, Math.min(win.chips.length - 1, win.chipIdx + (k === Qt.Key_Left ? -1 : 1)));
                win.category = win.chips[win.chipIdx].id;
                return true;
            }
            if (k === Qt.Key_Down || k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) { win.setZone("list"); return true; }
            if (k === Qt.Key_Up) { win.setZone("search"); return true; }
        }
        if (win.zone === "list") {
            if (k === Qt.Key_Up || k === Qt.Key_Down) return win.step(k === Qt.Key_Up ? -1 : 1);
            if (k === Qt.Key_PageUp || k === Qt.Key_PageDown) return win.step((k === Qt.Key_PageUp ? -1 : 1) * win.pageRows);
            if (k === Qt.Key_Home) return win.step(-win.rowNames.length);
            if (k === Qt.Key_End) return win.step(win.rowNames.length);
            if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Right) { win.setZone("detail"); return true; }
        }
        if (win.zone === "detail") {
            const n = win.detailButtons.length;
            if (k === Qt.Key_Left || k === Qt.Key_Up) { win.detailIdx = Math.max(0, win.detailIdx - 1); return true; }
            if (k === Qt.Key_Right || k === Qt.Key_Down) { win.detailIdx = Math.min(n - 1, win.detailIdx + 1); return true; }
            if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space)
                return n > 0 ? win.press(win.detailButtons[win.detailIdx]) : false;
        }
        // escribir fuera del campo vuelve a él (sólo imprimibles: Supr trae «\x7f»)
        if (win.zone !== "search" && text && text.length === 1 && text >= " " && text !== "\x7f" && !ctrl) {
            win.setZone("search");
            search.text = search.text + text;
            return true;
        }
        return false;
    }
    function key(name) {
        const map = { Escape: Qt.Key_Escape, Return: Qt.Key_Return, Up: Qt.Key_Up, Down: Qt.Key_Down, Left: Qt.Key_Left,
                      Right: Qt.Key_Right, PageUp: Qt.Key_PageUp, PageDown: Qt.Key_PageDown, Home: Qt.Key_Home,
                      End: Qt.Key_End, Tab: Qt.Key_Tab, Backtab: Qt.Key_Backtab, Space: Qt.Key_Space, F5: Qt.Key_F5,
                      F: Qt.Key_F, R: Qt.Key_R };
        const ctrl = String(name).indexOf("Ctrl+") === 0;
        const k = ctrl ? String(name).substring(5) : String(name);
        if (map[k] === undefined) return false;
        // Up/Down en el campo los manda el propio campo (señal moved): la misma función
        return win.handle(map[k], ctrl ? Qt.ControlModifier : 0, "");
    }
    function typeText(t) {
        win.setZone("search");
        search.text = String(t || "");
        return true;
    }
    function clickRow(name) {
        if (win.rowNames.indexOf(name) === -1) return false;
        win.selected = name; win.setZone("list");
        return true;
    }

    function clampX(x) { return Math.max(win.leftInset, Math.min(win.areaW - card.width - win.rightInset, x)); }
    function clampY(y) { return Math.max(win.topInset, Math.min(win.areaH - card.height - win.bottomInset, y)); }
    function place() {
        if (win.areaW <= 0 || win.areaH <= 0) return;
        const p = KeybindsUi.positionOf(win.name);
        card.x = win.clampX(p ? p.x : (win.areaW - card.width) / 2);
        card.y = win.clampY(p ? p.y : (win.areaH - card.height) / 2);
    }
    function placeAt(x, y) {
        if (!win.shown) return false;
        card.x = win.clampX(x); card.y = win.clampY(y);
        KeybindsUi.remember(win.name, card.x, card.y);
        return true;
    }
    function geometry() {
        return { screen: win.name, shown: win.shown, x: card.x, y: card.y, w: card.width, h: card.height,
                 screenW: win.areaW, screenH: win.areaH, topInset: win.topInset, margin: win.margin, split: win.split,
                 appear: card.appear, dragging: head.drag.active };
    }
    /** Dónde está cada cosa, en coordenadas de la pantalla (la capa la cubre entera): para probar con un puntero. */
    function boxOf(it) {
        if (!it || !it.visible || it.width <= 0) return null;
        const p = it.mapToItem(null, 0, 0);
        return { x: Math.round(p.x), y: Math.round(p.y), w: Math.round(it.width), h: Math.round(it.height) };
    }
    function hitTargets() {
        const chips = [], rows = [], buttons = [];
        const cr = win.rail ? railRep : chipRep;
        for (let i = 0; i < cr.count; i++) {
            const c = cr.itemAt(i), b = win.boxOf(c);
            if (b) chips.push(Object.assign({ id: c.modelData.id }, b));
        }
        const top = listClip.mapToItem(null, 0, 0).y;
        for (let i = 0; i < win.items.length; i++) {
            const d = list.itemAtIndex(i), b = d && d.isRow ? win.boxOf(d) : null;
            if (b && b.y >= top && b.y + b.h <= top + listClip.height) rows.push(Object.assign({ name: d.modelData.name }, b));
        }
        for (let i = 0; i < buttonRep.count; i++) {
            const it = buttonRep.itemAt(i), b = win.boxOf(it);
            if (b) buttons.push(Object.assign({ id: it.modelData }, b));
        }
        return { chips: chips, rows: rows, buttons: buttons, close: win.boxOf(closeButton), refresh: win.boxOf(refreshButton),
                 search: win.boxOf(searchBox), head: win.boxOf(head), detail: win.boxOf(detailPane), detailView: win.boxOf(detail) };
    }
    function viewState() {
        const states = {};
        for (const n of win.rowNames) states[n] = Keybinds.rowOf(n).state;
        return { zone: win.zone, query: win.query, category: win.category, selected: win.selected,
                 rows: win.rowNames, headers: win.items.filter(i => i.kind === "header").map(i => i.title),
                 chips: win.chips, chipIdx: win.chipIdx, detailButtons: win.detailButtons, detailIdx: win.detailIdx,
                 confirming: win.confirming, doneText: win.doneText, copied: win.copied, whyNot: win.whyNot,
                 states: states, selRow: win.selRow, stateHeadline: win.stateHeadline, stateExplain: win.stateExplain,
                 statusText: win.statusText, searchFocused: search.editing, keysFocused: keys.activeFocus,
                 liveState: win.liveState, listContentY: list.contentY, listHeight: list.height,
                 defaultCaps: Keybinds.defaultCaps(win.selected), service: Keybinds.summary(),
                 rail: win.rail, split: win.split, summaryLine: win.summaryLine, statusShown: status.visible,
                 topSection: win.topSection, stickyShown: sticky.visible, defaultSame: win.defaultSame };
    }

    onShownChanged: {
        if (win.shown) {
            win.place();
            win.restoreContext(KeybindsUi.context);
            Keybinds.claim("keybindsUi", true);
            win.setZone("search");
            Qt.callLater(win.revealSelected);
        } else {
            KeybindsUi.context = win.saveContext();
            Keybinds.claim("keybindsUi", false);
            win.confirming = "";
        }
    }
    onAreaWChanged: if (win.shown) win.place()
    onAreaHChanged: if (win.shown) win.place()
    onTopInsetChanged: if (win.shown) Qt.callLater(win.place)
    Component.onCompleted: KeybindsUi.layer = win
    Component.onDestruction: {
        Keybinds.claim("keybindsUi", false);
        if (KeybindsUi.layer === win) { KeybindsUi.context = win.saveContext(); KeybindsUi.layer = null; }
    }

    // ---- la tarjeta --------------------------------------------------------------------------------------------------
    // Tres anchos: con sitio (≥ 1060 lógicos) categorías en columna | lista | detalle; medio, categorías en una fila que
    // se desplaza | lista | detalle; estrecho, lista y el detalle se abre encima (Enter o clic; Esc o Back vuelve).
    Item {
        id: card
        width: Math.max(0, Math.min(1140 * win.s, win.areaW - win.leftInset - win.rightInset))
        height: Math.max(0, Math.min(760 * win.s, win.areaH - win.topInset - win.bottomInset))
        onWidthChanged: if (win.shown) Qt.callLater(win.place)
        onHeightChanged: if (win.shown) Qt.callLater(win.place)
        // Entrada/salida (2026-11-11, theme/Reveal, estilo de Settings → Animations): opacidad, escala desde
        // el centro y subida; sólo visual (posición, tamaño y región de entrada no cambian).
        Reveal { id: cardReveal; shown: win.shown; s: win.s }
        readonly property real appear: cardReveal.progress
        opacity: cardReveal.opacity
        scale: cardReveal.scale
        transformOrigin: Item.Center
        // sx/sy: Power-on y Mochi (theme/Reveal); 1 con los demás
        transform: [Translate { y: cardReveal.dy }, Scale { origin.x: card.width / 2; origin.y: card.height / 2; xScale: cardReveal.sx; yScale: cardReveal.sy }]
        layer.enabled: card.appear > 0.001 && card.appear < 0.999
        // Bloom, Ink, Scroll y Mist dibujan sobre la capa de la apertura (theme/RevealEffect, ADR-36)
        layer.effect: cardReveal.effect ? cardFx : null
        Component { id: cardFx; RevealEffect { rv: cardReveal; s: win.s } }
        Accessible.role: Accessible.Dialog
        Accessible.name: "Keyboard shortcuts"
        readonly property real pad: 22 * win.s
        readonly property real gap: 16 * win.s
        readonly property real detailW: win.split ? Math.min(340 * win.s, Math.max(300 * win.s, card.width * 0.31)) : 0
        // Auditoría tipográfica (2026-11-18): crece hasta el nombre de categoría más largo, medido sobre los datos
        // (TextMetrics, no el maquetado), entre los 184 del diseño y 264
        readonly property real railW: win.rail ? Math.min(264 * win.s, Math.max(184 * win.s,
            Math.ceil(railLongest.advanceWidth + railCount.advanceWidth) + 40 * win.s)) : 0
        TextMetrics {
            id: railLongest
            font.family: Typography.ui; font.pixelSize: win.labelSize; font.weight: Typography.wMedium
            text: (win.chips || []).reduce((a, c) => String(c.title).length > a.length ? String(c.title) : a, "")
        }
        TextMetrics { id: railCount; font.family: Typography.mono; font.pixelSize: win.captionSize; text: "000" }

        Glass {
            anchors.fill: parent; s: win.s; radius: Metrics.rLg * win.s
            surface: "keybindsUi"; shadowed: !head.drag.active
        }
        Item {
            id: keys
            anchors.fill: parent; focus: true
            Keys.onPressed: event => { if (win.handle(event.key, event.modifiers, event.text)) event.accepted = true; }
        }
        MouseArea {
            id: head
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            height: 78 * win.s
            cursorShape: head.drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            drag.target: card; drag.threshold: 2
            drag.minimumX: win.leftInset; drag.maximumX: Math.max(win.leftInset, win.areaW - card.width - win.rightInset)
            drag.minimumY: win.topInset; drag.maximumY: Math.max(win.topInset, win.areaH - card.height - win.bottomInset)
            onReleased: KeybindsUi.remember(win.name, card.x, card.y)
        }
        Rectangle {
            id: headTile
            x: card.pad; anchors.verticalCenter: head.verticalCenter
            width: 42 * win.s; height: width; radius: Metrics.rSm * win.s
            color: Theme.tintPrimarySoft
            Icon { anchors.centerIn: parent; name: "keyboard"; size: 19 * win.s; color: win.tileGlyph }
        }
        Column {
            anchors.left: headTile.right; anchors.leftMargin: 12 * win.s
            anchors.right: refreshButton.left; anchors.rightMargin: 16 * win.s
            anchors.verticalCenter: head.verticalCenter; spacing: 2 * win.s
            Text { width: parent.width; text: "Keyboard shortcuts"; elide: Text.ElideRight; color: Theme.fg; font.family: Typography.ui; font.pixelSize: 24 * Typography.textScale * win.s; font.weight: Typography.wStrong }
            Text {
                width: parent.width
                text: win.summaryLine
                elide: Text.ElideRight; color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: win.labelSize
            }
        }
        ActionButton {
            id: refreshButton
            anchors.right: closeButton.left; anchors.rightMargin: 6 * win.s; anchors.verticalCenter: head.verticalCenter
            s: win.s; glyph: "reload"; label: Keybinds.reading ? "Reading…" : "Refresh"
            enabled: !Keybinds.reading
            onTriggered: Keybinds.refresh("button")
        }
        ActionButton {
            id: closeButton
            anchors.right: parent.right; anchors.rightMargin: 14 * win.s; anchors.verticalCenter: head.verticalCenter
            s: win.s; glyph: "close"; label: "Close"; onTriggered: KeybindsUi.close()
        }
        Rectangle { id: headRule; anchors.top: head.bottom; x: card.pad; width: parent.width - 2 * card.pad; height: 1; color: Theme.hair }

        // ---- búsqueda común y aviso -------------------------------------------------------------------------------
        Rectangle {
            id: searchBox
            x: card.pad
            anchors.top: headRule.bottom; anchors.topMargin: card.gap
            width: card.width - 2 * card.pad
            height: 42 * win.s
            radius: Metrics.pill(height)
            color: Theme.tileBg
            border.width: search.editing ? Metrics.focusWidth * win.s : 1
            border.color: search.editing ? Theme.selBorder : Theme.hair
            // RePág/AvPág no los usa el campo: suben hasta aquí y mueven la lista
            Keys.onPressed: event => {
                if ((event.key === Qt.Key_PageUp || event.key === Qt.Key_PageDown) && win.handle(event.key, event.modifiers, ""))
                    event.accepted = true;
            }
            Icon { id: searchGlyph; x: 12 * win.s; anchors.verticalCenter: parent.verticalCenter; name: "search"; size: 13 * win.s; color: Theme.fgVariant }
            SearchField {
                id: search
                anchors.left: searchGlyph.right; anchors.leftMargin: 8 * win.s
                anchors.right: parent.right; anchors.rightMargin: 12 * win.s
                anchors.verticalCenter: parent.verticalCenter
                s: win.s
                placeholder: "Search an action, what it does or a key (super w)"
                backtabs: true
                onTextChanged: win.query = search.text
                onEditingChanged: if (search.editing) win.zone = "search"
                onMoved: delta => win.step(delta)
                onDismissed: win.handle(Qt.Key_Escape, 0, "")
                onTabbed: win.nextZone(1)
                onBacktabbed: win.nextZone(-1)
                onAccepted: win.handle(Qt.Key_Return, 0, "")
            }
        }
        // sólo cuando hay algo que decir (teclas sin identificar, Hyprland ilegible): el resumen va en la cabecera
        Notice {
            id: status
            anchors.top: searchBox.bottom; anchors.topMargin: visible ? 10 * win.s : 0
            x: card.pad
            width: card.width - 2 * card.pad
            visible: win.statusTone === "warn"
            height: visible ? implicitHeight : 0
            s: win.s
            tone: "warn"
            text: win.statusText
        }

        // ---- categorías y lista -----------------------------------------------------------------------------------
        Item {
            id: leftCol
            anchors.top: status.bottom; anchors.topMargin: card.gap
            anchors.bottom: parent.bottom; anchors.bottomMargin: card.pad
            x: card.pad
            width: card.width - 2 * card.pad - (win.split ? card.detailW + card.gap : 0)

            // categorías en UNA fila que se desplaza (sin columna lateral)
            Flickable {
                id: chipFlick
                anchors.top: parent.top
                width: parent.width
                visible: !win.rail
                height: visible ? chipFlow.height : 0
                contentWidth: chipFlow.width; contentHeight: chipFlow.height
                flickableDirection: Flickable.HorizontalFlick
                boundsBehavior: Flickable.StopAtBounds
                clip: true
                Flow {
                    id: chipFlow
                    width: Math.max(chipFlick.width, win.chipRowWidth)
                    spacing: 6 * win.s
                    Repeater {
                        id: chipRep
                        model: win.chips
                        delegate: Rectangle {
                            id: chip
                            required property var modelData
                            required property int index
                            readonly property bool on: win.category === chip.modelData.id
                            readonly property bool focusedChip: win.zone === "chips" && win.chipIdx === chip.index
                            height: 30 * win.s
                            width: chipText.implicitWidth + 20 * win.s
                            radius: Metrics.pill(height)
                            color: chip.on ? Theme.selBg : chipArea.containsMouse ? Theme.hoverBg : "transparent"
                            border.width: chip.focusedChip ? Metrics.focusWidth * win.s : 1
                            border.color: chip.focusedChip ? Theme.focusRing : chip.on ? Theme.selBorder : Theme.hair
                            opacity: chip.modelData.count === 0 && !chip.on ? 0.55 : 1
                            Accessible.role: Accessible.RadioButton
                            Accessible.name: chip.modelData.title + ", " + chip.modelData.count
                            Accessible.checked: chip.on
                            Text {
                                id: chipText
                                anchors.centerIn: parent
                                text: chip.modelData.title + "  " + chip.modelData.count
                                color: chip.on ? Theme.fg : Theme.fgVariant
                                font.family: Typography.ui; font.pixelSize: win.captionSize
                                font.weight: chip.on ? Typography.wMedium : Typography.wNormal
                            }
                            MouseArea {
                                id: chipArea
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { win.setCategory(chip.modelData.id); win.setZone("chips"); }
                            }
                        }
                    }
                }
            }

            Item {
                id: body
                anchors.top: chipFlick.bottom; anchors.topMargin: win.rail ? 0 : 12 * win.s
                anchors.bottom: parent.bottom
                width: parent.width

                // categorías en columna, como la navegación de Settings
                Column {
                    id: rail
                    visible: win.rail
                    width: card.railW
                    spacing: 2 * win.s
                    Repeater {
                        id: railRep
                        model: win.rail ? win.chips : []
                        delegate: Rectangle {
                            id: entry
                            required property var modelData
                            required property int index
                            readonly property bool on: win.category === entry.modelData.id
                            readonly property bool focusedEntry: win.zone === "chips" && win.chipIdx === entry.index
                            width: rail.width
                            height: 38 * win.s
                            radius: Metrics.rSm * win.s
                            color: entry.on ? Theme.selBg : entryArea.containsMouse ? Theme.hoverBg : "transparent"
                            border.width: entry.focusedEntry ? Metrics.focusWidth * win.s : 0
                            border.color: Theme.focusRing
                            opacity: entry.modelData.count === 0 && !entry.on ? 0.5 : 1
                            Accessible.role: Accessible.RadioButton
                            Accessible.name: entry.modelData.title + ", " + entry.modelData.count
                            Accessible.checked: entry.on
                            Rectangle {
                                visible: entry.on
                                anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                width: 2 * win.s; height: parent.height * 0.5; radius: Metrics.pill(width)
                                color: Theme.primary
                            }
                            Text {
                                anchors.left: parent.left; anchors.leftMargin: 12 * win.s
                                anchors.right: entryCount.left; anchors.rightMargin: 6 * win.s
                                anchors.verticalCenter: parent.verticalCenter
                                text: entry.modelData.title
                                elide: Text.ElideRight
                                color: entry.on ? Theme.fg : Theme.fgVariant
                                font.family: Typography.ui; font.pixelSize: win.labelSize
                                font.weight: entry.on ? Typography.wMedium : Typography.wNormal
                            }
                            Text {
                                id: entryCount
                                anchors.right: parent.right; anchors.rightMargin: 10 * win.s
                                anchors.verticalCenter: parent.verticalCenter
                                text: entry.modelData.count
                                color: entry.on ? Theme.primary : Theme.outlineText
                                font.family: Typography.mono; font.pixelSize: win.captionSize
                            }
                            MouseArea {
                                id: entryArea
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { win.setCategory(entry.modelData.id); win.setZone("chips"); }
                            }
                        }
                    }
                }
                Rectangle {
                    visible: win.rail
                    x: card.railW + card.gap / 2; width: 1; height: parent.height; color: Theme.hair
                }

                // La lista no se pinta bajo la cabecera fija mientras ésta se ve (2026-11-08): con un material
                // translúcido las filas que pasaban por debajo se veían a través de la banda. El recorte lo hace este
                // contenedor; la lista no se mueve (y: -listClip.y) y la barra de desplazamiento sigue siendo su hermana.
                Item {
                    id: listClip
                    x: win.rail ? card.railW + card.gap : 0
                    y: sticky.visible ? sticky.height : 0
                    width: body.width - x
                    height: body.height - y
                    // estrecho: lista O detalle (el detalle se abre encima al entrar; Esc o Back vuelve)
                    visible: win.split || win.zone !== "detail"
                    clip: true
                    ListView {
                        id: list
                        y: -listClip.y
                        width: listClip.width
                        height: body.height
                        model: win.items
                        boundsBehavior: Flickable.StopAtBounds
                        Accessible.role: Accessible.List
                        Accessible.name: "Shell shortcuts"
                        delegate: Item {
                            id: item
                            required property var modelData
                            required property int index
                            readonly property bool isRow: item.modelData.kind === "row"
                            readonly property bool current: item.isRow && item.modelData.name === win.selected
                            readonly property var info: { const res = Keybinds.resolved; const st = Keybinds.status; return item.isRow ? Keybinds.rowOf(item.modelData.name) : null; }
                            // hueco fijo para la barra, que va dentro (la caja recorta): el texto se reparte
                            // al ancho y uno que dependiera de si hay de más podría oscilar en el límite
                            width: list.width - listHint.gutter
                            height: item.isRow ? Math.max(80 * win.s, rowLabels.implicitHeight + 24 * win.s) : 34 * win.s
                            Accessible.role: item.isRow ? Accessible.ListItem : Accessible.Heading
                            Accessible.name: item.isRow ? item.modelData.title + ", "
                                + (item.info.state === "bound" ? item.info.keys[0].text : win.badge(item.info.state)) : item.modelData.title
                            Accessible.description: item.isRow ? item.modelData.description : ""
                            Accessible.selected: item.current

                            Text {
                                visible: !item.isRow
                                anchors.left: parent.left; anchors.leftMargin: 10 * win.s
                                anchors.bottom: parent.bottom; anchors.bottomMargin: 5 * win.s
                                text: item.modelData.title
                                color: Theme.outlineText
                                font.family: Typography.ui; font.pixelSize: win.captionSize; font.weight: Typography.wStrong
                                font.letterSpacing: Typography.tracking * win.s
                                font.capitalization: Font.AllUppercase
                            }
                            Rectangle {
                                visible: item.isRow
                                anchors.fill: parent; anchors.topMargin: 1 * win.s; anchors.bottomMargin: 1 * win.s
                                radius: Metrics.rSm * win.s
                                color: item.current ? Theme.selBg : rowArea.containsMouse ? Theme.hoverBg : "transparent"
                                border.width: item.current && win.zone === "list" ? Metrics.focusWidth * win.s : 0
                                border.color: Theme.focusRing
                            }
                            Rectangle {
                                visible: item.current
                                anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                width: 2 * win.s; height: parent.height * 0.42; radius: Metrics.pill(width)
                                color: Theme.primary
                            }
                            Rectangle {
                                id: rowTile
                                visible: item.isRow
                                x: 10 * win.s; anchors.verticalCenter: parent.verticalCenter
                                width: 34 * win.s; height: width; radius: Metrics.rSm * win.s
                                color: item.current ? Theme.tintPrimarySoft : Qt.alpha(Theme.fg, 0.05)
                                Icon {
                                    anchors.centerIn: parent
                                    name: item.isRow ? item.modelData.glyph : ""
                                    size: 17 * win.s
                                    color: item.current ? win.tileGlyph : Theme.fgVariant
                                }
                            }
                            Column {
                                id: rowLabels
                                visible: item.isRow
                                anchors.left: rowTile.right; anchors.leftMargin: 12 * win.s
                                anchors.right: parent.right; anchors.rightMargin: 12 * win.s
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 10 * win.s
                                Text {
                                    id: rowTitle
                                    // Reservar la altura de las teclas antes de empezar la descripción.
                                    height: Math.max(implicitHeight, rowRight.height)
                                    width: Math.max(0, parent.width - rowRight.width - 20 * win.s)
                                    verticalAlignment: Text.AlignVCenter
                                    wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                                    text: item.isRow ? item.modelData.title : ""
                                    color: Theme.fg; font.family: Typography.ui; font.pixelSize: win.bodySize; font.weight: Typography.wMedium
                                }
                                Text {
                                    width: parent.width; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                                    text: item.isRow ? item.modelData.description : ""
                                    color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: win.labelSize
                                }
                            }
                            Row {
                                id: rowRight
                                visible: item.isRow
                                anchors.right: parent.right; anchors.rightMargin: 12 * win.s
                                y: rowLabels.y + (rowTitle.height - height) / 2
                                spacing: 6 * win.s
                                KeybindsKeys {
                                    visible: !!item.info && item.info.state === "bound"
                                    s: win.s
                                    caps: item.info && item.info.state === "bound" ? item.info.keys[0].caps : []
                                }
                                Text {
                                    visible: !!item.info && item.info.state === "bound" && item.info.keys.length > 1
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: item.info && item.info.keys.length > 1 ? "+" + (item.info.keys.length - 1) : ""
                                    color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: win.captionSize
                                }
                                Rectangle {
                                    visible: !!item.info && item.info.state !== "bound"
                                    anchors.verticalCenter: parent.verticalCenter
                                    readonly property bool warned: !!item.info && (item.info.state === "unknown" || item.info.state === "unread")
                                    width: Math.min(badgeText.implicitWidth + 14 * win.s, list.width * 0.46); height: 26 * win.s; radius: Metrics.pill(height)
                                    color: Qt.alpha(warned ? Theme.warn : Theme.fg, warned ? 0.12 : 0.06)
                                    Text {
                                        id: badgeText
                                        anchors.fill: parent; anchors.leftMargin: 7 * win.s; anchors.rightMargin: 7 * win.s
                                        verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
                                        text: item.info ? win.badge(item.info.state) : ""
                                        color: parent.warned ? Theme.warn : Theme.fgVariant
                                        font.family: Typography.ui; font.pixelSize: win.captionSize
                                    }
                                }
                            }
                            MouseArea {
                                id: rowArea
                                enabled: item.isRow
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                // estrecho: un clic abre el detalle (no hay panel a la vista)
                                onClicked: { win.selected = item.modelData.name; win.setZone(win.split ? "list" : "detail"); }
                                // dos clics: al botón Open, sin ejecutar (nada se abre sin un clic o Enter sobre él)
                                onDoubleClicked: { win.selected = item.modelData.name; win.setZone("detail"); }
                            }
                        }
                    }
                    ScrollHint { id: listHint; view: list; s: win.s; inside: true }
                }
                // la sección de lo que se ve arriba, fija mientras se desplaza (antes la cabecera se cortaba a medias)
                Rectangle {
                    id: sticky
                    x: listClip.x; width: listClip.width; height: 34 * win.s
                    visible: list.visible && list.contentY > 2 && win.topSection.length > 0
                    color: Theme.bgFor("keybindsUi", false)
                    Text {
                        anchors.left: parent.left; anchors.leftMargin: 10 * win.s
                        anchors.bottom: parent.bottom; anchors.bottomMargin: 5 * win.s
                        text: win.topSection
                        color: Theme.outlineText
                        font.family: Typography.ui; font.pixelSize: win.captionSize; font.weight: Typography.wStrong
                        font.letterSpacing: Typography.tracking * win.s
                        font.capitalization: Font.AllUppercase
                    }
                    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.hair }
                }
                Empty {
                    anchors.centerIn: listClip
                    visible: win.rowNames.length === 0 && Keybinds.catalogOk && list.visible
                    s: win.s; glyph: "search"
                    text: "No shortcut matches"
                    hint: win.category.length > 0 ? "Try All, or another word" : "Search a title, what it does, or a key like super w"
                }
            }
        }

        // ---- el detalle (aquí entrará la edición en otra fase) ---------------------------------------------------------
        Rectangle {
            id: detailPane
            x: win.split ? card.width - card.pad - card.detailW : leftCol.x
            y: win.split ? leftCol.y : leftCol.y + body.y
            width: win.split ? card.detailW : leftCol.width
            height: win.split ? leftCol.height : body.height
            radius: Metrics.rMd * win.s
            color: Qt.alpha(Theme.fg, 0.025)
            border.width: win.zone === "detail" ? Metrics.focusWidth * win.s : 1
            border.color: win.zone === "detail" ? Theme.selBorder : Theme.hair
            visible: !!win.selAction && (win.split || win.zone === "detail")
            clip: true
            Accessible.role: Accessible.Pane
            Accessible.name: win.selAction ? win.selAction.title + " details" : ""

            Flickable {
                id: detail
                anchors.fill: parent; anchors.margins: 20 * win.s
                contentWidth: width; contentHeight: detailCol.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                clip: true
                Column {
                    id: detailCol
                    width: detail.width
                    spacing: 18 * win.s
                    ActionButton {
                        visible: !win.split
                        s: win.s; glyph: "chevron-left"; label: "Back to the list"
                        onTriggered: win.setZone("list")
                    }
                    Row {
                        width: parent.width; spacing: 12 * win.s
                        Rectangle {
                            id: dTile
                            width: 40 * win.s; height: width; radius: Metrics.rSm * win.s
                            color: Theme.tintPrimarySoft
                            Icon { anchors.centerIn: parent; name: win.selAction ? win.selAction.glyph : ""; size: 19 * win.s; color: win.tileGlyph }
                        }
                        Column {
                            width: parent.width - dTile.width - 12 * win.s
                            anchors.verticalCenter: dTile.verticalCenter
                            spacing: 2 * win.s
                            Text {
                                width: parent.width; wrapMode: Text.Wrap
                                text: win.selAction ? win.selAction.title : ""
                                color: Theme.fg; font.family: Typography.ui; font.pixelSize: 19 * Typography.textScale * win.s; font.weight: Typography.wStrong
                            }
                            Text {
                                width: parent.width; elide: Text.ElideRight
                                text: win.selAction ? Keybinds.categoryTitle(win.selAction.category) : ""
                                color: Theme.fgVariant; font.family: Typography.mono; font.pixelSize: win.captionSize
                            }
                        }
                    }
                    Text {
                        width: parent.width; wrapMode: Text.Wrap
                        text: win.selAction ? win.selAction.description : ""
                        color: Theme.fg; font.family: Typography.ui; font.pixelSize: win.bodySize
                        lineHeight: 1.1
                    }

                    // la tecla en Hyprland (lo efectivo), en su tarjeta
                    Rectangle {
                        id: keyCard
                        width: parent.width
                        height: keyCol.implicitHeight + 32 * win.s
                        radius: Metrics.rMd * win.s
                        readonly property bool warned: win.selRow.state === "unknown" || win.selRow.state === "unread"
                        color: keyCard.warned ? Qt.alpha(Theme.warn, 0.08) : Qt.alpha(Theme.fg, 0.04)
                        border.width: 1
                        border.color: keyCard.warned ? Qt.alpha(Theme.warn, 0.35) : Theme.hair
                        Column {
                            id: keyCol
                            x: 16 * win.s; y: 16 * win.s
                            width: parent.width - 32 * win.s
                            spacing: 8 * win.s
                            Text {
                                width: parent.width; wrapMode: Text.Wrap
                                text: win.stateHeadline
                                color: keyCard.warned ? Theme.warn : Theme.fgVariant
                                font.family: Typography.ui; font.pixelSize: win.captionSize; font.weight: Typography.wStrong
                                font.letterSpacing: Typography.tracking * win.s * 0.6
                                font.capitalization: Font.AllUppercase
                            }
                            Repeater {
                                model: win.selRow.state === "bound" ? win.selRow.keys : []
                                delegate: Column {
                                    id: keyRow
                                    required property var modelData
                                    width: keyCol.width
                                    spacing: 4 * win.s
                                    KeybindsKeys { s: win.s; unit: 1.4; caps: keyRow.modelData.caps }
                                    Text {
                                        visible: text.length > 0
                                        width: parent.width; wrapMode: Text.Wrap
                                        text: [keyRow.modelData.submap ? "Inside the submap " + keyRow.modelData.submap : "",
                                               keyRow.modelData.flags.length > 0 ? "Flags: " + keyRow.modelData.flags.join(", ") : ""]
                                            .filter(x => x.length > 0).join(" · ")
                                        color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: win.captionSize
                                    }
                                    Text {
                                        visible: keyRow.modelData.others.length > 0
                                        width: parent.width; wrapMode: Text.Wrap
                                        text: "The same key also runs: " + keyRow.modelData.others.join(", ")
                                        color: Theme.warn; font.family: Typography.ui; font.pixelSize: win.captionSize
                                    }
                                }
                            }
                            Text {
                                width: parent.width; wrapMode: Text.Wrap
                                text: win.stateExplain
                                color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: win.labelSize
                            }
                            Repeater {
                                model: win.selRow.notes
                                delegate: Text {
                                    required property string modelData
                                    width: keyCol.width; wrapMode: Text.Wrap
                                    text: modelData
                                    color: Theme.warn; font.family: Typography.ui; font.pixelSize: win.captionSize
                                }
                            }
                        }
                    }
                    // La sugerencia permanece secundaria y se adapta a las columnas estrechas.
                    Column {
                        width: parent.width; spacing: 8 * win.s
                        Text {
                            text: "Default key"
                            color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: win.captionSize
                            font.weight: Typography.wMedium
                        }
                        KeybindsKeys { s: win.s; muted: true; caps: Keybinds.defaultCaps(win.selected) }
                        Text {
                            width: parent.width; wrapMode: Text.Wrap
                            text: win.defaultSame ? "Same as your binding"
                                : "Suggested by the shell. Your Hyprland config decides the real key."
                            color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: win.labelSize
                        }
                    }

                    // la acción
                    Text {
                        visible: win.confirming.length > 0 && win.confirming === win.selected
                        width: parent.width; wrapMode: Text.Wrap
                        text: win.selAction && win.selAction.confirm ? win.selAction.confirm : ""
                        color: Theme.fg; font.family: Typography.ui; font.pixelSize: win.bodySize
                    }
                    Flow {
                        width: parent.width; spacing: 8 * win.s
                        visible: win.detailButtons.length > 0
                        Repeater {
                            id: buttonRep
                            model: win.detailButtons
                            delegate: ActionButton {
                                required property string modelData
                                required property int index
                                s: win.s
                                focused: win.zone === "detail" && win.detailIdx === index
                                primary: modelData === "open" && !(win.selAction && win.selAction.effect === "change")
                                accent: modelData === "confirm" || (modelData === "open" && !!win.selAction && win.selAction.effect === "change")
                                glyph: modelData === "open" ? "open-external" : modelData === "copy" ? "copy" : ""
                                label: modelData === "cancel" ? "Cancel"
                                    : modelData === "confirm" ? (win.selAction ? win.selAction.confirmLabel : "")
                                    : modelData === "copy" ? (win.copied ? "Copied" : "Copy Lua line")
                                    : (win.selAction && win.selAction.effect === "change" ? "Run…" : "Open")
                                onTriggered: { win.zone = "detail"; win.detailIdx = index; keys.forceActiveFocus(); win.press(modelData); }
                            }
                        }
                    }
                    Text {
                        visible: text.length > 0
                        width: parent.width; wrapMode: Text.Wrap
                        text: win.whyNot.length > 0 ? "Can't run here · " + win.whyNot
                            : [win.selAction && win.selAction.note ? win.selAction.note : "", win.liveState,
                               win.doneText].filter(x => x.length > 0).join(" · ")
                        color: win.whyNot.length > 0 ? Theme.warn : Theme.fgVariant
                        font.family: Typography.ui; font.pixelSize: win.captionSize
                    }

                    Text {
                        width: parent.width; wrapMode: Text.WrapAnywhere
                        text: win.selAction ? "sumi:" + win.selAction.name : ""
                        color: Theme.outlineText; font.family: Typography.mono; font.pixelSize: win.captionSize
                    }

                    // cómo hacerla reconocible (sólo si no se identificó)
                    Text {
                        visible: win.showSnippet
                        width: parent.width; wrapMode: Text.Wrap
                        text: win.selRow.state === "unbound"
                            ? "To bind it, add this to hyprland.lua (pick a free key):"
                            : "If it's already bound, add " + Keybinds.descriptionOption(win.selected)
                              + " to that hl.bind to show its key here. For example:"
                        color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: win.captionSize
                    }
                    Rectangle {
                        visible: win.showSnippet
                        width: parent.width; height: snippet.implicitHeight + 12 * win.s
                        radius: Metrics.rSm * win.s; color: Theme.surfaceContainerLow; border.width: 1; border.color: Theme.hair
                        Text {
                            id: snippet
                            anchors.fill: parent; anchors.margins: 6 * win.s
                            text: Keybinds.luaLine(win.selected)
                            wrapMode: Text.WrapAnywhere; color: Theme.fg
                            font.family: Typography.mono; font.pixelSize: win.captionSize
                        }
                    }
                }
            }
            ScrollHint { view: detail; s: win.s }
        }
        // interferencia de terminal (2026-11-15): al abrir y al cambiar de vista; encima de todo (z), sin
        // recibir clics. Último hijo de la tarjeta: no corre los índices de los demás
        Interference { anchors.fill: parent; s: win.s; open: win.shown; key: win.category }
    }
}
