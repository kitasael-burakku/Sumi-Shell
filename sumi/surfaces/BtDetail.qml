pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../services"
import "../components"
import "../lib/accent-zones.js" as Zones

/**
 * Ficha de un dispositivo bluetooth (Fase 9.f.3).
 *
 * La isla salta aqui desde la lista al elegir un aparato, igual que
 * `WifiDetail`. Es superficie de verdad y no un panel que crece, por la misma
 * razon: asi el morph tiene destino fijo y la lista no cambia de tamano debajo
 * del usuario. Y es superficie y no *pagina* (como si lo son las dos de
 * `Power`) porque un aparato es una ENTIDAD, no un estado efimero de la
 * accion elegida.
 *
 * ANCLAJES Y ALTURA POR CONTENIDO medida contra un ancho CONSTANTE (`innerW`,
 * nunca `width`, que es el que anima). Es lo que evita reabrir el bucle de
 * layout de 9.f.2.
 *
 * AQUI VIVE EL RIESGO DE LA SUB-FASE. Quickshell no registra agente de
 * emparejamiento -- el binario no referencia `org.bluez.AgentManager1` y la
 * documentacion oficial no menciona `agent`, `PIN`, `passkey` ni confirmacion
 * en ninguna de sus paginas (comprobado el 2026-09-09). `pair()` deberia
 * bastar para lo que empareja sin interaccion; un aparato que pida PIN no
 * tendra quien le conteste. Por eso la ficha **dice lo que pasa y nombra la
 * salida** en vez de quedarse girando: un fallo silencioso seria peor que no
 * tener la superficie. (La salida era SUPER+F7, rofi, ADR-18; se retiro en la
 * Fase 10.e, y no bondeaba: hacia `bluetoothctl pair` suelto. Para un aparato
 * que pida PIN, lo que funciona es `bluetoothctl` interactivo en una terminal.)
 */
