.pragma library
/*
 * El catálogo de ajustes del shell (rediseño, fase 3; rediseno/docs/futureSettingssurface.md §9-11).
 *
 * UNA sola tabla de ids, tipos, defaults, rangos, dueño y política de aplicación. De aquí
 * salen los defaults (no se repiten en QML), la validación, la migración desde el JSON
 * plano de antes y el documento que se escribe. `services/Settings` es el único que lo
 * usa para escribir; las superficies leen `Settings.<prop>` como siempre.
 *
 * Se puede cargar en node para probarlo (`module.exports` al final) — en QML esa rama
 * no existe y no hace nada.
 */

/**
 * v3 (portabilidad F3a, 2026-10-05): `apps.*` (terminal y navegador, «auto» = detectar) y la
 * frecuencia esperada de las tareas por id (`shell.dashboard.taskEveryDays`), que sustituye a
 * `dotbackupEveryDays`/`diskbackupEveryDays`. `upgrade()` lleva un v2 a v3; Settings lo hace al
 * leer el archivo, con copia previa.
 */
/**
 * v4 (portabilidad F4a, 2026-10-07): `providers.*` elige el proveedor de fondos, tema, miniaturas y
 * actualizaciones (enums cerrados; con `script`, la orden la declara `providers.json`, nunca este archivo)
 * y `theme.desktopSync` dice si la shell toca el claro/oscuro del escritorio (gsettings). Una
 * configuración nueva: todo `auto` y `desktopSync = off`. Al migrar, se respetan los proveedores
 * ya declarados en `providers.json` y las preferencias explícitas del usuario.
 */
var VERSION = 4;

/**
 * Cada entrada:
 *   id      ruta estable en el JSON anidado
 *   prop    la propiedad de `Settings` que lo expone (compatibilidad con los consumidores)
 *   legacy  la clave del JSON plano v1 (XDG_STATE_HOME), si la tenía
 *   type    real | int | bool | enum | string | path | paths | monitors | location | command | taskEvery
 *           | surfaceMaterials
 *   def     default compilado
 *   min/max rango (real, int); values: los permitidos (enum, y int con lista cerrada)
 *   section sección de la página Shell que lo muestra ("" = sin fila todavía)
 *   owner   quién es dueño del dato (siempre "shell" aquí: lo de otros servicios no entra)
 *   apply   immediate | restart (sólo se lee al arrancar)
 *   preset  appearance | layout | motion — 12D: entra en los presets, en UN solo grupo. Sin
 *           él, el ajuste no es presetable (la lista blanca de futureSettingssurface §12:
 *           nada de rutas, dispositivos, secretos ni integraciones).
 *   export  false — 12E: NO sale en «Export settings» ni se acepta al importar (sesión,
 *           integraciones, monitores, cuenta, ubicación, imágenes privadas del lock).
 *   local   true — 12E: se exporta, pero es una ruta de ESTA máquina: al importar se comprueba
 *           y, si falta, queda «Missing on this machine» sin invalidar el resto.
 */
