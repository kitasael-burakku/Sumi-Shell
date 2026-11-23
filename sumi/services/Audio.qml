pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Services.Pipewire

/**
 * The default sink and source, bound so their volume actually updates
 * (Pipewire nodes stay unbound until something tracks them).
 *
 * `changed` fires only when a level or mute really moves, and only after the
 * shell has settled: binding to the initial populate would flash an OSD every
 * time the shell starts.
 */
Singleton {
    id: root

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property bool sinkReady: sink !== null && sink.ready && sink.audio !== null
    readonly property real volume: sinkReady ? Math.max(0, Math.min(1, sink.audio.volume)) : 0
    readonly property bool muted: sinkReady ? sink.audio.muted : false
    readonly property string sinkName: sink ? (sink.description || sink.nickname || sink.name) : ""

    readonly property var source: Pipewire.defaultAudioSource
    readonly property bool sourceReady: source !== null && source.ready && source.audio !== null
    readonly property real micVolume: sourceReady ? Math.max(0, Math.min(1, source.audio.volume)) : 0
    readonly property bool micMuted: sourceReady ? source.audio.muted : false

    /** kind: "volume" | "mic" */
    signal changed(string kind)

    property bool armed: false
    Timer {
        interval: 1500
        running: true
        onTriggered: root.armed = true
    }

    PwObjectTracker {
        objects: [root.sink, root.source].filter(Boolean)
    }

    Connections {
        target: root.sinkReady ? root.sink.audio : null
        function onVolumeChanged() { if (root.armed) root.changed("volume"); }
        function onMutedChanged() { if (root.armed) root.changed("volume"); }
    }

    Connections {
        target: root.sourceReady ? root.source.audio : null
        function onMutedChanged() { if (root.armed) root.changed("mic"); }
        function onVolumeChanged() { if (root.armed) root.changed("mic"); }
    }
}
