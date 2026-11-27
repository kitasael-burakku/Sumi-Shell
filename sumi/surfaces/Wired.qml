pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../services"
import "../components"

/**
 * Ficha del cable (QS-FUNC-015, 2026-09-21).
 *
 * El hallazgo decia que `WiredDevice` se leia **solo para el indicador**: el
 * island pintaba `ethernet` y el badge `LAN`, y si abrias la superficie de red
 * no habia ni una fila del cable -- ni IP, ni MAC, ni acciones. Comprobado
 * mirandolo el 2026-09-21, con el cable puesto y siendo la ruta por defecto.
 * Esta es la otra mitad: un sitio donde contarlo.
 *
 * NI UN PROCESO, igual que el resto de 9.f: todo sale de
 * `Quickshell.Networking` a traves de `services/Net`. La unica excepcion es la
 * IP, que no tiene fuente nativa y es el mismo `ip -j -4 addr` acotado de la
 * ficha de wifi -- ahora preguntando por **esta** interfaz (`refreshWiredIp`).
 *
 * ALTURA POR CONTENIDO y ancho interno constante (`innerW`), como
 * `WifiDetail.qml`: el destino del morph solo se mueve cuando el contenido
 * cambia de verdad, no mientras la animacion corre.
 */
Surface {
    id: root

    mTop: Metrics.sp4
    mLeft: Metrics.sp5
    mRight: Metrics.sp5
    mBottom: Metrics.sp4

    property bool keyNav: false
    /** Saltar a otra ficha diciendo de dónde se viene (Speed test, 2026-11-14). */
    signal requestDetail(string name, string key)

    readonly property bool present: Net.wiredDev !== null
    /**
     * `Net.wiredUp`, NO `Net.wiredDev.connected`. Medido al desconectar el
     * cable de verdad el 2026-09-21: una superficie que encadena
     * `singleton.propiedadVar.campo` **no se entera del cambio**, mientras que
     * la misma expresion declarada dentro del singleton si -- por eso
     * `AUTOCONNECT` (que sale de `Net.wiredAutoconnect`) se actualizo y el
     * estado no, y la ficha se quedo diciendo "connected" con la IP muerta y el
     * boton en Disconnect. Es la regla que ya estaba escrita en la cabecera de
     * `Net.qml`: el servicio publica estado plano y las superficies lo leen.
     */
    readonly property bool connected: Net.wiredUp
    readonly property string iface: Net.wiredName

    /**
     * La IP se publica en `Net.ipv4` con la interfaz a la que pertenece
     * (`ipv4Iface`). Aqui solo se pinta si es la de **este** dispositivo: si
     * quedo la del wifi de una ficha anterior, mejor un guion que un dato
     * correcto en el sitio equivocado.
     */
    readonly property string ip: (root.connected && Net.ipv4Iface === root.iface)
        ? Net.ipv4 : ""

    /**
     * `onActiveChanged` se dispara durante la construccion, antes de que exista
     * `acts`: de ahi la guarda. Es la leccion que dejo `ServiceDetail`.
     */
    onActiveChanged: {
        if (!acts) return;
        acts.reset();
        root.keyNav = false;
        flick.contentY = 0;
        if (root.active) Net.refreshWiredIp();
    }

    Component.onCompleted: if (root.active) Net.refreshWiredIp()

    /**
     * El cable puede caerse (o volver) con la ficha delante: entonces la IP hay
     * que volver a pedirla, o limpiarla. `refreshWiredIp()` hace las dos cosas
     * segun el estado, asi que basta con llamarla.
     */
    onConnectedChanged: if (root.active) Net.refreshWiredIp()

    readonly property var actionList: [
        {
            id: "primary",
            label: root.connected ? "Disconnect" : "Connect",
            primary: true,
            danger: root.connected,
            confirm: root.connected,
            enabled: root.present && (root.connected || Net.wiredLink)
        },
        {
            id: "auto",
            label: Net.wiredAutoconnect ? "Turn autoconnect off" : "Turn autoconnect on",
            enabled: root.present
        },
        {
            id: "speed",
            glyph: "rocket",
            label: "Test speed",
            visible: root.connected
        }
    ]

    readonly property string stateLabel: {
        if (!root.present) return "";
        if (root.connected) return "connected";
        if (!Net.wiredLink) return "no cable";
        return Net.wiredState.toLowerCase();
    }
    readonly property color stateColor: root.connected ? Theme.primary : Theme.outline

    readonly property bool messageIsError: acts && acts.confirming.length > 0

    /**
     * El aviso de la desconexion no es decorativo: en esta maquina el cable
     * **es** la ruta por defecto, asi que la accion puede dejarla sin salida.
     * Se nombran las dos vias de confirmar, como en la ficha de wifi, porque
     * con raton el primer clic parecia no hacer nada.
     */
    readonly property string message: {
        if (acts && acts.confirming === "primary")
            return "Disconnect?  This drops the default route.  ⏎ or click again.";
        if (Net.unavailableWhy.length > 0) return Net.unavailableWhy + ".";
        if (!root.present) return "No wired device on this machine.";
        if (!Net.wiredLink) return "No cable plugged into this interface.";
        return "";
    }

    function back() {
        root.requestBack();
    }

    function run(id) {
        if (id === "primary") {
            if (root.connected) Net.wiredDisconnect();
            else Net.wiredConnect();
            return;
        }
        if (id === "auto") {
            Net.setWiredAutoconnect(!Net.wiredAutoconnect);
            return;
        }
        if (id === "speed") {
            root.requestDetail("speedtest", "wired");
            return;
        }
    }

    function keyPressed(event) {
        if (event.key === Qt.Key_Escape) { root.back(); event.accepted = true; return; }
        if (acts && acts.handleKey(event)) {
            root.keyNav = true;
            Qt.callLater(root.revealActions);
            event.accepted = true;
        }
    }

    readonly property real innerW: Math.min((Metrics.wiredW - root.mLeft - root.mRight) * root.s, root.width)

    implicitHeight: col.implicitHeight

    function revealActions() {
        flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height,
            acts.y + acts.height + Metrics.sp1 * root.s - flick.height));
    }

    /** Misma fila etiqueta/valor que la ficha de wifi. */
    /** La fila de ficha común (`components/FactRow`, fase 3B, ADR-42). */
    component Fact: FactRow { s: root.s }

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: col.implicitHeight
        clip: true
        interactive: contentHeight > height + 1
        boundsBehavior: Flickable.StopAtBounds

    Column {
        id: col
        anchors.top: parent.top
        anchors.left: parent.left
        width: root.innerW
        spacing: Metrics.sp3 * root.s

        // ---- cabecera ------------------------------------------------------

        Item {
            width: col.width
            height: 22 * root.s

            Icon {
                id: backIcon
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
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
                anchors.left: backIcon.right
                anchors.leftMargin: 8 * root.s
                anchors.right: stateTag.left
                anchors.rightMargin: 8 * root.s
                anchors.verticalCenter: parent.verticalCenter
                text: root.iface.length > 0 ? root.iface : "Wired"
                elide: Text.ElideRight
                color: Theme.fg
                font.family: Typography.ui
                font.pixelSize: Typography.title * root.s
                font.weight: Font.DemiBold
            }

            Text {
                id: stateTag
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.stateLabel
                color: root.stateColor
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
            }
        }

        // ---- enlace ---------------------------------------------------------

        Row {
            x: 22 * root.s
            spacing: 10 * root.s

            Row {
                spacing: 4 * root.s
                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "ethernet"
                    size: 12 * root.s
                    color: root.connected ? Theme.primary : Theme.fgVariant
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: Net.linkSpeed > 0 ? Net.linkSpeed + " Mb/s" : "—"
                    color: Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                    font.features: ({ "tnum": 1 })
                }
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: Net.degraded && root.connected ? Net.connectivity : ""
                color: Theme.fgVariant
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
            }
        }

        // ---- ficha -----------------------------------------------------------

        Column {
            width: col.width
            spacing: Metrics.sp1 * root.s

            Fact { width: parent.width; label: "IP";          value: root.ip }
            Fact { width: parent.width; label: "MAC";         value: Net.wiredMac }
            Fact { width: parent.width; label: "Cable";       value: Net.wiredLink ? "plugged" : "unplugged" }
            Fact { width: parent.width; label: "Autoconnect"; value: Net.wiredAutoconnect ? "on" : "off" }
            Fact { width: parent.width; label: "Managed";     value: Net.wiredManaged ? "NetworkManager" : "unmanaged" }
        }

        // ---- aviso -----------------------------------------------------------

        Item {
            width: col.width
            implicitHeight: msg.implicitHeight
            visible: msg.text.length > 0

            Notice {
                id: msg
                width: parent.width
                s: root.s
                tone: root.messageIsError ? "danger" : "info"
                text: root.message
            }
        }

        // ---- acciones --------------------------------------------------------

        Item { width: 1; height: Metrics.sp2 * root.s }

        ActionGroup {
            tabMoves: true
            stretch: false
            active: root.keyNav || confirming.length > 0
            hoverMovesFocus: false
            minimumRowHeight: Metrics.hitMin
            spacing: Metrics.sp2 * root.s
            onHovered: root.keyNav = false
            onConfirmingChanged: if (confirming.length > 0) Qt.callLater(root.revealActions)
            id: acts
            width: col.width
            s: root.s
            orientation: "vertical"
            actions: root.actionList
            onTriggered: (id) => root.run(id)
        }
    }
    }
    ScrollHint { view: flick; s: root.s }
}
