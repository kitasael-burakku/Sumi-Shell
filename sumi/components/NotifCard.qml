import QtQuick
import Quickshell
import "../theme"
import "../services"

/**
 * La tarjeta de una notificación, COMPARTIDA por el popup y el centro (rediseño,
 * fase 7A; DESIGN §6 «NotificationCard»). Antes cada uno pintaba la suya.
 *
 * Datos: `notif` (la viva de Quickshell, o null) y/o `entry` (la del historial).
 * Una viva manda en el contenido; sin ella, lo guardado. Todo lo que pinta lo
 * escribió otra aplicación: el cuerpo pasa por `Notifs.bodyText()` (sin `<img>`,
 * enlaces sólo http(s)/mailto) y las imágenes sólo son locales.
 *
 *   cabecera   icono de la APP + nombre, marca «Critical», punto de no leída,
 *              hora y la X (visible sin hover: DESIGN, accesible por teclado)
 *   cuerpo     resumen y texto; la IMAGEN de la notificación, si la hay, en
 *              miniatura a la derecha (sin imagen válida no queda hueco)
 *   pie        acciones sólo si funcionan: las de una VIVA; una restaurada
 *              («earlier») no ofrece ninguna. Una `gone` (desapareció con un
 *              borrador de respuesta) enseña el borrador con Send deshabilitado.
 *
 * La tarjeta no decide qué hacer: emite `activated(link)`, `dismissed()`,
 * `actionInvoked(id)`, `replyClicked()`, `replySent(texto)` y `replyClosed()`, y
 * el anfitrión (popup o centro) actúa. Así la preview la enseña con datos
 * ficticios sin ejecutar nada.
 *
 * `notif` puede quedarse en `null` mientras el popup hace su animación de
 * salida (el objeto de Quickshell ya se destruyó): todo se lee con guarda.
 */
