import QtQuick
import "../theme"

/**
 * Una combinación dibujada como teclas (ayuda de atajos, 2026-10-30): ["Super", "Ctrl", "W"] → tres teclas juntas.
 * `muted`: la tecla POR DEFECTO, que nunca debe parecer la efectiva (sin relleno, borde discontinuo no hay en QML: se
 * usa contorno fino y texto apagado, y quien la enseña siempre la rotula «Default»).
 */
Row {
    id: root
    property var caps: []
    property real s: 1
    property bool muted: false
    /** Tamaño relativo: 1 en la lista, más grande en la tarjeta «Your key» del detalle. */
    property real unit: 1
    spacing: 3 * root.s * root.unit
    Accessible.role: Accessible.StaticText
    Accessible.name: root.caps.join(" + ")

    Repeater {
        model: root.caps
        delegate: Rectangle {
            required property string modelData
            height: 26 * root.s * root.unit
            width: Math.max(height, label.implicitWidth + 12 * root.s * root.unit)
            radius: Metrics.r(5) * root.s * root.unit
            color: root.muted ? "transparent" : Theme.tileBg
            border.width: 1
            border.color: root.muted ? Theme.hair : Theme.outline
            Rectangle {
                // el canto inferior de una tecla: sólo en las efectivas
                visible: !root.muted
                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                anchors.margins: 1
                height: 2 * root.s
                radius: parent.radius
                color: Theme.hair
            }
            Text {
                id: label
                anchors.centerIn: parent
                anchors.verticalCenterOffset: root.muted ? 0 : -0.5 * root.s
                text: parent.modelData
                color: root.muted ? Theme.fgVariant : Theme.fg
                font.family: Typography.mono
                font.pixelSize: 13 * Typography.textScale * root.s * root.unit
                font.weight: Typography.wMedium
            }
        }
    }
}
