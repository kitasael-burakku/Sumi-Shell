import QtQuick
import "../theme"

/**
 * Un boton de accion. Dos formas:
 *
 *  - **fila** (por defecto): mide lo que mide su texto.
 *  - **`stacked`**: glifo grande arriba y etiqueta debajo, para las rejillas
 *    horizontales donde el icono es lo que se reconoce de un vistazo.
 *
 * Los `Behavior on color` se quedan: los mueve un estado discreto (foco,
 * confirmacion), no la geometria del contenedor. Es el criterio de ADR-25.
 */
Item {
    id: root

    /** La familia de acento de la zona (Theme.fam; lib/accent-zones.js). */
    readonly property var acc: Theme.fam(palette.accent)
    property real s: 1
    property string label: ""
    /** Nombre en `components/Icon`. Vacio = sin glifo. */
    property string glyph: ""
    /** Tinte opcional para distinguir una acción por su icono. */
    property color glyphTint: "transparent"
    /** Glifo arriba, etiqueta debajo. */
    property bool stacked: false
    property bool focused: false
    /**
     * La fila que lo contiene ya dibuja el foco (2026-10-01): enfocado sigue realzando el texto,
     * pero sin contorno propio — era una caja dentro de la caja de la fila.
     */
    property bool ringless: false
    property bool danger: false
    /**
     * `primary` da fondo **permanente**; `accent` solo pinta el texto. Se
     * separaron porque en una pregunta de si/no el fondo permanente compite con
     * el realce del foco: el usuario ve dos botones "encendidos" y no sabe cual
     * responde al Enter. Con `accent`, **el color del texto dice que hace el
     * boton y el fondo dice cual esta enfocado**.
     */
    property bool accent: false
    property bool primary: false
    property bool enabled: true
    /**
     * Contenido pegado a la izquierda en vez de centrado.
     *
     * Un botón que ocupa todo el ancho con el texto en el medio se lee como un
     * enlace suelto flotando, no como una fila de una lista: en el Dashboard,
     * cinco acciones así quedaban centradas una debajo de otra, con sus iconos
     * en cinco posiciones distintas y nada que guiara el ojo hacia abajo.
     * Alineados, los glifos forman columna y la lista se escanea de un vistazo.
     *
     * Lo pone `ActionGroup` cuando el botón se estira; un botón que mide lo que
     * mide su texto se queda centrado.
     */
    property bool leading: false

    signal triggered()
    signal hovered()

    implicitWidth: root.stacked
        ? Math.ceil(Math.max(64 * root.s, stackLabel.implicitWidth + 16 * root.s))
        : Math.ceil(rowText.implicitWidth + 24 * root.s
            + (root.glyph.length > 0 ? btnGlyph1.implicitWidth + Metrics.sp2 * root.s : 0))
    implicitHeight: root.stacked ? 66 * root.s
        : Math.max((root.primary ? 28 : 24) * root.s, rowText.implicitHeight + 8 * root.s)

    /**
     * El tinte explícito afecta sólo al glifo. Los demás botones toman el color
     * de `components/Icon.tint` o el de su estado.
     */
    readonly property bool plainGlyph: root.enabled && !root.danger
        && !root.primary && !root.accent

    function glyphColor(fallback: color): color {
        if (root.glyphTint.a > 0)
            return root.enabled ? root.glyphTint : Qt.alpha(root.glyphTint, Theme.disabledFg.a);
        return root.plainGlyph ? fallback : root.tone;
    }

    readonly property color tone: !root.enabled ? Theme.disabledFg
        : root.danger ? Theme.dangerText
        : (root.primary || root.accent) ? root.acc.text
        : (root.focused ? Theme.fg : Theme.fgVariant)

    /** El color con el que se realza cuando tiene el foco. */
    readonly property color mark: root.danger ? Theme.dangerText : root.acc.ring

    readonly property bool pointed: area.containsMouse && root.enabled

    Accessible.role: Accessible.Button
    Accessible.name: root.label
    Accessible.focusable: root.enabled
    Accessible.focused: root.focused
    Accessible.onPressAction: if (root.enabled) root.triggered()

    /**
     * Rediseño, fase 1 (DESIGN §5): **el foco es un contorno; el hover, un fondo
     * tenue**. Antes el foco pintaba el fondo con el color de la acción, y el
     * hover no pintaba nada: el puntero encima de un botón que no era el del
     * teclado no se veía, y un botón `primary` enfocado y otro sin enfocar sólo
     * se distinguían por la intensidad del mismo fondo. El contorno va DENTRO del
     * botón para que no lo recorte una lista con `clip`.
     */
    Rectangle {
        anchors.fill: parent
        radius: Metrics.r(10) * root.s
        color: !root.enabled ? "transparent"
             : Theme.controlBg("transparent", root.pointed, area.pressed && root.pointed, root.primary, root.acc)
        border.width: !root.enabled ? 0
                    : root.focused && !root.ringless ? Metrics.focusWidth * root.s
                    : root.primary ? 1 : 0
        // deshabilitado, sin contorno aunque tenga el foco o sea primario (2026-10-01: Connect sin cable
        // era una caja vacía a todo el ancho y se leía como un campo de texto); lo dice su color
        border.color: root.focused ? root.mark : Qt.alpha(root.mark, 0.34)
        Behavior on color { ColorAnimation { duration: Motion.fast } }
        Behavior on border.color { ColorAnimation { duration: Motion.fast } }
    }

    /**
     * Terminal (ADR-34): `[ label ]`. Los corchetes caben en el relleno lateral que el botón ya tiene (12·s por lado):
     * no cambian su ancho ni empujan a los vecinos. Ni en la forma apilada ni en las filas de lista (`leading`), que
     * se leen como menú. En soft el Loader no tiene objeto.
     */
    Loader {
        objectName: "styleMarks"
        anchors.fill: parent
        active: Style.terminal && !root.stacked && !root.leading
        sourceComponent: Item {
            readonly property color ink: root.focused ? root.mark : Qt.alpha(root.tone, 0.75)
            readonly property real px: (root.primary ? Typography.body : Typography.label) * root.s
            Text {
                anchors.left: parent.left
                anchors.leftMargin: 3 * root.s
                anchors.verticalCenter: parent.verticalCenter
                text: "["
                color: parent.ink
                font.family: Typography.mono
                font.pixelSize: parent.px
            }
            Text {
                anchors.right: parent.right
                anchors.rightMargin: 3 * root.s
                anchors.verticalCenter: parent.verticalCenter
                text: "]"
                color: parent.ink
                font.family: Typography.mono
                font.pixelSize: parent.px
            }
        }
    }

    // ---- forma apilada -------------------------------------------------------

    Column {
        anchors.centerIn: parent
        width: Math.max(0, root.width - 16 * root.s)
        visible: root.stacked
        spacing: 7 * root.s

        Icon {
            id: btnGlyph0
            anchors.horizontalCenter: parent.horizontalCenter
            name: root.glyph
            size: 26 * root.s
            color: root.glyphColor(btnGlyph0.tint)
            Behavior on color { ColorAnimation { duration: Motion.fast } }
        }

        Text {
            id: stackLabel
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: root.label
            color: root.tone
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
            font.weight: root.focused ? Font.DemiBold : Font.Normal
            Behavior on color { ColorAnimation { duration: Motion.fast } }
        }
    }

    // ---- forma en fila -------------------------------------------------------

    Row {
        id: buttonRow
        width: Math.max(0, Math.min(root.width - 24 * root.s,
            Math.ceil(rowText.implicitWidth + (root.glyph.length > 0 ? btnGlyph1.implicitWidth + buttonRow.spacing : 0))))
        anchors.verticalCenter: parent.verticalCenter
        anchors.horizontalCenter: root.leading ? undefined : parent.horizontalCenter
        anchors.left: root.leading ? parent.left : undefined
        anchors.leftMargin: root.leading ? Metrics.sp3 * root.s : 0
        visible: !root.stacked
        spacing: Metrics.sp2 * root.s

        Icon {
            id: btnGlyph1
            anchors.verticalCenter: parent.verticalCenter
            visible: root.glyph.length > 0
            name: root.glyph
            size: 14 * root.s
            color: root.glyphColor(btnGlyph1.tint)
        }

        Text {
            id: rowText
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, buttonRow.width - (btnGlyph1.visible ? btnGlyph1.width + buttonRow.spacing : 0))
            elide: Text.ElideRight
            text: root.label
            color: root.tone
            font.family: Typography.ui
            font.pixelSize: (root.primary ? Typography.body : Typography.label) * root.s
            font.weight: root.primary ? Font.DemiBold : Font.Normal
            Behavior on color { ColorAnimation { duration: Motion.fast } }
        }
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        enabled: root.enabled
        cursorShape: Qt.PointingHandCursor
        onEntered: root.hovered()
        onClicked: root.triggered()
    }
}
