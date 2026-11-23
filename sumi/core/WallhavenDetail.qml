pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Widgets
import "../theme"
import "../services"
import "../components"

/**
 * La ficha de un resultado en la tienda de Wallhaven (W3): lo que era el panel de detalle de
 * Wallpaper List (10C-2 / 10D-1), con sitio y para el ratón.
 *
 *   · La vista grande (`large`), los colores, los datos que ayudan a decidir (tamaño, formato y
 *     peso, categoría, vistas) y el autor y las etiquetas cuando llegan (`Wallhaven.info`, tras
 *     medio segundo en la misma ficha: no una petición por cada paso).
 *   · UNA acción principal según el estado, de `WallhavenStore.detailActions`:
 *       Download · (en cola / bajando / comprobando: progreso + Cancel) · (fallida: el motivo +
 *       Retry) · ya en la biblioteca: Apply now + Show in library.
 *     Descargar nunca aplica; Apply now es la acción explícita.
 *   · Secundarias: Similar (`like:`), Open on wallhaven.cc; una etiqueta busca `id:<etiqueta>`.
 *
 * Quien la aloja ejecuta las acciones (`act`): buscar, aplicar y abrir la biblioteca son cosas de
 * la tienda y de su pantalla, no de la ficha.
 */
Rectangle {
    id: sheet

    property real s: 1
    signal act(var action)
    signal closeRequested()

    readonly property var item: WallhavenStore.detailItem
    readonly property var info: { void Wallhaven.infos; return sheet.item ? (Wallhaven.infos[sheet.item.id] || null) : null; }
    readonly property var actions: WallhavenStore.detailActions(sheet.item, sheet.info)
    readonly property var primaryActs: sheet.actions.filter(a => ["download", "cancel", "retry", "apply", "show"].indexOf(a.kind) >= 0)
    readonly property var secondaryActs: sheet.actions.filter(a => a.kind === "similar" || a.kind === "open")
    readonly property var tags: sheet.actions.filter(a => a.kind === "tag")
    readonly property var dl: sheet.item ? WallhavenStore.dlItem(sheet.item.id) : null
    readonly property bool inLibrary: sheet.primaryActs.some(a => a.kind === "apply")

    radius: Metrics.rMd * sheet.s
    color: Theme.cardBg
    border.width: 1
    border.color: Theme.glassBorder

    /** Las etiquetas se piden al quedarse medio segundo en la misma ficha. */
    Timer {
        id: dwell
        interval: 500
        onTriggered: if (sheet.item) Wallhaven.info(sheet.item.id)
    }
    onItemChanged: if (sheet.item) dwell.restart()

    // los clics dentro no llegan al velo de debajo; la rueda, al acabar el scroll de la ficha,
    // tampoco (seguía moviendo la cuadrícula de la tienda)
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onWheel: (wheel) => wheel.accepted = true
    }

    // ---- barra: anterior / siguiente y cerrar ---------------------------------------------

    Item {
        id: bar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: 10 * sheet.s
        height: 26 * sheet.s

        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2 * sheet.s
            Repeater {
                model: [{ glyph: "chevron-left", dir: -1, name: "Previous wallpaper" },
                        { glyph: "chevron-right", dir: 1, name: "Next wallpaper" }]
                delegate: Rectangle {
                    id: stepBtn
                    required property var modelData
                    readonly property bool can: WallhavenStore.detailIndex + stepBtn.modelData.dir >= 0
                        && WallhavenStore.detailIndex + stepBtn.modelData.dir < Wallhaven.results.length
                    width: 26 * sheet.s
                    height: 26 * sheet.s
                    radius: Metrics.pill(width)
                    color: stepArea.containsMouse && stepBtn.can ? Theme.hoverBg : "transparent"
                    opacity: stepBtn.can ? 1 : 0.35
                    Accessible.role: Accessible.Button
                    Accessible.name: stepBtn.modelData.name
                    Icon {
                        anchors.centerIn: parent
                        name: stepBtn.modelData.glyph
                        size: 14 * sheet.s
                        color: Theme.fgVariant
                    }
                    MouseArea {
                        id: stepArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: stepBtn.can ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: if (stepBtn.can) WallhavenStore.stepDetail(stepBtn.modelData.dir)
                    }
                }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                leftPadding: 6 * sheet.s
                text: WallhavenStore.detailIndex >= 0 ? (WallhavenStore.detailIndex + 1) + " of " + Wallhaven.results.length : ""
                color: Theme.outlineText
                font.family: Typography.mono
                font.pixelSize: Typography.micro * sheet.s
                font.features: { "tnum": 1 }
            }
        }
        Rectangle {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: 26 * sheet.s
            height: 26 * sheet.s
            radius: Metrics.pill(width)
            color: closeArea.containsMouse ? Theme.hoverBg : "transparent"
            Accessible.role: Accessible.Button
            Accessible.name: "Close details"
            Icon {
                anchors.centerIn: parent
                name: "close"
                size: 13 * sheet.s
                color: closeArea.containsMouse ? Theme.fg : Theme.fgVariant
            }
            MouseArea {
                id: closeArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: sheet.closeRequested()
            }
        }
    }

    Flickable {
        id: flick
        anchors.top: bar.bottom
        anchors.topMargin: 8 * sheet.s
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: 14 * sheet.s
        anchors.rightMargin: 14 * sheet.s
        anchors.bottomMargin: 12 * sheet.s
        contentWidth: width
        contentHeight: col.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: col
            width: flick.width
            spacing: 12 * sheet.s

            // ---- la vista grande ----------------------------------------------------------
            ClippingRectangle {
                width: col.width
                height: Math.round(col.width * 0.6)
                radius: Metrics.rSm * sheet.s
                color: Theme.surfaceContainerLowest
                Image {
                    id: big
                    anchors.fill: parent
                    source: sheet.item ? sheet.item.large : ""
                    sourceSize.width: 720
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    opacity: big.status === Image.Ready ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: Motion.fast } }
                }
                // mientras llega la grande, la pequeña ya en caché
                Image {
                    anchors.fill: parent
                    visible: big.status !== Image.Ready
                    source: sheet.item ? sheet.item.thumb : ""
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                }
                Text {
                    anchors.centerIn: parent
                    visible: big.status === Image.Error
                    text: "Preview unavailable"
                    color: Theme.outlineText
                    font.family: Typography.ui
                    font.pixelSize: Typography.micro * sheet.s
                }
            }

            // ---- nombre y colores ---------------------------------------------------------
            Item {
                width: col.width
                height: 20 * sheet.s
                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: sheet.item ? "wallhaven-" + sheet.item.id : ""
                    color: Theme.fg
                    font.family: Typography.mono
                    font.pixelSize: Typography.body * sheet.s
                    font.weight: Font.DemiBold
                }
                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 3 * sheet.s
                    Repeater {
                        model: sheet.item ? sheet.item.colors : []
                        delegate: Rectangle {
                            required property var modelData
                            width: 12 * sheet.s
                            height: 12 * sheet.s
                            radius: Metrics.pill(width)
                            color: modelData
                            border.width: 1
                            border.color: Qt.alpha(Theme.outline, 0.4)
                        }
                    }
                }
            }

            // ---- lo que ayuda a decidir -----------------------------------------------------
            Grid {
                columns: 2
                columnSpacing: 12 * sheet.s
                rowSpacing: 4 * sheet.s
                Repeater {
                    model: !sheet.item ? [] : [
                        ["Size", sheet.item.resolution.replace("x", " × ") + (sheet.item.ratio ? "  ·  " + sheet.item.ratio : "")],
                        ["File", sheet.item.format + "  ·  " + Wallhaven.formatBytes(sheet.item.bytes)],
                        ["Kind", sheet.item.category + "  ·  " + sheet.item.purity],
                        ["Seen", sheet.item.views + " views  ·  " + sheet.item.favorites + " favorites"],
                        ["Added", (sheet.item.created || "—")
                            + (sheet.info && sheet.info.ok && sheet.info.uploader ? "  ·  by " + sheet.info.uploader : "")]
                    ].reduce((a, r) => a.concat(r), [])
                    delegate: Text {
                        required property var modelData
                        required property int index
                        width: index % 2 === 0 ? 44 * sheet.s : col.width - 56 * sheet.s
                        elide: Text.ElideRight
                        text: modelData
                        color: index % 2 === 0 ? Theme.outlineText : Theme.fgVariant
                        font.family: Typography.ui
                        font.pixelSize: Typography.caption * sheet.s
                    }
                }
            }

            // ---- la acción principal -------------------------------------------------------
            Column {
                width: col.width
                spacing: 8 * sheet.s

                /** El estado de la descarga en palabras (nunca sólo un color). */
                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    visible: text.length > 0
                    readonly property var d: sheet.dl
                    readonly property string why: { const a = sheet.primaryActs.find(x => x.why); return a ? a.why : ""; }
                    text: why.length > 0 ? why
                        : sheet.inLibrary ? (d && d.state === "done" ? "Downloaded · in your library, not applied" : "Already in your library")
                        : !d ? ""
                        : d.state === "running" ? "Downloading " + (d.bytes > 0 ? Math.floor(100 * d.got / d.bytes) + "%  ·  " : "")
                            + Wallhaven.formatBytes(d.got) + (d.bytes > 0 ? " of " + Wallhaven.formatBytes(d.bytes) : "")
                        : d.state === "queued" ? "Queued · at most two files download at a time"
                        : d.state === "validating" ? "Checking the file before it enters your library…"
                        : d.reason
                    color: why.length > 0 ? Theme.warn
                        : sheet.inLibrary ? Theme.primary
                        : d && ["failed", "paused", "interrupted", "cancelled"].indexOf(d.state) >= 0 ? Theme.warn : Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * sheet.s
                }
                /** Progreso: sólo mientras baja (sin animación propia; se mueve con los bytes). */
                Rectangle {
                    width: parent.width
                    height: 4 * sheet.s
                    radius: Metrics.pill(height)
                    color: Theme.tileBg
                    visible: sheet.dl !== null && ["running", "validating", "queued"].indexOf(sheet.dl.state) >= 0
                    Rectangle {
                        height: parent.height
                        radius: parent.radius
                        color: Theme.primary
                        width: !sheet.dl ? 0 : sheet.dl.state === "validating" ? parent.width
                            : sheet.dl.bytes > 0 ? parent.width * Math.min(1, sheet.dl.got / sheet.dl.bytes) : 0
                        Behavior on width { NumberAnimation { duration: Motion.fast } }
                    }
                }
                Flow {
                    width: col.width
                    spacing: 8 * sheet.s
                    Repeater {
                        model: sheet.primaryActs
                        delegate: ActionButton {
                            required property var modelData
                            required property int index
                            s: sheet.s
                            primary: index === 0 && modelData.kind !== "cancel"
                            glyph: modelData.kind === "download" ? "download" : ""
                            label: modelData.kind === "download" && sheet.item && sheet.item.bytes > 0
                                ? "Download  ·  " + Wallhaven.formatBytes(sheet.item.bytes) : modelData.label
                            // F2c: lo que no se puede aquí, apagado; el motivo, en la línea de estado
                            enabled: !modelData.why
                            onTriggered: if (!modelData.why) sheet.act(modelData)
                        }
                    }
                }
            }

            Rectangle { width: col.width; height: 1; color: Theme.hair }

            // ---- secundarias y etiquetas -----------------------------------------------------
            Flow {
                width: col.width
                spacing: 6 * sheet.s
                Repeater {
                    model: sheet.secondaryActs
                    delegate: StoreChip {
                        required property var modelData
                        s: sheet.s
                        maximumWidth: col.width
                        label: modelData.kind === "open" ? "Open on wallhaven.cc" : "Find similar"
                        trailing: modelData.kind === "open" ? "open-external" : ""
                        onActivated: sheet.act(modelData)
                    }
                }
            }
            Text {
                visible: !sheet.info || !sheet.info.ok
                text: !sheet.info ? "Loading tags…" : "Tags unavailable · " + sheet.info.reason
                color: Theme.outlineText
                font.family: Typography.ui
                font.pixelSize: Typography.micro * sheet.s
            }
            Flow {
                width: col.width
                spacing: 5 * sheet.s
                visible: sheet.tags.length > 0
                Repeater {
                    model: sheet.tags
                    delegate: StoreChip {
                        required property var modelData
                        s: sheet.s
                        maximumWidth: col.width
                        label: "#" + modelData.label
                        onActivated: sheet.act(modelData)
                    }
                }
            }
        }
    }
    ScrollHint { view: flick; s: sheet.s }
}
