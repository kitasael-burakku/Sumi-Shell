pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "components"
import "services"
import "theme"

/**
 * VISTA PREVIA DE LA TARJETA DE NOTIFICACIÓN (rediseño, fase 7A).
 *
 * `components/NotifCard` en sus estados, con DATOS FICTICIOS, en las dos variantes
 * que la usan: popup y fila del centro. **No ejecuta nada**: cada señal de la
 * tarjeta (activar, cerrar, acción, responder) sólo se anota en el log
 * (`PREVIEW {…}`).
 *
 *   XDG_CONFIG_HOME=$(mktemp -d) XDG_STATE_HOME=$(mktemp -d) \
 *   PREVIEW_IMAGE=/ruta/a/una/imagen.png qs -p <árbol>/preview-notifications.qml
 *
 * Sin directorios temporales no monta nada: `services/Notifs` lee el ajuste del
 * servidor de la configuración, y con la real ENCENDERÍA un segundo servidor de
 * notificaciones que se quedaría en cola por el nombre D-Bus (memoria del
 * proyecto: el día que el shell se reinicie, la preview se lo quedaría). Con los
 * temporales el ajuste vale su defecto, apagado; si aun así se encendiera, la
 * preview se cierra sola.
 *
 * Estados: popup con imagen y acciones, popup sin imagen, popup crítico; en el
 * centro, crítica, viva con imagen (seleccionada, no leída), viva respondiendo
 * con borrador, restaurada con la imagen perdida (sin hueco), y `gone` (la
 * notificación desapareció con un borrador).
 *
 * Entorno: PREVIEW_IMAGE (una imagen local), PREVIEW_SCALE, PREVIEW_SCREEN,
 * PREVIEW_BG (`desktop`, `light`, `dark`). IPC `sumi-notif-preview`: `state`, `quit`.
 */
