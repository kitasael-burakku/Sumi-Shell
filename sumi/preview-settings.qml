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
 * VISTA PREVIA DE SETTINGS · SHELL (rediseño, fase 3).
 *
 * Monta `surfaces/Settings` con el ConfigStore sobre directorios TEMPORALES:
 *
 *   XDG_CONFIG_HOME=$(mktemp -d) XDG_STATE_HOME=$(mktemp -d) qs -p <árbol>/preview-settings.qml
 *
 * Sin ellos no monta nada: escribiría la configuración real. Antes de montar pone
 * `polkitAgent` a false en esa configuración temporal, porque la superficie lee
 * `Polkit.registered` y con el ajuste encendido la preview registraría un SEGUNDO agente
 * de polkit en la sesión (memoria: un agente por sesión). Las filas de tema llaman a
 * matugen de verdad: no se tocan en la preview.
 *
 * Teclado sólo al hacer clic (OnDemand). IPC `sumi-settings-preview`: `state`,
 * `key <nombre> [shift]`, `scale <n>`.
 */
ShellRoot {
    id: root

    readonly property bool safe: (Quickshell.env("XDG_CONFIG_HOME") || "").length > 0
        && (Quickshell.env("XDG_STATE_HOME") || "").length > 0
        && Quickshell.env("XDG_CONFIG_HOME") !== Quickshell.env("HOME") + "/.config"
    property bool ready: false
    property real scaleOverride: 0
    readonly property real s: root.scaleOverride > 0 ? root.scaleOverride : Svc.Settings.uiScale
    property string screenName: Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    property var pageRef: null

    Timer {
        interval: 200
        running: root.safe && !root.ready
        repeat: true
        onTriggered: {
            if (!Svc.Settings.loaded) return;
            if (Svc.Settings.polkitAgent) Svc.Settings.polkitAgent = false;
            if (Svc.Settings.notificationServer) Svc.Settings.notificationServer = false;
            root.ready = true;
        }
    }
    Component.onCompleted: if (!root.safe) console.error("preview-settings: temp XDG dirs required — nothing mounted")

    Variants {
        model: root.ready ? Quickshell.screens : []

        PanelWindow {
            id: win
            required property var modelData
            screen: win.modelData
            visible: win.modelData.name === root.screenName
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "sumi-settings-preview"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
            anchors { top: true; left: true }
            margins { top: 40; left: 40 }
            implicitWidth: glass.width
            implicitHeight: glass.height

            Glass {
                id: glass
                s: root.s
                width: Metrics.settingsUiW * root.s
                height: Metrics.settingsUiH * root.s     // el tamaño inicial de la Settings UI flotante
                radius: Metrics.openCorner * root.s

                FocusScope {
                    anchors.fill: parent
                    focus: true
                    Keys.onPressed: (e) => page.keyPressed(e)
                    Srf.Settings {
                        id: page
                        floating: true
                        s: root.s
                        open: true
                        closeness: 1
                        Component.onCompleted: root.pageRef = page
                    }
                }
            }
        }
    }

    IpcHandler {
        target: "sumi-settings-preview"
        function state(): string {
            const p = root.pageRef;
            const f = p ? p.flat[p.kbIndex] : null;
            return JSON.stringify({ mounted: p !== null, kbIndex: p ? p.kbIndex : -1,
                at: f ? (f.banner ? "action:" + f.action.id : f.row.id) : null,
                store: Svc.Settings.summary(), values: Svc.Settings.values(),
                polkitAgent: Svc.Settings.polkitAgent });
        }
        function key(name: string, shift: bool): bool {
            const map = { up: Qt.Key_Up, down: Qt.Key_Down, left: Qt.Key_Left, right: Qt.Key_Right,
                          enter: Qt.Key_Return, del: Qt.Key_Delete };
            const ev = { key: map[name], modifiers: shift ? Qt.ShiftModifier : 0, text: "", accepted: false, isAutoRepeat: false };
            root.pageRef.keyPressed(ev);
            return ev.accepted;
        }
        function scale(v: real): void { root.scaleOverride = v; }
    }
}
