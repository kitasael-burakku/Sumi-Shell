pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../services"
import "../components"

/**
 * Superficie de bluetooth (Fase 9.f.3).
 *
 * SE LLAMA `BtList` Y NO `Bluetooth` a proposito: `Quickshell.Bluetooth` es
 * un singleton del mismo nombre, y un tipo propio que lo tape en cualquier
 * archivo que importe los dos seria un fallo silencioso, del tipo que cuesta
 * una tarde encontrar. La clave del registro si es `bluetooth`.
 *
 * Sustituye a los tres clics del modulo `custom/bluetooth` de Waybar: el
 * izquierdo abria `rofi/scripts/bluetooth.sh` (B3), el derecho llamaba a
 * `waybar/scripts/bluetooth.sh --toggle` (B4) y el del medio abria
 * `blueman-manager` (B5, renuncia escrita: es otra GUI, no una capacidad del
 * shell). El script de rofi **no se retira** (ADR-18).
 *
 * NI UN PROCESO. `Quickshell.Bluetooth` cubre tambien la accion, asi que no
 * hay `bluetoothctl` por ningun lado -- ni siquiera para escanear, que en el
 * original era lo mas retorcido: `scan on` como invocacion suelta no escanea
 * nada en bluez 5.87 y habia que alimentar una sesion interactiva por stdin y
 * mantenerla viva 6 s (T6). Aqui es `adapter.discovering = true`.
 *
 * EL ESCANEO ES EXPLICITO, y es la diferencia deliberada con la superficie de
 * wifi. Alli abrir enciende el escaner solo, porque el trabajo de esa pantalla
 * *es* elegir de lo que hay en el aire. Aqui el trabajo normal es tu propio
 * aparato ya emparejado, y bluez CACHEA lo visto (medido el 2026-09-09: tras
 * parar el escaneo, `bluetoothctl devices` seguia listando los 8 vecinos). Si
 * el escaneo fuera automatico, abrir para desconectar unos auriculares
 * llenaria la lista de televisores ajenos. Es la misma separacion que hacia
 * rofi entre su menu principal (T4) y su submenu de busqueda (T3/T7).
 *
 * ALTURA FIJA Y ANCLAJES, SIN `Column` -- leccion pagada en 9.f.2. Un
 * `ListView` dentro de un `Column` ata la altura de la superficie al contenido
 * mientras el morph vuela, y con una lista que crece sola el destino se mueve:
 * el shell se quedo repintando hasta dejar de responder al IPC. Y aqui la
 * lista crece sola tanto o mas que la de wifi.
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
     * Rediseño, fase 5D: la fila elegida POR IDENTIDAD («scan» o la dirección del
     * aparato). La lista se rehace al aparecer vecinos durante la búsqueda: con sólo el
     * índice, Enter pasaba a otro aparato (futurebluetooth §«Integración»).
     */
    property string selKey: "scan"
    /** Aviso de la propia superficie, no un fallo del adaptador. */
    property string note: ""

    /**
     * LAS FILAS SON DATOS, con la de buscar dentro del mismo array. Asi la
     * navegacion es un indice sobre una sola lista y no hay que llevar un
     * "estas en el boton o en la lista" aparte -- que es exactamente el fallo
     * que `ActionGroup` existe para no repetir.
     *
     * Es ademas la forma del menu original: la fila de busqueda de rofi (T3)
     * vivia entre el interruptor de energia y la lista de emparejados.
     */
    readonly property var rows: {
        if (!Bt.present || !Bt.powered) return [];
        const out = [{ kind: "scan" }];
        const ds = Bt.devices;
        for (let i = 0; i < ds.length; i++) out.push({ kind: "dev", dev: ds[i] });
        return out;
    }
    readonly property int count: root.rows.length

    /**
     * La reclamacion se hace TAMBIEN al crearse: `onActiveChanged` solo corre
     * cuando el valor cambia, y el host carga las superficies perezosamente ya
     * con `open: true`.
     */
    /**
     * La clave lleva el monitor y no se reclama mientras este vacio: mismo
     * razonamiento que en `Wifi.qml` (QS-FUNC-003).
     */
    readonly property string scanKey: root.screenName.length > 0 ? "bt@" + root.screenName : ""
    /** Una superficie recien creada nunca esta buscando: la busqueda se pide con Enter. */
    property bool searching: false
    Claim { target: Bt; method: "claimScan"; key: root.scanKey; value: root.searching }

    onActiveChanged: {
        if (root.active) {
            root.selected = 0;
            root.selKey = "scan";
            root.note = "";
        } else {
            // Cerrar SIEMPRE suelta la radio. La puerta P4 se mide con esto.
            root.searching = false;
        }
    }

    function keyOf(r) { return !r ? "" : (r.kind === "scan" ? "scan" : r.dev.address); }
    onSelectedChanged: { const r = root.rows[root.selected]; if (r) root.selKey = root.keyOf(r); }
    /** Tras un cambio de la lista: volver a la fila elegida, por identidad (un paso del bucle después). */
    function reconcile() {
        if (root.count === 0) { root.selected = 0; return; }
        let i = root.rows.findIndex(function (r) { return root.keyOf(r) === root.selKey; });
        if (i < 0) i = Math.max(0, Math.min(root.selected, root.count - 1));
        root.selected = i;
        root.selKey = root.keyOf(root.rows[i]);
    }
    onCountChanged: Qt.callLater(root.reconcile)
    Connections {
        target: Bt
        function onDevicesChanged() { Qt.callLater(root.reconcile); }
    }

    // ---- historial (fase 4): la fila por identidad y el scroll ------------------------
    function saveContext() { return { sel: root.selKey, y: list.contentY }; }
    function restoreContext(ctx) {
        if (!ctx) return true;
        root.selKey = ctx.sel || "scan";
        root.reconcile();
        list.contentY = Math.max(0, Math.min(ctx.y || 0, Math.max(0, list.contentHeight - list.height)));
        return root.rows.some(function (r) { return root.keyOf(r) === root.selKey; }) || root.count === 0;
    }

    function move(delta) {
        root.note = "";
        if (root.count === 0) return;
        root.selected = Math.max(0, Math.min(root.count - 1, root.selected + delta));
        list.positionViewAtIndex(root.selected, ListView.Contain);
    }

    function toggleScan() {
        root.searching = !Bt.scanWanted;
        root.note = Bt.scanWanted
            ? "Put the device in pairing mode so it shows up."
            : "";
    }

    /**
     * Enter. Sobre la fila de busqueda enciende o apaga el descubrimiento;
     * sobre un aparato abre su ficha, que es donde las acciones tienen sitio
     * para explicarse -- mismo reparto que lista/ficha en 9.f.2b.
     */
    function activate() {
        if (!Bt.present) return;
        /**
         * Con rfkill puesto, `enabled = true` no puede prosperar: bluez lo
         * rechaza y el adaptador se queda en `Blocked`. Antes esto llamaba a
         * `setPower()` igualmente y la tecla parecia no hacer nada -- visto al
         * ejercitar P5. Decirlo es mas barato que dejar al usuario probando.
         */
        if (Bt.blocked) {
            root.note = "Blocked by rfkill.  Run `rfkill unblock bluetooth` first.";
            return;
        }
        if (!Bt.powered) { Bt.setPower(true); return; }
        const r = root.rows[root.selected];
        if (!r) return;
        if (r.kind === "scan") { root.toggleScan(); return; }
        // La direccion viaja con el salto: la selecciona esta pantalla (§`sel`).
        root.requestDetail("btDetail", r.dev.address);
    }

    function keyPressed(event) {
        if (event.key === Qt.Key_Up)         { root.move(-1); event.accepted = true; }
        else if (event.key === Qt.Key_Down)  { root.move(1);  event.accepted = true; }
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activate(); event.accepted = true;
        }
    }

    /** Lo que dice el pie cuando hay una operacion en curso o recien fallada. */
    function phaseText() {
        const a = Bt.phaseAddr;
        if (a.length === 0) return "";
        const d = Bt.byAddress(a);
        const who = d ? Bt.labelOf(d) : a;
        if (Bt.phase === "busy")
            return (Bt.phaseKind === "pair" ? "Pairing with " : "Connecting to ") + who + "…";
        // 10.e: antes mandaba a SUPER+F7 (rofi), retirado — y que tampoco
        // contestaba un PIN (`bluetoothctl pair` suelto). La sesion interactiva
        // de bluetoothctl en una terminal si lo hace.
        if (Bt.phase === "failed" && Bt.failNote.length > 0) return Bt.failNote + ".";   // 6C-2
        if (Bt.phase === "failed" && Bt.phaseKind === "pair")
            return "Could not pair with " + who + ". If it asks for a PIN, pair it with bluetoothctl in a terminal.";
        if (Bt.phase === "failed") return "Could not reach " + who + ".";
        if (Bt.phase === "timeout") return who + " did not answer in time.";
        return "";
    }

    readonly property bool phaseIsError: Bt.phase === "failed" || Bt.phase === "timeout"

    // ---- cabecera -----------------------------------------------------------

        RadioHeader {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        s: root.s
        title: "Bluetooth"
        glyph: Bt.powered ? "bt" : "bt-off"
        aside: !Bt.present ? (Bt.ready ? "No adapter" : "Loading…")
            : !Bt.powered ? (Bt.blocked ? "Blocked" : "Bluetooth off")
            : Bt.connectedCount > 0 ? Bt.connectedCount + " connected"
            : Bt.pairedDevices.length === 0 ? "No devices yet"
            : Bt.pairedDevices.length + " paired"

        Toggle {
            anchors.verticalCenter:parent.verticalCenter
            s:root.s; label:"Bluetooth radio"; on:Bt.powered
            enabled:Bt.present && !Bt.blocked
            onToggled:Bt.togglePower()
        }
        FrameNav {
            anchors.verticalCenter: parent.verticalCenter
            s: root.s
            host: root.host
            onCloseRequested: root.requestClose()
        }
    }

    // ---- pie ----------------------------------------------------------------

    /**
     * El pie cuenta la fase del escaneo («Scanning…», «3 devices»), que es
     * estado corriente y va en texto; pero una nota o un fallo son cosas de las
     * que enterarse, y van en `Notice`. El alto sigue a lo que se enseña —un dato,
     * no la visibilidad, así que no es el bucle de polish de QS-FUNC-005— y la
     * lista, anclada a `foot.top`, deja sitio.
     */
    Item {
        id: foot
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        readonly property bool noticing: root.note.length > 0 || root.phaseIsError
        height: foot.noticing ? footNotice.implicitHeight : 14 * root.s

        Text {
            anchors.fill: parent
            visible: !foot.noticing
            verticalAlignment: Text.AlignVCenter
            text: root.phaseText()
            color: Theme.fgVariant
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
            elide: Text.ElideRight
        }

        Notice {
            id: footNotice
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            visible: foot.noticing
            s: root.s
            tone: root.note.length > 0 ? "info" : "danger"
            text: root.note.length > 0 ? root.note : root.phaseText()
        }
    }

    // ---- cuerpo --------------------------------------------------------------

    /**
     * W2 contra W4: "no hay adaptador" y "el adaptador esta apagado" son cosas
     * distintas, y distinguirlas fue un arreglo consciente del autor del script
     * (su linea 54). Aqui sale de `Bt.present` contra `Bt.powered`, y encima
     * hay un tercer caso que el original no sabia ver: `Blocked` por rfkill.
     */
    Empty {
        y: header.y + header.height
            + Math.max(Metrics.sp5 * root.s, (parent.height - header.y - header.height - height) * 0.42)
        anchors.horizontalCenter: parent.horizontalCenter
        visible: !Bt.present || !Bt.powered
        s: root.s
        maxWidth: parent.width
        loading: !Bt.present && !Bt.ready
        glyph: "bt-off"
        text: !Bt.present ? (Bt.ready ? "Adapter unavailable" : "Loading devices…")
            : Bt.blocked ? "Bluetooth is blocked" : "Bluetooth is off"
        hint: !Bt.present ? "" : Bt.blocked ? "Run rfkill unblock bluetooth" : "Enter turns it on"
    }

    ListView {
        id: list
        anchors.top: header.bottom
        anchors.topMargin: 6 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        // Filas enteras: el alto es un múltiplo del paso de fila, así la última no queda cortada
        // en reposo (2026-11-10). Lo que sobra queda como aire sobre el pie.
        readonly property real room: foot.y - y - 6 * root.s
        height: Math.max(root.rowH, Math.floor((room + spacing) / (root.rowH + spacing)) * (root.rowH + spacing) - spacing)
        visible: root.count > 0
        clip: true
        model: root.rows
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
            readonly property bool isScan: row.modelData.kind === "scan"
            readonly property var dev: row.isScan ? null : row.modelData.dev
            readonly property bool anon: !row.isScan && Bt.isAnonymous(row.dev)
            readonly property int batt: row.isScan ? -1 : Bt.batteryOf(row.dev)
            readonly property bool here: !row.isScan && Bt.phaseAddr === row.dev.address

            // 16A-2
            Accessible.role: Accessible.ListItem
            Accessible.name: row.isScan ? "Search for new devices" : Bt.labelOf(row.dev)
            Accessible.description: tag.text
            Accessible.selected: row.sel
            Accessible.onPressAction: { root.selected = row.index; root.activate(); }

            Rectangle {
                anchors.fill: parent
                anchors.topMargin: 1 * root.s
                anchors.bottomMargin: 1 * root.s
                radius: Metrics.r(8) * root.s
                // Elegida = celda + marca; conectado = tinte suave del tema; buscar = fondo tenue
                // propio; hover = fondo tenue (futurebluetooth: selección ≠ conexión).
                color: row.sel ? Theme.selBg
                     : rowArea.containsMouse ? Theme.hoverBg
                     : (!row.isScan && row.dev.connected) ? Qt.alpha(Theme.primary, 0.08)
                     : row.isScan ? Qt.alpha(Theme.fg, 0.04)
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
                id: glyph
                anchors.left: parent.left
                anchors.leftMargin: 15 * root.s
                anchors.verticalCenter: parent.verticalCenter
                name: row.isScan ? "bt-search" : Bt.deviceGlyph(row.dev)
                size: 18 * root.s
                // Mientras busca, pulso lento del glifo de búsqueda, como Wi-Fi; sólo en Normal.
                readonly property bool pulsing: row.isScan && root.active && Bt.scanWanted && Motion.mode === "normal"
                SequentialAnimation on opacity {
                    running: glyph.pulsing
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.35; duration: 900; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
                }
                onPulsingChanged: if (!pulsing) opacity = 1
                color: row.isScan
                        ? (Bt.scanWanted ? Theme.primary : Theme.fgVariant)
                        : row.dev.connected ? Theme.primary
                        : row.dev.blocked ? Theme.errorColor : Theme.fgVariant
            }

            Text {
                anchors.left: glyph.right
                id: deviceName
                anchors.leftMargin: 14 * root.s
                anchors.right: parent.right
                anchors.rightMargin: 8 * root.s
                anchors.top:parent.top; anchors.topMargin:8 * root.s
                /**
                 * `Bt.labelOf()` resuelve las tres formas: nombre real del
                 * aparato, alias si no hay, y la direccion en su forma normal
                 * (con dos puntos) cuando no anuncia ninguno -- que fueron 6 de
                 * 8 vecinos en la medida del 2026-09-09.
                 */
                text: row.isScan
                        ? "Search for new devices"
                        : Bt.labelOf(row.dev)
                elide: Text.ElideRight
                color: row.isScan ? (row.sel ? Theme.fg : Theme.fgVariant)
                     : row.dev.connected ? Theme.fg
                     : (row.sel ? Theme.fg : Theme.fgVariant)
                font.family: Typography.ui
                font.pixelSize: (Typography.body + 0.5) * root.s
                font.weight: (!row.isScan && row.dev.connected) ? Font.DemiBold : Font.Normal
            }

            /**
             * La etiqueta de estado, que es justo lo que el menu de rofi no
             * podia tener: dibuja una lista y se va, asi que "conectando" no
             * cabia en ningun sitio.
             */
            Text {
                id: tag
                anchors.left:deviceName.left
                anchors.right: battRow.visible ? battRow.left : parent.right
                anchors.rightMargin: 10 * root.s
                anchors.bottom:parent.bottom; anchors.bottomMargin:9 * root.s
                elide:Text.ElideRight
                text: {
                    if (row.isScan) return Bt.scanWanted ? "Searching…" : "Discover nearby devices";
                    if (row.here && Bt.phase === "busy")
                        return Bt.phaseKind === "pair" ? "Pairing…" : "Connecting…";
                    if (row.here && (Bt.phase === "failed" || Bt.phase === "timeout")) return "Failed";
                    if (row.dev.blocked) return "Blocked";
                    if (row.dev.connected) return "Connected";
                    if (row.dev.paired) return "Paired";
                    return "New";
                }
                color: (row.here && (Bt.phase === "failed" || Bt.phase === "timeout")) ? Theme.errorColor
                     : (!row.isScan && row.dev.blocked) ? Theme.errorColor
                     : (!row.isScan && row.dev.connected) ? Theme.primary
                     : (row.isScan && Bt.scanWanted) ? Theme.primary
                     : Theme.outline
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
            }

            /** W5: la bateria por dispositivo, sin las llamadas a `info`. */
            Row {
                id: battRow
                anchors.right: parent.right
                anchors.rightMargin: 10 * root.s
                anchors.bottom:parent.bottom; anchors.bottomMargin:9 * root.s
                spacing: 3 * root.s
                visible: row.batt >= 0

                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: row.batt <= 20 ? "battery-alert" : "battery"
                    size: 11 * root.s
                    color: row.batt <= 20 ? Theme.errorColor : Theme.outline
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.batt + " %"
                    color: row.batt <= 20 ? Theme.errorColor : Theme.outlineText
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                    font.features: ({ "tnum": 1 })
                }
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
