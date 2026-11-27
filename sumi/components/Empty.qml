import QtQuick
import "../theme"
import "../lib/text-wrap.js" as TextWrap

/**
 * Lo que se ve cuando no hay nada que ver: lista vacía, búsqueda sin resultados,
 * dato que aún se está cargando.
 *
 * Existía en cada superficie como un `Text` centrado en gris, con la redacción
 * que le tocara. Un estado vacío es una oportunidad de decir **qué hacer
 * ahora**, no sólo de informar de que no hay nada — de ahí `hint`.
 */
Column {
    id: empty

    property real s: 1
    property string glyph: ""
    property string text: ""
    /** Qué hacer para que deje de estar vacío. */
    property string hint: ""
    property bool loading: false
    /**
     * Ancho máximo de los textos; lo que no quepa se recorta con elipsis. Lo pone
     * quien lo usa (`parent.width`): un error de red llega entero del servicio y
     * sin tope se salía de la superficie.
     */
    property real maxWidth: 100000

    spacing: Metrics.sp2 * empty.s

    Icon {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: empty.glyph.length > 0
        name: empty.glyph
        size: Metrics.glyphLg * empty.s
        color: Theme.outline
        opacity: 0.7

        /** Cargando: el glifo late despacio. Es el único bucle del componente. */
        SequentialAnimation on opacity {
            running: empty.loading && !Motion.still
            loops: Animation.Infinite
            // con la velocidad elegida (fase 3B; antes 700 ms fijos)
            NumberAnimation { to: 0.28; duration: Motion.dur(700); easing.type: Easing.InOutSine }
            NumberAnimation { to: 0.70; duration: Motion.dur(700); easing.type: Easing.InOutSine }
        }
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(implicitWidth, empty.maxWidth)
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        text: empty.text
        color: Theme.fgVariant
        font.family: Typography.ui
        font.pixelSize: Typography.body * empty.s
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(implicitWidth, empty.maxWidth)
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        // hasta dos renglones, partidos entre « · » (auditoría tipográfica 2026-11-18): una pista no se elide
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        visible: empty.hint.length > 0
        text: TextWrap.keepSegments(empty.hint)
        color: Theme.outlineText
        font.family: Typography.ui
        font.pixelSize: Typography.caption * empty.s
    }
}
