import QtQuick
import "../theme"
import "../services"

/** Muestra el material con la opacidad vigente y estados de controles. */
Item {
    id: root
    property real s: 1
    /** La superficie cuyo material efectivo se enseña ("" = el global). */
    property string surface: ""
    /** El rótulo; vacío = el material y la opacidad efectivos. */
    property string title: ""
    /**
     * 2026-11-12 (captura del autor): el alto era fijo (166·s) y las pastillas iban en un `Flow` a (W − 10·s)/3: tres
     * más sus huecos sumaban justo el ancho y, por redondeo, la tercera saltaba de renglón; salían tres filas de dos
     * que rebasaban la tarjeta (más aún con Text size grande). Ahora una rejilla de columnas fijas y el alto del
     * contenido.
     */
    implicitHeight: content.implicitHeight + 36 * s

    Glass {
        anchors.fill: parent
        anchors.margins: 8 * root.s
        radius: Metrics.rMd * root.s
        s: root.s
        surface: root.surface
        shadowed: true
    }

    Column {
        id: content
        x: 18 * root.s
        y: 18 * root.s
        width: Math.max(0, root.width - 36 * root.s)
        spacing: 8 * root.s

        // 2026-11-07: con elipsis; en el panel contextual de la Settings UI la columna es estrecha
        Text {
            width: parent.width
            elide: Text.ElideRight
            text: root.title.length > 0 ? root.title
                : (Theme.materialFor(root.surface) === "satin" ? "Vidrio Satinado" : "Glass")
                  + " · " + Math.round(Theme.opacityFor(root.surface) * 100) + "%"
            color: Theme.fg
            font.family: Typography.ui
            font.pixelSize: Typography.body * root.s
            font.weight: Font.DemiBold
        }
        Text {
            width: parent.width
            elide: Text.ElideRight
            text: "Secondary text · icons and controls stay sharp"
            color: Theme.fgVariant
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }
        Grid {
            id: statesFlow
            width: parent.width
            spacing: 5 * root.s
            property var states: ["Normal", "Hover", "Focus", "Selected", "Pressed", "Disabled"]
            // tres columnas; dos si en un tercio no cabe la etiqueta más larga (columna estrecha, texto grande)
            readonly property real widest: 12 * root.s + 5 * root.s + labelProbe.implicitWidth + 16 * root.s
            columns: (width - 2 * spacing) / 3 >= widest ? 3 : 2
            readonly property real cellW: Math.floor((width - (columns - 1) * spacing) / columns)
            Text {
                id: labelProbe
                visible: false
                text: "Selected"
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
            }
            Repeater {
                model: statesFlow.states
                Rectangle {
                    required property string modelData
                    width: statesFlow.cellW
                    height: Math.max(32 * root.s, Math.ceil(labelProbe.implicitHeight) + 14 * root.s)
                    radius: Metrics.rSm * root.s
                    color: Theme.controlBg(Theme.cardBg, modelData === "Hover", modelData === "Pressed", modelData === "Selected")
                    border.width: modelData === "Focus" ? Metrics.focusWidth * root.s : 0
                    border.color: Theme.focusRing
                    Row {
                        anchors.centerIn: parent
                        spacing: 5 * root.s
                        opacity: modelData === "Disabled" ? Theme.disabledOpacity : 1
                        Icon { name: "check"; size: 12 * root.s; color: Theme.fg }
                        Text {
                            text: modelData
                            color: Theme.fg
                            font.family: Typography.ui
                            font.pixelSize: Typography.caption * root.s
                        }
                    }
                }
            }
        }
    }
}
