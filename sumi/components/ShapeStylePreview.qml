import QtQuick
import "../theme"
import "../lib/shape-open.js" as ShapeOpen

/**
 * Miniatura animada de un estilo de forma (2026-11-21, ADR-40; Settings → Animations → Bar panels e Island style): un
 * escritorio pequeño con la barra arriba y un panel que sale de ella (`kind` "bar"), o una píldora arriba que se abre en
 * panel ("island"), con las curvas de lib/shape-open.js de ESE estilo (`preview`, que aproxima también los de muelle).
 * Como WindowStylePreview, sólo se mueve mientras `playing`. En reposo enseña el panel
 * abierto. Sin los filetes de la unión: a este tamaño no se leen.
 */
Item {
    id: root

    property real s: 1
    property string kind: "bar"
    property string style: "slide"
    property bool playing: false

    implicitWidth: 136 * s
    implicitHeight: 80 * s

    readonly property var params: Motion.styleParams(root.kind, root.style)
    readonly property real openMs: root.params.openMs || 300
    readonly property real closeMs: root.params.closeMs || 220

    // la línea: un VALOR (como theme/Reveal)
    property real v: 1
    property bool opening: true
    NumberAnimation {
        id: anim
        target: root
        property: "v"
        easing.type: Easing.Linear
    }
    readonly property int playOpenMs: params.timeline ? Motion.styleMs(openMs) : Motion.still ? Motion.calmMs : Motion.dur(openMs)
    readonly property int playCloseMs: params.timeline ? Motion.styleMs(closeMs) : Motion.still ? Motion.returnMs : Motion.dur(closeMs)
    PreviewCycle {
        id: cycle
        playing: root.playing && !Motion.off
        openMs: root.playOpenMs
        closeMs: root.playCloseMs
        onOpenedChanged: if (playing) root.go(opened)
    }
    function go(open) {
        anim.stop();
        root.opening = open;
        anim.from = root.v;
        anim.to = open ? 1 : 0;
        anim.duration = Math.max(1, (open ? root.playOpenMs : root.playCloseMs) * Math.abs(anim.to - anim.from));
        anim.start();
    }
    readonly property bool cycling: cycle.playing
    onCyclingChanged: if (!cycling) { anim.stop(); v = 1; opening = true; }

    // medidas de la escena (px de miniatura)
    readonly property real barH: 8 * root.s
    readonly property real bigA: desk.width * 0.62
    readonly property real bigD: root.kind === "bar" ? desk.height * 0.56 : desk.height * 0.62
    readonly property real bigR: Metrics.r(6) * root.s
    readonly property var restG: root.kind === "bar" ? { a: 0, d: 0, r: 0 }
        : { a: desk.width * 0.32, d: 11 * root.s, r: Metrics.pill(11 * root.s) }
    readonly property real btnX: desk.width * 0.34
    readonly property var f: ShapeOpen.preview(root.kind, root.style, root.v, root.opening, root.restG,
        { a: root.bigA, d: root.bigD, r: root.bigR },
        { s: root.s * 0.5, reduced: Motion.still, returnRate: Motion.returnRate,
          tempo: root.params.timeline ? Motion.styleTempo : 1,
          openS: (Motion.still && !root.params.timeline ? Motion.calmBaseMs : root.openMs) / 1000,
          closeS: (Motion.still && !root.params.timeline ? Motion.calmBaseMs / Motion.returnRate : root.closeMs) / 1000,
          pill: (h) => Metrics.pill(h),
          btn: root.btnX - (desk.width - root.bigA) / 2 })
    readonly property var g: root.f.geom
    readonly property var e: root.f.fx

    Rectangle {
        id: desk
        anchors.fill: parent
        radius: Metrics.r(9) * root.s
        color: Qt.alpha(Theme.fg, 0.045)
        border.width: Math.max(1, root.s)
        border.color: Theme.hair
        clip: true

        // la barra (sólo Bar panels) y su acceso
        Rectangle {
            visible: root.kind === "bar"
            width: parent.width
            height: root.barH
            color: Theme.raisedBg
            Rectangle {
                x: root.btnX - width / 2
                anchors.verticalCenter: parent.verticalCenter
                width: 4 * root.s; height: width; radius: width / 2
                color: root.v > 0.01 ? Theme.primary : Theme.fgVariant
            }
        }

        // halo del acento (Bloom, Unfold, Power-on)
        Rectangle {
            readonly property real pad: 4 * root.s
            visible: root.e.glow > 0.01
            x: shape.x - pad; y: shape.y - pad
            width: shape.width + 2 * pad; height: shape.height + 2 * pad
            radius: shape.radius + pad
            color: Qt.alpha(Theme.primary, 0.3)
            opacity: root.e.glow
        }

        Rectangle {
            id: shape
            readonly property real topY: root.kind === "bar" ? root.barH : 4 * root.s
            readonly property real finalX: (desk.width - root.bigA) / 2
            readonly property real cx: root.kind === "bar"
                ? root.btnX + (finalX + root.bigA / 2 - root.btnX) * Math.max(0, Math.min(1, root.e.c))
                : desk.width / 2
            width: Math.max(0, root.g.a)
            height: Math.max(0, root.g.d)
            x: cx - width / 2
            y: topY
            visible: width > 0.5 && height > 0.5
            radius: Math.min(root.g.r, width / 2, height / 2)
            // con la barra, las dos esquinas de arriba unidas a ella
            topLeftRadius: root.kind === "bar" ? 0 : radius
            topRightRadius: root.kind === "bar" ? 0 : radius
            color: Theme.raisedBg
            border.width: Math.max(1, root.s)
            border.color: Theme.cardBorder
            antialiasing: true
            transform: Rotation {
                origin.x: shape.width / 2; origin.y: 0
                axis { x: 1; y: 0; z: 0 }
                angle: root.e.rot
            }

            // El contenido conserva su tamaño; el estilo decide por qué borde se descubre.
            Item {
                id: content
                anchors.fill: parent
                clip: true
                opacity: {
                    // Al recoger Drop o quitar la máscara de Ink, la cápsula ya no contiene el panel.
                    if (root.kind === "island" && (root.e.cOp < 0 || root.style === "ink")) {
                        const depth = (shape.height - root.restG.d) / Math.max(1, root.bigD - root.restG.d);
                        return root.opening ? Math.max(0, Math.min(1, depth)) : Motion.leave(1 - depth);
                    }
                    return root.e.cOp < 0 ? 1 : root.e.cOp;
                }
                layer.enabled: (root.style === "ink" || root.style === "mist") && root.v > 0.001 && root.v < 0.999
                layer.effect: Component {
                    ShapeRevealEffect {
                        s: root.s * 0.5
                        masked: root.style === "ink"
                        blurred: root.style === "mist"
                        ink: root.e.ink >= 0 ? root.e.ink : 1
                        // A escala de miniatura, la tinta de la isla se lee en las propias líneas.
                        ring: root.kind === "bar" ? root.e.ring : 0
                        blur: root.e.blur
                        zoom: root.e.zoom
                        cx: root.kind === "bar" ? root.btnX - shape.x : width / 2
                        cy: root.kind === "bar" ? 0 : root.restG.d / 2
                        reach: root.kind === "bar" ? Math.hypot(Math.max(root.btnX - shape.finalX,
                            shape.finalX + root.bigA - root.btnX), root.bigD)
                            : Math.hypot(root.bigA / 2, root.bigD - cy)
                    }
                }
                Item {
                    width: root.bigA
                    height: root.bigD
                    x: root.kind === "bar" && root.style === "ink" ? shape.finalX - shape.x : (parent.width - width) / 2
                    y: ShapeOpen.anchorsContent(root.kind, root.style) ? 0 : parent.height - height
                    Rectangle {
                        x: 6 * root.s; y: 6 * root.s
                        width: parent.width * 0.38; height: 4 * root.s; radius: Metrics.pill(height)
                        color: Theme.primary
                        opacity: 0.85
                    }
                    Column {
                        x: 6 * root.s; y: 16 * root.s
                        spacing: 4 * root.s
                        Repeater {
                            model: [0.82, 0.64, 0.74]
                            Rectangle {
                                required property var modelData
                                width: (root.bigA - 12 * root.s) * modelData; height: 3 * root.s; radius: Metrics.pill(height)
                                color: Theme.fgVariant
                                opacity: 0.35
                            }
                        }
                    }
                }
            }

            // relleno del acento o sombra de la solapa
            Rectangle {
                anchors.fill: parent
                visible: root.e.tint > 0.001 || root.e.shade > 0.001
                radius: parent.radius
                topLeftRadius: parent.topLeftRadius
                topRightRadius: parent.topRightRadius
                color: root.e.tint > 0.001 ? Qt.alpha(Theme.primary, 0.9 * root.e.tint) : Qt.rgba(0, 0, 0, root.e.shade)
            }
        }
    }
}
