pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Widgets
import "../theme"
import "../services"
import "../components"

/**
 * El catálogo de la tienda de Wallhaven (W2, `rediseno/Antes-de-fase-11.md`): lo que era la zona de
 * resultados de Wallpaper List (10C-1/10C-2), con sitio y para el ratón. La lógica es la de siempre
 * (`Wallhaven`: borrador de filtros, envío explícito, paginación con seed, estados); aquí sólo se
 * pinta.
 *
 *   · Fila de filtros: categorías y contenido como interruptores, Sort ▾ (menú), sentido, y
 *     **Filters** con el número de filtros avanzados activos (abre el panel lateral). Cambiar un
 *     filtro NO pide nada: el pie lo dice («Filters changed · press Search»).
 *   · Los filtros avanzados activos, como etiquetas quitables, sólo si los hay (Reset filters).
 *   · La cuadrícula: miniaturas grandes y nada más; la resolución y el peso salen al pasar el
 *     puntero; «In library» y el estado de descarga se quedan (son lo que decide). Un clic la
 *     selecciona (la ficha y la descarga son de W3).
 *   · Estados: idle · buscando (esqueleto sin resultados; resultados atenuados y una barra con
 *     ellos) · vacío · sin red / 5xx · 429 · clave rechazada · respuesta ilegible · combinación
 *     que no se puede enviar · resultados viejos a la vista (Stale, con Retry) · miniatura que
 *     no carga.
 *   · El movimiento: las tarjetas entran escalonadas SÓLO al llegar una página; nada se mueve
 *     mientras no pase algo (el esqueleto y la barra, sólo mientras se busca).
 */
