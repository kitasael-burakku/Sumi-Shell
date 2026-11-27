import QtQuick
import "../theme"

/**
 * Una fila de ficha: etiqueta a la izquierda, valor a la derecha (fase 3B de coherencia, 2026-11-27, ADR-42).
 *
 * Antes la misma fila estaba escrita cuatro veces con tres aspectos (WifiDetail y BtDetail iguales; Wired con la
 * etiqueta en `body`, otro hueco y un alto fijo que cortaba con Text size grande; ServiceDetail en mayúsculas y sin
 * elipsis, así que un valor largo se salía). Ahora una:
 *   - etiqueta `label` en `outlineText`, valor `body` en `fg` con cifras tabulares y elipsis en medio;
 *   - sin valor, «—» apagado (o la fila desaparece con `hideEmpty`);
 *   - `dense`: las dos en `caption` y filas de 18 px (fichas largas, como la de un servicio).
 * El alto nunca es menor que el texto (Text size).
 */
Item {
    id: row

    property real s: 1
    property string label: ""
    property string value: ""
    property bool dense: false
    property bool hideEmpty: false

    readonly property bool empty: row.value.length === 0
    visible: !(row.hideEmpty && row.empty)
    height: row.visible ? Math.max((row.dense ? 18 : 26) * row.s, factLabel.implicitHeight, factValue.implicitHeight) : 0

    Text {
        id: factLabel
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: row.label
        color: Theme.outlineText
        font.family: Typography.ui
        font.pixelSize: (row.dense ? Typography.caption : Typography.label) * row.s
    }
    Text {
        id: factValue
        anchors.left: factLabel.right
        anchors.leftMargin: 12 * row.s
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideMiddle
        text: row.empty ? "—" : row.value
        color: row.empty ? Theme.outlineText : Theme.fg
        font.family: Typography.ui
        font.pixelSize: (row.dense ? Typography.caption : Typography.body) * row.s
        font.features: ({ "tnum": 1 })
    }
}
