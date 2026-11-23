pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "components"
import "services"
import "surfaces"
import "theme"

/**
 * VISTA PREVIA DEL WEB HUB (rediseño, ARR-04, pruebas P-03…P-05).
 *
 * Monta `surfaces/WebHub` —la misma pieza que el shell— en una ventana propia,
 * sin host ni island. **No abre el navegador del usuario ni manda lo tecleado a un
 * buscador** si se lanza con el entorno de abajo:
 *
 *   SUMI_WEBSITES_CONF  un websites.conf de prueba (ausente, ilegible, largo…)
 *   SUMI_WEB_SUGGEST    servidor de sugerencias local, o un puerto cerrado
 *   BROWSER                el «navegador»: `true` finge que abre; una ruta que no
 *                          existe finge que no arranca. F3c: sólo cuenta con
 *                          apps.browser = auto, así que la preview necesita su propio
 *                          XDG_CONFIG_HOME (si no, lee el settings.json real)
 *
 * Importa `Web` (FileView de websites.conf, XHR y un Process para
 * el navegador) y los singletons de tema. Nada de notificaciones, polkit ni el IPC
 * del shell. Vive en la raíz porque un `qmldir` fuera de ella no carga los módulos.
 *
 *   XDG_STATE_HOME=$(mktemp -d) XDG_CONFIG_HOME=$(mktemp -d) SUMI_WEBSITES_CONF=… SUMI_WEB_SUGGEST=… \
 *     BROWSER=true qs -p <árbol>/preview-webhub.qml
 *
 * Teclado: sólo al hacer clic en el panel (OnDemand); nunca exclusivo.
 * IPC `sumi-webhub-preview`: `state`, `reopen`, `move <n>`, `activate`, `tab <±1>`,
 * `query <texto>`, `back`, `scale <n>`, `motion <modo>`, `quit`.
 */
ShellRoot {
    id: root

    property real scaleOverride: Number(Quickshell.env("PREVIEW_SCALE") || 0)
    readonly property real s: root.scaleOverride > 0 ? root.scaleOverride : Settings.uiScale
    property string screenName: Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    property bool shown: true
    property int closes: 0
    property var hubRef: null

    function log(o) { console.log("WEBHUB-PREVIEW " + JSON.stringify(o)); }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win
            required property var modelData
            screen: win.modelData
            visible: win.modelData.name === root.screenName
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "sumi-webhub-preview"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
            anchors { top: true; left: true }
            margins { top: 60; left: 40 }
            implicitWidth: glass.width
            implicitHeight: glass.height

            Glass {
                id: glass
                s: root.s
                width: Metrics.webW * root.s
                height: Metrics.webH * root.s
                radius: Metrics.openCorner * root.s

                FocusScope {
                    id: scope
                    anchors.fill: parent
                    focus: true
                    // Como `core/Screen`: Escape primero a la superficie; si no la quiere, «cerrar».
                    Keys.onEscapePressed: (e) => {
                        e.accepted = false;
                        hub.keyPressed(e);
                        if (!e.accepted) { root.closes++; root.log({ ev: "close (Esc)" }); }
                    }
                    Keys.onPressed: (e) => hub.keyPressed(e)

                    WebHub {
                        id: hub
                        s: root.s
                        open: root.shown
                        closeness: 1
                        Component.onCompleted: root.hubRef = hub
                        onRequestClose: {
                            root.closes++;
                            root.log({ ev: "requestClose", openError: hub.openError });
                        }
                    }
                }
            }
        }
    }

    Connections {
        target: Web.ops
        function onSettled(key, rev, state, reason) {
            root.log({ ev: "settled", key: key, rev: rev, state: state, reason: reason,
                       url: Web.ops.get(key).requested });
        }
    }

    IpcHandler {
        target: "sumi-webhub-preview"

        function state(): string {
            const h = root.hubRef;
            return JSON.stringify({
                page: h.page, category: h.category, zone: h.zone, engineFocus: h.engineFocus,
                selected: h.selected, count: h.count, opening: h.opening, openError: h.openError,
                closes: root.closes, engine: Web.engineId, query: Web.query,
                suggestions: Web.suggestions.length, fetching: Web.fetching,
                suggestError: Web.suggestError, confState: Web.confState, lastError: Web.lastError,
                browser: Web.browser, row: h.count > 0 ? JSON.stringify(h.rows[h.selected]) : null,
                openRev: h.openRev, ops: Web.ops.snapshot()   // 6C
            });
        }
        function reopen(): void { root.shown = false; root.shown = true; }
        function move(n: int): void { root.hubRef.move(n); }
        function activate(): void { root.hubRef.activate(); }
        function tab(dir: int): void { root.hubRef.tabTo(dir); }
        function query(q: string): void { root.hubRef.startSearch(q); }
        function back(): void { root.hubRef.back(); }
        function scale(v: real): void { root.scaleOverride = v; }
        function motion(m: string): void { Motion.override = m; }
        /**
         * Una tecla sintética directa a `keyPressed` (sin pasar por Qt): prueba la
         * lógica de la superficie. Nombres: tab, backtab, enter, space, left, right,
         * up, down, esc, o una letra. Devuelve si la superficie la aceptó.
         */
        function key(name: string): bool {
            const map = { tab: Qt.Key_Tab, backtab: Qt.Key_Backtab, enter: Qt.Key_Return,
                          space: Qt.Key_Space, left: Qt.Key_Left, right: Qt.Key_Right,
                          up: Qt.Key_Up, down: Qt.Key_Down, esc: Qt.Key_Escape, backspace: Qt.Key_Backspace };
            const letter = name.length === 1;
            const ev = { key: letter ? name.toUpperCase().charCodeAt(0) : map[name],
                         modifiers: 0, text: letter ? name : (name === "space" ? " " : ""), accepted: false };
            root.hubRef.keyPressed(ev);
            root.log({ ev: "key", name: name, accepted: ev.accepted });
            return ev.accepted;
        }
        function quit(): void { Qt.quit(); }
    }
}
