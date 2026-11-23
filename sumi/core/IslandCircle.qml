import QtQuick
import "../theme"
import "../components"

/**
 * Una pieza circular a un lado del island (fase 8B-1): Música a la izquierda, Red a la
 * derecha (`futureDinamicIslandidlesurface.md`, `New-DynamicIsland.png`).
 *
 * NO es hija del `Morph`: la coloca `core/Screen` a una distancia FIJA del centro, así
 * que ni el ancho de la cápsula ni la otra pieza la mueven. Sólo pinta, dice si el
 * puntero está encima (Screen no lo cuenta como hover del island) y emite `activated`.
 *
 * El diámetro es el alto de la cápsula en reposo: en la referencia los tres se leen
 * como una sola franja.
 */
Item {
    id: c

    property real s: 1
    /** Anillo de estado. Transparente = sin anillo. */
    property color halo: "transparent"
    /** Nombre accesible y tooltip. */
    property string label: ""
    /** Si se ve (la pieza de Música desaparece sin pista). Controla también la máscara. */
    property bool shown: true
    // Presentation changes follow the bar geometry, without a second opacity animation chasing it.
    property bool coordinated: false
    property real presentationOpacity: 1
    default property alias content: inner.data

    signal activated()

    readonly property bool hovered: hh.hovered
    /**
     * 1 en reposo; `Metrics.sideCompact` con un panel abierto (8B-2). Cambia el TAMAÑO,
     * no una escala: la máscara y el hueco hasta el panel siguen al cuadrado real.
     */
    property real sizeFactor: 1
    // el muelle de la forma (2026-10-01): el círculo se aparta y encoge al mismo pulso que el
    // borde del panel que lo empuja; antes 240 ms OutCubic llegaban después que el panel
    SpringValue { id: sizeSpring; target: c.sizeFactor; epsilon: 0.004 }
    readonly property real d: Metrics.restH * c.s * sizeSpring.value

    width: c.d
    height: c.d

    /**
     * Entra y sale con un fundido y una escala breves; la posición no se toca. `visible`
     * por `shown` y por la opacidad a la vez: no hay positioner dentro, así que no hay
     * medida que congelar (la trampa de `closeness` es de los Row/Column).
     */
    property real shownOpacity: c.shown ? 1 : 0
    opacity: c.shownOpacity * c.presentationOpacity
    scale: c.shown ? (tap.pressed ? 0.96 : 1) : 0.85
    visible: c.shown || c.opacity > 0.01
    // se va deprisa (la forma del island crece hacia ella); vuelve con calma
    Behavior on shownOpacity { enabled: !c.coordinated; NumberAnimation { duration: c.shown ? Motion.fast : Motion.vanish; easing.type: Easing.OutCubic } }
    Behavior on scale { NumberAnimation { duration: Motion.fast; easing.type: Easing.OutBack } }

    Glass {
        anchors.fill: parent
        radius: Metrics.pill(width)
        s: c.s
        shadowed: c.shown
    }

    Item {
        id: inner
        anchors.fill: parent
    }

    /** El halo: mismo color que el glifo (lo decide quien lo usa). */
    Rectangle {
        anchors.fill: parent
        radius: Metrics.pill(width)
        color: "transparent"
        border.width: 1.5 * c.s
        border.color: c.halo
        visible: c.halo.a > 0
        Behavior on border.color { ColorAnimation { duration: Motion.standard } }
    }

    /** Hover tenue, como el resto de controles (DESIGN §5). */
    Rectangle {
        anchors.fill: parent
        radius: Metrics.pill(width)
        color: Theme.hoverBg
        opacity: hh.hovered ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Motion.fast } }
    }

    HoverHandler {
        id: hh
        enabled: c.shown
        cursorShape: Qt.PointingHandCursor
    }
    TapHandler {
        id: tap
        enabled: c.shown
        onTapped: c.activated()
    }

    Accessible.role: Accessible.Button
    Accessible.name: c.label
    Accessible.onPressAction: c.activated()
}
