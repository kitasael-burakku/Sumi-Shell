import QtQuick
import "../theme"
import "../services"
import "../components"
import "../lib/monitor.js" as Monitor

/**
 * Processes: la lista entera (Sysmon inspect, cada 2 s), buscable y ordenable, y la ficha del
 * elegido. Sólo observar: no hay acciones sobre procesos (una extensión futura con confirmación y
 * permisos, `Antes-de-fase-12.md`).
 *
 * Sin saltos: el modelo se sincroniza en su sitio (mismas filas por pid+arranque, sólo se mueven
 * las que cambian de puesto) y, mientras el puntero está sobre la lista, el ORDEN se mantiene —
 * las cifras siguen al día, las filas nuevas van al final y las terminadas se quitan.
 */
Item {
    id: root
    property real s: 1
    readonly property bool holding: listHover.hovered
    property int shownCount: 0
    property int matchCount: 0

    function focusSearch() { search.focusField(); }
    function stepSelection(delta) {
        if (model.count === 0) return;
        let i = root.keys.indexOf(MonitorUi.selectedPid + ":" + MonitorUi.selectedStart);
        i = i < 0 ? (delta > 0 ? 0 : model.count - 1) : Math.max(0, Math.min(model.count - 1, i + delta));
        const r = model.get(i);
        MonitorUi.select(r.pid, r.start);
        list.positionViewAtIndex(i, ListView.Contain);
    }

    // ---- modelo --------------------------------------------------------------------------
    ListModel { id: model }
    /** Espejo de las claves del modelo: buscar con indexOf, no con model.get() en bucle. */
    property var keys: []

    function wanted() {
        const q = MonitorUi.query.trim().toLowerCase();
        const out = [];
        let matches = 0;
        for (const r of MonitorUi.processList) {
            if (!MonitorUi.showKernel && r.kernel) continue;
            if (q && !(r.name.toLowerCase().includes(q) || (r.cmd || "").toLowerCase().includes(q)
                       || String(r.pid) === q || (r.user || "").toLowerCase() === q)) continue;
            matches++;
            out.push({key: r.key || r.pid + ":" + r.startTicks, pid: r.pid, start: r.startTicks, name: r.name,
                      cmd: r.cmd || "", user: r.user || "", kernel: !!r.kernel, state: r.state || "",
                      threads: r.threads || 0, cpu: typeof r.cpuPct === "number" ? r.cpuPct : -1,
                      mem: r.memoryB, memPct: typeof r.memoryPct === "number" ? r.memoryPct : -1});
        }
        const k = MonitorUi.sortKey;
        out.sort(k === "memory" ? (a, b) => b.mem - a.mem || a.pid - b.pid
               : k === "pid" ? (a, b) => a.pid - b.pid
               : k === "name" ? (a, b) => a.name.localeCompare(b.name) || a.pid - b.pid
               : (a, b) => b.cpu - a.cpu || b.mem - a.mem);
        root.matchCount = matches;
        return out;
    }
    function sync() {
        const want = root.wanted(), keys = root.keys.slice();
        if (root.holding) {
            const byKey = {};
            for (const r of want) byKey[r.key] = r;
            for (let i = keys.length - 1; i >= 0; i--) if (!byKey[keys[i]]) { model.remove(i); keys.splice(i, 1); }
            for (let i = 0; i < keys.length; i++) { model.set(i, byKey[keys[i]]); delete byKey[keys[i]]; }
            for (const r of want) if (byKey[r.key]) { model.append(r); keys.push(r.key); }
        } else {
            for (let i = 0; i < want.length; i++) {
                const r = want[i];
                if (keys[i] === r.key) { model.set(i, r); continue; }
                const j = keys.indexOf(r.key, i + 1);
                if (j >= 0) { model.move(j, i, 1); keys.splice(i, 0, keys.splice(j, 1)[0]); model.set(i, r); }
                else { model.insert(i, r); keys.splice(i, 0, r.key); }
            }
            if (keys.length > want.length) { model.remove(want.length, keys.length - want.length); keys.length = want.length; }
        }
        root.keys = keys;
        root.shownCount = model.count;
    }
    Connections {
        target: MonitorUi
        function onProcessListChanged() { root.sync(); }
        function onQueryChanged() { root.sync(); }
        function onSortKeyChanged() { root.sync(); list.positionViewAtBeginning(); }
        function onShowKernelChanged() { root.sync(); }
    }
    Component.onCompleted: root.sync()

    // ---- barra de búsqueda y orden ---------------------------------------------------------
    Row {
        id: tools
        width: parent.width
        height: 32 * root.s
        spacing: 10 * root.s
        Rectangle {
            width: Math.min(300 * root.s, parent.width * 0.4)
            height: parent.height
            radius: Metrics.pill(height)
            color: Theme.tileBg
            border.width: search.editing ? Metrics.focusWidth * root.s : 1
            border.color: search.editing ? Theme.fam(palette.accent).selBorder : Theme.hair
            Icon { id: glyph; x: 11 * root.s; anchors.verticalCenter: parent.verticalCenter; name: "search"; size: 13 * root.s; color: Theme.fgVariant }
            SearchField {
                id: search
                anchors.left: glyph.right; anchors.leftMargin: 7 * root.s
                anchors.right: parent.right; anchors.rightMargin: 12 * root.s
                anchors.verticalCenter: parent.verticalCenter
                s: root.s
                placeholder: "Search name, command, user or PID"
                Component.onCompleted: search.text = MonitorUi.query
                onTextChanged: MonitorUi.query = search.text
                onMoved: delta => root.stepSelection(delta)
                onDismissed: {
                    if (search.text.length > 0) search.clear();
                    else MonitorUi.close();
                }
            }
            TapHandler { onTapped: search.focusField() }
        }
        Choice {
            anchors.verticalCenter: parent.verticalCenter
            s: root.s
            name: "Sort"
            options: [{value: "cpu", label: "CPU"}, {value: "memory", label: "Memory"}, {value: "pid", label: "PID"}, {value: "name", label: "Name"}]
            value: MonitorUi.sortKey
            onPicked: v => MonitorUi.sortKey = v
        }
        Toggle {
            anchors.verticalCenter: parent.verticalCenter
            s: root.s
            on: MonitorUi.showKernel
            label: "Show kernel threads"
            onToggled: MonitorUi.showKernel = !MonitorUi.showKernel
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Kernel threads"
            color: Theme.fgVariant
            font.family: Typography.ui; font.pixelSize: Typography.label * root.s
        }
    }
    Text {
        id: status
        anchors.top: tools.bottom
        anchors.topMargin: 8 * root.s
        width: parent.width
        elide: Text.ElideRight
        text: {
            const info = MonitorUi.processListInfo;
            if (!info) return "Reading processes…";
            return root.shownCount + (MonitorUi.query ? " matching" : " shown") + " of " + MonitorUi.processList.length
                + (info.truncated ? " · partial scan (time or count limit)" : "")
                + (info.unreadable ? " · " + info.unreadable + " ended during the scan" : "")
                + (info.cpuState !== "ok" ? " · CPU use after the next reading" : "")
                + " · updated " + Clock.fmt(info.at, true)
                + (root.holding && MonitorUi.sortKey !== "pid" ? " · order held while pointing" : "");
        }
        color: MonitorUi.processListInfo && MonitorUi.processListInfo.truncated ? Theme.warn : Theme.fgVariant
        font.family: Typography.ui; font.pixelSize: Typography.micro * root.s
    }

    // ---- tabla ---------------------------------------------------------------------------
    readonly property real detailW: MonitorUi.selectedPid ? Math.min(300 * root.s, root.width * 0.38) : 0
    readonly property real tableW: root.width - root.detailW - (root.detailW > 0 ? 12 * root.s : 0)
    component Cell: Text {
        color: Theme.fgVariant
        font.family: Typography.ui; font.pixelSize: Typography.micro * root.s; font.weight: Typography.wStrong
        font.capitalization: Font.AllUppercase
        elide: Text.ElideRight
    }
    Item {
        id: header
        anchors.top: status.bottom
        anchors.topMargin: 8 * root.s
        width: root.tableW
        height: 22 * root.s
        Cell { x: 8 * root.s; width: 56 * root.s; text: "PID" }
        Cell { x: 68 * root.s; width: parent.width - x - 290 * root.s; text: "Name · command" }
        Cell { x: parent.width - 282 * root.s; width: 96 * root.s; text: "User" }
        Cell { x: parent.width - 180 * root.s; width: 70 * root.s; horizontalAlignment: Text.AlignRight; text: "CPU"; color: MonitorUi.sortKey === "cpu" ? Theme.famNamed("primary").text : Theme.fgVariant }
        Cell { x: parent.width - 102 * root.s; width: 94 * root.s; horizontalAlignment: Text.AlignRight; text: "Memory"; color: MonitorUi.sortKey === "memory" ? Theme.famNamed("secondary").text : Theme.fgVariant }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.hair }
    }
    ListView {
        id: list
        anchors.top: header.bottom
        anchors.bottom: parent.bottom
        width: root.tableW
        clip: true
        model: model
        boundsBehavior: Flickable.StopAtBounds
        reuseItems: true
        HoverHandler { id: listHover }
        delegate: Rectangle {
            id: row
            required property int index
            required property string key
            required property int pid
            required property int start
            required property string name
            required property string cmd
            required property string user
            required property real cpu
            required property real mem
            readonly property bool chosen: MonitorUi.selectedPid === row.pid && MonitorUi.selectedStart === row.start
            // 16A-2
            Accessible.role: Accessible.Row
            Accessible.name: row.name + " (" + row.pid + ")"
            Accessible.description: (row.cpu < 0 ? "CPU unknown" : "CPU " + row.cpu.toFixed(1) + "%") + " · " + row.user
            Accessible.selected: row.chosen
            Accessible.onPressAction: row.chosen ? MonitorUi.select(0, 0) : MonitorUi.select(row.pid, row.start)
            width: list.width
            height: 30 * root.s
            radius: Metrics.r(6) * root.s
            color: row.chosen ? Theme.fam(palette.accent).sel : rowArea.containsMouse ? Theme.hoverBg : "transparent"
            Text {
                x: 8 * root.s; width: 56 * root.s; anchors.verticalCenter: parent.verticalCenter
                text: row.pid
                color: Theme.fgVariant
                font.family: Typography.mono; font.pixelSize: Typography.label * root.s
            }
            Text {
                x: 68 * root.s; width: parent.width - x - 290 * root.s; anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: row.name + (row.cmd && row.cmd !== row.name ? "   " + row.cmd : "")
                color: Theme.fg
                font.family: Typography.ui; font.pixelSize: Typography.label * root.s
            }
            Text {
                x: parent.width - 282 * root.s; width: 96 * root.s; anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                text: row.user
                color: Theme.fgVariant
                font.family: Typography.ui; font.pixelSize: Typography.label * root.s
            }
            Text {
                x: parent.width - 180 * root.s; width: 70 * root.s; anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: row.cpu < 0 ? "—" : Monitor.number(row.cpu, "%", 1)
                color: Theme.fg
                font.family: Typography.mono; font.pixelSize: Typography.label * root.s
            }
            Text {
                x: parent.width - 102 * root.s; width: 94 * root.s; anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: Monitor.bytes(row.mem)
                color: Theme.fg
                font.family: Typography.mono; font.pixelSize: Typography.label * root.s
            }
            MouseArea {
                id: rowArea
                anchors.fill: parent
                hoverEnabled: true
                onClicked: row.chosen ? MonitorUi.select(0, 0) : MonitorUi.select(row.pid, row.start)
            }
        }
        Empty {
            anchors.centerIn: parent
            visible: model.count === 0
            s: root.s
            maxWidth: list.width - 40 * root.s
            glyph: "search"
            loading: !MonitorUi.processListInfo
            text: !MonitorUi.processListInfo ? "Reading processes…" : MonitorUi.query ? "No process matches “" + MonitorUi.query + "”" : "No processes to show"
            hint: MonitorUi.query ? "Search looks at the name, command, user and PID" : !MonitorUi.showKernel ? "Kernel threads are hidden" : ""
        }
    }
    ScrollHint { view: list; s: root.s }

    // ---- ficha del elegido ------------------------------------------------------------------
    Rectangle {
        id: detail
        visible: root.detailW > 0
        anchors.top: status.bottom
        anchors.topMargin: 8 * root.s
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        width: root.detailW
        radius: Metrics.rMd * root.s
        color: Theme.tileBg
        border.width: 1
        border.color: Theme.hair
        readonly property var row: MonitorUi.selectedRow
        readonly property var f: MonitorUi.focus && MonitorUi.focus.pid === MonitorUi.selectedPid && MonitorUi.focus.startTicks === MonitorUi.selectedStart ? MonitorUi.focus : null
        readonly property bool gone: !detail.row && (!!MonitorUi.processListInfo) || (detail.f && detail.f.state === "gone")
        Flickable {
            anchors.fill: parent
            anchors.margins: 14 * root.s
            contentHeight: info.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            Column {
                id: info
                width: parent.width
                spacing: 8 * root.s
                Item {
                    width: parent.width
                    height: 22 * root.s
                    Text {
                        width: parent.width - 30 * root.s; elide: Text.ElideRight
                        anchors.verticalCenter: parent.verticalCenter
                        text: detail.row ? detail.row.name : "PID " + MonitorUi.selectedPid
                        color: Theme.fg
                        font.family: Typography.ui; font.pixelSize: Typography.title * root.s; font.weight: Typography.wStrong
                    }
                    Icon {
                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        name: "close"; size: 13 * root.s
                        color: closeArea.containsMouse ? Theme.fg : Theme.fgVariant
                        MouseArea { id: closeArea; anchors.fill: parent; anchors.margins: -6 * root.s; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: MonitorUi.select(0, 0) }
                    }
                }
                Text {
                    visible: detail.gone
                    width: parent.width; wrapMode: Text.Wrap
                    text: "This process has ended. Its PID may now belong to another one."
                    color: Theme.warn
                    font.family: Typography.ui; font.pixelSize: Typography.label * root.s
                }
                Repeater {
                    model: detail.row ? [
                        ["PID", detail.row.pid + (detail.f ? " · parent " + detail.f.ppid + (detail.f.parent ? " (" + detail.f.parent + ")" : "") : "")],
                        ["User", detail.row.user || "No data"],
                        ["State", ({R: "Running", S: "Sleeping", D: "Waiting on I/O", Z: "Zombie", T: "Stopped", I: "Idle", t: "Traced"})[detail.row.state] || detail.row.state || "No data"],
                        ["CPU", Monitor.number(detail.row.cpuPct, "%", 1) + " (100% = one core)"],
                        ["Memory", Monitor.bytes(detail.row.memoryB) + " resident · " + Monitor.number(detail.row.memoryPct, "%", 1) + (detail.f ? " · swap " + Monitor.bytes(detail.f.swapB) : "")],
                        ["Threads", String(detail.row.threads) + " · nice " + detail.row.nice],
                        ["Running for", detail.f ? Monitor.duration(detail.f.ageS) : "…"],
                        ["Disk I/O", !detail.f ? "…" : !detail.f.ioAvailable ? "Not readable (other user)" : "R " + Monitor.bytes(detail.f.readBps, true) + " · W " + Monitor.bytes(detail.f.writeBps, true)],
                        ["Open files", detail.f ? (detail.f.fds === null ? "Not readable (other user)" : String(detail.f.fds)) : "…"],
                        ["Executable", detail.f ? detail.f.exe || "Not readable" : "…"],
                        ["Command", detail.f && detail.f.cmd ? detail.f.cmd : detail.row.cmd]
                    ] : []
                    Column {
                        required property var modelData
                        width: info.width
                        spacing: 1 * root.s
                        Text {
                            text: modelData[0]
                            color: Theme.fgVariant
                            font.family: Typography.ui; font.pixelSize: Typography.micro * root.s
                            font.capitalization: Font.AllUppercase
                        }
                        Text {
                            width: parent.width
                            wrapMode: Text.WrapAnywhere
                            maximumLineCount: 8
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                            text: modelData[1]
                            color: Theme.fg
                            font.family: Typography.mono; font.pixelSize: Typography.label * root.s
                        }
                    }
                }
                Text {
                    width: parent.width; wrapMode: Text.Wrap
                    text: "Observation only: this monitor does not stop or signal processes."
                    color: Theme.fgVariant
                    font.family: Typography.ui; font.pixelSize: Typography.micro * root.s
                }
            }
        }
    }
}
