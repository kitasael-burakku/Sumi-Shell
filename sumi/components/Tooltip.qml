import QtQuick
import "../theme"

/**
 * El tooltip de la shell (fase 3A de coherencia, 2026-11-27, ADR-42).
 *
 * Antes había dos hechos a mano y distintos: el de la cara hover (sin espera, con fundido, 18 × 10, peso medio) y el de
 * la barra (400 ms, de golpe, 16 × 8, peso normal); en las superficies, ninguno. Ahora uno, con una sola regla:
 *   - con el puntero sale tras `delay` (la vista previa y el tooltip son complementarios: quien lo usa decide `active`);
 *   - con el teclado (`immediate`), al momento;
 *   - entra con un fundido y, en Normal, 4 px de recorrido; Reduced sin recorrido; Off de golpe (Motion).
 * Relleno opaco con el marco de la shell (Soft y Terminal), texto `caption` en peso medio. Dónde va lo decide quien lo pone
 * (x/y o anclas); el contenido no se mide fuera de aquí.
 *
 * Excepción decidida por el autor (16G): sin tooltip en Back/Forward del marco de Settings.
 */
Glass {
    id: tip

    property string text: ""
    /** Quiere enseñarse (hover o foco de teclado sobre algo con nombre). */
    property bool active: false
    /** Teclado: sin espera. */
    property bool immediate: false
    property int delay: 400

    /** Retiene el último texto no vacío para que no se borre a mitad del fundido. */
    property string shownText: ""
    onTextChanged: if (tip.text.length > 0) tip.shownText = tip.text
    Component.onCompleted: if (tip.text.length > 0) tip.shownText = tip.text

    readonly property bool want: tip.active && tip.text.length > 0
    property bool waited: false
    onWantChanged: { tip.waited = false; if (tip.want && !tip.immediate) wait.restart(); else wait.stop(); }
    Timer { id: wait; interval: tip.delay; onTriggered: tip.waited = true }
    readonly property bool shown: tip.want && (tip.immediate || tip.waited)

    width: label.implicitWidth + 16 * tip.s
    height: label.implicitHeight + 8 * tip.s
    radius: Metrics.rSm * tip.s
    z: 50
    // opaco (pedido del autor al ver la 3A): un tooltip se pone ENCIMA del contenido (deslizadores, tarjetas) y el
    // vidrio lo dejaba transparentarse; el marco sigue siendo el del estilo (Soft o Terminal)
    color: Qt.alpha(Theme.surfaceContainerHigh, 1)

    visible: opacity > 0.01
    opacity: tip.shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Motion.fast; easing.type: Motion.easeStandard } }
    transform: Translate {
        // el recorrido es movimiento: con Reduced u Off, ninguno
        y: (tip.shown || Motion.still) ? 0 : -4 * tip.s
        Behavior on y {
            enabled: !Motion.still
            NumberAnimation { duration: Motion.fast; easing.type: Motion.easeStandard }
        }
    }

    Accessible.role: Accessible.ToolTip
    Accessible.name: tip.shownText

    Text {
        id: label
        anchors.centerIn: parent
        text: tip.shownText
        color: Theme.fg
        font.family: Typography.ui
        font.pixelSize: Typography.caption * tip.s
        font.weight: Font.Medium
    }
}
