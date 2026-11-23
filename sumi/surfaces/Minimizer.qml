pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import "../theme"
import "../services"
import "../components"
import "../lib/text-wrap.js" as TextWrap

/**
 * Minimizador de ventanas (Fase 10.b).
 *
 * Sustituye a `rofi/scripts/window-switcher.sh` (`ALT+TAB`). NO es un ALT+TAB:
 * `⏎` sobre una ventana abierta la **minimiza** (a `special:minimized`), sobre
 * una minimizada la **restaura** al workspace activo y la enfoca. Mismo
 * comportamiento que el script.
 *
 * `→` (o clic derecho) **enfoca** la ventana sin minimizarla — es el modi
 * `window` de rofi (Fase 10.c.3): saltar a cualquier ventana esté donde esté.
 *
 * `window-switcher.sh` **no se retira aqui** (ADR-18 / PARIDAD §3): sigue en
 * `ALT+TAB` como red de seguridad hasta que 10.e lo jubile tras sus siete dias.
 *
 * Dos secciones con encabezado: «Minimized» y luego «Open». Cada fila lleva
 * icono por clase, titulo, clase, workspace y estado (decision del usuario,
 * 2026-09-10).
 *
 * CON VARIOS MONITORES (2026-09-23), «Open» se parte en una seccion por
 * pantalla, con `HyprlandToplevel.monitor`: primero la pantalla donde esta
 * abierto el minimizador («here»), luego las demas en el orden de
 * `Quickshell.screens`. Las minimizadas siguen en una sola seccion: no estan
 * en ninguna pantalla. Con un monitor no cambia nada. Lo que Waybar no podia
 * sin replicar un modulo por monitor: aqui el modelo es uno y las vistas varias.
 *
 * ANCLAJES, SIN `Column` alrededor del `ListView` (leccion pagada en 9.f.2):
 * la lista se puebla ~1 s despues de abrir y ataria el destino del morph a un
 * valor movil. `ready = hasData || settled`. Desde el 2026-11-17 el alto se
 * adapta a las ventanas (`fitH`), pero contado en los DATOS y con el alto de
 * siempre mientras lee: el destino nunca sale del maquetado.
 *
 * Los datos y las acciones estan en `services/Toplevels`.
 */
