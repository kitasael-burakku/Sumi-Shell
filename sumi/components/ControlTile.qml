import QtQuick
import "../theme"

/**
 * Tarjeta del Centro de control (rediseño del 2026-11-15, boceto del autor).
 *
 * Dos acciones: `opened()` (su vista, si `opens`) y `toggled()` (encender/apagar, si `switchable`). En los DOS estilos
 * el interruptor es el `Toggle` de siempre (soft: la cápsula; terminal: la caja `[■ ON ]`), a la derecha y centrado en
 * vertical, y el cuerpo abre la vista; sin vista (DND), el cuerpo también cambia.
 *   (La primera versión del rediseño hacía de la tarjeta entera el interruptor en soft —decisión D1—; el autor la
 *    probó en las capturas de la fase B y pidió volver al botón original, 2026-11-15.)
 *
 * Disposición: glifo a la izquierda, texto (título, estado y una línea de detalle opcional, D2) centrado en vertical,
 * y a la derecha el interruptor o, si sólo lleva a otra parte (Mode), un chevrón. La tarjeta no lee servicios.
 */
Rectangle {
    id: tile

    /** La familia de acento de la zona (Theme.fam; lib/accent-zones.js). */
    readonly property var acc: Theme.fam(palette.accent)
    property real s: 1
    property string glyph: ""
    property string title: ""
    property string status: ""
    /** Segunda línea opcional (con cable: «Wi‑Fi on»). */
    property string detail: ""
    property string error: ""
    property bool on: false
    property bool switchable: true
    /** El interruptor puede usarse ahora (radio presente y sin bloqueo). */
    property bool available: true
    property bool opens: true
    property bool toggleFocused: false
    property bool openFocused: false
    property string toggleLabel: tile.title
    signal toggled()
    signal opened()

    readonly property real pad: 10 * tile.s
    readonly property bool lit: tile.switchable && tile.on
    /**
     * El ancho que haría falta para no cortar el título ni el estado (auditoría tipográfica, 2026-11-18): se mide
     * sobre los textos (TextMetrics), no sobre el maquetado, así que no depende del ancho que recibe. Lo usa el
     * Centro de control para crecer sólo lo que falte; un error largo no cuenta (se elide).
     */
    readonly property real want: Math.round(icon.x + icon.width + 8 * tile.s)
        + Math.ceil(Math.max(titleNeed.advanceWidth, statusNeed.advanceWidth)) + 1
        + 6 * tile.s + side.width + side.anchors.rightMargin
    TextMetrics { id: titleNeed; font.family: Typography.ui; font.pixelSize: Typography.body * tile.s; font.weight: Font.DemiBold; text: tile.title }
    TextMetrics { id: statusNeed; font.family: Typography.ui; font.pixelSize: Typography.label * tile.s; text: tile.status }

    radius: Metrics.rMd * tile.s
    color: Theme.controlBg(tile.acc.container, bodyArea.containsMouse, bodyArea.pressed && bodyArea.containsMouse, tile.lit, tile.acc)
    readonly property bool actionable: tile.opens || (tile.switchable && tile.available)
    border.width: tile.openFocused ? Metrics.focusWidth : 1
    border.color: tile.openFocused ? tile.acc.ring : tile.lit ? tile.acc.selBorder : Theme.cardBorder
    Behavior on color { ColorAnimation { duration: Motion.fast } }
    Behavior on border.color { ColorAnimation { duration: Motion.fast } }

    Accessible.ignored: true

    // ---- cuerpo: abre su vista; sin vista y con interruptor (DND), cambia ----
    MouseArea {
        id: bodyArea
        anchors.fill: parent
        enabled: tile.actionable
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        Accessible.role: Accessible.Button
        Accessible.name: tile.title
        Accessible.description: tile.error.length > 0 ? tile.error : tile.status
        Accessible.onPressAction: bodyArea.act()
        function act() {
            if (tile.opens) tile.opened();
            else if (tile.switchable && tile.available) tile.toggled();
        }
        onClicked: bodyArea.act()
    }

    Rectangle {
        anchors.centerIn: icon
        width: 30 * tile.s
        height: width
        radius: Metrics.rSm * tile.s
        color: tile.lit ? Qt.alpha(tile.acc.accent, 0.14) : Theme.hoverBg
        scale: bodyArea.pressed && bodyArea.containsMouse && !Motion.still ? 0.92 : 1
        Behavior on color { ColorAnimation { duration: Motion.fast } }
        Behavior on scale {
            enabled: !Motion.still
            NumberAnimation { duration: bodyArea.pressed ? Motion.snap : Motion.fast; easing.type: Easing.OutCubic }
        }
    }

    Icon {
        id: icon
        x: tile.pad
        y: Math.round((parent.height - height) / 2)
        width: Math.round(22 * tile.s)
        name: tile.glyph
        size: 19 * tile.s
        color: tile.lit ? tile.acc.accent : Qt.alpha(tile.acc.accent, tile.available ? 0.78 : 0.5)
        opacity: tile.switchable && !tile.available ? Theme.disabledOpacity : 1
        Behavior on color { ColorAnimation { duration: Motion.fast } }
    }

    // Posición y ancho ENTEROS (2026-11-15, banco de la fase D): con ancho fraccionario, al cambiar el ancho (el
    // interruptor de terminal es más ancho) y volver, Qt dejaba los glifos 0,2 px a un lado; con enteros, no.
    Column {
        x: Math.round(icon.x + icon.width + 8 * tile.s)
        width: Math.floor(side.x - 6 * tile.s) - x
        y: Math.round((parent.height - height) / 2)
        spacing: 1 * tile.s
        Text {
            width: parent.width
            text: tile.title
            elide: Text.ElideRight
            textFormat: Text.PlainText
            color: Theme.fg
            font.family: Typography.ui
            font.pixelSize: Typography.body * tile.s
            font.weight: Font.DemiBold
        }
        Text {
            width: parent.width
            text: tile.error.length > 0 ? tile.error : tile.status
            elide: Text.ElideRight
            textFormat: Text.PlainText
            maximumLineCount: 1
            color: tile.error.length > 0 ? Theme.dangerText : Theme.fgVariant
            font.family: Typography.ui
            font.pixelSize: Typography.label * tile.s
        }
        Text {
            width: parent.width
            visible: tile.detail.length > 0
            text: tile.detail
            elide: Text.ElideRight
            textFormat: Text.PlainText
            color: Theme.outlineText
            font.family: Typography.ui
            font.pixelSize: Typography.caption * tile.s
        }
    }

    // ---- derecha: el interruptor de siempre, o el chevrón de «lleva a otra parte» ----
    Item {
        id: side
        anchors.right: parent.right
        anchors.rightMargin: 6 * tile.s
        y: Math.round((parent.height - height) / 2)
        // El hueco del interruptor es el del MÁS ANCHO de los dos estilos (terminal: 42), en los dos: el texto no
        // cambia de ancho al cambiar de estilo y Qt no lo re-maqueta (un Text con elide re-maquetado dejaba los glifos
        // 0,2 px a un lado: medido en el banco de la fase D, 2026-11-15). El interruptor, pegado a la derecha.
        width: tile.switchable ? Math.round(Math.max(Metrics.hitMin, 42 + 10) * tile.s)
             : tile.opens ? 18 * tile.s : 0
        height: Metrics.hitMin * tile.s

        Toggle {
            id: tgl
            visible: tile.switchable
            x: Math.round(parent.width - width - 4 * tile.s); y: Math.round((parent.height - height) / 2)
            s: tile.s
            on: tile.on
            enabled: tile.available
            focused: tile.toggleFocused
            label: tile.toggleLabel
            onToggled: if (tile.available) tile.toggled()
        }
        Icon {
            visible: !tile.switchable && tile.opens
            x: Math.round((parent.width - width) / 2); y: Math.round((parent.height - height) / 2)
            name: "chevron-right"
            size: 12 * tile.s
            color: bodyArea.containsMouse || tile.openFocused ? Theme.fg : Theme.fgVariant
            Behavior on color { ColorAnimation { duration: Motion.fast } }
            transform: Translate {
                x: !Motion.still && bodyArea.containsMouse ? 2 * tile.s : 0
                Behavior on x {
                    enabled: !Motion.still
                    NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic }
                }
            }
        }
    }
}
