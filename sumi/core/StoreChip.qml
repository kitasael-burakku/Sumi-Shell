import QtQuick
import "../theme"
import "../components"

/**
 * Un chip de la tienda de Wallhaven (W2). Pensado para el RATÓN: más alto que el `FilterChip` de
 * Wallpaper List (26 px contra 20) y sin estado de foco de teclado. Encendido (`on`), apagado con su
 * motivo (`why`, que la tienda enseña en el pie al pasar por encima: `hint`), muestra de color,
 * glifo detrás (el ▾ de un menú) y un contador (`badge`, los filtros avanzados activos).
 */
Rectangle {
    id: chip

    property real s: 1
    /** Optional cap for long tags in a narrow detail; other chips retain their intrinsic width. */
    property real maximumWidth: 1e9
    property string label: ""
    property bool on: false
    property bool disabled: false
    property string why: ""
    property string swatch: ""
    /** Un glifo de `components/Icon` detrás de la etiqueta (el chevron de un menú). */
    property string trailing: ""
    /** Un glifo delante de la etiqueta (‹ de Previous). */
    property string leading: ""
    /** Gira el glifo de detrás media vuelta (el ▾ de un menú abierto). */
    property bool flipped: false
    /** La acción principal (Search): relleno de acento y texto sobre él. */
    property bool strong: false
    property int badge: 0
    /** Lo que el pie debería decir mientras el puntero está encima ("" = nada). */
    readonly property string hint: area.containsMouse && chip.disabled ? chip.why : ""
    signal activated()

    readonly property real pad: 11 * chip.s
    implicitWidth: (chip.label.length > 0 ? text.implicitWidth + 2 * chip.pad : 20 * chip.s)
        + (chip.swatch.length > 0 && chip.label.length > 0 ? 14 * chip.s : 0)
        + (chip.trailing.length > 0 ? trail.width + 4 * chip.s : 0)
        + (chip.leading.length > 0 ? lead.width + 4 * chip.s : 0)
        + (chip.badge > 0 ? badgeBox.width + 5 * chip.s : 0)
    implicitHeight: 26 * chip.s
    width: Math.min(implicitWidth, chip.maximumWidth)
    height: implicitHeight
    radius: Metrics.pill(height)
    color: chip.strong ? (chip.disabled ? Qt.alpha(Theme.primary, 0.35) : area.containsMouse ? Qt.alpha(Theme.primary, 0.86) : Theme.primary)
        : chip.on ? Theme.selBg : (area.containsMouse && !chip.disabled ? Theme.hoverBg : "transparent")
    border.width: 1
    border.color: chip.strong ? "transparent" : chip.on ? Qt.alpha(Theme.primary, 0.35)
        : area.containsMouse && !chip.disabled ? Qt.alpha(Theme.primary, 0.30) : Theme.hair
    opacity: chip.disabled ? Theme.disabledOpacity : 1
    // al pulsar se hunde un poco (2026-10-01: la tienda no daba respuesta al clic hasta que llegaba la página)
    scale: area.pressed && !chip.disabled && !Motion.off ? 0.95 : 1
    Behavior on color { ColorAnimation { duration: Motion.fast } }
    Behavior on border.color { ColorAnimation { duration: Motion.fast } }
    Behavior on opacity { NumberAnimation { duration: Motion.fast } }
    Behavior on scale { NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic } }

    Accessible.role: chip.strong ? Accessible.Button : Accessible.CheckBox
    Accessible.name: chip.label.length > 0 ? chip.label : "Colour " + chip.swatch
    Accessible.checked: chip.on
    Accessible.description: chip.disabled ? chip.why : ""
    Accessible.onPressAction: if (!chip.disabled) chip.activated()

    Row {
        anchors.centerIn: parent
        spacing: 4 * chip.s

        Icon {
            id: lead
            anchors.verticalCenter: parent.verticalCenter
            visible: chip.leading.length > 0
            width: 11 * chip.s
            name: chip.leading
            size: 11 * chip.s
            color: chip.strong ? Theme.fgOnPrimary : chip.on ? Theme.primary : Theme.fgVariant
        }

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            visible: chip.swatch.length > 0
            width: (chip.label.length > 0 ? 10 : 14) * chip.s
            height: width
            radius: Metrics.pill(width)
            color: chip.swatch.length > 0 ? chip.swatch : "transparent"
            border.width: 1
            border.color: Qt.alpha(Theme.outline, 0.5)
        }
        Text {
            id: text
            anchors.verticalCenter: parent.verticalCenter
            visible: chip.label.length > 0
            text: chip.label
            width: Math.max(0, Math.min(implicitWidth, chip.width - (chip.implicitWidth - implicitWidth)))
            elide: Text.ElideRight
            color: chip.strong ? Theme.fgOnPrimary : chip.on ? Theme.primary : Theme.fgVariant
            Behavior on color { ColorAnimation { duration: Motion.fast } }
            font.family: Typography.ui
            font.pixelSize: Typography.caption * chip.s
            font.weight: Font.DemiBold
        }
        Icon {
            id: trail
            anchors.verticalCenter: parent.verticalCenter
            visible: chip.trailing.length > 0
            width: 11 * chip.s
            name: chip.trailing
            size: 11 * chip.s
            color: chip.strong ? Theme.fgOnPrimary : Theme.outline
            rotation: chip.flipped ? 180 : 0
            Behavior on rotation { NumberAnimation { duration: Motion.standard; easing.type: Easing.OutCubic } }
        }
        Rectangle {
            id: badgeBox
            anchors.verticalCenter: parent.verticalCenter
            visible: chip.badge > 0
            width: Math.max(height, badgeText.implicitWidth + 8 * chip.s)
            height: 15 * chip.s
            radius: Metrics.pill(height)
            color: Theme.primary
            // el número cambia: un pulso corto, se nota que el filtro contó
            property int seen: chip.badge
            onVisibleChanged: badgeBox.seen = chip.badge
            Connections {
                target: chip
                function onBadgeChanged() {
                    if (chip.badge > badgeBox.seen && !Motion.still) badgePop.restart();
                    badgeBox.seen = chip.badge;
                }
            }
            SequentialAnimation {
                id: badgePop
                NumberAnimation { target: badgeBox; property: "scale"; to: 1.3; duration: Motion.fast; easing.type: Easing.OutCubic }
                NumberAnimation { target: badgeBox; property: "scale"; to: 1; duration: Motion.standard; easing.type: Easing.OutBack }
            }
            Text {
                id: badgeText
                anchors.centerIn: parent
                text: chip.badge
                color: Theme.fgOnPrimary
                font.family: Typography.mono
                font.pixelSize: Typography.micro * chip.s
                font.weight: Font.DemiBold
            }
        }
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: chip.disabled ? Qt.ArrowCursor : Qt.PointingHandCursor
        onClicked: if (!chip.disabled) chip.activated()
    }
}