Surface {
    id: root
    /**
     * Fase 3D (ADR-42): Bluetooth en su familia de color en todas partes (`lib/accent-zones.js`: secondary), como su
     * tarjeta del Control Center; antes este panel lo pintaba con primary a mano.
     */
    palette.accent: Theme.zone(Zones.of("bluetooth"))
    readonly property var acc: Theme.fam(palette.accent)

    mTop: 12
    mLeft: 14
    mRight: 14
    mBottom: 12

    signal requestSurface(string name)
    property bool keyNav: false
    readonly property bool splitLayout: root.innerW >= 620 * root.s

    /**
     * El aparato que mira ESTA pantalla (core/SurfaceHost §`sel`); antes salia
     * de `Bt.detailObj`, compartido entre monitores. La FASE de una operacion
     * (emparejar, conectar) sigue siendo global y keyed por direccion, que es
     * lo correcto: la operacion es una sola aunque se mire desde dos sitios.
     */
    property string sel: ""
    readonly property string addr: root.sel

    /** Mismo motivo que en `WifiDetail`: se sostiene el objeto, uno por ficha. */
    property var devObj: null
    readonly property var dev: root.devObj
    function resolve() {
        // The derived addr may still be the previous one inside onSelChanged.
        const d = Bt.byAddress(root.sel);
        if (d)
            root.devObj = d;
    }
    onSelChanged: { root.devObj = null; root.resolve(); root.keyNav = false; if (acts) acts.reset(); }
    Connections {
        target: Bt
        function onDevicesChanged() { root.resolve(); }
    }
    readonly property bool anon: root.dev !== null && Bt.isAnonymous(root.dev)
    readonly property string title: root.dev === null ? "—" : Bt.labelOf(root.dev)
    /** El alias del usuario, si dice algo distinto del nombre del aparato. */
    readonly property string alias_: root.dev === null ? "" : Bt.aliasOf(root.dev)

    readonly property bool connected: root.dev !== null && root.dev.connected
    readonly property bool paired: root.dev !== null && root.dev.paired
    readonly property bool bonded: root.dev !== null && root.dev.bonded
    readonly property bool trusted: root.dev !== null && root.dev.trusted
    readonly property bool devBlocked: root.dev !== null && root.dev.blocked
    readonly property bool pairing: root.dev !== null && root.dev.pairing
    readonly property int batt: Bt.batteryOf(root.dev)

    /** La fase solo cuenta si habla de ESTE aparato. */
    readonly property string phase: (root.addr.length > 0 && Bt.phaseAddr === root.addr)
        ? Bt.phase : "idle"
    readonly property bool busy: root.phase === "busy"
    readonly property string phaseKind: root.busy ? Bt.phaseKind : ""

    /**
     * La ficha mantiene viva la busqueda mientras se mira un aparato NO
     * emparejado: si la soltara, bluez podria perderlo justo cuando se va a
     * pulsar "Pair". Con uno ya emparejado no hace falta y no se paga.
     *
     * La clave lleva el monitor y no se reclama mientras este vacio: mismo
     * razonamiento que en `Wifi.qml` (QS-FUNC-003).
     */
    readonly property string scanKey: root.screenName.length > 0 ? "btDetail@" + root.screenName : ""
    Claim {
        target: Bt; method: "claimScan"; key: root.scanKey
        value: root.active && root.dev !== null && !root.paired
    }

    onActiveChanged: if (root.active) { acts.reset(); root.keyNav = false; if (detailView) detailView.contentY = 0; }

    /**
     * LAS ACCIONES SON DATOS. `ActionGroup` las dibuja, las mide y las navega;
     * si una desaparece, el layout se recoloca y el foco se re-acota solo.
     * Se escribio generico justo para esta pantalla y aqui se usa sin tocarlo.
     */
    readonly property var actionList: [
        /**
         * LA PREGUNTA DEL AGENTE (2026-09-22). Mientras BlueZ espera respuesta,
         * las dos primeras acciones son contestarla: el codigo se ensena arriba
         * en el aviso y aqui se confirma o se rechaza. Antes esa pregunta se
         * perdia y el emparejamiento moria de `AuthenticationTimeout` a los
         * ~40 s con el prompt crudo de `bluetoothctl` en la tarjeta.
         */
        {
            id: "confirmPair",
            glyph: "check",
            label: Bt.askCode.length > 0 ? "Yes, the codes match" : "Yes, pair",
            primary: false,
            visible: Bt.asking
        },
        {
            id: "rejectPair",
            glyph: "close",
            label: "No",
            danger: true,
            visible: Bt.asking
        },
        {
            id: "primary",
            glyph: root.connected ? "bt-off" : "bt",
            label: root.busy
                    ? (root.phaseKind === "pair" ? "Pairing…"
                       : root.phaseKind === "disconnect" ? "Disconnecting…" : "Connecting…")
                 : root.connected ? "Disconnect"
                 : root.paired ? "Connect"
                 : "Pair and connect",
            primary: false,
            visible: !Bt.asking,
            enabled: !root.busy && !root.devBlocked && root.dev !== null,
            /** Sin bond, desconectar equivale a desemparejar: se pregunta. */
            confirm: root.connected && root.paired && !root.bonded
        },
        {
            id: "cancel",
            glyph: "close",
            label: "Cancel pairing",
            visible: root.busy && root.phaseKind === "pair"
        },
        {
            id: "trust",
            glyph: root.trusted ? "lock" : "check-circle",
            label: root.trusted ? "Stop trusting" : "Trust this device",
            visible: root.paired && !root.busy
        },
        {
            id: "forget",
            glyph: "delete",
            label: "Forget device",
            visible: (root.paired || root.bonded) && !root.busy,
            danger: true,
            confirm: true
        },
        {
            id: "block",
            glyph: root.devBlocked ? "check-circle" : "x-circle",
            label: root.devBlocked ? "Unblock" : "Block",
            visible: root.dev !== null && !root.busy,
            danger: !root.devBlocked,
            confirm: !root.devBlocked
        }
    ]

    readonly property string stateLabel: {
        if (root.busy) return root.phaseKind === "pair" ? "pairing…" : "connecting…";
        if (root.phase === "timeout") return "no answer";
        if (root.phase === "failed") return "failed";
        if (root.devBlocked) return "blocked";
        if (root.connected) return "connected";
        if (root.paired) return "paired";
        return "not paired";
    }

    readonly property color stateColor: (root.phase === "failed" || root.phase === "timeout"
                                         || root.devBlocked) ? Theme.errorColor
        : root.connected ? root.acc.accent : Theme.outline

    readonly property bool messageIsError:
        // La pregunta no es un error: es una pregunta. Se pinta en tono normal
        // aunque la fase siga en `busy`.
        !Bt.asking
        && (acts.confirming.length > 0 || root.phase === "failed" || root.phase === "timeout")

    readonly property string message: {
        // El aviso nombra las DOS vias. Decir solo "⏎ confirma" hacia que con
        // el raton el primer clic pareciera no hacer nada (reportado en 9.f.2b).
        if (acts.confirming === "primary")
            return "Disconnect?  You may need to pair again.  ⏎ or click again.";
        if (acts.confirming === "forget") return "Forget this device?  ⏎ or click again.";
        if (acts.confirming === "block")  return "Block this device?  ⏎ or click again.";
        // La pregunta del agente va primero: es lo unico que el emparejamiento
        // esta esperando, y es de la persona, no de la radio.
        if (Bt.asking) {
            return Bt.askCode.length > 0
                ? "Pairing code  " + Bt.askCode + "  —  " + Bt.askText
                : Bt.askText;
        }
        if (root.busy && root.phaseKind === "pair")
            return "Waiting for the device.  Keep it in pairing mode.";
        /**
         * EL MENSAJE DEL RIESGO. Sin agente de emparejamiento no hay quien
         * conteste un PIN, asi que cuando `pair()` se cae hay que nombrar la
         * salida en vez de dejar al usuario adivinando.
         */
        if (root.phase === "failed" && Bt.failNote.length > 0) return Bt.failNote + ".";   // 6C-2
        if (root.phase === "failed" && Bt.phaseKind === "pair")
            return Bt.pairFail.length > 0
                ? "Pairing failed — " + Bt.pairFail
                : "Pairing failed.  Is the device still in pairing mode?";
        if (root.phase === "failed") return "The device did not answer the request.";
        if (root.phase === "timeout") return "Timed out.  The device may be out of range.";
        if (root.devBlocked) return "Blocked: the adapter will ignore this device.";
        /**
         * PAIRED SIN BONDED, y la causa esta MEDIDA (2026-09-09, mando de PS5).
         * No es cosa del aparato: emparejado desde el shell da `Bonded: false`
         * y el emparejamiento se evapora al desconectar; el MISMO mando
         * emparejado con `bluetoothctl` -- que si registra agente -- da
         * `Bonded: true` y sobrevive. Es la falta de agente
         * (`org.bluez.AgentManager1`). Desde 9.f.3 el propio shell empareja con
         * una sesion interactiva (`agent on` + `default-agent`, services/Bt), asi
         * que el remedio esta en esta misma ficha: olvidarlo y emparejarlo otra
         * vez desde aqui. (Hasta 10.e el mensaje mandaba a SUPER+F7, rofi — que
         * hacia `bluetoothctl pair` suelto y tampoco bondeaba.)
         */
        if (root.paired && !root.bonded)
            return "No key stored: it won't survive a disconnect.  Forget it and pair again here.";
        if (!root.paired) return "Not paired yet.  Pair to use it.";
        return "";
    }

    /** Volver a donde se vino (la pila del host). Escape sale de dentro hacia fuera. */
    function back() { root.requestBack(); }

    function run(id) {
        if (root.dev === null) return;
        if (id === "primary") {
            if (root.connected) Bt.disconnectFrom(root.addr);
            else if (root.paired) Bt.connectTo(root.addr);
            else Bt.pairWith(root.addr);
            return;
        }
        if (id === "confirmPair") { Bt.answerPair(true); return; }
        if (id === "rejectPair")  { Bt.answerPair(false); return; }
        if (id === "cancel") { Bt.cancelPairWith(root.addr); return; }
        if (id === "trust")  { Bt.setTrusted(root.addr, !root.trusted); return; }
        if (id === "forget") { Bt.forgetDevice(root.addr); root.back(); return; }
        if (id === "block")  { Bt.setBlocked(root.addr, !root.devBlocked); return; }
    }

    function keyPressed(event) {
        if (event.key === Qt.Key_Escape) { root.back(); event.accepted = true; return; }
        const back = event.key === Qt.Key_Up || event.key === Qt.Key_Backtab
            || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier));
        const forward = event.key === Qt.Key_Down || event.key === Qt.Key_Tab;
        if (!root.keyNav && (back || forward)) {
            root.keyNav = true;
            acts.current = back ? Math.max(0, acts.count - 1) : 0;
            Qt.callLater(()=>root.revealItem(acts));
            event.accepted = true; return;
        }
        if (back || forward || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.keyNav = true;
        if (acts.handleKey(event)) event.accepted = true;
    }

    readonly property real frameW: Math.min(Metrics.radioDetailW * root.s, root.host ? root.host.maxW : 1e9)
    readonly property real innerW: frameW - (root.mLeft + root.mRight) * root.s

    implicitHeight: col.implicitHeight

    /** Una fila de la ficha: etiqueta a la izquierda, valor a la derecha. */
    /** La fila de ficha común (`components/FactRow`, fase 3B, ADR-42). */
    component Fact: FactRow { s: root.s }

    function revealItem(item) {
        if (!root.open || !item) return;
        const p=item.mapToItem(col,0,0);
        if (p.y < detailView.contentY) detailView.contentY=Math.max(0,p.y);
        else if(p.y+item.height>detailView.contentY+detailView.height)
            detailView.contentY=Math.min(Math.max(0,detailView.contentHeight-detailView.height),p.y+item.height-detailView.height);
    }
    Connections {
        target:acts
        function onCurrentChanged() { Qt.callLater(()=>root.revealItem(acts)); }
        function onConfirmingChanged() { Qt.callLater(()=>root.revealItem(acts)); }
    }
    Flickable {
        id:detailView
        anchors.fill:parent; contentWidth:width; contentHeight:col.implicitHeight
        clip:true; boundsBehavior:Flickable.StopAtBounds
        interactive:contentHeight>height+1
    Column {
        id: col
        width: root.innerW
        spacing: 12 * root.s

        // ---- cabecera ------------------------------------------------------

        Item {
            width: col.width
            height: Math.max(56 * root.s, detailTitle.implicitHeight + stateTag.implicitHeight + 8 * root.s)

            Icon {
                id: backIcon
                anchors.left: parent.left
                anchors.top:parent.top; anchors.topMargin:5 * root.s
                name: "chevron-left"
                size: 14 * root.s
                color: backArea.containsMouse ? Theme.fg : Theme.fgVariant
                Behavior on color { ColorAnimation { duration: Motion.fast } }

                MouseArea {
                    id: backArea
                    Accessible.role: Accessible.Button
                    Accessible.name: "Back"
                    Accessible.onPressAction: root.back()
                    anchors.fill: parent
                    anchors.margins: -6 * root.s
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.back()
                }
            }

            Text {
                id:detailTitle
                anchors.left: backIcon.right
                anchors.leftMargin: 8 * root.s
                anchors.right: parent.right
                anchors.rightMargin: 8 * root.s
                anchors.top:parent.top
                text: root.title
                wrapMode:Text.Wrap; maximumLineCount:2; elide: Text.ElideRight
                color: Theme.fg
                font.family: Typography.ui
                font.pixelSize: Typography.title * root.s
                font.weight: Font.DemiBold
            }

            Text {
                id: stateTag
                anchors.left:detailTitle.left; anchors.right:parent.right
                anchors.top:detailTitle.bottom; anchors.topMargin:5 * root.s
                text: root.stateLabel
                color: root.stateColor
                font.family: Typography.ui
                font.pixelSize: Typography.label * root.s
            }
        }

        Item {
            id:detailBody
            width:col.width
            implicitHeight:root.splitLayout ? Math.max(infoColumn.implicitHeight, actionPanel.height)
                : infoColumn.implicitHeight + 16 * root.s + actionPanel.height
            height:implicitHeight
            Column {
                id:infoColumn
                objectName:"radio-info"
                width:root.splitLayout ? Math.floor((detailBody.width - 20 * root.s) * 0.57) : detailBody.width
                spacing:12 * root.s
        // ---- clase y bateria -------------------------------------------------

        Row {
            x: 22 * root.s
            spacing: 10 * root.s

            Row {
                spacing: 4 * root.s
                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: Bt.deviceGlyph(root.dev)
                    size: 12 * root.s
                    color: root.connected ? root.acc.accent : Theme.fgVariant
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    /**
                     * `icon` es un nombre de icono del sistema y llega VACIO la
                     * mayoria de las veces (medido: 6 de 8). Cuando no hay, se
                     * dice "unknown type" en vez de un hueco.
                     */
                    text: (root.dev && String(root.dev.icon).length > 0)
                            ? String(root.dev.icon) : "unknown type"
                    color: Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                }
            }

            /** W5/W6: bateria por dispositivo, y el umbral literal del original. */
            Row {
                spacing: 4 * root.s
                visible: root.batt >= 0
                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: root.batt <= 20 ? "battery-alert" : "battery"
                    size: 11 * root.s
                    color: root.batt <= 20 ? Theme.errorColor : Theme.outline
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.batt + " %"
                    color: root.batt <= 20 ? Theme.errorColor : Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                    font.features: ({ "tnum": 1 })
                }
            }
        }

        // ---- ficha -----------------------------------------------------------

        Rectangle {
            width:infoColumn.width; height:factRows.implicitHeight+16 * root.s
            radius:Metrics.rMd * root.s; color:Theme.tileBg
        Column {
            id:factRows
            x:10 * root.s; y:8 * root.s; width:parent.width-20 * root.s
            spacing:2 * root.s

            Fact { width: parent.width; label: "Address"; value: root.dev ? root.dev.address : "" }
            /**
             * El alias NO se pierde por preferir `deviceName` en el titulo: si
             * hay uno puesto y dice algo distinto, tiene su propia fila.
             */
            Fact {
                width: parent.width
                // Sin `height: visible ? … : 0`: el `Column` ya se salta lo
                // invisible, y ese binding es el que dispara el bucle de
                // polish() (QS-FUNC-005). `Fact` ya mide 17 por su cuenta.
                visible: root.alias_.length > 0
                label: "Alias"
                value: root.alias_
            }
            Fact { width: parent.width; label: "State";   value: Bt.stateOf(root.dev) }
            Fact { width: parent.width; label: "Paired";  value: root.paired ? (root.bonded ? "yes, bonded" : "yes") : "no" }
            Fact { width: parent.width; label: "Trusted"; value: root.trusted ? "yes" : "no" }
            Fact { width: parent.width; label: "Adapter"; value: Bt.adapterName }
        }
        }


            }
            Rectangle {
                id:actionPanel
                objectName:"radio-actions"
                x:root.splitLayout ? infoColumn.width + 20 * root.s : 0
                y:root.splitLayout ? 0 : infoColumn.implicitHeight + 16 * root.s
                width:detailBody.width-x
                height:actionColumn.implicitHeight+24 * root.s
                radius:Metrics.rMd * root.s; color:Theme.tileBg
                Column {
                    id:actionColumn
                    x:12 * root.s; y:12 * root.s
                    width:parent.width-24 * root.s; spacing:10 * root.s
                    Text {
                        width:parent.width; text:"Actions"
                        color:Theme.fg; font.family:Typography.ui; font.pixelSize:Typography.body * root.s
                        font.weight:Typography.wStrong
                    }
                    Text {
                        width:parent.width; text:"↑↓ / Tab · Enter"
                        color:Theme.fgVariant; font.family:Typography.ui; font.pixelSize:Typography.caption * root.s
                    }
        // ---- aviso -----------------------------------------------------------

        /**
         * Ocupa sitio **solo cuando dice algo**, y el `Text` mide contra un
         * ancho constante, no contra el animado: asi un mensaje de dos lineas
         * empuja igual que uno de una, sin bucle de binding.
         *
         * `visible` decide y la altura es la implicita del texto, sin
         * condicional: el `Column` ya se salta lo invisible (QS-FUNC-005).
         */
        Item {
            width: actionColumn.width
            implicitHeight: msg.implicitHeight
            visible: msg.text.length > 0

            // Un fallo y una confirmación ya no se distinguen sólo por el color
            // del texto: el tono tiene forma (filo + glifo).
            Notice {
                id: msg
                width: parent.width
                s: root.s
                tone: root.messageIsError ? "danger" : "info"
                text: root.message
            }
        }

        // ---- acciones --------------------------------------------------------

        ActionGroup {
            tabMoves: true
            id: acts
            width: actionColumn.width
            s: root.s
            orientation: "vertical"
            minimumRowHeight: 40
            spacing: 8 * root.s
            hoverMovesFocus: false
            active: root.keyNav
            actions: root.actionList
            onTriggered: (id) => root.run(id)
        }

                }
            }
        }
    }
    }
    ScrollHint { view:detailView; s:root.s }
}