var CATALOG = [
    { id: "shell.interface.scale", prop: "uiScale", legacy: "uiScale", type: "real",
      def: 1.0, min: 0.8, max: 1.5, section: "General", owner: "shell", apply: "immediate", preset: "layout" },
    { id: "shell.interface.density", prop: "density", type: "enum",
      def: "default", values: ["comfortable", "default", "compact"], section: "", owner: "shell", apply: "immediate" },
    { id: "shell.interface.autoHide", prop: "autoHide", legacy: "autoHide", type: "bool",
      def: false, section: "General", owner: "shell", apply: "immediate" },
    { id: "shell.interface.reserveSpace", prop: "reserveSpace", legacy: "reserveSpace", type: "bool",
      def: false, section: "General", owner: "shell", apply: "immediate" },
    /**
     * Hover preview (fase 4C; DESIGN §2): el puntero sobre un icono de la cara hover abre
     * su panel TEMPORAL, sin teclado; un clic o su atajo lo fijan. Ajuste pedido por el
     * usuario para poder apagarlo; por defecto, lo que decidió el diseño.
     */
    { id: "shell.interface.hoverPreview", prop: "hoverPreview", type: "bool",
      def: true, section: "Interaction", owner: "shell", apply: "immediate" },
    /**
     * 8G-1 (pedido por el usuario): dónde va el OSD cuando hay un panel abierto, siempre
     * FUERA para no tapar lo que se mira. «sides»: al lado, salvo en paneles apaisados
     * (Wallpaper, Media, Power), que lo llevan debajo; «below»: siempre debajo. La primera
     * versión tenía «outside»/«top» (la banda arriba): el usuario pidió estas dos. El
     * almacén escribe TODOS los campos, así que «outside» ya estaba en su archivo: `aliases`.
     */
    { id: "shell.interface.osdPlacement", prop: "osdPlacement", type: "enum",
      def: "sides", values: ["sides", "below"], aliases: { outside: "sides", top: "below" },
      section: "OSD", owner: "shell", apply: "immediate", preset: "layout" },
    /**
     * 2026-11-12 (pedido del usuario): las piezas redondas a los lados del island y de la muesca
     * (Música a la izquierda, Red a la derecha) se pueden quitar, cada una por su lado. Ausente en
     * un archivo anterior → visibles, sin migración.
     */
    { id: "shell.island.musicCircle", prop: "islandMusicCircle", type: "bool",
      def: true, section: "Island", owner: "shell", apply: "immediate" },
    { id: "shell.island.networkCircle", prop: "islandNetCircle", type: "bool",
      def: true, section: "Island", owner: "shell", apply: "immediate" },
    /**
     * Gestos sobre la island y el notch (2026-11-17, parte 3 del notch en vivo): la rueda (volumen) y el clic medio
     * (reproducir/pausar). No en la barra, que tiene su rueda. Sin brillo: la capa no ve el Shift (sin foco de
     * teclado). Encendidos de serie; ausente en un archivo anterior → serie, sin migración.
     */
    { id: "shell.island.wheel", prop: "islandWheel", type: "enum",
      def: "volume", values: ["volume", "off"], section: "Island", owner: "shell", apply: "immediate" },
    { id: "shell.island.middleClick", prop: "islandMiddleClick", type: "enum",
      def: "playpause", values: ["playpause", "off"], section: "Island", owner: "shell", apply: "immediate" },
    /**
     * Notch en vivo (2026-11-17, pedido del usuario: «darle el mismo cariño al modo notch»). Forma y color de la muesca
     * (island-muesca y barra-muesca a la vez) y sus actividades en vivo (orejas). De serie, todo como antes: radio 18,
     * faldón largo, el tono de la paleta y el reloj en reposo; las actividades, encendidas. Ausente → serie, sin migración.
     */
    { id: "shell.notch.rest", prop: "notchRest", type: "enum",
      def: "clock", values: ["clock", "minimal"], section: "Notch", owner: "shell", apply: "immediate" },
    { id: "shell.notch.color", prop: "notchColor", type: "enum",
      def: "theme", values: ["theme", "black"], section: "Notch", owner: "shell", apply: "immediate" },
    { id: "shell.notch.corners", prop: "notchCorners", type: "enum",
      def: "rounded", values: ["rounded", "soft", "tight"], section: "Notch", owner: "shell", apply: "immediate" },
    { id: "shell.notch.flare", prop: "notchFlare", type: "enum",
      def: "long", values: ["long", "short", "none"], section: "Notch", owner: "shell", apply: "immediate" },
    /**
     * Las ondas de la oreja de música (2026-11-17): cava a esos fps (sin el aviso de privacidad: su nodo va marcado) o 0 =
     * ondas sintéticas. Clave nueva: la vieja `shell.island.visualizerFps` (15H) sigue sin leerse.
     */
    { id: "shell.notch.visualizerFps", prop: "notchVisualizerFps", type: "int",
      def: 30, min: 0, max: 60, section: "NotchActivities", owner: "shell", apply: "immediate" },
    { id: "shell.notch.activity.music", prop: "notchActMusic", type: "bool",
      def: true, section: "NotchActivities", owner: "shell", apply: "immediate" },
    { id: "shell.notch.activity.recording", prop: "notchActRecording", type: "bool",
      def: true, section: "NotchActivities", owner: "shell", apply: "immediate" },
    { id: "shell.notch.activity.speed", prop: "notchActSpeed", type: "bool",
      def: true, section: "NotchActivities", owner: "shell", apply: "immediate" },
    { id: "shell.notch.activity.power", prop: "notchActPower", type: "bool",
      def: true, section: "NotchActivities", owner: "shell", apply: "immediate" },
    { id: "shell.notch.activity.copy", prop: "notchActCopy", type: "bool",
      def: true, section: "NotchActivities", owner: "shell", apply: "immediate" },
    { id: "shell.notch.activity.bluetooth", prop: "notchActBluetooth", type: "bool",
      def: true, section: "NotchActivities", owner: "shell", apply: "immediate" },
    { id: "shell.notch.activity.workspace", prop: "notchActWorkspace", type: "bool",
      def: true, section: "NotchActivities", owner: "shell", apply: "immediate" },
    { id: "shell.interface.workspaceIndicators", prop: "workspaceCount", legacy: "workspaceCount", type: "int",
      def: 5, min: 0, max: 10, section: "General", owner: "shell", apply: "immediate", preset: "layout" },
    { id: "shell.animations.mode", prop: "motionMode", legacy: "reduceMotion", type: "enum",
      def: "normal", values: ["normal", "reduced", "off"], section: "Animations", subsection: "Motion", owner: "shell", apply: "immediate", preset: "motion" },
    /**
     * 9C-1 (futureSettingssurface §5 Animations): **Global speed**, un solo valor persistido
     * (el «Duration multiplier» de Advanced sería otra vista de éste, no otro campo). >1 =
     * más rápido: las duraciones se dividen por él y los muelles suben su ω hasta el tope
     * estable del integrador de Qt (theme/Motion). No toca esperas de interacción ni
     * confirmaciones ni el Lock.
     */
    { id: "shell.animations.speed", prop: "motionSpeed", type: "real",
      def: 1.0, min: 0.75, max: 1.5, section: "Animations", subsection: "Motion", owner: "shell", apply: "immediate", preset: "motion" },
    /**
     * 2026-11-11: estilo de las ventanas flotantes (theme/Motion `windowStyles`, theme/Reveal): Minimalist (sutil,
     * ~180 ms) o Expressive (más visible, ~260 ms). 2026-11-17 (ADR-36): seis más con línea de tiempo (Power-on, Bloom,
     * Mochi, Ink, Scroll, Mist), en Soft y Terminal, y todos valen con Normal y Reduced; Off no lo usa. Ausente en un
     * archivo anterior → `minimalist`, sin migración.
     */
    { id: "shell.animations.windowStyle", prop: "windowStyle", type: "enum",
      def: "minimalist", values: ["minimalist", "expressive", "poweron", "bloom", "mochi", "ink", "scroll", "mist"], section: "Animations", subsection: "Window style", owner: "shell", apply: "immediate",
      preset: "motion" },
    /**
     * 2026-11-19: cómo salen los paneles de la barra permanente. Slide (de serie): el cajón, el panel ya a su tamaño
     * desliza desde debajo de la barra; Grow: lo de antes, la forma crece desde el punto bajo el acceso. Sin barra no
     * cuenta (island y muesca no cambian). Ausente en un archivo anterior → `slide`, sin migración.
     * 2026-11-21 (ADR-40): seis más con línea de tiempo (Spring, Unfold, Flap, Bloom, Ink, Mist; lib/shape-open.js),
     * todos sobre el cajón salvo Grow.
     */
    { id: "shell.animations.barPanels", prop: "barPanels", type: "enum",
      def: "slide", values: ["slide", "grow", "spring", "unfold", "flap", "bloom", "ink", "mist"], section: "Animations", subsection: "Bar panels",
      owner: "shell", apply: "immediate", preset: "motion" },
    /**
     * 2026-11-21 (ADR-40): cómo se abre la forma sin la barra, en la island y en el notch (un solo ajuste). Fluid (de
     * serie) es lo de siempre; Mochi, Drop, Jelly, Power-on, Bloom, Ink y Mist tienen línea de tiempo. Sólo al abrir un
     * panel desde el reposo (o la fila hover) y al volver; el OSD y los avisos siguen ensanchándose como siempre.
     * Ausente → `fluid`, sin migración.
     */
    { id: "shell.animations.islandStyle", prop: "islandStyle", type: "enum",
      def: "fluid", values: ["fluid", "mochi", "drop", "jelly", "poweron", "bloom", "ink", "mist"], section: "Animations", subsection: "Island style",
      owner: "shell", apply: "immediate", preset: "motion" },
    { id: "shell.surfaces.unloadSeconds", prop: "unloadSec", legacy: "unloadSec", type: "real",
      def: 60, min: 5, max: 600, section: "Lifecycle", owner: "shell", apply: "immediate" },
    { id: "shell.surfaces.minimizerThumbnails", prop: "minimizerThumbs", legacy: "minimizerThumbs", type: "bool",
      def: false, section: "Surfaces", owner: "shell", apply: "immediate" },
    // (15H) `shell.island.visualizerFps` se retiró con el visualizador del Lock (LOCK-D13): un valor que quede en
    // un settings.json se conserva tal cual y no se lee.
    { id: "shell.session.keepAwake", prop: "keepAwake", legacy: "keepAwake", type: "bool",
      def: false, section: "Power", owner: "shell", apply: "immediate", export: false },
    { id: "shell.battery.alerts", prop: "batteryAlerts", type: "bool",
      def: true, section: "Battery", owner: "shell", apply: "immediate" },
    { id: "shell.battery.low", prop: "batteryLow", type: "int",
      def: 20, min: 1, max: 99, section: "Battery", owner: "shell", apply: "immediate" },
    { id: "shell.battery.veryLow", prop: "batteryVeryLow", type: "int",
      def: 10, min: 1, max: 99, section: "Battery", owner: "shell", apply: "immediate" },
    { id: "shell.battery.critical", prop: "batteryCritical", type: "int",
      def: 5, min: 1, max: 99, section: "Battery", owner: "shell", apply: "immediate" },
    { id: "shell.integrations.polkitAgent", prop: "polkitAgent", legacy: "polkitAgent", type: "bool",
      def: false, section: "Integrations", owner: "shell", apply: "immediate", export: false },
    { id: "shell.integrations.notificationServer", prop: "notificationServer", legacy: "notificationServer", type: "bool",
      def: false, section: "", owner: "shell", apply: "restart", export: false },
    { id: "shell.lock.avatar", prop: "lockAvatar", legacy: "lockAvatar", type: "path",
      def: "", section: "Lock screen", owner: "shell", apply: "immediate", export: false },
    { id: "shell.lock.fetchImage", prop: "lockFetchImage", legacy: "lockFetchImage", type: "path",
      def: "", section: "Lock screen", owner: "shell", apply: "immediate", export: false },
    /**
     * Portabilidad F5d (2026-10-10; H-07): cómo pide la shell el bloqueo (botón Lock, IPC `lock`, menú de energía).
     *   auto    por logind (`loginctl lock-session`) si alguien lo atiende (hypridle con el helper de la shell, con
     *           hyprlock u otro: se respeta); directo si nadie escucha (services/LockEntry)
     *   logind  siempre `loginctl lock-session`        direct  siempre el helper de la shell, en su scope
     * Sin subir de versión (P6.1): `auto` reproduce lo de antes en la máquina del autor (hypridle llama al helper).
     */
    { id: "shell.lock.entry", prop: "lockEntry", type: "enum",
      def: "auto", values: ["auto", "logind", "direct"], section: "Lock screen", owner: "shell", apply: "immediate", export: false },
    /** F5d (consumidor en F5e; H-26): la pila PAM del Lock. `auto` = `login` (la de siempre). Nunca `other`. */
    { id: "shell.lock.pamService", prop: "lockPamService", type: "pamService",
      def: "auto", section: "", owner: "shell", apply: "immediate", export: false },
    { id: "theme.wallpaper.videoPreview", prop: "wallpaperVideoPreview", legacy: "wallpaperVideoPreview", type: "bool",
      def: false, section: "Wallpaper", owner: "shell", apply: "immediate" },
    /**
     * 10A (futureSettingssurface §6 Sources; futureWallpaper-listsurface): las carpetas de la
     * biblioteca, un solo inventario para Wallpaper List y Theme → Wallpaper. Se escanean a UN
     * nivel (como `generate-thumbs.sh`, que lee la misma lista); el tipo lo da la extensión. Los
     * defaults son las dos carpetas de siempre. `~/` se admite y se expande al usarlas.
     */
    { id: "theme.wallpaper.sources", prop: "wallpaperSources", type: "paths",
      def: ["~/Pictures/Wallpapers", "~/Videos/Wallpapers"], max: 16,
      section: "Wallpaper", owner: "shell", apply: "immediate", local: true },
    /**
     * 10A: la carpeta donde entrarán las descargas de Wallhaven (fase 10D). Tiene que ser una de
     * Sources y escribible; si se retira de Sources, Settings lo explica y deja elegir otra antes
     * de la próxima descarga (futureWallpaper-listsurface «Origen y colecciones»).
     */
    { id: "theme.wallpaper.downloadDir", prop: "wallpaperDownloadDir", type: "path",
      def: "~/Pictures/Wallpapers", section: "Wallpaper", owner: "shell", apply: "immediate", local: true },
    /**
     * 10E-1a: el usuario de Wallhaven (la ruta de lectura de colecciones lo pide). Preferencia
     * normal: la CLAVE no está aquí, está en secrets/ (WallhavenAccount).
     */
    { id: "theme.wallpaper.wallhaven.username", prop: "wallhavenUser", type: "string",
      def: "", max: 64, section: "Wallhaven", owner: "shell", apply: "immediate", export: false },
    /**
     * 10B (futureSettingssurface §6 Rotation): APAGADA por defecto. Un solo programador (el del
     * shell, `core/WallpaperRotation`); aplica a todas las pantallas por el camino de siempre, así
     * que repinta con matugen. Pausas opcionales: pantalla completa, batería, modos Gaming/Cinema.
     */
    { id: "theme.wallpaper.rotation.enabled", prop: "wallRotation", type: "bool",
      def: false, section: "Rotation", owner: "shell", apply: "immediate" },
    { id: "theme.wallpaper.rotation.minutes", prop: "wallRotationMinutes", type: "int",
      def: 60, values: [15, 30, 60, 180, 360, 1440], section: "Rotation", owner: "shell", apply: "immediate" },
    { id: "theme.wallpaper.rotation.from", prop: "wallRotationFrom", type: "enum",
      def: "all", values: ["all", "images", "videos", "favorites"], section: "Rotation", owner: "shell", apply: "immediate" },
    { id: "theme.wallpaper.rotation.pauseFullscreen", prop: "wallRotationPauseFullscreen", type: "bool",
      def: true, section: "Rotation", owner: "shell", apply: "immediate" },
    { id: "theme.wallpaper.rotation.pauseBattery", prop: "wallRotationPauseBattery", type: "bool",
      def: false, section: "Rotation", owner: "shell", apply: "immediate" },
    { id: "theme.wallpaper.rotation.pauseModes", prop: "wallRotationPauseModes", type: "bool",
      def: false, section: "Rotation", owner: "shell", apply: "immediate" },
    /**
     * 10B (§6 Transitions): el tipo de transición de awww para IMÁGENES (mpvpaper no tiene). Sólo
     * los que el backend admite; «any» es lo que el rice usaba siempre.
     */
    { id: "theme.wallpaper.transition", prop: "wallTransition", type: "enum",
      def: "any", values: ["any", "fade", "wipe", "wave", "grow", "outer", "none"],
      section: "Transitions", owner: "shell", apply: "immediate" },
    /**
     * Pantalla preferida (fase 4D; DESIGN §4): el destino de un atajo cuando no se sabe
     * cuál tiene el foco. Conector («HDMI-A-1») o identidad estable («modelo|serie»);
     * vacío = la primera salida. Sin fila mientras haya un solo monitor.
     */
    { id: "shell.integration.preferredDisplay", prop: "preferredDisplay", type: "string",
      def: "", max: 256, section: "", owner: "shell", apply: "immediate", export: false },
    /**
     * Presentación por monitor (fase 3, «persistir preferencias por monitor, incluido el
     * futuro Enable dock»). Clave = identidad estable de la salida (modelo|serie), no el
     * nombre del conector. Sin fila todavía: nada la consume hasta las fases 8 y 9.
     */
    { id: "shell.monitors", prop: "monitors", type: "monitors",
      def: {}, section: "", owner: "shell", apply: "immediate", export: false },
    /**
     * Clima (fase 7C/7D; spec de Calendar «Clima opcional»): APAGADO por defecto, sin
     * geolocalización por IP ni consulta de red antes de elegirlo. La ciudad se elige de
     * la búsqueda de Open-Meteo y se guarda con sus coordenadas y su zona horaria; las
     * unidades las comparten Calendar y Lock. `{}` = sin ciudad.
     */
    /**
     * 9C-2 (futureSettingssurface §5 «Surfaces, módulos y opciones específicas»): opciones de
     * Calendar, Notifications, OSD y Launcher. Cada una tiene un consumidor real; los defaults
     * son lo que el shell hacía hasta ahora (locale, 24 h, 4 s, 1,8 s, número, scrollbar izquierda).
     */
    /**
     * 11A-2 (futureDashboardsurface): frecuencia ESPERADA de cada copia, en días. 0 = sin
     * frecuencia: la antigüedad es sólo información y nunca un asunto del Overview.
     */
    /**
     * F3a: el mismo dato, por id de tarea (`tasks.json`): { "<id>": días }. Sólo se guardan las
     * frecuencias activas (0 = sin frecuencia = el default, y no se escribe). Los dos ajustes v2
     * (`dotbackupEveryDays`/`diskbackupEveryDays`) se mueven aquí en `upgrade()`. F3d-2: Settings →
     * Dashboard tiene una fila por tarea con `lastRun`; las dos propiedades de compatibilidad ya no existen.
     */
    { id: "shell.dashboard.taskEveryDays", prop: "taskEveryDays", type: "taskEvery",
      def: {}, section: "Dashboard", owner: "shell", apply: "immediate" },
    { id: "shell.calendar.firstDay", prop: "calendarFirstDay", type: "enum",
      def: "locale", values: ["locale", "monday", "sunday"], section: "Calendar", owner: "shell", apply: "immediate" },
    { id: "shell.calendar.clock", prop: "clockFormat", type: "enum",
      def: "24h", values: ["24h", "12h"], section: "Calendar", owner: "shell", apply: "immediate" },
    { id: "shell.notifications.popupSeconds", prop: "notifPopupSec", type: "int",
      def: 4, min: 2, max: 30, section: "Notifications", owner: "shell", apply: "immediate" },
    /**
     * Dónde salen los popups (2026-11-19, pedido del autor): cuatro esquinas y abajo al centro (arriba al centro no: ahí
     * viven la isla y el notch), siempre en el monitor enfocado. `margin`: px (× escala) a los bordes, el aire que antes
     * era `Metrics.notifMargin`. De serie, lo de siempre: abajo a la derecha a 20 px. Ausente → serie, sin migración.
     */
    { id: "shell.notifications.position", prop: "notifPosition", type: "enum",
      def: "bottom-right", values: ["top-left", "top-right", "bottom-left", "bottom-center", "bottom-right"],
      section: "Notifications", owner: "shell", apply: "immediate" },
    { id: "shell.notifications.margin", prop: "notifMargin", type: "int",
      def: 20, min: 8, max: 64, section: "Notifications", owner: "shell", apply: "immediate" },
    { id: "shell.osd.durationMs", prop: "osdMs", type: "int",
      def: 1800, min: 800, max: 5000, section: "OSD", owner: "shell", apply: "immediate" },
    { id: "shell.osd.showValue", prop: "osdShowValue", type: "bool",
      def: true, section: "OSD", owner: "shell", apply: "immediate", preset: "layout" },
    { id: "shell.launcher.scrollbar", prop: "launcherScrollbar", type: "enum",
      def: "left", values: ["left", "right"], section: "Launcher", owner: "shell", apply: "immediate", preset: "layout" },
    /** Selector de emojis (2026-11-17): qué hace ⏎ (Shift+⏎, lo otro). `paste` copia y envía Ctrl+V a la ventana de antes. */
    { id: "shell.emoji.action", prop: "emojiAction", type: "enum",
      def: "copy", values: ["copy", "paste"], section: "Emoji picker", owner: "shell", apply: "immediate" },
    /**
     * 9D-1 (futureSettingssurface §6 Apariencia visual): tamaño del TEXTO dentro de Iosevka,
     * aparte de la escala general (que agranda también márgenes e iconos). Un factor sobre los
     * tamaños de `theme/Typography`; nunca otra familia.
     */
    // T0–T2: requested choices only; deliberately outside Appearance presets.
    { id: "theme.typography.preset", prop: "fontPreset", type: "fontId",
      def: "iosevka", section: "", owner: "shell", apply: "immediate" },
    { id: "theme.typography.uiFamily", prop: "fontUi", type: "fontFamily",
      def: "", section: "", owner: "shell", apply: "immediate" },
    { id: "theme.typography.monoFamily", prop: "fontMono", type: "fontFamily",
      def: "", section: "", owner: "shell", apply: "immediate" },
    // Optional Qt 5 targets; local preferences, never enabled by an import or a settings preset.
    { id: "theme.typography.sync.qt5Interface", prop: "fontSyncQt5Interface", type: "bool",
      def: false, section: "", owner: "shell", apply: "immediate", export: false },
    { id: "theme.typography.sync.qt5Fixed", prop: "fontSyncQt5Fixed", type: "bool",
      def: false, section: "", owner: "shell", apply: "immediate", export: false },
    // T4: llevar la tipografía a otras apps, destino a destino. Todo apagado; de ESTA máquina (sin exportar);
    // sólo dice qué se puede sincronizar: nada se escribe hasta «Sync selected» (scripts/font-sync.py).
    { id: "theme.typography.sync.gtkInterface", prop: "fontSyncGtkInterface", type: "bool",
      def: false, section: "", owner: "shell", apply: "immediate", export: false },
    { id: "theme.typography.sync.gtkMonospace", prop: "fontSyncGtkMonospace", type: "bool",
      def: false, section: "", owner: "shell", apply: "immediate", export: false },
    { id: "theme.typography.sync.gtk4Interface", prop: "fontSyncGtk4Interface", type: "bool",
      def: false, section: "", owner: "shell", apply: "immediate", export: false },
    { id: "theme.typography.sync.qt6Interface", prop: "fontSyncQt6Interface", type: "bool",
      def: false, section: "", owner: "shell", apply: "immediate", export: false },
    { id: "theme.typography.sync.qt6Fixed", prop: "fontSyncQt6Fixed", type: "bool",
      def: false, section: "", owner: "shell", apply: "immediate", export: false },
    { id: "theme.typography.sync.kitty", prop: "fontSyncKitty", type: "bool",
      def: false, section: "", owner: "shell", apply: "immediate", export: false },
    { id: "theme.typography.sync.kittyReload", prop: "fontSyncKittyReload", type: "bool",
      def: false, section: "", owner: "shell", apply: "immediate", export: false },
    { id: "theme.typography.sync.vscodium", prop: "fontSyncVscodium", type: "bool",
      def: false, section: "", owner: "shell", apply: "immediate", export: false },
    /**
     * Apariencia (2026-11-13): el tema de iconos y el cursor que la shell quiere en las apps (scripts/appearance.py,
     * services/Appearance). Se escriben al pulsar Apply en Settings → Appearance → Icons (no al elegir: elegir es un
     * borrador); lo que de verdad se aplicó, y dónde, lo guarda el registro del helper. "" / 0 = no gestionado: manda
     * lo que tenga el escritorio. Ausentes en un archivo anterior → "" / 0: para quien ya tenía la shell no cambia
     * nada (sin migración, sin subir la versión); una configuración nueva tampoco trae ninguno (Colloid como el de
     * Minimaru se retiró el mismo día a petición del autor). De esta máquina: ni presets ni exportación.
     *   followMode  el par claro/oscuro del tema (Papirus-Light/-Dark…) sigue al modo confirmado
     *               del tema de colores; sólo si lo último aplicado ya era ese tema
     */
    { id: "theme.icons.theme", prop: "iconTheme", type: "themeName",
      def: "", section: "", owner: "shell", apply: "immediate", export: false },
    { id: "theme.icons.followMode", prop: "iconFollowMode", type: "bool",
      def: true, section: "", owner: "shell", apply: "immediate", export: false },
    { id: "theme.cursor.theme", prop: "cursorTheme", type: "themeName",
      def: "", section: "", owner: "shell", apply: "immediate", export: false },
    { id: "theme.cursor.size", prop: "cursorSize", type: "int",
      def: 0, values: [0, 16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 96], section: "", owner: "shell",
      apply: "immediate", export: false },
    { id: "theme.typography.textSize", prop: "textScale", type: "real",
      def: 1.0, values: [1.0, 1.08, 1.15], section: "Typography", owner: "shell", apply: "immediate", preset: "appearance" },
    /**
     * 12D (futureSettingssurface §6 Apariencia; §10 «0.75–1.00; preview de contraste»): la
     * opacidad del vidrio de las surfaces (`Theme.glassBg`), que era un 0,95 fijo. Por debajo de
     * ~0,94 el texto de lo que hay detrás se lee a través (medido el 2026-09-24 a 0,90).
     */
    { id: "theme.appearance.glassOpacity", prop: "glassOpacity", type: "real",
      def: 0.95, min: 0.75, max: 1.0, section: "Glass", owner: "shell", apply: "immediate", preset: "appearance" },
    /** Material y acabado. La opacidad sigue perteneciendo sólo a glassOpacity. */
    { id: "theme.appearance.material", prop: "material", type: "enum",
      def: "glass", values: ["glass", "satin"], section: "Material", owner: "shell", apply: "immediate", preset: "appearance" },
    { id: "theme.appearance.materialEdge", prop: "materialEdge", type: "enum",
      def: "subtle", values: ["none", "subtle", "defined"], section: "Material", owner: "shell", apply: "immediate", preset: "appearance" },
    { id: "theme.appearance.materialShadow", prop: "materialShadow", type: "bool",
      def: true, section: "Material", owner: "shell", apply: "immediate", preset: "appearance" },
    /**
     * 2026-10-28 (Theme → Material → Surfaces): material y opacidad propios de una superficie,
     * propiedad a propiedad; lo que falta se hereda de los dos de arriba (lib/surface-materials.js).
     * Sin sección: «Reset section» del material global no los toca. No es presetable (un preset
     * de material sigue cambiando sólo el global) y no sube la versión: `{}` = el aspecto de antes.
     */
    { id: "theme.appearance.surfaces", prop: "surfaceMaterials", type: "surfaceMaterials",
      def: {}, section: "", owner: "shell", apply: "immediate" },
    /**
     * 2026-11-14 (ADR-34, theme/Style): el estilo de interfaz, la forma de la shell (geometría, marco, decoraciones y
     * presentación de los controles), aparte del color, el material, la tipografía y el movimiento. `soft` es la de
     * siempre. Los tres de terminal sólo cuentan con `terminal`. Ausentes en un archivo anterior → soft y los de serie:
     * sin migración ni subir la versión. Página: Settings → Appearance → Interface style (secciones InterfaceStyle y
     * TerminalStyle, para «Reset section»).
     */
    { id: "theme.style.name", prop: "interfaceStyle", type: "enum",
      def: "soft", values: ["soft", "terminal"], section: "InterfaceStyle", owner: "shell", apply: "immediate", preset: "appearance" },
    { id: "theme.style.terminal.frame", prop: "termFrame", type: "enum",
      def: "single", values: ["single", "double", "segmented"], section: "TerminalStyle", owner: "shell", apply: "immediate", preset: "appearance" },
    { id: "theme.style.terminal.decor", prop: "termDecor", type: "enum",
      def: "minimal", values: ["none", "minimal", "full"], section: "TerminalStyle", owner: "shell", apply: "immediate", preset: "appearance" },
    { id: "theme.style.terminal.monoText", prop: "termMono", type: "bool",
      def: true, section: "TerminalStyle", owner: "shell", apply: "immediate", preset: "appearance" },
    /**
     * 2026-11-14 (F5 del estilo, ADR-34 y ADR-23): los efectos de terminal, todos apagados de serie (cuestan algo y no a
     * todo el mundo le gustan). Sólo existen con el estilo terminal; el glitch y el encendido, además, sólo con
     * movimiento Normal (Reduced/Off, y por tanto los modos Focus y Gaming, los quitan). Nunca en el bloqueo, ni sobre
     * texto, campos o avisos críticos. Sin subir la versión.
     */
    { id: "theme.effects.glitch", prop: "fxGlitch", type: "enum",
      def: "off", values: ["off", "subtle", "strong"], section: "TerminalEffects", owner: "shell", apply: "immediate", preset: "appearance" },
    { id: "theme.effects.scanlines", prop: "fxScanlines", type: "bool",
      def: false, section: "TerminalEffects", owner: "shell", apply: "immediate", preset: "appearance" },
    { id: "theme.effects.glow", prop: "fxGlow", type: "bool",
      def: false, section: "TerminalEffects", owner: "shell", apply: "immediate", preset: "appearance" },
    // 2026-11-17 (ADR-36): `theme.effects.powerOn` se retiró: Power-on es ahora un estilo de ventana
    // (`shell.animations.windowStyle` = "poweron"), para Soft y Terminal. Un valor que quede en un settings.json se
    // conserva tal cual y no se lee.
    { id: "shell.weather.enabled", prop: "weatherEnabled", type: "bool",
      def: false, section: "Weather", owner: "shell", apply: "immediate", export: false },
    { id: "shell.weather.location", prop: "weatherLocation", type: "location",
      def: {}, section: "Weather", owner: "shell", apply: "immediate", export: false },
    { id: "shell.weather.units", prop: "weatherUnits", type: "enum",
      def: "celsius", values: ["celsius", "fahrenheit"], section: "Weather", owner: "shell", apply: "immediate" },
    /**
     * F3a (portabilidad, H-28/H-27): los programas del usuario. «auto» = detectar (terminal:
     * xdg-terminal-exec → $TERMINAL → lista conocida; navegador: $BROWSER → xdg-open). Un valor
     * explícito es SÓLO un nombre de ejecutable o una ruta absoluta, sin argumentos. No se exportan
     * ni se importan: un archivo importado no puede decidir qué programa ejecuta la shell. La terminal
     * tiene fila y consumidores desde la F3b (Settings → Shell → Apps); el navegador, desde la F3c.
     */
    { id: "apps.terminal", prop: "appTerminal", type: "command",
      def: "auto", section: "Apps", owner: "shell", apply: "immediate", export: false },
    /** Cómo se pasa la orden a una terminal que no está en la lista: `-e`, `--` o detrás sin nada. */
    { id: "apps.terminalExec", prop: "appTerminalExec", type: "enum",
      def: "auto", values: ["auto", "-e", "--", "none"], section: "Apps", owner: "shell", apply: "immediate", export: false },
    { id: "apps.browser", prop: "appBrowser", type: "command",
      def: "auto", section: "Apps", owner: "shell", apply: "immediate", export: false },
    /** F8b: auto exige evidencia fresca; direct no sale de un cgroup heredado. */
    { id: "apps.launchScope", prop: "appLaunchScope", type: "enum",
      def: "auto", values: ["auto", "systemd", "direct"], section: "Apps", owner: "shell", apply: "immediate", export: false },
    /**
     * F4a (portabilidad, H-10/H-11/H-15): qué proveedor usa cada función. `auto` = el propio de la shell
     * con lo que haya instalado (prioridades documentadas en ROADMAP §F4; llegan en F4b–F4e); un backend
     * por su nombre = sólo ése, y si falta se dice por qué (nunca otro en silencio); `script` = la orden
     * de `providers.json`; `none` = la función no existe aquí. No se exportan ni se importan: eligen qué
     * se ejecuta. Sin fila hasta que cada consumidor llegue (F4b–F4e).
     */
    { id: "providers.wallpaper", prop: "providerWallpaper", type: "enum",       // F4b: fila en Shell → Apps
      def: "auto", values: ["auto", "awww", "hyprpaper", "script", "none"], section: "Providers", owner: "shell", apply: "immediate", export: false },
    { id: "providers.theme", prop: "providerTheme", type: "enum",              // F4d: fila en Shell → Apps
      def: "auto", values: ["auto", "matugen", "static", "script"], section: "Providers", owner: "shell", apply: "immediate", export: false },
    { id: "providers.thumbnails", prop: "providerThumbnails", type: "enum",     // F4c: fila en Shell → Apps
      def: "auto", values: ["auto", "builtin", "script", "none"], section: "Providers", owner: "shell", apply: "immediate", export: false },
    { id: "providers.updates", prop: "providerUpdates", type: "enum",          // F4e: fila en Shell → Apps
      def: "auto", values: ["auto", "pacman", "script", "none"], section: "Providers", owner: "shell", apply: "immediate", export: false },
    /**
     * F4a (PL-04): sincronizar el tema con el escritorio. off = la shell no toca nada fuera de sí;
     * colorScheme = sólo org.gnome.desktop.interface color-scheme; full = además gtk-theme
     * (Adwaita/Adwaita-dark), lo que la shell hacía desde la 12F. Consumidor en F4d.
     */
    { id: "theme.desktopSync", prop: "themeDesktopSync", type: "enum",         // F4d: fila en Shell → Apps
      def: "off", values: ["off", "colorScheme", "full"], section: "Providers", owner: "shell", apply: "immediate", export: false },
    /**
     * Grabador 2.0 (2026-10-29, Settings → Screen recording). Antes vivía en recorder.json, fuera de este archivo;
     * ahora los chips de la surface editan ESTOS valores (una sola fuente). Defaults = lo de la segunda entrega
     * (Standard, sistema sí, micro no, 3 s, MP4/AAC). Sin subir la versión: si falta, el default. La resolución de
     * lo que se graba (codificador real, fps, tamaño) la hace el helper con estos valores; aquí sólo se validan.
     *   preset      standard · high · custom (Custom = las cinco `custom.*`)
     *   encoder     auto o un id del helper (`ENCODERS`); los que no funcionen aquí los dice `probe`
     *   fps         0 = automático (el refresco, como mucho 60); 1–240
     *   height      0 = nativa; si no, la altura de salida (144–4320, nunca hacia arriba)
     *   delay       segundos de cuenta atrás; 0 = sin ella (el chip D alterna con el último distinto de 0)
     *   hud.*       el indicador bajo el island y en la barra (el punto de privacidad NO depende de esto)
     * Las fuentes de audio son dispositivos de esta máquina: no se exportan. La carpeta es local.
     */
    { id: "recorder.preset", prop: "recPreset", type: "enum",
      def: "standard", values: ["standard", "high", "custom"], section: "Recorder preset", owner: "shell", apply: "immediate" },
    { id: "recorder.custom.encoder", prop: "recEncoder", type: "enum",
      def: "auto", values: ["auto", "h264_vaapi", "hevc_vaapi", "av1_vaapi", "libx264"], section: "Recorder custom", owner: "shell", apply: "immediate" },
    { id: "recorder.custom.fps", prop: "recFps", type: "int",
      def: 0, min: 0, max: 240, section: "Recorder custom", owner: "shell", apply: "immediate" },
    { id: "recorder.custom.quality", prop: "recQuality", type: "enum",
      def: "high", values: ["balanced", "high", "veryhigh", "bitrate"], section: "Recorder custom", owner: "shell", apply: "immediate" },
    { id: "recorder.custom.bitrate", prop: "recBitrate", type: "int",
      def: 12, values: [4, 8, 12, 20, 40, 80], section: "Recorder custom", owner: "shell", apply: "immediate" },
    { id: "recorder.custom.height", prop: "recHeight", type: "int",
      def: 0, min: 0, max: 4320, section: "Recorder custom", owner: "shell", apply: "immediate" },
    { id: "recorder.format", prop: "recFormat", type: "enum",
      def: "mp4", values: ["mp4", "mkv", "webm"], section: "Recorder format", owner: "shell", apply: "immediate" },
    { id: "recorder.audio.system", prop: "recSystemAudio", type: "bool",
      def: true, section: "Recorder audio", owner: "shell", apply: "immediate" },
    { id: "recorder.audio.mic", prop: "recMic", type: "bool",
      def: false, section: "Recorder audio", owner: "shell", apply: "immediate" },
    { id: "recorder.audio.systemSource", prop: "recSystemSource", type: "string",
      def: "", max: 256, section: "Recorder audio", owner: "shell", apply: "immediate", export: false },
    { id: "recorder.audio.micSource", prop: "recMicSource", type: "string",
      def: "", max: 256, section: "Recorder audio", owner: "shell", apply: "immediate", export: false },
    { id: "recorder.audio.codec", prop: "recAudioCodec", type: "enum",
      def: "aac", values: ["aac", "opus"], section: "Recorder audio", owner: "shell", apply: "immediate" },
    { id: "recorder.audio.bitrate", prop: "recAudioBitrate", type: "int",
      def: 160, values: [96, 128, 160, 192, 256], section: "Recorder audio", owner: "shell", apply: "immediate" },
    { id: "recorder.audio.sampleRate", prop: "recSampleRate", type: "int",
      def: 48000, values: [44100, 48000], section: "Recorder audio", owner: "shell", apply: "immediate" },
    { id: "recorder.files.dir", prop: "recDir", type: "path",
      def: "", section: "Recorder files", owner: "shell", apply: "immediate", local: true },
    { id: "recorder.files.name", prop: "recName", type: "string",
      def: "Recording {date} {time}", max: 120, section: "Recorder files", owner: "shell", apply: "immediate" },
    { id: "recorder.delay", prop: "recDelay", type: "int",
      def: 3, values: [0, 3, 5, 10], section: "Recorder behavior", owner: "shell", apply: "immediate" },
    { id: "recorder.hud.indicator", prop: "recIndicator", type: "bool",
      def: true, section: "Recorder behavior", owner: "shell", apply: "immediate" },
    { id: "recorder.hud.timer", prop: "recTimer", type: "bool",
      def: true, section: "Recorder behavior", owner: "shell", apply: "immediate" },
    { id: "recorder.hud.island", prop: "recIslandControls", type: "bool",
      def: true, section: "Recorder behavior", owner: "shell", apply: "immediate" },
    { id: "recorder.hud.bar", prop: "recBarControls", type: "bool",
      def: true, section: "Recorder behavior", owner: "shell", apply: "immediate" },
    { id: "recorder.notify", prop: "recNotify", type: "bool",
      def: false, section: "Recorder behavior", owner: "shell", apply: "immediate" },
    { id: "recorder.openFolder", prop: "recOpenFolder", type: "bool",
      def: false, section: "Recorder behavior", owner: "shell", apply: "immediate" },
    { id: "recorder.rememberMode", prop: "recRememberMode", type: "bool",
      def: true, section: "Recorder behavior", owner: "shell", apply: "immediate" },
    /**
     * El reproductor del Mixer apaisado (2026-11-09, pedido del usuario): sólo composición. Fondo de la
     * zona de reproducción (la carátula desenfocada de la 9E-2 o el del tema), forma de la carátula
     * (cuadrada o disco) y qué tiempo se enseña junto al transcurrido. Defaults = lo de antes. El giro
     * del disco (`shell.player.spin`) se retiró el mismo día a petición del usuario; si quedó en un
     * settings.json, `build` lo conserva como campo desconocido sin usarlo.
     */
    { id: "shell.player.backdrop", prop: "mediaBackdrop", type: "enum",
      def: "cover", values: ["cover", "theme"], section: "Media player", owner: "shell", apply: "immediate" },
    { id: "shell.player.cover", prop: "mediaCoverShape", type: "enum",
      def: "square", values: ["square", "disc"], section: "Media player", owner: "shell", apply: "immediate" },
    { id: "shell.player.endTime", prop: "mediaEndTime", type: "enum",
      def: "total", values: ["total", "remaining"], section: "Media player", owner: "shell", apply: "immediate" }
];

