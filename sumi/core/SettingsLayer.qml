pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Wayland
import "../services"
import "../theme"
import "../components"
import "../surfaces" as Surfaces

/**
 * Settings UI independiente (2026-11-07). Antes Settings era una superficie del island (fase 9A,
 * 880×560 fijo, tres destinos); ahora es una tarjeta flotante como la Calendar UI, la del
 * monitor y la tienda de Wallhaven: se arrastra por la cabecera dentro del monitor, se puede
 * redimensionar por la esquina, una sola instancia (`SettingsUi`), fuera de Alt+Tab.
 *
 * Esta capa es SÓLO la ventana y su ciclo de vida: posición, tamaño, aparición, teclado, la
 * pregunta de salida y cuándo se descarga el contenido. El contenido es el mismo
 * `surfaces/Settings.qml` de siempre (la tabla, las filas, la búsqueda) en modo `floating`,
 * sin host del island. Las preferencias siguen en `services/Settings`.
 *
 * Teclado: lo da el compositor al pulsar dentro (`OnDemand`) y al abrirse. Las teclas que el
 * contenido no consume suben hasta aquí: Esc cierra (o vuelve a la superficie de origen). Con
 * un secreto sin enviar (clave de Wallhaven, prueba PAM) cerrar pregunta antes, como el host.
 *
 * Cerrada, el contenido sigue cargado `Settings.unloadSec` (el mismo «Unload after» que las
 * superficies) para que reabrir sea inmediato; después se descarga guardando la vista. Con la
 * sesión bloqueada se descarga en el acto y los campos secretos se vacían.
 */
