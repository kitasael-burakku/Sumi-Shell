pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "../theme"
import "../services"
import "../components"

/**
 * El centro de notificaciones (ADR-29; Fase 2 de docs/FASE9/NOTIFICACIONES.md).
 *
 * Decisiones del usuario (§7 y §12): el centro ES el historial (descartar lo
 * borra del archivo); grupos por app plegados con la mas reciente y el numero,
 * las criticas sueltas y arriba; No molestar y «Clear all» en la cabecera; las
 * respuestas en linea se escriben aqui (el «Reply» de un popup abre esto con el
 * campo enfocado).
 *
 * Teclado:
 *   ↑ ↓          moverse                 ⏎        abrir (accion `default` o la ventana de la app)
 *   → ←          Show more / less        Tab      responder (si la notificacion lo admite)
 *   Supr ⌫       descartar la fila       ⇧Supr    Clear all
 *   Ctrl+D       No molestar             Esc      cierra (o sale del campo de respuesta)
 *
 * Datos y acciones: `services/NotifHistory` (filas, entradas, DND, no leidas) y
 * `services/Notifs` (lo vivo: acciones, respuesta, enfocar la app). Todo lo que
 * se pinta es dato ajeno y lo pinta `components/NotifCard`, la misma tarjeta que el
 * popup (fase 7A del rediseño).
 *
 * Fase 7A: cada app con varias entradas enseña la más nueva y una fila «more»
 * (Show more / Show less, total y pendientes). La selección se guarda por CLAVE de
 * fila, no por índice: una llegada nueva inserta filas arriba y no mueve el
 * objetivo del teclado; lo seleccionado y lo que se responde quedan retenidos
 * (`NotifHistory.hold`) y no se pliegan aunque otra más nueva encabece el grupo.
 *
 * Fase 7B:
 *   · LEÍDA POR PERMANENCIA: una tarjeta pasa a leída cuando lleva `dwellMs` a la
 *     vista (al menos el 60 % de ella dentro de la lista) con el centro FIJADO,
 *     terminado de abrir y sin la confirmación encima. La vista previa por hover,
 *     un grupo plegado y lo que queda fuera del viewport no marcan.
 *   · CLEAR ALL CONFIRMADO: el botón, ⇧Supr y el clic central del island piden
 *     «Clear N notifications?» con Cancel por defecto; la pregunta captura las
 *     claves de ESE momento y sólo borra ésas (`NotifHistory.clearSet`). Cerrar el
 *     centro la cancela. Con la pregunta abierta: ← → Tab cambian de botón, ⏎/Espacio
 *     lo pulsan, Esc cancela.
 *   · TRANSITORIOS VIVOS arriba, marcados «temporary»: se alcanzan por teclado,
 *     no se guardan y desaparecen al caducar.
 *
 * ALTURA FIJA Y ANCLAJES, sin `Column` alrededor de la lista (leccion de 9.f.2),
 * y la lista es un `ListModel` reconciliado: llegan filas en vivo y no puede
 * volver arriba en cada una. Las `Image` solo existen en las filas que el
 * `ListView` tiene construidas (ADR-14).
 */
