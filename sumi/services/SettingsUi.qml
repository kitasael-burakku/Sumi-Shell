pragma Singleton

import QtQuick
import Quickshell

/**
 * Settings UI independiente (2026-11-07): el ESTADO DE LA VENTANA de Settings. Nada de
 * preferencias: la autoridad sigue siendo `services/Settings` (ConfigStore); aquí sólo vive
 * dónde está la ventana, si está abierta y la vista que se deja al cerrarla.
 *
 * Mismo patrón que la Calendar UI, el monitor y la tienda de Wallhaven: UNA instancia lógica
 * (`open` + `screen`), la capa `core/SettingsLayer` sólo en la pantalla dueña. Pedirla en
 * otra pantalla la lleva allí con su vista (`context`, el `saveContext()` de Settings).
 *
 * Todos los caminos de antes siguen valiendo: el atajo `sumi:settings`, el engranaje del
 * island y de la barra, el IPC `open/toggle/close settings` (y `settingsTheme`,
 * `settingsSystem`), `settingsOpen <ruta>` y los enlaces «Configure…» de otras superficies.
 * Llegan por `core/Screens` (un solo sitio) y terminan aquí.
 *
 * `origin` ({from: superficie}): Settings abierto desde una superficie del island
 * (Configure wallpapers, el ajuste del Mixer…). Esc desde la raíz de Settings vuelve a ella,
 * como antes hacía la pila del host; Close (y el atajo) sólo cierra.
 */
Singleton {
    id: root

    property bool open: false
    property string screen: ""
    /** La vista de Settings al cerrarse o al cambiar de pantalla: página, scroll, fila, plegables. */
    property var context: null
    /** Ruta pedida y aún no aplicada (la ventana se estaba creando). */
    property string pendingPath: ""
    property var origin: null
    property var positions: ({})
    /** Tamaño elegido con la esquina, en unidades lógicas; sólo de la sesión (null = el de Metrics). */
    property var size: null
    property var layer: null
    property int opens: 0
    /** Para el banco: cuántas veces se creó el contenido (no debe crecer al reabrir dentro del plazo). */
    property int builds: 0

    /** Desde fuera se vuelve a una superficie (Esc con origen); lo atiende `core/Screens`. */
    signal returnRequested(string screen, var origin)

    function item() { return root.layer ? root.layer.contentItem() : null; }
    function capture() {
        const it = root.item();
        if (it) root.context = it.saveContext();
    }

    /**
     * Abrir (o traer) en la pantalla `name`; con `path`, además ir a esa página/fila. Devuelve lo
     * que devuelve `openPath` si la ruta se pudo aplicar ya (false si no existe: no enfoca otra
     * fila en su lugar), o true si se aplicará al crearse el contenido.
     */
    function show(name, path, origin) {
        if (!name || Lock.engaged) return false;
        if (root.open && root.screen !== name) root.capture();
        root.origin = origin || null;
        root.pendingPath = path ? String(path) : "";
        root.screen = name;
        if (!root.open) root.opens++;
        root.open = true;
        if (root.layer) root.layer.raise();
        return root.applyPending();
    }
    /** Aplica la ruta pendiente si el contenido ya existe. */
    function applyPending() {
        const it = root.item();
        if (root.pendingPath.length === 0) return true;
        if (!it) return true;
        const p = root.pendingPath;
        root.pendingPath = "";
        return it.openPath(p);
    }
    /** `back`: Esc desde la raíz. Con origen, se vuelve a la superficie de la que se vino. */
    function close(back, force) {
        if (!root.open) return false;
        // un secreto sin enviar: la capa pregunta (Keep editing / Discard and leave) y no se cierra aún
        if (force !== true && root.layer && root.layer.guardBlocks(back === true)) return false;
        root.capture();
        const o = root.origin;
        const scr = root.screen;
        root.origin = null;
        root.pendingPath = "";
        root.open = false;
        if (back === true && o && o.from) root.returnRequested(scr, o);
        return true;
    }
    /** El atajo y el engranaje: en su pantalla, abierta → cierra; si no, se muestra allí. */
    function toggle(name, path) {
        if (root.open && root.screen === name && !path) return root.close(false);
        return root.show(name, path || "", null);
    }

    function positionOf(name) { return root.positions[name] || null; }
    function remember(name, x, y) {
        const p = Object.assign({}, root.positions);
        p[name] = {x: Math.round(x), y: Math.round(y)};
        root.positions = p;
    }

    function summary() {
        return {open: root.open, screen: root.screen, opens: root.opens, builds: root.builds,
            pendingPath: root.pendingPath, origin: root.origin, context: root.context,
            positions: root.positions, size: root.size, layer: root.layer ? root.layer.geometry() : null};
    }
}
