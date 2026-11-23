pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Networking
import "../theme"
import "../services"
import "../components"

/**
 * Ficha de una red (Fase 9.f.2b).
 *
 * La isla salta aqui desde la lista al elegir una red. El salto es una
 * superficie de verdad, registrada en `core/SurfaceHost`, no un panel que
 * crece: asi el morph tiene destino fijo y la lista no cambia de tamano
 * debajo del usuario.
 *
 * NO CHOCA CON BUG-S1/S3, que siguen pospuestos. Aquellos son otra cosa: con
 * una superficie abierta, los botones de la cara **hover** quedan
 * inalcanzables porque esa cara se desvanece. Aqui el salto lo dispara una
 * fila de la propia superficie, que si esta viva y recibe el clic.
 *
 * ANCLAJES Y ALTURA FIJA, como la lista y por la misma razon (ver el
 * comentario de `Wifi.qml`): nada de `Column` alimentando `implicitHeight`.
 */
Surface {
    id: root

    mTop: 12
    mLeft: 14
    mRight: 14
    mBottom: 12

    signal requestSurface(string name)
    /** Saltar a otra ficha diciendo de dónde se viene (Speed test, 2026-11-14). */
    signal requestDetail(string name, string key)
    property bool keyNav: false
    readonly property bool splitLayout: root.innerW >= 620 * root.s

    /**
     * La red que mira ESTA pantalla (core/SurfaceHost §`sel`). Hasta el
     * 2026-09-22 salia de `Net.detailSsid`, un singleton, y con dos monitores
     * abrir otra ficha en la otra pantalla cambiaba esta sin avisar: de una red
     * conectada con su boton *Disconnect* a una ajena con *Connect with
     * password*. Las operaciones en vuelo (conectar, olvidar) siguen siendo
     * globales y comparadas por ssid, como ya estaban.
     */
    property string sel: ""
    readonly property string ssid: root.sel

    /**
     * La ficha sostiene **el objeto**, no solo el nombre, y esa razon sigue en
     * pie tras bajar la seleccion a la pantalla: si se resolviera el ssid en
     * cada lectura, bastaria con que un escaneo podara esa entrada para dejar
     * la ficha en blanco con el usuario mirandola (pasaba, y por eso se hizo
     * asi). Lo que cambia es DONDE vive: uno por ficha, no uno por shell. Solo
     * se sustituye cuando una busqueda nueva acierta; una que falla no lo
     * borra.
     */
    property var netObj: null
    readonly property var net: root.netObj
    function resolve() {
        // The derived ssid may still be the previous one inside onSelChanged.
        const n = Net.netByName(root.sel);
        if (n)
            root.netObj = n;
    }
    onSelChanged: { root.netObj = null; root.resolve(); root.keyNav = false; if (acts) acts.reset(); }
    Connections {
        target: Net
        function onNetworksChanged() { root.resolve(); }
    }
    readonly property bool connected: root.net !== null && root.net.connected
    readonly property bool known: root.net !== null && root.net.known
    readonly property bool pending: Net.busy && Net.pendingSsid === root.ssid
    readonly property bool needsPsk: root.net !== null && Net.pskCapable(root.net) && !root.known
    readonly property bool isEnterprise: root.net !== null && Net.enterprise(root.net)

    property string asking: ""

    /**
     * DEVOLVER EL FOCO AL CERRAR EL CAMPO. Sin esto la superficie se queda
     * **sorda al teclado** en cuanto se envia la contrasena: el `TextInput` del
     * campo tenia `activeFocus`, y al ocultarse el campo Qt se lo quita sin
     * dárselo a nadie, asi que el `FocusScope` de `core/Screen` deja de recibir
     * teclas. El sintoma es inconfundible y lo reporto el usuario: **el raton
     * sigue funcionando y el teclado no** -- `Esc` no volvia a la lista, pero
     * el chevron si.
     *
     * Va en `onAskingChanged` y no en cada sitio que cierra el campo, para que
     * valga por igual al enviar, al cancelar y a cualquier via futura.
     */
    onAskingChanged: {
        if (root.asking.length === 0 && root.active) root.forceActiveFocus();
        else if (root.asking.length > 0) Qt.callLater(()=>root.revealItem(key.parent));
    }

    /**
     * La ficha tambien reclama el escaner, y lo hace **al crearse ademas de al
     * cambiar** (desde la fase 6A lo garantiza `Claim`): `onActiveChanged` solo corre cuando el valor cambia, y el host
     * carga la superficie perezosamente ya con `open: true`. Al abrir la ficha
     * directamente no habia ningun cambio que observar, asi que nadie pedia el
     * escaner, el modelo se quedaba con las redes conocidas y la ficha de una
     * red ajena no encontraba la suya.
     *
     * La clave lleva el monitor y no se reclama mientras este vacio: mismo
     * razonamiento que en `Wifi.qml` (QS-FUNC-003).
     */
    readonly property string scanKey: root.screenName.length > 0 ? "wifiDetail@" + root.screenName : ""
    Claim { target: Net; method: "claimScan"; key: root.scanKey; value: root.active }

    onActiveChanged: {
        if (root.active) {
            acts.reset(); root.keyNav = false; if (detailView) detailView.contentY = 0;
            root.asking = "";
            key.clear();
            Net.refreshWifiIp();
        } else {
            root.asking = "";
            key.clear();
        }
    }

    /**
     * LAS ACCIONES SON DATOS, no widgets colocados a mano. `ActionGroup` las
     * dibuja, las mide y las navega; si una desaparece, el layout se recoloca y
     * el foco se re-acota solo. Antes esto era un indice 0..2 fijo, y con una
     * red no guardada apuntaba a botones que no existian.
     */
    readonly property var actionList: [
        {
            id: "primary",
            glyph: root.connected ? "wifi-off" : "wifi",
            label: root.busy ? "Connecting…"
                 : root.connected ? "Disconnect"
                 : root.needsPsk ? "Connect with password"
                 : "Connect",
            primary: false,
            enabled: !root.busy && !root.isEnterprise
        },
        {
            id: "speed",
            glyph: "rocket",
            label: "Test speed",
            visible: root.connected
        },
        {
            id: "clear",
            glyph: "lock",
            label: "Clear password",
            visible: root.known,
            confirm: true
        },
        {
            id: "forget",
            glyph: "delete",
            label: "Forget network",
            visible: root.known,
            danger: true,
            confirm: true
        }
    ]

    readonly property bool busy: Net.busy && Net.phaseSsid === root.ssid

    /** 6D: el intento en curso de ESTA red es una operación global (con plazo). */
    opId: root.busy ? Net.connectOpId : ""

    /** El estado de la cabecera sale de la fase, no de banderas sueltas. */
    readonly property string stateLabel: {
        if (root.busy) return "connecting…";
        if (root.connected) return "connected";
        if (Net.phaseSsid === root.ssid && Net.phase === "timeout") return "no answer";
        if (root.known) return "saved";
        return "";
    }
    readonly property color stateColor: root.connected ? Theme.primary
        : (Net.phaseSsid === root.ssid && Net.phase === "timeout") ? Theme.errorColor
        : Theme.outline

    readonly property bool messageIsError: {
        if (root.isEnterprise) return false;
        if (acts.confirming.length > 0) return true;
        return Net.phaseSsid === root.ssid
            && (Net.phase === "failed" || Net.phase === "timeout");
    }

    readonly property string message: {
        // El aviso nombra las DOS vias. Decir solo "⏎ confirma" hacia que con
        // el raton el primer clic pareciera no hacer nada -- reportado por el
        // usuario como "retraso" al olvidar una red, cuando lo que veia era el
        // paso de confirmacion sin saber como cerrarlo.
        if (acts.confirming === "clear") return "Delete the saved password?  ⏎ or click again.";
        if (acts.confirming === "forget") return "Forget this network?  ⏎ or click again.";
        // 10.e: antes mandaba a SUPER+F6 (rofi), que tampoco podía — `wifi.sh`
        // sólo sabía `nmcli … password`, que no sirve para EAP. nmtui (1.58, con
        // «WPA & WPA2 Enterprise») y nm-connection-editor sí.
        if (root.isEnterprise) return "Enterprise network: set it up with nmtui or nm-connection-editor.";
        if (root.asking.length > 0) return "⏎ connect · Esc cancel";
        if (root.busy && root.opElsewhere) return "Connecting from " + root.opOwner + " · click here to follow it on this screen";
        if (Net.phaseSsid !== root.ssid) return "";
        if (Net.phase === "timeout") return "The network did not answer in time.";
        if (Net.phase !== "failed") return "";
        switch (Net.failCode) {
        case ConnectionFailReason.NoSecrets:      return "Wrong password, or it was rejected.";
        case ConnectionFailReason.WifiAuthTimeout: return "The network did not answer the authentication.";
        case ConnectionFailReason.WifiNetworkLost: return "The network vanished during the attempt.";
        case ConnectionFailReason.WifiClientFailed: return "The network refused the connection.";
        case ConnectionFailReason.WifiClientDisconnected: return "The network dropped the connection.";
        default: return Net.lastFail;
        }
    }

    /** Volver a donde se vino (la pila del host). Escape sale de dentro hacia fuera. */
    function back() {
        root.asking = "";
        key.clear();
        root.requestBack();
    }

    function run(id) {
        if (id === "primary") { root.primary(); return; }
        if (id === "speed")   { root.requestDetail("speedtest", "wifi"); return; }
        if (id === "clear")   { Net.clearSecrets(root.ssid); return; }
        if (id === "forget")  { Net.forgetNetwork(root.ssid); root.back(); return; }
    }

    function primary() {
        if (!root.net) return;
        if (root.connected) { Net.disconnectCurrent(); return; }
        if (root.isEnterprise) return;
        if (root.needsPsk) {
            root.asking = root.ssid;
            key.clear();
            Qt.callLater(key.focusField);
            return;
        }
        Net.connectTo(root.ssid, root.screenName);
    }

    /** Guarded (fase 4): una contraseña tecleada y sin enviar no se pierde por un clic fuera. */
    guardReason: root.asking.length > 0 && key.text.length > 0 ? "An unsent password" : ""
    function discardGuarded() { key.clear(); root.asking = ""; }
    /** Para las pruebas: sólo la LONGITUD de lo tecleado, nunca el texto (la regla I-8 del lock). */
    readonly property int keyLength: key.text.length
    function focusGuarded() { key.focusField(); }
    /**
     * SÓLO PRUEBAS (6D, verbo `guardTestFill`): pone `n` caracteres FICTICIOS en el
     * campo de clave, como si se hubieran tecleado, para probar la guardia sin `wtype`
     * (con dos pantallas el teclado no es fiable). Nunca envía: sólo Enter lo haría.
     */
    function testFillSecret(n) {
        if (!root.needsPsk) return false;
        root.asking = root.ssid;
        key.text = "x".repeat(Math.max(1, n));
        return true;
    }

    function submitKey() {
        const psk = key.text;
        if (psk.length === 0) return;
        root.asking = "";
        key.clear();
        Net.connectWithKey(root.ssid, psk, root.screenName);
    }

    /**
     * El teclado: mientras el campo de contrasena tiene el foco se lo queda el;
     * si no, navega el grupo de acciones. Escape sale de lo mas interno hacia
     * fuera -- primero cancela el campo, luego vuelve a la lista.
     */
    function keyPressed(event) {
        if (root.asking.length > 0) return;
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

    function sigGlyph(q) {
        if (q >= 0.75) return "wifi-4";
        if (q >= 0.50) return "wifi-3";
        if (q >= 0.25) return "wifi-2";
        return "wifi-1";
    }

    function ago(ts) {
        if (!ts) return "never";
        const d = Math.floor(Date.now() / 1000) - ts;
        if (d < 90) return "now";
        if (d < 5400) return Math.round(d / 60) + " min";
        if (d < 172800) return Math.round(d / 3600) + " h";
        return Math.round(d / 86400) + " d";
    }

    /**
     * ALTURA DIRIGIDA POR EL CONTENIDO. La superficie mide lo que mide su
     * columna; el host lo lee y el morph se mueve hacia ahi.
     *
     * Esto no reabre el bucle de layout de 9.f.2, y la diferencia importa: alli
     * el problema era un `ListView` cuyo ancho venia del `Column` mientras el
     * morph animaba, con una lista que ademas crecia sola. Aqui no hay
     * `ListView`, y **el ancho interno es constante** (`innerW`, no `width`),
     * asi que el alto se calcula una vez y no cambia con la animacion. El
     * destino solo se mueve cuando el contenido cambia de verdad -- aparece el
     * campo de contrasena, aparece un aviso -- que es exactamente lo que se
     * quiere que anime.
     */
    readonly property real frameW: Math.min(Metrics.radioDetailW * root.s, root.host ? root.host.maxW : 1e9)
    readonly property real innerW: frameW - (root.mLeft + root.mRight) * root.s

    implicitHeight: col.implicitHeight

    /** Una fila de la ficha: etiqueta a la izquierda, valor a la derecha. */
    component Fact: Item {
        property string label: ""
        property string value: ""
        height: 26 * root.s

        Text {
            id: factLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: parent.label
            color: Theme.outlineText
            font.family: Typography.ui
            font.pixelSize: Typography.label * root.s
        }
        Text {
            id: factValue
            anchors.left:factLabel.right; anchors.leftMargin:12 * root.s
            anchors.right: parent.right
            horizontalAlignment:Text.AlignRight; elide:Text.ElideMiddle
            anchors.verticalCenter: parent.verticalCenter
            text: parent.value.length > 0 ? parent.value : "—"
            color: parent.value.length > 0 ? Theme.fg : Theme.outlineText
            font.family: Typography.ui
            font.pixelSize: Typography.body * root.s
            font.features: ({ "tnum": 1 })
        }
    }

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
                text: root.ssid
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
        // ---- señal y seguridad ---------------------------------------------

        Row {
            x: 22 * root.s
            spacing: 10 * root.s

            Row {
                spacing: 4 * root.s
                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: root.net ? root.sigGlyph(root.net.signalStrength) : "wifi-none"
                    size: 12 * root.s
                    color: root.connected ? Theme.primary : Theme.fgVariant
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.net ? Math.round(root.net.signalStrength * 100) + " %" : "—"
                    color: Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                    font.features: ({ "tnum": 1 })
                }
            }

            Row {
                spacing: 4 * root.s
                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "lock"
                    size: 10 * root.s
                    color: Theme.outline
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.net ? Net.secLabel(root.net) : ""
                    color: Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
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

            // IP y MAC solo en la tarjeta de la red **conectada**: son de la
            // conexion viva, no de la red que estes mirando. Con la ficha
            // abierta sin red en contexto se quedaban puestos (2026-09-21).
            Fact { width: parent.width; label: "IP";         value: root.connected ? Net.ipv4 : "" }
            Fact { width: parent.width; label: "MAC";        value: root.connected ? Net.mac : "" }
            Fact { width: parent.width; label: "AP";         value: Net.bssidOf(root.ssid) }
            Fact { width: parent.width; label: "Security";    value: Net.keyMgmtOf(root.ssid) }
            Fact { width: parent.width; label: "Last used"; value: root.known ? root.ago(Net.lastUsedOf(root.ssid)) : "" }
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
        // ---- contraseña ------------------------------------------------------

        /**
         * En el flujo, no flotando: aparece entre la ficha y las acciones y
         * **empuja** lo que tiene debajo. Con `visible: false` un hijo de
         * `Column` no ocupa sitio, asi que no hace falta ningun offset.
         */
        Item {
            width: actionColumn.width
            height: 36 * root.s
            visible: root.asking.length > 0

            Rectangle {
                anchors.fill: parent
                radius: Metrics.r(8) * root.s
                color: Qt.alpha(Theme.primary, 0.10)
                border.width: 1
                border.color: Qt.alpha(Theme.primary, 0.35)
            }
            Icon {
                id: keyIcon
                anchors.left: parent.left
                anchors.leftMargin: 9 * root.s
                anchors.verticalCenter: parent.verticalCenter
                name: "lock"
                size: 11 * root.s
                color: Theme.primary
            }
            SearchField {
                id: key
                anchors.left: keyIcon.right
                anchors.leftMargin: 8 * root.s
                anchors.right: parent.right
                anchors.rightMargin: 10 * root.s
                anchors.verticalCenter: parent.verticalCenter
                height: 24 * root.s
                s: root.s
                secret: true
                placeholder: "Password"
                onAccepted: root.submitKey()
                onDismissed: { root.asking = ""; key.clear(); }
            }
        }

        // ---- aviso -----------------------------------------------------------

        /**
         * Ocupa sitio **solo cuando dice algo**, y envuelto en un `Item` con
         * la altura implicita del texto: asi un mensaje de dos lineas empuja
         * igual que uno de una, sin bucle de binding (el `Text` mide contra un
         * ancho constante, no contra el animado).
         *
         * `visible` decide y la altura va sin condicional: el `Column` ya se
         * salta lo invisible (QS-FUNC-005).
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
