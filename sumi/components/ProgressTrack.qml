import QtQuick
import "../theme"

/**
 * Barra de progreso común (F3 del estilo de interfaz, 2026-11-14; ADR-34). Sustituye a las pistas sueltas de
 * TestCountdown, el speed test y las tareas del Dashboard, que eran el mismo dibujo repetido: una pista y un relleno
 * a `ancho × fracción`.
 *
 *  soft      la pista (`trackColor`) con el relleno (`tint`) encima, con el radio que ponga quien la usa (de serie,
 *            cápsula). El árbol es el de antes: un Rectangle con otro dentro.
 *  terminal  `[█████░░░░]`: celdas rectas, llenas hasta `value`, vacías del color de la pista. Se dibujan con
 *            rectángulos, no con texto (no dependen de la fuente ni de sus glifos).
 *
 * El `Behavior`, si hace falta, va sobre `value` en quien la usa (ADR-25: sobre el valor, no sobre el píxel).
 */
Rectangle {
    id: root

    /** La familia de acento de la zona (Theme.fam; lib/accent-zones.js). */
    readonly property var acc: Theme.fam(palette.accent)
    property real s: 1
    /** 0…1; fuera de rango se recorta. */
    property real value: 0
    property color tint: root.acc.fill
    property color trackColor: root.acc.track
    readonly property real shown: Math.max(0, Math.min(1, root.value))

    radius: Metrics.pill(height)
    color: Style.terminal ? "transparent" : root.trackColor

    Rectangle {
        height: parent.height
        radius: parent.radius
        color: root.tint
        width: parent.width * root.shown
        visible: !Style.terminal
    }

    Item {
        id: cells
        objectName: "styleMarks"
        anchors.fill: parent
        visible: Style.terminal
        readonly property real gap: Math.max(1, Math.round(2 * root.s))
        readonly property real cell: Math.max(3, Math.round(6 * root.s))
        readonly property int n: Math.max(4, Math.floor((width + gap) / (cell + gap)))
        readonly property real cellW: (width - gap * (n - 1)) / n
        Repeater {
            model: cells.visible ? cells.n : 0
            Rectangle {
                required property int index
                x: Math.round(index * (cells.cellW + cells.gap))
                width: Math.round((index + 1) * (cells.cellW + cells.gap) - cells.gap) - x
                height: cells.height
                color: (index + 0.5) / cells.n <= root.shown ? root.tint : root.trackColor
            }
        }
    }
}