ShellRoot {
    id: root

    readonly property bool safe: (Quickshell.env("XDG_CONFIG_HOME") || "").length > 0
        && (Quickshell.env("XDG_STATE_HOME") || "").length > 0
        && Quickshell.env("XDG_CONFIG_HOME") !== Quickshell.env("HOME") + "/.config"
    readonly property bool ready: root.safe && Settings.loaded && !Notifs.enabled
    property real scaleOverride: Number(Quickshell.env("PREVIEW_SCALE") || 0)
    readonly property real s: root.scaleOverride > 0 ? root.scaleOverride : Settings.uiScale
    property string bg: Quickshell.env("PREVIEW_BG") || "desktop"
    property string screenName: Quickshell.env("PREVIEW_SCREEN")
        || (Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "")
    readonly property string image: {
        const p = Quickshell.env("PREVIEW_IMAGE") || "";
        return p.length > 0 ? "file://" + p : "";
    }
    readonly property real now: Date.now()

    Component.onCompleted: {
        if (!root.safe) console.error("preview-notifications: temp XDG dirs required — nothing mounted");
        // Borradores ficticios (en memoria de ESTE proceso, no del shell).
        Drafts.set("notif-reply:p-reply", "Sounds good, see you at");
        Drafts.set("notif-reply:p-gone", "I'll send the photos tonight, the second set came out");
    }
    Connections {
        target: Notifs
        function onEnabledChanged() {
            if (Notifs.enabled) {
                console.error("preview-notifications: the notification server turned on — quitting");
                Qt.quit();
            }
        }
    }

    function log(o) { console.log("PREVIEW " + JSON.stringify(o)); }

    // --- datos ficticios -------------------------------------------------------------

    function act(id, text) { return { identifier: id, text: text }; }

    readonly property var popups: [
        { appName: "Files", appIcon: "org.gnome.Nautilus", image: root.image, urgency: 1, id: 1,
          summary: "Photo shared", body: "Goldship sent you a picture from the track",
          actions: [root.act("default", "Open"), root.act("view", "View"), root.act("save", "Save")], hasInlineReply: false },
        { appName: "Firefox", appIcon: "firefox", image: "", urgency: 1, id: 2,
          summary: "Build finished", body: "The redesign build passed all checks in 42 s. Open the log to read the full output of every step.",
          actions: [], hasInlineReply: true },
        { appName: "Disks", appIcon: "", desktopEntry: "", image: "", urgency: 2, id: 3,
          summary: "Disk almost full", body: "Only 2 GB left on <b>/</b>",
          actions: [root.act("clean", "Clean up")], hasInlineReply: false }
    ]

    readonly property var center: [
        { entry: { key: "p-crit", app: "Disks", appIcon: "dialog-warning", image: "", urgency: 2, time: root.now - 120000,
                   summary: "Disk almost full", body: "Only 2 GB left on /" },
          notif: null, unread: true, selected: false, replying: false },
        { entry: { key: "p-img", app: "Files", appIcon: "org.gnome.Nautilus", image: root.image, urgency: 1, time: root.now - 30000,
                   summary: "Photo shared", body: "Goldship sent you a picture from the track. It is a long caption that wraps onto a second line." },
          notif: { appName: "Files", appIcon: "org.gnome.Nautilus", image: root.image, urgency: 1, id: 11,
                   summary: "Photo shared", body: "Goldship sent you a picture from the track. It is a long caption that wraps onto a second line.",
                   actions: [root.act("view", "View"), root.act("save", "Save")], hasInlineReply: false },
          unread: true, selected: true, replying: false },
        { entry: { key: "p-reply", app: "Telegram", appIcon: "telegram", image: "", urgency: 1, time: root.now - 600000,
                   summary: "Minimaru", body: "Are we still on for tomorrow?" },
          notif: { appName: "Telegram", appIcon: "telegram", image: "", urgency: 1, id: 12,
                   summary: "Minimaru", body: "Are we still on for tomorrow?", actions: [], hasInlineReply: true,
                   inlineReplyPlaceholder: "Message Minimaru" },
          unread: false, selected: false, replying: true },
        { entry: { key: "p-restored", app: "Files", appIcon: "org.gnome.Nautilus", image: "file:///nonexistent/sumi-preview.png",
                   urgency: 1, time: root.now - 7200000, summary: "Copy finished", body: "12 files copied to Backups (restored entry, its image is gone)" },
          notif: null, unread: false, selected: false, replying: false },
        { entry: { key: "p-gone", app: "Telegram", appIcon: "telegram", image: "", urgency: 1, time: root.now - 900000, gone: true,
                   summary: "Speed", body: "Did you get the photos?" },
          notif: null, unread: false, selected: false, replying: false }
    ]

    IpcHandler {
        target: "sumi-notif-preview"
        function state(): string {
            return JSON.stringify({ safe: root.safe, ready: root.ready, server: Notifs.enabled, drafts: Drafts.summary() });
        }
        function quit(): void { Qt.quit(); }
    }

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
            WlrLayershell.namespace: "sumi-preview"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
            anchors { top: true; left: true }
            margins { top: 60; left: 40 }
            implicitWidth: backdrop.width
            implicitHeight: backdrop.height

            Rectangle {
                id: backdrop
                width: grid.width + 48
                height: grid.height + 48
                radius: 26 * root.s
                color: root.bg === "light" ? "#ecebe7" : root.bg === "dark" ? "#0c0c0e" : "transparent"

                Row {
                    id: grid
                    x: 24; y: 24
                    spacing: 32 * root.s

                    // ── popups ───────────────────────────────────────────
                    Column {
                        width: Metrics.notifW * root.s
                        spacing: 10 * root.s

                        Text {
                            text: "POPUP"
                            color: Theme.fg
                            font.family: Typography.ui
                            font.pixelSize: Typography.caption * root.s
                            font.weight: Font.DemiBold
                        }
                        Repeater {
                            model: root.popups
                            NotifCard {
                                id: pc
                                required property var modelData
                                width: parent.width
                                s: root.s
                                mode: "popup"
                                notif: pc.modelData
                                onActivated: (link) => root.log({ ev: "activated", card: pc.modelData.id, link: link })
                                onDismissed: root.log({ ev: "dismissed", card: pc.modelData.id })
                                onActionInvoked: (a) => root.log({ ev: "action", card: pc.modelData.id, action: a })
                                onReplyClicked: root.log({ ev: "reply", card: pc.modelData.id })
                            }
                        }
                    }

                    // ── centro ───────────────────────────────────────────
                    Glass {
                        s: root.s
                        width: Metrics.notifCenterW * root.s
                        height: centerCol.height + 28 * root.s
                        radius: 22 * root.s

                        Column {
                            id: centerCol
                            x: 14 * root.s; y: 14 * root.s
                            width: parent.width - 28 * root.s
                            spacing: 2 * root.s

                            SurfaceHeader { s: root.s; title: "NOTIFICATIONS"; aside: "2 unread"; width: parent.width }
                            Item { width: 1; height: 6 * root.s }

                            Repeater {
                                model: root.center
                                NotifCard {
                                    id: cc
                                    required property var modelData
                                    width: parent.width
                                    s: root.s
                                    mode: "center"
                                    entry: cc.modelData.entry
                                    notif: cc.modelData.notif
                                    unread: cc.modelData.unread
                                    selected: cc.modelData.selected
                                    replying: cc.modelData.replying
                                    now: root.now
                                    onActivated: (link) => root.log({ ev: "activated", card: cc.modelData.entry.key, link: link })
                                    onDismissed: root.log({ ev: "dismissed", card: cc.modelData.entry.key })
                                    onActionInvoked: (a) => root.log({ ev: "action", card: cc.modelData.entry.key, action: a })
                                    onReplyClicked: root.log({ ev: "reply", card: cc.modelData.entry.key })
                                    onReplySent: (t) => root.log({ ev: "replySent", card: cc.modelData.entry.key, length: t.length })
                                }
                            }

                            // El pie de un grupo, como lo pinta el centro (surfaces/Notifications).
                            Row {
                                x: 32 * root.s
                                height: 28 * root.s
                                spacing: 6 * root.s
                                Icon { anchors.verticalCenter: parent.verticalCenter; name: "chevron-right"; size: 12 * root.s; color: Theme.fgVariant }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "Show 3 more  ·  4 total  ·  1 unread"
                                    color: Theme.fgVariant
                                    font.family: Typography.ui
                                    font.pixelSize: Typography.caption * root.s
                                    font.weight: Font.Medium
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
