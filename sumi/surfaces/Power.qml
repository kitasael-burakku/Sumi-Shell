pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../services"
import "../components"

/**
 * Session power (Fase 9.h, rediseñada a petición del usuario el 2026-09-09).
 *
 * Dos páginas, no dos superficies: la isla morphea de la fila de acciones a la
 * pregunta de confirmación y vuelve. Se hizo con **una sola superficie** porque
 * lo que se confirma es un estado efímero de la acción elegida, no una entidad
 * aparte como sí lo era una red en 9.f.2b: manteniéndolo local, el «qué estoy
 * confirmando» no puede desincronizarse ni sobrevivir a una descarga. El
 * efecto en pantalla es el mismo.
 *
 * ANCHO FIJO POR PÁGINA, no medido del contenido. Cada página declara el suyo y
 * el morph anima **entre dos constantes**. Si el ancho saliera del layout,
 * volveríamos al destino móvil que congeló el shell en 9.f.2: el texto se mide
 * contra el ancho, el ancho sale del texto.
 *
 * Reemplaza los tres caminos anteriores (wlogout, `power.sh`, `custom/power`) y
 * es **la única excepción a ADR-18** (ADR-21).
 */
Surface {
    id: root

    mTop: 12
    mLeft: 16
    mRight: 16
    mBottom: 12

    /** "pick" = la fila de acciones · "confirm" = la pregunta. */
    property string page: "pick"
    property string pending: ""
    /**
     * Rediseño, ARR-05 (futuresession-power §«errores»): un rechazo se dice junto a
     * las acciones — «Could not suspend: …» — en vez de perderse. Desde la 6C lo dice
     * `Power.ops` (antes, la señal `Power.actionFailed`, que nadie escuchaba).
     * Sobrevive a cerrar y reabrir dos minutos, porque Lock y Suspend cierran la
     * superficie antes de saber si salió bien.
     */
    /** La acción con el foco de teclado (la que haría Enter); para las pruebas. */
    readonly property string focusedAction: picks.currentId
    property string failNote: ""
    property real failAt: 0

    // 2026-11-12: la página de elegir crece hasta que quepa la fila de botones (Text size, familias anchas);
    // `picks.implicitWidth` es la suma natural de los botones, no depende del ancho del panel
    readonly property real targetW: root.page === "confirm" ? Metrics.powerConfirmW * root.s
        : Math.max(Metrics.powerW * root.s, Math.ceil(picks.implicitWidth) + (root.mLeft + root.mRight) * root.s)
    implicitHeight: root.page === "confirm" ? confirmCol.implicitHeight : pickCol.implicitHeight

    readonly property real innerW: root.targetW - (root.mLeft + root.mRight) * root.s

    onActiveChanged: {
        if (root.active) {
            root.page = "pick";
            root.pending = "";
            picks.reset();
            yesno.reset();
            if (Date.now() - root.failAt > 120000) root.failNote = "";
            Power.probeCapabilities();
        }
    }
    Component.onCompleted: if (root.active) Power.probeCapabilities()

    // ---- las acciones -------------------------------------------------------

    /** Cada acción usa un tinte de la paleta activa. */
    readonly property var actionList: [
        { id: "lock",      label: "Lock",      glyph: "lock",      glyphTint: Theme.tintPrimary },
        { id: "logout",    label: "Log out",   glyph: "logout",    glyphTint: Theme.tintSecondary },
        // Sin sondear no se sabe: desconocido NO es disponible (antes `|| !Power.probed`).
        // Los valores del singleton sobreviven entre aperturas, así que sólo la
        // primera apertura de la sesión lo ve apagado un instante.
        { id: "suspend",   label: "Suspend",   glyph: "suspend",   glyphTint: Theme.tintSecondarySoft,
          enabled: Power.suspendOk },
        { id: "reboot",    label: "Reboot",    glyph: "restart",   glyphTint: Theme.tintTertiary },
        { id: "shutdown",  label: "Shut down", glyph: "power",     glyphTint: Theme.tintDanger, danger: true },
        { id: "hibernate", label: "Hibernate", glyph: "hibernate", glyphTint: Theme.tintPrimarySoft,
          enabled: Power.hibernateOk }
    ]
    readonly property var pendingAction: root.actionList.find(action => action.id === root.pending)

    /** La confirmación de apagar y reiniciar lleva el estilo destructivo. */
    readonly property bool destructive: root.pending === "shutdown" || root.pending === "reboot"

    /** Lock y suspend no preguntan: son reversibles con la contraseña. */
    readonly property var needsAsk: ({ logout: true, reboot: true, shutdown: true, hibernate: true })

    readonly property var verbOf: ({ lock: "lock", logout: "log out", suspend: "suspend",
        reboot: "reboot", shutdown: "shut down", hibernate: "hibernate" })

    /** La ayuda de la acción con el foco de teclado (DESIGN §3: ayuda por foco). */
    function helpOf(id) {
        if (id === "lock") return "Lock the screen now";
        if (id === "logout") return "End the session · asks first";
        if (id === "suspend") {
            if (!Power.suspendOk) return Power.probed ? "Suspend: " + Power.suspendNote : "Checking whether suspend is available…";
            return Power.lockBeforeSleep ? "Sleep now · locks first" : "Sleep now";
        }
        if (id === "reboot") return "Restart the computer · asks first";
        if (id === "shutdown") return "Power off · asks first";
        if (id === "hibernate")
            return Power.hibernateOk ? "Save to disk and power off · asks first" : "Hibernate: " + Power.hibernateNote;
        return "";
    }

    /** 6C: el estado de la orden sale de `Power.ops`, el mismo modelo que Web, Clip o el perfil. */
    Connections {
        target: Power.ops
        function onSettled(key, rev, state, reason) {
            if (state !== "error") return;
            const action = String(Power.ops.get(key).requested);
            root.failNote = "Could not " + (root.verbOf[action] || action)
                + (reason.length > 0 ? ": " + reason.split("\n")[0] : "");
            root.failAt = Date.now();
            root.pending = "";
            root.page = "pick";
        }
    }

    function pick(id) {
        if (root.needsAsk[id] === true) {
            root.pending = id;
            root.page = "confirm";
            yesno.reset();
            // Se vuelve a mirar al pedirla: lo sondeado al abrir puede haber cambiado.
            Power.probeCapabilities();
            return;
        }
        root.fire(id);
    }

    /** Una orden a la vez: mientras `Power.busy`, otra pulsación no hace nada. */
    function fire(id) {
        if (Power.busy) return;
        root.failNote = "";
        if (id === "lock")      { Power.lock();      root.requestClose(); return; }
        if (id === "suspend")   { Power.suspend();   root.requestClose(); return; }
        if (id === "logout")    { Power.logout();    return; }
        if (id === "reboot")    { Power.reboot();    return; }
        if (id === "shutdown")  { Power.shutdown();  return; }
        if (id === "hibernate") {
            if (!Power.hibernate()) {
                root.failNote = "Could not hibernate: " + (Power.hibernateNote || "not available");
                root.failAt = Date.now();
                root.back();
            }
            return;
        }
    }

    /**
     * Historial (fase 4): Power no guarda nada A PROPÓSITO. Volver con Back siempre
     * enseña la fila de acciones, nunca una confirmación armada (DESIGN §2: «Confirmación
     * de Power: cancelar al salir, sin ejecutar ni restaurar la confirmación al volver»).
     */
    function saveContext() { return null; }

    function back() {
        root.pending = "";
        root.page = "pick";
        picks.reset();
    }

    /** Escape retrocede una página antes de cerrar: el mismo camino que la ficha de wifi. */
    function keyPressed(event) {
        if (event.key === Qt.Key_Escape) {
            if (root.page === "confirm") root.back();
            else root.requestClose();
            event.accepted = true;
            return;
        }
        const g = root.page === "confirm" ? yesno : picks;
        if (g.handleKey(event)) event.accepted = true;
    }

    // ---- página 1: elegir ---------------------------------------------------

    Column {
        id: pickCol
        anchors.top: parent.top
        anchors.left: parent.left
        width: root.innerW
        spacing: 10 * root.s
        visible: root.page === "pick"

        SurfaceHeader {
            width: parent.width
            s: root.s
            title: "POWER"
            FrameNav {
                s: root.s
                host: root.host
                onCloseRequested: root.requestClose()
            }
        }

        ActionGroup {
            tabMoves: true
            id: picks
            width: pickCol.width
            s: root.s
            orientation: "horizontal"
            stacked: true
            spacing: 4 * root.s
            actions: root.actionList
            // El hover sólo resalta; Enter sigue en el botón del teclado (DESIGN §3).
            hoverMovesFocus: false
            onTriggered: (id) => root.pick(id)
        }

        /**
         * Reserva su línea siempre: un aviso que aparece y desaparece movería la
         * fila justo antes de pulsar, que es el peor momento posible aquí.
         */
        Text {
            width: pickCol.width
            height: Typography.box(14, Typography.caption, root.s)
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: {
                if (root.failNote.length > 0) return root.failNote;
                if (!Power.probed) return "";
                const bits = [];
                if (!Power.suspendOk) bits.push("Suspend: " + Power.suspendNote);
                // QS-FUNC-021: el bloqueo previo depende del inhibidor de hypridle.
                else if (Power.inhibitorsProbed && !Power.lockBeforeSleep)
                    bits.push("Suspend: won't lock first (hypridle not holding sleep)");
                if (!Power.hibernateOk) bits.push("Hibernate: " + Power.hibernateNote);
                return bits.join("   ·   ");
            }
            color: root.failNote.length > 0 ? Theme.danger : Theme.outlineText
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }

        /** La ayuda de la acción con el foco, también en su línea reservada. */
        Text {
            width: pickCol.width
            height: Typography.box(14, Typography.caption, root.s)
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: root.helpOf(picks.currentId)
            color: Theme.fgVariant
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }
    }

    // ---- página 2: confirmar ------------------------------------------------

    Column {
        id: confirmCol
        anchors.top: parent.top
        anchors.left: parent.left
        width: root.innerW
        spacing: 14 * root.s
        visible: root.page === "confirm"

        /** La pregunta va **centrada**: es lo único que hay que leer aquí. */
        Item {
            width: confirmCol.width
            height: 34 * root.s

            Row {
                anchors.centerIn: parent
                spacing: 11 * root.s

                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: root.pendingAction ? root.pendingAction.glyph : ""
                    size: 22 * root.s
                    color: root.pendingAction ? root.pendingAction.glyphTint : Theme.tintNeutral
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.pendingAction ? root.pendingAction.label + "?" : ""
                    color: Theme.fg
                    font.family: Typography.ui
                    font.pixelSize: Typography.display * root.s
                    font.weight: Font.DemiBold
                }
            }
        }

        ActionGroup {
            tabMoves: true
            id: yesno
            width: confirmCol.width
            s: root.s
            orientation: "horizontal"
            spacing: 10 * root.s
            /**
             * Ni `primary` ni fondo permanente: **el texto dice qué hace cada
             * botón y el fondo dice cuál está enfocado**. Con los dos pintados
             * a la vez no se distinguía cuál responde al Enter.
             */
            hoverMovesFocus: false
            actions: [
                { id: "no",  label: "No",  accent: !root.destructive },
                { id: "yes", label: "Yes", accent: !root.destructive,
                  danger: root.destructive }
            ]
            onTriggered: (id) => {
                if (id === "yes") root.fire(root.pending);
                else root.back();
            }
        }
    }
}