Surface {
    id: root

    mTop: 12
    mLeft: 14
    mRight: 14
    mBottom: 12

    readonly property bool serverOn: Notifs.enabled
    readonly property int rowCount: NotifHistory.rows.count

    /**
     * El alto que pide (paneles que se adaptan, 2026-11-17, decisión del autor: «sólo vacío»): compacto con el aviso de
     * vacío (o con el servidor apagado); con avisos, el alto de siempre. Las tarjetas miden distinto (cuerpo, acciones,
     * respuesta, «Show more») y medirlas sería un destino que sale del maquetado (9.f.2). El host lo acota a
     * `Metrics.notifCenterH`; un aviso que llega con el panel abierto lo hace crecer en el sitio.
     */
    readonly property real fitH: (root.serverOn && root.rowCount > 0) ? Metrics.notifCenterH * root.s
        : (root.mTop + root.mBottom) * root.s + header.height + body.anchors.topMargin
          + notifEmpty.implicitHeight + 2 * Metrics.sp5 * root.s
    /** La fila seleccionada, por su clave estable (`e:<clave>` o `m:<grupo>`). */
    property string selKey: ""
    readonly property int sel: {
        void NotifHistory.rowsRev;
        const i = root.indexOfRow(root.selKey);
        return i >= 0 ? i : 0;
    }
    /** La entrada con el campo de respuesta abierto ("" = ninguna). */
    property string replyKey: ""
    /** Reloj de los tiempos relativos; solo corre con el centro abierto. */
    property real now: Date.now()

    Timer {
        interval: 30000
        repeat: true
        running: root.active
        onTriggered: root.now = Date.now()
    }

    /** Lo que el centro tiene entre manos no se pliega al llegar otra (NotifHistory.hold). */
    readonly property var holdKeys: {
        const out = [];
        if (!root.active) return out;
        if (root.selKey.startsWith("e:")) out.push(root.selKey.substring(2));
        if (root.replyKey.length > 0 && out.indexOf(root.replyKey) < 0) out.push(root.replyKey);
        return out;
    }
    onHoldKeysChanged: NotifHistory.setHold(root.holdKeys)

    /**
     * Leer por permanencia (7B). Fase 4C: una vista previa por hover NO marca nada
     * (DESIGN §2); tampoco el panel mientras se despliega (`settled`) ni con la
     * confirmación encima.
     */
    readonly property int dwellMs: 1000
    readonly property bool readArmed: root.active && root.engaged && (Motion.off || root.settled) && !root.confirming

    /** Clear all: las claves capturadas al preguntar (null = sin pregunta). */
    property var confirmKeys: null
    readonly property bool confirming: root.confirmKeys !== null
    /** 0 = Cancel (el foco inicial, la acción segura), 1 = Clear. */
    property int confirmFocus: 0

    function askClearAll() { return root.askClear(NotifHistory.keys()); }
    /** La pregunta sobre un conjunto dado (el IPC de prueba lo acota a avisos kt-…). */
    function askClear(keys) {
        if (!keys || keys.length === 0) return false;
        root.replyKey = "";
        root.confirmFocus = 0;
        root.confirmKeys = keys;
        return true;
    }
    function answerClear(clear) {
        const keys = root.confirmKeys;
        root.confirmKeys = null;
        if (clear && keys) NotifHistory.clearSet(keys);
        root.forceActiveFocus();
    }

    /**
     * Clic central en el island o en la campana de la barra: la pregunta, en cuanto el centro está fijado.
     * Se toma fuera del enlace (ADR-42): con el panel ya abierto (la vista previa de la barra), bajar `clearWanted`
     * dentro de su propio cambio era un «Binding loop» de `clearWantedHere`.
     */
    readonly property bool clearWantedHere: NotifHistory.clearWanted && root.active && root.engaged
    onClearWantedHereChanged: if (root.clearWantedHere) Qt.callLater(root.takeClearWanted)
    function takeClearWanted() {
        if (!root.clearWantedHere) return;
        NotifHistory.clearWanted = false;
        root.askClearAll();
    }

    onActiveChanged: {
        if (!root.active) {
            root.replyKey = "";
            root.confirmKeys = null;   // cerrar cancela, no borra
            return;
        }
        root.now = Date.now();
        const target = NotifHistory.replyTarget;
        NotifHistory.replyTarget = "";
        root.selKey = root.rowCount > 0 ? NotifHistory.rows.get(0).rkey : "";
        if (target.length > 0)
            Qt.callLater(function () { root.openReply(target); });
        // 7E-2: llegar desde el Centro de control con una entrada que localizar.
        const loc = NotifHistory.locateTarget;
        NotifHistory.locateTarget = "";
        if (loc.length > 0 && NotifHistory.entry(loc))
            Qt.callLater(function () { root.locate(loc); });
    }

    /** La seleccionada desapareció (descartada): la que ocupa ahora su sitio. */
    Connections {
        target: NotifHistory
        function onRowsRevChanged() {
            if (root.indexOfRow(root.selKey) < 0 && root.rowCount > 0)
                root.selKey = NotifHistory.rows.get(Math.min(root.lastSel, root.rowCount - 1)).rkey;
            else
                root.lastSel = root.sel;
        }
    }
    property int lastSel: 0

    function rowAt(i) { return (i >= 0 && i < NotifHistory.rows.count) ? NotifHistory.rows.get(i) : null; }

    function indexOfRow(rkey) {
        if (!rkey) return -1;
        for (let i = 0; i < NotifHistory.rows.count; i++)
            if (NotifHistory.rows.get(i).rkey === rkey)
                return i;
        return -1;
    }

    function selectIndex(i) {
        const r = root.rowAt(i);
        root.selKey = r ? r.rkey : "";
        root.lastSel = Math.max(0, i);
    }

    function move(delta) {
        if (root.rowCount === 0 || !list) return;
        root.selectIndex(Math.max(0, Math.min(root.rowCount - 1, root.sel + delta)));
        list.positionViewAtIndex(root.sel, ListView.Contain);
    }

    /** Abre el campo de respuesta de una entrada, desplegando su grupo si hace falta. */
    function openReply(key) {
        const e = NotifHistory.entry(key);
        if (!e || !list) return;
        root.selKey = "e:" + key;   // retenida: se ve aunque el grupo siga plegado
        root.replyKey = NotifHistory.isLive(key) ? key : "";
        Qt.callLater(function () {
            const i = root.indexOfRow("e:" + key);
            if (i >= 0) list.positionViewAtIndex(i, ListView.Contain);
        });
    }

    /** Selecciona una entrada (retenida: se ve aunque su grupo esté plegado) y la trae a la vista. */
    function locate(key) {
        if (!list || !NotifHistory.entry(key)) return false;
        root.selKey = "e:" + key;
        Qt.callLater(function () {
            const i = root.indexOfRow("e:" + key);
            if (i >= 0) list.positionViewAtIndex(i, ListView.Contain);
        });
        return true;
    }

    function closeReply() {
        root.replyKey = "";
        root.forceActiveFocus();
    }

    /**
     * Abrir necesita cerrar el centro PRIMERO: con esta capa teniendo el foco de
     * teclado, enfocar otra ventana no gana (lo mismo que el minimizador, 10.b).
     * Si no hay a donde ir (restaurada sin ventana), no se cierra por nada.
     */
    property string pendingKey: ""
    function activateKey(key) {
        if (!Notifs.hasTarget(NotifHistory.entry(key)))
            return;
        root.pendingKey = key;
        root.requestClose();
        actTimer.restart();
    }
    Timer {
        id: actTimer
        interval: 130
        onTriggered: {
            const k = root.pendingKey;
            root.pendingKey = "";
            if (k.length > 0) NotifHistory.activate(k);
            const nid = root.pendingNid;
            root.pendingNid = -1;
            if (nid >= 0) Notifs.activate(Notifs.find(nid));
        }
    }

    function dismissRow(r) {
        if (!r) return;
        if (r.kind === "more") NotifHistory.dismissGroup(r.key);
        else if (r.kind === "transient") Notifs.dismiss(Notifs.find(Number(r.key)));
        else NotifHistory.dismiss(r.key);
    }

    /** Un transitorio vivo: como `activateKey`, cerrar primero y luego su acción. */
    property int pendingNid: -1
    function activateTransient(nid) {
        const n = Notifs.find(nid);
        if (!n) return;
        root.pendingNid = nid;
        root.requestClose();
        actTimer.restart();
    }

    function toggleMore(gkey, on) {
        NotifHistory.setExpanded(gkey, on);
    }

    function keyPressed(e) {
        if (!root.serverOn)
            return;
        const ctrl = (e.modifiers & Qt.ControlModifier) !== 0;
        const shift = (e.modifiers & Qt.ShiftModifier) !== 0;
        const r = root.rowAt(root.sel);
        if (root.confirming) {
            // La pregunta se queda el teclado entero: nada llega a la lista por debajo.
            if (e.key === Qt.Key_Escape) root.answerClear(false);
            else if (e.key === Qt.Key_Left || e.key === Qt.Key_Right || e.key === Qt.Key_Tab || e.key === Qt.Key_Backtab)
                root.confirmFocus = 1 - root.confirmFocus;
            else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space)
                root.answerClear(root.confirmFocus === 1);
            e.accepted = true;
            return;
        }
        if (e.key === Qt.Key_Escape && root.replyKey.length > 0) {
            root.closeReply();
            e.accepted = true;
        } else if (e.key === Qt.Key_Down) {
            root.move(1); e.accepted = true;
        } else if (e.key === Qt.Key_Up) {
            root.move(-1); e.accepted = true;
        } else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
            if (r && r.kind === "more") root.toggleMore(r.key, NotifHistory.expanded[r.key] !== true);
            else if (r && r.kind === "transient") root.activateTransient(Number(r.key));
            else if (r) root.activateKey(r.key);
            e.accepted = true;
        } else if (e.key === Qt.Key_Right) {
            if (r && r.kind === "more") root.toggleMore(r.key, true);
            e.accepted = true;
        } else if (e.key === Qt.Key_Left) {
            if (r && r.kind === "more") {
                root.toggleMore(r.key, false);
            } else if (r && r.depth === 1) {
                const g = NotifHistory.groupKeyOf(NotifHistory.entry(r.key));
                root.selKey = "m:" + g;
                root.toggleMore(g, false);
            }
            e.accepted = true;
        } else if (e.key === Qt.Key_Delete || e.key === Qt.Key_Backspace) {
            if (shift) root.askClearAll();
            else root.dismissRow(r);
            e.accepted = true;
        } else if (ctrl && e.key === Qt.Key_D) {
            NotifHistory.toggleDnd();
            e.accepted = true;
        } else if (e.key === Qt.Key_Tab) {
            if (r && r.kind === "entry") root.openReply(r.key);
            e.accepted = true;
        }
    }

    // ---- cabecera -----------------------------------------------------------------

    Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: (root.serverOn ? 82 : 36) * root.s

        Text {
            anchors.left: parent.left; anchors.right: countLabel.left
            anchors.rightMargin: 12 * root.s
            text: "Notifications"; color: Theme.fg
            font.family: Typography.ui; font.pixelSize: Typography.display * root.s
            font.weight: Typography.wStrong; elide: Text.ElideRight
        }
        Text {
            id: countLabel
            anchors.right: parent.right; y: 5 * root.s
            width: Math.min(implicitWidth, 150 * root.s)
            text: NotifHistory.unread > 0 ? NotifHistory.unread + " unread"
                : NotifHistory.count > 0 ? NotifHistory.count + " saved" : ""
            color: Theme.fgVariant; elide: Text.ElideRight
            font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
        }
        Item {
            id: headerCtrls
            anchors.left: parent.left; anchors.right: parent.right
            anchors.bottom: parent.bottom; anchors.bottomMargin: 8 * root.s
            height: 34 * root.s; visible: root.serverOn
            Row {
                anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                spacing: 8 * root.s
                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: NotifHistory.dnd ? "bell-off" : "bell"
                    size: 16 * root.s
                    color: NotifHistory.dnd ? Theme.primary : Theme.fgVariant
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Do not disturb"; color: Theme.fgVariant
                    font.family: Typography.ui; font.pixelSize: Typography.body * root.s
                }
                Toggle {
                    anchors.verticalCenter: parent.verticalCenter
                    s: root.s; on: NotifHistory.dnd
                    onToggled: NotifHistory.toggleDnd()
                }
            }
            ActionButton {
                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                height: 34 * root.s
                s: root.s; label: "Clear all"
                enabled: NotifHistory.count > 0 && !root.confirming
                danger: NotifHistory.count > 0
                onTriggered: root.askClearAll()
            }
        }
        Rectangle {
            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
            height: 1; color: Qt.alpha(Theme.outline, 0.25)
        }
    }

    // ---- estados sin lista ----------------------------------------------------------

    Empty {
        id: notifEmpty
        anchors.centerIn: body
        visible: !root.serverOn || root.rowCount === 0
        s: root.s
        maxWidth: body.width - 40 * root.s
        glyph: root.serverOn ? "bell" : "bell-off"
        text: root.serverOn ? "No notifications" : "The shell notification server is off"
        hint: root.serverOn ? "You are all caught up" : "Turn it on in Settings"
    }

    // ---- la lista -----------------------------------------------------------------------

    Item {
        id: body
        anchors.top: header.bottom
        anchors.topMargin: 8 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
    }

    ListView {
        id: list
        anchors.fill: body
        visible: root.serverOn && root.rowCount > 0
        clip: true
        spacing: 8 * root.s
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: 120 * root.s
        add: Transition {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Motion.page; easing.type: Easing.OutCubic }
        }
        displaced: Transition {
            NumberAnimation { properties: "y"; duration: Motion.still ? 0 : Motion.page; easing.type: Easing.OutCubic }
        }
        model: root.serverOn ? NotifHistory.rows : null

        delegate: Item {
            id: row

            required property int index
            required property string kind
            required property string key
            required property int depth

            readonly property bool selected: root.sel === row.index
            readonly property real indent: row.kind === "more" ? 22 * root.s : row.depth * 22 * root.s

            /** A la vista: al menos el 60 % de la fila dentro del viewport de la lista. */
            readonly property bool inView: {
                const view = row.ListView.view;
                if (!view || row.height <= 0) return false;
                const top = row.y - view.contentY;
                const shown = Math.min(top + row.height, view.height) - Math.max(top, 0);
                return shown >= 0.6 * Math.min(row.height, view.height);
            }
            readonly property bool unread: { void NotifHistory.revision; return row.kind === "entry" && NotifHistory.isUnread(NotifHistory.entry(row.key)); }
            // Permanencia: se reinicia si sale de la vista o se desarma antes de tiempo.
            Timer {
                running: row.unread && row.inView && root.readArmed
                interval: root.dwellMs
                onTriggered: NotifHistory.markRead(row.key)
            }
            width: ListView.view ? ListView.view.width : 0
            height: loader.item ? loader.item.implicitHeight : 0

            Loader {
                id: loader
                x: row.indent
                width: parent.width - row.indent
                sourceComponent: row.kind === "more" ? moreRow : (row.kind === "transient" ? transientRow : entryRow)
            }

            // ---- una notificación: la tarjeta compartida ----
            Component {
                id: entryRow

                NotifCard {
                    id: card
                    readonly property var e: { void NotifHistory.revision; return NotifHistory.entry(row.key); }
                    s: root.s
                    mode: "center"
                    entry: card.e
                    notif: { void NotifHistory.revision; void Notifs.tracked; return NotifHistory.liveOf(card.e); }
                    selected: row.selected
                    unread: row.unread
                    replying: root.replyKey === row.key && card.canReply
                    now: root.now

                    onActivated: (link) => {
                        root.selKey = "e:" + row.key;
                        if (link.length > 0) Notifs.openLink(link);
                        else root.activateKey(row.key);
                    }
                    onDismissed: NotifHistory.dismiss(row.key)
                    onActionInvoked: (identifier) => Notifs.invokeAction(card.notif, identifier)
                    onReplyClicked: { root.selKey = "e:" + row.key; root.replyKey = row.key; }
                    onReplySent: (text) => {
                        if (NotifHistory.reply(row.key, text)) {
                            card.replyDone();
                            root.replyKey = "";
                        }
                    }
                    onReplyClosed: root.closeReply()
                }
            }

            // ---- un transitorio vivo: no se guarda, se va al caducar ----
            Component {
                id: transientRow

                NotifCard {
                    id: tcard
                    s: root.s
                    mode: "center"
                    notif: { void Notifs.tracked; return Notifs.find(Number(row.key)); }
                    selected: row.selected
                    note: "temporary"
                    allowReply: false
                    onActivated: (link) => {
                        root.selKey = "t:" + row.key;
                        if (link.length > 0) Notifs.openLink(link);
                        else root.activateTransient(Number(row.key));
                    }
                    onDismissed: Notifs.dismiss(tcard.notif)
                    onActionInvoked: (identifier) => Notifs.invokeAction(tcard.notif, identifier)
                }
            }

            // ---- el pie de un grupo: Show more / Show less ----
            Component {
                id: moreRow

                Item {
                    id: mr
                    readonly property int total: { void NotifHistory.revision; return NotifHistory.groupEntries(row.key).length; }
                    readonly property int pending: { void NotifHistory.revision; return NotifHistory.unreadIn(row.key); }
                    readonly property bool unfolded: NotifHistory.expanded[row.key] === true

                    implicitHeight: 40 * root.s

                    HoverHandler { id: mHover }

                    Rectangle {
                        anchors.fill: parent
                        radius: Metrics.rSm * root.s
                        color: row.selected ? Qt.alpha(Theme.primary, 0.10) : (mHover.hovered ? Theme.tileBg : "transparent")
                        border.width: row.selected ? Metrics.focusWidth : 0
                        border.color: Qt.alpha(Theme.primary, 0.65)
                    }


                    Accessible.role: Accessible.Button
                    Accessible.name: mr.unfolded ? "Show less" : ("Show " + (mr.total - 1) + " more")
                    Accessible.description: mr.pending > 0 ? mr.pending + " unread" : ""
                    Accessible.onPressAction: { root.selKey = "m:" + row.key; root.toggleMore(row.key, !mr.unfolded); }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            root.selKey = "m:" + row.key;
                            root.toggleMore(row.key, !mr.unfolded);
                        }
                    }

                    Row {
                        x: 10 * root.s
                        width: Math.max(0, (groupClear.visible ? groupClear.x : parent.width) - x - 8 * root.s)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6 * root.s

                        Icon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: mr.unfolded ? "chevron-down" : "chevron-right"
                            size: 12 * root.s
                            color: Theme.fgVariant
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.max(0, parent.width - 18 * root.s); elide: Text.ElideRight
                            text: (mr.unfolded ? "Show less" : "Show " + (mr.total - 1) + " more")
                                  + "  ·  " + mr.total + " total"
                                  + (mr.pending > 0 ? "  ·  " + mr.pending + " unread" : "")
                            color: Theme.fgVariant
                            font.family: Typography.ui
                            font.pixelSize: Typography.caption * root.s
                            font.weight: Font.Medium
                        }
                    }

                    // Cerrar el grupo dice su alcance (spec: «un cierre de grupo identifica su alcance»).
                    ActionButton {
                        id: groupClear
                        height: 32 * root.s
                        anchors.right: parent.right
                        anchors.rightMargin: 4 * root.s
                        anchors.verticalCenter: parent.verticalCenter
                        visible: mHover.hovered || row.selected
                        s: root.s
                        label: "Clear " + mr.total
                        onTriggered: NotifHistory.dismissGroup(row.key)
                    }
                }
            }
        }
    }

    // ---- Clear all: la confirmación (DESIGN §7) ----------------------------------------

    /** Cubre la lista: un clic fuera de la tarjeta cancela; mientras está, nada se marca leído. */
    Item {
        id: confirmLayer
        anchors.fill: body
        property real reveal: root.confirming ? 1 : 0
        visible: root.confirming || reveal > 0
        enabled: root.confirming
        opacity: reveal
        Behavior on reveal { NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic } }
        z: 10

        Rectangle {
            anchors.fill: parent
            radius: Metrics.rMd * root.s
            color: Qt.alpha(Theme.surfaceContainerLowest, 0.82)
        }
        MouseArea {
            anchors.fill: parent
            onClicked: root.answerClear(false)
        }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(parent.width - 24 * root.s, 360 * root.s)
            height: confirmCol.implicitHeight + 28 * root.s
            radius: Metrics.rMd * root.s
            color: Theme.surfaceContainer
            border.width: 1
            border.color: Theme.glassBorder

            // Tragarse el clic dentro de la tarjeta (el de fuera cancela).
            MouseArea { anchors.fill: parent }

            Column {
                id: confirmCol
                x: 14 * root.s
                y: 14 * root.s
                width: parent.width - 28 * root.s
                spacing: 12 * root.s

                Text {
                    width: parent.width
                    readonly property int n: root.confirmKeys ? root.confirmKeys.length : 0
                    text: "Clear " + n + (n === 1 ? " notification?" : " notifications?")
                    wrapMode: Text.Wrap
                    color: Theme.fg
                    font.family: Typography.ui
                    font.pixelSize: Typography.title * root.s
                    font.weight: Font.DemiBold
                }
                Text {
                    width: parent.width
                    text: "Notifications that arrive after this stay. This cannot be undone."
                    wrapMode: Text.Wrap
                    color: Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.label * root.s
                }
                Row {
                    anchors.right: parent.right
                    topPadding: 4 * root.s
                    spacing: 6 * root.s
                    ActionButton {
                        s: root.s
                        label: "Cancel"
                        focused: root.confirmFocus === 0
                        onTriggered: root.answerClear(false)
                    }
                    ActionButton {
                        s: root.s
                        label: "Clear"
                        danger: true
                        focused: root.confirmFocus === 1
                        onTriggered: root.answerClear(true)
                    }
                }
            }
        }
    }

    /**
     * La barra de desplazamiento (2026-09-15). Hermana de la lista, no hija:
     * un hijo de un `ListView` viaja dentro del contenido y se iria con el scroll.
     */
    ScrollHint { view: list; s: root.s }

}
