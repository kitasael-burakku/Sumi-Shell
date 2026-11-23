import QtQuick
import "../theme"

/**
 * Un aviso del island: glifo, contador opcional y nada mas.
 *
 * La regla de ADR-16, que sale de los comentarios del propio `waybar/config.jsonc`
 * ("en reposo ocupan cero o casi"), aqui es literal: **cuando `active` es false
 * el item mide 0 px de ancho y no aparece en el Row**. Por eso el island en
 * reposo tranquilo sigue midiendo lo que media (143 px, capturado en 9.a).
 *
 * **Indicador puro, sin raton.** Un MouseArea aqui seria inalcanzable: acercar
 * el puntero al island lo pasa a modo hover y la cara rest se desvanece antes
 * de que el clic llegue. Lo accionable vive en la cara hover (core/Island.qml).
 *
 * No sabe de donde sale el dato: se lo dan hecho.
 */
Item {
    id: root

    property bool active: false
    property string icon: ""
    /** Texto a la derecha del glifo. Vacio = solo glifo. */
    property string label: ""
    property color tint: Theme.fgVariant
    property real s: 1

    // 16A-2: el aviso de privacidad también en texto, no sólo el punto de color
    Accessible.role: Accessible.StaticText
    Accessible.name: root.label
    Accessible.ignored: !root.active
    visible: root.active
    implicitWidth: widthSpring.value
    SpringValue { id: widthSpring; target: root.active ? row.implicitWidth : 0 }
    implicitHeight: row.implicitHeight

    // Empuja el ancho del island, y de ese ancho depende su máscara: firme.

    Row {
        id: row
        anchors.verticalCenter: parent.verticalCenter
        spacing: 4 * root.s

        Icon {
            anchors.verticalCenter: parent.verticalCenter
            name: root.icon
            size: 13 * root.s
            color: root.tint
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.label.length > 0
            text: root.label
            color: root.tint
            font.family: Typography.ui
            font.pixelSize: Typography.label * root.s
            font.weight: Font.DemiBold
            font.features: ({ "tnum": 1 })
        }
    }

}