/** El id de una tarea de `tasks.json` (lib/tasks-schema.js usa el mismo). */
var TASK_ID = /^[a-z][a-z0-9_-]{0,31}$/;

function entryByProp(prop) {
    for (var i = 0; i < CATALOG.length; i++)
        if (CATALOG[i].prop === prop) return CATALOG[i];
    return null;
}

function clone(v) { return v === undefined ? undefined : JSON.parse(JSON.stringify(v)); }

function def(prop) {
    var e = entryByProp(prop);
    return e ? clone(e.def) : undefined;
}

function getPath(doc, id) {
    var parts = id.split(".");
    var cur = doc;
    for (var i = 0; i < parts.length; i++) {
        if (cur === null || typeof cur !== "object" || Array.isArray(cur)) return undefined;
        cur = cur[parts[i]];
    }
    return cur;
}

function setPath(doc, id, value) {
    var parts = id.split(".");
    var cur = doc;
    for (var i = 0; i < parts.length - 1; i++) {
        if (cur[parts[i]] === null || typeof cur[parts[i]] !== "object" || Array.isArray(cur[parts[i]]))
            cur[parts[i]] = {};
        cur = cur[parts[i]];
    }
    cur[parts[parts.length - 1]] = value;
}

/** Un valor contra su entrada: { ok, value } o { ok: false, error }. Nunca recorta: rechaza. */
function check(e, v) {
    switch (e.type) {
    case "bool":
        return typeof v === "boolean" ? { ok: true, value: v } : { ok: false, error: "expected true or false" };
    case "real":
    case "int":
        if (typeof v !== "number" || !isFinite(v)) return { ok: false, error: "expected a number" };
        if (e.type === "int" && Math.floor(v) !== v) return { ok: false, error: "expected a whole number" };
        if (e.values && e.values.indexOf(v) < 0) return { ok: false, error: "expected one of " + e.values.join(", ") };
        if (e.min !== undefined && v < e.min) return { ok: false, error: "below " + e.min };
        if (e.max !== undefined && v > e.max) return { ok: false, error: "above " + e.max };
        return { ok: true, value: v };
    case "enum":
        // `aliases`: valores retirados que siguen leyéndose como su sustituto (el archivo
        // se reescribe con el nuevo en el siguiente guardado)
        if (e.aliases && typeof v === "string" && e.aliases[v] !== undefined) v = e.aliases[v];
        return e.values.indexOf(v) >= 0 ? { ok: true, value: v }
            : { ok: false, error: "expected one of " + e.values.join(", ") };
    case "fontId":
        return typeof v === "string" && /^[a-z][a-z0-9-]{0,63}$/.test(v)
            ? {ok:true,value:v} : {ok:false,error:"expected a stable font preset id"};
    case "fontFamily":
        return typeof v === "string" && v.length <= 160 && !/[\x00-\x1f\x7f/\\]/.test(v)
            ? {ok:true,value:v} : {ok:false,error:"expected a local family name"};
    case "themeName":
        // un nombre de carpeta de tema (iconos/cursor): sin rutas ni controles; "" = no gestionado
        return typeof v === "string" && (v === "" || /^[A-Za-z0-9][A-Za-z0-9._+ -]{0,100}$/.test(v))
            ? { ok: true, value: v } : { ok: false, error: "expected an icon or cursor theme name" };
    case "string":
        if (typeof v !== "string") return { ok: false, error: "expected text" };
        if (e.max !== undefined && v.length > e.max) return { ok: false, error: "too long" };
        return { ok: true, value: v };
    case "path":
        if (typeof v !== "string") return { ok: false, error: "expected a path" };
        if (v.length > 4096) return { ok: false, error: "path too long" };
        if (v.length > 0 && v.charAt(0) !== "/" && v.charAt(0) !== "~")
            return { ok: false, error: "only local paths (/… or ~/…)" };
        if (v.indexOf("://") >= 0) return { ok: false, error: "only local paths" };
        return { ok: true, value: v };
    case "paths":
        // Lista de carpetas locales, sin repetidas; vacía se admite (biblioteca vacía)
        if (!Array.isArray(v)) return { ok: false, error: "expected a list of paths" };
        if (e.max !== undefined && v.length > e.max) return { ok: false, error: "at most " + e.max + " folders" };
        var seen = {};
        var list = [];
        for (var j = 0; j < v.length; j++) {
            var one = check({ type: "path" }, v[j]);
            if (!one.ok) return { ok: false, error: one.error };
            if (one.value.length === 0 || seen[one.value]) continue;
            seen[one.value] = true;
            list.push(one.value);
        }
        return { ok: true, value: list };
    case "monitors":
        if (v === null || typeof v !== "object" || Array.isArray(v)) return { ok: false, error: "expected an object" };
        var out = {};
        for (var k in v) {
            var m = v[k];
            if (m === null || typeof m !== "object" || Array.isArray(m) || k.length === 0 || k.length > 256) continue;
            var keep = {};
            if (m.presentation === "island" || m.presentation === "bar") keep.presentation = m.presentation;
            if (typeof m.dock === "boolean") keep.dock = m.dock;
            // 2026-11-19: borde y longitud de la barra permanente (lib/bar-edge.js); lo desconocido se cae
            if (["top", "bottom", "left", "right"].indexOf(m.barEdge) >= 0) keep.barEdge = m.barEdge;
            if (typeof m.barLength === "number" && isFinite(m.barLength))
                keep.barLength = Math.max(30, Math.min(100, Math.round(m.barLength)));
            out[k] = keep;
        }
        return { ok: true, value: out };
    case "pamService":
        // F5d: «auto» o el nombre de un servicio de /etc/pam.d. `other` es la pila de lo que no existe (pam_deny en Arch,
        // otras cosas en otras distros): nunca se elige a propósito.
        if (v === "auto") return { ok: true, value: v };
        if (typeof v !== "string" || !/^[a-z0-9][a-z0-9_.-]{0,63}$/.test(v)) return { ok: false, error: "expected a PAM service name" };
        if (v === "other") return { ok: false, error: "the 'other' PAM stack is never used" };
        return { ok: true, value: v };
    case "command":
        // F3a: «auto», un nombre de ejecutable o una ruta absoluta. Nunca una línea con argumentos.
        if (typeof v !== "string") return { ok: false, error: "expected a program name" };
        if (v === "auto") return { ok: true, value: v };
        if (v.length === 0 || v.length > 256) return { ok: false, error: "expected a program name" };
        if (/^[A-Za-z0-9_][A-Za-z0-9._+-]*$/.test(v)) return { ok: true, value: v };
        if (v.charAt(0) === "/" && !/[\s\x00-\x1f]/.test(v) && v.indexOf("/../") < 0) return { ok: true, value: v };
        return { ok: false, error: "only a program name or an absolute path, without arguments" };
    case "taskEvery":
        // F3a: { id: días }. Rechaza el valor entero si algo no vale; los 0 no se guardan (= default)
        if (v === null || typeof v !== "object" || Array.isArray(v)) return { ok: false, error: "expected an object" };
        var every = {};
        for (var tid in v) {
            if (!TASK_ID.test(tid)) return { ok: false, error: "invalid task id " + JSON.stringify(tid).substring(0, 40) };
            var days = v[tid];
            if (typeof days !== "number" || Math.floor(days) !== days || days < 0 || days > 30)
                return { ok: false, error: "expected 0-30 days for " + tid };
            if (days > 0) every[tid] = days;
        }
        return { ok: true, value: every };
    case "surfaceMaterials":
        // { clave: { material?, opacity? } } con los mismos valores que el material y la opacidad globales
        if (v === null || typeof v !== "object" || Array.isArray(v)) return { ok: false, error: "expected an object" };
        var mats = entryByProp("material"), opa = entryByProp("glassOpacity");
        var surf = {};
        for (var sk in v) {
            if (!/^[a-z][A-Za-z0-9]{0,31}$/.test(sk)) return { ok: false, error: "invalid surface " + JSON.stringify(sk).substring(0, 40) };
            var se = v[sk];
            if (se === null || typeof se !== "object" || Array.isArray(se)) return { ok: false, error: "expected an object for " + sk };
            var sm = {};
            if (se.material !== undefined) {
                var cm = check(mats, se.material);
                if (!cm.ok) return { ok: false, error: sk + " material: " + cm.error };
                sm.material = cm.value;
            }
            if (se.opacity !== undefined) {
                var co = check(opa, se.opacity);
                if (!co.ok) return { ok: false, error: sk + " opacity: " + co.error };
                sm.opacity = co.value;
            }
            // una entrada vacía no se guarda: hereda todo
            if (sm.material !== undefined || sm.opacity !== undefined) surf[sk] = sm;
        }
        return { ok: true, value: surf };
    case "location":
        if (v === null || typeof v !== "object" || Array.isArray(v)) return { ok: false, error: "expected an object" };
        if (Object.keys(v).length === 0) return { ok: true, value: {} };
        if (typeof v.lat !== "number" || !isFinite(v.lat) || v.lat < -90 || v.lat > 90
            || typeof v.lon !== "number" || !isFinite(v.lon) || v.lon < -180 || v.lon > 180)
            return { ok: false, error: "expected lat/lon" };
        var str = function (x, n) { return typeof x === "string" ? x.substring(0, n) : ""; };
        var name = str(v.name, 128);
        if (name.length === 0) return { ok: false, error: "expected a city name" };
        var tz = str(v.tz, 64);
        if (tz.length > 0 && !/^[A-Za-z0-9_+\-\/]+$/.test(tz)) return { ok: false, error: "invalid time zone" };
        return { ok: true, value: { name: name, admin: str(v.admin, 128), country: str(v.country, 128),
                                    lat: v.lat, lon: v.lon, tz: tz } };
    }
    return { ok: false, error: "unknown type" };
}

