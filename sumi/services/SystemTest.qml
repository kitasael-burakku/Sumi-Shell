pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Las pruebas de sistema con vuelta atrás (fase 14B): el lado del shell del watchdog.
 *
 * Quien aplica, espera y revierte es `scripts/sumi-guard.py`, una unidad transitoria de
 * systemd que NO depende del shell (futureSettingssurface §7 «Displays y confirmación», §14).
 * Esto sólo:
 *   · lanza la prueba (`launch`) y la registra en `Operations` (recurso `system:<tipo>`, plazo
 *     ABSOLUTO: trasladarla o recargar no lo reinicia);
 *   · sigue su archivo de estado en $XDG_RUNTIME_DIR/sumi-guard/<id>.json;
 *   · pinta la cuenta regresiva (core/TestCountdown, en TODAS las pantallas) y manda Keep o Revert;
 *   · al arrancar (recarga o reinicio), recupera la prueba viva con el mismo plazo, y dice el
 *     resultado de la que terminó mientras no estaba (`list` / `ack`).
 * Si el shell no vuelve, el guard revierte igual cuando vence el plazo.
 *
 * Pruebas: `testOnly` (regex) se pasa como `--only` y el guard se niega a tocar cualquier salida
 * que no case; el IPC de pruebas no lanza nada sin él (como `jobStart` sin comando falso, 6B).
 */
