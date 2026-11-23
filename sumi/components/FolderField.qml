import QtQuick
import "../theme"

/**
 * Campo para escribir una carpeta (10A: «Add a folder» en Theme → Wallpaper → Sources).
 *
 * Como `PathField`, pero sin vista previa: una `Image` apuntando a una carpeta no carga y deja un
 * aviso en el journal. En reposo enseña el resultado del último intento (`note`, con su tono);
 * activar la fila (clic, o Enter desde `SettingRow`) entra en edición; Enter envía, Esc cancela.
 * La validación la hace quien recibe `committed` (el servicio), no el campo.
 */
Item {
    id: root

    property real s: 1
    property string placeholder: "~/Pictures/More wallpapers"
    /** 10E-1a: también sirve para otros textos cortos (el usuario de Wallhaven). */
    property string glyph: "folder"
    property string idleText: "Type a path"
    property string accessibleName: "Folder path"
    /** El resultado del último intento, y si fue un error (rojo) o no. */
    property string note: ""
    property bool noteError: false
    signal committed(string text)
    /**
     * Terminó la edición (enviada o cancelada): quien lo aloja devuelve el teclado a su página.
     * Sin esto el campo oculto se quedaba el foco y el siguiente Enter lo reenviaba (10A, medido).
     */
    signal finished()

    property bool editing: false

    function startEdit() {
        editInput.text = "";
        root.editing = true;
        editInput.forceActiveFocus();
    }
    function cancelEdit() {
        root.editing = false;
        root.finished();
    }
    function commit() {
        const t = editInput.text.trim();
        root.editing = false;
        if (t.length > 0) root.committed(t);
        root.finished();
    }

    implicitWidth: root.editing ? 220 * root.s : Math.min(noteText.implicitWidth, 220 * root.s) + addGlyph.width + 6 * root.s
    implicitHeight: 28 * s

    Row {
        visible: !root.editing
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6 * root.s

        Text {
            id: noteText
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, 220 * root.s)
            elide: Text.ElideLeft
            text: root.note.length > 0 ? root.note : root.idleText
            color: root.noteError ? Theme.errorColor : root.note.length > 0 ? Theme.fgVariant : Theme.outlineText
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }
        Icon {
            id: addGlyph
            anchors.verticalCenter: parent.verticalCenter
            name: root.glyph
            size: 12 * root.s
            color: Theme.fgVariant
        }
    }

    Rectangle {
        visible: root.editing
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: 220 * root.s
        height: 20 * root.s
        radius: Metrics.r(4) * root.s
        color: Theme.tileBg
        border.width: 1
        border.color: editInput.activeFocus ? Theme.selBorder : Theme.hair

        TextInput {
            id: editInput
            anchors.fill: parent
            anchors.leftMargin: 6 * root.s
            anchors.rightMargin: 6 * root.s
            verticalAlignment: TextInput.AlignVCenter
            color: Theme.fg
            font.family: Typography.mono
            font.pixelSize: Typography.caption * root.s
            clip: true
            Accessible.role: Accessible.EditableText
            Accessible.name: root.accessibleName

            Text {
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                visible: editInput.text.length === 0
                text: root.placeholder
                color: Theme.outlineText
                font: editInput.font
                elide: Text.ElideRight
            }

            Keys.onPressed: (e) => {
                if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                    root.commit(); e.accepted = true;
                } else if (e.key === Qt.Key_Escape) {
                    root.cancelEdit(); e.accepted = true;
                }
            }
            onActiveFocusChanged: if (!activeFocus && root.editing) root.cancelEdit()
        }
    }
}
