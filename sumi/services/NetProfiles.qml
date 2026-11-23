pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Perfiles guardados de NetworkManager (Settings → System → Network; lectura 14A, edición 14D).
 *
 * `services/Net` sigue siendo el dueño de conectar, desconectar y olvidar; esto enseña y EDITA
 * autoconnect, prioridad, metered, DNS e IPv4 (decisión del usuario, 2026-09-29), por dos caminos:
 *   · lo que no puede cortar nada (un perfil inactivo, o autoconnect/prioridad/metered): se guarda
 *     directo con `nm-profiles.py apply`, y *Undo* lo devuelve;
 *   · DNS e IPv4 de un perfil ACTIVO: prueba con vuelta atrás (`SystemTest`, tipo `network`): el
 *     guard crea un checkpoint de NetworkManager (polkit pide la contraseña), aplica en memoria,
 *     comprueba, cuenta 15 s y guarda en disco sólo con Keep.
 * `scripts/nm-profiles.py` nunca pide secretos.
 *
 * Coste: nada en reposo. Lee al reclamarse y otra vez cuando cambia la conexión (Net), con
 * respiro, mientras siga reclamado.
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
    onActiveChanged: {
        if (root.active) root.read();
        else { debounce.stop(); root.data = ({}); root.loaded = false; root.error = ""; }
    }

    property var data: ({})
    property bool loaded: false
    property string error: ""
    property int reads: 0
    property bool again: false
    readonly property var profiles: root.data.profiles || []
    readonly property var checkpoints: root.data.checkpoints || ({ supported: false, permission: "unknown" })

    /** Portabilidad F2d: leer y editar perfiles necesita libnm y PyGObject (`nm-profiles.py`). */
    readonly property string whyNot: Capabilities.whyFirst(["network.editProfiles"])

    function read() {
        if (root.whyNot.length > 0) { root.error = root.whyNot; root.loaded = false; return; }
        if (proc.running) { root.again = true; return; }
        proc.running = true;
    }
    Process {
        id: proc
        command: ["python3", Quickshell.shellPath("scripts/nm-profiles.py"), "read"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const o = JSON.parse(this.text);
                    if (o.error) root.error = o.error;
                    else { root.data = o; root.error = ""; root.loaded = true; }
                } catch (e) {
                    root.error = "Could not read the saved networks";
                }
                root.reads++;
            }
        }
        onRunningChanged: if (!running && root.again) { root.again = false; root.read(); }
    }
    Timer { id: debounce; interval: 800; onTriggered: if (root.active) root.read() }
    // la conexión cambió: los perfiles activos también
    readonly property string netKey: Net.kind + "|" + Net.connected + "|" + Net.ssid + "|" + Net.wiredUp
    onNetKeyChanged: if (root.active) debounce.restart()

    // ---- 14D: guardar ------------------------------------------------------------------------

    /** Lo que puede cortar una conexión activa (el mismo RISKY de scripts/nm_edit.py). */
    readonly property var risky: ["ipv4Method", "addresses", "gateway", "dns", "ignoreAutoDns"]
    /** {ok, uuid, name, detail, undo, active, error, needsTest, undone, at} del último guardado directo. */
    property var lastSave: null
    property bool saving: false
    property string saveOpId: ""
    function byUuid(uuid) { return root.profiles.find(p => p.uuid === uuid) || null; }
    function needsTest(p, props) { return !!p && p.active && Object.keys(props).some(k => root.risky.indexOf(k) >= 0); }
    /** Guardar `props` en el perfil. Devuelve false si no se pudo ni empezar (el motivo, en lastSave). */
    function save(uuid, props, owner) {
        const p = root.byUuid(uuid);
        if (!p) return false;
        if (root.whyNot.length > 0) {
            root.lastSave = { ok: false, uuid: uuid, error: root.whyNot, at: Date.now() };
            return false;
        }
        if (root.saving || SystemTest.live || SystemTest.launching) {
            root.lastSave = { ok: false, uuid: uuid, error: "Another network change is in progress", at: Date.now() };
            return false;
        }
        if (root.needsTest(p, props))
            return SystemTest.start("network", { uuid: uuid, props: props }, owner || "", SystemTest.titleFor("network"));
        const b = Operations.begin("net-profile", "net-profile:" + uuid, "settings", p.name, owner || "", {});
        if (!b.id) {
            root.lastSave = { ok: false, uuid: uuid, error: "Another change to this network is in progress", at: Date.now() };
            return false;
        }
        root.saveOpId = b.id;
        root.saving = true;
        saver.undoing = false;
        saver.command = ["python3", Quickshell.shellPath("scripts/nm-profiles.py"), "apply", uuid, JSON.stringify(props)];
        saver.running = true;
        return true;
    }
    /** Deshacer el último guardado directo (el de una prueba ya se decidió con Keep o Revert). */
    function undo(owner) {
        const l = root.lastSave;
        if (!l || !l.ok || !l.undo || l.undone) return false;
        const ok = root.save(l.uuid, l.undo, owner);
        if (ok && root.saving) saver.undoing = true;
        return ok;
    }
    Process {
        id: saver
        property bool undoing: false
        stdout: StdioCollector {
            onStreamFinished: {
                let r;
                try { r = JSON.parse(this.text); } catch (e) { r = { error: "The helper gave no answer" }; }
                r.ok = !r.error;
                r.at = Date.now();
                r.undone = saver.undoing;
                if (saver.undoing && r.ok) r.undo = null;          // deshacer no se deshace
                root.lastSave = r;
                root.saving = false;
                if (root.saveOpId.length > 0) Operations.end(root.saveOpId, r.ok ? "succeeded" : "failed", r.error || "");
                root.saveOpId = "";
                if (root.active) root.read();
            }
        }
    }
    // una prueba de red terminó: el perfil pudo cambiar
    Connections {
        target: SystemTest
        function onFinished(state, reason, screen) { if (SystemTest.last && SystemTest.last.kind === "network" && root.active) root.read(); }
    }
    /** El resultado del último guardado, en una línea (inglés). */
    function saveText(r) {
        if (!r) return "";
        if (!r.ok) return r.error || "Could not save";
        return (r.undone ? "Undone · " : "Saved · ") + r.name + " · " + r.detail
            + (r.active && !r.undone ? " · applies the next time it connects" : "");
    }

    function kindName(t) {
        return t === "802-3-ethernet" ? "Ethernet" : t === "802-11-wireless" ? "Wi-Fi" : t === "bluetooth" ? "Bluetooth"
            : t === "dummy" ? "Virtual" : t === "vpn" || t === "wireguard" ? "VPN" : t;
    }
    /** Una línea con lo que la 14F podrá editar, tal como está. */
    function describe(p) {
        const parts = [];
        parts.push(p.autoconnect ? "Connects automatically" + (p.priority !== 0 ? " (priority " + p.priority + ")" : "")
                                 : "Manual");
        if (p.metered === "yes") parts.push("metered");
        const v4 = p.ipv4;
        if (v4) {
            parts.push(v4.method === "auto" ? "IPv4 automatic" : v4.method === "manual"
                       ? "IPv4 " + (v4.addresses[0] || "manual") : v4.method === "disabled" ? "IPv4 off" : "IPv4 " + v4.method);
            if (v4.dns.length > 0) parts.push("DNS " + v4.dns.join(", ") + (v4.ignoreAutoDns ? " only" : ""));
        }
        return parts.join(" · ");
    }
    /** El rollback de NetworkManager, en palabras. */
    readonly property string rollbackText: !root.loaded ? "" : !root.checkpoints.supported ? "Not supported by this NetworkManager"
        : root.checkpoints.permission === "yes" ? "Available"
        : root.checkpoints.permission === "auth" ? "Available · asks for your password"
        : root.checkpoints.permission === "no" ? "Not allowed for this user" : "Unknown"

    function summary() {
        return { active: root.active, loaded: root.loaded, error: root.error, reads: root.reads,
                 version: root.data.version || "", checkpoints: root.checkpoints, rollback: root.rollbackText,
                 modifySystem: root.data.modifySystem || "", profiles: root.profiles,
                 saving: root.saving, lastSave: root.lastSave, lastSaveText: root.saveText(root.lastSave) };
    }
}
