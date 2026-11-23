import QtQuick
import "../theme"
import "../services"

/**
 * La base de cada sección de la Audio UI (antes de la fase 14): un Flickable con foco de teclado
 * por id estable, como la surface del Mixer. La capa manda las teclas: ↑↓ recorren `focusList`,
 * ←→ y Enter/Espacio llegan como `activate(id, dir)` (dir −1/+1, 0 = activar).
 *
 * El contorno del foco sólo se pinta tras usar el teclado (`AudioUi.keyNav`): la UI es sobre todo
 * de puntero y un contorno fijo en el primer control sería ruido.
 */
Flickable {
    id: root
    property real s: 1
    property var focusList: []
    property string focusId: ""
    signal activate(string id, int dir)

    contentWidth: width
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    // Si lo enfocado desaparece (un flujo que termina), el foco pasa al primero que siga.
    onFocusListChanged: if (root.focusList.indexOf(root.focusId) < 0)
        root.focusId = root.focusList.length > 0 ? root.focusList[0] : ""

    function step(d) {
        const l = root.focusList;
        if (!l.length) return false;
        const i = l.indexOf(root.focusId);
        root.focusId = i < 0 ? l[0] : l[Math.max(0, Math.min(l.length - 1, i + d))];
        return true;
    }
    /** Pulsar con el ratón mueve el foco ahí (el teclado sigue desde lo último tocado). */
    function pick(id) { root.focusId = id; }

    /** Lo enfocado, a la vista. */
    function reveal(item) {
        if (!item || !AudioUi.keyNav) return;
        const p = item.mapToItem(root.contentItem, 0, 0);
        if (p.y < root.contentY) root.contentY = Math.max(0, p.y - 6 * root.s);
        else if (p.y + item.height > root.contentY + root.height)
            root.contentY = Math.max(0, Math.min(root.contentHeight - root.height, p.y + item.height + 6 * root.s - root.height));
    }
}
