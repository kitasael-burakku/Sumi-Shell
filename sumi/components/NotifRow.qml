import QtQuick
import "../theme"
import "../services"

/**
 * Un aviso sin leer en el Centro de control: app, resumen, hasta tres líneas de texto
 * y el `⊗` que lo descarta. Pulsar la fila abre Notifications con la entrada localizada (lo decide el anfitrión).
 *
 * Verla aquí NO la marca como leída (la lectura es del centro, por permanencia), igual que antes del rediseño.
 * Todo lo que pinta lo escribió otra aplicación: sólo texto plano, el icono por `Notifs.appIconOf` (sólo local).
 */
Rectangle {
    id: row

    property real s: 1
    /** La entrada de `NotifHistory` (o null mientras desaparece). */
    property var entry: null
    property bool focused: false
    property bool dismissFocused: false
    signal activated()
    signal dismissed()

    readonly property bool critical: row.entry !== null && row.entry.urgency === 2
    readonly property real pad: 12 * row.s
    readonly property real verticalPad: 13 * row.s

    implicitHeight: Math.ceil(Math.max(copy.implicitHeight, dismiss.height) + 2 * row.verticalPad)
    radius: Metrics.rMd * row.s
    color: area.containsMouse ? Qt.alpha(Theme.primary, 0.08) : Theme.tileBg
    border.width: row.focused ? Metrics.focusWidth * row.s : 1
    border.color: row.focused ? Theme.focusRing : row.critical ? Qt.alpha(Theme.errorColor, 0.6) : Theme.glassBorder
    Behavior on color { ColorAnimation { duration: Motion.fast } }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        Accessible.role: Accessible.Button
        Accessible.name: row.entry ? (row.entry.app || "Notification") + ": " + String(row.entry.summary || "") : ""
        Accessible.onPressAction: row.activated()
        onClicked: row.activated()
    }

    Column {
        id: copy
        x: Math.round(row.pad)
        y: Math.round((parent.height - height) / 2)
        width: Math.max(0, Math.floor(dismiss.x - x - 8 * row.s))
        spacing: 4 * row.s
        Row {
            width: parent.width
            spacing: 6 * row.s
            Image {
                id: appIcon
                width: 13 * row.s
                height: 13 * row.s
                y: Math.round((parent.height - height) / 2)
                source: row.entry ? Notifs.appIconOf(row.entry) : ""
                visible: status === Image.Ready
                sourceSize.width: 26 * row.s
                sourceSize.height: 26 * row.s
                asynchronous: true
            }
            // terminal: la etiqueta aparte, para que el nombre no cambie de contenido con el estilo (un Text con elide
            // que se re-maqueta deja los glifos 0,2 px a un lado; banco de la fase D, 2026-11-15)
            Text {
                id: tag
                visible: Style.terminal
                y: Math.round((parent.height - height) / 2)
                textFormat: Text.PlainText
                text: row.critical ? "[CRIT]" : "[INFO]"
                color: row.critical ? Theme.errorColor : Theme.fgVariant
                font.family: Typography.ui
                font.pixelSize: Typography.caption * row.s
                font.features: ({ "calt": 0, "liga": 0 })
            }
            Text {
                // ancho FIJO en los dos estilos: se reserva el hueco de la etiqueta aunque no esté, para que el nombre
                // no cambie de ancho con el estilo (Qt re-maqueta y desplaza los glifos; fase D, 2026-11-15)
                width: Math.max(0, Math.floor(parent.width - (appIcon.visible ? appIcon.width + parent.spacing : 0)
                                  - Math.round(48 * row.s) - parent.spacing))
                y: Math.round((parent.height - height) / 2)
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: row.entry ? (row.entry.app || "Notification") : ""
                color: row.critical ? Theme.errorColor : Theme.fgVariant
                font.family: Typography.ui
                font.pixelSize: Typography.caption * row.s
            }
        }
        Text {
            width: parent.width
            text: row.entry ? String(row.entry.summary || "") : ""
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: Theme.fg
            font.family: Typography.ui
            font.pixelSize: Typography.body * row.s
            font.weight: Font.DemiBold
        }
        Text {
            width: parent.width
            visible: text.length > 0
            text: row.entry ? String(row.entry.body || "").replace(/<[^>]*>/g, "").replace(/\s+/g, " ").trim() : ""
            textFormat: Text.PlainText
            elide: Text.ElideRight
            wrapMode: Text.Wrap
            maximumLineCount: 3
            color: Theme.fgVariant
            font.family: Typography.ui
            font.pixelSize: Typography.label * row.s
        }
    }

    GlyphButton {
        id: dismiss
        anchors.right: parent.right
        anchors.rightMargin: 6 * row.s
        y: Math.round((parent.height - height) / 2)
        s: row.s
        glyph: "dismiss"
        label: "Dismiss notification"
        glyphSize: 16
        focused: row.dismissFocused
        onTriggered: row.dismissed()
    }
}
