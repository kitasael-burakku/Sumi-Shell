pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../services"
import "../components"

/**
 * Web hub (Fase 9.i), over the user's `websites.conf` (F3c: ~/.config/sumi-shell/websites.conf).
 *
 * Replaces `web_launcher.sh` and its two blocking rofi calls with one surface
 * that walks the same two levels — categories, then pages — and **adds the one
 * thing the original could not do**: search. Where rofi's `[Search]` category
 * only opened the engine's home page, here you type and get live suggestions,
 * and picking one opens the browser on that search.
 *
 * `websites.conf` stays the single source (`services/Web`).
 *
 * Anchors, no `Column` wrapping the list: the page list is unbounded, so it
 * scrolls. Since 2026-11-17 the height fits the rows (`fitH`, counted from the
 * data, never from the layout), up to the old fixed height.
 *
 * ── REDISEÑO, ARR-04 (2026-09-24, `rediseno/docs/futureweb-hubsurface.md`) ──
 *
 * Se conserva la organización (Search the web primero, categorías, páginas, la
 * búsqueda en vista propia, los dos motores, el orden del archivo). Cambia:
 *
 *   · Tab / Shift+Tab recorren campo → motores → resultados; un motor se elige
 *     con Enter/Espacio o con clic. Tab ya no cambia el motor por sí solo.
 *   · El hover sólo resalta: ya no mueve la fila sobre la que actúa Enter.
 *   · Filas sin carpetas ni globos repetidos; nombre y dominio no se pisan.
 *   · websites.conf ausente / ilegible / sin categorías es un estado con Retry,
 *     distinto de una categoría vacía, y Search the web sigue disponible.
 *   · Abrir sólo cierra si el navegador arrancó; si no, el motivo y el contexto
 *     se quedan.
 *   · La búsqueda vacía dice «Type to search» y ya no promete que Enter abra
 *     el navegador (`Web.search("")` no abre nada).
 */
