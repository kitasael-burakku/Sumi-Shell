pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../services"
import "../components"
import "../lib/accent-zones.js" as Zones

/**
 * Output e Input de la Audio UI (antes de la fase 14): la misma forma para los dos lados.
 *
 *   Device     la predeterminada entre las disponibles (elegirla mueve lo que la sigue: los flujos
 *              que no tienen destino propio; WirePlumber decide, como en la surface)
 *   Level      volumen y silencio; balance y canales si es estéreo (Mixer.setBalance)
 *   Hardware   tarjeta, perfil y puerto EN LECTURA (decisión del usuario: cambiarlos, fase 14) y
 *              el formato cuando hay audio (suspendida no hay formato que enseñar)
 *   Output     su ecualizador, con enlace a Equalizer ya en esa salida
 *   Input      estado con palabras (sin dispositivo, silenciada, en reposo, grabando, sin control)
 *              y quién graba de ella
 *
 * No es un inspector de PipeWire: sin nodos internos (los del EQ quedan fuera) ni propiedades crudas.
 */
AudioSection {
    id: root
    /** La familia de acento de la zona (Theme.fam; lib/accent-zones.js). */
    readonly property var acc: Theme.fam(palette.accent)
    /** "sink" | "source" */
    property string kind: "sink"
    readonly property bool out: root.kind === "sink"
    // salida y entrada llevan siempre su color (lib/accent-zones.js), también fuera de la ventana de Audio
    palette.accent: Theme.zone(Zones.of(root.out ? "output" : "input"))
    readonly property var list: root.out ? Mixer.sinks : Mixer.sources
    readonly property var cur: root.out ? Mixer.defaultSink : Mixer.defaultSource
    readonly property string curName: root.cur ? String(root.cur.name) : ""
    readonly property var info: { void AudioDevices.reads; return root.curName ? AudioDevices.nodeInfo(root.curName) : null; }
    readonly property var card: { void AudioDevices.reads; return root.curName ? AudioDevices.cardOfNode(root.curName) : null; }
    readonly property var streams: root.out ? Mixer.playback : Mixer.capture
    readonly property var here: root.streams.filter(n => AudioRoutes.effectiveOf(n).some(r => r.node === root.cur))
    readonly property var defOp: { void Mixer.ops.table; return Mixer.ops.get(root.kind); }

    readonly property string stateWord: {
        if (!root.cur) return root.out ? "No output device" : "No input device";
        if (!root.cur.audio) return "Volume not available for this " + (root.out ? "output" : "input");
        if (Mixer.shownMuted(root.cur)) return "Muted";
        if (root.out) return root.here.length > 0 ? "Playing · " + root.here.length + (root.here.length === 1 ? " app" : " apps") : "Idle";
        return root.here.length > 0 ? "Recording · " + root.here.length + (root.here.length === 1 ? " app" : " apps") : "Idle · nothing is recording";
    }

    function routeDesc(c) {
        if (!c) return "";
        const r = c.routes.find(x => x.active && x.direction === (root.out ? "Output" : "Input"));
        return r ? r.description + (r.available === "no" ? " (unplugged)" : "") : "";
    }
    function nodeLine(name) {
        const inf = AudioDevices.nodeInfo(name);
        const c = AudioDevices.cardOfNode(name);
        if (!inf) return AudioDevices.loaded ? "Virtual device" : "";
        return [inf.profile || (c ? "" : "Virtual device"), root.routeDesc(c)].filter(x => x).join(" · ");
    }
    function channelNames(n) {
        const pos = root.info ? root.info.position : [];
        return (n && n.audio ? n.audio.volumes : []).map((v, i) => (pos[i] || ("Ch " + (i + 1))) + " " + Math.round(v * 100) + " %");
    }
    function balWord(b) {
        if (Math.abs(b) < 0.005) return "Centered";
        return (b < 0 ? "Left " : "Right ") + Math.round(Math.abs(b) * 100) + " %";
    }

    contentHeight: col.implicitHeight
    focusList: {
        const l = root.list.map(n => "dev:" + n.name);
        if (root.cur && root.cur.audio) l.push("vol");
        if (Mixer.canBalance(root.cur)) l.push("bal");
        if (root.out && root.curName && Equalizer.supported) l.push("eq");
        l.push("devices");
        return l;
    }
    onActivate: (id, dir) => {
        if (id.startsWith("dev:")) {
            if (dir !== 0) {
                const i = root.focusList.indexOf(id);
                const next = root.focusList[i + dir];
                if (next && next.startsWith("dev:")) root.focusId = next;
                return;
            }
            const n = Mixer.nodeByName(id.substring(4));
            if (n) { if (root.out) Mixer.setDefaultSink(n); else Mixer.setDefaultSource(n); }
        } else if (id === "vol") {
            if (dir === 0) Mixer.toggleMute(root.cur); else Mixer.setVolume(root.cur, Mixer.shownVolume(root.cur) + 0.05 * dir);
        } else if (id === "bal") {
            Mixer.setBalance(root.cur, dir === 0 ? 0 : Mixer.balanceOf(root.cur) + 0.05 * dir);
        } else if (id === "eq") {
            if (dir === 0) { AudioUi.pickEq(root.curName); AudioUi.section = "equalizer"; }
        } else if (id === "devices") {
            if (dir === 0) AudioUi.section = "devices";
        }
    }

    Column {
        id: col
        width: root.width
        spacing: 14 * root.s

        // ---- el dispositivo ---------------------------------------------------------------
        Column {
            width: parent.width
            spacing: 4 * root.s
            MonitorHeading {
                s: root.s
                text: root.out ? "Output device" : "Input device"
                aside: root.defOp.state === "pending" ? "Switching…"
                     : root.defOp.state === "error" ? "Couldn't switch: " + root.defOp.reason : root.stateWord
                warning: root.defOp.state === "error"
            }
            Text {
                visible: root.list.length === 0
                text: root.out ? "No output device" : "No input device"
                color: Theme.fgVariant
                font.family: Typography.ui; font.pixelSize: Typography.body * root.s
            }
            Repeater {
                model: root.list
                Rectangle {
                    id: dev
                    required property var modelData
                    readonly property string fid: "dev:" + dev.modelData.name
                    readonly property bool isDefault: dev.modelData === root.cur
                    width: parent ? parent.width : 0
                    height: 44 * root.s
                    radius: Metrics.rSm * root.s
                    color: dev.isDefault ? root.acc.sel : devArea.containsMouse ? Theme.hoverBg : "transparent"
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: Mixer.shortLabel(dev.modelData)
                    Accessible.checked: dev.isDefault
                    AudioFocus { on: root.focusId === dev.fid; s: root.s }
                    Rectangle {
                        id: radio
                        anchors.left: parent.left; anchors.leftMargin: 10 * root.s
                        anchors.verticalCenter: parent.verticalCenter
                        width: 12 * root.s; height: 12 * root.s; radius: Metrics.pill(width)
                        color: "transparent"
                        border.width: 1.5 * root.s
                        border.color: dev.isDefault ? root.acc.fill : Theme.outline
                        Rectangle {
                            anchors.centerIn: parent
                            visible: dev.isDefault
                            width: 6 * root.s; height: 6 * root.s; radius: Metrics.pill(width)
                            color: root.acc.fill
                        }
                    }
                    Column {
                        anchors.left: radio.right; anchors.leftMargin: 10 * root.s
                        anchors.right: devTag.left; anchors.rightMargin: 10 * root.s
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1 * root.s
                        Text {
                            width: parent.width; elide: Text.ElideRight
                            text: Mixer.shortLabel(dev.modelData)
                            color: Theme.fg
                            font.family: Typography.ui; font.pixelSize: Typography.body * root.s
                            font.weight: dev.isDefault ? Typography.wStrong : Typography.wNormal
                        }
                        Text {
                            width: parent.width; elide: Text.ElideRight
                            text: { void AudioDevices.reads; return root.nodeLine(String(dev.modelData.name)) || Mixer.label(dev.modelData); }
                            color: Theme.fgVariant
                            font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                        }
                    }
                    Text {
                        id: devTag
                        anchors.right: parent.right; anchors.rightMargin: 12 * root.s
                        anchors.verticalCenter: parent.verticalCenter
                        text: dev.isDefault ? "Default" : devArea.containsMouse ? "Use" : ""
                        color: dev.isDefault ? root.acc.text : Theme.fgVariant
                        font.family: Typography.ui; font.pixelSize: Typography.caption * root.s; font.weight: Typography.wStrong
                    }
                    MouseArea {
                        id: devArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: dev.isDefault ? Qt.ArrowCursor : Qt.PointingHandCursor
                        onClicked: {
                            root.pick(dev.fid);
                            if (!dev.isDefault) { if (root.out) Mixer.setDefaultSink(dev.modelData); else Mixer.setDefaultSource(dev.modelData); }
                        }
                    }
                }
            }
        }

        // ---- nivel, balance y canales ----------------------------------------------------------
        Column {
            visible: root.cur !== null
            width: parent.width
            spacing: 6 * root.s
            MonitorHeading { s: root.s; text: "Level"; aside: root.cur && root.cur.audio ? root.channelNames(root.cur).join("  ·  ") : "" }
            AudioChannel {
                visible: !!root.cur && !!root.cur.audio
                node: root.cur
                s: root.s
                title: root.out ? "Volume" : "Input volume"
                focused: root.focusId === "vol"
                onFocusedChanged: if (focused) root.reveal(this)
                onPicked: root.pick("vol")
            }
            Text {
                visible: !!root.cur && !root.cur.audio
                width: parent.width
                wrapMode: Text.WordWrap
                text: "This " + (root.out ? "output" : "input") + " doesn't expose a volume control to the shell (virtual devices often don't). It can still be chosen."
                color: Theme.fgVariant
                font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
            }
            Item {
                id: bal
                visible: Mixer.canBalance(root.cur)
                readonly property real value: { void Mixer.ops.table; return Mixer.balanceOf(root.cur); }
                readonly property var op: { void Mixer.ops.table; return root.cur ? Mixer.ops.get("bal:" + root.cur.id) : null; }
                width: parent.width
                height: 40 * root.s
                Accessible.role: Accessible.Slider
                Accessible.name: "Balance"
                Accessible.description: root.balWord(bal.value)
                AudioFocus { on: root.focusId === "bal"; s: root.s }
                Text {
                    id: balLabel
                    anchors.left: parent.left; anchors.top: parent.top
                    text: "Balance"
                    color: Theme.fg
                    font.family: Typography.ui; font.pixelSize: Typography.body * root.s
                }
                Text {
                    anchors.right: parent.right; anchors.top: parent.top
                    text: bal.op && bal.op.state === "error" ? bal.op.reason : root.balWord(bal.value)
                    color: bal.op && bal.op.state === "error" ? Theme.errorColor : Theme.fgVariant
                    font.family: Typography.mono; font.pixelSize: Typography.caption * root.s
                }
                Text {
                    anchors.left: parent.left; anchors.bottom: parent.bottom
                    text: "L"
                    color: Theme.fgVariant
                    font.family: Typography.ui; font.pixelSize: Typography.micro * root.s
                }
                Text {
                    anchors.right: parent.right; anchors.bottom: parent.bottom
                    text: "R"
                    color: Theme.fgVariant
                    font.family: Typography.ui; font.pixelSize: Typography.micro * root.s
                }
                Item {
                    id: balTrack
                    anchors.left: parent.left; anchors.leftMargin: 16 * root.s
                    anchors.right: parent.right; anchors.rightMargin: 16 * root.s
                    anchors.bottom: parent.bottom
                    height: 16 * root.s
                    readonly property real cx: width / 2
                    readonly property real kx: (bal.value + 1) / 2 * width
                    Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 6 * root.s; radius: Metrics.pill(height); color: Theme.trackBg }
                    Rectangle {   // del centro al valor
                        anchors.verticalCenter: parent.verticalCenter
                        x: Math.min(balTrack.cx, balTrack.kx); width: Math.max(2, Math.abs(balTrack.kx - balTrack.cx))
                        height: 6 * root.s; radius: Metrics.pill(height)
                        color: root.acc.fill
                    }
                    Rectangle { x: balTrack.cx - 0.5; anchors.verticalCenter: parent.verticalCenter; width: 1; height: 14 * root.s; color: Theme.hair }
                    Rectangle {
                        x: balTrack.kx - width / 2
                        anchors.verticalCenter: parent.verticalCenter
                        width: 14 * root.s; height: 14 * root.s; radius: Metrics.pill(width)
                        color: root.acc.fill
                        border.width: 2; border.color: Theme.surface
                    }
                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -6 * root.s
                        cursorShape: Qt.PointingHandCursor
                        preventStealing: true
                        // encaje suave en el centro: ±4 % vuelve a 0 (volver exacto sin pelear con el ratón)
                        function at(x) {
                            const b = Math.max(-1, Math.min(1, (x - 6 * root.s) / balTrack.width * 2 - 1));
                            return Math.abs(b) < 0.04 ? 0 : Math.round(b * 100) / 100;
                        }
                        onPressed: (m) => { root.pick("bal"); Mixer.setBalance(root.cur, at(m.x)); }
                        onPositionChanged: (m) => { if (pressed) Mixer.setBalance(root.cur, at(m.x)); }
                        onDoubleClicked: Mixer.setBalance(root.cur, 0)
                        onWheel: (w) => Mixer.setBalance(root.cur, bal.value + (w.angleDelta.y > 0 ? 0.05 : -0.05))
                    }
                }
            }
        }

        // ---- el ecualizador de esta salida -----------------------------------------------------
        Item {
            id: eqBox
            visible: root.out && root.curName.length > 0 && Equalizer.supported
            width: parent.width
            height: eqRow.height
            readonly property var st: { void Equalizer.ops.table; return Equalizer.stateOf(root.curName); }
            readonly property var v: { void Equalizer.profiles; return Equalizer.view(root.curName); }
            AudioFocus { on: root.focusId === "eq"; s: root.s }
            Column {
                id: eqRow
                width: parent.width
                spacing: 4 * root.s
                MonitorHeading { s: root.s; text: "Equalizer on this output" }
                Item {
                    width: parent.width
                    height: 28 * root.s
                    Text {
                        anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                        text: eqBox.st.state === "failed" ? "Couldn't start · " + eqBox.st.reason
                            : eqBox.st.state === "unavailable" ? "Unavailable · " + eqBox.st.reason
                            : (eqBox.v.enabled ? "On · " : "Off · ") + Equalizer.presetName(eqBox.v.preset)
                        color: eqBox.st.state === "failed" ? Theme.errorColor : eqBox.st.state === "unavailable" ? Theme.warn : Theme.fg
                        font.family: Typography.ui; font.pixelSize: Typography.body * root.s
                    }
                    ActionButton {
                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        s: root.s
                        label: "Open equalizer ↗"
                        onTriggered: { root.pick("eq"); AudioUi.pickEq(root.curName); AudioUi.section = "equalizer"; }
                    }
                }
            }
        }

        // ---- hardware (lectura) --------------------------------------------------------------
        Column {
            visible: root.cur !== null
            width: parent.width
            spacing: 4 * root.s
            MonitorHeading {
                s: root.s
                text: "Hardware"
                aside: AudioDevices.error ? AudioDevices.error : !AudioDevices.loaded ? "Reading…" : ""
                warning: AudioDevices.error.length > 0
            }
            Grid {
                id: hw
                width: parent.width
                columns: 2
                columnSpacing: 16 * root.s
                rowSpacing: 3 * root.s
                readonly property var rows: {
                    const c = root.card, i = root.info;
                    if (!i) return AudioDevices.loaded ? [["Device", "Virtual (no sound card)"]] : [];
                    const fmt = i.rate > 0 ? Math.round(i.rate / 100) / 10 + " kHz · " + (i.format || "?") + " · " + i.channels + " ch"
                              : i.state === "running" ? "—" : "Shown while audio plays (now " + (i.state || "unknown") + ")";
                    const out = [["Card", c ? c.label + (c.bus ? " · " + c.bus.toUpperCase() : "") : "Virtual"]];
                    if (c && c.profile) out.push(["Profile", c.profile.description || c.profile.name]);
                    const port = root.routeDesc(c);
                    if (port) out.push(["Port", port]);
                    if (i.codec) out.push(["Codec", i.codec]);
                    out.push(["Format", fmt]);
                    out.push(["Channels", i.position.length ? i.position.join(" ") : String(i.channels)]);
                    return out;
                }
                Repeater {
                    model: hw.rows.length * 2
                    Text {
                        required property int index
                        readonly property var row: hw.rows[Math.floor(index / 2)]
                        width: index % 2 === 0 ? 90 * root.s : hw.width - 90 * root.s - hw.columnSpacing
                        elide: Text.ElideRight
                        text: row ? row[index % 2] : ""
                        color: index % 2 === 0 ? Theme.fgVariant : Theme.fg
                        font.family: index % 2 === 0 ? Typography.ui : Typography.mono
                        font.pixelSize: Typography.caption * root.s
                    }
                }
            }
            Item {
                width: parent.width
                height: 30 * root.s
                AudioFocus { on: root.focusId === "devices"; s: root.s }
                Text {
                    anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                    anchors.right: devBtn.left; anchors.rightMargin: 10 * root.s
                    elide: Text.ElideRight
                    text: "Profiles and ports are read-only here."
                    color: Theme.fgVariant
                    font.family: Typography.ui; font.pixelSize: Typography.micro * root.s
                }
                ActionButton {
                    id: devBtn
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    s: root.s
                    label: "All devices ↗"
                    onTriggered: { root.pick("devices"); AudioUi.section = "devices"; }
                }
            }
        }

        // ---- quién usa este dispositivo ---------------------------------------------------------
        Column {
            width: parent.width
            spacing: 4 * root.s
            MonitorHeading {
                s: root.s
                text: root.out ? "Playing here" : "Recording from here"
                aside: root.streams.length > root.here.length ? (root.streams.length - root.here.length) + " elsewhere · see Applications" : ""
            }
            Text {
                visible: root.here.length === 0
                text: root.out ? "Nothing is playing to this output" : "Nothing is recording from this input"
                color: Theme.fgVariant
                font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
            }
            Repeater {
                model: root.here
                Text {
                    required property var modelData
                    width: parent ? parent.width : 0
                    elide: Text.ElideRight
                    text: Mixer.shortLabel(modelData) + (modelData.audio ? "  ·  " + (Mixer.shownMuted(modelData) ? "muted" : Math.round(Mixer.shownVolume(modelData) * 100) + " %") : "")
                    color: root.out ? Theme.fg : Theme.errorColor
                    font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                }
            }
        }
    }
}
