pragma Singleton
import QtQuick
import Quickshell

/**
 * Ventana Login screen (Sumi SDDM, 2026-11-23): sólo el estado de la vista. Los datos son de SddmTheme (y, por
 * debajo, de la orden `sumi-sddm`); esta ventana es un cliente más, como Settings → Desktop tools → Login screen.
 *
 *   page       grupo del esquema a la vista («background», «notch»…) o «system»; se recuerda entre aperturas
 *   focusKey   una clave a enfocar al abrir (la búsqueda de Settings); se consume al llegar
 *   origin     {from: "settings", path} si se abrió desde Settings: Esc vuelve allí, a esa fila
 *   scenePinned  la escena de la vista previa la eligió la persona: deja de seguir al grupo hasta cerrar
 *
 * Mientras una orden con pkexec espera la contraseña la ventana no se cierra: queda pedido y se cierra al acabar.
 */
Singleton {
    id: root
    property bool open: false
    property string screen: ""
    property string page: ""
    property string focusKey: ""
    property var origin: null
    property var positions: ({})
    property var size: null
    property var layer: null
    property bool scenePinned: false
    /** Tamaño de la vista previa: «screen» (el de este monitor) o «AnchoxAlto». */
    property string previewPick: "screen"
    /** Se pidió cerrar con una orden de sistema en marcha: se cierra al acabar. */
    property bool closePending: false
    property var _closeArgs: null
    signal returnRequested(string screen, var origin)

    /**
     * Abrir (o traer) en la pantalla `name`. `page`: "" = la última; un grupo; "system"; o "key:<clave>" para ir a
     * su grupo y enfocarla.
     */
    function show(name, page, origin) {
        if (!name || Lock.engaged) return false;
        const p = String(page || "");
        if (p.indexOf("key:") === 0) {
            const k = p.slice(4);
            const e = SddmTheme.keys[k];
            root.focusKey = k;
            if (e) root.page = String(e.group);
        } else if (p.length > 0) {
            root.page = p;
            root.focusKey = "";
        }
        root.origin = origin || null;
        root.closePending = false;
        root.screen = name;
        root.open = true;
        if (root.layer && root.layer.raise) root.layer.raise();
        return true;
    }
    /** `back`: Esc desde la raíz; con origen, se vuelve a la superficie de la que se vino. */
    function close(back) {
        if (!root.open) return false;
        if (SddmTheme.systemBusy !== "") {
            root.closePending = true;
            root._closeArgs = { back: back === true };
            return false;
        }
        const o = root.origin, scr = root.screen;
        root.origin = null;
        root.open = false;
        root.closePending = false;
        root.scenePinned = false;
        if (back === true && o && o.from === "settings") root.returnRequested(scr, o);
        return true;
    }
    function toggle(name) {
        if (root.open && root.screen === name) return root.close(false);
        return root.show(name, "", null);
    }
    Connections {
        target: SddmTheme
        function onSystemBusyChanged() {
            if (SddmTheme.systemBusy === "" && root.closePending) {
                const a = root._closeArgs || { back: false };
                root.closePending = false;
                Qt.callLater(() => root.close(a.back));
            }
        }
    }

    function positionOf(name) { return root.positions[name] || null; }
    function remember(name, x, y) {
        const p = Object.assign({}, root.positions);
        p[name] = { x: Math.round(x), y: Math.round(y) };
        root.positions = p;
    }
    function summary() {
        return { open: root.open, screen: root.screen, page: root.page, focusKey: root.focusKey, origin: root.origin,
                 scenePinned: root.scenePinned, closePending: root.closePending, positions: root.positions,
                 size: root.size, layer: root.layer ? root.layer.geometry() : null };
    }
}
