pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../services"
import "../components"

/**
 * Ventana Login screen (Sumi SDDM, 2026-11-23): el contenido de core/LoginLayer. Un cliente más de SddmTheme,
 * como Settings → Desktop tools → Login screen; los ajustes salen del esquema de `sumi-sddm`.
 *
 *   cabecera   título, ficha de estado (Applied · Not applied · Not in use · Not installed) y Apply
 *   rail       búsqueda, los grupos del esquema (punto = ajustes cambiados) y System (punto naranja = sin aplicar)
 *   centro     las filas del grupo (components/SddmField) o la página System (components/SddmSystemPanel)
 *   vista previa  components/SddmPreviewPane a ~58 % del ancho; por debajo de 980 px lógicos pasa arriba.
 *                 Clic en la imagen: la vista previa ocupa todo (Esc o clic vuelve)
 *
 * La escena sigue al grupo (SddmTheme.sceneFor) mientras no se elija una a mano (LoginUi.scenePinned).
 * Teclado: ↑↓ grupos · Tab ajustes · ←→ cambia · Enter edita · Supr vuelve al valor de serie · Ctrl+F busca ·
 * Ctrl+PgUp/PgDn grupo · Esc sale de la búsqueda, de la ampliación, de los ajustes y, al final, cierra.
 */
