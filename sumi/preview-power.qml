pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "components"
import "services" as Svc
import "surfaces" as Srf
import "theme"

/**
 * VISTA PREVIA DE POWER (rediseño, ARR-05, prueba P-06).
 *
 * Monta `surfaces/Power` —la del shell— con el servicio `Power` en SIMULACIÓN:
 *
 *   SUMI_POWER_DRYRUN=ok    las acciones «salen bien» (`true`)
 *   SUMI_POWER_DRYRUN=fail  las rechaza un proceso con «Access denied» y código 1
 *
 * **Sin esa variable no se monta nada y se cierra al instante**: una preview de
 * Power que pudiera ejecutar de verdad apagaría, reiniciaría o bloquearía la
 * sesión del usuario. Las seis funciones de `Power` comprueban `simulated` en su
 * primera línea; esta guarda es la segunda.
 *
 * Importa además `Session` (por `keepAwake`): con un XDG_STATE_HOME temporal crea
 * una capa de 1 px, un IdleInhibitor apagado y un `dbus-monitor` de sólo lectura.
 *
 *   XDG_STATE_HOME=$(mktemp -d) SUMI_POWER_DRYRUN=fail qs -p <árbol>/preview-power.qml
 *
 * Teclado sólo al hacer clic (OnDemand), nunca exclusivo. IPC
 * `sumi-power-preview`: `state`, `reopen`, `hide`, `key <nombre>`, `click <id>`,
 * `quit`.
 */
ShellRoot {
    id: root

    property string screenName: Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    property bool shown: true
    property int closes: 0
    property var hubRef: null

    function log(o) { console.log("POWER-PREVIEW " + JSON.stringify(o)); }

    Component.onCompleted: {
        if (!Svc.Power.simulated) {
            console.error("preview-power: SUMI_POWER_DRYRUN no es ok|fail — no se monta nada");
            Qt.quit();
        }
    }

    Variants {
        model: Svc.Power.simulated ? Quickshell.screens : []

        PanelWindow {
            id: win
            required property var modelData
            screen: win.modelData
            visible: win.modelData.name === root.screenName
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "sumi-power-preview"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
            anchors { top: true; left: true }
            margins { top: 60; left: 40 }
            implicitWidth: glass.width
            implicitHeight: glass.height

            Glass {
                id: glass
                s: Svc.Settings.uiScale
                width: pw.targetW
                height: pw.implicitHeight + (pw.mTop + pw.mBottom) * Svc.Settings.uiScale
                radius: Metrics.openCorner * Svc.Settings.uiScale

                FocusScope {
                    anchors.fill: parent
                    focus: true
                    Keys.onEscapePressed: (e) => { e.accepted = false; pw.keyPressed(e); }
                    Keys.onPressed: (e) => pw.keyPressed(e)

                    Srf.Power {
                        id: pw
                        s: Svc.Settings.uiScale
                        open: root.shown
                        closeness: 1
                        Component.onCompleted: root.hubRef = pw
                        onRequestClose: { root.closes++; root.log({ ev: "requestClose" }); }
                    }
                }
            }
        }
    }

    IpcHandler {
        target: "sumi-power-preview"

        function state(): string {
            const p = root.hubRef;
            if (!p) return JSON.stringify({ mounted: false });
            return JSON.stringify({
                dryRun: Svc.Power.dryRun, simulated: Svc.Power.simulated, busy: Svc.Power.busy,
                page: p.page, pending: p.pending, focused: p.focusedAction, failNote: p.failNote, closes: root.closes,
                probed: Svc.Power.probed, suspendOk: Svc.Power.suspendOk, hibernateOk: Svc.Power.hibernateOk,
                ops: Svc.Power.ops.snapshot()   // 6C
            });
        }
        function reopen(): void { root.shown = false; root.shown = true; }
        function hide(): void { root.shown = false; }
        function key(name: string): bool {
            const map = { left: Qt.Key_Left, right: Qt.Key_Right, enter: Qt.Key_Return, esc: Qt.Key_Escape };
            const ev = { key: map[name], modifiers: 0, text: "", accepted: false };
            root.hubRef.keyPressed(ev);
            return ev.accepted;
        }
        /** Lo mismo que un clic en el botón `id` de la fila (o `yes` / `no` en la pregunta). */
        function click(id: string): void {
            const p = root.hubRef;
            if (p.page === "confirm") { if (id === "yes") p.fire(p.pending); else p.back(); }
            else p.pick(id);
        }
        function quit(): void { Qt.quit(); }
    }
}
