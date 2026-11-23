import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import "../lib/window-open.js" as WinOpen

/**
 * Lo que dibujan Bloom, Ink, Scroll y Mist encima de la forma (2026-11-17, ADR-36). Es el `layer.effect` de la
 * tarjeta de cada ventana flotante: la tarjeta ya va en una capa mientras anima (`layer.enabled` con `appear` entre 0 y
 * 1), así que esto sólo existe durante la apertura o el cierre y no cuesta nada con la ventana quieta. Lo pone la
 * ventana sólo si `rv.effect` (los estilos que sólo transforman no lo usan).
 *
 *   Bloom   máscara de cápsula que se estira y se abre, rellena del acento, con un halo que se apaga.
 *   Scroll  máscara que baja desde la franja del título, con un filo de luz en el borde.
 *   Ink     máscara circular con el borde difuminado, desde el centro, con un aro del acento.
 *   Mist    desenfoque que se aclara.
 *
 * Las banderas de MultiEffect (máscara, desenfoque) son fijas por estilo: así no cambia de variante de shader a mitad
 * de la animación. El color de Bloom es un relleno encima, no `colorization`. Radios con `Metrics` (rectos en Terminal).
 */
Item {
    id: fx

    property var source                 // lo pone el sistema de capas
    property var rv: null               // el Reveal de la ventana
    property real s: 1
    property real radius: Metrics.rLg * fx.s

    readonly property string name: fx.rv ? fx.rv.name : ""
    readonly property var e: fx.rv ? WinOpen.effect(fx.name, fx.rv.value, fx.width, fx.height, fx.radius, fx.s,
                                                    (h) => Metrics.pill(h)) : null
    readonly property bool rectMasked: fx.name === "bloom" || fx.name === "scroll"
    readonly property bool circleMasked: fx.name === "ink"

    // Bloom: el halo de la cápsula, detrás
    Rectangle {
        visible: fx.name === "bloom" && fx.e !== null && fx.e.glow > 0.01
        readonly property real pad: 7 * fx.s
        x: fx.e ? fx.e.mx - pad : 0
        y: fx.e ? fx.e.my - pad : 0
        width: fx.e ? fx.e.mw + 2 * pad : 0
        height: fx.e ? fx.e.mh + 2 * pad : 0
        radius: fx.e ? fx.e.mr + pad : 0
        color: Qt.alpha(Theme.primary, 0.22)
        opacity: fx.e ? fx.e.glow * (Motion.still ? 0.35 : 1) : 0
    }

    MultiEffect {
        anchors.fill: parent
        source: fx.source
        autoPaddingEnabled: false
        maskEnabled: fx.rectMasked || fx.circleMasked
        maskSource: fx.circleMasked ? circleMask : rectMask
        blurEnabled: fx.name === "mist"
        blurMax: 32
        blur: fx.e ? fx.e.blur * (Motion.still ? 0.35 : 1) : 0
    }

    // máscaras (sólo la del estilo va en capa)
    Item {
        id: rectMask
        anchors.fill: parent
        visible: false
        layer.enabled: fx.rectMasked
        Rectangle {
            x: fx.e ? fx.e.mx : 0
            y: fx.e ? fx.e.my : 0
            width: fx.e ? fx.e.mw : 0
            height: fx.e ? fx.e.mh : 0
            radius: fx.e ? fx.e.mr : 0
            color: "white"
            antialiasing: true
        }
    }
    Item {
        id: circleMask
        anchors.fill: parent
        visible: false
        layer.enabled: fx.circleMasked
        Shape {
            anchors.fill: parent
            visible: fx.circleMasked
            ShapePath {
                strokeWidth: -1
                strokeColor: "transparent"
                fillGradient: RadialGradient {
                    readonly property real cr: fx.e ? Math.max(0.5, fx.e.cr) : 0.5
                    centerX: fx.width / 2; centerY: fx.height / 2
                    focalX: fx.width / 2; focalY: fx.height / 2
                    centerRadius: cr
                    focalRadius: 0
                    GradientStop { position: 0; color: "white" }
                    GradientStop {
                        position: fx.e && fx.e.cr > 0 ? Math.max(0, Math.min(0.999, (fx.e.cr - fx.e.cf) / fx.e.cr)) : 0
                        color: "white"
                    }
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

    // Bloom: la cápsula de luz, delante (relleno del acento que se apaga al abrirse; medido en banco el 2026-11-17: el
    // `colorization` de MultiEffect conserva la luminancia del vidrio y dejaba leer el texto dentro de la cápsula)
    Rectangle {
        visible: fx.name === "bloom" && fx.e !== null && fx.e.tint > 0.01
        x: fx.e ? fx.e.mx : 0
        y: fx.e ? fx.e.my : 0
        width: fx.e ? fx.e.mw : 0
        height: fx.e ? fx.e.mh : 0
        radius: fx.e ? fx.e.mr : 0
        color: Theme.primary
        opacity: fx.e ? (Motion.still ? 0.45 : 0.9) * fx.e.tint : 0
        antialiasing: true
    }
    Rectangle {
        visible: fx.name === "bloom" && fx.e !== null && fx.e.glow > 0.01
        x: fx.e ? fx.e.mx : 0
        y: fx.e ? fx.e.my : 0
        width: fx.e ? fx.e.mw : 0
        height: fx.e ? fx.e.mh : 0
        radius: fx.e ? fx.e.mr : 0
        color: "transparent"
        border.width: Math.max(1, 1.5 * fx.s)
        border.color: Theme.primary
        opacity: fx.e ? (Motion.still ? 0.32 : 0.8) * fx.e.glow : 0
        antialiasing: true
    }

    // Scroll: el filo de luz que baja con el borde
    Item {
        visible: fx.name === "scroll" && fx.e !== null && fx.e.rim > 0.01
        x: fx.width * 0.06
        width: fx.width * 0.88
        y: fx.e ? fx.e.rimY - height / 2 : 0
        height: 8 * fx.s
        opacity: fx.e ? fx.e.rim : 0
        Rectangle {
            anchors.fill: parent
            radius: Metrics.pill(height)
            color: Qt.alpha(Theme.primary, 0.22)
        }
        Rectangle {
            anchors.centerIn: parent
            width: parent.width
            height: Math.max(1, 2 * fx.s)
            radius: Metrics.pill(height)
            color: Theme.primary
        }
    }

    // Ink: el aro que se adelanta a la tinta y se desvanece
    Rectangle {
        visible: fx.name === "ink" && fx.e !== null && fx.e.ring > 0.01
        width: fx.e ? 2 * fx.e.ringR : 0
        height: width
        x: (fx.width - width) / 2
        y: (fx.height - height) / 2
        radius: width / 2
        color: Qt.alpha(Theme.primary, 0.06)
        border.width: Math.max(1, 2 * fx.s)
        border.color: Theme.primary
        opacity: fx.e ? fx.e.ring : 0
        antialiasing: true
    }
}
