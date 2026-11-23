pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Widgets
import "../theme"
import "../services"
import "../components"
import "../lib/text-wrap.js" as TextWrap

/**
 * Wallpaper strip. The focused thumbnail is
 * large and lit, its neighbours shrink and dim as they slide under it, so the
 * row reads as depth instead of a list.
 *
 * The strip renders from one continuous `pos` that chases `focusIndex`
 * exponentially, not from per-tile animations: any input rate (key autorepeat,
 * a wheel burst) stays coherent because lag is bounded by the time constant
 * rather than piling up across retargeted animations. Borrowed from Ukishima,
 * the one piece of its wallpaper UI worth keeping.
 *
 * 10A (rediseño; futureWallpaper-listsurface «Buscar wallpapers instalados»): la tira muestra
 * `Wallpaper.query(tipo, conjunto, texto)` — el mismo inventario que Settings → Theme →
 * Wallpaper. **Search installed wallpapers** filtra al teclear, sin red; All/Images/Videos y
 * Recent/Favorites se combinan con ella. La cabecera nombra el fondo aplicado aunque el filtro lo
 * oculte, y su miniatura lleva una marca. Zonas de teclado: tira → búsqueda → filtros (Tab);
 * en la tira siguen R y S; `/` o Ctrl+F llevan a la búsqueda.
 *
 * Antes de la fase 11 (W4, `rediseno/Antes-de-fase-11.md`): la búsqueda y la descarga de
 * Wallhaven (10C-1…10E-2) salieron a su propia tienda flotante (`core/WallhavenLayer`,
 * Super+Ctrl+W). Aquí quedan elegir y aplicar: el chip **Wallhaven ↗** (o `W`) la abre y cierra la
 * tira; el filtro local **Collection** (índice privado, sin red) y la marca «Wallhaven» se quedan.
 */
