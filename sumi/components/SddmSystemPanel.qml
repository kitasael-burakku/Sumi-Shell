pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../services"

/**
 * Página System de la ventana Login screen (2026-11-23): lo que hace la pantalla de inicio de verdad.
 *
 *   estado     `sumi-sddm` y `system status` (instalado, tema activo, quién lo decide, si lo aplicado coincide)
 *   acciones   Apply · Use · Restore (pkexec, la contraseña cada vez; Use y Restore con dos pulsaciones)
 *   tus ajustes  Reset all (dos pulsaciones; queda copia) · Undo the last reset
 *   registro   el último arranque del greeter (`system log`): bien, con problemas o ninguno en este arranque
 *   recuperación  la orden para la consola de texto y la guía instalada
 *
 * Los textos son los de SddmTheme (los mismos que Settings). Teclado: el dueño mueve `focusIndex` por `rowIds`
 * y llama a activate(i).
 */
Item {
    id: root

    property real s: 1
    property int focusIndex: -1
    /** Las filas que se pueden activar, en orden (el teclado de LoginScreen las recorre). */
    readonly property var rowIds: ["sddmApply", "sddmActivate", "sddmDeactivate", "sddmReset", "sddmRestore",
                                   "logToggle", "recoveryGuide"]
    readonly property var log: SddmTheme.logSummary()
    property bool logOpen: false
    readonly property string guide: "/usr/share/doc/sumi-sddm/RECUPERACION.md"
    readonly property string tty: "sudo /usr/lib/sumi-sddm/sumi-sddm-helper deactivate"

    function activate(i) {
        const id = root.rowIds[i];
        if (id === "logToggle") { if (root.log.problems.length > 0) root.logOpen = !root.logOpen; return; }
        if (id === "recoveryGuide") { Apps.openPath(root.guide); return; }
        if (SddmTheme.reasonText(id).length === 0) SddmTheme.runAction(id);
    }
    function focused(id) { return root.focusIndex === root.rowIds.indexOf(id); }

    implicitHeight: col.implicitHeight

    Column {
        id: col
        width: parent.width
        spacing: 8 * root.s

        Text {
            width: col.width
            text: "System"
            color: Theme.fg
            font.family: Typography.ui; font.pixelSize: Typography.body * root.s; font.weight: Typography.wStrong
        }
        Repeater {
            model: ["sddmStatus", "sddmApplied"]
            SettingRow {
                id: ir
                required property string modelData
                width: col.width
                s: root.s; grouped: true; sectioned: true; captionEssential: true
                name: ir.modelData === "sddmStatus" ? "Sumi SDDM" : "On the login screen"
                caption: SddmTheme.captionText(ir.modelData)
                Text {
                    text: SddmTheme.infoText(ir.modelData)
                    color: ir.modelData === "sddmApplied" && SddmTheme.system && SddmTheme.system.installed
                           && !SddmTheme.system.inSync ? Theme.warn : Theme.fgVariant
                    font.family: Typography.ui; font.pixelSize: Typography.label * root.s
                }
            }
        }
        Repeater {
            model: [{ id: "sddmApply", name: "Apply to the login screen", label: "Apply" },
                    { id: "sddmActivate", name: "Use as the login screen", label: "Use" },
                    { id: "sddmDeactivate", name: "Restore the previous login screen", label: "Restore" },
                    { id: "", name: "Your settings", label: "" },
                    { id: "sddmReset", name: "Reset everything", label: "Reset" },
                    { id: "sddmRestore", name: "Undo the last reset", label: "Restore" }]
            Item {
                id: slot
                required property var modelData
                width: col.width
                height: slot.modelData.id === "" ? headText.implicitHeight + 6 * root.s : ar.height
                Text {
                    id: headText
                    visible: slot.modelData.id === ""
                    y: 6 * root.s
                    width: col.width
                    text: slot.modelData.name
                    color: Theme.fg
                    font.family: Typography.ui; font.pixelSize: Typography.body * root.s; font.weight: Typography.wStrong
                }
                SettingRow {
                    id: ar
                    readonly property string rowId: slot.modelData.id
                    readonly property string why: SddmTheme.reasonText(ar.rowId)
                    readonly property bool armed: ar.rowId === "sddmActivate" ? SddmTheme.activateArmed
                        : ar.rowId === "sddmDeactivate" ? SddmTheme.deactivateArmed
                        : ar.rowId === "sddmReset" ? SddmTheme.resetArmed : false
                    visible: ar.rowId !== ""
                    width: col.width
                    s: root.s; grouped: true; sectioned: true; captionEssential: true
                    focused: ar.rowId !== "" && root.focused(ar.rowId)
                    name: slot.modelData.name
                    caption: SddmTheme.captionText(ar.rowId)
                    available: ar.why.length === 0
                    reason: ar.why
                    onActivated: root.activate(root.rowIds.indexOf(ar.rowId))
                    ActionButton {
                        s: root.s
                        label: slot.modelData.label
                        primary: ar.rowId === "sddmApply"
                        danger: ar.armed
                        enabled: ar.available
                        focused: ar.focused
                        onTriggered: root.activate(root.rowIds.indexOf(ar.rowId))
                    }
                }
            }
        }

        Text {
            width: col.width; topPadding: 6 * root.s
            text: "Last login screen"
            color: Theme.fg
            font.family: Typography.ui; font.pixelSize: Typography.body * root.s; font.weight: Typography.wStrong
        }
        SettingRow {
            id: logRow
            width: col.width
            s: root.s; grouped: true; sectioned: true; captionEssential: true
            focused: root.focused("logToggle")
            name: root.log.state === "ok" ? "No problems" : root.log.state === "problems" ? "Problems"
                : root.log.state === "missing" ? "Not shown yet" : "Checking…"
            caption: root.log.text
            onActivated: root.activate(root.rowIds.indexOf("logToggle"))
            Text {
                visible: root.log.problems.length > 0
                text: root.logOpen ? "Hide" : "Show"
                color: Theme.fgVariant
                font.family: Typography.ui; font.pixelSize: Typography.label * root.s
            }
        }
        Rectangle {
            visible: root.logOpen && root.log.problems.length > 0
            width: col.width
            height: probs.implicitHeight + 16 * root.s
            radius: Metrics.rSm * root.s
            color: Theme.tileBg
            border.width: 1; border.color: Theme.hair
            Column {
                id: probs
                x: 10 * root.s; y: 8 * root.s
                width: parent.width - 20 * root.s
                spacing: 4 * root.s
                Repeater {
                    model: root.log.problems
                    TextEdit {
                        required property var modelData
                        width: probs.width
                        readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap
                        text: String(modelData)
                        color: Theme.fgVariant
                        font.family: Typography.mono; font.pixelSize: Typography.caption * root.s
                    }
                }
            }
        }

        Text {
            width: col.width; topPadding: 6 * root.s
            text: "If the login screen breaks"
            color: Theme.fg
            font.family: Typography.ui; font.pixelSize: Typography.body * root.s; font.weight: Typography.wStrong
        }
        Text {
            width: col.width
            wrapMode: Text.Wrap
            text: "Press Ctrl+Alt+F3 on the login screen, sign in and run this to go back to the previous theme:"
            color: Theme.fgVariant
            font.family: Typography.ui; font.pixelSize: Typography.label * root.s
        }
        Rectangle {
            width: col.width
            height: cmd.implicitHeight + 14 * root.s
            radius: Metrics.rSm * root.s
            color: Theme.tileBg
            border.width: 1; border.color: Theme.hair
            TextEdit {
                id: cmd
                x: 10 * root.s; anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 20 * root.s
                readOnly: true; selectByMouse: true; wrapMode: TextEdit.WrapAnywhere
                text: root.tty
                color: Theme.fg
                font.family: Typography.mono; font.pixelSize: Typography.label * root.s
                Accessible.role: Accessible.StaticText
                Accessible.name: "Recovery command"
            }
        }
        SettingRow {
            width: col.width
            s: root.s; grouped: true; sectioned: true; captionEssential: true
            focused: root.focused("recoveryGuide")
            name: "Recovery guide"
            caption: "Every way back, also without the helper"
            onActivated: root.activate(root.rowIds.indexOf("recoveryGuide"))
            ActionButton {
                s: root.s
                label: "Open"
                glyph: "open-external"
                focused: root.focused("recoveryGuide")
                onTriggered: root.activate(root.rowIds.indexOf("recoveryGuide"))
            }
        }
    }
}
