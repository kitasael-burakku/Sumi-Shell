pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../services"
import "../surfaces"
import "../components"

/**
 * Hosts the morphing surfaces. One inactive Loader per registered surface;
 * a surface is built the first time it opens (from a handler, never inside a
 * binding) and dropped again after it has stayed closed for its idle tier.
 *
 * Adding a surface: one entry in `registry` + one Loader below. The entry
 * gives the loader and the target size the island should morph to once the
 * surface item exists. `revision` bumps whenever a loader loads, so size
 * bindings that saw "not built yet" re-evaluate in the same event-loop turn.
 */
Item {
    id: host

    /**
     * Recorta a la capsula. El cinturon del relevo escalonado: el contenido de
     * una superficie tiene su propio ancho (un `Row` con `implicitWidth` no se
     * comprime cuando el padre encoge), asi que mientras el island vuelve a
     * reposo el texto se salia por los lados. Con `vanish` ya no da tiempo a
     * verse, pero un recorte cuesta un scissor rectangular y cierra el caso.
     *
     * Desde el 2026-10-28 el recorte es ademas la mitad del cajon: cada superficie
     * mide lo suyo (`frameFor`) y la forma la descubre al crecer.
     *
     * Va aqui y no en `Morph`: el cuerpo con su sombra (`layer.effect`) y las
     * caras rest/hover son HERMANOS de este Item, no hijos, asi que la sombra
     * sigue pudiendo dibujarse fuera. Las esquinas redondeadas no importan: el
     * contenido vive con margenes (`mLeft` 18, `mTop` 14) y nunca las alcanza.
     */
    clip: true

    property real s: 1
    property string open: ""
    property real closeness: 1
    /** Vista previa por hover (fase 4C): la superficie abierta aún no está fijada. */
    property bool preview: false
    /**
     * El cajón de la barra (2026-11-19, core/Island `drawerPhase`): abriendo desde el reposo o volviendo a él, el
     * contenido viaja ya visible (Surface sin fundido). `farEdge`, el lado de la barra: la superficie se pega al
     * borde OPUESTO (el lejano) mientras la forma es más corta que ella; sin barra o con Grow, «top» (lo de siempre).
     */
    property bool drawer: false
    property string farEdge: "top"
    property string entryEdge: "top"
    /** La forma descubre el contenido desde su primer borde; mantiene el orden de lectura. */
    property bool anchorContent: false
    /** Desplazamiento a lo largo del borde para descubrir el panel en su sitio mientras la gota se centra. */
    property real contentOffset: 0
    /**
     * Estilos de forma (2026-11-21, ADR-40; core/Island `styleContent`): la opacidad que pide el estilo para el contenido
     * mientras corre su línea de tiempo (Bloom no se ve dentro de la cápsula, Mist entra con el enfoque…). −1 = nada: el
     * relevo de siempre (y, con el cajón, visible).
     */
    property real styleReveal: -1
    property int revision: 0
    /** Se pasa a cada superficie para componer sus claves de reclamacion (QS-FUNC-003). */
    property string screenName: ""

    /**
     * Seleccion de las fichas, POR PANTALLA (2026-09-22). Antes vivia en los
     * singletons (`Net.detailObj`, `Units.detailUnit`, `Bt.detailObj`) y las dos
     * pantallas compartian una sola: abrir una ficha en A cambiaba SIN AVISO lo
     * que pintaba B. Medido con una salida headless: la ficha de servicio de B
     * pasaba de `sumi-shell` a `hypridle` con sus Start/Stop vivos, y la de
     * wifi de una red conectada a otra ajena con su boton de conectar. Los
     * SERVICIOS siguen siendo globales y trabajan por clave (que es como ya
     * estaban: `Net.phaseSsid === root.ssid`); lo que baja aqui es *cual* mira
     * esta pantalla.
     *
     * Se reasigna el objeto entero, nunca una clave suelta: en QML escribir
     * dentro de un `var` no notifica a quien lo lee.
     */
    property var sel: ({})
    function selOf(name) {
        const v = host.sel[name];
        return v === undefined ? "" : v;
    }
    function select(name, key) {
        const next = ({});
        for (const k in host.sel)
            next[k] = host.sel[k];
        next[name] = (key === undefined || key === null) ? "" : String(key);
        host.sel = next;
    }

    signal requestClose()
    /**
     * Saltar de una superficie a otra (9.f.2b). Lo pide la superficie de wifi
     * para abrir el detalle de una red. No choca con BUG-S1/S3, que son otra
     * cosa: alli lo inalcanzable son los botones de la cara hover mientras hay
     * una superficie abierta. Aqui el salto lo dispara una fila de la propia
     * superficie, que si esta viva.
     */
    signal requestSurface(string name)
    /**
     * Igual que `requestSurface`, pero la fila que lo dispara dice ADEMAS que
     * mirar: la lista de wifi pasa el ssid, la de servicios la unidad. Va a la
     * seleccion de ESTA pantalla, no a un singleton (ver `sel`).
     */
    signal requestDetail(string name, string key)

    readonly property var registry: ({
        dashboard: {
            loader: () => ldDashboard,
            size: (it) => Qt.size(Metrics.dashboardW * host.s, Metrics.dashboardH * host.s)
        },
        wallpaper: {
            loader: () => ldWallpaper,
            // W4: Wallhaven salió a su tienda; la tira vuelve a su alto de la 10B
            // + el renglón de más del pie de teclado cuando no cabe en uno (2026-11-18)
            size: (it) => Qt.size(Metrics.wallpaperW * host.s, Metrics.wallpaperH * host.s + (it ? it.footerExtra || 0 : 0))
        },
        /** El grabador crece con su aviso para conservar el sitio de las tarjetas. */
        recorder: {
            loader: () => ldRecorder,
            inPlace: true,
            size: (it) => Qt.size(Metrics.recorderW * host.s,
                Math.max(Metrics.recorderH * host.s, it ? it.implicitHeight : 0))
        },
        /*
         * Paneles que se adaptan a lo que muestran (2026-11-17, pedido del autor): el alto sale de los DATOS
         * (`fitH`, filas de alto fijo) con el de siempre como tope, nunca del maquetado de su lista (la lección de
         * 9.f.2). `inPlace`: con el panel ya abierto crece pegado arriba (ver `frameFor`).
         */
        launcher: {
            loader: () => ldLauncher,
            inPlace: true,
            size: (it) => Qt.size(Metrics.launcherW * host.s, Math.min(Metrics.launcherH * host.s, it.fitH))
        },
        /*
         * Settings (fase 9A) vivía aquí: tres nombres —Shell, Theme y System— con un solo marco.
         * Desde el 2026-11-07 es una ventana flotante propia (`core/SettingsLayer`, `SettingsUi`):
         * los tres nombres los atiende `Screen.openSurface` antes de llegar al island.
         */
        system: {
            loader: () => ldSystem,
            size: (it) => Qt.size(Metrics.systemW * host.s, Metrics.systemH * host.s)
        },
        controlCenter: {
            loader: () => ldControlCenter,
            inPlace: true,
            size: (it) => Qt.size(ldControlCenter.width, it.implicitHeight + (it.mTop + it.mBottom) * host.s)
        },
        calendar: {
            loader: () => ldCalendar,
            inPlace: true,
            size: (it) => Qt.size(Metrics.calendarW * host.s, it.implicitHeight + 26 * host.s)
        },
        mixer: {
            loader: () => ldMixer,
            inPlace: true,
            size: (it) => Qt.size(Metrics.mixerW * host.s, it.implicitHeight + (it.mTop + it.mBottom) * host.s)
        },
        wifi: {
            loader: () => ldWifi,
            size: (it) => Qt.size(Metrics.wifiW * host.s, Metrics.wifiH * host.s)
        },
        web: {
            loader: () => ldWeb,
            inPlace: true,
            size: (it) => Qt.size(Metrics.webW * host.s, Math.min(Metrics.webH * host.s, it.fitH))
        },
        power: {
            loader: () => ldPower,
            inPlace: true,
            // `targetW` lo declara la superficie segun su pagina: dos anchos
            // constantes entre los que el morph anima, en vez de un ancho
            // medido del contenido (que fue el destino movil de 9.f.2).
            size: (it) => Qt.size(it.targetW, it.implicitHeight + 24 * host.s)
        },
        clipboard: {
            loader: () => ldClipboard,
            inPlace: true,
            size: (it) => Qt.size(Metrics.clipW * host.s, Math.min(Metrics.clipH * host.s, it.fitH))
        },
        // Selector de emojis (2026-11-17): tamaño fijo, la rejilla se desplaza dentro
        emoji: {
            loader: () => ldEmoji,
            size: (it) => Qt.size(Metrics.emojiW * host.s, Metrics.emojiH * host.s)
        },
        minimizer: {
            loader: () => ldMinimizer,
            inPlace: true,
            size: (it) => Qt.size(Metrics.minimizerW * host.s, Math.min(Metrics.minimizerH * host.s, it.fitH))
        },
        services: {
            loader: () => ldServices,
            size: (it) => Qt.size(Metrics.servicesW * host.s, Metrics.servicesH * host.s)
        },
        serviceDetail: {
            loader: () => ldServiceDetail,
            inPlace: true,
            // Altura dirigida por el contenido contra un ancho constante, como
            // `wifiDetail`: crece si aparece un aviso, encoge al irse.
            size: (it) => Qt.size(Metrics.serviceDetailW * host.s, it.implicitHeight + 24 * host.s)
        },
        serviceJournal: {
            loader: () => ldServiceJournal,
            size: (it) => Qt.size(Metrics.serviceJournalW * host.s, Metrics.serviceJournalH * host.s)
        },
        theme: {
            loader: () => ldThemePicker,
            size: (it) => Qt.size(Metrics.themeW * host.s, Metrics.themeH * host.s + (it ? it.statusExtra || 0 : 0))
        },
        cli: {
            loader: () => ldCommandPalette,
            inPlace: true,
            size: (it) => Qt.size(Metrics.cliW * host.s, Math.min(Metrics.cliH * host.s, it.fitH))
        },
        wired: {
            loader: () => ldWired,
            inPlace: true,
            // Altura por contenido, como la ficha de wifi: crece con el aviso
            // del cable desenchufado o el de la confirmacion.
            size: (it) => Qt.size(Metrics.wiredW * host.s, it.implicitHeight + (it.mTop + it.mBottom) * host.s)
        },
        speedtest: {
            loader: () => ldSpeedTest,
            inPlace: true,
            // Alto por contenido con el hueco del aviso reservado: no se mueve durante la prueba (como `wired`).
            size: (it) => Qt.size(Metrics.speedtestW * host.s, it.implicitHeight + (it.mTop + it.mBottom) * host.s)
        },
        wifiDetail: {
            loader: () => ldWifiDetail,
            inPlace: true,
            // Constant target width; the detail stacks its columns on a narrow screen.
            size: (it) => Qt.size(Metrics.radioDetailW * host.s, it.implicitHeight + 24 * host.s)
        },
        bluetooth: {
            loader: () => ldBluetooth,
            size: (it) => Qt.size(Metrics.btW * host.s, Metrics.btH * host.s)
        },
        auth: {
            loader: () => ldAuth,
            inPlace: true,
            // Altura por contenido (mensaje de polkit de largo variable, aviso de error).
            size: (it) => Qt.size(Metrics.authW * host.s, it.implicitHeight + 26 * host.s)
        },
        notifications: {
            loader: () => ldNotifications,
            // Altura fija con avisos: la lista crece en vivo y un destino que sale del maquetado bajo el morph es lo
            // que congeló el shell en 9.f.2. Vacía (2026-11-17), compacta: `fitH` decide entre las dos, por datos.
            inPlace: true,
            size: (it) => Qt.size(Metrics.notifCenterW * host.s, Math.min(Metrics.notifCenterH * host.s, it.fitH))
        },
        btDetail: {
            loader: () => ldBtDetail,
            inPlace: true,
            // Igual que `wifiDetail`: la ficha crece cuando aparece un aviso o
            // una accion mas, medida contra un ancho constante.
            size: (it) => Qt.size(Metrics.radioDetailW * host.s, it.implicitHeight + 24 * host.s)
        }
    })

    function has(name) { return name.length > 0 && host.registry[name] !== undefined; }
    function names() { return Object.keys(host.registry); }

    function item(name) {
        if (!host.has(name))
            return null;
        return host.registry[name].loader().item;
    }

    /** Target size for `name`, or null while its item is not built yet. */
    /**
     * Alto máximo de un panel en ESTA pantalla (rediseño, fase 4, SurfaceFrame): lo que
     * queda bajo el island menos un margen. Lo pone el island. Un panel más alto se recorta
     * aquí y su superficie hace scroll (DESIGN §5: «reorganizar y usar scroll vertical; no
     * reducir texto»). Antes Settings a escala 1,25 salía por debajo de la pantalla.
     */
    property real maxH: 100000
    /** 8C-2: una surface más ancha que la pantalla se ajusta a ella con márgenes. */
    property real maxW: 100000

    function sizeFor(name) {
        void host.revision;
        const it = host.item(name);
        if (!it) return null;
        const sz = host.registry[name].size(it);
        return Qt.size(Math.min(sz.width, host.maxW), Math.min(sz.height, host.maxH));
    }

    /**
     * DONDE SE COLOCA CADA SUPERFICIE (2026-10-28, pedido del usuario con un video de referencia:
     * «texto, iconos y controles deben conservar sus proporciones»). Con SU tamaño, no con el de la
     * forma que se mueve: antes cada loader llenaba el host y la superficie se reacomodaba en cada
     * fotograma del morph (la tarjeta del clima de Hoy cambiaba de ancho y el texto de linea; con
     * `implicitHeight` dependiendo del ancho, el destino del alto se movia). Ahora la forma es un
     * cajon: centrada en horizontal y, mientras la forma es mas baja que ella, pegada al borde de
     * abajo, asi que entra deslizandose desde la union con la barra y se recoge hacia ella; mas alta
     * (relevo hacia una superficie mas baja), arriba, y el borde la alcanza. Sin reloj propio: la
     * posicion sale de la geometria, asi que una interrupcion sigue desde donde este. Antes de
     * construirse, el cargador activo toma el tamaño del host.
     */
    function frameFor(name) {
        // Sólo los cargadores con contenido (incluido el que sale) siguen el morph.
        if (!host.registry[name].loader().active) return Qt.rect(0, 0, 0, 0);
        const sz = host.sizeFor(name);
        const w = sz ? sz.width : host.width, h = sz ? sz.height : host.height;
        const vertical = host.farEdge === "left" || host.farEdge === "right";
        const cx = Math.round((host.width - w) / 2 + (vertical ? 0 : host.contentOffset));
        const cy = Math.round((host.height - h) / 2 + (vertical ? host.contentOffset : 0));
        // En estos estilos, y en un panel adaptable ya abierto, el borde descubre el contenido sin desplazarlo.
        const anchored = host.anchorContent || host.settledOpen === name;
        switch (host.farEdge) {
        // barra abajo: crece hacia arriba, pegada al borde de arriba (el lejano); ya abierta, al de la barra
        case "bottom": return Qt.rect(cx, anchored ? Math.round(host.height - h) : 0, w, h);
        // barra a un costado: lo mismo a lo ancho
        case "left": return Qt.rect(anchored ? 0 : Math.round(Math.min(0, host.width - w)), cy, w, h);
        case "right": return Qt.rect(anchored ? Math.round(host.width - w) : 0, cy, w, h);
        }
        return Qt.rect(cx, anchored ? 0 : Math.round(Math.min(0, host.height - h)), w, h);
    }

    /**
     * La superficie adaptable (`inPlace` en el registro) que ya terminó de abrirse (2026-11-17). Abriendo, el cajón
     * de siempre: pegada al borde de abajo mientras la forma es más baja, así entra deslizándose. Una vez abierta, un
     * cambio de alto por su contenido (escribir en el lanzador, una copia nueva) la dejaría deslizarse igual y el
     * campo de búsqueda subiría y bajaría: queda arriba. Se fija cuando la forma llega (`closeness` 1, y ahí la regla
     * vieja también daba 0: no hay salto) y se suelta al cambiar `open`.
     */
    property string settledOpen: ""
    onClosenessChanged: if (host.closeness >= 0.999 && host.has(host.open) && host.registry[host.open].inPlace === true)
        host.settledOpen = host.open

    function keyPressed(event) {
        if (host.leaveTarget !== null) { host.leaveKey(event); return; }
        const it = host.item(host.open);
        if (it && typeof it.keyPressed === "function")
            it.keyPressed(event);
    }

    // ---- navegacion (QS-FUNC-004) ------------------------------------

    /**
     * PILA DE NAVEGACION. Antes cada ficha tenia su `back()` con el destino
     * cableado (`ServiceJournal` devolvia literalmente "serviceDetail"): con
     * tres niveles funcionaba porque hoy cada ficha solo se alcanza desde su
     * lista. Un cuarto nivel, o una ficha abierta desde otra superficie,
     * volveria a donde dice el cable y no a donde venias.
     *
     * Solo apila lo que salta DESDE una superficie (`forward`). Cualquier otra
     * apertura -- atajo, IPC, un boton del island -- o un cierre la vacia: el
     * cambio de `open` llega sin `_navigating`. Es sincrono: la senal sube a
     * `Screen.openSurface` y el binding de `open` baja en la misma llamada.
     * Hay una pila por `SurfaceHost`, o sea por monitor.
     */
    property var navStack: []
    property bool _navigating: false

    /**
     * Con la pila vacia (la ficha se abrio directa, p. ej. `ipc serviceDetail`),
     * `goBack` sube al padre natural: lo que hacian los `back()` cableados,
     * ahora como dato en un solo sitio.
     */
    readonly property var parents: ({
        wifiDetail: "wifi",
        wired: "wifi",
        speedtest: "wifi",
        btDetail: "bluetooth",
        serviceDetail: "services",
        serviceJournal: "serviceDetail"
    })

    function _jump(name) {
        host._navigating = true;
        host.requestSurface(name);
        host._navigating = false;
    }

    /** Como `forward`, fijando antes que mira la ficha en ESTA pantalla. */
    function forwardTo(name, key) {
        host.select(name, key);
        host.forward(name);
    }

    /** Una superficie pide abrir otra: se apila de donde se viene. */
    function forward(name) {
        if (host.open.length > 0 && host.open !== name) {
            const s = host.navStack.slice();
            s.push(host.open);
            host.navStack = s.slice(-3);   // tres niveles bastan; nunca crece sin tope
        }
        host._jump(name);
    }

    /**
     * 9B: abrir Settings en `dest/página[/fila]` desde otra surface (Configure wallpapers,
     * Theme settings…). Settings UI (2026-11-07): abre la ventana flotante y cierra esta
     * superficie; Esc desde la raíz de Settings vuelve a ella (antes, la pila del host).
     * false si algo lo impide (Guarded) o la ruta no existe.
     */
    function openSettingsAt(path) {
        return Screens.settingsOpenOn(path, host.screenName, { from: host.open });
    }

    /** Volver: lo ultimo de la pila, el padre natural, o cerrar. */
    function goBack() {
        const s = host.navStack.slice();
        const to = s.length > 0 ? s.pop() : (host.parents[host.open] || "");
        if (to.length === 0) {
            host.requestClose();
            return;
        }
        host.navStack = s;
        host._returning = true;
        host._jump(to);
        host._returning = false;
    }
    /**
     * 11A-1: true durante el salto de VUELTA de `goBack` (Esc desde una surface enlazada). La
     * surface a la que se vuelve conserva su vista (el Dashboard, su pestaña) en vez de empezar
     * como una apertura directa.
     */
    property bool _returning: false

    /** `back` del IPC: el mismo camino que Esc -- la superficie limpia lo suyo y pide volver. */
    function back() {
        const it = host.item(host.open);
        if (it && typeof it.back === "function" && host.parents[host.open] !== undefined) {
            it.back();
            return true;
        }
        return false;
    }

    // ---- historial Back/Forward (rediseño, fase 4) ---------------------

    /**
     * Historial POR MONITOR (DESIGN §3), en memoria de la sesión: visitas
     * `{ surface, key, ctx }`. `key` es la selección de la ficha en esta pantalla
     * (`sel`); `ctx` lo da la superficie al salir (`saveContext()`: consulta,
     * selección por id, scroll) y se le devuelve al volver (`restoreContext`).
     *
     * Cerrar NO lo vacía: al reabrir por un acceso directo se añade una visita y Back
     * lleva a la anterior. Una navegación nueva tras Back descarta la rama Forward.
     * Volver nunca ejecuta nada: sólo reabre y restaura la vista.
     *
     * Es independiente de `navStack` (Esc → vista padre, QS-FUNC-004): Esc no recorre
     * otras superficies visitadas; Back/Forward sí (Alt+←/→ y el marco).
     */
    property var history: []
    property int historyIndex: -1
    property bool _historyMove: false
    /** «Item no longer available» un momento, si lo que se restauró ya no existe. */
    property string historyNote: ""
    readonly property bool canBack: host.historyIndex > 0
    readonly property bool canForward: host.historyIndex >= 0 && host.historyIndex < host.history.length - 1

    function _saveCurrent() {
        const i = host.historyIndex;
        if (i < 0 || i >= host.history.length) return;
        const v = host.history[i];
        const it = host.item(v.surface);
        if (!it || typeof it.saveContext !== "function") return;
        let ctx = null;
        try { ctx = it.saveContext(); } catch (e) { console.warn("history: saveContext failed on", v.surface, e); }
        const h = host.history.slice();
        h[i] = { surface: v.surface, key: v.key, ctx: ctx === undefined ? null : JSON.parse(JSON.stringify(ctx)) };
        host.history = h;
    }

    function _pushVisit(name) {
        const key = host.selOf(name);
        const cur = host.history[host.historyIndex];
        // Reabrir lo mismo que ya es la visita actual no crea otra (volvería a sí misma).
        if (cur && cur.surface === name && cur.key === key) {
            const h = host.history.slice();
            h[host.historyIndex] = { surface: name, key: key, ctx: null };
            host.history = h;
            return;
        }
        const h = host.history.slice(0, host.historyIndex + 1);
        h.push({ surface: name, key: key, ctx: null });
        const trimmed = h.slice(-20);
        host.history = trimmed;
        host.historyIndex = trimmed.length - 1;
    }

    function _go(delta) {
        const to = host.historyIndex + delta;
        if (to < 0 || to >= host.history.length) return false;
        host._saveCurrent();
        const v = host.history[to];
        if (!host.has(v.surface)) return false;
        const from = host.historyIndex;
        host.historyIndex = to;
        host.select(v.surface, v.key);
        host._historyMove = true;
        host.requestSurface(v.surface);
        host._historyMove = false;
        if (host.open !== v.surface) {
            // Bloqueado (Guarded): el historial no se mueve. Si la pregunta termina en
            // «Discard and leave», se repite el mismo paso.
            host.historyIndex = from;
            if (host.leaveTarget !== null) host.leaveTarget = { kind: "history", delta: delta };
            return false;
        }
        // Tras el reinicio de la propia superficie al abrirse (sus onOpenChanged y
        // callLater), no antes: dos vueltas del bucle.
        Qt.callLater(() => Qt.callLater(() => host._restore(to)));
        return true;
    }

    function _restore(index) {
        if (index !== host.historyIndex) return;   // se navegó otra vez entretanto
        const v = host.history[index];
        const it = v ? host.item(v.surface) : null;
        if (!it || v.ctx === null || typeof it.restoreContext !== "function") return;
        let ok = true;
        try { ok = it.restoreContext(v.ctx) !== false; } catch (e) { ok = false; console.warn("history: restoreContext failed on", v.surface, e); }
        if (!ok) {
            host.historyNote = "Item no longer available";
            noteTimer.restart();
        }
    }

    Timer { id: noteTimer; interval: 2500; onTriggered: host.historyNote = "" }

    function historyBack() { return host._go(-1); }
    function historyForward() { return host._go(1); }
    function historyDump() {
        return { index: host.historyIndex, visits: host.history.map(v => ({ surface: v.surface, key: v.key, ctx: v.ctx })) };
    }

    // ---- salida protegida: Guarded (rediseño, fase 4) ------------------

    /**
     * La superficie abierta tiene un secreto sin enviar y algo quiso salir (Screen
     * §`guardBlocks`). Aquí se pregunta: **Keep editing** (por defecto: Esc, y el primer
     * botón) o **Discard and leave**. Mientras, el foco se queda en el host: si lo
     * conservara el campo, un Enter enviaría la contraseña.
     *
     * `leaveTarget`: null · { kind: "close" } · { kind: "open", name } · { kind: "history", delta }.
     */
    property var leaveTarget: null
    property int leaveChoice: 0          // 0 = Keep editing, 1 = Discard and leave
    readonly property string leaveReason: {
        const it = host.item(host.open);
        return it && it.guardReason ? it.guardReason : "";
    }

    function askLeave(target) {
        host.leaveTarget = target;
        host.leaveChoice = 0;
        host.forceActiveFocus();
    }

    function keepEditing() {
        host.leaveTarget = null;
        const it = host.item(host.open);
        if (it) it.focusGuarded();
    }

    function discardAndLeave() {
        const t = host.leaveTarget;
        host.leaveTarget = null;
        const it = host.item(host.open);
        if (it) it.discardGuarded();
        if (!t) return;
        if (t.kind === "close") host.requestClose();
        else if (t.kind === "open") host.requestSurface(t.name);
        else if (t.kind === "history") host._go(t.delta);
    }

    function leaveKey(event) {
        const k = event.key;
        if (k === Qt.Key_Escape) { host.keepEditing(); event.accepted = true; return; }
        if (k === Qt.Key_Left || k === Qt.Key_Right || k === Qt.Key_Tab || k === Qt.Key_Backtab) {
            host.leaveChoice = host.leaveChoice === 0 ? 1 : 0;
            event.accepted = true;
            return;
        }
        if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) {
            if (host.leaveChoice === 0) host.keepEditing(); else host.discardAndLeave();
            event.accepted = true;
            return;
        }
        event.accepted = true;   // nada más llega a la superficie mientras se pregunta
    }

    // Si la superficie deja de estar protegida (se envió, se cerró su campo), la pregunta sobra.
    onLeaveReasonChanged: if (host.leaveReason.length === 0 && host.leaveTarget !== null) host.leaveTarget = null

    /** La pregunta, al pie del panel y por encima del contenido. */
    Rectangle {
        id: leaveBar
        z: 100
        visible: host.leaveTarget !== null
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 10 * host.s
        height: leaveCol.implicitHeight + 16 * host.s
        radius: Metrics.r(12) * host.s
        color: Theme.bgFor(Theme.surfaceKey(host.open), true)
        border.width: 1
        border.color: Qt.alpha(Theme.warn, 0.6)

        // Un clic en la barra no debe atravesarla hacia el contenido de debajo.
        MouseArea { anchors.fill: parent }

        Column {
            id: leaveCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 12 * host.s
            anchors.rightMargin: 12 * host.s
            spacing: 8 * host.s

            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: host.leaveReason + " will be lost. Leave anyway?"
                color: Theme.fg
                font.family: Typography.ui
                font.pixelSize: Typography.body * host.s
            }
            Row {
                spacing: 8 * host.s
                ActionButton {
                    s: host.s
                    label: "Keep editing"
                    accent: true
                    focused: host.leaveChoice === 0
                    onTriggered: host.keepEditing()
                }
                ActionButton {
                    s: host.s
                    label: "Discard and leave"
                    danger: true
                    focused: host.leaveChoice === 1
                    onTriggered: host.discardAndLeave()
                }
            }
        }
    }

    // ---- lifecycle -----------------------------------------------------

    property string prevOpen: ""
    property var closedAt: ({})

    onOpenChanged: {
        host.settledOpen = "";
        // La pregunta de salida es de la superficie que se va: al cambiar, sobra.
        host.leaveTarget = null;
        // Historial: al salir de una visita se guarda su contexto; una apertura que no
        // viene de Back/Forward es una visita nueva.
        if (host.prevOpen.length > 0 && host.prevOpen !== host.open && !host._historyMove)
            host._saveCurrent();
        if (host.open.length > 0 && !host._historyMove)
            host._pushVisit(host.open);
        if (!host._navigating || host.open.length === 0)
            host.navStack = [];
        if (host.has(host.open)) {
            const ld = host.registry[host.open].loader();
            if (!ld.active)
                ld.active = true;
            // 9A: varios nombres pueden compartir loader (Settings): se cancela la descarga
            // de todos los que lo usan, no sólo la del nombre abierto.
            const pending = Object.keys(host.closedAt);
            for (let i = 0; i < pending.length; i++)
                if (host.registry[pending[i]].loader() === ld)
                    host.cancelUnload(pending[i]);
        }
        if (host.prevOpen.length > 0 && host.prevOpen !== host.open)
            host.scheduleUnload(host.prevOpen);
        host.prevOpen = host.open;
    }

    function scheduleUnload(name) {
        if (!host.has(name) || !host.registry[name].loader().active)
            return;
        // 9A: el que se va comparte loader con el que se abre (Shell → Theme): sigue vivo.
        if (host.has(host.open) && host.registry[host.open].loader() === host.registry[name].loader())
            return;
        const m = Object.assign({}, host.closedAt);
        m[name] = Date.now();
        host.closedAt = m;
        sweep.start();
    }

    function cancelUnload(name) {
        if (host.closedAt[name] === undefined)
            return;
        const m = Object.assign({}, host.closedAt);
        delete m[name];
        host.closedAt = m;
        if (Object.keys(m).length === 0)
            sweep.stop();
    }

    function unloadClosed() {
        const names = Object.keys(host.closedAt);
        for (let i = 0; i < names.length; i++) {
            const ld = host.registry[names[i]].loader();
            if (ld.active)
                ld.active = false;
        }
        host.closedAt = ({});
        sweep.stop();
    }

    Timer {
        id: sweep
        interval: 5000
        repeat: true
        onTriggered: {
            const now = Date.now();
            const idle = Math.max(10, Settings.unloadSec) * 1000;
            const names = Object.keys(host.closedAt);
            const keep = {};
            for (let i = 0; i < names.length; i++) {
                if (now - host.closedAt[names[i]] >= idle) {
                    const ld = host.registry[names[i]].loader();
                    if (ld.active)
                        ld.active = false;
                } else {
                    keep[names[i]] = host.closedAt[names[i]];
                }
            }
            host.closedAt = keep;
            if (Object.keys(keep).length === 0)
                sweep.stop();
        }
    }

    // ---- loaders -------------------------------------------------------

    Loader {
        id: ldWallpaper
        active: false
        readonly property rect frame: host.frameFor("wallpaper")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: Wallpaper {
            s: host.s
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "wallpaper"
            closeness: host.closeness
            onRequestClose: host.requestClose()
        }
    }

    Loader {
        id: ldRecorder
        active: false
        readonly property rect frame: host.frameFor("recorder")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: Recorder {
            s: host.s
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "recorder"
            closeness: host.closeness
            onRequestClose: host.requestClose()
        }
    }

    Loader {
        id: ldSystem
        active: false
        readonly property rect frame: host.frameFor("system")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: System {
            s: host.s
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "system"
            closeness: host.closeness
            onRequestClose: host.requestClose()
        }
    }

    Loader {
        id: ldControlCenter
        active: false
        readonly property rect frame: host.frameFor("controlCenter")
        // El texto se ajusta al ancho disponible antes de calcular el alto del panel.
        readonly property real baseWidth: Metrics.controlCenterW * host.s
        readonly property real wantedWidth: item ? item.wantW + (item.mLeft + item.mRight) * host.s : baseWidth
        x: frame.x; y: frame.y; height: frame.height
        width: Math.min(host.maxW, 1.25 * baseWidth, Math.max(baseWidth, wantedWidth))
        onLoaded: host.revision++
        sourceComponent: ControlCenter {
            s: host.s
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "controlCenter"
            closeness: host.closeness
            onRequestClose: host.requestClose()
            onRequestSurface: (n) => host.forward(n)
        }
    }

    Loader {
        id: ldCalendar
        active: false
        readonly property rect frame: host.frameFor("calendar")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: Today {
            s: host.s
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "calendar"
            closeness: host.closeness
            onRequestClose: host.requestClose()
        }
    }

    Loader {
        id: ldMixer
        active: false
        readonly property rect frame: host.frameFor("mixer")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: Mixer {
            s: host.s
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "mixer"
            closeness: host.closeness
            onRequestClose: host.requestClose()
        }
    }

    Loader {
        id: ldWeb
        active: false
        readonly property rect frame: host.frameFor("web")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: WebHub {
            s: host.s
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "web"
            closeness: host.closeness
            onRequestClose: host.requestClose()
        }
    }

    Loader {
        id: ldPower
        active: false
        readonly property rect frame: host.frameFor("power")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: Power {
            s: host.s
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "power"
            closeness: host.closeness
            onRequestClose: host.requestClose()
        }
    }

    Loader {
        id: ldClipboard
        active: false
        readonly property rect frame: host.frameFor("clipboard")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: Clipboard {
            s: host.s
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "clipboard"
            closeness: host.closeness
            onRequestClose: host.requestClose()
        }
    }

    Loader {
        id: ldEmoji
        active: false
        readonly property rect frame: host.frameFor("emoji")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: Emoji {
            s: host.s
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "emoji"
            closeness: host.closeness
            onRequestClose: host.requestClose()
        }
    }

    Loader {
        id: ldMinimizer
        active: false
        readonly property rect frame: host.frameFor("minimizer")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: Minimizer {
            s: host.s
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "minimizer"
            closeness: host.closeness
            onRequestClose: host.requestClose()
        }
    }

    Loader {
        id: ldServices
        active: false
        readonly property rect frame: host.frameFor("services")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: Services {
            s: host.s
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "services"
            closeness: host.closeness
            onRequestClose: host.requestClose()
            onRequestDetail: (n, k) => host.forwardTo(n, k)
            onRequestSurface: (n) => host.forward(n)
        }
    }

    Loader {
        id: ldServiceDetail
        active: false
        readonly property rect frame: host.frameFor("serviceDetail")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: ServiceDetail {
            s: host.s
            sel: host.selOf("serviceDetail")
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "serviceDetail"
            closeness: host.closeness
            onRequestClose: host.requestClose()
            onRequestDetail: (n, k) => host.forwardTo(n, k)
            onRequestSurface: (n) => host.forward(n)
            onRequestBack: host.goBack()
        }
    }

    Loader {
        id: ldServiceJournal
        active: false
        readonly property rect frame: host.frameFor("serviceJournal")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: ServiceJournal {
            s: host.s
            sel: host.selOf("serviceJournal")
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "serviceJournal"
            closeness: host.closeness
            onRequestClose: host.requestClose()
            onRequestSurface: (n) => host.forward(n)
            onRequestBack: host.goBack()
        }
    }

    Loader {
        id: ldThemePicker
        active: false
        readonly property rect frame: host.frameFor("theme")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: ThemePicker {
            s: host.s
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "theme"
            closeness: host.closeness
            onRequestClose: host.requestClose()
        }
    }

    Loader {
        id: ldCommandPalette
        active: false
        readonly property rect frame: host.frameFor("cli")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: CommandPalette {
            s: host.s
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "cli"
            closeness: host.closeness
            onRequestClose: host.requestClose()
            onRequestSurface: (n) => host.forward(n)
        }
    }

    Loader {
        id: ldWired
        active: false
        readonly property rect frame: host.frameFor("wired")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: Wired {
            s: host.s
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "wired"
            closeness: host.closeness
            onRequestClose: host.requestClose()
            onRequestBack: host.goBack()
            onRequestDetail: (n, k) => host.forwardTo(n, k)
        }
    }

    Loader {
        id: ldSpeedTest
        active: false
        readonly property rect frame: host.frameFor("speedtest")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: NetSpeed {
            s: host.s
            sel: host.selOf("speedtest")
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "speedtest"
            closeness: host.closeness
            onRequestClose: host.requestClose()
            onRequestBack: host.goBack()
        }
    }

    Loader {
        id: ldWifiDetail
        active: false
        readonly property rect frame: host.frameFor("wifiDetail")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: WifiDetail {
            s: host.s
            sel: host.selOf("wifiDetail")
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "wifiDetail"
            closeness: host.closeness
            onRequestClose: host.requestClose()
            onRequestSurface: (n) => host.forward(n)
            onRequestDetail: (n, k) => host.forwardTo(n, k)
            onRequestBack: host.goBack()
        }
    }

    Loader {
        id: ldBluetooth
        active: false
        readonly property rect frame: host.frameFor("bluetooth")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: BtList {
            s: host.s
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "bluetooth"
            closeness: host.closeness
            onRequestClose: host.requestClose()
            onRequestDetail: (n, k) => host.forwardTo(n, k)
            onRequestSurface: (n) => host.forward(n)
        }
    }

    Loader {
        id: ldAuth
        active: false
        readonly property rect frame: host.frameFor("auth")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: Auth {
            s: host.s
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "auth"
            closeness: host.closeness
            onRequestClose: host.requestClose()
        }
    }

    Loader {
        id: ldNotifications
        active: false
        readonly property rect frame: host.frameFor("notifications")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: Notifications {
            s: host.s
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "notifications"
            closeness: host.closeness
            onRequestClose: host.requestClose()
        }
    }

    Loader {
        id: ldBtDetail
        active: false
        readonly property rect frame: host.frameFor("btDetail")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: BtDetail {
            s: host.s
            sel: host.selOf("btDetail")
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "btDetail"
            closeness: host.closeness
            onRequestClose: host.requestClose()
            onRequestSurface: (n) => host.forward(n)
            onRequestBack: host.goBack()
        }
    }

    Loader {
        id: ldWifi
        active: false
        readonly property rect frame: host.frameFor("wifi")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: Wifi {
            s: host.s
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "wifi"
            closeness: host.closeness
            onRequestClose: host.requestClose()
            onRequestDetail: (n, k) => host.forwardTo(n, k)
            onRequestSurface: (n) => host.forward(n)
        }
    }

    Loader {
        id: ldLauncher
        active: false
        readonly property rect frame: host.frameFor("launcher")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: Launcher {
            s: host.s
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "launcher"
            closeness: host.closeness
            onRequestClose: host.requestClose()
        }
    }

    Loader {
        id: ldDashboard
        active: false
        readonly property rect frame: host.frameFor("dashboard")
        x: frame.x; y: frame.y; width: frame.width; height: frame.height
        onLoaded: host.revision++
        sourceComponent: Dashboard {
            s: host.s
            screenName: host.screenName
            host: host
            engaged: !host.preview
            open: host.open === "dashboard"
            closeness: host.closeness
            onRequestClose: host.requestClose()
            onRequestSurface: (n) => host.forward(n)
            onRequestDetail: (n, k) => host.forwardTo(n, k)
        }
    }
}
