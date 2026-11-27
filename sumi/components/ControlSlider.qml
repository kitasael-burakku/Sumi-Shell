import QtQuick
import "../theme"

/**
 * Columna de deslizador del Centro de control (rediseño del 2026-11-15): una tarjeta alta con el `VSlider` y, abajo,
 * su glifo y el porcentaje. Volumen y brillo, a la derecha de las tarjetas, como en el boceto.
 *
 * `available: false` (decisión D3, sin control de brillo): la columna se queda en su sitio, atenuada, con «—» y la
 * razón en `note` (nombre accesible y texto bajo el porcentaje si cabe). Nada se mueve de sitio según el equipo.
 * `opens`: el glifo y la cifra abren otra vista (el volumen abre el Mixer); el carril sólo cambia el valor.
 */
Rectangle {
    id: col

    /** La familia de acento de la zona (Theme.fam; lib/accent-zones.js). */
    readonly property var acc: Theme.fam(palette.accent)
    property real s: 1
    property string glyph: ""
    property string label: ""
    property real value: 0
    property bool available: true
    property bool muted: false
    /** Lo pintado está confirmado por el servicio (false = aún no se ha leído: «…»). */
    property bool known: true
    property string error: ""
    property string note: ""
    property bool opens: false
    property bool focused: false
    signal moved(real v)
    signal opened()

    radius: Metrics.rMd * col.s
    color: Theme.controlBg(col.acc.container, hover.hovered && col.available, footArea.pressed && footArea.containsMouse, false, col.acc)
    border.width: col.focused ? Metrics.focusWidth : 1
    border.color: col.focused ? col.acc.ring : col.error.length > 0 ? Qt.alpha(Theme.dangerText, 0.6) : Theme.cardBorder
    opacity: col.available ? 1 : Theme.disabledOpacity
    Behavior on color { ColorAnimation { duration: Motion.fast } }

    Accessible.ignored: true
    HoverHandler { id: hover }

    VSlider {
        id: slider
        anchors.top: parent.top
        anchors.topMargin: 8 * col.s
        anchors.bottom: foot.top
        anchors.bottomMargin: 2 * col.s
        anchors.horizontalCenter: parent.horizontalCenter
        width: parent.width
        s: col.s
        value: col.value
        available: col.available && col.known
        muted: col.muted
        ring: false
        focused: col.focused
        label: col.available ? col.label : col.label + ": " + col.note
        onMoved: (v) => col.moved(v)
    }

    Item {
        id: foot
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 6 * col.s
        height: 30 * col.s

        Column {
            x: Math.round((parent.width - width) / 2); y: Math.round((parent.height - height) / 2)
            spacing: 0
            Icon {
                anchors.horizontalCenter: parent.horizontalCenter
                name: col.glyph
                size: 14 * col.s
                color: col.error.length > 0 ? Theme.errorColor : footArea.containsMouse ? Theme.fg : Theme.fgVariant
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: !col.available ? "—" : !col.known ? "…" : Math.round(col.value * 100) + "%"
                color: col.error.length > 0 ? Theme.errorColor : Theme.fgVariant
                font.family: Typography.ui
                font.pixelSize: Typography.caption * col.s
                font.features: ({ "tnum": 1 })
            }
        }
        MouseArea {
            id: footArea
            anchors.fill: parent
            enabled: col.opens
            hoverEnabled: true
            cursorShape: col.opens ? Qt.PointingHandCursor : Qt.ArrowCursor
            Accessible.role: Accessible.Button
            Accessible.name: "Open " + col.label
            Accessible.onPressAction: col.opened()
            onClicked: col.opened()
        }
    }
}
