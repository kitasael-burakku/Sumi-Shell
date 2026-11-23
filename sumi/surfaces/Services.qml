pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "../theme"
import "../services"
import "../components"

/**
 * Systemd Units — la lista (Fase 10.c; ámbitos y tipos desde el rediseño 11F-1,
 * futuresystemd-unitssurface).
 *
 * Estructura lista → ficha → journal, como wifi: elegir una unidad **salta a su ficha**
 * (`serviceDetail`). Aquí sólo se elige el ámbito, se busca y se elige.
 *
 *  - **User | System** arriba (el patrón de All | Images | Videos), con recuento y caídas; las
 *    caídas salen de `Units.failed`, la MISMA fuente que el aviso del Dashboard. Nunca se mezclan
 *    ámbitos, ni en la lista ni en la búsqueda. Una apertura directa empieza en User; desde un aviso
 *    del Dashboard, en el ámbito de la unidad y con ella elegida.
 *  - Tipos `.service`, `.timer`, `.socket`, `.mount`/`.automount`, cada fila con su etiqueta; las
 *    fallidas primero sea cual sea su tipo; después agrupadas por función, con los montajes en una
 *    sección plegable (el sistema tiene decenas).
 *  - Los tipos que no se listan (`.path`, `.target`, …) se abren escribiendo su nombre exacto.
 *  - Una lectura fallida es **Unknown state** (con la lista anterior como antigua), nunca «0».
 *
 * Buscador arriba, siempre con el foco: teclear filtra el ámbito visible, ↑↓ mueve, ⏎ abre,
 * Ctrl+Tab / Ctrl+RePág / Ctrl+AvPág cambian de ámbito, `Esc` limpia el filtro o cierra.
 *
 * ALTURA FIJA Y ANCLAJES, sin `Column` alrededor del `ListView`.
 */
