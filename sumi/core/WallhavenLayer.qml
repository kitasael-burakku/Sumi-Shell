pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import "../theme"
import "../services"
import "../components"

/**
 * La tienda de Wallhaven como ventana flotante (antes de la fase 11,
 * `rediseno/Antes-de-fase-11.md`). Decidido con el usuario el 2026-09-26: **capa del shell**, no
 * una `FloatingWindow` de Hyprland — Quickshell 0.3.1 no expone el movimiento desde la aplicación
 * (sólo se movería con Super+arrastrar) y una ventana real saldría en el minimizador y en Alt+Tab.
 *
 * Una capa `Top` a pantalla completa y transparente; lo único que recibe ratón es la tarjeta
 * (`mask`). La tarjeta se arrastra por su cabecera dentro del monitor, menos `Metrics.storeMargin`
 * por lado: nunca queda fuera (futureSettingssurface: «no se permite arrastrar arbitrariamente una
 * surface fuera de pantalla»). Al soltar, la posición se guarda en `WallhavenStore` para esta
 * pantalla y esta sesión.
 *
 * `Top` y no `Overlay`: el island y sus surfaces (capa Overlay) quedan encima, así que Wallpaper
 * List abierto desde aquí («Show in library») se ve sobre la tienda. Teclado `OnDemand`: se lo da el
 * compositor al pulsar dentro (el campo de búsqueda); la tienda está hecha para el ratón.
 *
 * La carga el `Screen` de la pantalla dueña (`WallhavenStore.screen`) y sigue cargada oculta: el
 * estado de la vista se conserva al cerrar y reabrir.
 */
