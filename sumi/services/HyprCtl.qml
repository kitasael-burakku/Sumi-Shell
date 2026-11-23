pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "../lib/hypr-dialect.js" as Dialect

/**
 * El único sitio que le habla a Hyprland con dispatch o config en caliente (portabilidad F5a, 2026-10-10;
 * H-03, HC-61/62). Ningún servicio construye esas cadenas: piden un verbo y `lib/hypr-dialect.js` da la forma
 * del dialecto de esta instancia.
 *
 * El dialecto se averigua UNA vez al arrancar con la sonda inofensiva `hyprctl eval 'local _ = 0'` (no cambia
 * nada; medido en F5a), leyendo la respuesta: el código es 0 en los dos casos, como todo lo cruzado (F0).
 * Hyprland lo fija al arrancar (añadir el otro archivo y recargar no lo cambia, medido), así que no se repite;
 * una shell nueva sobre otra instancia vuelve a preguntar.
 *   pending   aún no ha contestado: los dispatch esperan en cola (como mucho `waitMs`)
 *   lua       config Lua: `hl.dsp.…` y `eval "hl.config({…})"` (lo de antes de F5)
 *   hyprlang  hyprland.conf: dispatchers clásicos y `keyword` (sólo Hyprland ≤ 0.56; CONGELADO el 2026-10-30:
 *             0.57 ya no lee hyprland.conf y la sonda da lua, medido; no se le añade nada nuevo)
 *   unknown   la sonda no aclaró nada (sin Hyprland, hyprctl ausente, otra versión): se usa la forma Lua,
 *             que es lo que hacía la shell hasta F5 (regla de F2: lo no comprobado se ofrece como hoy)
 */
Singleton {
    id: root

    property string dialect: "pending"
    /** Lo que contestó la sonda (diagnóstico: `hyprDialect` por IPC). */
    property string probeReply: ""
    property real checkedAt: 0
    /** La forma que se emite ahora: sólo hyprlang cambia lo de siempre. */
    readonly property string effective: root.dialect === "hyprlang" ? "hyprlang" : "lua"
    readonly property int waitMs: 3000

    property var queue: []

    function summary() {
        return { dialect: root.dialect, effective: root.effective, reply: root.probeReply.slice(0, 120),
                 checkedAt: root.checkedAt, queued: root.queue.length };
    }

    /** El texto que se enviaría (pruebas y `hyprForm` en seco); null si los argumentos no valen. */
    function form(verb, args) { return Dialect.dispatch(root.effective, verb, args); }

    /**
     * Enviar un dispatch. Devuelve false si el verbo o sus argumentos no valen (no se envía nada). Mientras la
     * sonda no contesta, se encola y sale con la forma buena en cuanto se sabe (o con la de antes a los waitMs).
     */
    function dispatch(verb, args) {
        const command = root.form(verb, args);
        if (command === null) {
            console.warn("hyprctl: refusing", verb, JSON.stringify(args));
            return false;
        }
        if (root.dialect === "pending") {
            root.queue = root.queue.concat([{ verb: verb, args: args }]);
            if (!waitTimer.running) waitTimer.start();
            return true;
        }
        Hyprland.dispatch(command);
        return true;
    }

    /** Los argumentos de `hyprctl` para una opción de los modos (blur, animations, cursors, glass), o null. */
    function hotConfigArgs(key, value) { return Dialect.hotConfig(root.effective, key, value); }

    function settle(d, reply) {
        root.probeReply = reply || "";
        root.checkedAt = Date.now() / 1000;
        root.dialect = d;
        waitTimer.stop();
        const q = root.queue;
        root.queue = [];
        for (let i = 0; i < q.length; i++)
            root.dispatch(q[i].verb, q[i].args);
        if (d !== "lua") console.info("hyprctl: config dialect", d, d === "unknown" ? "(" + root.probeReply.slice(0, 80) + ")" : "");
    }

    Process {
        id: probe
        command: ["timeout", "3", "hyprctl", "eval", "local _ = 0"]
        stdout: StdioCollector { id: probeOut }
        stderr: StdioCollector { id: probeErr }
        onExited: root.settle(Dialect.classify(probeOut.text), (probeOut.text || probeErr.text).trim())
        // hyprctl ausente: `running` cae sin `exited` (memoria del proyecto)
        onRunningChanged: if (!running && root.dialect === "pending") Qt.callLater(function () {
            if (root.dialect === "pending") root.settle("unknown", "hyprctl did not run");
        })
    }

    Timer {
        id: waitTimer
        interval: root.waitMs
        onTriggered: if (root.dialect === "pending") root.settle("unknown", "no answer in " + root.waitMs + " ms")
    }

    Component.onCompleted: {
        if (Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")) probe.running = true;
        else root.settle("unknown", "not running under Hyprland");
    }
}
