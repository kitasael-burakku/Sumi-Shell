import QtQuick
import "../components"
import "../theme"

/** Vista previa de Settings. Sólo la composición del Lock y estados de demostración. */
Column {
    id: root

    property real s: 1
    property real availableWidth: 480
    property bool focused: false
    signal interacted()
    width: root.availableWidth
    spacing: Metrics.sp2 * root.s

    function adjust(dir) {
        if (dir === 0)
            root.play(choice.value);
        else
            choice.cycle(dir);
    }

    function play(scene) {
        next.stop();
        demo.stop();
        result.stop();
        reset.stop();
        ctx.phase = "unlocked";
        ctx.auth = { state: "idle", failed: 0 };
        ctx.bufferLength = 0;
        next.scene = scene;
        next.start();
    }

    QtObject {
        id: ctx
        property string phase: "locked"
        readonly property bool instant: false
        readonly property bool calm: false
        readonly property string avatarSource: ""
        readonly property string layoutCode: "US"
        readonly property int layoutCount: 2
        readonly property bool capsLock: false
        readonly property bool numLock: false
        property int bufferLength: 0
        property var auth: ({ state: "idle", failed: 0 })
        readonly property string userName: "Sumi"
        readonly property var fetch: ({ os: "Arch Linux", wm: "Hyprland", shell: "fish", kernel: "Linux",
                                          cpu: "8 cores", gpu: "Graphics" })
        readonly property var weather: ({ state: "ok", temp: "24°", condition: "Partly cloudy", icon: "weather-partly" })
        readonly property var metrics: ({
            cpu: { state: "ok", value: 23, unit: "%", frac: 0.23 },
            cpuTemp: { state: "ok", value: 54, unit: "°C", frac: 0.48 },
            ram: { state: "ok", value: 41, unit: "%", frac: 0.41 },
            disk: { state: "ok", value: 61, unit: "%", frac: 0.61 }
        })
        readonly property var music: ({ has: true, playing: true, title: "Evening", artist: "Sample track",
                                        canPrev: true, canToggle: true, canNext: true })
        readonly property var notifs: ({
            state: "ok", count: 2,
            groups: [{ app: "sumi", name: "Sumi Shell", count: 2, items: [
                { id: "sample-1", title: "Updates available", body: "Two packages are ready to update.", time: Date.now() },
                { id: "sample-2", title: "Backup complete", body: "Your files are up to date.", time: Date.now() }
            ] }]
        })
        readonly property bool suspendOk: true
        signal failedAttempt()

        function enterDone(screen) { if (ctx.phase === "entering") ctx.phase = "locked"; }
        function leaveDone(screen) {
            if (ctx.phase !== "leaving") return;
            ctx.phase = "unlocked";
            reset.restart();
        }
    }

    Timer {
        id: next
        property string scene: "entry"
        interval: 0
        onTriggered: {
            ctx.phase = next.scene === "entry" ? "entering" : "locked";
            if (next.scene !== "entry")
                demo.restart();
        }
    }
    Timer {
        id: demo
        interval: 95
        repeat: true
        onTriggered: {
            if (ctx.bufferLength < 5) {
                ctx.bufferLength++;
                return;
            }
            demo.stop();
            if (next.scene === "typing") return;
            ctx.auth = { state: "checking", failed: 0 };
            result.restart();
        }
    }
    Timer {
        id: result
        interval: 430
        onTriggered: {
            ctx.bufferLength = 0;
            if (next.scene === "error") {
                ctx.auth = { state: "failed", message: "Wrong password", failed: 1 };
                ctx.failedAttempt();
            } else {
                ctx.auth = { state: "idle", failed: 0 };
                ctx.phase = "leaving";
            }
        }
    }
    Timer { id: reset; interval: 900; onTriggered: ctx.phase = "locked" }

    Choice {
        id: choice
        s: root.s
        name: "Replay"
        availableWidth: root.width
        focused: root.focused
        options: [{ label: "Entry", value: "entry" }, { label: "Typing", value: "typing" },
                  { label: "Error", value: "error" }, { label: "Unlock", value: "unlock" }]
        value: "entry"
        onPicked: (scene) => {
            choice.value = scene;
            root.interacted();
            root.play(scene);
        }
    }

    Rectangle {
        id: stage
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(root.width, 650 * root.s)
        height: Math.round(width * 0.615)
        radius: Metrics.rSm * root.s
        color: Theme.surfaceContainerHigh
        clip: true
        Accessible.ignored: true

        Loader {
            id: view
            width: 1120
            height: 689
            scale: stage.width / width
            transformOrigin: Item.TopLeft
            active: ctx.phase !== "unlocked"
            sourceComponent: LockBoardSurface {
                context: ctx
                screenName: "preview"
                focused: true
                interactive: false
                enabled: false
            }
        }
    }

}
