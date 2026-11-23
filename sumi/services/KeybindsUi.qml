pragma Singleton
import QtQuick
import Quickshell

/**
 * La ventana de ayuda de atajos (2026-10-30): sólo el estado de la vista, como CalendarUi. Una instancia, en la pantalla
 * dueña (core/KeybindsLayer). Los datos son de services/Keybinds.
 *
 * `origin` recuerda desde dónde se abrió para devolver el foco al cerrar: desde Settings, `returnRequested` vuelve a la
 * misma fila (lo atiende core/Screens, que puede abrir Settings); desde el Launcher, el IPC o el atajo, el teclado vuelve
 * a la ventana que lo tenía (lo hace Hyprland al soltar la capa). Ejecutar una acción no vuelve: abre lo pedido.
 */
Singleton {
    id: root
    property bool open: false
    property string screen: ""
    /** {query, category, selected, zone} de la última vez; al reabrir la vista sólo recupera la fila elegida. */
    property var context: null
    property var positions: ({})
    property var layer: null
    /** {from: "settings", path} o null. */
    property var origin: null
    signal returnRequested(string screen, var origin)

    function capture() {
        if (root.layer) root.context = root.layer.saveContext();
    }
    function show(name, origin) {
        if (!name || Lock.engaged) return false;
        root.origin = origin || null;
        root.screen = name;
        root.open = true;
        return true;
    }
    /** `back` false: se cierra para ejecutar una acción (no se vuelve al origen). */
    function close(back) {
        if (!root.open) return false;
        root.capture();
        root.open = false;
        const o = root.origin;
        root.origin = null;
        if (back !== false && o && o.from === "settings") root.returnRequested(root.screen, o);
        return true;
    }
    function toggle(name) {
        return root.open && root.screen === name ? root.close() : root.show(name, null);
    }
    function positionOf(name) { return root.positions[name] || null; }
    function remember(name, x, y) {
        const p = Object.assign({}, root.positions);
        p[name] = {x:Math.round(x), y:Math.round(y)};
        root.positions = p;
    }
    function summary() {
        return {open:root.open, screen:root.screen, origin:root.origin, context:root.context,
            layer:root.layer ? root.layer.geometry() : null, view:root.layer ? root.layer.viewState() : null};
    }
}
