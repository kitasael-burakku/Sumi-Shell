pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "../theme"
import "../services"
import "../components"

/**
 * Paleta de la CLI `minimaru` (Fase 10.g).
 *
 * `sumi` (fish, ~415 líneas) tiene diez verbos. Cada uno ya llega al shell
 * por algún lado —island, Dashboard, cara hover, fila MODE—, pero no había un
 * sitio que fuera *la CLI en sí*: teclear el nombre de un comando y ⏎. Esto lo
 * es. **No** reimplementa ningún verbo (ADR-13): los seis de terminal
 * (`health`, `clean`, `update`, `doctor`, `diskbackup`) abren una terminal con
 * `sumi <verbo>` — la misma orden que teclearías tú—, y los cuatro con
 * superficie (`theme`, `wall`, `mode`→dashboard, `dashboard`) morfan a ella.
 * `menu` asoma la cara de iconos.
 *
 * `SUPER+CTRL+X` ("execute"). `Esc` cierra.
 *
 * Rediseño 11B: el catálogo y el ejecutor son `services/Commands`, los mismos que usa la pestaña
 * Tasks del Dashboard. Lo que corre en el panel (`diskbackup`) ya no abre Kitty: lleva a
 * la capa Tasks (etapa B del Dashboard) con ese trabajo, que pide la confirmación y lo sigue.
 */
