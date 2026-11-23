pragma ComponentBehavior: Bound

import QtQuick
import "../theme"

/**
 * One value out of several. Up to four options show as pills, because seeing
 * them all is worth the width; more than that collapses to the current value
 * between chevrons, since nine scheme names in a row would be unreadable.
 */
Item {
    id: root

    /** La familia de acento de la zona (Theme.fam; lib/accent-zones.js). */
    readonly property var acc: Theme.fam(palette.accent)
    property real s: 1
    property bool spacious: false
    /** Optional cap for long device labels; zero preserves natural pill width. */
    property real optionMaxWidth: 0
    /**
     * El sitio que le deja quien lo contiene (2026-11-12, «Text size»). Cero = como antes: pastillas
     * a su ancho natural. Con sitio, las pastillas que no caben **parten en renglones** (cada una con
     * tope y elisión) y la etiqueta compacta mide la más larga de las opciones, hasta ese tope.
     * No depende del ancho del propio control: sin bucle de enlaces.
     */
    property real availableWidth: 0
    /** [{ label, value }] */
    property var options: []
    property var value
    /** Lo pinta; el foco de teclado lo lleva la fila que contiene el Choice. */
    property bool focused: false
    /** Nombre accesible: el de la fila. */
    property string name: ""
    signal picked(var value)

    Accessible.role: Accessible.ComboBox
    Accessible.name: root.name
    Accessible.description: root.label
    Accessible.focusable: true
    Accessible.focused: root.focused

    /**
     * Pastillas aunque haya más de 4 opciones (2026-11-16: Interface scale, ocho escalas que el autor quiso a la vista,
     * no «< valor >»). Si no caben, parten en renglones como cualquier otra.
     */
    property bool forcePills: false
    readonly property bool compact: !root.forcePills && root.options.length > 4
    /** Las pastillas en una fila, a su ancho natural (lo mide `measure`, que no se pinta). */
    readonly property real naturalWidth: measure.implicitWidth
    readonly property bool wraps: !root.compact && root.availableWidth > 0 && root.naturalWidth > root.availableWidth + 0.5
    readonly property real pillCap: Math.min(root.optionMaxWidth > 0 ? Math.floor(root.optionMaxWidth) : Infinity,
                                             root.availableWidth > 0 ? Math.floor(root.availableWidth) : Infinity)
    /**
     * La etiqueta entre chevrones. Antes 84·s fijo: no crecía con Text size ni con otra familia y
     * elidía «Auto (hyprpaper)». Ahora: lo que pida la opción más larga, nunca menos de aquellos
     * 84·s (no baila al pasar de una a otra) y, con sitio conocido, nunca más del que hay. Sin sitio
     * conocido sólo crece con Text size.
     */
    readonly property real compactLabelWidth: {
        const floor = 84 * root.s;
        const want = Math.max(floor, Math.ceil(labelMeasure.implicitWidth));
        if (root.availableWidth <= 0) return Math.min(want, Math.ceil(floor * Typography.textScale));
        const room = root.availableWidth - prevChevron.implicitWidth - nextChevron.implicitWidth - 2 * compactRow.spacing;
        return Math.max(Math.min(floor, room), Math.min(want, room));
    }

    readonly property int index: {
        for (let i = 0; i < root.options.length; i++)
            if (String(root.options[i].value) === String(root.value))
                return i;
        return -1;
    }
    readonly property string label: root.index >= 0 ? root.options[root.index].label : "—"

    function cycle(dir) {
        const n = root.options.length;
        if (n === 0)
            return;
        const i = ((root.index < 0 ? 0 : root.index) + dir % n + n) % n;
        root.picked(root.options[i].value);
    }

    implicitWidth: root.compact ? compactRow.implicitWidth : pills.width
    implicitHeight: root.compact ? (root.spacious ? 34 : 20) * s : Math.max((root.spacious ? 34 : 20) * s, pills.implicitHeight)

    /** Medidas sin pintar: el ancho natural de las pastillas y el de la etiqueta compacta más larga. */
    Row {
        id: measure
        visible: false
        spacing: 3 * root.s
        Repeater {
            model: root.compact ? [] : root.options
            delegate: Item {
                id: m
                required property var modelData
                width: Math.min(Math.ceil(mText.implicitWidth) + Math.ceil((root.spacious ? 22 : 13) * root.s), root.pillCap)
                height: 1
                Text {
                    id: mText
                    text: m.modelData.label
                    font.family: Typography.ui
                    font.pixelSize: (root.spacious ? Typography.body : Typography.caption) * root.s
                    font.weight: Font.DemiBold
                }
            }
        }
    }
    Column {
        id: labelMeasure
        visible: false
        Repeater {
            model: root.compact ? root.options : []
            delegate: Text {
                required property var modelData
                text: modelData.label
                font.family: Typography.ui
                font.pixelSize: (root.spacious ? Typography.body : Typography.caption) * root.s
                font.weight: Font.DemiBold
            }
        }
    }

    Flow {
        id: pills
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.compact
        spacing: 3 * root.s
        // medio píxel de holgura: `measure` y Flow suman lo mismo, pero en coma flotante
        width: root.wraps ? Math.floor(root.availableWidth) : Math.ceil(root.naturalWidth + 0.5)

        Repeater {
            model: root.compact ? [] : root.options
            delegate: Rectangle {
                id: pill
                required property var modelData
                readonly property bool current: String(pill.modelData.value) === String(root.value)
                // Round the text and padding separately: at scale 1.1, subtracting fractional
                // padding produced 19.499999 instead of 19.5 and elided short labels.
                readonly property real labelPadding: Math.ceil((root.spacious ? 22 : 13) * root.s)
                readonly property real naturalWidth: Math.ceil(pillLabel.implicitWidth) + labelPadding
                width: Math.min(naturalWidth, root.pillCap)
                height: root.spacious ? Typography.box(34, Typography.body, root.s) : Typography.box(18, Typography.caption, root.s)
                radius: Metrics.r(7) * root.s
                // terminal (ADR-34): la opción elegida va invertida, como una selección de TUI
                readonly property color fill: pill.current && Style.terminal ? Theme.activeBg(pillArea.containsMouse, pillArea.pressed && pillArea.containsMouse, root.acc)
                    : Theme.controlBg(root.spacious ? Theme.tileBg : "transparent", pillArea.containsMouse, pillArea.pressed && pillArea.containsMouse, pill.current, root.acc)
                color: fill
                Behavior on color { ColorAnimation { duration: Motion.fast } }

                Text {
                    id: pillLabel
                    width: Math.max(0, parent.width - pill.labelPadding); elide: Text.ElideRight
                    anchors.centerIn: parent
                    text: pill.modelData.label
                    color: pill.current ? (Style.terminal ? Theme.activeText(pill.fill, root.acc) : root.acc.text) : Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: (root.spacious ? Typography.body : Typography.caption) * root.s
                    font.weight: Font.DemiBold
                }

                MouseArea {
                    id: pillArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.picked(pill.modelData.value)
                }
            }
        }
    }

    Row {
        id: compactRow
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: root.compact
        spacing: 6 * root.s

        Text {
            id: prevChevron
            anchors.verticalCenter: parent.verticalCenter
            text: Style.terminal ? "<" : "‹"
            color: prevArea.containsMouse ? Theme.fg : Theme.outlineText
            font.family: Typography.ui
            font.pixelSize: Typography.title * root.s
            MouseArea {
                id: prevArea
                anchors.fill: parent
                anchors.margins: -5 * root.s
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.cycle(-1)
            }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: root.compactLabelWidth
            horizontalAlignment: Text.AlignHCenter
            text: root.label
            elide: Text.ElideRight
            color: root.acc.text
            font.family: Typography.ui
            font.pixelSize: (root.spacious ? Typography.body : Typography.caption) * root.s
            font.weight: Font.DemiBold
        }
        Text {
            id: nextChevron
            anchors.verticalCenter: parent.verticalCenter
            text: Style.terminal ? ">" : "›"
            color: nextArea.containsMouse ? Theme.fg : Theme.outlineText
            font.family: Typography.ui
            font.pixelSize: Typography.title * root.s
            MouseArea {
                id: nextArea
                anchors.fill: parent
                anchors.margins: -5 * root.s
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.cycle(1)
            }
        }
    }

    /** Anillo de foco alrededor de todo el control (DESIGN §5: foco = contorno). */
    Rectangle {
        x: (root.compact ? compactRow.x : pills.x) - (Metrics.focusGap + Metrics.focusWidth) * root.s
        width: (root.compact ? compactRow.width : pills.width) + 2 * (Metrics.focusGap + Metrics.focusWidth) * root.s
        anchors.verticalCenter: parent.verticalCenter
        height: (root.compact ? root.height : pills.height) + 2 * (Metrics.focusGap + Metrics.focusWidth) * root.s
        radius: Metrics.r(9) * root.s
        color: "transparent"
        visible: root.focused
        border.width: Metrics.focusWidth * root.s
        border.color: root.acc.ring
    }
}