function defaults() {
    var doc = { schemaVersion: VERSION };
    for (var i = 0; i < CATALOG.length; i++) setPath(doc, CATALOG[i].id, clone(CATALOG[i].def));
    return doc;
}

/**
 * Valida un documento v2 ya parseado. Devuelve:
 *   structure  "" o el motivo por el que no se puede usar en absoluto
 *   newer      schemaVersion mayor que el soportado (modo lectura)
 *   values     { prop: valor } — el valor válido, o el default si faltaba o se rechazó
 *   errors     [{ id, error }] — lo rechazado, para el diagnóstico
 */
function validate(doc) {
    var r = { structure: "", newer: false, values: {}, errors: [] };
    if (doc === null || typeof doc !== "object" || Array.isArray(doc)) {
        r.structure = "the file is not a JSON object";
        return r;
    }
    if (typeof doc.schemaVersion !== "number" || Math.floor(doc.schemaVersion) !== doc.schemaVersion || doc.schemaVersion < 2) {
        r.structure = "missing or invalid schemaVersion";
        return r;
    }
    r.newer = doc.schemaVersion > VERSION;
    for (var i = 0; i < CATALOG.length; i++) {
        var e = CATALOG[i];
        var raw = getPath(doc, e.id);
        if (raw === undefined) { r.values[e.prop] = clone(e.def); continue; }
        var c = check(e, raw);
        if (c.ok) r.values[e.prop] = c.value;
        else { r.values[e.prop] = clone(e.def); r.errors.push({ id: e.id, error: c.error }); }
    }
    if (!(r.values.batteryCritical < r.values.batteryVeryLow && r.values.batteryVeryLow < r.values.batteryLow)) {
        for (var p of ["batteryLow", "batteryVeryLow", "batteryCritical"]) {
            var entry = entryByProp(p);
            r.values[p] = clone(entry.def);
            r.errors.push({ id: entry.id, error: "Battery thresholds must satisfy critical < very low < low" });
        }
    }
    return r;
}

