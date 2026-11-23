pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../lib/session-backend.js" as SessionBackend

/**
 * The session: staying awake, locking, and noticing when the machine comes
 * back from sleep.
 *
 * Locking is NOT implemented here and never will be (ADR: docs/LOCKSCREEN.md).
 * `lock()` asks logind, which fires hypridle's `lock_cmd`, which runs hyprlock
 * — the same path `before_sleep_cmd` and the SUPER+ALT+H keybind already take,
 * so there is exactly one lock in the rice and PAM stays in hyprlock's hands.
 *
 * Keep-awake holds TWO inhibitors on purpose:
 *   · the Wayland one (zwp_idle_inhibit) stops the compositor's own idle/DPMS;
 *   · a logind one (`systemd-inhibit --what=idle:sleep --mode=block`) is the
 *     wire hypridle actually respects — it runs its own timers and never sees
 *     the Wayland inhibitor.
 * Measured on this machine: with only the Wayland inhibitor, hypridle still
 * fires. Both together, it does not. See docs/MIGRATION.md § Fase 3.
 */
Singleton {
    id: root

    /**
     * Mirror of the persisted flag, never assigned directly: writing to a bound
     * property severs the binding, which is exactly how Ukishima's Flags/ScreenRec
     * pair stops following the file (docs/STATE.md § duplicados). Settings is the
     * single source; setKeepAwake writes there and this follows.
     */
    readonly property bool keepAwake: Settings.keepAwake
    readonly property string powerBackend: SessionBackend.backend(Capabilities.source, Capabilities.helper,
                                                                  Capabilities.report)
    property bool keepAwakeEffective: false
    property string keepAwakeError: ""
    function holdCommand(what, who, why) {
        const owner = String(Quickshell.processId);
        if (root.powerBackend === "login1")
            return ["python3", Quickshell.shellPath("scripts/login1-inhibit.py"), what, who, why, owner];
        if (root.powerBackend === "systemd")
            return ["systemd-inhibit", "--what=" + what, "--who=" + who, "--why=" + why,
                    "--mode=block", "python3", Quickshell.shellPath("scripts/mode-idle-guard.py"), owner];
        return [];
    }

    /**
     * Is anybody there? (QS-FUNC-018.) The claim gates already ask "is anybody
     * looking at this surface?"; this adds "is anybody at the machine?". An
     * open system surface used to sample at 1 s all night.
     *
     * ext-idle-notify, not a poll. `respectInhibitors: true` on purpose: a video
     * holding an idle inhibitor, or keep-awake itself, means someone is there,
     * so the gates stay open — the two features cannot fight (keep-awake just
     * means no savings while it is on).
     *
     * `forceIdle` exists only for IPC (`idleForce`): exercising the gates must
     * not require walking away from the machine for two minutes.
     */
    readonly property int idleTimeoutSec: 120
    property bool forceIdle: false
    readonly property bool idle: idleMonitor.isIdle || root.forceIdle

    IdleMonitor {
        id: idleMonitor
        timeout: root.idleTimeoutSec
        respectInhibitors: true
    }

    // Reclamación temporal del motor, separada de Keep awake y sin inhibir sleep.
    property bool modeIdleWanted: false
    property bool modeInhibited: false
    property var modeIdleCallback: null
    function claimModeIdle(wanted, done) {
        if (root.modeIdleCallback) { done({ok: false, reason: "An idle claim is already pending"}); return; }
        if (wanted && !root.powerBackend) {
            Capabilities.refresh("idle inhibition");
            done({ok: false, reason: "No verified login manager for idle inhibition"});
            return;
        }
        root.modeIdleWanted = wanted;
        if (wanted && root.modeInhibited) { done({ok: true}); return; }
        if (!wanted && !modeInhibitor.running) { root.modeInhibited = false; done({ok: true}); return; }
        root.modeIdleCallback = done;
        modeDeadline.restart();
        if (wanted) {
            modeInhibitor.stdinEnabled = true;
            modeInhibitor.command = root.holdCommand("idle", "Sumi Shell modes", "temporary desktop mode");
            modeInhibitor.running = true;
        } else modeInhibitor.stdinEnabled = false;
    }
    function modeSettled(ok, reason) {
        modeDeadline.stop();
        const cb = root.modeIdleCallback; root.modeIdleCallback = null;
        if (cb) cb({ok: ok, reason: reason || ""});
    }
    Process {
        id: modeInhibitor
        stderr: StdioCollector { id: modeErr }
        stdout: SplitParser {
            onRead: line => {
                if (line.trim() === "READY" && root.modeIdleWanted && modeDeadline.running) {
                    root.modeInhibited = true;
                    root.modeSettled(true, "");
                }
            }
        }
        onExited: {
            root.modeInhibited = false;
            root.modeSettled(!root.modeIdleWanted,
                             root.modeIdleWanted ? (modeErr.text.trim() || "Idle inhibition ended") : "");
        }
    }
    Timer {
        id: modeDeadline
        interval: 4000
        onTriggered: {
            modeInhibitor.stdinEnabled = false;
            root.modeInhibited = false;
            root.modeSettled(false, "Could not acquire the idle inhibitor");
        }
    }


    /** Bumped every time the machine wakes from suspend; surfaced by IPC status. */
    property int resumeCount: 0
    property bool preparingForSleep: false
    signal resumed()

    /** F5d: logind o directo según `shell.lock.entry` y quién atiende la señal (services/LockEntry). */
    function lock() {
        return LockEntry.request();
    }

    function setKeepAwake(on) {
        Settings.keepAwake = on === true;
        return root.keepAwake;
    }

    function toggleKeepAwake() {
        return root.setKeepAwake(!root.keepAwake);
    }

    /** A 1×1 background surface: the Wayland inhibitor has to hang off a window. */
    PanelWindow {
        id: inhibitWin
        visible: root.keepAwake
        implicitWidth: 1
        implicitHeight: 1
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Background
        WlrLayershell.namespace: "sumi-shell-inhibit"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        anchors { top: true; left: true }

        IdleInhibitor {
            window: inhibitWin
            enabled: root.keepAwake
        }
    }

    /**
     * The logind inhibitor. `running` is driven imperatively, never bound:
     * assigning to a bound property severs the binding, and the respawn below
     * has to assign. Measured: if this process dies (OOM, a stray kill) nothing
     * brought it back, so keep-awake kept claiming to be on while hypridle was
     * free to lock. It now comes back, with a budget so a systemd-inhibit that
     * cannot start at all does not spin.
     */
    Process {
        id: logindInhibitor
        stdinEnabled: true
        stderr: StdioCollector { id: inhibitErr }
        stdout: SplitParser {
            onRead: line => {
                if (line.trim() === "READY" && root.keepAwake && inhibitReadyDeadline.running) {
                    inhibitReadyDeadline.stop();
                    stable.restart();
                    root.keepAwakeEffective = true;
                    root.keepAwakeError = "";
                }
            }
        }
        onStarted: inhibitReadyDeadline.restart()
        onExited: {
            inhibitReadyDeadline.stop();
            stable.stop();
            root.keepAwakeEffective = false;
            root.keepAwakeError = inhibitErr.text.trim() || root.keepAwakeError || "The sleep inhibitor ended";
            if (!root.keepAwake) {
                root.keepAwakeError = "";
                return;
            }
            if (root.inhibitRestarts >= 5) {
                console.warn("session: sleep inhibitor keeps dying, giving up:", root.keepAwakeError);
                return;
            }
            root.inhibitRestarts++;
            respawn.restart();
        }
    }

    property int inhibitRestarts: 0

    function syncInhibitor() {
        if (root.keepAwake && root.powerBackend) {
            if (!logindInhibitor.running) {
                root.keepAwakeError = "";
                logindInhibitor.stdinEnabled = true;
                logindInhibitor.command = root.holdCommand("idle:sleep", "Sumi Shell", "keep awake");
                logindInhibitor.running = true;
            }
        } else {
            respawn.stop();
            logindInhibitor.stdinEnabled = false;
            logindInhibitor.running = false;
            root.keepAwakeEffective = false;
            if (root.keepAwake) {
                root.keepAwakeError = "No verified login manager for sleep inhibition";
                Capabilities.refresh("keep awake inhibition");
            } else root.keepAwakeError = "";
        }
    }

    onKeepAwakeChanged: {
        root.inhibitRestarts = 0;
        root.syncInhibitor();
    }
    onPowerBackendChanged: {
        if (logindInhibitor.running) {
            logindInhibitor.running = false;
        } else root.syncInhibitor();
        if (modeInhibitor.running) modeInhibitor.stdinEnabled = false;
    }
    Component.onCompleted: {
        root.syncInhibitor();
        sleepWatcher.running = true;
    }

    Timer {
        id: respawn
        interval: 1000
        onTriggered: if (root.keepAwake) root.syncInhibitor()
    }

    Timer {
        id: inhibitReadyDeadline
        interval: 4000
        onTriggered: {
            if (root.keepAwakeEffective) return;
            root.keepAwakeError = "Could not acquire the sleep inhibitor";
            logindInhibitor.running = false;
        }
    }

    /** Alive for ten seconds means the process is healthy; forget past deaths. */
    Timer {
        id: stable
        interval: 10000
        onTriggered: root.inhibitRestarts = 0
    }

    /**
     * logind broadcasts PrepareForSleep(true) before suspending and (false) on
     * wake. The wake edge is what the shell needs: monotonic timers (SystemClock
     * included) do not advance while suspended, so anything driven by one shows
     * a frozen pre-sleep value until it drains. One watcher for the whole shell,
     * not one per monitor.
     *
     * Same respawn discipline as the logind inhibitor above
     * (QS-FUNC-002). It used to be `running: true` by binding plus
     * `onExited: running = true`: no delay and no budget, so a dbus-monitor
     * that exits at once (binary gone after an update, system bus not up yet,
     * a D-Bus policy rejecting the match) became a tight fork loop — and the
     * assignment severed the binding anyway. `running` is now driven by hand
     * and started from Component.onCompleted above.
     */
    Process {
        id: sleepWatcher
        command: ["dbus-monitor", "--system",
                  "type='signal',sender='org.freedesktop.login1',path='/org/freedesktop/login1',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'"]
        stdout: SplitParser {
            onRead: (line) => {
                if (line.trim() === "boolean true") root.preparingForSleep = true;
                else if (line.trim() === "boolean false" && root.preparingForSleep) {
                    root.preparingForSleep = false;
                    root.resumeCount++;
                    root.resumed();
                }
            }
        }
        onStarted: sleepStable.restart()
        onExited: {
            sleepStable.stop();
            if (root.sleepRestarts >= 5) {
                console.warn("session: dbus-monitor keeps dying, giving up; resume from sleep will go unnoticed");
                return;
            }
            root.sleepRestarts++;
            sleepRespawn.restart();
        }
    }

    property int sleepRestarts: 0
    /** Surfaced by IPC status: without the watcher, resumeCount stops meaning anything. */
    readonly property bool watchingSleep: sleepWatcher.running

    Timer {
        id: sleepRespawn
        interval: 2000
        onTriggered: sleepWatcher.running = true
    }

    /** Alive for ten seconds means the watcher is healthy; forget past deaths. */
    Timer {
        id: sleepStable
        interval: 10000
        onTriggered: root.sleepRestarts = 0
    }
}
