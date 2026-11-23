pragma ComponentBehavior: Bound
import QtQuick
import "../components"
import "../theme"

/**
 * Las notificaciones del Lock (fase 15, LOCK-D08/D12/D17, futurelocksurface §8 «Reglas operativas»):
 * grupos por aplicación con su último mensaje y la cantidad; «Show more / Show less» abre el grupo y
 * «Expand message / Collapse message» el cuerpo. Sin descartar, responder, abrir enlaces ni apps; ni
 * mostrar ni expandir marca como leído.
 *
 * `notifs` (del contexto) = { state: ok · unavailable, count, groups: [{ app, name, count,
 * items: [{ id, title, body, time }] }] }, grupos por su mensaje más reciente y mensajes de más
 * reciente a más antiguo. El estado de expansión es de esta vista y por ID (`app`, `id`): una llegada
 * nueva no cambia lo abierto; al desbloquear se destruye (no se persiste).
 *
 * LLEGADAS (15D, §8 «Reglas operativas»): mientras se LEE —el foco dentro, algo abierto o la lista
 * desplazada— lo que se enseña no se reordena bajo el lector: la cantidad de la cabecera sí sigue a lo
 * vivo y aparece «New notifications», que trae la lista nueva. Sin leer, la lista se actualiza sola. Si
 * al traerla desaparece el control enfocado, `focusLost()` y la superficie lo lleva al siguiente.
 *
 * `ownScroll`: en el panel ancho, scroll propio con alto acotado; en el estrecho, false y todo el
 * alto (el scroll es el común de los widgets: nada de dos regiones verticales anidadas).
 */