Surface {
    id: root

    mTop: 12
    mLeft: 14
    mRight: 14
    mBottom: 12

    /** "cats" · "pages" · "search" */
    property string page: "cats"
    property string category: ""
    /** La fila sobre la que actúa Enter. El hover NO la mueve (DESIGN §3). */
    property int selected: 0
    /** En la vista de búsqueda, dónde está el teclado: "field" · "engine" · "list". */
    property string zone: "field"
    property int engineFocus: 0
    /**
     * Esperando a que arranque el navegador: la revisión de ESTA apertura en
     * `Web.ops` (6C), 0 si ninguna. Un resultado de otra revisión no es nuestro.
     */
    property int openRev: 0
    readonly property bool opening: root.openRev > 0
    property string openError: ""

    readonly property real rowH: 34 * root.s
    /** La lista tiene el teclado: su fila elegida lleva el contorno de foco (nunca en vista previa, fase 4C). */
    readonly property bool listHasKeys: root.engaged && (root.page !== "search" || root.zone === "list")

    onActiveChanged: {
        if (root.active) {
            root.page = "cats";
            root.category = "";
            root.selected = 0;
            root.zone = "field";
            root.openRev = 0;
            root.openError = "";
            Web.query = "";
            search.clear();
        }
    }

    Connections {
        target: Web.ops
        function onSettled(key, rev, state, reason) {
            if (key === "open" && rev === root.openRev) root.openDone(state, reason);
        }
    }

    function openDone(state, reason) {
        root.openRev = 0;
        if (state === "ok") root.requestClose();
        else root.openError = reason;
    }

    /** La fila de "buscar" va la primera: es lo que más se usa. */
    readonly property var catRows: {
        const out = [{ kind: "search", name: "Search the web" }];
        if (Web.confState === "ready") {
            for (let i = 0; i < Web.categories.length; i++)
                out.push({ kind: "cat", name: Web.categories[i].name,
                           count: Web.categories[i].pages.length });
        } else if (Web.confState !== "loading") {
            // Ausente, ilegible o sin categorías: una fila que lo dice y reintenta.
            out.push({ kind: "error", name: Web.lastError });
        }
        return out;
    }

    readonly property var rows: {
        if (root.page === "cats") return root.catRows;
        if (root.page === "pages") return Web.pagesOf(root.category);
        return Web.suggestions;
    }
    readonly property int count: root.rows.length

    /**
     * El alto que pide (paneles que se adaptan, 2026-11-17): filas de `rowH` contadas en los datos (nunca el maquetado
     * de la lista, 9.f.2). La fila de error parte su texto: cuenta como dos (si es más larga, se desplaza). Sin filas,
     * el aviso de vacío; con un fallo al abrir, su línea. Las sugerencias conservan la lista vieja mientras llega la
     * nueva (`services/Web`), así que escribir no lo hace saltar. El host lo acota a `Metrics.webH`.
     */
    readonly property real fitH: {
        const s = root.s;
        const cap = Metrics.webH * s;
        let listH = 0;
        const rows = root.rows;
        for (let i = 0; i < rows.length && listH < cap; i++)
            listH += rows[i] && rows[i].kind === "error" ? 2 * root.rowH : root.rowH;
        const bodyH = root.count > 0 ? list.anchors.topMargin + listH
            : webEmpty.anchors.topMargin + webEmpty.implicitHeight + Metrics.sp5 * s;
        return (root.mTop + root.mBottom) * s + header.height + hair.anchors.topMargin + hair.height + bodyH
            + (failure.visible ? failure.height + 6 * s : 0);
    }

    onCountChanged: {
        if (root.selected >= root.count) root.selected = Math.max(0, root.count - 1);
        if (root.count === 0 && root.zone === "list") root.setZone("field");
    }
    onPageChanged: { root.selected = 0; root.openError = ""; }

    function move(delta) {
        if (root.count === 0) return;
        root.selected = Math.max(0, Math.min(root.count - 1, root.selected + delta));
        list.positionViewAtIndex(root.selected, ListView.Contain);
    }

    /** Abrir en el navegador; la superficie se cierra cuando `Web` confirma que arrancó. */
    function openLink(url) {
        root.openError = "";
        const r = Web.openUrl(url);
        const o = Web.ops.get("open");
        // Una URL rechazada se resuelve dentro de la llamada, antes de tener la revisión.
        if (o.rev === r && o.state !== "pending") root.openDone(o.state, o.reason);
        else root.openRev = r;
    }

    function activate() {
        if (root.opening) return;
        if (root.page === "cats") {
            const r = root.catRows[root.selected];
            if (!r) return;
            if (r.kind === "search") {
                root.page = "search";
                Web.query = "";
                search.clear();
                root.setZone("field");
                return;
            }
            if (r.kind === "error") { Web.reloadConf(); return; }
            root.category = r.name;
            root.page = "pages";
            return;
        }
        if (root.page === "pages") {
            const p = root.rows[root.selected];
            if (p) root.openLink(p.url);
            return;
        }
        // search: la sugerencia elegida, o lo tecleado tal cual si no hay ninguna
        const term = ((root.count > 0 && root.selected < root.count)
            ? root.rows[root.selected] : Web.query).trim();
        if (term.length > 0) root.openLink(Web.searchUrl(term));
    }

    // ---- historial (fase 4): contexto de la visita --------------------------------

    function rowKey(r) {
        if (r === undefined || r === null) return "";
        if (root.page === "search") return String(r);
        if (root.page === "pages") return r.url;
        return r.kind + ":" + (r.name || "");
    }

    function saveContext() {
        return { page: root.page, category: root.category, query: Web.query, engine: Web.engineId,
                 sel: root.rowKey(root.rows[root.selected]), y: list.contentY };
    }

    /** Vuelve a la vista sin abrir nada; `false` si la categoría ya no existe. */
    function restoreContext(ctx) {
        if (!ctx) return true;
        if (ctx.engine) Web.setEngine(ctx.engine);
        if (ctx.page === "pages") {
            if (Web.pagesOf(ctx.category).length === 0
                    && !Web.categories.some(c => c.name === ctx.category))
                return false;
            root.category = ctx.category;
            root.page = "pages";
        } else if (ctx.page === "search") {
            root.startSearch(ctx.query || "");
        }
        for (let i = 0; i < root.rows.length; i++)
            if (root.rowKey(root.rows[i]) === ctx.sel) { root.selected = i; break; }
        list.contentY = Math.max(0, Math.min(ctx.y || 0, Math.max(0, list.contentHeight - list.height)));
        return true;
    }

    /** Ir a la búsqueda con un texto ya escrito (la usa la preview; el mismo camino que teclearlo). */
    function startSearch(q) {
        root.page = "search";
        search.text = q;
        root.setZone("field");
    }

    function back() {
        if (root.page === "cats") { root.requestClose(); return; }
        root.page = "cats";
        root.category = "";
        root.zone = "field";
        Web.query = "";
        search.clear();
        root.forceActiveFocus();   // el campo suelta el teclado (lección de 9.f.2b)
    }

    // ---- el recorrido con Tab en la búsqueda ---------------------------------

    function tabStops() {
        const st = ["field"];
        for (let i = 0; i < Web.engines.length; i++) st.push("engine:" + i);
        if (root.count > 0) st.push("list");
        return st;
    }

    function setZone(stop) {
        if (stop === "field") {
            root.zone = "field";
            Qt.callLater(search.focusField);
        } else if (stop === "list") {
            root.zone = "list";
            root.forceActiveFocus();
        } else {
            root.zone = "engine";
            root.engineFocus = parseInt(stop.split(":")[1]);
            root.forceActiveFocus();
        }
    }

    function tabTo(dir) {
        const st = root.tabStops();
        // Un clic en el campo le da el teclado sin pasar por aquí: se mira el foco real.
        const cur = search.editing ? "field"
            : root.zone === "engine" ? "engine:" + root.engineFocus : root.zone;
        const i = Math.max(0, st.indexOf(cur));
        root.setZone(st[(i + dir + st.length) % st.length]);
    }

    function keyPressed(event) {
        if (root.page === "search" && search.editing) return;   // el campo manda mientras escribe
        const k = event.key;
        const shift = (event.modifiers & Qt.ShiftModifier) !== 0;

        if (root.page === "search") {
            if (k === Qt.Key_Tab || k === Qt.Key_Backtab) {
                root.tabTo(k === Qt.Key_Backtab || shift ? -1 : 1);
                event.accepted = true;
                return;
            }
            if (root.zone === "engine") {
                if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) {
                    Web.setEngine(Web.engines[root.engineFocus].id);
                    event.accepted = true;
                    return;
                }
                if (k === Qt.Key_Left || k === Qt.Key_Right) {
                    root.engineFocus = Math.max(0, Math.min(Web.engines.length - 1,
                        root.engineFocus + (k === Qt.Key_Right ? 1 : -1)));
                    event.accepted = true;
                    return;
                }
            }
            // Escribir desde un motor o desde la lista vuelve al campo con esa letra.
            if (event.text.length === 1 && event.text >= " " && !(event.modifiers & Qt.ControlModifier)) {
                search.text = search.text + event.text;
                root.setZone("field");
                event.accepted = true;
                return;
            }
            if (k === Qt.Key_Backspace) {
                search.text = search.text.slice(0, -1);
                root.setZone("field");
                event.accepted = true;
                return;
            }
        }

        if (k === Qt.Key_Escape) { root.back(); event.accepted = true; }
        // 16G: en categorías y en una categoría hay un solo grupo: Tab y Mayús+Tab como ↓/↑
        else if (k === Qt.Key_Tab || k === Qt.Key_Backtab) {
            root.move(k === Qt.Key_Backtab || shift ? -1 : 1); event.accepted = true;
        }
        else if (k === Qt.Key_Up)   { root.move(-1); event.accepted = true; }
        else if (k === Qt.Key_Down) { root.move(1);  event.accepted = true; }
        else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) {
            root.activate(); event.accepted = true;
        }
    }

    // ---- header --------------------------------------------------------------

    Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 24 * root.s

        Icon {
            id: crumbIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            name: root.page === "search" ? "search" : "web"
            size: 14 * root.s
            color: Theme.fgVariant
        }

        /** «WEB HUB» o el nombre de la categoría, en el mismo sitio: el cambio de nivel se lee sin mover nada. */
        Text {
            id: crumb
            anchors.left: crumbIcon.right
            anchors.leftMargin: 9 * root.s
            anchors.right: headCount.left
            anchors.rightMargin: 10 * root.s
            anchors.verticalCenter: parent.verticalCenter
            visible: root.page !== "search"
            text: root.page === "cats" ? "WEB HUB" : root.category.toUpperCase()
            elide: Text.ElideRight
            color: Theme.fgVariant
            font.family: Typography.ui
            font.pixelSize: Typography.label * root.s
            font.weight: Typography.wStrong
            font.letterSpacing: Typography.tracking * root.s
        }

        /** Back · Forward · Close (fase 4), siempre en la esquina. */
        FrameNav {
            id: frameNav
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            s: root.s
            host: root.host
            onCloseRequested: root.requestClose()
        }

        SearchField {
            id: search
            anchors.left: crumbIcon.right
            anchors.leftMargin: 9 * root.s
            anchors.right: engineRow.left
            anchors.rightMargin: 10 * root.s
            anchors.verticalCenter: parent.verticalCenter
            height: parent.height
            visible: root.page === "search"
            s: root.s
            backtabs: true
            placeholder: "Search " + Web.engine.name
            onTextChanged: { Web.query = search.text; root.selected = 0; root.openError = ""; }
            onMoved: (d) => root.move(d)
            onAccepted: root.activate()
            onDismissed: root.back()
            onTabbed: root.tabTo(1)
            onBacktabbed: root.tabTo(-1)
        }

        /**
         * Los buscadores: pastilla con el acento para el activo (además del peso),
         * contorno para el que tiene el teclado. Se eligen con clic o Enter/Espacio.
         */
        Row {
            id: engineRow
            anchors.right: frameNav.left
            anchors.rightMargin: 8 * root.s
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4 * root.s
            visible: root.page === "search"

            Repeater {
                model: Web.engines
                delegate: Rectangle {
                    id: pill
                    required property var modelData
                    required property int index
                    readonly property bool current: Web.engineId === pill.modelData.id
                    readonly property bool keyed: root.zone === "engine" && root.engineFocus === pill.index

                    anchors.verticalCenter: parent.verticalCenter
                    width: pillText.implicitWidth + 14 * root.s
                    height: 20 * root.s
                    radius: Metrics.r(7) * root.s
                    color: pill.current ? Theme.selBg : (pillArea.containsMouse ? Theme.hoverBg : "transparent")
                    border.width: pill.keyed ? Metrics.focusWidth * root.s : 0
                    border.color: Theme.focusRing
                    Behavior on color { ColorAnimation { duration: Motion.fast } }

                    Accessible.role: Accessible.RadioButton
                    Accessible.name: pill.modelData.name
                    Accessible.checkable: true
                    Accessible.checked: pill.current
                    Accessible.onPressAction: Web.setEngine(pill.modelData.id)

                    Text {
                        id: pillText
                        anchors.centerIn: parent
                        text: pill.modelData.name
                        color: pill.current ? Theme.primary : Theme.fgVariant
                        font.family: Typography.ui
                        font.pixelSize: Typography.caption * root.s
                        font.weight: pill.current ? Typography.wStrong : Typography.wNormal
                    }

                    MouseArea {
                        id: pillArea
                        anchors.fill: parent
                        // Objetivo de clic de ~32 px de alto sin agrandar la pastilla.
                        anchors.margins: -6 * root.s
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Web.setEngine(pill.modelData.id)
                    }
                }
            }
        }

        Text {
            id: headCount
            anchors.right: frameNav.left
            anchors.rightMargin: 8 * root.s
            anchors.verticalCenter: parent.verticalCenter
            visible: root.page !== "search"
            text: {
                const n = root.page === "cats" ? Web.pageCount : root.count;
                return n + (n === 1 ? " page" : " pages");
            }
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

    // ---- list ----------------------------------------------------------------

    /**
     * Estados de la búsqueda, cada uno con su texto: vacía, buscando, sin
     * sugerencias y sugerencias no disponibles. Con algo escrito, Enter busca
     * aunque no haya sugerencias, y el hint lo dice; con la búsqueda vacía no hay
     * hint, porque Enter no hace nada.
     */
    Empty {
        id: webEmpty
        anchors.top: hair.bottom
        anchors.topMargin: Metrics.sp5 * root.s
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.count === 0
        s: root.s
        maxWidth: parent.width
        readonly property bool searching: root.page === "search"
        readonly property bool blank: Web.query.trim().length === 0
        loading: searching && !blank && Web.fetching
        glyph: searching ? "search" : "web"
        text: {
            if (searching) {
                if (blank) return "Type to search";
                if (Web.fetching) return "Looking up suggestions…";
                if (Web.suggestError.length > 0) return Web.suggestError;
                return "No suggestions";
            }
            return "No pages in this category";
        }
        hint: searching && !blank && !Web.fetching ? "Enter searches your query" : ""
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
        model: root.rows
        currentIndex: root.selected
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: 0

        delegate: Item {
            id: row
            required property int index
            required property var modelData

            width: list.width
            height: row.kind === "error" ? Math.max(root.rowH, rowText.implicitHeight + 12 * root.s) : root.rowH

            /** "search" · "cat" · "error" · "page" · "suggestion" */
            readonly property string kind: root.page === "cats" ? row.modelData.kind
                : root.page === "pages" ? "page" : "suggestion"
            readonly property bool current: row.index === root.selected
            readonly property bool pointed: area.containsMouse
            readonly property bool navigates: row.kind === "search" || row.kind === "cat"

            readonly property bool hasPath: row.kind === "error"
                && (Web.confState === "missing" || Web.confState === "unreadable")
            readonly property string label: row.kind === "error" && Web.confState === "missing" ? "No websites.conf yet"
                : row.kind === "error" && Web.confState === "unreadable" ? "Could not read websites.conf"
                : row.kind === "suggestion" ? row.modelData : row.modelData.name
            readonly property string aside: row.kind === "cat" ? row.modelData.count + ""
                : row.kind === "page" ? row.modelData.url.replace(/^[a-z][a-z0-9+.-]*:\/\//i, "").split("/")[0]
                : row.kind === "error" ? "Retry"
                : ""

            Accessible.role: Accessible.ListItem
            Accessible.name: row.label
            Accessible.description: row.aside + (row.hasPath ? " · " + Web.lastError : "")
            Accessible.selected: row.current
            Accessible.onPressAction: { root.selected = row.index; root.activate(); }

            /**
             * Elegida = celda + marca; con el teclado en la lista, además contorno.
             * Hover = fondo tenue. «Search the web» lleva un tinte de acento propio,
             * más flojo que la selección para no confundirse con ella.
             */
            Rectangle {
                anchors.fill: parent
                anchors.topMargin: 1 * root.s
                anchors.bottomMargin: 1 * root.s
                radius: Metrics.r(8) * root.s
                color: row.current ? Theme.selBg
                     : row.pointed ? Theme.hoverBg
                     : row.kind === "search" ? Qt.alpha(Theme.primary, 0.06)
                     : "transparent"
                border.width: row.current && root.listHasKeys ? Metrics.focusWidth * root.s : 0
                border.color: Theme.selBorder
                Behavior on color { ColorAnimation { duration: Motion.fast } }
            }

            Rectangle {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                visible: row.current
                width: 2 * root.s
                height: parent.height * 0.4
                radius: Metrics.pill(width)
                color: Theme.primary
            }

            /** Sólo lleva glifo lo que no es una fila más: buscar y el error. */
            Icon {
                id: rowIcon
                anchors.left: parent.left
                anchors.leftMargin: 10 * root.s
                anchors.verticalCenter: parent.verticalCenter
                visible: row.kind === "search" || row.kind === "error"
                name: row.kind === "search" ? "search" : "alert"
                size: 13 * root.s
                color: row.kind === "search" ? Theme.primary : Theme.warn
            }

            Column {
                id: rowText
                anchors.left: rowIcon.visible ? rowIcon.right : parent.left
                anchors.leftMargin: rowIcon.visible ? 9 * root.s : 12 * root.s
                anchors.right: tail.left
                anchors.rightMargin: 10 * root.s
                anchors.verticalCenter: parent.verticalCenter
                spacing: 3 * root.s

                Text {
                    id: rowLabel
                    width: parent.width
                    text: row.label
                    wrapMode: row.kind === "error" ? Text.WordWrap : Text.NoWrap
                    elide: row.kind === "error" ? Text.ElideNone : Text.ElideRight
                    color: row.kind === "error" ? Theme.warn : (row.current ? Theme.fg : Theme.fgVariant)
                    font.family: Typography.ui
                    font.pixelSize: Typography.body * root.s
                    font.weight: row.kind === "search" ? Typography.wStrong : Typography.wNormal
                }
                Text {
                    width: parent.width
                    visible: row.hasPath
                    text: (Web.confState === "missing" ? "Create " : "") + Web.confPretty
                    elide: Text.ElideMiddle
                    color: Theme.fgVariant
                    font.family: Typography.mono
                    font.pixelSize: Typography.caption * root.s
                }
            }

            /** El dato de la derecha y, si la fila lleva a otra vista, el chevrón. */
            Row {
                id: tail
                anchors.right: parent.right
                anchors.rightMargin: 8 * root.s
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6 * root.s

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: text.length > 0
                    // El dominio no puede comerse el nombre: como mucho el 42 % de la fila.
                    width: Math.min(implicitWidth, row.width * 0.42)
                    text: row.aside
                    elide: Text.ElideRight
                    color: row.kind === "error" ? Theme.primary : Theme.outlineText
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                    font.weight: row.kind === "error" ? Typography.wStrong : Typography.wNormal
                    font.features: ({ "tnum": 1 })
                }
                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: row.navigates
                    name: "chevron-right"
                    size: 11 * root.s
                    color: row.current ? Theme.fgVariant : Theme.outline
                }
            }

            MouseArea {
                id: area
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

    /** Un fallo al abrir: el motivo, sin perder la vista ni lo escrito. */
    Notice {
        id: failure
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.openError.length > 0
        s: root.s
        tone: "danger"
        text: root.openError
    }
}
