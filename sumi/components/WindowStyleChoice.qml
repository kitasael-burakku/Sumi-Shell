pragma ComponentBehavior: Bound

import QtQuick
import "../theme"

/**
 * Selector del estilo de las ventanas flotantes (2026-11-11): una tarjeta por estilo, con su miniatura animada, su
 * nombre y una línea. Los estilos, sus nombres y sus líneas salen de `Motion.windowStyles` (una sola fuente).
 * Teclado: lo lleva la fila de Settings (←/→ cambian, Enter alterna); el ratón elige con un clic.
 *
 * Las miniaturas sólo se mueven con la página a la vista (`active`): en Normal, la seleccionada o señalada; en Reduced, la que se señala
 * o la elegida con el foco de teclado; con Off, ninguna.
 *
 * Ocho estilos (2026-11-17, ADR-36): rejilla de 8, 4, 2 o 1 columnas, la mayor que quepa en `availableWidth`
 * (divisores de 8). Las columnas reparten el ancho de la fila y reservan sitio para notas de dos líneas.
 *
 * 2026-11-21 (ADR-40): también los estilos de forma. `kind` elige la familia: "window" (Window style, lo de siempre),
 * "bar" (Bar panels) o "island" (Island style); nombres y notas de `Motion.styleNames/styleParams`, y la miniatura de
 * la familia (WindowStylePreview o ShapeStylePreview).
 */
Item {
    id: root

    property real s: 1
    property string kind: "window"
    property string value: "minimalist"
    property bool focused: false
    property bool active: true
    property Flickable viewport: null
    // Offset en el contenido desplazable. Leer la jerarquía registra también los
    // cambios de altura de filas anteriores al cambiar escala o tipografía.
    readonly property real topInContent: {
        if (!root.viewport) return 0;
        let y = 0;
        for (let p = root; p && p !== root.viewport.contentItem; p = p.parent) y += p.y;
        return y;
    }
    property string hoveredStyle: ""
    // Una elección por teclado se reproduce aunque el puntero siga quieto sobre otra tarjeta.
    onValueChanged: {
        root.hoveredStyle = "";
        if (root.focused) Qt.callLater(root.revealSelection);
    }
    function revealSelection() {
        if (!root.active || !root.visible || !root.focused || !root.viewport) return;
        const card = styleCards.itemAt(Motion.styleNames(root.kind).indexOf(root.value));
        if (!card) return;
        const view = root.viewport;
        const y = card.mapToItem(view.contentItem, 0, 0).y;
        const pad = 6 * root.s;
        if (y - pad < view.contentY) view.contentY = Math.max(0, y - pad);
        else if (y + card.height + pad > view.contentY + view.height)
            view.contentY = Math.min(view.contentHeight - view.height, y + card.height + pad - view.height);
    }
    property string name: ""
    /** El ancho de la fila apilada (SettingRow.controlMaxWidth); sin él, una sola fila. */
    property real availableWidth: Infinity
    signal picked(string value)

    readonly property real gap: 8 * root.s
    readonly property var acc: Theme.fam(palette.accent)
    readonly property real minCardW: Math.round(152 * root.s * Typography.textScale)
    readonly property real cardW: isFinite(availableWidth) && availableWidth > 0
        ? Math.floor((availableWidth - (columns - 1) * gap) / columns) : minCardW
    FontMetrics { id: noteMetrics; font.family: Typography.ui; font.pixelSize: Typography.caption * root.s }
    readonly property int columns: {
        const n = Motion.styleNames(root.kind).length;
        for (const c of [n, 4, 2]) if (n % c === 0 && c * root.minCardW + (c - 1) * root.gap <= root.availableWidth) return c;
        return 1;
    }

    Accessible.role: Accessible.Grouping
    Accessible.name: root.name

    implicitWidth: grid.implicitWidth
    implicitHeight: grid.implicitHeight

    Grid {
        id: grid
        columns: root.columns
        spacing: root.gap

        Repeater {
            id: styleCards
            model: Motion.styleNames(root.kind)
            delegate: Rectangle {
                id: card
                required property string modelData
                readonly property var info: Motion.styleParams(root.kind, card.modelData)
                readonly property bool current: card.modelData === root.value

                // crece con Text size (2026-11-12): a 152·s fijo la nota se cortaba («opens in ab…»)
                width: root.cardW
                height: col.implicitHeight + 16 * root.s
                radius: Metrics.r(12) * root.s
                color: card.current ? root.acc.sel : (area.containsMouse ? Theme.hoverBg : "transparent")
                border.width: Math.max(1, root.s)
                border.color: card.current ? root.acc.selBorder : Theme.hair
                Behavior on color { ColorAnimation { duration: Motion.fast } }

                Accessible.role: Accessible.RadioButton
                Accessible.name: card.info.label
                Accessible.description: Motion.styleNote(card.info)
                Accessible.checkable: true
                Accessible.checked: card.current
                Accessible.onPressAction: root.picked(card.modelData)

                Column {
                    id: col
                    x: 8 * root.s
                    y: 8 * root.s
                    width: card.width - 16 * root.s
                    spacing: 6 * root.s

                    readonly property real previewTop: root.topInContent + grid.y + card.y + col.y + preview.y
                    readonly property bool inView: !root.viewport || (col.previewTop < root.viewport.contentY + root.viewport.height
                        && col.previewTop + preview.height > root.viewport.contentY)
                    onInViewChanged: if (!inView && root.hoveredStyle === card.modelData) root.hoveredStyle = ""
                    readonly property bool playing: root.active && root.visible && col.inView && !Motion.off
                        && (root.hoveredStyle ? root.hoveredStyle === card.modelData
                            : card.current && (!Motion.still || root.focused))
                    Loader {
                        id: preview
                        width: parent.width
                        sourceComponent: root.kind === "window" ? winPreview : shapePreview
                        Component {
                            id: winPreview
                            WindowStylePreview { s: root.s; style: card.modelData; playing: col.playing }
                        }
                        Component {
                            id: shapePreview
                            ShapeStylePreview { s: root.s; kind: root.kind; style: card.modelData; playing: col.playing }
                        }
                    }
                    Item {
                        width: parent.width
                        height: title.implicitHeight
                        Text {
                            id: title
                            anchors.left: parent.left
                            anchors.right: tick.left
                            anchors.rightMargin: card.current ? 4 * root.s : 0
                            text: card.info.label
                            elide: Text.ElideRight
                            color: card.current ? root.acc.text : Theme.fg
                            font.family: Typography.ui
                            font.pixelSize: Typography.body * root.s
                            font.weight: Typography.wStrong
                        }
                        Icon {
                            id: tick
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            visible: card.current
                            width: card.current ? 16 * root.s : 0
                            name: "check"
                            size: 13 * root.s
                            color: root.acc.text
                        }
                    }
                    Text {
                        width: parent.width
                        height: Math.max(implicitHeight, 2 * noteMetrics.lineSpacing)
                        text: Motion.styleNote(card.info)
                        wrapMode: Text.WordWrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
                        color: Theme.fgVariant
                        font.family: Typography.ui
                        font.pixelSize: Typography.caption * root.s
                    }
                }

                MouseArea {
                    id: area
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onPositionChanged: if (containsMouse) root.hoveredStyle = card.modelData
                    onContainsMouseChanged: {
                        if (containsMouse) root.hoveredStyle = card.modelData;
                        else if (root.hoveredStyle === card.modelData) root.hoveredStyle = "";
                    }
                    onClicked: root.picked(card.modelData)
                }
            }
        }
    }
}
