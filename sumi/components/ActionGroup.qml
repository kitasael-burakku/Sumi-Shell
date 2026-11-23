pragma ComponentBehavior: Bound

import QtQuick
import "../theme"

/**
 * Grupo de acciones dinamico (auditoria del 2026-09-09).
 *
 * Existe porque el problema no era de wifi: era de **suponer que siempre hay
 * el mismo numero de botones**. La ficha de red los colocaba con `anchors` a
 * posiciones fijas y guardaba el foco como un indice 0..2 constante, asi que
 * con una red no guardada (donde dos acciones desaparecen) el foco apuntaba a
 * botones inexistentes y el campo de contrasena se solapaba con ellos.
 *
 * Aqui la lista manda: se le pasan las acciones y el grupo **se dibuja, se
 * mide y se navega solo**. Si una aparece o desaparece, el layout se recoloca
 * y el foco se vuelve a acotar a lo que de verdad se ve.
 *
 *     actions: [
 *         { id: "connect", label: "Conectar", primary: true },
 *         { id: "forget",  label: "Olvidar",  danger: true, confirm: true, visible: known }
 *     ]
 *
 * Campos por accion: `id` · `label` · `visible` (por defecto true) ·
 * `primary` · `danger` · `confirm` (pide un segundo Enter) · `enabled` · `glyphTint` (opcional).
 *
 * Sirve igual para bluetooth o para cualquier superficie futura: no sabe nada
 * de redes.
 */
