import QtQuick
import "../theme"

/**
 * One settings line: a name, an optional caption, and a control on the right.
 * The owning surface drives `focused` from its keyboard index and takes clicks
 * anywhere on the row as "activate this one".
 */
Item {
    id: root

    /** La familia de acento de la zona (Theme.fam; lib/accent-zones.js). */
    readonly property var acc: Theme.fam(palette.accent)
    property real s: 1
    property string name: ""
    property string caption: ""
    property bool focused: false
    property bool last: false
    /** Settings pages use grouped rows; compact consumers keep their existing layout. */
    property bool grouped: false
    property bool first: false
    property bool sectioned: false
    property bool vertical: false
    property bool captionEssential: false
    property bool helpExpanded: false
    readonly property bool hasHelp: root.sectioned && !root.captionEssential && root.caption.length > 0
    signal helpRequested()
    readonly property bool stacked: root.vertical || (root.grouped && slot.width > root.width * 0.46)
    /**
     * Lo más que puede medir el control (2026-11-12): el ancho de la fila apilada, de margen a margen.
     * No depende de `slot.width`, así que el control puede leerlo sin bucle (Choice parte en renglones).
     */
    readonly property real controlMaxWidth: Math.max(0, root.width - 22 * root.s)
    /**
     * Rediseño, fase 1 (DESIGN §5, «Disabled conserva una explicación»): una fila
     * que no se puede usar lo dice en su segundo renglón (`reason`) en vez de
     * enseñar un control apagado que parece sólo desactivado. No se activa.
     */
    property bool available: true
    property string reason: ""
    /**
     * Rediseño, fase 3: el valor no es el default. Se marca con un punto delante del
     * nombre y aparece un botón para volver al default (el teclado lo hace con Supr).
     */
    property bool custom: false
    signal resetRequested()
    default property alias control: slot.data

    signal activated()
    /** Window coordinates, so the owner can tell a real pointer move from a row sliding under it. */
    signal hoveredAt(real gx, real gy)

    Accessible.role: Accessible.ListItem
    Accessible.name: root.name
    Accessible.description: (!root.available && root.reason.length > 0 ? root.reason : root.caption)
        + (root.custom ? " (custom)" : "")
    Accessible.focusable: true
    Accessible.focused: root.focused
    Accessible.onPressAction: if (root.available) root.activated()

    width: parent ? parent.width : 0
    height: root.stacked ? text.implicitHeight + slot.height + 30 * s
        : Math.max(text.implicitHeight, slot.height) + (root.sectioned ? 28 : root.grouped ? 22 : 14) * s

    Rectangle {
        anchors.fill: parent
        visible: root.grouped
        // la tarjeta de la fila lleva el tinte de su zona (2026-11-21; antes un velo neutro de fg al 3,5 %)
        color: root.acc.card
        topLeftRadius: root.first || root.sectioned ? Metrics.r(12) * root.s : 0
        topRightRadius: topLeftRadius
        bottomLeftRadius: root.last || root.sectioned ? Metrics.r(12) * root.s : 0
        bottomRightRadius: bottomLeftRadius
    }

    Rectangle {
        anchors.fill: parent
        anchors.topMargin: 2 * root.s
        anchors.bottomMargin: 2 * root.s
        radius: Metrics.r(8) * root.s
        // Foco = contorno y fondo de celda; hover = fondo tenue (DESIGN §5): antes los
        // dos pintaban el mismo `tileBg` y no se sabía cuál de dos filas era la del teclado.
        color: root.focused ? Theme.tileBg : area.containsMouse ? Theme.hoverBg : "transparent"
        border.width: root.focused ? Metrics.focusWidth * root.s : 0
        border.color: root.acc.selBorder
        Behavior on color { ColorAnimation { duration: Motion.fast } }
    }

    // (2026-10-01) Aquí iba una barrita de acento a la izquierda de la fila enfocada: montada sobre
    // el contorno, era una tercera marca para lo mismo y se leía como otra caja. Contorno y fondo bastan.

    /**
     * The hover is reported in WINDOW coordinates, not as a bare "I am hovered".
     * A row that merely slides under a still cursor — which is what happens
     * while the island morphs open — fires `entered` and even `positionChanged`,
     * because the pointer moved relative to the item. Only the owner, comparing
     * against the last window position, can tell that apart from a real move,
     * and only a real move should take the keyboard row.
     */
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        onPositionChanged: (mouse) => {
            const p = area.mapToItem(null, mouse.x, mouse.y);
            root.hoveredAt(p.x, p.y);
        }
        onClicked: if (root.available) root.activated()
    }

    Column {
        id: text
        anchors.left: parent.left
        anchors.leftMargin: 12 * root.s
        anchors.right: resetBox.left
        anchors.rightMargin: 12 * root.s
        y: root.stacked ? 10 * root.s : (root.height - height) / 2
        height: implicitHeight
        spacing: 2 * root.s

        Text {
            id: nameText
            width: parent.width
            text: root.name
            elide: Text.ElideRight
            wrapMode: root.sectioned ? Text.WordWrap : Text.NoWrap
            color: root.available ? Theme.fg : Theme.disabledFg
            font.family: Typography.ui
            font.pixelSize: (Typography.body + (root.grouped ? Typography.textScale : 0)) * root.s
            font.weight: root.grouped ? Typography.wMedium : Typography.wNormal
        }
        Text {
            width: parent.width
            // Ojo: aquí `text` a secas sería la Column de arriba (`id: text`), no esta propiedad.
            readonly property string line: !root.available && root.reason.length > 0
                ? root.reason + (root.sectioned && root.helpExpanded && root.caption.length > 0 ? "\n" + root.caption : "") : root.caption
            visible: line.length > 0 && (!root.available || !root.sectioned || root.captionEssential || root.helpExpanded)
            text: line
            elide: Text.ElideRight
            wrapMode: root.grouped ? Text.WordWrap : Text.NoWrap
            // 2026-11-12: tres renglones; con «Larger» o una familia ancha, dos cortaban la explicación
            maximumLineCount: root.sectioned ? 1000 : root.grouped ? 3 : 1
            // el motivo de una fila no disponible es una explicación, no un aviso (2026-10-01): con `warn`
            // (el terciario de matugen) salía rosa en oscuro —«Already applied», «No input device»— y se
            // leía como un error. Va en cursiva y con el color de apoyo de siempre.
            color: Theme.fgVariant
            font.italic: !root.available && root.reason.length > 0
            font.family: Typography.ui
            font.pixelSize: (root.grouped ? Typography.label : Typography.caption) * root.s
        }
    }

    Rectangle {
        anchors.left: parent.left
        anchors.leftMargin: 5 * root.s
        // a la altura del NOMBRE, delante de él (2026-10-01: centrado en la fila caía entre las dos
        // líneas, pegado al contorno del foco)
        y: text.y + nameText.y + (nameText.height - height) / 2
        visible: root.custom
        width: 4 * root.s
        height: 4 * root.s
        radius: Metrics.pill(width)
        color: root.acc.accent
    }

    /** Volver al default: con el ratón aquí; con el teclado, Supr sobre la fila. */
    Item {
        id: resetBox
        anchors.right: root.hasHelp ? helpBox.left : root.stacked ? parent.right : slot.left
        anchors.rightMargin: 8 * root.s
        y: root.stacked ? 10 * root.s : (root.height - height) / 2
        width: root.custom && root.available ? 22 * root.s : 0
        height: 22 * root.s
        visible: width > 0

        Rectangle {
            anchors.fill: parent
            radius: Metrics.r(6) * root.s
            color: resetArea.containsMouse ? Theme.hoverBg : "transparent"
        }
        Icon {
            anchors.centerIn: parent
            name: "reload"
            size: 12 * root.s
            color: resetArea.containsMouse ? Theme.fg : Theme.outline
        }
        MouseArea {
            id: resetArea
            anchors.fill: parent
            anchors.margins: -5 * root.s
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.resetRequested()
        }
        Accessible.role: Accessible.Button
        Accessible.name: "Reset " + root.name
        Accessible.onPressAction: root.resetRequested()
    }

    Item {
        id: helpBox
        visible: root.hasHelp
        width: root.hasHelp ? 28 * root.s : 0
        height: 28 * root.s
        anchors.right: root.stacked ? parent.right : slot.left
        anchors.rightMargin: 8 * root.s
        y: root.stacked ? 4 * root.s : (root.height - height) / 2
        Rectangle { anchors.fill: parent; radius: Metrics.r(6) * root.s; color: root.helpExpanded ? root.acc.sel : helpArea.containsMouse ? Theme.hoverBg : "transparent" }
        Icon { anchors.centerIn: parent; name: "info"; size: 14 * root.s; color: root.helpExpanded ? root.acc.accent : Theme.fgVariant }
        Accessible.role: Accessible.Button
        Accessible.name: "Help for " + root.name
        Accessible.onPressAction: { root.helpRequested(); root.helpExpanded = !root.helpExpanded; }
        MouseArea {
            id: helpArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { root.helpRequested(); root.helpExpanded = !root.helpExpanded; }
        }
    }

    Item {
        id: slot
        anchors.right: parent.right
        anchors.rightMargin: 10 * root.s
        y: root.stacked ? root.height - height - 10 * root.s : (root.height - height) / 2
        width: childrenRect.width
        height: childrenRect.height
        enabled: root.available
        opacity: root.available ? 1 : Theme.disabledOpacity
    }

    Rectangle {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 12 * root.s
        anchors.rightMargin: 10 * root.s
        height: 1
        color: Theme.hair
        opacity: 0.5
        visible: !root.last && !root.sectioned
    }
}
