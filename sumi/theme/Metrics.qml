pragma Singleton
import QtQuick
import Quickshell
import "../services"

/** Geometry tokens in logical pixels at scale 1; callers multiply by `s`. */
Singleton {
    /**
     * ESCALA DE ESPACIO Y RADIO (2026-09-15).
     *
     * Hasta ahora cada superficie elegía los suyos: contados en el árbol,
     * espaciados literales de 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14 y 16, y
     * radios de 3, 5, 6, 7, 8, 9, 10, 12, 14 y 16. Catorce valores para decir
     * «un poco de aire» es lo que hace que un conjunto de paneles se lea como
     * componentes sueltos y no como un entorno.
     *
     * Estos no sustituyen a los anchos de superficie de más abajo (esos son
     * medidas de una pieza concreta); son el vocabulario para el aire interior.
     */
    /*
     * Regla para código nuevo (fase 3D de coherencia, ADR-42, decisión del autor): márgenes, huecos y rellenos con
     * esta escala (`Metrics.spN * s`), no con cifras sueltas. Las superficies ya aprobadas a la vista conservan las
     * suyas; no se migran en bloque.
     */
    readonly property real sp1: 4      // dentro de un grupo pegado
    readonly property real sp2: 8      // entre elementos de una fila
    readonly property real sp3: 12     // entre grupos
    readonly property real sp4: 16     // entre bloques
    readonly property real sp5: 24     // entre secciones
    readonly property real sp6: 32     // aire de respiro

    /*
     * Los radios son del estilo de interfaz (theme/Style, ADR-34): en soft, 5 · 8 · 12 · 16 de siempre; en terminal, 0.
     */
    readonly property real rXs: Style.now.rXs   // realces de una palabra
    readonly property real rSm: Style.now.rSm   // filas, tiles
    readonly property real rMd: Style.now.rMd   // tarjetas
    readonly property real rLg: Style.now.rLg   // paneles y popups
    readonly property real rPill: 999  // cápsulas
    /**
     * Radio de una cápsula de control de alto `h` (ya escalado): `h / 2` en soft, la esquina del estilo en terminal.
     * Sólo para cápsulas (pistas, pastillas, interruptores); un círculo de verdad (avatar, punto de estado) no la usa.
     */
    function pill(h) { return Style.now.pill ? h / 2 : Style.now.pillR; }
    /**
     * Un radio que todavía es una cifra suelta (6, 7, 9, 10…: los que no caen en la escala de arriba). Igual que antes en
     * soft; lo que el estilo diga en los demás (terminal: `Style.squareR`, nunca 0 en caliente). Sirve para pasar el árbol
     * a tokens sin mover un píxel.
     */
    function r(n) { return n > 0 ? Math.max(Style.squareR, n * Style.now.cornerScale) : 0; }

    /** Grosor de las reglas finas. Siempre 1 px físico, nunca escalado. */
    readonly property real hair: 1
    /**
     * Anillo de foco (DESIGN §5). 1,5 px lógicos: con 1 px se confundía con el
     * borde del vidrio, que ya es de 1 px. Separado del control por `focusGap`
     * para que no se lea como un borde propio del botón.
     */
    readonly property real focusWidth: 1.5
    readonly property real focusGap: 2
    /**
     * Tamaños de glifo por papel (fase 3C de coherencia, ADR-42), en px lógicos a escala 1: `glyphSm` el mini botón de
     * un pie o una cabecera, `glyphMd` el botón de glifo y el indicador, `glyphLg` el de un estado vacío. Para lo nuevo;
     * los literales de la barra y la isla (ya aprobados a la vista) se quedan.
     */
    readonly property real glyphSm: 12
    readonly property real glyphMd: 16
    readonly property real glyphLg: 20
    /** Objetivo mínimo de clic (DESIGN §5, «al menos 32 × 32»). */
    readonly property real hitMin: 32

    /**
     * Ancho de DISEÑO del reposo: lo usan quien necesita una cifra antes de medir (la
     * barra al desplegarse, el Lock). El island real mide su contenido (`restPad`).
     */
    readonly property real restW: 160
    /**
     * Aire de la cápsula en reposo a cada lado de los puntos de privacidad (2026-10-01,
     * pedido del usuario: «elimina el espacio muerto a los lados»). Antes `facePad` (20) y un
     * mínimo de `restW`, que dejaban ~37 px vacíos a cada lado. Su contenido ya no cambia de
     * ancho (los dos huecos existen siempre), así que medirlo no hace bailar la cápsula.
     */
    readonly property real restPad: 13
    readonly property real restH: 38
    /** Alto de la Hover Bar persistente (8C-1). */
    readonly property real barH: 40
    /**
     * Hueco entre la barra y una surface que cuelga de ella (8C-1). SIN USO desde el 2026-10-01:
     * la forma cuelga pegada a la barra (`Island.attached`). Se queda por si se vuelve atrás.
     */
    readonly property real barGap: 8
    readonly property real hoverH: 58
    readonly property real facePad: 20
    readonly property real restCorner: Style.now.restCorner
    /**
     * Esquinas inferiores del dock en reposo y en OSD (8F-1). 12 → 18 el 2026-10-01 (pedido
     * del usuario, «redondea más las curvas del notch»): casi medio alto, la muesca se lee
     * como una gota colgando del borde y no como una pestaña.
     */
    /**
     * Settings → Notch → Corners (2026-11-17): Rounded (el de siempre), Soft (2/3) o Tight (1/3) del radio del estilo.
     * Con Terminal el radio ya es «recto» (`Style.squareR`) y así se queda.
     */
    readonly property real notchCornerScale: Settings.notchCorners === "soft" ? 2 / 3 : Settings.notchCorners === "tight" ? 1 / 3 : 1
    readonly property real notchCorner: Style.now.notchCorner * notchCornerScale
    /**
     * Las uniones de la muesca con el borde de arriba (2026-11-12, pedido del usuario: «que parezca una
     * extensión continua de la barra y no un elemento colgado»). Eran un collar cóncavo de 8 × 8, un cuarto
     * de círculo. Ahora un faldón más largo sobre el borde que por el lateral (`notchFlareW` × `notchFlareH`)
     * y con los tiradores largos (`notchFlareK`; 0,5523 es el círculo): la curva entra en el borde y en el
     * lateral casi recta, sin la arista de curvatura del cuarto de círculo, y la muesca se lee como el borde
     * de la pantalla que se ensancha hacia abajo. Las mismas para el island-muesca y la barra-muesca.
     * `notchShoulder` (el collar viejo) sigue siendo la semilla del filete cuando la forma se une a la barra
     * sin muesca: ese relevo no cambia.
     */
    readonly property real notchShoulder: Style.now.notchShoulder
    /** Settings → Notch → Flare (2026-11-17): Long (el de siempre), Short (0,6) o None (sin faldón: cae recto del borde). */
    readonly property real notchFlareScale: Settings.notchFlare === "short" ? 0.6 : Settings.notchFlare === "none" ? 0 : 1
    readonly property real notchFlareW: Style.now.notchFlareW * notchFlareScale
    readonly property real notchFlareH: Style.now.notchFlareH * notchFlareScale
    readonly property real notchFlareK: 0.78
    /**
     * Filete cóncavo de lo que cuelga de la barra (2026-10-28, vídeo de referencia del usuario): del
     * tamaño de la esquina de un panel abierto (`openCorner`), así la unión se lee como la misma curva
     * que sus esquinas y no como un remate. Era 12 fijo en `Island`.
     */
    readonly property real barShoulder: Style.now.barShoulder
    /**
     * Las piezas laterales con el dock (2026-10-01, pedido del usuario): las mismas del
     * island, más pequeñas. Con un panel abierto manda `sideCompact`, que es menor.
     */
    readonly property real dockSide: 0.76
    readonly property real openCorner: Style.now.openCorner
    readonly property real topGap: 8
    /** Aire entre la cápsula en reposo y cada pieza lateral (8B-1, New-DynamicIsland). */
    readonly property real sideGap: 10
    /** Tamaño de las piezas laterales con un panel abierto (8B-2, decisión del usuario). */
    readonly property real sideCompact: 0.7
    /**
     * Tamaño de las piezas laterales en reposo (2026-11-12, pedido del usuario): menores que la
     * cápsula, para que el centro sea la isla. Antes medían lo mismo que ella (`restH`).
     */
    readonly property real sideRest: 0.8
    readonly property real appGap: 12
    readonly property real revealW: 420
    readonly property real revealH: 10
    /** 8D: alto de la franja de detección con pantalla completa, en px FÍSICOS (sin escalar). */
    readonly property real fsStripH: 3
    /**
     * 11A-1: familia Consulta (DESIGN §5, 640–960) y alto FIJO, el mismo para Overview,
     * Performance y Tasks: cambiar de pestaña no deforma el panel. Antes 460 y alto por contenido.
     * Etapa C (2026-11-10): Tasks es una ventana y Overview ya no tiene pliegue ni lista de actividad: más bajo,
     * medido en el banco para que el Overview quepa sin scroll con tres asuntos y «N more».
     */
    readonly property real dashboardW: 720
    readonly property real dashboardH: 440
    /**
     * Settings UI independiente (2026-11-07): ya no es una superficie del island (antes 880×560 fijo,
     * familia Configuración 9A) sino una tarjeta flotante como el monitor (`core/SettingsLayer`).
     * Tamaño inicial; se recorta al monitor y la esquina lo cambia (sólo en la sesión). Por debajo
     * del mínimo no se encoge: más pequeño ya no cabe una fila con su control.
     * `settingsUiHeadH`: la franja de arriba que arrastra la tarjeta.
     */
    readonly property real settingsUiW: 1180
    readonly property real settingsUiH: 780
    readonly property real settingsUiMinW: 560
    readonly property real settingsUiMinH: 420
    readonly property real settingsUiHeadH: 54
    /** Por debajo, la barra lateral se pliega en un desplegable; por encima, aparece el panel contextual. */
    readonly property real settingsCompactW: 740
    readonly property real settingsContextW: 1060
    readonly property real settingsSideW: 212
    readonly property real settingsAsideW: 290
    /**
     * System Monitor compacto (antes de la fase 12, M4): seis tarjetas en 2×3 con destinos
     * fijos debajo; las tarjetas se desplazan si el monitor o el texto lo requieren. Era 880×640 en la 11E-2, cuando la surface también inspeccionaba.
     */
    readonly property real systemW: 800
    readonly property real systemH: 660
    readonly property real calendarW: 360   // Today glance; month and agenda live in Calendar UI.
    /**
     * Mixer apaisado (2026-11-09, pedido del usuario; referencia: la tira de Wallpaper): el reproductor a
     * la izquierda (`mixerPlayerW`) y la mezcla a la derecha. Antes 560 en una columna. El host acota el
     * ancho a la pantalla; por debajo de `mixerWideMin` vuelve a una columna. La mezcla hace scroll por
     * encima de `mixerMaxH` (Applications desplegado con muchos flujos).
     */
    readonly property real mixerW: 920
    readonly property real mixerPlayerW: 400
    readonly property real mixerWideMin: 720
    readonly property real mixerMaxH: 520
    readonly property real controlCenterW: 440   // Ancho base con los interruptores y el estado de conexión.
    readonly property real wiredW: 520
    // Speed test (2026-11-14): mismo ancho que la ficha del cable; el alto lo da su contenido (aviso reservado).
    readonly property real speedtestW: 520
    readonly property real wifiW: 480
    /** Fixed target: readable two-line rows without changing height as discovery grows. */
    // 500: caben seis filas enteras (60 + 4 de paso) bajo la cabecera, con el pie de estado
    readonly property real wifiH: 500
    readonly property real wifiDetailH: 216
    readonly property real radioDetailW: 760   // Information and action columns; lists keep their own width.
    readonly property real btW: 480
    readonly property real authW: 420
    /** Match Wi-Fi list rhythm; discovery never changes the target height. */
    readonly property real btH: 500   // como wifiH: seis filas enteras
    readonly property real clipW: 520
    readonly property real clipH: 360
    /** Selector de emojis (2026-11-17): 12 columnas de emoji a escala 1; Kaomoji, 3. */
    readonly property real emojiW: 540
    readonly property real emojiH: 420
    readonly property real powerW: 440
    readonly property real powerConfirmW: 300
    readonly property real webW: 460
    readonly property real webH: 330
    readonly property real launcherW: 500
    readonly property real launcherH: 500
    readonly property real minimizerW: 460
    readonly property real minimizerH: 360
    // 11F-1: pestañas User | System y etiqueta de tipo por fila (antes 460×384)
    readonly property real servicesW: 520
    readonly property real servicesH: 460
    readonly property real serviceDetailW: 460
    readonly property real serviceJournalW: 480
    readonly property real serviceJournalH: 380
    /** 12B: Visual Profiles es un carrusel (familia Consulta, como la tira de Wallpaper). */
    readonly property real themeW: 720
    readonly property real themeH: 272
    readonly property real cliW: 520
    readonly property real cliH: 520
    readonly property real mediaW: 440
    readonly property real mediaH: 132
    readonly property real osdW: 248
    /** Popups de notificacion (ADR-29): el ancho y el margen de SwayNC (NOTIFICACIONES §8). */
    readonly property real notifW: 360
    readonly property real notifMargin: 20
    /** El centro (Fase 2): altura fija, la lista hace scroll. */
    readonly property real notifCenterW: 520
    readonly property real notifCenterH: 600
    readonly property real osdH: 44
    readonly property real wallpaperW: 840
    // Búsqueda, filtros y carrusel con separación propia entre bloques.
    readonly property real wallpaperH: 260
    /**
     * El grabador de pantalla (2026-10-29), hermano de la tira de Wallpaper: la misma familia Consulta
     * con estado arriba, opciones, tarjetas y ayuda; más estrecho (dos o tres tarjetas, no once).
     */
    readonly property real recorderW: 720
    readonly property real recorderH: 300      // Estado, opciones y tarjetas en filas separadas.
    /** Tarjetas del grabador: enfocada primero (ancho, alto, brillo), como `slotW/H/Bright` de la tira. */
    readonly property var recCardW: [176, 150]
    readonly property var recCardH: [104, 88]
    readonly property var recCardBright: [1, 0.62]
    /** La pieza de grabación bajo el island: alto y aire hasta la forma. */
    readonly property real recPillH: 30
    readonly property real recPillGap: 6
    /**
     * La tienda de Wallhaven (antes de la fase 11): ventana flotante de la familia Consulta
     * (DESIGN §5, 640–960 de ancho). Se recorta a la pantalla menos `storeMargin` por lado; ése es
     * también el borde que el arrastre no deja cruzar.
     */
    readonly property real storeW: 920
    readonly property real storeH: 640
    readonly property real storeMargin: 16
    /** La cabecera por la que se arrastra. */
    readonly property real storeHeadH: 44
    /**
     * La UI de inspección de System Monitor (antes de la fase 12): ventana flotante como la tienda,
     * con su margen y su cabecera de arrastre. Más ancha que la familia Consulta (960) a propósito:
     * `Antes-de-fase-12.md` le pide más espacio que la surface (880); se recorta a la pantalla.
     */
    readonly property real monW: 1040
    readonly property real monH: 700
    readonly property real monSideW: 164
    /**
     * La capa Tasks (etapa B del Dashboard, 2026-11-09): ventana flotante como System Monitor, de la
     * familia Consulta (DESIGN §5, 640–960): catálogo a la izquierda, consola a la derecha.
     */
    readonly property real tasksW: 920
    readonly property real tasksH: 600
    /**
     * La Audio UI (antes de la fase 14): la misma familia que la UI del monitor, algo más baja. El
     * ecualizador pide anchura (el pedido: «no forzar un instrumento horizontal en una columna
     * estrecha»): con la barra lateral quedan ~780 px para las once barras y la curva.
     */
    readonly property real audioW: 1000
    readonly property real audioH: 660
    readonly property real audioSideW: 164

    /** Wallpaper strip slots, focused first: width, height, centre offset, dimming. */
    readonly property var slotW:      [196, 126, 104, 88, 74]
    readonly property var slotH:      [110, 71, 59, 50, 42]
    readonly property var slotCX:     [0, 168, 284, 382, 468]
    readonly property var slotBright: [1, 0.56, 0.42, 0.30, 0.22]

    /**
     * Pantalla de bloqueo: el alto del campo (ADR-30; lo usa `LockField`). El resto de las medidas de la
     * composición de ADR-30 se retiró en la fase 15H con ella.
     */
    readonly property real lockCapsuleH: 44

    /**
     * El panel del rediseño (fase 15, rediseno/docs/futurelocksurface.md §8, §10): tres
     * columnas con ancho acotado. Los mínimos deciden cuándo pasa a la versión estrecha
     * (autenticación fija arriba y widgets con scroll, LOCK-D18); todo × `uiScale`.
     */
    readonly property real lockBoardMaxW: 1120
    readonly property real lockBoardH: 580
    readonly property real lockBoardPad: 24
    readonly property real lockColLeft: 300
    readonly property real lockColCenter: 380
    readonly property real lockColRight: 320
    /** Mínimos: por debajo de su suma el panel pasa a la versión estrecha. */
    readonly property real lockColLeftMin: 270
    readonly property real lockColCenterMin: 340
    readonly property real lockColRightMin: 290
    readonly property real lockBoardAvatar: 104
    readonly property real lockFieldW: 340
    readonly property real lockNarrowW: 520
    readonly property real lockMargin: 32

    /** Height of the reserved band: resting face + top gap + air under it. */
    function reservedH(s) { return (restH + topGap + appGap) * s; }
    /** Zona reservada con la barra persistente: su alto, no el del island (8C-1). */
    function reservedBarH(s) { return (barH + topGap + appGap) * s; }
    /** Con el dock: pegado al borde, sin `topGap` (8F-1). */
    function reservedDockH(s) { return (restH + appGap) * s; }
    /** La barra con el dock (2026-10-01): la misma muesca, pegada al borde, sin `topGap`. */
    function reservedBarDockH(s) { return (barH + appGap) * s; }
}
