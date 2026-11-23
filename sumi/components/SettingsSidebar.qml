pragma ComponentBehavior: Bound
import QtQuick
import "../theme"
import "../lib/accent-zones.js" as Zones

/** Índice por grupos. Sólo las páginas del grupo desplegado reciben entrada. */
Item {
    id: side
    property real s: 1
    required property var groups
    property string expandedGroup: ""
    property string currentKey: ""
    property string focusKey: ""
    property string hint: ""
    implicitHeight: column.implicitHeight + foot.implicitHeight + 6 * side.s
    signal activated(string key)

    function reveal(item) {
        if (!side.visible || !item) return;
        const y = item.mapToItem(column, 0, 0).y;
        const maxY = Math.max(0, flick.contentHeight - flick.height);
        if (y < flick.contentY) flick.contentY = Math.min(maxY, Math.max(0, y));
        else if (y + item.height > flick.contentY + flick.height)
            flick.contentY = Math.min(maxY, y + item.height - flick.height);
    }

    function revealSelection() {
        const item = side.itemFor(side.focusKey || side.currentKey);
        side.reveal(item);
    }
    function itemFor(key) {
        for (let i = 0; i < groupRep.count; i++) {
            const group = groupRep.itemAt(i);
            if (!group) continue;
            if (group.modelData.id === key) return group.headerItem;
            if (!group.open) continue;
            for (let j = 0; j < group.pages.count; j++) {
                const page = group.pages.itemAt(j);
                if (page && page.modelData.key === key) return page;
            }
        }
        return null;
    }
    onFocusKeyChanged: if (side.focusKey) Qt.callLater(side.revealSelection)
    onCurrentKeyChanged: Qt.callLater(side.revealSelection)
    onVisibleChanged: if (side.visible) Qt.callLater(side.revealSelection)

    /** Diagnóstico del índice en coordenadas de la barra. */
    function layoutInfo() {
        const entries = [];
        function add(key, item) {
            const y = item.mapToItem(flick, 0, 0).y;
            entries.push({key: key, y: Math.round(y), h: Math.round(item.height),
                          visible: y >= -1 && y + item.height <= flick.height + 1});
        }
        for (let i = 0; i < groupRep.count; i++) {
            const group = groupRep.itemAt(i);
            if (!group) continue;
            add(group.modelData.id, group.headerItem);
            if (group.open) for (let j = 0; j < group.pages.count; j++) {
                const page = group.pages.itemAt(j);
                if (page) add(page.modelData.key, page);
            }
        }
        return {w: Math.round(side.width), h: Math.round(flick.height), contentY: Math.round(flick.contentY),
                contentH: Math.round(flick.contentHeight), entries: entries};
    }

    Flickable {
        id: flick
        anchors { left: parent.left; right: parent.right; top: parent.top; bottom: foot.top }
        anchors.bottomMargin: 6 * side.s
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        interactive: contentHeight > height + 1
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: column
            width: flick.width - sideHint.reserve
            spacing: 3 * side.s
            Repeater {
                id: groupRep
                model: side.groups
                delegate: Column {
                    id: group
                    required property var modelData
                    readonly property bool open: side.expandedGroup === modelData.id
                    readonly property alias headerItem: header
                    readonly property alias pages: pageRep
                    width: column.width
                    palette.accent: Theme.zone(Zones.group(modelData.id))

                    SettingsNavRow {
                        id: header
                        width: parent.width
                        s: side.s
                        label: group.modelData.title
                        glyph: group.modelData.glyph
                        expanded: group.open
                        selected: !group.open && group.modelData.pages.some(p => p.key === side.currentKey)
                        focused: side.focusKey === group.modelData.id
                        onActivated: side.activated(group.modelData.id)
                    }
                    Item {
                        width: parent.width
                        height: group.open ? pagesColumn.implicitHeight : 0
                        clip: true
                        enabled: group.open
                        visible: height > 0
                        Behavior on height {
                            enabled: side.visible && !Motion.still
                            NumberAnimation {
                                id: unfold
                                duration: Motion.fast
                                easing.type: Easing.OutCubic
                                onRunningChanged: if (!running) Qt.callLater(side.revealSelection)
                            }
                        }
                        Connections {
                            target: Motion
                            function onModeChanged() { if (Motion.still && unfold.running) unfold.complete(); }
                        }
                        Column {
                            id: pagesColumn
                            x: 8 * side.s
                            width: parent.width - x
                            Repeater {
                                id: pageRep
                                model: group.modelData.pages
                                delegate: SettingsNavRow {
                                    id: page
                                    required property var modelData
                                    width: pagesColumn.width
                                    s: side.s
                                    label: modelData.label
                                    selected: side.currentKey === modelData.key
                                    focused: group.open && side.focusKey === modelData.key
                                    Accessible.ignored: !group.open
                                    onActivated: side.activated(modelData.key)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    ScrollHint { id: sideHint; view: flick; s: side.s; inside: true }
    Text {
        id: foot
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        leftPadding: 10 * side.s
        lineHeight: 1.15
        wrapMode: Text.WordWrap
        text: side.hint
        color: Theme.outlineText
        font.family: Typography.ui
        font.pixelSize: Typography.micro * side.s
    }
}
