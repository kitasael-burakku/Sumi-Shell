import QtQuick
import "../theme"

/**
 * Un campo de formulario con etiqueta, ayuda y error (2026-10-27, editor del calendario).
 * Como `SearchField`, un `TextInput`/`TextEdit` desnudo: sin QtQuick.Controls ni su estilo.
 *
 * El valor lo manda el modelo (`value`); teclear emite `edited(texto)` y el modelo lo
 * devuelve. El error tiene forma y texto, no sólo color: borde de error y la frase debajo.
 *
 * Teclado: Tab/⇧Tab → `tabbed(atrás)`; Esc → `escaped`; Ctrl+S o Ctrl+Intro → `submitted`.
 * En una línea, Intro pasa al siguiente (`tabbed(false)`); en `multiline`, Intro es salto.
 * ↑ ↓ → `stepped(±1)` (fechas y horas: el anfitrión decide cuánto).
 */
Item {
    id: root

    /** La familia de acento de la zona (Theme.fam; lib/accent-zones.js). */
    readonly property var acc: Theme.fam(palette.accent)
    property real s: 1
    property string label: ""
    property string value: ""
    property string placeholder: ""
    property string hint: ""
    property string error: ""
    property bool multiline: false
    property bool mono: false
    property int maxLength: 32767
    property bool readOnly: false
    /** Contraseña: no se ve ni se copia (CalDAV, 2026-10-28). */
    property bool secret: false
    /** Las líneas visibles de `multiline` antes de crecer el formulario (sin scroll propio). */
    property int minLines: 3
    readonly property bool focused: single.activeFocus || multi.activeFocus
    readonly property Item editor: root.multiline ? multi : single
    /** Dónde está el cursor, en coordenadas del campo (para que el anfitrión lo deje a la vista). */
    readonly property rect cursorRect: {
        const c = root.multiline ? multi.cursorRectangle : single.cursorRectangle;
        const p = root.editor.mapToItem(root, c.x, c.y);
        return Qt.rect(p.x, p.y, c.width, c.height);
    }

    signal edited(string text)
    signal tabbed(bool back)
    signal escaped()
    signal submitted()
    signal stepped(int delta)

    function focusField() { root.editor.forceActiveFocus(); }

    implicitHeight: col.implicitHeight
    implicitWidth: 200 * root.s

    Accessible.role: Accessible.EditableText
    Accessible.name: root.label
    Accessible.description: root.error.length > 0 ? root.error : root.hint

    onValueChanged: {
        if (single.text !== root.value) single.text = root.value;
        if (multi.text !== root.value) multi.text = root.value;
    }
    Component.onCompleted: { single.text = root.value; multi.text = root.value; }

    function keys(e, multi) {
        const ctrl = (e.modifiers & Qt.ControlModifier) !== 0;
        if (e.key === Qt.Key_Tab || e.key === Qt.Key_Backtab) { root.tabbed(e.key === Qt.Key_Backtab || (e.modifiers & Qt.ShiftModifier) !== 0); e.accepted = true; }
        else if (e.key === Qt.Key_Escape) { root.escaped(); e.accepted = true; }
        else if (ctrl && (e.key === Qt.Key_S || e.key === Qt.Key_Return || e.key === Qt.Key_Enter)) { root.submitted(); e.accepted = true; }
        else if (!multi && (e.key === Qt.Key_Return || e.key === Qt.Key_Enter)) { root.tabbed(false); e.accepted = true; }
        else if (!multi && (e.key === Qt.Key_Up || e.key === Qt.Key_Down)) { root.stepped(e.key === Qt.Key_Up ? 1 : -1); e.accepted = true; }
    }

    Column {
        id: col
        width: root.width
        spacing: 4 * root.s

        Text {
            width: parent.width
            visible: root.label.length > 0
            text: root.label
            elide: Text.ElideRight
            color: root.error.length > 0 ? Theme.errorColor : (root.focused ? Theme.fg : Theme.fgVariant)
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
            font.weight: Font.DemiBold
        }

        Rectangle {
            id: box
            width: parent.width
            height: root.multiline
                ? Math.max(multi.contentHeight, root.minLines * fm.height) + 14 * root.s
                : Math.max(Metrics.hitMin * root.s, fm.height + 14 * root.s)
            radius: Metrics.rSm * root.s
            color: root.readOnly ? "transparent" : Theme.tileBg
            border.width: root.focused || root.error.length > 0 ? Metrics.focusWidth * root.s : 1
            border.color: root.error.length > 0 ? Theme.errorColor : root.focused ? root.acc.selBorder : Theme.hair
            Behavior on border.color { ColorAnimation { duration: Motion.fast } }

            FontMetrics { id: fm; font.family: root.mono ? Typography.mono : Typography.ui; font.pixelSize: Typography.body * root.s }

            Text {
                anchors.fill: parent
                anchors.leftMargin: 10 * root.s; anchors.rightMargin: 10 * root.s
                anchors.topMargin: root.multiline ? 7 * root.s : 0
                verticalAlignment: root.multiline ? Text.AlignTop : Text.AlignVCenter
                visible: root.value.length === 0 && root.placeholder.length > 0
                text: root.placeholder
                elide: Text.ElideRight
                color: Theme.outlineText
                font: fm.font
            }

            TextInput {
                id: single
                visible: !root.multiline
                enabled: !root.multiline && !root.readOnly
                anchors.fill: parent
                anchors.leftMargin: 10 * root.s; anchors.rightMargin: 10 * root.s
                verticalAlignment: TextInput.AlignVCenter
                clip: true
                maximumLength: root.maxLength
                selectByMouse: !root.secret
                echoMode: root.secret ? TextInput.Password : TextInput.Normal
                inputMethodHints: root.secret ? (Qt.ImhHiddenText | Qt.ImhSensitiveData | Qt.ImhNoPredictiveText) : Qt.ImhNone
                color: Theme.fg
                selectionColor: Qt.alpha(root.acc.fill, 0.35)
                selectedTextColor: Theme.fg
                font: fm.font
                onTextChanged: if (!root.multiline && text !== root.value) root.edited(text)
                Keys.onPressed: e => root.keys(e, false)
            }

            TextEdit {
                id: multi
                visible: root.multiline
                enabled: root.multiline && !root.readOnly
                anchors.fill: parent
                anchors.leftMargin: 10 * root.s; anchors.rightMargin: 10 * root.s
                anchors.topMargin: 7 * root.s; anchors.bottomMargin: 7 * root.s
                wrapMode: TextEdit.Wrap
                textFormat: TextEdit.PlainText
                selectByMouse: true
                persistentSelection: false
                color: Theme.fg
                selectionColor: Qt.alpha(root.acc.fill, 0.35)
                selectedTextColor: Theme.fg
                font: fm.font
                onTextChanged: {
                    if (!root.multiline) return;
                    if (text.length > root.maxLength) { text = text.substring(0, root.maxLength); return; }
                    if (text !== root.value) root.edited(text);
                }
                Keys.onPressed: e => root.keys(e, true)
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton
                cursorShape: Qt.IBeamCursor
                propagateComposedEvents: true
                // Clic en el borde o fuera del texto: el foco va al campo, el texto lo coloca Qt.
                onPressed: mouse => { root.focusField(); mouse.accepted = false; }
            }
        }

        Text {
            width: parent.width
            visible: text.length > 0
            text: root.error.length > 0 ? root.error : root.hint
            wrapMode: Text.Wrap
            color: root.error.length > 0 ? Theme.errorColor : Theme.outlineText
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }
    }
}
