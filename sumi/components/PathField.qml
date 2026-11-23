import QtQuick
import QtQuick.Effects
import Quickshell
import "../theme"

/**
 * Fila de ajuste con una ruta local editable y una vista previa pequeña
 * (docs/lock/CONFIGURACION.md §5: `lockAvatar`, `lockFetchImage`).
 *
 * En reposo: la vista previa y la ruta efectiva, elidida por la izquierda
 * (lo que importa de una ruta larga es el nombre del archivo). Activar la
 * fila (clic, o Enter desde `SettingRow`) entra en edición: un campo de texto
 * toma el foco; Enter guarda, Esc cancela sin tocar el valor.
 *
 * La validación de «sólo local» (I-14) ya la hace quien consume la ruta
 * (`Avatar.path`, o el `Image.source` de abajo): un `http:`/`data:` guardado
 * aquí simplemente nunca se dibuja. No hace falta duplicarla al guardar.
 *
 * Fase 15H (decisión 3): si la ruta no es local o la imagen no se puede leer, la fila LO DICE
 * («Not found · …») y qué hará el Lock en su lugar; el Lock nunca enseña ese aviso.
 */
Item {
    id: root

    property real s: 1
    property string value: ""
    /** Lo que se ve si `value` está vacío (el valor por defecto real). */
    property string placeholder: ""
    /** La ruta que se decodifica para la vista previa: `value`, resuelta como el consumidor real. */
    property string effectivePath: root.value.length > 0 ? root.value : root.placeholder
    property bool round: false
    /** Qué hace el Lock si la imagen falta: la inicial (avatar) o sin imagen (fetch). */
    property string fallbackNote: root.round ? "the lock screen shows your initial" : "the lock screen shows no image"
    /** "" o el problema de la ruta efectiva, en inglés (UI). */
    readonly property string problem: {
        if (root.editing) return "";
        const p = root.effectivePath.trim();
        if (p.length === 0) return "";
        if (p.indexOf("://") >= 0 || p.indexOf("data:") === 0 || (p.indexOf("/") !== 0 && p.indexOf("~/") !== 0))
            return "Only local files · " + root.fallbackNote;
        if (img.status === Image.Error) return "Not found · " + root.fallbackNote;
        return "";
    }
    signal committed(string text)

    property bool editing: false

    function startEdit() {
        field.text = root.value;
        root.editing = true;
        editInput.forceActiveFocus();
        editInput.selectAll();
    }
    function cancelEdit() { root.editing = false; }
    function commit() {
        root.committed(field.text.trim());
        root.editing = false;
    }

    implicitWidth: row.implicitWidth
    implicitHeight: 28 * s

    Row {
        id: row
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 8 * root.s

        Item {
            id: preview
            anchors.verticalCenter: parent.verticalCenter
            width: 22 * root.s
            height: width

            readonly property string resolved: {
                const p = root.effectivePath.trim();
                if (p.length === 0 || p.indexOf("://") >= 0 || p.indexOf("data:") === 0)
                    return "";
                if (p.indexOf("~/") === 0)
                    return Quickshell.env("HOME") + p.slice(1);
                return p.indexOf("/") === 0 ? p : "";
            }

            Image {
                id: img
                anchors.fill: parent
                source: preview.resolved.length > 0 ? ("file://" + preview.resolved) : ""
                sourceSize.width: preview.width * 2
                sourceSize.height: preview.height * 2
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                smooth: true
                visible: false
            }
            Item {
                id: mask
                anchors.fill: parent
                layer.enabled: true
                visible: false
                Rectangle { anchors.fill: parent; radius: root.round ? Metrics.pill(width) : Metrics.r(4) * root.s; color: "black" }
            }
            MultiEffect {
                anchors.fill: parent
                source: img
                visible: img.status === Image.Ready
                maskEnabled: true
                maskSource: mask
                maskThresholdMin: 0.5
                maskSpreadAtMin: 1.0
            }
            Rectangle {
                anchors.fill: parent
                radius: root.round ? Metrics.pill(width) : Metrics.r(4) * root.s
                visible: img.status !== Image.Ready
                color: Theme.tileBg
                border.width: 1
                border.color: Theme.hair
            }
        }

        Item {
            anchors.verticalCenter: parent.verticalCenter
            width: root.editing ? 160 * root.s : pathText.implicitWidth
            height: 20 * root.s

            Text {
                id: pathText
                visible: !root.editing
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, (root.problem.length > 0 ? 280 : 160) * root.s * Typography.grow)
                elide: root.problem.length > 0 ? Text.ElideRight : Text.ElideLeft
                text: root.problem.length > 0 ? root.problem : (root.value.length > 0 ? root.value : "(default)")
                color: root.problem.length > 0 ? Theme.warn : (root.value.length > 0 ? Theme.fgVariant : Theme.outlineText)
                font.family: Typography.mono
                font.pixelSize: Typography.caption * root.s
            }

            Rectangle {
                id: field
                visible: root.editing
                anchors.fill: parent
                radius: Metrics.r(4) * root.s
                color: Theme.tileBg
                border.width: 1
                border.color: editInput.activeFocus ? Theme.selBorder : Theme.hair

                property alias text: editInput.text

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
    }
}
