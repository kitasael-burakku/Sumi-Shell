import QtQuick
import "../theme"

/**
 * Botón de sólo glifo (rediseño del Centro de control, 2026-11-15): Settings `⚙` y Clear all `≡` en rojo.
 *
 * El nombre accesible es obligatorio (`label`): el glifo no se lee. `danger` lo pinta en rojo (Clear all del boceto).
 * Zona de clic de `Metrics.hitMin`; el foco de teclado lo lleva quien lo contiene. En terminal el marco es recto
 * (tokens de Metrics) y no hay más diferencia.
 */
Item {
    id: btn

    /** La familia de acento de la zona (Theme.fam; lib/accent-zones.js). */
    readonly property var acc: Theme.fam(palette.accent)
    property real s: 1
    property string glyph: ""
    property string label: ""
    property bool danger: false
    property bool focused: false
    property bool enabled: true
    property real glyphSize: btn.compact ? Metrics.glyphSm : Metrics.glyphMd
    /** Fase 3A (ADR-42): el nombre (`label`) como tooltip, debajo; `tip: false` lo calla. */
    property bool tip: true
    /**
     * Fase 3C (ADR-42): el mini botón de un pie o una cabecera (Recorder, Wallpaper, Theme, Mixer), del tamaño que tenían
     * los hechos a mano (20 × 18, glifo de 12) y con la zona de clic ampliada fuera de la caja; mismo hover, foco,
     * tooltip y marco de Terminal (sólo al pasar o con foco: a este tamaño un marco fijo sería ruido).
     */
    property bool compact: false
    signal triggered()

    implicitWidth: (btn.compact ? 20 : Metrics.hitMin) * btn.s
    implicitHeight: (btn.compact ? 18 : Metrics.hitMin) * btn.s
    Accessible.role: Accessible.Button
    Accessible.name: btn.label
    Accessible.focusable: btn.enabled
    Accessible.focused: btn.focused
    Accessible.onPressAction: if (btn.enabled) btn.triggered()

    readonly property color ink: !btn.enabled ? Theme.disabledFg
        : btn.danger ? Theme.dangerText : area.containsMouse ? Theme.fg : Theme.fgVariant

    Rectangle {
        anchors.fill: parent
        anchors.margins: (btn.compact ? -2 : 2) * btn.s
        radius: Metrics.rSm * btn.s
        color: !btn.enabled || !area.containsMouse ? "transparent"
             : area.pressed ? Theme.pressedBg : btn.danger ? Theme.errorBg : Theme.hoverBg
        border.width: !btn.enabled ? 0 : btn.focused ? Metrics.focusWidth * btn.s
            : Style.terminal && (!btn.compact || area.containsMouse) ? 1 : 0
        border.color: btn.focused ? btn.acc.ring : Qt.alpha(btn.ink, 0.3)
        Behavior on color { ColorAnimation { duration: Motion.fast } }
    }
    Icon {
        x: Math.round((parent.width - width) / 2); y: Math.round((parent.height - height) / 2)
        name: btn.glyph
        size: btn.glyphSize * btn.s
        color: btn.ink
    }
    MouseArea {
        id: area
        anchors.fill: parent
        anchors.margins: btn.compact ? -6 * btn.s : 0
        hoverEnabled: true
        enabled: btn.enabled
        cursorShape: Qt.PointingHandCursor
        onClicked: btn.triggered()
    }
    /**
     * Dónde cuelga el tooltip: el primer antepasado que recorta (el panel). Hijo del botón, lo tapaban los hermanos que
     * se dibujan después (los deslizadores del Control Center: `z` sólo ordena entre hermanos); colgado del panel va
     * por encima de todo su contenido y se mide contra sus bordes. Se recalcula al enseñarse.
     */
    readonly property Item tipHost: {
        void tipItem.want;
        let a = btn.parent;
        while (a && !a.clip && a.parent) a = a.parent;
        return a || btn;
    }
    Tooltip {
        id: tipItem
        parent: btn.tipHost
        s: btn.s
        text: btn.label
        active: btn.tip && btn.enabled && (area.containsMouse || btn.focused)
        immediate: btn.focused && !area.containsMouse
        readonly property point at: { void tipItem.want; return btn.mapToItem(btn.tipHost, 0, 0); }
        // centrado bajo el botón, sin salirse del panel (un botón pegado al borde, como el engranaje del CC)
        x: Math.round(Math.max(4 * btn.s, Math.min(btn.tipHost.width - width - 4 * btn.s,
                                                    tipItem.at.x + (btn.width - width) / 2)))
        y: Math.round(tipItem.at.y + btn.height + 4 * btn.s)
    }
}
