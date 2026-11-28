pragma ComponentBehavior: Bound

import QtQuick
import "../theme"

/**
 * El marco común de una superficie (rediseño, fase 4, DESIGN §3): **Back, Forward y
 * Close**, siempre en el mismo sitio de la cabecera.
 *
 * Back/Forward recorren el historial de ESTA pantalla (`SurfaceHost`); con el
 * teclado son Alt+← / Alt+→ (un `Shortcut` de `Screen`, que también funciona con
 * el foco en un campo). Close es lo mismo que Esc desde la raíz o un clic fuera.
 * Iconos con nombre accesible y objetivo de clic de 32 px; no se superponen al
 * contenido: ocupan su hueco en la cabecera.
 *
 *   FrameNav { s: root.s; host: root.host; onCloseRequested: root.requestClose() }
 */
Row {
    id: nav

    property real s: 1
    /** El `SurfaceHost` (lo trae `Surface.host`). Sin él, Back/Forward quedan apagados. */
    property var host: null
    property bool showClose: true
    signal closeRequested()

    spacing: 2 * nav.s

    /** «Item no longer available», un momento, tras volver a algo que ya no existe. */
    Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: nav.host !== null && nav.host.historyNote.length > 0
        text: nav.host ? nav.host.historyNote : ""
        rightPadding: 6 * nav.s
        color: Theme.warn
        font.family: Typography.ui
        font.pixelSize: Typography.caption * nav.s
    }

    component NavButton: Item {
        id: b
        property string glyph: ""
        property string label: ""
        property bool active: true
        signal pressed()

        width: 22 * nav.s
        height: 22 * nav.s
        opacity: b.active ? 1 : Theme.disabledOpacity

        Accessible.role: Accessible.Button
        Accessible.name: b.label
        Accessible.onPressAction: if (b.active) b.pressed()

        InteractionPlate {
            anchors.fill: parent
            s: nav.s
            radius: Metrics.r(6) * nav.s
            hovered: area.containsMouse && b.active
            down: area.pressed && hovered
        }
        Icon {
            anchors.centerIn: parent
            name: b.glyph
            size: 12 * nav.s
            color: !b.active ? Theme.disabledFg : (area.containsMouse ? Theme.fg : Theme.fgVariant)
            Behavior on color { ColorAnimation { duration: Motion.fast } }
        }
        MouseArea {
            id: area
            anchors.fill: parent
            anchors.margins: -5 * nav.s     // 32 px de objetivo sin agrandar el icono
            hoverEnabled: true
            enabled: b.active
            cursorShape: Qt.PointingHandCursor
            onClicked: b.pressed()
        }
    }

    NavButton {
        glyph: "chevron-left"
        label: "Back (Alt+Left)"
        active: nav.host !== null && nav.host.canBack
        onPressed: nav.host.historyBack()
    }
    NavButton {
        glyph: "chevron-right"
        label: "Forward (Alt+Right)"
        active: nav.host !== null && nav.host.canForward
        onPressed: nav.host.historyForward()
    }
    NavButton {
        visible: nav.showClose
        glyph: "close"
        label: "Close (Esc)"
        onPressed: nav.closeRequested()
    }
}