PanelWindow {
    id: win

    required property var targetScreen
    readonly property string name: win.targetScreen ? win.targetScreen.name : ""
    readonly property real s: Settings.uiScale

    /** Visible y usable: abierta en esta pantalla y sin la sesión bloqueada (ISLAND.md §3.2). */
    readonly property bool shown: WallhavenStore.open && WallhavenStore.screen === win.name && !Lock.engaged
    readonly property real margin: Metrics.storeMargin * win.s
    readonly property real topInset: Math.max(Metrics.reservedH(win.s), Metrics.reservedBarH(win.s))
    /** 2026-11-19: la barra permanente abajo o a un lado no se tapa: su franja, además del margen (Screen.barInset). */
    readonly property var barHost: Screens.byName(win.targetScreen ? String(win.targetScreen.name) : "")
    readonly property real leftInset: win.margin + (win.barHost ? win.barHost.barInset("left") : 0)
    readonly property real rightInset: win.margin + (win.barHost ? win.barHost.barInset("right") : 0)
    readonly property real bottomInset: win.margin + (win.barHost ? win.barHost.barInset("bottom") : 0)
    /**
     * El área es la de la PANTALLA, no la de la ventana: oculta, la ventana vuelve a 100×100 hasta
     * que el compositor la configure otra vez, y colocar con ese tamaño la dejaba descolocada al
     * reabrir (medido en W1: y=554 en vez de 252).
     */
    readonly property real areaW: win.targetScreen ? win.targetScreen.width : 0
    readonly property real areaH: win.targetScreen ? win.targetScreen.height : 0

    screen: win.targetScreen
    visible: win.shown || card.appear > 0.001
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "sumi-wallhaven"
    WlrLayershell.keyboardFocus: win.shown ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    anchors { top: true; left: true; right: true; bottom: true }

    /** Sólo la tarjeta, y sólo mientras está a la vista: al salir, los clics ya pasan. */
    mask: win.shown ? cardRegion : noRegion
    Region { id: noRegion }
    /**
     * La región de entrada es la geometría de la tarjeta, SIN la transformación de la entrada (escala y subida de
     * `Reveal`): `item: card` la tomaba con la escala/subida del primer fotograma y no se recalculaba al acabar la
     * animación (sólo al mover o redimensionar), así que con Expressive quedaban muertos ~28 px de la cabecera y
     * ~20 px por lado (2026-11-11, tools/sumi-drag/).
     */
    Region { id: cardRegion; x: card.x; y: card.y; width: card.width; height: card.height }

    // ---- posición ---------------------------------------------------------------------

    function clampX(x) { return Math.max(win.leftInset, Math.min(win.areaW - card.width - win.rightInset, x)); }
    function clampY(y) { return Math.max(win.topInset, Math.min(win.areaH - card.height - win.bottomInset, y)); }
    /** La posición guardada de esta pantalla, acotada; sin ella, centrada. */
    function place() {
        if (win.areaW <= 0 || win.areaH <= 0) return;
        const p = WallhavenStore.positionOf(win.name);
        card.x = win.clampX(p ? p.x : (win.areaW - card.width) / 2);
        card.y = win.clampY(p ? p.y : (win.areaH - card.height) / 2);
    }
    /** Lo mismo que soltar un arrastre en (x, y): se acota y se recuerda. Para IPC (`whStorePlace`). */
    function placeAt(x, y) {
        card.x = win.clampX(x);
        card.y = win.clampY(y);
        WallhavenStore.remember(win.name, card.x, card.y);
        return true;
    }
    /** Para IPC (`whStoreGet`): lo mismo que el botón de descarga de una tarjeta. */
    function catalogDownload(r) { catalog.download(r); }
    /** Para IPC (`whStoreAct`): una acción de la ficha abierta, por su tipo. */
    function catalogAct(kind) {
        const a = WallhavenStore.detailActions(WallhavenStore.detailItem, null).find(x => x.kind === kind);
        if (!a) return false;
        catalog.act(a);
        return true;
    }
    function geometry() {
        return { screen: win.name, shown: win.shown, x: Math.round(card.x), y: Math.round(card.y),
                 w: Math.round(card.width), h: Math.round(card.height),
                 screenW: Math.round(win.areaW), screenH: Math.round(win.areaH),
                 dragging: head.drag.active, appear: Math.round(card.appear * 100) / 100,
                 toast: catalog.toastText, toastPath: catalog.toastPath };
    }

    onShownChanged: if (win.shown) { win.place(); keys.forceActiveFocus(); }
    // la pantalla cambió de tamaño (o la escala): la tarjeta vuelve dentro
    onAreaWChanged: if (win.shown) win.place()
    onAreaHChanged: if (win.shown) win.place()
    Component.onCompleted: WallhavenStore.layer = win
    Component.onDestruction: if (WallhavenStore.layer === win) WallhavenStore.layer = null

    // ---- la tarjeta ---------------------------------------------------------------------

    Item {
        id: card
        width: Math.max(0, Math.min(Metrics.storeW * win.s, win.areaW - win.leftInset - win.rightInset))
        height: Math.max(0, Math.min(Metrics.storeH * win.s, win.areaH - win.topInset - win.bottomInset))
        onWidthChanged: if (win.shown) Qt.callLater(win.place)
        onHeightChanged: if (win.shown) Qt.callLater(win.place)

        /**
         * Aparición: opacidad y una escala corta (0,97 → 1); sin rebote (ANIMATIONS: los rebotes
         * son de elementos secundarios). Reduced: sólo la opacidad, en `calmMs`. Off: al instante.
         * Mientras anima se aplana en una capa, para que la opacidad no deje ver unas piezas a
         * través de otras (el «texto fantasma» de las transiciones).
         */
        // Entrada/salida (2026-11-11, theme/Reveal, estilo de Settings → Animations): opacidad, escala desde
        // el centro y subida; sólo visual (posición, tamaño y región de entrada no cambian).
        Reveal { id: cardReveal; shown: win.shown; s: win.s }
        readonly property real appear: cardReveal.progress
        opacity: cardReveal.opacity
        scale: cardReveal.scale
        transformOrigin: Item.Center
        // sx/sy: Power-on y Mochi (theme/Reveal); 1 con los demás
        transform: [Translate { y: cardReveal.dy }, Scale { origin.x: card.width / 2; origin.y: card.height / 2; xScale: cardReveal.sx; yScale: cardReveal.sy }]
        layer.enabled: card.appear > 0.001 && card.appear < 0.999
        // Bloom, Ink, Scroll y Mist dibujan sobre la capa de la apertura (theme/RevealEffect, ADR-36)
        layer.effect: cardReveal.effect ? cardFx : null
        Component { id: cardFx; RevealEffect { rv: cardReveal; s: win.s } }

        Glass {
            id: glass
            anchors.fill: parent
            s: win.s
            radius: Metrics.rLg * win.s
            /**
             * Fue un 0,985 fijo: la tienda se deja abierta sobre el escritorio y una terminal con texto
             * blanco se leía a través (W1). Desde el 2026-10-28 sigue al material global como todo
             * (petición del usuario); casi opaca de nuevo con un override en Theme → Material → Advanced.
             */
            surface: "wallhaven"
            // la sombra cuesta un FBO por fotograma: fuera mientras se arrastra
            shadowed: !head.drag.active
        }

        /** Esc cierra lo de encima (menú, Filters) o la tienda. Lo demás es del ratón. */
        Item {
            id: keys
            anchors.fill: parent
            focus: true
            Keys.onEscapePressed: if (!catalog.dismiss()) WallhavenStore.close()
        }

        // ---- cabecera: la región de arrastre --------------------------------------------

        /**
         * El MouseArea de arrastre va DEBAJO de lo que se pulsa en la cabecera (la X): uno de
         * contenedor encima robaría el clic (memoria «TapHandler de contenedor roba clics»).
         */
        MouseArea {
            id: head
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: Metrics.storeHeadH * win.s
            cursorShape: head.drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            drag.target: card
            drag.threshold: 2
            drag.minimumX: win.leftInset
            drag.maximumX: Math.max(win.leftInset, win.areaW - card.width - win.rightInset)
            drag.minimumY: win.topInset
            drag.maximumY: Math.max(win.topInset, win.areaH - card.height - win.bottomInset)
            onPressed: keys.forceActiveFocus()
            onReleased: WallhavenStore.remember(win.name, card.x, card.y)
        }

        Row {
            id: headLeft
            anchors.left: parent.left
            anchors.leftMargin: 20 * win.s
            anchors.verticalCenter: head.verticalCenter
            spacing: 14 * win.s

            // el mismo rótulo que SurfaceHeader (punto de acento y versalitas), que dentro de un Row
            // no tiene ancho propio y quedaba tapado por la búsqueda
            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Metrics.sp2 * win.s
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 5 * win.s
                    height: 5 * win.s
                    radius: Metrics.pill(width)
                    color: Theme.primary
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Wallhaven"
                    color: Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.label * win.s
                    font.weight: Typography.wStrong
                    font.capitalization: Font.AllUppercase
                    font.letterSpacing: Typography.tracking * win.s
                }
            }

            /**
             * W2: la búsqueda. Sólo pide al pulsar Enter o Search, nunca al teclear ni al abrir.
             * El texto vive en `WallhavenStore.text`: al reabrir sigue ahí.
             */
            Rectangle {
                id: searchBox
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(360 * win.s, card.width * 0.42)
                height: 30 * win.s
                radius: Metrics.pill(height)
                color: Theme.tileBg
                border.width: field.editing ? Metrics.focusWidth * win.s : 1
                border.color: field.editing ? Theme.selBorder : searchHover.hovered ? Qt.alpha(Theme.primary, 0.30) : Theme.hair
                Behavior on border.color { ColorAnimation { duration: Motion.fast } }
                HoverHandler { id: searchHover; cursorShape: Qt.IBeamCursor }
                Icon {
                    id: searchGlyph
                    anchors.left: parent.left
                    anchors.leftMargin: 11 * win.s
                    anchors.verticalCenter: parent.verticalCenter
                    name: "search"
                    size: 13 * win.s
                    color: Theme.fgVariant
                }
                SearchField {
                    id: field
                    anchors.left: searchGlyph.right
                    anchors.leftMargin: 7 * win.s
                    anchors.right: clearGlyph.visible ? clearGlyph.left : parent.right
                    anchors.rightMargin: 10 * win.s
                    anchors.verticalCenter: parent.verticalCenter
                    s: win.s
                    placeholder: "Search Wallhaven"
                    Component.onCompleted: field.text = WallhavenStore.text
                    onTextChanged: WallhavenStore.text = field.text
                    // W3: Similar y las etiquetas de la ficha escriben la búsqueda por la tienda
                    Connections {
                        target: WallhavenStore
                        function onTextChanged() { if (field.text !== WallhavenStore.text) field.text = WallhavenStore.text; }
                    }
                    onAccepted: catalog.search(field.text)
                    // Esc: primero el texto; vacío, lo de encima; si no, cierra la tienda
                    onDismissed: {
                        if (field.text.length > 0) field.clear();
                        else if (!catalog.dismiss()) WallhavenStore.close();
                    }
                }
                Icon {
                    id: clearGlyph
                    anchors.right: parent.right
                    anchors.rightMargin: 10 * win.s
                    anchors.verticalCenter: parent.verticalCenter
                    visible: field.text.length > 0
                    name: "close"
                    size: 12 * win.s
                    color: clearArea.containsMouse ? Theme.fg : Theme.outline
                    MouseArea {
                        id: clearArea
                        anchors.fill: parent
                        anchors.margins: -5 * win.s
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { field.clear(); field.focusField(); }
                    }
                }
                // un clic en la caja (no sólo en el texto) empieza a escribir
                TapHandler { onTapped: field.focusField() }
            }

            // la misma pastilla y el mismo alto que el campo (antes un botón rectangular 2 px más bajo)
            StoreChip {
                anchors.verticalCenter: parent.verticalCenter
                implicitHeight: searchBox.height
                s: win.s
                strong: true
                label: Wallhaven.dirty && !Wallhaven.loading ? "Search ·" : "Search"
                disabled: Wallhaven.loading
                onActivated: catalog.search(field.text)
            }
        }

        /**
         * Lo que permite la cuenta, a la vista (el resultado no depende de ajustes invisibles).
         * Clic → Settings · Theme · Wallpaper · API key.
         */
        /**
         * W3: las descargas siguen aunque se cierre la tienda; aquí, su resumen (el detalle está en
         * cada tarjeta, en la ficha y en el Dashboard).
         */
        Row {
            id: dlSummary
            anchors.right: accountNote.left
            anchors.rightMargin: 14 * win.s
            anchors.verticalCenter: head.verticalCenter
            spacing: 5 * win.s
            visible: Downloads.runningCount + Downloads.queuedCount + Downloads.pausedCount > 0
            Icon {
                anchors.verticalCenter: parent.verticalCenter
                name: "download"
                size: 12 * win.s
                color: Downloads.pausedCount > 0 ? Theme.warn : Theme.primary
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: Downloads.runningCount + " downloading"
                    + (Downloads.queuedCount > 0 ? " · " + Downloads.queuedCount + " queued" : "")
                    + (Downloads.pausedCount > 0 ? " · " + Downloads.pausedCount + " paused" : "")
                color: Downloads.pausedCount > 0 ? Theme.warn : Theme.primary
                font.family: Typography.ui
                font.pixelSize: Typography.micro * win.s
                font.weight: Font.DemiBold
            }
        }

        Text {
            id: accountNote
            visible: width >= 70 * win.s
            anchors.right: closeBtn.left
            anchors.rightMargin: 12 * win.s
            anchors.verticalCenter: head.verticalCenter
            width: Math.max(0, Math.min(implicitWidth, closeBtn.x - headLeft.x - headLeft.width - 28 * win.s
                            - (dlSummary.visible ? dlSummary.width + 14 * win.s : 0)))
            elide: Text.ElideRight
            text: WallhavenAccount.usable ? "Account: " + WallhavenAccount.accountText()
                : WallhavenAccount.hasKeyFile ? "API key: " + WallhavenAccount.statusText.toLowerCase()
                : "No API key · SFW only"
            color: WallhavenAccount.status === "rejected" ? Theme.warn
                : accountArea.containsMouse ? Theme.fgVariant : Theme.outline
            font.family: Typography.ui
            font.pixelSize: Typography.micro * win.s
            Accessible.role: Accessible.Link
            Accessible.name: text + " · open the setting"
            MouseArea {
                id: accountArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Screens.settingsOpenOn("theme/wallpaper/whKey", win.name)
            }
        }

        Rectangle {
            id: closeBtn
            anchors.right: parent.right
            anchors.rightMargin: 12 * win.s
            anchors.verticalCenter: head.verticalCenter
            width: 28 * win.s
            height: 28 * win.s
            radius: Metrics.pill(width)
            color: closeArea.containsMouse ? Theme.hoverBg : "transparent"
            Behavior on color { ColorAnimation { duration: Motion.fast } }
            Accessible.role: Accessible.Button
            Accessible.name: "Close Wallhaven"

            Icon {
                anchors.centerIn: parent
                name: "close"
                size: 15 * win.s
                color: closeArea.containsMouse ? Theme.fg : Theme.fgVariant
            }
            MouseArea {
                id: closeArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: WallhavenStore.close()
            }
        }

        Rectangle {
            id: rule
            anchors.top: head.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 20 * win.s
            anchors.rightMargin: 20 * win.s
            height: 1
            color: Theme.hair
        }

        // ---- cuerpo: el catálogo (W2) ---------------------------------------------------

        WallhavenCatalog {
            id: catalog
            anchors.top: rule.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: 20 * win.s
            anchors.rightMargin: 20 * win.s
            anchors.topMargin: 12 * win.s
            anchors.bottomMargin: 12 * win.s
            s: win.s
            screenName: win.name
        }
        // interferencia de terminal (2026-11-15): al abrir y al cambiar de vista; encima de todo (z), sin
        // recibir clics. Último hijo de la tarjeta: no corre los índices de los demás
        Interference { anchors.fill: parent; s: win.s; open: win.shown; key: "" }
    }
}
