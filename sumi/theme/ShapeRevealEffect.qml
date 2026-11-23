import QtQuick
import QtQuick.Effects
import QtQuick.Shapes

/**
 * Lo que los estilos de forma (2026-11-21, ADR-40; lib/shape-open.js) dibujan sobre el CONTENIDO del island: el
 * `layer.effect` de su SurfaceHost mientras dura la apertura o el cierre de Ink y Mist (con la forma quieta no hay capa).
 *
 *   Ink   máscara circular de borde difuso desde `cx, cy` (el acceso de la barra o el centro de la píldora) y un aro
 *         del acento que se adelanta y se desvanece.
 *   Mist  desenfoque que se aclara y una escala que vuelve a 1.
 *
 * Sólo el contenido: una capa sobre la forma entera recortaría los filetes de la unión, que se dibujan fuera del Item
 * (medido con tools/shape-open/qmltest.py: `layer.sourceRect` mayor no los incluye). Por eso en la barra la gota de Ink
 * es también la geometría (lib/shape-open.js) y aquí sólo se enmascara lo de dentro.
 *
 * Las banderas de MultiEffect son fijas por estilo (`masked`, `blurred` se fijan al crear el efecto): no cambia de
 * variante de shader a mitad, como theme/RevealEffect.
 */
Item {
    id: fx

    // La máscara y el aro viven dentro del rectángulo del contenido.
    clip: fx.masked

    property var source                  // lo pone el sistema de capas
    property real s: 1
    property bool masked: false
    property bool blurred: false
    /** 0–1, radio de la gota como fracción de `reach` (lo que hace falta para cubrirlo todo). */
    property real ink: 0
    property real cx: fx.width / 2
    property real cy: 0
    property real reach: Math.hypot(fx.width, fx.height)
    property real ring: 0
    property real blur: 0
    property real zoom: 1

    readonly property real feather: Math.max(10 * fx.s, 0.14 * fx.reach)
    /** Radio exterior de la máscara: con `ink` = 1 el borde difuso ya ha pasado la esquina más lejana. */
    readonly property real cr: Math.max(0.5, fx.ink * (fx.reach + fx.feather))

    MultiEffect {
        anchors.fill: parent
        source: fx.source
        autoPaddingEnabled: false
        maskEnabled: fx.masked
        maskSource: mask
        blurEnabled: fx.blurred
        blurMax: 32
        blur: fx.blur
        transform: Scale { origin.x: fx.width / 2; origin.y: fx.height / 2; xScale: fx.zoom; yScale: fx.zoom }
    }

    Item {
        id: mask
        anchors.fill: parent
        visible: false
        layer.enabled: fx.masked
        Shape {
            anchors.fill: parent
            visible: fx.masked
            ShapePath {
                strokeWidth: -1
                strokeColor: "transparent"
                fillGradient: RadialGradient {
                    centerX: fx.cx; centerY: fx.cy
                    focalX: fx.cx; focalY: fx.cy
                    centerRadius: fx.cr
                    focalRadius: 0
                    GradientStop { position: 0; color: "white" }
                    GradientStop { position: Math.max(0, Math.min(0.999, (fx.cr - fx.feather) / fx.cr)); color: "white" }
                    GradientStop { position: 1; color: "#00ffffff" }
                }
                startX: 0; startY: 0
                PathLine { x: fx.width; y: 0 }
                PathLine { x: fx.width; y: fx.height }
                PathLine { x: 0; y: fx.height }
                PathLine { x: 0; y: 0 }
            }
        }
    }

    // el aro que se adelanta a la tinta y se desvanece
    Rectangle {
        readonly property real rr: Math.max(2 * fx.s, fx.cr - fx.feather * 0.45)
        visible: fx.masked && fx.ring > 0.01
        width: 2 * rr
        height: width
        x: fx.cx - rr
        y: fx.cy - rr
        radius: rr
        color: Qt.alpha(Theme.primary, 0.06)
        border.width: Math.max(1, 2 * fx.s)
        border.color: Theme.primary
        opacity: fx.ring
        antialiasing: true
    }
}
