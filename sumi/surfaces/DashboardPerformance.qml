import QtQuick
import QtQuick.Layouts
import "../theme"
import "../services"
import "../components"
import "../lib/text-wrap.js" as TextWrap
import "../lib/accent-zones.js" as Zones

// Presentación de Performance; las peticiones y los resultados pertenecen a Modes.
Item {
    id: root
    property real s: 1
    property string section: "mode"
    property int selected: 0
    property int hovered: -1
    property int action: 0
    property var powerTest: null
    signal navigate(string section)
    signal monitor()
    /** Antes de la fase 12: la UI de inspección (la misma instancia que Super+Ctrl+Y). */
    signal inspect()
    /** En la fila del monitor: 0 = la surface, 1 = la UI de inspección (← →). */
    property int monitorPick: 0
    signal revealRequested()
    implicitHeight: content.implicitHeight
    readonly property var cards: [
        {id: "normal", name: "Normal", glyph: "monitor", caption: "Your everyday session"},
        {id: "focus", name: "Focus", glyph: "target", caption: "Fewer interruptions"},
        {id: "gaming", name: "Gaming", glyph: "controller", caption: "Performance for gaming"},
        {id: "cinema", name: "Cinema", glyph: "tv", caption: "Uninterrupted playback"}
    ]
    readonly property var effects: ({
        dnd: ["Do not disturb", "On · critical alerts still arrive"],
        motion: ["Shell motion", "Reduced"], cursors: ["Dynamic cursors", "Off"],
        blur: ["Blur", "Off"], animations: ["Desktop animations", "Off"],
        glass: ["Hyprglass", "Off"], power: ["Power profile", "Performance, if available"],
        video: ["Background video", "Paused"], idle: ["Idle inhibition", "On · Keep awake stays separate"]
    })
    readonly property var keys: ({normal: [], focus: ["dnd", "motion", "cursors"],
        gaming: ["dnd", "motion", "cursors", "blur", "animations", "glass", "power", "video", "idle"],
        cinema: ["dnd", "cursors", "video", "idle"]})
    readonly property int detailIndex: root.hovered >= 0 ? root.hovered : root.selected
    readonly property var detailCard: root.cards[root.detailIndex]
    readonly property string detailMode: root.detailCard.id
    readonly property bool trouble: ["partial", "unavailable", "error"].indexOf(Modes.state) >= 0
    readonly property var actions: (root.trouble ? ["Retry"] : []).concat(Modes.mode !== "normal" || root.trouble ? ["Back to normal"] : [])
    readonly property var progress: Modes.data.progress || null
    readonly property var power: Modes.testing && root.powerTest ? root.powerTest : ({
        checked: PowerProfile.checked, present: PowerProfile.ok, available: PowerProfile.available,
        current: PowerProfile.current, shown: PowerProfile.shownProfile, applying: PowerProfile.applying,
        error: PowerProfile.opState === "error" ? PowerProfile.opReason : "",
        degradation: PowerProfile.degradation, holds: PowerProfile.holds
    })
    readonly property string powerNote: {
        const p = root.power, bits = [];
        if (!p.checked) return "Checking power profiles…";
        if (!p.present) return "Unavailable · the power profile service is not answering";
        if (p.applying) bits.push("Applying " + p.shown + "… · current: " + p.current);
        if (p.error) bits.push("Could not switch · " + p.error);
        if (p.degradation) bits.push("Performance degraded · " + p.degradation);
        for (const h of p.holds || []) bits.push(h.profile + " held by " + h.app + (h.reason ? " · " + h.reason : ""));
        if ((p.available || []).indexOf("performance") < 0) bits.push("Performance unavailable on this device");
        return bits.join(" · ");
    }
    Connections {
        target: Modes
        function onTestRootChanged() { root.powerTest = null; }
    }
    onActionsChanged: {
        root.action = Math.min(root.action, Math.max(0, root.actions.length - 1));
        if (!root.actions.length && root.section === "modeActions") root.navigate("mode");
    }
    onSelectedChanged: root.revealRequested()
    function reset() { root.selected = Math.max(0, root.cards.findIndex(c => c.id === Modes.mode)); root.hovered = -1; root.action = 0; }
    function choose(i) {
        root.selected = i; root.navigate("mode");
        if (!Modes.busy) Modes.set(root.cards[i].id);
    }
    function activateAction() {
        if (Modes.busy) return;
        if (root.actions[root.action] === "Retry") Modes.retry();
        else if (root.actions[root.action] === "Back to normal") Modes.set("normal");
    }
    function nextSection() { return root.actions.length ? "modeActions" : "profile"; }
    function key(event) {
        const k = event.key, up = k === Qt.Key_Up, down = k === Qt.Key_Down;
        const left = k === Qt.Key_Left, right = k === Qt.Key_Right;
        const enter = k === Qt.Key_Return || k === Qt.Key_Enter;
        const tab = k === Qt.Key_Tab, back = k === Qt.Key_Backtab;
        if (!(up || down || left || right || enter || tab || back)) return false;
        // Al usar teclado, su selección vuelve a mandar aunque el puntero siga dentro.
        root.hovered = -1;
        if (root.section === "mode") {
            if (enter) root.choose(root.selected);
            else if (tab) { if (root.selected < 3) root.selected++; else root.navigate(root.nextSection()); }
            else if (back) { if (root.selected > 0) root.selected--; else root.navigate("tabs"); }
            else if (left) root.selected -= root.selected % 2;
            else if (right) root.selected += 1 - root.selected % 2;
            else if (up) { if (root.selected >= 2) root.selected -= 2; else root.navigate("tabs"); }
            else if (down) { if (root.selected < 2) root.selected += 2; else root.navigate(root.nextSection()); }
        } else if (root.section === "modeActions") {
            if (enter) root.activateAction();
            else if (left || back && root.action > 0) root.action = Math.max(0, root.action - 1);
            else if (right || tab && root.action < root.actions.length - 1) root.action = Math.min(root.actions.length - 1, root.action + 1);
            else if (up || back) root.navigate("mode");
            else if (down || tab) root.navigate("profile");
        } else if (root.section === "profile") {
            if ((left || right) && root.power.present && !Modes.testing && !Modes.busy) profile.cycle(right ? 1 : -1);
            else if (up || back) root.navigate(root.actions.length ? "modeActions" : "mode");
            else if (down || tab) root.navigate("monitor");
        } else if (root.section === "monitor") {
            // etapa A: un solo acceso (Inspect está en la propia superficie de System Monitor)
            if (enter) root.monitor();
            else if (left || right) {}
            else if (up || back) root.navigate("profile");
            else if (tab) root.navigate("tabs");
        } else return false;
        return true;
    }
    function focusItem() {
        if (root.section === "mode") return cardRep.itemAt(root.selected);
        if (root.section === "modeActions") return buttons;
        if (root.section === "profile") return energy;
        if (root.section === "monitor") return monitorButton;
        return null;
    }
    function rows() {
        const ks = root.keys[root.detailMode].slice();
        // Al volver a normal, los efectos todavía sin restaurar también explican el fallo.
        if (root.detailMode === Modes.mode)
            for (const k of Object.keys(Modes.data.effects)) if (ks.indexOf(k) < 0) ks.push(k);
        const wont = Modes.wontApply(root.detailMode);     // F2d: antes de elegir
        return ks.map(k => {
            const meta = root.effects[k], r = root.detailMode === Modes.mode ? Modes.data.effects[k] : null;
            let value = k === "motion" && root.detailMode === "gaming" ? "Off" : meta[1];
            let status = "", warning = false;
            if (!r && wont[k]) { status = "Won't apply here · " + wont[k]; warning = true; }
            if (r) {
                if (r.status === "unavailable") { status = "Unavailable · " + r.reason; warning = true; }
                else if (r.status === "error" || r.status === "unknown") { status = (r.status === "unknown" ? "Could not check · " : "Could not apply · ") + r.reason; warning = true; }
                else if (r.manual || r.manualParts || r.status === "modified") status = "Kept your change";
                else if (r.status === "applied") status = "Verified";
                else status = Modes.busy ? "Checking…" : "Not applied";
                if (root.keys[root.detailMode].indexOf(k) < 0) value = "Restore previous value";
            }
            return {key: k, label: meta[0], value: value, status: status, warning: warning};
        });
    }
    readonly property var detailRows: { void Modes.data; return root.rows(); }
    function summary() {
        return {selected: root.cards[root.selected].id, detail: root.detailMode, section: root.section,
            actions: root.actions, action: root.actions[root.action] || "", rows: root.detailRows,
            mode: Modes.mode, activeMode: Modes.activeMode, state: Modes.state, progress: root.progress,
            power: root.power, powerNote: root.powerNote};
    }
    Column {
        id: content
        width: parent.width
        spacing: 10 * root.s
        Grid {
            width: parent.width
            columns: 2
            spacing: 8 * root.s
            Repeater {
                id: cardRep
                model: root.cards
                delegate: Rectangle {
                    id: card
                    required property var modelData
                    required property int index
                    readonly property bool chosen: Modes.activeMode === modelData.id
                    readonly property bool focused: root.section === "mode" && root.selected === index
                    readonly property bool pending: Modes.busy && (root.progress ? root.progress.mode : Modes.mode) === modelData.id
                    /** Cada modo con su color (lib/accent-zones.js): su tarjeta, no la shell entera. */
                    palette.accent: Theme.zone(Zones.of(modelData.id))
                    readonly property var acc: Theme.fam(palette.accent)
                    width: (content.width - 8 * root.s) / 2
                    // 2026-11-12: lo que pida su texto (el pie admite dos renglones), nunca menos de 64·s, y lo mismo
                    // que su pareja de fila para que las dos tarjetas sigan alineadas
                    readonly property real need: Math.max(64 * root.s, Math.ceil(textCol.implicitHeight) + 20 * root.s)
                    readonly property real peerNeed: {
                        void cardRep.count;
                        const peer = cardRep.itemAt(card.index ^ 1);
                        return peer ? peer.need : 0;
                    }
                    height: Math.max(card.need, card.peerNeed)
                    radius: Metrics.r(10) * root.s
                    color: Theme.controlBg(card.acc.container, mouse.containsMouse, mouse.pressed && mouse.containsMouse, card.chosen, card.acc)
                    // etapa A: un solo borde. El foco de teclado manda; sin foco, el activo lleva el suyo
                    // (antes, dos anillos concéntricos en la tarjeta activa enfocada)
                    border.width: card.focused ? Metrics.focusWidth * root.s : chosen ? 1 : 0
                    border.color: card.focused ? card.acc.ring : card.acc.selBorder
                    Behavior on color { ColorAnimation { duration: Motion.fast } }
                    Accessible.role: Accessible.Button
                    Accessible.name: modelData.name
                    Accessible.description: modelData.caption + (chosen ? ". Active" : pending ? ". " + Modes.statusText : "")
                    Accessible.focusable: true
                    Accessible.focused: focused
                    Accessible.onPressAction: root.choose(index)
                    // etapa A: hueco fijo; el texto de las cuatro tarjetas empieza en la misma x
                    Item {
                        id: glyph
                        anchors.left: parent.left; anchors.leftMargin: 12 * root.s; anchors.verticalCenter: parent.verticalCenter
                        width: 26 * root.s; height: width
                        Icon { anchors.centerIn: parent; name: card.modelData.glyph; size: 23 * root.s; color: card.acc.accent }
                    }
                    Column {
                        id: textCol
                        anchors.left: glyph.right; anchors.leftMargin: 10 * root.s
                        anchors.right: parent.right; anchors.rightMargin: 12 * root.s
                        anchors.verticalCenter: parent.verticalCenter; spacing: 3 * root.s
                        Row {
                            width: parent.width
                            spacing: 7 * root.s
                            Text { text: card.modelData.name; color: Theme.fg; font.family: Typography.ui; font.pixelSize: Typography.body * root.s; font.weight: Typography.wStrong }
                            Icon { name: "check"; size: 13 * root.s; visible: card.chosen; anchors.verticalCenter: parent.verticalCenter; color: card.acc.accent }
                            Text {
                                text: card.chosen ? "Active" : card.pending ? Modes.statusText : card.modelData.id === Modes.mode && root.trouble ? (Modes.state === "error" ? "Could not apply" : Modes.statusText) : ""
                                color: card.modelData.id === Modes.mode && root.trouble ? Theme.dangerText : card.acc.text
                                font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                            }
                        }
                        Text {
                            // F2d: cuántos de sus efectos no se aplicarían aquí (el detalle dice cuáles)
                            readonly property int wont: Object.keys(Modes.wontApply(card.modelData.id)).length
                            // etapa A: con ancho y recorte (antes desbordaba la tarjeta: «1 won't apply he…»)
                            // 2026-11-12: dos renglones, partidos entre « · » («3 won't apply here» no se corta)
                            width: parent.width; elide: Text.ElideRight; wrapMode: Text.WordWrap; maximumLineCount: 2
                            text: TextWrap.keepSegments(card.modelData.caption + (wont > 0 ? " · " + wont + " won't apply here" : ""))
                            color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: Typography.label * root.s
                        }
                    }
                    ProgressTrack {
                        visible: card.pending
                        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                        anchors.margins: 8 * root.s
                        height: 2 * root.s; s: root.s; radius: 0; trackColor: Theme.hair
                        value: root.progress && root.progress.total ? root.progress.done / root.progress.total : 0
                    }
                    MouseArea {
                        id: mouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onEntered: root.hovered = card.index
                        onExited: if (root.hovered === card.index) root.hovered = -1
                        onClicked: root.choose(card.index)
                    }
                }
            }
        }
        Column {
            width: parent.width
            spacing: 5 * root.s
            // el detalle, con el color del modo que describe
            palette.accent: Theme.zone(Zones.of(root.detailMode))
            Text {
                text: root.detailCard.name + " · " + (root.detailMode === Modes.mode || root.progress && root.progress.mode === root.detailMode ? Modes.statusText : "What changes")
                color: Theme.fg; font.family: Typography.ui; font.pixelSize: Typography.body * root.s; font.weight: Typography.wStrong
            }
            Text {
                width: parent.width; wrapMode: Text.WordWrap
                text: root.detailMode === "normal" ? "Restore the session from before the mode; manual changes stay."
                    : root.detailMode === "focus" ? "Idle lock stays on; energy and effects are unchanged."
                    : root.detailMode === "cinema" ? "Energy, blur and animations unchanged; volume and brightness stay yours."
                    : "Volume and brightness stay yours; manual changes win on return."
                color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: Typography.label * root.s
            }
            Text {
                visible: Modes.busy && root.progress !== null
                text: root.progress ? (root.progress.stage === "read" ? "Checking effects" : "Verifying effects") + " · " + root.progress.done + " / " + root.progress.total : ""
                color: Theme.fam(palette.accent).text; font.family: Typography.ui; font.pixelSize: Typography.label * root.s
            }
            GridLayout {
                width: parent.width
                columns: 2; columnSpacing: 14 * root.s; rowSpacing: 4 * root.s
                Repeater {
                    model: root.detailRows
                    delegate: Column {
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.preferredWidth: (content.width - 14 * root.s) / 2
                        Layout.alignment: Qt.AlignTop
                        Item {
                            width: parent.width
                            implicitHeight: effectText.implicitHeight
                            Accessible.role: Accessible.StaticText
                            Accessible.name: modelData.label + ". " + modelData.value + ". " + modelData.status
                            Text {
                                id: effectText
                                width: parent.width - (modelData.status === "Verified" ? 16 * root.s : 0)
                                wrapMode: Text.WordWrap
                                text: modelData.label + " · " + (modelData.status === "Kept your change" ? modelData.status : modelData.value)
                                color: Theme.fg; font.family: Typography.ui; font.pixelSize: Typography.label * root.s
                            }
                            Icon {
                                anchors.right: parent.right; anchors.top: parent.top
                                visible: modelData.status === "Verified"
                                name: "check"; size: 12 * root.s; color: Theme.fam(palette.accent).accent
                            }
                        }
                        Text {
                            width: parent.width; wrapMode: Text.WordWrap
                            visible: modelData.status !== "" && modelData.status !== "Kept your change" && modelData.status !== "Verified"
                            text: modelData.status; color: modelData.warning ? Theme.errorColor : Theme.fgVariant
                            font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                        }
                    }
                }
            }
        }
        Text {
            width: parent.width; wrapMode: Text.WordWrap
            visible: Modes.state === "error"
            text: Modes.statusText; color: Theme.errorColor; font.family: Typography.ui; font.pixelSize: Typography.label * root.s
        }
        Row {
            id: buttons
            visible: root.actions.length > 0
            spacing: 8 * root.s
            Repeater {
                model: root.actions
                delegate: ActionButton {
                    required property string modelData
                    required property int index
                    s: root.s; label: modelData; glyph: index === 0 && root.trouble ? "reload" : "monitor"
                    enabled: !Modes.busy && Modes.loaded
                    focused: root.section === "modeActions" && root.action === index
                    onTriggered: { root.action = index; root.navigate("modeActions"); root.activateAction(); }
                }
            }
        }
        Rectangle { width: parent.width; height: 1; color: Theme.hair }
        Column {
            id: energy
            width: parent.width
            spacing: 6 * root.s
            Text {
                objectName: "batteryPerformance"
                width: parent.width; visible: Battery.present; wrapMode: Text.WordWrap
                text: Battery.description
                color: Battery.low ? Theme.danger : Theme.fgVariant
                font.family: Typography.ui; font.pixelSize: Typography.label * root.s
            }
            Rectangle {
                width: parent.width; height: energyRow.implicitHeight + 8 * root.s
                color: "transparent"; radius: Metrics.r(6) * root.s
                border.width: root.section === "profile" ? Metrics.focusWidth * root.s : 0
                border.color: Theme.selBorder
                Row {
                    id: energyRow
                    anchors.left: parent.left; anchors.leftMargin: 6 * root.s; anchors.verticalCenter: parent.verticalCenter
                    spacing: 14 * root.s
                    Text { text: "Power profile"; anchors.verticalCenter: parent.verticalCenter; color: Theme.fg; font.family: Typography.ui; font.pixelSize: Typography.body * root.s; font.weight: Typography.wStrong }
                    Choice {
                        id: profile
                        s: root.s; name: "Power profile"
                        visible: root.power.checked && root.power.present
                        enabled: !Modes.testing && !Modes.busy
                        focused: root.section === "profile"
                        options: (root.power.available || []).map(n => ({label: n, value: n}))
                        value: root.power.shown || ""
                        onPicked: v => { root.navigate("profile"); if (!Modes.testing && !Modes.busy) PowerProfile.setProfile(String(v)); }
                    }
                }
            }
            Text {
                width: parent.width; visible: text.length > 0; wrapMode: Text.WordWrap
                text: root.powerNote; color: root.power.error ? Theme.errorColor : Theme.fgVariant
                font.family: Typography.ui; font.pixelSize: Typography.label * root.s
            }
        }
        Rectangle { width: parent.width; height: 1; color: Theme.hair }
        Row {
            spacing: 8 * root.s
            ActionButton {
                id: monitorButton
                s: root.s; label: "Open System Monitor"; glyph: "gauge"
                focused: root.section === "monitor"
                onTriggered: { root.navigate("monitor"); root.monitor(); }
            }
        }
    }
}
