import QtQuick
import QtQuick.Shapes
import "../theme"
import "../services"

/**
 * Miniatura de un estilo de interfaz (F4 del estilo, 2026-11-14; ADR-34; Settings → Appearance → Interface style): un
 * panel pequeño con un título, un interruptor y un deslizador, dibujado con la tabla de ESE estilo
 * (`Style.params(style)`), no con el activo: `Metrics` y los controles comunes siguen al estilo global y un singleton no
 * se puede acotar a un subárbol. Mismo patrón que `WindowStylePreview` con `Reveal`.
 *
 * Los colores son los de la paleta actual (cualquiera, también la de matugen) y, para terminal, el marco, las
 * decoraciones y la letra que el usuario tenga elegidos: la miniatura cambia en cuanto se tocan esas filas. Quieta: no
 * tiene animación ni temporizador.
 */
Item {
    id: root

    property real s: 1
    property string style: "soft"

    readonly property var p: Style.params(root.style)
    readonly property bool term: root.style === "terminal"
    readonly property string frame: root.term ? Settings.termFrame : "none"
    readonly property string decor: root.term ? Settings.termDecor : "none"
    readonly property string family: root.term && Settings.termMono ? Typography.mono : Typography.uiChosen
    readonly property color edge: root.term ? Theme.frameFor("") : Theme.cardBorder

    implicitWidth: 136 * s
    implicitHeight: 80 * s

    // el «escritorio» de fondo: lo pinta el estilo activo, como el resto de la tarjeta
    Rectangle {
        id: desk
        anchors.fill: parent
        radius: Metrics.r(9) * root.s
        color: Qt.alpha(Theme.fg, 0.045)
        border.width: Math.max(1, root.s)
        border.color: Theme.hair
        clip: true

        Rectangle {
            id: panel
            anchors.fill: parent
            anchors.margins: 8 * root.s
            radius: root.p.rMd * root.s * 0.75
            color: Theme.raisedBg
            border.width: root.frame === "segmented" ? 0 : Math.max(1, root.s)
            border.color: root.edge

            // marco doble: un segundo trazo por dentro
            Rectangle {
                visible: root.frame === "double"
                anchors.fill: parent
                anchors.margins: 3 * root.s
                radius: 0
                color: "transparent"
                border.width: Math.max(1, root.s)
                border.color: root.edge
            }
            // marco segmentado: trazo discontinuo
            Shape {
                visible: root.frame === "segmented"
                anchors.fill: parent
                ShapePath {
                    strokeColor: root.edge
                    strokeWidth: Math.max(1, root.s)
                    fillColor: "transparent"
                    strokeStyle: ShapePath.DashLine
                    dashPattern: [3, 2]
                    startX: 0.5; startY: 0.5
                    PathLine { x: panel.width - 0.5; y: 0.5 }
                    PathLine { x: panel.width - 0.5; y: panel.height - 0.5 }
                    PathLine { x: 0.5; y: panel.height - 0.5 }
                    PathLine { x: 0.5; y: 0.5 }
                }
            }
            // corchetes de esquina
            Repeater {
                model: root.term && root.decor !== "none" ? 4 : 0
                Item {
                    id: br
                    required property int index
                    readonly property bool atRight: index % 2 === 1
                    readonly property bool atBottom: index >= 2
                    readonly property real arm: 7 * root.s
                    readonly property real th: Math.max(1, 2 * root.s)
                    x: atRight ? panel.width - arm : 0
                    y: atBottom ? panel.height - arm : 0
                    width: arm; height: arm
                    Rectangle { y: br.atBottom ? br.arm - br.th : 0; width: br.arm; height: br.th; color: Theme.frameMark }
                    Rectangle { x: br.atRight ? br.arm - br.th : 0; width: br.th; height: br.arm; color: Theme.frameMark }
                }
            }
            // velo de acento de soft: una franja tenue arriba
            Rectangle {
                visible: root.p.veil
                x: 1; y: 1
                width: parent.width - 2
                height: parent.height * 0.4
                radius: parent.radius
                gradient: Gradient {
                    GradientStop { position: 0; color: Qt.alpha(Theme.primary, 0.10) }
                    GradientStop { position: 1; color: "transparent" }
                }
            }

            Text {
                x: 8 * root.s; y: 6 * root.s
                text: root.term ? "> sumi" : "Sumi"
                color: Theme.fg
                font.family: root.family
                font.pixelSize: 10 * root.s
                font.weight: Font.DemiBold
            }

            // interruptor encendido: cápsula con botón (soft) o `[ON]` (terminal)
            Rectangle {
                id: tog
                x: parent.width - width - 8 * root.s; y: 7 * root.s
                width: (root.term ? 26 : 22) * root.s
                height: 12 * root.s
                radius: root.p.pill ? height / 2 : root.p.pillR
                color: Theme.primary
                Rectangle {
                    visible: !root.term
                    width: parent.height - 4 * root.s; height: width
                    radius: width / 2
                    x: parent.width - width - 2 * root.s
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.fgOnPrimary
                }
                Text {
                    visible: root.term
                    anchors.centerIn: parent
                    text: "ON"
                    color: Theme.fgOnPrimary
                    font.family: Typography.mono
                    font.pixelSize: 7 * root.s
                    font.weight: Font.Bold
                }
            }

            // deslizador al 60 %: pista redonda con relleno (soft) o celdas (terminal)
            Item {
                id: sl
                x: 8 * root.s
                width: parent.width - 16 * root.s
                y: parent.height - 16 * root.s
                height: 5 * root.s
                readonly property real v: 0.6
                Rectangle {
                    visible: !root.term
                    anchors.fill: parent
                    radius: height / 2
                    color: Theme.trackBg
                    Rectangle { width: parent.width * sl.v; height: parent.height; radius: parent.radius; color: Theme.primary }
                }
                Repeater {
                    model: root.term ? 12 : 0
                    Rectangle {
                        required property int index
                        readonly property real gap: Math.max(1, Math.round(1.5 * root.s))
                        readonly property real cw: (sl.width - gap * 11) / 12
                        x: Math.round(index * (cw + gap))
                        width: Math.max(1, Math.round(cw))
                        height: sl.height
                        color: (index + 0.5) / 12 <= sl.v ? Theme.primary : Theme.trackBg
                    }
                }
            }
            // una fila de texto entre el título y el deslizador
            Rectangle {
                x: 8 * root.s; y: 26 * root.s
                width: parent.width * 0.55; height: 3 * root.s
                radius: root.p.pill ? height / 2 : 0
                color: Theme.fgVariant
                opacity: 0.35
            }
        }
    }
}
