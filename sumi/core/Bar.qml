import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Widgets
import "../theme"
import "../services"
import "../components"
import "../lib/bar-edge.js" as BarEdge

/**
 * LA HOVER BAR PERSISTENTE (fase 8C-1, `futureHoverBarsurface.md`, `new-hoverbar.png`).
 *
 * Una barra por monitor, cuando su preferencia es `presentation: "bar"` (Super+Ctrl+P la
 * alterna en el monitor enfocado). Sustituye al island compacto en esa pantalla: el
 * `Morph` sigue existiendo, pero en reposo mide 0 y las surfaces se despliegan desde
 * DEBAJO de la barra (`core/Screen`). Aquí sólo se pinta y se avisa; abrir, fijar y la
 * vista previa los decide Screen igual que con el island.
 *
 * Distribución «por función» (2026-11-16, encuesta del autor; `tools/bar-layout/README.md`):
 *
 *   IZQUIERDA (hacer)   Settings · Workspaces · [Launcher · Clipboard · Web Hub · Windows]
 *                         · [Wallpaper · Visual profiles · Screen recorder] · [Dashboard · Units · CLI]
 *   CENTRO (tiempo)     multimedia compacta (carátula, título corto, ⏯) · RELOJ + FECHA (centro exacto)
 *                         · CPU/RAM/temperatura
 *   DERECHA (estado)    (grabando: ● 00:42 ⏸ ■) · privacidad · Tray · Keep awake · Notifications · Updates
 *                         · [cápsula: Internet · Bluetooth · Volume · Battery] · Power
 *
 * Los datos también abren: multimedia → Media (alias del Mixer; ⏮⏭ están allí), métricas →
 * System monitor, reloj → Calendar. La CÁPSULA es el acceso al Control Center (clic izquierdo,
 * vista previa y teclado: una sola parada); el clic derecho en cada indicador abre su vista
 * (Wi-Fi, Bluetooth, Mixer, Settings → Battery).
 *
 * MONITORES ESTRECHOS (8C-2; por lado desde el 2026-11-16): sin punto de corte fijo, cada lado pliega lo suyo
 * cuando a él le falta sitio, en el orden de `foldOrder`:
 *
 *   izquierda   título más corto · sin título (carátula + ⏯) · herramientas a «More»
 *   derecha     métricas sin etiquetas · bandeja con dos iconos (el resto en More) · cápsula sólo con glifos
 *   los dos     el reloj sin fecha
 *   y al final  (falte por donde falte) las métricas salen del centro · después la música
 *               · si ni así cabe, el reloj se corre hacia el lado con sitio (`centerShift`)
 *
 * El centro ya no es sólo el reloj: lo que cabe a cada lado se mide contra el reloj MÁS su
 * acompañante de ese lado (multimedia a la izquierda, métricas a la derecha).
 *
 * Siempre quedan el reloj, los workspaces, More, las notificaciones y Power (último). La
 * decisión NO es un binding sobre el ancho de las filas —cambiar el nivel cambia ese ancho:
 * bucle de polish, la memoria del proyecto— sino un temporizador que estima cada nivel con
 * lo medido ahora ± lo que cada paso ahorra, y exige `hysteresis` de aire para volver a un
 * nivel más ancho: un porcentaje o un icono de bandeja no la hacen oscilar.
 *
 * EN CUALQUIER BORDE (2026-11-19, docs/SUMI-BARRA-BORDES-2026-11-19.md; geometría en lib/bar-edge.js): Screen la pone
 * arriba, abajo, a la izquierda o a la derecha, centrada y con su longitud. Los MISMOS accesos se reordenan con
 * `Grid` —una fila o una columna—, nunca girados: en vertical cada acceso es su glifo con el número debajo, el reloj
 * se apila (horas, minutos), la música es carátula y ⏯, las métricas sólo la CPU y la cápsula de estado va en
 * columna. «A lo largo» (`len`, `along*`) es el ancho en horizontal y el alto en vertical; el plegado mide en ese eje.
 * Lo que sale de la barra (More, la tooltip, el menú de la bandeja) se abre hacia dentro (`BarEdge.popup`).
 */