Item {
    id: root

    property real s: 1
    property bool open: false
    property string screenName: ""
    /** «AnchoxAlto» de este monitor en píxeles físicos (lo da la capa). */
    property string screenSize: "1920x1080"
    signal requestClose(bool back)
    /** El teclado vuelve a la tarjeta (tras editar un campo de texto). */
    signal requestFocus()

    readonly property bool narrow: root.width / root.s < 980
    property bool zoomed: false
    /** rail · content · search */
    property string zone: "rail"
    property int kbIndex: 0

    readonly property var railItems: SddmTheme.groups.map(g => ({ id: g.id, label: g.label }))
                                         .concat([{ id: "system", label: "System" }])
    readonly property string page: {
        const p = LoginUi.page;
        if (p.length > 0 && root.railItems.some(x => x.id === p)) return p;
        return SddmTheme.groups.length > 0 ? SddmTheme.groups[0].id : "system";
    }
    readonly property int railIndex: Math.max(0, root.railItems.findIndex(x => x.id === root.page))
    readonly property string query: search.text.trim().toLowerCase()
    readonly property var rows: {
        if (!SddmTheme.ready) return [];
        if (root.query.length > 0) {
            const labels = {};
            for (const g of SddmTheme.groups) labels[g.id] = g.label;
            return SddmTheme.order.filter(k => {
                const e = SddmTheme.keys[k];
                return String(e.label || k).toLowerCase().indexOf(root.query) >= 0
                    || String(e.help || "").toLowerCase().indexOf(root.query) >= 0
                    || String(k).toLowerCase().indexOf(root.query) >= 0;
            }).map(k => ({ id: "sddm:" + k, key: k, name: String(SddmTheme.keys[k].label || k),
                           group: labels[SddmTheme.keys[k].group] || "" }));
        }
        return root.page === "system" ? [] : SddmTheme.rows(root.page);
    }
    readonly property bool systemPage: root.query.length === 0 && root.page === "system"
    readonly property int rowCount: root.systemPage ? (sysLoader.item ? sysLoader.item.rowIds.length : 0) : root.rows.length
    /** La vista previa al día y pintada (bancos). */
    readonly property bool previewReady: pane.imageReady
    readonly property string effectiveSize: LoginUi.previewPick === "screen" ? root.screenSize : LoginUi.previewPick

    // ---- vida ---------------------------------------------------------------------------------------------------
    function claimNow() {
        SddmTheme.claim("loginUi", root.open);
        if (root.open) {
            SddmTheme.previewSize = root.effectiveSize;
            root.followScene();
        } else {
            root.zoomed = false;
            search.text = "";
        }
    }
    onOpenChanged: root.claimNow()
    Component.onCompleted: root.claimNow()
    Component.onDestruction: SddmTheme.claim("loginUi", false)
    onEffectiveSizeChanged: if (root.open) SddmTheme.previewSize = root.effectiveSize
    onPageChanged: { root.followScene(); root.kbIndex = 0; flick.contentY = 0; root.refreshPage(); }
    onSystemPageChanged: root.refreshPage()
    function refreshPage() {
        if (root.open && root.systemPage && SddmTheme.ready) { SddmTheme.refreshSystem(); SddmTheme.refreshLog(); }
    }
    Connections {
        target: SddmTheme
        function onReadyChanged() { root.followScene(); root.refreshPage(); root.takeFocusKey(); }
    }
    Connections {
        target: LoginUi
        function onFocusKeyChanged() { Qt.callLater(root.takeFocusKey); }
    }
    function followScene() {
        if (!LoginUi.scenePinned && SddmTheme.ready) SddmTheme.scenario = SddmTheme.sceneFor(root.page);
    }
    /** Abierta con «key:<clave>» (la búsqueda de Settings): a su fila. */
    function takeFocusKey() {
        const k = LoginUi.focusKey;
        if (!k || !SddmTheme.ready) return;
        const i = root.rows.findIndex(r => r.key === k);
        if (i < 0) return;
        LoginUi.focusKey = "";
        root.zone = "content";
        root.kbIndex = i;
        Qt.callLater(root.revealRow);
    }

    // ---- navegación -----------------------------------------------------------------------------------------------
    function goPage(i) {
        const n = root.railItems.length;
        if (n === 0) return;
        LoginUi.page = root.railItems[((i % n) + n) % n].id;
    }
    function rowItem(i) { return rowRepeater.itemAt(i); }
    function revealRow() {
        let it = null, y = 0, h = 0;
        if (root.systemPage) return;
        it = root.rowItem(root.kbIndex);
        if (!it) return;
        y = it.y + rowsCol.y; h = it.height;
        if (y < flick.contentY) flick.contentY = Math.max(0, y - 8 * root.s);
        else if (y + h > flick.contentY + flick.height)
            flick.contentY = Math.min(Math.max(0, flick.contentHeight - flick.height), y + h - flick.height + 8 * root.s);
    }
    onKbIndexChanged: Qt.callLater(root.revealRow)

    function activateRow(dir) {
        if (root.systemPage) { if (dir === 0 && sysLoader.item) sysLoader.item.activate(root.kbIndex); return; }
        const it = root.rowItem(root.kbIndex);
        if (it && it.field) it.field.activate(dir);
    }
    function resetRow() {
        if (root.systemPage) return;
        const r = root.rows[root.kbIndex];
        if (r && SddmTheme.isSet(r.key)) SddmTheme.unset(r.key);
    }

    /** Teclas desde la capa (o el banco). Lo que no usa, lo deja: Esc cierra en la capa. */
    function keyPressed(event) {
        const k = event.key, ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        if (ctrl && k === Qt.Key_F) { root.zone = "search"; search.focusField(); event.accepted = true; return; }
        if (ctrl && (k === Qt.Key_PageUp || k === Qt.Key_PageDown)) {
            search.text = "";
            root.goPage(root.railIndex + (k === Qt.Key_PageDown ? 1 : -1));
            event.accepted = true; return;
        }
        if (k === Qt.Key_Escape) {
            if (root.zoomed) { root.zoomed = false; event.accepted = true; return; }
            if (root.query.length > 0) { search.text = ""; root.zone = "rail"; event.accepted = true; return; }
            if (root.zone === "content") { root.zone = "rail"; event.accepted = true; return; }
            return;
        }
        if (k === Qt.Key_Tab || k === Qt.Key_Backtab) {
            root.zone = root.zone === "content" ? "rail" : "content";
            if (root.zone === "content") root.kbIndex = Math.min(root.kbIndex, Math.max(0, root.rowCount - 1));
            event.accepted = true; return;
        }
        if (root.zone === "rail") {
            if (k === Qt.Key_Up || k === Qt.Key_Down) {
                search.text = "";
                root.goPage(root.railIndex + (k === Qt.Key_Down ? 1 : -1));
                event.accepted = true;
            } else if (k === Qt.Key_Right || k === Qt.Key_Return || k === Qt.Key_Enter) {
                if (root.rowCount > 0) { root.zone = "content"; root.kbIndex = 0; }
                event.accepted = true;
            }
            return;
        }
        // content
        if (k === Qt.Key_Up || k === Qt.Key_Down) {
            if (root.rowCount > 0)
                root.kbIndex = Math.max(0, Math.min(root.rowCount - 1, root.kbIndex + (k === Qt.Key_Down ? 1 : -1)));
            event.accepted = true;
        } else if (k === Qt.Key_Left || k === Qt.Key_Right) {
            root.activateRow(k === Qt.Key_Right ? 1 : -1);
            event.accepted = true;
        } else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) {
            root.activateRow(0);
            event.accepted = true;
        } else if (k === Qt.Key_Delete) {
            root.resetRow();
            event.accepted = true;
        }
    }
    function saveContext() { return { page: LoginUi.page }; }
    function restoreContext(ctx) { if (ctx && ctx.page) LoginUi.page = ctx.page; }

    // ---- medidas ----------------------------------------------------------------------------------------------------
    readonly property real headH: 64 * root.s
    readonly property real pad: 16 * root.s
    readonly property real railW: (root.width / root.s < 800 ? 132 : Metrics.monSideW) * root.s
    readonly property real contentX: root.railW + 2 * root.pad
    readonly property real contentW: Math.max(0, root.width - root.contentX - root.pad)
    readonly property real footH: 30 * root.s
    readonly property real bodyY: root.headH + 1
    readonly property real bodyH: Math.max(0, root.height - root.bodyY - root.footH)
    readonly property real gap: 18 * root.s
    readonly property real paneW: root.narrow || root.zoomed ? root.contentW : Math.round(root.contentW * 0.58)
    readonly property real listW: root.zoomed ? 0 : root.narrow ? root.contentW : Math.max(0, root.contentW - root.paneW - root.gap)

    // ---- cabecera ---------------------------------------------------------------------------------------------------
    readonly property var chip: {
        if (SddmTheme.systemBusy !== "") return { text: "Waiting for your password…", tone: "warn" };
        if (!SddmTheme.ready) return { text: SddmTheme.infoText("sddmStatus"), tone: SddmTheme.status === "checking" ? "" : "error" };
        const sy = SddmTheme.system;
        if (!sy) return { text: "Checking…", tone: "" };
        if (sy.installed !== true) return { text: "Not installed", tone: "" };
        if (!sy.active) return { text: sy.inSync ? "Not in use" : "Not in use · not applied", tone: "" };
        if (!sy.inSync) return { text: "Not applied", tone: "warn" };
        return { text: "Applied", tone: "ok" };
    }
    Column {
        x: 20 * root.s
        anchors.verticalCenter: head.verticalCenter
        width: Math.max(0, chipBox.x - x - 12 * root.s)
        spacing: 2 * root.s
        Text {
            width: parent.width; elide: Text.ElideRight
            text: "Login screen"
            color: Theme.fg; font.family: Typography.ui; font.pixelSize: Typography.display * root.s
            font.weight: Typography.wStrong
        }
        Text {
            width: parent.width; elide: Text.ElideRight
            text: SddmTheme.version.length > 0 ? "Sumi SDDM " + SddmTheme.version : "Sumi SDDM"
            color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: Typography.label * root.s
        }
    }
    Item { id: head; width: root.width; height: root.headH }
    Rectangle {
        id: chipBox
        anchors.verticalCenter: head.verticalCenter
        anchors.right: applyBtn.left; anchors.rightMargin: 10 * root.s
        width: chipRow.implicitWidth + 18 * root.s
        height: chipRow.implicitHeight + 8 * root.s
        radius: Metrics.pill(height)
        color: "transparent"
        border.width: 1; border.color: Theme.hair
        Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: 6 * root.s
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 7 * root.s; height: width; radius: width / 2
                color: root.chip.tone === "ok" ? Theme.ok : root.chip.tone === "warn" ? Theme.warn
                     : root.chip.tone === "error" ? Theme.errorColor : Theme.fgVariant
            }
            Text {
                text: root.chip.text
                color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: Typography.label * root.s
            }
        }
        Accessible.role: Accessible.StaticText
        Accessible.name: "Login screen state: " + root.chip.text
    }
    ActionButton {
        id: applyBtn
        anchors.verticalCenter: head.verticalCenter
        anchors.right: closeBtn.left; anchors.rightMargin: 8 * root.s
        s: root.s
        readonly property bool synced: !!(SddmTheme.system && SddmTheme.system.installed && SddmTheme.system.inSync)
        visible: !!(SddmTheme.system && SddmTheme.system.installed === true)
        label: applyBtn.synced ? "Already applied" : "Apply"
        primary: !applyBtn.synced
        enabled: SddmTheme.reasonText("sddmApply").length === 0
        onTriggered: SddmTheme.systemApply()
    }
    ActionButton {
        id: closeBtn
        anchors.verticalCenter: head.verticalCenter
        anchors.right: parent.right; anchors.rightMargin: 14 * root.s
        s: root.s; glyph: "close"; label: "Close"
        onTriggered: root.requestClose(false)
    }
    Rectangle { y: root.headH; x: 18 * root.s; width: root.width - 36 * root.s; height: 1; color: Theme.hair }

    // ---- rail -------------------------------------------------------------------------------------------------------
    Item {
        id: rail
        x: root.pad; y: root.bodyY + 12 * root.s
        width: root.railW
        height: root.bodyH - 12 * root.s
        Rectangle {
            // el campo de búsqueda es un TextInput desnudo: su caja, como la del lanzador
            width: parent.width; height: search.height + 12 * root.s
            radius: Metrics.rSm * root.s
            color: Theme.tileBg
            border.width: search.input.activeFocus ? Metrics.focusWidth * root.s : 1
            border.color: search.input.activeFocus ? Theme.focusRing : Theme.hair
        }
        SearchField {
            id: search
            x: 10 * root.s; y: 6 * root.s
            width: parent.width - 20 * root.s
            s: root.s
            placeholder: "Search"
            onMoved: (d) => { if (root.rows.length > 0) { root.zone = "content"; root.kbIndex = 0; root.requestFocus(); } }
            onAccepted: { if (root.rows.length > 0) { root.zone = "content"; root.kbIndex = 0; } root.requestFocus(); }
            onDismissed: { search.text = ""; root.zone = "rail"; root.requestFocus(); }
            onTabbed: { root.zone = "content"; root.kbIndex = 0; root.requestFocus(); }
            Accessible.name: "Search login screen settings"
        }
        Flickable {
            id: railView
            anchors.top: search.bottom; anchors.topMargin: 16 * root.s
            anchors.bottom: hint.top; anchors.bottomMargin: 8 * root.s
            width: parent.width
            clip: true; contentWidth: width; contentHeight: railCol.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            Rectangle {
                id: railMark
                visible: root.query.length === 0
                y: root.railIndex * (38 + 2) * root.s + (root.page === "system" ? 13 * root.s : 0)
                width: parent.width; height: 38 * root.s
                radius: Metrics.rSm * root.s
                color: Qt.alpha(Theme.primary, root.zone === "rail" ? 0.2 : 0.12)
                Behavior on y { NumberAnimation { duration: Motion.still ? 0 : Motion.page; easing.type: Easing.OutCubic } }
                Rectangle {
                    x: 0; anchors.verticalCenter: parent.verticalCenter
                    width: 3 * root.s; height: parent.height * 0.5; radius: Metrics.pill(width)
                    color: Theme.primary
                }
            }
            Column {
                id: railCol
                width: parent.width
                spacing: 2 * root.s
                Repeater {
                    model: root.railItems
                    Item {
                        id: entry
                        required property var modelData
                        required property int index
                        readonly property bool current: root.query.length === 0 && root.page === entry.modelData.id
                        readonly property bool sys: entry.modelData.id === "system"
                        readonly property int custom: entry.sys ? 0 : SddmTheme.customIn(entry.modelData.id)
                        readonly property bool pendingApply: entry.sys && !!SddmTheme.system
                            && SddmTheme.system.installed === true && SddmTheme.system.inSync === false
                        width: railCol.width
                        height: 38 * root.s + (entry.sys ? 13 * root.s : 0)
                        Rectangle {
                            visible: entry.sys
                            x: 6 * root.s; y: 6 * root.s
                            width: parent.width - 12 * root.s; height: 1
                            color: Theme.hair
                        }
                        Rectangle {
                            id: entryBg
                            y: entry.sys ? 13 * root.s : 0
                            width: parent.width; height: 38 * root.s
                            radius: Metrics.rSm * root.s
                            color: !entry.current && entryArea.containsMouse ? Theme.hoverBg : "transparent"
                            Text {
                                x: 12 * root.s; anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 34 * root.s; elide: Text.ElideRight
                                text: entry.modelData.label
                                color: entry.current ? Theme.fg : Theme.fgVariant
                                font.family: Typography.ui; font.pixelSize: Typography.body * root.s
                                font.weight: entry.current ? Typography.wStrong : Typography.wNormal
                            }
                            Rectangle {
                                visible: entry.custom > 0 || entry.pendingApply
                                anchors.right: parent.right; anchors.rightMargin: 10 * root.s
                                anchors.verticalCenter: parent.verticalCenter
                                width: 6 * root.s; height: width; radius: width / 2
                                color: entry.pendingApply ? Theme.warn : Theme.primary
                            }
                            MouseArea {
                                id: entryArea
                                anchors.fill: parent
                                hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { search.text = ""; LoginUi.page = entry.modelData.id; root.zone = "rail"; root.requestFocus(); }
                            }
                        }
                        Accessible.role: Accessible.PageTab
                        Accessible.name: entry.modelData.label + (entry.custom > 0 ? ", " + entry.custom + " changed" : "")
                                         + (entry.pendingApply ? ", not applied" : "")
                        Accessible.selected: entry.current
                    }
                }
            }
        }
        Text {
            id: hint
            anchors.bottom: parent.bottom
            width: parent.width; x: 4 * root.s
            wrapMode: Text.Wrap
            text: "↑↓ groups · Tab settings\nCtrl+F search · Esc " + (LoginUi.origin ? "back" : "close")
            color: Theme.fgVariant; opacity: 0.8
            font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
        }
    }
    Rectangle {
        x: root.pad + root.railW + root.pad - 1; y: root.bodyY + 12 * root.s
        width: 1; height: root.bodyH - 12 * root.s
        color: Theme.hair
    }

    // ---- sin Sumi SDDM ----------------------------------------------------------------------------------------------
    Column {
        visible: !SddmTheme.ready
        x: root.contentX; y: root.bodyY + root.bodyH * 0.32
        width: root.contentW
        spacing: 6 * root.s
        Text {
            width: parent.width; horizontalAlignment: Text.AlignHCenter
            text: SddmTheme.status === "checking" || SddmTheme.status === "" ? "Reading…" : "Sumi SDDM is not available"
            color: Theme.fg; font.family: Typography.ui; font.pixelSize: Typography.title * root.s
        }
        Text {
            width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap
            text: SddmTheme.status === "missing" ? SddmTheme.captionText("sddmStatus") : SddmTheme.statusDetail
            color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: Typography.label * root.s
        }
    }

    // ---- ajustes ---------------------------------------------------------------------------------------------------
    Flickable {
        id: flick
        visible: SddmTheme.ready && !root.zoomed
        x: root.contentX
        y: root.narrow ? paneBox.y + paneBox.height + 14 * root.s : root.bodyY + 12 * root.s
        width: root.listW
        height: Math.max(0, root.bodyY + root.bodyH - y)
        clip: true
        contentWidth: width
        contentHeight: (root.systemPage ? sysLoader.height : rowsCol.y + rowsCol.implicitHeight) + 12 * root.s
        boundsBehavior: Flickable.StopAtBounds
        Row {
            id: pageHead
            visible: !root.systemPage
            spacing: 8 * root.s
            Text {
                id: pageTitle
                text: root.query.length > 0 ? "Search" : (root.railItems[root.railIndex] || { label: "" }).label
                color: Theme.fg; font.family: Typography.ui; font.pixelSize: Typography.title * root.s
                font.weight: Typography.wStrong
            }
            Text {
                anchors.baseline: pageTitle.baseline
                readonly property int changed: root.query.length > 0 ? 0 : SddmTheme.customIn(root.page)
                text: root.query.length > 0
                    ? (root.rows.length === 0 ? "nothing matches" : root.rows.length + (root.rows.length === 1 ? " match" : " matches"))
                    : root.rows.length + " settings" + (changed > 0 ? " · " + changed + " changed" : "")
                color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: Typography.label * root.s
            }
        }
        Column {
            id: rowsCol
            visible: !root.systemPage
            y: pageHead.height + 10 * root.s
            width: flick.width
            spacing: 8 * root.s
            Repeater {
                id: rowRepeater
                model: root.systemPage ? [] : root.rows
                SettingRow {
                    id: row
                    required property var modelData
                    required property int index
                    property alias field: sfield
                    width: rowsCol.width
                    s: root.s
                    grouped: true; sectioned: true
                    captionEssential: true
                    name: row.modelData.name
                    caption: (row.modelData.group ? row.modelData.group + " · " : "") + SddmTheme.captionFor(row.modelData.key)
                    focused: root.zone === "content" && root.kbIndex === row.index
                    custom: SddmTheme.isSet(row.modelData.key)
                    onResetRequested: SddmTheme.unset(row.modelData.key)
                    onActivated: { root.zone = "content"; root.kbIndex = row.index; sfield.activate(0); root.requestFocus(); }
                    SddmField {
                        id: sfield
                        s: root.s
                        key: row.modelData.key
                        focused: row.focused
                        availableWidth: row.controlMaxWidth
                        // en la línea del nombre (SettingRow apila lo que pasa del 46 %): filas más bajas
                        fitWidth: Math.floor(row.width * 0.45)
                        onFinished: root.requestFocus()
                    }
                }
            }
        }
        Loader {
            id: sysLoader
            active: root.systemPage
            width: flick.width
            sourceComponent: SddmSystemPanel {
                s: root.s
                focusIndex: root.zone === "content" ? root.kbIndex : -1
            }
        }
    }

    // ---- vista previa ------------------------------------------------------------------------------------------------
    Item {
        id: paneBox
        visible: SddmTheme.ready
        x: root.narrow || root.zoomed ? root.contentX : root.contentX + root.listW + root.gap
        y: root.bodyY + 12 * root.s
        width: root.paneW
        height: pane.implicitHeight
        Rectangle {
            visible: !root.narrow && !root.zoomed
            x: -root.gap / 2; y: 0
            width: 1; height: root.bodyH - 12 * root.s
            color: Theme.hair
        }
        SddmPreviewPane {
            id: pane
            width: parent.width
            s: root.s
            availableWidth: parent.width
            side: root.narrow && !root.zoomed
            zoomed: root.zoomed
            screenSize: root.screenSize
            imageMaxHeight: root.zoomed ? root.bodyH - 120 * root.s
                          : root.narrow ? Math.max(140 * root.s, root.bodyH * 0.38)
                          : root.bodyH - 150 * root.s
            onZoomToggled: root.zoomed = !root.zoomed
        }
    }

    // ---- pie: lo que pasó por última vez ----------------------------------------------------------------------------
    Text {
        x: root.contentX; y: root.bodyY + root.bodyH + (root.footH - height) / 2
        width: root.contentW - 24 * root.s
        elide: Text.ElideRight
        text: !SddmTheme.ready ? "" : SddmTheme.error.length > 0 ? SddmTheme.error
            : SddmTheme.notice.length > 0 ? SddmTheme.notice
            : SddmTheme.saving ? "Saving…" : "Changes are saved for Sumi SDDM as you make them · Apply puts them on the login screen"
        color: SddmTheme.error.length > 0 ? Theme.errorColor : Theme.fgVariant
        font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
        Accessible.role: Accessible.StaticText
        Accessible.name: text
    }
}
