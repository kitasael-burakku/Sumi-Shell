pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Cómo pide la shell el bloqueo: botón Lock, IPC `lock`, menú de energía (portabilidad F5d, 2026-10-10; H-07, HC-46).
 *
 * Hasta F5d era siempre `loginctl lock-session` (con `execDetached`: un fallo no se veía), que sólo bloquea si alguien
 * escucha a logind. En la máquina del autor lo atiende hypridle, cuyo `lock_cmd` llama al helper de la shell; en otra,
 * puede no haber nadie (no bloquea nada) o un hypridle con hyprlock.
 *
 *   Settings.lockEntry = auto    logind si alguien atiende la señal (también hypridle → hyprlock: es la elección del
 *                                usuario); directo si nadie la atiende (capacidad `lock.entry`, scripts/hypridle_conf.py).
 *                                Sin detección todavía, o dudosa: logind (lo de antes).
 *                        logind  siempre `loginctl lock-session`
 *                        direct  siempre el helper de la shell (`scripts/sumi-lock session`) en su scope: la misma red
 *                                que por hypridle (si la shell no bloquea, hyprlock) y la línea `sumi-lock` en el journal
 *
 * Si `loginctl` falla (sin logind, o lo rechaza), se cae al camino directo y se dice en el journal.
 */
Singleton {
    id: root

    readonly property string setting: Settings.lockEntry
    readonly property var cap: Capabilities.caps ? Capabilities.caps["lock.entry"] || null : null
    /** shell · hyprlock · other · none · unknown (lo que detectó capabilities.py). */
    readonly property string listener: root.cap && root.cap.detail && root.cap.detail.listener ? root.cap.detail.listener : "unknown"
    readonly property string effective: root.setting === "logind" ? "logind"
        : root.setting === "direct" ? "direct"
        : (root.listener === "none" ? "direct" : "logind")
    readonly property string helper: Quickshell.shellPath("scripts/sumi-lock")

    /** Lo último que se hizo (diagnóstico: IPC `lockEntry`). */
    property string lastPath: ""
    property string lastError: ""
    property real lastAt: 0

    /** Texto de Settings: quién atiende el bloqueo, en una frase. */
    readonly property string describe: {
        if (root.effective === "direct")
            return root.setting === "direct" ? "Sumi Shell locks directly (set here)"
                : "Nothing listens for lock requests, so Sumi Shell locks directly";
        if (root.listener === "shell") return "Through logind: " + (root.cap.provider || "hypridle → Sumi Shell");
        if (root.listener === "hyprlock") return "Through logind: hypridle runs hyprlock (its lock_cmd)";
        if (root.listener === "other") return "Through logind: " + (root.cap.provider || "another program");
        return "Through logind" + (root.setting === "logind" ? " (set here)" : "");
    }

    function request() {
        root.lastAt = Date.now() / 1000;
        root.lastError = "";
        if (root.effective === "direct")
            return root.direct("direct");
        root.lastPath = "logind";
        logind.running = true;
        return true;
    }

    function direct(why) {
        root.lastPath = why;
        directCheck.restart();
        return Apps.spawn([root.helper, "session"], "sumi-lock");
    }

    /**
     * `Apps.spawn` (systemd-run en un scope, por execDetached) no avisa si no arranca: medido en el banco, sin
     * $XDG_RUNTIME_DIR/systemd/private no se lanza nada. Si a los 3 s la shell no ha empezado a bloquear, se le pide
     * directamente. Si hyprlock ya sostiene la sesión (el helper cayó a él), LockSession no compite (R8).
     */
    Timer {
        id: directCheck
        interval: 3000
        onTriggered: {
            if (Lock.phase !== "unlocked") return;
            root.lastError = "the lock helper did not lock; asked the shell directly";
            console.warn("lock: " + root.lastError);
            root.lastPath = root.lastPath + "+shell";
            Lock.request("session");
        }
    }

    function summary() {
        return { setting: root.setting, effective: root.effective, listener: root.listener,
                 provider: root.cap ? root.cap.provider : "", state: root.cap ? root.cap.state : "",
                 describe: root.describe, helper: root.helper,
                 last: { path: root.lastPath, error: root.lastError, at: root.lastAt } };
    }

    Process {
        id: logind
        command: ["loginctl", "lock-session"]
        stderr: StdioCollector { id: logindErr }
        onExited: (code) => {
            if (code === 0) return;
            root.lastError = (logindErr.text.trim() || ("loginctl exited " + code)).slice(0, 160);
            console.warn("lock: loginctl lock-session failed (" + root.lastError + "); locking directly");
            root.direct("direct-fallback");
        }
        // loginctl ausente: `running` cae sin `started` ni `exited` (memoria del proyecto)
        property bool begun: false
        onStarted: begun = true
        onRunningChanged: {
            if (running) return;
            if (!begun && root.lastPath === "logind") {
                root.lastError = "loginctl could not run";
                console.warn("lock: loginctl could not run; locking directly");
                root.direct("direct-fallback");
            }
            begun = false;
        }
    }
}
