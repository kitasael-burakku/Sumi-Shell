pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import "../services"
import "../theme"
import "../components"
import "../surfaces" as Surfaces

/**
 * Ventana flotante Login screen (Sumi SDDM, 2026-11-23), como Calendar, Monitor y Audio: capa `sumi-login`, tarjeta
 * arrastrable por la cabecera y con asa de tamaño. El contenido es surfaces/LoginScreen; el estado de la vista,
 * services/LoginUi; los datos, SddmTheme (también los usa Settings → Desktop tools → Login screen).
 */
PanelWindow {
    id: win
    required property var targetScreen
    readonly property string name: win.targetScreen ? win.targetScreen.name : ""
    readonly property real s: Settings.uiScale
    readonly property bool shown: LoginUi.open && LoginUi.screen === win.name && !Lock.engaged
    readonly property real margin: Metrics.storeMargin * win.s
    readonly property real topInset: Math.max(Metrics.reservedH(win.s), Metrics.reservedBarH(win.s))
    /** La barra permanente abajo o a un lado no se tapa: su franja, además del margen (Screen.barInset). */
    readonly property var barHost: Screens.byName(win.targetScreen ? String(win.targetScreen.name) : "")
    readonly property real leftInset: win.margin + (win.barHost ? win.barHost.barInset("left") : 0)
    readonly property real rightInset: win.margin + (win.barHost ? win.barHost.barInset("right") : 0)
    readonly property real bottomInset: win.margin + (win.barHost ? win.barHost.barInset("bottom") : 0)
    readonly property real areaW: win.targetScreen ? win.targetScreen.width : 0
    readonly property real areaH: win.targetScreen ? win.targetScreen.height : 0
    readonly property real maxW: Math.max(0, win.areaW - win.leftInset - win.rightInset)
    readonly property real maxH: Math.max(0, win.areaH - win.topInset - win.bottomInset)
    readonly property real minW: Math.min(win.maxW, 720 * win.s)
    readonly property real minH: Math.min(win.maxH, 520 * win.s)
    /** «AnchoxAlto» del monitor en píxeles físicos: el tamaño de serie de la vista previa. */
    readonly property string physicalSize: {
        const sc = win.targetScreen;
        if (!sc) return "1920x1080";
        const r = sc.devicePixelRatio || 1;
        return Math.round(sc.width * r) + "x" + Math.round(sc.height * r);
    }
    screen: win.targetScreen
    visible: win.shown || card.appear > 0.001
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "sumi-login"
    WlrLayershell.keyboardFocus: win.shown ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    anchors { top: true; left: true; right: true; bottom: true }
    mask: win.shown ? cardRegion : noRegion
    Region { id: noRegion }
    /** La geometría de la tarjeta, sin la transformación de la entrada (nunca `item: card`: tools/sumi-drag/). */
    Region { id: cardRegion; x: card.x; y: card.y; width: card.width; height: card.height }

    function contentItem() { return body.item; }
    function focusKeys() { if (win.shown) keys.forceActiveFocus(); }
    function keysFocused() { return keys.activeFocus; }
    function raise() { if (win.shown) Qt.callLater(win.focusKeys); }
    function restore(ctx) { if (body.item) body.item.restoreContext(ctx); }
    function clampX(x) { return Math.max(win.leftInset, Math.min(win.areaW - card.width - win.rightInset, x)); }
    function clampY(y) { return Math.max(win.topInset, Math.min(win.areaH - card.height - win.bottomInset, y)); }
    function place() {
        if (win.areaW <= 0 || win.areaH <= 0) return;
        const p = LoginUi.positionOf(win.name);
        card.x = win.clampX(p ? p.x : (win.areaW - card.width) / 2);
        card.y = win.clampY(p ? p.y : (win.areaH - card.height) / 2);
    }
    function placeAt(x, y) {
        if (!win.shown) return false;
        card.x = win.clampX(x); card.y = win.clampY(y);
        LoginUi.remember(win.name, card.x, card.y);
        return true;
    }
    function handle(k, mods) {
        if (!win.shown) return false;
        const it = body.item;
        const event = { key: k, modifiers: mods, accepted: false };
        if (it) it.keyPressed(event);
        if (event.accepted) return true;
        if (k === Qt.Key_Escape) { LoginUi.close(true); return true; }
        return false;
    }
    /** IPC `loginUiKey`: «Down», «Ctrl+F», «Shift+Tab»… (el modificador delante, como lo escribe el IPC). */
    function key(name) {
        const map = { Escape: Qt.Key_Escape, Return: Qt.Key_Return, Space: Qt.Key_Space, Up: Qt.Key_Up, Down: Qt.Key_Down,
            Left: Qt.Key_Left, Right: Qt.Key_Right, PageUp: Qt.Key_PageUp, PageDown: Qt.Key_PageDown, Tab: Qt.Key_Tab,
            Backtab: Qt.Key_Backtab, Delete: Qt.Key_Delete, F: Qt.Key_F };
        const ctrl = String(name).indexOf("Ctrl+") === 0;
        const k = ctrl ? String(name).substring(5) : String(name);
        return map[k] ? win.handle(map[k], ctrl ? Qt.ControlModifier : 0) : false;
    }
    function geometry() {
        const it = body.item;
        return { screen: win.name, shown: win.shown, x: card.x, y: card.y, w: card.width, h: card.height,
            screenW: win.areaW, screenH: win.areaH, physical: win.physicalSize, loaded: it !== null,
            page: it ? it.page : "", zone: it ? it.zone : "", kbIndex: it ? it.kbIndex : -1,
            narrow: it ? it.narrow : false, zoomed: it ? it.zoomed : false,
            appear: card.appear, dragging: head.drag.active, resizing: grip.pressed, focused: keys.activeFocus };
    }
    onShownChanged: {
        if (win.shown) { win.place(); keys.forceActiveFocus(); }
    }
    onAreaWChanged: if (win.shown) win.place()
    onAreaHChanged: if (win.shown) win.place()
    Component.onCompleted: LoginUi.layer = win
    Component.onDestruction: { if (LoginUi.layer === win) LoginUi.layer = null; }

    Item {
        id: card
        readonly property var want: LoginUi.size
        width: Math.max(win.minW, Math.min(win.maxW, (card.want ? card.want.w : 1180) * win.s))
        height: Math.max(win.minH, Math.min(win.maxH, (card.want ? card.want.h : 720) * win.s))
        onWidthChanged: if (win.shown && !grip.pressed) Qt.callLater(win.place)
        onHeightChanged: if (win.shown && !grip.pressed) Qt.callLater(win.place)
        // Entrada/salida (theme/Reveal, Settings → Animations → Window style): sólo visual
        Reveal { id: cardReveal; shown: win.shown; s: win.s }
        readonly property real appear: cardReveal.progress
        opacity: cardReveal.opacity
        scale: cardReveal.scale
        transformOrigin: Item.Center
        transform: [Translate { y: cardReveal.dy }, Scale { origin.x: card.width / 2; origin.y: card.height / 2; xScale: cardReveal.sx; yScale: cardReveal.sy }]
        layer.enabled: card.appear > 0.001 && card.appear < 0.999
        layer.effect: cardReveal.effect ? cardFx : null
        Component { id: cardFx; RevealEffect { rv: cardReveal; s: win.s } }
        Glass {
            anchors.fill: parent; s: win.s; radius: Metrics.rLg * win.s
            surface: "loginUi"; shadowed: !head.drag.active && !grip.pressed
        }
        Item {
            id: keys
            anchors.fill: parent; focus: true
            Keys.onPressed: event => { if (win.handle(event.key, event.modifiers)) event.accepted = true; }
        }
        // la cabecera arrastra la tarjeta; sus botones (del contenido, encima) se quedan sus clics
        MouseArea {
            id: head
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            height: 64 * win.s
            cursorShape: head.drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            drag.target: card; drag.threshold: 2
            drag.minimumX: win.leftInset; drag.maximumX: Math.max(win.leftInset, win.areaW - card.width - win.rightInset)
            drag.minimumY: win.topInset; drag.maximumY: Math.max(win.topInset, win.areaH - card.height - win.bottomInset)
            onPressed: keys.forceActiveFocus()
            onReleased: LoginUi.remember(win.name, card.x, card.y)
        }
        Loader {
            id: body
            anchors.fill: parent
            active: win.shown || card.appear > 0.001
            sourceComponent: Surfaces.LoginScreen {
                s: win.s; open: win.shown; screenName: win.name; screenSize: win.physicalSize
                onRequestClose: (back) => LoginUi.close(back)
                onRequestFocus: win.focusKeys()
            }
        }
        /** Esquina inferior derecha: cambia el tamaño (dentro del monitor; mínimo legible). */
        MouseArea {
            id: grip
            z: 50
            anchors.right: parent.right; anchors.bottom: parent.bottom
            width: 18 * win.s; height: 18 * win.s
            cursorShape: Qt.SizeFDiagCursor
            hoverEnabled: true
            property point origin
            property size start
            onPressed: mouse => {
                grip.origin = mapToItem(null, mouse.x, mouse.y);
                grip.start = Qt.size(card.width, card.height);
                keys.forceActiveFocus();
            }
            onPositionChanged: mouse => {
                if (!grip.pressed) return;
                const p = mapToItem(null, mouse.x, mouse.y);
                const w = Math.max(win.minW, Math.min(win.areaW - card.x - win.rightInset, grip.start.width + p.x - grip.origin.x));
                const h = Math.max(win.minH, Math.min(win.areaH - card.y - win.bottomInset, grip.start.height + p.y - grip.origin.y));
                LoginUi.size = { w: Math.round(w / win.s), h: Math.round(h / win.s) };
            }
            onReleased: LoginUi.remember(win.name, card.x, card.y)
            Accessible.role: Accessible.Grip
            Accessible.name: "Resize login screen window"
            Repeater {
                model: 2
                delegate: Rectangle {
                    required property int index
                    readonly property real len: (index === 0 ? 11 : 6) * win.s
                    width: len; height: Math.max(1, win.s)
                    radius: Metrics.pill(height)
                    rotation: -45
                    color: Theme.fgVariant
                    opacity: grip.containsMouse || grip.pressed ? 0.9 : 0.45
                    x: grip.width - 4 * win.s - len * 0.85
                    y: grip.height - 4 * win.s - len * 0.35
                }
            }
        }
        // interferencia de terminal: al abrir y al cambiar de grupo; encima de todo, sin recibir clics. Último hijo
        Interference { anchors.fill: parent; s: win.s; open: win.shown; key: body.item ? body.item.page : "" }
    }
}
