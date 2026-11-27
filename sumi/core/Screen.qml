pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import "../theme"
import "../services"
import "../components"
import "../lib/bar-edge.js" as BarEdge

/**
 * Everything one monitor owns: the reserve strip (optional exclusive zone),
 * the full-screen overlay whose input mask decides what is clickable, the
 * island, the open surface and the hold state.
 *
 * Hold state is one enumeration, `holdReason`, derived from four latches:
 *   surface  a surface is open (modal, keyboard focus)
 *   pin      the island was tapped without auto-hide (modal)
 *   hover    the pointer is over the island (or left it < grace ago)
 *   reveal   auto-hide: the pointer touched the top-edge strip
 *   none     resting (auto-hide may retract it)
 */
Scope {
    id: screen

    required property var modelData
    readonly property string name: modelData ? modelData.name : ""

    /** Logical-pixel scale: user preference only. Qt applies the DPR (ADR-10). */
    readonly property real s: Settings.uiScale

    property string open: ""
    property bool hovered: false
    property bool hoverLatch: false
    property bool pinned: false
    property bool revealing: false
    property bool bootSettled: false
    /** Un menu de bandeja abierto: se comporta como modal (Fase 9.c). */
    property bool menuOpen: false

    readonly property bool surfaceOpen: open.length > 0
    /**
     * Fase 8C-1: la presentación de ESTA pantalla (`Settings.monitors`, por modelo|serie;
     * una pantalla nueva empieza como island). Super+Ctrl+P la alterna (`toggleBar`).
     */
    readonly property bool barMode: Settings.monitorPref(screen.modelData, "presentation", "island") === "bar"
    /**
     * 8F-1: el dock sustituye al island COMPACTO en esta pantalla (`monitors[id].dock`,
     * apagado por defecto). Desactivarlo devuelve el island.
     */
    readonly property bool dockPref: Settings.monitorPref(screen.modelData, "dock", false) === true
    readonly property bool dockMode: !barMode && dockPref
    /**
     * 2026-10-01 (pedido del usuario): el dock ya no se apaga con la barra persistente, la
     * VISTE — la barra se pega al borde, opaca y con las esquinas de abajo de la muesca.
     * Antes la barra «mandaba» y el dock esperaba a que se quitara.
     */
    readonly property bool barDock: barMode && dockPref
    /**
     * BORDE Y LONGITUD DE LA BARRA (2026-11-19, encuesta del autor; lib/bar-edge.js), por monitor como la
     * presentación: `monitors[id].barEdge|barLength`. Siempre centrada: la longitud la encoge hacia el centro hasta su
     * límite (`barLimitLength`). Un valor desconocido cae en arriba · 100 %.
     */
    readonly property string barEdge: BarEdge.edgeOf(Settings.monitorPref(screen.modelData, "barEdge", "top"))
    readonly property int barLength: BarEdge.lengthOf(Settings.monitorPref(screen.modelData, "barLength", 100))
    /** Para Settings (Length): lo más corta que puede ser en este borde y lo que mide el borde sin sus márgenes. */
    readonly property real barLimitLength: bar.minLen
    readonly property real barEdgeLength: Math.max(0, focusScope.alongSize - 2 * overlay.topGap)
    readonly property bool barVertical: BarEdge.vertical(journey.edge)
    /**
     * El lado por el que el island se une y crece: el de la barra mientras la hay (también mientras se pliega de
     * vuelta); con el island o la muesca, arriba. `edgeTop` es el camino de siempre, sin tocar.
     */
    readonly property string attachEdge: (screen.barMode || bar.unfold > 0.01) ? journey.edge : "top"
    readonly property bool edgeTop: screen.attachEdge === "top"
    /** La franja reservada y los popups: el borde de la barra con la barra, si no arriba. */
    readonly property string reserveEdge: screen.barMode ? screen.barEdge : "top"
    /** Lo que la barra reserva en `side` (para no taparla: popups, ventanas flotantes); 0 en los demás lados. */
    function barInset(side) { return screen.barMode && screen.barEdge === side ? overlay.reservedH : 0; }
    // Con la barra no hay cara hover: el peek y el menú de bandeja son de la barra.
    readonly property bool expanded: surfaceOpen || (!barMode && (pinned || hoverLatch || menuOpen))
    /**
     * Vista previa por hover (fase 4C): la superficie está abierta pero NO fijada. Sin
     * teclado (la aplicación de debajo lo conserva), sin capturar clics fuera (la
     * máscara es el island) y se cierra al salir el puntero. Un clic dentro, su atajo o
     * abrirla de cualquier otra forma la fijan (`engage`).
     */
    property bool preview: false
    readonly property bool engaged: surfaceOpen && !preview
    // 8C-2: el desplegable More de la barra se cierra con un clic fuera, como un menú
    readonly property bool modal: engaged || pinned || menuOpen || (barMode && bar.moreOpen)
    /**
     * Con `auth` abierta no cuenta la pantalla completa (QS-FUNC-017): un
     * `pkexec` lanzado con un juego delante esperaria un dialogo invisible, y
     * sin el no hay forma de autenticar.
     */
    readonly property bool fullscreen: Hypr.hasFullscreen(screen.name) && screen.open !== "auth"
    /**
     * FASE 8D (DESIGN §4, futureHoverBarsurface): con pantalla completa el shell se oculta
     * y conserva su modo. Quedarse `Motion.fsRevealMs` en la franja del borde superior lo
     * REVELA (`fsReveal`) superpuesto, sin tocar la zona reservada; salir sin interactuar
     * lo vuelve a ocultar (`fsHide`). Una surface, el peek, el menú de bandeja o More lo
     * mantienen hasta cerrarse — también si los abre un atajo: antes la surface quedaba
     * INVISIBLE con el teclado exclusivo (medido en la 8D, `open='launcher'` y nada en
     * pantalla).
     *
     * `concealed` es lo que antes era `fullscreen` en todo lo visual y en la máscara.
     */
    property bool fsReveal: false
    readonly property bool concealed: fullscreen && !fsReveal && !surfaceOpen && !pinned && !menuOpen
        && !(barMode && bar.moreOpen)
    /**
     * 2026-10-02 (pedido del usuario): el OSD y los avisos del island SÍ salen sobre una pantalla
     * completa. Sólo lo visual: la máscara sigue siendo la franja, así que no roban clics ni teclado
     * a la aplicación. Con la barra no cuelgan de ella (está oculta): salen donde el island.
     */
    readonly property bool osdOver: concealed && (island.mode === "osd" || island.mode === "notice")
    /** Lo que de verdad esconde el island con pantalla completa: todo menos el OSD. */
    readonly property bool islandConcealed: concealed && !osdOver
    // La barra es persistente: auto-hide no la esconde (futureHoverBarsurface, «permanecerá visible»).
    readonly property bool hidden: !barMode && Settings.autoHide && !expanded && !revealing
    readonly property string holdReason: surfaceOpen ? "surface"
        : (pinned ? "pin" : (hoverLatch ? "hover" : (revealing ? "reveal" : "none")))

    function hasSurface(n) {
        // Settings UI (2026-11-07): `settings`, `settingsTheme` y `settingsSystem` ya no son del island, pero siguen valiendo
        if (Screens.isSettings(n) || Screens.isTasks(n) || Screens.isLogin(n))
            return true;
        const name = Screens.canonical(n);
        if (["services", "serviceDetail", "serviceJournal"].indexOf(name) >= 0 && !Units.supported)
            return false;
        return island.hasSurface(name);
    }
    Connections {
        target: Units
        function onSupportedChanged() {
            if (!Units.supported && ["services", "serviceDetail", "serviceJournal"].indexOf(screen.open) >= 0)
                screen.closeSurface();
        }
    }
    function surfaceNames() { return island.surfaceNames(); }

    /**
     * La puerta de SALIDA (rediseño, fase 4, Guarded): toda apertura de otra
     * superficie y todo cierre pasan por aquí. Si la abierta tiene un secreto sin
     * enviar, no se sale: el host pregunta. `force` sólo lo usan el bloqueo de sesión y
     * la pantalla completa, que cierran sí o sí (la superficie borra sus campos al
     * dejar de estar activa).
     */
    /** Hay una edición sensible abierta (sin preguntar nada): para elegir pantalla (6D). */
    function isGuarded() {
        if (screen.open.length === 0) return false;
        const it = island.surfaceItem(screen.open);
        return !!(it && it.guardReason && it.guardReason.length > 0);
    }

    function guardBlocks(target) {
        if (screen.open.length === 0) return false;
        const it = island.surfaceItem(screen.open);
        if (!it || !it.guardReason || it.guardReason.length === 0) return false;
        island.askLeave(target);
        return true;
    }

    /**
     * 8E: algo cuelga de la barra (surface, OSD o aviso). Se enciende al salir del reposo con
     * la barra y se apaga cuando la forma, ya en reposo, mide 0: así el island no salta a la
     * franja mientras aún se está recogiendo hacia la barra.
     */
    property bool belowBar: false
    readonly property bool belowWatch: screen.barMode && island.mode !== "rest"
    onBelowWatchChanged: if (screen.belowWatch) screen.belowBar = true
    // con el cajón (2026-11-19) la forma conserva su largo hasta el final: lo que cuenta es la profundidad
    readonly property bool belowGone: island.mode === "rest" && (island.drawer ? island.depthNow < 2 : island.width < 2)
    onBelowGoneChanged: if (screen.belowGone) screen.belowBar = false
    onBarModeChanged: if (!screen.barMode) screen.belowBar = false

    /**
     * 8E: desplazamiento del acceso que pide ESTA apertura (un clic o la vista previa de la barra);
     * NaN = no viene de la barra. Lo pone el manejador de la barra justo antes de pedir y lo
     * borra justo después, se haya abierto algo o no (2026-11-12: antes sólo se consumía al
     * abrir, así que un clic que CERRABA el Mixer dejaba su origen guardado y el siguiente atajo
     * nacía bajo el Mixer).
     */
    property real pendingOrigin: NaN
    /**
     * Con atajo o IPC y la barra puesta, la surface nace bajo SU acceso, igual que con el ratón
     * (2026-11-12, decisión del usuario); si el acceso está en More o no está, del centro.
     */
    function takeOrigin(n) {
        let o = screen.pendingOrigin;
        if (isNaN(o))
            o = screen.barMode ? bar.originForSurface(n) - focusScope.alongSize / 2 : 0;
        island.originOffset = o;
        screen.pendingOrigin = NaN;
    }

    function openSurface(n) {
        // ISLAND.md §3.4: con la sesión bloqueada nada del shell puede abrirse (I-13)
        if (Lock.engaged)
            return false;
        // Settings UI (2026-11-07): la ventana flotante, no el island (su página inicial por el nombre)
        if (Screens.isSettings(n))
            return screen.showSettings(Screens.settingsDefaultPath(n), null);
        // Etapa B del Dashboard (2026-11-09): `tasks` es la ventana flotante, no una pestaña
        if (Screens.isTasks(n))
            return screen.showTasks("", false);
        // Login screen (Sumi SDDM, 2026-11-23): la ventana flotante
        if (Screens.isLogin(n))
            return screen.showLogin("", null);
        // 9E-1: `media` es el Mixer; por dónde se llegó decide sólo su foco inicial. 13F: una
        // pista puntual `apps` (forwardTo) no se pisa: el Mixer la consume al abrirse y la
        // devuelve a «output». (La de `eq` se fue antes de la fase 14: el EQ está en la Audio UI.)
        if (n === "media" || n === "mixer") {
            const cur = island.surfaceSel("mixer");
            if (cur !== "apps")
                island.selectSurface("mixer", n === "media" ? "playback" : "output");
        }
        // 11A-1: la pestaña del Dashboard, por el nombre con que se llega (Screens.dashboardTabs)
        const dashTab = Screens.dashboardTabs[n];
        n = Screens.canonical(n);
        if (!screen.hasSurface(n))
            return false;
        if (dashTab !== undefined && screen.open === n) {
            // ya abierto: cambia de pestaña él mismo, sin reabrir
            island.selectSurface(n, dashTab);
            const it = screen.surfaceItem(n);
            if (it && typeof it.showTab === "function") it.showTab(dashTab);
            if (screen.preview) screen.engage();   // pedirlo por su nombre es explícito
            return true;
        }
        if (dashTab !== undefined) island.selectSurface(n, dashTab);
        if (screen.open !== n && screen.guardBlocks({ kind: "open", name: n }))
            return false;
        screen.dismissTrayMenu();
        screen.pinned = false;
        screen.hoverLatch = false;
        screen.revealing = false;
        screen.preview = false;
        // 9A: dentro de una familia (Shell → Theme) el panel no cambia de origen: con la
        // barra seguiría naciendo bajo el engranaje en vez de saltar al centro.
        if (screen.open.length > 0 && Screens.familyOf(screen.open) === Screens.familyOf(n))
            screen.pendingOrigin = NaN;
        else
            screen.takeOrigin(n);
        screen.open = n;
        return true;
    }

    /**
     * La vista previa: sólo desde la cara hover en reposo (nada abierto ni fijado), y
     * nunca con la sesión bloqueada o en pantalla completa.
     */
    function openPreview(n) {
        // 8C-1: otra vista previa SÍ la sustituye (sólo si aún no está fijada: DESIGN §2).
        // Era lo pendiente de la 4C; con el island los iconos desaparecen y no se daba.
        if (Lock.engaged || (screen.fullscreen && !screen.fsReveal) || (screen.surfaceOpen && !screen.preview)
                || screen.pinned || screen.menuOpen)
            return false;
        // 9E-1: el alias también en la vista previa. Sin esto el acceso de música de la barra
        // pedía «media», el host no la conoce y el island se quedaba en su cara hover.
        if (n === "media" || n === "mixer")
            island.selectSurface("mixer", n === "media" ? "playback" : "output");
        // Settings UI (2026-11-07): una ventana flotante no tiene vista previa por hover; se abre con clic
        if (Screens.isSettings(n) || Screens.isTasks(n) || Screens.isLogin(n)) return false;
        n = Screens.canonical(n);
        if (screen.open === n) return true;
        if (!screen.hasSurface(n) || !Settings.hoverPreview)
            return false;
        screen.preview = true;
        screen.takeOrigin(n);
        screen.open = n;
        // Si el puntero ya no está encima (se fue en los 450 ms, o la abrió el IPC), el
        // hover no «cambia» y nada la cerraría: la gracia empieza ya.
        if (!screen.hovered) previewClose.restart();
        return true;
    }

    /** Fijar la vista previa: desde aquí es una superficie normal (teclado, clic fuera). */
    function engage() {
        if (!screen.preview) return;
        screen.preview = false;
        previewClose.stop();
    }

    /**
     * Un círculo del island (8B-1): abre su superficie; si ya es la abierta y fijada, la
     * cierra. Una vista previa de esa misma superficie se fija (DESIGN §2: el primer clic
     * activa). Pasa por `openSurface`, así que respeta el bloqueo y Guarded.
     */
    /**
     * Settings UI (2026-11-07): abrir (o traer) la ventana de Settings en esta pantalla, en `path`
     * si se da. Una superficie del island abierta se cierra antes (Guarded pregunta, como al abrir
     * otra superficie): la que lo pidió es `origin.from` y Esc en Settings vuelve a ella.
     */
    function showSettings(path, origin) {
        if (Lock.engaged)
            return false;
        if (screen.open.length > 0 && !screen.closeSurface())
            return false;
        screen.dismissTrayMenu();
        screen.pinned = false;
        screen.hoverLatch = false;
        screen.revealing = false;
        return SettingsUi.show(screen.name, path || "", origin || null);
    }
    readonly property bool settingsHere: SettingsUi.open && SettingsUi.screen === screen.name

    /**
     * La capa Tasks (etapa B del Dashboard): abrir o traer la ventana en esta pantalla, con la tarea `id`
     * elegida y, con `start`, arrancada. Una superficie del island abierta se cierra antes (Guarded
     * pregunta); la ventana pide el teclado cuando ésa ya se cerró.
     */
    function showTasks(id, start) {
        if (Lock.engaged)
            return false;
        if (screen.open.length > 0 && !screen.closeSurface())
            return false;
        screen.dismissTrayMenu();
        screen.pinned = false;
        screen.hoverLatch = false;
        screen.revealing = false;
        return TasksUi.show(screen.name, id || "", start === true);
    }
    readonly property bool tasksHere: TasksUi.open && TasksUi.screen === screen.name

    /** La ventana Login screen (Sumi SDDM, 2026-11-23), como Tasks: una superficie del island abierta se cierra antes. */
    function showLogin(page, origin) {
        if (Lock.engaged)
            return false;
        if (screen.open.length > 0 && !screen.closeSurface())
            return false;
        screen.dismissTrayMenu();
        screen.pinned = false;
        screen.hoverLatch = false;
        screen.revealing = false;
        return LoginUi.show(screen.name, page || "", origin || null);
    }
    readonly property bool loginHere: LoginUi.open && LoginUi.screen === screen.name

    function toggleFromCircle(n) {
        if (Screens.isSettings(n))
            return screen.settingsHere ? SettingsUi.close(false) : screen.showSettings("", null);
        if (Screens.isTasks(n))
            return screen.tasksHere ? TasksUi.requestClose() : screen.showTasks("", false);
        if (Screens.isLogin(n))
            return screen.loginHere ? LoginUi.close(false) : screen.showLogin("", null);
        if (screen.open.length > 0 && Screens.familyOf(screen.open) === Screens.familyOf(n)) {
            if (screen.preview) { screen.engage(); return true; }
            return screen.closeSurface();
        }
        return screen.openSurface(n);
    }

    function closeSurface(force) {
        if (force !== true && screen.guardBlocks({ kind: "close" }))
            return false;
        screen.open = "";
        screen.preview = false;
        return true;
    }

    /**
     * Abre una ficha diciendo QUE mira, en esta pantalla y solo en esta
     * (SurfaceHost §`sel`). Es el camino de los verbos IPC `wifiDetail`,
     * `btDetail`, `serviceDetail` y `unitJournal`.
     */
    function openSurfaceWith(n, key) {
        n = Screens.canonical(n);
        if (!screen.hasSurface(n))
            return false;
        island.selectSurface(n, key);
        return screen.openSurface(n);
    }

    function surfaceSel(n) { return island.surfaceSel(n); }
    function surfaceSelAll() { return island.surfaceSelAll(); }

    function toggleSurface(n) {
        // Settings UI: el atajo y el engranaje alternan la ventana en esta pantalla
        if (Screens.isSettings(n))
            return screen.settingsHere && screen.open.length === 0 ? SettingsUi.close(false)
                : screen.showSettings(Screens.settingsDefaultPath(n), null);
        if (Screens.isTasks(n))
            return screen.tasksHere && screen.open.length === 0 ? TasksUi.requestClose() : screen.showTasks("", false);
        if (Screens.isLogin(n))
            return screen.loginHere && screen.open.length === 0 ? LoginUi.close(false) : screen.showLogin("", null);
        // El atajo de una superficie en vista previa la FIJA en vez de cerrarla.
        const same = screen.open.length > 0 && Screens.familyOf(screen.open) === Screens.familyOf(n);
        if (same && screen.preview) {
            screen.engage();
            return true;
        }
        if (same) {
            screen.closeSurface();
            return true;
        }
        return screen.openSurface(n);
    }

    function unloadClosed() { island.unloadClosed(); }
    function navStack() { return island.navStack(); }
    function backSurface() { return island.backSurface(); }
    function historyBack() { return Lock.engaged ? false : island.historyBack(); }
    function historyForward() { return Lock.engaged ? false : island.historyForward(); }
    function historyDump() { return island.historyDump(); }
    function surfaceHost() { return island.surfaceHost(); }
    /** Fase 4C, para pruebas: qué icono de la cara hover tiene el puntero y si abriría vista previa. */
    /** Fase 4C, para pruebas: lo que haría el puntero al entrar en un icono (hyprctl no mueve dentro de la capa). */
    function setHoverKey(k) { island.hoverKey = k; return island.previewable; }
    /** Fase 8B-1 (IPC `islandState`): geometría y caras del reposo, en px de la capa. */
    function islandInfo() {
        const pt = function (it) { return { x: Math.round(it.x), y: Math.round(it.y), w: Math.round(it.width), h: Math.round(it.height) }; };
        return {
            mode: island.mode, width: overlay.width,
            // la tooltip de la cara hover (texto; vacío = callada)
            tip: island.tipText, hoverKey: island.hoverKey,
            island: { x: Math.round(island.x), w: Math.round(island.width), targetW: Math.round(island.targetW),
                      h: Math.round(island.height), targetH: Math.round(island.targetH),
                      centre: Math.round((island.x + island.width / 2) * 10) / 10 },
            music: Object.assign(pt(musicCircle), { shown: musicCircle.shown, opacity: Math.round(musicCircle.opacity * 100) / 100,
                     playing: Media.playing, art: Media.artUrl.length > 0, label: musicCircle.label }),
            net: Object.assign(pt(netCircle), { shown: netCircle.shown, opacity: Math.round(netCircle.opacity * 100) / 100,
                     glyph: netCircle.face.glyph, tone: netCircle.face.tone, halo: "" + netCircle.halo, label: netCircle.label }),
            privacy: { red: Privacy.screenActive, right: Privacy.cameraActive ? "green" : (Privacy.micActive ? "orange" : "") },
            // la pieza del grabador (2026-10-29): dónde cuelga respecto a la forma
            rec: Object.assign(pt(recPill), { shown: recPill.shown, opacity: Math.round(recPill.opacity * 100) / 100,
                     label: recPill.label, islandBottom: Math.round(island.y + islandShift.y + island.height),
                     tipTop: Math.round(hoverTip.y) }),
            hovered: screen.hovered,
            // 8E: origen de la surface con la barra
            origin: { offset: Math.round(island.originOffset), target: Math.round(island.hOffsetTarget),
                      now: Math.round(island.hOffset), barOriginX: Math.round(bar.originX), belowBar: screen.belowBar }
        };
    }

    function hoverInfo() { return { hoverKey: island.hoverKey, previewable: island.previewable, mode: island.mode, hovered: screen.hovered }; }
    function surfaceItem(n) { return island.surfaceItem(n); }

    /** Escape (llega con `accepted` en false). Compartido por Keys y por `testKey`. */
    function escapeKey(e) {
        // 8C-2: con la barra, Esc cierra primero su desplegable More (lo local, DESIGN §3).
        // Llega aquí antes que a `bar.keyPressed`: sin esto soltaba el peek y More seguía.
        if (screen.barMode && !screen.surfaceOpen && bar.moreOpen) {
            bar.moreOpen = false;
            e.accepted = true;
            return;
        }
        island.keyPressed(e);
        if (!e.accepted && island.escapeToContainer()) return;
        if (!e.accepted) {
            screen.closeSurface();
            screen.pinned = false;   // y suelta el peek (Fase 10.h)
        }
    }
    function pressKey(e) {
        if (screen.barMode && !screen.surfaceOpen) bar.keyPressed(e);
        else island.keyPressed(e);
    }

    /**
     * 16B, SÓLO PRUEBAS: una tecla por el mismo camino que `Keys`, sin teclado virtual
     * (el de `wtype` llegó a disparar el atajo global Super+Esc; en Hyprland hay además
     * Ctrl+Alt+Esc → poweroff). Sólo si la pantalla tiene el teclado (fijada o peek) y
     * nunca con la sesión bloqueada. No escribe en campos de texto (eso es del teclado real).
     */
    function testKey(name, shift) {
        // Settings UI: sin superficie del island delante, las teclas de prueba van a su ventana
        if (!Lock.engaged && screen.settingsHere && !screen.engaged && !screen.pinned && SettingsUi.layer)
            return SettingsUi.layer.key(name, shift);
        if (Lock.engaged || !(screen.engaged || screen.pinned)) return false;
        const map = { Escape: Qt.Key_Escape, Tab: Qt.Key_Tab, Backtab: Qt.Key_Backtab, Up: Qt.Key_Up,
                      Down: Qt.Key_Down, Left: Qt.Key_Left, Right: Qt.Key_Right, Home: Qt.Key_Home,
                      End: Qt.Key_End, PageUp: Qt.Key_PageUp, PageDown: Qt.Key_PageDown,
                      Return: Qt.Key_Return, Space: Qt.Key_Space, Delete: Qt.Key_Delete };
        // Qt entrega Mayús+Tab como Key_Backtab (con Mayús en los modificadores); una letra sola, su tecla
        // (2026-10-29: las letras directas del grabador)
        const k = name === "Tab" && shift ? Qt.Key_Backtab
            : /^[A-Z]$/.test(name) ? Qt.Key_A + name.charCodeAt(0) - 65 : map[name];
        if (!k) return false;
        const e = { key: k, modifiers: shift ? Qt.ShiftModifier : Qt.NoModifier, text: k === Qt.Key_Space ? " " : "",
                    isAutoRepeat: false, accepted: false };
        if (k === Qt.Key_Escape) screen.escapeKey(e); else screen.pressKey(e);
        return true;
    }
    /**
     * EL MENÚ DE LA BANDEJA Y LOS PANELES NO CONVIVEN (2026-11-17, captura del autor). Con el menú abierto, un clic
     * en la cápsula de estado de la barra cae «dentro» (no cierra nada) y abría Network: el panel nacía ENCIMA del
     * menú, que seguía abierto y se leía apagado a través del vidrio. Dos vidrios de la misma capa no se difuminan
     * entre sí (el blur del compositor ve la capa entera), así que apilarlos nunca se lee bien. Regla: abrir un
     * panel o una ventana flotante cierra el menú; abrir el menú cierra el panel (con su guarda: si un panel con
     * cambios sin guardar no se deja cerrar, el menú no se abre). Y el menú va por encima (`z` en `trayMenu`) para
     * que en el relevo, mientras el panel se recoge, no asome por debajo.
     */
    function dismissTrayMenu() {
        if (screen.menuOpen) trayMenu.close();
    }
    /** (`ax`, `ay`): el punto del lado interior de lo que lo abre; `edge`, hacia dónde se abre (arriba = hacia abajo). */
    function showTrayMenu(menuHandle, ax, ay, edge) {
        if (Lock.engaged) return false;
        if (screen.open.length > 0 && !screen.closeSurface()) return false;
        return trayMenu.openFor(menuHandle, ax, ay, edge || "top");
    }
    function openTrayMenu(i) {
        if (Lock.engaged) return false;
        if (i < 0) { trayMenu.close(); return true; }
        return screen.barMode ? bar.openTrayMenu(i) : island.openTrayMenu(i);
    }
    /** Geometria real del island, para medir sin adivinar desde una captura. */
    function islandSize() { return ({ w: Math.round(island.width), h: Math.round(island.height),
                                      restW: Math.round(island.restW), hoverW: Math.round(island.hoverW) }); }
    /**
     * Geometría del island para el relevo de la pantalla de bloqueo
     * (docs/lock/ISLAND.md §3): `{x,y,w,h,r}` en coordenadas del overlay. Con
     * `autoHide` retraído o pantalla completa, la `y` se corrige con el mismo
     * desplazamiento del `Translate` del island (no es una posición real: el
     * island se traslada, no se mueve).
     */
    function islandGeometry() {
        const shift = (screen.islandConcealed || screen.hidden) ? (island.height + overlay.topGap) : 0;
        return { x: Math.round(island.x), y: Math.round(island.y - shift),
                 w: Math.round(island.width), h: Math.round(island.height),
                 r: Math.round(island.radius) };
    }
    /**
     * De dónde sale (y adónde vuelve) la cápsula del Lock (fase 15F, LOCK-D11, «resolver la entrada desde
     * dock/barra»), en las coordenadas de `islandGeometry`:
     *   · island y dock: el propio island (el dock es el island pegado al borde, con esquinas de muesca);
     *   · barra: el island está oculto (0 × 0), así que sale del TRAMO DEL RELOJ de la barra, con su alto.
     */
    function lockOrigin() {
        if (screen.barMode && bar.visible && bar.clockItem && bar.clockItem.width > 0) {
            const space = island.parent;
            const c = bar.clockItem.mapToItem(space, 0, 0);
            const b = bar.mapToItem(space, 0, 0);
            const pad = 12 * screen.s;
            // 2026-11-19: con la barra a un lado, el reloj apilado: de su ancho y con el margen arriba y abajo
            if (bar.vertical) {
                const w = Math.round(bar.width);
                return { x: Math.round(b.x), y: Math.round(c.y - pad), w: w, h: Math.round(bar.clockItem.height + pad * 2),
                         r: Math.round(w / 2), presentation: "bar" };
            }
            const h = Math.round(bar.height);
            return { x: Math.round(c.x - pad), y: Math.round(b.y), w: Math.round(bar.clockItem.width + pad * 2),
                     h: h, r: Math.round(h / 2), presentation: "bar" };
        }
        return Object.assign(screen.islandGeometry(), { presentation: screen.dockMode ? "dock" : "island" });
    }
    function enterTrayMenu(i) {
        if (Lock.engaged)
            return false;
        island.trayMenuEnterRequested(i);
        return true;
    }
    function backTrayMenu() { island.trayMenuBackRequested(); return true; }
    function dumpTrayMenu() { return island.trayMenuDump; }
    /** ISLAND.md §3.4: un aviso descartado con la sesión bloqueada sería viejo al volver. */
    function flashOsd(kind) { if (!Lock.engaged) osd.flash(kind); }
    /** Que el island diga algo. Lo usan los servicios y el verbo IPC `announce`. */
    function announce(text, glyph, tone) {
        if (Lock.engaged)
            return false;
        osd.announce(text, glyph, tone);
        return true;
    }

    /** Hold the island open without the pointer; a click anywhere drops it. */
    function osdInfo() {
        return { mode: osd.mode, kind: osd.kind, level: Math.round(osd.level * 100) / 100,
                 islandMode: island.mode, band: island.bandShown, suppressed: island.bandSuppressed,
                 place: island.bandPlaceKept, kind: island.bandKind, bandBox: island.bandBox(),
                 open: screen.open, keyboard: screen.engaged || screen.pinned,
                 // F2c (pruebas sin capturas): el aviso del island que se ve, si hay
                 notice: osd.noticing ? osd.noticeText : "" };
    }

    function barInfo() {
        return Object.assign(bar.info(), { presentation: screen.barMode ? "bar" : "island", dock: screen.barDock, visible: bar.visible,
                                           reserved: Math.round(overlay.reservedH),
                                           // 2026-11-19: dónde está y de qué lado cuelga lo que sale de ella
                                           length: screen.barLength, limit: Math.round(screen.barLimitLength), attachEdge: screen.attachEdge,
                                           fits: focusScope.barFits, short: focusScope.barShort,
                                           rect: { x: Math.round(bar.x), y: Math.round(bar.y), w: Math.round(bar.width),
                                                   h: Math.round(bar.height) },
                                           island: { x: Math.round(island.x), y: Math.round(island.y), w: Math.round(island.width),
                                                     h: Math.round(island.height), attached: island.attached,
                                                     offset: Math.round(island.hOffset) },
                                           islandTop: Math.round(island.y), tip: bar.tipInfo() });
    }
    function setBarHover(k) {
        if (!screen.barMode) return false;
        bar.hoverKey = k;
        return true;
    }

    /** 8F-1: dock encendido/apagado en esta pantalla (por monitor). Sólo IPC hasta la 8F-2. */
    function toggleDock() {
        if (Lock.engaged) return false;
        const next = !(Settings.monitorPref(screen.modelData, "dock", false) === true);
        screen.hoverLatch = false;
        Settings.setMonitorPref(screen.modelData, "dock", next);
        return next;
    }

    /** Island ⇄ barra persistente en esta pantalla, recordado por monitor (8C-1). */
    function toggleBar() {
        if (Lock.engaged) return false;
        const next = screen.barMode ? "island" : "bar";
        screen.pinned = false;
        screen.hoverLatch = false;
        Settings.setMonitorPref(screen.modelData, "presentation", next);
        return next === "bar";
    }

    function togglePin() {
        if (Lock.engaged)
            return false;
        screen.pinned = !screen.pinned;
        return screen.pinned;
    }

    onFullscreenChanged: {
        screen.fsReveal = false;
        fsDwell.stop();
        fsHide.stop();
        if (fullscreen) {
            screen.closeSurface(true);
            screen.pinned = false;
            screen.hoverLatch = false;
            screen.revealing = false;
        }
    }

    /** 8D: la espera en la franja antes de revelar. */
    Timer {
        id: fsDwell
        interval: Motion.fsRevealMs
        onTriggered: if (screen.fullscreen && screen.hovered && !screen.fsReveal) screen.fsReveal = true
    }
    /** 8D: fuera sin interactuar → se vuelve a ocultar (lo activo lo mantiene). */
    Timer {
        id: fsHide
        interval: Motion.hoverCloseMs
        onTriggered: {
            if (!screen.fullscreen || !screen.fsReveal || screen.hovered) return;
            if (screen.surfaceOpen || screen.pinned || screen.menuOpen || (screen.barMode && bar.moreOpen)) return;
            screen.fsReveal = false;
            screen.hoverLatch = false;
        }
    }
    /** Al cerrarse lo que lo mantenía, con el puntero fuera: a ocultarse. */
    function fsSettle() {
        if (screen.fullscreen && !screen.hovered) {
            screen.fsReveal = screen.fsReveal || screen.surfaceOpen || screen.pinned;
            fsHide.restart();
        }
    }
    onPinnedChanged: if (!screen.pinned) screen.fsSettle()
    onMenuOpenChanged: if (!screen.menuOpen) screen.fsSettle()

    /**
     * Al bloquear (ISLAND.md §3.2): cierra la superficie abierta (esto ya
     * cancela un polkit pendiente, `deferredCancel`), suelta peek/hover/
     * revelado y cierra el menú de bandeja. El island y la máscara ya
     * reaccionan por binding a `Lock.engaged` (arriba); esto es lo que sólo
     * puede hacerse imperativamente.
     */
    Connections {
        target: Lock
        function onEngagedChanged() {
            if (!Lock.engaged)
                return;
            screen.closeSurface(true);
            screen.pinned = false;
            screen.hoverLatch = false;
            screen.revealing = false;
            if (screen.menuOpen)
                trayMenu.close();
        }
    }

    Component.onCompleted: Screens.register(screen)
    Component.onDestruction: Screens.unregister(screen)

    /**
     * Hyprland hands pointer focus to a freshly mapped layer at the cursor
     * position; the window-level HoverHandler would read that as a hover and
     * latch the island open. Latching only after boot settles filters it.
     */
    Timer {
        interval: 3000
        running: true
        onTriggered: screen.bootSettled = true
    }

    /** Tolerancia al salir del panel en vista previa (el trayecto): luego se cierra. */
    Timer {
        id: previewClose
        interval: Motion.hoverCloseMs
        onTriggered: if (screen.preview && !screen.hovered && !screen.previewHeld) screen.closeSurface(true)
    }
    /**
     * Sólo pruebas (fase 7A, IPC `previewHold`): la vista previa abierta por IPC no
     * se cierra por falta de hover. `hyprctl dispatch movecursor` no da hover dentro
     * de la capa, así que sin esto se cierra a los ~0,4 s. Sigue siendo vista previa
     * (no fijada): lo que se prueba con ella es justo lo que NO hace el hover.
     */
    property bool previewHeld: false
    onPreviewChanged: if (!screen.preview) screen.previewHeld = false

    onHoveredChanged: {
        if (screen.preview) {
            if (hovered) previewClose.stop(); else previewClose.restart();
        }
        /**
         * 8D: con pantalla completa, entrar en la franja arma la espera y no despliega
         * nada; ya revelado, la cara hover sólo se engancha sobre el island (`onPointChanged`
         * del HoverHandler), nunca por volver a la franja.
         */
        if (screen.fullscreen) {
            if (hovered) {
                fsHide.stop();
                if (!screen.fsReveal && !screen.surfaceOpen && !screen.pinned) fsDwell.restart();
            } else {
                fsDwell.stop();
                fsHide.restart();
                graceTimer.restart();
            }
            return;
        }
        if (hovered) {
            if (Settings.autoHide && !screen.expanded) {
                screen.revealing = true;
                revealTimer.stop();
            } else if (screen.bootSettled && !screen.revealing) {
                screen.hoverLatch = true;
                graceTimer.stop();
            }
        } else {
            graceTimer.restart();
            revealTimer.restart();
        }
    }

    /**
     * Una vista previa que se cierra sola (el puntero se fue) deja `hoverLatch` puesto:
     * la gracia saltó mientras seguía abierta y volvió sin reprogramarse, y nada más la
     * arrancaba. Medido en la 8B-1 (camino de la 4C): el island se quedó en la cara
     * hover con `hovered` false indefinidamente. Al cerrarse, si no hay puntero, se
     * rearma.
     */
    onSurfaceOpenChanged: {
        if (!screen.surfaceOpen && !screen.hovered && screen.hoverLatch) graceTimer.restart();
        if (!screen.surfaceOpen) screen.fsSettle();
    }

    /** Pointer left: drop the hover latch once the morph has settled. */
    Timer {
        id: graceTimer
        interval: 300
        onTriggered: {
            if (screen.hovered || screen.pinned || screen.surfaceOpen)
                return;
            if (island.closeness < 0.95) {
                graceTimer.restart();
                return;
            }
            screen.hoverLatch = false;
        }
    }

    /** Pointer left the reveal strip and the island: end the reveal session. */
    Timer {
        id: revealTimer
        interval: 350
        onTriggered: if (!screen.hovered && !screen.pinned && !screen.surfaceOpen) screen.revealing = false
    }

    Connections {
        target: Settings
        function onAutoHideChanged() {
            screen.pinned = false;
            screen.hoverLatch = false;
            screen.revealing = false;
        }
    }

    // ---- reserve strip (optional exclusive zone) ----------------------

    PanelWindow {
        id: reserve
        screen: screen.modelData
        visible: Settings.reserveSpace
        color: "transparent"
        exclusionMode: ExclusionMode.Normal
        // 8C-1: con la barra, su alto (futureHoverBarsurface: «la zona reservada deberá
        // corresponder a la altura de la barra»); una surface desplegada no la aumenta.
        exclusiveZone: overlay.reservedH
        // 2026-11-19: en el borde de la barra (arriba con el island); a un lado, una columna de ese ancho
        implicitHeight: overlay.reservedH
        implicitWidth: overlay.reservedH
        aboveWindows: true
        anchors {
            top: screen.reserveEdge !== "bottom"
            bottom: screen.reserveEdge !== "top"
            left: screen.reserveEdge !== "right"
            right: screen.reserveEdge !== "left"
        }
        WlrLayershell.namespace: "sumi-shell-reserve"
        mask: Region {}
    }

    // ---- overlay ------------------------------------------------------

    PanelWindow {
        id: overlay
        screen: screen.modelData
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "sumi-shell"
        /**
         * Con una superficie abierta, foco de teclado exclusivo de siempre.
         * Con sólo el peek (`pinned`, sin superficie) también (Fase 10.h): así
         * la cara hover se puede recorrer con ←/→ y ⏎. `Esc` o un clic fuera lo
         * sueltan, igual que cierran el peek.
         */
        WlrLayershell.keyboardFocus: (screen.engaged || screen.pinned)
            ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        anchors { top: true; left: true; right: true; bottom: true }

        readonly property real topGap: Metrics.topGap * screen.s
        /** La franja reservada de esta presentación: barra (con o sin muesca), dock o island. */
        readonly property real reservedH: screen.barMode
            ? (screen.barDock ? Metrics.reservedBarDockH(screen.s) : Metrics.reservedBarH(screen.s))
            : (screen.dockMode ? Metrics.reservedDockH(screen.s) : Metrics.reservedH(screen.s))

        /** ISLAND.md §3.2: con la sesión bloqueada el compositor ya retira la entrada; sin máscara no queda estado raro al volver. */
        mask: Lock.engaged ? noRegion
            : screen.concealed ? fsStrip
            : screen.modal ? fullRegion
            : journey.busy ? (screen.surfaceOpen ? islandRegion : noRegion)
            : screen.fullscreen ? fsUnion
            : screen.barMode ? barUnion
            : Settings.autoHide && (screen.revealing || screen.hidden) ? revealUnion : restRegion

        Region { id: noRegion }
        Region { id: fullRegion; width: overlay.width; height: overlay.height }

        /** The island rect, widened to its target so a growing island keeps the pointer covered. */
        Region {
            id: islandRegion
            // gestos (2026-11-17): mientras el OSD de la rueda se adelanta, la huella que tenía la forma al girar
            readonly property real baseW: Math.max(island.width, island.targetW, island.gestureHoldW)
            readonly property real baseH: Math.max(island.height, island.targetH, island.gestureHoldH)
            // 8C-1: con la barra, desde su borde inferior: el hueco hasta el panel sigue dentro
            readonly property real top: screen.barMode ? Math.min(bar.y + bar.height, island.y) : island.y
            /**
             * 2026-11-19: colgando de otro borde, lo mismo desde ESE lado de la barra: abajo crece hacia arriba (lo que
             * será el panel queda por encima de la forma de ahora); a un lado, hacia dentro, centrado a lo largo.
             */
            readonly property rect box: {
                const ix = island.x, iy = island.y, w = island.width, h = island.height, bw = baseW, bh = baseH;
                switch (screen.attachEdge) {
                case "bottom": {
                    const far = iy + h, hi = screen.barMode ? Math.max(far, bar.y) : far;
                    return Qt.rect(ix + (w - bw) / 2, far - bh, bw, Math.max(0, hi - (far - bh)));
                }
                case "left": {
                    const near = screen.barMode ? Math.min(bar.x + bar.width, ix) : ix;
                    return Qt.rect(near, iy + (h - bh) / 2, Math.max(0, ix + bw - near), bh);
                }
                case "right": {
                    const far = ix + w, hi = screen.barMode ? Math.max(far, bar.x) : far;
                    return Qt.rect(far - bw, iy + (h - bh) / 2, Math.max(0, hi - (far - bw)), bh);
                }
                }
                return Qt.rect(ix + (w - bw) / 2, top, bw, Math.max(0, iy + bh - top));
            }
            x: box.x
            y: box.y
            width: box.width
            height: box.height
        }

        /** La barra ∪ la forma que cuelga de ella (8C-1). */
        Region {
            id: barUnion
            x: bar.x
            y: bar.y
            width: bar.width
            height: bar.height
            Region {
                x: islandRegion.x
                y: islandRegion.y
                width: islandRegion.width
                height: islandRegion.height
            }
        }

        /**
         * Reposo (fase 8B-1): el island ∪ las dos piezas circulares. Una pieza oculta
         * mide 0: el hueco entre piezas nunca es clicable, así que los clics ahí siguen
         * llegando a la ventana de debajo.
         */
        Region {
            id: restRegion
            x: islandRegion.x
            y: islandRegion.y
            width: islandRegion.width
            height: islandRegion.height
            Region {
                x: musicCircle.x
                y: musicCircle.y
                width: musicCircle.shown && !screen.hidden ? musicCircle.width : 0
                height: musicCircle.height
            }
            Region {
                x: netCircle.x
                y: netCircle.y
                width: netCircle.shown && !screen.hidden ? netCircle.width : 0
                height: netCircle.height
            }
            Region {
                x: recPill.x
                y: recPill.y
                width: recPill.shown ? recPill.width : 0
                height: recPill.height
            }
        }

        /**
         * 8D: la franja de detección con pantalla completa. Fina y centrada arriba, sin
         * teclado (la ventana no lo pide mientras no hay nada activo) y sin cubrir la
         * pantalla: la aplicación sigue recibiendo todo lo demás.
         */
        Region {
            id: fsStrip
            readonly property real w: Metrics.revealW * screen.s
            /** 2026-11-19: en el borde de la barra, frente a su centro (con el island, arriba al centro). */
            readonly property rect box: {
                const e = screen.barMode ? screen.barEdge : "top", t = Metrics.fsStripH;
                const c = !screen.barMode ? overlay.width / 2
                    : screen.barVertical ? bar.y + bar.height / 2 : bar.x + bar.width / 2;
                const a = Math.max(0, c - fsStrip.w / 2);
                switch (e) {
                case "bottom": return Qt.rect(a, overlay.height - t, fsStrip.w, t);
                case "left": return Qt.rect(0, a, t, fsStrip.w);
                case "right": return Qt.rect(overlay.width - t, a, t, fsStrip.w);
                }
                return Qt.rect(a, 0, fsStrip.w, t);
            }
            x: box.x
            y: box.y
            width: box.width
            height: box.height
        }
        /** Revelado: la franja ∪ lo que se ve (island y piezas, o barra y forma). */
        Region {
            id: fsUnion
            x: fsStrip.x
            y: fsStrip.y
            width: fsStrip.width
            height: fsStrip.height
            Region {
                x: islandRegion.x
                y: islandRegion.y
                width: islandRegion.width
                height: islandRegion.height
            }
            Region {
                x: musicCircle.x
                y: musicCircle.y
                width: musicCircle.shown ? musicCircle.width : 0
                height: musicCircle.height
            }
            Region {
                x: netCircle.x
                y: netCircle.y
                width: netCircle.shown ? netCircle.width : 0
                height: netCircle.height
            }
            Region {
                x: recPill.x
                y: recPill.y
                width: recPill.shown ? recPill.width : 0
                height: recPill.height
            }
            Region {
                x: bar.x
                y: bar.y
                width: screen.barMode ? bar.width : 0
                height: bar.height
            }
        }

        /** Auto-hide: a thin top-centre strip the pointer can always find. */
        Region {
            id: revealRegion
            readonly property real revealW: Metrics.revealW * screen.s
            x: Math.max(0, overlay.width / 2 - revealW / 2)
            y: 0
            width: revealW
            height: Metrics.revealH * screen.s
        }

        /** Strip ∪ island while the island is being pulled in, so the hover never flickers. */
        Region {
            id: revealUnion
            x: revealRegion.x
            y: revealRegion.y
            width: revealRegion.width
            height: revealRegion.height
            // una Region anidada copia sólo el rectángulo de otra, no sus hijas: las piezas, repetidas
            Region {
                x: islandRegion.x
                y: islandRegion.y
                width: islandRegion.width
                height: islandRegion.height
            }
            Region {
                x: musicCircle.x
                y: musicCircle.y
                width: musicCircle.shown && !screen.hidden ? musicCircle.width : 0
                height: musicCircle.height
            }
            Region {
                x: netCircle.x
                y: netCircle.y
                width: netCircle.shown && !screen.hidden ? netCircle.width : 0
                height: netCircle.height
            }
            Region {
                x: recPill.x
                y: recPill.y
                width: recPill.shown ? recPill.width : 0
                height: recPill.height
            }
        }

        /** Backdrop: a press outside the island dismisses the modal state. */
        MouseArea {
            anchors.fill: parent
            enabled: screen.modal
            acceptedButtons: Qt.AllButtons
            onPressed: (mouse) => {
                const inRect = function (r) {
                    return r.width > 0 && mouse.x >= r.x && mouse.x <= r.x + r.width
                        && mouse.y >= r.y && mouse.y <= r.y + r.height;
                };
                // Las piezas tampoco son «fuera»: sin esto, pulsar Red con el Centro de control
                // abierto lo cerraba aquí y la pieza lo reabría (8B-2).
                const inside = inRect(islandRegion) || (screen.barMode && inRect(bar))
                    || (musicCircle.shown && inRect(musicCircle)) || (netCircle.shown && inRect(netCircle))
                    || (recPill.shown && inRect(recPill));
                if (screen.barMode && bar.moreOpen) {
                    // More: un clic fuera (o sobre la barra) lo cierra y nada más
                    const mm = bar.moreRect();
                    if (!(mouse.x >= mm.x && mouse.x <= mm.x + mm.width && mouse.y >= mm.y && mouse.y <= mm.y + mm.height))
                        bar.moreOpen = false;
                    return;
                }
                if (inside)
                    return;
                if (screen.menuOpen) {
                    // Un clic fuera cierra el menu y nada mas: el island sigue
                    // donde estaba, como en cualquier menu contextual.
                    trayMenu.close();
                    return;
                }
                if (screen.surfaceOpen)
                    screen.closeSurface();
                screen.pinned = false;
                screen.hoverLatch = false;
                screen.revealing = false;
            }
        }

        FocusScope {
            id: focusScope
            anchors.fill: parent
            focus: screen.engaged || screen.pinned

            /**
             * **El hover del island, y por qué se queda en pantalla completa.**
             *
             * El handler cubre todo el overlay a propósito: la máscara de input
             * de `Screen` es island ∪ tira de revelado cuando `autoHide` está
             * encendido, y la tira **no** está sobre el island. Bajar el handler
             * al island (probado el 2026-09-16) deja de encender `revealing` y
             * el escritorio ya no se puede sacar del borde.
             *
             * Lo que sí había que arreglar: **con una superficie abierta la
             * máscara es `fullRegion`** —para que un clic fuera cierre—, así que
             * este handler dice `hovered = true` con el puntero en cualquier
             * parte de la pantalla. `enabled` lo ignora mientras dura, pero al
             * cerrar el panel el handler se reactiva y reporta ese `true` antes
             * de que la máscara haya vuelto a encoger: `hoverLatch` se quedaba
             * puesto, `graceTimer` sólo arranca desde `onHoveredChanged`, y el
             * island **se quedaba desplegado a 828 px indefinidamente** con el
             * cursor en la otra punta (medido: `hold=hover`, cursor 979,538, sin
             * soltar en minutos). Con teclado, que es como se usa este shell, no
             * se corrige solo: hay que tocar el ratón.
             *
             * `maskSettle` es esa ventana: al reactivarse se suelta el latch y
             * se ignora lo que el handler diga hasta que la máscara vuelva a ser
             * la del island. Si el puntero está de verdad encima, el primer
             * movimiento lo abre otra vez.
             */
            HoverHandler {
                id: islandHover
                // En vista previa sigue vivo: salir del panel es lo que la cierra.
                enabled: (!screen.surfaceOpen || screen.preview) && !screen.pinned
                /**
                 * Fase 8B-1: sobre un círculo NO es hover del island. Si lo fuera, la cara
                 * hover (818 px) se desplegaría encima del círculo que se iba a pulsar.
                 *
                 * Por POSICIÓN y no por el `hovered` de la pieza: al entrar, este handler se
                 * entera antes que el de la pieza, y ese instante de «hover del island»
                 * bastaba para enganchar `hoverLatch` (no tiene espera). Lo vio el usuario con
                 * el ratón: acercándose en diagonal a la carátula se desplegaba la cara hover
                 * sin llegar al island (la máscara de la pieza es su cuadrado).
                 *
                 * Calculado A MANO al moverse el puntero, no como binding: un binding que lee
                 * la pieza cierra un bucle (hover → modo → pieza → hover; «Binding loop
                 * detected», journal de la 8B-1).
                 *
                 * En píxeles enteros hacia fuera: `Region` trunca a entero y la pieza no cae en
                 * uno (con uiScale 0,9 mide 34,2 px en x = 844,8), así que la máscara empezaba
                 * en 844 y 7, y esa columna y esa fila contaban como island: entrar a la pieza
                 * por su borde izquierdo o superior desplegaba la cara hover (medido el
                 * 2026-09-28). Con floor/ceil la máscara queda siempre dentro de este rectángulo.
                 */
                function over(c) {
                    const p = islandHover.point.position;
                    return c.shown && p.x >= Math.floor(c.x) && p.x <= Math.ceil(c.x + c.width)
                        && p.y >= Math.floor(c.y) && p.y <= Math.ceil(c.y + c.height);
                }
                function overIsland() {
                    const p = islandHover.point.position;
                    return p.x >= islandRegion.x && p.x <= islandRegion.x + islandRegion.width
                        && p.y >= islandRegion.y && p.y <= islandRegion.y + islandRegion.height;
                }
                onHoveredChanged: if (enabled && !maskSettle.running)
                    screen.hovered = hovered && !over(musicCircle) && !over(netCircle) && !over(recPill)
                /**
                 * Al moverse, SÓLO lo que tiene que ver con las piezas: de pieza a cápsula (y
                 * sólo si el puntero está de verdad sobre la forma) o de cápsula a pieza. Un
                 * recálculo completo aquí reponía un `hovered` caducado: con un panel abierto
                 * la máscara es toda la pantalla, el handler se queda en true y al encoger no
                 * llega salida (medido: island atascado en la cara hover con el puntero a
                 * 700 px, 8B-2).
                 */
                onPointChanged: {
                    if (!enabled || maskSettle.running) return;
                    const onPiece = over(musicCircle) || over(netCircle) || over(recPill);
                    // 8D: revelado en pantalla completa, la cara hover se engancha al llegar
                    // al island (no en la franja del borde)
                    if (screen.fullscreen && screen.fsReveal && !screen.barMode && !screen.hoverLatch
                            && !onPiece && overIsland() && island.mode === "rest")
                        screen.hoverLatch = true;
                    if (screen.hovered && onPiece)
                        screen.hovered = false;
                    else if (!screen.hovered && islandHover.hovered && !onPiece && overIsland())
                        screen.hovered = true;
                }
                onEnabledChanged: if (enabled) {
                    screen.hovered = false;
                    maskSettle.restart();
                }
            }

            Timer { id: maskSettle; interval: 200 }

            /**
             * Escape: la superficie abierta tiene **derecho de veto**, y si no
             * lo usa se cierra como siempre.
             *
             * Hacia falta porque Qt despacha `onEscapePressed` ANTES que
             * `onPressed`, asi que la superficie no llegaba a ver la tecla:
             * la ficha de una red wifi (9.f.2b) queria volver a la lista con
             * Escape y en su lugar se cerraba el island entero. Medido el
             * 2026-09-09.
             *
             * El contrato para las superficies es el de siempre: quien quiera
             * quedarse con una tecla pone `event.accepted = true`. Ninguna de
             * las anteriores toca Escape, asi que su comportamiento no cambia.
             */
            Keys.onEscapePressed: (e) => {
                // El evento llega YA aceptado a un handler especifico, asi que
                // sin bajarlo primero la comprobacion de abajo nunca se cumple
                // y la superficie parecia consumir siempre la tecla.
                e.accepted = false;
                screen.escapeKey(e);
            }
            Keys.onPressed: (e) => screen.pressKey(e)

            /**
             * Alt+← / Alt+→: historial de ESTA pantalla (DESIGN §3). `Shortcut` de ventana
             * y no `Keys`: un campo de texto con el foco se quedaría la flecha. En Linux
             * `TextInput` no reclama Alt+flechas (su salto por palabra es Ctrl), así que el
             * atajo le llega también escribiendo.
             */
            Shortcut {
                sequences: ["Alt+Left"]
                enabled: screen.surfaceOpen && !Lock.engaged
                onActivated: island.historyBack()
            }
            Shortcut {
                sequences: ["Alt+Right"]
                enabled: screen.surfaceOpen && !Lock.engaged
                onActivated: island.historyForward()
            }

            TrayMenu {
                id: trayMenu
                // por encima de la barra, el island y los círculos; debajo de la tooltip de la cara hover (z 5)
                z: 4
                s: screen.s
                onOpened: screen.menuOpen = true
                onClosed: screen.menuOpen = false
            }

            /**
             * LA HOVER BAR PERSISTENTE (8C-1). Declarada antes que el island: los paneles
             * que cuelgan de ella se pintan por encima (su tooltip incluido).
             */
            BarJourney {
                id: journey
                permanent: screen.barMode
                destination: screen.barEdge
                animate: Settings.loaded && !screen.concealed && !Lock.engaged
                onBusyChanged: if (busy) { bar.moreOpen = false; trayMenu.close(); }
                // Último centro de la isla dibujada, también cuando la forma estaba desplazada.
                property real islandOffset: 0
                islandPosition: {
                    const a = Math.max(0, focusScope.width / 2 - inset);
                    const b = Math.max(0, focusScope.height / 2 - inset);
                    const r = Math.min(72 * screen.s, a, b);
                    return Math.max(r - a, Math.min(a - r, islandOffset))
                        / Math.max(1, a + b - 2 * r + r * Math.PI / 2);
                }
                readonly property bool travelling: busy && Math.abs(BarEdge.nearestStop(position, edge) - position) > 0.0001
                readonly property real inset: (screen.dockPref ? 0 : Math.round(overlay.topGap)) + bar.thick / 2
                readonly property var point: travelling
                    ? BarEdge.rimPoint(position, focusScope.width, focusScope.height, inset, 72 * screen.s) : null
                // Al doblar la esquina los extremos de la cápsula deben caber dentro del monitor.
                readonly property real cornerLimit: {
                    if (!point) return Infinity;
                    const a = point.angle * Math.PI / 180;
                    const dx = Math.min(point.x, focusScope.width - point.x);
                    const dy = Math.min(point.y, focusScope.height - point.y);
                    return bar.thick + 2 * Math.max(0, Math.min(Math.abs(Math.cos(a)) < 0.001 ? Infinity : (dx - bar.thick / 2) / Math.abs(Math.cos(a)),
                        Math.abs(Math.sin(a)) < 0.001 ? Infinity : (dy - bar.thick / 2) / Math.abs(Math.sin(a))));
                }
            }

            Bar {
                id: bar
                // 2026-10-01: con el dock, pegada al borde como la muesca (`dockLift` la sube)
                // 2026-10-02: en píxeles enteros, arriba y de alto. Con `uiScale` 0,9 el hueco medía
                // 7,2 px y el filo de abajo caía a mitad de píxel: lo que cuelga de ella (translúcido)
                // dejaba una raya en la unión, oscura si se solapaban y clara si no (captura del usuario)
                // 2026-11-19: en su borde, con su alineación y su longitud (`focusScope.barBox`); arriba, al
                // 100 % y al centro, el mismo rectángulo que daban las anclas de antes
                x: focusScope.barBox.x
                y: focusScope.barBox.y
                width: focusScope.barBox.w
                height: focusScope.barBox.h
                edge: journey.edge
                unfoldRaw: journey.spread
                s: screen.s
                /**
                 * Por la PREFERENCIA de dock, no por `barDock` (2026-10-01, pedido del usuario): así
                 * el despliegue dock → barra nace de la muesca —pegada y opaca desde el primer
                 * fotograma— y el pliegue vuelve a ella, en vez de pasar por la cápsula de vidrio
                 * del island (medido con grim: subía y se volvía opaca a mitad del despliegue).
                 * Sin dock nada cambia: `dockLift` se queda en 0.
                 */
                dockMode: screen.dockPref
                sharedDockLift: island.dockLift
                presentationOpacity: 1 - focusScope.panelPresence * (1 - focusScope.barPresence)
                capsuleH: island.restH
                // el tramo del filo interior que tapa lo que cuelga (forma + hombros), a lo largo, en px de la barra
                hangX: island.attached ? (bar.vertical ? island.y - bar.y : island.x - bar.x) - island.shoulderW : 0
                hangW: island.attached ? (bar.vertical ? island.height : island.width) + 2 * island.shoulderW : 0
                // se despliega desde la cápsula real (ya no mide 160 fijos); en barra el
                // reposo no se pinta y su medida puede no estar: entonces la de diseño
                capsuleW: Math.min(journey.cornerLimit, island.restW > 2 * Metrics.restPad * screen.s + 1 ? island.restW : Metrics.restW * screen.s)
                screenName: screen.name
                open: screen.open
                navActive: screen.barMode && screen.pinned && !screen.surfaceOpen
                preview: screen.preview
                // 8E: visible también mientras se pliega de vuelta al island
                shown: screen.barMode
                visible: (screen.barMode || journey.busy || bar.unfold > 0.01) && !Lock.engaged
                opacity: screen.concealed ? 0 : journey.exposure
                Behavior on opacity { enabled: !journey.busy; NumberAnimation { duration: Motion.fast } }
                // 8D: oculta, sale por su borde (arriba, como el island); revelada, vuelve superpuesta
                SpringValue { id: barConceal; target: screen.concealed ? -(bar.thick + overlay.topGap) : 0; honorOff: false }
                transform: [
                    Rotation {
                        origin.x: bar.width / 2; origin.y: bar.height / 2
                        angle: journey.point ? journey.point.angle - BarEdge.ringEdges.indexOf(bar.edge) * 90 : 0
                    },
                    Translate {
                        x: journey.point ? journey.point.x - bar.x - bar.width / 2 : 0
                        y: journey.point ? journey.point.y - bar.y - bar.height / 2 : 0
                    },
                    Translate {
                        x: bar.edge === "left" ? barConceal.value : bar.edge === "right" ? -barConceal.value : 0
                        y: bar.edge === "top" ? barConceal.value : bar.edge === "bottom" ? -barConceal.value : 0
                    }
                ]
                enabled: !screen.concealed && !journey.busy
                // 8E: la surface nace bajo el acceso (`bar.originX`, en px de la ventana)
                // (a lo largo: en vertical, `originX` es una y)
                onRequestSurface: (n) => {
                    screen.pendingOrigin = bar.originX - focusScope.alongSize / 2;
                    screen.toggleSurface(n);
                    screen.pendingOrigin = NaN;
                }
                onPreviewRequested: (n) => {
                    screen.pendingOrigin = bar.originX - focusScope.alongSize / 2;
                    screen.openPreview(n);
                    screen.pendingOrigin = NaN;
                }
                onTrayMenuRequested: function (menuHandle, ax, ay) {
                    screen.showTrayMenu(menuHandle, ax, ay, bar.edge);
                }
            }

            /** Lecturas básicas para la barra: el nivel «summary» de Sysmon (6A). */
            Claim {
                target: Sysmon
                key: "bar:" + screen.name
                value: screen.barMode && !screen.concealed && !Lock.engaged ? "summary" : false
            }

            Island {
                id: island
                readonly property real visibleOffset: x + width / 2 - focusScope.width / 2
                onVisibleOffsetChanged: if (!screen.barMode && !journey.busy) journey.islandOffset = visibleOffset
                // 8C-1: con la barra, cuelga de ella. 8E: sólo mientras hay algo colgando
                // (`belowBar`); en reposo se queda en la franja, donde nace y muere la barra
                // 8F-1: el dock pega la forma al borde (`dockLift` la sube con suavidad)
                // 2026-10-01: pegado a la barra, ya no a `barGap`. 2026-10-02: justo debajo de su filo (entero,
                // ver `bar`), sin el píxel de solape de antes: los dos vidrios translúcidos se sumaban en esa
                // fila y dibujaban una raya oscura; la barra ya corta su filo ahí
                // One animated position for presentation changes; the input region reads this y.
                SpringValue {
                    id: dropSpring
                    // el grosor de la barra (y su hueco, si el panel no cabe en una barra corta y cuelga despegado)
                    target: (screen.barMode && screen.belowBar && !screen.concealed) ? bar.thick + focusScope.detachGap : 0
                    animate: island.shapeShown
                }
                property real presentationDrop: dropSpring.value
                // Recogida (al abrir desde reposo o ya cerrada), la forma nace en el filo de la barra: sin caer
                // desde dentro de ella, cuyo vidrio translúcido solapaba unos fotogramas (raya oscura, 2026-10-28)
                // Dock already animates dockLift: do not put a second spring behind it.
                // A stable viewport across modes keeps tall content from reflowing on every frame.
                // The arc uses only spare height; a full-height panel takes the direct path.
                availableTop: overlay.topGap + bar.thick + focusScope.shortGap
                // la coreografía con la barra arriba (`topUnfold`: 0 si la barra está en otro borde)
                readonly property real coordinatedDrop: (bar.height + focusScope.detachGap) * focusScope.topUnfold
                    + focusScope.clearance * 4 * focusScope.topUnfold * (1 - focusScope.topUnfold)
                // con la barra arriba y entera, lo de siempre; en otro borde o más corta, la unión es la del muelle
                presentationJoin: screen.edgeTop && !focusScope.barShort
                    ? (1 - focusScope.panelPresence) * Math.max(0, Math.min(1, island.attachment))
                        + focusScope.panelPresence * focusScope.smooth((focusScope.topUnfold - 0.9) / 0.1)
                    : Math.max(0, Math.min(1, island.attachment))
                /**
                 * 2026-11-19: arriba, lo de siempre (centrada + `hOffset`, que es lo que hacían las anclas, y la caída
                 * coordinada con la barra). En otro borde, pegada al lado interior de la barra (`presentationDrop` es
                 * lo que la separa de su lado exterior) y a lo largo con `hOffset`; mientras la barra se despliega o
                 * se pliega, entre esa posición y la del island arriba, con el mismo `unfold`: sin saltos.
                 */
                x: screen.edgeTop ? (parent.width - width) / 2 + island.hOffset : focusScope.edgePos().x
                y: screen.edgeTop
                    ? overlay.topGap * (1 - island.dockLift)
                        + focusScope.topUnfold * (bar.y - overlay.topGap * (1 - island.dockLift))
                        + presentationDrop * (1 - focusScope.panelPresence) + coordinatedDrop * focusScope.panelPresence
                    : focusScope.edgePos().y
                attachEdge: screen.attachEdge
                // el tramo a lo largo: el recto de la barra, o la pantalla si el panel no cabe en una barra corta
                alongLo: screen.barMode && (!screen.edgeTop || focusScope.barShort)
                    ? (focusScope.barFits ? focusScope.barLo : 16 * screen.s) : -1
                alongHi: screen.barMode && (!screen.edgeTop || focusScope.barShort)
                    ? (focusScope.barFits ? focusScope.barHi : focusScope.alongSize - 16 * screen.s) : -1
                barMidOffset: screen.barMode ? focusScope.barSpan.start + focusScope.barSpan.len / 2 - focusScope.alongSize / 2 : 0
                roomW: screen.edgeTop || screen.attachEdge === "bottom" ? -1
                    : screen.attachEdge === "left" ? focusScope.width - (bar.x + bar.width) - focusScope.shortGap - 16 * screen.s
                    : bar.x - focusScope.shortGap - 16 * screen.s
                roomH: screen.edgeTop ? -1
                    : screen.attachEdge === "bottom" ? bar.y - focusScope.shortGap - 16 * screen.s
                    : focusScope.height - 32 * screen.s
                /**
                 * Por la preferencia (2026-10-01): con la barra-muesca lo que cuelga de ella es también
                 * muesca —opaco, sin filo— y se lee dibujado desde la barra. En reposo con la barra el
                 * island no se ve, así que no hay más cambio; sin barra vale lo mismo que `dockMode`.
                 */
                dockMode: screen.dockPref
                // 2026-11-19: y si cabe en el tramo recto de la barra (una barra corta y un panel ancho: despegado)
                attached: screen.barMode && screen.belowBar && !screen.concealed && focusScope.barFits
                // y si no cabe: con la barra-muesca deja de ser muesca y cuelga como tarjeta suelta (2026-11-21)
                detached: screen.barMode && screen.belowBar && !screen.concealed && !focusScope.barFits
                swapHidden: (journey.busy && island.mode === "rest") || (screen.barMode && island.mode === "rest" && !screen.belowBar)
                    || (!screen.barMode && island.mode === "rest" && bar.unfold > 0.02)
                s: screen.s
                screenName: screen.name
                barMode: screen.barMode
                open: screen.open
                preview: screen.preview
                onPreviewRequested: (n) => screen.openPreview(n)
                expanded: screen.expanded
                hidden: screen.hidden

                /** El OSD es un estado del island desde el 2026-09-15 (core/Osd). */
                osdActive: osd.active
                osdLevel: osd.level
                osdOff: osd.off
                osdGlyph: osd.glyph
                osdKind: osd.kind
                osdMode: osd.mode
                noticeText: osd.noticeText
                noticeGlyph: osd.noticeGlyph
                noticeTone: osd.noticeTone
                /** Gestos (2026-11-17): la rueda pide el OSD de volumen también cuando el nivel no se mueve (0 o 100 %). */
                onGestureFeedback: (kind) => osd.flash(kind)
                // El HUD conserva su sitio; la banda contextual deja libre toda su fila, también al desvanecerse.
                belowAccessoryH: recPill.visible ? recPill.height + Metrics.recPillGap * screen.s : 0

                onTrayMenuRequested: function (menuHandle, cx, bottom) {
                    screen.showTrayMenu(menuHandle, cx, bottom, "top");
                }
                onTrayMenuCloseRequested: trayMenu.close()
                onTrayMenuEnterRequested: (i) => trayMenu.enter(i)
                onTrayMenuBackRequested: trayMenu.back()
                trayMenuDump: trayMenu.dump()

                /**
                 * Ya no se aparta por el OSD: el OSD **es** el island (core/Osd).
                 * Sólo desaparece con una ventana a pantalla completa.
                 */
                opacity: (screen.islandConcealed || Lock.engaged) ? 0 : 1
                /**
                 * ISLAND.md §3.2: al bloquear el island se oculta SIN fundido — es el
                 * relevo con la réplica del lock, no un desvanecido propio. `enabled`
                 * cambia por el mismo `Lock.engaged` que mueve `opacity`, así que
                 * queda deshabilitado justo en esa transición; el fundido de pantalla
                 * completa sigue animado.
                 */
                Behavior on opacity {
                    enabled: !Lock.engaged
                    NumberAnimation { duration: Motion.fast; easing.type: Motion.easeStandard }
                }
                // Geometría con máscara de input detrás: firme, sin rebote.
                SpringValue {
                    id: islandConceal
                    // por su lado (con la barra en otro borde, por el de la barra)
                    target: (screen.islandConcealed || screen.hidden)
                        ? -((island.alongVertical ? island.width : island.height) + overlay.topGap) : 0
                    honorOff: false
                }
                // la solapa de Flap (estilos de forma, 2026-11-21, ADR-40) gira desde el borde de la barra, antes del desplazamiento
                transform: [island.styleRotation, islandShift]
                Translate {
                    id: islandShift
                    x: screen.attachEdge === "left" ? islandConceal.value : screen.attachEdge === "right" ? -islandConceal.value : 0
                    y: screen.attachEdge === "top" ? islandConceal.value : screen.attachEdge === "bottom" ? -islandConceal.value : 0
                }

                onRequestSurface: (n) => {
                    // "peek" no es una superficie: es la cara hover de iconos.
                    // Lo pide la paleta de la CLI (10.g) para su verbo `menu`.
                    if (n === "peek") {
                        if (screen.closeSurface())
                            screen.pinned = true;
                        return;
                    }
                    screen.openSurface(n);
                }
                onRequestClose: screen.closeSurface()


                /**
                 * Fase 4C: un clic DENTRO de una vista previa la fija, y el clic sigue
                 * llegando al control pulsado (se ejecuta una vez, sin clic extra: DESIGN
                 * §2). Pasivo a propósito: un TapHandler de contenedor roba el clic
                 * (memoria del proyecto); un PointHandler sólo observa.
                 */
                PointHandler {
                    enabled: screen.preview
                    acceptedButtons: Qt.AllButtons
                    onActiveChanged: if (active) screen.engage()
                }

                /** Tap: pin (no auto-hide) or latch the hover expansion (auto-hide). */
                TapHandler {
                    enabled: !screen.surfaceOpen
                    gesturePolicy: TapHandler.WithinBounds
                    onTapped: {
                        if (Settings.autoHide)
                            screen.hoverLatch = !screen.hoverLatch;
                        else
                            screen.pinned = !screen.pinned;
                    }
                }
            }

            /**
             * LAS PIEZAS LATERALES (fase 8B-1): Música a la izquierda, Red a la derecha,
             * a una distancia FIJA del centro de la pantalla — medida desde el ancho de
             * diseño de la cápsula en reposo, no desde su ancho real, así que ni un aviso
             * ni la otra pieza las mueven.
             *
             * La distancia fija era la de la 8B-1; desde la 8B-2 siguen el borde de la forma
             * (ver `sideX`).
             */
            /**
             * 8B-2 (revisada con el usuario el 2026-09-25): con un panel abierto las piezas
             * NO se quedan quietas — la cápsula crece hasta ser el panel, como antes, y ellas
             * se apartan siguiendo su borde (`island.width`, que ya anima el muelle) y se
             * encogen a `Metrics.sideCompact`. Con la cara hover se ocultan. Aparta la
             * especificación («no se desplazan»): decisión del usuario.
             *
             * `fromSurface`: volviendo de un panel siguen visibles y regresan con la forma;
             * volviendo de la cara hover o del OSD esperan a que la forma se recoja (8B-1: si
             * no, reaparecían encima de la forma aún ancha).
             */
            // One geometric driver (Bar.unfold), per monitor. No timers, reopening or reparenting.
            // The panel leaves the seam, turns while the bar is still contracting, then returns.
            // Blend by visible height during opening/closing so interruptions cannot jump position.
            /**
             * LA GEOMETRÍA DE LA BARRA (2026-11-19, lib/bar-edge.js). `alongSize` es la pantalla a lo largo de su borde;
             * `barSpan`, su tramo (porcentaje, centrado, y el mínimo que pone su contenido, `bar.minLen`); `barBox`,
             * su rectángulo. `barLo`/`barHi` es el tramo RECTO, donde caben la forma que cuelga y sus hombros (lo de
             * antes: margen + esquina + hombro + 2). Una barra corta (`barShort`) con un panel que no cabe en él lo deja
             * colgar despegado (`barFits`), con el hueco de siempre (`detachGap`), en vez de con los hombros al aire.
             */
            readonly property real alongSize: screen.barVertical ? focusScope.height : focusScope.width
            readonly property var barSpan: BarEdge.span(focusScope.alongSize, overlay.topGap, screen.barLength, bar.minLen)
            readonly property var barBox: BarEdge.rect(journey.edge, focusScope.width, focusScope.height, Math.round(bar.implicitHeight),
                                                       Math.round(overlay.topGap * (1 - bar.dockLift)), focusScope.barSpan)
            readonly property bool barShort: focusScope.barSpan.len < focusScope.alongSize - 2 * overlay.topGap - 0.5
            readonly property real barStraight: (Metrics.restCorner + Metrics.barShoulder + 2) * screen.s
            readonly property real barLo: focusScope.barSpan.start + focusScope.barStraight
            readonly property real barHi: focusScope.barSpan.start + focusScope.barSpan.len - focusScope.barStraight
            readonly property bool barFits: !focusScope.barShort
                || (screen.barVertical ? island.targetH : island.targetW) <= focusScope.barHi - focusScope.barLo
            readonly property real detachGap: focusScope.barFits ? 0 : Metrics.appGap * screen.s
            /**
             * Lo que se descuenta del sitio del panel por si cuelga despegado: con una barra corta, siempre el hueco.
             * No `detachGap`: el sitio decide el tamaño del panel y el tamaño decide si cabe (bucle en `surfaceSize`).
             */
            readonly property real shortGap: focusScope.barShort ? Metrics.appGap * screen.s : 0
            /** El despliegue de la barra para la coreografía de arriba: 0 si la barra está en otro borde. */
            readonly property real topUnfold: journey.edge === "top" ? bar.unfold : 0
            /** Fuera de arriba: pegada al lado interior de la barra y, mientras se despliega, hacia el island de arriba. */
            function edgePos() {
                const W = focusScope.width, H = focusScope.height, w = island.width, h = island.height;
                const d = island.presentationDrop, u = bar.unfold;
                let ex = (W - w) / 2 + island.hOffset, ey = 0;
                switch (screen.attachEdge) {
                case "bottom": ey = bar.y + bar.height - d - h; break;
                case "left": ex = bar.x + d; ey = (H - h) / 2 + island.hOffset; break;
                case "right": ex = bar.x + bar.width - d - w; ey = (H - h) / 2 + island.hOffset; break;
                }
                const tx = (W - w) / 2, ty = overlay.topGap * (1 - island.dockLift);
                return Qt.point(tx + (ex - tx) * u, ty + (ey - ty) * u);
            }

            readonly property real panelPresence: Math.max(0, Math.min(1,
                (island.height - island.restH) / (Metrics.hoverH * screen.s)))
            function smooth(v) { const p = Math.max(0, Math.min(1, v)); return p * p * (3 - 2 * p); }
            readonly property real barPresence: smooth((bar.unfold - 0.4) / 0.35)
            // Keep the entire panel on screen; tall panels get a smaller, still coordinated arc.
            readonly property real clearance: Math.min(0.75 * bar.thick,
                Math.max(0, focusScope.height - island.height - overlay.topGap - bar.thick - 16 * screen.s))
            readonly property bool surfaceMode: !island.small
            property bool fromSurface: false
            onSurfaceModeChanged: if (focusScope.surfaceMode) focusScope.fromSurface = true
            readonly property bool settledRest: island.mode === "rest" && island.width <= island.restW + 4 * screen.s
            onSettledRestChanged: if (focusScope.settledRest) focusScope.fromSurface = false
            onModeWatchChanged: if (island.mode === "hover" || island.mode === "osd" || island.mode === "notice") focusScope.fromSurface = false
            readonly property string modeWatch: island.mode
            // 8E: y no mientras la barra se pliega (vuelven cuando la cápsula ocupa su sitio)
            // 8F-1 las quitaba del dock (DESIGN §4: «son del modo island»); el 2026-10-01 el
            // usuario las pidió también ahí, las mismas y más pequeñas (`sideFactor`)
            readonly property bool sidesShown: !journey.busy && !screen.concealed && !Lock.engaged
                && (((focusScope.surfaceMode || focusScope.panelPresence > 0) && bar.unfold < 0.999)
                    || (!screen.barMode && bar.unfold < 0.02 && (focusScope.settledRest
                        || (island.mode === "rest" && focusScope.fromSurface))))
            readonly property real sideFactor: focusScope.surfaceMode ? Metrics.sideCompact
                : (screen.dockMode ? Math.min(Metrics.dockSide, Metrics.sideRest) : Metrics.sideRest)
            /**
             * Con el dock, DEBAJO de la barra (2026-10-01): la muesca se ensancha hasta ser la barra
             * y se las traga al pasar, en vez de quedar pintadas encima mientras se desvanecen.
             */
            // sólo mientras hay barra: en reposo siguen a z 0, nada puede taparles el clic
            readonly property real sideZ: screen.dockPref && !focusScope.surfaceMode && focusScope.panelPresence <= 0 && (screen.barMode || bar.unfold > 0.01) ? -1 : 0
            /** Centradas en la cápsula en reposo, que con el dock sube al borde. */
            readonly property real sideMid: overlay.topGap * (1 - island.dockLift) + island.restH / 2
            /**
             * Cuánto suben para esconderse (auto-hide, pantalla completa): hasta que su borde de abajo
             * y su sombra (`Glass`: desplazada 3 y difuminada 20) quedan por encima del borde. Antes
             * subían su alto más `topGap`, que sólo bastaba con el círculo al alto de la cápsula; al 80 %
             * (`Metrics.sideRest`) va centrado más abajo y asomaba una tira (2026-11-12, captura del usuario).
             */
            function sideHide(c) { return -(c.y + c.height + 24 * screen.s); }
            /** Borde exterior de la forma, más el aire, con la pantalla como tope. */
            function sideX(c, left) {
                const g = Metrics.sideGap * screen.s;
                // la barra que se despliega aparta las piezas sólo si es la de arriba (en otro borde no las cruza)
                const bodyHalf = journey.edge === "top" ? (bar.capsuleW + (bar.width - bar.capsuleW) * bar.unfold) / 2 : 0;
                // con la muesca, también el faldón de sus uniones con el borde (`island.flareW`)
                const edge = Math.max(island.width / 2 + island.flareW, bodyHalf * focusScope.panelPresence) + g;
                const cx = focusScope.width / 2 + island.hOffset;
                const m = 8 * screen.s;
                return left ? Math.max(m, cx - edge - c.width) : Math.min(focusScope.width - m - c.width, cx + edge);
            }

            IslandCircle {
                id: musicCircle
                coordinated: focusScope.surfaceMode || focusScope.panelPresence > 0
                presentationOpacity: 1 - focusScope.panelPresence * bar.unfold
                s: screen.s
                x: focusScope.sideX(musicCircle, true)
                y: focusScope.sideMid - height / 2
                sizeFactor: focusScope.sideFactor
                z: focusScope.sideZ
                // con la oreja de música del notch se queda (2026-11-18, pedido del autor: es el acceso
                // directo al Mixer); `sideX` ya lo pone fuera de la oreja, que entra en `island.width`
                shown: focusScope.sidesShown && Media.has && Settings.islandMusicCircle
                label: Media.has ? ((Media.playing ? "Playing: " : "Paused: ") + Media.title) : "Music"
                onActivated: screen.toggleFromCircle("media")
                SpringValue {
                    id: musicConceal
                    target: (screen.concealed || screen.hidden) ? focusScope.sideHide(musicCircle) : 0
                    honorOff: false
                }
                transform: Translate {
                    y: musicConceal.value
                }

                /** Carátula recortada en círculo; sin ella, el glifo de música. */
                Image {
                    id: musicArt
                    anchors.fill: parent
                    anchors.margins: 2 * screen.s
                    source: Media.artUrl
                    // FIJO al tamaño de reposo: con el ancho, al encogerse la pieza la imagen se
                    // recargaba en cada fotograma y enseñaba el glifo mientras (8B-2)
                    sourceSize.width: Math.ceil(Metrics.restH * screen.s * 2)
                    sourceSize.height: Math.ceil(Metrics.restH * screen.s * 2)
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    retainWhileLoading: true
                    cache: false
                    visible: false
                }
                Item {
                    id: musicMask
                    anchors.fill: musicArt
                    layer.enabled: true
                    visible: false
                    Rectangle { anchors.fill: parent; radius: Metrics.pill(width); color: "black" }
                }
                MultiEffect {
                    anchors.fill: musicArt
                    source: musicArt
                    visible: musicArt.status === Image.Ready && Media.artUrl.length > 0
                    maskEnabled: true
                    maskSource: musicMask
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 1.0
                }
                Icon {
                    anchors.centerIn: parent
                    name: "music"
                    size: 15 * screen.s * musicCircle.sizeFactor
                    color: Theme.fg
                    visible: !(musicArt.status === Image.Ready && Media.artUrl.length > 0)
                }
                /** Pausa: una marca discreta en la esquina, la carátula sigue. */
                Rectangle {
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    width: 14 * screen.s * musicCircle.sizeFactor
                    height: width
                    radius: Metrics.pill(width)
                    color: Theme.surface
                    border.width: 1
                    border.color: Theme.glassBorder
                    opacity: Media.playing ? 0 : 1
                    scale: Media.playing ? 0.5 : 1
                    Behavior on opacity { NumberAnimation { duration: Motion.fast } }
                    Behavior on scale { NumberAnimation { duration: Motion.fast; easing.type: Easing.OutBack } }
                    Icon {
                        anchors.centerIn: parent
                        name: "pause"
                        size: 8 * screen.s * musicCircle.sizeFactor
                        color: Theme.fg
                    }
                }
            }

            IslandCircle {
                id: netCircle
                coordinated: focusScope.surfaceMode || focusScope.panelPresence > 0
                presentationOpacity: 1 - focusScope.panelPresence * bar.unfold
                s: screen.s
                x: focusScope.sideX(netCircle, false)
                y: focusScope.sideMid - height / 2
                sizeFactor: focusScope.sideFactor
                z: focusScope.sideZ
                shown: focusScope.sidesShown && (Settings.islandNetCircle || netCircle.speed)
                label: netCircle.speed ? "Speed test · " + (isFinite(SpeedTest.liveMbps) ? Math.round(SpeedTest.liveMbps) + " Mb/s" : "measuring")
                                       : netCircle.face.label
                halo: netCircle.speed ? Theme.primary : netCircle.face.color
                onActivated: screen.toggleFromCircle(netCircle.speed ? "speedtest" : "controlCenter")
                /**
                 * F5 (2026-11-27): mientras corre un speed test, el círculo de red lo enseña (cohete o subida) y abre
                 * su vista; con el círculo apagado, aparece sólo mientras dura. En el Edge lo dice su oreja (ADR-37).
                 */
                readonly property bool speed: SpeedTest.busy && island.earLive !== "speed"
                SpringValue {
                    id: netConceal
                    target: (screen.concealed || screen.hidden) ? focusScope.sideHide(netCircle) : 0
                    honorOff: false
                }
                transform: Translate {
                    y: netConceal.value
                }

                /** { glyph, tone, color, label }; ver `Screens.netFace`. */
                readonly property var face: Screens.netFace

                Icon {
                    anchors.centerIn: parent
                    name: netCircle.speed ? (SpeedTest.phase === "upload" ? "upload" : "rocket") : netCircle.face.glyph
                    size: 15 * screen.s * netCircle.sizeFactor
                    // neutro: el glifo legible, el halo apagado
                    color: netCircle.speed ? Theme.primary
                        : netCircle.face.tone === "unknown" ? Theme.fgVariant : netCircle.face.color
                    Behavior on color { ColorAnimation { duration: Motion.standard } }
                }
            }

            /**
             * LA PIEZA DE GRABACIÓN (2026-10-29): el mini HUD del grabador, colgando del borde de abajo
             * de la forma —reposo, cara hover, OSD o un panel abierto— como una zona secundaria del
             * island. Sólo en la presentación island/dock: con la barra lo dice la barra. Con el island
             * escondido (auto-hide) se queda arriba, en su sitio: una grabación no se esconde. No sobre
             * una pantalla completa (saldría en lo que se graba de ella) ni con el grabador abierto, que
             * ya tiene los mismos controles.
             */
            readonly property bool recPillShown: (ScreenRecorder.active || ScreenRecorder.flashing) && Settings.recIndicator
                && !screen.barMode && !screen.concealed && !Lock.engaged && screen.open !== "recorder"
                // con la oreja de grabación del notch (2026-11-17) el tiempo está en la muesca: sin botones, nada que añadir
                && !(island.earLive === "recording" && !Settings.recIslandControls)
            RecorderPill {
                id: recPill
                s: screen.s
                shown: focusScope.recPillShown
                buttonsOnly: island.earLive === "recording"
                x: Math.round(focusScope.width / 2 + island.hOffset - width / 2)
                y: Math.round(Math.min(focusScope.height - height - 8 * screen.s,
                    Math.max(overlay.topGap * (1 - island.dockLift),
                             island.y + islandShift.y + island.height + Metrics.recPillGap * screen.s)))
                onOpenRequested: screen.toggleFromCircle("recorder")
            }

            /**
             * Tooltip flotante de la cara hover (Fase 10.h). Cuelga bajo el
             * island, fuera de sus límites (como el menú de bandeja) — no toca
             * el layout. Dice el nombre del botón bajo el ratón o con el foco de
             * teclado (`island.tipText`); vacío = oculto.
             */
            Glass {
                id: hoverTip
                s: screen.s
                anchors.top: island.bottom
                // con la pieza de grabación colgando, debajo de ella
                anchors.topMargin: 7 * screen.s + (recPill.shown ? recPill.height + Metrics.recPillGap * screen.s : 0)
                anchors.horizontalCenter: island.horizontalCenter
                z: 5

                /** Retiene el último texto no vacío para que no se borre a mitad del fundido. */
                property string shownLabel: ""
                Connections {
                    target: island
                    function onTipTextChanged() {
                        if (island.tipText.length > 0)
                            hoverTip.shownLabel = island.tipText;
                    }
                }

                readonly property bool show: island.tipText.length > 0
                    && !screen.concealed && !osd.active && !Lock.engaged

                width: tipLabel.implicitWidth + 18 * screen.s
                height: tipLabel.implicitHeight + 10 * screen.s
                radius: Metrics.rSm * screen.s

                visible: opacity > 0.01
                opacity: hoverTip.show ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Motion.fast; easing.type: Motion.easeStandard } }

                transform: Translate {
                    // El desplazamiento es movimiento: con reduce motion, ninguno.
                    y: (hoverTip.show || Motion.still) ? 0 : -4 * screen.s
                    Behavior on y {
                        enabled: !Motion.still
                        NumberAnimation { duration: Motion.fast; easing.type: Motion.easeStandard }
                    }
                }

                Text {
                    id: tipLabel
                    anchors.centerIn: parent
                    text: hoverTip.shownLabel
                    color: Theme.fg
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * screen.s
                    font.weight: Font.Medium
                }
            }

            /** Sin geometría: sólo decide cuándo y qué. Lo pinta el island. */
            Osd {
                id: osd
                s: screen.s
                screenName: screen.name
            }
        }

        onVisibleChanged: if (visible && (screen.surfaceOpen || screen.pinned)) focusScope.forceActiveFocus()
        Connections {
            target: screen
            function onSurfaceOpenChanged() { if (screen.surfaceOpen) focusScope.forceActiveFocus(); }
            function onPinnedChanged() { if (screen.pinned) focusScope.forceActiveFocus(); }
        }
    }

    // ---- notificaciones (ADR-29) --------------------------------------

    /**
     * Los popups, solo con el servidor del shell encendido (`Notifs.enabled`,
     * leido al arrancar). Apagado no se crea la ventana.
     */
    LazyLoader {
        active: Notifs.enabled
        NotifLayer { targetScreen: screen.modelData }
    }

    /**
     * La tienda de Wallhaven (antes de la fase 11): sólo en la pantalla dueña. Sigue cargada oculta
     * al cerrarla (conserva la vista); pedirla en otra pantalla la descarga aquí y la carga allí.
     */
    LazyLoader {
        active: WallhavenStore.screen === screen.name && screen.name.length > 0
        WallhavenLayer { targetScreen: screen.modelData }
    }

    /**
     * La UI de inspección de System Monitor (antes de la fase 12): igual que la tienda, sólo en la
     * pantalla dueña y cargada oculta al cerrarla (sin sección instanciada: su Loader se apaga).
     */
    LazyLoader {
        active: MonitorUi.screen === screen.name && screen.name.length > 0
        MonitorLayer { targetScreen: screen.modelData }
    }

    /** La capa Tasks (etapa B del Dashboard): como la del monitor, sólo en la pantalla dueña. */
    LazyLoader {
        active: TasksUi.screen === screen.name && screen.name.length > 0
        TasksLayer { targetScreen: screen.modelData }
    }

    /**
     * 14B: la cuenta regresiva de una prueba de sistema, en TODAS las pantallas (no sólo la dueña:
     * §7 «aparece en todas las pantallas visibles»). Sólo existe mientras hay una prueba viva.
     */
    LazyLoader {
        active: SystemTest.live
        TestCountdown { targetScreen: screen.modelData }
    }

    /** La ventana Login screen (Sumi SDDM, 2026-11-23), sólo en la pantalla dueña. */
    LazyLoader {
        active: LoginUi.screen === screen.name && screen.name.length > 0
        LoginLayer { targetScreen: screen.modelData }
    }

    /** One wide calendar, loaded only on its owning screen. */
    LazyLoader {
        active: CalendarUi.screen === screen.name && screen.name.length > 0
        CalendarLayer { targetScreen: screen.modelData }
    }

    /** La Audio UI (antes de la fase 14): como la del monitor, sólo en la pantalla dueña. */
    LazyLoader {
        active: AudioUi.screen === screen.name && screen.name.length > 0
        AudioLayer { targetScreen: screen.modelData }
    }

    /**
     * Settings UI independiente (2026-11-07): una tarjeta flotante como el monitor; sólo en la pantalla
     * dueña. Pedirla en otra pantalla la descarga aquí y la carga allí con su vista (`SettingsUi.context`).
     */
    LazyLoader {
        active: SettingsUi.screen === screen.name && screen.name.length > 0
        SettingsLayer { targetScreen: screen.modelData }
    }

    /** La ayuda de atajos (2026-10-30): una tarjeta flotante, como Calendar; sólo en la pantalla dueña. */
    LazyLoader {
        active: KeybindsUi.screen === screen.name && screen.name.length > 0
        KeybindsLayer { targetScreen: screen.modelData }
    }
}
