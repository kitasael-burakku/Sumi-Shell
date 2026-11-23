import QtQuick
import "../theme"

/**
 * La cabecera de una sección plegable (rediseño, 9C-1; DESIGN §6 «DisclosureSection»):
 * Advanced y Experimental de Settings, y en la 9E el Equalizer y Applications del Mixer.
 *
 * Sólo la cabecera: quien la usa decide qué enseña debajo con `expanded`. Se abre con un
 * clic o con el teclado del dueño (Enter / Espacio alternan, → abre, ← pliega); nunca por
 * hover. `summary` va a la derecha (p. ej. «3 settings · 1 custom»). El estado se anuncia
 * (`Accessible.expanded`), no sólo el chevron.
 */
Item {
    id: root

    /** La familia de acento de la zona (Theme.fam; lib/accent-zones.js). */
    readonly property var acc: Theme.fam(palette.accent)
    property real s: 1
    property string label: ""
    property string summary: ""
    property bool expanded: false
    property bool focused: false
    signal toggled()
    /** Coordenadas de ventana, como `SettingRow`: el dueño distingue un movimiento real. */
    signal hoveredAt(real gx, real gy)

    width: parent ? parent.width : 0
    height: 34 * s

    Accessible.role: Accessible.Button
    Accessible.name: root.label
    Accessible.description: root.summary
    Accessible.checkable: true
    Accessible.checked: root.expanded
    Accessible.focusable: true
    Accessible.focused: root.focused
    Accessible.onPressAction: root.toggled()

    Rectangle {
        anchors.fill: parent
        anchors.topMargin: 2 * root.s
        anchors.bottomMargin: 2 * root.s
        radius: Metrics.r(8) * root.s
        color: root.focused ? Theme.tileBg : area.containsMouse ? Theme.hoverBg : "transparent"
        border.width: root.focused ? Metrics.focusWidth * root.s : 0
        border.color: root.acc.selBorder
        Behavior on color { ColorAnimation { duration: Motion.fast } }
    }

    Icon {
        id: chevron
        anchors.left: parent.left
        anchors.leftMargin: 10 * root.s
        anchors.verticalCenter: parent.verticalCenter
        name: "chevron-right"
        size: 12 * root.s
        color: Theme.fgVariant
        visible: !Style.terminal
        rotation: root.expanded ? 90 : 0
        Behavior on rotation { NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic } }
    }
    // terminal (ADR-34): `[+]` plegado, `[-]` abierto
    Text {
        id: tuiMark
        objectName: "styleMarks"
        visible: Style.terminal
        anchors.left: parent.left
        anchors.leftMargin: 8 * root.s
        anchors.verticalCenter: parent.verticalCenter
        text: root.expanded ? "[-]" : "[+]"
        color: Theme.fgVariant
        font.family: Typography.mono
        font.pixelSize: Typography.label * root.s
    }
    Text {
        anchors.left: Style.terminal ? tuiMark.right : chevron.right
        anchors.leftMargin: 8 * root.s
        anchors.verticalCenter: parent.verticalCenter
        text: root.label
        color: Theme.fg
        font.family: Typography.ui
        font.pixelSize: Typography.body * root.s
        font.weight: Typography.wMedium
    }
    Text {
        anchors.right: parent.right
        anchors.rightMargin: 12 * root.s
        anchors.verticalCenter: parent.verticalCenter
        text: root.summary
        color: Theme.outlineText
        font.family: Typography.ui
        font.pixelSize: Typography.caption * root.s
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onPositionChanged: (mouse) => {
            const p = area.mapToItem(null, mouse.x, mouse.y);
            root.hoveredAt(p.x, p.y);
        }
        onClicked: root.toggled()
    }
}
