pragma Singleton

import QtQuick
import Quickshell

/**
 * La capa Tasks (etapa B del Dashboard híbrido, 2026-11-09): el ESTADO de su ventana. Los trabajos no
 * viven aquí: son de `Jobs` (y las descargas, de `Downloads`); esta capa sólo los mira, les contesta
 * y los lanza por el mismo camino que la paleta.
 *
 * Una sola instancia lógica, como System Monitor: `open` + `screen`. La abren el nombre `tasks` (IPC
 * `open`/`toggle`, la paleta), el Dashboard (Maintenance, los asuntos de health/doctor, «Output» de la
 * actividad) y el IPC `tasksUi`; pedirla en otra pantalla la LLEVA allí. Cerrarla no toca ningún
 * trabajo.
 *
 * `pick`: lo que pidió quien la abrió (una tarea que elegir y, con `start`, arrancar). La capa lo
 * atiende una vez por `seq`, también si se crea después (LazyLoader).
 */
Singleton {
    id: root

    property bool open: false
    property string screen: ""
    property var positions: ({})
    property var layer: null
    property int opens: 0
    property var pick: ({ id: "", start: false, seq: 0 })

    function show(name, id, start) {
        if (!name) return false;
        root.screen = name;
        if (!root.open) root.opens++;
        root.open = true;
        root.pick = { id: id || "", start: start === true, seq: root.pick.seq + 1 };
        return true;
    }
    /** Cierra sin preguntar (la ventana ya limpió lo que fuera secreto). */
    function close() {
        root.open = false;
        return true;
    }
    /**
     * Cerrar pasando por la ventana: con una passphrase escrita y sin enviar, la ventana pregunta
     * (DESIGN §4: Discard and leave / Keep editing) en vez de cerrarse.
     */
    function requestClose() {
        if (root.layer && root.layer.shown) return root.layer.requestClose();
        return root.close();
    }
    /** Mismo sitio y abierta → cierra; si no, se muestra allí. */
    function toggle(name) {
        if (root.open && root.screen === name) return root.requestClose();
        return root.show(name, "", false);
    }
    function positionOf(name) { return root.positions[name] || null; }
    function remember(name, x, y) {
        const p = Object.assign({}, root.positions);
        p[name] = { x: Math.round(x), y: Math.round(y) };
        root.positions = p;
    }

    function summary() {
        const l = root.layer;
        return Object.assign({ open: root.open, screen: root.screen, opens: root.opens, positions: root.positions },
                             l ? l.state() : { layer: null });
    }
}