Surface {
    id: root

    mTop: 12
    mLeft: 14
    mRight: 14
    mBottom: 12

    signal requestSurface(string name)
    /** Saltar a una ficha diciendo QUE mirar (core/SurfaceHost §`sel`). */
    signal requestDetail(string name, string key)

    readonly property real rowH: 30 * root.s
    readonly property real headH: 22 * root.s

    property string scope: "user"
    property string query: ""
    /** La fila elegida, por CLAVE (ámbito + unidad; «fold:mounts»; «exact:<nombre>»), no por índice. */
    property string selKey: ""
    property bool mountsOpen: false

    readonly property var list: { void Units.rev; return Units.listOf(root.scope); }
    readonly property bool loading: root.list.state === "loading"
    readonly property bool failedRead: root.list.state === "error"
    readonly property var failedHere: { void Units.failed; return Units.failedIn(root.scope); }

    /**
     * Las filas pintadas, en orden: cabeceras de grupo (no se eligen), filas de unidad, el pliegue
     * de montajes y, si la búsqueda es un nombre exacto que no está en la lista, «Open <nombre>».
     *   { kind: head | row | fold | exact, key, title, u }
     */
    readonly property var entries: {
        void Units.rev;
        const q = root.query.trim().toLowerCase();
        const match = function (u) {
            return q.length === 0 || u.unit.toLowerCase().indexOf(q) >= 0 || u.desc.toLowerCase().indexOf(q) >= 0;
        };
        const rows = root.list.rows.filter(match);
        const out = [];
        const push = function (title, arr) {
            if (arr.length === 0) return;
            out.push({ kind: "head", key: "head:" + title, title: title + "  ·  " + arr.length });
            for (const u of arr) out.push({ kind: "row", key: Units.key(u.scope, u.unit), u: u });
        };
        push("Failed", rows.filter(u => u.active === "failed"));
        const ok = rows.filter(u => u.active !== "failed");
        push("Services", ok.filter(u => u.type === "service"));
        push("Timers", ok.filter(u => u.type === "timer"));
        push("Sockets", ok.filter(u => u.type === "socket"));
        const mounts = ok.filter(u => u.type === "mount" || u.type === "automount");
        if (mounts.length > 0) {
            // con una búsqueda escrita los montajes que coinciden se enseñan: buscar no pliega
            const open = root.mountsOpen || q.length > 0;
            out.push({ kind: "fold", key: "fold:mounts", title: "Mounts  ·  " + mounts.length, open: open });
            if (open) for (const u of mounts) out.push({ kind: "row", key: Units.key(u.scope, u.unit), u: u });
        }
        const raw = root.query.trim();
        if (Units.looksLikeUnit(raw) && !root.list.rows.some(u => u.unit === raw))
            out.push({ kind: "exact", key: "exact:" + raw, title: raw });
        return out;
    }
    readonly property var pickable: root.entries.filter(e => e.kind !== "head")
    readonly property int count: root.entries.filter(e => e.kind === "row").length
    readonly property int selIndex: {
        const i = root.pickable.findIndex(e => e.key === root.selKey);
        return i >= 0 ? i : 0;
    }
    readonly property var selEntry: root.pickable[root.selIndex] || null

    /**
     * Reclamación con nombre, con el monitor Y el ámbito (QS-FUNC-003/007, 11F-1): mientras la
     * lista está abierta, `Units` relee cada 5 s SÓLO el ámbito visible.
     */
    readonly property string claimKey: root.screenName.length > 0 ? "services@" + root.screenName : ""
    Claim { target: Units; key: root.claimKey; value: root.active ? root.scope : false }

    onActiveChanged: {
        if (root.active) {
            // La pista del host: "system" / "user", o una clave ("system:foo.service") desde un aviso.
            const hint = root.host ? root.host.selOf("services") : "";
            const p = hint.indexOf(":") > 0 ? Units.parseKey(hint) : null;
            root.scope = p ? p.scope : (hint === "system" ? "system" : "user");
            root.query = "";
            search.clear();
            root.mountsOpen = false;
            root.selKey = p ? Units.key(p.scope, p.unit) : "";
            if (p && ["mount", "automount"].indexOf(Units.typeOf(p.unit)) >= 0) root.mountsOpen = true;
            Qt.callLater(search.focusField);
            Qt.callLater(root.reveal);
        }
    }

    // La lista se relee en vivo: si la elegida sigue, se vuelve a enseñar; si desapareció, la primera.
    onEntriesChanged: Qt.callLater(function () {
        if (!list || !root.active) return;
        if (root.pickable.length > 0 && !root.pickable.some(e => e.key === root.selKey))
            root.selKey = root.pickable[0].key;
        root.reveal();
    })
    // tras recalcular `entries` (los bindings no tienen orden garantizado): la primera de la búsqueda
    onQueryChanged: Qt.callLater(function () { root.selKey = root.pickable.length > 0 ? root.pickable[0].key : ""; })
    onScopeChanged: {
        root.mountsOpen = false;
        root.selKey = "";
        if (root.active) Units.refreshScope(root.scope);
    }

    function setScope(sc) {
        if (sc === root.scope) return;
        root.scope = sc;
    }

    function reveal() {
        if (!list) return;
        // la primera elegible: al principio, con su cabecera de grupo a la vista
        if (root.selIndex === 0) { list.positionViewAtBeginning(); return; }
        const i = root.entries.findIndex(e => e.key === (root.selEntry ? root.selEntry.key : ""));
        if (i >= 0) list.positionViewAtIndex(i, ListView.Contain);
    }

    function move(delta) {
        const n = root.pickable.length;
        if (n === 0) return;
        const i = Math.max(0, Math.min(n - 1, root.selIndex + delta));
        root.selKey = root.pickable[i].key;
        root.reveal();
    }

    function activate() {
        const e = root.selEntry;
        if (!e) return;
        if (e.kind === "fold") { root.mountsOpen = !root.mountsOpen; root.selKey = "fold:mounts"; return; }
        const k = e.kind === "exact" ? Units.key(root.scope, e.title) : e.key;
        // La unidad viaja con el salto: la selecciona esta pantalla (core/SurfaceHost §`sel`).
        Units.loadDetail(k);
        root.requestDetail("serviceDetail", k);
    }

    /** El campo tiene el foco; el host sólo ve lo que el campo no consume. */
    function keyPressed(event) {
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        if (ctrl && (event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp || event.key === Qt.Key_Backtab)) {
            root.setScope(root.scope === "user" ? "system" : "user");
            event.accepted = true;
            return;
        }
        if (event.key === Qt.Key_Escape && root.query.length > 0) {
            root.query = "";
            search.clear();
            event.accepted = true;
        }
        // Esc con el filtro vacío cae sin aceptar: cierra.
    }

    // ---- historial (fase 4): ámbito, filtro, unidad, pliegue y scroll ------
    /** Para el IPC (`unitsState`): lo que ve y elige esta lista. */
    function stateInfo() {
        return { scope: root.scope, query: root.query, sel: root.selEntry ? root.selEntry.key : "",
                 state: root.list.state, error: root.list.error, stale: root.list.stale, mountsOpen: root.mountsOpen,
                 count: root.count, failedHere: root.failedHere.map(f => f.unit),
                 groups: root.entries.filter(e => e.kind === "head" || e.kind === "fold").map(e => e.title),
                 exact: root.entries.filter(e => e.kind === "exact").map(e => e.title),
                 sample: root.pickable.slice(0, 6).map(e => e.kind === "row" ? e.u.unit + " [" + e.u.type + "] " + e.u.active : e.key) };
    }

    function saveContext() {
        return { scope: root.scope, query: root.query, sel: root.selKey, mounts: root.mountsOpen,
                 y: list ? list.contentY : 0 };
    }
    function restoreContext(ctx) {
        if (!ctx) return true;
        root.scope = ctx.scope === "system" ? "system" : "user";
        search.text = ctx.query || "";
        root.mountsOpen = ctx.mounts === true;
        root.selKey = ctx.sel || "";
        Qt.callLater(function () { if (list) list.contentY = Math.max(0, Math.min(ctx.y || 0, list.contentHeight - list.height)); });
        return true;
    }

    function unitGlyph(u) {
        if (u.active === "failed") return "alert";
        if (u.active === "active") return "check";
        return "cog";
    }
    function unitColor(u) {
        if (u.active === "failed") return Theme.errorColor;
        if (u.active === "active") return Theme.primary;
        return Theme.outline;
    }
    function scopeCount(sc) {
        void Units.rev;
        const l = Units.listOf(sc);
        return l.state === "loading" ? "…" : l.state === "error" && !l.stale ? "?" : String(l.rows.length);
    }

    // ---- cabecera: título y ámbitos ------------------------------------

    SurfaceHeader {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        s: root.s
        title: "SYSTEMD UNITS"
        aside: root.loading ? "…" : root.failedRead ? "unknown state"
            : root.count + " shown" + (root.failedHere.length > 0 ? "  ·  " + root.failedHere.length + " failed" : "")
        asideColor: root.failedRead ? Theme.warn : root.failedHere.length > 0 ? Theme.errorColor : Theme.outline
    }

    Row {
        id: scopeRow
        anchors.top: header.bottom
        anchors.topMargin: 8 * root.s
        anchors.left: parent.left
        spacing: 6 * root.s
        Accessible.role: Accessible.PageTabList
        Repeater {
            model: [{ id: "user", label: "User" }, { id: "system", label: "System" }]
            delegate: Rectangle {
                id: chip
                required property var modelData
                readonly property bool cur: root.scope === chip.modelData.id
                readonly property int nFailed: { void Units.failed; return Units.failedIn(chip.modelData.id).length; }
                width: chipRow.implicitWidth + 18 * root.s
                height: 24 * root.s
                radius: Metrics.r(8) * root.s
                color: chip.cur ? Theme.selBg : chipArea.containsMouse ? Theme.hoverBg : "transparent"
                border.width: chip.cur ? 1 : 0
                border.color: Theme.selBorder
                Accessible.role: Accessible.PageTab
                Accessible.name: chip.modelData.label + " units"
                Accessible.selected: chip.cur
                Row {
                    id: chipRow
                    anchors.centerIn: parent
                    spacing: 6 * root.s
                    // la marca de la activa, además del color
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: chip.cur
                        width: 5 * root.s; height: 5 * root.s; radius: Metrics.pill(width)
                        color: Theme.primary
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: chip.modelData.label + "  " + root.scopeCount(chip.modelData.id)
                        color: chip.cur ? Theme.fg : Theme.fgVariant
                        font.family: Typography.ui
                        font.pixelSize: Typography.caption * root.s
                        font.weight: chip.cur ? Font.DemiBold : Font.Normal
                        font.features: ({ "tnum": 1 })
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: chip.nFailed > 0
                        text: chip.nFailed + " failed"
                        color: Theme.errorColor
                        font.family: Typography.ui
                        font.pixelSize: Typography.caption * root.s
                    }
                }
                MouseArea {
                    id: chipArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.setScope(chip.modelData.id); search.focusField(); }
                }
            }
        }
    }

    Rectangle {
        id: searchBox
        anchors.top: scopeRow.bottom
        anchors.topMargin: 8 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        height: 28 * root.s
        radius: Metrics.r(8) * root.s
        color: Theme.tileBg
        border.width: 1
        border.color: search.input.activeFocus ? Qt.alpha(Theme.primary, 0.4) : Theme.hair

        Icon {
            id: si
            anchors.left: parent.left
            anchors.leftMargin: 9 * root.s
            anchors.verticalCenter: parent.verticalCenter
            name: "search"
            size: 12 * root.s
            color: Theme.fgVariant
        }
        SearchField {
            id: search
            anchors.left: si.right
            anchors.leftMargin: 8 * root.s
            anchors.right: parent.right
            anchors.rightMargin: 10 * root.s
            anchors.verticalCenter: parent.verticalCenter
            height: 18 * root.s
            s: root.s
            ctrlTabs: true
            placeholder: root.scope === "system" ? "Filter system units…" : "Filter user units…"
            onTextChanged: root.query = text
            onMoved: (d) => root.move(d)
            onAccepted: root.activate()
            onCtrlTabbed: (d) => root.setScope(root.scope === "user" ? "system" : "user")
            onDismissed: {
                if (root.query.length > 0) { root.query = ""; search.clear(); }
                else root.requestClose();
            }
        }
    }

    // ---- lectura fallida: Unknown state, nunca «0 unidades» -------------
    Rectangle {
        id: unknownBanner
        anchors.top: searchBox.bottom
        anchors.topMargin: 6 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        visible: root.failedRead
        height: visible ? bannerText.implicitHeight + 10 * root.s : 0
        radius: Metrics.r(7) * root.s
        color: Qt.alpha(Theme.warn, 0.12)
        Text {
            id: bannerText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 8 * root.s
            anchors.rightMargin: 8 * root.s
            wrapMode: Text.WordWrap
            text: "Unknown state · could not read " + root.scope + " units: " + root.list.error
                + (root.list.stale ? " · showing the list from " + Qt.formatTime(new Date(root.list.at), "HH:mm") : "")
            color: Theme.warn
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }
    }

    // ---- pie ----------------------------------------------------------

    Text {
        id: hint
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 13 * root.s
        verticalAlignment: Text.AlignVCenter
        text: Units.lastResult.length > 0
            ? Units.lastVerb + " " + Units.lastUnit + " → " + Units.lastResult
            : "type to filter   ↑↓ pick   ⏎ open   Ctrl+Tab User / System   Esc close"
        color: Units.lastResult === "ok" ? Theme.primary
             : Units.lastResult.indexOf("exit") === 0 ? Theme.errorColor
             : Theme.fgVariant
        font.family: Typography.ui
        font.pixelSize: Typography.caption * root.s
        elide: Text.ElideRight
    }

    // ---- lista ------------------------------------------------------

    Text {
        anchors.top: unknownBanner.bottom
        anchors.topMargin: 12 * root.s
        anchors.left: parent.left
        visible: root.loading
        text: root.scope === "system" ? "Reading system units…" : "Reading user units…"
        color: Theme.fgVariant
        font.family: Typography.ui
        font.pixelSize: Typography.body * root.s
    }

    Empty {
        anchors.top: unknownBanner.bottom
        anchors.topMargin: Metrics.sp5 * root.s
        anchors.horizontalCenter: parent.horizontalCenter
        visible: !root.loading && root.pickable.length === 0 && !(root.failedRead && !root.list.stale)
        s: root.s
        maxWidth: parent.width
        glyph: "server"
        text: root.query.length > 0 ? "No " + root.scope + " unit matches “" + root.query + "”"
            : "No " + root.scope + " units"
        hint: root.query.length > 0 ? "Searches this scope only · a full unit name (basic.target) opens it"
            : "Nothing of these types under systemd" + (root.scope === "user" ? " --user" : "")
    }

    ListView {
        id: list
        visible: !root.loading && root.entries.length > 0
        anchors.top: unknownBanner.bottom
        anchors.topMargin: 6 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: hint.top
        anchors.bottomMargin: 6 * root.s
        clip: true
        model: root.entries
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: 0
        opacity: root.failedRead ? 0.55 : 1   // la lista de antes de un fallo, marcada como antigua

        delegate: Item {
            id: row
            required property int index
            required property var modelData
            readonly property string kind: row.modelData.kind
            readonly property bool selRow: row.kind !== "head" && root.selEntry !== null && root.selEntry.key === row.modelData.key
            width: list.width
            height: row.kind === "head" ? root.headH : root.rowH
            Accessible.role: row.kind === "head" ? Accessible.StaticText : Accessible.ListItem
            Accessible.name: row.kind === "row" ? row.modelData.u.unit + ", " + row.modelData.u.type + ", "
                + row.modelData.u.active + " " + row.modelData.u.sub : row.modelData.title
            Accessible.selected: row.selRow

            // cabecera de grupo
            Text {
                visible: row.kind === "head"
                anchors.left: parent.left
                anchors.leftMargin: 4 * root.s
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 3 * root.s
                text: row.kind === "head" ? row.modelData.title.toUpperCase() : ""
                color: row.modelData.title && row.modelData.title.indexOf("Failed") === 0 ? Theme.errorColor : Theme.outlineText
                font.family: Typography.ui
                font.pixelSize: Typography.micro * root.s
                font.weight: Typography.wStrong
                font.letterSpacing: Typography.tracking * root.s
            }

            Rectangle {
                visible: row.kind !== "head"
                anchors.fill: parent
                anchors.topMargin: 1 * root.s
                anchors.bottomMargin: 1 * root.s
                radius: Metrics.r(7) * root.s
                color: row.selRow ? Theme.selBg : rowArea.containsMouse ? Theme.hoverBg : "transparent"
                Behavior on color { ColorAnimation { duration: Motion.fast } }
            }

            Icon {
                id: g
                visible: row.kind !== "head"
                anchors.left: parent.left
                anchors.leftMargin: 8 * root.s
                anchors.verticalCenter: parent.verticalCenter
                name: row.kind === "fold" ? (row.modelData.open ? "chevron-down" : "chevron-right")
                    : row.kind === "exact" ? "search" : row.kind === "row" ? root.unitGlyph(row.modelData.u) : "cog"
                size: 12 * root.s
                color: row.kind === "row" ? root.unitColor(row.modelData.u) : Theme.fgVariant
            }
            Text {
                visible: row.kind !== "head"
                anchors.left: g.right
                anchors.leftMargin: 8 * root.s
                anchors.right: typeTag.visible ? typeTag.left : st.left
                anchors.rightMargin: 8 * root.s
                anchors.verticalCenter: parent.verticalCenter
                text: row.kind === "row" ? row.modelData.u.unit
                    : row.kind === "exact" ? "Open " + row.modelData.title + " (" + root.scope + ")"
                    : row.kind === "fold" ? row.modelData.title : ""
                elide: Text.ElideMiddle
                color: row.selRow ? Theme.fg : Theme.fgVariant
                font.family: Typography.ui
                font.pixelSize: Typography.label * root.s
                font.weight: row.kind === "row" && row.modelData.u.active === "failed" ? Font.DemiBold : Font.Normal
            }
            // la etiqueta del tipo
            Rectangle {
                id: typeTag
                visible: row.kind === "row"
                anchors.right: st.left
                anchors.rightMargin: 8 * root.s
                anchors.verticalCenter: parent.verticalCenter
                width: typeText.implicitWidth + 10 * root.s
                height: 16 * root.s
                radius: Metrics.r(5) * root.s
                color: Theme.tileBg
                Text {
                    id: typeText
                    anchors.centerIn: parent
                    text: row.kind === "row" ? row.modelData.u.type : ""
                    color: Theme.fgVariant
                    font.family: Typography.mono
                    font.pixelSize: Typography.micro * root.s
                }
            }
            Text {
                id: st
                visible: row.kind === "row"
                anchors.right: parent.right
                anchors.rightMargin: 10 * root.s
                anchors.verticalCenter: parent.verticalCenter
                text: row.kind === "row" ? row.modelData.u.active + " / " + row.modelData.u.sub : ""
                color: row.kind === "row" ? root.unitColor(row.modelData.u) : Theme.outlineText
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
            }

            MouseArea {
                id: rowArea
                visible: row.kind !== "head"
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                // hover sólo pinta; no mueve la elegida (DESIGN §3)
                onClicked: { root.selKey = row.modelData.key; root.activate(); }
            }
        }
    }

    /**
     * La barra de desplazamiento (2026-09-15). Hermana de la lista, no hija:
     * un hijo de un `ListView` viaja dentro del contenido y se iria con el scroll.
     */
    ScrollHint { view: list; s: root.s }

}