Item {
    id: cat

    property real s: 1
    /** La pantalla de la tienda (para abrir Settings allí). */
    property string screenName: ""
    /** Lo que el pie dice mientras el puntero está sobre algo que lo explica. */
    property string hoverHint: ""

    readonly property bool hasResults: Wallhaven.results.length > 0
    readonly property var advancedKeys: ["topRange", "atleast", "resolutions", "ratios", "color", "format"]
    readonly property var advanced: { void Wallhaven.draft; return Wallhaven.activeFilters().filter(f => cat.advancedKeys.indexOf(f.key) >= 0); }
    readonly property var problems: { void Wallhaven.draft; void Wallhaven.state; return Wallhaven.problems(); }
    readonly property bool failed: ["unavailable", "limited", "rejected", "error", "invalid"].indexOf(Wallhaven.state) >= 0

    property bool sortOpen: false

    /** Esc: primero lo que está encima (confirmación, menú, ficha, panel); `false` si no había nada. */
    function dismiss() {
        if (Downloads.prep) { Downloads.cancelPrep(); return true; }
        if (cat.sortOpen) { cat.sortOpen = false; return true; }
        if (WallhavenStore.detailOpen) { WallhavenStore.detailOpen = false; return true; }
        if (WallhavenStore.filtersOpen) { WallhavenStore.filtersOpen = false; return true; }
        return false;
    }
    function search(text) {
        cat.sortOpen = false;
        WallhavenStore.filtersOpen = false;
        WallhavenStore.detailOpen = false;
        WallhavenStore.selectedId = "";
        return Wallhaven.search(text);
    }
    /** Buscar desde la ficha (Similar, una etiqueta): el texto pasa también al campo. */
    function searchFor(q) {
        WallhavenStore.text = q;
        cat.search(q);
    }

    // ---- W3: acciones de la ficha, de la tarjeta y del aviso ---------------------------

    /** Descargar nunca aplica. Lo que ya está se dice, y desde una colección se anota sin otra copia. */
    function download(r) {
        if (!r) return;
        const res = Downloads.download(r, Wallhaven.collectionCtx());
        if (!res.ok) cat.toast(res.reason, "warn", "");
        else if (res.state === "exists") cat.toast(res.reason, "info", "");
    }
    /** Apply now: el apply de siempre (el que observa Wallpaper List), a todas las pantallas. */
    property string applying: ""
    function apply(path) {
        // F2c: la tienda sigue sirviendo para mirar y bajar; aplicar, sólo con proveedor
        const why = Wallpaper.whyNot(path);
        if (why.length > 0) { cat.toast("Can't apply here · " + why, "warn", ""); return; }
        cat.applying = path;
        Wallpaper.apply(path);
        cat.toast("Applying " + Wallpaper.baseName(path) + "…", "info", "");
    }
    function showInLibrary(path) { Screens.showInLibraryOn(path, cat.screenName); }
    function act(a) {
        const it = WallhavenStore.detailItem;
        if (!a) return;
        if (a.kind === "download") cat.download(it);
        else if (a.kind === "cancel") Downloads.cancel(a.job);
        else if (a.kind === "retry") Downloads.retry(a.job);
        else if (a.kind === "apply") cat.apply(a.path);
        else if (a.kind === "show") cat.showInLibrary(a.path);
        else if (a.kind === "open" && it) Apps.spawn(["xdg-open", it.page], "xdg-open");   // en su scope (Apps.scoped)
        else if (a.kind === "similar" && it) cat.searchFor("like:" + it.id);
        else if (a.kind === "tag") cat.searchFor("id:" + a.tag);
    }

    /**
     * El aviso de la tienda (download-complete, ya en la biblioteca, un fallo al aplicar): abajo,
     * 6 s, se para con el puntero encima. Con `path`, trae Apply now y Show in library.
     */
    property string toastText: ""
    property string toastTone: "info"
    property string toastPath: ""
    function toast(text, tone, path) {
        cat.toastText = text;
        cat.toastTone = tone;
        cat.toastPath = path || "";
        toastTimer.restart();
    }
    Timer {
        id: toastTimer
        interval: 6000
        running: false
        onTriggered: if (toastArea.containsMouse) toastTimer.restart(); else cat.toastText = ""
    }
    Connections {
        target: Downloads
        function onFinished(id, path) {
            // las de una colección no avisan una a una (serían decenas): su fila dice el progreso
            const it = Downloads.itemOf(id);
            const job = it ? Downloads.jobById(it.job) : null;
            if (job && job.collectionId) return;
            // «no aplicado» lo dice el propio Apply now del aviso
            cat.toast("Downloaded " + Wallpaper.baseName(path).replace(/\.[a-z0-9]+$/i, ""), "ok", path);
        }
    }
    Connections {
        target: Wallpaper
        function onApplied(path) {
            if (path !== cat.applying) return;
            cat.applying = "";
            cat.toast("Applied " + Wallpaper.baseName(path), "ok", "");
        }
        function onFailed(path, reason) {
            if (path !== cat.applying) return;
            cat.applying = "";
            cat.toast("Couldn't apply · " + reason, "warn", "");
        }
    }
    /** El trabajo de la colección abierta (el más reciente), para su progreso y Cancel / Retry pending. */
    readonly property var collJob: { void Downloads.items; void Downloads.jobs;
        return Wallhaven.view === "collection" && Wallhaven.collection ? Downloads.jobOfCollection(Wallhaven.collection.id) : null; }
    readonly property string collJobState: { void Downloads.items; return cat.collJob ? Downloads.jobState(cat.collJob.id) : ""; }
    readonly property bool inSearch: Wallhaven.view === "search"
    function toggleCollections() {
        WallhavenStore.detailOpen = false;
        WallhavenStore.filtersOpen = false;
        cat.sortOpen = false;
        if (Wallhaven.view === "search") Wallhaven.openCollections();
        else Wallhaven.backToSearch();
    }
    function openSettings(path) { Screens.settingsOpenOn(path, cat.screenName); }

    /** Al llegar una página: vuelve arriba y las tarjetas entran (sólo las de ese momento). */
    property real arrivedAt: 0
    Connections {
        target: Wallhaven
        function onResultsChanged() {
            cat.arrivedAt = Date.now();
            grid.positionViewAtBeginning();
        }
    }

    // ---- fila de filtros ------------------------------------------------------------

    Flow {
        id: filterRow
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: implicitHeight
        spacing: 5 * cat.s

        Repeater {
            model: WallhavenStore.filterItems(WallhavenStore.filtersOpen).filter(it => it.kind === "cat" || it.kind === "pur")
            delegate: Row {
                id: fi
                required property var modelData
                required property int index
                spacing: 5 * cat.s
                /** Separador entre categorías y contenido. */
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: fi.index === 3
                    width: 1
                    height: 14 * cat.s
                    color: Theme.hair
                }
                StoreChip {
                    s: cat.s
                    label: fi.modelData.label
                    on: fi.modelData.on
                    disabled: fi.modelData.disabled === true
                    why: fi.modelData.why || ""
                    onHintChanged: cat.hoverHint = hint
                    onActivated: Wallhaven.toggleBit(fi.modelData.kind === "cat" ? "categories" : "purity", fi.modelData.i)
                }
            }
        }

        StoreChip {
            id: sortChip
            s: cat.s
            label: "Sort: " + Wallhaven.sortLabel(Wallhaven.draft.sorting)
            trailing: "chevron-down"
            flipped: cat.sortOpen
            on: cat.sortOpen
            disabled: !cat.inSearch
            why: "Collections only filter by content"
            onHintChanged: cat.hoverHint = hint
            onActivated: {
                const p = sortChip.mapToItem(cat, 0, sortChip.height + 4 * cat.s);
                sortMenu.x = Math.max(0, Math.min(p.x, cat.width - sortMenu.width));
                sortMenu.y = p.y;
                cat.sortOpen = !cat.sortOpen;
            }
        }
        StoreChip {
            s: cat.s
            label: Wallhaven.draft.order === "asc" ? "↑ Ascending" : "↓ Descending"
            on: Wallhaven.draft.order !== "desc"
            disabled: !cat.inSearch
            why: "Collections only filter by content"
            onHintChanged: cat.hoverHint = hint
            onActivated: Wallhaven.setDraft("order", Wallhaven.draft.order === "asc" ? "desc" : "asc")
        }
        StoreChip {
            s: cat.s
            label: "Filters"
            badge: cat.advanced.length
            on: WallhavenStore.filtersOpen
            disabled: !cat.inSearch
            why: "Collections only filter by content"
            onHintChanged: cat.hoverHint = hint
            onActivated: { cat.sortOpen = false; WallhavenStore.detailOpen = false; WallhavenStore.filtersOpen = !WallhavenStore.filtersOpen; }
        }

        /** 10E-1b: las colecciones de la cuenta (necesitan usuario; la clave, para las privadas). */
        StoreChip {
            s: cat.s
            label: "My collections"
            on: !cat.inSearch
            onActivated: cat.toggleCollections()
        }
    }

    // ---- W3: dónde se está en las colecciones, y el trabajo de la abierta ----------------

    Item {
        id: navRow
        anchors.top: filterRow.bottom
        anchors.topMargin: visible ? 8 * cat.s : 0
        anchors.left: parent.left
        anchors.right: parent.right
        visible: !cat.inSearch
        height: visible ? 28 * cat.s : 0

        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8 * cat.s
            StoreChip {
                anchors.verticalCenter: parent.verticalCenter
                s: cat.s
                label: Wallhaven.view === "collection" ? "‹ Collections" : "‹ Search"
                onActivated: {
                    WallhavenStore.detailOpen = false;
                    if (Wallhaven.view === "collection") Wallhaven.backToCollections();
                    else Wallhaven.backToSearch();
                }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, navRow.width * 0.4)
                elide: Text.ElideRight
                text: Wallhaven.view === "collection" && Wallhaven.collection
                    ? Wallhaven.collection.label + "  ·  " + Wallhaven.collection.count
                      + (Wallhaven.collection.count === 1 ? " wallpaper" : " wallpapers")
                      + (Wallhaven.collection.public ? "" : "  ·  private")
                    : "My collections" + (Settings.wallhavenUser ? "  ·  " + Settings.wallhavenUser : "")
                color: Theme.fg
                font.family: Typography.ui
                font.pixelSize: Typography.body * cat.s
                font.weight: Font.DemiBold
            }
        }
        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8 * cat.s
            visible: Wallhaven.view === "collection"
            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: cat.collJob !== null
                text: { void Downloads.items; return cat.collJob ? Downloads.progressText(cat.collJob.id) : ""; }
                color: ["failed", "paused", "interrupted"].indexOf(cat.collJobState) >= 0 ? Theme.warn : Theme.fgVariant
                font.family: Typography.ui
                font.pixelSize: Typography.caption * cat.s
            }
            StoreChip {
                anchors.verticalCenter: parent.verticalCenter
                visible: ["running", "queued"].indexOf(cat.collJobState) >= 0
                s: cat.s
                label: "Cancel"
                onActivated: Downloads.cancel(cat.collJob.id)
            }
            StoreChip {
                anchors.verticalCenter: parent.verticalCenter
                visible: ["failed", "cancelled", "paused", "interrupted", "partial"].indexOf(cat.collJobState) >= 0
                s: cat.s
                label: "Retry pending"
                onActivated: Downloads.retry(cat.collJob.id)
            }
            StoreChip {
                anchors.verticalCenter: parent.verticalCenter
                visible: Wallhaven.collection !== null && Wallhaven.collection.count > 0
                    && ["running", "queued"].indexOf(cat.collJobState) < 0
                s: cat.s
                on: true
                label: "Download collection"
                trailing: "download"
                onActivated: { WallhavenStore.detailOpen = false; Downloads.prepareCollection(Wallhaven.collection); }
            }
        }
    }

    // ---- filtros avanzados activos --------------------------------------------------

    Flow {
        id: activeRow
        anchors.top: navRow.bottom
        anchors.topMargin: visible ? 8 * cat.s : 0
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 5 * cat.s
        visible: cat.advanced.length > 0 && cat.inSearch
        height: visible ? implicitHeight : 0

        Repeater {
            model: cat.advanced
            delegate: StoreChip {
                required property var modelData
                s: cat.s
                label: modelData.label + "  ×"
                swatch: modelData.color || ""
                on: true
                onActivated: Wallhaven.removeFilter(modelData.key, modelData.value)
            }
        }
        StoreChip {
            s: cat.s
            label: "Reset filters"
            onActivated: WallhavenStore.resetAdvanced()
        }
    }

    /** Un fallo con resultados anteriores a la vista: el aviso encima, los resultados siguen. */
    Item {
        id: staleRow
        anchors.top: activeRow.bottom
        anchors.topMargin: visible ? 8 * cat.s : 0
        anchors.left: parent.left
        anchors.right: parent.right
        visible: Wallhaven.stale
        height: visible ? Math.max(staleNotice.implicitHeight, retryStale.implicitHeight) : 0
        Notice {
            id: staleNotice
            anchors.left: parent.left
            anchors.right: retryStale.left
            anchors.rightMargin: 8 * cat.s
            anchors.verticalCenter: parent.verticalCenter
            s: cat.s
            tone: "warn"
            text: Wallhaven.reason + " · showing the last results"
        }
        ActionButton {
            id: retryStale
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: Wallhaven.state !== "limited"
            s: cat.s
            label: "Retry"
            onTriggered: Wallhaven.retry()
        }
    }

    // ---- resultados -----------------------------------------------------------------

    Item {
        id: area
        anchors.top: staleRow.bottom
        anchors.topMargin: 10 * cat.s
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        anchors.bottomMargin: 6 * cat.s
        clip: true

        readonly property int cols: Math.max(2, Math.floor(area.width / (190 * cat.s)))
        readonly property real cellW: Math.floor(area.width / area.cols)
        readonly property real cellH: Math.round(area.cellW * 0.64)
        readonly property real gap: 10 * cat.s

        // la cuadrícula y su barra van juntas: ScrollHint define su propio `visible`, y suelto se
        // quedaba a la vista sobre las colecciones con la cuadrícula oculta
        Item {
            anchors.fill: parent
            visible: cat.hasResults && Wallhaven.view !== "collections"
        GridView {
            id: grid
            anchors.fill: parent
            anchors.rightMargin: -area.gap / 2
            anchors.leftMargin: -area.gap / 2
            // una búsqueda en curso con resultados: se atenúan, siguen ahí
            opacity: Wallhaven.loading ? 0.45 : 1
            Behavior on opacity { NumberAnimation { duration: Motion.fast } }
            cellWidth: Math.floor(grid.width / area.cols)
            cellHeight: Math.round(grid.cellWidth * 0.64)
            cacheBuffer: grid.cellHeight * 2
            boundsBehavior: Flickable.StopAtBounds
            model: Wallhaven.results
            interactive: contentHeight > height

            delegate: Item {
                id: cell
                required property var modelData
                required property int index
                readonly property bool hot: hover.containsMouse || WallhavenStore.testHot === cell.modelData.id
                readonly property bool selected: WallhavenStore.selectedId === cell.modelData.id
                readonly property bool inLibrary: { void Wallpaper.entries; return Wallhaven.installed(cell.modelData.id); }
                readonly property string dl: WallhavenStore.dlLabel(cell.modelData.id)
                readonly property var dlIt: WallhavenStore.dlItem(cell.modelData.id)
                /** Se puede bajar ya: ni está, ni está en curso (una fallida se reintenta en la ficha). */
                readonly property bool canGet: !cell.inLibrary && !cell.dlIt
                width: grid.cellWidth
                height: grid.cellHeight

                Accessible.role: Accessible.ListItem
                Accessible.name: "Wallhaven " + cell.modelData.id + ", " + cell.modelData.resolution
                    + (cell.inLibrary ? ", already in your library" : "")
                Accessible.selected: cell.selected

                /**
                 * Entrada escalonada: sólo las tarjetas creadas al llegar la página (las que se crean
                 * al hacer scroll aparecen sin más). Reduced: un fundido corto y a la vez. Off: nada.
                 */
                opacity: 1
                /** Recorrido de la entrada (sube 14 px mientras aparece; Reduced/Off: sin recorrido). */
                property real rise: 0
                transform: Translate { y: cell.rise }
                // al pulsar se hunde entera, borde incluido (la ficha tarda lo que tarda: el clic se nota ya)
                scale: hover.pressed && !Motion.off ? 0.97 : 1
                Behavior on scale { NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic } }
                Component.onCompleted: {
                    if (Motion.off || Date.now() - cat.arrivedAt > 400) return;
                    cell.opacity = 0;
                    cell.rise = Motion.still ? 0 : 14 * cat.s;
                    enter.start();
                }
                SequentialAnimation {
                    id: enter
                    PauseAnimation { duration: Motion.still ? 0 : Math.min(cell.index, 11) * 26 }
                    ParallelAnimation {
                        NumberAnimation {
                            target: cell
                            property: "opacity"
                            to: 1
                            duration: Motion.still ? Motion.calmMs : Motion.standard
                            easing.type: Easing.OutCubic
                        }
                        NumberAnimation {
                            target: cell
                            property: "rise"
                            to: 0
                            duration: Motion.still ? 0 : Motion.standard + 60
                            easing.type: Easing.OutCubic
                        }
                    }
                }

                ClippingRectangle {
                    id: frame
                    anchors.fill: parent
                    anchors.margins: area.gap / 2
                    radius: Metrics.rMd * cat.s
                    color: Theme.surfaceContainerLow

                    Image {
                        id: img
                        anchors.fill: parent
                        source: cell.modelData.thumb
                        sourceSize.width: 360
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        opacity: img.status === Image.Ready ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: Motion.fast } }
                        // al pasar el puntero, un acercamiento corto (Reduced/Off: nada)
                        scale: cell.hot && !Motion.still ? 1.045 : 1
                        Behavior on scale { NumberAnimation { duration: Motion.standard; easing.type: Easing.OutCubic } }
                    }

                    /** image-load-error: la tarjeta sigue, sin foto. */
                    Column {
                        anchors.centerIn: parent
                        visible: img.status === Image.Error
                        spacing: 4 * cat.s
                        Icon {
                            anchors.horizontalCenter: parent.horizontalCenter
                            name: "image"
                            size: 18 * cat.s
                            color: Theme.outline
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "Preview unavailable"
                            color: Theme.outlineText
                            font.family: Typography.ui
                            font.pixelSize: Typography.micro * cat.s
                        }
                    }

                    /** Lo que se consulta al pasar: resolución, formato y peso. */
                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 38 * cat.s
                        opacity: cell.hot ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: Motion.fast } }
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: "transparent" }
                            GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.72) }
                        }
                        Text {
                            anchors.left: parent.left
                            anchors.bottom: parent.bottom
                            anchors.margins: 7 * cat.s
                            text: cell.modelData.resolution + (cell.canGet ? "   " + cell.modelData.format + " · "
                                + Wallhaven.formatBytes(cell.modelData.bytes) : "")
                            color: "white"
                            font.family: Typography.mono
                            font.pixelSize: Typography.caption * cat.s
                            font.weight: Font.DemiBold
                        }
                        Text {
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            anchors.margins: 7 * cat.s
                            // con el botón de descarga a la derecha, el peso va junto a la resolución
                            visible: !cell.canGet
                            text: cell.modelData.format + " · " + Wallhaven.formatBytes(cell.modelData.bytes)
                            color: Qt.rgba(1, 1, 1, 0.8)
                            font.family: Typography.mono
                            font.pixelSize: Typography.micro * cat.s
                        }
                    }

                    /** Lo que decide: ya está en la biblioteca, o cómo va su descarga. */
                    Rectangle {
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.margins: 6 * cat.s
                        visible: cell.inLibrary
                        width: libText.implicitWidth + 12 * cat.s
                        height: 18 * cat.s
                        radius: Metrics.pill(height)
                        color: Qt.rgba(0, 0, 0, 0.62)
                        Text {
                            id: libText
                            anchors.centerIn: parent
                            text: "In library"
                            color: Theme.primary
                            font.family: Typography.ui
                            font.pixelSize: Typography.micro * cat.s
                            font.weight: Font.DemiBold
                        }
                    }
                    Rectangle {
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.margins: 6 * cat.s
                        visible: cell.dl.length > 0 && !(cell.inLibrary && cell.dl === "Downloaded")
                        width: dlText.implicitWidth + 12 * cat.s
                        height: 18 * cat.s
                        radius: Metrics.pill(height)
                        color: Qt.rgba(0, 0, 0, 0.62)
                        Text {
                            id: dlText
                            anchors.centerIn: parent
                            text: cell.dl
                            color: cell.dl === "Failed" || cell.dl === "Interrupted" ? Theme.warn : "white"
                            font.family: Typography.mono
                            font.pixelSize: Typography.micro * cat.s
                        }
                    }
                }

                /** Mientras baja: una línea fina abajo que avanza con los bytes. */
                Rectangle {
                    anchors.left: frame.left
                    anchors.bottom: frame.bottom
                    anchors.leftMargin: frame.radius / 2
                    anchors.bottomMargin: 3 * cat.s
                    readonly property real span: frame.width - frame.radius
                    visible: cell.dlIt !== null && ["running", "validating"].indexOf(cell.dlIt.state) >= 0
                    height: 3 * cat.s
                    radius: Metrics.pill(height)
                    color: Theme.primary
                    width: !cell.dlIt ? 0 : cell.dlIt.state === "validating" ? span
                        : cell.dlIt.bytes > 0 ? span * Math.min(1, cell.dlIt.got / cell.dlIt.bytes) : 0
                    Behavior on width { NumberAnimation { duration: Motion.fast } }
                }

                /** Borde: fino en reposo, acento al pasar, grueso seleccionada. */
                Rectangle {
                    anchors.fill: frame
                    radius: frame.radius
                    color: "transparent"
                    border.width: cell.selected ? 2.5 * cat.s : 1
                    border.color: cell.selected ? Theme.primary
                        : cell.hot ? Qt.alpha(Theme.primary, 0.55) : Theme.hair
                    Behavior on border.color { ColorAnimation { duration: Motion.fast } }
                }

                MouseArea {
                    id: hover
                    anchors.fill: frame
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: WallhavenStore.openDetail(cell.modelData.id)
                }

                /**
                 * Descarga rápida, sólo al pasar (y sólo si se puede): encima del MouseArea de la
                 * tarjeta, para que su clic no abra la ficha.
                 */
                Rectangle {
                    id: getBtn
                    anchors.right: frame.right
                    anchors.bottom: frame.bottom
                    anchors.margins: 6 * cat.s
                    width: 28 * cat.s
                    height: 28 * cat.s
                    radius: Metrics.pill(width)
                    visible: opacity > 0.01
                    // F2c: sin curl/ImageMagick no aparece; la ficha dice por qué no se puede bajar
                    opacity: cell.canGet && Capabilities.can("wallpaper.download") && (cell.hot || getArea.containsMouse) ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: Motion.fast } }
                    color: getArea.containsMouse ? Theme.primary : Qt.rgba(0, 0, 0, 0.62)
                    Behavior on color { ColorAnimation { duration: Motion.fast } }
                    Accessible.role: Accessible.Button
                    Accessible.name: "Download wallhaven-" + cell.modelData.id
                    Icon {
                        anchors.centerIn: parent
                        name: "download"
                        size: 15 * cat.s
                        color: getArea.containsMouse ? Theme.fgOnPrimary : "white"
                    }
                    MouseArea {
                        id: getArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: cat.download(cell.modelData)
                    }
                }
            }
        }
        ScrollHint { view: grid; s: cat.s }
        }

        /** Buscando sin nada que enseñar: el hueco de una página, respirando (sólo mientras busca). */
        Grid {
            id: skeleton
            anchors.fill: parent
            visible: Wallhaven.loading && !cat.hasResults && Wallhaven.view !== "collections"
            columns: area.cols
            Repeater {
                model: area.cols * 3
                delegate: Item {
                    width: area.cellW
                    height: area.cellH
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: area.gap / 2
                        radius: Metrics.rMd * cat.s
                        color: Theme.surfaceContainerHigh
                    }
                }
            }
            SequentialAnimation on opacity {
                running: skeleton.visible && !Motion.still
                loops: Animation.Infinite
                NumberAnimation { from: 0.9; to: 0.45; duration: 700; easing.type: Easing.InOutSine }
                NumberAnimation { from: 0.45; to: 0.9; duration: 700; easing.type: Easing.InOutSine }
            }
        }

        /** Buscando con resultados: una barra fina arriba (los resultados siguen, atenuados). */
        Rectangle {
            id: progress
            anchors.top: parent.top
            height: 2 * cat.s
            width: parent.width * 0.28
            radius: Metrics.r(1)
            color: Theme.primary
            visible: Wallhaven.loading && cat.hasResults
            NumberAnimation on x {
                running: progress.visible && !Motion.off
                loops: Animation.Infinite
                from: -progress.width
                to: area.width
                duration: 1100
                easing.type: Easing.InOutQuad
            }
        }

        /** Nada que enseñar: nunca se confunde un fallo con «sin resultados». */
        Column {
            anchors.centerIn: parent
            width: Math.min(parent.width, 460 * cat.s)
            visible: !cat.hasResults && !Wallhaven.loading && Wallhaven.view !== "collections"
            spacing: 12 * cat.s
            Empty {
                anchors.horizontalCenter: parent.horizontalCenter
                s: cat.s
                maxWidth: parent.width
                glyph: Wallhaven.state === "idle" || Wallhaven.state === "empty" ? "search" : "web"
                text: Wallhaven.state === "empty" && Wallhaven.view === "collection" ? "This collection has nothing with this content filter"
                    : Wallhaven.state === "empty" ? (Wallhaven.query.length > 0
                        ? "Nothing on Wallhaven matches “" + Wallhaven.query + "”" : "Nothing on Wallhaven with these filters")
                    : Wallhaven.state === "unavailable" ? "Wallhaven unavailable"
                    : Wallhaven.state === "limited" ? "Too many requests to Wallhaven"
                    : Wallhaven.state === "rejected" ? "Wallhaven rejected the API key"
                    : Wallhaven.state === "error" ? "Couldn't read Wallhaven's answer"
                    : Wallhaven.state === "invalid" ? Wallhaven.reason
                    : "Discover wallpapers"
                hint: Wallhaven.state === "unavailable" || Wallhaven.state === "limited" || Wallhaven.state === "error"
                        ? Wallhaven.reason
                    : Wallhaven.state === "rejected" ? "Check the key in Settings · Theme · Wallpaper"
                    : Wallhaven.state === "empty" && Wallhaven.view === "collection" ? "Change SFW / Sketchy / NSFW above, or open another collection"
                    : Wallhaven.state === "empty" ? "Try other words or fewer filters"
                    : Wallhaven.state === "invalid" ? "Change the filters above, then search again"
                    : "Type above and press Enter · nothing is requested until you search"
            }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 8 * cat.s
                ActionButton {
                    visible: Wallhaven.state === "idle"
                    s: cat.s
                    primary: true
                    label: "Browse latest"
                    onTriggered: cat.search("")
                }
                ActionButton {
                    visible: ["unavailable", "error"].indexOf(Wallhaven.state) >= 0
                    s: cat.s
                    primary: true
                    label: "Retry"
                    onTriggered: Wallhaven.retry()
                }
                ActionButton {
                    visible: Wallhaven.state === "rejected" || (Wallhaven.state === "invalid" && Wallhaven.reason.indexOf("NSFW") === 0)
                    s: cat.s
                    label: "Open Settings"
                    onTriggered: cat.openSettings("theme/wallpaper/whKey")
                }
                ActionButton {
                    visible: Wallhaven.state === "empty" && cat.advanced.length > 0
                    s: cat.s
                    label: "Reset filters"
                    onTriggered: { WallhavenStore.resetAdvanced(); cat.search(Wallhaven.query); }
                }
            }
        }

        // ---- W3: My collections (10E-1b), en tarjetas ------------------------------------

        Item {
            anchors.fill: parent
            visible: Wallhaven.view === "collections" && Wallhaven.collections.length > 0
        GridView {
            id: collGrid
            anchors.fill: parent
            anchors.leftMargin: -area.gap / 2
            anchors.rightMargin: -area.gap / 2
            clip: true
            cellWidth: Math.floor(collGrid.width / 3)
            cellHeight: 78 * cat.s
            model: Wallhaven.collections
            boundsBehavior: Flickable.StopAtBounds
            delegate: Item {
                id: ccell
                required property var modelData
                width: collGrid.cellWidth
                height: collGrid.cellHeight
                Accessible.role: Accessible.ListItem
                Accessible.name: ccell.modelData.label + ", " + ccell.modelData.count + " wallpapers"
                    + (ccell.modelData.public ? "" : ", private")
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: area.gap / 2
                    radius: Metrics.rMd * cat.s
                    color: Theme.controlBg(Theme.tileBg, cArea.containsMouse, cArea.pressed && cArea.containsMouse, false)
                    border.width: 1
                    border.color: cArea.containsMouse ? Qt.alpha(Theme.primary, 0.55) : Theme.hair
                    Behavior on color { ColorAnimation { duration: Motion.fast } }
                    Column {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: 14 * cat.s
                        anchors.rightMargin: 14 * cat.s
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4 * cat.s
                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            text: ccell.modelData.label
                            color: Theme.fg
                            font.family: Typography.ui
                            font.pixelSize: Typography.body * cat.s
                            font.weight: Font.DemiBold
                        }
                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            text: ccell.modelData.count + (ccell.modelData.count === 1 ? " wallpaper" : " wallpapers")
                                + "  ·  " + (ccell.modelData.public ? "public" : "private")
                            color: Theme.outlineText
                            font.family: Typography.ui
                            font.pixelSize: Typography.caption * cat.s
                        }
                    }
                    MouseArea {
                        id: cArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Wallhaven.openCollection(ccell.modelData)
                    }
                }
            }
        }
        ScrollHint { view: collGrid; s: cat.s }
        }

        /** Sin colecciones que enseñar: cargando, vacía, falta la cuenta o el motivo del fallo. */
        Column {
            anchors.centerIn: parent
            width: Math.min(parent.width, 460 * cat.s)
            visible: Wallhaven.view === "collections" && Wallhaven.collections.length === 0
            spacing: 12 * cat.s
            Empty {
                anchors.horizontalCenter: parent.horizontalCenter
                s: cat.s
                maxWidth: parent.width
                loading: Wallhaven.collectionsState === "loading"
                glyph: "folder"
                text: Wallhaven.collectionsState === "loading" ? "Loading your collections…"
                    : Wallhaven.collectionsState === "empty" ? "Your account has no collections yet"
                    : Wallhaven.collectionsState === "needsAccount" ? Wallhaven.collectionsReason
                    : Wallhaven.collectionsState === "unavailable" ? "Wallhaven unavailable"
                    : Wallhaven.collectionsReason
                hint: Wallhaven.collectionsState === "needsAccount" ? "Your username and API key go in Settings · Theme · Wallpaper"
                    : Wallhaven.collectionsState === "unavailable" ? Wallhaven.collectionsReason + " · your installed wallpapers are unaffected"
                    : ""
            }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 8 * cat.s
                ActionButton {
                    visible: Wallhaven.collectionsState === "needsAccount"
                    s: cat.s
                    primary: true
                    label: "Open Settings"
                    onTriggered: cat.openSettings(WallhavenAccount.usable ? "theme/wallpaper/whUser" : "theme/wallpaper/whKey")
                }
                ActionButton {
                    visible: ["unavailable", "error", "rejected", "limited"].indexOf(Wallhaven.collectionsState) >= 0
                    s: cat.s
                    primary: true
                    label: "Retry"
                    onTriggered: Wallhaven.openCollections()
                }
            }
        }
    }

    // ---- pie: páginas y estado ------------------------------------------------------

    Item {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 28 * cat.s

        // pastillas como los chips de arriba: su borde es el de la cuadrícula (un ActionButton sin
        // fondo dejaba «‹ Previous» flotando 12 px dentro)
        StoreChip {
            id: prevBtn
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            visible: cat.hasResults && Wallhaven.view !== "collections"
            s: cat.s
            label: "Previous"
            leading: "chevron-left"
            disabled: Wallhaven.page <= 1 || Wallhaven.loading
            onActivated: Wallhaven.prevPage()
        }
        Text {
            anchors.centerIn: parent
            width: Math.min(implicitWidth, parent.width - 2 * Math.max(prevBtn.width, nextBtn.width) - 24 * cat.s)
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
            text: cat.hoverHint.length > 0 ? cat.hoverHint
                : cat.problems.length > 0 && Wallhaven.state !== "invalid" ? cat.problems[0]
                : Wallhaven.dirty && !Wallhaven.loading ? "Filters changed · press Search"
                : Wallhaven.loading ? "Searching Wallhaven…"
                : Wallhaven.view === "collections" ? ""
                : Wallhaven.view === "collection" && cat.hasResults && Wallhaven.collection
                    ? Wallhaven.collection.label + " · Page " + Wallhaven.page + " of " + Wallhaven.lastPage
                      + " · " + Wallhaven.total + (Wallhaven.total === 1 ? " wallpaper" : " wallpapers")
                : cat.hasResults ? (Wallhaven.query.length > 0 ? "“" + Wallhaven.query + "” · " : "")
                    + "Page " + Wallhaven.page + " of " + Wallhaven.lastPage
                    + " · " + Wallhaven.total + (Wallhaven.total === 1 ? " result" : " results")
                : ""
            color: cat.hoverHint.length > 0 ? Theme.fgVariant
                : cat.problems.length > 0 || cat.failed ? Theme.warn
                : Wallhaven.dirty ? Theme.primary : Theme.outline
            font.family: Typography.ui
            font.pixelSize: Typography.caption * cat.s
        }
        StoreChip {
            id: nextBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: cat.hasResults && Wallhaven.view !== "collections"
            s: cat.s
            label: "Next"
            trailing: "chevron-right"
            disabled: Wallhaven.page >= Wallhaven.lastPage || Wallhaven.loading
            onActivated: Wallhaven.nextPage()
        }
    }

    // ---- menú de orden ----------------------------------------------------------------

    /** Un clic fuera del menú lo cierra (y no llega a lo de debajo). */
    MouseArea {
        anchors.fill: parent
        visible: cat.sortOpen
        z: 19
        hoverEnabled: true
        onWheel: (wheel) => wheel.accepted = true
        onClicked: cat.sortOpen = false
    }
    Rectangle {
        id: sortMenu
        z: 20
        width: 170 * cat.s
        height: sortCol.implicitHeight + 12 * cat.s
        radius: Metrics.rMd * cat.s
        color: Theme.surfaceContainerHigh
        border.width: 1
        border.color: Theme.glassBorder
        visible: opacity > 0.01
        opacity: cat.sortOpen ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Motion.fast } }
        // se despliega desde el chip (Reduced/Off: sólo aparece)
        transformOrigin: Item.TopLeft
        scale: cat.sortOpen || Motion.still ? 1 : 0.94
        Behavior on scale { NumberAnimation { duration: Motion.standard; easing.type: Easing.OutCubic } }

        Column {
            id: sortCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 6 * cat.s
            Repeater {
                model: Wallhaven.sortings
                delegate: Rectangle {
                    id: opt
                    required property var modelData
                    readonly property bool on: Wallhaven.draft.sorting === opt.modelData.key
                    width: sortCol.width
                    height: 28 * cat.s
                    radius: Metrics.rSm * cat.s
                    color: optArea.containsMouse ? Theme.hoverBg : "transparent"
                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 10 * cat.s
                        anchors.verticalCenter: parent.verticalCenter
                        text: opt.modelData.label
                        color: opt.on ? Theme.primary : Theme.fg
                        font.family: Typography.ui
                        font.pixelSize: Typography.caption * cat.s
                        font.weight: opt.on ? Font.DemiBold : Font.Normal
                    }
                    Icon {
                        anchors.right: parent.right
                        anchors.rightMargin: 10 * cat.s
                        anchors.verticalCenter: parent.verticalCenter
                        visible: opt.on
                        name: "check"
                        size: 12 * cat.s
                    }
                    MouseArea {
                        id: optArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { Wallhaven.setDraft("sorting", opt.modelData.key); cat.sortOpen = false; }
                    }
                }
            }
        }
    }

    // ---- panel Filters ------------------------------------------------------------------

    /** Velo sobre los resultados mientras el panel está abierto; un clic lo cierra. */
    Rectangle {
        anchors.top: filterRow.bottom
        anchors.topMargin: 8 * cat.s
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        z: 9
        radius: Metrics.rMd * cat.s
        color: Qt.rgba(0, 0, 0, 0.28)
        visible: opacity > 0.01
        opacity: WallhavenStore.filtersOpen ? 1 : 0
        enabled: WallhavenStore.filtersOpen
        Behavior on opacity { NumberAnimation { duration: Motion.fast } }
        MouseArea {
            anchors.fill: parent
            // la rueda y el hover tampoco: si no, la cuadrícula de debajo se movía
            hoverEnabled: true
            onWheel: (wheel) => wheel.accepted = true
            onClicked: WallhavenStore.filtersOpen = false
        }
    }
    Item {
        id: panelClip
        enabled: WallhavenStore.filtersOpen
        anchors.top: filterRow.bottom
        anchors.topMargin: 8 * cat.s
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        width: 330 * cat.s
        z: 10
        clip: true
        // Reduced/Off keep x at zero: opacity must also hide the input surface.
        visible: Motion.still ? panel.opacity > 0.01 : panel.x < panelClip.width - 1

        Rectangle {
            id: panel
            width: parent.width
            height: parent.height
            // sale desde la derecha (Reduced/Off: sin recorrido, sólo aparece)
            x: WallhavenStore.filtersOpen || Motion.still ? 0 : panelClip.width
            opacity: WallhavenStore.filtersOpen ? 1 : (Motion.still ? 0 : 1)
            Behavior on x { NumberAnimation { duration: Motion.standard; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: Motion.calmMs } }
            radius: Metrics.rMd * cat.s
            color: Theme.surfaceContainer
            border.width: 1
            border.color: Theme.glassBorder
            // los clics dentro del panel no llegan al velo, ni la rueda al acabar su scroll
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onWheel: (wheel) => wheel.accepted = true
            }

            Text {
                id: panelTitle
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.margins: 14 * cat.s
                text: "Filters"
                color: Theme.fg
                font.family: Typography.ui
                font.pixelSize: Typography.body * cat.s
                font.weight: Font.DemiBold
            }
            Text {
                anchors.baseline: panelTitle.baseline
                anchors.right: parent.right
                anchors.rightMargin: 14 * cat.s
                text: "Applied when you search"
                color: Theme.outlineText
                font.family: Typography.ui
                font.pixelSize: Typography.micro * cat.s
            }

            Flickable {
                id: flick
                anchors.top: panelTitle.bottom
                anchors.topMargin: 10 * cat.s
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: panelActions.top
                anchors.leftMargin: 14 * cat.s
                anchors.rightMargin: 14 * cat.s
                anchors.bottomMargin: 20 * cat.s
                contentWidth: width
                contentHeight: secCol.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Column {
                    id: secCol
                    width: flick.width
                    spacing: 14 * cat.s

                    Repeater {
                        model: WallhavenStore.moreSections
                        delegate: Column {
                            id: sec
                            required property var modelData
                            required property int index
                            width: secCol.width
                            spacing: 6 * cat.s
                            Text {
                                text: sec.modelData.title
                                color: Theme.fg
                                font.family: Typography.ui
                                font.pixelSize: Typography.caption * cat.s
                                font.weight: Font.DemiBold
                            }
                            Text {
                                width: sec.width
                                wrapMode: Text.WordWrap
                                text: sec.modelData.note
                                color: Theme.outlineText
                                font.family: Typography.ui
                                font.pixelSize: Typography.micro * cat.s
                            }
                            Flow {
                                width: sec.width
                                spacing: 5 * cat.s
                                Repeater {
                                    model: WallhavenStore.moreItems.filter(it => it.sec === sec.index)
                                    delegate: StoreChip {
                                        id: mchip
                                        required property var modelData
                                        s: cat.s
                                        label: mchip.modelData.label
                                        swatch: mchip.modelData.swatch || ""
                                        on: mchip.modelData.on
                                        disabled: mchip.modelData.disabled === true
                                        why: "Choose the Toplist order first"
                                        onHintChanged: cat.hoverHint = hint
                                        onActivated: {
                                            const it = mchip.modelData;
                                            if (it.kind === "range") Wallhaven.setDraft("topRange", it.value);
                                            else if (it.kind === "min") Wallhaven.setAtleast(it.value);
                                            else if (it.kind === "custom") { customInput.text = ""; customBox.editing = true; customInput.forceActiveFocus(); }
                                            else if (it.kind === "res") Wallhaven.toggleIn("resolutions", it.value);
                                            else if (it.kind === "ratio") Wallhaven.toggleIn("ratios", it.value);
                                            else if (it.kind === "color") Wallhaven.setDraft("color", it.value);
                                            else if (it.kind === "format") Wallhaven.setDraft("format", it.value);
                                        }
                                    }
                                }
                            }
                            /** La mínima personalizada: se escribe aquí y Enter la valida. */
                            Rectangle {
                                id: customBox
                                property bool editing: false
                                visible: sec.index === 1 && customBox.editing
                                width: 150 * cat.s
                                height: 26 * cat.s
                                radius: Metrics.rSm * cat.s
                                color: Theme.tileBg
                                border.width: 1
                                border.color: Theme.selBorder
                                TextInput {
                                    id: customInput
                                    anchors.fill: parent
                                    anchors.leftMargin: 8 * cat.s
                                    anchors.rightMargin: 8 * cat.s
                                    verticalAlignment: TextInput.AlignVCenter
                                    color: Theme.fg
                                    font.family: Typography.mono
                                    font.pixelSize: Typography.caption * cat.s
                                    Accessible.role: Accessible.EditableText
                                    Accessible.name: "Custom minimum resolution"
                                    function commit() {
                                        const v = customInput.text.trim().toLowerCase().replace("×", "x");
                                        customBox.editing = false;
                                        if (Wallhaven.validCustom(v)) Wallhaven.setAtleast(v);
                                        else if (v.length > 0) cat.hoverHint = "Minimum resolution must look like 2560x1440";
                                    }
                                    Keys.onReturnPressed: customInput.commit()
                                    Keys.onEnterPressed: customInput.commit()
                                    Keys.onEscapePressed: customBox.editing = false
                                    onActiveFocusChanged: if (!activeFocus && customBox.editing) customInput.commit()
                                    Text {
                                        anchors.fill: parent
                                        verticalAlignment: Text.AlignVCenter
                                        visible: customInput.text.length === 0
                                        text: "2560x1080 · Enter"
                                        color: Theme.outlineText
                                        font: customInput.font
                                    }
                                }
                            }
                        }
                    }

                    Text {
                        width: secCol.width
                        wrapMode: Text.WordWrap
                        text: "Syntax: tag · -exclude · +require · @uploader · id:123 · like:abc123 (similar)"
                        color: Theme.outlineText
                        font.family: Typography.ui
                        font.pixelSize: Typography.micro * cat.s
                    }
                }
            }
            ScrollHint { view: flick; s: cat.s }

            /**
             * Reset y Search a lo ancho, con los bordes del contenido del panel (antes dos botones de
             * formas distintas, apretados a la derecha). Una regla los separa de la lista.
             */
            Rectangle {
                anchors.left: parent.left; anchors.right: parent.right
                anchors.bottom: panelActions.top; anchors.bottomMargin: 10 * cat.s
                height: 1
                color: Theme.hair
            }
            Item {
                id: panelActions
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 14 * cat.s
                height: 30 * cat.s
                StoreChip {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    implicitHeight: 30 * cat.s
                    width: (parent.width - 8 * cat.s) * 0.38
                    s: cat.s
                    label: "Reset"
                    leading: "reload"
                    disabled: cat.advanced.length === 0
                    onActivated: WallhavenStore.resetAdvanced()
                }
                StoreChip {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    implicitHeight: 30 * cat.s
                    width: (parent.width - 8 * cat.s) * 0.62
                    s: cat.s
                    strong: true
                    label: "Search"
                    leading: "search"
                    disabled: cat.problems.length > 0 || Wallhaven.loading
                    onActivated: cat.search(WallhavenStore.text)
                }
            }
        }
    }

    // ---- W3: la ficha --------------------------------------------------------------------

    /** Velo sobre los resultados mientras la ficha está abierta; un clic la cierra. */
    Rectangle {
        anchors.top: filterRow.bottom
        anchors.topMargin: 8 * cat.s
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        z: 11
        radius: Metrics.rMd * cat.s
        color: Qt.rgba(0, 0, 0, 0.28)
        visible: opacity > 0.01
        opacity: WallhavenStore.detailOpen && WallhavenStore.detailItem !== null ? 1 : 0
        enabled: sheetClip.shown
        Behavior on opacity { NumberAnimation { duration: Motion.fast } }
        MouseArea {
            anchors.fill: parent
            // la rueda y el hover tampoco: si no, la cuadrícula de debajo se movía
            hoverEnabled: true
            onWheel: (wheel) => wheel.accepted = true
            onClicked: WallhavenStore.detailOpen = false
        }
    }
    Item {
        id: sheetClip
        enabled: sheetClip.shown
        anchors.top: filterRow.bottom
        anchors.topMargin: 8 * cat.s
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        width: Math.min(410 * cat.s, cat.width)
        z: 12
        clip: true
        readonly property bool shown: WallhavenStore.detailOpen && WallhavenStore.detailItem !== null
        visible: Motion.still ? sheet.opacity > 0.01 : sheet.x < sheetClip.width - 1

        WallhavenDetail {
            id: sheet
            width: parent.width
            height: parent.height
            s: cat.s
            // sale desde la derecha, como Filters (Reduced/Off: sin recorrido)
            x: sheetClip.shown || Motion.still ? 0 : sheetClip.width
            opacity: sheetClip.shown ? 1 : (Motion.still ? 0 : 1)
            Behavior on x { NumberAnimation { duration: Motion.standard; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: Motion.calmMs } }
            onAct: (a) => cat.act(a)
            onCloseRequested: WallhavenStore.detailOpen = false
        }
    }

    // ---- W3: Download collection, confirmación (10E-2) --------------------------------------

    /**
     * Mientras se recorren las páginas dice cuántas lleva; lista, dice exactamente qué se hará
     * (nombre, Content, accesibles, ya instaladas, a descargar). Nada se baja hasta confirmar, y
     * nada se aplica. Modal sobre la tienda: el velo no deja tocar lo de debajo.
     */
    readonly property var prep: Downloads.prep
    readonly property int prepTodo: cat.prep && cat.prep.state === "ready" ? cat.prep.items.length - cat.prep.installed : 0
    Rectangle {
        anchors.fill: parent
        anchors.margins: -12 * cat.s
        z: 30
        radius: Metrics.rLg * cat.s
        color: Qt.rgba(0, 0, 0, 0.45)
        visible: opacity > 0.01
        opacity: cat.prep !== null ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Motion.fast } }
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onWheel: (wheel) => wheel.accepted = true
        }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(440 * cat.s, parent.width - 40 * cat.s)
            height: confirmCol.implicitHeight + 40 * cat.s
            radius: Metrics.rMd * cat.s
            color: Theme.surfaceContainerHigh
            border.width: 1
            border.color: Theme.glassBorder
            scale: cat.prep !== null || Motion.still ? 1 : 0.97
            Behavior on scale { NumberAnimation { duration: Motion.standard; easing.type: Easing.OutCubic } }

            Column {
                id: confirmCol
                anchors.centerIn: parent
                width: parent.width - 40 * cat.s
                spacing: 10 * cat.s

                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: !cat.prep ? "" : "Download collection “" + cat.prep.collection.label + "”" + (cat.prep.state === "ready" ? "?" : "")
                    color: Theme.fg
                    font.family: Typography.ui
                    font.pixelSize: Typography.body * cat.s
                    font.weight: Font.DemiBold
                }
                Repeater {
                    model: !cat.prep ? [] : cat.prep.state === "ready" ? [
                        "Content: " + ["SFW", "Sketchy", "NSFW"].filter((n, i) => cat.prep.purity.charAt(i) === "1").join(" + ")
                            + " · only what this content filter allows",
                        cat.prep.items.length + (cat.prep.items.length === 1 ? " wallpaper" : " wallpapers") + " you can access, across "
                            + cat.prep.lastPage + (cat.prep.lastPage === 1 ? " page" : " pages"),
                        cat.prep.installed > 0 ? cat.prep.installed + " already in your library · linked to this collection, not downloaded again" : "",
                        cat.prepTodo + " to download · at most two at a time · nothing is applied"
                    ] : cat.prep.state === "listing" ? [
                        "Reading every page with the current content filter… page " + Math.max(1, cat.prep.page)
                            + (cat.prep.lastPage > 0 ? " of " + cat.prep.lastPage : ""),
                        cat.prep.items.length + " found so far · nothing is downloaded before you confirm"
                    ] : [cat.prep.reason]
                    delegate: Text {
                        required property var modelData
                        visible: modelData.length > 0
                        width: confirmCol.width
                        wrapMode: Text.WordWrap
                        text: modelData
                        color: cat.prep && (cat.prep.state === "failed" || cat.prep.state === "limited") ? Theme.warn : Theme.fgVariant
                        font.family: Typography.ui
                        font.pixelSize: Typography.caption * cat.s
                    }
                }
                Row {
                    anchors.right: parent.right
                    spacing: 8 * cat.s
                    ActionButton {
                        s: cat.s
                        label: cat.prep && cat.prep.state === "failed" ? "Close" : "Cancel"
                        onTriggered: Downloads.cancelPrep()
                    }
                    ActionButton {
                        visible: cat.prep !== null && cat.prep.state === "ready"
                        s: cat.s
                        primary: true
                        label: cat.prepTodo > 0 ? "Download " + cat.prepTodo
                            : "Link " + (cat.prep ? cat.prep.items.length : 0) + " to this collection"
                        onTriggered: Downloads.confirmCollection()
                    }
                }
            }
        }
    }

    // ---- W3: el aviso ---------------------------------------------------------------------

    Rectangle {
        id: toastBox
        // centrado en lo que queda libre: con la ficha abierta no tapa sus botones
        readonly property real room: sheetClip.shown ? cat.width - sheetClip.width - 12 * cat.s : cat.width
        x: Math.max(0, (toastBox.room - toastBox.width) / 2)
        Behavior on x { NumberAnimation { duration: Motion.standard; easing.type: Easing.OutCubic } }
        anchors.bottom: footer.top
        anchors.bottomMargin: 10 * cat.s
        z: 25
        width: Math.min(toastRow.implicitWidth + 28 * cat.s, toastBox.room - 16 * cat.s)
        height: 38 * cat.s
        radius: Metrics.pill(height)
        color: Theme.surfaceContainerHigh
        border.width: 1
        border.color: cat.toastTone === "warn" ? Qt.alpha(Theme.warn, 0.6)
            : cat.toastTone === "ok" ? Qt.alpha(Theme.primary, 0.45) : Theme.glassBorder
        visible: opacity > 0.01
        opacity: cat.toastText.length > 0 ? 1 : 0
        // entra desde abajo, poco (Reduced/Off: sólo aparece)
        transform: Translate { y: cat.toastText.length > 0 || Motion.still ? 0 : 10 * cat.s
            Behavior on y { NumberAnimation { duration: Motion.standard; easing.type: Easing.OutCubic } } }
        Behavior on opacity { NumberAnimation { duration: Motion.fast } }

        MouseArea {
            id: toastArea
            anchors.fill: parent
            hoverEnabled: true
        }
        Row {
            id: toastRow
            anchors.centerIn: parent
            spacing: 10 * cat.s
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, toastBox.room - 44 * cat.s
                    - (cat.toastPath.length > 0 ? toastApply.width + toastShow.width + 20 * cat.s : 0))
                elide: Text.ElideMiddle
                text: cat.toastText
                color: cat.toastTone === "warn" ? Theme.warn : Theme.fg
                font.family: Typography.ui
                font.pixelSize: Typography.caption * cat.s
            }
            ActionButton {
                id: toastApply
                anchors.verticalCenter: parent.verticalCenter
                visible: cat.toastPath.length > 0
                s: cat.s
                primary: true
                label: "Apply now"
                onTriggered: { const p = cat.toastPath; cat.toastText = ""; cat.apply(p); }
            }
            ActionButton {
                id: toastShow
                anchors.verticalCenter: parent.verticalCenter
                visible: cat.toastPath.length > 0
                s: cat.s
                label: "Show in library"
                onTriggered: { const p = cat.toastPath; cat.toastText = ""; cat.showInLibrary(p); }
            }
        }
    }
}