/**
 * v1 (el JSON plano de XDG_STATE_HOME) → v2. Traduce TODAS las claves conocidas; lo que
 * no se conoce se guarda tal cual bajo `legacy.unknown` en vez de perderse.
 */
function migrateFlat(old) {
    var doc = defaults();
    var errors = [];
    var known = {};
    if (old === null || typeof old !== "object" || Array.isArray(old))
        return { doc: doc, errors: [{ id: "(file)", error: "legacy file is not a JSON object" }] };
    for (var i = 0; i < CATALOG.length; i++) {
        var e = CATALOG[i];
        if (!e.legacy) continue;
        known[e.legacy] = true;
        if (!(e.legacy in old)) continue;
        var v = old[e.legacy];
        if (e.prop === "motionMode") {
            if (typeof v !== "boolean") { errors.push({ id: e.id, error: "reduceMotion was not true/false" }); continue; }
            v = v ? "reduced" : "normal";
        }
        var c = check(e, v);
        if (c.ok) setPath(doc, e.id, c.value);
        else errors.push({ id: e.id, error: c.error + " (legacy " + e.legacy + ")" });
    }
    var unknown = {};
    var any = false;
    for (var k in old) if (!known[k]) { unknown[k] = old[k]; any = true; }
    if (any) setPath(doc, "legacy.unknown", unknown);
    doc.migratedFrom = { schemaVersion: 1, file: "XDG_STATE_HOME/sumi-shell/settings.json" };
    return { doc: doc, errors: errors };
}

