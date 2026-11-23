import QtQuick
import "../theme"

/**
 * Un mensaje de estado dentro de una superficie: el error de una conexión, el
 * aviso de que algo va a cerrar la barra, la confirmación de que el backup
 * terminó.
 *
 * Hasta ahora cada superficie lo resolvía con un `Text` suelto de color
 * distinto, así que un fallo de wifi y una confirmación de borrado se parecían.
 * Aquí un fallo **tiene forma**: filo de color a la izquierda, glifo, y el
 * mismo sitio siempre.
 *
 * El tono NO es decorativo — dice qué clase de cosa es:
 *   ok      salió bien              warn  algo que mirar
 *   danger  falló o es destructivo  info  contexto
 */
Item {
    id: notice

    property real s: 1
    property string tone: "info"
    property string text: ""
    /** Glifo propio; vacío = el del tono. */
    property string glyph: ""

    readonly property color tint: notice.tone === "ok" ? Theme.ok
        : notice.tone === "warn" ? Theme.warn
        : notice.tone === "danger" ? Theme.danger
        : Theme.info

    readonly property string mark: notice.glyph.length > 0 ? notice.glyph
        : notice.tone === "ok" ? "check"
        : notice.tone === "danger" ? "alert"
        : notice.tone === "warn" ? "alert"
        : "info"

    implicitHeight: body.implicitHeight + Metrics.sp2 * notice.s
    height: implicitHeight

    Rectangle {
        anchors.fill: parent
        radius: Metrics.rSm * notice.s
        color: Qt.alpha(notice.tint, 0.10)
    }

    /** El filo: es lo que se reconoce de lejos, antes de leer nada. */
    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: Metrics.sp1 * notice.s
        anchors.bottomMargin: Metrics.sp1 * notice.s
        width: 2 * notice.s
        radius: Metrics.pill(width)
        color: notice.tint
    }

    Row {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Metrics.sp3 * notice.s
        anchors.rightMargin: Metrics.sp2 * notice.s
        spacing: Metrics.sp2 * notice.s

        Icon {
            anchors.verticalCenter: parent.verticalCenter
            name: notice.mark
            size: 12 * notice.s
            color: notice.tint
        }

        Text {
            width: parent.width - 12 * notice.s - Metrics.sp2 * notice.s
            text: notice.text
            wrapMode: Text.WordWrap
            color: Theme.fg
            font.family: Typography.ui
            font.pixelSize: Typography.caption * notice.s
        }
    }
}
