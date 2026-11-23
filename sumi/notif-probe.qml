import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "services"
import "core"
import "surfaces"
import "theme"

/**
 * Sonda de las notificaciones del shell (Fase 1 de NOTIFICACIONES.md): el MISMO
 * `services/Notifs.qml` y la MISMA `core/NotifLayer.qml` que el shell real, y
 * nada mas. Sin island, sin atajos, sin el resto de servicios.
 *
 * SOLO EN UN BUS PRIVADO. La arranca `~/Projects/Quickshell/tools/notif-noloss.sh private shell`,
 * dentro de `dbus-run-session` y con un `XDG_STATE_HOME` temporal cuyo
 * `settings.json` enciende `notificationServer`. En el bus real no haria nada
 * con el ajuste apagado, y con el ajuste encendido se pondria en cola por el
 * nombre de SwayNC (ver la cabecera de Notifs.qml): no se lanza a mano.
 *
 * Vive en la raiz del shell a proposito: Quickshell no carga los `qmldir` de un
 * directorio fuera de la raiz de lo que lanza (medido: los singletons salen
 * `undefined` y «NotifLayer is not a type»), y asi `Quickshell.shellDir` es el
 * del shell y `Colors` encuentra `colors.json`. Nada la importa: el shell real
 * solo carga `shell.qml`.
 *
 * Los verbos IPC tienen el mismo nombre que en `core/Ipc.qml`, para que el
 * guion hable igual con la sonda (`qs -p`) que con el shell (`qs -c sumi`).
 *
 * Fase 2: el centro (`surfaces/Notifications.qml`, el mismo) en una ventana
 * propia arriba al centro que imita lo minimo del island: vidrio, foco de
 * teclado exclusivo mientras esta abierto y las teclas reenviadas a
 * `keyPressed` como hace `core/Screen.qml`. `open notifications ""` / `close`.
 */
ShellRoot {
    id: root

    Variants {
        model: Quickshell.screens

        Scope {
            id: sc
            required property var modelData

            LazyLoader {
                active: Notifs.enabled
                NotifLayer { targetScreen: sc.modelData }
            }
        }
    }

    // ---- el centro, sin island -------------------------------------------------

    property bool centerOpen: false

    Connections {
        target: Notifs
        function onReplyRequested(key) { root.centerOpen = true; }
    }

    PanelWindow {
        id: centerWin
        visible: root.centerOpen
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "sumi-shell"
        WlrLayershell.keyboardFocus: root.centerOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        anchors { top: true }
        margins { top: 8 }
        implicitWidth: Metrics.notifCenterW
        implicitHeight: Metrics.notifCenterH

        FocusScope {
            id: centerScope
            anchors.fill: parent
            focus: root.centerOpen

            Rectangle {
                anchors.fill: parent
                radius: Metrics.openCorner
                color: Theme.glassBg
                border.width: 1
                border.color: Theme.glassBorder
            }

            Keys.onEscapePressed: (e) => {
                e.accepted = false;
                center.keyPressed(e);
                if (!e.accepted) root.centerOpen = false;
            }
            Keys.onPressed: (e) => center.keyPressed(e)

            Notifications {
                id: center
                s: 1
                open: root.centerOpen
                closeness: 1
                onRequestClose: root.centerOpen = false
            }
        }
        onVisibleChanged: if (visible) centerScope.forceActiveFocus()
    }

    IpcHandler {
        target: "sumi"

        function open(name: string, mon: string): bool { if (name !== "notifications") return false; root.centerOpen = true; return true; }
        function close(name: string): bool { root.centerOpen = false; return true; }
        function notifRows(): string { return NotifHistory.rowsJson(); }
        function notifExpand(key: string, on: bool): bool { NotifHistory.setExpanded(key, on); return true; }
        function notifDismissEntry(key: string): bool { return NotifHistory.dismiss(key); }
        function notifClearAll(): bool { return NotifHistory.clearAll(); }
        function notifDnd(on: bool): bool { return NotifHistory.setDnd(on); }
        function notifDndToggle(): bool { return NotifHistory.toggleDnd(); }
        function notifReply(id: int, text: string): bool { return Notifs.replyById(id, text); }

        function status(): string {
            return JSON.stringify({ pid: Quickshell.processId, probe: true, notifs: Notifs.summary() });
        }
        function notifList(): string { return Notifs.listJson(); }
        function notifAction(id: int, action: string): bool { return Notifs.actionById(id, action); }
        function notifActivate(id: int): bool { return Notifs.activateById(id); }
        function notifDismiss(id: int): bool { return Notifs.dismissById(id); }
        /** Recarga en caliente, para probar `keepOnReload` (el shell real ya tiene el suyo). */
        function reload(): void { Quickshell.reload(false); }
    }

    Component.onCompleted: void Notifs.enabled
}
