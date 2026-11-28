import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import "../theme"
import "../services"
import "../components"
import "../lib/notch-activities.js" as Acts
import "../lib/bar-edge.js" as BarEdge
import "../lib/shape-open.js" as ShapeOpen
import "../lib/wheel.js" as Wheel
import "../lib/nav-keys.js" as NavKeys

/**
 * The island: one Morph per screen whose target geometry is a pure function
 * of `mode`. Faces (rest, hover) and surfaces are stacked children that fade
 * with `closeness`. Input, latches and masks live in Screen; this item only
 * knows its mode and how to look.
 *
 * Rest is the glanceable one: the clock in the exact centre between two privacy
 * dots (fase 8B-1). The Music and Network circles beside it are NOT children of
 * this Morph: `core/Screen` places them (`IslandCircle`). Hover carries everything else: the workspace dots,
 * the date, the buttons that open surfaces, the indicators, tray and battery.
 */
Morph {
    id: island
    returning: mode === "rest"

    property string screenName: ""
    property string open: ""
    property bool expanded: false
    /**
     * Fase 8C-1: esta pantalla tiene la Hover Bar persistente. El island no tiene cara en
     * reposo (mide 0: la barra la sustituye) y cuelga bajo la barra (`core/Screen`), así
     * que las surfaces nacen de ella; el OSD y los avisos siguen siendo su cápsula.
     */
    property bool barMode: false
    /**
     * Cuelga de la barra persistente (2026-10-01, pedido del usuario: «que parezca que sale de la
     * barra»): sin hueco, el borde de arriba recto y pegado al de la barra, y dos curvas cóncavas
     * (los filetes de `contour`) que la unen a ella. Lo decide Screen (`barMode && belowBar`).
     */
    property bool attached: false
    /**
     * EL LADO POR EL QUE SE UNE (2026-11-19, lib/bar-edge.js): el borde donde está la barra de esta pantalla (top ·
     * bottom · left · right); con el island o la muesca, siempre arriba. El contorno se dibuja «arriba» y se lleva a
     * este lado; `hOffset` corre a lo largo de él (en vertical, en `y`).
     */
    property string attachEdge: "top"
    readonly property bool alongVertical: island.attachEdge === "left" || island.attachEdge === "right"
    /**
     * Dónde puede caer la forma a lo largo, en px del padre (lo pone Screen): con la barra, su tramo recto —y, si no
     * cabe, el de la pantalla, despegada—; −1 = el de siempre (16 px a cada lado, o el tramo de la barra entera).
     */
    property real alongLo: -1
    property real alongHi: -1
    /** El centro de la barra a lo largo, desde el centro de la pantalla: de ahí cuelgan el OSD y los avisos. */
    property real barMidOffset: 0
    /** Lo que queda para el panel en cada eje (lo pone Screen fuera de la barra de arriba; −1 = el cálculo de siempre). */
    property real roomW: -1
    property real roomH: -1
    // Independent sizing envelope during a presentation arc; avoid size -> y -> maxH feedback.
    property real availableTop: island.y
    /** Largo de cada filete sobre la barra (0 sin colgar): la barra no pinta su filo sobre la forma ni sobre ellos. */
    readonly property real shoulderW: island.attached ? contour.fx : 0
    /**
     * Lo que el faldón de la muesca (2026-11-12) asoma a cada lado más que el collar de antes: las piezas
     * laterales se apartan eso y guardan con él el aire que tenían. Sin muesca, 0.
     */
    readonly property real flareW: island.attached ? 0
        : Math.max(0, contour.fx - Metrics.notchShoulder * island.s * contour.e)
    // The seam changes shape from its current geometry when a presentation is interrupted.
    // Recogida no hay nada que ver: se une de golpe y el panel nace ya siendo parte de la barra.
    SpringValue { id: attachSpring; target: island.attached ? 1 : 0; animate: island.shapeShown; epsilon: 0.004 }
    property real attachment: attachSpring.value
    /**
     * DESPEGADA DE UNA BARRA CORTA (2026-11-21, pedido del autor con capturas): un panel más ancho que el tramo recto
     * cuelga a `appGap` de la barra (Screen, `barFits`). Con la barra-muesca seguía dibujándose como muesca —arriba
     * recta y con los dos faldones— flotando sin tocar nada. Despegada es una tarjeta suelta: la misma muesca opaca,
     * sin filo ni faldones y con las cuatro esquinas redondeadas (eligió esto entre cuatro). Lo decide Screen.
     */
    property bool detached: false
    SpringValue { id: detachSpring; target: island.detached ? 1 : 0; animate: island.shapeShown; epsilon: 0.004 }
    readonly property real detachment: Math.max(0, Math.min(1, detachSpring.value))
    // Screen supplies a continuous join while a panel accompanies a bar transformation.
    property real presentationJoin: Math.max(0, Math.min(1, island.attachment))
    // la muesca se une al borde salvo despegada de la barra: entonces sólo queda su cuerpo opaco (`notchBody`)
    readonly property real edgeJoin: Math.max(island.presentationJoin, island.dockLift * (1 - island.detachment))
    /** El cuerpo de la muesca (opaco, sin filo) lo pinta `contour` aunque no se una a nada. */
    readonly property bool notchBody: island.dockLift > 0.001

    /**
     * FASE 8E: con la barra, la surface nace BAJO EL ACCESO que la abrió
     * (futureHoverBarsurface, ANIMATIONS «Hover Bar persistente → surface») y se recoge
     * hacia él. `originOffset` es la distancia del acceso al centro (la pone Screen antes de
     * abrir; 0 por atajo o IPC); `hOffset` lo recorta para que el panel quepa con 16 px de
     * margen. Con el island va centrado: las piezas laterales se apartan a los lados del
     * panel (8B-2) y un panel bajo la de Red chocaría con ella.
     *
     * Con la forma a 0 (reposo con barra) el salto es instantáneo —nada se ve moverse—; con
     * la forma visible, muelle firme (geometría con máscara: sin rebote).
     */
    property real originOffset: 0

    /**
     * 8E: el relevo con la barra. La barra nace del tamaño y el sitio exactos de la cápsula
     * y muere en ellos, así que la cápsula se oculta de golpe al empezar a desplegarse y
     * reaparece cuando la barra termina de plegarse (su cara entra con un fundido corto).
     * Lo decide Screen.
     */
    property bool swapHidden: false

    /**
     * FASE 8F-1: DOCK (futuredocksurface.md, notch-idle/-desplegado/-OSD). La presentación
     * compacta tipo notch: la MISMA forma pegada al borde superior, opaca, con las esquinas de
     * arriba rectas y las de abajo redondeadas. Reposo, cara hover, OSD y surfaces salen de
     * ella como del island. `dockLift` (0→1) sube la forma al borde y relevan vidrio y notch.
     */
    property bool dockMode: false
    // 2026-10-01: el muelle de la forma (antes 240 ms OutCubic, otro reloj que el del panel)
    SpringValue { id: dockSpring; target: island.dockMode ? 1 : 0; epsilon: 0.004 }
    property real dockLiftRaw: dockSpring.value
    readonly property real dockLift: Math.max(0, Math.min(1, island.dockLiftRaw))

    /**
     * NOTCH EN VIVO (2026-11-17): con la muesca y sin barra, la actividad en curso asoma en dos OREJAS a los lados del
     * reposo (`core/NotchEar`; qué actividad, `services/LiveActivity` con `lib/notch-activities.js`). Sólo en el notch:
     * la island conserva sus círculos. `earLive` es la persistente (la lee Screen para el círculo de Música y la
     * pastilla del grabador); `earActivity`, la que se ve, con las flash de esta pantalla encima.
     */
    readonly property bool earsOn: island.dockMode && !island.barMode
    readonly property string earLive: island.earsOn ? LiveActivity.live : ""
    readonly property string earActivity: island.earsOn ? LiveActivity.currentFor(island.screenName) : ""
    /** Cada oreja (las dos miden lo mismo). Sólo cuenta en reposo: en hover, OSD o panel manda su propio ancho. */
    readonly property real earW: Acts.width(island.earActivity) * island.s
    /** La que se dibuja: la última no vacía, para que la oreja se desvanezca con su contenido mientras la forma encoge. */
    property string earShown: ""
    onEarActivityChanged: if (island.earActivity.length > 0) island.earShown = island.earActivity
    /** Settings → Notch → Rest: Minimal deja sólo los puntos de privacidad (el reloj, en la fila hover). */
    readonly property bool restMinimal: island.dockMode && Settings.notchRest === "minimal"
    /** El OSD y los avisos conservan el centro de la barra hasta que su forma termina de recogerse. */
    readonly property bool barFeedback: {
        if (!island.barMode) return false;
        const face = island.mode === "rest" ? island.drawerFrom : island.mode;
        return face === "osd" || face === "notice";
    }
    readonly property real hOffsetTarget: {
        if (!island.barMode) return 0;
        // el cajón recogiéndose: donde estaba (el OSD no se corre hacia el acceso mientras entra en la barra)
        if (island.drawerHolding) return island.drawerHoldOffset;
        if (island.barFeedback) return island.barMidOffset;
        // otro borde, o una barra más corta: el tramo que da Screen, a lo largo de ese borde
        if (island.alongLo >= 0 && island.alongHi >= 0) {
            const pl = island.parent ? (island.alongVertical ? island.parent.height : island.parent.width) : 0;
            const tl = island.alongVertical ? island.targetH : island.targetW;
            const lo = island.alongLo + tl / 2, hi = island.alongHi - tl / 2;
            const c = pl / 2 + island.originOffset;
            return (lo > hi ? (island.alongLo + island.alongHi) / 2 : Math.max(lo, Math.min(hi, c))) - pl / 2;
        }
        const pw = island.parent ? island.parent.width : 0;
        /*
         * 2026-10-01: colgando de la barra, la forma y sus hombros caben en el TRAMO RECTO del
         * borde de abajo de la barra (margen de la barra + su esquina + un hombro). Con 16 px, abierta
         * desde el engranaje, el hombro sobresalía de la punta redondeada y dibujaba un pico suelto
         * con la sombra detrás (captura del usuario).
         */
        const m = island.attached ? (Metrics.topGap + Metrics.restCorner + Metrics.barShoulder + 2) : 16;
        const lim = Math.max(0, (pw - island.targetW) / 2 - m * island.s);
        return Math.max(-lim, Math.min(lim, island.originOffset));
    }
    SpringValue { id: hOffsetSpring; target: island.hOffsetTarget; animate: island.shapeShown }
    readonly property real styleOriginOffset: island.barFeedback ? island.barMidOffset : island.originOffset
    /** Unfold, Bloom e Ink interpolan desde el origen de la cara hasta su posición final a lo largo de la barra. */
    property real hOffset: island.styleCentre < 1
        ? island.styleOriginOffset + (hOffsetSpring.value - island.styleOriginOffset) * island.styleCentre
        : hOffsetSpring.value
    property bool hidden: false

    /**
     * El OSD, que ahora es un ESTADO del island y no una cápsula aparte
     * (2026-09-15). Lo alimenta `core/Osd`, que se quedó con la lógica.
     */
    property bool osdActive: false
    property real osdLevel: 0
    property bool osdOff: false
    property string osdGlyph: "volume-high"
    property string osdKind: "volume"
    /** Fase 3D (ADR-42): el color del significado (`lib/accent-zones.js`), como en el Control Center: brillo tertiary. */
    readonly property color osdAccent: island.osdKind === "brightness" ? Theme.famTertiary.fill : Theme.primary
    /** "none" · "level" (volumen) · "notice" (algo que contar). */
    property string osdMode: "none"
    property string noticeText: ""
    property string noticeGlyph: "alert"
    property string noticeTone: "danger"

    signal requestSurface(string name)
    /** Hover preview (fase 4C): el puntero se quedó sobre un icono que abre `name`. */
    signal previewRequested(string name)
    /** La superficie abierta es una vista previa (la decide `Screen`). */
    property bool preview: false
    signal requestClose()

    /**
     * El modo. El OSD va DESPUÉS de `expanded` y de la superficie abierta a
     * propósito: con el puntero encima o con el mezclador delante ya estás
     * viendo el volumen, y que el island se plegara a enseñarlo otra vez sería
     * quitarte de en medio lo que estás usando.
     */
    readonly property string mode: (open.length > 0 && host.has(open)) ? open
        : (osdForce && osdMode === "level") ? "osd"
        : expanded ? "hover"
        : osdMode === "notice" ? "notice"
        : osdMode === "level" ? "osd"
        : "rest"
    readonly property bool hovering: mode === "hover"

    /**
     * GESTOS (notch en vivo, parte 3, 2026-11-17; en la island y en el notch, sin la barra): la rueda es el volumen
     * (±5 % por muesca) y el clic medio reproduce o pausa. Settings → Shell → General → Island («Scroll», «Middle
     * click»). Los atiende `gestures`, DEBAJO de las caras: lo que ya tiene su rueda o su clic medio (la bandeja, el
     * botón de avisos) sigue mandando.
     *
     * Sin Shift + rueda para el brillo, que se había aprobado: medido en el banco, la capa no tiene el teclado y Wayland
     * sólo cuenta los modificadores a quien lo tiene, así que Qt no ve el Shift (sí con el peek fijado, que lo toma).
     * El autor eligió dejar el brillo fuera de los gestos (encuesta del 2026-11-17).
     *
     * Con el puntero encima el modo es `hover` y el OSD no saldría (va después de `expanded`, ver `mode`): girar la
     * rueda es pedir ese valor, así que `osdForce` lo pone delante del hover un momento y al parar vuelve la fila. Sólo
     * el nivel: un aviso conserva su orden de siempre.
     */
    property bool osdForce: false
    Timer { id: osdForceTimer; interval: 1200; onTriggered: island.osdForce = false }
    /**
     * Mientras dura, la entrada conserva el sitio que tenía la forma al girar (la fila hover mide ~800 px y el OSD
     * mucho menos): sin esto, con el puntero en un extremo de la fila la forma encogía bajo él y las muescas siguientes
     * caían en la ventana de debajo (la página del navegador se desplazaba). Sólo la máscara y `gestures`; lo que se
     * dibuja no cambia. Lo lee Screen (`islandRegion`).
     */
    property real gestureHoldW: 0
    property real gestureHoldH: 0
    onOsdForceChanged: if (!island.osdForce) { island.gestureHoldW = 0; island.gestureHoldH = 0; }
    readonly property bool gesturesOn: !island.barMode && island.small
    /** Para Screen: el volumen pide su OSD aunque no cambie (al 100 % la rueda arriba no movía nada y no se veía). */
    signal gestureFeedback(string kind)

    function holdForGesture() {
        island.gestureHoldW = Math.max(island.gestureHoldW, island.width, island.targetW);
        island.gestureHoldH = Math.max(island.gestureHoldH, island.height, island.targetH);
        island.osdForce = true;
        osdForceTimer.restart();
    }
    /**
     * Una muesca de rueda son 120 unidades; una rueda fina o un touchpad mandan trozos y se suman, así que el paso es
     * el mismo (5 %) con cualquier dispositivo. Cambiar de sentido empieza la cuenta de cero.
     */
    property real wheelAcc: 0
    function gestureWheel(w) {
        if (Settings.islandWheel !== "volume") { w.accepted = false; return; }
        w.accepted = true;
        const r = Wheel.step(island.wheelAcc, Wheel.delta(w.angleDelta));
        island.wheelAcc = r.acc;
        if (r.steps !== 0) island.gestureVolume(r.steps * 0.05);
    }
    /** Un paso de volumen (`Mixer.nudgeVolume`, el mismo que la barra), con su OSD. */
    function gestureVolume(delta) {
        if (!Mixer.defaultSink) return false;
        island.holdForGesture();
        Mixer.nudgeVolume(delta);
        island.gestureFeedback("volume");
        return true;
    }
    function gestureMiddle() {
        if (Settings.islandMiddleClick !== "playpause") return false;
        return Media.toggle();
    }

    /** F10: la temperatura de la fecha, al día mientras la cara hover está abierta (la caché vale 30 min). */
    Claim { target: Weather; key: "hover@" + island.screenName; value: island.mode === "hover" && Weather.configured }

    readonly property real restW: restFace.implicitWidth + 2 * Metrics.restPad * s + 2 * island.earW
    readonly property real restH: Metrics.restH * s
    readonly property real hoverW: hoverFace.implicitWidth + 2 * Metrics.facePad * s
    readonly property real hoverH: Metrics.hoverH * s

    readonly property bool small: mode === "rest" || mode === "hover"
        || mode === "osd" || mode === "notice"
    readonly property var surfaceSize: !small ? host.sizeFor(mode) : null

    /**
     * En modo OSD el island **sólo se ensancha**: mismo alto que en reposo. Que
     * la altura no cambie es lo que hace que se lea como la misma pieza
     * diciendo algo, y no como otra cosa que aparece.
     */
    readonly property real openW: surfaceSize ? surfaceSize.width
        : mode === "hover" ? hoverW
        : mode === "osd" ? Metrics.osdW * s
        : mode === "notice" ? Math.min(Metrics.notifW * s, noticeFace.implicitWidth + 2 * Metrics.facePad * s)
        : barMode ? 0
        : restW
    // con el cajón, un panel aún sin medir (recién cargado) no asoma: si creciera hacia `restH` mientras su largo es
    // 0, al llegar el tamaño ya no estaría recogido y el largo crecería en vez de saltar (banco, 2026-11-19)
    readonly property real openH: surfaceSize ? surfaceSize.height
        : (mode === "hover" ? hoverH : ((mode === "rest" && barMode) || (drawer && !small) ? 0 : restH))
    readonly property real openR: small ? (dockMode ? Metrics.notchCorner * s : Metrics.restCorner * s) : Metrics.openCorner * s
    // el cajón: cerrando, el largo a lo largo y las esquinas se quedan como estaban hasta que la profundidad llega a 0
    // (el eje primero: el destino de la profundidad no depende de la retención, que lee la profundidad)
    targetW: !island.alongVertical && island.drawerHolding ? island.drawerHoldW : island.openW
    targetH: island.alongVertical && island.drawerHolding ? island.drawerHoldH : island.openH
    targetRadius: island.drawerHolding ? island.drawerHoldR : island.openR

    /**
     * EL CAJÓN DE LA BARRA (2026-11-19, pedido del autor: «que la superficie se deslice ya expandida»; Settings →
     * Animations → Bar panels, `slide` de serie). Con la barra, en reposo la forma mide 0 × 0 y antes crecía en los
     * dos ejes desde el punto bajo el acceso: un globo que se infla. Con Slide la forma tiene desde el primer fotograma
     * su largo A LO LARGO de la barra (`snapW/H` de Morph mientras la profundidad es ~0) y sólo crece en PROFUNDIDAD,
     * con el contenido pegado al borde lejano (`SurfaceHost.frameFor`, `drawerShift` de las caras) y opaco: se ve el
     * panel entero saliendo de debajo de la barra. Cerrando, el largo, las esquinas y el sitio se retienen
     * (`drawerHolding`) hasta que la profundidad llega a 0. Entre dos paneles ya abiertos, el morph de siempre.
     * Sin barra (island, muesca) no cuenta; con Grow, todo como antes.
     */
    // 2026-11-21 (ADR-40): todos los estilos de Bar panels van sobre el cajón salvo Grow (lo de antes)
    readonly property bool drawer: island.barMode && Motion.barPanelStyle !== "grow"
    /** La profundidad (hacia dentro desde la barra) que tiene ahora la forma. */
    readonly property real depthNow: island.alongVertical ? island.width : island.height
    /*
     * Los tres siguientes los pone `drawerTrack` (manejadores), no un enlace: leen la geometría que ellos mismos
     * mueven (el destino retenido, el snap) y como enlaces daban «Binding loop» en `depthNow` (banco, 2026-11-19).
     */
    /** Recogida: el eje a lo largo y el radio en «snap». */
    property bool drawerFlat: false
    /** Cerrando y aún asomada: retiene largo, esquinas y sitio. */
    property bool drawerHolding: false
    /** La forma se ve (gobierna los muelles del sitio y la unión): con el cajón, por la profundidad. */
    property bool shapeShown: false
    property bool drawerTracking: false
    function drawerTrack() {
        // los cambios que provoca (snap, destino retenido) mueven la geometría y vuelven a llamar: se repasa después
        if (island.drawerTracking) { Qt.callLater(island.drawerTrack); return; }
        island.drawerTracking = true;
        const d = island.alongVertical ? island.width : island.height;
        const flat = island.drawer && d < 1;
        const hold = island.drawer && island.mode === "rest" && d >= 1;
        const shown = island.drawer ? d > 2 : island.width > 2;
        if (island.drawerFlat !== flat) island.drawerFlat = flat;
        if (island.drawerHolding !== hold) island.drawerHolding = hold;
        if (island.shapeShown !== shown) island.shapeShown = shown;
        // abriendo: el deslizamiento acaba al llegar (un panel aún sin medir tiene destino 0 y no cuenta)
        if (island.drawerSliding && island.mode !== "rest" && island.drawerDepth > 0 && d >= island.drawerDepth - 0.5)
            island.drawerSliding = false;
        island.drawerTracking = false;
    }
    Component.onCompleted: island.drawerTrack()
    // con un estilo de forma la geometría es un enlace a la línea (`tlOn`): cambiar aquí el destino retenido en el mismo
    // instante volvía a evaluar la línea («Binding loop» en `styleFrame`, banco 2026-11-21): al turno siguiente
    onWidthChanged: if (island.tlOn) Qt.callLater(island.drawerTrack); else island.drawerTrack()
    onHeightChanged: if (island.tlOn) Qt.callLater(island.drawerTrack); else island.drawerTrack()
    onDrawerChanged: island.drawerTrack()
    onAlongVerticalChanged: island.drawerTrack()
    snapW: island.drawerFlat && !island.alongVertical
    snapH: island.drawerFlat && island.alongVertical
    snapR: island.drawerFlat
    /** Lo último abierto (panel, OSD o aviso): su largo, profundidad, esquinas, sitio y cara, para recogerlo entero. */
    property real drawerHoldW: 0
    property real drawerHoldH: 0
    property real drawerHoldR: 0
    property real drawerHoldOffset: 0
    property string drawerFrom: ""
    function drawerKeep() {
        if (island.mode === "rest") return;
        island.drawerHoldW = island.openW;
        island.drawerHoldH = island.openH;
        island.drawerHoldR = island.openR;
        island.drawerHoldOffset = island.hOffsetTarget;
    }
    onOpenWChanged: island.drawerKeep()
    onOpenHChanged: island.drawerKeep()
    onOpenRChanged: island.drawerKeep()
    onHOffsetTargetChanged: if (island.mode !== "rest") island.drawerHoldOffset = island.hOffsetTarget
    /**
     * Abriendo desde el reposo o volviendo a él con el cajón: el contenido viaja ya visible (SurfaceHost `drawer`,
     * las caras sin relevo). Se apaga al cambiar entre dos modos abiertos (no al llegar: un panel aún sin medir
     * llega a 0 × 0 antes de crecer, y el contenido entraba con fundido; banco, 2026-11-19).
     */
    property bool drawerPhase: false
    /**
     * El deslizamiento en sí (los filetes crecen con él): desde que empieza la fase hasta que la profundidad llega a su
     * destino; al cerrar, hasta el reposo. Un panel ya abierto que cambia de alto en su sitio no lo vuelve a encender.
     */
    property bool drawerSliding: false
    /** La profundidad completa de lo que entra o sale, y cuánto correr las caras para pegarlas al borde lejano. */
    readonly property real drawerDepth: island.mode === "rest"
        ? (island.alongVertical ? island.drawerHoldW : island.drawerHoldH)
        : (island.alongVertical ? island.openW : island.openH)
    readonly property real drawerShift: !island.drawerPhase ? 0
        : (island.attachEdge === "top" || island.attachEdge === "left")
            ? (island.depthNow - island.drawerDepth) / 2 : (island.drawerDepth - island.depthNow) / 2

    /** El modo anterior y si veníamos de un panel (el relevo de vuelta va tarde: `Motion.settleHandoff`). */
    property string lastMode: "rest"
    property bool fromPanel: false
    onModeChanged: {
        const prevMode = island.lastMode;
        const small = ["rest", "hover", "osd", "notice"];
        island.fromPanel = small.indexOf(island.lastMode) < 0 && small.indexOf(island.mode) >= 0;
        // el cajón: sólo saliendo del reposo o volviendo a él (entre dos abiertos, el morph de siempre). «Saliendo»
        // por la profundidad y no por `lastMode`: con la barra, abrir pasa un instante por `hover` (banco, 2026-11-19)
        island.drawerPhase = island.drawer && (island.depthNow < 1 || island.mode === "rest");
        island.drawerSliding = island.drawerPhase;
        if (island.mode !== "rest") island.drawerFrom = island.mode;
        island.lastMode = island.mode;
        island.drawerKeep();
        island.drawerTrack();
        island.travelling = true;        // hay algo que relevar: ver `reveal`
        if (mode !== "hover") {          // el peek se fue: sin cursor ni tooltip
            island.navIdx = -1;
            island.hoverKey = "";
        }
        island.styleBegin(prevMode);
    }

    /**
     * ESTILOS DE FORMA (2026-11-21, ADR-40; lib/shape-open.js, tools/shape-open/). Settings → Animations → Bar panels
     * (con la barra) e Island style (island y notch). Slide, Grow y Fluid son los muelles de siempre y no pasan por aquí.
     * Los demás tienen una línea de tiempo `styleV` (un VALOR, nunca un enlace: lección del destello de Power-on en
     * theme/Reveal) que corre al salir del reposo y al volver a él:
     *  - con la barra, como el cajón: desde profundidad 0 (paneles, vistas previas, OSD y avisos) y de vuelta al reposo;
     *  - sin ella, al abrir un panel desde el reposo o la fila hover y al volver (el OSD y los avisos se ensanchan como
     *    siempre: «la misma pieza diciendo algo»).
     * Entre dos paneles abiertos, el morph de siempre: la línea suelta la forma y se acaba.
     *
     * Abriendo, el reposo es lo que se veía al empezar (`styleSnap`) y el destino es el vivo; cerrando, al revés. La
     * curva da exactamente el destino al acabar y Morph recoge la forma con sus muelles sin salto (`tlOn`). Cambiar de
     * rumbo a mitad empieza otra línea desde lo que se ve (geometría continua por construcción) y mezcla los efectos los
     * primeros 18 %. Un panel aún sin medir espera (`styleWaiting`) con la forma en su reposo.
     */
    property real styleV: 0
    property bool styleRun: false
    property bool styleGeom: false
    property bool styleOpening: false
    property bool styleWaiting: false
    property string styleKind: ""
    property string styleName: ""
    property var styleSnap: null
    property var styleFxFrom: null
    NumberAnimation {
        id: styleAnim
        target: island
        property: "styleV"
        easing.type: Easing.Linear
        onFinished: island.styleFinish()
    }
    readonly property var styleParams: island.styleKind === "bar" ? Motion.barPanelParams(island.styleName)
        : Motion.islandParams(island.styleName)
    /** El destino vivo en el marco canónico (a lo largo, profundidad, radio). */
    readonly property var styleLive: ({
        a: island.alongVertical ? island.targetH : island.targetW,
        d: island.alongVertical ? island.targetW : island.targetH,
        r: island.targetRadius
    })
    /** Dónde cae el acceso que lo abrió a lo largo del panel abierto, desde su principio (la gota de Ink). */
    readonly property real styleBtn: island.styleLive.a / 2 + island.styleOriginOffset - hOffsetSpring.value
    readonly property var styleFrame: {
        if (!island.styleRun || !island.styleSnap) return null;
        const live = island.styleLive;
        const p = island.styleParams;
        const f = ShapeOpen.frame(island.styleKind, island.styleName, island.styleV, island.styleOpening,
            island.styleOpening ? island.styleSnap : live, island.styleOpening ? live : island.styleSnap,
            { s: island.s, reduced: Motion.still, openS: (p.openMs || 400) / 1000, closeS: (p.closeMs || 240) / 1000,
              pill: (h) => Metrics.pill(h), btn: island.styleBtn });
        if (island.styleFxFrom) {
            const q = island.styleOpening ? island.styleV : 1 - island.styleV;
            if (q < 0.18) f.fx = ShapeOpen.mixFx(island.styleFxFrom, f.fx, 1 - Math.pow(1 - q / 0.18, 3));
        }
        return f;
    }
    readonly property var styleFx: island.styleFrame ? island.styleFrame.fx : null
    readonly property real styleCentre: island.barMode && island.styleFx ? Math.max(0, Math.min(1, island.styleFx.c)) : 1
    readonly property real styleTint: island.styleFx ? island.styleFx.tint : 0
    readonly property real styleGlow: island.styleFx ? island.styleFx.glow : 0
    readonly property real styleShade: island.styleFx ? island.styleFx.shade : 0
    readonly property real styleRot: island.styleFx ? island.styleFx.rot : 0
    /** La opacidad que pide el estilo para el contenido (−1 = el relevo de siempre). */
    readonly property real styleContent: island.styleFx ? island.styleFx.cOp : -1
    /** Las caras del OSD y de los avisos que cuelgan de la barra siguen la misma opacidad (Bloom: no dentro de la cápsula). */
    readonly property real styleFaceOp: island.barMode && island.styleContent >= 0 ? island.styleContent : 1
    /** La capa del contenido (máscara de Ink, desenfoque de Mist): sólo mientras corre la línea. */
    readonly property bool styleLayer: island.styleRun && ShapeOpen.contentLayer(island.styleKind, island.styleName)

    function styleBegin(prev) {
        const kind = island.barMode ? "bar" : "island";
        const name = island.barMode ? Motion.barPanelStyle : Motion.islandStyle;
        const small = ["rest", "hover", "osd", "notice"];
        const reopening = island.styleRun && !island.styleOpening;
        let phase = "";
        if (!Motion.off && ShapeOpen.timeline(kind, name)) {
            if (island.barMode) {
                // con la barra, abrir pasa un instante por `hover`: ni empieza ni corta nada
                if (island.mode === "hover") return;
                if (island.mode === "rest") phase = island.depthNow >= 1 ? "close" : "";
                else if (island.depthNow < 1 || reopening) phase = "open";
            } else {
                const was = small.indexOf(prev) >= 0, is = small.indexOf(island.mode) >= 0;
                // Al cerrar desde Screen, open y expanded pueden pasar por hover antes de rest en el
                // mismo turno. La línea aún está en su origen y styleLive ya lee el destino definitivo.
                if (was && is && reopening && island.styleV === 1
                        && island.styleKind === kind && island.styleName === name) return;
                if (!is && (was || reopening)) phase = "open";
                else if (is && !was) phase = "close";
            }
        }
        if (phase === "") {
            // entre dos paneles (o el estilo ya no tiene línea): la forma vuelve a los muelles desde lo que se ve
            if (island.styleRun) { styleAnim.stop(); island.styleFinish(); }
            return;
        }
        const cur = {
            a: island.alongVertical ? island.height : island.width,
            d: island.alongVertical ? island.width : island.height,
            r: island.radius
        };
        island.styleFxFrom = island.styleRun && island.styleFx ? island.styleFx : null;
        styleAnim.stop();
        island.styleKind = kind;
        island.styleName = name;
        island.styleOpening = phase === "open";
        island.styleSnap = cur;
        island.styleV = island.styleOpening ? 0 : 1;
        island.styleRun = true;
        island.styleGeom = ShapeOpen.drivesGeometry(kind, name);
        island.styleWaiting = island.styleOpening && !island.small && island.surfaceSize === null;
        if (!island.styleWaiting) island.styleGo();
    }
    function styleGo() {
        const p = island.styleParams;
        styleAnim.from = island.styleV;
        styleAnim.to = island.styleOpening ? 1 : 0;
        styleAnim.duration = Math.max(1, Motion.styleMs(island.styleOpening ? (p.openMs || 400) : (p.closeMs || 240)));
        styleAnim.start();
    }
    function styleFinish() {
        island.styleWaiting = false;
        // primero la geometría (Morph siembra sus muelles leyendo `tlW/H/R`, aún válidos), después la línea
        island.styleGeom = false;
        island.styleRun = false;
        island.styleFxFrom = null;
    }
    onSurfaceSizeChanged: if (island.styleWaiting && island.surfaceSize !== null) {
        island.styleWaiting = false;
        island.styleGo();
    }
    // Off a mitad: se acaba en el sitio
    Connections {
        target: Motion
        function onOffChanged() { if (Motion.off && island.styleRun) { styleAnim.stop(); island.styleFinish(); } }
    }
    tlOn: island.styleGeom && island.styleFrame !== null && island.styleFrame.geom !== null
    tlW: island.styleFrame && island.styleFrame.geom
        ? (island.alongVertical ? island.styleFrame.geom.d : island.styleFrame.geom.a) : 0
    tlH: island.styleFrame && island.styleFrame.geom
        ? (island.alongVertical ? island.styleFrame.geom.a : island.styleFrame.geom.d) : 0
    tlR: island.styleFrame && island.styleFrame.geom ? island.styleFrame.geom.r : 0
    tlProgress: island.styleOpening ? island.styleV : 1 - island.styleV
    /**
     * Flap: la solapa gira desde el borde de la barra con perspectiva (un `Rotation` con eje, sin capa: los filetes, que
     * quedan fuera del Item, también giran). Lo añade Screen a la `transform` de la forma. El signo hace que el borde
     * lejano se acerque a quien mira (medido con tools/shape-open/qmltest.py).
     */
    readonly property Rotation styleRotation: Rotation {
        readonly property string e: island.attachEdge
        origin.x: e === "right" ? island.width : 0
        origin.y: e === "bottom" ? island.height : 0
        axis { x: (e === "left" || e === "right") ? 0 : 1; y: (e === "left" || e === "right") ? 1 : 0; z: 0 }
        angle: (e === "top" || e === "right") ? island.styleRot : -island.styleRot
    }

    /**
     * **Con qué se revela lo que entra**, y NO con `closeness` a pelo. Es el
     * mismo pestillo que `surfaces/Surface` ya tenía (`settled`) y que a las
     * cuatro caras del island les faltaba.
     *
     * `closeness` vuelve a 0 cada vez que se mueve el destino, y el destino se
     * mueve sin que haya transición ninguna: un aviso de privacidad que entra,
     * el visualizador que aparece al sonar música, la bandeja que gana un icono.
     * Revelar con `closeness` a pelo esconde entonces lo que YA estaba en
     * pantalla — y ahí empieza lo malo, porque una cara escondida **deja de
     * medir**: un positioner invisible congela su `implicitWidth` (comprobado
     * con una sonda de qml6 el 2026-09-16). Al volver mide otra cosa, el destino
     * se mueve otra vez, se vuelve a esconder, y el ciclo no para.
     *
     * Ese es el bug del 2026-09-16: **al poner música el reloj y el visualizador
     * desaparecían del todo** y el shell se quedaba clavado al 100 % de un
     * núcleo (medido: `qs` en R al 99,8 %, 1,6 GB de pico, el IPC sin
     * responder y la cápsula dibujada pero vacía). Hacen falta las dos cosas a
     * la vez para dispararlo: las barras de cava Y el aviso de micrófono que
     * enciende el visualizador de maly al reproducir. Juntas la cara rest pasa
     * de ~134 a ~179 px y cruza `Metrics.restW`, que es el único momento en que
     * el reposo cambia de tamaño.
     *
     * `travelling` lo enciende SÓLO un cambio de modo, que es lo único que de
     * verdad hay que relevar; un reajuste con el modo ya puesto no lo toca.
     */
    property bool travelling: false
    onClosenessChanged: if (island.closeness >= 0.999) island.travelling = false

    /* Con reduce motion la forma también se mueve (calmada), así que `closeness`
     * vuelve a ser un reloj válido y no hace falta un fundido aparte. */
    readonly property real reveal: island.travelling ? Motion.enter(island.closeness, island.fromPanel) : 1

    function surfaceNames() { return host.names(); }
    function hasSurface(name) { return host.has(Screens.canonical(name)); }
    function unloadClosed() { host.unloadClosed(); }
    /** QS-FUNC-004: la pila de navegacion y el volver, para el IPC. */
    function navStack() { return host.navStack; }
    function backSurface() { return host.back(); }
    /**
     * 7E-1: Esc en una vista abierta DESDE el Centro de control vuelve a él (spec: «Esc
     * retrocede un nivel local: ficha → lista → resumen»). Sólo ese contenedor: el resto
     * de superficies siguen cerrándose con Esc desde su raíz (DESIGN §3).
     * 9A: Settings también es contenedor — una surface abierta con un enlace suyo (Open
     * wallpaper list, System monitor) vuelve con Esc a la misma página de Settings.
     */
    function escapeToContainer() {
        const s = host.navStack;
        if (s.length === 0) return false;
        const from = s[s.length - 1];
        if (from !== "controlCenter" && Screens.familyOf(from) !== "settings") return false;
        host.goBack();
        return true;
    }
    /** Historial Back/Forward de esta pantalla (rediseño, fase 4; SurfaceHost §historial). */
    function historyBack() { return host.historyBack(); }
    /** Guarded: el host pregunta antes de salir (SurfaceHost §salida protegida). */
    function askLeave(target) { host.askLeave(target); }
    function surfaceHost() { return host; }
    function historyForward() { return host.historyForward(); }
    function historyDump() { return host.historyDump(); }
    function surfaceItem(name) { return host.item(name); }
    /** Seleccion de ficha de ESTA pantalla (SurfaceHost §`sel`). */
    function selectSurface(name, key) { host.select(name, key); }
    function surfaceSel(name) { return host.selOf(name); }
    function surfaceSelAll() { return host.sel; }

    /**
     * Navegación por teclado de la cara hover (Fase 10.h).
     *
     * Hasta 10.h la cara hover era solo-ratón: con el peek (`SUPER+CTRL+P`) se
     * veían los botones pero no se podían recorrer. Ahora, mientras el island
     * está en modo "hover" y sin superficie abierta, ←/→ mueven un cursor por
     * los botones, ⏎ activa y `Esc` cierra el peek (lo hace `Screen`). El
     * tooltip flotante que dibuja `Screen` sigue a este cursor — o al ratón.
     *
     * `navList` se recalcula con lo que de verdad se ve (media y updates
     * aparecen y desaparecen; notificaciones es fijo mientras haya servidor),
     * igual que el `shown` de `ActionGroup`. **Y va en el orden de los bloques
     * de la cara** (2026-09-15): si no, ←/→ recorrería la fila saltando.
     * La bandeja queda fuera: su recuento es dinámico y ya tiene navegación
     * propia por IPC (`enterTrayMenu`).
     */
    readonly property var navList: {
        const out = [];
        const add = (k, l) => out.push({ key: k, label: l });
        // buscar
        add("launcher", "App launcher");
        add("clipboard", "Clipboard history");
        add("emoji", "Emoji and symbols");
        add("web", "Web hub");
        add("minimizer", "Minimized windows");
        // medios
        add("wallpaper", "Wallpaper");
        add("theme", "Visual profile");
        add("recorder", ScreenRecorder.active ? "Screen recorder · " + ScreenRecorder.statusText : "Screen recorder");
        add("mixer", "Audio mixer");
        // sistema
        add("calendar", CalendarReminders.nextText.length > 0 ? "Calendar · " + CalendarReminders.nextText : "Calendar");
        add("system", "System monitor");
        // ADR-42: como en la barra, sin systemd no hay botón de servicios (era un botón muerto)
        if (Units.supported) add("services", "systemd services");
        add("cli", "sumi commands");
        // sesion
        add("awake", "Keep awake");
        add("settings", "Settings");
        add("dashboard", LiveActivity.workCount > 0 ? "Dashboard · " + LiveActivity.workText + " running" : "Dashboard");
        add("power", "Session power");
        // estado
        // F4 (2026-11-27, como la barra): el estado abre el Control Center; el clic derecho, su vista
        if (Bt.shown) add("bluetooth", "Control center · right-click: Bluetooth");
        if (Net.ready && Net.icon.length > 0) add("wifi", "Control center · right-click: Wi-Fi");
        if (island.notifAvailable) add("notifications", island.notifLabel);
        if (Updates.any) add("updates", Updates.risky ? "Updates · risky" : "Updates");
        return out;
    }

    /**
     * Aviso de notificaciones (ADR-29): del servidor propio, contando las NO
     * LEIDAS (decision del usuario). Hasta la Fase 4 (2026-09-22) el otro camino
     * era el cliente de SwayNC; se retiro con el resto de su integracion, asi
     * que sin el ajuste encendido no hay a quien preguntar y el aviso se calla.
     */
    readonly property bool notifOwn: Notifs.enabled
    readonly property int notifCount: island.notifOwn ? NotifHistory.unread : 0
    readonly property bool notifDnd: island.notifOwn && NotifHistory.dnd
    /** Hay a quien preguntar: solo el servidor propio. */
    readonly property bool notifAvailable: island.notifOwn
    /** Tooltip del boton de la cara hover. */
    readonly property string notifLabel: "Notifications"
        + (island.notifCount > 0 ? " · " + island.notifCount + " unread" : "")
        + (island.notifDnd ? " · Do not disturb" : "")
    function notifOpen() { island.requestSurface("notifications"); }
    function notifToggleDnd() { NotifHistory.toggleDnd(); }
    /** Clic central: Clear all también pide confirmación (7B): abre el centro con la pregunta. */
    function notifClearAll() {
        if (NotifHistory.count === 0) return;
        NotifHistory.clearWanted = true;
        island.requestSurface("notifications");
    }

    /** Cursor de teclado: −1 = ninguno (modo ratón, sin anillo). */
    property int navIdx: -1
    /** `navKey` del botón bajo el ratón, o "". */
    property string hoverKey: ""

    readonly property string navCurrentKey: (island.navIdx >= 0 && island.navIdx < island.navList.length)
        ? island.navList[island.navIdx].key : ""

    /** Lo que el tooltip debe decir: el foco de teclado manda sobre el ratón. */
    readonly property string tipKey: island.navCurrentKey.length > 0 ? island.navCurrentKey : island.hoverKey
    readonly property string tipText: {
        if (island.mode !== "hover" || island.tipKey.length === 0)
            return "";
        // Tooltips y vista previa, complementarios (después de la fase 9, decisión del usuario):
        // con «Open on hover» el RATÓN sobre un icono que abre una surface no lleva tooltip —
        // la vista previa ya dice qué es. Se quedan el teclado (el peek no abre vistas previas),
        // los iconos sin surface (Keep awake, Updates) y todo con el ajuste apagado.
        if (island.navCurrentKey.length === 0 && Settings.hoverPreview
                && island.tipKey !== "awake" && island.tipKey !== "updates")
            return "";
        for (let i = 0; i < island.navList.length; i++)
            if (island.navList[i].key === island.tipKey)
                return island.navList[i].label;
        return "";
    }

    /**
     * Hover preview (fase 4C). Con el puntero quieto `Motion.hoverOpenMs` sobre un icono
     * que ABRE una superficie, se pide su vista previa. Los que no abren nada (keep awake,
     * updates) no cuentan. Sólo con el ratón en la cara hover: el cursor de teclado del
     * peek no dispara nada, y con el ajuste apagado tampoco.
     */
    readonly property bool previewable: Settings.hoverPreview && island.mode === "hover"
        && island.hoverKey.length > 0 && island.hoverKey !== "awake" && island.hoverKey !== "updates"
        && island.navCurrentKey.length === 0
    onPreviewableChanged: if (island.previewable) previewTimer.restart(); else previewTimer.stop()
    onHoverKeyChanged: if (island.previewable) previewTimer.restart(); else previewTimer.stop()
    Timer {
        id: previewTimer
        interval: Motion.hoverOpenMs
        onTriggered: if (island.previewable) island.previewRequested(island.hoverKey)
    }

    /** Si lo visible cambia, re-acota el cursor (patrón de `ActionGroup`). */
    onNavListChanged: if (island.navIdx >= island.navList.length)
        island.navIdx = island.navList.length - 1;

    function keyPressed(event) {
        if (island.open.length > 0 && host.has(island.open)) {
            host.keyPressed(event);
            return;
        }
        if (island.mode !== "hover")
            return;
        island.navKeyPressed(event);
    }

    /** F9 (2026-11-27): las mismas teclas que la barra (`lib/nav-keys.js`). */
    function navKeyPressed(event) {
        const r = NavKeys.step(event.key, event.modifiers, island.navIdx, island.navList.length);
        if (!r.accepted)
            return;   // Escape cae sin aceptar: `Screen` cierra el peek.
        event.accepted = true;
        island.navIdx = r.idx;
        if (r.act === "activate") island.navActivate();
        else if (r.act === "secondary") island.navSecondary();
    }

    /** Shift+⏎ o Menú: lo del clic derecho (la vista propia del estado, el No molestar, la lista de updates). */
    function navSecondary() {
        const k = island.navCurrentKey;
        if (k === "bluetooth" || k === "wifi") { island.requestSurface(k); return; }
        if (k === "notifications") { island.notifToggleDnd(); return; }
        if (k === "updates") { Updates.list(); return; }
    }

    function navActivate() {
        const k = island.navCurrentKey;
        if (k.length === 0)
            return;
        if (k === "awake")   { Session.toggleKeepAwake(); return; }
        if (k === "notifications") { island.notifOpen(); return; }
        if (k === "updates") { Updates.update();          return; }
        // F4: el bloque de estado es la puerta del Control Center, con el ratón y con el teclado (como la barra)
        if (k === "bluetooth" || k === "wifi") { island.requestSurface("controlCenter"); return; }
        island.requestSurface(k);   // launcher · … · power
    }

    /** A button in the hover face: glyph, hover tint, click. */
    /**
     * El menu contextual de la bandeja lo dibuja Screen (components/TrayMenu),
     * no el island: tiene que poder salirse del island y de su mascara de
     * input. Aqui solo se avisa, con la posicion ya en coordenadas de ventana.
     */
    signal trayMenuRequested(var menuHandle, real cx, real bottom)

    /**
     * Del borde de abajo del island YA EXPANDIDO cuelga el menú de la bandeja (2026-11-12): con el
     * menú abierto el island pasa a su cara hover, y anclado a la cápsula en reposo la cara
     * crecía por encima del menú (lo tapaba 6–8 px, captura del usuario).
     */
    function trayMenuTop() {
        return island.mapToItem(null, 0, 0).y + Math.max(island.height, island.hoverH);
    }

    function requestTrayMenu(trayItem, anchorItem) {
        if (!trayItem || !trayItem.hasMenu) return false;
        const p = anchorItem.mapToItem(null, anchorItem.width / 2, 0);
        island.trayMenuRequested(trayItem.menu, p.x, island.trayMenuTop());
        return true;
    }

    /**
     * Abrir el menu del item `i` sin raton, anclado al propio island. Existe
     * porque el menu era la unica parte de la bandeja que no se podia probar
     * de otra forma: Hyprland no mueve el cursor. Lo usa el verbo IPC.
     */
    signal trayMenuCloseRequested()
    signal trayMenuEnterRequested(int index)
    signal trayMenuBackRequested()
    property var trayMenuDump: null

    function openTrayMenu(i) {
        if (i < 0) { island.trayMenuCloseRequested(); return true; }
        const list = Tray.items;
        if (i >= list.length) return false;
        const it = list[i];
        if (!it || !it.hasMenu) return false;
        const p = island.mapToItem(null, island.width / 2, 0);
        island.trayMenuRequested(it.menu, p.x, island.trayMenuTop());
        return true;
    }

    /** Un punto de privacidad: hueco fijo, se enciende con escala y fundido. */
    component PrivacyDot: Item {
        id: dot
        property bool on: false
        property color dotColor: "white"
        property string label: ""
        width: 8 * island.s
        height: 8 * island.s

        Rectangle {
            anchors.centerIn: parent
            width: parent.width
            height: parent.height
            radius: Metrics.pill(width)
            color: dot.dotColor
            opacity: dot.on ? 1 : 0
            scale: dot.on ? 1 : 0.4
            Behavior on opacity { NumberAnimation { duration: Motion.fast } }
            Behavior on scale { NumberAnimation { duration: Motion.fast; easing.type: Easing.OutBack } }
            Behavior on color { ColorAnimation { duration: Motion.fast } }
        }

        Accessible.role: Accessible.Indicator
        Accessible.name: dot.on ? dot.label : ""
    }

    /**
     * Un bloque de la cara hover. Agrupa lo que significa lo mismo y se realza
     * entero cuando el puntero entra: es lo que convierte una fila de 21 iconos
     * sueltos en cinco grupos que se leen de un vistazo.
     *
     * El realce lo lleva un `HoverHandler` y no un `MouseArea`: un área de ratón
     * aquí se tragaría los clics de los botones de dentro (pasó ya con el
     * `TapHandler` de la tarjeta de notificación, 2026-09-15).
     */
    component Cluster: Item {
        id: cl
        default property alias content: clRow.data
        property real gap: 7
        property real entryDelay: 0.12
        property bool statusGroup: false
        readonly property real padX: 6
        readonly property real padY: 4

        implicitWidth: clRow.implicitWidth + 2 * cl.padX * island.s
        /**
         * El alto SIGUE AL CONTENIDO, con un mínimo. Era `26 * s` fijo, y el
         * bloque del reloj (hora de 18 px sobre fecha de 9) mide **31 px**:
         * medido con una sonda de qml6 el 2026-09-16, el realce salía de 23 y le
         * cortaba 8 px por el medio, así que al pasar por encima no se veía una
         * pastilla envolviendo la hora sino una barra cruzándola. Los bloques de
         * iconos miden menos que el mínimo y no cambian.
         */
        implicitHeight: Math.max(26 * island.s, clRow.implicitHeight + 2 * cl.padY * island.s)
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        opacity: Motion.stagger(hoverFace.progress, cl.entryDelay)

        InteractionPlate {
            anchors.fill: parent
            visible: clRow.implicitWidth > 0
            s: island.s
            radius: cl.statusGroup ? Metrics.pill(height) : Metrics.rSm * island.s
            rest: cl.statusGroup ? Theme.tileBg : "transparent"
            rim: cl.statusGroup ? Theme.hair : "transparent"
            hovered: clHover.hovered && !cl.statusGroup
        }

        HoverHandler { id: clHover; enabled: island.hovering }

        Row {
            id: clRow
            anchors.centerIn: parent
            spacing: cl.gap * island.s
        }
    }

    /** La regla fina que separa zonas. Entre bloques basta el aire. */
    component Rule: Rectangle {
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        width: Metrics.hair
        height: 20 * island.s
        color: Theme.hair
        opacity: Motion.stagger(hoverFace.progress, 0.16)
    }

    component IconButton: Item {
        id: btn
        property string glyph: ""
        property bool lit: false
        /** Numero pegado al glifo. Vacio = boton cuadrado de siempre. */
        property string badge: ""
        /** Color cuando `lit`, o cuando el boton quiere avisar de algo. */
        property color accent: Theme.primary
        /**
         * Clave en `island.navList` (Fase 10.h). Con ella el botón sabe cuándo
         * lo tiene el cursor de teclado y reporta el hover del ratón para el
         * tooltip. Vacía = fuera de la navegación (la bandeja).
         */
        property string navKey: ""
        readonly property bool navFocused: btn.navKey.length > 0
            && island.navCurrentKey === btn.navKey
        signal activated()
        signal secondary()
        signal middle()

        width: btn.badge.length > 0 ? btnRow.implicitWidth + 6 * island.s : 22 * island.s
        height: 22 * island.s

        readonly property bool warm: btnArea.containsMouse || btn.navFocused

        InteractionPlate {
            anchors.fill: parent
            anchors.margins: (btn.navFocused ? -3 : -1) * island.s
            s: island.s
            radius: Metrics.r(7) * island.s
            focused: btn.navFocused
            hovered: btnArea.containsMouse
            down: btnArea.pressed && btnArea.containsMouse
        }

        Row {
            id: btnRow
            anchors.centerIn: parent
            spacing: 3 * island.s

            Icon {
                id: btnIcon
                anchors.verticalCenter: parent.verticalCenter
                name: btn.glyph
                size: 15 * island.s
                /**
                 * El glifo lleva SU color (`components/Icon.tint`). El realce ya no
                 * cambia de tono —eso borraba la identidad del icono justo al
                 * mirarlo— sino de intensidad; y `lit`, que es «esta superficie
                 * está abierta», sigue mandando con el acento.
                 */
                color: btn.lit ? btn.accent : btnIcon.tint
                opacity: (btn.lit || btn.warm) ? 1 : 0.82
                Behavior on opacity { NumberAnimation { duration: Motion.fast } }
                Behavior on color { ColorAnimation { duration: Motion.fast } }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: btn.badge.length > 0
                text: btn.badge
                color: btn.lit ? btn.accent : (btn.warm ? Theme.fg : Theme.fgVariant)
                font.family: Typography.ui
                font.pixelSize: Typography.label * island.s
                font.weight: Font.DemiBold
                font.features: ({ "tnum": 1 })
                Behavior on color { ColorAnimation { duration: Motion.fast } }
            }
        }

        MouseArea {
            id: btnArea
            anchors.fill: parent
            anchors.margins: -3 * island.s
            hoverEnabled: true
            enabled: island.hovering
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
            cursorShape: Qt.PointingHandCursor
            onEntered: if (btn.navKey.length > 0) island.hoverKey = btn.navKey;
            onExited: if (island.hoverKey === btn.navKey) island.hoverKey = "";
            onClicked: function (mouse) {
                if (mouse.button === Qt.RightButton) btn.secondary();
                else if (mouse.button === Qt.MiddleButton) btn.middle();
                else btn.activated();
            }
        }
    }

    /**
     * Estilos de forma (ADR-40): el halo del acento (Bloom, Unfold, Power-on), detrás de la forma; el relleno y la
     * sombra de la solapa van encima (`styleOverlay`: en el vidrio suelto un Rectangle con sus esquinas, unida o hecha
     * muesca un trazado más de `contour`). Sólo existen mientras el estilo los pide.
     */
    RectangularShadow {
        anchors.fill: parent
        visible: island.styleGlow > 0.01 && island.width > 0.5 && island.height > 0.5
        radius: Math.min(island.radius, width / 2, height / 2)
        blur: 16 * island.s
        spread: 1 * island.s
        color: Theme.primary
        opacity: 0.7 * island.styleGlow
    }
    readonly property color styleOverlay: island.styleTint > 0.001 ? Qt.alpha(Theme.primary, 0.9 * island.styleTint)
        : island.styleShade > 0.001 ? Qt.rgba(0, 0, 0, island.styleShade) : "transparent"

    Glass {
        id: body
        anchors.fill: parent
        radius: island.radius
        // las dos esquinas del lado pegado (arriba con la barra arriba; las de abajo con ella abajo; un costado)
        readonly property real joinedR: island.radius * (1 - Math.max(0, Math.min(1, island.attachment)))
        readonly property var joined: BarEdge.joinedCorners(island.attachEdge)
        topLeftRadius: body.joined.tl ? body.joinedR : island.radius
        topRightRadius: body.joined.tr ? body.joinedR : island.radius
        bottomLeftRadius: body.joined.bl ? body.joinedR : island.radius
        bottomRightRadius: body.joined.br ? body.joinedR : island.radius
        // colgando, el filo lo pinta `contour` sin el tramo de arriba, y sin velo: el mismo
        // tono que la barra de la que sale
        border.width: island.attached ? 0 : 1
        veil: !island.attached
        s: island.s
        /** Theme → Material → Surfaces: la superficie abierta trae su material; en reposo, el global. */
        surface: Theme.surfaceKey(island.open)
        // al pasar de una superficie a otra (o a reposo) el tono no salta; con Off, `fast` es 0
        Behavior on color { ColorAnimation { duration: Motion.fast } }
        // unida a la barra o hecha muesca la pinta `contour`, en un solo trazado: aquí sólo la suelta
        opacity: (island.swapHidden || island.edgeJoin > 0.001 || island.notchBody) ? 0 : 1
        /** La sombra re-renderiza su FBO por fotograma: fuera mientras se mueve. */
        // colgando es parte de la barra: sin sombra propia, que asomaba por los hombros translúcidos
        shadowed: !island.morphing && !island.hidden && !island.attached
    }
    Rectangle {
        anchors.fill: parent
        visible: body.opacity > 0 && island.styleOverlay.a > 0.001
        color: island.styleOverlay
        topLeftRadius: body.topLeftRadius
        topRightRadius: body.topRightRadius
        bottomLeftRadius: body.bottomLeftRadius
        bottomRightRadius: body.bottomRightRadius
        antialiasing: true
    }

    /**
     * EL CONTORNO UNIDO (2026-10-28, pedido del usuario con un vídeo de referencia: el panel tiene que
     * leerse como una prolongación de la barra). Colgando de ella o hecha muesca, la forma es UN solo
     * trazado: dos filetes cóncavos que la funden con el borde, los laterales y las esquinas de abajo,
     * con el relleno y el filo juntos. Antes eran cuatro piezas que se tocaban (vidrio, filo recortado,
     * dos hombros y la muesca): con la forma moviéndose en x fraccionaria, los bordes suavizados de dos
     * piezas translúcidas contiguas dejaban un hilo en cada costura.
     *
     * Como en la referencia, cada filete conserva su largo sobre la barra (`fx`) y su alto crece con la
     * forma (`fy`, nunca más de medio alto): nace como un bulto en el borde y se alarga desde él. Las
     * esquinas de arriba pasan de convexas (suelta) a filete (unida) con `edgeJoin`, sin salto: en 0 el
     * trazado es el del vidrio, que entonces la releva (`body`). El filo no cruza la unión. Sólo pinta:
     * la máscara de entrada sigue siendo la forma.
     */
    Shape {
        id: contour
        anchors.fill: parent
        visible: (island.edgeJoin > 0.001 || island.notchBody) && !island.swapHidden
        preferredRendererType: Shape.CurveRenderer
        readonly property real e: island.edgeJoin
        /*
         * Hecha muesca, un faldón largo y suave contra el borde de la pantalla (`Metrics.notchFlare*`,
         * 2026-11-12); colgando de la barra, el filete del tamaño de una esquina de panel (`barShoulder`,
         * un cuarto de círculo). Sin muesca la semilla es el collar viejo (`notchShoulder`): el relevo
         * island → barra no cambia. `k` es el largo de los tiradores (0,5523 = círculo).
         */
        readonly property real att: Math.max(0, Math.min(1, island.attachment))
        readonly property real seedW: Metrics.notchShoulder + (Metrics.notchFlareW - Metrics.notchShoulder) * island.dockLift
        readonly property real seedH: Metrics.notchShoulder + (Metrics.notchFlareH - Metrics.notchShoulder) * island.dockLift
        readonly property real seedK: 0.5523 + (Metrics.notchFlareK - 0.5523) * island.dockLift
        readonly property real fw: (contour.seedW + (Metrics.barShoulder - contour.seedW) * contour.att) * island.s
        readonly property real fh: (contour.seedH + (Metrics.barShoulder - contour.seedH) * contour.att) * island.s
        readonly property real fk: contour.seedK + (0.5523 - contour.seedK) * contour.att
        /** A lo largo del lado pegado y hacia dentro (en vertical, alto y ancho). */
        readonly property real alongW: BarEdge.alongOf(island.attachEdge, island.width, island.height)
        readonly property real depthH: BarEdge.depthOf(island.attachEdge, island.width, island.height)
        /*
         * Con el cajón (2026-11-19, elegido por el autor entre tres al verlo): los filetes crecen enteros, con su forma,
         * durante todo el deslizamiento y llegan a su tamaño con el panel (al cerrar, se recogen a la vez). Antes nacían
         * con su largo completo en el primer fotograma y sólo crecía su alto: una cuña plana que salía de la nada.
         */
        readonly property real grow: {
            if (!island.drawer || !island.drawerSliding) return 1;
            const p = Math.min(1, contour.depthH / Math.max(1, island.drawerDepth));
            return p * p * (3 - 2 * p);
        }
        readonly property real fx: contour.fw * contour.e * contour.grow
        readonly property real fy: Math.min(contour.fh * contour.grow, contour.depthH / 2) * contour.e
        /** Vidrio o, con la barra-muesca, el cuerpo opaco de la muesca (`dockLift`). */
        readonly property color fill: Qt.tint(body.color, Qt.alpha(Theme.notchBg, island.dockLift))
        // la muesca no lleva filo
        readonly property color edge: Qt.alpha(body.edge, body.edge.a * (1 - island.dockLift))

        /**
         * El trazado, en SVG. Cada esquina de arriba va del tramo de arriba al lateral con una cúbica cuyos
         * puntos se interpolan entre el filete (unida) y la esquina convexa (suelta). `i` mete el filo medio
         * píxel para que su línea de 1 px caiga entera en una fila, como el borde de un `Rectangle`.
         */
        /*
         * 2026-11-19: en el marco canónico (lib/bar-edge.js: `u` a lo largo del lado pegado, `v` hacia dentro), con
         * `w`/`h` el largo y el fondo, y llevado al lado real con `BarEdge.mapper`. Pegada arriba es la identidad: el
         * trazado de siempre, número a número.
         */
        function outline(i, closed) {
            const w = contour.alongW, h = contour.depthH, r = island.radius, k = 0.5523, e = contour.e;
            const m = BarEdge.mapper(island.attachEdge, island.width, island.height);
            const rtx = Math.min(r * (1 - e), w / 2), rty = Math.min(r * (1 - e), h / 2);
            const bx = Math.min(r, w / 2), by = Math.min(r, h / 2);
            const L = i, R = w - i, B = h - i, T = i * (1 - e);
            const tx = rtx - contour.fx, sy = rty + contour.fy;
            // tiradores: los del filete (`fk`) más los de la esquina convexa que queda (círculo)
            const ax = contour.fk * contour.fx - k * rtx, ay = contour.fk * contour.fy + k * rty;
            return "M " + m(tx, T)
                + " C " + m(tx + ax, T) + " " + m(L, sy - ay) + " " + m(L, sy)
                + " L " + m(L, h - by)
                + " C " + m(L, h - by + k * by) + " " + m(bx - k * bx, B) + " " + m(bx, B)
                + " L " + m(w - bx, B)
                + " C " + m(w - bx + k * bx, B) + " " + m(R, h - by + k * by) + " " + m(R, h - by)
                + " L " + m(R, sy)
                + " C " + m(R, sy - ay) + " " + m(w - tx - ax, T) + " " + m(w - tx, T)
                + (closed ? " Z" : "");
        }

        ShapePath {
            strokeWidth: -1
            fillColor: contour.fill
            PathSvg { path: contour.outline(0, true) }
        }
        // estilos de forma: el relleno del acento o la sombra de la solapa, con el mismo trazado
        ShapePath {
            strokeWidth: -1
            fillColor: island.styleOverlay
            PathSvg { path: island.styleOverlay.a > 0.001 ? contour.outline(0, true) : "" }
        }
        ShapePath {
            strokeWidth: 1
            strokeColor: contour.edge
            fillColor: "transparent"
            capStyle: ShapePath.FlatCap
            PathSvg { path: contour.outline(0.5, false) }
        }
        // el tramo de arriba: con la forma suelta es su borde; unida, la costura con la barra, sin filo
        ShapePath {
            strokeWidth: 1
            strokeColor: Qt.alpha(contour.edge, contour.edge.a * (1 - contour.e))
            fillColor: "transparent"
            capStyle: ShapePath.FlatCap
            PathSvg {
                path: {
                    const rtx = Math.min(island.radius * (1 - contour.e), contour.alongW / 2);
                    const m = BarEdge.mapper(island.attachEdge, island.width, island.height);
                    return "M " + m(contour.alongW - rtx, 0.5) + " L " + m(rtx, 0.5);
                }
            }
        }
    }

    /**
     * Rest (rediseño del 2026-09-15, decisiones del usuario tras verlo; desde la
     * fase 8B-1 el visualizador de audio salió: lo sustituye la pieza de Música):
     *   · SÓLO el reloj, en el CENTRO EXACTO;
     *   · fuera los espacios de trabajo (siguen, clicables, en la cara hover), el
     *     título de lo que suena (lo dice la tarjeta de media) y los indicadores:
     *     notificaciones, actualizaciones, bandeja, bluetooth y wifi viven ahora
     *     sólo en la cara hover, que ya tenía sus botones. Con un contrapeso para
     *     centrar el reloj el island quedaba largo y medio vacío (captura del
     *     usuario), y eligió «indicadores sólo en hover»;
     *   · se quedan los avisos de PRIVACIDAD: son alarmas, no estado. Desde la 8B-1
     *     son puntos de color con hueco fijo a cada lado del reloj (ver `PrivacyDot`).
     *
     * SÓLO INDICADORES, a propósito: un MouseArea aquí es inalcanzable (acercar
     * el puntero pasa el island a hover). Los clics viven en la cara hover.
     */
    /**
     * Las dos caras viven recortadas a la cápsula.
     *
     * Un `Row` mide su `implicitWidth` completo desde el primer fotograma, y
     * las dos están centradas, así que mientras el island crece hacia `hoverW`
     * los extremos de la fila se dibujaban FUERA: medido con grim el
     * 2026-09-15, a 102 y 137 ms se veían los dots de workspace y los iconos de
     * notificaciones y bandeja flotando sobre el fondo, a los lados de una
     * cápsula que todavía no había llegado a su ancho.
     *
     * El recorte va en este envoltorio y no en `Morph`: el cuerpo y su sombra
     * (`layer.effect`) son hermanos suyos y tienen que poder pintar fuera.
     * Recortado, el contenido se revela DENTRO de la forma, que es lo que hace
     * que la cápsula parezca un objeto y no una fila de iconos con un fondo
     * detrás.
     */
    /**
     * Los gestos (ver `osdForce`). Antes que `faces`, así que DEBAJO: un hijo de las caras que atiende la rueda o el
     * clic medio se lo queda (la rueda de `TrayIcon`, el clic medio de los botones); los demás clics, el hover y la
     * rueda de lo que no la quiere pasan hasta aquí. Sin hover propio y sólo con el botón medio: el izquierdo y el
     * derecho siguen yendo a quien iban. Mientras se mantiene el OSD cubre la huella que tenía la forma.
     */
    MouseArea {
        id: gestures
        objectName: "islandGestures"
        readonly property real w: Math.max(island.width, island.gestureHoldW)
        readonly property real h: Math.max(island.height, island.gestureHoldH)
        x: (island.width - gestures.w) / 2
        y: 0
        width: gestures.w
        height: gestures.h
        enabled: island.gesturesOn
        hoverEnabled: false
        acceptedButtons: Settings.islandMiddleClick === "playpause" ? Qt.MiddleButton : Qt.NoButton
        onWheel: (w) => island.gestureWheel(w)
        onClicked: island.gestureMiddle()
    }

    Item {
        id: faces
        anchors.fill: parent
        clip: true
        opacity: island.swapHidden ? 0 : 1
        Behavior on opacity { enabled: !island.swapHidden; NumberAnimation { duration: Motion.fast } }

    Row {
        id: restFace
        anchors.centerIn: parent
        spacing: 12 * island.s
        /**
         * Entrando sigue a la geometria; saliendo, reloj propio (ADR-25) — y
         * desde el 2026-09-15 las dos caras **se relevan** en vez de cruzarse:
         * la que sale se va en `vanish` (110 ms) y la que entra no empieza a
         * verse hasta que la forma lleva `Motion.handoff` hecho (~80 ms). Antes
         * la de rest salia en 300 ms mientras la de hover ya estaba casi opaca:
         * medido con grim, **dos relojes a la vez durante 180 ms**, el de rest
         * flotando en el centro exacto encima de la fila de iconos.
         */
        property real vis: island.mode === "rest" ? 1 : 0
        // hacia un panel la cara se va DE GOLPE (2026-10-01): con 40 ms el reloj seguía dentro de la
        // forma que crecía (grim, +18…+38 ms); con la barra no hay cara y no pasaba. Entre caras
        // pequeñas (rest↔hover↔OSD) sigue el relevo corto.
        Behavior on vis { enabled: island.small; NumberAnimation { duration: Motion.snap; easing.type: Easing.OutCubic } }
        opacity: island.barMode ? 0 : (island.mode === "rest" ? island.reveal : restFace.vis)
        transform: Translate {
            y: Motion.still ? 0 : -3 * island.s * (1 - restFace.opacity)
        }
        /**
         * Visible por MODO, nunca por su propia opacidad: `visible: opacity > 0.01`
         * cierra un ciclo —opacidad → visible → layout → `implicitWidth` → ancho
         * destino → `closeness` → opacidad— porque un positioner invisible congela
         * su medida. Ver `reveal`.
         */
        visible: !island.barMode && (island.mode === "rest" || restFace.vis > 0.01)

        /**
         * FASE 8B-1: reloj con un punto de privacidad a cada lado. Los dos huecos
         * existen SIEMPRE, encendidos o no: así el reloj queda en el centro exacto sin
         * contrapeso y la cápsula no cambia de ancho cuando llega un aviso (que era lo
         * único que movía el reposo, y el origen del bug del 2026-09-16).
         *
         *   izquierda  rojo: se graba o comparte la pantalla
         *   derecha    verde: cámara (con o sin micro) · naranja: sólo micro
         *
         * Colores fijos y no de la paleta: son los de iOS, y su significado no puede
         * depender del fondo de pantalla. El cava ya no está aquí: la pieza de Música
         * lo sustituye en el reposo (sigue vivo para el lock).
         */
        PrivacyDot {
            anchors.verticalCenter: parent.verticalCenter
            on: Privacy.screenActive
            dotColor: Theme.privacyScreen
            label: "Screen is being recorded or shared"
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            // Minimal (notch): fuera del Row, que mide sólo los dos huecos de privacidad
            visible: !island.restMinimal
            text: Clock.time
            color: Theme.fg
            font.family: Typography.ui
            font.pixelSize: Typography.restTime * island.s
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
        }

        PrivacyDot {
            anchors.verticalCenter: parent.verticalCenter
            on: Privacy.cameraActive || Privacy.micActive
            dotColor: Privacy.cameraActive ? Theme.privacyCamera : Theme.privacyMic
            label: Privacy.cameraActive ? "Camera in use" : "Microphone in use"
        }
    }

    /**
     * Las orejas del notch (2026-11-17), a los dos lados del reposo, pegadas a los bordes de la forma: crecen con ella
     * y se van con la cara de reposo (misma opacidad). Su ancho es fijo y ya va en `restW`; no miden nada, así que
     * no pueden reabrir el bucle de medida de `reveal`. Con la actividad terminada se desvanecen (`vis`) mientras la
     * forma encoge, dibujando todavía la última (`earShown`).
     */
    Item {
        id: ears
        anchors.fill: parent
        property real vis: island.earActivity.length > 0 ? 1 : 0
        Behavior on vis { NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic } }
        opacity: ears.vis * restFace.opacity
        visible: island.earsOn && ears.opacity > 0.01

        NotchEar {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            side: "left"
            s: island.s
            activity: island.earShown
            info: LiveActivity.flashData
            live: ears.visible && island.mode === "rest"
        }
        NotchEar {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            side: "right"
            s: island.s
            activity: island.earShown
            info: LiveActivity.flashData
            live: ears.visible && island.mode === "rest"
        }
    }


    /**
     * La cara del OSD. Contenido de tamaño FIJO desde el primer fotograma: la
     * cápsula se mueve, la barra no, así que el nivel nunca se estira con la
     * transición (era ya el criterio de la cápsula vieja y sigue valiendo).
     */
    Item {
        id: osdFace
        /*
         * Su ancho, el de la cápsula del OSD, centrado (gestos, 2026-11-17): llenaba la forma, y al llegar desde la fila
         * hover (913 px, y ahora es el camino de la rueda) el carril se estiraba a todo lo ancho mientras la forma
         * encogía (película del banco). Desde el reposo no cambia nada a la vista: la forma crece y el recorte lo revela.
         */
        anchors.centerIn: parent
        // el cajón: pegada al borde lejano mientras entra o sale (`drawerShift`, 0 fuera de él)
        anchors.verticalCenterOffset: island.alongVertical ? 0 : island.drawerShift
        anchors.horizontalCenterOffset: island.alongVertical ? island.drawerShift : 0
        width: Metrics.osdW * island.s
        height: parent.height
        property real vis: island.mode === "osd" || (island.drawerHolding && island.drawerFrom === "osd") ? 1 : 0
        Behavior on vis { enabled: island.small; NumberAnimation { duration: Motion.snap; easing.type: Easing.OutCubic } }
        opacity: (island.mode === "osd" ? (island.drawerPhase ? 1 : island.reveal) : osdFace.vis) * island.styleFaceOp
        visible: island.mode === "osd" || osdFace.vis > 0.01

        Icon {
            id: osdGlyph
            anchors.left: parent.left
            anchors.leftMargin: Metrics.sp4 * island.s
            anchors.verticalCenter: parent.verticalCenter
            size: 15 * island.s
            color: island.osdOff ? Theme.outline : Theme.fgVariant
            name: island.osdGlyph
        }

        Text {
            id: osdPct
            anchors.right: parent.right
            anchors.rightMargin: Metrics.sp4 * island.s
            anchors.verticalCenter: parent.verticalCenter
            // sin número el carril ocupa su sitio (no un hueco a la derecha)
            width: text.length > 0 ? 32 * island.s : 0
            horizontalAlignment: Text.AlignRight
            // 9C-2: el número se puede ocultar; «off» es un estado y se queda
            text: island.osdOff ? "off" : Settings.osdShowValue ? Math.round(island.osdLevel * 100) + "%" : ""
            color: island.osdOff ? Theme.outlineText : Theme.fg
            font.family: Typography.ui
            font.pixelSize: Typography.label * island.s
            font.weight: Typography.wStrong
            font.features: { "tnum": 1 }
        }

        ProgressTrack {
            anchors.left: osdGlyph.right
            anchors.leftMargin: Metrics.sp3 * island.s
            anchors.right: osdPct.left
            anchors.rightMargin: Metrics.sp3 * island.s
            anchors.verticalCenter: parent.verticalCenter
            height: 4 * island.s
            // fase 3C (ADR-42): la pista común, que en Terminal se dibuja en celdas; la fracción lleva la animación
            s: island.s
            trackColor: Qt.alpha(Theme.fg, 0.13)
            tint: island.osdOff ? Theme.outline : island.osdAccent
            value: island.osdLevel
            Behavior on value { NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic } }
        }
    }

    /**
     * La cara del aviso. Mismo alto que el reposo, como el OSD: **el island no
     * crece hacia abajo para hablar**, sólo se ensancha, y por eso se lee como
     * la misma pieza diciendo algo.
     *
     * El tono es el del sistema de estados (`Theme.ok/warn/danger/info`), el
     * mismo que usa `components/Notice` dentro de las superficies: enterarse por
     * el island y entenderlo en el panel son el mismo lenguaje.
     */
    Row {
        id: noticeFace
        anchors.centerIn: parent
        anchors.verticalCenterOffset: island.alongVertical ? 0 : island.drawerShift
        anchors.horizontalCenterOffset: island.alongVertical ? island.drawerShift : 0
        spacing: Metrics.sp2 * island.s
        property real vis: island.mode === "notice" || (island.drawerHolding && island.drawerFrom === "notice") ? 1 : 0
        Behavior on vis { enabled: island.small; NumberAnimation { duration: Motion.snap; easing.type: Easing.OutCubic } }
        opacity: (island.mode === "notice" ? (island.drawerPhase ? 1 : island.reveal) : noticeFace.vis) * island.styleFaceOp
        visible: island.mode === "notice" || noticeFace.vis > 0.01

        readonly property color tint: island.noticeTone === "ok" ? Theme.ok
            : island.noticeTone === "warn" ? Theme.warn
            : island.noticeTone === "info" ? Theme.info
            : Theme.danger

        Icon {
            anchors.verticalCenter: parent.verticalCenter
            name: island.noticeGlyph
            size: 14 * island.s
            color: noticeFace.tint
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            // lo que cabe en la cápsula (notifW): sin ancho, `elide` no actuaba y un aviso largo se salía
            // por los dos lados (14F: «Network test: Authorization was cancelled · nothing changed»)
            width: Math.min(implicitWidth, Metrics.notifW * island.s - 2 * Metrics.facePad * island.s
                                            - 14 * island.s - Metrics.sp2 * island.s)
            text: island.noticeText
            color: Theme.fg
            elide: Text.ElideRight
            font.family: Typography.ui
            font.pixelSize: Typography.label * island.s
            font.weight: Typography.wMedium
        }
    }

    /**
     * Hover: espacios de trabajo, reloj con fecha, los botones de las
     * superficies, los indicadores, la bandeja y la batería.
     *
     * ESTA CARA SI CRECE, y es deliberado. Son dos presupuestos distintos:
     *
     *   rest   presupuesto FIJO. Es lo que esta siempre delante, asi que cada
     *          pixel se pelea: un aviso sin nada que avisar mide 0 (ADR-16) y
     *          `hyprland/window` se descarto por costar 308 px permanentes.
     *   hover  presupuesto ABIERTO. Solo existe mientras el raton esta encima,
     *          y es la via de integracion por raton: cada superficie nueva
     *          gana aqui su boton. Que crezca es la funcion, no un descuido.
     *
     * Corolario practico: al anadir una superficie, el boton va SIEMPRE aqui;
     * el indicador en `rest` solo si hay algo de lo que enterarse.
     *
     * ── BLOQUES, 2026-09-15 ────────────────────────────────────────────────
     *
     * Eran 21 iconos monocromos en una fila de 762 px con tres reglas sueltas:
     * indiferenciados, y la única forma de saber qué era cada uno era el
     * tooltip, uno por uno. Ahora van en grupos con nombre —y el orden dice
     * algo: **a la izquierda dónde estás, en medio lo que haces, a la derecha
     * lo que pasa**.
     *
     *   espacio   los workspaces: dónde estás
     *   tiempo    hora y fecha
     *   buscar    lanzador · portapapeles · web · ventanas  (escribe y encuentra)
     *   medios    fondo · tema · grabador · audio            (lo que se ve y se oye)
     *   sistema   calendario · sensores · servicios · CLI
     *   sesión    café · ajustes · panel · apagar
     *   estado    bluetooth · red · avisos · bandeja · batería
     *
     * Bluetooth y red se mudaron de en medio al bloque de estado: son cosas de
     * las que enterarse, no botones que se pulsen a diario, y estaban partiendo
     * la fila de acciones en dos. Siguen abriendo su superficie al pulsarlas.
     *
     * El cursor de teclado (`navList`) sigue este mismo orden: si no, ←/→
     * saltaría por la fila en un orden que no es el que se ve.
     */
    Row {
        id: hoverFace
        anchors.centerIn: parent
        spacing: Metrics.sp3 * island.s
        /**
         * Igual que la cara rest (ADR-25) y con el mismo relevo: sale en
         * `Motion.snap` y entra sólo cuando la forma lleva `Motion.handoff`
         * hecho, así que nunca se cruza con lo que se va.
         */
        // Al salir, parte de lo que ya se veía, también si el puntero se fue a mitad de la entrada.
        property real progress: island.hovering ? island.reveal : 0
        Behavior on progress {
            enabled: !island.hovering && island.small
            NumberAnimation { duration: Motion.snap; easing.type: Easing.OutCubic }
        }
        /**
         * Visible por MODO, nunca por su propia opacidad: `visible: opacity > 0.01`
         * cierra un ciclo —opacidad → visible → layout → `implicitWidth` → ancho
         * destino → `closeness` → opacidad— porque un positioner invisible congela
         * su medida. Ver `reveal`.
         */
        visible: island.hovering || hoverFace.progress > 0.01

        Cluster {
            entryDelay: 0.26
            Workspaces {
                anchors.verticalCenter: parent.verticalCenter
                screenName: island.screenName
                s: island.s
                interactive: island.hovering
            }
        }

        Rule {}

        Cluster {
            entryDelay: 0
            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1 * island.s
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Clock.time
                    color: Theme.fg
                    font.family: Typography.ui
                    font.pixelSize: Typography.hoverTime * island.s
                    font.weight: Typography.wStrong
                    font.features: { "tnum": 1 }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    // F10: con el tiempo activado, la temperatura junto a la fecha (como en la barra)
                    text: Clock.date + (Weather.shortTemp.length > 0 ? " · " + Weather.shortTemp : "")
                    color: Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.micro * island.s
                    font.weight: Typography.wMedium
                    font.capitalization: Font.AllUppercase
                    font.letterSpacing: Typography.tracking * island.s
                }
                /**
                 * F7 (2026-11-27): la hora abre Calendar, como el reloj de la barra. Manejadores y no un MouseArea:
                 * dentro de un Column, un Item más sería otra fila.
                 */
                HoverHandler {
                    enabled: island.hovering
                    cursorShape: Qt.PointingHandCursor
                    // como el botón Calendar: su tooltip (con el próximo evento) o su vista previa
                    onHoveredChanged: {
                        if (hovered) island.hoverKey = "calendar";
                        else if (island.hoverKey === "calendar") island.hoverKey = "";
                    }
                }
                TapHandler {
                    objectName: "hoverClock"
                    enabled: island.hovering
                    acceptedButtons: Qt.LeftButton
                    onTapped: island.requestSurface("calendar")
                }
            }
        }

        Rule {}

        /** Escribe y encuentra: aplicación, recorte, sitio, ventana. */
        Cluster {
            entryDelay: 0.19
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: "search"
                navKey: "launcher"
                lit: island.open === "launcher"
                onActivated: island.requestSurface("launcher")
            }
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: "clipboard"
                navKey: "clipboard"
                lit: island.open === "clipboard"
                onActivated: island.requestSurface("clipboard")
            }
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: "emoji"
                navKey: "emoji"
                lit: island.open === "emoji"
                onActivated: island.requestSurface("emoji")
            }
            /**
             * El hub web lleva el globo y no la lupa porque la lupa ya es del
             * lanzador, y no el logo de un navegador concreto porque el
             * navegador lo decide el usuario (`apps.browser`, F3c), no el shell.
             */
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: "web"
                navKey: "web"
                lit: island.open === "web"
                onActivated: island.requestSurface("web")
            }
            /** NO es un ALT+TAB: minimiza y restaura por `special:minimized`. */
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: "window"
                navKey: "minimizer"
                lit: island.open === "minimizer"
                onActivated: island.requestSurface("minimizer")
            }
        }

        /** Lo que se ve y lo que se oye. El tema va junto al fondo: matugen deriva uno del otro. */
        Cluster {
            entryDelay: 0.08
            // 9E-1: Media y Mixer son una sola vista: un solo botón (el del Mixer, más abajo)
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: "wallpaper"
                navKey: "wallpaper"
                lit: island.open === "wallpaper"
                onActivated: island.requestSurface("wallpaper")
            }
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: "palette"
                navKey: "theme"
                lit: island.open === "theme"
                onActivated: island.requestSurface("theme")
            }
            /** El grabador (2026-10-29), hermano del fondo; en rojo mientras graba. */
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: "recorder"
                navKey: "recorder"
                lit: island.open === "recorder" || ScreenRecorder.active
                accent: ScreenRecorder.active && island.open !== "recorder" ? Theme.dangerText : Theme.primary
                onActivated: island.requestSurface("recorder")
            }
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                // Deslizadores, no altavoz: el altavoz es el NIVEL (el OSD ya lo usa)
                // y aquí el botón abre la mesa. Mudo sí sigue siendo el altavoz
                // tachado: eso es una alarma, y las alarmas van rellenas.
                glyph: Audio.muted ? "volume-off" : "mixer"
                navKey: "mixer"
                lit: island.open === "mixer"
                onActivated: island.requestSurface("mixer")
            }
        }

        /** La máquina: qué día es, cómo va, qué corre, y la CLI. */
        Cluster {
            entryDelay: 0.04
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: "calendar"
                navKey: "calendar"
                lit: island.open === "calendar"
                onActivated: island.requestSurface("calendar")
            }
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: "gauge"
                navKey: "system"
                lit: island.open === "system"
                onActivated: island.requestSurface("system")
            }
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                visible: Units.supported
                glyph: "server"
                navKey: "services"
                lit: island.open === "services"
                onActivated: island.requestSurface("services")
            }
            /** Teclear el nombre de un verbo y ⏎; no reimplementa ninguno (ADR-13). */
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: "terminal"
                navKey: "cli"
                lit: island.open === "cli"
                onActivated: island.requestSurface("cli")
            }
        }

        /** La sesión. `power` va el último de todo el bloque: es lo que peor sienta pulsar sin querer. */
        Cluster {
            entryDelay: 0.17
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: "awake"
                navKey: "awake"
                lit: Session.keepAwakeEffective
                onActivated: Session.toggleKeepAwake()
            }
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: "cog"
                navKey: "settings"
                // Settings UI (2026-11-07): la ventana flotante de esta pantalla
                lit: Screens.familyOf(island.open) === "settings"
                    || (SettingsUi.open && SettingsUi.screen === island.screenName)
                onActivated: island.requestSurface("settings")
            }
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: "info"
                navKey: "dashboard"
                // F10: con trabajo en curso (Tasks, descargas), el número, como la campana
                badge: LiveActivity.workCount > 0 ? String(LiveActivity.workCount) : ""
                lit: island.open === "dashboard" || LiveActivity.workCount > 0
                onActivated: island.requestSurface("dashboard")
            }
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: "power"
                navKey: "power"
                lit: island.open === "power"
                onActivated: island.requestSurface("power")
            }
        }

        Rule {}

        /**
         * Estado: lo que hay que enterarse de que pasa. Bluetooth y red son
         * botones desde 9.f.2 y 9.f.3 —abren su superficie— pero viven aquí y
         * no entre las acciones porque lo que hacen la mayor parte del tiempo
         * es informar. Aquí sí va la cifra (`{signalStrength}%` de Waybar y el
         * `󰂱 N` del script de bluetooth): el presupuesto de esta cara es abierto.
         */
        Cluster {
            statusGroup: true
            entryDelay: 0.26
            gap: Metrics.sp2

            Item {
                id: btBtn
                anchors.verticalCenter: parent.verticalCenter
                width: btAviso.implicitWidth
                height: btAviso.implicitHeight
                visible: Bt.shown
                readonly property bool navFocused: island.navCurrentKey === "bluetooth"

                InteractionPlate {
                    anchors.fill: parent
                    anchors.margins: (btBtn.navFocused ? -4 : -2) * island.s
                    s: island.s
                    radius: Metrics.rXs * island.s
                    focused: btBtn.navFocused
                    hovered: btArea.containsMouse
                    down: btArea.pressed && btArea.containsMouse
                }

                Aviso {
                    id: btAviso
                    anchors.centerIn: parent
                    s: island.s
                    active: Bt.shown
                    icon: Bt.icon
                    label: Bt.badge
                    tint: (island.open === "bluetooth" || island.open === "controlCenter") ? Theme.primary
                        : Bt.lowBattery ? Theme.danger
                        : (Bt.connectedCount > 0) ? Theme.primary
                        : ((btArea.containsMouse || btBtn.navFocused) ? Theme.fg : Theme.fgVariant)
                }

                MouseArea {
                    id: btArea
                    anchors.fill: parent
                    anchors.margins: -4 * island.s
                    hoverEnabled: true
                    enabled: island.hovering
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onEntered: island.hoverKey = "bluetooth"
                    onExited: if (island.hoverKey === "bluetooth") island.hoverKey = "";
                    onClicked: (mouse) => island.requestSurface(mouse.button === Qt.RightButton ? "bluetooth" : "controlCenter")
                }
            }

            Item {
                id: netBtn
                anchors.verticalCenter: parent.verticalCenter
                width: netAviso.implicitWidth
                height: netAviso.implicitHeight
                visible: Net.ready && Net.icon.length > 0
                readonly property bool navFocused: island.navCurrentKey === "wifi"

                InteractionPlate {
                    anchors.fill: parent
                    anchors.margins: (netBtn.navFocused ? -4 : -2) * island.s
                    s: island.s
                    radius: Metrics.rXs * island.s
                    focused: netBtn.navFocused
                    hovered: netArea.containsMouse
                    down: netArea.pressed && netArea.containsMouse
                }

                Aviso {
                    id: netAviso
                    anchors.centerIn: parent
                    s: island.s
                    active: Net.ready && Net.icon.length > 0
                    icon: Net.icon
                    label: Net.badge
                    // ADR-42: los colores de alarma son los de `Screens.netFace` (círculo y barra): limitada o
                    // conectando en naranja, sin red en rojo; el reposo y el hover siguen siendo de esta cara
                    tint: (island.open === "wifi" || island.open === "controlCenter") ? Theme.primary
                        : (Screens.netFace.tone === "warn" || Screens.netFace.tone === "off") ? Screens.netFace.color
                        : ((netArea.containsMouse || netBtn.navFocused) ? Theme.fg : Theme.fgVariant)
                }

                MouseArea {
                    id: netArea
                    anchors.fill: parent
                    anchors.margins: -4 * island.s
                    hoverEnabled: true
                    enabled: island.hovering
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onEntered: island.hoverKey = "wifi"
                    onExited: if (island.hoverKey === "wifi") island.hoverKey = "";
                    onClicked: (mouse) => island.requestSurface(mouse.button === Qt.RightButton ? "wifi" : "controlCenter")
                }
            }

            /*
             * Notificaciones: FIJO en la cara hover desde el 2026-09-15 (pedido
             * por el usuario): con el aviso a cero no habia con que abrir el
             * centro usando el raton. Clic abre el centro (o el panel de SwayNC),
             * derecho cambia el DND, central es Clear all.
             */
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                visible: island.notifAvailable
                glyph: island.notifDnd ? "bell-off" : "bell"
                navKey: "notifications"
                badge: island.notifCount > 0 ? String(island.notifCount) : ""
                lit: island.notifCount > 0 || island.notifDnd
                accent: island.notifDnd ? Theme.fgVariant : Theme.primary
                onActivated: island.notifOpen()
                onSecondary: island.notifToggleDnd()
                onMiddle: island.notifClearAll()
            }
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                visible: Updates.any
                glyph: Updates.failed ? "alert" : "update"
                navKey: "updates"
                badge: Updates.count > 0 ? String(Updates.count) : ""
                lit: true
                accent: (Updates.failed || Updates.risky || Updates.state === "critical")
                        ? Theme.danger : Theme.warn
                onActivated: Updates.update()
                onSecondary: Updates.list()
                onMiddle: Updates.recheck()
            }

            /*
             * La bandeja clicable. Izquierdo activa, central es la accion
             * secundaria, derecho abre el menu DBusMenu y la rueda hace scroll,
             * igual que el modulo `tray` de Waybar.
             */
            Repeater {
                model: Tray.items
                TrayIcon {
                    required property var modelData
                    anchors.verticalCenter: parent.verticalCenter
                    item: modelData
                    s: island.s
                    interactive: island.hovering
                    onMenuRequested: function (trayItem, anchorItem) {
                        island.requestTrayMenu(trayItem, anchorItem);
                    }
                }
            }

            /** La batería, en las máquinas que tienen una. F7: el clic abre su estado en Settings, como en la barra. */
            Text {
                objectName: "batteryIndicator"
                anchors.verticalCenter: parent.verticalCenter
                visible: Battery.present
                text: Battery.percent + "%"
                color: Battery.ink
                font.family: Typography.ui
                font.pixelSize: Typography.label * island.s
                font.weight: Typography.wStrong
                font.features: { "tnum": 1 }
                Accessible.name: Battery.description
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4 * island.s
                    enabled: island.hovering
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        const sc = Screens.resolve(island.screenName);
                        if (sc) sc.showSettings("system/power/batteryStatus", null);
                    }
                }
            }
        }
    }

    }   // fin del envoltorio recortado de las caras

    /*
     * Aquí iba el filo de progreso del reposo (la canción en el borde de abajo) y,
     * con él, la suscripción del island a la posición MPRIS. Retirados los dos el
     * 2026-09-16 a petición del usuario. La superficie de media sigue pidiendo la
     * posición por su cuenta al abrirse (`Media.subscribe` en `surfaces/Media`), y
     * en reposo ya no corre ningún temporizador por la música.
     */

    /**
     * 8G-1: EL OSD CON UN PANEL ABIERTO (futuredocksurface §OSD, ROADMAP «integrar OSD sin
     * tomar foco ni reemplazar una tarea»). Antes el panel mandaba y el OSD no se veía. Ahora
     * es una banda superpuesta arriba del panel: no cambia su geometría, no pide foco ni
     * recoge clics (no tiene manejadores: pasan al contenido), cada evento renueva la misma
     * (core/Osd) y al acabar queda el panel como estaba. También los avisos.
     *
     * Se calla si el panel ya enseña ese valor: volumen en el Mixer, Media y el Centro de
     * control; brillo en el Centro de control.
     */
    readonly property bool bandSuppressed: island.osdMode === "level"
        && ((island.osdKind === "brightness" && island.open === "controlCenter")
            || (island.osdKind !== "brightness" && ["mixer", "controlCenter"].indexOf(island.open) >= 0))
    readonly property bool bandShown: !island.small && island.osdMode !== "none" && !island.bandSuppressed

    SurfaceHost {
        id: host
        anchors.fill: parent
        s: island.s
        screenName: island.screenName
        open: island.open
        preview: island.preview
        // el cajón (2026-11-19): pegado al borde lejano del lado de la barra, y el contenido viaja visible
        drawer: island.drawerPhase
        farEdge: island.drawer ? island.attachEdge : "top"
        entryEdge: island.barMode ? island.attachEdge : "top"
        anchorContent: !Motion.off && (island.barMode ? ShapeOpen.anchorsContent("bar", Motion.barPanelStyle)
            : ShapeOpen.anchorsContent("island", Motion.islandStyle))
        contentOffset: island.styleRun && island.styleKind === "bar" && island.styleName === "ink"
            ? hOffsetSpring.value - island.hOffset : 0
        // Lo que queda de pantalla bajo el island, con 16 px de margen (fase 4, SurfaceFrame); con la barra en otro
        // borde, lo que deja ella (`roomH`/`roomW`, de Screen: encima de la de abajo, al lado de una lateral)
        maxH: island.roomH >= 0 ? Math.max(120 * island.s, island.roomH)
            : island.parent ? Math.max(120 * island.s, island.parent.height - island.availableTop - 16 * island.s) : 100000
        // 8C-2: centrada, con 16 px de margen a cada lado como mucho
        maxW: island.roomW >= 0 ? Math.max(240 * island.s, island.roomW)
            : island.parent ? Math.max(240 * island.s, island.parent.width - 32 * island.s) : 100000
        closeness: island.closeness
        // estilos de forma (ADR-40): la opacidad que pide el estilo y la capa de Ink/Mist sobre el contenido
        styleReveal: island.styleContent
        layer.enabled: island.styleLayer
        layer.effect: island.styleLayer ? contentFx : null
        onRequestClose: island.requestClose()
        onRequestSurface: (n) => island.requestSurface(n)
    }

    Component {
        id: contentFx
        ShapeRevealEffect {
            s: island.s
            masked: island.styleName === "ink"
            blurred: island.styleName === "mist"
            ink: island.styleFx && island.styleFx.ink >= 0 ? island.styleFx.ink : 1
            ring: island.styleFx ? island.styleFx.ring : 0
            blur: island.styleFx ? island.styleFx.blur : 0
            zoom: island.styleFx ? island.styleFx.zoom : 1
            // la gota: del acceso sobre el borde de la barra, o del centro de la píldora de la que salió
            readonly property real btnU: Math.max(0, Math.min(island.alongVertical ? height : width,
                (island.alongVertical ? height : width) / 2 + island.styleOriginOffset - island.hOffset))
            readonly property real restD: island.styleSnap && island.styleOpening ? island.styleSnap.d
                : island.styleLive.d
            readonly property var c0: island.barMode
                ? (island.attachEdge === "bottom" ? { x: btnU, y: height } : island.attachEdge === "left" ? { x: 0, y: btnU }
                   : island.attachEdge === "right" ? { x: width, y: btnU } : { x: btnU, y: 0 })
                : { x: width / 2, y: Math.min(height, restD / 2) }
            cx: c0.x
            cy: c0.y
            // lo que hace falta para cubrir el panel abierto desde ahí
            reach: {
                const a = island.styleLive.a, d = island.styleLive.d;
                if (!island.barMode) return Math.hypot(a / 2, Math.max(0, d - Math.min(d, restD / 2)));
                const u = Math.max(0, Math.min(a, island.styleBtn));
                return Math.max(Math.hypot(u, d), Math.hypot(a - u, d));
            }
        }
    }

    /**
     * Dónde va (ajuste «OSD over a panel», pedido por el usuario), siempre FUERA del panel
     * para no tapar lo que se mira (el reloj del Calendar, p. ej.):
     *
     *   sides  al lado, en vertical (derecha; izquierda si no cabe), por debajo de la franja
     *          de las piezas; un panel apaisado (≥ 2:1: Wallpaper, Media, Power) lo lleva debajo
     *   below  debajo, en horizontal
     *
     * Un aviso (texto) va debajo en los dos. Sin sitio debajo: al lado; un aviso, arriba.
     */
    /**
     * El último TIPO que se enseñó (nivel o aviso). No vuelve a «none» al acabar: si
     * `bandPlace` leyera `osdMode` directamente, al apagarse el OSD se recalculaba como aviso
     * («debajo») y, según el orden en que Qt evaluara los bindings, el congelado de abajo lo
     * recogía antes de soltarse: la banda se teletransportaba abajo y desaparecía ahí (lo vio
     * el usuario con Beside; en una captura tocó el orden bueno).
     */
    // Espacio de la pieza persistente bajo la forma; los avisos temporales van después.
    property real belowAccessoryH: 0
    property string bandKind: "level"
    /** Pruebas (IPC `osdState`): dónde está la banda, en px del island. */
    function bandBox() { return { x: Math.round(osdBand.x), y: Math.round(osdBand.y), w: Math.round(osdBand.width),
                                  h: Math.round(osdBand.height), o: Math.round(osdBand.opacity * 100) / 100 }; }
    onOsdModeChanged: if (island.osdMode !== "none") island.bandKind = island.osdMode
    readonly property string bandPlace: {
        const level = island.bandKind === "level";
        const pw = island.parent ? island.parent.width : 0;
        const ph = island.parent ? island.parent.height : 0;
        const roomBelow = island.y + island.targetH + island.belowAccessoryH + (8 + 30) * island.s < ph - 8 * island.s;
        const roomRight = island.x + (island.width + island.targetW) / 2 + (8 + 30) * island.s < pw - 8 * island.s;
        // 2026-11-19: nunca del lado de la barra (debajo con ella abajo; al costado que la toca con ella a un lado)
        const e = island.barMode ? island.attachEdge : "top";
        const side = e === "left" ? "right" : e === "right" ? "left" : (roomRight ? "right" : "left");
        const wide = island.targetW >= 2 * island.targetH;
        if (level && Settings.osdPlacement !== "below" && !wide) return side;
        if (e === "bottom") return island.y > (8 + 30 + 8) * island.s ? "above" : (level ? side : "top");
        if (roomBelow) return "below";
        return level ? side : "top";
    }
    /**
     * La posición se CONGELA mientras la banda se oculta: al acabar el OSD `osdMode` pasa a
     * «none», `bandPlace` se recalculaba como si fuera un aviso y la banda saltaba abajo justo
     * al desvanecerse (visto por el usuario).
     */
    property string bandPlaceKept: "below"
    Binding {
        target: island
        property: "bandPlaceKept"
        value: island.bandPlace
        when: island.bandShown
        restoreMode: Binding.RestoreNone
    }
    readonly property bool bandVertical: island.bandPlaceKept === "left" || island.bandPlaceKept === "right"

    Glass {
        id: osdBand
        z: 10
        s: island.s
        deep: true
        readonly property real gap: 8 * island.s
        width: island.bandVertical ? 30 * island.s
            : Math.min((island.bandPlaceKept === "top" ? island.width - 24 * island.s : island.width), 280 * island.s)
        height: island.bandVertical ? Math.min(180 * island.s, Math.max(90 * island.s, island.height - 60 * island.s))
            : 30 * island.s
        radius: Metrics.pill(Math.min(width, height))
        x: island.bandPlaceKept === "right" ? island.width + osdBand.gap
            : island.bandPlaceKept === "left" ? -osdBand.gap - osdBand.width
            : (island.width - osdBand.width) / 2
        // al lado, por debajo de la franja de las piezas laterales (que se apartan a esa altura)
        y: island.bandPlaceKept === "below" ? island.height + island.belowAccessoryH + osdBand.gap
            : island.bandPlaceKept === "above" ? -osdBand.gap - osdBand.height
            : island.bandVertical ? (Metrics.restH + 10) * island.s
            : 8 * island.s
        opacity: island.bandShown ? 1 : 0
        visible: opacity > 0.01
        // se va sola, sin forma que recoger detrás: un fundido suave (`standard`), no `vanish`
        Behavior on opacity { NumberAnimation { duration: island.bandShown ? Motion.fast : Motion.standard; easing.type: Easing.InOutQuad } }

        // ---- en horizontal (arriba o debajo) ----
        Icon {
            id: bandGlyph
            visible: !island.bandVertical
            anchors.left: parent.left
            anchors.leftMargin: 12 * island.s
            anchors.verticalCenter: parent.verticalCenter
            size: 14 * island.s
            name: island.bandKind === "notice" ? island.noticeGlyph : island.osdGlyph
            color: island.osdOff ? Theme.outline : Theme.fg
        }
        Text {
            id: bandPct
            anchors.right: parent.right
            anchors.rightMargin: 12 * island.s
            anchors.verticalCenter: parent.verticalCenter
            visible: !island.bandVertical && island.bandKind === "level"
            // 9C-2: el número se puede ocultar; «off» es un estado y se queda
            text: island.osdOff ? "off" : Settings.osdShowValue ? Math.round(island.osdLevel * 100) + "%" : ""
            color: island.osdOff ? Theme.outlineText : Theme.fg
            font.family: Typography.ui
            font.pixelSize: Typography.label * island.s
            font.weight: Typography.wStrong
            font.features: { "tnum": 1 }
        }
        ProgressTrack {
            anchors.left: bandGlyph.right
            anchors.leftMargin: 10 * island.s
            anchors.right: bandPct.left
            anchors.rightMargin: 10 * island.s
            anchors.verticalCenter: parent.verticalCenter
            visible: !island.bandVertical && island.bandKind === "level"
            height: 4 * island.s
            // fase 3C (ADR-42): la pista común (celdas en Terminal)
            s: island.s
            trackColor: Qt.alpha(Theme.fg, 0.13)
            tint: island.osdOff ? Theme.outline : island.osdAccent
            value: island.osdLevel
            Behavior on value { NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic } }
        }
        Text {
            anchors.left: bandGlyph.right
            anchors.leftMargin: 8 * island.s
            anchors.right: parent.right
            anchors.rightMargin: 12 * island.s
            anchors.verticalCenter: parent.verticalCenter
            visible: !island.bandVertical && island.bandKind === "notice"
            elide: Text.ElideRight
            text: island.noticeText
            color: Theme.fg
            font.family: Typography.ui
            font.pixelSize: Typography.label * island.s
        }

        // ---- en vertical (al lado): % arriba, carril que se llena hacia arriba, glifo abajo ----
        Text {
            id: vPct
            visible: island.bandVertical
            anchors.top: parent.top
            anchors.topMargin: 10 * island.s
            anchors.horizontalCenter: parent.horizontalCenter
            text: island.osdOff ? "off" : Settings.osdShowValue ? String(Math.round(island.osdLevel * 100)) : ""
            color: island.osdOff ? Theme.outlineText : Theme.fg
            font.family: Typography.ui
            font.pixelSize: Typography.caption * island.s
            font.weight: Typography.wStrong
            font.features: { "tnum": 1 }
        }
        Icon {
            id: vGlyph
            visible: island.bandVertical
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 9 * island.s
            anchors.horizontalCenter: parent.horizontalCenter
            size: 13 * island.s
            name: island.osdGlyph
            color: island.osdOff ? Theme.outline : Theme.fg
        }
        Rectangle {
            visible: island.bandVertical
            anchors.top: vPct.bottom
            anchors.topMargin: 8 * island.s
            anchors.bottom: vGlyph.top
            anchors.bottomMargin: 8 * island.s
            anchors.horizontalCenter: parent.horizontalCenter
            width: 4 * island.s
            radius: Metrics.pill(width)
            color: Qt.alpha(Theme.fg, 0.13)
            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                radius: parent.radius
                height: parent.height * Math.max(0, Math.min(1, island.osdLevel))
                color: island.osdOff ? Theme.outline : island.osdAccent
                Behavior on height { NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic } }
            }
        }

        Accessible.role: Accessible.StatusBar
        Accessible.name: island.osdMode === "notice" ? island.noticeText
            : (island.osdKind === "brightness" ? "Brightness " : "Volume ") + Math.round(island.osdLevel * 100) + "%"
    }
}