/**
 * F3a: v2 → v3, en memoria y sin efectos (Settings hace antes la copia y después escribe).
 *   ctx.at          fecha ISO de la migración; ctx.backup: la copia del archivo original.
 * Las opciones de apps se conservan si existen. Sin ellas se usa la detección normal.
 * Conserva todo lo demás, desconocidos incluidos.
 *
 * F4a: `upgrade()` lleva un v2 (por v3) o un v3 a v4; uno que ya es v4 o más no se toca. Para v2 → v3
 * vale lo de arriba (upgrade2to3); para v3 → v4, upgrade3to4.
 */
function upgrade(doc, ctx) {
    ctx = ctx || {};
    if (doc === null || typeof doc !== "object" || Array.isArray(doc) || (doc.schemaVersion !== 2 && doc.schemaVersion !== 3))
        return { doc: doc, changed: false, errors: [] };
    var r = doc.schemaVersion === 2 ? upgrade2to3(doc, ctx) : { doc: clone(doc), errors: [] };
    var r4 = upgrade3to4(r.doc, ctx);
    return { doc: r4.doc, changed: true, errors: r.errors.concat(r4.errors) };
}

/**
 * F4a: v3 → v4, en memoria y sin efectos.
 *   ctx.declared  los tipos que ya declara providers.json.
 * Un valor ya escrito se conserva. La sincronización externa se activa por elección del usuario.
 */
