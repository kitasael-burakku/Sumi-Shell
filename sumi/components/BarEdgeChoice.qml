pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../lib/bar-edge.js" as BarEdge

/**
 * Dónde va la barra permanente (2026-11-19, docs/SUMI-BARRA-BORDES-2026-11-19.md): un monitor en miniatura con una
 * barra posible en cada borde. La elegida va rellena del acento, centrada y con su longitud de verdad, y un panel
 * que cuelga de ella hacia dentro: la vista previa de hacia dónde se abren las cosas. Las otras tres, sólo su contorno
 * (el ratón elige con un clic). Teclado: lo lleva la fila de Settings (←/→ recorren top, bottom, left, right).
 *
 * Sólo dibujo con tokens (Theme, Metrics), como NotifPositionChoice: radios rectos en Terminal y sin textos que crezcan
 * con Text size; el nombre del borde va en el pie de la fila.
 */
Item {
    id: root

    property real s: 1
    property string value: "top"
    property int length: 100
    property bool focused: false
    property string name: ""
    signal picked(string value)
    /** El borde bajo el ratón (su franja de clic). */
    property string hoverEdge: ""

    readonly property real screenW: Math.round(184 * root.s)
    readonly property real screenH: Math.round(112 * root.s)
    /** Grosor de la barra y margen con el borde, en la miniatura. */
    readonly property real thick: Math.round(8 * root.s)
    readonly property real inset: Math.round(5 * root.s)

    Accessible.role: Accessible.Grouping
    Accessible.name: root.name

    implicitWidth: root.screenW
    implicitHeight: root.screenH

    /** El rectángulo de la barra en `e`, en px de la miniatura (la elegida con su longitud; las otras, enteras). */
    function barBox(e, chosen) {
        const along = BarEdge.vertical(e) ? root.screenH : root.screenW;
        const sp = chosen ? BarEdge.span(along, root.inset, root.length, 0)
                          : BarEdge.span(along, root.inset + root.thick + Math.round(3 * root.s), 100, 0);
        return BarEdge.rect(e, root.screenW, root.screenH, root.thick, root.inset, sp);
    }

    // el monitor
    Rectangle {
        id: frame
        anchors.fill: parent
        radius: Metrics.r(10) * root.s
        color: Theme.tileBg
        border.width: Math.max(1, root.s)
        border.color: root.focused ? Theme.selBorder : Theme.hair
        Behavior on border.color { ColorAnimation { duration: Motion.fast } }
    }

    /** El panel que sale de la elegida, hacia dentro, frente a su centro (como un panel abierto desde ella). */
    Rectangle {
        id: hang
        readonly property var b: root.barBox(root.value, true)
        readonly property bool vert: BarEdge.vertical(root.value)
        readonly property real pw: Math.round((hang.vert ? 44 : 58) * root.s)
        readonly property real ph: Math.round((hang.vert ? 40 : 30) * root.s)
        readonly property real gap: Math.round(3 * root.s)
        width: hang.pw
        height: hang.ph
        x: root.value === "left" ? hang.b.x + hang.b.w + hang.gap
            : root.value === "right" ? hang.b.x - hang.gap - hang.pw
            : Math.round(Math.max(root.inset, Math.min(root.screenW - root.inset - hang.pw, hang.b.x + hang.b.w / 2 - hang.pw / 2)))
        y: root.value === "top" ? hang.b.y + hang.b.h + hang.gap
            : root.value === "bottom" ? hang.b.y - hang.gap - hang.ph
            : Math.round(Math.max(root.inset, Math.min(root.screenH - root.inset - hang.ph, hang.b.y + hang.b.h / 2 - hang.ph / 2)))
        radius: Metrics.r(4) * root.s
        color: Qt.alpha(Theme.primary, 0.16)
        border.width: Math.max(1, root.s)
        border.color: Qt.alpha(Theme.primary, 0.55)
        Behavior on x { enabled: !Motion.still; NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic } }
        Behavior on y { enabled: !Motion.still; NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic } }
    }

    Repeater {
        model: BarEdge.EDGES
        delegate: Rectangle {
            id: spot
            required property string modelData
            readonly property bool current: spot.modelData === root.value
            readonly property var b: root.barBox(spot.modelData, spot.current)

            x: spot.b.x
            y: spot.b.y
            width: spot.b.w
            height: spot.b.h
            radius: Metrics.pill(Math.min(width, height))
            color: spot.current ? Theme.primary : (root.hoverEdge === spot.modelData ? Theme.hoverBg : "transparent")
            border.width: Math.max(1, root.s)
            border.color: spot.current ? Theme.primary : (root.hoverEdge === spot.modelData ? Theme.selBorder : Theme.hair)
            Behavior on color { ColorAnimation { duration: Motion.fast } }

            Accessible.role: Accessible.RadioButton
            Accessible.name: BarEdge.edgeLabel(spot.modelData)
            Accessible.checkable: true
            Accessible.checked: spot.current
            Accessible.onPressAction: root.picked(spot.modelData)
        }
    }

    /**
     * La zona de clic de cada borde: su franja entera (aunque la elegida sea más corta), de la orilla hasta un poco
     * más dentro que la barra, sin las esquinas (que no son de nadie).
     */
    Repeater {
        model: BarEdge.EDGES
        delegate: MouseArea {
            id: zone
            required property string modelData
            readonly property real band: root.inset + root.thick + Math.round(8 * root.s)
            readonly property real corner: root.inset + root.thick
            x: zone.modelData === "right" ? root.screenW - zone.band : zone.modelData === "left" ? 0 : zone.corner
            y: zone.modelData === "bottom" ? root.screenH - zone.band : zone.modelData === "top" ? 0 : zone.corner
            width: BarEdge.vertical(zone.modelData) ? zone.band : root.screenW - 2 * zone.corner
            height: BarEdge.vertical(zone.modelData) ? root.screenH - 2 * zone.corner : zone.band
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onContainsMouseChanged: {
                if (zone.containsMouse) root.hoverEdge = zone.modelData;
                else if (root.hoverEdge === zone.modelData) root.hoverEdge = "";
            }
            onClicked: root.picked(zone.modelData)
        }
    }
}
