pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Integraciones del escritorio, en SÓLO LECTURA (fase 14A; la 14F las cierra así: el agente de polkit
 * se enciende o apaga en Settings, avisando si otro tiene la sesión; el servidor de notificaciones sólo
 * se enseña, porque no hay a quién cedérselo).
 *
 * El shell es el único servidor de notificaciones (ADR-29, sin SwayNC) y su agente de polkit es el
 * de la sesión. Esto sólo COMPRUEBA que siga siendo así: quién tiene el nombre
 * org.freedesktop.Notifications y si corre otro agente de polkit conocido. Nunca cambia de dueño.
 *
 * Coste: nada en reposo; lee al reclamarse (Shell → General → Integrations a la vista, IPC).
 */
Singleton {
    id: root

    property var claims: ({})
    readonly property bool active: Object.keys(root.claims).length > 0
    function claim(who, on) {
        if (!!on === !!root.claims[who]) return;
        const c = Object.assign({}, root.claims);
        if (on) c[who] = true; else delete c[who];
        root.claims = c;
    }
    onActiveChanged: if (root.active) root.read()

    property var data: ({})
    property bool loaded: false
    function read() { if (!proc.running) proc.running = true; }
    Process {
        id: proc
        command: ["python3", Quickshell.shellPath("scripts/integrations.py"), "read", String(Quickshell.processId)]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.data = JSON.parse(this.text); root.loaded = true; }
                catch (e) { root.loaded = false; }
            }
        }
    }

    readonly property var notif: root.data.notifications || ({})
    readonly property var polkitOthers: (root.data.polkit && root.data.polkit.others) || []

    /** El dueño del servidor de notificaciones, en palabras. */
    readonly property string notifOwner: !root.loaded ? ""
        : root.notif.shell ? "The shell"
        : root.notif.pid > 0 ? (root.notif.name || "Another program") + " (pid " + root.notif.pid + ")"
        : "Nobody · notifications are not shown"
    readonly property string polkitText: !root.loaded ? ""
        : root.polkitOthers.length > 0 ? "Another agent is running: " + root.polkitOthers.map(a => a.name).join(", ")
        : "No other agent running"

    function summary() {
        return { active: root.active, loaded: root.loaded, notifications: root.notif, notifOwner: root.notifOwner,
                 polkitOthers: root.polkitOthers, polkitText: root.polkitText,
                 polkitRegistered: Polkit.registered, polkitEnabled: Polkit.enabled };
    }
}
