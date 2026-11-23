import QtQuick
import "../theme"
import "../services"

/**
 * Base of every morphing surface. The host sets `open`, `s` and `closeness`;
 * the surface sets its insets and its implicit size, and may override
 * `keyPressed(event)` to consume keys while it is open. `settled` latches
 * once the open morph has arrived so an internal relayout never dims it.
 */
Item {
    id: surface

    property real s: 1
    property bool open: false
    property real closeness: 1
    /**
     * El monitor de esta instancia (QS-FUNC-003). Hay un `SurfaceHost` por
     * `Screen`, asi que una reclamacion con nombre que no lo lleve dentro se
     * pisa con la del otro monitor: el primero que cierra suelta el escaner
     * del otro. Llega por binding: puede estar vacio mientras se construye.
     */
    property string screenName: ""

    property real mTop: 14
    property real mLeft: 18
    property real mRight: 18
    property real mBottom: 14

    /**
     * El `SurfaceHost` que la aloja (rediseño, fase 4): historial Back/Forward de ESTA
     * pantalla (`canBack`, `canForward`, `historyBack()`, `historyForward()`) para los
     * botones del marco (`components/FrameNav`). Lo pone el host; puede ser null.
     */
    property var host: null

    /**
     * Engaged (fase 4C; DESIGN §2): la abrieron un clic, un atajo o el teclado. `false`
     * mientras es una vista previa por hover: sin teclado, y sin efectos de «lo he
     * visto» (Notifications no marca como leído). Un clic dentro la fija.
     */
    property bool engaged: true

    /**
     * El contexto de la visita, para volver a ella con Back/Forward (DESIGN §3):
     * consulta, selección POR ID, scroll. Datos planos, nunca objetos QML, nunca
     * secretos ni comandos. `restoreContext` sólo devuelve la vista a ese estado:
     * NO ejecuta nada (volver nunca relanza una acción). Por defecto no hay contexto.
     */
    function saveContext() { return null; }
    function restoreContext(ctx) {}

    /**
     * **Guarded** (rediseño, fase 4; DESIGN §2): no vacío mientras la superficie tiene
     * algo que no debe perderse en silencio — hoy, un SECRETO SIN ENVIAR (contraseña de
     * wifi, de polkit, passphrase SSH). Salir por clic fuera, otro atajo, Close, Back o
     * IPC no cierra: el host pregunta «Keep editing / Discard and leave». Esc DENTRO del
     * campo sigue siendo un descarte explícito, como siempre.
     *
     * `discardGuarded()` borra el secreto (el búfer, no sólo lo que se ve);
     * `focusGuarded()` devuelve el foco al campo al elegir «Keep editing».
     */
    property string guardReason: ""
    function discardGuarded() {}
    function focusGuarded() {}

    /**
     * OPERACIÓN GLOBAL (fase 6D; DESIGN §4). La superficie que es el control de
     * una operación de `Operations` pone aquí su id. Abierta de forma EXPLÍCITA
     * (`engaged`: clic, atajo, teclado, IPC) en esta pantalla, reclama el control:
     * si lo llevaba otra, se traslada (misma operación, mismo plazo) y la vista
     * vieja se cierra sin cancelar. En vista previa por hover NO reclama: sólo
     * informa (`opElsewhere`, `opOwner`).
     */
    property string opId: ""
    readonly property var opRecord: { void Operations.ops; return Operations.get(surface.opId); }
    readonly property string opOwner: surface.opRecord ? surface.opRecord.owner : ""
    readonly property bool opLive: Operations.isLive(surface.opRecord)
    /** Hay una operación viva y la lleva otra pantalla. */
    readonly property bool opElsewhere: surface.opLive && surface.opOwner.length > 0
        && surface.opOwner !== surface.screenName
    readonly property bool opClaimWanted: surface.active && surface.engaged && surface.opLive
    onOpClaimWantedChanged: if (surface.opClaimWanted) Qt.callLater(surface.claimOp)
    function claimOp() {
        if (surface.opClaimWanted && surface.screenName.length > 0)
            Operations.claim(surface.opId, surface.screenName);
    }

    signal requestClose()
    /** Volver a donde se vino; decide la pila del host (QS-FUNC-004). */
    signal requestBack()

    readonly property bool active: open
    property bool settled: false
    // Coalesce binding changes: on close, geometry can settle before `open` propagates.
    // Reading both in the next event-loop turn prevents a stale "fully open" frame.
    onClosenessChanged: {
        if (surface.open) Qt.callLater(surface.revealContent);
        else if (surface.retracting) Qt.callLater(surface.retractContent);
    }

    onOpenChanged: {
        exitFade.stop();
        surface.retracting = false;
        if (surface.open) {
            Qt.callLater(surface.revealContent);
        } else {
            surface.settled = false;
            if (Motion.off) surface.revealOpacity = 0;
            else Qt.callLater(surface.beginExit);
        }
    }

    /**
     * CERRAR COMO SE ABRE (2026-10-28, pedido del usuario: «que se cierre la surface igual que como se
     * abra»). Hacia el reposo la salida no lleva reloj propio: sigue a la forma que se recoge, igual que
     * la entrada sigue a la que crece (`Motion.leave`, espejo de `enter`). Con el cajón (`SurfaceHost`
     * §frameFor) el contenido se queda a la vista mientras el borde lo devuelve bajo la barra, y se ha
     * ido antes de que vuelva la cara de reposo. Hacia OTRA superficie sigue el relevo corto (`vanish`):
     * la que llega empieza a verse a mitad de camino y las dos no deben cruzarse. Se decide un turno
     * después, cuando `host.open` y el destino de la forma ya son los nuevos.
     */
    property bool retracting: false
    function beginExit() {
        if (surface.open) return;
        if (surface.host && surface.host.open.length > 0) {
            exitFade.start();
        } else {
            surface.retracting = true;
            surface.retractContent();
        }
    }
    function retractContent() {
        if (surface.open || !surface.retracting) return;
        // un estilo de forma que pide su opacidad (2026-11-21, ADR-40): manda sobre el cajón y el relevo
        if (surface.host && surface.host.styleReveal >= 0) {
            surface.revealOpacity = Math.min(surface.revealOpacity, surface.host.styleReveal);
            return;
        }
        // el cajón de la barra (2026-11-19): se recoge entero bajo ella y se apaga al llegar
        if (surface.host && surface.host.drawer) {
            if (surface.closeness >= 0.999) surface.revealOpacity = 0;
            return;
        }
        surface.revealOpacity = Math.min(surface.revealOpacity, Motion.leave(surface.closeness));
    }
    // recogiéndose, otra superficie se abre: pasa al relevo corto desde la opacidad que tenga
    Connections {
        target: surface.host
        function onOpenChanged() {
            if (surface.retracting && surface.host.open.length > 0) {
                surface.retracting = false;
                exitFade.start();
            }
        }
        // la opacidad que pide el estilo de forma también mueve el contenido (como `closeness`)
        function onStyleRevealChanged() {
            if (surface.open) Qt.callLater(surface.revealContent);
            else if (surface.retracting) Qt.callLater(surface.retractContent);
        }
    }

    function keyPressed(event) {}

    anchors.fill: parent
    anchors.topMargin: mTop * s
    anchors.leftMargin: mLeft * s
    anchors.rightMargin: mRight * s
    anchors.bottomMargin: mBottom * s

    /**
     * A single displayed value survives reversals. Opening follows the actual geometry, and so does
     * closing to rest; closing toward another surface starts at the opacity already on screen.
     * Reopening stops the exit in place; a relayout cannot dim content already revealed.
     */
    property real revealOpacity: 0
    function revealContent() {
        if (!surface.open) return;
        if (surface.closeness > 0.92) surface.settled = true;
        // un estilo de forma que pide su opacidad (2026-11-21, ADR-40): la sigue hasta el final
        const styled = surface.host ? surface.host.styleReveal : -1;
        if (styled >= 0) {
            surface.revealOpacity = Math.max(surface.revealOpacity, styled);
            return;
        }
        // el cajón de la barra (2026-11-19): el panel sale ya visible, entero
        surface.revealOpacity = Math.max(surface.revealOpacity,
            surface.settled || (surface.host && surface.host.drawer) ? 1 : Motion.enter(surface.closeness));
    }
    NumberAnimation {
        id: exitFade
        target: surface
        property: "revealOpacity"
        to: 0
        duration: Motion.vanish
        easing.type: Easing.OutCubic
    }
    Component.onCompleted: Qt.callLater(surface.revealContent)

    enabled: open
    opacity: revealOpacity
    visible: open || opacity > 0.01
}
