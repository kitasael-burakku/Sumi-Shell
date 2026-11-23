pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../services"
import "../components"
import "../lib/fuzzy.js" as Fuzzy

/**
 * Clipboard history (Fase 9.g), over `cliphist`.
 *
 * Replaces the one-line pipe in `hypr/modules/programs.lua`
 * (`cliphist list | rofi -dmenu | cliphist decode | wl-copy`). That pipe stays
 * on SUPER+SHIFT+V as the safety net (ADR-18); what this adds is the one thing
 * it could never do -- **image thumbnails**. In rofi an image reads as the text
 * `[[ binary data 1 MiB png 1920x1080 ]]`.
 *
 * ADR-14 IS THE HARD RULE HERE. An `Image` with a `source` decodes whether or
 * not it is visible: binding all of them cost +153 MB for 79 wallpaper thumbs.
 * So the source hangs off **distance to the visible window**, never `visible`,
 * exactly as `surfaces/Wallpaper.qml` does it.
 *
 * Fixed height and anchors, no `Column` wrapping the list: the history is
 * unbounded (750 entries max) so it scrolls, and a moving target under the
 * morph is what froze the shell in 9.f.2.
 */
Surface {
    id: root

    mTop: 12
    mLeft: 14
    mRight: 14
    mBottom: 12

    property string query: ""
    property int selected: 0
    /**
     * Rediseño, fase 5B: la entrada elegida POR ID. Una copia nueva que llega con el panel
     * abierto entra arriba y desplaza la lista: con sólo el índice, Enter pasaba a pegar
     * otra cosa. `selected` se recoloca sobre este id (futureclipboard §«Feedback»).
     */
    property string selId: ""
    /**
     * Pegado en vuelo: la revisión de ESTE pegado en `Clip.ops` (6C), 0 si
     * ninguno; y, si falló, el motivo (Could not copy item / Item no longer available).
     */
    property int pendingRev: 0
    property string pasteError: ""

    readonly property real rowH: 44 * root.s

    /**
     * With no query the order is **recency**, which is how `cliphist list`
     * already comes; `fuzzy.rank` would sort alphabetically and throw away the
     * only ordering a clipboard has.
     */
    readonly property var results: root.query.trim().length === 0
        ? Clip.entries
        : Fuzzy.rank(Clip.entries, root.query, {})
    readonly property int count: root.results.length

    /**
     * El alto que pide (paneles que se adaptan, 2026-11-17): filas de `rowH` contadas en los datos (nunca el maquetado
     * de la lista, 9.f.2), el aviso de vacío o el de un pegado fallido. El host lo acota a `Metrics.clipH`.
     */
    readonly property real fitH: {
        const s = root.s;
        const listH = root.count > 0 ? Math.min(root.count, 1 + Math.ceil(Metrics.clipH * s / root.rowH)) * root.rowH
            : clipEmpty.implicitHeight + 2 * Metrics.sp5 * s;
        return (root.mTop + root.mBottom) * s + header.height + hair.anchors.topMargin + hair.height
            + list.anchors.topMargin + listH + (failure.visible ? failure.height + 6 * s : 0);
    }

    /**
     * La clave lleva el monitor y no se reclama mientras este vacio: mismo
     * razonamiento que en `Wifi.qml` (QS-FUNC-003).
     */
    readonly property string claimKey: root.screenName.length > 0 ? "clipboard@" + root.screenName : ""
    Claim { target: Clip; key: root.claimKey; value: root.active }

    onActiveChanged: {
        if (root.active) {
            root.query = "";
            search.clear();
            root.selected = 0;
            root.selId = "";
            root.pendingRev = 0;
            root.pasteError = "";
            Qt.callLater(root.reconcile);   // fija por id la primera fila desde el principio
            // En vista previa por hover el buscador no toma el foco (fase 4C): al fijarla sí.
            if (root.engaged) Qt.callLater(search.focusField);
        }
    }
    onEngagedChanged: if (root.active && root.engaged) Qt.callLater(search.focusField)

    onSelectedChanged: {
        const e = root.results[root.selected];
        if (e) root.selId = e.id;
    }

    /** Tras un cambio del historial o del filtro: volver a la entrada elegida, por id. */
    function reconcile() {
        if (root.count === 0) { root.selected = 0; return; }
        let i = root.selId.length > 0 ? root.results.findIndex(function (e) { return e.id === root.selId; }) : -1;
        if (i < 0) i = Math.max(0, Math.min(root.selected, root.count - 1));
        root.selected = i;
        root.selId = root.results[i].id;   // fijado: la próxima copia ya no la mueve
    }
    // Un paso del bucle después (lección de la 5A: dentro del aviso, `results` aún es el viejo).
    onCountChanged: Qt.callLater(root.reconcile)
    Connections {
        target: Clip
        function onEntriesChanged() { Qt.callLater(root.reconcile); }
    }
    Connections {
        target: Clip.ops
        function onSettled(key, rev, state, reason) {
            if (key === "paste" && rev === root.pendingRev) root.pasteDone(state, reason);
        }
    }

    function pasteDone(state, reason) {
        root.pendingRev = 0;
        if (state === "ok") root.requestClose();
        else root.pasteError = reason === "Item no longer available" ? reason : "Could not copy item";
    }

    function move(delta) {
        if (root.count === 0) return;
        root.selected = Math.max(0, Math.min(root.count - 1, root.selected + delta));
        list.positionViewAtIndex(root.selected, ListView.Contain);
    }

    /** Pegar: se cierra cuando `Clip` confirma; si falla, la consulta y la fila se quedan. */
    function activate() {
        const e = root.results[root.selected];
        if (!e || root.pendingRev > 0) return;
        root.pasteError = "";
        const r = Clip.paste(e.id, e.image);
        if (r === 0) return;   // rechazado (otro pegado en vuelo): no hay nada que esperar
        const o = Clip.ops.get("paste");
        // «Item no longer available» se resuelve dentro de la llamada.
        if (o.rev === r && o.state !== "pending") root.pasteDone(o.state, o.reason);
        else root.pendingRev = r;
    }

    /** The field owns the keyboard while open; the host only sees what it declines. */
    function keyPressed(event) {}

    // ---- historial (fase 4): la consulta y el ID; nunca el contenido del portapapeles ----
    function saveContext() { return { query: root.query, selId: root.selId }; }
    function restoreContext(ctx) {
        if (!ctx) return true;
        search.text = ctx.query || "";
        if (!ctx.selId) return true;
        const i = root.results.findIndex(function (e) { return e.id === ctx.selId; });
        if (i < 0) return false;
        root.selected = i;
        return true;
    }

    // ---- header --------------------------------------------------------------

    Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 24 * root.s

        Icon {
            id: searchIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            name: "search"
            size: 14 * root.s
            color: Theme.fgVariant
        }

        SearchField {
            id: search
            anchors.left: searchIcon.right
            anchors.leftMargin: 9 * root.s
            anchors.right: countLabel.left
            anchors.rightMargin: 10 * root.s
            anchors.verticalCenter: parent.verticalCenter
            height: parent.height
            s: root.s
            placeholder: "Search clipboard"
            // Escribir lleva a la primera coincidencia: se olvida la entrada elegida antes.
            onTextChanged: { root.query = search.text; root.selId = ""; root.selected = 0; root.pasteError = ""; }
            onMoved: (d) => root.move(d)
            onAccepted: root.activate()
            onDismissed: root.requestClose()
        }

        FrameNav {
            id: frameNav
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            s: root.s
            host: root.host
            onCloseRequested: root.requestClose()
        }

        Text {
            id: countLabel
            anchors.right: frameNav.left
            anchors.rightMargin: 8 * root.s
            anchors.verticalCenter: parent.verticalCenter
            text: Clip.loading ? "Loading…"
                : root.count + (Clip.imageCount > 0 ? "  ·  " + Clip.imageCount + " img" : "")
            color: Theme.outlineText
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
            font.features: ({ "tnum": 1 })
        }
    }

    Rectangle {
        id: hair
        anchors.top: header.bottom
        anchors.topMargin: 6 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: Theme.hair
    }

    // ---- the list ------------------------------------------------------------

    Empty {
        id: clipEmpty
        y: hair.y + hair.height + Math.max(Metrics.sp5 * root.s, (parent.height - hair.y - hair.height - height) * 0.42)
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.count === 0
        s: root.s
        maxWidth: parent.width
        loading: Clip.loading
        glyph: Clip.lastError.length > 0 ? "alert" : "clipboard"
        // Tres estados distintos: cliphist falló, historial vacío, y búsqueda sin resultados.
        text: Clip.loading ? "Reading history…"
            : Clip.whyNot.length > 0 ? "Clipboard history is unavailable"
            : Clip.lastError.length > 0 ? "Could not read the clipboard history"
            : root.query.length > 0 ? "No results" : "Clipboard is empty"
        hint: Clip.loading ? ""
            : Clip.lastError.length > 0 ? Clip.lastError
            : root.query.length > 0 ? "" : Clip.notice.length > 0 ? Clip.notice : "Copy something and it lands here"
    }

    ListView {
        id: list
        anchors.top: hair.bottom
        anchors.topMargin: 4 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: failure.visible ? failure.top : parent.bottom
        anchors.bottomMargin: failure.visible ? 6 * root.s : 0
        visible: root.count > 0
        clip: true
        model: root.results
        currentIndex: root.selected
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: 0

        delegate: Item {
            id: row
            required property int index
            required property var modelData

            width: list.width
            height: root.rowH

            readonly property bool current: row.index === root.selected

            // 16A-2
            Accessible.role: Accessible.ListItem
            Accessible.name: row.modelData.image
                ? ("Image " + row.modelData.w + "×" + row.modelData.h) : String(row.modelData.name || "")
            Accessible.selected: row.current
            Accessible.onPressAction: { root.selected = row.index; root.activate(); }

            /**
             * Distance in rows to the visible window. This -- and not
             * `visible` -- is what gates the thumbnail, because an `Image`
             * decodes a source it has been given even off screen (ADR-14).
             */
            readonly property int away: {
                const first = Math.floor(list.contentY / root.rowH);
                const last = first + Math.ceil(list.height / root.rowH);
                if (row.index < first) return first - row.index;
                if (row.index > last) return row.index - last;
                return 0;
            }
            readonly property bool near: row.away <= 2

            onNearChanged: if (row.near && row.modelData.image) Clip.wantThumb(row.modelData.id)
            Component.onCompleted: if (row.near && row.modelData.image) Clip.wantThumb(row.modelData.id)

            Rectangle {
                anchors.fill: parent
                anchors.topMargin: 1 * root.s
                anchors.bottomMargin: 1 * root.s
                radius: Metrics.r(8) * root.s
                // Elegida = celda (y marca, abajo); hover = fondo tenue, sin mover la elegida (DESIGN §3).
                color: row.current ? Theme.selBg : (rowArea.containsMouse ? Theme.hoverBg : "transparent")
                Behavior on color { ColorAnimation { duration: Motion.fast } }
            }

            // --- thumbnail, or a glyph for text ---
            Rectangle {
                id: shot
                anchors.left: parent.left
                anchors.leftMargin: 8 * root.s
                anchors.verticalCenter: parent.verticalCenter
                width: 52 * root.s
                height: 34 * root.s
                radius: Metrics.r(5) * root.s
                color: row.modelData.image ? Theme.insetBg : "transparent"
                border.width: row.modelData.image ? 1 : 0
                border.color: Theme.hair

                Image {
                    anchors.fill: parent
                    anchors.margins: 1
                    visible: row.modelData.image
                    // Only rows near the window get a source at all (ADR-14).
                    source: (row.modelData.image && row.near) ? Clip.thumbUrl(row.modelData.id) : ""
                    sourceSize.width: 160
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: false
                }

                Icon {
                    anchors.centerIn: parent
                    visible: !row.modelData.image
                    name: "clipboard"
                    size: 15 * root.s
                    color: row.current ? Theme.fgVariant : Theme.outline
                }
            }

            Text {
                id: label
                anchors.left: shot.right
                anchors.leftMargin: 10 * root.s
                anchors.right: meta.left
                anchors.rightMargin: 10 * root.s
                anchors.verticalCenter: parent.verticalCenter
                text: row.modelData.image
                    ? (row.modelData.kind.toUpperCase() + "  " + row.modelData.w + "×" + row.modelData.h)
                    : row.modelData.name
                elide: Text.ElideRight
                color: row.current ? Theme.fg : Theme.fgVariant
                font.family: row.modelData.image ? Typography.ui : Typography.mono
                font.pixelSize: Typography.label * root.s
            }

            Text {
                id: meta
                anchors.right: parent.right
                anchors.rightMargin: 10 * root.s
                anchors.verticalCenter: parent.verticalCenter
                text: row.modelData.image ? row.modelData.size : ""
                color: Theme.outlineText
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
            }

            MouseArea {
                id: rowArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.selected = row.index; root.activate(); }
            }
        }
    }

    /**
     * La barra de desplazamiento (2026-09-15). Hermana de la lista, no hija:
     * un hijo de un `ListView` viaja dentro del contenido y se iria con el scroll.
     */
    ScrollHint { view: list; s: root.s }

    /** Un pegado fallido: el motivo y Retry; la consulta y la fila siguen donde estaban. */
    Row {
        id: failure
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.pasteError.length > 0
        spacing: 6 * root.s
        Notice {
            width: parent.width - (retryBtn.visible ? retryBtn.width + parent.spacing : 0)
            s: root.s
            tone: "danger"
            text: root.pasteError + (root.pasteError === "Could not copy item" ? " · Enter retries" : "")
        }
        ActionButton {
            id: retryBtn
            anchors.verticalCenter: parent.verticalCenter
            visible: root.pasteError === "Could not copy item"
            s: root.s
            label: "Retry"
            onTriggered: root.activate()
        }
    }

}