Item {
    id: bar

    property real s: 1
    /** El borde de la pantalla donde está (lo pone Screen, de `monitors[id].barEdge`). */
    property string edge: "top"
    readonly property bool vertical: bar.edge === "left" || bar.edge === "right"
    /** A lo largo del borde y de grosor (en horizontal, ancho y alto). */
    readonly property real len: bar.vertical ? bar.height : bar.width
    readonly property real thick: bar.vertical ? bar.width : bar.height
    /** El eje del borde de un objeto: su largo, su posición y su centro en la ventana. */
    function lenOf(it) { return it ? (bar.vertical ? it.height : it.width) : 0; }
    function implicitLenOf(it) { return it ? (bar.vertical ? it.implicitHeight : it.implicitWidth) : 0; }
    /** Posición a lo largo entre hermanos (los tramos de `bodyBox`). */
    function posOf(it) { return it ? (bar.vertical ? it.y : it.x) : 0; }
    function alongOf(it) {
        const p = it.mapToItem(null, it.width / 2, it.height / 2);
        return bar.vertical ? p.y : p.x;
    }
    /** El centro de la barra a lo largo, en la ventana (el origen cuando no hay acceso). */
    function mid() { return bar.alongOf(bar); }
    /** Grosor de un acceso en vertical (el de la barra menos un margen) y su relleno a lo largo. */
    readonly property real vAccW: Math.max(20 * bar.s, bar.thick - 10 * bar.s)
    /** El reloj de la barra: de ahí sale la cápsula del Lock en modo barra (fase 15F, `Screen.lockOrigin`). */
    readonly property Item clockItem: clock
    property string screenName: ""
    /** Lo que Screen tiene abierto en esta pantalla (para `lit`). */
    property string open: ""
    /** El cursor de teclado del peek (Super+Ctrl+Space) está sobre la barra. */
    property bool navActive: false
    /** La superficie abierta es una vista previa (para cerrar More al fijar otra). */
    property bool preview: false

    /** Cuántos pasos de plegado hay aplicados (0 = completa; `fold`, `foldOrder`). Sólo para la sonda y la lectura. */
    readonly property int level: Object.keys(bar.fold).length
    readonly property real hysteresis: 24 * bar.s
    /** El desplegable More (nivel ≥ 3). Screen lo trata como modal: un clic fuera lo cierra. */
    property bool moreOpen: false
    onMoreShownChanged: if (!bar.moreShown) bar.moreOpen = false
    /**
     * MORE Y LOS PANELES NO CONVIVEN (2026-11-19, captura del autor: la vista previa del grabador, abierta desde una
     * entrada de More, se dibujaba encima del desplegable y los dos se leían uno a través del otro). La regla del menú
     * de la bandeja (core/Screen `dismissTrayMenu`): abrir un panel —también una vista previa— cierra More, y abrir More
     * cierra el panel (`activate("more")`, con su guarda). Con More abierto no hay vista previa, ni de sus entradas ni
     * de la barra: es modal, como con los clics (uno en la barra sólo lo cierra). Si la hubiera, al abrirse cerraría More,
     * la máscara de entrada encogería y la vista previa se cerraría enseguida (medido en tools/bar-more: un parpadeo).
     */
    onOpenChanged: if (bar.open.length > 0) bar.moreOpen = false
    /** Lo que pasa a More en el nivel 3, en su orden y con sus grupos. */
    readonly property var moreGroups: [
        { title: "Search & windows", keys: ["launcher", "clipboard", "emoji", "web", "minimizer"] },
        { title: "Personalization", keys: ["wallpaper", "theme"] },
        { title: "Capture", keys: ["recorder"] },
        { title: "System", keys: Units.supported ? ["dashboard", "services", "cli"] : ["dashboard", "cli"] }
    ]
    readonly property var moreKeys: ["launcher", "clipboard", "emoji", "web", "minimizer", "wallpaper", "theme", "recorder",
                                     "dashboard"].concat(Units.supported ? ["services"] : []).concat(["cli"])
    /** Iconos de bandeja que se quedan en la barra desde el nivel 3. */
    readonly property int trayKeep: 2
    readonly property var glyphs: ({ launcher: "search", clipboard: "clipboard", emoji: "emoji", web: "web", minimizer: "window",
                                     wallpaper: "wallpaper", theme: "palette", recorder: "recorder", dashboard: "info",
                                     services: "server", cli: "terminal" })

    /** Clic o Enter: Screen decide abrir, fijar la vista previa o cerrar. */
    signal requestSurface(string name)
    /** El puntero se quedó `Motion.hoverOpenMs` sobre un acceso. */
    signal previewRequested(string name)
    /** El menú de un icono de la bandeja: (`ax`, `ay`) es el punto del lado interior de la barra frente al icono. */
    signal trayMenuRequested(var menuHandle, real ax, real ay)

    readonly property real barH: Metrics.barH * bar.s
    implicitHeight: bar.barH

    // ---- navegación, tooltip y vista previa -------------------------------------

    /** Accesos en el orden visual; `surface` vacío = no abre nada (no hay vista previa). */
    readonly property var navList: {
        const out = [];
        const add = (k, l, sfc) => out.push({ key: k, label: l, surface: sfc === undefined ? k : sfc });
        // el tramo de la grabación, primero de la derecha (como se ve)
        const addRec = () => {
            if (!bar.recShown) return;
            add("recStatus", ScreenRecorder.active ? "Screen recorder · " + ScreenRecorder.statusText
                                                   : "Screen recorder · " + ScreenRecorder.flashText, "recorder");
            if (!Settings.recBarControls) return;
            if (ScreenRecorder.live) {
                add("recToggle", ScreenRecorder.paused ? "Resume recording" : "Pause recording", "");
                add("recStop", "Stop and save the recording", "");
            } else if (ScreenRecorder.preparing) {
                add("recCancel", "Cancel recording", "");
            } else if (ScreenRecorder.offerCopy) {
                add("recCopy", "Copy the recording", "");
            }
        };
        add("settings", "Settings");
        const moved = bar.toolEntries;
        // izquierda: las herramientas, o More con ellas dentro
        if (bar.foldTools) {
            add("more", bar.moreOpen ? "Close more" : "More", "");
            if (bar.moreOpen) for (let i = 0; i < moved.length; i++) add(moved[i][0], moved[i][1]);
        } else {
            for (let i = 0; i < moved.length; i++) add(moved[i][0], moved[i][1]);
            // sólo la bandeja plegada: More guarda sus iconos
            if (bar.moreShown) add("more", bar.moreOpen ? "Close more" : "More", "");
        }
        // centro: lo que suena, el reloj, las métricas
        if (Media.has) add("media", Media.title.length > 0
            ? (Media.artist.length > 0 ? Media.title + " · " + Media.artist : Media.title) : "Media");
        add("calendar", "Calendar");
        add("system", "System monitor");
        // derecha: el estado
        addRec();
        add("awake", Session.keepAwakeEffective ? "Keep awake: on"
            : Session.keepAwake ? "Keep awake: " + (Session.keepAwakeError || "starting")
            : "Keep awake: off", "");
        if (Notifs.enabled) add("notifications", NotifHistory.unread > 0
            ? NotifHistory.unread + " unread notifications" : "Notifications");
        if (Updates.any) add("updates", Updates.failed ? "Update check failed"
            : Updates.count + " updates" + (Updates.risky ? " · risky" : ""), "");
        add("control", bar.controlLabel, "controlCenter");
        add("power", "Session power");
        return out;
    }
    /**
     * Las herramientas (clave, nombre), en su orden: en la barra o dentro de More. Aparte de `navList` (2026-11-19): las
     * entradas de More toman de aquí su nombre, que no puede depender de si More está abierto (al recogerse animado,
     * `navList` ya no las tenía y enseñaban la clave, «launcher», con el desplegable estrechándose).
     */
    readonly property var toolEntries: [["launcher", "App launcher"], ["clipboard", "Clipboard history"],
        ["emoji", "Emoji and symbols"], ["web", "Web hub"], ["minimizer", "Windows"], ["wallpaper", "Wallpapers"],
        ["theme", "Visual profiles"],
        ["recorder", ScreenRecorder.active ? "Screen recorder · " + ScreenRecorder.statusText : "Screen recorder"],
        ["dashboard", "Dashboard"], ["services", "Systemd units"], ["cli", "System CLI"]]
        .filter(x => x[0] !== "services" || Units.supported)
    function toolLabel(k) {
        const e = bar.toolEntries.find(x => x[0] === k);
        return e ? e[1] : k;
    }
    /** La cápsula de estado en una frase (tooltip con teclado, `Accessible.name`). */
    readonly property string controlLabel: {
        const parts = ["Control center"];
        parts.push(Net.connected ? (Net.kind === "wired" ? "Ethernet" : "Wi-Fi " + Net.ssid) : "Offline");
        if (Bt.present) parts.push(Bt.connectedCount > 0 ? "Bluetooth " + Bt.connectedCount : "Bluetooth");
        parts.push((Audio.muted ? "Muted " : "Volume ") + Math.round(Audio.volume * 100) + "%");
        if (Battery.present) parts.push("Battery " + Battery.percent + "%");
        return parts.join(" · ");
    }
    /** Las vistas que abre cada indicador de la cápsula (clic derecho) nacen bajo la cápsula. */
    readonly property var capsuleSurfaces: ["controlCenter", "wifi", "bluetooth", "mixer"]
    property int navIdx: -1
    readonly property string navKey: (bar.navActive && bar.navIdx >= 0 && bar.navIdx < bar.navList.length)
        ? bar.navList[bar.navIdx].key : ""
    onNavActiveChanged: bar.navIdx = bar.navActive ? 0 : -1

    /** Acceso bajo el ratón. */
    property string hoverKey: ""
    property Item hoverItem: null
    /** 8E: centro (x de la ventana; en vertical, y) del acceso que pidió la última apertura o vista previa. */
    property real originX: 0
    property var itemsByKey: ({})
    /**
     * Las entradas del desplegable More, aparte (2026-11-16): con un solo registro «gana el primero» ganaban ELLAS
     * (los delegados del Repeater se completan antes) y las diez herramientas nacían en el centro de la barra, por
     * clic y por atajo, aunque se vieran en la barra. Medido en el banco de tools/bar-layout (fase C).
     */
    property var moreItemsByKey: ({})
    function originOf(k) {
        const it = bar.itemsByKey[k];
        if (!it || !it.visible) return bar.mid();
        return bar.alongOf(it);
    }

    /**
     * Con atajo o IPC (2026-11-12): el centro (x de la ventana) del acceso que abre la surface `n`;
     * si está dentro de More o no está en la barra, el centro de la barra. Desde el 2026-11-16 las
     * herramientas de la izquierda (`moreKeys`), siempre el centro.
     */
    function originForSurface(n) {
        // 2026-11-16 (pedido del autor, «por comodidad visual»): las herramientas de la izquierda, abiertas con su
        // atajo, nacen en el CENTRO (el clic y el ⏎ de la barra siguen naciendo bajo su icono: pasan por `originX`)
        if (bar.moreKeys.indexOf(Screens.canonical(n)) >= 0) return bar.mid();
        if (bar.capsuleSurfaces.indexOf(n) >= 0) return bar.originOf("control");
        for (let i = 0; i < bar.navList.length; i++) {
            const e = bar.navList[i];
            if (e.key !== n && e.surface !== n) continue;
            if (bar.moreKeys.indexOf(e.key) >= 0 && bar.foldTools) break;
            return bar.originOf(e.key);
        }
        return bar.mid();
    }

    function entryOf(k) {
        for (let i = 0; i < bar.navList.length; i++)
            if (bar.navList[i].key === k) return bar.navList[i];
        return null;
    }

    function activate(k) {
        if (k === "more") {
            // abrirlo cierra lo que hubiera abierto en esta pantalla (si su guarda lo deja: si no, More no se abre)
            if (!bar.moreOpen && bar.open.length > 0) {
                const sc = Screens.resolve(bar.screenName);
                if (sc && !sc.closeSurface()) return;
            }
            bar.moreOpen = !bar.moreOpen;
            return;
        }
        // desde More, el origen es More (las entradas del desplegable no están en la barra)
        bar.originX = bar.originOf(bar.moreKeys.indexOf(k) >= 0 && bar.foldTools ? "more" : k);
        if (bar.moreKeys.indexOf(k) >= 0) bar.moreOpen = false;
        if (k === "awake") { Session.toggleKeepAwake(); return; }
        if (k === "updates") { Updates.update(); return; }
        if (k === "mediaToggle") { Media.toggle(); return; }
        if (k === "recToggle") { ScreenRecorder.togglePause(); return; }
        if (k === "recStop") { ScreenRecorder.stop(); return; }
        if (k === "recCancel") { ScreenRecorder.cancel(); return; }
        if (k === "recCopy") { ScreenRecorder.copyLast(); return; }
        const e = bar.entryOf(k);
        bar.requestSurface(e && e.surface.length > 0 ? e.surface : k);
    }

    /**
     * Clic derecho en un indicador de la cápsula: su propia vista, nacida bajo ese indicador
     * (`piece`: net · bt · vol · bat).
     */
    function openPiece(piece, item) {
        if (item) bar.originX = bar.alongOf(item);
        if (piece === "bat") {
            // por Screen: cierra antes lo que hubiera abierto (como el engranaje)
            const sc = Screens.resolve(bar.screenName);
            if (sc) sc.showSettings("system/power/batteryStatus", null);
            return;
        }
        const n = piece === "net" ? "wifi" : piece === "bt" ? "bluetooth" : piece === "vol" ? "mixer" : "";
        if (n.length > 0) bar.requestSurface(n);
    }

    function keyPressed(event) {
        const n = bar.navList.length;
        if (!bar.navActive || n === 0) return;
        // la lista cambia al abrir More: el cursor se queda en su acceso
        if (bar.navIdx >= n) bar.navIdx = n - 1;
        const k = event.key;
        // en vertical, ↓/↑ además de →/← (la lista va en el orden en que se ve, de arriba abajo)
        if (k === Qt.Key_Right || k === Qt.Key_Tab || (bar.vertical && k === Qt.Key_Down)) {
            bar.navIdx = Math.min(n - 1, bar.navIdx + 1); event.accepted = true;
        } else if (k === Qt.Key_Left || k === Qt.Key_Backtab || (bar.vertical && k === Qt.Key_Up)) {
            bar.navIdx = Math.max(0, bar.navIdx - 1); event.accepted = true;
        } else if (k === Qt.Key_Home) {
            bar.navIdx = 0; event.accepted = true;
        } else if (k === Qt.Key_End) {
            bar.navIdx = n - 1; event.accepted = true;
        } else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) {
            if (bar.navKey.length > 0) bar.activate(bar.navKey);
            event.accepted = true;
        }
        // Escape lo resuelve Screen: primero cierra More, después suelta el peek.
    }

    /** Vista previa (DESIGN §2): la espera empieza al entrar y se cancela al salir. */
    onHoverKeyChanged: {
        const e = bar.entryOf(bar.hoverKey);
        // con More abierto, sin vista previa (sus entradas y la barra se abren con clic)
        if (e && e.surface.length > 0 && Settings.hoverPreview && !bar.moreOpen) previewTimer.restart();
        else previewTimer.stop();
    }
    function cancelPreview() { previewTimer.stop(); }
    Timer {
        id: previewTimer
        interval: Motion.hoverOpenMs
        onTriggered: {
            const e = bar.entryOf(bar.hoverKey);
            if (e && e.surface.length > 0 && !bar.moreOpen) {
                // el acceso bajo el ratón sólo si es el de `hoverKey` (el IPC `barHover` o un
                // cambio rápido pueden dejarlos distintos)
                const hi = bar.hoverItem;
                bar.originX = (hi && hi.key === bar.hoverKey) ? bar.alongOf(hi) : bar.originOf(bar.hoverKey);
                bar.previewRequested(e.surface);
            }
        }
    }

    /**
     * 8G-2: el menú del icono `i` de la bandeja (IPC `trayMenu`, teclado), bajo su icono en la
     * barra; si está agrupado en More, bajo More. Antes salía anclado al island, que con la
     * barra mide 0 bajo el centro.
     */
    /**
     * Borde inferior visible de la barra (y de la ventana): de ahí cuelga el menú de la bandeja,
     * con el mismo hueco que bajo el island (2026-11-12; antes se medía desde el icono más el
     * alto de la barra, y quedaba más lejos que en el island).
     */
    /**
     * 2026-11-19: el punto del lado INTERIOR de la barra frente a `anchor` (en la ventana): arriba, su borde de abajo;
     * abajo, el de arriba; a un lado, el del otro lado. El menú cuelga de ahí hacia dentro (`TrayMenu.openFor`).
     */
    function trayPoint(anchor) {
        const c = anchor.mapToItem(null, anchor.width / 2, anchor.height / 2);
        const o = bar.mapToItem(null, 0, 0);
        switch (bar.edge) {
        case "bottom": return { x: c.x, y: o.y };
        case "left": return { x: o.x + bar.width, y: c.y };
        case "right": return { x: o.x, y: c.y };
        }
        return { x: c.x, y: o.y + bar.height };
    }
    function requestTrayMenu(menu, anchor) {
        const p = bar.trayPoint(anchor);
        bar.trayMenuRequested(menu, p.x, p.y);
    }

    function openTrayMenu(i) {
        const list = Tray.items;
        if (i < 0 || i >= list.length) return false;
        const it = list[i];
        if (!it || !it.hasMenu) return false;
        const icon = trayRep.itemAt(i);
        bar.requestTrayMenu(it.menu, (icon && icon.visible) ? icon : moreBtn);
        return true;
    }

    /** El desplegable More en coordenadas de la ventana (clic fuera, en Screen). */
    function moreRect() {
        const p = moreMenu.mapToItem(null, 0, 0);
        return { x: p.x, y: p.y, width: bar.moreOpen ? moreMenu.width : 0, height: moreMenu.height };
    }

    /** Test (IPC `barState`). */
    function info() {
        const vis = [];
        for (let i = 0; i < bar.navList.length; i++) vis.push(bar.navList[i].key);
        return { h: Math.round(bar.height), w: Math.round(bar.width), keys: vis, navKey: bar.navKey,
                 // 2026-11-19: el borde y lo que mide a lo largo (el mínimo es lo que el contenido no pliega)
                 edge: bar.edge, vertical: bar.vertical, len: Math.round(bar.len), minLen: Math.round(bar.minLen),
                 level: bar.level, fold: Object.keys(bar.fold), shift: bar.centerShift, moreShown: bar.moreShown,
                 moreOpen: bar.moreOpen, moreReveal: Math.round(bar.moreReveal * 100) / 100, fit: bar.fitDump,
                 hoverKey: bar.hoverKey, left: Math.round(bar.lenOf(leftRow)), right: Math.round(bar.lenOf(rightRow)),
                 clockX: Math.round(bar.vertical ? clock.y + clock.height / 2 : clock.x + clock.width / 2),
                 // 2026-11-16: el centro con sus acompañantes y el aire que queda a cada lado (< 0 = solape)
                 centerLeft: Math.round(centerL.visible ? bar.lenOf(centerL) : 0), centerRight: Math.round(centerR.visible ? bar.lenOf(centerR) : 0),
                 gapLeft: Math.round(bar.posOf(centerL.visible ? centerL : clock) - (bar.posOf(leftRow) + bar.lenOf(leftRow))),
                 gapRight: Math.round(bar.posOf(rightRow) - (centerR.visible ? bar.posOf(centerR) + bar.lenOf(centerR)
                                                                            : bar.posOf(clock) + bar.lenOf(clock))),
                 capsule: { x: Math.round(capsule.mapToItem(bar, 0, 0).x), y: Math.round(capsule.mapToItem(bar, 0, 0).y),
                            w: Math.round(capsule.width), h: Math.round(capsule.height),
                            pieces: bar.capsulePieces(), lit: capsule.lit },
                 // fase C (2026-11-16): dónde está cada acceso visible, en coordenadas de la pantalla (puntero del
                 // banco), el origen de la última apertura y la música
                 at: bar.boxes(), originX: Math.round(bar.originX),
                 media: { has: Media.has, playing: Media.playing, title: Media.title },
                 privacy: privacyRow.visible, s: bar.s,
                 // el grabador (2026-10-29): el tramo de la derecha y el tinte del acceso
                 rec: { shown: recSeg.visible, w: Math.round(recSeg.width), x: Math.round(recSeg.mapToItem(bar, 0, 0).x),
                        entryTint: "" + recorderBtn.tint, entryVisible: recorderBtn.visible } };
    }

    // ---- ajuste al ancho (8C-2) ---------------------------------------------------

    // a lo largo del borde (en vertical, alto): lo mismo con otro eje
    readonly property real accW: (bar.vertical ? 26 : 27) * bar.s   // un acceso sólo con glifo (15 + 12; en vertical, 15 + 11)
    readonly property real gapW: 4 * bar.s           // `spacing` de las filas
    readonly property real ruleW: Metrics.hair + 4 * bar.s
    function wOf(it, fallback) { const l = bar.lenOf(it); return l > 0 ? l : fallback; }
    function sumW(items) {
        let t = 0;
        for (let i = 0; i < items.length; i++) t += bar.wOf(items[i], bar.accW) + bar.gapW;
        return t;
    }
    function textW(tm, cap) { return Math.min(tm.advanceWidth, cap); }

    /** Cuánto ocupa el título de la multimedia: corto, o más corto con su paso de plegado. */
    function titleCap(short) { return (short ? 64 : 110) * bar.s; }

    /**
     * PLEGADO POR LADO (2026-11-16, encuesta del autor; antes una sola escalera de niveles 1–4). Cada paso tiene su
     * lado: L (izquierda o lo que acompaña al reloj por la izquierda), R (ídem por la derecha) o B (el reloj: ayuda a
     * los dos). Un lado sólo pliega lo suyo, en este orden, cuando a él le falta sitio; así la izquierda no manda sus
     * herramientas a More porque la derecha esté llena (lo que hacía la escalera: medido en tools/bar-layout, fase E).
     * Los dos últimos vacían el centro; si ni así cabe, el centro se desplaza (`centerShift`).
     */
    readonly property var foldOrder: [
        { k: "titleShort", side: "L" },     // título de la música más corto
        { k: "metricsShort", side: "R" },   // CPU/RAM sin etiquetas
        { k: "titleOff", side: "L" },       // la música, sólo carátula y ⏯
        { k: "tools", side: "L" },          // las herramientas, a More
        { k: "tray", side: "R" },           // la bandeja deja `trayKeep` iconos; el resto, a More
        { k: "capsule", side: "R" },        // la cápsula, sólo glifos
        { k: "date", side: "B" },           // el reloj sin fecha
        // vaciar el centro, con falte por donde falte (la música a la izquierda deja sitio para correr el reloj):
        { k: "metricsOff", side: "B" },     // las métricas salen del centro (siguen en el Dashboard)
        { k: "mediaOff", side: "B" }        // la música sale del centro (sigue en el Mixer y en la cápsula)
    ]
    /** Los pasos aplicados (clave → true). Lo cambia sólo `fit()`. */
    property var fold: ({})
    // en vertical, sin título, métricas cortas y sin fecha siempre (`foldUseless`)
    readonly property bool foldTitleShort: bar.vertical || !!bar.fold.titleShort
    readonly property bool foldMetricsShort: bar.vertical || !!bar.fold.metricsShort
    readonly property bool foldTitleOff: bar.vertical || !!bar.fold.titleOff
    readonly property bool foldTools: !!bar.fold.tools
    readonly property bool foldTray: !!bar.fold.tray
    readonly property bool foldCapsule: !!bar.fold.capsule
    readonly property bool foldDate: bar.vertical || !!bar.fold.date
    readonly property bool foldMetricsOff: !!bar.fold.metricsOff
    readonly property bool foldMediaOff: !!bar.fold.mediaOff
    /** More existe si guarda algo: las herramientas o los iconos de bandeja que no caben. */
    readonly property bool moreShown: bar.foldTools || (bar.foldTray && Tray.items.length > bar.trayKeep)
    /** Último recurso: el reloj y sus acompañantes se corren (px, < 0 = a la izquierda) lo justo para no pisar nada. */
    property real centerShift: 0

    /**
     * Lo que ahorra el paso `k` en cada tramo: [izquierda, derecha, acompañante izq. (con su hueco), acompañante der.,
     * reloj]. Del ancho real de cada pieza si se conoce, o de su texto medido; independiente de qué esté plegado,
     * salvo el orden (un paso de un lado sólo se aplica tras los anteriores de ese lado).
     */
    function saving(k) {
        const s = bar.s;
        const t = (tm) => tm.advanceWidth > 0 ? tm.advanceWidth + 5 * s : 0;
        switch (k) {
        case "titleShort":
            return [0, 0, Media.has ? bar.textW(tmTitle, bar.titleCap(false)) - bar.textW(tmTitle, bar.titleCap(true)) : 0, 0, 0];
        case "titleOff":
            return [0, 0, Media.has ? bar.textW(tmTitle, bar.titleCap(true)) + 5 * s : 0, 0, 0];
        case "metricsShort":
            return [0, 0, 0, tmMetricsFull.advanceWidth - tmMetricsShort.advanceWidth, 0];
        case "tools": {
            // las herramientas y las dos reglas entre sus grupos salen; entra More (si no estaba ya por la bandeja)
            const tools = [launcherBtn, clipboardBtn, emojiBtn, webBtn, minimizerBtn, wallpaperBtn, themeBtn, recorderBtn, dashboardBtn]
                .concat(Units.supported ? [servicesBtn] : []).concat([cliBtn]);
            const more = bar.fold.tray && Tray.items.length > bar.trayKeep ? 0 : bar.accW + bar.gapW;
            return [bar.sumW(tools) + 2 * bar.ruleW - more, 0, 0, 0, 0];
        }
        case "tray": {
            const extra = Math.max(0, Tray.items.length - bar.trayKeep);
            // More entra a la izquierda si las herramientas no lo trajeron ya
            const more = extra > 0 && !bar.fold.tools ? bar.accW + bar.gapW : 0;
            return [-more, extra * (22 * s + bar.gapW), 0, 0, 0];
        }
        case "capsule":
            return [0, t(tmNet) + (Bt.present ? t(tmBt) : 0) + t(tmVol) + (Battery.present ? t(tmBat) : 0), 0, 0, 0];
        case "date":
            return [0, 0, 0, 0, tmDate.advanceWidth + 5 * s];
        case "metricsOff":
            // en vertical, lo que mide el tramo (sólo glifos: no depende del texto) más su hueco con el reloj
            if (bar.vertical) return [0, 0, 0, centerR.implicitHeight + 4 * s, 0];
            // regla + hueco + el acceso con las métricas cortas (glifo, texto, márgenes) + el hueco con el reloj
            return [0, 0, 0, Metrics.hair + 4 * s + 15 * s + 5 * s + tmMetricsShort.advanceWidth + 12 * s + 4 * s, 0];
        case "mediaOff":
            if (bar.vertical) return [0, 0, Media.has ? centerL.implicitHeight + 4 * s : 0, 0, 0];
            // carátula (con márgenes) + ⏯ + hueco + regla + el hueco con el reloj
            return [0, 0, Media.has ? 32 * s + bar.accW + 4 * s + Metrics.hair + 4 * s : 0, 0, 0];
        }
        return [0, 0, 0, 0, 0];
    }
    /** El paso no hace nada con lo que hay (sin música, sin iconos de bandeja de sobra…). */
    function foldUseless(k) {
        // en vertical ya van así siempre (sin título, métricas cortas, cápsula de glifos, sin fecha): no son pasos
        if (bar.vertical && ["titleShort", "titleOff", "metricsShort", "capsule", "date"].indexOf(k) >= 0) return true;
        if (k === "titleShort" || k === "titleOff" || k === "mediaOff") return !Media.has;
        if (k === "tray") return Tray.items.length <= bar.trayKeep;
        return false;
    }

    /** Lo que sobra (≥ 0) o falta (< 0) a cada lado: la mitad de la barra menos medio reloj, su acompañante y la fila. */
    function slacks(v) {
        const half = bar.len / 2 - v[4] / 2 - 16 * bar.s;
        return [half - v[2] - v[0], half - v[3] - v[1]];
    }

    property var fitDump: ({})
    /** paso → ancho de la barra en que quitarlo no cupo: no se vuelve a quitar hasta tener `hysteresis` más. */
    property var downFail: ({})
    property var lastRemoved: []
    function fit() {
        const gap = 4 * bar.s;   // entre el reloj y cada acompañante
        const cur = [bar.implicitLenOf(leftRow), bar.implicitLenOf(rightRow), centerL.visible ? bar.implicitLenOf(centerL) + gap : 0,
                     centerR.visible ? bar.implicitLenOf(centerR) + gap : 0, bar.lenOf(clock)];
        // lo medido, desplegado del todo (estimado): lo de ahora más lo que ahorra cada paso aplicado
        const v = cur.slice();
        for (let i = 0; i < bar.foldOrder.length; i++) {
            const k = bar.foldOrder[i].k;
            if (!bar.fold[k]) continue;
            const sv = bar.saving(k);
            for (let j = 0; j < 5; j++) v[j] += sv[j];
        }
        // el mínimo: todo plegado (el centro, vacío) y el reloj corrido si hace falta: izquierda + reloj + derecha
        const vf = v.slice();
        for (let i = 0; i < bar.foldOrder.length; i++) {
            const k = bar.foldOrder[i].k;
            if (bar.foldUseless(k)) continue;
            const sv = bar.saving(k);
            for (let j = 0; j < 5; j++) vf[j] -= sv[j];
        }
        const ml = Math.ceil(Math.max(0, vf[0]) + Math.max(0, vf[1]) + Math.max(0, vf[2]) + Math.max(0, vf[3])
                             + Math.max(0, vf[4]) + 2 * 16 * bar.s + 8 * bar.s);
        if (Math.abs(ml - bar.minLen) >= 1) bar.minLen = ml;
        // quitar un paso que ya estaba pide `hysteresis` de aire; ponerlo, que falte sitio en su lado
        const next = {};
        let doneL = false, doneR = false;
        for (let i = 0; i < bar.foldOrder.length; i++) {
            const k = bar.foldOrder[i].k, side = bar.foldOrder[i].side;
            if (bar.foldUseless(k)) continue;
            const was = !!bar.fold[k];
            const blocked = was && bar.downFail[k] !== undefined && bar.len <= bar.downFail[k] + bar.hysteresis;
            const thr = was ? bar.hysteresis : 0;
            const sl = bar.slacks(v);
            const needL = !doneL && sl[0] < thr, needR = !doneR && sl[1] < thr;
            const need = side === "L" ? needL : side === "R" ? needR : (needL || needR);
            if (blocked || need) {
                next[k] = true;
                const sv = bar.saving(k);
                for (let j = 0; j < 5; j++) v[j] -= sv[j];
            } else if (side === "L") doneL = true;
            else if (side === "R") doneR = true;
        }
        // un paso que se quitó en la vuelta anterior y vuelve: quitarlo no cupo a este ancho
        for (let i = 0; i < bar.lastRemoved.length; i++)
            if (next[bar.lastRemoved[i]]) {
                const m = Object.assign({}, bar.downFail);
                m[bar.lastRemoved[i]] = bar.len;
                bar.downFail = m;
            }
        const removed = [];
        for (const k in bar.fold) if (bar.fold[k] && !next[k]) removed.push(k);
        bar.lastRemoved = removed;
        // último recurso: hacia el lado con sitio, sólo lo que falta
        const sl = bar.slacks(v);
        let shift = 0;
        if (sl[1] < 0 && sl[0] > 0) shift = -Math.min(-sl[1], sl[0]);
        else if (sl[0] < 0 && sl[1] > 0) shift = Math.min(-sl[0], sl[1]);
        const names = Object.keys(next);
        const same = names.length === Object.keys(bar.fold).filter(k => bar.fold[k]).length && names.every(k => bar.fold[k]);
        bar.fitDump = { fold: names, shift: Math.round(shift), slack: sl.map(Math.round),
                        measured: cur.map(Math.round) };
        if (!same) bar.fold = next;
        if (Math.abs(shift - bar.centerShift) >= 1 || (shift === 0 && bar.centerShift !== 0)) bar.centerShift = Math.round(shift);
    }
    Timer {
        id: fitTimer
        interval: 60
        onTriggered: bar.fit()
    }
    function refit() { if (bar.visible) fitTimer.restart(); }
    onWidthChanged: bar.refit()
    onHeightChanged: bar.refit()
    onVisibleChanged: bar.refit()
    /** Otro eje: lo plegado y sus bloqueos se midieron en el anterior; se empieza desplegada y se vuelve a medir. */
    onVerticalChanged: { bar.fold = ({}); bar.downFail = ({}); bar.lastRemoved = []; bar.centerShift = 0; bar.refit(); }
    Connections { target: leftRow; function onImplicitWidthChanged() { bar.refit(); } function onImplicitHeightChanged() { bar.refit(); } }
    Connections { target: rightRow; function onImplicitWidthChanged() { bar.refit(); } function onImplicitHeightChanged() { bar.refit(); } }
    Connections { target: clock; function onWidthChanged() { bar.refit(); } function onHeightChanged() { bar.refit(); } }
    Connections { target: centerL; function onImplicitWidthChanged() { bar.refit(); } function onImplicitHeightChanged() { bar.refit(); }
                  function onVisibleChanged() { bar.refit(); } }
    Connections { target: centerR; function onImplicitWidthChanged() { bar.refit(); } function onImplicitHeightChanged() { bar.refit(); }
                  function onVisibleChanged() { bar.refit(); } }
    /** Si cambia QUÉ hay (no cuánto mide), los bloqueos de bajada ya no valen. */
    readonly property string contentKey: [bar.edge, Media.has, Tray.items.length, Updates.any, Bt.present, Battery.present,
        Privacy.any, Notifs.enabled, bar.s, bar.recShown, ScreenRecorder.live, ScreenRecorder.preparing,
        ScreenRecorder.offerCopy, Settings.recBarControls, Settings.recTimer].join("|")

    /**
     * La grabación en la barra (2026-10-29): mientras dura —y unos segundos con su resultado— el tramo
     * de estado de la derecha. Es lo que la pieza bajo el island es en la presentación island.
     */
    readonly property bool recShown: (ScreenRecorder.active || ScreenRecorder.flashing) && Settings.recIndicator
    /** Grabador 2.0 (Settings → Behavior): los botones del tramo y el reloj se pueden quitar; el indicador entero, también. */
    readonly property bool recControls: Settings.recBarControls
    readonly property color recRed: Theme.dangerText
    /** Con el foco de teclado en el tramo, el aviso con Copy no se va (lo mismo que el puntero encima). */
    readonly property bool recNavHeld: bar.navKey.indexOf("rec") === 0
    onRecNavHeldChanged: ScreenRecorder.holdFlash("bar-keys", bar.recNavHeld)
    onContentKeyChanged: { bar.downFail = ({}); bar.refit(); }

    /**
     * LO MÁS CORTA QUE PUEDE SER (2026-11-19): lo que queda con TODOS los pasos de plegado aplicados (Settings, los
     * workspaces y More; el reloj sin fecha; Keep awake, las notificaciones, la cápsula de glifos y Power), con el
     * centro vacío y los márgenes de `slacks`, más un poco de aire. Screen no deja que la longitud elegida baje de aquí:
     * por debajo los tramos se solaparían. Lo calcula `fit()` con su mismo modelo, no un enlace: leer el tamaño de los
     * `Grid` desde un enlace fuerza su colocación y cerraba un bucle (medido en el banco).
     */
    property real minLen: 0

    // la multimedia compacta: sólo el título (el artista, en la tooltip y en el Mixer)
    TextMetrics { id: tmTitle; font.family: Typography.ui; font.pixelSize: Typography.label * bar.s; text: Media.title }
    TextMetrics { id: tmBat; font.family: Typography.ui; font.pixelSize: Typography.label * bar.s; font.weight: Typography.wMedium
        text: Battery.percent + "%" }
    TextMetrics { id: tmMetricsFull; font.family: Typography.ui; font.pixelSize: Typography.label * bar.s; font.weight: Typography.wMedium
        text: bar.metricsText(false) }
    TextMetrics { id: tmMetricsShort; font.family: Typography.ui; font.pixelSize: Typography.label * bar.s; font.weight: Typography.wMedium
        text: bar.metricsText(true) }
    TextMetrics { id: tmNet; font.family: Typography.ui; font.pixelSize: Typography.label * bar.s; font.weight: Typography.wMedium; text: Net.badge }
    TextMetrics { id: tmBt; font.family: Typography.ui; font.pixelSize: Typography.label * bar.s; font.weight: Typography.wMedium; text: Bt.badge }
    TextMetrics { id: tmVol; font.family: Typography.ui; font.pixelSize: Typography.label * bar.s; font.weight: Typography.wMedium
        text: Math.round(Audio.volume * 100) + "%" }
    TextMetrics { id: tmDate; font.family: Typography.ui; font.pixelSize: Typography.micro * bar.s; font.weight: Typography.wMedium
        font.capitalization: Font.AllUppercase; font.letterSpacing: Typography.tracking * bar.s; text: Clock.date }

    /** Vertical: sólo la CPU, sin «%» (cabe bajo el glifo); el resto en la tooltip y en System monitor. */
    function cpuText() {
        if (!Sysmon.active || !Number.isFinite(Sysmon.cpuPct)) return "--";
        return String(Math.round(Sysmon.cpuPct));
    }
    /**
     * El reloj apilado (vertical): «23:24» → 23 / 24; «11:24 PM» → 11 / 24 / PM (este en pequeño). Lo que no se
     * reconoce va entero en pequeño: nunca se pierde.
     */
    function clockParts(time) {
        const m = /^\s*(\d{1,2})[:.](\d{2})\s*(.*)$/.exec(String(time));
        if (!m) return [{ t: String(time), small: true }];
        const out = [{ t: m[1], small: false }, { t: m[2], small: false }];
        if (m[3].length > 0) out.push({ t: m[3], small: true });
        return out;
    }

    function metricsText(compact) {
        if (!Sysmon.active) return compact ? "--" : "CPU --  RAM --";
        const cpu = Number.isFinite(Sysmon.cpuPct) ? Math.round(Sysmon.cpuPct) + "%" : "—";
        const mem = Number.isFinite(Sysmon.memPct) ? Math.round(Sysmon.memPct) + "%" : "—";
        const t = Sysmon.cpuTempC > 0 ? "  " + Math.round(Sysmon.cpuTempC) + "°" : "";
        return compact ? cpu + "  " + mem + t
                       : "CPU " + cpu + "  RAM " + mem + t;
    }

    // ---- piezas -------------------------------------------------------------------

    /** Un acceso de la barra: glifo (y texto opcional), realce y clic. */
    component Access: Item {
        id: acc
        property string key: ""
        property string glyph: ""
        property string text: ""
        property bool lit: (bar.open.length > 0
            && Screens.familyOf(bar.open) === Screens.familyOf(bar.entryOf(acc.key) ? bar.entryOf(acc.key).surface : acc.key))
            // Settings UI (2026-11-07): la ventana flotante de esta pantalla enciende el engranaje
            || (acc.key === "settings" && SettingsUi.open && SettingsUi.screen === bar.screenName)
        property color accent: Theme.primary
        /** Color del glifo; transparente = el suyo (`Icon.tint`). */
        property color tint: "transparent"
        default property alias extra: accRow.data
        /** Fondo y filo en reposo (la cápsula de estado); transparentes = los de siempre. */
        property color restBg: "transparent"
        property color restEdge: "transparent"
        property real cornerR: Metrics.r(8) * bar.s
        /** Separación entre las piezas de dentro. */
        property real innerSpacing: 5 * bar.s
        property real padX: 6 * bar.s
        /** En vertical, el relleno arriba y abajo (el ancho es el de la barra: `vAccW`). */
        property real padY: 5.5 * bar.s
        /** x (y en vertical) del acceso en el último clic: la cápsula sabe qué indicador se pulsó. */
        property real pressX: -1
        /** En la barra vertical (las entradas de More siguen en fila: glifo y nombre). */
        readonly property bool vert: bar.vertical && !acc.inMore
        /** El hueco real entre las piezas de dentro, a lo largo (en vertical el `Grid` usa la mitad). */
        readonly property real gapNow: acc.vert ? accRow.rowSpacing : accRow.columnSpacing
        signal secondary()
        signal middle()

        readonly property bool warm: accArea.containsMouse || bar.navKey === acc.key
        // 8E: el registro de accesos por clave, para el origen (el primero gana: la barra
        // se declara antes que el desplegable de More)
        // Reasignando el objeto entero: mutar uno guardado en una propiedad `var` no se conserva
        // (medido: el registro quedaba vacío y todo nacía en el centro)
        /** Una entrada del desplegable More (su propio registro: `moreItemsByKey`). */
        property bool inMore: false
        Component.onCompleted: {
            if (acc.key.length === 0) return;
            if (acc.inMore) {
                if (bar.moreItemsByKey[acc.key]) return;
                const mm = Object.assign({}, bar.moreItemsByKey);
                mm[acc.key] = acc;
                bar.moreItemsByKey = mm;
            } else if (!bar.itemsByKey[acc.key]) {
                const m = Object.assign({}, bar.itemsByKey);
                m[acc.key] = acc;
                bar.itemsByKey = m;
            }
        }
        // sin anclas: lo coloca el `Grid` de su tramo (fila o columna, centrado en el otro eje)
        width: acc.vert ? Math.max(bar.vAccW, accRow.implicitWidth + 4 * bar.s) : accRow.implicitWidth + 2 * acc.padX
        height: acc.vert ? Math.max(26 * bar.s, accRow.implicitHeight + 2 * acc.padY) : 26 * bar.s

        Rectangle {
            anchors.fill: parent
            radius: acc.cornerR
            color: bar.navKey === acc.key ? Theme.selBg : (accArea.containsMouse ? Theme.hoverBg : acc.restBg)
            border.width: (bar.navKey === acc.key || acc.restEdge.a > 0) ? 1 : 0
            border.color: bar.navKey === acc.key ? Theme.selBorder : acc.restEdge
            Behavior on color { ColorAnimation { duration: Motion.fast } }
        }

        /** Glifo y texto: en fila, o (en vertical) el número bajo el glifo. */
        Grid {
            id: accRow
            anchors.centerIn: parent
            // como core/BarLane: `rows: 1` o `columns: 1`, cambiados a la vez (ni 1000 columnas ni un instante 1 × 1)
            rows: 1
            readonly property bool vert: acc.vert
            onVertChanged: accRow.orient()
            Component.onCompleted: accRow.orient()
            function orient() {
                if (accRow.vert) { accRow.rows = -1; accRow.columns = 1; }
                else { accRow.columns = -1; accRow.rows = 1; }
            }
            rowSpacing: acc.vert ? acc.innerSpacing * 0.5 : 0
            columnSpacing: acc.innerSpacing
            horizontalItemAlignment: Grid.AlignHCenter
            verticalItemAlignment: Grid.AlignVCenter
            Icon {
                id: accIcon
                visible: acc.glyph.length > 0
                name: acc.glyph
                size: 15 * bar.s
                color: acc.lit ? acc.accent : (acc.tint.a > 0 ? acc.tint : accIcon.tint)
                opacity: (acc.lit || acc.warm) ? 1 : 0.85
            }
            Text {
                visible: acc.text.length > 0
                text: acc.text
                color: acc.lit ? acc.accent : (acc.warm ? Theme.fg : Theme.fgVariant)
                font.family: Typography.ui
                // en vertical, un punto menos: el número cabe bajo el glifo en el ancho de la barra
                font.pixelSize: (acc.vert ? Typography.caption : Typography.label) * bar.s
                font.weight: Typography.wMedium
                font.features: { "tnum": 1 }
            }
        }

        MouseArea {
            id: accArea
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
            cursorShape: Qt.PointingHandCursor
            onEntered: { bar.hoverKey = acc.key; bar.hoverItem = acc; }
            onExited: if (bar.hoverKey === acc.key) { bar.hoverKey = ""; bar.hoverItem = null; }
            // un clic decide: la espera de la vista previa ya no vale (con la cápsula, a los 450 ms abría el
            // Control Center encima de la vista que pidió el clic derecho y movía su origen)
            onPressed: bar.cancelPreview()
            onClicked: function (mouse) {
                acc.pressX = acc.vert ? mouse.y : mouse.x;
                if (mouse.button === Qt.RightButton) acc.secondary();
                else if (mouse.button === Qt.MiddleButton) acc.middle();
                else bar.activate(acc.key);
            }
        }

        Accessible.role: Accessible.Button
        Accessible.name: bar.entryOf(acc.key) ? bar.entryOf(acc.key).label : acc.key
        Accessible.onPressAction: bar.activate(acc.key)
    }

    /** Separador entre grupos: vertical en la fila, horizontal en la columna. */
    component Rule: Rectangle {
        width: bar.vertical ? 18 * bar.s : Metrics.hair
        height: bar.vertical ? Metrics.hair : 18 * bar.s
        color: Theme.hair
    }

    /**
     * 8E: EL CUERPO que se despliega. Island → barra: la forma se abre desde el ancho de la
     * cápsula, en el centro, hasta la barra entera, y el contenido —que no se mueve de su
     * sitio— aparece cuando ya cabe (`contentVis`). Barra → island: el contenido sale
     * primero y la forma se recoge. `unfold` lo mueve Screen (`shown`); ANIMATIONS
     * «Dynamic Island ↔ Hover Bar persistente».
     */
    // Shared with Screen's panel trajectory; zero before the returning panel overlaps this body.
    property real presentationOpacity: 1
    property bool shown: false
    // Screen comparte la apertura con el recorrido de BarJourney y con el panel acoplado.
    property real unfoldRaw: bar.shown ? 1 : 0
    readonly property real unfold: Math.max(0, Math.min(1, bar.unfoldRaw))
    /** El contenido entra con la segunda mitad del despliegue y sale con la primera del pliegue. */
    readonly property real contentVis: Math.max(0, Math.min(1, (bar.unfold - 0.55) / 0.45))
    /** Ancho de la cápsula de la que nace y a la que vuelve (la del island, la pone Screen). */
    property real capsuleW: Metrics.restW * bar.s
    /**
     * La barra con el dock (2026-10-01, pedido del usuario): la muesca hecha barra — pegada
     * al borde (Screen la sube con `dockLift`), opaca y con las esquinas de arriba tapadas.
     * El mismo relevo vidrio → muesca que el island (`Island.dockLift`).
     */
    property bool dockMode: false
    property real sharedDockLift: -1
    /**
     * Alto de la muesca de la que nace (la pone Screen: `island.restH`). Sólo cuenta con el
     * dock: el cuerpo pasa de ese alto al de la barra mientras se despliega, pegado arriba,
     * para que el primer fotograma sea la muesca misma y no un escalón de 2 px.
     */
    property real capsuleH: bar.height
    /**
     * 2026-10-01: lo que cuelga de la barra sale DE ella — su filo de abajo se interrumpe sobre la
     * forma y sus hombros (`hangX`/`hangW`, en px de la barra; los pone Screen). Sin nada colgando,
     * ancho 0 y el filo entero de siempre.
     */
    property real hangX: 0
    property real hangW: 0
    // el mismo muelle que `Island.dockLift`: barra y muesca suben juntas, fotograma a fotograma
    SpringValue { id: dockSpring; target: bar.dockMode ? 1 : 0; animate: bar.sharedDockLift < 0; epsilon: 0.004 }
    property real dockLiftRaw: dockSpring.value
    readonly property real dockLift: bar.sharedDockLift >= 0 ? bar.sharedDockLift : Math.max(0, Math.min(1, bar.dockLiftRaw))

    /**
     * La muesca: como `Island` §contour hecha muesca, opaca y del tono más hondo. 2026-11-12 (pedido del
     * usuario: «que parezca una extensión continua de la barra»): antes un rectángulo con las esquinas de
     * arriba rectas, un bloque colgado del borde; ahora UN trazado con los faldones de `Metrics.notchFlare*`
     * que lo funden con el borde de la pantalla. Fuera de `bodyBox`, que recorta (los faldones asoman a los
     * lados) y debajo de él (el vidrio se funde por encima, como antes, y el contenido sigue delante). Cada
     * faldón cabe en lo que queda hasta el lateral de la pantalla: con la barra entera son los `topGap` del
     * margen y la curva muere justo en la esquina; recién nacida de la muesca, los mismos del island.
     */
    /** Lo que se despliega, a lo largo y de grosor (en px de la barra), y su distancia al borde de la pantalla. */
    readonly property real bodyLen: bar.capsuleW + (bar.len - bar.capsuleW) * bar.unfold
    readonly property real bodyThick: bar.thick - (bar.thick - bar.capsuleH) * (1 - bar.unfold) * bar.dockLift
    readonly property real bodyOuter: (bar.thick - bar.bodyThick) / 2 * (1 - bar.dockLift)
    /** Dónde empieza el cuerpo a lo largo (`bodyBox.x`, o `y` en vertical). */
    readonly property real bodyAlong: (bar.len - bar.bodyLen) / 2
    /** La pantalla a lo largo y dónde empieza la barra en ella (los faldones de la muesca no se salen). */
    readonly property real screenAlong: bar.parent ? (bar.vertical ? bar.parent.height : bar.parent.width) : bar.len
    readonly property real barAlong: bar.vertical ? bar.y : bar.x

    Shape {
        id: notchShape
        anchors.fill: parent
        visible: bar.dockLift > 0.01 && bar.bodyLen > 1
        // una sola pieza: con opacidad parcial (relevo con un panel) nada se suma
        opacity: bar.presentationOpacity * bar.dockLift
        preferredRendererType: Shape.CurveRenderer
        readonly property real e: bar.dockLift
        // hasta la esquina de la pantalla, a cada lado
        readonly property real roomA: Math.max(0, bar.barAlong + bar.bodyAlong)
        readonly property real roomB: Math.max(0, bar.screenAlong - bar.barAlong - bar.bodyAlong - bar.bodyLen)
        readonly property real fxA: Math.min(Metrics.notchFlareW * bar.s, notchShape.roomA) * notchShape.e
        readonly property real fxB: Math.min(Metrics.notchFlareW * bar.s, notchShape.roomB) * notchShape.e
        readonly property real fy: Math.min(Metrics.notchFlareH * bar.s, bar.bodyThick / 2) * notchShape.e
        /**
         * En el marco canónico (`u` a lo largo, `v` desde el borde de la pantalla: la barra «arriba») y llevado al
         * borde real con `BarEdge.mapper`; arriba es la identidad, el trazado de siempre.
         */
        function outline() {
            const m = BarEdge.mapper(bar.edge, bar.width, bar.height);
            const x0 = bar.bodyAlong, x1 = bar.bodyAlong + bar.bodyLen, T = bar.bodyOuter, B = bar.bodyOuter + bar.bodyThick;
            const r = Math.min(Metrics.notchCorner * bar.s, bar.bodyLen / 2, bar.bodyThick / 2);
            const fa = notchShape.fxA, fb = notchShape.fxB, fy = notchShape.fy, kf = Metrics.notchFlareK, k = 0.5523;
            return "M " + m(x0 - fa, T)
                + " C " + m(x0 - fa + kf * fa, T) + " " + m(x0, T + fy - kf * fy) + " " + m(x0, T + fy)
                + " L " + m(x0, B - r)
                + " C " + m(x0, B - r + k * r) + " " + m(x0 + r - k * r, B) + " " + m(x0 + r, B)
                + " L " + m(x1 - r, B)
                + " C " + m(x1 - r + k * r, B) + " " + m(x1, B - r + k * r) + " " + m(x1, B - r)
                + " L " + m(x1, T + fy)
                + " C " + m(x1, T + fy - kf * fy) + " " + m(x1 + fb - kf * fb, T) + " " + m(x1 + fb, T)
                + " Z";
        }
        ShapePath {
            strokeWidth: -1
            fillColor: Theme.notchBg
            PathSvg { path: notchShape.outline() }
        }
    }

    Item {
        id: bodyBox
        opacity: bar.presentationOpacity
        // a lo largo crece desde la cápsula; de grosor, con la muesca, del alto de ella al de la barra, pegado al borde
        width: bar.vertical ? bar.bodyThick : bar.bodyLen
        height: bar.vertical ? bar.bodyLen : bar.bodyThick
        x: bar.vertical ? (bar.edge === "left" ? bar.bodyOuter : bar.thick - bar.bodyThick - bar.bodyOuter) : bar.bodyAlong
        y: bar.vertical ? bar.bodyAlong : (bar.edge === "bottom" ? bar.thick - bar.bodyThick - bar.bodyOuter : bar.bodyOuter)
        clip: true

        Glass {
            id: barGlass
            anchors.fill: parent
            radius: Metrics.restCorner * bar.s
            s: bar.s
            opacity: 1 - bar.dockLift
            visible: opacity > 0.01
            // con algo colgando, el filo lo pinta `barEdge` con el hueco
            border.width: bar.hangW > 0 ? 0 : 1
            // el velo, desde el borde de la pantalla (2026-11-19): nunca en el lado interior, donde se une el panel
            veilFrom: bar.edge
            /*
             * Sin sombra (2026-10-01, captura del usuario): `bodyBox` recorta (lo necesita el
             * despliegue), así que la sombra quedaba cortada en un rectángulo y se veía como una
             * mancha cuadrada en las puntas redondas, junto al engranaje y a Power. Sin recortar,
             * se transparentaría por lo que cuelga de la barra.
             */
            shadowed: false
        }
        /**
         * El filo con hueco: el mismo marco tres veces, recortado — todo menos las dos filas del lado INTERIOR (abajo
         * con la barra arriba; arriba con ella abajo; el otro costado a un lado), y esas dos filas a cada lado del
         * hueco. El hueco cae en el tramo recto (lo que cuelga nunca llega a las puntas redondas de la barra).
         */
        Item {
            id: barEdge
            anchors.fill: parent
            visible: bar.hangW > 0 && barGlass.visible
            opacity: barGlass.opacity
            // a lo largo, en px del cuerpo
            readonly property real gx: Math.max(0, bar.hangX - bar.bodyAlong)
            readonly property real gw: Math.max(0, Math.min(bar.bodyLen - gx, bar.hangW))
            /** La pieza `i` (0: todo menos la tira interior; 1 y 2: la tira antes y después del hueco). */
            function piece(i) {
                const W = barEdge.width, H = barEdge.height, a = barEdge.gx, b = barEdge.gx + barEdge.gw;
                switch (bar.edge) {
                case "bottom":
                    return i === 0 ? Qt.rect(0, 2, W, H - 2) : i === 1 ? Qt.rect(0, 0, a, 2) : Qt.rect(b, 0, Math.max(0, W - b), 2);
                case "left":
                    return i === 0 ? Qt.rect(0, 0, W - 2, H) : i === 1 ? Qt.rect(W - 2, 0, 2, a) : Qt.rect(W - 2, b, 2, Math.max(0, H - b));
                case "right":
                    return i === 0 ? Qt.rect(2, 0, W - 2, H) : i === 1 ? Qt.rect(0, 0, 2, a) : Qt.rect(0, b, 2, Math.max(0, H - b));
                }
                return i === 0 ? Qt.rect(0, 0, W, H - 2) : i === 1 ? Qt.rect(0, H - 2, a, 2) : Qt.rect(b, H - 2, Math.max(0, W - b), 2);
            }
            component EdgeClip: Item {
                clip: true
                Rectangle {
                    x: -parent.x
                    y: -parent.y
                    width: barEdge.width
                    height: barEdge.height
                    radius: barGlass.radius
                    color: "transparent"
                    border.width: 1
                    border.color: barGlass.edge
                }
            }
            EdgeClip { readonly property rect box: barEdge.piece(0); x: box.x; y: box.y; width: box.width; height: box.height }
            EdgeClip { readonly property rect box: barEdge.piece(1); x: box.x; y: box.y; width: box.width; height: box.height }
            EdgeClip { readonly property rect box: barEdge.piece(2); x: box.x; y: box.y; width: box.width; height: box.height }
        }

        // ---- izquierda (en vertical, arriba) ------------------------------------------
        // Cada tramo se coloca A LO LARGO en su sitio de siempre y se centra en el grosor; en horizontal, las mismas
        // cuentas que antes con `x` (y centrado en `y`, lo que hacía `anchors.verticalCenter`).

        BarLane {
                vertical: bar.vertical
            id: leftRow
            readonly property real along: 8 * bar.s - bar.bodyAlong
            x: bar.vertical ? (bodyBox.width - width) / 2 : along
            y: bar.vertical ? along : (bodyBox.height - height) / 2
            opacity: bar.contentVis
            spacing: 4 * bar.s

            Access { id: settingsBtn; key: "settings"; glyph: "cog" }
            Rule {}
            /** Los puntos de los workspaces; en vertical, la misma fila girada (sólo círculos: nada que leer). */
            Item {
                id: wsBox
                width: bar.vertical ? bar.vAccW : ws.implicitWidth + 12 * bar.s
                height: bar.vertical ? ws.implicitWidth + 12 * bar.s : 26 * bar.s
                Workspaces {
                    id: ws
                    anchors.centerIn: parent
                    rotation: bar.vertical ? 90 : 0
                    screenName: bar.screenName
                    s: bar.s
                    interactive: true
                }
            }
            Rule {}

            // las herramientas, en sus tres grupos: buscar y ventanas │ personalizar y capturar │ sistema
            Access { id: launcherBtn; key: "launcher"; glyph: "search"; visible: !bar.foldTools }
            Access { id: clipboardBtn; key: "clipboard"; glyph: "clipboard"; visible: !bar.foldTools }
            Access { id: emojiBtn; key: "emoji"; glyph: "emoji"; visible: !bar.foldTools }
            Access { id: webBtn; key: "web"; glyph: "web"; visible: !bar.foldTools }
            Access { id: minimizerBtn; key: "minimizer"; glyph: "window"; visible: !bar.foldTools }
            Rule { visible: !bar.foldTools }
            Access { id: wallpaperBtn; key: "wallpaper"; glyph: "wallpaper"; visible: !bar.foldTools }
            Access { id: themeBtn; key: "theme"; glyph: "palette"; visible: !bar.foldTools }
            /** El grabador: hermano de Wallpaper; rojo mientras graba (el estado completo, a la derecha). */
            Access {
                id: recorderBtn
                key: "recorder"
                glyph: "recorder"
                visible: !bar.foldTools
                tint: ScreenRecorder.active ? bar.recRed : "transparent"
            }
            Rule { visible: !bar.foldTools }
            Access { id: dashboardBtn; key: "dashboard"; glyph: "info"; visible: !bar.foldTools }
            Access { id: servicesBtn; key: "services"; glyph: "server"; visible: !bar.foldTools && Units.supported }
            Access { id: cliBtn; key: "cli"; glyph: "terminal"; visible: !bar.foldTools }
            /** More (nivel ≥ 3): las herramientas, con sus grupos, en un desplegable. */
            Access {
                id: moreBtn
                key: "more"
                glyph: "dots"
                visible: bar.moreShown
                lit: bar.moreOpen
            }
        }

        // ---- centro -----------------------------------------------------------------

        /**
         * Lo que suena, a la izquierda del reloj (2026-11-16, «un poco más compacta»): carátula,
         * título corto y ⏯; ⏮⏭ y el artista están en el Mixer. El bloque abre Media. En vertical,
         * encima del reloj: carátula y ⏯, sin título.
         */
        BarLane {
                vertical: bar.vertical
            id: centerL
            readonly property real along: bar.posOf(clock) - 4 * bar.s - bar.lenOf(centerL)
            x: bar.vertical ? (bodyBox.width - width) / 2 : along
            y: bar.vertical ? along : (bodyBox.height - height) / 2
            opacity: bar.contentVis
            visible: Media.has && !bar.foldMediaOff
            spacing: 0

            Access {
                key: "media"
                ClippingRectangle {
                    width: 20 * bar.s
                    height: 20 * bar.s
                    radius: Metrics.r(5) * bar.s
                    color: Theme.tileBg
                    Image {
                        anchors.fill: parent
                        source: Media.artUrl
                        sourceSize.width: 40 * bar.s
                        sourceSize.height: 40 * bar.s
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: false
                    }
                }
                // tope por nivel; el elide, siempre el mismo (uno condicional tumba Qt: CLAUDE.md §7)
                Text {
                    visible: !bar.foldTitleOff
                    width: Math.min(implicitWidth, bar.titleCap(bar.foldTitleShort))
                    elide: Text.ElideRight
                    text: Media.title
                    color: Theme.fg
                    font.family: Typography.ui
                    font.pixelSize: Typography.label * bar.s
                }
            }
            Access { key: "mediaToggle"; glyph: Media.playing ? "pause" : "play" }
            Item { width: bar.vertical ? 1 : 4 * bar.s; height: bar.vertical ? 4 * bar.s : 1 }
            Rule {}
        }

        /**
         * Reloj y fecha en el centro EXACTO; abre Calendar. En vertical, apilado —horas, minutos y, con el formato
         * de 12 horas, AM/PM debajo en pequeño— y sin fecha (está en Calendar y en la tooltip del teclado).
         */
        Access {
            id: clock
            key: "calendar"
            // el centro EXACTO, salvo el último recurso del plegado (`centerShift`)
            readonly property real along: bar.len / 2 - bar.bodyAlong - bar.lenOf(clock) / 2 + bar.centerShift
            x: bar.vertical ? (bodyBox.width - width) / 2 : along
            y: bar.vertical ? along : (bodyBox.height - height) / 2
            opacity: bar.contentVis
            innerSpacing: bar.vertical ? 0 : 5 * bar.s
            readonly property var parts: bar.clockParts(Clock.time)
            Text {
                visible: !bar.vertical
                text: Clock.time
                color: Theme.fg
                font.family: Typography.ui
                font.pixelSize: Typography.restTime * bar.s
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
            }
            Text {
                visible: !bar.foldDate
                text: Clock.date
                color: Theme.fgVariant
                font.family: Typography.ui
                font.pixelSize: Typography.micro * bar.s
                font.weight: Typography.wMedium
                font.capitalization: Font.AllUppercase
                font.letterSpacing: Typography.tracking * bar.s
            }
            Repeater {
                model: bar.vertical ? clock.parts : []
                Text {
                    required property var modelData
                    text: modelData.t
                    color: modelData.small ? Theme.fgVariant : Theme.fg
                    font.family: Typography.ui
                    font.pixelSize: (modelData.small ? Typography.micro : Typography.restTime) * bar.s
                    font.weight: modelData.small ? Typography.wMedium : Font.DemiBold
                    font.capitalization: Font.AllUppercase
                    font.features: { "tnum": 1 }
                }
            }
        }

        /**
         * Métricas básicas (Sysmon «summary», reclamado por Screen), a la derecha del reloj; abren System monitor.
         * En vertical, debajo: el glifo y la CPU (RAM y temperatura, en la tooltip y en el monitor).
         */
        BarLane {
                vertical: bar.vertical
            id: centerR
            readonly property real along: bar.posOf(clock) + bar.lenOf(clock) + 4 * bar.s
            x: bar.vertical ? (bodyBox.width - width) / 2 : along
            y: bar.vertical ? along : (bodyBox.height - height) / 2
            opacity: bar.contentVis
            visible: !bar.foldMetricsOff
            spacing: 0
            Rule {}
            Item { width: bar.vertical ? 1 : 4 * bar.s; height: bar.vertical ? 4 * bar.s : 1 }
            Access {
                key: "system"
                glyph: "gauge"
                text: bar.vertical ? bar.cpuText() : bar.metricsText(bar.foldMetricsShort)
            }
        }

        // ---- derecha (en vertical, abajo) --------------------------------------------

        BarLane {
                vertical: bar.vertical
            id: rightRow
            readonly property real along: bar.len - bar.bodyAlong - 8 * bar.s - bar.lenOf(rightRow)
            x: bar.vertical ? (bodyBox.width - width) / 2 : along
            y: bar.vertical ? along : (bodyBox.height - height) / 2
            opacity: bar.contentVis
            spacing: 4 * bar.s

            /**
             * La grabación: indicador y tiempo (abre el grabador), y pausa/parar —o cancelar mientras se
             * prepara— como glifos compactos. Después, unos segundos, el resultado. Antes que la
             * privacidad: mientras graba la nuestra, su aviso «Screen» es este. En vertical, sólo glifos
             * (el tiempo, en la tooltip y en el grabador).
             */
            BarLane {
                vertical: bar.vertical
                id: recSeg
                visible: bar.recShown
                spacing: 0
                Access {
                    key: "recStatus"
                    glyph: ScreenRecorder.paused ? "pause" : !ScreenRecorder.active
                        ? (ScreenRecorder.flashTone === "ok" ? "check-circle" : ScreenRecorder.flashTone === "info" ? "close" : "alert")
                        : "record"
                    tint: ScreenRecorder.paused ? Theme.warn
                        : !ScreenRecorder.active ? (ScreenRecorder.flashTone === "ok" ? Theme.ok : ScreenRecorder.flashTone === "danger"
                                                    ? Theme.danger : ScreenRecorder.flashTone === "warn" ? Theme.warn : Theme.fgVariant)
                        : ScreenRecorder.status === "recording" ? bar.recRed : Theme.fgVariant
                    text: bar.vertical ? ""
                        : ScreenRecorder.live ? (Settings.recTimer ? ScreenRecorder.clock : ScreenRecorder.paused ? "Paused" : "Recording")
                        : ScreenRecorder.active ? ScreenRecorder.statusText : ScreenRecorder.flashText
                }
                Access {
                    key: "recToggle"
                    visible: ScreenRecorder.live && bar.recControls
                    glyph: ScreenRecorder.paused ? "play" : "pause"
                }
                Access {
                    key: "recStop"
                    visible: ScreenRecorder.live && bar.recControls
                    glyph: "stop"
                    tint: bar.recRed
                }
                Access {
                    key: "recCancel"
                    visible: ScreenRecorder.preparing && bar.recControls
                    glyph: "close"
                }
                /** Recién guardada: copiarla al portapapeles como archivo (segunda entrega). */
                Access {
                    key: "recCopy"
                    visible: ScreenRecorder.offerCopy && bar.recControls
                    glyph: "copy"
                }
                HoverHandler { onHoveredChanged: ScreenRecorder.holdFlash("pointer", hovered) }
            }
            Rule { visible: bar.recShown }

            /**
             * Privacidad con TEXTO: el island sólo tiene puntos, y la especificación pide la
             * explicación «al desplegar la barra». Mismos colores que los puntos. En vertical, los
             * puntos en columna, sin texto (no cabe en el ancho de la barra).
             */
            BarLane {
                vertical: bar.vertical
                id: privacyRow
                spacing: (bar.vertical ? 5 : 8) * bar.s
                visible: (Privacy.screenActive && !(ScreenRecorder.capturing && bar.recShown)) || Privacy.cameraActive || Privacy.micActive
                Repeater {
                    model: [
                        { on: Privacy.screenActive && !(ScreenRecorder.capturing && bar.recShown), c: Theme.privacyScreen, t: "Screen" },
                        { on: Privacy.cameraActive, c: Theme.privacyCamera, t: "Camera" },
                        { on: Privacy.micActive && !Privacy.cameraActive, c: Theme.privacyMic, t: "Mic" }
                    ]
                    Row {
                        required property var modelData
                        visible: modelData.on
                        spacing: 4 * bar.s
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 7 * bar.s; height: width; radius: Metrics.pill(width)
                            color: modelData.c
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: !bar.vertical
                            text: modelData.t
                            color: Theme.fg
                            font.family: Typography.ui
                            font.pixelSize: Typography.caption * bar.s
                        }
                    }
                }
            }

            Rule { visible: privacyRow.visible }

            Repeater {
                id: trayRep
                model: Tray.items
                TrayIcon {
                    required property var modelData
                    required property int index
                    // desde el nivel 3 sólo los primeros; el resto está en More
                    visible: !bar.foldTray || index < bar.trayKeep
                    item: modelData
                    s: bar.s
                    interactive: true
                    onMenuRequested: function (trayItem, anchorItem) {
                        if (!trayItem || !trayItem.hasMenu) return;
                        bar.requestTrayMenu(trayItem.menu, anchorItem);
                    }
                }
            }
            Rule { visible: Tray.items.length > 0 }
            Access {
                id: awakeBtn
                key: "awake"
                glyph: "awake"
                lit: Session.keepAwakeEffective
            }
            Access {
                id: notifBtn
                key: "notifications"
                visible: Notifs.enabled
                glyph: NotifHistory.dnd ? "bell-off" : "bell"
                text: NotifHistory.unread > 0 ? String(NotifHistory.unread) : ""
                onSecondary: NotifHistory.toggleDnd()
            }
            Access {
                key: "updates"
                visible: Updates.any
                glyph: Updates.failed ? "alert" : "update"
                text: Updates.count > 0 ? String(Updates.count) : ""
                tint: (Updates.failed || Updates.risky || Updates.state === "critical") ? Theme.danger : Theme.warn
                onSecondary: Updates.list()
                onMiddle: Updates.recheck()
            }
            Rule {}

            /**
             * LA CÁPSULA DE ESTADO (2026-11-16): red, Bluetooth, volumen y batería en un solo acceso.
             * Clic izquierdo, Enter y la vista previa → Control Center, que nace bajo ella; clic
             * derecho en un indicador → su vista (`bar.openPiece`). En vertical, en columna: los glifos
             * y, bajo el volumen y la batería, su número (las insignias de red y Bluetooth, en la tooltip).
             */
            Access {
                id: capsule
                key: "control"
                restBg: Theme.tileBg
                restEdge: Theme.hair
                cornerR: Metrics.pill(bar.vertical ? capsule.width : 26 * bar.s)
                padX: 9 * bar.s
                padY: 8 * bar.s
                // en vertical el `Grid` reparte la mitad de esto entre glifo y glifo (`accRow.rowSpacing`)
                innerSpacing: (bar.vertical ? 16 : 10) * bar.s
                // también con las vistas de sus indicadores (el Mixer enciende la música: es su alias)
                lit: bar.open.length > 0 && ["controlCenter", "wifi", "bluetooth"]
                    .some(n => Screens.familyOf(n) === Screens.familyOf(bar.open))
                onSecondary: {
                    const p = bar.pieceAt(capsule.pressX);
                    if (p) bar.openPiece(p.piece, p);
                }

                BarLane {
                vertical: bar.vertical
                    id: netPiece
                    readonly property string piece: "net"
                    spacing: (bar.vertical ? 1 : 5) * bar.s
                    Icon {
                        name: Net.icon.length > 0 ? Net.icon : "wifi"
                        size: 15 * bar.s
                        color: !Net.ready ? Theme.fgVariant : (Net.degraded ? Theme.netWarn : (Net.connected ? Theme.fg : Theme.danger))
                        opacity: (capsule.lit || capsule.warm) ? 1 : 0.85
                    }
                    Text {
                        visible: !bar.foldCapsule && !bar.vertical && text.length > 0
                        text: Net.badge
                        color: capsule.lit ? capsule.accent : (capsule.warm ? Theme.fg : Theme.fgVariant)
                        font.family: Typography.ui
                        font.pixelSize: Typography.label * bar.s
                        font.weight: Typography.wMedium
                    }
                }
                BarLane {
                vertical: bar.vertical
                    id: btPiece
                    readonly property string piece: "bt"
                    visible: Bt.present
                    spacing: (bar.vertical ? 1 : 5) * bar.s
                    Icon {
                        name: Bt.icon.length > 0 ? Bt.icon : "bt"
                        size: 15 * bar.s
                        color: Bt.lowBattery ? Theme.danger : (Bt.connectedCount > 0 ? Theme.primary : Theme.fgVariant)
                        opacity: (capsule.lit || capsule.warm) ? 1 : 0.85
                    }
                    Text {
                        visible: !bar.foldCapsule && !bar.vertical && text.length > 0
                        text: Bt.badge
                        color: capsule.lit ? capsule.accent : (capsule.warm ? Theme.fg : Theme.fgVariant)
                        font.family: Typography.ui
                        font.pixelSize: Typography.label * bar.s
                        font.weight: Typography.wMedium
                        font.features: { "tnum": 1 }
                    }
                }
                /** Un Item (no un tramo): la zona de la rueda no entra en el reparto. */
                Item {
                    id: volPiece
                    readonly property string piece: "vol"
                    width: volRow.implicitWidth
                    height: volRow.implicitHeight
                    BarLane {
                vertical: bar.vertical
                        id: volRow
                        spacing: (bar.vertical ? 1 : 5) * bar.s
                        Icon {
                            name: Audio.muted ? "volume-off" : (Audio.volume > 0.66 ? "volume-high" : (Audio.volume > 0.33 ? "volume-mid" : "volume-low"))
                            size: 15 * bar.s
                            color: capsule.lit ? capsule.accent : Theme.fg
                            opacity: (capsule.lit || capsule.warm) ? 1 : 0.85
                        }
                        Text {
                            visible: !bar.foldCapsule
                            // en vertical sin «%»: el número cabe bajo el glifo
                            text: Math.round(Audio.volume * 100) + (bar.vertical ? "" : "%")
                            color: capsule.lit ? capsule.accent : (capsule.warm ? Theme.fg : Theme.fgVariant)
                            font.family: Typography.ui
                            font.pixelSize: (bar.vertical ? Typography.caption : Typography.label) * bar.s
                            font.weight: Typography.wMedium
                            font.features: { "tnum": 1 }
                        }
                    }
                    /**
                     * La rueda sobre el volumen: ±5 % (como el Mixer). Debajo del `accArea` de la cápsula, que
                     * no atiende la rueda y la deja pasar; sin botones ni hover, no le quita nada más. Cubre el
                     * grosor entero de la cápsula y medio hueco a cada lado a lo largo.
                     */
                    MouseArea {
                        objectName: "barVolumeWheel"
                        x: bar.vertical ? (volPiece.width - capsule.width) / 2 : -capsule.gapNow / 2
                        y: bar.vertical ? -capsule.gapNow / 2 : (volPiece.height - capsule.height) / 2
                        width: bar.vertical ? capsule.width : volPiece.width + capsule.gapNow
                        height: bar.vertical ? volPiece.height + capsule.gapNow : capsule.height
                        acceptedButtons: Qt.NoButton
                        onWheel: (w) => {
                            // girar es usar el volumen: la vista previa del Control Center, no
                            bar.cancelPreview();
                            const dy = w.angleDelta.y !== 0 ? w.angleDelta.y : -w.angleDelta.x;
                            if (dy !== 0 && Mixer.defaultSink) Mixer.setVolume(Mixer.defaultSink, Audio.volume + (dy > 0 ? 0.05 : -0.05));
                            w.accepted = true;
                        }
                    }
                }
                BarLane {
                vertical: bar.vertical
                    id: batPiece
                    readonly property string piece: "bat"
                    visible: Battery.present
                    spacing: (bar.vertical ? 1 : 3) * bar.s
                    readonly property color ink: Battery.low ? Theme.danger : (Battery.externalPower ? Theme.primary : Theme.fgVariant)
                    Icon {
                        name: bar.batteryGlyph
                        size: 15 * bar.s
                        color: batPiece.ink
                        opacity: (capsule.lit || capsule.warm) ? 1 : 0.85
                    }
                    Text {
                        // el nombre que buscan los bancos (tools/laptop): texto y color del porcentaje
                        objectName: "batteryIndicator"
                        visible: !bar.foldCapsule
                        text: Battery.percent + (bar.vertical ? "" : "%")
                        color: batPiece.ink
                        font.family: Typography.ui
                        font.pixelSize: (bar.vertical ? Typography.caption : Typography.label) * bar.s
                        font.weight: Typography.wStrong
                        font.features: { "tnum": 1 }
                        Accessible.name: Battery.description
                    }
                }
            }
            Access { id: powerBtn; key: "power"; glyph: "power" }
        }
    }

    /** El glifo de la batería, como el del Control Center: por décimas, cargando y baja. */
    readonly property string batteryGlyph: {
        if (Battery.low && !Battery.charging) return "battery-alert";
        const tenth = Battery.percent < 5 ? 0 : Math.min(100, Math.round(Battery.percent / 10) * 10);
        return (Battery.charging ? "battery-charging-" : "battery-") + tenth;
    }

    /** Cajas globales (x, y, ancho, alto) de los accesos visibles y de las piezas de la cápsula (`barState.at`). */
    function boxes() {
        const out = {};
        const box = (it) => {
            const g = it.mapToGlobal(0, 0);
            return { x: Math.round(g.x), y: Math.round(g.y), w: Math.round(it.width), h: Math.round(it.height) };
        };
        const keys = Object.keys(bar.itemsByKey);
        for (let i = 0; i < keys.length; i++) {
            const it = bar.itemsByKey[keys[i]];
            if (it && it.visible && it.width > 0) {
                // visible también exige a los padres (More cerrado, `centerL` sin música)
                let shown = true;
                for (let q = it.parent; q && q !== bar; q = q.parent) if (!q.visible) { shown = false; break; }
                if (shown) out[keys[i]] = box(it);
            }
        }
        const ps = bar.capsuleItems();
        for (let i = 0; i < ps.length; i++) out["piece:" + ps[i].piece] = box(ps[i]);
        if (moreMenu.visible) {
            out.moreMenu = box(moreMenu);
            const mk = Object.keys(bar.moreItemsByKey);
            for (let i = 0; i < mk.length; i++) {
                const it = bar.moreItemsByKey[mk[i]];
                if (it && it.visible && it.width > 0) out["more:" + mk[i]] = box(it);
            }
        }
        return out;
    }

    /** Los indicadores visibles de la cápsula, de izquierda a derecha (también para `barState`). */
    function capsuleItems() { return [netPiece, btPiece, volPiece, batPiece].filter(p => p.visible); }
    function capsulePieces() {
        return bar.capsuleItems().map(p => {
            const q = p.mapToItem(capsule, 0, 0);
            return { piece: p.piece, x: Math.round(q.x), y: Math.round(q.y), w: Math.round(p.width), h: Math.round(p.height) };
        });
    }
    /**
     * El indicador bajo `x` (del acceso; en vertical, `y`): el hueco entre dos se reparte a medias; fuera, el más
     * cercano.
     */
    function pieceAt(x) {
        const list = bar.capsuleItems();
        if (list.length === 0) return null;
        const half = capsule.gapNow / 2;
        for (let i = 0; i < list.length; i++) {
            const q = list[i].mapToItem(capsule, 0, 0);
            if (x < (bar.vertical ? q.y : q.x) + bar.lenOf(list[i]) + half) return list[i];
        }
        return list[list.length - 1];
    }

    // ---- More (8C-2) --------------------------------------------------------------

    /**
     * El desplegable de More: los tres grupos con su título, en el orden de la barra, y los
     * iconos de bandeja que no caben. Cuelga del acceso More. Sus entradas son accesos como
     * los de la barra: la misma espera de vista previa, clic y teclado (al abrirlo, sus
     * entradas entran en `navList` detrás de More).
     */
    /**
     * MORE NACE DE SU BOTÓN (2026-11-19, pedido del autor: «que la pestaña More sea animable»), como el menú de la
     * bandeja (components/TrayMenu): un muelle firme lleva `moreReveal` de 0 a 1 y el desplegable crece desde el punto
     * frente a More —hacia dentro más (0,3) que a lo largo (`fromScale`)— con el contenido entrando un poco después; al
     * cerrar se recoge igual y sólo entonces se oculta. Escala, no tamaño: su geometría (`barState.at.moreMenu`) no
     * cambia. Reduced: casi sólo fundido. Off: instantáneo (el muelle salta).
     */
    SpringValue {
        id: moreSpring
        target: bar.moreOpen && bar.moreShown ? 1 : 0
        critical: true
        epsilon: 0.004
    }
    readonly property real moreReveal: Math.max(0, Math.min(1, moreSpring.value))

    Glass {
        id: moreMenu
        s: bar.s
        visible: bar.moreShown && (bar.moreOpen || bar.moreReveal > 0.004)
        // mientras se recoge no atiende (el puntero ya no lo ve como abierto)
        enabled: bar.moreOpen
        radius: Metrics.r(12) * bar.s
        width: moreCol.implicitWidth + 20 * bar.s
        height: moreCol.implicitHeight + 16 * bar.s
        // hacia dentro de la pantalla, a 6 px del lado interior; a lo largo, desde More sin salirse de la barra
        readonly property point at: bar.popupAt(moreBtn, moreMenu.width, moreMenu.height, true)
        x: moreMenu.at.x
        y: moreMenu.at.y
        opacity: Math.min(1, bar.moreReveal * 1.8)
        readonly property real fromScale: Motion.still ? 0.94 : 0.55
        readonly property real deep: Motion.still ? moreMenu.fromScale : 0.3
        /** El punto frente a More, en px del desplegable: el lado que mira a la barra, a la altura del botón. */
        readonly property point seed: {
            const g = 6 * bar.s;
            const c = moreBtn.mapToItem(bar, moreBtn.width / 2, moreBtn.height / 2);
            const ax = Math.max(0, Math.min(moreMenu.width, c.x - moreMenu.x));
            const ay = Math.max(0, Math.min(moreMenu.height, c.y - moreMenu.y));
            switch (bar.edge) {
            case "bottom": return Qt.point(ax, moreMenu.height + g);
            case "left": return Qt.point(-g, ay);
            case "right": return Qt.point(moreMenu.width + g, ay);
            }
            return Qt.point(ax, -g);
        }
        transform: Scale {
            origin.x: moreMenu.seed.x
            origin.y: moreMenu.seed.y
            xScale: bar.vertical ? moreMenu.deep + (1 - moreMenu.deep) * bar.moreReveal
                                 : moreMenu.fromScale + (1 - moreMenu.fromScale) * bar.moreReveal
            yScale: bar.vertical ? moreMenu.fromScale + (1 - moreMenu.fromScale) * bar.moreReveal
                                 : moreMenu.deep + (1 - moreMenu.deep) * bar.moreReveal
        }

        Column {
            id: moreCol
            anchors.centerIn: parent
            spacing: 8 * bar.s
            // el contenido, un poco después que la forma
            opacity: Math.max(0, Math.min(1, (bar.moreReveal - 0.35) / 0.65))

            Repeater {
                model: bar.moreGroups
                Column {
                    required property var modelData
                    // las herramientas, sólo si están plegadas (con sólo la bandeja, More guarda sólo sus iconos);
                    // el modelo no cambia: sus accesos siguen registrados en `moreItemsByKey`
                    visible: bar.foldTools
                    spacing: 2 * bar.s
                    Text {
                        text: modelData.title
                        color: Theme.fgVariant
                        font.family: Typography.ui
                        font.pixelSize: Typography.micro * bar.s
                        font.capitalization: Font.AllUppercase
                        font.letterSpacing: Typography.tracking * bar.s
                    }
                    Repeater {
                        model: modelData.keys
                        Access {
                            required property var modelData
                            anchors.verticalCenter: undefined
                            inMore: true
                            key: modelData
                            glyph: bar.glyphs[modelData] || ""
                            text: bar.toolLabel(modelData)
                        }
                    }
                }
            }

            Column {
                visible: bar.foldTray && Tray.items.length > bar.trayKeep
                spacing: 4 * bar.s
                Text {
                    text: "Tray"
                    color: Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.micro * bar.s
                    font.capitalization: Font.AllUppercase
                    font.letterSpacing: Typography.tracking * bar.s
                }
                Row {
                    spacing: 6 * bar.s
                    Repeater {
                        model: Tray.items
                        TrayIcon {
                            required property var modelData
                            required property int index
                            visible: index >= bar.trayKeep
                            item: modelData
                            s: bar.s
                            interactive: bar.moreOpen
                            onMenuRequested: function (trayItem, anchorItem) {
                                if (!trayItem || !trayItem.hasMenu) return;
                                bar.moreOpen = false;
                                // More se cierra: el menú cuelga de la barra, como los de la fila, frente a More
                                bar.requestTrayMenu(trayItem.menu, moreBtn);
                            }
                        }
                    }
                }
            }
        }
    }

    // ---- tooltip ------------------------------------------------------------------

    /**
     * Dónde va algo de w × h que sale de la barra (More, la tooltip), en px de la barra: a 6 px de su lado INTERIOR
     * y, a lo largo, centrado en `it` (o empezando en él, `fromStart`, como More), sin salirse de la barra. Arriba,
     * lo de siempre: debajo, con x entre 0 y el ancho de la barra.
     */
    function popupAt(it, w, h, fromStart) {
        const gap = 6 * bar.s;
        const L = bar.vertical ? h : w;
        let c = bar.len / 2;
        if (it) {
            const q = it.mapToItem(bar, 0, 0);
            const p0 = bar.vertical ? q.y : q.x;
            c = fromStart ? p0 + L / 2 : p0 + bar.lenOf(it) / 2;
        }
        const inner = bar.edge === "bottom" ? 0 : bar.edge === "left" ? bar.width : bar.edge === "right" ? 0 : bar.height;
        const r = BarEdge.popup(bar.edge, inner, c, w, h, gap, 0, bar.len);
        return Qt.point(r.x, r.y);
    }

    /** Para el IPC (`barState.tip`): qué diría la tooltip y si se ve. */
    function tipInfo() { return { label: tip.label, visible: tip.visible }; }

    Glass {
        id: tip
        s: bar.s
        // bajo el acceso del que habla (con teclado, el del cursor)
        readonly property Item target: {
            const k = bar.navKey.length > 0 ? bar.navKey : bar.hoverKey;
            if (bar.hoverItem && bar.hoverItem.key === k) return bar.hoverItem;
            const mi = bar.moreOpen ? bar.moreItemsByKey[k] : null;
            if (mi && mi.visible) return mi;
            const it = bar.itemsByKey[k];
            return it && it.visible ? it : null;
        }
        readonly property string label: {
            const k = bar.navKey.length > 0 ? bar.navKey : bar.hoverKey;
            const e = bar.entryOf(k);
            if (!e) return "";
            // Complementario de la vista previa (como en el island): con «Open on hover», el
            // ratón sobre un acceso que abre una surface no lleva tooltip. Antes salía a los
            // 400 ms y la vista previa lo tapaba a los 450: un destello. Teclado y accesos sin
            // surface (More, Keep awake, Updates) lo conservan.
            if (bar.navKey.length === 0 && Settings.hoverPreview && e.surface.length > 0) return "";
            return e.label;
        }
        // con More abierto su tooltip taparía el primer grupo del desplegable
        visible: tip.label.length > 0 && tipDelay.done
            && !(bar.moreOpen && (bar.hoverKey === "more" || bar.navKey === "more"))
        width: tipText.implicitWidth + 16 * bar.s
        height: tipText.implicitHeight + 8 * bar.s
        radius: Metrics.r(8) * bar.s
        // del lado interior, centrada en el acceso del que habla
        readonly property point at: bar.popupAt(tip.target, tip.width, tip.height, false)
        x: tip.at.x
        y: tip.at.y
        Text {
            id: tipText
            anchors.centerIn: parent
            text: tip.label
            color: Theme.fg
            font.family: Typography.ui
            font.pixelSize: Typography.caption * bar.s
        }
        onLabelChanged: tipDelay.restart()
        Timer {
            id: tipDelay
            property bool done: false
            interval: 400
            onRunningChanged: if (running) done = false
            onTriggered: done = true
        }
    }
}
