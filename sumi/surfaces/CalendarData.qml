pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../services"
import "../components"

/**
 * Import & export del calendario local (2026-10-28), en la columna de la agenda de Calendar
 * UI. Sólo vista: el estado y las llamadas viven en `CalendarTransfer`.
 *
 * Exportar crea un .ics nuevo; importar (de un .ics o de calcurse) es siempre vista previa →
 * confirmación, con lo que ya está y lo no admitido dichos antes de escribir nada.
 * Teclado: Tab/⇧Tab entre las rutas; Intro en una ruta ejecuta su acción; Esc vuelve.
 */
Item {
    id: root

    property real s: 1
    readonly property var p: CalendarTransfer.preview
    readonly property string calcurseWhy: Capabilities.whyFirst(["agenda.calcurse"])

    function focusFirst() { exportField.focusField(); }

    Flickable {
        id: flick
        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
        anchors.bottom: footer.top; anchors.bottomMargin: 8 * root.s
        contentWidth: width; contentHeight: col.implicitHeight + 4 * root.s
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height + 1

        Column {
            id: col
            width: flick.width - 10 * root.s
            spacing: 12 * root.s

            Text {
                text: "Import & export"
                color: Theme.fg
                font.family: Typography.ui; font.pixelSize: Typography.title * root.s; font.weight: Font.DemiBold
            }
            Text {
                width: parent.width
                text: "Local calendar · .ics files and calcurse · the source is not changed"
                wrapMode: Text.Wrap
                color: Theme.fgVariant
                font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
            }

            Notice {
                width: parent.width
                visible: CalendarTransfer.error !== null
                s: root.s; tone: "danger"
                text: CalendarTransfer.error ? CalendarTransfer.error.message : ""
            }
            Notice {
                width: parent.width
                visible: CalendarTransfer.result.length > 0
                s: root.s; tone: "ok"
                text: CalendarTransfer.result
            }

            // ---- exportar ----
            Text {
                text: "Export"
                color: Theme.fg
                font.family: Typography.ui; font.pixelSize: Typography.body * root.s; font.weight: Font.DemiBold
            }
            FormField {
                id: exportField
                width: parent.width
                s: root.s; mono: true
                label: "Save as"
                hint: "A new file in your home folder; never overwrites one"
                value: CalendarTransfer.exportPath
                readOnly: CalendarTransfer.busy
                onEdited: text => CalendarTransfer.exportPath = text
                onTabbed: back => (back ? importField : importField).focusField()
                onEscaped: CalendarTransfer.close()
                onSubmitted: CalendarTransfer.exportNow()
            }
            ActionButton {
                s: root.s; glyph: "download"; accent: true
                label: CalendarTransfer.busy ? "Working…" : "Export all events"
                enabled: !CalendarTransfer.busy
                onTriggered: CalendarTransfer.exportNow()
            }

            Rectangle { width: parent.width; height: 1; color: Theme.hair }

            // ---- importar ----
            Text {
                text: "Import"
                color: Theme.fg
                font.family: Typography.ui; font.pixelSize: Typography.body * root.s; font.weight: Font.DemiBold
            }
            FormField {
                id: importField
                width: parent.width
                s: root.s; mono: true
                label: "From an .ics file"
                placeholder: "~/Downloads/calendar.ics"
                value: CalendarTransfer.importPath
                readOnly: CalendarTransfer.busy
                onEdited: text => CalendarTransfer.importPath = text
                onTabbed: back => exportField.focusField()
                onEscaped: CalendarTransfer.close()
                onSubmitted: CalendarTransfer.previewFile()
            }
            Flow {
                width: parent.width
                spacing: 6 * root.s
                ActionButton {
                    s: root.s; glyph: "file"
                    label: "Preview file"
                    enabled: !CalendarTransfer.busy && CalendarTransfer.importPath.trim().length > 0
                    onTriggered: CalendarTransfer.previewFile()
                }
                ActionButton {
                    s: root.s; glyph: "calendar"
                    label: "Preview from calcurse"
                    enabled: !CalendarTransfer.busy && root.calcurseWhy.length === 0
                    onTriggered: CalendarTransfer.previewCalcurse()
                }
            }
            Text {
                width: parent.width
                visible: root.calcurseWhy.length > 0
                text: root.calcurseWhy
                wrapMode: Text.Wrap
                color: Theme.outlineText
                font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
            }

            // ---- la vista previa ----
            Rectangle {
                width: parent.width
                visible: root.p !== null
                height: visible ? previewCol.implicitHeight + 20 * root.s : 0
                radius: Metrics.rSm * root.s
                color: Theme.tileBg
                border.width: 1
                border.color: Theme.hair
                Column {
                    id: previewCol
                    x: 12 * root.s; y: 10 * root.s
                    width: parent.width - 24 * root.s
                    spacing: 6 * root.s
                    Text {
                        width: parent.width
                        text: !root.p ? "" : (root.p.source === "calcurse" ? "From calcurse: " : "From the file: ")
                            + root.p.newCount + (root.p.newCount === 1 ? " new event" : " new events")
                            + " · " + root.p.duplicates + " already in your calendar"
                            + " · " + root.p.unsupportedCount + " not supported"
                        wrapMode: Text.Wrap
                        color: Theme.fg
                        font.family: Typography.ui; font.pixelSize: Typography.label * root.s; font.weight: Font.DemiBold
                    }
                    Repeater {
                        model: root.p ? root.p.new.slice(0, 8) : []
                        Text {
                            required property var modelData
                            width: previewCol.width
                            text: "+ " + modelData
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            color: Theme.fgVariant
                            font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                        }
                    }
                    Text {
                        visible: root.p !== null && root.p.newCount > 8
                        text: root.p ? "… and " + (root.p.newCount - 8) + " more" : ""
                        color: Theme.outlineText
                        font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                    }
                    Repeater {
                        model: root.p ? root.p.unsupported.slice(0, 5) : []
                        Text {
                            required property var modelData
                            width: previewCol.width
                            text: "× " + modelData.summary + " — " + modelData.reason
                            textFormat: Text.PlainText
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                            color: Theme.warn
                            font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                        }
                    }
                    Flow {
                        width: parent.width
                        spacing: 6 * root.s
                        ActionButton {
                            s: root.s; primary: true; glyph: "check"
                            label: !root.p ? "" : root.p.newCount === 0 ? "Nothing new to import"
                                : "Import " + root.p.newCount + (root.p.newCount === 1 ? " event" : " events")
                            enabled: !CalendarTransfer.busy && root.p !== null && root.p.newCount > 0
                            onTriggered: CalendarTransfer.importNow()
                        }
                        ActionButton {
                            s: root.s; label: "Discard preview"
                            enabled: !CalendarTransfer.busy
                            onTriggered: CalendarTransfer.discardPreview()
                        }
                    }
                    Text {
                        width: parent.width
                        text: "A copy of your calendar is kept before importing."
                        wrapMode: Text.Wrap
                        color: Theme.outlineText
                        font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                    }
                }
            }
        }
    }
    ScrollHint { view: flick; s: root.s; visible: flick.interactive }

    Item {
        id: footer
        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
        height: Math.max(back.implicitHeight, 36 * root.s)
        Rectangle { width: parent.width; height: 1; color: Theme.hair }
        ActionButton {
            id: back
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            s: root.s; glyph: "chevron-left"; label: "Back to the agenda"
            enabled: !CalendarTransfer.busy
            onTriggered: CalendarTransfer.close()
        }
    }
}