Rectangle {
    id: root

    property real s: 1
    property var notifs: ({ state: "ok", count: 0, groups: [] })
    property bool ownScroll: true

    /** Una lista JS o la que llega de QVariant (no pasa `Array.isArray`): siempre un Array. */
    function list(x) { return x && x.length !== undefined ? Array.prototype.slice.call(x) : []; }
    /** Lo que se enseña (puede ir por detrás de `notifs` mientras se lee). */
    property var shown: root.notifs
    property bool pending: false
    readonly property var groups: root.shown ? root.list(root.shown.groups) : []
    readonly property int count: root.notifs && typeof root.notifs.count === "number" ? root.notifs.count : 0
    readonly property bool unavailable: !root.notifs || root.notifs.state === "unavailable"

    signal focusLost()
    /** El usuario hizo algo aquí (expandir, desplazar, traer la lista): cuenta para la calma (15E). */
    signal interacted()
    readonly property Item focusItem: Window.activeFocusItem
    function holdsFocus() {
        for (let it = root.focusItem; it; it = it.parent)
            if (it === root) return true;
        return false;
    }
    readonly property bool anyOpen: Object.keys(root.openGroups).some(function (k) { return root.openGroups[k]; })
        || Object.keys(root.openItems).some(function (k) { return root.openItems[k]; })
    readonly property bool reading: root.holdsFocus() || root.anyOpen || flick.contentY > 1
    onNotifsChanged: {
        if (!root.reading || root.unavailable) root.adopt();
        else root.pending = true;
    }
    onReadingChanged: if (!root.reading && root.pending) root.adopt()
    function adopt() {
        const had = root.holdsFocus();
        root.shown = root.notifs;
        root.pending = false;
        flick.contentY = 0;
        if (had) Qt.callLater(function () { if (!root.holdsFocus()) root.focusLost(); });
    }

    property var openGroups: ({})
    property var openItems: ({})
    function toggleGroup(app) { const o = Object.assign({}, root.openGroups); o[app] = !o[app]; root.openGroups = o; root.interacted(); }
    function toggleItem(id) { const o = Object.assign({}, root.openItems); o[id] = !o[id]; root.openItems = o; root.interacted(); }

    function ago(t) {
        const m = Math.max(0, Math.round((Date.now() - t) / 60000));
        if (m < 1) return "now";
        if (m < 60) return m + " min";
        const h = Math.round(m / 60);
        if (h < 24) return h + " h";
        return Math.round(h / 24) + " d";
    }

    radius: Metrics.rMd * root.s
    color: Theme.tileBg
    implicitHeight: header.height + Metrics.sp3 * 3 * root.s + body.implicitHeight

    Accessible.role: Accessible.Grouping
    Accessible.name: "Notifications, " + root.count

    Row {
        id: header
        x: Metrics.sp3 * root.s
        y: Metrics.sp3 * root.s
        width: root.width - Metrics.sp3 * 2 * root.s
        height: Typography.label * 1.6 * root.s
        spacing: Metrics.sp2 * root.s

        Icon {
            anchors.verticalCenter: parent.verticalCenter
            name: "bell"
            size: 14 * root.s
            color: Theme.fgVariant
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Notifications"
            color: Theme.fg
            font.family: Typography.uiChosen
            font.weight: Typography.wStrong
            font.pixelSize: Typography.label * root.s
        }
        Rectangle {
            id: badge
            anchors.verticalCenter: parent.verticalCenter
            visible: root.count > 0
            width: Math.max(height, countText.implicitWidth + 10 * root.s)
            height: 18 * root.s
            radius: Metrics.pill(height)
            color: Theme.selBg
            Text {
                id: countText
                anchors.centerIn: parent
                text: root.count > 99 ? "99+" : String(root.count)
                color: Theme.primary
                font.family: Typography.uiChosen
                font.weight: Typography.wStrong
                font.pixelSize: Typography.micro * root.s
                font.features: { "tnum": 1 }
            }
        }
    }

    /** Trae la lista nueva sin mover al lector antes de que lo pida. */
    LockTextButton {
        anchors.right: parent.right
        anchors.rightMargin: Metrics.sp2 * root.s
        anchors.verticalCenter: header.verticalCenter
        s: root.s
        visible: root.pending
        text: "New notifications"
        onActivated: { root.adopt(); root.interacted(); }
    }

    Flickable {
        id: flick
        x: Metrics.sp3 * root.s
        y: header.y + header.height + Metrics.sp2 * root.s
        width: root.width - Metrics.sp3 * 2 * root.s
        height: root.ownScroll ? root.height - y - Metrics.sp3 * root.s : body.implicitHeight
        contentHeight: body.implicitHeight
        clip: root.ownScroll
        interactive: root.ownScroll && contentHeight > height
        boundsBehavior: Flickable.StopAtBounds
        onMovementStarted: root.interacted()

        Column {
            id: body
            width: flick.width
            spacing: Metrics.sp2 * root.s

            // vacío / no disponible: un mensaje contenido, sin ilustración (§4.6)
            Text {
                width: parent.width
                visible: root.unavailable || root.groups.length === 0
                text: root.unavailable
                    ? (root.count > 0 ? root.count + " unread · " : "") + "Notification details unavailable"
                    : "No notifications"
                wrapMode: Text.WordWrap
                color: Theme.fgVariant
                font.family: Typography.uiChosen
                font.pixelSize: Typography.caption * root.s
                topPadding: Metrics.sp2 * root.s
                bottomPadding: Metrics.sp2 * root.s
            }

            Repeater {
                model: root.unavailable ? [] : root.groups
                delegate: Rectangle {
                    id: group
                    required property var modelData
                    readonly property bool open: root.openGroups[group.modelData.app] === true
                    readonly property var items: root.list(group.modelData.items)
                    width: body.width
                    height: gcol.implicitHeight + Metrics.sp2 * 2 * root.s
                    radius: Metrics.rSm * root.s
                    color: Qt.alpha(Theme.surfaceContainerHigh, 0.45)

                    Column {
                        id: gcol
                        x: Metrics.sp2 * root.s
                        y: Metrics.sp2 * root.s
                        width: group.width - Metrics.sp2 * 2 * root.s
                        spacing: Metrics.sp1 * root.s

                        Row {
                            width: parent.width
                            spacing: Metrics.sp2 * root.s
                            Text {
                                width: parent.width - more.width - Metrics.sp2 * root.s
                                text: (group.modelData.name || group.modelData.app || "Unknown app")
                                    + (group.modelData.count > 1 ? "  ·  " + group.modelData.count : "")
                                elide: Text.ElideRight
                                color: Theme.fgVariant
                                font.family: Typography.uiChosen
                                font.weight: Typography.wMedium
                                font.pixelSize: Typography.micro * root.s
                                font.letterSpacing: 0.6 * root.s
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            LockTextButton {
                                id: more
                                s: root.s
                                visible: group.items.length > 1
                                text: group.open ? "Show less" : "Show more"
                                subject: group.modelData.name || group.modelData.app || ""
                                onActivated: root.toggleGroup(group.modelData.app)
                            }
                        }

                        // el último siempre; los demás sólo con el grupo abierto (cada uno una vez)
                        Repeater {
                            model: group.open ? group.items : group.items.slice(0, 1)
                            delegate: Column {
                                id: item
                                required property var modelData
                                readonly property bool open: root.openItems[item.modelData.id] === true
                                width: gcol.width
                                spacing: 2 * root.s

                                Row {
                                    width: parent.width
                                    spacing: Metrics.sp2 * root.s
                                    Text {
                                        width: parent.width - when.implicitWidth - Metrics.sp2 * root.s
                                        text: item.modelData.title || "(no title)"
                                        elide: Text.ElideRight
                                        color: Theme.fg
                                        font.family: Typography.uiChosen
                                        font.weight: Typography.wStrong
                                        font.pixelSize: Typography.caption * root.s
                                    }
                                    Text {
                                        id: when
                                        text: root.ago(item.modelData.time || Date.now())
                                        color: Theme.outlineText
                                        font.family: Typography.uiChosen
                                        font.pixelSize: Typography.micro * root.s
                                    }
                                }
                                Text {
                                    id: snippet
                                    width: parent.width
                                    visible: text.length > 0
                                    text: item.modelData.body || ""
                                    textFormat: Text.PlainText
                                    wrapMode: Text.Wrap
                                    maximumLineCount: item.open ? 1000 : 2
                                    elide: Text.ElideRight
                                    color: Theme.fgVariant
                                    font.family: Typography.uiChosen
                                    font.pixelSize: Typography.caption * root.s
                                }
                                LockTextButton {
                                    s: root.s
                                    visible: snippet.truncated || item.open
                                    text: item.open ? "Collapse message" : "Expand message"
                                    subject: item.modelData.title || ""
                                    onActivated: root.toggleItem(item.modelData.id)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    ScrollHint { view: flick; s: root.s }
}
