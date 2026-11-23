pragma ComponentBehavior: Bound
import QtQuick
import "../theme"
import "../services"

// T4: Settings → Theme → Typography → Other apps. Cada destino tiene su interruptor (apagados por defecto);
// el plan se ve antes de escribir nada y «Sync selected» aplica SÓLO lo encendido y sólo si el plan sigue vigente.
// Zen y Firefox: información, nunca se escriben. Sin componentes en línea (la recarga en caliente no los admite).
FocusScope {
    id: root
    property real s: 1
    property bool open: false
    property int current: 0
    signal finished()
    visible: open
    enabled: open
    focus: open

    readonly property var toggles: [
        { prop: "fontSyncGtkInterface", slot: "gtk.interface", label: "GTK 3 interface font" },
        { prop: "fontSyncGtkMonospace", slot: "gtk.monospace", label: "GTK 3 monospace font" },
        { prop: "fontSyncGtk4Interface", slot: "gtk4.interface", label: "GTK 4 interface font (settings.ini)" },
        { prop: "fontSyncQt6Interface", slot: "qt6.interface", label: "Qt 6 interface font (qt6ct)" },
        { prop: "fontSyncQt6Fixed", slot: "qt6.fixed", label: "Qt 6 fixed font (qt6ct)" },
        { prop: "fontSyncKitty", slot: "kitty.terminal", label: "kitty" },
        { prop: "fontSyncKittyReload", slot: "", label: "Reload open kitty windows" },
        { prop: "fontSyncVscodium", slot: "vscodium.editor", label: "VSCodium editor" },
        { prop: "fontSyncQt5Interface", slot: "qt5.interface", label: "Qt 5 interface font (qt5ct)" },
        { prop: "fontSyncQt5Fixed", slot: "qt5.fixed", label: "Qt 5 fixed font (qt5ct)" }
    ]
    readonly property var buttons: ["preview", "sync", "undoLast", "undoAll", "close"]
    readonly property int count: toggles.length + buttons.length

    function begin() {
        FontSync.beginDraft();
        open = true; current = 0;
        scroll.contentY = 0;
        FontSync.refreshStatus();
        FontSync.preview();
        forceActiveFocus();
    }
    onOpenChanged: if (!open) { previewSoon.stop(); FontSync.discardDraft(); }
    function close() { open = false; finished(); }
    function toggle(i) {
        const t = root.toggles[i];
        if (!t || !Settings.writable) return;
        FontSync.toggle(t.prop);
        previewSoon.restart();
    }
    function press(name) {
        if (name === "preview") FontSync.preview(true);
        else if (name === "sync") FontSync.apply();
        else if (name === "undoLast") FontSync.undoLast();
        else if (name === "undoAll") FontSync.undoAll();
        else if (name === "close") root.close();
    }
    function activate(i) {
        if (i < root.toggles.length) root.toggle(i);
        else root.press(root.buttons[i - root.toggles.length]);
    }
    function handleKey(event) {
        if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true; return; }
        if ([Qt.Key_Tab, Qt.Key_Backtab, Qt.Key_Up, Qt.Key_Down].indexOf(event.key) >= 0) {
            const back = event.key === Qt.Key_Backtab || event.key === Qt.Key_Up || (event.modifiers & Qt.ShiftModifier);
            root.current = (root.current + (back ? root.count - 1 : 1)) % root.count;
            root.reveal(); event.accepted = true; return;
        }
        if ([Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space, Qt.Key_Left, Qt.Key_Right].indexOf(event.key) >= 0) {
            if (!event.isAutoRepeat) root.activate(root.current);
            event.accepted = true;
        }
    }
    function reveal() {
        if (root.current >= root.toggles.length) return;
        const item = rows.itemAt(root.current);
        if (!item) return;
        const y = item.mapToItem(content, 0, 0).y;
        if (y < scroll.contentY) scroll.contentY = y;
        else if (y + item.height > scroll.contentY + scroll.height)
            scroll.contentY = Math.max(0, y + item.height - scroll.height);
    }
    function buttonReason(name) {
        if (name === "close") return "";
        if (FontSync.busy) return "Working…";
        if (name === "sync" && !FontSync.draftValid) return "Saved targets changed: cancel and reopen";
        if (name === "sync" && FontSync.plan && FontSync.plan.ok !== true)
            return FontSync.plan.reason || "Preview could not be checked";
        if (name === "sync") return !Settings.writable ? "Settings are read-only"
            : FontSync.draftDirty && FontSync.fresh ? "" : FontSync.targets.length === 0 ? "Turn on at least one app"
            : !FontSync.fresh ? "Preview the changes first" : FontSync.changes === 0 ? "Nothing to change" : "";
        if (name === "undoLast" || name === "undoAll") return FontSync.canUndo ? "" : "Nothing synced";
        return "";
    }
    Timer { id: previewSoon; interval: 250; onTriggered: if (root.open) FontSync.preview(true) }
    Keys.onPressed: event => root.handleKey(event)

    Rectangle { anchors.fill: parent; color: Theme.surfaceContainer }
    MouseArea { anchors.fill: parent }          // los clics no llegan al Settings de detrás
    Flickable {
        id: scroll
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: statusLine.top
        anchors.margins: 12 * root.s
        clip: true
        contentWidth: width
        contentHeight: content.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        Column {
            id: content
            width: scroll.width
            spacing: 8 * root.s
            Text {
                width: parent.width; text: "Fonts in other apps"
                color: Theme.fg; font.family: Typography.ui; font.pixelSize: Typography.title * root.s
                font.weight: Typography.wStrong
            }
            Text {
                width: parent.width; wrapMode: Text.Wrap
                text: "Turn on the apps that should follow your font, then press Apply selected. Only the family "
                    + "changes; Undo restores it. Open apps may need reopening."
                color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: Typography.label * root.s
            }
            Repeater {
                id: rows
                model: root.toggles
                delegate: Rectangle {
                    id: row
                    required property var modelData
                    required property int index
                    readonly property bool on: FontSync.selected(row.modelData.prop)
                    width: content.width
                    implicitHeight: col.implicitHeight + 12 * root.s
                    radius: Metrics.r(8) * root.s
                    color: root.current === row.index ? Theme.hoverBg : "transparent"
                    border.width: root.current === row.index ? 1 : 0
                    border.color: Theme.primary
                    Accessible.role: Accessible.CheckBox
                    Accessible.name: row.modelData.label
                    Accessible.checked: row.on
                    Column {
                        id: col
                        x: 10 * root.s; y: 6 * root.s
                        width: parent.width - 20 * root.s
                        spacing: 2 * root.s
                        Text {
                            width: parent.width; wrapMode: Text.Wrap
                            text: row.modelData.label + " · " + (row.on ? "On" : "Off")
                            color: Theme.fg; font.family: Typography.ui; font.pixelSize: Typography.body * root.s
                            font.weight: row.on ? Typography.wStrong : Typography.wNormal
                        }
                        Text {
                            width: parent.width; wrapMode: Text.Wrap
                            visible: text.length > 0
                            text: row.modelData.slot.length ? FontSync.describe(row.modelData.slot)
                                : "Reloads open kitty windows (resets zoom)"
                            color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: Typography.label * root.s
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { root.current = row.index; root.toggle(row.index); }
                    }
                }
            }
            Text {
                width: parent.width; wrapMode: Text.Wrap
                visible: text.length > 0
                text: {
                    const p = FontSync.plan;
                    if (!p) return "";
                    const notes = [];
                    for (const sl of (p.slots || []))
                        if (sl.action === "change" || sl.action === "restore")
                            for (const n of (sl.notes || [])) {
                                // las notas generales (GTK 4, recarga) una sola vez; las propias, con su destino
                                const generic = /^GTK 3 apps only|^Open kitty windows|^GTK 4 apps read|^nwg-look/.test(n);
                                const line = generic ? n : sl.label + ": " + n;
                                if (notes.indexOf(line) < 0) notes.push(line);
                            }
                    return notes.join("\n");
                }
                color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: Typography.label * root.s
            }
            Text {
                width: parent.width; wrapMode: Text.Wrap
                visible: text.length > 0
                text: {
                    const p = FontSync.plan;
                    if (!p) return "";
                    return (p.browsers || []).filter(b => b.installed || (b.profiles || []).length > 0)
                        .map(b => b.label + " (not synced): " + b.steps).join("\n");
                }
                color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: Typography.label * root.s
            }
        }
    }
    // Lo último que pasó (o por qué no), SIEMPRE a la vista encima de los botones: no dentro del desplazable.
    Text {
        id: statusLine
        objectName: "syncStatusLine"
        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: actions.top
        anchors.leftMargin: 12 * root.s; anchors.rightMargin: 12 * root.s; anchors.bottomMargin: 4 * root.s
        wrapMode: Text.Wrap
        maximumLineCount: 3
        elide: Text.ElideRight
        text: !FontSync.draftValid ? FontSync.summary
            : FontSync.error.length && !FontSync.lastLine.length ? FontSync.error
            : FontSync.lastLine.length ? FontSync.lastLine : FontSync.summary
        color: (FontSync.lastBad || FontSync.error.length) ? Theme.errorColor : Theme.fg
        font.family: Typography.ui; font.pixelSize: Typography.label * root.s
        font.weight: Typography.wMedium
        Accessible.role: Accessible.StaticText
        Accessible.name: text
    }
    Flow {
        id: actions
        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
        anchors.margins: 12 * root.s
        spacing: 10 * root.s
        Repeater {
            model: [{ id: "preview", label: "Preview" }, { id: "sync", label: "Apply selected" },
                    { id: "undoLast", label: "Undo last sync" }, { id: "undoAll", label: "Undo all" },
                    { id: "close", label: "Cancel" }]
            delegate: ActionButton {
                required property var modelData
                required property int index
                s: root.s
                label: modelData.label
                enabled: root.buttonReason(modelData.id).length === 0
                accent: modelData.id === "sync" && enabled
                focused: root.current === root.toggles.length + index
                Accessible.description: root.buttonReason(modelData.id)
                onTriggered: { root.current = root.toggles.length + index; root.press(modelData.id); }
            }
        }
    }
    ScrollHint { view: scroll; s: root.s }
}