Surface {
    id: root

    mTop: 12
    mLeft: 14
    mRight: 14
    mBottom: 12

    /** Con miniaturas la fila crece para que se reconozca lo que hay dentro (QS-FUNC-016). */
    readonly property bool thumbs: Settings.minimizerThumbs
    readonly property real rowH: (root.thumbs ? 62 : 42) * root.s
    readonly property real headH: 18 * root.s

    /** Indice sobre `wins`: las ventanas en el orden en que se VEN. */
    /**
     * Rediseño, ARR-05 (futurewindow-minimizer §«Coherencia»): la selección va por
     * IDENTIDAD de ventana (`keyOf`), no por índice. Antes `sel` era una posición:
     * si una ventana de arriba se cerraba, Enter pasaba a actuar sobre la de
     * debajo. `sel` sigue existiendo como índice DERIVADO para mover y dibujar.
     */
    property string selKey: ""
    property int lastSel: 0
    readonly property int sel: {
        for (let i = 0; i < root.count; i++)
            if (root.keyOf(root.wins[i]) === root.selKey) return i;
        return -1;
    }
    /** «Window no longer available», un momento, si se pidió actuar sobre una que ya no está. */
    property string goneNote: ""

    function keyOf(w) {
        if (!w) return "";
        return w.address.length > 0 ? w.address : (w.appId + "|" + w.title + "|" + w.workspace);
    }
    // `wins.length` y no `count`: se llama desde `onWinsChanged`, cuando `count`
    // (derivado de `wins`) puede no haberse recalculado todavía.
    function selectAt(i) {
        const n = root.wins.length;
        if (n === 0) { root.selKey = ""; return; }
        const k = Math.max(0, Math.min(n - 1, i));
        root.selKey = root.keyOf(root.wins[k]);
        root.lastSel = k;
    }

    Timer {
        id: goneTimer
        interval: 2500
        onTriggered: root.goneNote = ""
    }

    /**
     * La lista plana sale de las filas, no de `Toplevels.windows`: con las
     * secciones por pantalla el orden visual ya no es el del servicio, y las
     * flechas tienen que bajar por lo que se ve.
     */
    readonly property var wins: root.rows.filter(function (r) { return r.win !== undefined; })
        .map(function (r) { return r.win; })
    readonly property int count: root.wins.length
    /** `true` cuando ya hay datos o el arranque ha asentado sin traer nada. */
    readonly property bool ready: Toplevels.ready || root.settled

    /**
     * El alto que pide (paneles que se adaptan, 2026-11-17): rótulos de `headH` y filas de `rowH` contados en los
     * datos (`rows`), nunca el maquetado de la lista (9.f.2). Mientras lee (`!ready`, ~1 s) pide el alto de siempre:
     * abrir diminuto y crecer al llegar la lista serían dos movimientos. El host lo acota a `Metrics.minimizerH`.
     */
    readonly property real fitH: {
        const s = root.s;
        const cap = Metrics.minimizerH * s;
        if (!root.ready) return cap;
        let listH = 0;
        const rows = root.rows;
        for (let i = 0; i < rows.length && listH < cap; i++)
            listH += rows[i].header !== undefined ? root.headH : root.rowH;
        const bodyH = root.count > 0 ? list.anchors.topMargin + listH + list.anchors.bottomMargin
            : minEmpty.implicitHeight + 2 * Metrics.sp5 * s;
        return (root.mTop + root.mBottom) * s + header.height + bodyH + hint.height;
    }

    // Sin reclamacion desde QS-FUNC-001: `Toplevels` ya no lanza `hyprctl` al
    // abrir; el modelo de Hyprland esta siempre vivo.
    onActiveChanged: {
        if (!root.active) return;
        root.goneNote = "";
        root.selectAt(0);
        Toplevels.refreshOrder();   // `focusHistoryID` fresco para el orden (QS-FUNC-012c)
    }

    // La elegida desapareció: se queda una válida en su sitio (por posición la vecina).
    onSelChanged: if (root.sel >= 0) root.lastSel = root.sel
    // Ojo: aquí NO se leen `root.sel` ni `root.count`. Medido en ARR-05: el manejador
    // corre antes de que esos bindings se recalculen y los veía con los valores
    // viejos (la selección se quedaba en -1, luego vacía). Se mira `wins` directamente.
    onWinsChanged: {
        for (let i = 0; i < root.wins.length; i++)
            if (root.keyOf(root.wins[i]) === root.selKey) return;
        root.selectAt(root.lastSel);
    }

    function selWin() {
        return (root.sel >= 0 && root.sel < root.count) ? root.wins[root.sel] : null;
    }

    function sameWin(a, b) {
        if (!a || !b) return false;
        if (a.address.length > 0 && b.address.length > 0)
            return a.address === b.address;
        return a.appId === b.appId && a.title === b.title && a.workspace === b.workspace;
    }

    /** Mas de una pantalla: «Open» se parte por monitor. */
    readonly property bool byScreen: Quickshell.screens.length > 1

    /**
     * Grupos de «Open»: `[{ name, here, wins }]`. Esta pantalla primero; una
     * ventana sin monitor conocido cae en «elsewhere» al final. Cada grupo
     * conserva el orden de uso reciente del servicio.
     */
    function openGroups(ops) {
        if (!root.byScreen)
            return [{ name: "", here: false, wins: ops }];
        const order = [root.screenName];
        const sc = Quickshell.screens;
        for (let i = 0; i < sc.length; i++)
            if (order.indexOf(sc[i].name) < 0) order.push(sc[i].name);
        const groups = order.map(function (n) {
            return { name: n, here: n === root.screenName, wins: [] };
        });
        const other = { name: "elsewhere", here: false, wins: [] };
        for (let i = 0; i < ops.length; i++) {
            const k = order.indexOf(ops[i].monitor);
            (k >= 0 ? groups[k] : other).wins.push(ops[i]);
        }
        groups.push(other);
        return groups.filter(function (g) { return g.wins.length > 0; });
    }

    /** Filas del `ListView`: encabezado de seccion + una por ventana. */
    readonly property var rows: {
        const mins = Toplevels.minimizedWindows;
        const out = [];
        if (mins.length > 0) {
            out.push({ header: "Minimized", n: mins.length });
            for (let i = 0; i < mins.length; i++) out.push({ win: mins[i] });
        }
        const groups = root.openGroups(Toplevels.openWindows);
        for (let g = 0; g < groups.length; g++) {
            const gr = groups[g];
            out.push({ header: gr.name.length > 0 ? "Open · " + gr.name : "Open",
                       n: gr.wins.length, here: gr.here });
            for (let i = 0; i < gr.wins.length; i++) out.push({ win: gr.wins[i] });
        }
        return out;
    }

    function rowIndexOfSel() {
        const w = root.selWin();
        if (!w) return -1;
        for (let i = 0; i < root.rows.length; i++)
            if (root.rows[i].win && root.sameWin(root.rows[i].win, w))
                return i;
        return -1;
    }

    function move(delta) {
        if (root.count === 0) return;
        root.selectAt((root.sel < 0 ? root.lastSel : root.sel) + delta);
        const ri = root.rowIndexOfSel();
        if (ri >= 0) list.positionViewAtIndex(ri, ListView.Contain);
    }

    /**
     * `⏎` / clic sobre una ventana: minimizar si esta abierta, restaurar si
     * esta minimizada. Al minimizar se queda abierto para ordenar varias.
     *
     * `→` / clic derecho: enfocar la ventana (rofi `window`, 10.c.3).
     *
     * Restaurar y enfocar necesitan **cerrar el minimizador primero**: mientras
     * esta capa layer-shell tiene el foco de teclado, un `hl.dsp.focus` sobre
     * una ventana no "gana", asi que se cierra y un Timer corto hace el trabajo
     * despues (mismo problema y misma solucion que el `setsid + sleep 0.15` de
     * `window-switcher.sh`). Minimizar no lo necesita: no cambia el foco.
     */
    property var pending: null      // { w, kind: "restore" | "focus" }

    /** ¿Sigue existiendo? Un clic en una fila que se está yendo, o un Enter tardío. */
    function alive(w) {
        const k = root.keyOf(w);
        for (let i = 0; i < root.count; i++)
            if (root.keyOf(root.wins[i]) === k) return true;
        return false;
    }

    function gone() {
        root.goneNote = "Window no longer available";
        goneTimer.restart();
    }

    function act(w) {
        if (!w) return;
        if (!root.alive(w)) { root.gone(); return; }
        if (!w.minimized) {
            Toplevels.minimize(w);
            return;
        }
        if (w.address.length === 0) return;
        root.deferred(w, "restore");
    }

    function focusSel() {
        const w = root.selWin();
        if (!w || w.address.length === 0) return;
        root.deferred(w, "focus");
    }

    function deferred(w, kind) {
        root.pending = { w: w, kind: kind };
        root.requestClose();
        actionTimer.start();
    }

    Timer {
        id: actionTimer
        interval: 130
        onTriggered: {
            const p = root.pending;
            root.pending = null;
            if (!p) return;
            // En los 130 ms del cierre la ventana pudo irse: no se actúa sobre otra.
            if (!root.alive(p.w)) { console.warn("minimizer: window gone before", p.kind); return; }
            if (p.kind === "restore") Toplevels.restore(p.w);
            else Toplevels.focus(p.w);
        }
    }

    // ---- historial (fase 4): la ventana elegida, por identidad ----------------------
    function saveContext() { return { selKey: root.selKey }; }
    /** Si la ventana ya no está, se queda la selección que haya y el host lo avisa. */
    function restoreContext(ctx) {
        if (!ctx || !ctx.selKey) return true;
        for (let i = 0; i < root.wins.length; i++)
            if (root.keyOf(root.wins[i]) === ctx.selKey) { root.selKey = ctx.selKey; return true; }
        return false;
    }

    function keyPressed(event) {
        if (event.key === Qt.Key_Up)        { root.move(-1); event.accepted = true; }
        else if (event.key === Qt.Key_Down) { root.move(1);  event.accepted = true; }
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.act(root.selWin());
            event.accepted = true;
        }
        else if (event.key === Qt.Key_Right || event.key === Qt.Key_L) {
            root.focusSel();
            event.accepted = true;
        }
        // Escape cae sin aceptar: la superficie se cierra.
    }

    function stateTag(w) {
        if (w.minimized) return "minimized";
        if (w.fullscreen) return "fullscreen";
        if (w.activated) return "focused";
        if (w.maximized) return "maximized";
        return "";
    }

    // ---- cabecera ----------------------------------------------------------

        SurfaceHeader {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        s: root.s
        title: "WINDOWS"
        aside: !root.ready ? "…"
        : root.count === 0 ? "no windows"
        : root.count === 1 ? "1 window"
        : root.count + " windows"
        FrameNav {
            s: root.s
            host: root.host
            onCloseRequested: root.requestClose()
        }
    }

    // ---- pie -------------------------------------------------------------

    Text {
        id: hint
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        // 2026-11-12: un renglón fijo cortaba «Esc close» con Text size grande; ahora hasta dos, partidos
        // entre gestos (TextWrap), y la lista de arriba se acorta lo que haga falta
        height: Math.max(13 * root.s, implicitHeight)
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        verticalAlignment: Text.AlignVCenter
        // Qué hace cada gesto sobre la fila elegida, con sus nombres (Minimize /
        // Restore / Focus) y el clic derecho, que antes no se contaba en ningún sitio.
        text: TextWrap.keepSegments(hintText)
        readonly property string hintText: {
            if (root.goneNote.length > 0) return root.goneNote;
            const w = root.selWin();
            if (!w) return "Esc close";
            if (w.address.length === 0) return "Resolving window…  ·  Esc close";
            return (w.minimized
                ? "Enter or click: Restore & focus"
                : "Enter or click: Minimize  ·  → or right-click: Focus") + "  ·  Esc close";
        }
        color: root.goneNote.length > 0 ? Theme.warn : Theme.fgVariant
        font.family: Typography.ui
        font.pixelSize: Typography.caption * root.s
        elide: Text.ElideRight
    }

    // ---- cuerpo --------------------------------------------------------

    Empty {
        id: minEmpty
        y: header.y + header.height + Math.max(Metrics.sp5 * root.s, (parent.height - header.y - header.height - height) * 0.42)
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.ready && root.count === 0
        s: root.s
        maxWidth: parent.width
        glyph: "window"
        text: "No windows"
        hint: "Windows you minimize wait here"
    }

    Text {
        anchors.top: header.bottom
        anchors.topMargin: 12 * root.s
        anchors.left: parent.left
        visible: !root.ready
        text: "Reading windows…"
        color: Theme.fgVariant
        font.family: Typography.ui
        font.pixelSize: Typography.body * root.s
    }

    ListView {
        id: list
        anchors.top: header.bottom
        anchors.topMargin: 4 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: hint.top
        anchors.bottomMargin: 6 * root.s
        visible: root.ready && root.count > 0
        clip: true
        model: root.rows
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: 0

        delegate: Item {
            id: rowItem
            required property int index
            required property var modelData

            width: list.width
            height: rowItem.modelData.header !== undefined ? root.headH : root.rowH

            // -- encabezado de seccion --
            Row {
                visible: rowItem.modelData.header !== undefined
                anchors.left: parent.left
                anchors.leftMargin: 2 * root.s
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6 * root.s

                Text {
                    text: rowItem.modelData.header !== undefined ? rowItem.modelData.header : ""
                    color: Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                    font.weight: Font.DemiBold
                    font.letterSpacing: 0.8 * root.s
                }
                Text {
                    text: rowItem.modelData.n !== undefined ? "· " + rowItem.modelData.n : ""
                    color: Theme.outlineText
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                }
                Text {
                    visible: rowItem.modelData.here === true
                    text: "this screen"
                    color: Theme.primary
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                }
            }

            // -- fila de ventana --
            Item {
                id: winRow
                visible: rowItem.modelData.win !== undefined
                anchors.fill: parent

                readonly property var w: rowItem.modelData.win !== undefined ? rowItem.modelData.win : null
                readonly property bool sel: winRow.w !== null && root.sameWin(winRow.w, root.selWin())
                readonly property bool noAddr: winRow.w !== null && winRow.w.address.length === 0

                // 16A-2
                Accessible.role: Accessible.ListItem
                Accessible.name: winRow.w ? (winRow.w.title.length > 0 ? winRow.w.title : winRow.w.appId) : ""
                Accessible.description: winRow.w ? (winRow.w.appId + (winRow.w.minimized ? " · minimized" : "")) : ""
                Accessible.selected: winRow.sel
                Accessible.onPressAction: if (winRow.w) { winArea.selectHere(); root.act(winRow.w); }

                Rectangle {
                    anchors.fill: parent
                    anchors.topMargin: 1 * root.s
                    anchors.bottomMargin: 1 * root.s
                    radius: Metrics.r(8) * root.s
                    // Elegida = celda + marca; hover = fondo tenue, sin mover la elegida (DESIGN §3).
                    color: winRow.sel ? Theme.selBg : (winArea.containsMouse ? Theme.hoverBg : "transparent")
                    Behavior on color { ColorAnimation { duration: Motion.fast } }
                }

                Rectangle {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    visible: winRow.sel
                    width: 2 * root.s
                    height: parent.height * 0.42
                    radius: Metrics.pill(width)
                    color: Theme.primary
                }

                /**
                 * MINIATURA VIVA (QS-FUNC-016), solo con el ajuste encendido.
                 * `ScreencopyView` sobre el `Toplevel` de Wayland, que desde
                 * QS-FUNC-001 es el handle exacto (`w.handle`). Funciona tambien
                 * con la ventana ya minimizada (medido en la auditoria).
                 *
                 * CAPTURA UNICA, NUNCA `live` -- medido con 10 ventanas de
                 * 1600×900 (2026-09-14): con la fila elegida en vivo, la capa se
                 * redibuja a la frecuencia del monitor (200 Hz aqui: 1378-1962
                 * fotogramas en 10 s) aunque la ventana apenas cambie, y cuesta
                 * 13,5 % de CPU del shell y +15 puntos de GPU. Con todas en
                 * captura unica: 0 % de CPU, GPU en su base, +5,9 MB de RSS.
                 * Cada miniatura se toma al crearse la fila (al abrir).
                 */
                Item {
                    id: thumbBox
                    visible: root.thumbs
                    anchors.left: parent.left
                    anchors.leftMargin: 7 * root.s
                    anchors.verticalCenter: parent.verticalCenter
                    width: root.thumbs ? 88 * root.s : 0
                    height: 50 * root.s
                    clip: true

                    Rectangle {
                        anchors.fill: parent
                        radius: Metrics.r(5) * root.s
                        color: Theme.tileBg
                    }

                    Loader {
                        anchors.fill: parent
                        active: root.thumbs && winRow.w !== null && winRow.w.handle !== null
                        sourceComponent: ScreencopyView {
                            captureSource: winRow.w ? winRow.w.handle : null
                            live: false
                            paintCursor: false
                            // Encaja respetando la proporcion de la ventana.
                            readonly property real ratio: (hasContent && sourceSize.height > 0)
                                ? sourceSize.width / sourceSize.height : 16 / 9
                            width: Math.min(thumbBox.width, thumbBox.height * ratio)
                            height: Math.min(thumbBox.height, thumbBox.width / ratio)
                            x: (thumbBox.width - width) / 2
                            y: (thumbBox.height - height) / 2
                        }
                    }
                }

                Image {
                    id: appIcon
                    // Con miniatura, el icono queda pequeño en su esquina.
                    anchors.left: root.thumbs ? thumbBox.left : parent.left
                    anchors.leftMargin: root.thumbs ? 2 * root.s : 9 * root.s
                    anchors.verticalCenter: root.thumbs ? undefined : parent.verticalCenter
                    anchors.bottom: root.thumbs ? thumbBox.bottom : undefined
                    anchors.bottomMargin: root.thumbs ? 2 * root.s : 0
                    width: (root.thumbs ? 16 : 22) * root.s
                    height: (root.thumbs ? 16 : 22) * root.s
                    source: winRow.w ? Toplevels.iconFor(winRow.w.appId) : ""
                    sourceSize.width: 44
                    sourceSize.height: 44
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    smooth: true
                    visible: status === Image.Ready
                }
                Icon {
                    anchors.fill: appIcon
                    visible: appIcon.status !== Image.Ready
                    name: "monitor"
                    size: 15 * root.s
                    color: Theme.fgVariant
                }

                Column {
                    anchors.left: root.thumbs ? thumbBox.right : appIcon.right
                    anchors.leftMargin: 10 * root.s
                    anchors.right: tag.left
                    anchors.rightMargin: 8 * root.s
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1 * root.s

                    Text {
                        width: parent.width
                        text: winRow.w ? (winRow.w.title.length > 0 ? winRow.w.title : winRow.w.appId) : ""
                        elide: Text.ElideRight
                        color: winRow.noAddr ? Theme.outlineText
                             : (winRow.sel || (winRow.w && winRow.w.activated)) ? Theme.fg : Theme.fgVariant
                        font.family: Typography.ui
                        font.pixelSize: Typography.body * root.s
                        font.weight: (winRow.w && winRow.w.activated) ? Font.DemiBold : Font.Normal
                    }
                    Text {
                        width: parent.width
                        text: {
                            if (!winRow.w) return "";
                            let s = winRow.w.appId;
                            if (winRow.w.workspace.length > 0)
                                s += winRow.w.minimized ? "  ·  minimized"
                                   : "  ·  ws " + winRow.w.workspace;
                            return s;
                        }
                        elide: Text.ElideRight
                        color: Theme.outlineText
                        font.family: Typography.ui
                        font.pixelSize: Typography.caption * root.s
                    }
                }

                Text {
                    id: tag
                    anchors.right: parent.right
                    anchors.rightMargin: 11 * root.s
                    anchors.verticalCenter: parent.verticalCenter
                    text: winRow.w ? root.stateTag(winRow.w) : ""
                    color: (winRow.w && winRow.w.activated) ? Theme.primary : Theme.outlineText
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                }

                MouseArea {
                    id: winArea
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: winRow.w !== null
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    function selectHere() {
                        for (let i = 0; i < root.count; i++)
                            if (root.sameWin(root.wins[i], winRow.w)) { root.selectAt(i); break; }
                    }
                    onClicked: (m) => {
                        selectHere();
                        // izquierdo = minimizar/restaurar · derecho = enfocar
                        if (m.button === Qt.RightButton) root.focusSel();
                        else root.act(winRow.w);
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
