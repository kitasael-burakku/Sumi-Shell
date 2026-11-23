pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Networking
import "../theme"
import "../services"
import "../components"

/**
 * Superficie de wifi (Fase 9.f.2).
 *
 * Sustituye al `on-click` del modulo `network` de Waybar, que abria
 * `rofi/scripts/wifi.sh`. Ese script fue la red de seguridad (ADR-18) mientras
 * esta sub-fase corria su riesgo, la unica donde un fallo deja al usuario sin
 * red; se retiro en la Fase 10.e (ADR-27). Sin shell, el camino es `nmtui`.
 *
 * NI UN PROCESO. `Quickshell.Networking` cubre tambien la accion, asi que no
 * hay `nmcli` por ningun lado. La consecuencia que mas importa: la contrasena
 * **nunca pasa por argv**, que era el riesgo que el autor de `wifi.sh` dejo
 * escrito y aceptado en sus lineas 96-102.
 *
 * PUERTA DE ESCANER. Abrir enciende `scannerEnabled` y cerrar lo apaga
 * (`services/Net`). Aqui la puerta si ahorra algo real, al reves que la del
 * mezclador: mantener la radio escaneando cuesta.
 *
 * ALTURA FIJA Y ANCLAJES, SIN `Column` -- y es una leccion pagada, no un
 * gusto. La primera version metia el `ListView` en un `Column` y ataba la
 * altura de la superficie a `col.implicitHeight`. Al abrir, el escaner puebla
 * la lista de 3 a 16 redes en unos cientos de ms, asi que el **destino del
 * morph se movia** en pleno vuelo: Qt lo canta como
 * `Column called polish() inside updatePolish()` y el shell se quedo
 * repintando hasta dejar de responder al IPC (2026-09-09). Es el mismo
 * fenomeno de ADR-25 -- destino movil bajo una animacion -- pero en el layout
 * en vez de en una propiedad. Con altura fija el morph tiene destino quieto y
 * la lista se desplaza por dentro, que es lo que ya hacia el lanzador.
 */
