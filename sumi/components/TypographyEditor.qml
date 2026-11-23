pragma ComponentBehavior: Bound
import QtQuick
import "../theme"
import "../services"
import "../lib/typography.js" as Fonts

// Local preview only. The sole writer is Settings.applyTypography on explicit Apply.
FocusScope {
    id: root
    property real s: 1
    property bool editing: false
    property var draft: null
    property string original: ""
    property string error: ""
    property bool advanced: false
    property int current: 0
    readonly property var choice: draft || Settings.typographySelection
    readonly property var uiResolution: Typography.resolve(choice,"ui")
    readonly property var monoResolution: Typography.resolve(choice,"mono")
    readonly property bool applicable: editing && Typography.canApply(choice) && Settings.writable
        && original === Settings.typographySignature
    signal finished()
    visible: editing
    enabled: editing
    focus: editing

    function begin() {
        Typography.refresh();
        original = Settings.typographySignature;
        draft = JSON.parse(JSON.stringify(Settings.typographySelection));
        error = ""; advanced = false; current = 0; editing = true;
        previewScroll.contentY = 0;
        forceActiveFocus();
    }
    function cancel() { editing = false; draft = null; error = ""; finished(); }
    function apply() {
        if (!applicable) { error = "Family unavailable or settings changed. Cancel and reopen to reload."; return false; }
        if (!Settings.applyTypography(original,choice)) { error = "Settings changed; cancel and reopen."; return false; }
        cancel(); return true;
    }
    function choose(id) { draft = Fonts.selection(id,"",""); }
    function options(role) {
        const out = [{label:"From preset", value:""}];
        for (const p of Typography.catalog.presets) {
            const v = Fonts.listed(p[role],Typography.installed) || p[role][0];
            if (!out.some(o => o.value === v)) out.push({label:p.label,value:v});
        }
        if (choice[role] && !out.some(o => o.value === choice[role])) out.push({label:choice[role],value:choice[role]});
        return out;
    }
    function step(row,delta) {
        if (row === 0) {
            const ps=Typography.catalog.presets;
            const at=ps.findIndex(p => p.id === choice.preset);
            choose(ps[((at+delta)%ps.length+ps.length)%ps.length].id);
        } else if (row === 1) advanced = !advanced;
        else if (row === 2 || row === 3) {
            const role=row === 2 ? "ui" : "mono";
            const list=options(role); const at=list.findIndex(o => o.value === choice[role]);
            const next=JSON.parse(JSON.stringify(choice));
            next[role]=list[((at+delta)%list.length+list.length)%list.length].value;
            draft=next;
        } else if (row === 4) Typography.refresh();
        else if (row === 5) apply();
        else if (row === 6) cancel();
    }
    function handleKey(event) {
        const rows=advanced ? [0,1,2,3,4,5,6] : [0,1,4,5,6];
        const i=Math.max(0,rows.indexOf(current));
        if ([Qt.Key_PageUp,Qt.Key_PageDown,Qt.Key_Home,Qt.Key_End].indexOf(event.key)>=0) {
            const maxY=Math.max(0,previewScroll.contentHeight-previewScroll.height);
            previewScroll.contentY=event.key === Qt.Key_Home ? 0 : event.key === Qt.Key_End ? maxY
                : Math.max(0,Math.min(maxY,previewScroll.contentY + previewScroll.height * (event.key === Qt.Key_PageUp ? -.8 : .8)));
            event.accepted=true;return;
        }
        if (event.key === Qt.Key_Escape) { cancel(); event.accepted=true; return; }
        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab || event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
            const back=event.key === Qt.Key_Backtab || event.key === Qt.Key_Up || (event.modifiers & Qt.ShiftModifier);
            current=rows[(i+(back ? rows.length-1 : 1))%rows.length];
            revealCurrent(); event.accepted=true; return;
        }
        if ([Qt.Key_Left,Qt.Key_Right,Qt.Key_Return,Qt.Key_Enter,Qt.Key_Space].indexOf(event.key)>=0) {
            if (!event.isAutoRepeat) step(current,event.key === Qt.Key_Left ? -1 : 1);
            event.accepted=true;
        }
    }
    function revealCurrent() {
        if (current >= 4) return;
        const item=[presetRow,advancedRow,uiRow,monoRow][current];
        const y=item.mapToItem(content,0,0).y;
        if (y < previewScroll.contentY) previewScroll.contentY=y;
        else if (y+item.height > previewScroll.contentY+previewScroll.height)
            previewScroll.contentY=Math.max(0,y+item.height-previewScroll.height);
    }
    Keys.onPressed: event => root.handleKey(event)
    FontInfo { id: uiInfo; font.family: root.uiResolution.selected }
    FontInfo { id: monoInfo; font.family: root.monoResolution.selected }
    Rectangle { anchors.fill: parent; color: Theme.surfaceContainer }
    // Prevent clicks from reaching the Settings frame behind this editor.
    MouseArea { anchors.fill: parent }
    Flickable {
        id: previewScroll
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: actions.top
        anchors.margins: 12 * root.s
        clip: true
        contentWidth: width
        contentHeight: content.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        Column {
            id: content
            width: previewScroll.width
            spacing: 10 * root.s
            Text {
                width: parent.width; text: "Font families · local preview"
                color: Theme.fg; font.family: Typography.ui; font.pixelSize: Typography.title * root.s
                font.weight: Typography.wStrong
            }
            Text {
                width: parent.width; wrapMode: Text.Wrap
                text: "A draft: Apply keeps it, Cancel or Escape discards it."
                color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: Typography.label * root.s
            }
            SelectRow {
                id: presetRow; width: parent.width; index: 0; title: "Preset"
                value: (Fonts.preset(Typography.catalog,root.choice.preset) || {label:root.choice.preset}).label
            }
            Flow {
                width: parent.width; spacing: 6 * root.s
                Repeater {
                    model: Typography.catalog.presets
                    delegate: ActionButton {
                        required property var modelData
                        readonly property var resolved: Typography.resolve(Fonts.selection(modelData.id,"",""),"ui")
                        s: root.s
                        label: modelData.label + (resolved.state === "unavailable" ? " · not installed" : resolved.state === "unknown" ? " · unknown" : "")
                        accent: root.choice.preset === modelData.id
                        onTriggered: { root.choose(modelData.id); root.current=0; }
                    }
                }
            }
            SelectRow { id: advancedRow; width: parent.width; index: 1; title: "Advanced"; value: root.advanced ? "UI and code independently" : "Show options" }
            SelectRow { id: uiRow; visible: root.advanced; width: parent.width; index: 2; title: "UI override"; value: root.choice.ui || "From preset" }
            SelectRow { id: monoRow; visible: root.advanced; width: parent.width; index: 3; title: "Code override"; value: root.choice.mono || "From preset" }
            Text {
                width: parent.width; wrapMode: Text.Wrap
                text: "UI requested: " + root.uiResolution.requested + "\nEffective: " + uiInfo.family
                    + (root.uiResolution.reason ? "\n" + root.uiResolution.reason : "")
                    + "\nCode requested: " + root.monoResolution.requested + "\nEffective: " + monoInfo.family
                    + (root.monoResolution.reason ? "\n" + root.monoResolution.reason : "")
                    + "\nIcons: " + Typography.icons + " · " + Typography.iconReport.state
                color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: Typography.label * root.s
            }
            Rectangle {
                width: parent.width; height: samples.implicitHeight + 20 * root.s
                radius: Metrics.r(10) * root.s; color: Theme.hoverBg
                Column {
                    id: samples; x: 10 * root.s; y: 10 * root.s; width: parent.width - 20 * root.s; spacing: 8 * root.s
                    Repeater {
                        model: [Font.Normal,Font.Medium,Font.DemiBold]
                        delegate: Text {
                            required property int modelData
                            width: samples.width; wrapMode: Text.Wrap
                            text: "Configuración · pingüino · Ñ áéíóú ¿¡ € @ # % & — " + modelData
                            color: Theme.fg; font.family: uiInfo.family; font.pixelSize: Typography.body * root.s; font.weight: modelData
                        }
                    }
                    Text {
                        width: parent.width; wrapMode: Text.Wrap
                        text: "Proportional UI: minimum WWW · 00:00 11:11 23:59\n0123456789 · −42.50 °C · 100%"
                        font.features: {"tnum":1}
                        color: Theme.fg; font.family: uiInfo.family; font.pixelSize: Typography.body * root.s
                    }
                    Text {
                        width: parent.width; wrapMode: Text.Wrap
                        text: "Code / log\nconst café = (n) => n !== 0; // ñ\niiii WWWW 0123 [] {} () -> => != <= >=\nRead only · العربية · 日本語 · 🙂"
                        color: Theme.fg; font.family: monoInfo.family; font.pixelSize: Typography.body * root.s
                    }
                    Flow {
                        width: parent.width; spacing: 12 * root.s
                        Repeater {
                            model: ["clock","wifi","bt","volume-high","cog","terminal","power"]
                            delegate: Icon { required property string modelData; name: modelData; size: 18 * root.s }
                        }
                    }
                }
            }
            Text {
                width: parent.width; wrapMode: Text.Wrap
                text: root.error || (root.original !== Settings.typographySignature ? "Font settings changed externally. Cancel and reopen."
                    : !root.applicable ? "Apply needs both families installed and writable settings." : "Ready to apply to Sumi Shell")
                color: root.applicable ? Theme.fgVariant : Theme.errorColor
                font.family: Typography.ui; font.pixelSize: Typography.label * root.s
            }

        }
    }
    Flow {
                id: actions; anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 12 * root.s; spacing: 10 * root.s
                ActionButton { s: root.s; label: "Refresh fonts"; focused: root.current === 4; onTriggered: { root.current=4; Typography.refresh(); } }
                ActionButton { s: root.s; label: "Apply"; enabled: root.applicable; focused: root.current === 5; onTriggered: root.apply() }
                ActionButton { s: root.s; label: "Cancel"; focused: root.current === 6; onTriggered: root.cancel() }
            }
    ScrollHint { view: previewScroll; s: root.s }
    component SelectRow: Item {
        id: row
        required property int index
        property string title: ""
        property string value: ""
        implicitHeight: Math.max(32 * root.s, valueText.implicitHeight + 8 * root.s)
        Rectangle { anchors.fill: parent; radius: Metrics.r(8) * root.s; color: root.current === row.index ? Theme.hoverBg : "transparent"; border.width: root.current === row.index ? 1 : 0; border.color: Theme.primary }
        Text {
            id: valueText; x: 10 * root.s; anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0,parent.width - arrows.width - 20 * root.s); wrapMode: Text.Wrap
            text: row.title + ": " + row.value
            color: Theme.fg; font.family: Typography.ui; font.pixelSize: Typography.body * root.s
        }
        Row {
            id: arrows; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            ActionButton { s: root.s; label: "‹"; Accessible.name: "Previous " + row.title; onTriggered: { root.current=row.index; root.step(row.index,-1); } }
            ActionButton { s: root.s; label: "›"; Accessible.name: "Next " + row.title; onTriggered: { root.current=row.index; root.step(row.index,1); } }
        }
    }
}