Surface {
    id: root

    mTop: 10
    mLeft: 0
    mRight: 0
    mBottom: 8
    clip: true

    /** all | images | videos — por extensión (10A). */
    property string kind: "all"
    /** library | recent | favorites — Recent/Favorites como filtros de la tira (10A). */
    property string set: "library"
    /** Search installed wallpapers: por nombre de archivo, al teclear. */
    property string query: ""
    /**
     * 10E-1b: Collection (una colección de Wallhaven del índice privado, o "" = todas). Independiente
     * del tipo, de Recent/Favorites y del texto: se combinan.
     */
    property string collection: ""
    readonly property var localColls: WallhavenIndex.localCollections
    onLocalCollsChanged: if (root.collection.length > 0 && !root.localColls.some(c => c.id === root.collection)) root.collection = ""
    function cycleCollection(dir) {
        const ids = [""].concat(root.localColls.map(c => c.id));
        const i = Math.max(0, ids.indexOf(root.collection));
        root.collection = ids[(i + (dir || 1) + ids.length) % ids.length];
        Qt.callLater(root.centerOnCurrent);
    }
    /**
     * 10E-1b: « · Wallhaven» para los `wallhaven-<id>…` (por el nombre: también los bajados a mano)
     * y « · Nature, Cats» si el índice los asocia a colecciones.
     */
    function originOf(name) {
        if (!/^wallhaven-/.test(String(name))) return "";
        void WallhavenIndex.entries;
        const cs = WallhavenIndex.collectionsOf(name);
        return "  ·  Wallhaven" + (cs.length > 0 ? " · " + cs.join(", ") : "");
    }
    readonly property string collectionLabel: root.collection.length > 0
        ? "Collection: " + WallhavenIndex.collectionName(root.collection) : "Collection: All"
    /** strip · search · filters (Tab las recorre). */
    property string zone: "strip"
    /** El chip con el foco en la zona de filtros (índice en `filterChips`). */
    property int filterIndex: 0
    /** La tienda de Wallhaven en esta pantalla (la misma instancia que Super+Ctrl+W); la tira se cierra. */
    function openStore() {
        if (!WallhavenStore.show(root.screenName)) return;
        root.requestClose();
    }
    /**
     * Show in library (desde la tienda, `Screens.showInLibraryOn`): la tira sin filtros, con el
     * foco en ese archivo.
     */
    function showInLibrary(path) {
        root.kind = "all";
        root.set = "library";
        root.collection = "";
        root.clearSearch();
        Qt.callLater(function () {
            const i = Wallpaper.indexOfPath(root.items, path);
            if (i >= 0) { root.focusIndex = i; }
            root.goZone("strip");
        });
    }
    property int focusIndex: 0
    property real pos: 0

    /** Path being applied right now, and the last one that failed. */
    property string pending: ""
    property string errorPath: ""
    /**
     * 10B: el aviso del pie (4 s): un fallo con su motivo, o lo que hizo Restore previous. No
     * cambia el alto del pie.
     */
    property string noticeText: ""
    property string noticeTone: "info"
    function notify(text, tone) {
        root.noticeText = text;
        root.noticeTone = tone;
        errorClear.restart();
    }
    /** 10B: hay un fondo anterior al que volver (Recent). */
    readonly property var previousEntry: { void WallpaperMeta.recent; return WallpaperMeta.previous(Wallpaper.current); }
    function restore() {
        root.errorPath = "";
        if (Wallpaper.applyWhy.length > 0) { root.notify(Wallpaper.applyWhy, "warn"); return; }
        if (!Wallpaper.restorePrevious() && Wallpaper.applyState !== "failed")
            root.notify("Another wallpaper is still being applied", "warn");
    }

    readonly property var items: Wallpaper.query(root.kind, root.set, root.query, root.collection)
    readonly property int itemCount: items.length
    /**
     * 10A: el ancho de DESTINO de las filas de texto (no el animado): durante la apertura se
     * recortan con el panel en vez de apretarse y reelidir el texto a cada fotograma.
     */
    readonly property real rowW: Math.max(0, Math.min((Metrics.wallpaperW - 48) * root.s, root.width - 24 * root.s))
    /** La caja de búsqueda: la del diseño, más ancha con familias anchas o Text size (hasta 45 % de la fila; 2026-11-18). */
    readonly property real searchW: Math.min(root.rowW * 0.45, 260 * root.s * Typography.grow)
    readonly property var focused: (focusIndex >= 0 && focusIndex < itemCount) ? items[focusIndex] : null

    /** What THIS screen shows: its own pick, or the wallpaper of every screen. */
    readonly property string onHere: Wallpaper.currentFor(root.screenName)
    readonly property string applyStatus: Wallpaper.applyState === "applying" ? "applying…"
        : Wallpaper.colorsState === "updating" ? "updating colours…"
        : Wallpaper.colorsState === "failed" ? "colours failed"
        : Wallpaper.colorsState === "unknown" ? "colours didn't report" : ""
    /**
     * Portabilidad F2c: lo que esta máquina no puede hacer con la tira, dicho ANTES de pulsar y
     * fijo en el pie (no los 4 s de un fallo). Mirar, buscar, filtrar y favoritos siguen.
     */
    readonly property string capNote: {
        const w = Wallpaper.whyNot(root.focused ? root.focused.path : "");
        if (w.length > 0) return (Wallpaper.applyWhy.length > 0 ? "Browse only · " : "Can't apply this one · ") + w;
        return Wallpaper.colorsWhy.length > 0 ? "Colours won't follow the wallpaper · " + Wallpaper.colorsWhy : "";
    }
    function useShared() {
        if (Wallpaper.applyWhy.length > 0) { root.notify(Wallpaper.applyWhy, "warn"); return; }
        Wallpaper.clearOutput(root.screenName);
    }
    /** El aplicado está entre los resultados (si no, sólo lo nombra la cabecera). */
    readonly property bool onHereShown: Wallpaper.indexOfPath(root.items, root.onHere) >= 0

    readonly property var kinds: [
        { key: "all", label: "All" },
        { key: "images", label: "Images" },
        { key: "videos", label: "Videos" }
    ]
    readonly property var sets: [
        { key: "recent", label: "Recent" },
        { key: "favorites", label: "Favorites" }
    ]
    /** Los chips en el orden del teclado: tipo y después conjunto. */
    readonly property var filterChips: root.kinds.map(k => ({ group: "kind", key: k.key }))
        .concat(root.sets.map(k => ({ group: "set", key: k.key })))
        .concat(root.localColls.length > 0 ? [{ group: "collection", key: "collection" }] : [])

    function move(delta) {
        if (root.itemCount === 0)
            return;
        root.focusIndex = Math.max(0, Math.min(root.itemCount - 1, root.focusIndex + delta));
    }

    function centerOnCurrent() {
        const idx = Wallpaper.indexOfPath(root.items, root.onHere);
        root.focusIndex = idx >= 0 ? idx : 0;
        root.pos = root.focusIndex;
    }

    /**
     * `⏎` / clic: al destino elegido (12G; «all» por defecto, como siempre). `⇧⏎` / clic derecho:
     * al otro — con una sola pantalla, siempre a todas (el rice no distingue).
     */
    /**
     * 12G: a dónde va Enter con más de una pantalla — «all» (todas: colores y lock las siguen) o
     * «screen» (sólo ésta: se guarda aparte y los colores siguen al fondo de todas). Por vista;
     * ⇧⏎ (o clic derecho) aplica al otro destino.
     */
    property string applyTarget: "all"
    readonly property bool targetScreen: Wallpaper.multiScreen && root.applyTarget === "screen"
    function toggleTarget() {
        if (Wallpaper.multiScreen) root.applyTarget = root.applyTarget === "all" ? "screen" : "all";
    }

    function activate(invert) {
        if (!root.focused)
            return;
        const thisScreenOnly = root.targetScreen !== (invert === true);
        const mon = (thisScreenOnly && Wallpaper.multiScreen) ? root.screenName : "";
        if (thisScreenOnly && mon.length === 0)
            return;
        root.errorPath = "";
        const why = Wallpaper.whyNot(root.focused.path);
        if (why.length > 0) { root.notify(why, "warn"); return; }
        root.pending = root.focused.path;
        Wallpaper.apply(root.focused.path, mon);
    }

    function setKind(k) {
        if (root.kind === k)
            return;
        root.kind = k;
        Qt.callLater(root.centerOnCurrent);
    }

    /** Recent/Favorites: el mismo chip otra vez vuelve a toda la biblioteca. */
    function setSet(k) {
        root.set = root.set === k ? "library" : k;
        Qt.callLater(root.centerOnCurrent);
    }

    function setQuery(q) {
        if (root.query === q)
            return;
        root.query = q;
        Qt.callLater(root.centerOnCurrent);
    }

    function clearSearch() {
        searchField.clear();
        root.setQuery("");
    }

    function activateChip(i) {
        const c = root.filterChips[i];
        if (!c) return;
        root.filterIndex = i;
        if (c.group === "kind") root.setKind(c.key);
        else if (c.group === "collection") root.cycleCollection(1);
        else root.setSet(c.key);
    }

    function goZone(z) {
        root.zone = z;
        if (z === "search") {
            searchField.focusField();
        } else {
            if (z === "filters") {
                // el foco empieza en el chip activo del tipo
                for (let i = 0; i < root.kinds.length; i++)
                    if (root.kinds[i].key === root.kind) root.filterIndex = i;
            }
            root.forceActiveFocus();
        }
    }
    function tabZone(dir) {
        const order = ["strip", "search", "filters"];
        const i = order.indexOf(root.zone);
        root.goZone(order[((i < 0 ? 0 : i) + dir + order.length) % order.length]);
    }

    /** Contexto de la visita (DESIGN §3): consulta, filtros y el enfocado POR RUTA. */
    function saveContext() {
        return { kind: root.kind, set: root.set, query: root.query, collection: root.collection,
                 focus: root.focused ? root.focused.path : "" };
    }
    function restoreContext(ctx) {
        if (!ctx) return true;
        root.kind = ["all", "images", "videos"].indexOf(ctx.kind) >= 0 ? ctx.kind : "all";
        root.set = ["library", "recent", "favorites"].indexOf(ctx.set) >= 0 ? ctx.set : "library";
        searchField.text = String(ctx.query || "");
        root.query = searchField.text;
        root.collection = typeof ctx.collection === "string" ? ctx.collection : "";
        // W4: un contexto guardado antes trae también el de Wallhaven (remoteText…); se ignora
        const want = String(ctx.focus || "");
        Qt.callLater(function () {
            const idx = Wallpaper.indexOfPath(root.items, want);
            if (idx >= 0) { root.focusIndex = idx; root.pos = idx; }
            else root.centerOnCurrent();
        });
        return true;
    }

    /** Para el IPC (`wallpaperView`). */
    function viewState() {
        return { zone: root.zone, kind: root.kind, set: root.set, query: root.query, collection: root.collection,
                 count: root.itemCount, focus: root.focused ? root.focused.name : "",
                 focusIndex: root.focusIndex, applied: Wallpaper.baseName(root.onHere),
                 appliedShown: root.onHereShown, target: root.applyTarget, multiScreen: Wallpaper.multiScreen,
                 own: Wallpaper.hasOwn(root.screenName), clearState: Wallpaper.clearState,
                 hint: footerHint.text, capNote: root.capNote, notice: root.noticeText,
                 filterFocus: root.zone === "filters"
                     ? root.filterChips[root.filterIndex].key : "",
                 editing: searchField.editing };
    }

    function cycleKind(dir) {
        let i = 0;
        for (let n = 0; n < root.kinds.length; n++)
            if (root.kinds[n].key === root.kind)
                i = n;
        root.setKind(root.kinds[(i + dir + root.kinds.length) % root.kinds.length].key);
    }

    /** Keys arrive from the Screen's FocusScope; Escape is left to the host. */
    function keyPressed(event) {
        // en la búsqueda manda el campo (sus señales); lo que no quiere (← al principio) no mueve la tira
        if (root.zone === "search")
            return;
        if (root.zone === "filters") {
            switch (event.key) {
            case Qt.Key_Left:  root.filterIndex = Math.max(0, root.filterIndex - 1); event.accepted = true; break;
            case Qt.Key_Right: root.filterIndex = Math.min(root.filterChips.length - 1, root.filterIndex + 1); event.accepted = true; break;
            case Qt.Key_Return:
            case Qt.Key_Enter:
            case Qt.Key_Space:
                if (!event.isAutoRepeat) root.activateChip(root.filterIndex);
                event.accepted = true;
                break;
            case Qt.Key_Down:
            case Qt.Key_Escape: root.goZone("strip"); event.accepted = true; break;
            case Qt.Key_Tab:     root.tabZone(1);  event.accepted = true; break;
            case Qt.Key_Backtab: root.tabZone(-1); event.accepted = true; break;
            }
            return;
        }
        if (event.key === Qt.Key_Slash
                || (event.key === Qt.Key_F && (event.modifiers & Qt.ControlModifier))) {
            root.goZone("search");
            event.accepted = true;
            return;
        }
        switch (event.key) {
        case Qt.Key_Left:  root.move(-1); event.accepted = true; break;
        case Qt.Key_Right: root.move(1);  event.accepted = true; break;
        case Qt.Key_Home:  root.focusIndex = 0; event.accepted = true; break;
        case Qt.Key_End:   root.focusIndex = Math.max(0, root.itemCount - 1); event.accepted = true; break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Space:
            if (!event.isAutoRepeat) {
                // sin resultados por la búsqueda, Enter la limpia (lo que ofrece el vacío)
                if (root.itemCount === 0 && root.query.length > 0) root.clearSearch();
                else root.activate((event.modifiers & Qt.ShiftModifier) !== 0);
            }
            event.accepted = true;
            break;
        case Qt.Key_Tab:      root.tabZone(1);  event.accepted = true; break;
        case Qt.Key_Backtab:  root.tabZone(-1); event.accepted = true; break;
        // antes de la fase 11: la tienda de Wallhaven
        case Qt.Key_W:
            if (!event.isAutoRepeat) root.openStore();
            event.accepted = true;
            break;
        // 9B: «Configure wallpapers» → Settings · Theme · Wallpaper
        case Qt.Key_S:
            if (!event.isAutoRepeat && root.host) root.host.openSettingsAt("theme/wallpaper");
            event.accepted = true;
            break;
        case Qt.Key_R:
            if (!event.isAutoRepeat) {
                if (Wallpaper.applyWhy.length > 0) root.notify(Wallpaper.applyWhy, "warn");
                else {
                    root.pending = "random";
                    Wallpaper.random(root.kind);
                }
            }
            event.accepted = true;
            break;
        // 12G: destino del Enter (todas / esta pantalla) y volver al fondo de todas
        case Qt.Key_M:
            if (!event.isAutoRepeat) root.toggleTarget();
            event.accepted = true;
            break;
        case Qt.Key_U:
            if (!event.isAutoRepeat) root.useShared();
            event.accepted = true;
            break;
        // 10B: Restore previous
        case Qt.Key_P:
            if (!event.isAutoRepeat) root.restore();
            event.accepted = true;
            break;
        }
    }

    onOpenChanged: if (open) {
        root.previewArmed = false;
        previewArm.restart();
        root.zone = "strip";
        Wallpaper.scan();
        // Adelanta el trabajo de `thumbs-refresh.timer`: un wallpaper recién
        // añadido no tiene miniatura hasta que el rice la genera, y el timer
        // sólo corre a diario. generate-thumbs.sh es incremental y con
        // `flock -n`, así que dispararlo de más es inofensivo.
        Wallpaper.refreshThumbs();
        centerOnCurrent();
    } else if (searchField.editing) {
        root.forceActiveFocus();
    }

    onItemsChanged: if (root.focusIndex >= root.itemCount) root.focusIndex = Math.max(0, root.itemCount - 1)

    Connections {
        target: Wallpaper
        function onScanned() { if (root.open) root.centerOnCurrent(); }
        function onApplied(path) {
            root.pending = "";
            root.errorPath = "";
            if (Wallpaper.applyOrigin === "restore") {
                root.notify("Restored " + Wallpaper.baseName(path)
                            + (Wallpaper.restoreNote.length > 0 ? " · " + Wallpaper.restoreNote : ""), "ok");
                // el restaurado no lo eligió la tira: se lleva el foco hasta él
                Qt.callLater(root.centerOnCurrent);
            }
            else root.noticeText = "";
        }
        function onFailed(path, reason) {
            root.pending = "";
            root.errorPath = path;
            root.notify(reason, "danger");
        }
    }

    Timer {
        id: errorClear
        interval: 4000
        onTriggered: { root.errorPath = ""; root.noticeText = ""; }
    }

    /**
     * Exponential chase: `pos` closes 1/e of the gap every `Motion.chaseTau`,
     * whatever the input rate.
     *
     * La constante era un `0.07` literal, y por eso esta —el movimiento mas
     * grande del shell— era lo unico que `reduce motion` no acortaba
     * (auditoria del 2026-09-08). Ahora sale del mismo singleton que el resto.
     */
    FrameAnimation {
        running: !Motion.off && root.open && root.pos !== root.focusIndex
        onTriggered: {
            const k = 1 - Math.exp(-frameTime / Motion.chaseTau);
            const next = root.pos + (root.focusIndex - root.pos) * k;
            root.pos = Math.abs(next - root.focusIndex) < 0.001 ? root.focusIndex : next;
        }
    }

    /** Video previews only arm once the strip has rested, so paging never spins up decoders. */
    property bool previewArmed: false
    Connections {
        target: Motion
        function onOffChanged() { if (Motion.off) root.pos = root.focusIndex; }
    }
    onFocusIndexChanged: {
        if (Motion.off) root.pos = root.focusIndex;
        root.previewArmed = false;
        previewArm.restart();
    }
    Timer {
        id: previewArm
        interval: 320
        onTriggered: root.previewArmed = true
    }

    function slotLerp(arr, ao) {
        if (ao >= 4)
            return arr[4];
        const i = Math.floor(ao);
        return arr[i] + (arr[i + 1] - arr[i]) * (ao - i);
    }

    function offsetX(off) {
        const ao = Math.abs(off);
        const cx = ao <= 4 ? root.slotLerp(Metrics.slotCX, ao) : Metrics.slotCX[4] + (ao - 4) * 60;
        return (off < 0 ? -cx : cx) * strip.cardScale;
    }

    // ---- búsqueda local (10A) ----------------------------------------------

    Item {
        id: searchRow
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.rowW
        height: 26 * root.s

        Rectangle {
            id: searchBox
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: root.searchW
            height: 26 * root.s
            radius: Metrics.r(8) * root.s
            color: Theme.tileBg
            border.width: root.zone === "search" ? Metrics.focusWidth * root.s : 0
            border.color: Theme.selBorder

            Icon {
                id: searchGlyph
                anchors.left: parent.left
                anchors.leftMargin: 8 * root.s
                anchors.verticalCenter: parent.verticalCenter
                name: "search"
                size: 12 * root.s
                color: Theme.fgVariant
            }
            SearchField {
                id: searchField
                anchors.left: searchGlyph.right
                anchors.leftMargin: 6 * root.s
                anchors.right: clearBtn.visible ? clearBtn.left : parent.right
                anchors.rightMargin: 8 * root.s
                anchors.verticalCenter: parent.verticalCenter
                s: root.s
                placeholder: "Search installed wallpapers"
                onTextChanged: root.setQuery(text)
                // Enter o ↓: a la tira, con el foco en el primer resultado
                onAccepted: root.goZone("strip")
                onMoved: (d) => { if (d > 0) root.goZone("strip"); }
                // Esc: primero limpia; con el campo vacío vuelve a la tira (DESIGN §3)
                onDismissed: {
                    if (text.length > 0) root.clearSearch();
                    else root.goZone("strip");
                }
                onTabbed: root.tabZone(1)
                backtabs: true
                onBacktabbed: root.tabZone(-1)
            }
            Item {
                id: clearBtn
                anchors.right: parent.right
                anchors.rightMargin: 6 * root.s
                anchors.verticalCenter: parent.verticalCenter
                visible: root.query.length > 0
                width: 16 * root.s
                height: 16 * root.s
                Accessible.role: Accessible.Button
                Accessible.name: "Clear search"
                Accessible.onPressAction: root.clearSearch()
                Icon {
                    anchors.centerIn: parent
                    name: "close"
                    size: 11 * root.s
                    color: clearArea.containsMouse ? Theme.fg : Theme.fgVariant
                }
                MouseArea {
                    id: clearArea
                    anchors.fill: parent
                    anchors.margins: -5 * root.s
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.clearSearch()
                }
            }
            // Un clic en la caja lleva el teclado a la búsqueda (no sólo al TextInput).
            TapHandler { onTapped: root.goZone("search") }
        }

        /**
         * El aplicado SIEMPRE nombrado aquí, salga o no en los resultados (spec); con varias
         * pantallas, el de ésta.
         */
        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6 * root.s
            visible: root.onHere.length > 0

            Icon {
                anchors.verticalCenter: parent.verticalCenter
                name: "check-circle"
                size: 12 * root.s
                color: Theme.primary
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: !Wallpaper.multiScreen ? "On screen"
                    : Wallpaper.hasOwn(root.screenName) ? "Own on this screen" : "On this screen"
                color: Theme.fgVariant
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, root.rowW - root.searchW
                                - (root.applyStatus.length > 0 ? 270 : 150) * root.s)
                elide: Text.ElideMiddle
                text: Wallpaper.baseName(root.onHere)
                color: Theme.fg
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
                font.weight: Font.DemiBold
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: !root.onHereShown && root.itemCount > 0 && root.applyStatus.length === 0
                text: "· not in these results"
                color: Theme.outlineText
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
            }
            /** 12G: una pantalla con fondo propio vuelve al de todas (U). */
            Text {
                id: useShared
                anchors.verticalCenter: parent.verticalCenter
                visible: Wallpaper.hasOwn(root.screenName) && root.applyStatus.length === 0
                text: Wallpaper.clearState === "clearing" ? "· using the shared one…"
                    : Wallpaper.clearState === "failed" ? "· could not use the shared one" : "· Use shared (U)"
                color: Wallpaper.clearState === "failed" ? Theme.warn
                    : sharedArea.containsMouse ? Theme.fg : Theme.primary
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
                Accessible.role: Accessible.Button
                Accessible.name: "Use the shared wallpaper on this screen"
                Accessible.onPressAction: root.useShared()
                MouseArea {
                    id: sharedArea
                    anchors.fill: parent
                    anchors.margins: -4 * root.s
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.useShared()
                }
            }
            /** 10B: lo que se está haciendo (el apply y después los colores), observado. */
            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.applyStatus.length > 0
                text: "· " + root.applyStatus
                color: Wallpaper.colorsState === "failed" || Wallpaper.colorsState === "unknown" ? Theme.warn : Theme.fgVariant
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
            }
        }
    }

    // ---- header --------------------------------------------------------

    Item {
        id: header
        anchors.top: searchRow.bottom
        anchors.topMargin: Metrics.sp3 * root.s
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.rowW
        height: 24 * root.s

        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: 7 * root.s

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.focused !== null && root.focused.video
                width: 5 * root.s
                height: 5 * root.s
                radius: Metrics.pill(width)
                color: Theme.secondary
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, root.rowW - chipRow.implicitWidth
                                - (originText.visible ? originText.width + 8 * root.s : 0) - 30 * root.s)
                elide: Text.ElideMiddle
                // The empty-state message below owns the explanation; keep the count here.
                visible: root.focused !== null || Wallpaper.busy
                text: root.focused ? root.focused.name : "scanning…"
                color: Theme.fg
                font.family: Typography.ui
                font.pixelSize: Typography.body * root.s
                font.weight: Font.DemiBold
            }
            /** 10E-1b: «Wallhaven · Nature, Cats», aparte del nombre (no se recorta con él). */
            Text {
                id: originText
                anchors.verticalCenter: parent.verticalCenter
                // el nombre manda: el origen sólo si al nombre le quedan 150 px, y encoge para caber
                readonly property real room: root.rowW - chipRow.implicitWidth - 180 * root.s
                visible: text.length > 0 && room > 50 * root.s
                width: Math.min(implicitWidth, room)
                elide: Text.ElideRight
                text: root.focused ? root.originOf(root.focused.name).replace(/^  ·  /, "") : ""
                color: Theme.outlineText
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
            }
        }

        Row {
            id: chipRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4 * root.s

            Repeater {
                model: root.kinds
                delegate: Rectangle {
                    id: chip
                    required property var modelData
                    required property int index
                    readonly property bool on: root.kind === chip.modelData.key
                    anchors.verticalCenter: parent.verticalCenter
                    width: chipLabel.implicitWidth + 12 * root.s
                    height: 22 * root.s
                    radius: Metrics.pill(height)
                    color: Theme.controlBg("transparent", chipArea.containsMouse, chipArea.pressed && chipArea.containsMouse, chip.on)
                    border.width: root.zone === "filters" && root.filterIndex === chip.index ? Metrics.focusWidth * root.s : 0
                    border.color: Theme.selBorder
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: chip.modelData.label
                    Accessible.checked: chip.on
                    Accessible.onPressAction: root.setKind(chip.modelData.key)
                    Behavior on color { ColorAnimation { duration: Motion.fast } }

                    Text {
                        id: chipLabel
                        anchors.centerIn: parent
                        text: chip.modelData.label
                        color: chip.on ? Theme.primary : Theme.fgVariant
                        font.family: Typography.ui
                        font.pixelSize: Typography.caption * root.s
                        font.weight: Font.DemiBold
                    }

                    MouseArea {
                        id: chipArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.setKind(chip.modelData.key)
                    }
                }
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 1
                height: 12 * root.s
                color: Theme.hair
            }

            /** Recent / Favorites (WallpaperMeta): filtros de la tira; el activo otra vez → todo. */
            Repeater {
                model: root.sets
                delegate: Rectangle {
                    id: setChip
                    required property var modelData
                    required property int index
                    readonly property bool on: root.set === setChip.modelData.key
                    anchors.verticalCenter: parent.verticalCenter
                    width: setLabel.implicitWidth + 12 * root.s
                    height: 16 * root.s
                    radius: Metrics.pill(height)
                    color: Theme.controlBg("transparent", setArea.containsMouse, setArea.pressed && setArea.containsMouse, setChip.on)
                    border.width: root.zone === "filters" && root.filterIndex === root.kinds.length + setChip.index
                        ? Metrics.focusWidth * root.s : 0
                    border.color: Theme.selBorder
                    Accessible.role: Accessible.CheckBox
                    Accessible.name: setChip.modelData.label
                    Accessible.checked: setChip.on
                    Accessible.onPressAction: root.setSet(setChip.modelData.key)
                    Behavior on color { ColorAnimation { duration: Motion.fast } }

                    Text {
                        id: setLabel
                        anchors.centerIn: parent
                        text: setChip.modelData.label
                        color: setChip.on ? Theme.primary : Theme.fgVariant
                        font.family: Typography.ui
                        font.pixelSize: Typography.caption * root.s
                        font.weight: Font.DemiBold
                    }
                    MouseArea {
                        id: setArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.setSet(setChip.modelData.key)
                    }
                }
            }

            /** 10E-1b: Collection: All | nombre — sólo las colecciones del índice con archivos aquí. */
            Rectangle {
                id: collChip
                readonly property bool on: root.collection.length > 0
                anchors.verticalCenter: parent.verticalCenter
                visible: root.localColls.length > 0
                width: Math.min(collLabel.implicitWidth + 12 * root.s, 150 * root.s)
                height: 16 * root.s
                radius: Metrics.pill(height)
                color: Theme.controlBg("transparent", collArea.containsMouse, collArea.pressed && collArea.containsMouse, collChip.on)
                border.width: root.zone === "filters" && root.filterIndex === root.kinds.length + root.sets.length
                    ? Metrics.focusWidth * root.s : 0
                border.color: Theme.selBorder
                Accessible.role: Accessible.ComboBox
                Accessible.name: root.collectionLabel
                Accessible.onPressAction: root.cycleCollection(1)
                Text {
                    id: collLabel
                    anchors.centerIn: parent
                    width: Math.min(implicitWidth, parent.width - 10 * root.s)
                    elide: Text.ElideRight
                    text: root.collectionLabel
                    color: collChip.on ? Theme.primary : Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                    font.weight: Font.DemiBold
                }
                MouseArea {
                    id: collArea
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: (m) => root.cycleCollection(m.button === Qt.RightButton ? -1 : 1)
                }
            }

            /** 10B: Restore previous (teclado: P); apagado sin un fondo anterior. */
            Item {
                anchors.verticalCenter: parent.verticalCenter
                width: 20 * root.s
                height: 16 * root.s
                opacity: root.previousEntry ? 1 : 0.35
                Accessible.role: Accessible.Button
                Accessible.name: root.previousEntry ? "Restore previous: " + Wallpaper.baseName(root.previousEntry.path) + " (P)"
                                                    : "Restore previous: nothing yet"
                Accessible.onPressAction: root.restore()
                Icon {
                    anchors.centerIn: parent
                    name: "history"
                    size: 12 * root.s
                    color: restoreArea.containsMouse && root.previousEntry ? Theme.fg : Theme.fgVariant
                }
                MouseArea {
                    id: restoreArea
                    anchors.fill: parent
                    anchors.margins: -8 * root.s
                    hoverEnabled: true
                    cursorShape: root.previousEntry ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: if (root.previousEntry) root.restore()
                }
            }

            /**
             * Antes de la fase 11: la tienda de Wallhaven (teclado: W). Una sola instancia: la trae a
             * esta pantalla y cierra la tira, que es otro contexto (elegir y aplicar).
             */
            Rectangle {
                id: storeChip
                anchors.verticalCenter: parent.verticalCenter
                width: storeLabel.implicitWidth + 12 * root.s
                height: 16 * root.s
                radius: Metrics.pill(height)
                color: storeArea.containsMouse ? Theme.tileBg : "transparent"
                Behavior on color { ColorAnimation { duration: Motion.fast } }
                Accessible.role: Accessible.Button
                Accessible.name: "Open Wallhaven (W)"
                Accessible.onPressAction: root.openStore()
                Text {
                    id: storeLabel
                    anchors.centerIn: parent
                    text: "Wallhaven ↗"
                    color: storeArea.containsMouse ? Theme.fg : Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                    font.weight: Font.DemiBold
                }
                MouseArea {
                    id: storeArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openStore()
                }
            }

            /** 9B: Configure wallpapers (teclado: S). */
            Item {
                anchors.verticalCenter: parent.verticalCenter
                width: 20 * root.s
                height: 16 * root.s
                Accessible.role: Accessible.Button
                Accessible.name: "Configure wallpapers (S)"
                Accessible.onPressAction: if (root.host) root.host.openSettingsAt("theme/wallpaper")
                Icon {
                    anchors.centerIn: parent
                    name: "cog"
                    size: 12 * root.s
                    color: cfgArea.containsMouse ? Theme.fg : Theme.fgVariant
                }
                MouseArea {
                    id: cfgArea
                    anchors.fill: parent
                    anchors.margins: -8 * root.s
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (root.host) root.host.openSettingsAt("theme/wallpaper")
                }
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                leftPadding: 6 * root.s
                text: root.itemCount > 0 ? (root.focusIndex + 1) + "/" + root.itemCount : "0"
                color: Theme.outlineText
                font.family: Typography.mono
                font.pixelSize: Typography.caption * root.s
                font.features: { "tnum": 1 }
            }
        }
    }

    // ---- strip ---------------------------------------------------------

    Item {
        id: strip
        anchors.top: header.bottom
        anchors.topMargin: Metrics.sp3 * root.s
        anchors.bottom: footer.top
        anchors.bottomMargin: Metrics.sp3 * root.s
        anchors.left: parent.left
        anchors.right: parent.right

        // Tres vecinos completos por lado. En el medio paso siguiente la tarjeta se desvanece
        // dentro del ancho de la cabecera, dejando margen incluso durante el desplazamiento.
        readonly property real outerSlot: 3.5
        readonly property real cardScale: Math.min(root.s, root.rowW / (2 * root.slotLerp(Metrics.slotCX, outerSlot)
            + root.slotLerp(Metrics.slotW, outerSlot)))

        // Hasta seis miniaturas precargadas a cada lado del centro.
        readonly property int capacity: Math.min(root.itemCount, 13)
        readonly property int first: Math.max(0, Math.min(root.itemCount - strip.capacity, Math.floor(root.pos) - 6))
        readonly property var emptyEntry: ({path: "", hasThumb: false, video: false})

        Repeater {
            model: strip.capacity

            delegate: Item {
                id: tile
                required property int index
                // El índice absoluto conserva su tarjeta al moverse una posición.
                readonly property int itemIndex: strip.first + (index - strip.first % 13 + 13) % 13
                readonly property var modelData: root.items[tile.itemIndex] || strip.emptyEntry
                readonly property string entryPath: tile.modelData.path
                property string pressedPath: ""
                onEntryPathChanged: {
                    tile.pressedPath = "";
                    if (thumbRetry) thumbRetry.stop();
                    if (thumbImg) thumbImg.retry = 0;
                }

                readonly property real off: tile.itemIndex - root.pos
                readonly property real ao: Math.abs(tile.off)
                readonly property bool isFocused: tile.itemIndex === root.focusIndex
                readonly property bool isCurrent: tile.modelData.path === root.onHere
                readonly property bool isPending: Wallpaper.applyState === "applying"
                    && tile.modelData.path === Wallpaper.applyPath
                readonly property bool isError: tile.modelData.path === root.errorPath
                readonly property real bright: root.slotLerp(Metrics.slotBright, tile.ao)

                width: root.slotLerp(Metrics.slotW, tile.ao) * strip.cardScale
                height: root.slotLerp(Metrics.slotH, tile.ao) * strip.cardScale
                x: strip.width / 2 + root.offsetX(tile.off) - width / 2
                y: (strip.height - height) / 2
                z: 10 - tile.ao
                visible: tile.ao < strip.outerSlot
                opacity: Math.max(0, Math.min(1, (strip.outerSlot - tile.ao) * 2))

                ClippingRectangle {
                    id: card
                    anchors.fill: parent
                    radius: Metrics.r(9 + 3 * Math.max(0, 1 - tile.ao)) * root.s
                    color: Theme.surfaceContainerLowest

                    /** Only the focused tile gets a shadow: one offscreen buffer, not eleven. */
                    layer.enabled: tile.isFocused
                    layer.effect: MultiEffect {
                        shadowEnabled: true
                        shadowColor: Theme.shadow
                        shadowBlur: 0.7
                        shadowVerticalOffset: 4 * root.s
                    }

                    Image {
                        id: thumbImg
                        anchors.fill: parent
                        // Only tiles near the window get a source at all. `visible`
                        // is not enough: an Image with a source decodes whether or
                        // not it is on screen, so binding all of them pinned a
                        // whole library of decoded thumbnails in RAM (measured:
                        // +340 MB with 79 wallpapers).
                        // The thumb is named after the source file, so a regenerated
                        // one keeps the URL; the mtime busts QPixmapCache.
                        // `retry` se añade a la URL para reintentar cuando la
                        // miniatura aún no existe (el rice la está generando en
                        // background); sin esto la tile quedaba en blanco hasta
                        // cerrar y reabrir la superficie.
                        property int retry: 0
                        // W4: sólo con la miniatura ya en la caché (`hasThumb`, del escaneo, que se
                        // repite mientras falte alguna); pedirla antes dejaba «Cannot open» por intento
                        source: tile.ao <= 6 && tile.modelData.hasThumb
                            ? "file://" + tile.modelData.thumb + "?v=" + Math.round(tile.modelData.mtime) + "&r=" + retry
                            : ""
                        sourceSize.width: 320
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: false
                        onStatusChanged: if (status === Image.Error && root.open && retry < 20)
                            thumbRetry.restart()
                        Timer {
                            id: thumbRetry
                            interval: 1000
                            onTriggered: thumbImg.retry++
                        }
                    }

                    Loader {
                        anchors.fill: parent
                        active: Settings.wallpaperVideoPreview && tile.isFocused
                            && root.previewArmed && tile.modelData.video && root.open
                        source: active ? "VideoPreview.qml" : ""
                        onLoaded: item.path = Qt.binding(() => tile.entryPath)
                    }

                    /** Depth by dimming, not by a per-tile saturation shader. */
                    Rectangle {
                        anchors.fill: parent
                        color: "black"
                        opacity: 1 - tile.bright
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: tile.isPending
                        text: "applying…"
                        color: Theme.fg
                        font.family: Typography.ui
                        font.pixelSize: Typography.caption * root.s
                    }

                    /** Miniatura todavía sin generar: el rice la está creando. */
                    Text {
                        anchors.centerIn: parent
                        visible: !tile.isPending && tile.isFocused
                            && (!tile.modelData.hasThumb || thumbImg.status === Image.Error)
                        text: "generating thumbnail…"
                        color: Theme.fgVariant
                        font.family: Typography.ui
                        font.pixelSize: Typography.caption * root.s
                    }
                }

                /** 10A: el aplicado lleva una marca, además del borde (se lee también en las vecinas). */
                Rectangle {
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.margins: 5 * root.s
                    visible: tile.isCurrent && tile.ao < 3.5
                    width: 16 * root.s
                    height: 16 * root.s
                    radius: Metrics.pill(width)
                    color: Theme.primary
                    Icon {
                        anchors.centerIn: parent
                        name: "check"
                        size: 10 * root.s
                        color: Theme.fgOnPrimary
                    }
                }

                /** Video badge, top-left of the focused tile. */
                Rectangle {
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.margins: 5 * root.s
                    visible: tile.modelData.video && tile.ao < 1.5
                    width: 16 * root.s
                    height: 16 * root.s
                    radius: Metrics.pill(width)
                    color: Qt.rgba(0, 0, 0, 0.55)
                    Text {
                        anchors.centerIn: parent
                        text: "▶"
                        color: Theme.fg
                        font.pixelSize: 7 * root.s
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    radius: card.radius
                    color: "transparent"
                    border.width: (tile.isCurrent || tile.isError) ? 2 : 1
                    border.color: tile.isError ? Theme.errorColor
                        : (tile.isCurrent ? Theme.primary : Theme.hair)
                    Behavior on border.color { ColorAnimation { duration: Motion.fast } }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    property bool focusedOnPress: false
                    onPressed: {
                        tile.pressedPath = tile.entryPath;
                        focusedOnPress = tile.isFocused;
                    }
                    onCanceled: tile.pressedPath = ""
                    onClicked: (m) => {
                        // La tarjeta pudo cambiar de archivo mientras el botón estaba pulsado.
                        if (!tile.pressedPath || tile.pressedPath !== tile.entryPath) return;
                        tile.pressedPath = "";
                        if (focusedOnPress && tile.isFocused)
                            root.activate(m.button === Qt.RightButton);
                        else
                            root.focusIndex = tile.itemIndex;
                    }
                }
            }
        }

        /**
         * Qué falta y qué hacer (DESIGN §7): la búsqueda sin coincidencias no es «biblioteca
         * vacía», y un filtro de Recent/Favorites vacío tampoco.
         */
        Empty {
            anchors.centerIn: parent
            visible: root.itemCount === 0 && !Wallpaper.busy
            s: root.s
            maxWidth: parent.width
            glyph: root.query.length > 0 ? "search" : "wallpaper"
            text: root.query.length > 0 ? "No installed wallpapers match “" + root.query + "”"
                : root.collection.length > 0 && root.set === "library" ? "Nothing from this collection with these filters"
                : root.set === "recent" ? "No recent wallpapers here"
                : root.set === "favorites" ? "No favorites here"
                : Wallpaper.sourceDirs.length === 0 ? "No wallpaper folders"
                : root.kind === "videos" ? "No videos yet"
                : (root.kind === "images" ? "No images yet" : "No wallpapers yet")
            hint: root.query.length > 0 ? "⏎ or click to clear the search"
                : root.set === "recent" ? "Wallpapers you apply appear in Recent"
                : root.set === "favorites" ? "Star wallpapers in Settings · Theme · Wallpaper"
                : "Add folders in Settings · Theme · Wallpaper · Sources (S)"
        }
        /** Clic en el vacío de una búsqueda: la limpia (fuera de `Empty`: es una Column). */
        MouseArea {
            anchors.fill: parent
            visible: root.itemCount === 0 && root.query.length > 0
            cursorShape: Qt.PointingHandCursor
            onClicked: root.clearSearch()
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            property real acc: 0
            onWheel: (event) => {
                acc += event.angleDelta.y / 120;
                const notches = Math.trunc(acc);
                if (notches !== 0) {
                    root.move(-notches);
                    acc -= notches;
                }
                event.accepted = true;
            }
        }
    }

    // ---- footer --------------------------------------------------------

    /**
     * La ayuda de teclado en los renglones que pida, hasta tres (auditoría tipográfica, 2026-11-18). Se mide con
     * un Text OCULTO del ancho del DISEÑO (no el del maquetado): el alto entra en el tamaño del panel y un alto
     * sacado del Text visible cerraba un bucle con `frame` (la lección de 9.f.2). Medir con un Text, y no estimar
     * con el ancho total, cuenta lo que se pierde al partir sólo entre grupos tecla-acción.
     */
    readonly property real hintW: (Metrics.wallpaperW - 48 - (Wallpaper.multiScreen ? 175 : 60)) * root.s
    Text { id: hintFit; visible: false; width: root.hintW; text: footerHint.text; font: footerHint.font
           wrapMode: Text.WordWrap; maximumLineCount: 3 }
    readonly property int hintLines: Math.max(1, hintFit.lineCount)
    /** Lo que crece el pie con el segundo renglón (SurfaceHost lo suma al alto del panel). */
    readonly property real footerExtra: Math.max(0, footer.height - 14 * root.s)

    Item {
        id: footer
        // 10C-1: el bloque local tiene su alto fijo; debajo va Wallhaven
        anchors.top: parent.top
        anchors.topMargin: (Metrics.wallpaperH - root.mTop - root.mBottom) * root.s + root.footerExtra - height
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.rowW
        // un renglón (el diseño) o dos si la ayuda no cabe: la tira no se mueve, el panel crece por abajo
        height: Math.max(14 * root.s, footerHint.visible ? hintFit.implicitHeight : 0)

        Text {
            id: footerHint
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            visible: root.noticeText.length === 0 && root.capNote.length === 0
            // 12G: con el destino «esta pantalla», la ayuda dice de dónde siguen saliendo los colores
            wrapMode: Text.WordWrap
            maximumLineCount: root.hintLines
            text: TextWrap.keepHints(root.zone === "search" ? "type to filter    ⏎ ↓  results    Esc  clear    ⇥  filters"
                : root.zone === "filters" ? "← →  choose    ⏎  toggle    Esc ↓  results    ⇥  wallpapers"
                : root.targetScreen
                ? "⏎  this screen only · colours from " + Wallpaper.paletteOriginShort + "    ⇧⏎  all    M  target"
                : Wallpaper.multiScreen
                ? "⏎  all screens    ⇧⏎  this one    M  target    /  search    R  random    P  previous    S  settings"
                : "← →  move    ⏎  apply    /  search    ⇥  next    R  random    P  previous    W  Wallhaven    S  settings")
            color: root.targetScreen ? Theme.fgVariant : Theme.outlineText
            elide: Text.ElideRight
            width: parent.width - (Wallpaper.multiScreen ? 175 : 60) * root.s
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }

        /**
         * El fallo al aplicar ocupa el sitio de la ayuda de teclado durante los 4 s
         * de `errorClear`. Centrado sobre el pie y SIN cambiar su alto: la tira
         * de miniaturas se ancla a `footer.top`, y crecer el pie la haría saltar.
         */
        Notice {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 60 * root.s
            visible: root.noticeText.length > 0
            s: root.s
            tone: root.noticeTone
            text: root.noticeText
        }
        /** F2c: lo que no se puede aquí, fijo en el sitio de la ayuda (sin cambiar el alto del pie). */
        Notice {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - (Wallpaper.multiScreen ? 175 : 60) * root.s
            visible: root.noticeText.length === 0 && root.capNote.length > 0
            s: root.s
            tone: "warn"
            text: root.capNote
        }

        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8 * root.s

            Text {
                anchors.verticalCenter: parent.verticalCenter
                // con varias pantallas lo dice la cabecera («On this screen …») y el pie necesita el
                // sitio para el selector y la ayuda
                visible: !Wallpaper.multiScreen && root.focused !== null && root.focused.path === root.onHere
                text: "on screen"
                color: Theme.primary
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
                font.weight: Font.DemiBold
            }

            /** 12G: el destino del Enter, visible y con ratón (antes sólo ⇧⏎ o clic derecho). */
            Row {
                anchors.verticalCenter: parent.verticalCenter
                visible: Wallpaper.multiScreen
                spacing: 2 * root.s
                Repeater {
                    model: [{ key: "all", label: "All screens" }, { key: "screen", label: "This screen" }]
                    delegate: Rectangle {
                        id: tgt
                        required property var modelData
                        readonly property bool on: root.applyTarget === tgt.modelData.key
                        anchors.verticalCenter: parent.verticalCenter
                        width: tgtText.implicitWidth + 12 * root.s
                        height: 16 * root.s
                        radius: Metrics.pill(height)
                        color: Theme.controlBg("transparent", tgtArea.containsMouse, tgtArea.pressed && tgtArea.containsMouse, tgt.on)
                        border.width: tgt.on ? 0 : 1
                        border.color: Theme.hair
                        Accessible.role: Accessible.RadioButton
                        Accessible.name: "Apply to " + tgt.modelData.label.toLowerCase()
                        Accessible.checked: tgt.on
                        Accessible.onPressAction: root.applyTarget = tgt.modelData.key
                        Text {
                            id: tgtText
                            anchors.centerIn: parent
                            text: tgt.modelData.label
                            color: tgt.on ? Theme.primary : Theme.fgVariant
                            font.family: Typography.ui
                            font.pixelSize: Typography.caption * root.s
                            font.weight: tgt.on ? Font.DemiBold : Font.Normal
                        }
                        MouseArea {
                            id: tgtArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.applyTarget = tgt.modelData.key
                        }
                    }
                }
            }
        }
    }
}
