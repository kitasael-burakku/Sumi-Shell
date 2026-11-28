pragma ComponentBehavior: Bound

import QtQuick
import "../theme"

/**
 * La hora del bloqueo con dígitos que ruedan (2026-11-28): al cambiar el minuto, sólo los caracteres que cambian
 * suben y dejan entrar el nuevo desde abajo. Con Reduced es un fundido en el sitio; con Off, un cambio seco.
 *
 * Cada carácter es una celda recortada con el ancho de su glifo (cifras tabulares: todas miden lo mismo, así que la
 * hora no baila). Si cambia el número de caracteres (12 h: 9:59 → 10:00) las celdas se rehacen sin animar.
 * Quieto no cuesta nada: una animación de `Motion.lockDigit` por minuto, y ninguna con `rolling` apagado.
 */
Item {
    id: root

    property string text: ""
    property color color: Theme.fg
    property string family: Typography.uiChosen
    property int weight: Typography.wStrong
    property real pixelSize: 48
    /** Se anima sólo a la vista; apagado, el cambio es seco. */
    property bool rolling: true

    readonly property var chars: root.text.split("")

    implicitWidth: row.implicitWidth
    implicitHeight: probe.implicitHeight

    Accessible.role: Accessible.StaticText
    Accessible.name: "Time " + root.text

    // la altura de una línea de esta letra, para el recorte y el recorrido
    Text {
        id: probe
        visible: false
        text: "0"
        font.family: root.family
        font.weight: root.weight
        font.pixelSize: root.pixelSize
        font.features: { "tnum": 1 }
    }

    Row {
        id: row
        Repeater {
            model: root.chars.length
            delegate: Item {
                id: cell
                required property int index
                readonly property string ch: root.chars[cell.index] || ""
                property string prev: ""
                property real t: 1
                readonly property real travel: Motion.still ? 0 : cell.height * 0.55

                width: cur.implicitWidth
                height: probe.implicitHeight
                clip: cell.t < 1

                onChChanged: {
                    if (!root.rolling || Motion.off || cell.prev === "" || cell.prev === cell.ch) {
                        roll.stop();
                        cell.t = 1;
                        cell.prev = cell.ch;
                    } else {
                        roll.restart();
                    }
                }
                // `prev` es lo que se veía; se actualiza al acabar (o al saltar)
                Component.onCompleted: cell.prev = cell.ch
                onTChanged: if (cell.t >= 1) cell.prev = cell.ch

                NumberAnimation {
                    id: roll
                    target: cell; property: "t"; from: 0; to: 1
                    duration: Motion.lockDigit
                    easing.type: Motion.still ? Easing.InOutQuad : Easing.OutCubic
                }

                Text {
                    id: old
                    visible: cell.t < 1
                    y: -cell.travel * cell.t
                    opacity: 1 - cell.t
                    text: cell.prev
                    color: root.color
                    font: cur.font
                }
                Text {
                    id: cur
                    y: cell.travel * (1 - cell.t)
                    opacity: cell.t < 1 ? cell.t : 1
                    text: cell.ch
                    color: root.color
                    font.family: root.family
                    font.weight: root.weight
                    font.pixelSize: root.pixelSize
                    font.features: { "tnum": 1 }
                }
            }
        }
    }
}
