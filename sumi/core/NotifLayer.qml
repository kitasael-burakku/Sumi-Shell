pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import "../theme"
import "../services"
import "../components"
import "../lib/window-open.js" as WinOpen

/**
 * Los popups de notificacion de un monitor (ADR-29, Fase 1): 360 px, de serie
 * abajo a la derecha, donde los tenia SwayNC (NOTIFICACIONES §7 y §8). Desde
 * el 2026-11-19 la esquina y el margen se eligen (Settings → Notifications:
 * `notifPosition`, `notifMargin`): cuatro esquinas y abajo al centro.
 *
 * Ventana propia y no el overlay del island: la mascara de aquel esta hecha
 * para el island y sus estados modales, y los popups no deben pedir teclado
 * (`keyboardFocus: None`) ni tapar clics fuera de las tarjetas (`mask`). La
 * ventana ocupa la columna derecha entera, transparente; lo que recibe raton
 * es solo la pila.
 *
 * Solo en el monitor enfocado, como el OSD: una notificacion es un aviso
 * global, no de una pantalla.
 *
 * El mas nuevo junto al borde (`insert(0)` + `BottomToTop`, o `TopToBottom`
 * arriba): los anteriores se alejan con una transicion en vez de saltar.
 */
PanelWindow {
    id: layer

    required property var targetScreen

    readonly property real s: Settings.uiScale
    readonly property bool onFocusedMonitor: Hypr.focusedName.length === 0
        || Hypr.focusedName === String(layer.targetScreen ? layer.targetScreen.name : "")
    readonly property bool hasPopups: Notifs.popups.count > 0
    /** Aire alrededor de la pila para que la sombra de las tarjetas no se corte en el borde de la ventana. */
    readonly property real shadowPad: 12 * layer.s

    // Dónde (2026-11-19). Un valor desconocido cae en la esquina de serie.
    readonly property string pos: ["top-left", "top-right", "bottom-left", "bottom-center", "bottom-right"]
        .indexOf(Settings.notifPosition) >= 0 ? Settings.notifPosition : "bottom-right"
    readonly property bool atTop: layer.pos.startsWith("top")
    readonly property bool atLeft: layer.pos.endsWith("left")
    readonly property bool atCenter: layer.pos.endsWith("center")
    readonly property real margin: Math.max(8, Math.min(64, Settings.notifMargin)) * layer.s
    /**
     * Arriba, por debajo de la franja de la barra o la isla de este monitor. Con «Reserve space» ya la reserva el
     * compositor (zona exclusiva de `sumi-shell-reserve`, y esta capa es `ExclusionMode.Normal`); sin ella, la barra
     * se dibuja sobre las ventanas y hay que bajar a mano lo mismo: la cuenta de `overlay.reservedH` en core/Screen
     * (repetida aquí para no tocar Screen.qml).
     */
    readonly property var host: Screens.byName(String(layer.targetScreen ? layer.targetScreen.name : ""))
    readonly property real topInset: !layer.atTop || Settings.reserveSpace || !layer.host
            || (layer.host.reserveEdge || "top") !== "top" ? 0
        : layer.host.barMode
            ? (layer.host.barDock ? Metrics.reservedBarDockH(layer.host.s) : Metrics.reservedBarH(layer.host.s))
            : (layer.host.dockMode ? Metrics.reservedDockH(layer.host.s) : Metrics.reservedH(layer.host.s))
    /**
     * 2026-11-19: con la barra en otro borde, lo mismo en ESE lado (abajo, a la izquierda o a la derecha), si la pila
     * está pegada a él; arriba queda sólo el margen. «Reserve space» ya lo resuelve el compositor.
     */
    function sideInset(side) {
        if (Settings.reserveSpace || !layer.host || typeof layer.host.barInset !== "function") return 0;
        if (side === "bottom" && layer.atTop) return 0;
        if (side === "left" && !layer.atLeft) return 0;
        if (side === "right" && (layer.atLeft || layer.atCenter)) return 0;
        return layer.host.barInset(side);
    }
    readonly property real bottomInset: layer.sideInset("bottom")
    readonly property real leftInset: layer.sideInset("left")
    readonly property real rightInset: layer.sideInset("right")

    screen: layer.targetScreen
    /** ISLAND.md §3.2 / §7: nada del shell se ve con la sesión bloqueada. */
    visible: layer.onFocusedMonitor && layer.held && !Lock.engaged
    color: "transparent"
    exclusionMode: ExclusionMode.Normal
    exclusiveZone: 0
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "sumi-notifications"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    // la columna entera del lado elegido; al centro, sin ancla lateral (el compositor la centra)
    anchors { top: true; bottom: true; left: layer.atLeft; right: !layer.atLeft && !layer.atCenter }
    margins {
        top: layer.topInset + layer.margin - layer.shadowPad
        left: layer.leftInset + layer.margin - layer.shadowPad
        right: layer.rightInset + layer.margin - layer.shadowPad
        bottom: layer.bottomInset + layer.margin - layer.shadowPad
    }
    implicitWidth: Metrics.notifW * layer.s + 2 * layer.shadowPad

    /**
     * La animacion de salida de la ultima tarjeta necesita la ventana viva un momento. `held` es un valor y no
     * `hasPopups || linger.running` (2026-11-19, medido en banco): con aquel enlace, `visible` caía en cuanto
     * `hasPopups` pasaba a falso, antes de que este manejador arrancara `linger`; la capa se ocultaba y la última
     * tarjeta desaparecía de golpe.
     */
    property bool held: false
    Component.onCompleted: layer.held = layer.hasPopups
    onHasPopupsChanged: {
        if (layer.hasPopups) { linger.stop(); layer.held = true; }
        else linger.restart();
    }
    Timer { id: linger; interval: list.closeMs + 80; onTriggered: layer.held = layer.hasPopups }

    mask: Region { item: list }

    ListView {
        id: list
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: layer.shadowPad
        anchors.rightMargin: layer.shadowPad
        // Arriba o abajo con `y`, sin anclas verticales (2026-11-19, medido en banco): al pasar de anclar `bottom` a
        // anclar `top` hubo un instante con las dos, Qt fijó la altura con la ventana aún a 0 (−24 px) y rompió el
        // enlace de `height`; la pila se quedaba invisible hasta recargar.
        y: layer.atTop ? layer.shadowPad : parent.height - layer.shadowPad - height
        height: Math.max(0, Math.min(contentHeight, parent.height - 2 * layer.shadowPad))
        interactive: false
        verticalLayoutDirection: layer.atTop ? ListView.TopToBottom : ListView.BottomToTop
        spacing: 10 * layer.s
        model: Notifs.popups

        /**
         * Entrada y salida con el Window style (2026-11-19, ADR-36; Settings → Animations → Window style):
         *  - Minimalist y Expressive (los de muelle) conservan lo de siempre: la tarjeta llega desde el borde y se
         *    va hacia él. Es lo que eligió el autor: «llega de la esquina» es lo propio del aviso.
         *  - Power-on, Bloom, Mochi, Ink, Scroll y Mist abren la tarjeta en su sitio con las mismas curvas que las
         *    ventanas flotantes (lib/window-open.js, theme/RevealEffect): sólo avanza `value` del hueco, lineal en
         *    el tiempo, y la tarjeta dibuja la forma. Como en las ventanas, valen con Normal y Reduced; Off es
         *    inmediato.
         * Entrada y salida: `enterAnim` y `exitAnim` de cada hueco (la lista no tiene `add` ni `remove`). El estilo se
         * lee al añadir o quitar cada tarjeta: cambiarlo con popups en pantalla no las mueve.
         */
        readonly property string style: Motion.windowStyles[Motion.windowStyle] ? Motion.windowStyle : "minimalist"
        readonly property var params: Motion.windowParams(list.style)
        readonly property bool timeline: list.params.timeline === true && !Motion.off
        readonly property int openMs: list.timeline ? Motion.styleMs(list.params.openMs) : Motion.standard
        readonly property int closeMs: list.timeline ? Motion.styleMs(list.params.closeMs) : Motion.exit

        // `notif` y `gen` las rellena el modelo por nombre de rol. El hueco es lo que se anima (x, y, opacidad o
        // `value`); la tarjeta, dentro, sólo dibuja la forma de la línea de tiempo.
        delegate: Item {
            id: slot
            required property var notif
            required property int gen
            width: ListView.view ? ListView.view.width : 0
            height: pop.height

            // Lo que lee RevealEffect (`rv.name`, `rv.value`) y lo que necesita Mochi (`opening`, `snap`).
            // `value` es un valor, no un enlace (theme/Reveal, destello de Power-on): 1 si nada lo anima.
            readonly property string name: list.style
            // la escala, aquí y no `layer.s` en el Component de abajo: dentro de RevealEffect `layer` es su propia
            // propiedad de capa (Item.layer), no esta ventana (aviso «Unable to assign [undefined]» en banco)
            readonly property real s: layer.s
            property real value: 1
            property bool opening: true
            property var snap: null
            readonly property bool timeline: list.timeline
            readonly property bool effect: slot.timeline && WinOpen.needsEffect(slot.name)
            readonly property var tl: slot.timeline
                ? WinOpen.shape(slot.name, slot.value, slot.s, slot.opening, slot.snap, Motion.still) : null

            /**
             * La entrada la lleva el hueco y no la transición `add` de la lista (2026-11-19, medido en banco, también
             * antes de este cambio y con una `add` de 2 s): el primer popup es el que muestra la ventana, y ListView no
             * ejecuta `add` para lo que llega con ella oculta; la tarjeta salía entera, de golpe. Arranca al crearse.
             * Cada familia anima lo suyo y la otra parte ya está en su sitio (duración 0); con Off, todo es 0.
             */
            ParallelAnimation {
                id: enterAnim
                NumberAnimation {
                    target: slot; property: "value"; from: 0; to: 1; easing.type: Easing.Linear
                    duration: slot.timeline ? list.openMs : 0
                }
                NumberAnimation {
                    target: slot; property: "opacity"; from: slot.timeline ? 1 : 0; to: 1; easing.type: Motion.easeStandard
                    duration: slot.timeline ? 0 : Motion.standard
                }
                NumberAnimation {
                    target: slot; property: "off"; from: slot.timeline ? 0 : 1; to: 0; easing.type: Motion.easeStandard
                    duration: slot.timeline ? 0 : Motion.standard
                }
            }
            Component.onCompleted: enterAnim.start()
            // otra posición con la tarjeta en pantalla: la ventana ya se movió; vuelve a entrar desde su borde nuevo
            readonly property string place: layer.pos
            onPlaceChanged: if (!slot.leaving) enterAnim.restart()

            // Minimalist y Expressive: desplazamiento hacia el borde más cercano (0 = en su sitio, 1 = fuera)
            property real off: 0
            transform: Translate { x: slot.off * list.slideX; y: slot.off * list.slideY }

            /**
             * La salida también la lleva el hueco (2026-11-19, medido en banco: antes la tarjeta desaparecía de golpe,
             * con cualquier ajuste). Dos causas:
             *  - El popup se retira con `Qt.callLater` cuando el aviso ya salió del modelo del servidor
             *    (services/Notifs): para entonces el objeto estaba destruido y la tarjeta se quedaba vacía (40 px).
             *    `keep` lo retiene (Notification es Retainable) hasta que se destruye el hueco.
             *  - La lista mide lo que su contenido: al quitar la fila encogía en el acto y soltaba el hueco, ya fuera
             *    de la vista, sin transición. `delayRemove` lo deja en su sitio mientras sale; luego las demás se
             *    desplazan (`displaced`).
             */
            RetainableLock { id: keep; object: slot.notif; locked: true }
            property bool leaving: false
            SequentialAnimation {
                id: exitAnim
                ParallelAnimation {
                    NumberAnimation {
                        target: slot; property: "value"; to: 0; easing.type: Easing.Linear
                        duration: slot.timeline ? list.closeMs : 0
                    }
                    NumberAnimation {
                        target: slot; property: "opacity"; to: slot.timeline ? 1 : 0; easing.type: Easing.InCubic
                        duration: slot.timeline ? 0 : Motion.exit
                    }
                    NumberAnimation {
                        target: slot; property: "off"; to: slot.timeline ? 0 : 1; easing.type: Easing.InCubic
                        duration: slot.timeline ? 0 : Motion.exit
                    }
                }
                PropertyAction { target: slot; property: "ListView.delayRemove"; value: false }
            }
            ListView.onRemove: {
                slot.ListView.delayRemove = true;
                slot.leaving = true;
                enterAnim.stop();
                // cerrar parte de lo que se ve (Mochi, si aún se estaba abriendo)
                if (slot.tl && slot.name === "mochi" && slot.value < 0.999)
                    slot.snap = { sx: slot.tl.sx, sy: slot.tl.sy, opacity: slot.tl.opacity, v0: slot.value };
                slot.opening = false;
                exitAnim.start();
            }

            NotifCard {
                id: pop
                notif: slot.notif
                gen: slot.gen
                width: slot.width
                s: slot.s
                mode: "popup"
                // el aviso ya está cerrado mientras sale: sin clics sobre él
                enabled: !slot.leaving

                opacity: slot.tl ? slot.tl.opacity : 1
                scale: slot.tl ? slot.tl.scale : 1
                transformOrigin: Item.Center
                transform: [
                    Translate { y: slot.tl ? slot.tl.dy : 0 },
                    Scale {
                        origin.x: pop.width / 2; origin.y: pop.height / 2
                        xScale: slot.tl ? slot.tl.sx : 1; yScale: slot.tl ? slot.tl.sy : 1
                    }
                ]
                // en capa sólo mientras abre o cierra; Bloom, Ink, Scroll y Mist dibujan encima (ADR-36)
                layer.enabled: slot.timeline && slot.value > 0.001 && slot.value < 0.999
                layer.effect: slot.effect ? popFx : null

                // Lo que antes hacía la tarjeta por su cuenta (fase 7A: ahora sólo pinta y avisa).
                onActivated: (link) => {
                    if (!pop.notif) return;
                    if (link.length > 0) Notifs.openLink(link);
                    else Notifs.activate(pop.notif);
                }
                onDismissed: Notifs.dismiss(pop.notif)
                onActionInvoked: (identifier) => Notifs.invokeAction(pop.notif, identifier)
                // Responder pide teclado y el popup no lo tiene (a propósito): abre el centro.
                onReplyClicked: Notifs.requestReply(pop.notif)
            }
            Component { id: popFx; RevealEffect { rv: slot; s: slot.s } }
        }

        /**
         * Con reduce motion la tarjeta no viaja: `slide` vale 0 y sólo queda el
         * fundido. Es la misma regla que en todo el shell — se apaga el
         * desplazamiento, no el cambio (`theme/Motion`).
         */
        readonly property real slide: Motion.still ? 0 : 48 * layer.s
        // hacia el borde más cercano (2026-11-19): los lados en horizontal; abajo al centro, hacia abajo
        readonly property real slideX: layer.atCenter ? 0 : (layer.atLeft ? -list.slide : list.slide)
        readonly property real slideY: layer.atCenter ? list.slide : 0

        // la entrada y la salida las lleva cada hueco (`enterAnim`, `exitAnim`); aquí sólo el desplazamiento de las demás
        displaced: Transition {
            NumberAnimation { property: "y"; duration: Motion.standard; easing.type: Motion.easeStandard }
        }
    }
}
