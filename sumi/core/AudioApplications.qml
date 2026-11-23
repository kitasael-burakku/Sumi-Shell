pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../services"
import "../components"

/**
 * Applications de la Audio UI: quién reproduce y quién graba, agrupado por aplicación (una app con
 * varios flujos es un bloque con una fila por flujo). Cada flujo: volumen, silencio y su ruta con
 * el mismo selector y los mismos estados que la surface (AudioRoutes: pedida, efectiva, recordada;
 * «Changing to…», error con Retry, preferencia ausente). Los nodos del EQ no aparecen (13A).
 *
 * El ecualizador no es por aplicación (es por salida): aquí no se ofrece.
 */
AudioSection {
    id: root

    /** [{ key, app, rec, streams: [nodo] }]: por aplicación (nombre + proceso), reproducción primero. */
    function groups(list, rec) {
        const out = [];
        for (const n of list) {
            const key = (rec ? "rec:" : "play:") + Mixer.label(n) + "|" + AudioRoutes.prop(n, "application.process.id");
            let g = out.find(x => x.key === key);
            if (!g) { g = {key: key, app: Mixer.label(n), rec: rec, streams: []}; out.push(g); }
            g.streams.push(n);
        }
        return out;
    }
    readonly property var playing: root.groups(Mixer.playback, false)
    readonly property var recording: root.groups(Mixer.capture, true)

    contentHeight: col.implicitHeight
    focusList: {
        const l = [];
        for (const g of root.playing.concat(root.recording))
            for (const n of g.streams) {
                l.push("app:" + n.id);
                if (AudioRoutes.routeWanted(n)) l.push("route:" + n.id);
            }
        return l;
    }
    onActivate: (id, dir) => {
        if (id.startsWith("route:")) {
            const n = Mixer.nodeById(parseInt(id.substring(6)));
            if (!n) return;
            if (dir === 0 && AudioRoutes.rowStatus(n).state === "error") AudioRoutes.retryRoute(n);
            else AudioRoutes.cycleRoute(n, dir === 0 ? 1 : dir);
        } else if (id.startsWith("app:")) {
            const n = Mixer.nodeById(parseInt(id.substring(4)));
            if (!n) return;
            if (dir === 0) Mixer.toggleMute(n); else Mixer.setVolume(n, Mixer.shownVolume(n) + 0.05 * dir);
        }
    }

    component Group: Column {
        id: grp
        required property var modelData
        readonly property bool many: grp.modelData.streams.length > 1
        width: parent ? parent.width : 0
        spacing: 4 * root.s
        Text {
            visible: grp.many
            width: parent.width
            elide: Text.ElideRight
            text: grp.modelData.app + "  ·  " + grp.modelData.streams.length + " streams"
            color: Theme.fg
            font.family: Typography.ui; font.pixelSize: Typography.body * root.s; font.weight: Typography.wStrong
        }
        Repeater {
            model: grp.modelData.streams
            Column {
                id: st
                required property var modelData
                width: grp.width
                spacing: 2 * root.s
                AudioChannel {
                    node: st.modelData
                    s: root.s
                    x: grp.many ? 14 * root.s : 0
                    width: grp.width - x
                    recording: grp.modelData.rec
                    title: grp.many ? (AudioRoutes.prop(st.modelData, "media.name") || Mixer.shortLabel(st.modelData)) : Mixer.shortLabel(st.modelData)
                    sub: {
                        const r = Mixer.routeOf(st.modelData);
                        const m = grp.many ? "" : AudioRoutes.prop(st.modelData, "media.name");
                        return [r ? (grp.modelData.rec ? "← " : "→ ") + r : "", m && m !== Mixer.shortLabel(st.modelData) ? m : ""]
                            .filter(x => x).join("  ·  ");
                    }
                    focused: root.focusId === "app:" + st.modelData.id
                    onFocusedChanged: if (focused) root.reveal(this)
                    onPicked: root.pick("app:" + st.modelData.id)
                }
                Item {
                    id: rc
                    readonly property var status: AudioRoutes.rowStatus(st.modelData)
                    readonly property string fid: "route:" + st.modelData.id
                    visible: AudioRoutes.routeWanted(st.modelData)
                    x: grp.many ? 14 * root.s : 0
                    width: grp.width - x
                    height: rcChoice.implicitHeight + (rcStatus.visible ? rcStatus.implicitHeight + 2 * root.s : 0) + 8 * root.s
                    Accessible.role: Accessible.ComboBox
                    Accessible.name: (st.modelData.isSink ? "Output for " : "Input for ") + Mixer.shortLabel(st.modelData)
                    Accessible.description: rcChoice.label + (rc.status.text.length > 0 ? ". " + rc.status.text : "")
                    AudioFocus { on: root.focusId === rc.fid; s: root.s }
                    Text {
                        id: rcLabel
                        anchors.left: parent.left
                        anchors.leftMargin: 22 * root.s
                        anchors.verticalCenter: rcChoice.verticalCenter
                        text: st.modelData.isSink ? "Output" : "Input"
                        color: Theme.fgVariant
                        font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                    }
                    Choice {
                        id: rcChoice
                        anchors.top: parent.top
                        anchors.topMargin: 2 * root.s
                        anchors.left: rcLabel.right
                        anchors.leftMargin: 12 * root.s
                        anchors.right: parent.right
                        s: root.s
                        name: (st.modelData.isSink ? "Output for " : "Input for ") + Mixer.shortLabel(st.modelData)
                        options: AudioRoutes.routeOptions(st.modelData)
                        value: AudioRoutes.shownChoice(st.modelData)
                        onPicked: function (v) { root.pick(rc.fid); AudioRoutes.moveTo(st.modelData, v); }
                    }
                    Text {
                        id: rcStatus
                        anchors.left: rcChoice.left
                        anchors.right: parent.right
                        anchors.top: rcChoice.bottom
                        anchors.topMargin: 2 * root.s
                        visible: text.length > 0
                        text: rc.status.text + (rc.status.state === "error" ? " · Retry" : "")
                        color: rc.status.state === "error" ? Theme.errorColor : Theme.fgVariant
                        font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                        elide: Text.ElideRight
                        MouseArea {
                            anchors.fill: parent
                            enabled: rc.status.state === "error"
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: { root.pick(rc.fid); AudioRoutes.retryRoute(st.modelData); }
                        }
                    }
                }
            }
        }
    }

    Column {
        id: col
        width: root.width
        spacing: 14 * root.s

        Empty {
            visible: Mixer.playback.length + Mixer.capture.length === 0
            width: parent.width
            s: root.s
            glyph: "mixer"
            text: "No apps are playing or recording"
            hint: "Apps appear here while they have an audio stream open."
        }

        Column {
            visible: root.playing.length > 0
            width: parent.width
            spacing: 8 * root.s
            MonitorHeading { s: root.s; text: "Playing"; aside: Mixer.playback.length + (Mixer.playback.length === 1 ? " stream" : " streams") }
            Repeater { model: root.playing; Group {} }
        }
        Column {
            visible: root.recording.length > 0
            width: parent.width
            spacing: 8 * root.s
            MonitorHeading { s: root.s; text: "Recording"; aside: Mixer.capture.length + (Mixer.capture.length === 1 ? " stream" : " streams") + " · the microphone indicator is on" }
            Repeater { model: root.recording; Group {} }
        }
        Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "The equalizer is per output: every app playing there goes through it."
            color: Theme.fgVariant
            font.family: Typography.ui; font.pixelSize: Typography.micro * root.s
        }
    }
}
