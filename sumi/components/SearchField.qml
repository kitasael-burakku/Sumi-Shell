import QtQuick
import "../theme"

/**
 * One-line search input. A bare `TextInput` rather than Controls' `TextField`:
 * the shell would otherwise pull in QtQuick.Controls and its default style for
 * a box whose background we immediately throw away.
 *
 * Arrows and Escape are re-emitted as signals so the host can drive a list
 * without the field swallowing navigation.
 */
Item {
    id: root

    /** La familia de acento de la zona (Theme.fam; lib/accent-zones.js). */
    readonly property var acc: Theme.fam(palette.accent)
    property real s: 1
    property string placeholder: ""
    /** Modo contrasena (9.f.2): oculta lo tecleado y desactiva la seleccion. */
    property bool secret: false
    /**
     * Pegar. Con `false` se ignoran `Ctrl+V`, `Shift+Insert` y el botón central
     * (I-10 de docs/lock/SEGURIDAD.md: en la pantalla de bloqueo no se pega). Por
     * defecto `true`: pegar la clave de una wifi o de polkit desde un gestor de
     * contraseñas es legítimo.
     */
    property bool allowPaste: true
    /**
     * `Ctrl+U` y `Ctrl+Backspace` borran TODO y avisan con `clearRequested` (la
     * pantalla de bloqueo, ENTRADA.md §3). Apagado por defecto: en el resto del shell
     * `Ctrl+Backspace` borra una palabra, como en cualquier campo.
     */
    property bool clearKeys: false
    signal clearRequested()
    property alias text: input.text
    readonly property alias input: input

    /** Los modificadores viajan con la senal: el launcher usa Shift para "en terminal". */
    signal accepted(int modifiers)
    signal moved(int delta)
    signal dismissed()
    /** Tab: el hub web lo usa para pasar a sus buscadores; el launcher, para sus acciones. */
    signal tabbed()
    /**
     * Shift+Tab. Sólo se consume si `backtabs` está puesto (el hub web, rediseño
     * ARR-04); en los demás campos la tecla sigue como antes.
     */
    signal backtabbed()
    property bool backtabs: false
    /**
     * 11B: Ctrl+Tab / Ctrl+⇧Tab salen como `ctrlTabbed(±1)` en vez de `tabbed()` (el Dashboard
     * cambia de pestaña con ellos también desde el buscador de Tasks).
     */
    property bool ctrlTabs: false
    signal ctrlTabbed(int dir)
    /**
     * `Ctrl+←` / `Ctrl+→` — el modo archivo del launcher (10.c.2) lo usa para
     * salir y entrar de directorios sin reteclear la ruta. `-1` sale, `+1`
     * entra. Sólo se interceptan si `stepping` está puesto, para no quitarle el
     * salto por palabra a los demás campos del shell.
     */
    property bool stepping: false
    signal stepped(int dir)
    /**
     * Rejilla (selector de emojis, 2026-11-17): con `gridKeys`, ← / → sin modificadores salen como
     * `sideMoved(±1)` (la celda de al lado) en vez de mover el cursor de texto, y Retroceso con el
     * campo vacío sale como `emptyBackspace()`. Apagado por defecto: los demás campos no cambian.
     */
    property bool gridKeys: false
    signal sideMoved(int dir)
    signal emptyBackspace()

    /**
     * Cursor de bloque con el estilo terminal (ADR-34). El bloqueo lo apaga (`lock/LockField`): toma sólo la geometría
     * del estilo.
     */
    property bool tui: true
    readonly property bool blockCursor: Style.terminal && root.tui

    implicitHeight: input.implicitHeight

    FontMetrics { id: caretMetrics; font: input.font }

    function focusField() { input.forceActiveFocus(); }
    /** Si el teclado está en el campo; quien tenga varios controles lo necesita para saber dónde está. */
    readonly property bool editing: input.activeFocus
    function clear() { input.text = ""; }

    TextInput {
        id: input
        Accessible.role: Accessible.EditableText
        Accessible.name: root.placeholder
        Accessible.passwordEdit: root.secret
        anchors.fill: parent
        verticalAlignment: TextInput.AlignVCenter
        color: Theme.fg
        font.family: Typography.ui
        font.pixelSize: Typography.body * root.s
        echoMode: root.secret ? TextInput.Password : TextInput.Normal
        passwordCharacter: "\u2022"
        /** Sin seleccion con el raton en modo secreto: no se copia una clave. */
        selectByMouse: !root.secret
        selectionColor: Qt.alpha(root.acc.fill, 0.35)
        selectedTextColor: Theme.fg
        clip: true
        /** Que un método de entrada no guarde ni prediga lo que se teclea en un secreto. */
        inputMethodHints: root.secret
            ? (Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhHiddenText)
            : Qt.ImhNone

        Keys.onUpPressed: root.moved(-1)
        Keys.onDownPressed: root.moved(1)
        Keys.onPressed: (e) => {
            const ctrl = (e.modifiers & Qt.ControlModifier) !== 0;
            // I-10: antes que nada, para que el TextInput no llegue a ver el pegado
            if (!root.allowPaste && (e.matches(StandardKey.Paste)
                    || (e.key === Qt.Key_Insert && (e.modifiers & Qt.ShiftModifier) !== 0))) {
                e.accepted = true;
                return;
            }
            if (root.clearKeys && ctrl && (e.key === Qt.Key_U || e.key === Qt.Key_Backspace)) {
                input.text = "";
                root.clearRequested();
                e.accepted = true;
                return;
            }
            if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                root.accepted(e.modifiers);
                e.accepted = true;
            } else if (e.key === Qt.Key_Escape) {
                root.dismissed();
                e.accepted = true;
            } else if (root.ctrlTabs && ctrl && (e.key === Qt.Key_Tab || e.key === Qt.Key_Backtab)) {
                root.ctrlTabbed(e.key === Qt.Key_Tab && !(e.modifiers & Qt.ShiftModifier) ? 1 : -1);
                e.accepted = true;
            } else if (root.backtabs && (e.key === Qt.Key_Backtab
                    || (e.key === Qt.Key_Tab && (e.modifiers & Qt.ShiftModifier)))) {
                root.backtabbed();
                e.accepted = true;
            } else if (e.key === Qt.Key_Tab) {
                root.tabbed();
                e.accepted = true;
            } else if (root.gridKeys && (e.modifiers & ~Qt.KeypadModifier) === Qt.NoModifier
                       && (e.key === Qt.Key_Left || e.key === Qt.Key_Right)) {   // las flechas pueden traer Keypad
                root.sideMoved(e.key === Qt.Key_Right ? 1 : -1);
                e.accepted = true;
            } else if (root.gridKeys && e.key === Qt.Key_Backspace && input.text.length === 0) {
                root.emptyBackspace();
                e.accepted = true;
            } else if (root.stepping && ctrl && e.key === Qt.Key_Right) {
                root.stepped(1);
                e.accepted = true;
            } else if (root.stepping && ctrl && e.key === Qt.Key_Left) {
                root.stepped(-1);
                e.accepted = true;
            }
        }

        // terminal: un bloque del ancho de una letra, con la letra que tapa en el color de fondo (invertida); mismo
        // temporizador, sólo con foco
        cursorDelegate: Rectangle {
            id: caret
            width: root.blockCursor ? Math.max(2 * root.s, Math.round(caretMetrics.averageCharacterWidth)) : 2 * root.s
            color: root.acc.fill
            visible: input.activeFocus && blink
            property bool blink: true
            Timer {
                interval: 530
                repeat: true
                running: input.activeFocus
                onTriggered: parent.blink = !parent.blink
            }
            Text {
                objectName: "styleMarks"
                visible: root.blockCursor
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                text: input.displayText.charAt(input.cursorPosition)
                color: root.acc.onFill
                font: input.font
            }
        }
    }

    /**
     * El botón central pega la selección primaria en Wayland. Sólo acepta ese botón:
     * los clics normales siguen llegando al campo.
     */
    MouseArea {
        anchors.fill: input
        enabled: !root.allowPaste
        acceptedButtons: Qt.MiddleButton
        onPressed: (m) => { m.accepted = true; }
    }

    Text {
        anchors.fill: input
        verticalAlignment: Text.AlignVCenter
        visible: input.text.length === 0
        text: root.placeholder
        // 9D-1: con el texto a 1,15 el del Launcher se montaba sobre su contador
        elide: Text.ElideRight
        color: Theme.outlineText
        font.family: Typography.ui
        font.pixelSize: Typography.body * root.s
    }
}
