import QtQuick
import "../theme"

/**
 * Miniatura animada de un estilo de ventana (2026-11-11, Settings → Shell → Animations → Window style): un escritorio
 * pequeño y una ventana que se abre y se cierra con `theme/Reveal` y los números de ESE estilo, no los del ajuste.
 * Sólo se mueve mientras `playing`; quieta, enseña la ventana abierta. Usa el modo y la velocidad efectivos.
 *
 * 2026-11-17 (ADR-36): también los estilos con línea de tiempo; la ventanita aplica sx/sy (Power-on, Mochi) y, mientras
 * anima, la misma capa con theme/RevealEffect que las ventanas de verdad (Bloom, Ink, Scroll, Mist).
 */
Item {
    id: root

    property real s: 1
    property string style: "minimalist"
    property bool playing: false

    implicitWidth: 136 * s
    implicitHeight: 80 * s

    Reveal {
        id: prv
        style: root.style
        animated: cycle.playing
        // A escala de miniatura: la ventana real mide unas cinco veces más; la mitad de la subida se lee igual.
        s: root.s * 0.5
        shown: cycle.opened
    }

    PreviewCycle {
        id: cycle
        playing: root.playing && !Motion.off
        openMs: prv.params.timeline ? Motion.styleMs(prv.params.openMs) : Motion.dur(260)
        closeMs: prv.params.timeline ? Motion.styleMs(prv.params.closeMs) : Motion.dur(180)
    }

    Rectangle {
        id: desk
        anchors.fill: parent
        radius: Metrics.r(9) * root.s
        color: Qt.alpha(Theme.fg, 0.045)
        border.width: Math.max(1, root.s)
        border.color: Theme.hair
        clip: true

        Rectangle {
            id: win
            width: desk.width * 0.62
            height: desk.height * 0.62
            anchors.centerIn: parent
            radius: Metrics.r(6) * root.s
            color: Theme.raisedBg
            border.width: Math.max(1, root.s)
            border.color: Theme.cardBorder
            opacity: prv.opacity
            scale: prv.scale
            transformOrigin: Item.Center
            transform: [Translate { y: prv.dy }, Scale { origin.x: win.width / 2; origin.y: win.height / 2; xScale: prv.sx; yScale: prv.sy }]
            antialiasing: true
            layer.enabled: prv.effect && prv.progress > 0.001 && prv.progress < 0.999
            layer.effect: prv.effect ? winFx : null
            Component { id: winFx; RevealEffect { rv: prv; s: root.s * 0.5; radius: win.radius } }

            // la barra de título y dos renglones: lo justo para leer «una ventana»
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
                        width: (win.width - 12 * root.s) * modelData; height: 3 * root.s; radius: Metrics.pill(height)
                        color: Theme.fgVariant
                        opacity: 0.35
                    }
                }
            }
        }
    }
}