function upgrade3to4(doc, ctx) {
    var out = clone(doc);
    var declared = Array.isArray(ctx.declared) ? ctx.declared : [];
    out.schemaVersion = 4;
    var kinds = ["wallpaper", "theme", "thumbnails", "updates"];
    for (var i = 0; i < kinds.length; i++)
        if (getPath(out, "providers." + kinds[i]) === undefined)
            setPath(out, "providers." + kinds[i], declared.indexOf(kinds[i]) >= 0 ? "script" : "auto");
    if (getPath(out, "theme.desktopSync") === undefined) setPath(out, "theme.desktopSync", "off");
    var mig = Array.isArray(out.migrations) ? out.migrations : [];
    mig.push({ from: 3, to: 4, at: ctx.at || "", backup: ctx.backup || "" });
    out.migrations = mig;
    return { doc: out, errors: [] };
}

function upgrade2to3(doc, ctx) {
    var errors = [];
    var out = clone(doc);
    out.schemaVersion = 3;
    for (var prop of ["terminal", "terminalExec", "browser"])
        if (getPath(out, "apps." + prop) === undefined) setPath(out, "apps." + prop, "auto");
    var every = {};
    var olds = [["dotbackupEveryDays", "dotbackup"], ["diskbackupEveryDays", "diskbackup"]];
    var dash = getPath(out, "shell.dashboard");
    for (var i = 0; i < olds.length; i++) {
        if (!dash || typeof dash !== "object" || Array.isArray(dash) || !(olds[i][0] in dash)) continue;
        var d = dash[olds[i][0]];
        if (typeof d === "number" && Math.floor(d) === d && d >= 0 && d <= 30) { if (d > 0) every[olds[i][1]] = d; }
        else errors.push({ id: "shell.dashboard." + olds[i][0], error: "not 0-30 days; dropped" });
        delete dash[olds[i][0]];
    }
    var prev = getPath(out, "shell.dashboard.taskEveryDays");
    if (prev && typeof prev === "object" && !Array.isArray(prev))
        for (var k in prev) every[k] = prev[k];
    setPath(out, "shell.dashboard.taskEveryDays", every);
    var mig = Array.isArray(out.migrations) ? out.migrations : [];
    mig.push({ from: 2, to: 3, at: ctx.at || "", backup: ctx.backup || "" });
    out.migrations = mig;
    return { doc: out, errors: errors };
}

