import QtQuick
import "../theme"
import "../services"
import "../components"
import "../lib/accent-zones.js" as Zones

/**
 * Overview: decidir qué configurar después. Cuatro cifras que llevan a su sección (salida, entrada,
 * aplicaciones, ecualizador), el volumen de salida y de entrada, y quién suena o graba ahora. No
 * repite la surface: sin reproducción (es de Media) ni rutas por app (son de Applications).
 */
AudioSection {
    id: root
    readonly property var sink: Mixer.defaultSink
    readonly property var source: Mixer.defaultSource
    readonly property int playing: Mixer.playback.length
    readonly property int recording: Mixer.capture.length
    readonly property string eqDev: AudioUi.defaultSinkName
    readonly property var eqState: { void Equalizer.ops.table; return root.eqDev ? Equalizer.stateOf(root.eqDev) : {state: "none", reason: ""}; }
    readonly property var eqView: { void Equalizer.profiles; return Equalizer.view(root.eqDev); }

    /** Estado de la entrada con palabras discretas (el pedido): sin dispositivo, silenciada, grabando, en reposo. */
    readonly property string inputWord: !root.source ? "No device" : !root.source.audio ? "No control"
        : Mixer.shownMuted(root.source) ? "Muted" : root.recording > 0 ? "Recording" : "Idle"

    contentHeight: col.implicitHeight
    focusList: ["tile:output", "tile:input", "tile:applications"]
        .concat(Equalizer.supported ? ["tile:equalizer"] : [])
        .concat(root.sink ? ["outVol"] : []).concat(root.source && root.source.audio ? ["inVol"] : [])
    onActivate: (id, dir) => {
        if (id.startsWith("tile:")) { if (dir === 0) AudioUi.section = id.substring(5); return; }
        const n = id === "outVol" ? root.sink : root.source;
        if (!n) return;
        if (dir === 0) Mixer.toggleMute(n); else Mixer.setVolume(n, Mixer.shownVolume(n) + 0.05 * dir);
    }

    Column {
        id: col
        width: root.width
        spacing: 14 * root.s

        Grid {
            id: tiles
            width: parent.width
            columns: width >= 900 * root.s ? (Equalizer.supported ? 4 : 3) : width >= 420 * root.s ? 2 : 1
            spacing: 8 * root.s
            readonly property real cell: (width - (columns - 1) * spacing) / columns
            Repeater {
                model: [
                    {id: "output", label: "Output",
                     value: !root.sink ? "None" : Mixer.shownMuted(root.sink) ? "Muted" : Math.round(Mixer.shownVolume(root.sink) * 100) + " %",
                     sub: root.sink ? Mixer.shortLabel(root.sink) : "No output device", warn: !root.sink},
                    {id: "input", label: "Input", value: root.inputWord,
                     sub: root.source ? Mixer.shortLabel(root.source) : "No input device", warn: false},
                    {id: "applications", label: "Applications", value: root.playing + " playing",
                     sub: root.recording + " recording" + (root.recording > 0 ? " · mic in use" : ""), warn: false}
                ].concat(Equalizer.supported ? [{id: "equalizer", label: "Equalizer",
                     value: root.eqState.state === "failed" ? "Error" : root.eqState.state === "unavailable" ? "Unavailable"
                          : root.eqState.state === "loading" ? "…"
                          : root.eqState.state === "starting" ? "Starting" : root.eqView.enabled ? "On" : "Off",
                     sub: root.eqDev ? Equalizer.presetName(root.eqView.preset) + " · " + AudioRoutes.labelOf(root.eqDev) : "No output",
                     warn: root.eqState.state === "failed" || root.eqState.state === "unavailable"}] : [])
                Item {
                    id: tile
                    required property var modelData
                    width: tiles.cell
                    height: stat.implicitHeight
                    readonly property bool focused: root.focusId === "tile:" + tile.modelData.id
                    onFocusedChanged: if (focused) Qt.callLater(() => { if (root && tile) root.reveal(tile); })
                    MonitorStat {
                        id: stat
                        anchors.fill: parent
                        s: root.s
                        palette.accent: Theme.zone(Zones.of(tile.modelData.id))
                        link: true
                        label: tile.modelData.label
                        value: tile.modelData.value
                        sub: tile.modelData.sub
                        warning: tile.modelData.warn
                        valueColor: tile.modelData.id === "input" && root.recording > 0 ? Theme.dangerText
                            : tile.modelData.id === "output" && root.sink && !Mixer.shownMuted(root.sink) ? Theme.famNamed(Zones.of("output")).text
                            : tile.modelData.id === "equalizer" && root.eqView.enabled ? Theme.successText : Theme.fg
                        onActivated: { root.pick("tile:" + tile.modelData.id); AudioUi.section = tile.modelData.id; }
                    }
                    AudioFocus { on: root.focusId === "tile:" + tile.modelData.id; s: root.s }
                    // grabar se marca también en rojo (no sólo con el color: la palabra ya lo dice)
                    Rectangle {
                        visible: tile.modelData.id === "input" && root.recording > 0
                        anchors.right: parent.right; anchors.top: parent.top
                        anchors.margins: 10 * root.s
                        width: 7 * root.s; height: 7 * root.s; radius: Metrics.pill(width)
                        color: Theme.errorColor
                    }
                }
            }
        }

        Column {
            width: parent.width
            spacing: 6 * root.s
            MonitorHeading { s: root.s; text: "Levels" }
            AudioChannel {
                visible: root.sink !== null
                node: root.sink
                s: root.s
                sub: "Output"
                focused: root.focusId === "outVol"
                onFocusedChanged: if (focused) root.reveal(this)
                onPicked: root.pick("outVol")
            }
            AudioChannel {
                visible: root.source !== null && !!root.source.audio
                node: root.source
                s: root.s
                sub: "Input"
                focused: root.focusId === "inVol"
                onFocusedChanged: if (focused) root.reveal(this)
                onPicked: root.pick("inVol")
            }
            Text {
                visible: !root.sink || !root.source
                text: [!root.sink ? "No output device" : "", !root.source ? "No input device" : ""].filter(x => x).join(" · ")
                color: Theme.fgVariant
                font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
            }
        }

        Column {
            width: parent.width
            spacing: 4 * root.s
            MonitorHeading {
                s: root.s
                text: "Now"
                aside: root.playing + root.recording > 0 ? "Details in Applications" : ""
            }
            Text {
                visible: root.playing + root.recording === 0
                text: "No apps are playing or recording"
                color: Theme.fgVariant
                font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
            }
            Repeater {
                model: Mixer.playback.concat(Mixer.capture).slice(0, 8)
                Item {
                    id: now
                    required property var modelData
                    readonly property bool rec: !now.modelData.isSink
                    width: parent ? parent.width : 0
                    height: 30 * root.s
                    Icon {
                        id: nowIcon
                        anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                        name: now.rec ? "mic" : "volume-mid"
                        size: 12 * root.s
                        color: now.rec ? Theme.errorColor : Theme.fgVariant
                    }
                    Text {
                        anchors.left: nowIcon.right; anchors.leftMargin: 8 * root.s
                        anchors.right: nowRoute.left; anchors.rightMargin: 12 * root.s
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        text: Mixer.shortLabel(now.modelData) + (now.rec ? "  ·  recording" : "")
                        color: Theme.fg
                        font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                    }
                    Text {
                        id: nowRoute
                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, parent.width * 0.4)
                        elide: Text.ElideRight
                        text: { const r = Mixer.routeOf(now.modelData); return r ? (now.rec ? "← " : "→ ") + r : ""; }
                        color: Theme.fgVariant
                        font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                    }
                }
            }
        }
    }
}