PanelWindow {
    id: win
    required property var targetScreen
    readonly property string name: win.targetScreen ? win.targetScreen.name : ""
    readonly property real s: Settings.uiScale
    readonly property bool shown: SettingsUi.open && SettingsUi.screen === win.name && !Lock.engaged
    readonly property real margin: Metrics.storeMargin * win.s
    // Leave the resting Island/bar accessible even when the window fills a short screen.
    readonly property real topInset: Math.max(Metrics.reservedH(win.s), Metrics.reservedBarH(win.s))
    /** 2026-11-19: la barra permanente abajo o a un lado no se tapa: su franja, además del margen (Screen.barInset). */
    readonly property var barHost: Screens.byName(win.targetScreen ? String(win.targetScreen.name) : "")
    readonly property real leftInset: win.margin + (win.barHost ? win.barHost.barInset("left") : 0)
    readonly property real rightInset: win.margin + (win.barHost ? win.barHost.barInset("right") : 0)
    readonly property real bottomInset: win.margin + (win.barHost ? win.barHost.barInset("bottom") : 0)
    readonly property real areaW: win.targetScreen ? win.targetScreen.width : 0
    readonly property real areaH: win.targetScreen ? win.targetScreen.height : 0
    readonly property real maxW: Math.max(0, win.areaW - win.leftInset - win.rightInset)
    readonly property real maxH: Math.max(0, win.areaH - win.topInset - win.bottomInset)
    readonly property real minW: Math.min(win.maxW, Metrics.settingsUiMinW * win.s)
    readonly property real minH: Math.min(win.maxH, Metrics.settingsUiMinH * win.s)

    screen: win.targetScreen
    visible: win.shown || card.appear > 0.001
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "sumi-settings"
    WlrLayershell.keyboardFocus: !win.shown ? WlrKeyboardFocus.None
        : win.grab ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand
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

    /**
     * El teclado. Con `OnDemand` Hyprland NO siempre da el teclado a una capa al mapearla (medido en
     * el banco: la primera apertura tras arrancar a veces se quedaba sin él), ni siempre lo devuelve
     * cuando se cierra una superficie del island abierta desde un enlace de Settings (0,5 s o nunca).
     * Así que al abrirse, y al cerrarse la superficie que abrió un enlace propio, la ventana lo pide en
     * exclusiva (`grab`) HASTA que el compositor se lo da (como mucho 1,5 s) y vuelve a `OnDemand`: el
     * clic fuera sigue llevándolo a otra ventana. Un pulso corto con reintentos no bastaba: cuando el
     * island suelta el suyo a la vez, Hyprland tardaba más (banco, 2026-11-07).
     */
    property bool grab: false
    function pulseGrab() {
        win.grab = true;
        regrab.restart();
        if (card.Window.active) release.restart();
    }
    property string linked: ""
    readonly property var hostScreen: Screens.byName(win.name)
    readonly property string islandOpen: win.hostScreen ? win.hostScreen.open : ""
    onIslandOpenChanged: {
        // una superficie del island se abre encima: el teclado es suyo, no se le disputa
        if (win.islandOpen.length > 0) { linkBack.stop(); regrab.stop(); release.stop(); win.grab = false; return; }
        if (win.linked.length === 0) return;
        win.linked = "";
        if (win.shown) linkBack.restart();
    }
    /**
     * Un momento después, no en el mismo instante: si la petición llega junto con la liberación del
     * island, Hyprland a veces la pasaba por alto (banco: los primeros ciclos tras arrancar, 3 s sin
     * teclado); hecha después, siempre se atiende.
     */
    Timer {
        id: linkBack
        interval: 150
        onTriggered: if (win.shown && win.islandOpen.length === 0) { win.pulseGrab(); win.raise(); }
    }
    /** Tope: si el compositor no lo da (otra capa exclusiva delante), no se insiste. */
    Timer { id: regrab; interval: 1500; onTriggered: win.grab = false }
    /** Ya lo tiene: un momento más para que no se cruce con la capa que lo soltaba, y `OnDemand`. */
    Timer { id: release; interval: 120; onTriggered: { regrab.stop(); win.grab = false; } }
    function followLink(n, k) {
        if (Screens.openFromSettings(win.name, n, k)) win.linked = n;
    }
    /** Devuelve el teclado a la tarjeta (al abrir, al volver de un enlace, tras la pregunta). */
    function raise() { if (win.shown) Qt.callLater(win.focusContent); }
    function focusContent() {
        if (!win.shown) return;
        if (body.item) body.item.forceActiveFocus(); else keys.forceActiveFocus();
    }
    function clampX(x) { return Math.max(win.leftInset, Math.min(win.areaW - card.width - win.rightInset, x)); }
    function clampY(y) { return Math.max(win.topInset, Math.min(win.areaH - card.height - win.bottomInset, y)); }
    function place() {
        if (win.areaW <= 0 || win.areaH <= 0) return;
        const p = SettingsUi.positionOf(win.name);
        card.x = win.clampX(p ? p.x : (win.areaW - card.width) / 2);
        card.y = win.clampY(p ? p.y : win.topInset + Math.max(0, (win.areaH - win.topInset - win.bottomInset - card.height) / 2));
    }
    function placeAt(x, y) {
        if (!win.shown) return false;
        card.x = win.clampX(x); card.y = win.clampY(y);
        SettingsUi.remember(win.name, card.x, card.y);
        return true;
    }
    /** Tamaño en unidades lógicas (se escala con la interfaz); sólo de la sesión, no es una preferencia. */
    function resizeTo(w, h) {
        if (!win.shown) return false;
        SettingsUi.size = { w: Math.round(w / win.s), h: Math.round(h / win.s) };
        Qt.callLater(win.place);
        return true;
    }

    // ---- salida protegida (como `SurfaceHost` §Guarded) ------------------------------------

    /** null · {back: bool}: algo quiso cerrar con un secreto sin enviar; se pregunta. */
    property var leaveTarget: null
    property int leaveChoice: 0
    readonly property string leaveReason: body.item && body.item.guardReason ? body.item.guardReason : ""
    onLeaveReasonChanged: if (win.leaveReason.length === 0) win.leaveTarget = null
    /** true si la salida queda pendiente de la pregunta (`SettingsUi.close` lo consulta). */
    function guardBlocks(back) {
        if (!win.shown || win.leaveReason.length === 0) return false;
        win.leaveTarget = { back: back === true };
        win.leaveChoice = 0;
        leaveKeys.forceActiveFocus();  // si lo conservara el campo, un Enter enviaría el secreto
        return true;
    }
    function keepEditing() {
        win.leaveTarget = null;
        if (body.item) body.item.focusGuarded();
    }
    function discardAndLeave() {
        const t = win.leaveTarget;
        win.leaveTarget = null;
        if (body.item) body.item.discardGuarded();
        SettingsUi.close(t ? t.back : false);
    }
    function leaveKey(event) {
        const k = event.key;
        if (k === Qt.Key_Escape) win.keepEditing();
        else if (k === Qt.Key_Left || k === Qt.Key_Right || k === Qt.Key_Tab || k === Qt.Key_Backtab)
            win.leaveChoice = win.leaveChoice === 0 ? 1 : 0;
        else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) {
            if (win.leaveChoice === 0) win.keepEditing(); else win.discardAndLeave();
        }
        event.accepted = true;         // nada más llega a Settings mientras se pregunta
    }

    // ---- teclado -------------------------------------------------------------------------

    /** Lo que el contenido no consume: Esc vuelve (con origen) o cierra. */
    function handle(event) {
        if (!win.shown) return false;
        if (win.leaveTarget !== null) { win.leaveKey(event); return true; }
        const it = body.item;
        if (it) it.keyPressed(event);
        if (event.accepted) return true;
        if (event.key === Qt.Key_Escape) { SettingsUi.close(true); event.accepted = true; return true; }
        return false;
    }
    /** El mismo manejo que una tecla real, para el IPC (`settingsUiKey`), sin inyectar nada al compositor. */
    function key(name, shift) {
        const map = {Escape: Qt.Key_Escape, Tab: Qt.Key_Tab, Backtab: Qt.Key_Backtab, Up: Qt.Key_Up, Down: Qt.Key_Down,
            Left: Qt.Key_Left, Right: Qt.Key_Right, Home: Qt.Key_Home, End: Qt.Key_End, PageUp: Qt.Key_PageUp,
            PageDown: Qt.Key_PageDown, Return: Qt.Key_Return, Space: Qt.Key_Space, Delete: Qt.Key_Delete,
            Backspace: Qt.Key_Backspace};
        let n = String(name), mods = shift ? Qt.ShiftModifier : Qt.NoModifier;
        if (n.indexOf("Ctrl+") === 0) { mods |= Qt.ControlModifier; n = n.substring(5); }
        if (n.indexOf("Alt+") === 0) { mods |= Qt.AltModifier; n = n.substring(4); }
        const letter = /^[A-Z]$/.test(n);
        const k = n === "Tab" && shift ? Qt.Key_Backtab : letter ? Qt.Key_A + n.charCodeAt(0) - 65 : map[n];
        if (!k) return false;
        const e = {key: k, modifiers: mods, text: k === Qt.Key_Space ? " " : "", isAutoRepeat: false, accepted: false};
        return win.handle(e);
    }
    function geometry() {
        const it = body.item;
        return {screen: win.name, shown: win.shown, x: Math.round(card.x), y: Math.round(card.y),
            w: Math.round(card.width), h: Math.round(card.height), screenW: Math.round(win.areaW),
            screenH: Math.round(win.areaH), topInset: Math.round(win.topInset), margin: Math.round(win.margin),
            minW: Math.round(win.minW), minH: Math.round(win.minH),
            loaded: it !== null, keep: unload.running, appear: Math.round(card.appear * 100) / 100,
            dragging: drag.drag.active, resizing: grip.pressed, focused: win.contentFocused(), linked: win.linked, grab: win.grab,
            windowActive: card.Window.active,
            leave: win.leaveTarget !== null ? {reason: win.leaveReason, choice: win.leaveChoice} : null,
            layout: it ? it.layoutInfo() : null};
    }
    /** ¿Tiene el teclado algo dentro de la tarjeta? (para comprobar la vuelta de los enlaces) */
    function contentFocused() { return keys.activeFocus || (body.item !== null && body.item.activeFocus); }

    /** Cerrada: el contenido se queda «Unload after» y luego se descarga guardando la vista. */
    property bool keep: false
    Timer {
        id: unload
        interval: Math.max(5, Settings.unloadSec) * 1000
        onTriggered: { SettingsUi.capture(); win.keep = false; }
    }
    onShownChanged: {
        if (win.shown) {
            unload.stop();
            win.keep = true;
            win.place();
            win.pulseGrab();
            win.raise();
        } else {
            win.leaveTarget = null;
            if (body.item) SettingsUi.context = body.item.saveContext();
            if (Lock.engaged) {
                // bloqueada: nada de secretos en memoria ni contenido cargado tras el cristal
                if (body.item) body.item.discardGuarded();
                unload.stop();
                win.keep = false;
            } else unload.restart();
        }
    }
    onAreaWChanged: if (win.shown) win.place()
    onAreaHChanged: if (win.shown) win.place()
    Component.onCompleted: { SettingsUi.layer = win; if (win.shown) { win.keep = true; win.place(); win.pulseGrab(); win.raise(); } }
    Component.onDestruction: {
        if (SettingsUi.layer === win) {
            SettingsUi.capture();
            SettingsUi.layer = null;
        }
    }

    Item {
        id: card
        readonly property var want: SettingsUi.size
        width: Math.max(win.minW, Math.min(win.maxW, (card.want ? card.want.w : Metrics.settingsUiW) * win.s))
        height: Math.max(win.minH, Math.min(win.maxH, (card.want ? card.want.h : Metrics.settingsUiH) * win.s))
        onWidthChanged: if (win.shown && !grip.pressed) Qt.callLater(win.place)
        onHeightChanged: if (win.shown && !grip.pressed) Qt.callLater(win.place)
        Window.onActiveChanged: if (Window.active && win.grab) release.restart()
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
            surface: "settings"; shadowed: !drag.drag.active && !grip.pressed   // el material global (Theme → Material)
        }

        /**
         * La franja de arriba arrastra la tarjeta. Va DEBAJO del contenido: los controles de la
         * cabecera (búsqueda, Back/Forward, Close) se llevan sus clics; el resto, hasta aquí.
         */
        MouseArea {
            id: drag
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            height: Metrics.settingsUiHeadH * win.s
            cursorShape: drag.drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            drag.target: card; drag.threshold: 2
            drag.minimumX: win.leftInset; drag.maximumX: Math.max(win.leftInset, win.areaW - card.width - win.rightInset)
            drag.minimumY: win.topInset; drag.maximumY: Math.max(win.topInset, win.areaH - card.height - win.bottomInset)
            onPressed: win.focusContent()
            onReleased: SettingsUi.remember(win.name, card.x, card.y)
        }

        FocusScope {
            id: keys
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => { if (win.handle(event)) event.accepted = true; }

            Loader {
                id: body
                anchors.fill: parent
                active: win.shown || card.appear > 0.001 || win.keep
                onLoaded: { SettingsUi.builds++; SettingsUi.applyPending(); win.raise(); }
                sourceComponent: Surfaces.Settings {
                    floating: true
                    initialContext: SettingsUi.context
                    screenName: win.name; s: win.s; open: win.shown; closeness: 1; settled: true
                    // 2026-11-19: el límite de Length en este monitor y borde (core/Screen; surfaces/ no ve core/)
                    barLimit: win.hostScreen ? win.hostScreen.barLimitLength : 0
                    barAvail: win.hostScreen ? win.hostScreen.barEdgeLength : 0
                    onRequestClose: SettingsUi.close(false)
                    onRequestBack: SettingsUi.close(true)
                    // un enlace a una superficie del island: encima de la ventana, que se queda debajo
                    onRequestLink: (n, k) => win.followLink(n, k)
                }
            }
        }

        /** La pregunta, al pie de la tarjeta y por encima del contenido. */
        Rectangle {
            id: leaveBar
            z: 100
            visible: win.leaveTarget !== null
            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
            anchors.margins: 12 * win.s
            height: leaveCol.implicitHeight + 16 * win.s
            radius: Metrics.r(12) * win.s
            color: Theme.bgFor("settings", true)
            border.width: 1
            border.color: Qt.alpha(Theme.warn, 0.6)
            MouseArea { anchors.fill: parent }      // no atraviesa hacia las filas
            /** Fuera del FocusScope del contenido: el campo secreto pierde el teclado de verdad. */
            Item {
                id: leaveKeys
                Keys.onPressed: event => win.leaveKey(event)
            }
            Column {
                id: leaveCol
                anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 12 * win.s; anchors.rightMargin: 12 * win.s
                spacing: 8 * win.s
                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: win.leaveReason + " will be lost. Leave anyway?"
                    color: Theme.fg
                    font.family: Typography.ui
                    font.pixelSize: Typography.body * win.s
                }
                Row {
                    spacing: 8 * win.s
                    ActionButton { s: win.s; label: "Keep editing"; accent: true; focused: win.leaveChoice === 0; onTriggered: win.keepEditing() }
                    ActionButton { s: win.s; label: "Discard and leave"; danger: true; focused: win.leaveChoice === 1; onTriggered: win.discardAndLeave() }
                }
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
                win.focusContent();
            }
            onPositionChanged: mouse => {
                if (!grip.pressed) return;
                const p = mapToItem(null, mouse.x, mouse.y);
                const w = Math.max(win.minW, Math.min(win.areaW - card.x - win.rightInset, grip.start.width + p.x - grip.origin.x));
                const h = Math.max(win.minH, Math.min(win.areaH - card.y - win.bottomInset, grip.start.height + p.y - grip.origin.y));
                SettingsUi.size = { w: Math.round(w / win.s), h: Math.round(h / win.s) };
            }
            onReleased: SettingsUi.remember(win.name, card.x, card.y)
            Accessible.role: Accessible.Grip
            Accessible.name: "Resize settings"
            // dos trazos diagonales, sin Canvas (Cooperative parpadea: memoria del proyecto)
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
        // interferencia de terminal (2026-11-15): al abrir y al cambiar de vista; encima de todo (z), sin
        // recibir clics. Último hijo de la tarjeta: no corre los índices de los demás
        Interference { anchors.fill: parent; s: win.s; open: win.shown; key: "" }   // la página y la pestaña las avisa Settings desde dentro (Style.interfere): un enlace que las leía desde aquí ponía la GUI al 100 % (medido)
    }
}
