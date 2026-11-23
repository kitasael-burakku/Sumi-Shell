pragma ComponentBehavior: Bound

import QtQuick
import "../theme"

/**
 * Muestras de la paleta (rediseño, 9D-1; futureSettingssurface §6 Colors y Matugen): cada
 * rol con su nombre, su hex y el CONTRASTE de su pareja de texto, calculado como WCAG
 * (luminancia relativa). Sólo muestra: no selecciona ni aplica nada (eso es Visual
 * profiles; la prueba global llega en la fase 12).
 *
 *   swatches: [{ name, color, on }]   `on` = el color del texto que va encima
 */
Grid {
    id: grid

    property real s: 1
    property var swatches: []

    columns: 4
    columnSpacing: 8 * s
    rowSpacing: 8 * s

    /**
     * El ancho de cada celda (2026-11-12): nunca menos de los 92·s de siempre, pero sí lo que pida el nombre más largo
     * o la línea «#RRGGBB  00.0:1» con la familia y el Text size en uso. A 92·s fijos, con Fira Code se salía.
     */
    readonly property real cellW: Math.max(92 * s, Math.ceil(measure.implicitWidth))

    // Sin pintar: Grid no coloca a los hijos invisibles
    Column {
        id: measure
        visible: false
        Repeater {
            model: grid.swatches
            delegate: Text {
                required property var modelData
                text: modelData.name
                font.family: Typography.ui
                font.pixelSize: Typography.caption * grid.s
            }
        }
        Text {
            text: "#888888  88.8:1"
            font.family: Typography.mono
            font.pixelSize: Typography.micro * grid.s
            font.features: { "tnum": 1 }
        }
    }

    function lum(c) {
        const f = (v) => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
        return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
    }
    function contrast(a, b) {
        const la = grid.lum(a), lb = grid.lum(b);
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
    }
    function hex(c) {
        const h = (v) => ("0" + Math.round(v * 255).toString(16)).slice(-2);
        return ("#" + h(c.r) + h(c.g) + h(c.b)).toUpperCase();
    }

    Repeater {
        model: grid.swatches
        delegate: Column {
            id: sw
            required property var modelData
            readonly property real ratio: grid.contrast(sw.modelData.color, sw.modelData.on)
            spacing: 3 * grid.s
            width: grid.cellW

            Accessible.role: Accessible.StaticText
            Accessible.name: sw.modelData.name + " " + grid.hex(sw.modelData.color)
                + ", text contrast " + sw.ratio.toFixed(1) + " to 1"

            Rectangle {
                width: parent.width
                height: 34 * grid.s
                radius: Metrics.r(8) * grid.s
                color: sw.modelData.color
                border.width: 1
                border.color: Qt.alpha(Theme.outline, 0.35)
                Text {
                    anchors.centerIn: parent
                    text: "Aa"
                    color: sw.modelData.on
                    font.family: Typography.ui
                    font.pixelSize: Typography.body * grid.s
                    font.weight: Typography.wStrong
                }
            }
            Text {
                width: parent.width
                elide: Text.ElideRight
                text: sw.modelData.name
                color: Theme.fg
                font.family: Typography.ui
                font.pixelSize: Typography.caption * grid.s
            }
            Text {
                width: parent.width
                text: grid.hex(sw.modelData.color) + "  " + sw.ratio.toFixed(1) + ":1"
                // bajo 4,5:1 (texto normal, WCAG) se marca: el acento generado no siempre llega
                color: sw.ratio < 4.5 ? Theme.warn : Theme.outlineText
                font.family: Typography.mono
                font.pixelSize: Typography.micro * grid.s
                font.features: { "tnum": 1 }
            }
        }
    }
}
