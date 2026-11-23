import QtQuick
import "../theme"

/**
 * Deslizador horizontal de 0 a 1.
 *
 * El shell no tenia ninguno: los ajustes se hacen con `Choice` (valores
 * discretos) y `Toggle`. El volumen es continuo, asi que hacia falta.
 *
 * Tres formas de moverlo, las mismas que ofrecia Waybar entre `pulseaudio` y
 * `pulseaudio/slider`: arrastrar, pulsar en un punto, y la rueda -- con el
 * mismo paso del 2 % que tenia `scroll-step`.
 *
 * `value` NO se escribe solo al arrastrar: se emite `moved(v)` y quien manda
 * decide. Asi el valor mostrado siempre es el que Pipewire confirma, y no se
 * queda pegado si el cambio se rechaza.
 */
Item {
    id: root

    /** La familia de acento de la zona (Theme.fam; lib/accent-zones.js). */
    readonly property var acc: Theme.fam(palette.accent)
    property real value: 0
    property bool muted: false
    property real s: 1
    /** Paso de la rueda, en fraccion. 0.02 = el `scroll-step: 2` de Waybar. */
    property real step: 0.02
    property color tint: root.acc.fill

    /** Lo pinta; el foco de teclado lo lleva quien contiene el Slider. */
    property bool focused: false
    /**
     * Su propio anillo de foco. Fuera cuando la fila que lo contiene ya dibuja el suyo (2026-10-01,
     * captura del usuario: Sound en el Centro de control enseñaba una caja dentro de otra).
     */
    property bool ring: true
    /** Nombre accesible: «Output volume», «Brightness»… */
    property string label: ""
    signal moved(real value)

    Accessible.role: Accessible.Slider
    Accessible.name: root.label
    Accessible.focusable: true
    Accessible.focused: root.focused
    Accessible.description: Math.round(root.value * 100) + " percent"
    Accessible.onIncreaseAction: root.adjust(1)
    Accessible.onDecreaseAction: root.adjust(-1)

    function adjust(direction) {
        if (direction && root.enabled)
            root.moved(Math.max(0, Math.min(1, root.value + direction * root.step)));
    }

    implicitHeight: 18 * root.s

    readonly property real trackH: 6 * root.s
    readonly property real knobR: 7 * root.s
    /**
     * Cuánto se recoge el carril por cada lado (2026-10-01, capturas del usuario: en la Audio UI y
     * en el Centro de control el pomo al 100 % salía medio fuera y lo cortaba el `clip` de la
     * lista). El pomo —también crecido al pasar el puntero (×1,15)— cabe entero dentro del Slider,
     * y su borde coincide con el de lo que va alineado encima (la cifra del porcentaje).
     */
    readonly property real inset: Math.ceil(root.knobR * 1.15)

    /**
     * El valor que se PINTA, entre 0 y 1. Aqui vive la animacion, y no en el
     * ancho en pixeles (ADR-25).
     *
     * El ancho del carril lo decide el island, que se esta animando: si el
     * `Behavior` estuviera sobre `fill.width`, cada fotograma del morph moveria
     * su destino, Qt reiniciaria la animacion con la duracion completa y la
     * propiedad no avanzaria nada. Medido el 2026-09-08: el relleno se quedaba
     * congelado 437 ms y el pomo 580, y el pomo llegaba a su sitio 720 ms
     * despues de abrir el mezclador — el "los deslizadores entran desde fuera".
     *
     * Con la animacion sobre la fraccion, el destino solo se mueve cuando de
     * verdad cambia el volumen, asi que la animacion corre; y el pixel, que es
     * `shown * anchoDelCarril`, sigue a la geometria fotograma a fotograma.
     */
    property real shown: Math.max(0, Math.min(1, root.value))
    Behavior on shown {
        enabled: !area.pressed
        NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic }
    }

    Rectangle {
        id: track
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: root.inset
        anchors.rightMargin: root.inset
        anchors.verticalCenter: parent.verticalCenter
        height: root.trackH
        radius: Metrics.pill(height)
        // terminal (ADR-34): la pista son segmentos; el carril continuo y su relleno sólo existen para medir
        color: Style.terminal ? "transparent" : root.acc.track

        Rectangle {
            id: fill
            width: root.shown * parent.width
            height: parent.height
            radius: parent.radius
            visible: !Style.terminal
            color: root.muted ? Theme.fgVariant : root.tint
            opacity: root.muted ? 0.45 : 1
            // `color` si lleva Behavior: lo mueve un estado discreto (mute), no
            // la geometria. Es el criterio de ADR-25.
            Behavior on color { ColorAnimation { duration: Motion.fast } }
        }
    }

    /**
     * Terminal: `segN` segmentos fijos (el número no sigue al ancho: con el morph del island se recrearían los
     * delegados en cada fotograma; sólo cambia su geometría). Uno se enciende si su centro queda por debajo del valor.
     * En soft no se crean. Los segmentos nacen sin radio y no lo cambian nunca (ver
     * `Style.squareR`: lo que se rompe al cambiar de estilo en caliente es pasar un radio de > 0 a 0).
     */
    Item {
        id: segs
        objectName: "styleMarks"
        anchors.fill: track
        visible: Style.terminal
        readonly property int segN: 24
        readonly property real gap: Math.max(1, Math.round(2 * root.s))
        readonly property real segW: (width - gap * (segN - 1)) / segN
        // la opacidad del silencio, en el contenedor: una sola, no 24 (y bordes en píxel entero)
        opacity: root.muted ? 0.45 : 1
        Repeater {
            model: Style.terminal ? segs.segN : 0
            Rectangle {
                required property int index
                x: Math.round(index * (segs.segW + segs.gap))
                width: Math.round((index + 1) * (segs.segW + segs.gap) - segs.gap) - x
                height: segs.height
                color: (index + 0.5) / segs.segN <= root.shown ? (root.muted ? Theme.fgVariant : root.tint) : root.acc.track
            }
        }
    }

    Rectangle {
        id: knob
        x: track.x + fill.width - width / 2
        anchors.verticalCenter: parent.verticalCenter
        // terminal: un cursor vertical en vez del pomo redondo
        width: Style.terminal ? 3 * root.s : root.knobR * 2
        height: root.knobR * 2
        radius: Style.terminal ? 0 : root.knobR
        color: root.muted ? Theme.fgVariant : root.tint
        border.width: Style.terminal ? 0 : 2
        border.color: Theme.surface
        scale: scaleSpring.value
        // `epsilon` en fracción, no en píxeles: 0.35 pararía el muelle de golpe.
        SpringValue { id: scaleSpring; target: area.containsMouse || area.pressed ? 1.15 : 1; soft: true; epsilon: 0.004 }
    }

    MouseArea {
        id: area
        anchors.fill: parent
        anchors.margins: -4 * root.s
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor

        /** `px` en coordenadas del área; el carril empieza en `track.x` del Slider. (Antes restaba el
         *  margen negativo en vez de sumarlo: el valor caía 8 px a la derecha de donde se pulsaba.) */
        function emitAt(px) {
            const w = track.width;
            if (w <= 0) return;
            root.moved(Math.max(0, Math.min(1, (px + area.x - track.x) / w)));
        }

        onPressed: (mouse) => area.emitAt(mouse.x)
        onPositionChanged: (mouse) => { if (area.pressed) area.emitAt(mouse.x); }
        onWheel: (wheel) => {
            if (!wheel.angleDelta.y) { wheel.accepted = false; return; }
            root.adjust(Math.sign(wheel.angleDelta.y));
        }
    }

    /** Anillo de foco (DESIGN §5): rodea carril y pomo, sin mover nada de sitio. */
    Rectangle {
        anchors.fill: parent
        anchors.margins: -(Metrics.focusGap + Metrics.focusWidth) * root.s
        radius: Metrics.pill(height)
        color: "transparent"
        visible: root.focused && root.ring
        border.width: Metrics.focusWidth * root.s
        border.color: root.acc.ring
    }
}
