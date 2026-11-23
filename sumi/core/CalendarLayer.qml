pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import "../services"
import "../theme"
import "../components"
import "../surfaces" as Surfaces

/** Floating shell card, like Monitor and Audio. No independent calendar data model. */
PanelWindow {
    id: win
    required property var targetScreen
    readonly property string name: win.targetScreen ? win.targetScreen.name : ""
    readonly property real s: Settings.uiScale
    readonly property bool shown: CalendarUi.open && CalendarUi.screen === win.name && !Lock.engaged
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
    WlrLayershell.namespace: "sumi-calendar"
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

    function contentItem() { return body.item; }
    /** Al cerrar el formulario, el teclado vuelve a la tarjeta (un campo oculto no lo devuelve solo). */
    function focusKeys() { if (win.shown) keys.forceActiveFocus(); }
    function keysFocused() { return keys.activeFocus; }
    function restore(ctx) { if (body.item) body.item.restoreContext(ctx); }
    function clampX(x) { return Math.max(win.leftInset, Math.min(win.areaW - card.width - win.rightInset, x)); }
    function clampY(y) { return Math.max(win.topInset, Math.min(win.areaH - card.height - win.bottomInset, y)); }
    function place() {
        if (win.areaW <= 0 || win.areaH <= 0) return;
        const p = CalendarUi.positionOf(win.name);
        card.x = win.clampX(p ? p.x : (win.areaW-card.width)/2);
        card.y = win.clampY(p ? p.y : (win.areaH-card.height)/2);
    }
    function placeAt(x, y) {
        if (!win.shown) return false;
        card.x = win.clampX(x); card.y = win.clampY(y);
        CalendarUi.remember(win.name, card.x, card.y);
        return true;
    }
    function handle(k, mods) {
        if (!win.shown) return false;
        const it = body.item;
        const event = {key:k, modifiers:mods, accepted:false};
        if (it) it.keyPressed(event);
        if (event.accepted) return true;
        if (k === Qt.Key_Escape) { CalendarUi.close(); return true; }
        return false;
    }
    function key(name) {
        const map = {Escape:Qt.Key_Escape, Backspace:Qt.Key_Backspace, Return:Qt.Key_Return,
            Up:Qt.Key_Up, Down:Qt.Key_Down, Left:Qt.Key_Left, Right:Qt.Key_Right,
            PageUp:Qt.Key_PageUp, PageDown:Qt.Key_PageDown, Home:Qt.Key_Home, End:Qt.Key_End,
            Tab:Qt.Key_Tab, Backtab:Qt.Key_Backtab, Delete:Qt.Key_Delete, N:Qt.Key_N, E:Qt.Key_E, S:Qt.Key_S};
        // «Ctrl+S»: el modificador delante, como lo escribe el IPC.
        const ctrl = String(name).indexOf("Ctrl+") === 0;
        const k = ctrl ? String(name).substring(5) : name;
        return map[k] ? win.handle(map[k], ctrl ? Qt.ControlModifier : 0) : false;
    }
    function geometry() {
        return {screen:win.name, shown:win.shown, x:card.x, y:card.y, w:card.width, h:card.height,
            screenW:win.areaW, screenH:win.areaH, topInset:win.topInset, margin:win.margin,
            loaded:body.item !== null, split:body.item ? body.item.splitLayout : false,
            appear:card.appear, dragging:head.drag.active};
    }
    onShownChanged: {
        if (win.shown) { win.place(); keys.forceActiveFocus(); }
        else {
            if (body.item) CalendarUi.context = body.item.saveContext();
            CalendarEdit.markDraft();   // cambios sin guardar: al volver se ven como borrador
        }
    }
    onAreaWChanged: if (win.shown) win.place()
    onAreaHChanged: if (win.shown) win.place()
    Component.onCompleted: CalendarUi.layer = win
    Component.onDestruction: {
        if (CalendarUi.layer === win) {
            CalendarUi.capture();
            CalendarUi.layer = null;
        }
    }

    Item {
        id: card
        width: Math.max(0, Math.min(980 * win.s, win.areaW - win.leftInset - win.rightInset))
        height: Math.max(0, Math.min(660 * win.s, win.areaH - win.topInset - win.bottomInset))
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
        Glass {
            anchors.fill: parent; s: win.s; radius: Metrics.rLg * win.s
            surface: "calendarUi"; shadowed: !head.drag.active   // el material global (Theme → Material)
        }
        Item {
            id: keys
            anchors.fill: parent; focus:true
            Keys.onPressed: event => { if (win.handle(event.key,event.modifiers)) event.accepted=true; }
        }
        MouseArea {
            id: head
            anchors.left: parent.left; anchors.right:parent.right; anchors.top:parent.top
            height: 64 * win.s
            cursorShape: head.drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            drag.target:card; drag.threshold:2
            drag.minimumX: win.leftInset; drag.maximumX:Math.max(win.leftInset, win.areaW - card.width - win.rightInset)
            drag.minimumY:win.topInset; drag.maximumY:Math.max(win.topInset,win.areaH - card.height - win.bottomInset)
            onPressed: keys.forceActiveFocus()
            onReleased: CalendarUi.remember(win.name,card.x,card.y)
        }
        Column {
            anchors.left:parent.left; anchors.leftMargin:20*win.s
            anchors.right:closeButton.left; anchors.rightMargin:16*win.s
            anchors.verticalCenter:head.verticalCenter; spacing:2*win.s
            Text { width:parent.width; text:"Calendar"; elide:Text.ElideRight; color:Theme.fg; font.family:Typography.ui; font.pixelSize:Typography.display*win.s; font.weight:Typography.wStrong }
            Text { width:parent.width; text:"Month, agenda and local events"; elide:Text.ElideRight; color:Theme.fgVariant; font.family:Typography.ui; font.pixelSize:Typography.label*win.s }
        }
        ActionButton {
            id: closeButton
            anchors.right:parent.right; anchors.rightMargin:14*win.s; anchors.verticalCenter:head.verticalCenter
            s:win.s; glyph:"close"; label:"Close"; onTriggered:CalendarUi.close()
        }
        Rectangle { anchors.top:head.bottom; x:18*win.s; width:parent.width-36*win.s; height:1; color:Theme.hair }
        Loader {
            id: body
            anchors.top:head.bottom; anchors.left:parent.left; anchors.right:parent.right; anchors.bottom:parent.bottom
            active: win.shown || card.appear > 0.001
            sourceComponent: Surfaces.Calendar {
                expanded:true; initialContext:CalendarUi.context
                screenName:win.name; s:win.s; open:win.shown; closeness:1; settled:true
                onRequestClose:CalendarUi.close()
                onRequestBack:CalendarUi.close()
            }
        }
        // interferencia de terminal (2026-11-15): al abrir y al cambiar de vista; encima de todo (z), sin
        // recibir clics. Último hijo de la tarjeta: no corre los índices de los demás
        Interference { anchors.fill: parent; s: win.s; open: win.shown; key: "" }
    }
}