Surface {
    id: root

    mTop: 12
    mLeft: 14
    mRight: 14
    mBottom: 12

    signal requestSurface(string name)
    /** Saltar a una ficha diciendo QUE mirar (core/SurfaceHost §`sel`). */
    signal requestDetail(string name, string key)

    readonly property real rowH: 60 * root.s

    property int selected: 0
    /**
     * Rediseño, fase 5C: la red elegida POR NOMBRE («__wired__» = la fila del cable). Las
     * redes se ordenan por señal y se reordenan solas: con sólo el índice, un cambio de
     * intensidad movía el objetivo de Enter a otra red (futurewifi §«Integración»).
     */
    property string selName: ""
    /** Contrasena pedida: guarda el SSID al que se le esta preguntando. */
    /** Aviso de la propia superficie, no un fallo de NetworkManager. */
    property string note: ""

    readonly property var nets: Net.networks
    readonly property int count: root.nets.length

    /**
     * EL CABLE OCUPA EL INDICE -1 (QS-FUNC-015). La lista sigue siendo la de
     * redes wifi y sus indices no se tocan -- el delegado sigue comparando
     * `index === selected` sin correcciones --, asi que la fila del cable entra
     * por debajo del cero en vez de desplazar a todo el mundo.
     */
    readonly property bool hasWired: Net.wiredDev !== null
    readonly property int firstIndex: root.hasWired ? -1 : 0

    /**
     * CLAVE POR MONITOR (QS-FUNC-003): con una clave fija, dos monitores con la
     * lista abierta comparten reclamacion y el primero que cierra apaga el
     * escaner del otro. `screenName` llega por binding y `onActiveChanged` se
     * dispara durante la construccion, a veces antes que el: con la clave aun
     * vacia NO se reclama -- `"wifi@"` quedaria subida para siempre, porque el
     * cierre suelta la clave completa. `Component.onCompleted`, que ya ve todos
     * los bindings, hace la reclamacion de verdad.
     */
    readonly property string scanKey: root.screenName.length > 0 ? "wifi@" + root.screenName : ""
    /** Fase 6A: la reclamación la lleva `Claim` (al crearse, al cambiar y al destruirse). */
    Claim { target: Net; method: "claimScan"; key: root.scanKey; value: root.active }

    onActiveChanged: {
        if (root.active) {
            // El cursor empieza donde va el trafico: si mandas por cable, en el
            // cable; si no, en la primera red.
            root.selected = (root.hasWired && Net.kind === "wired") ? -1 : 0;
            root.selName = "";
            root.note = "";
            Qt.callLater(root.reconcile);
        }
    }

    onSelectedChanged: {
        if (root.selected < 0) { root.selName = "__wired__"; return; }
        const n = Net.netAt(root.selected);
        if (n) root.selName = n.name;
    }
    /** Tras un cambio de la lista: volver a la red elegida, por nombre (un paso del bucle después). */
    function reconcile() {
        if (root.selName === "__wired__" && root.hasWired) { root.selected = -1; return; }
        let i = root.selName.length > 0 ? Net.indexOfSsid(root.selName) : -1;
        if (i < 0) i = Math.max(root.firstIndex, Math.min(root.selected, root.count - 1));
        root.selected = i;
        const n = Net.netAt(i);
        if (n) root.selName = n.name;
    }
    onCountChanged: Qt.callLater(root.reconcile)
    Connections {
        target: Net
        function onNetworksChanged() { Qt.callLater(root.reconcile); }
    }

    // ---- historial (fase 4): la red elegida por nombre y el scroll -----------------------
    function saveContext() { return { sel: root.selName, y: list.contentY }; }
    function restoreContext(ctx) {
        if (!ctx) return true;
        root.selName = ctx.sel || "";
        root.reconcile();
        list.contentY = Math.max(0, Math.min(ctx.y || 0, Math.max(0, list.contentHeight - list.height)));
        return ctx.sel === "__wired__" || !ctx.sel || Net.indexOfSsid(ctx.sel) >= 0;
    }

    function move(delta) {
        root.note = "";
        if (root.count === 0 && !root.hasWired) return;
        root.selected = Math.max(root.firstIndex,
                                 Math.min(root.count - 1, root.selected + delta));
        if (root.selected >= 0) list.positionViewAtIndex(root.selected, ListView.Contain);
    }

    /**
     * Enter sobre la fila elegida. Tres caminos, y el del medio es el unico
     * que existe aqui y no en el script: `known` dice **de antemano** si hace
     * falta clave, asi que no hay que intentar conectar primero para deducirlo
     * del mensaje de error.
     */
    /**
     * Elegir una red **abre su ficha**, no conecta a bocajarro. Asi la
     * contrasena, el estado y las acciones destructivas viven en un sitio con
     * espacio para explicarse, y la lista se queda siendo una lista.
     */
    function activate() {
        if (root.selected < 0) { root.requestSurface("wired"); return; }
        if (!Net.wifiEnabled) { Net.setRadio(true); return; }
        const net = Net.netAt(root.selected);
        if (!net) return;
        // El ssid viaja con el salto: lo selecciona esta pantalla (§`sel`).
        root.requestDetail("wifiDetail", net.name);
    }



    /**
     * El teclado lo lleva la superficie mientras no haya campo de contrasena;
     * cuando lo hay, el campo tiene el foco y se queda con las teclas (mismo
     * reparto que en el lanzador).
     */
    function keyPressed(event) {
        if (event.key === Qt.Key_Up)         { root.move(-1); event.accepted = true; }
        else if (event.key === Qt.Key_Down)  { root.move(1);  event.accepted = true; }
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activate(); event.accepted = true;
        }
    }

    function sigGlyph(q) {
        if (q >= 0.75) return "wifi-4";
        if (q >= 0.50) return "wifi-3";
        if (q >= 0.25) return "wifi-2";
        return "wifi-1";
    }

    /**
     * Se compara contra el ENUM, no contra el texto: `toString()` devuelve una
     * frase en ingles ("Secrets were required but not provided"), no el nombre
     * del valor. Medido el 2026-09-09 -- la primera version comparaba cadenas y
     * no acertaba ni una.
     */
    function failText() {
        switch (Net.lastFailCode) {
        case ConnectionFailReason.NoSecrets:
            return "Wrong password, or it was rejected.";
        case ConnectionFailReason.WifiAuthTimeout:
            return "The network did not answer the authentication.";
        case ConnectionFailReason.WifiNetworkLost:
            return "The network vanished during the attempt.";
        case ConnectionFailReason.WifiClientFailed:
            return "The network refused the connection.";
        case ConnectionFailReason.WifiClientDisconnected:
            return "The network dropped the connection.";
        default:
            return Net.lastFail.length > 0 ? Net.lastFail : "";
        }
    }

    // ---- cabecera -----------------------------------------------------------

    RadioHeader {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        s: root.s
        // Con cable, el panel ya no es solo de wifi y el titulo lo dice.
        title: root.hasWired ? "Network" : "Wi-Fi"
        glyph: Net.wifiEnabled ? "wifi" : "wifi-off"
        scanning: root.active && Net.scanning && Net.wifiEnabled

        /**
         * Singular/plural, y "buscando" mientras la lista aun crece. En frio la
         * primera apertura solo trae la red conectada: el cache de
         * NetworkManager se vacia con el tiempo y el escaneo real tarda unos
         * segundos. Decir "1 red" a secas ahi seria dar por terminada una
         * busqueda que sigue.
         */
        aside: !Net.wifiEnabled ? ""
            : Net.scanning ? (root.count === 0 ? "Scanning…" : root.count + (root.count === 1 ? " network · scanning" : " networks · scanning"))
            : root.count === 1 ? "1 network" : root.count > 1 ? root.count + " networks" : ""

        /**
         * Mientras escanea, un pulso LENTO de opacidad del glifo (futurewifi §«Dirección
         * visual»); sólo en Normal: con Reduced u Off el estado lo dicen el glifo fijo y el
         * texto. Corre sólo con el panel abierto y escaneando.
         */

        /**
         * El mismo interruptor que usa la superficie de ajustes
         * (`components/Toggle`), para que encender la radio se parezca a todo
         * lo demas del shell y no a un truco de esta pantalla.
         */
        Toggle {
            anchors.verticalCenter: parent.verticalCenter
            s: root.s
            label: "Wi-Fi radio"
            on: Net.wifiEnabled
            onToggled: Net.setRadio(!Net.wifiEnabled)
        }

        // Separado del interruptor: su área de clic no se toca con la del marco.
        Item { width: 6 * root.s; height: 1 }
        FrameNav {
            anchors.verticalCenter: parent.verticalCenter
            s: root.s
            host: root.host
            onCloseRequested: root.requestClose()
        }
    }

    // ---- el cable, si lo hay -------------------------------------------------

    /**
     * La fila que faltaba. No va dentro del `ListView` a proposito: aquel
     * modelo son redes wifi, y meter un elemento ajeno obligaria a corregir
     * indices en el delegado y en el escaner. Aqui es una fila hermana, con la
     * misma forma y el mismo `rowH`, y la lista empieza debajo.
     */
    Item {
        id: wiredRow
        anchors.top: header.bottom
        anchors.topMargin: 6 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        height: root.rowH
        visible: root.hasWired

        readonly property bool sel: root.selected < 0

        // 16A-2
        Accessible.role: Accessible.ListItem
        Accessible.name: "Wired connection"
        Accessible.selected: wiredRow.sel
        Accessible.onPressAction: { root.selected = -1; root.activate(); }

        Rectangle {
            anchors.fill: parent
            anchors.topMargin: 1 * root.s
            anchors.bottomMargin: 1 * root.s
            radius: Metrics.r(8) * root.s
            color: wiredRow.sel ? Theme.selBg : (wiredArea.containsMouse ? Theme.hoverBg : "transparent")
            Behavior on color { ColorAnimation { duration: Motion.fast } }
        }

        Icon {
            id: wiredIcon
            anchors.left: parent.left
            anchors.leftMargin: 8 * root.s
            anchors.verticalCenter: parent.verticalCenter
            name: "ethernet"
            size: 14 * root.s
            color: Net.wiredUp ? Theme.primary : Theme.fgVariant
        }

        Text {
            anchors.left: wiredIcon.right
            anchors.leftMargin: 7 * root.s
            anchors.right: wiredTag.left
            anchors.rightMargin: 8 * root.s
            anchors.verticalCenter: parent.verticalCenter
            text: Net.wiredName.length > 0 ? Net.wiredName : "Wired"
            elide: Text.ElideRight
            color: Net.wiredUp ? Theme.fg : (wiredRow.sel ? Theme.fg : Theme.fgVariant)
            font.family: Typography.ui
            font.pixelSize: Typography.body * root.s
            font.weight: Net.wiredUp ? Font.DemiBold : Font.Normal
        }

        Text {
            id: wiredTag
            anchors.right: wiredSpeed.left
            anchors.rightMargin: 8 * root.s
            anchors.verticalCenter: parent.verticalCenter
            text: Net.wiredUp ? "Connected" : (Net.wiredLink ? "" : "No cable")
            color: Net.wiredUp ? Theme.primary : Theme.outlineText
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }

        Text {
            id: wiredSpeed
            anchors.right: parent.right
            anchors.rightMargin: 10 * root.s
            anchors.verticalCenter: parent.verticalCenter
            text: Net.linkSpeed > 0 ? Net.linkSpeed + " Mb/s" : ""
            color: Theme.outlineText
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
            font.features: ({ "tnum": 1 })
        }

        MouseArea {
            id: wiredArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { root.selected = -1; root.activate(); }
        }
    }

    /** Debajo de la fila del cable si la hay, y si no debajo de la cabecera. */
    readonly property Item bodyTop: root.hasWired ? wiredRow : header

    // ---- pie: contraseña y error --------------------------------------------

    /**
     * El fallo de conexión, con la forma que tiene un fallo en todo el shell
     * (`components/Notice`): filo de color, glifo y sitio fijo. Antes era un
     * `Text` rojo a secas, indistinguible de una nota informativa salvo por el
     * color — y el color solo no basta para decir de qué clase de cosa se trata.
     */
    Notice {
        id: fail
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        s: root.s
        visible: text.length > 0
        tone: root.note.length > 0 ? "info" : "danger"
        text: root.note.length > 0 ? root.note : root.failText()
    }

    // ---- cuerpo --------------------------------------------------------------

    // Apagado o sin gestor: el mismo estado vacío que el resto de la shell, centrado en el cuerpo.
    Empty {
        id: radioOff
        y: root.bodyTop.y + root.bodyTop.height
            + Math.max(Metrics.sp5 * root.s, (parent.height - root.bodyTop.y - root.bodyTop.height - height) * 0.42)
        anchors.horizontalCenter: parent.horizontalCenter
        visible: !Net.wifiEnabled
        s: root.s
        maxWidth: parent.width
        glyph: "wifi-off"
        text: Net.unavailableWhy.length > 0 ? Net.unavailableWhy
              : Net.wifiHardware ? "Wi-Fi is off" : "No Wi-Fi adapter"
        hint: Net.unavailableWhy.length > 0 ? "The shell manages Wi-Fi through it"
              : Net.wifiHardware ? "Enter turns it on" : ""
    }

    Empty {
        y: root.bodyTop.y + root.bodyTop.height
            + Math.max(Metrics.sp5 * root.s, (parent.height - root.bodyTop.y - root.bodyTop.height - height) * 0.42)
        anchors.horizontalCenter: parent.horizontalCenter
        visible: Net.wifiEnabled && root.count === 0
        s: root.s
        maxWidth: parent.width
        loading: Net.scanning
        glyph: "wifi-none"
        text: !Net.ready ? "Loading networks…" : Net.scanning ? "Scanning…" : "No networks found"
        hint: (Net.scanning || !Net.ready) ? "" : "Move closer, or scan again"
    }

    ListView {
        id: list
        anchors.top: root.bodyTop.bottom
        anchors.topMargin: 6 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        // Filas enteras: el alto es un múltiplo del paso de fila, así la última no queda cortada
        // en reposo (2026-11-10). Lo que sobra queda como aire sobre el pie.
        readonly property real room: (fail.visible ? fail.y : parent.height - 14 * root.s) - y - 6 * root.s
        height: Math.max(root.rowH, Math.floor((room + spacing) / (root.rowH + spacing)) * (root.rowH + spacing) - spacing)
        visible: Net.wifiEnabled && root.count > 0
        clip: true
        model: root.nets
        currentIndex: root.selected
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: 0
        spacing: 4 * root.s

        delegate: Item {
            id: row
            required property int index
            required property var modelData

            width: list.width
            height: root.rowH

            readonly property bool sel: row.index === root.selected
            readonly property bool isPending: Net.busy && Net.pendingSsid === row.modelData.name
            readonly property bool failedHere: Net.lastFail.length > 0
                && Net.lastFailSsid === row.modelData.name

            // 16A-2: el estado en palabras, no sólo en el tinte
            Accessible.role: Accessible.ListItem
            Accessible.name: String(row.modelData.name || "")
            Accessible.description: (row.modelData.connected ? "Connected" : row.isPending ? "Connecting"
                : row.failedHere ? "Failed" : row.modelData.known ? "Saved" : "")
                + " · signal " + Math.round(row.modelData.signalStrength * 100) + "%"
            Accessible.selected: row.sel
            Accessible.onPressAction: { root.selected = row.index; root.activate(); }

            Rectangle {
                anchors.fill: parent
                anchors.topMargin: 1 * root.s
                anchors.bottomMargin: 1 * root.s
                radius: Metrics.r(8) * root.s
                // La conectada lleva un tinte suave del tema SIEMPRE; la elegida, la celda de
                // selección y una marca; el hover, un fondo tenue (futurewifi: no se confunden).
                color: row.sel ? Theme.selBg
                     : rowArea.containsMouse ? Theme.hoverBg
                     : row.modelData.connected ? Qt.alpha(Theme.primary, 0.08)
                     : "transparent"
                /** Estado discreto (la seleccion), no geometria: ADR-25 lo deja. */
                Behavior on color { ColorAnimation { duration: Motion.fast } }
            }
            Rectangle {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                visible: row.sel
                width: 2 * root.s
                height: parent.height * 0.50
                radius: Metrics.pill(width)
                color: Theme.primary
            }

            Rectangle {
                x:8 * root.s; anchors.verticalCenter:parent.verticalCenter
                width:32 * root.s; height:32 * root.s; radius:Metrics.r(10) * root.s
                color:Qt.alpha(Theme.fg,0.045)
            }
            Icon {
                id: sig
                anchors.left: parent.left
                anchors.leftMargin: 15 * root.s
                anchors.verticalCenter: parent.verticalCenter
                name: root.sigGlyph(row.modelData.signalStrength)
                size: 18 * root.s
                color: row.modelData.connected ? Theme.primary
                     : (row.failedHere ? Theme.errorColor : Theme.fgVariant)
            }

            Icon {
                id: lock
                anchors.left: sig.right
                anchors.leftMargin: 14 * root.s
                anchors.bottom:parent.bottom; anchors.bottomMargin:10 * root.s
                visible: Net.needsKey(row.modelData)
                name: "lock"
                size: 10 * root.s
                color: Theme.outline
            }

            Text {
                id: networkName
                anchors.left: sig.right
                anchors.leftMargin: 14 * root.s
                anchors.right: parent.right
                anchors.rightMargin: 8 * root.s
                anchors.top:parent.top; anchors.topMargin:8 * root.s
                text: row.modelData.name
                elide: Text.ElideRight
                color: row.modelData.connected ? Theme.fg
                     : (row.sel ? Theme.fg : Theme.fgVariant)
                font.family: Typography.ui
                font.pixelSize: (Typography.body + 0.5) * root.s
                font.weight: row.modelData.connected ? Font.DemiBold : Font.Normal
            }

            /**
             * La etiqueta de estado, y es la parte que el menu de rofi no podia
             * tener: rofi dibuja una lista y se va, asi que "conectando" no
             * cabia en ningun sitio.
             */
            Text {
                id: tag
                anchors.left:lock.visible ? lock.right : networkName.left
                anchors.leftMargin:lock.visible ? 5 * root.s : 0
                anchors.right: pct.left
                anchors.rightMargin: 8 * root.s
                anchors.bottom:parent.bottom; anchors.bottomMargin:9 * root.s
                elide:Text.ElideRight
                text: row.isPending ? "Connecting…"
                    : row.failedHere ? "Failed"
                    : row.modelData.connected ? "Connected · " + Net.secLabel(row.modelData)
                    : row.modelData.known ? "Saved · " + Net.secLabel(row.modelData) : Net.secLabel(row.modelData)
                color: row.failedHere ? Theme.errorColor
                     : row.modelData.connected ? Theme.primary : Theme.outline
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
            }

            Text {
                id: pct
                anchors.right: parent.right
                anchors.rightMargin: 10 * root.s
                anchors.bottom:parent.bottom; anchors.bottomMargin:9 * root.s
                width:54 * root.s; horizontalAlignment:Text.AlignRight
                text: Math.round(row.modelData.signalStrength * 100) + " %"
                color: Theme.outlineText
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
                font.features: ({ "tnum": 1 })
            }

            MouseArea {
                id: rowArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.selected = row.index; root.activate(); }
            }
        }
    }

    /**
     * La barra de desplazamiento (2026-09-15). Hermana de la lista, no hija:
     * un hijo de un `ListView` viaja dentro del contenido y se iria con el scroll.
     */
    ScrollHint { view: list; s: root.s }

}