Item {
    id: card

    property real s: 1
    /** "popup" (vidrio propio, cuenta atrás) o "center" (fila del centro). */
    property string mode: "center"
    property var notif: null
    property var entry: null
    /** Popup: sube con cada `replaces_id` y la cuenta atrás vuelve a empezar. */
    property int gen: 0
    property bool selected: false
    property bool unread: false
    /** Centro: el campo de respuesta está abierto en esta tarjeta. */
    property bool replying: false
    /** Reloj de los tiempos relativos (lo da el anfitrión; 0 = sin hora). */
    property real now: 0
    /** Texto tras el nombre de la app (el centro pone «temporary» a un transitorio vivo). */
    property string note: ""
    /** El anfitrión puede no saber responder (un transitorio no tiene entrada donde guardar el borrador). */
    property bool allowReply: true

    signal activated(string link)
    signal dismissed()
    signal actionInvoked(string identifier)
    signal replyClicked()
    signal replySent(string text)
    signal replyClosed()

    readonly property bool popup: card.mode === "popup"
    readonly property var src: card.notif ? card.notif : card.entry
    readonly property bool critical: card.src !== null && card.src.urgency === 2
    readonly property bool gone: card.notif === null && card.entry !== null && card.entry.gone === true
    readonly property bool restored: card.notif === null && card.entry !== null && !card.gone
    readonly property string appName: {
        const a = card.notif ? card.notif.appName : (card.entry ? card.entry.app : "");
        return a && a.length > 0 ? a : "Notification";
    }
    readonly property string appIconSrc: Notifs.appIconOf(card.src)
    readonly property string imageSrc: card.notif ? Notifs.imageOf(card.notif) : (card.entry ? String(card.entry.image || "") : "")
    readonly property var actionList: Notifs.actionsOf(card.notif)
    readonly property bool canReply: card.allowReply && card.notif !== null && card.notif.hasInlineReply === true
    readonly property string draftKey: card.entry ? NotifHistory.draftKeyOf(card.entry.key) : ""
    readonly property string draft: { void Drafts.drafts; return card.draftKey.length > 0 ? Drafts.get(card.draftKey) : ""; }
    readonly property bool hovered: hover.hovered
    readonly property real pad: (card.popup ? 12 : 14) * card.s
    readonly property real thumbMax: (card.popup ? 44 : 56) * card.s

    implicitHeight: content.implicitHeight + 2 * card.pad

    // 16A-2: la tarjeta, con su app y su resumen; «unread» en palabras, no sólo el punto
    Accessible.role: Accessible.ListItem
    Accessible.name: card.appName + (card.src ? ": " + String(card.src.summary || "") : "")
    Accessible.description: (card.unread ? "Unread" : "") + (card.critical ? (card.unread ? " · critical" : "Critical") : "")
    Accessible.selected: card.selected
    Accessible.onPressAction: card.activated("")

    // --- popup: su cuenta atrás ---------------------------------------------------

    onGenChanged: if (life.running) life.restart()

    Timer {
        id: life
        interval: Math.max(1, Notifs.popupTimeout(card.notif))
        running: card.popup && Notifs.popupTimeout(card.notif) > 0 && card.notif !== null && !hover.hovered
        onTriggered: {
            const id = card.notif ? card.notif.id : -1;
            Qt.callLater(function () { Notifs.expirePopup(id); });
        }
    }

    HoverHandler { id: hover }

    // --- fondo ---------------------------------------------------------------------

    Glass {
        visible: card.popup
        anchors.fill: parent
        radius: Metrics.rLg * card.s
        s: card.s
        /** Aparece sobre lo que sea: se lee antes de dejar pasar el fondo. */
        deep: true
        surface: "notifPopups"
        edge: card.critical ? Theme.errorColor : Theme.borderFor("notifPopups")
        // un aviso crítico no lleva efectos de terminal (ADR-34): se lee quieto
        fxQuiet: card.critical
    }

    Rectangle {
        visible: !card.popup
        anchors.fill: parent
        radius: Metrics.rMd * card.s
        color: Theme.controlBg(Theme.cardBg, hover.hovered, activationArea.pressed && hover.hovered, card.selected)
        // Seleccionada = contorno, distinto del fondo de hover y de la marca de crítica.
        border.width: card.selected ? Metrics.focusWidth : 0
        border.color: Theme.focusRing
        Behavior on color { ColorAnimation { duration: Motion.fast } }
    }

    // Crítica: una barra fina además de la palabra (no sólo color).
    Rectangle {
        visible: card.critical && !card.popup
        x: 3 * card.s
        anchors.verticalCenter: parent.verticalCenter
        width: 3 * card.s
        height: parent.height - 16 * card.s
        radius: Metrics.pill(width)
        color: Theme.errorColor
    }

    /**
     * El clic en la tarjeta. Un MouseArea DEBAJO del contenido, y no un
     * TapHandler encima: medido con el usuario (2026-09-15) que el TapHandler de
     * la tarjeta recogía también el clic sobre la X, «activaba» (quitaba el
     * popup) antes que ella, y la X ya encontraba `notif` a null. Debajo, los
     * MouseArea de la X, los botones y el campo aceptan su clic y éste no lo ve.
     */
    MouseArea {
        id: activationArea
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: body.hoveredLink.length > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: (mouse) => {
            if (mouse.button === Qt.RightButton) {
                card.dismissed();
                return;
            }
            const p = mapToItem(body, mouse.x, mouse.y);
            card.activated(body.visible ? body.linkAt(p.x, p.y) : "");
        }
    }

    Column {
        id: content
        x: card.pad + (card.critical && !card.popup ? 6 * card.s : 0)
        y: card.pad
        width: card.width - x - card.pad
        spacing: (card.popup ? 4 : 8) * card.s

        // ---- cabecera: la app ----
        Item {
            width: parent.width
            height: Math.max((card.popup ? 16 : 28) * card.s, appLabel.implicitHeight)

            Item {
                id: appIcon
                width: 16 * card.s
                height: 16 * card.s
                anchors.verticalCenter: parent.verticalCenter

                // ADR-14: una Image decodifica aunque esté oculta; aquí sólo existe
                // mientras la tarjeta está construida, y a su tamaño.
                Image {
                    id: appImg
                    anchors.fill: parent
                    source: card.appIconSrc
                    visible: card.appIconSrc.length > 0 && status === Image.Ready
                    sourceSize.width: 32 * card.s
                    sourceSize.height: 32 * card.s
                    asynchronous: true
                    fillMode: Image.PreserveAspectFit
                    mipmap: true
                }
                Icon {
                    anchors.centerIn: parent
                    visible: !appImg.visible
                    name: card.critical ? "alert" : "bell"
                    size: 13 * card.s
                    color: card.critical ? Theme.errorColor : Theme.fgVariant
                }
            }

            Row {
                anchors.left: appIcon.right
                anchors.leftMargin: 8 * card.s
                anchors.right: tail.left
                anchors.rightMargin: 6 * card.s
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6 * card.s

                Text {
                    id: appLabel
                    width: Math.max(0, Math.min(implicitWidth, parent.width - (critTag.visible ? critTag.width + parent.spacing : 0)))
                    anchors.verticalCenter: parent.verticalCenter
                    // terminal (F6, ADR-34): el nivel delante, como un registro del sistema (el crítico ya lleva su etiqueta)
                    text: (Style.terminal && !card.critical ? (card.src !== null && card.src.urgency === 0 ? "[LOW] " : "[INFO] ") : "")
                        + card.appName + (card.restored ? "  ·  earlier" : "") + (card.note.length > 0 ? "  ·  " + card.note : "")
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    color: Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * card.s
                    font.weight: Font.Medium
                    // sin ligaduras en terminal: Maple Mono dibuja «[INFO]» como una pastilla redondeada
                    font.features: Style.terminal ? { "calt": 0, "liga": 0 } : ({})
                }

                // «Critical» en texto: la prioridad no depende sólo del color.
                Rectangle {
                    id: critTag
                    visible: card.critical
                    anchors.verticalCenter: parent.verticalCenter
                    width: critText.implicitWidth + 10 * card.s
                    height: critText.implicitHeight + 2 * card.s
                    radius: Metrics.pill(height)
                    color: Qt.alpha(Theme.errorColor, 0.16)
                    Text {
                        id: critText
                        anchors.centerIn: parent
                        text: Style.terminal ? "CRIT" : "Critical"
                        color: Theme.errorColor
                        font.family: Typography.ui
                        font.pixelSize: Typography.micro * card.s
                        font.weight: Font.DemiBold
                    }
                }
            }

            Row {
                id: tail
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8 * card.s

                // No leída: un punto (forma, no sólo color) junto a la hora.
                Rectangle {
                    visible: card.unread
                    anchors.verticalCenter: parent.verticalCenter
                    width: 6 * card.s
                    height: width
                    radius: Metrics.pill(width)
                    color: Theme.primary
                }
                Text {
                    visible: card.now > 0 && card.entry !== null
                    anchors.verticalCenter: parent.verticalCenter
                    text: card.entry ? card.ago(card.entry.time) : ""
                    color: Theme.outlineText
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * card.s
                }
                Item {
                    anchors.verticalCenter: parent.verticalCenter
                    width: (card.popup ? 14 : 28) * card.s
                    height: width

                    Icon {
                        anchors.centerIn: parent
                        name: "x-circle"
                        size: 13 * card.s
                        opacity: (hover.hovered || card.selected || closeArea.containsMouse) ? 1 : 0.55
                        color: closeArea.containsMouse ? Theme.fg : Theme.fgVariant
                    }
                    MouseArea {
                        id: closeArea
                        Accessible.role: Accessible.Button
                        Accessible.name: "Dismiss"
                        Accessible.onPressAction: card.dismissed()
                        anchors.fill: parent
                        anchors.margins: -5 * card.s
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: card.dismissed()
                    }
                }
            }
        }

        // ---- cuerpo: texto y, si la hay, la imagen ----
        Item {
            width: parent.width
            height: Math.max(textCol.implicitHeight, thumb.shown ? thumb.height : 0)

            Column {
                id: textCol
                width: parent.width - (thumb.shown ? thumb.width + 10 * card.s : 0)
                spacing: 2 * card.s

                Text {
                    width: parent.width
                    visible: text.length > 0
                    text: card.src ? card.src.summary : ""
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    color: Theme.fg
                    font.family: Typography.ui
                    font.pixelSize: (card.popup ? Typography.body : Typography.title) * card.s
                    font.weight: Font.DemiBold
                }

                Text {
                    id: body
                    width: parent.width
                    visible: text.length > 0
                    text: Notifs.bodyText(card.src)
                    textFormat: Text.StyledText
                    wrapMode: Text.Wrap
                    maximumLineCount: card.popup ? 3 : (card.selected ? 8 : 2)
                    elide: Text.ElideRight
                    color: Theme.fgVariant
                    linkColor: Theme.primary
                    font.family: Typography.ui
                    font.pixelSize: (card.popup ? Typography.label : Typography.body) * card.s
                }
            }

            /**
             * La miniatura: proporción respetada dentro de `thumbMax`. Sólo ocupa
             * sitio cuando la imagen cargó (una ruta perdida tras reiniciar no deja
             * ni hueco ni icono roto).
             */
            Item {
                id: thumb
                readonly property bool shown: card.imageSrc.length > 0 && thumbImg.status === Image.Ready
                anchors.right: parent.right
                y: 2 * card.s
                width: card.thumbMax
                height: shown ? Math.max(1, Math.min(card.thumbMax, thumbImg.paintedHeight)) : 0
                visible: shown

                Rectangle {
                    anchors.centerIn: thumbImg
                    width: thumbImg.paintedWidth + 2
                    height: thumbImg.paintedHeight + 2
                    radius: Metrics.rXs * card.s
                    color: "transparent"
                    border.width: 1
                    border.color: Theme.glassBorder
                }
                Image {
                    id: thumbImg
                    width: card.thumbMax
                    height: card.thumbMax
                    anchors.top: parent.top
                    source: card.imageSrc
                    sourceSize.width: 2 * card.thumbMax
                    sourceSize.height: 2 * card.thumbMax
                    asynchronous: true
                    fillMode: Image.PreserveAspectFit
                    verticalAlignment: Image.AlignTop
                    mipmap: true
                }
            }
        }

        // ---- acciones de una viva ----
        Flow {
            width: parent.width
            visible: !card.replying && !card.gone && (card.actionList.length > 0 || card.canReply)
            topPadding: 2 * card.s
            spacing: 4 * card.s

            ActionButton {
                visible: card.canReply
                width: Math.min(implicitWidth, parent.width)
                s: card.s
                glyph: "chevron-right"
                // «Draft» al volver (DESIGN §2): hay una respuesta a medias guardada.
                label: card.draft.length > 0 ? "Reply · draft" : "Reply"
                primary: card.actionList.length === 0
                onTriggered: card.replyClicked()
            }
            Repeater {
                model: card.actionList
                ActionButton {
                    required property var modelData
                    required property int index
                    s: card.s
                    width: Math.min(implicitWidth, parent.width)
                    label: modelData ? modelData.text : ""
                    primary: index === 0 && !card.canReply
                    onTriggered: card.actionInvoked(modelData.identifier)
                }
            }
        }

        // ---- respuesta en línea (centro): lo que se escribe va a la app ----
        Item {
            visible: card.replying && !card.gone
            width: parent.width
            height: 30 * card.s

            Rectangle {
                anchors.left: parent.left
                anchors.right: discardBtn.visible ? discardBtn.left : sendBtn.left
                anchors.rightMargin: 6 * card.s
                anchors.verticalCenter: parent.verticalCenter
                height: 28 * card.s
                radius: Metrics.r(9) * card.s
                color: Theme.tileBg
                border.width: 1
                border.color: Qt.alpha(Theme.primary, 0.45)

                SearchField {
                    id: field
                    anchors.fill: parent
                    anchors.leftMargin: 10 * card.s
                    anchors.rightMargin: 10 * card.s
                    s: card.s
                    placeholder: card.notif && String(card.notif.inlineReplyPlaceholder || "").length > 0
                        ? card.notif.inlineReplyPlaceholder : "Reply"
                    onTextChanged: if (card.replying && card.draftKey.length > 0) Drafts.set(card.draftKey, field.text)
                    onAccepted: if (field.text.length > 0) card.replySent(field.text)
                    onDismissed: card.replyClosed()
                }
            }
            /** Tirar el borrador: vacía el campo, y con él lo guardado. */
            ActionButton {
                id: discardBtn
                anchors.right: sendBtn.left
                anchors.rightMargin: 4 * card.s
                anchors.verticalCenter: parent.verticalCenter
                visible: field.text.length > 0
                s: card.s
                label: "Discard draft"
                onTriggered: { field.clear(); Drafts.discard(card.draftKey); field.focusField(); }
            }
            ActionButton {
                id: sendBtn
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                s: card.s
                label: "Send"
                primary: true
                enabled: field.text.length > 0
                onTriggered: card.replySent(field.text)
            }
        }

        // ---- borrador huérfano: la notificación desapareció (DESIGN §2) ----
        Column {
            visible: card.gone
            width: parent.width
            spacing: 4 * card.s

            Text {
                width: parent.width
                text: "Reply no longer available — the app closed this notification."
                wrapMode: Text.Wrap
                color: Theme.fgVariant
                font.family: Typography.ui
                font.pixelSize: Typography.caption * card.s
            }
            Rectangle {
                width: parent.width
                height: draftText.implicitHeight + 12 * card.s
                radius: Metrics.r(9) * card.s
                color: Theme.tileBg
                border.width: 1
                border.color: Theme.glassBorder
                Text {
                    id: draftText
                    x: 10 * card.s
                    y: 6 * card.s
                    width: parent.width - 20 * card.s
                    text: card.draft
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    maximumLineCount: 4
                    elide: Text.ElideRight
                    color: Theme.fg
                    font.family: Typography.ui
                    font.pixelSize: Typography.label * card.s
                }
            }
            Row {
                spacing: 4 * card.s
                ActionButton {
                    s: card.s
                    label: "Copy draft"
                    onTriggered: Quickshell.clipboardText = card.draft
                }
                ActionButton {
                    s: card.s
                    label: "Discard draft"
                    onTriggered: Drafts.discard(card.draftKey)
                }
                ActionButton {
                    s: card.s
                    label: "Send"
                    enabled: false
                }
            }
        }
    }

    // --- para el anfitrión ----------------------------------------------------------

    function ago(t) { return Clock.ago(t, "compact", card.now); }

    /** Abre el campo con el borrador guardado, si lo hay, y le da el foco. */
    function focusReply() {
        if (field.text.length === 0 && card.draft.length > 0)
            field.text = card.draft;
        field.focusField();
    }
    /** Tras enviar: campo vacío y borrador fuera. */
    function replyDone() {
        field.clear();
        Drafts.discard(card.draftKey);
    }

    onReplyingChanged: if (card.replying) Qt.callLater(card.focusReply)
    Component.onCompleted: if (card.replying) Qt.callLater(card.focusReply)
}
