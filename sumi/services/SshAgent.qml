pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Agente SSH efímero para el push de `dotbackup` desde el panel (Fase 10.a,
 * spike del 2026-09-10 — docs/FASE10/SPIKE-DOTBACKUP.md).
 *
 * El problema: `git push` de `dotbackup` va por SSH y la clave del usuario
 * (`~/.ssh/id_ed25519`) tiene passphrase. `ssh` la pide por `/dev/tty`, no por
 * stdin, así que el `Process` del panel no puede contestarla y el push falla en
 * silencio. Y la sesión no tiene ningún `ssh-agent`.
 *
 * La solución: el shell arranca su PROPIO `ssh-agent` (no toca el de gpg ni el
 * de la sesión), le añade la clave con la passphrase que el usuario teclea en
 * el panel —vía `scripts/ssh-askpass`, con `SUMI_SSH_PASS` puesto SÓLO en el
 * entorno de ese `ssh-add`— y expone `sock` para pasárselo a `dotbackup` en su
 * `environment`. La clave descifrada vive en la memoria del agente; el agente
 * muere al reiniciar el shell (o con `lock()`).
 *
 * SEGURIDAD: la passphrase nunca toca argv, disco ni el journal. Está en
 * `/proc/<pid>/environ` de ese `ssh-add` (0600, sólo el propio usuario) los
 * ~200 ms que corre, y en un `var` de QML que se limpia justo después.
 */
Singleton {
    id: root

    /**
     * F3d-1 (HC-27): la clave la puede declarar la tarea que pide el agente (`sshKey` en tasks.json); si
     * no, la de siempre. `SUMI_SSH_KEY` sigue mandando (pruebas).
     */
    readonly property var keyTask: { for (const t of Tasks.tasks) if (t.sshAgent) return t; return null; }
    readonly property string keyPath: Quickshell.env("SUMI_SSH_KEY")
        || (root.keyTask && root.keyTask.sshKey ? root.keyTask.sshKey : "")
        || (Quickshell.env("HOME") + "/.ssh/id_ed25519")
    readonly property string helper: Quickshell.shellDir + "/scripts/ssh-askpass"
    readonly property string rt: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
    readonly property string sockPath: root.rt + "/sumi-ssh-agent.sock"
    readonly property string guardPath: root.rt + "/sumi-ssh-guard"

    /** Socket del agente propio, "" hasta que arranca. */
    property string sock: ""
    property int agentPid: 0
    /** ¿la clave está cargada en NUESTRO agente? */
    property bool keyLoaded: false
    property bool busy: false
    /** idle | starting | checking | unlocking | ready | error */
    property string state: "idle"
    property string lastError: ""

    signal unlocked()
    signal unlockFailed(string reason)

    property string _pendingPass: ""

    // ---- API ------------------------------------------------------------

    /** Arranca el agente si hace falta y comprueba si la clave ya está. */
    function prepare() {
        if (root.sock.length > 0) { root.check(); return; }
        if (root.state === "starting") return;
        root.state = "starting";
        root.busy = true;
        // limpia un agente huérfano de una sesión anterior antes de arrancar:
        // pkill (por el path del socket, no `sh -c`) -> rm -f -> ssh-agent.
        killOld.running = true;
    }

    function check() {
        if (root.sock.length === 0) { root.prepare(); return; }
        root.state = "checking";
        listProc.running = true;
    }

    /** Añade la clave con `passphrase`. Arranca el agente antes si hace falta. */
    function unlock(passphrase) {
        root._pendingPass = passphrase;
        if (root.sock.length === 0) { root.prepare(); return; }   // sigue en startProc.onExited
        root._runUnlock();
    }

    /** Descarga la clave y mata el agente. */
    function lock() {
        root.keyLoaded = false;
        root.state = "idle";
        if (root.agentPid > 0)
            Quickshell.execDetached(["kill", String(root.agentPid)]);
        root.agentPid = 0;
        root.sock = "";
    }

    Component.onDestruction: {
        if (root.agentPid > 0)
            Quickshell.execDetached(["kill", String(root.agentPid)]);
    }

    function _runUnlock() {
        root.state = "unlocking";
        root.busy = true;
        rmGuard.running = true;   // borra el guard; addProc va detrás
    }

    // ---- procesos ------------------------------------------------------

    Process {
        id: killOld
        command: ["pkill", "-f", "ssh-agent -a " + root.sockPath]
        onExited: rmSock.running = true
    }

    Process {
        id: rmSock
        command: ["rm", "-f", root.sockPath]
        onExited: startProc.running = true
    }

    Process {
        id: startProc
        command: ["ssh-agent", "-a", root.sockPath]
        stdout: StdioCollector {
            onStreamFinished: {
                const m = /SSH_AGENT_PID=(\d+)/.exec(this.text);
                if (m) {
                    root.agentPid = parseInt(m[1], 10);
                    root.sock = root.sockPath;
                }
            }
        }
        onExited: (code) => {
            root.busy = false;
            if (root.sock.length === 0) {
                root.state = "error";
                root.lastError = "ssh-agent no arrancó (exit " + code + ")";
                if (root._pendingPass.length > 0) {
                    root._pendingPass = "";
                    root.unlockFailed(root.lastError);
                }
                return;
            }
            if (root._pendingPass.length > 0) root._runUnlock();
            else root.check();
        }
    }

    Process {
        id: listProc
        command: ["ssh-add", "-l"]
        environment: ({ "SSH_AUTH_SOCK": root.sock })
        stdout: StdioCollector { id: listOut }
        onExited: (code) => {
            root.keyLoaded = (code === 0) && listOut.text.trim().length > 0;
            root.state = root.keyLoaded ? "ready" : "idle";
            root.busy = false;
        }
    }

    Process {
        id: rmGuard
        command: ["rm", "-f", root.guardPath]
        onExited: addProc.running = true
    }

    Process {
        id: addProc
        command: ["ssh-add", root.keyPath]
        environment: ({
            "SSH_AUTH_SOCK": root.sock,
            "SSH_ASKPASS": root.helper,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": ":0",
            "SUMI_SSH_PASS": root._pendingPass,
            "SUMI_SSH_GUARD": root.guardPath
        })
        stderr: StdioCollector { id: addErr }
        onExited: (code) => {
            root._pendingPass = "";                 // fuera de memoria
            root.busy = false;
            if (code === 0) {
                root.keyLoaded = true;
                root.state = "ready";
                root.unlocked();
            } else {
                root.state = "idle";
                const e = addErr.text.trim();
                root.unlockFailed(e.length > 0 ? e.split("\n").pop() : "wrong passphrase");
            }
        }
    }
}