Item {
    id: root

    property real s: 1
    property var actions: []
    /** "vertical" usa arriba/abajo; "horizontal" usa izquierda/derecha. */
    property string orientation: "vertical"
    /**
     * Cuando es false, ningún botón se pinta enfocado: el foco de teclado está
     * en otra sección de la superficie. No toca `current` (se recuerda para
     * cuando el grupo recupere el foco), sólo el realce.
     */
    property bool active: true
    property real spacing: 6 * root.s
    /** Optional logical row height; zero retains the existing button sizing. */
    property real minimumRowHeight: 0
    /** En vertical, los botones ocupan todo el ancho salvo que se diga que no. */
    property bool stretch: true
    /** Glifo grande arriba y etiqueta debajo, para las rejillas horizontales. */
    property bool stacked: false

    signal triggered(string id)
    /** El ratón entró en una acción: la superficie puede mover aquí su sección. */
    signal hovered(string id)
    /**
     * Si el hover mueve también el foco de teclado. `true` por compatibilidad (el
     * Dashboard mueve su sección con `hovered`); el contrato del rediseño (DESIGN §3)
     * los quiere independientes y cada superficie lo apaga en su fase: Power, ARR-05.
     * Apagado, el botón señalado sólo se pinta (hover de `ActionButton`).
     */
    property bool hoverMovesFocus: true

    readonly property bool vertical: root.orientation === "vertical"

    /** Lo unico que existe para navegar y medir: lo que de verdad se ve. */
    readonly property var shown: {
        const out = [];
        for (let i = 0; i < root.actions.length; i++) {
            const a = root.actions[i];
            if (a && a.visible !== false) out.push(a);
        }
        return out;
    }
    readonly property int count: root.shown.length

    /** Indice sobre `shown`, nunca sobre `actions`. */
    property int current: 0
    /** `id` de la accion que espera confirmacion, o "". */
    property string confirming: ""

    readonly property string currentId: (root.current >= 0 && root.current < root.count)
        ? root.shown[root.current].id : ""

    /**
     * Cuando cambia lo visible, el foco se re-acota. Sin esto el foco se queda
     * apuntando a una accion que ya no existe, que es el fallo que se venia
     * arrastrando.
     */
    onCountChanged: root.clampFocus()
    function clampFocus() {
        if (root.count === 0) { root.current = 0; return; }
        if (root.current >= root.count) root.current = root.count - 1;
        if (root.current < 0) root.current = 0;
        if (root.confirming.length > 0 && root.currentId !== root.confirming)
            root.confirming = "";
    }

    function reset() { root.current = 0; root.confirming = ""; }

    function move(delta) {
        if (root.count === 0) return false;
        const next = root.current + delta;
        if (next < 0 || next >= root.count) return false;   // deja pasar el borde
        root.current = next;
        root.confirming = "";
        return true;
    }

    function activateAt(i) {
        if (i < 0 || i >= root.count) return false;
        const a = root.shown[i];
        if (a.enabled === false) return false;
        if (a.confirm === true && root.confirming !== a.id) {
            root.current = i;
            root.confirming = a.id;
            return true;
        }
        root.confirming = "";
        root.triggered(a.id);
        return true;
    }

    /** 16B: Tab y Mayús+Tab como las flechas. Opt-in: Dashboard y ServiceDetail ya usan Tab. */
    property bool tabMoves: false

    function activate() { return root.activateAt(root.current); }

    /**
     * Devuelve true si consume la tecla. El consumidor decide que hacer con lo
     * que no se consume (por ejemplo, salir del grupo).
     */
    function handleKey(event) {
        const back = root.vertical ? Qt.Key_Up : Qt.Key_Left;
        const fwd  = root.vertical ? Qt.Key_Down : Qt.Key_Right;
        if (event.key === back) return root.move(-1);
        if (event.key === fwd)  return root.move(1);
        // 16B: Tab/Mayús+Tab recorren también (DESIGN §3), sólo donde la superficie no usa Tab para otra cosa
        if (root.tabMoves && event.key === Qt.Key_Tab) return root.move(1);
        if (root.tabMoves && event.key === Qt.Key_Backtab) return root.move(-1);
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) return root.activate();
        return false;
    }

    implicitWidth: root.vertical ? column.implicitWidth : row.implicitWidth
    implicitHeight: root.vertical ? column.implicitHeight : row.implicitHeight

    Column {
        id: column
        visible: root.vertical
        width: root.width
        spacing: root.spacing

        Repeater {
            model: root.vertical ? root.shown : []
            delegate: ActionButton {
                required property int index
                required property var modelData
                width: root.stretch ? column.width : implicitWidth
                /** Estirado = fila de una lista: el contenido va a la izquierda. */
                leading: root.stretch && !root.stacked
                s: root.s
                label: (root.confirming === modelData.id) ? "Confirm?" : modelData.label
                glyph: modelData.glyph !== undefined ? modelData.glyph : ""
                glyphTint: modelData.glyphTint ?? "transparent"
                stacked: root.stacked
                height: Math.max(implicitHeight, root.minimumRowHeight * root.s)
                accent: modelData.accent === true
                primary: modelData.primary === true
                danger: (modelData.danger === true) || (root.confirming === modelData.id)
                enabled: modelData.enabled !== false
                focused: root.active && root.current === index
                onHovered: {
                    if (root.hoverMovesFocus) { root.current = index; root.confirming = ""; }
                    root.hovered(modelData.id);
                }
                onTriggered: root.activateAt(index)
            }
        }
    }

    Row {
        id: row
        visible: !root.vertical
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: root.spacing

        Repeater {
            model: root.vertical ? [] : root.shown
            delegate: ActionButton {
                required property int index
                required property var modelData
                s: root.s
                label: (root.confirming === modelData.id) ? "Confirm?" : modelData.label
                glyph: modelData.glyph !== undefined ? modelData.glyph : ""
                glyphTint: modelData.glyphTint ?? "transparent"
                stacked: root.stacked
                height: Math.max(implicitHeight, root.minimumRowHeight * root.s)
                accent: modelData.accent === true
                primary: modelData.primary === true
                danger: (modelData.danger === true) || (root.confirming === modelData.id)
                enabled: modelData.enabled !== false
                focused: root.active && root.current === index
                onHovered: {
                    if (root.hoverMovesFocus) { root.current = index; root.confirming = ""; }
                    root.hovered(modelData.id);
                }
                onTriggered: root.activateAt(index)
            }
        }
    }
}
