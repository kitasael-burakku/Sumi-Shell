import QtQuick
import "../theme"

/**
 * La cabecera de una superficie. **Una sola**.
 *
 * Contado el 2026-09-15: once superficies tenían título y doce no tenían
 * ninguno, y las once lo escribían a mano con cuatro variantes distintas —con
 * punto de acento y sin él, `letterSpacing` 1,4 y 1,6, dentro de un `Column` o
 * dentro de un `Item` de 18 px. Ninguna sabía de las otras.
 *
 *   SurfaceHeader { s: root.s; title: "MIXER"; aside: Audio.sinkName }
 *
 * `aside` es el renglón de la derecha: el contador, el estado, la ruta — lo que
 * cada superficie ya ponía ahí. `dot` enciende el punto de acento, que es lo que
 * ata la cabecera al resto del shell: el mismo acento que el filo de luz del
 * vidrio.
 */
Item {
    id: header

    /** La familia de acento de la zona (Theme.fam; lib/accent-zones.js). */
    readonly property var acc: Theme.fam(palette.accent)
    property real s: 1
    property string title: ""
    property string aside: ""
    property color asideColor: Theme.outline
    property bool dot: true
    /** La regla bajo la cabecera. La ponen las superficies con lista. */
    property bool rule: false

    implicitHeight: (header.rule ? 20 : 16) * header.s
    height: implicitHeight

    Row {
        id: left
        anchors.left: parent.left
        anchors.top: parent.top
        spacing: Metrics.sp2 * header.s

        Rectangle {
            anchors.verticalCenter: label.verticalCenter
            visible: header.dot
            width: 5 * header.s
            height: 5 * header.s
            radius: Metrics.pill(width)
            color: header.acc.accent
        }

        Text {
            id: label
            text: header.title
            color: Theme.fgVariant
            font.family: Typography.ui
            font.pixelSize: Typography.label * header.s
            font.weight: Typography.wStrong
            font.capitalization: Font.AllUppercase
            font.letterSpacing: Typography.tracking * header.s
        }
    }

    /**
     * El lado derecho: el contador o el estado (`aside`), y detrás lo que la
     * superficie quiera poner ahí —un spinner, los botones de «no molestar» y
     * «limpiar»—. Ese hueco existe porque si no, cada superficie se inventa su
     * propia fila a la derecha, que es de donde salían las seis variantes.
     */
    default property alias extra: extras.data

    Row {
        id: extras
        anchors.right: parent.right
        anchors.verticalCenter: left.verticalCenter
        spacing: Metrics.sp2 * header.s

        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: header.aside.length > 0
            text: header.aside
            color: header.asideColor
            font.family: Typography.ui
            font.pixelSize: Typography.micro * header.s
            font.features: ({ "tnum": 1 })
        }
    }

    Rectangle {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        visible: header.rule
        height: Metrics.hair
        color: Theme.hair
    }
}
