import QtQuick
import "../theme"
import "../services"
import "../components"
import "../lib/monitor.js" as Monitor

/**
 * System Monitor, la surface COMPACTA (antes de la fase 12, `rediseno/Antes-de-fase-12.md`, M4):
 * el vistazo. Tarjetas con el valor de ahora y la micrográfica de 60 s; cada «Details» abre la UI
 * de inspección (Super+Ctrl+Y, `core/MonitorLayer`) en su sección y cierra esta surface. Lo que
 * pide quedarse (procesos, núcleos, montajes, un instante pasado) ya no está aquí: 11E-2 lo tenía.
 *
 * Reclama Sysmon "detail" como antes: 60 s de historial compartido con la UI (misma generación).
 */
Surface {
    id: root
    property string selectedCard: "cpu"
    readonly property int columns: root.width / root.s < 604 ? 1 : 2
    readonly property var energy: ({profile: !PowerProfile.checked ? "Checking…" : PowerProfile.present ? PowerProfile.current : "Unavailable",
        lines: [Monitor.line("Profile", PowerProfile.degradation ? "Degraded · " + PowerProfile.degradation : "Current setting")]
            .concat(Battery.present ? [Monitor.line("Battery", Battery.description, Battery.low)] : [])
            .concat(Battery.peripherals.map(p => Monitor.line(p.name, p.percent + "%" + (p.charging ? " · Charging" : ""))))
            .concat(Bt.all.filter(d => d && d.connected && d.batteryAvailable).map(d => Monitor.line(d.name || d.address, Math.round(d.battery * 100) + "%")))})
    readonly property var cards: Monitor.cards(Sysmon.current, root.energy, Sysmon.alerts, Sysmon.tempUnits)
    property var cardIds: []
    onCardsChanged: {
        const ids = root.cards.map(c => c.id);
        if (JSON.stringify(ids) !== JSON.stringify(root.cardIds)) root.cardIds = ids;
    }
    readonly property var focusKeys: root.cardIds.concat(["inspect", "performance"])
    Claim { target: Sysmon; key: root.screenName ? "system@" + root.screenName : ""; value: root.active ? "detail" : false }
    onActiveChanged: if (root.active) PowerProfile.refresh()

    function saveContext() { return {card: root.selectedCard, scroll: flick.contentY}; }
    function restoreContext(ctx) {
        ctx = ctx || {}; root.selectedCard = ctx.card || "cpu";
        Qt.callLater(() => flick.contentY = Math.max(0, Math.min(ctx.scroll || 0, flick.contentHeight - flick.height)));
    }
    /** Details: la UI de inspección en esta pantalla y en esa sección; la surface le deja sitio. */
    function openDetails(section) {
        if (MonitorUi.show(root.screenName, section || "overview")) root.requestClose();
    }
    function activate(key) {
        if (key === "inspect") root.openDetails("overview");
        else if (key === "performance") { if (root.host) root.host.requestSurface("performance"); }
        else {
            const c = root.cards.find(c => c.id === key);
            if (c && c.section) root.openDetails(c.section);
        }
    }
    function keyPressed(event) {
        const k = event.key;
        if (event.modifiers & Qt.AltModifier) return;
        const keys = root.focusKeys;
        let i = keys.indexOf(root.selectedCard);
        const move = d => { root.selectedCard = keys[((i < 0 ? 0 : i) + d + keys.length) % keys.length]; reveal.restart(); };
        if (k === Qt.Key_Escape) root.requestClose();
        else if (k === Qt.Key_Tab || k === Qt.Key_Backtab) move(k === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? -1 : 1);
        else if (k === Qt.Key_Left || k === Qt.Key_Right) move(k === Qt.Key_Left ? -1 : 1);
        else if (k === Qt.Key_Up || k === Qt.Key_Down) move((k === Qt.Key_Up ? -1 : 1) * (root.cardIds.indexOf(root.selectedCard) >= 0 ? root.columns : 1));
        else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) root.activate(root.selectedCard);
        else if (k === Qt.Key_PageDown || k === Qt.Key_PageUp) flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY + (k === Qt.Key_PageDown ? 1 : -1) * flick.height * .8));
        else return;
        event.accepted = true;
    }
    function state() {
        return {open: root.active, columns: root.columns, width: root.width, height: root.height, card: root.selectedCard,
            scroll: flick.contentY, contentHeight: flick.contentHeight, viewHeight: flick.height, historyCount: Sysmon.history.length,
            cards: root.cards.map(c => ({id: c.id, section: c.section, headline: c.headline, aside: c.aside, sub: c.sub, warning: !!c.warning,
                                         graph: c.graph ? c.graph.keys : null, volumes: (c.volumes || []).length}))};
    }
    Timer {
        id: reveal; interval: 40
        onTriggered: {
            const i = root.cardIds.indexOf(root.selectedCard), item = i >= 0 ? cardRep.itemAt(i) : null;
            if (!item) { flick.contentY = Math.max(0, flick.contentHeight - flick.height); return; }
            if (item.y < flick.contentY || item.y + item.height > flick.contentY + flick.height) flick.contentY = Math.min(item.y, Math.max(0, flick.contentHeight - flick.height));
        }
    }
    Column {
        id: top; width: parent.width; spacing: 6 * root.s
        Item {
            width: parent.width; height: 30 * root.s
            Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                text: "System Monitor"; color: Theme.fg
                font.family: Typography.ui; font.pixelSize: Typography.display * root.s; font.weight: Typography.wStrong }
            Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                text: "60 s history"; color: Theme.fgVariant
                font.family: Typography.ui; font.pixelSize: Typography.caption * root.s }
        }
        Text {
            width: parent.width; elide: Text.ElideRight
            text: !Sysmon.current ? (Sysmon.error || "Waiting for samples…")
                : "Now  ·  CPU " + Monitor.number(Sysmon.cpuPct, "%") + "  ·  GPU " + Monitor.number(Sysmon.gpuPct, "%")
                  + "  ·  RAM " + Monitor.number(Sysmon.memPct, "%") + "  ·  ↓ " + Monitor.bytes(Sysmon.current.network ? Sysmon.current.network.rxBps : null, true)
                  + (Sysmon.alerts.length ? "  ·  " + Sysmon.alerts.length + (Sysmon.alerts.length === 1 ? " warning" : " warnings") : "")
            color: Sysmon.error ? Theme.warn : Sysmon.alerts.length ? Theme.warn : Theme.fg
            font.family: Typography.ui; font.pixelSize: Typography.body * root.s
        }
    }
    Flickable {
        id: flick
        anchors.top: top.bottom; anchors.topMargin: 10 * root.s; anchors.bottom: exits.top; anchors.bottomMargin: 8 * root.s
        width: parent.width; clip: true; contentWidth: width; contentHeight: body.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        Column {
            id: body; width: flick.width; spacing: 10 * root.s
            Grid {
                id: grid; width: parent.width; columns: root.columns; spacing: 10 * root.s
                Repeater {
                    id: cardRep; model: root.cardIds
                    SystemCard {
                        required property string modelData
                        required property int index
                        readonly property var card: root.cards.find(c => c.id === modelData) || ({})
                        width: (grid.width - (grid.columns - 1) * grid.spacing) / grid.columns
                        s: root.s; dataRow: card; samples: Sysmon.history
                        selected: root.selectedCard === modelData
                        peerHeight: {
                            if (grid.columns < 2) return 0;
                            void cardRep.count;
                            const peer = cardRep.itemAt(index ^ 1);
                            return peer ? peer.implicitHeight : 0;
                        }
                        painting: root.active && y + height >= flick.contentY && y <= flick.contentY + flick.height
                        onPicked: root.selectedCard = modelData
                        onDetails: { root.selectedCard = modelData; root.activate(modelData); }
                    }
                }
            }

        }
    }
    // Keep both destinations visible while the metric cards scroll.
    Grid {
        id: exits
        anchors.bottom: footer.top; anchors.bottomMargin: 8 * root.s
        width: parent.width
        columns: root.columns
        spacing: 10 * root.s
        Exit {
            key: "inspect"; glyph: "open-external"
            // la tecla de verdad si la shell la conoce (ayuda de atajos); nunca la de por defecto como si fuera la tuya
            label: "Inspect"; hint: Keybinds.keyText("monitor") || "Floating window"
        }
        Exit {
            key: "performance"; glyph: "gauge"
            label: "Dashboard → Performance"; hint: "Modes and limits"
        }
    }
    ScrollHint { view: flick; s: root.s }
    Text {
        id: footer; anchors.bottom: parent.bottom; width: parent.width; elide: Text.ElideRight
        text: "Tab / arrows cards · Enter details · Esc close"
        color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
    }

    /** Una salida de la surface, del tamaño de una tarjeta de la rejilla. */
    component Exit: Rectangle {
        id: ex
        property string key: ""
        property string glyph: ""
        property string label: ""
        property string hint: ""
        readonly property bool focused: root.selectedCard === ex.key
        width: (exits.width - (exits.columns - 1) * exits.spacing) / exits.columns
        height: 60 * root.s
        radius: Metrics.r(12) * root.s
        color: Theme.controlBg(Theme.tileBg, exArea.containsMouse, exArea.pressed && exArea.containsMouse, false)
        border.width: ex.focused ? 2 * root.s : 1
        border.color: ex.focused ? Theme.primary : exArea.containsMouse ? Qt.alpha(Theme.primary, 0.45) : Theme.hair
        scale: exArea.pressed && !Motion.still ? 0.98 : 1
        Behavior on color { ColorAnimation { duration: Motion.fast } }
        Behavior on border.color { ColorAnimation { duration: Motion.fast } }
        Behavior on scale { NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic } }
        Accessible.role: Accessible.Button
        Accessible.name: ex.label
        Accessible.focusable: true
        Accessible.focused: ex.focused
        Accessible.onPressAction: { root.selectedCard = ex.key; root.activate(ex.key); }
        Icon {
            x: 12 * root.s; anchors.verticalCenter: parent.verticalCenter
            name: ex.glyph; size: 18 * root.s
            color: ex.focused || exArea.containsMouse ? Theme.primary : Theme.fgVariant
        }
        Column {
            x: 40 * root.s; anchors.verticalCenter: parent.verticalCenter
            width: parent.width - x - 12 * root.s; spacing: 3 * root.s
            Text {
                width: parent.width; elide: Text.ElideRight; text: ex.label; color: Theme.fg
                font.family: Typography.ui; font.pixelSize: Typography.body * root.s; font.weight: Typography.wStrong
            }
            Text {
                width: parent.width; elide: Text.ElideRight; text: ex.hint; color: Theme.fgVariant
                font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
            }
        }
        MouseArea {
            id: exArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { root.selectedCard = ex.key; root.activate(ex.key); }
        }
    }
}
