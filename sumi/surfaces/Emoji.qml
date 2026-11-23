pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../services"
import "../components"

/**
 * Emoji, kaomoji, symbols and Nerd Font glyphs (2026-11-17; docs/SUMI-EMOJI-2026-11-17.md).
 *
 * Four tabs over `services/Emoji` (data loaded on demand). With no query the grid shows one
 * group at a time — the chips under the tabs, «Recent» first when there is history; typing
 * searches the whole tab, in English and Spanish (CLDR keywords, accents ignored).
 *
 * Keys: ↑↓←→ move · Ctrl+←/→ tab · Tab/Shift+Tab group · ⏎ the configured action
 * (`shell.emoji.action`) · Shift+⏎ the other one · Ctrl+⏎ add to the tray · Backspace on an
 * empty query takes the last one off the tray · Esc closes. With items in the tray, ⏎ acts on
 * the whole tray. Mouse: click = ⏎, right click or Ctrl+click = add.
 *
 * Fixed sizes everywhere (no `Column` around the grid, no conditional `elide`): the morph and
 * the 0,2 px glyph shift of a relaid-out elided Text are already-paid lessons.
 */
Surface {
    id: root

    mTop: 12
    mLeft: 14
    mRight: 14
    mBottom: 12

    property string tab: Emoji.lastTab
    property string query: ""
    /** -1 = Recent; 0… = the tab's groups. Ignored while there is a query. */
    property int groupSel: 0
    property int selected: 0
    property int hovered: -1
    /** [{ tab, c, n }] waiting to be copied together. */
    property var tray: []
    /** The window that had the focus when the picker opened (`Emoji.target()`). */
    property var target: null
    property int pendingRev: 0
    property string error: ""

    readonly property bool searching: root.query.trim().length > 0
    readonly property bool loaded: Emoji.loaded(root.tab)
    readonly property string loadError: Emoji.errorOf(root.tab)
    readonly property var groupNames: { void Emoji.dataRev; return Emoji.groups(root.tab); }
    readonly property var recentItems: { void Emoji.dataRev; void Emoji.usage; return Emoji.recent(root.tab, 48); }
    readonly property bool hasRecent: root.recentItems.length > 0

    readonly property var items: {
        void Emoji.dataRev;
        if (!root.loaded) return [];
        if (root.searching) return Emoji.search(root.tab, root.query, 600);
        // Recent sólo si esta pestaña lo tiene: tras cambiar de pestaña, `groupSel` puede venir de la anterior
        if (root.groupSel < 0 && root.hasRecent) return root.recentItems;
        return Emoji.group(root.tab, Math.max(0, root.groupSel));
    }
    readonly property int count: root.items.length

    /** Representative glyphs for the emoji groups, in the order of `emoji.json`. */
    readonly property var emojiGroupGlyphs: ["😀", "👋", "🐻", "🍔", "✈️", "⚽", "💡", "🔣", "🏳️"]
    /** Noto Color Emoji is what tools/emoji/build-data.py checked coverage against. */
    readonly property string emojiFamily: "Noto Color Emoji"
    function familyOf(tab) {
        if (tab === "emoji") return root.emojiFamily;
        if (tab === "nerdfont") return Typography.icons;
        if (tab === "symbols") return Typography.mono;
        return Typography.ui;
    }

    readonly property bool wide: root.tab === "kaomoji"
    readonly property real cellH: (root.wide ? 40 : 42) * root.s
    readonly property int columns: root.wide ? 3 : Math.max(1, Math.floor(grid.width / (42 * root.s)))
    readonly property real cellW: Math.floor(grid.width / root.columns)

    readonly property string claimKey: root.screenName.length > 0 ? "emoji@" + root.screenName : ""
    Claim { target: Emoji; key: root.claimKey; value: root.active }

    onTabChanged: {
        Emoji.want(root.tab);
        Emoji.rememberTab(root.tab);
        root.resetGroup();
        root.selected = 0;
        root.error = "";
    }
    onQueryChanged: { root.selected = 0; root.error = ""; }
    onGroupSelChanged: { root.selected = 0; grid.positionViewAtBeginning(); }
    onLoadedChanged: if (root.loaded && root.active) root.resetGroup()

    onActiveChanged: {
        if (root.active) {
            // Antes que nada: la ventana de antes, para «pegar» en ella (la capa no cambia la ventana activa).
            root.target = Emoji.target();
            root.tab = Emoji.lastTab;
            Emoji.want(root.tab);
            search.clear();
            root.query = "";
            root.tray = [];
            root.pendingRev = 0;
            root.error = "";
            root.resetGroup();
            root.selected = 0;
            if (root.engaged) Qt.callLater(search.focusField);
        }
    }
    onEngagedChanged: if (root.active && root.engaged) Qt.callLater(search.focusField)

    /**
     * Recent si la pestaña tiene historial, si no el primer grupo. Pregunta a `Emoji` por la pestaña
     * de AHORA: dentro de `onTabChanged`, `hasRecent` aún es el de la anterior (banco, 2026-11-17).
     */
    function resetGroup() { root.groupSel = Emoji.recent(root.tab, 1).length > 0 ? -1 : 0; }

    function setTab(i) {
        const n = Emoji.tabs.length;
        root.tab = Emoji.tabs[((i % n) + n) % n].key;
    }
    function stepTab(d) { root.setTab(Emoji.tabIndex(root.tab) + d); }

    /** Tab / Shift+Tab: the next group chip (Recent included); typing hides the chips. */
    function stepGroup(d) {
        if (root.searching) return;
        const first = root.hasRecent ? -1 : 0;
        const last = root.groupNames.length - 1;
        let g = root.groupSel + d;
        if (g > last) g = first;
        if (g < first) g = last;
        root.groupSel = g;
    }

    function move(delta) {
        if (root.count === 0) return;
        root.selected = Math.max(0, Math.min(root.count - 1, root.selected + delta));
        grid.positionViewAtIndex(root.selected, GridView.Contain);
    }

    function current() {
        const i = root.hovered >= 0 ? root.hovered : root.selected;
        return root.items[i] || null;
    }

    function addToTray(e) {
        if (!e) return;
        root.tray = root.tray.concat([{ tab: root.tab, c: e.c, n: e.n }]);
    }
    function popTray() {
        if (root.tray.length > 0) root.tray = root.tray.slice(0, root.tray.length - 1);
    }

    /** ⏎: the tray if it has something, else the selected cell. `invert`: Shift. */
    function activate(invert) {
        if (root.pendingRev > 0) return;
        let picks = root.tray;
        if (picks.length === 0) {
            const e = root.items[root.selected];
            if (!e) return;
            picks = [{ tab: root.tab, c: e.c }];
        }
        root.error = "";
        const r = Emoji.pick(picks, Emoji.actionFor(invert), root.target);
        if (r > 0) root.pendingRev = r;
    }
    Connections {
        target: Emoji
        function onSettled(rev, ok, reason) {
            if (rev !== root.pendingRev) return;
            root.pendingRev = 0;
            if (ok) { root.tray = []; root.requestClose(); }
            else root.error = reason;
        }
    }

    function accept(mods) {
        if (mods & Qt.ControlModifier) root.addToTray(root.items[root.selected]);
        else root.activate((mods & Qt.ShiftModifier) !== 0);
    }

    /**
     * Lo que el campo no se queda (sin foco en él: vista previa fijada con un clic) y las teclas
     * de prueba del IPC (`keyTest`, `emojiKey`), que entran por aquí: el mismo mapa que el campo.
     */
    function keyPressed(event) {
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        switch (event.key) {
        case Qt.Key_Up: root.move(-root.columns); break;
        case Qt.Key_Down: root.move(root.columns); break;
        case Qt.Key_Left: if (ctrl) root.stepTab(-1); else root.move(-1); break;
        case Qt.Key_Right: if (ctrl) root.stepTab(1); else root.move(1); break;
        case Qt.Key_Tab: root.stepGroup(1); break;
        case Qt.Key_Backtab: root.stepGroup(-1); break;
        case Qt.Key_Return:
        case Qt.Key_Enter: root.accept(event.modifiers); break;
        case Qt.Key_Backspace: if (root.query.length === 0) root.popTray(); else return; break;
        default: return;
        }
        event.accepted = true;
    }

    // ---- historial (fase 4): pestaña, consulta y grupo; nunca lo copiado -------------------------
    function saveContext() { return { tab: root.tab, query: root.query, group: root.groupSel }; }
    function restoreContext(ctx) {
        if (!ctx) return true;
        if (Emoji.tabIndex(ctx.tab) >= 0) root.tab = ctx.tab;
        search.text = ctx.query || "";
        if (typeof ctx.group === "number") root.groupSel = ctx.group;
        return true;
    }

    /** Banco: el estado sin abrir nada más (verbo IPC `emojiState`). */
    function state() {
        const e = root.items[root.selected];
        return { tab: root.tab, query: root.query, group: root.groupSel, groups: root.groupNames.length,
                 recent: root.recentItems.length, count: root.count, selected: root.selected,
                 columns: root.columns, current: e ? { c: e.c, n: e.n } : null,
                 tray: root.tray.map(function (t) { return t.c; }), loaded: root.loaded,
                 error: root.error || root.loadError, target: root.target,
                 action: Emoji.actionFor(false) };
    }
    function setQuery(q) { search.text = String(q || ""); }

    // ---- header ---------------------------------------------------------------------------------

    Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 24 * root.s

        Icon {
            id: searchIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            name: "search"
            size: 14 * root.s
            color: Theme.fgVariant
        }

        SearchField {
            id: search
            anchors.left: searchIcon.right
            anchors.leftMargin: 9 * root.s
            anchors.right: countLabel.left
            anchors.rightMargin: 10 * root.s
            anchors.verticalCenter: parent.verticalCenter
            height: parent.height
            s: root.s
            placeholder: root.tab === "emoji" ? "Search emoji · English or Spanish"
                : root.tab === "kaomoji" ? "Search kaomoji"
                : root.tab === "symbols" ? "Search symbols" : "Search Nerd Font glyphs"
            gridKeys: true
            stepping: true
            backtabs: true
            onTextChanged: root.query = search.text
            onMoved: (d) => root.move(d * root.columns)
            onSideMoved: (d) => root.move(d)
            onStepped: (d) => root.stepTab(d)
            onTabbed: root.stepGroup(1)
            onBacktabbed: root.stepGroup(-1)
            onEmptyBackspace: root.popTray()
            onAccepted: (mods) => root.accept(mods)
            onDismissed: root.requestClose()
        }

        FrameNav {
            id: frameNav
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            s: root.s
            host: root.host
            onCloseRequested: root.requestClose()
        }

        Text {
            id: countLabel
            anchors.right: frameNav.left
            anchors.rightMargin: 8 * root.s
            anchors.verticalCenter: parent.verticalCenter
            width: 44 * root.s
            horizontalAlignment: Text.AlignRight
            text: root.loaded ? String(root.count) : ""
            color: Theme.outlineText
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
            font.features: ({ "tnum": 1 })
        }
    }

    // ---- tabs and groups ------------------------------------------------------------------------

    Choice {
        id: tabs
        anchors.top: header.bottom
        anchors.topMargin: 8 * root.s
        anchors.left: parent.left
        s: root.s
        forcePills: true
        name: "Kind"
        availableWidth: parent.width
        options: Emoji.tabs.map(function (t) { return { label: t.title, value: t.key }; })
        value: root.tab
        onPicked: (v) => { root.tab = v; Qt.callLater(search.focusField); }
    }

    ListView {
        id: chips
        anchors.top: tabs.bottom
        anchors.topMargin: 6 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        height: 26 * root.s
        orientation: ListView.Horizontal
        spacing: 4 * root.s
        clip: true
        visible: !root.searching && root.loaded
        boundsBehavior: Flickable.StopAtBounds
        model: (root.hasRecent ? ["Recent"] : []).concat(root.groupNames)
        currentIndex: root.groupSel + (root.hasRecent ? 1 : 0)
        highlightFollowsCurrentItem: false
        onCurrentIndexChanged: chips.positionViewAtIndex(chips.currentIndex, ListView.Contain)

        delegate: Item {
            id: chip
            required property int index
            required property string modelData
            readonly property int group: chip.index - (root.hasRecent ? 1 : 0)
            readonly property bool current: chip.group === root.groupSel
            readonly property bool glyphOnly: root.tab === "emoji" && chip.group >= 0
            width: chip.glyphOnly ? 30 * root.s : chipText.implicitWidth + 18 * root.s
            height: chips.height

            Accessible.role: Accessible.PageTab
            Accessible.name: chip.modelData
            Accessible.selected: chip.current

            Rectangle {
                anchors.fill: parent
                radius: Metrics.pill(height)
                color: chip.current ? Theme.selBg : (chipArea.containsMouse ? Theme.hoverBg : "transparent")
                border.width: chip.current ? 1 : 0
                border.color: Theme.hair
            }
            Text {
                id: chipText
                anchors.centerIn: parent
                text: chip.glyphOnly ? (root.emojiGroupGlyphs[chip.group] || "•") : chip.modelData
                color: chip.current ? Theme.fg : Theme.fgVariant
                font.family: chip.glyphOnly ? root.emojiFamily : Typography.ui
                font.pixelSize: (chip.glyphOnly ? 15 : Typography.caption) * root.s
            }
            MouseArea {
                id: chipArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.groupSel = chip.group; search.focusField(); }
            }
        }
    }

    Text {
        id: resultsLabel
        anchors.verticalCenter: chips.verticalCenter
        anchors.left: parent.left
        width: parent.width
        visible: root.searching
        text: root.count === 0 ? "" : (root.count >= 600 ? "600+" : String(root.count)) + " results"
        color: Theme.outlineText
        font.family: Typography.ui
        font.pixelSize: Typography.caption * root.s
    }

    Rectangle {
        id: hair
        anchors.top: chips.bottom
        anchors.topMargin: 6 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: Theme.hair
    }

    // ---- the grid -------------------------------------------------------------------------------

    Empty {
        y: hair.y + hair.height + Math.max(Metrics.sp5 * root.s, (footer.y - hair.y - hair.height - height) * 0.42)
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.count === 0
        s: root.s
        maxWidth: parent.width
        loading: !root.loaded && root.loadError.length === 0
        glyph: root.loadError.length > 0 ? "alert" : "search"
        text: root.loadError.length > 0 ? root.loadError
            : !root.loaded ? "Loading…"
            : root.searching ? "No results" : "Nothing here yet"
        hint: root.loadError.length > 0 ? "Reinstall the shell, or run tools/emoji/build-data.py"
            : root.searching && root.tab === "emoji" ? "Try another word, in English or Spanish" : ""
    }

    GridView {
        id: grid
        anchors.top: hair.bottom
        anchors.topMargin: 4 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        anchors.bottomMargin: 6 * root.s
        visible: root.count > 0
        clip: true
        model: root.items
        cellWidth: root.cellW
        cellHeight: root.cellH
        currentIndex: root.selected
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: 0

        delegate: Item {
            id: cell
            required property int index
            required property var modelData
            width: grid.cellWidth
            height: grid.cellHeight
            readonly property bool current: cell.index === root.selected

            Accessible.role: Accessible.ListItem
            Accessible.name: String(cell.modelData.n || "")
            Accessible.selected: cell.current
            Accessible.onPressAction: { root.selected = cell.index; root.activate(false); }

            Rectangle {
                anchors.fill: parent
                anchors.margins: 2 * root.s
                radius: Metrics.r(8) * root.s
                color: cell.current ? Theme.selBg : (cellArea.containsMouse ? Theme.hoverBg : "transparent")
                border.width: cell.current ? 1 : 0
                border.color: Theme.primary
            }
            Text {
                anchors.fill: parent
                anchors.leftMargin: 6 * root.s
                anchors.rightMargin: 6 * root.s
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: cell.modelData.c
                elide: Text.ElideRight
                color: cell.current ? Theme.fg : Theme.fgVariant
                font.family: root.familyOf(root.tab)
                font.pixelSize: (root.wide ? Typography.label : root.tab === "emoji" ? 22 : 20) * root.s
            }
            MouseArea {
                id: cellArea
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: root.hovered = cellArea.containsMouse ? cell.index
                    : (root.hovered === cell.index ? -1 : root.hovered)
                onClicked: (m) => {
                    root.selected = cell.index;
                    if (m.button === Qt.RightButton || (m.modifiers & Qt.ControlModifier)) root.addToTray(cell.modelData);
                    else root.activate((m.modifiers & Qt.ShiftModifier) !== 0);
                    search.focusField();
                }
            }
        }
    }

    ScrollHint { view: grid; s: root.s }

    // ---- footer: preview, tray, hints or the error ----------------------------------------------

    Item {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 36 * root.s

        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: Theme.hair
        }

        Notice {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.error.length > 0
            s: root.s
            tone: "danger"
            text: root.error + " · Enter retries"
        }

        // izquierda: la bandeja (si hay) o la vista previa de la celda elegida / bajo el puntero
        Item {
            id: footLeft
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.topMargin: 1
            width: parent.width - hints.width - 10 * root.s
            visible: root.error.length === 0

            Text {
                id: preview
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: root.tray.length > 0 ? 0 : (root.wide ? 0 : 30 * root.s)
                visible: root.tray.length === 0 && !root.wide
                horizontalAlignment: Text.AlignHCenter
                text: { const e = root.current(); return e ? e.c : ""; }
                color: Theme.fg
                font.family: root.familyOf(root.tab)
                font.pixelSize: 20 * root.s
            }
            Text {
                anchors.left: preview.right
                anchors.leftMargin: preview.visible ? 8 * root.s : 0
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.tray.length > 0
                    ? root.tray.map(function (t) { return t.c; }).join(root.tab === "kaomoji" ? " " : "")
                    : (function () { const e = root.current(); return e ? e.n : ""; })()
                elide: Text.ElideRight
                color: root.tray.length > 0 ? Theme.fg : Theme.fgVariant
                font.family: root.tray.length > 0 ? root.familyOf(root.tab) : Typography.ui
                font.pixelSize: (root.tray.length > 0 ? Typography.body : Typography.label) * root.s
            }
        }

        Text {
            id: hints
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.error.length === 0
            text: {
                const act = Emoji.actionFor(false) === "paste" ? "Paste" : "Copy";
                const other = act === "Paste" ? "Copy" : "Paste";
                if (root.tray.length > 0) return "⏎ " + act + " " + root.tray.length + "  ·  ⌫ remove";
                return "⏎ " + act + "  ·  ⇧⏎ " + other + "  ·  Ctrl+⏎ add";
            }
            color: Theme.outlineText
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }
    }
}