Singleton {
    id: root

    readonly property string dir: Quickshell.env("XDG_RUNTIME_DIR") + "/sumi-guard"
    readonly property string script: Quickshell.shellPath("scripts/sumi-guard.py")
    readonly property int timeoutSec: 15
    /** Pruebas: sólo salidas cuyo nombre case (p. ej. «^KT»). Vacío = sin restricción. */
    property string testOnly: ""

    /** La transacción que se sigue ahora (el JSON del guard), o null. */
    property var txn: null
    /** La última que terminó (para el aviso y el IPC). */
    property var last: null
    property string opId: ""
    property string owner: ""
    property string title: ""
    property string error: ""
    property bool launching: false

    /** Mientras el guard la lleva. «authorizing» (14D): polkit pide la contraseña del checkpoint de
     *  la red; la cuenta regresiva aún no se enseña para no taparle el teclado al diálogo. */
    readonly property var liveStates: ["starting", "authorizing", "applying", "testing", "reverting"]
    readonly property string state: root.txn ? root.txn.state : ""
    readonly property string kind: root.txn ? root.txn.kind : ""
    /** Una línea de lo que se prueba (la red: perfil y cambios). */
    readonly property string detail: root.txn && root.txn.detail ? root.txn.detail : ""
    /** Red: si hay internet ahora mismo, según NetworkManager. */
    readonly property string connectivityText: !root.txn || root.txn.kind !== "network" || !root.txn.connectivity ? ""
        : root.txn.connectivity === "full" ? "Internet works right now"
        : root.txn.connectivity === "limited" || root.txn.connectivity === "portal" ? "Internet is limited right now"
        : root.txn.connectivity === "none" ? "No internet right now" : ""
    readonly property bool live: root.txn !== null && root.liveStates.indexOf(root.state) >= 0
    readonly property bool testing: root.state === "testing"
    property double now: Date.now()
    readonly property int remainingMs: root.testing ? Math.max(0, root.txn.deadline - root.now) : 0

    /** Las cuentas regresivas vivas, por pantalla (pruebas: `sysTestKey` usa la enfocada). */
    property var layers: ({})
    function registerLayer(name, item) {
        const l = Object.assign({}, root.layers);
        if (item) l[name] = item; else delete l[name];
        root.layers = l;
    }

    /** El resultado de una prueba terminada, para el island (UI en inglés). */
    signal finished(string state, string reason, string screen)

    // ---- lanzar ------------------------------------------------------------------------

    /**
     * Probar `proposal` ({salida: {mode, position, scale, transform}}) con vuelta atrás.
     * `label` es lo que dirá la cuenta regresiva («Keep these display settings?»).
     */
    /**
     * Portabilidad F2d: una prueba con vuelta atrás corre en una unidad transitoria
     * (`systemd-run --user`, sumi-guard.py); la de tarjeta usa además pactl y playerctl; la de red,
     * libnm. Sin ellos no se empieza: aplicar sin vuelta atrás garantizada no es una prueba.
     */
    readonly property var needs: ({ "audio-profile": ["audio.profileTest"],
                                    "network": ["network.editProfiles", "session.systemd"] })
    function whyNot(kind) {
        if (Capabilities.userManagerState !== "available")
            return "A systemd user service manager is required for rollback tests";
        return Capabilities.whyFirst(root.needs[kind] || []);
    }

    function start(kind, proposal, owner, label) {
        if (root.live || root.launching) { root.error = "Another test is running"; return false; }
        const why = root.whyNot(kind);
        if (why.length > 0) { root.error = why; return false; }
        const h = Operations.holder("system:" + kind);
        if (h) { root.error = "Another test is running"; return false; }
        root.error = "";
        root.owner = owner || "";
        root.title = label || "Keep these settings?";
        root.launching = true;
        const argv = ["python3", root.script, "launch", kind, JSON.stringify(proposal), "--timeout", String(root.timeoutSec)];
        if (root.testOnly.length > 0) argv.push("--only", root.testOnly);
        launcher.command = argv;
        launcher.kind = kind;
        launcher.running = true;
        return true;
    }
    Process {
        id: launcher
        property string kind: ""
        stdout: StdioCollector {
            onStreamFinished: {
                root.launching = false;
                let r = null;
                try { r = JSON.parse(this.text); } catch (e) { r = null; }
                if (!r || !r.ok) { root.error = r && r.error ? r.error : "Could not start the test"; return; }
                const b = Operations.begin("system-test", "system:" + launcher.kind, "", r.id, root.owner, {});
                root.opId = b.id;
                root.follow(r.id);
            }
        }
        onRunningChanged: if (!running && root.launching) { root.launching = false; root.error = "Could not start the test"; }
    }

    // ---- seguir el archivo del guard ---------------------------------------------------

    function follow(id) {
        txnFile.path = root.dir + "/" + id + ".json";
        txnFile.reload();
        poll.start();
    }
    FileView {
        id: txnFile
        path: ""
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.took(txnFile.text())
    }
    // El guard escribe por renombrado: el vigilante puede perder el archivo nuevo; se relee además
    // con un reloj mientras dura (lectura de un archivo pequeño en tmpfs).
    Timer {
        id: poll
        interval: 200
        repeat: true
        onTriggered: { root.now = Date.now(); if (txnFile.path.length > 0) txnFile.reload(); }
    }

    function took(text) {
        let t = null;
        try { t = JSON.parse(text); } catch (e) { return; }
        if (!t || !t.id) return;
        // el reloj va con el sondeo de 200 ms: sin esto, el primer fotograma de la cuenta usaba la
        // hora de la prueba anterior («Reverting in 56 seconds» con un plazo de 15; medido en la 14F)
        root.now = Date.now();
        const was = root.state;
        root.txn = t;
        if (t.state === "testing" && root.opId.length > 0) {
            const o = Operations.get(root.opId);
            if (o && o.deadline !== t.deadline) Operations.update(root.opId, { deadline: t.deadline, snapshot: t.before || null });
        }
        if (["kept", "reverted", "failed"].indexOf(t.state) >= 0) root.done(t);
        else if (was === "" || was !== t.state) console.info("system-test:", t.id, t.state);
    }

    function done(t) {
        poll.stop();
        txnFile.path = "";
        root.last = t;
        root.txn = null;
        if (root.opId.length > 0)
            Operations.end(root.opId, t.state === "kept" ? "succeeded" : t.state === "failed" ? "failed" : "cancelled",
                           t.reason || "");
        root.opId = "";
        console.info("system-test:", t.id, t.state, t.reason || "");
        ack.command = ["python3", root.script, "ack", t.id];
        ack.running = true;
        root.finished(t.state, t.reason || "", root.owner);
    }
    Process { id: ack }

    // ---- decidir -----------------------------------------------------------------------

    function keep() { return root.decide("keep"); }
    function revert() { return root.decide("revert"); }
    function decide(d) {
        if (!root.testing || decider.running) return false;
        decider.command = ["python3", root.script, "decide", root.txn.id, d];
        decider.running = true;
        return true;
    }
    Process { id: decider }

    // ---- al arrancar: lo que el guard siga haciendo, o lo que terminó sin nosotros -------

    Component.onCompleted: lister.running = true
    Process {
        id: lister
        command: ["python3", root.script, "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                let l = [];
                try { l = JSON.parse(this.text); } catch (e) { l = []; }
                const unseen = [];
                for (const t of l) {
                    const live = root.liveStates.indexOf(t.state) >= 0;
                    if (live && (t.unit === "active" || t.unit === "activating") && !root.txn) {
                        // recuperar: la operación del arranque anterior quedó «unknown»; vuelve a vivir
                        let op = null;
                        for (const id in Operations.ops)
                            if (Operations.ops[id].key === t.id) op = Operations.ops[id];
                        if (op) {
                            Operations.update(op.id, { state: "running", reason: "Recovered after the shell restarted",
                                                       deadline: t.deadline || 0 });
                            root.opId = op.id;
                            root.owner = op.owner;
                        } else {
                            root.opId = Operations.begin("system-test", "system:" + t.kind, "", t.id, "", { deadline: t.deadline || 0 }).id;
                        }
                        root.title = root.titleFor(t.kind);
                        console.info("system-test: recovered", t.id, t.state);
                        root.follow(t.id);
                    } else if (!live && !t.seen) {
                        unseen.push(t);
                        // su operación quedó «unknown · The shell restarted»: el guard sí sabe cómo acabó
                        for (const id in Operations.ops) {
                            const o = Operations.ops[id];
                            if (o.key === t.id && o.state === "unknown")
                                Operations.update(o.id, { state: t.state === "kept" ? "succeeded" : t.state === "failed" ? "failed" : "cancelled",
                                                          reason: (t.reason || "") + " (while the shell was down)" });
                        }
                    }
                }
                // terminadas mientras el shell no estaba: se dice UNA, la más reciente y sólo si es de
                // hace poco (la lista viene de la más nueva a la más vieja); todas quedan vistas
                if (unseen.length > 0) {
                    const t = unseen[0];
                    if (Date.now() - (t.updated || 0) < 5 * 60 * 1000) {
                        root.last = t;
                        root.finished(t.state, (t.reason || "") + " · while the shell was restarting", "");
                    }
                    ack.command = ["python3", root.script, "ack"].concat(unseen.map(x => x.id));
                    ack.running = true;
                }
            }
        }
    }

    // ---- textos --------------------------------------------------------------------------

    function titleFor(kind) {
        return kind === "displays" ? "Keep these display settings?" : kind === "network" ? "Keep these network settings?"
            : kind === "audio-profile" ? "Keep this sound profile?" : "Keep these settings?";
    }
    /**
     * El resultado para el island: CORTO, cabe en la cápsula (≤ ~45 caracteres). El motivo completo
     * sigue en el registro del guard y en Settings («Last change»).
     */
    function resultText(state, reason) {
        const k = root.last ? root.last.kind : "displays";
        const what = k === "network" ? "Network" : k === "audio-profile" ? "Sound profile" : "Display";
        const r = String(reason || "");
        if (state === "kept") return what + (k === "audio-profile" ? " kept" : " settings kept");
        if (state === "failed") {
            if (/Authorization was cancelled/.test(r)) return what + ": password cancelled · nothing changed";
            if (/nothing changed/.test(r)) return what + " test didn't start · nothing changed";
            return what + " test: couldn't restore everything";
        }
        const why = /^No confirmation/.test(r) ? "timed out"
            : /disconnected/.test(r) ? "device disconnected"
            : /stopped|interrupted/.test(r) ? "test interrupted"
            : /^Could not/.test(r) ? "couldn't apply"
            : /reloaded/.test(r) ? "Hyprland reloaded" : "";
        return what + (k === "audio-profile" ? " reverted" : " settings reverted") + (why ? " · " + why : "");
    }

    function summary() {
        return {
            live: root.live, state: root.state, testing: root.testing, remainingMs: root.remainingMs,
            opId: root.opId, owner: root.owner, title: root.title, error: root.error, launching: root.launching,
            testOnly: root.testOnly,
            // F2d: por qué no se puede probar aquí (vacío = sí)
            unavailable: { "audio-profile": root.whyNot("audio-profile"), network: root.whyNot("network") },
            txn: root.txn ? { id: root.txn.id, kind: root.txn.kind, state: root.txn.state, reason: root.txn.reason,
                              deadline: root.txn.deadline, proposal: root.txn.proposal, before: root.txn.before,
                              detail: root.txn.detail || "", connectivity: root.txn.connectivity || "",
                              checkpoint: root.txn.checkpoint || "" } : null,
            last: root.last ? { id: root.last.id, kind: root.last.kind, state: root.last.state, reason: root.last.reason,
                                resumed: root.last.resumed || [],
                                remained: root.last.remained || [], gone: root.last.gone || [] } : null
        };
    }
}