Surface {
    id: root

    mTop: Metrics.sp4
    mLeft: Metrics.sp5
    mRight: Metrics.sp5
    mBottom: Metrics.sp4

    signal requestSurface(string name)

    // dos renglones (orden y descripción): auditoría tipográfica 2026-11-18, alto por la familia y el Text size
    readonly property real rowH: Typography.box(46, [Typography.body, Typography.label], root.s)

    property string query: ""
    property int sel: 0

    /** El catálogo compartido (services/Commands) y la búsqueda con sus tres vacíos. */
    readonly property var verbs: Commands.catalog
    readonly property var result: Commands.filter(root.query)
    readonly property var shown: root.result.rows
    readonly property int count: root.shown.length

    /**
     * El alto que pide (paneles que se adaptan, 2026-11-17): filas de `rowH` contadas en los datos (nunca el maquetado
     * de la lista, 9.f.2) o el aviso de vacío, más cabecera, regla y pie. El host lo acota a `Metrics.cliH`.
     */
    readonly property real fitH: {
        const s = root.s;
        const listH = root.count > 0 ? Math.min(root.count, 1 + Math.ceil(Metrics.cliH * s / root.rowH)) * root.rowH
            : paletteEmpty.anchors.topMargin + paletteEmpty.implicitHeight + Metrics.sp5 * s - list.anchors.topMargin;
        return (root.mTop + root.mBottom) * s + header.height + rule.anchors.topMargin + rule.height
            + list.anchors.topMargin + listH + list.anchors.bottomMargin + hint.height;
    }

    onShownChanged: if (root.sel >= root.count) root.sel = Math.max(0, root.count - 1)

    onOpenChanged: if (open) {
        root.query = "";
        search.clear();
        root.sel = 0;
        Qt.callLater(search.focusField);
    }

    function move(delta) {
        if (root.count === 0)
            return;
        root.sel = Math.max(0, Math.min(root.count - 1, root.sel + delta));
        list.positionViewAtIndex(root.sel, ListView.Contain);
    }

    function activate() {
        if (root.sel < 0 || root.sel >= root.count)
            return;
        const v = root.shown[root.sel];
        // Lo del panel lo arranca la capa Tasks (confirmación y seguimiento): se le encarga.
        if (v.runs === "panel") Commands.request(v.id, root.screenName);
        const r = Commands.run(v.id);
        if (!r.ok) return;
        if (r.to.length > 0) root.requestSurface(r.to);
        else root.requestClose();
    }

    /** El campo se queda el teclado; el host sólo ve lo que rechaza. */
    function keyPressed(event) {}

    // ---- historial (fase 4) -------------------------------------------------------
    function saveContext() {
        const v = root.shown[root.sel];
        return { query: root.query, sel: v ? v.id : "" };
    }
    function restoreContext(ctx) {
        if (!ctx) return true;
        search.text = ctx.query || "";
        for (let i = 0; i < root.shown.length; i++)
            if (root.shown[i].id === ctx.sel) { root.sel = i; break; }
        return true;
    }

    // ---- cabecera -------------------------------------------------------

    Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 32 * root.s

        Icon {
            id: glyph
            anchors.left: parent.left
            anchors.leftMargin: 4 * root.s
            anchors.verticalCenter: parent.verticalCenter
            name: "terminal"
            size: 14 * root.s
            color: Theme.primary
        }

        SearchField {
            id: search
            anchors.left: glyph.right
            anchors.leftMargin: 10 * root.s
            anchors.right: counter.left
            anchors.rightMargin: 8 * root.s
            anchors.verticalCenter: parent.verticalCenter
            height: parent.height
            s: root.s
            placeholder: "sumi — run a command"
            onTextChanged: { root.query = text; root.sel = 0; }
            onMoved: (d) => root.move(d)
            onAccepted: root.activate()
            onDismissed: root.requestClose()
            // 16G: un solo grupo (la lista): Tab y Mayús+Tab la recorren como ↓/↑ (DESIGN §3)
            backtabs: true
            onTabbed: root.move(1)
            onBacktabbed: root.move(-1)
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
            id: counter
            anchors.right: frameNav.left
            anchors.rightMargin: 6 * root.s
            anchors.verticalCenter: parent.verticalCenter
            text: root.count + " / " + root.verbs.length
            color: Theme.outlineText
            font.family: Typography.mono
            font.pixelSize: Typography.caption * root.s
            font.features: ({ "tnum": 1 })
        }
    }

    Rectangle {
        id: rule
        anchors.top: header.bottom
        anchors.topMargin: Metrics.sp3 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: Theme.hair
    }

    // ---- pie -----------------------------------------------------------

    Text {
        id: hint
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: Typography.box(13, Typography.caption, root.s)
        verticalAlignment: Text.AlignVCenter
        text: root.count === 0 ? "Esc close"
            : "↑↓ select  ·  Enter run  ·  Esc close"
        color: Theme.fgVariant
        font.family: Typography.ui
        font.pixelSize: Typography.caption * root.s
        elide: Text.ElideRight
    }

    // ---- lista ---------------------------------------------------------

    ListView {
        id: list
        anchors.top: rule.bottom
        anchors.topMargin: Metrics.sp3 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: hint.top
        anchors.bottomMargin: Metrics.sp3 * root.s
        clip: true
        model: root.shown
        currentIndex: root.sel
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: 0

        delegate: Item {
            id: row
            required property int index
            required property var modelData
            width: list.width
            height: root.rowH

            readonly property bool selRow: row.index === root.sel

            Rectangle {
                anchors.fill: parent
                anchors.topMargin: 1 * root.s
                anchors.bottomMargin: 1 * root.s
                radius: Metrics.r(7) * root.s
                // Elegida = celda + marca; hover = fondo tenue, sin mover la elegida (DESIGN §3).
                color: row.selRow ? Theme.selBg : (rowArea.containsMouse ? Theme.hoverBg : "transparent")
                Behavior on color { ColorAnimation { duration: Motion.fast } }
            }

            Rectangle {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                visible: row.selRow
                width: 2 * root.s
                height: parent.height * 0.42
                radius: Metrics.pill(width)
                color: Theme.primary
            }

            readonly property string where: Commands.whereLong(row.modelData)
            Accessible.role: Accessible.ListItem
            Accessible.name: "sumi " + row.modelData.id
            Accessible.description: row.modelData.desc + ". " + row.where
            Accessible.selected: row.selRow

            Icon {
                id: rowIcon
                anchors.left: parent.left
                anchors.leftMargin: 10 * root.s
                anchors.verticalCenter: parent.verticalCenter
                name: row.modelData.glyph
                size: 15 * root.s
                color: row.selRow ? Theme.primary : Theme.fgVariant
            }

            Column {
                // columna fija, no `rowIcon.right`: el glifo no tiene ancho fijo y cada icono movía el
                // texto un par de píxeles (2026-10-01, «minimaru doctor» salía corrido)
                anchors.left: parent.left
                anchors.leftMargin: (10 + 15 + 11) * root.s
                anchors.right: tag.left
                anchors.rightMargin: 8 * root.s
                anchors.verticalCenter: parent.verticalCenter
                spacing: Metrics.sp1 * root.s

                Text {
                    text: "sumi " + row.modelData.id
                    color: row.selRow ? Theme.fg : Theme.fgVariant
                    font.family: Typography.mono
                    font.pixelSize: Typography.body * root.s
                    font.weight: row.selRow ? Font.DemiBold : Font.Normal
                }
                Text {
                    width: parent.width
                    text: row.modelData.desc
                    elide: Text.ElideRight
                    // micro → caption: la descripción es lo que se lee para elegir (ARR-05).
                    color: Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                }
            }

            /**
             * Dónde acaba la orden (futuresystem-CLI: «cada fila indicará si abre una
             * surface, corre dentro del panel o pasa a Kitty»). Era «TERMINAL /
             * SURFACE / MENU» en versales a tamaño micro; ahora nombra el sitio.
             */
            Text {
                id: tag
                anchors.right: parent.right
                anchors.rightMargin: 10 * root.s
                anchors.top: parent.top
                anchors.topMargin: 8 * root.s
                width: Math.min(implicitWidth, row.width * 0.28)
                elide: Text.ElideRight
                text: Commands.whereText(row.modelData)
                color: row.selRow ? Theme.fgVariant : Theme.outlineText
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
            }

            MouseArea {
                id: rowArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.sel = row.index; root.activate(); }
            }
        }
    }

    /**
     * La barra de desplazamiento (2026-09-15). Hermana de la lista, no hija:
     * un hijo de un `ListView` viaja dentro del contenido y se iria con el scroll.
     */
    ScrollHint { view: list; s: root.s }

    /** Sin coincidencias o sin catálogo: estados propios (11B), no una línea en el pie. */
    Empty {
        id: paletteEmpty
        anchors.top: rule.bottom
        anchors.topMargin: Metrics.sp5 * root.s
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.count === 0
        s: root.s
        maxWidth: parent.width
        glyph: root.result.state === "unavailable" ? "alert" : "search"
        text: root.result.state === "unavailable" ? "Commands unavailable" : "No matching command"
        hint: root.result.state === "unavailable" ? "The sumi catalog could not be loaded"
            : "Search by name or by a word of its description"
    }

}