/** El documento a escribir: el anterior (conserva campos desconocidos) con los valores actuales. */
function build(base, values) {
    var doc = (base && typeof base === "object" && !Array.isArray(base)) ? clone(base) : defaults();
    doc.schemaVersion = VERSION;
    for (var i = 0; i < CATALOG.length; i++) {
        var e = CATALOG[i];
        if (e.prop in values) setPath(doc, e.id, clone(values[e.prop]));
    }
    return doc;
}

function serialize(doc) { return JSON.stringify(doc, null, 2) + "\n"; }

function isDefault(prop, v) {
    var e = entryByProp(prop);
    return e ? JSON.stringify(e.def) === JSON.stringify(v) : true;
}

/** 12D: los grupos de los presets, en orden de la UI. */
var PRESET_GROUPS = ["appearance", "layout", "motion"];

function entryById(id) {
    for (var i = 0; i < CATALOG.length; i++)
        if (CATALOG[i].id === id) return CATALOG[i];
    return null;
}

/** 12E: las entradas que salen en un export (y que un import puede escribir). */
function exportable() {
    var out = [];
    for (var i = 0; i < CATALOG.length; i++) if (CATALOG[i].export !== false) out.push(CATALOG[i]);
    return out;
}

/** Las entradas presetables (con grupo). */
function presetable() {
    var out = [];
    for (var i = 0; i < CATALOG.length; i++) if (CATALOG[i].preset) out.push(CATALOG[i]);
    return out;
}

function propsInSection(section) {
    var out = [];
    for (var i = 0; i < CATALOG.length; i++) {
        var field = CATALOG[i];
        if (field.section === section || (field.subsection && field.subsection === section)) out.push(field.prop);
    }
    return out;
}

if (typeof module !== "undefined")
    module.exports = { VERSION: VERSION, CATALOG: CATALOG, def: def, check: check, defaults: defaults,
        validate: validate, migrateFlat: migrateFlat, build: build, serialize: serialize, upgrade: upgrade,
        upgrade2to3: upgrade2to3, upgrade3to4: upgrade3to4,
        TASK_ID: TASK_ID,
        isDefault: isDefault, getPath: getPath, propsInSection: propsInSection, entryByProp: entryByProp,
        entryById: entryById, presetable: presetable, exportable: exportable, PRESET_GROUPS: PRESET_GROUPS };
