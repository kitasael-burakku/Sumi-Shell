pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "../theme"
import "../services"
import "../components"
import "../lib/settings-schema.js" as Schema
import "../lib/system-catalog.js" as SysCat
import "../lib/surface-materials.js" as SurfaceMaterials
import "../lib/settings-nav.js" as Nav
import "../lib/text-wrap.js" as TextWrap
import "../lib/settings-sections.js" as Sections
import "../lib/bar-edge.js" as BarEdge
import "../lib/accent-zones.js" as Zones

/**
 * Settings UI independiente (2026-11-07): este archivo es ahora el CONTENIDO de la tarjeta
 * flotante `core/SettingsLayer` (`floating: true`; ventana y ciclo de vida en la capa y en
 * `services/SettingsUi`). Ya no es una superficie del island. Lo que cambió aquí:
 *   - el índice despliega un grupo a la vez; al buscar o volver en el historial sigue la página;
 *   - si hay altura, las pestañas se quedan a la vista mientras se desplazan los ajustes;
 *   - Back/Forward recorren las páginas visitadas (sin host del island): Alt+←/→;
 *   - los enlaces a superficies del island las abren encima, con Settings debajo.
 * Las filas, la tabla, la búsqueda, el teclado y las preferencias siguen igual. El texto
 * siguiente describe el marco de la fase 9A y sigue valiendo para la tabla y el teclado.
 *
 * Settings — el marco de las TRES surfaces de configuración (fase 9A,
 * rediseno/docs/futureSettingssurface.md §3, §5-§7; DESIGN §5 familia Configuración).
 *
 * `settings` (Shell), `settingsTheme` (Theme) y `settingsSystem` (System) son tres nombres
 * del host que comparten ESTE item (un loader): el host fija `dest` y el marco —cabecera
 * con breadcrumbs, Back/Forward/Close y sidebar— no se recrea ni se mueve al pasar de una a
 * otra. Sólo se releva el contenido, con un deslizamiento corto y un fundido
 * (ANIMATIONS «Centro de control → Wi-Fi/Bluetooth»: el panel no se mueve). Las tres tienen
 * el mismo tamaño fijo, así que el destino del panel no cambia nunca.
 *
 * Las páginas salen de una tabla (`tree`): destino → páginas → secciones → filas. Cada
 * fila dice a qué propiedad de `Settings` pertenece (Custom + reset por el catálogo,
 * `lib/settings-schema.js`); las que no son del shell (matugen) no tienen reset. Un dato
 * vive en UNA página (futureSettingssurface §4): otra sección sólo puede enlazarlo.
 *
 * Contexto por página: al cambiar de página se guardan su scroll y su fila; `saveContext`
 * devuelve todo para Back/Forward (DESIGN §3). Abrir por un acceso directo empieza en
 * Shell → General (y Theme → Wallpaper, System → Power); volver con Esc desde una surface
 * enlazada (Open wallpaper list…) conserva la página.
 *
 * Teclado: Tab alterna sidebar ⇄ contenido. En la sidebar ↑↓ recorren y Enter / → abren.
 * En el contenido, como antes: ↑↓ filas, ←→ cambian, Enter / Espacio activan, Supr
 * resetea el campo y Mayús+Supr la sección. En un panel estrecho la sidebar se vuelve una
 * fila con los tres destinos y un desplegable de páginas (futureSettingssurface §3).
 */
Surface {
    id: root

    mTop: 10
    mLeft: 14
    mRight: 14
    mBottom: 12

    /**
     * Settings UI (2026-11-07): contenido de la tarjeta flotante, sin host. `initialContext`, la
     * vista que dejó la última visita (la restaura al crearse).
     */
    property bool floating: false
    property var initialContext: null
    /** Flotante: un enlace a una superficie del island (la capa lo abre encima, por `core/Screens`). */
    signal requestLink(string name, string key)
    /** Restaurando la vista al abrir: las páginas no se deslizan. */
    property bool resuming: false

    /** `settings` | `settingsTheme` | `settingsSystem` — lo pone el host; flotante, la propia navegación. */
    property string dest: "settings"
    /**
     * 2026-11-19: el límite de Length de la barra en esta pantalla y su borde (px de contenido y px de borde), que pone
     * core/SettingsLayer desde core/Screen. Sin él (0), el deslizador baja hasta `BarEdge.MIN_PCT`.
     */
    property real barLimit: 0
    property real barAvail: 0
    readonly property string destId: root.dest === "settingsTheme" ? "theme"
        : root.dest === "settingsSystem" ? "system" : "shell"
    readonly property var destSurface: ({ shell: "settings", theme: "settingsTheme", system: "settingsSystem" })
    readonly property var defaultPages: ({ shell: "general", theme: "overview", system: "audio" })

    /** La página de cada destino. Se reasigna entero (escribir dentro de un `var` no notifica). */
    property var pageOf: ({ shell: "general", theme: "overview", system: "audio" })
    /** Scroll y fila por página (`dest/page`), guardados al salir de ella. */
    property var scrollOf: ({})
    property var rowOf: ({})

    readonly property string pageKey: root.destId + "/" + root.pageOf[root.destId]
    /** La página que se VE. Sigue a `pageKey` en `swapTo`, que guarda antes la anterior. */
    property string shownKey: ""
    onPageKeyChanged: root.swapTo(root.pageKey)

    /** "content" | "nav": dónde actúan las flechas. */
    property string zone: "content"
    property int navIndex: 0
    property int kbIndex: 0
    property point lastPointer: Qt.point(-1, -1)

    /**
     * Estrecho: el ancho de DESTINO (no el animado: decidir columnas con el ancho animado
     * mueve el destino a media apertura, 8G-2) no llega a la familia Configuración.
     */
    readonly property real frameW: root.width + (root.mLeft + root.mRight) * root.s
    readonly property bool compact: root.frameW < Metrics.settingsCompactW * root.s
    /** La letra de las pastillas de `Choice` (spacious): con ella `choiceLong` mide si caben en media fila. */
    FontMetrics { id: pillMetrics; font.family: Typography.ui; font.pixelSize: Typography.body * root.s }
    /** La ayuda se abre en la fila; el panel contextual anterior ya no reserva ancho. */
    readonly property bool asideShown: false

    /** La opacidad del vidrio: la global y la de cada superficie eligen entre los mismos valores. */
    readonly property var glassOptions: [{ label: "75%", value: 0.75 }, { label: "80%", value: 0.8 }, { label: "85%", value: 0.85 },
                                         { label: "90%", value: 0.9 }, { label: "95%", value: 0.95 }, { label: "98%", value: 0.98 },
                                         { label: "Opaque", value: 1.0 }]

    // ---- la tabla ---------------------------------------------------------------------

    readonly property var tree: [
        { id: "shell", title: "Shell", glyph: "cog", pages: [
            // 9C-1: las secciones con `level` («advanced», «experimental») van plegadas bajo su
            // cabecera, dentro de su página (§3: no son destinos globales). Sin contenido real no
            // hay cabecera: Experimental no aparece hasta que exista algo experimental.
            { id: "general", title: "General", sections: [
                { title: "Interface", key: "General", rows: [
                    // 2026-11-16 (pedido del autor): ocho escalas, finas alrededor de 1, en pastillas
                    { id: "scale", prop: "uiScale", kind: "choice", name: "Interface scale", pills: true,
                      options: [{ label: "0.8", value: 0.8 }, { label: "0.85", value: 0.85 },
                                { label: "0.9", value: 0.9 }, { label: "0.95", value: 0.95 },
                                { label: "1.0", value: 1.0 }, { label: "1.1", value: 1.1 },
                                { label: "1.25", value: 1.25 }, { label: "1.5", value: 1.5 }] },
                    { id: "autoHide", prop: "autoHide", kind: "toggle", name: "Auto-hide" },
                    { id: "reserve", prop: "reserveSpace", kind: "toggle", name: "Reserve space" },
                    { id: "ws", prop: "workspaceCount", kind: "choice", name: "Workspace dots",
                      options: [{ label: "live", value: 0 }, { label: "3", value: 3 },
                                { label: "5", value: 5 }, { label: "8", value: 8 }] }
                ] },
                // 2026-11-12: las piezas redondas a los lados (también con la muesca), cada una por su lado.
                { title: "Capsule & Edge", key: "Island", rows: [
                    { id: "musicCircle", prop: "islandMusicCircle", kind: "toggle", name: "Music circle" },
                    { id: "netCircle", prop: "islandNetCircle", kind: "toggle", name: "Network circle" },
                    // 2026-11-17: gestos sobre la forma (también el notch; la barra tiene los suyos)
                    { id: "islandWheel", prop: "islandWheel", kind: "choice", name: "Scroll",
                      options: [{ label: "Volume", value: "volume" }, { label: "Off", value: "off" }] },
                    { id: "islandMiddle", prop: "islandMiddleClick", kind: "choice", name: "Middle click",
                      options: [{ label: "Play/pause", value: "playpause" }, { label: "Off", value: "off" }] }
                ] },
                { title: "Lifecycle", key: "Lifecycle", level: "advanced", rows: [
                    { id: "unload", prop: "unloadSec", kind: "choice", name: "Unload after",
                      options: [{ label: "30 s", value: 30 }, { label: "60 s", value: 60 }, { label: "120 s", value: 120 }] }
                ] },
                // Integraciones avanzadas (§5): comprueban que no haya otro dueño. El servidor de
                // notificaciones sólo se enseña: se cambia con `notif-server`, que reinicia (ADR-29).
                { title: "Integrations", key: "Integrations", level: "advanced", rows: [
                    { id: "polkit", prop: "polkitAgent", kind: "toggle", name: "Polkit agent" },
                    { id: "notifServer", prop: "", kind: "info", name: "Notification server" }
                ] }
            ] },
            { id: "animations", title: "Animations", sections: [
                { title: "Motion", key: "Motion", rows: [
                    { id: "motion", prop: "motionMode", kind: "choice", name: "Motion",
                      options: [{ label: "Normal", value: "normal" }, { label: "Reduced", value: "reduced" },
                                { label: "Off", value: "off" }] },
                    { id: "speed", prop: "motionSpeed", kind: "choice", name: "Global speed",
                      options: [{ label: "Slower", value: 0.75 }, { label: "Default", value: 1.0 },
                                { label: "Faster", value: 1.25 }] }
                ] },
                { title: "Windows", key: "Window style", rows: [
                    { id: "windowStyle", prop: "windowStyle", kind: "windowStyle", name: "Window style" }
                ] },
                { title: "Dynamic Bar", key: "Bar panels", rows: [
                    { id: "barPanels", prop: "barPanels", kind: "windowStyle", family: "bar", name: "Bar panels" }
                ] },
                { title: "Capsule & Edge", key: "Island style", rows: [
                    { id: "islandStyle", prop: "islandStyle", kind: "windowStyle", family: "island", name: "Capsule style" }
                ] }
            ] },
            { id: "interaction", title: "Interaction", sections: [
                { title: "Pointer and keyboard", key: "Interaction", rows: [
                    { id: "hoverPreview", prop: "hoverPreview", kind: "toggle", name: "Open on hover" },
                    // Informativo, sin toggle que los mezcle (§5 General e interacción).
                    { id: "focusInfo", prop: "", kind: "info", name: "Hover and keyboard focus" },
                    // Ayuda de atajos (2026-10-30): abre la tarjeta flotante; al cerrarla, Settings vuelve aquí
                    { id: "shortcutsHelp", prop: "", kind: "action", name: "Keyboard shortcuts", label: "Open" }
                ] }
            ] },
            /**
             * F3b/F3c (portabilidad, H-28, HC-13): los programas del usuario. Terminal y navegador ofrecen
             * Auto (con lo detectado), los instalados de su lista conocida y el elegido (`optionsOf`). La
             * forma de pasar la orden a la terminal, plegada.
             */
            { id: "apps", title: "Apps", sections: [
                { title: "Programs", key: "Apps", rows: [
                    { id: "terminal", prop: "appTerminal", kind: "choice", name: "Terminal", options: [], dynamic: "terminal" },
                    { id: "browser", prop: "appBrowser", kind: "choice", name: "Browser", options: [], dynamic: "browser" }
                ] },
                { title: "Command style", key: "", level: "advanced", rows: [
                    { id: "launchScope", prop: "appLaunchScope", kind: "choice", name: "Launch applications",
                      options: [{ label: "Auto", value: "auto" }, { label: "Systemd scope", value: "systemd" },
                                { label: "Direct", value: "direct" }] },
                    { id: "terminalExec", prop: "appTerminalExec", kind: "choice", name: "Pass the command with",
                      options: [{ label: "Auto", value: "auto" }, { label: "-e", value: "-e" },
                                { label: "--", value: "--" }, { label: "Nothing", value: "none" }] }
                ] },
                // F4b (portabilidad): quién pone los fondos. Auto dice qué backend detectó; Script = la orden
                // de providers.json (la del autor: su apply-wallpaper.sh); Off = no hay fondos aquí.
                { title: "Providers", key: "Providers", rows: [
                    { id: "wallProvider", prop: "providerWallpaper", kind: "choice", name: "Wallpapers", options: [],
                      dynamic: "wallProvider" },
                    // F4c: quién hace las miniaturas de la tira (Auto = las propias de la shell)
                    { id: "thumbProvider", prop: "providerThumbnails", kind: "choice", name: "Thumbnails",
                      options: [{ label: "Auto", value: "auto" }, { label: "Built-in", value: "builtin" },
                                { label: "Script (providers.json)", value: "script" }, { label: "Off", value: "none" }] },
                    // F4d: quién genera los colores (Auto/matugen = los propios, sólo de la shell salvo que
                    // providers.json declare tu config de matugen; Script = tus órdenes; Static = paleta fija)
                    { id: "themeProvider", prop: "providerTheme", kind: "choice", name: "Theme colours",
                      options: [{ label: "Auto", value: "auto" }, { label: "matugen", value: "matugen" },
                                { label: "Static only", value: "static" }, { label: "Script (providers.json)", value: "script" }] },
                    // F4d (PL-04): qué toca la shell fuera de sí al cambiar claro/oscuro, y devolverlo
                    { id: "desktopSync", prop: "themeDesktopSync", kind: "choice", name: "Desktop light and dark",
                      options: [{ label: "Off", value: "off" }, { label: "Light/dark preference", value: "colorScheme" },
                                { label: "Preference and GTK theme", value: "full" }] },
                    { id: "desktopRestore", prop: "", kind: "action", name: "Restore desktop settings", label: "Restore" },
                    // F4e: de dónde salen las actualizaciones (Auto/pacman = las propias; Off = no hay fuente)
                    { id: "updatesProvider", prop: "providerUpdates", kind: "choice", name: "System updates",
                      options: [{ label: "Auto", value: "auto" }, { label: "pacman", value: "pacman" },
                                { label: "Script (providers.json)", value: "script" }, { label: "Off", value: "none" }] }
                ] }
            ] },
            /**
             * 8F-2 (futureSettingssurface §Dock): por MONITOR, el de esta pantalla. Sin `prop`:
             * no es un campo plano del ConfigStore sino `monitors[id].dock`; no entra en Reset.
             */
            // En la UI «Notch» (2026-11-12, pedido del usuario: un dock es otra cosa); ids y clave `dock` intactos.
            { id: "dock", title: "Edge", sections: [
                { title: "This monitor", key: "", rows: [
                    { id: "dock", prop: "", kind: "dock", name: "Enable Edge" },
                    { id: "dockPreview", prop: "", kind: "dockPreview", name: "Preview Edge" },
                    // Enlaces, no otra copia del dato (futureSettingssurface §Dock y §4).
                    { id: "dockMotion", prop: "", kind: "goto", name: "Motion mode", path: "shell/animations/motion" },
                    { id: "dockOsd", prop: "", kind: "goto", name: "OSD settings", path: "shell/osd/osd" },
                    { id: "dockGestures", prop: "", kind: "goto", name: "Gestures", path: "shell/general/islandWheel" }
                ] },
                // Notch en vivo (2026-11-17): forma y color (también la barra-muesca) y el reposo; para todos los monitores.
                { title: "Shape", key: "Notch", rows: [
                    { id: "notchCorners", prop: "notchCorners", kind: "choice", name: "Corners",
                      options: [{ label: "Rounded", value: "rounded" }, { label: "Soft", value: "soft" }, { label: "Tight", value: "tight" }] },
                    { id: "notchFlare", prop: "notchFlare", kind: "choice", name: "Flare",
                      options: [{ label: "Long", value: "long" }, { label: "Short", value: "short" }, { label: "None", value: "none" }] },
                    { id: "notchColor", prop: "notchColor", kind: "choice", name: "Color",
                      options: [{ label: "Theme", value: "theme" }, { label: "Black", value: "black" }] },
                    { id: "notchRest", prop: "notchRest", kind: "choice", name: "At rest",
                      options: [{ label: "Clock", value: "clock" }, { label: "Minimal", value: "minimal" }] }
                ] },
                // Las orejas: qué actividades asoman a los lados de la muesca en reposo.
                { title: "Live activities", key: "NotchActivities", rows: [
                    { id: "notchActMusic", prop: "notchActMusic", kind: "toggle", name: "Music" },
                    { id: "notchViz", prop: "notchVisualizerFps", kind: "choice", name: "Audio visualizer",
                      options: [{ label: "Off", value: 0 }, { label: "15", value: 15 },
                                { label: "30", value: 30 }, { label: "60", value: 60 }] },
                    { id: "notchActRecording", prop: "notchActRecording", kind: "toggle", name: "Screen recording" },
                    { id: "notchActSpeed", prop: "notchActSpeed", kind: "toggle", name: "Speed test" },
                    { id: "notchActWork", prop: "notchActWork", kind: "toggle", name: "Tasks and downloads" },
                    { id: "notchActPower", prop: "notchActPower", kind: "toggle", name: "Charger" },
                    { id: "notchActCopy", prop: "notchActCopy", kind: "toggle", name: "Copied" },
                    { id: "notchActBluetooth", prop: "notchActBluetooth", kind: "toggle", name: "Bluetooth audio" },
                    { id: "notchActWorkspace", prop: "notchActWorkspace", kind: "toggle", name: "Workspace" }
                ] }
            ] },
            // La barra persistente, por monitor: el MISMO `monitors[id].presentation` que Super+Ctrl+P.
            { id: "panels", title: "Layout", sections: [
                { title: "This monitor", key: "", rows: [
                    { id: "bar", prop: "", kind: "bar", name: "Dynamic Bar" },
                    // 2026-11-19: dónde va la barra de ESTE monitor (`monitors[id].barEdge|barLength`; siempre centrada)
                    { id: "barEdge", prop: "", kind: "barEdge", name: "Position" },
                    { id: "barLength", prop: "", kind: "barLength", name: "Length" },
                    { id: "barReset", prop: "", kind: "action", name: "Default position and length", label: "Reset" },
                    { id: "layoutDock", prop: "", kind: "goto", name: "Edge", path: "shell/dock/dock" }
                ] },
                { title: "Windows", key: "Surfaces", rows: [
                    { id: "thumbs", prop: "minimizerThumbs", kind: "toggle", name: "Window thumbnails" }
                ] },
                { title: "Launcher", key: "Launcher", rows: [
                    { id: "scrollbar", prop: "launcherScrollbar", kind: "choice", name: "Scrollbar",
                      options: [{ label: "Left", value: "left" }, { label: "Right", value: "right" }] }
                ] },
                // Selector de emojis (2026-11-17): qué hace ⏎; Shift+⏎ hace lo otro.
                { title: "Emoji picker", key: "Emoji picker", rows: [
                    { id: "emojiAction", prop: "emojiAction", kind: "choice", name: "Enter",
                      options: [{ label: "Copy", value: "copy" }, { label: "Copy and paste", value: "paste" }] }
                ] }
            ] },
            // Qué módulos opcionales hay y cómo están: cada uno se cambia en SU página (enlaces).
            { id: "modules", title: "Modules", sections: [
                { title: "Optional modules", key: "", rows: [
                    { id: "modWeather", prop: "", kind: "goto", name: "Weather", path: "shell/calendar/weather" },
                    { id: "modDock", prop: "", kind: "goto", name: "Edge", path: "shell/dock/dock" },
                    { id: "modPolkit", prop: "", kind: "goto", name: "Polkit agent", path: "shell/general/polkit" },
                    { id: "modNotif", prop: "", kind: "goto", name: "Notification server", path: "shell/general/notifServer" }
                ] }
            ] },
            // 11A-2: la página que la 9C-1 dejó sin crear (no había opciones con efecto).
            /**
             * F3d-2: las frecuencias salen de las tareas con `lastRun` de tasks.json (antes, dotbackup y
             * diskbackup fijos); la fila de arriba dice qué hay en tasks.json (o por qué no se usa).
             */
            { id: "dashboard", title: "Dashboard", sections: [
                { title: "Maintenance tasks", key: "", rows: [
                    { id: "tasksFile", prop: "", kind: "info", name: "Maintenance tasks" }
                ] },
                { title: "Backups", key: "Dashboard", dynamic: "taskEvery", rows: [] }
            ] },
            // Decisión del usuario (9, 2026-09-26): Weather va en Shell → Calendar, como la spec.
            { id: "calendar", title: "Calendar", sections: [
                { title: "Calendar", key: "Calendar", rows: [
                    { id: "firstDay", prop: "calendarFirstDay", kind: "choice", name: "First day of the week",
                      options: [{ label: "Locale", value: "locale" }, { label: "Monday", value: "monday" },
                                { label: "Sunday", value: "sunday" }] },
                    { id: "clock", prop: "clockFormat", kind: "choice", name: "Clock",
                      options: [{ label: "24-hour", value: "24h" }, { label: "12-hour", value: "12h" }] }
                ] },
                { title: "Weather", key: "Weather", rows: [
                    { id: "weather", prop: "weatherEnabled", kind: "toggle", name: "Weather" },
                    { id: "city", prop: "weatherLocation", kind: "location", name: "City" },
                    { id: "units", prop: "weatherUnits", kind: "choice", name: "Units",
                      options: [{ label: "°C", value: "celsius" }, { label: "°F", value: "fahrenheit" }] }
                ] }
            ] },
            { id: "notifications", title: "Notifications", sections: [
                { title: "Popups", key: "Notifications", rows: [
                    // 2026-11-19: dónde salen y a qué distancia de los bordes (core/NotifLayer)
                    { id: "notifPos", prop: "notifPosition", kind: "notifPos", name: "Position" },
                    { id: "notifMargin", prop: "notifMargin", kind: "range", name: "Distance from the edges",
                      min: 8, max: 64, step: 4, unit: "px" },
                    { id: "popupSec", prop: "notifPopupSec", kind: "choice", name: "Popup duration",
                      options: [{ label: "3 s", value: 3 }, { label: "4 s", value: 4 },
                                { label: "6 s", value: 6 }, { label: "10 s", value: 10 }] },
                    // DND es estado del centro, no una preferencia: se enlaza, no se copia.
                    { id: "dnd", prop: "", kind: "link", name: "Do Not Disturb", target: "notifications" }
                ] }
            ] },
            { id: "osd", title: "OSD", sections: [
                { title: "On-screen display", key: "OSD", rows: [
                    { id: "osd", prop: "osdPlacement", kind: "choice", name: "Over a panel",
                      options: [{ label: "Beside", value: "sides" }, { label: "Below", value: "below" }] },
                    { id: "osdMs", prop: "osdMs", kind: "choice", name: "Duration",
                      options: [{ label: "1.2 s", value: 1200 }, { label: "1.8 s", value: 1800 },
                                { label: "2.5 s", value: 2500 }, { label: "3.5 s", value: 3500 }] },
                    { id: "osdValue", prop: "osdShowValue", kind: "toggle", name: "Show the value" }
                ] }
            ] },
            /**
             * Grabador 2.0 (2026-10-29, pedido del usuario): la configuración del grabador, antes en recorder.json.
             * La surface edita los mismos ajustes (sistema, micro, preset, cuenta atrás); aquí además lo técnico. Lo
             * que se grabará lo resuelve el helper (`ScreenRecorder.plan`, «Will record»); los codificadores, fuentes
             * y pantallas salen de su `probe`: sólo se ofrece lo que funciona en esta máquina.
             */
            { id: "recording", title: "Screen recording", sections: [
                { title: "Quality preset", key: "Recorder preset", rows: [
                    { id: "recPreset", prop: "recPreset", kind: "choice", name: "Preset", rec: true,
                      options: [{ label: "Standard", value: "standard" }, { label: "High", value: "high" },
                                { label: "Custom", value: "custom" }] },
                    { id: "recNow", prop: "", kind: "info", name: "Will record", rec: true }
                ] },
                { title: "Custom preset", key: "Recorder custom", rows: [
                    { id: "recEncoder", prop: "recEncoder", kind: "choice", name: "Encoder", options: [], dynamic: "recEncoder", rec: true },
                    { id: "recFps", prop: "recFps", kind: "choice", name: "Frame rate", options: [], dynamic: "recFps", rec: true },
                    { id: "recQuality", prop: "recQuality", kind: "choice", name: "Quality", rec: true,
                      options: [{ label: "Balanced", value: "balanced" }, { label: "High", value: "high" },
                                { label: "Very high", value: "veryhigh" }, { label: "Bitrate", value: "bitrate" }] },
                    { id: "recBitrate", prop: "recBitrate", kind: "choice", name: "Bitrate", rec: true,
                      options: [{ label: "4 Mb/s", value: 4 }, { label: "8 Mb/s", value: 8 }, { label: "12 Mb/s", value: 12 },
                                { label: "20 Mb/s", value: 20 }, { label: "40 Mb/s", value: 40 }, { label: "80 Mb/s", value: 80 }] },
                    { id: "recHeight", prop: "recHeight", kind: "choice", name: "Resolution", options: [], dynamic: "recHeight", rec: true }
                ] },
                { title: "Format", key: "Recorder format", rows: [
                    { id: "recFormat", prop: "recFormat", kind: "choice", name: "Container", options: [], dynamic: "recFormat", rec: true },
                ] },
                { title: "Compatibility", key: "Recorder format", level: "advanced", rows: [
                    { id: "recEncoders", prop: "", kind: "info", name: "Encoders that work here", rec: true },
                    { id: "recProbe", prop: "", kind: "action", name: "Test the encoders again", label: "Test", rec: true },
                    { id: "recCursor", prop: "", kind: "info", name: "Pointer", rec: true },
                    { id: "recPause", prop: "", kind: "info", name: "Pause", rec: true }
                ] },
                { title: "Custom values", key: "Recorder custom", level: "advanced", rows: [
                    { id: "recFpsOther", prop: "", kind: "recText", field: "fps", name: "Other frame rate", rec: true, placeholder: "1–240" },
                    { id: "recHeightOther", prop: "", kind: "recText", field: "height", name: "Other height", rec: true, placeholder: "900" }
                ] },
                { title: "Audio", key: "Recorder audio", rows: [
                    { id: "recSystemAudio", prop: "recSystemAudio", kind: "toggle", name: "System audio", rec: true },
                    { id: "recSystemSource", prop: "recSystemSource", kind: "choice", name: "System audio from", options: [],
                      dynamic: "recSystemSource", rec: true },
                    { id: "recMic", prop: "recMic", kind: "toggle", name: "Microphone", rec: true },
                    { id: "recMicSource", prop: "recMicSource", kind: "choice", name: "Microphone device", options: [],
                      dynamic: "recMicSource", rec: true },
                    { id: "recAudioCodec", prop: "recAudioCodec", kind: "choice", name: "Audio codec", rec: true,
                      options: [{ label: "AAC", value: "aac" }, { label: "Opus", value: "opus" }] },
                    { id: "recAudioBitrate", prop: "recAudioBitrate", kind: "choice", name: "Audio bitrate", rec: true,
                      options: [{ label: "96 kb/s", value: 96 }, { label: "128 kb/s", value: 128 }, { label: "160 kb/s", value: 160 },
                                { label: "192 kb/s", value: 192 }, { label: "256 kb/s", value: 256 }] },
                    { id: "recSampleRate", prop: "recSampleRate", kind: "choice", name: "Sample rate", rec: true,
                      options: [{ label: "44.1 kHz", value: 44100 }, { label: "48 kHz", value: 48000 }] },
                    { id: "recMix", prop: "", kind: "info", name: "System audio and microphone", rec: true }
                ] },
                { title: "Files", key: "Recorder files", rows: [
                    { id: "recDir", prop: "recDir", kind: "recText", field: "dir", name: "Folder", rec: true, placeholder: "~/Videos/Recordings" },
                    { id: "recName", prop: "recName", kind: "recText", field: "name", name: "File name", rec: true,
                      placeholder: "Recording {date} {time}" },
                    { id: "recExisting", prop: "", kind: "info", name: "Existing files", rec: true },
                    { id: "recOpenDir", prop: "", kind: "action", name: "Recordings folder", label: "Open", rec: true }
                ] },
                { title: "Behavior", key: "Recorder behavior", rows: [
                    { id: "recDelay", prop: "recDelay", kind: "choice", name: "Countdown", rec: true,
                      options: [{ label: "Off", value: 0 }, { label: "3 s", value: 3 }, { label: "5 s", value: 5 },
                                { label: "10 s", value: 10 }] },
                    { id: "recIndicator", prop: "recIndicator", kind: "toggle", name: "Recording indicator", rec: true },
                    { id: "recTimer", prop: "recTimer", kind: "toggle", name: "Timer", rec: true },
                    { id: "recIslandControls", prop: "recIslandControls", kind: "toggle", name: "Controls under the capsule", rec: true },
                    { id: "recBarControls", prop: "recBarControls", kind: "toggle", name: "Controls in the Dynamic Bar", rec: true },
                    { id: "recNotify", prop: "recNotify", kind: "toggle", name: "Notify when saved", rec: true },
                    { id: "recOpenFolder", prop: "recOpenFolder", kind: "toggle", name: "Open the folder when saved", rec: true },
                    { id: "recRememberMode", prop: "recRememberMode", kind: "toggle", name: "Remember the last mode", rec: true }
                ] }
            ] },
            // Fase 15H: el visualizador se retiró con el Lock nuevo (LOCK-D13); Preview abre la vista previa aparte.
            { id: "lock", title: "Lock screen", sections: [
                { title: "Lock screen", key: "Lock screen", rows: [
                    { id: "avatar", prop: "lockAvatar", kind: "path", name: "Avatar", round: true, placeholder: "" },
                    { id: "fetch", prop: "lockFetchImage", kind: "path", name: "Fetch image", round: false,
                      placeholder: Quickshell.env("HOME") + "/.config/fastfetch/fastfetchlogo/minimaru.png" },
                    { id: "lockPreview", prop: "", kind: "action", name: "Preview lock screen", label: "Preview" }
                ] },
                // F5d (portabilidad, H-07): por dónde llega el bloqueo. Auto = logind si alguien lo atiende (hypridle con
                // el helper de la shell, con hyprlock u otro), directo si nadie; la fila de abajo dice quién lo atiende.
                { title: "Lock requests", key: "Lock screen", rows: [
                    { id: "lockEntry", prop: "lockEntry", kind: "choice", name: "Send lock requests",
                      options: [{ label: "Auto", value: "auto" }, { label: "Through logind", value: "logind" },
                                { label: "Directly", value: "direct" }] },
                    { id: "lockHandler", prop: "", kind: "info", name: "Handled by" }
                ] },
                // F5e (portabilidad, H-26): la pila PAM. Elegir otra NO la guarda: «Test and use» autentica con ella sin
                // bloquear y sólo si sale bien se usa (desde el siguiente bloqueo).
                { title: "Authentication", key: "Lock screen", rows: [
                    { id: "pamInfo", prop: "", kind: "info", name: "PAM service" },
                    { id: "pamChoice", prop: "", kind: "pamChoice", name: "Try another" },
                    { id: "pamTest", prop: "", kind: "pamTest", name: "Test and use" }
                ] }
            ] },
            // Sumi SDDM (2026-11-22): la pantalla de inicio de sesión. Los valores son de Sumi SDDM (services/SddmTheme,
            // orden `sumi-sddm`), no de settings.json. Apply / Use / Restore pasan por pkexec (contraseña cada vez).
            // Desde el 2026-11-23 los ajustes, la vista previa y el sistema viven en su ventana (core/LoginLayer);
            // aquí quedan el estado, la puerta («Open») y las tres acciones del sistema.
            { id: "sddm", title: "Login screen", sections: [
                { title: "Login screen", key: "", rows: [
                    { id: "sddmStatus", prop: "", kind: "info", name: "Sumi SDDM" },
                    { id: "sddmApplied", prop: "", kind: "info", name: "On the login screen" },
                    { id: "sddmOpen", prop: "", kind: "action", name: "Open Login screen", label: "Open" },
                    { id: "sddmApply", prop: "", kind: "action", name: "Apply to the login screen", label: "Apply" },
                    { id: "sddmActivate", prop: "", kind: "action", name: "Use as the login screen", label: "Use" },
                    { id: "sddmDeactivate", prop: "", kind: "action", name: "Restore the previous login screen", label: "Restore" }
                ] }
            ] },
            // 12E (futureSettingssurface §12): portabilidad. Export nunca incluye secretos,
            // integraciones, monitores ni datos de cuenta; Import analiza antes de aplicar.
            { id: "portability", title: "Import and export", sections: [
                { title: "Export", key: "", rows: [
                    { id: "exportSettings", prop: "", kind: "action", name: "Export settings", label: "Export" },
                    { id: "exportAll", prop: "", kind: "action", name: "Export settings and your presets", label: "Export" },
                    { id: "exportResult", prop: "", kind: "info", name: "Last export" }
                ] },
                { title: "Import", key: "", rows: [
                    { id: "importFile", prop: "", kind: "importFile", name: "File to import" }
                ] },
                { title: "Before importing", key: "", dynamic: "importPreview", rows: [] }
            ] }
        ] },
        { id: "theme", title: "Theme", glyph: "palette", pages: [
            // 9D-1 (futureSettingssurface §6): identidad visual. Theme presenta y enlaza; la
            // tubería (apply-wallpaper.sh → matugen) sigue siendo la dueña (§4, un dueño por dato).
            { id: "overview", title: "Overview", sections: [
                { title: "Current theme", key: "", rows: [
                    { id: "themeCard", prop: "", kind: "themeCard", name: "Current theme" },
                    { id: "ovWallpapers", prop: "", kind: "link", name: "Wallpaper list", target: "wallpaper" },
                    { id: "ovProfiles", prop: "", kind: "link", name: "Visual profiles", target: "theme" },
                    { id: "ovRandom", prop: "", kind: "action", name: "Random wallpaper", label: "Random" }
                ] }
            ] },
            { id: "wallpaper", title: "Wallpaper", sections: [
                { title: "Wallpaper", key: "Wallpaper", rows: [
                    { id: "wallCurrent", prop: "", kind: "wallCurrent", name: "Current wallpaper" },
                    { id: "wallRestore", prop: "", kind: "action", name: "Restore previous", label: "Restore" },
                    { id: "video", prop: "wallpaperVideoPreview", kind: "toggle", name: "Video preview" },
                    // no es un ajuste del shell: lo hacen los modos del rice (desktop-mode.sh) y mpvpaper
                    { id: "videoPause", prop: "", kind: "info", name: "Video wallpapers" },
                    { id: "openWallpapers", prop: "", kind: "link", name: "Wallpaper list", target: "wallpaper" }
                ] },
                // 12G: el fondo de cada pantalla (el rice guarda las excepciones aparte) y de dónde
                // salen los colores: siempre del fondo de TODAS, de un color propio o del estático
                { title: "Screens", key: "", dynamic: "screens", rows: [] },
                // Metadatos locales (WallpaperMeta): Recent = aplicaciones recientes, no «los más usados».
                // 10B: un solo programador (WallpaperRotation), apagado por defecto
                { title: "Rotation", key: "Rotation", rows: [
                    { id: "rotOn", prop: "wallRotation", kind: "toggle", name: "Rotate automatically" },
                    { id: "rotEvery", prop: "wallRotationMinutes", kind: "choice", name: "Every",
                      options: [{ label: "15 min", value: 15 }, { label: "30 min", value: 30 }, { label: "1 h", value: 60 },
                                { label: "3 h", value: 180 }, { label: "6 h", value: 360 }, { label: "1 day", value: 1440 }] },
                    { id: "rotFrom", prop: "wallRotationFrom", kind: "choice", name: "From",
                      options: [{ label: "All", value: "all" }, { label: "Images", value: "images" },
                                { label: "Videos", value: "videos" }, { label: "Favorites", value: "favorites" }] },
                    { id: "rotFullscreen", prop: "wallRotationPauseFullscreen", kind: "toggle", name: "Pause rotation in fullscreen" },
                    { id: "rotBattery", prop: "wallRotationPauseBattery", kind: "toggle", name: "Pause rotation on battery" },
                    { id: "rotModes", prop: "wallRotationPauseModes", kind: "toggle", name: "Pause rotation in Gaming and Cinema" },
                    { id: "rotStatus", prop: "", kind: "info", name: "Status" }
                ] },
                // 10B: sólo lo que awww admite, y sólo para imágenes
                { title: "Transitions", key: "Transitions", rows: [
                    { id: "transition", prop: "wallTransition", kind: "choice", name: "Image transition",
                      options: [{ label: "Default", value: "any" }, { label: "Fade", value: "fade" },
                                { label: "Wipe", value: "wipe" }, { label: "Wave", value: "wave" },
                                { label: "Grow", value: "grow" }, { label: "Outer", value: "outer" },
                                { label: "None", value: "none" }] }
                ] },
                { title: "Recent", key: "", dynamic: "recent", rows: [] },
                { title: "Favorites", key: "", dynamic: "favorites", rows: [] },
                // 10A: el inventario compartido con Wallpaper List (las cuentas salen de él; la tira
                // es el selector: Settings no pinta otra) y Sources configurable.
                { title: "Library", key: "", rows: [
                    { id: "libImages", prop: "", kind: "info", name: "Images" },
                    { id: "libVideos", prop: "", kind: "info", name: "Videos" }
                ] },
                { title: "Sources", key: "", dynamic: "sources", rows: [] },
                { title: "Folders", key: "", rows: [
                    { id: "wallSourceAdd", prop: "wallpaperSources", kind: "wallSourceAdd", name: "Add a folder" },
                    { id: "wallDownloadDir", prop: "wallpaperDownloadDir", kind: "wallDownloadDir", name: "Download folder" }
                ] },
                // 10E-1a: la clave NO está en settings.json (secrets/, WallhavenAccount); el usuario sí
                { title: "Wallhaven", key: "Wallhaven", rows: [
                    { id: "whKey", prop: "", kind: "whKey", name: "API key" },
                    { id: "whUser", prop: "wallhavenUser", kind: "whUser", name: "Username" },
                    { id: "whTest", prop: "", kind: "action", name: "Test connection", label: "Test" },
                    { id: "whRemove", prop: "", kind: "action", name: "Remove the key", label: "Remove" },
                    { id: "whAccount", prop: "", kind: "info", name: "Account filters" }
                ] }
            ] },
            // El perfil no es del shell: lo manda matugen y repinta el escritorio entero. Sin Custom
            // ni reset (§4, un dueño por dato). 12C: elegir sólo SELECCIONA; Preview prueba en
            // todo el escritorio y Keep changes / Revert deciden (el mismo `ThemePreview` que el
            // carrusel). Antes «Colours from wallpaper» y «Scheme» aplicaban al tocarlos; Static
            // es ahora un perfil más (Minimaru).
            { id: "colors", title: "Colors", sections: [
                { title: "The whole desktop", key: "", rows: [
                    { id: "themeProfile", prop: "", kind: "themeProfile", name: "Profile" },
                    // 12F: modo, contraste y color de origen; también sólo seleccionan
                    { id: "themeMode", prop: "", kind: "themeOpt", opt: "lightness", name: "Mode",
                      options: [{ label: "Dark", value: "dark" }, { label: "Light", value: "light" }] },
                    { id: "themeContrast", prop: "", kind: "themeOpt", opt: "contrast", name: "Contrast",
                      options: [{ label: "Lower", value: -0.5 }, { label: "Standard", value: 0 },
                                { label: "Higher", value: 0.5 }, { label: "Highest", value: 1 }] },
                    { id: "themeSource", prop: "", kind: "themeOpt", opt: "sourceKind", name: "Colour source",
                      options: [{ label: "Wallpaper", value: "wallpaper" }, { label: "Custom colour", value: "custom" }] },
                    { id: "themeSourceHex", prop: "", kind: "themeHex", name: "Custom colour" },
                    { id: "themePreview", prop: "", kind: "action", name: "Preview", label: "Preview" },
                    { id: "themeKeep", prop: "", kind: "action", name: "Keep changes", label: "Keep" },
                    { id: "themeRevert", prop: "", kind: "action", name: "Revert", label: "Revert" },
                    { id: "themeRegenerate", prop: "", kind: "action", name: "Regenerate palette", label: "Regenerate" },
                    // F-e (2026-11-04): a qué apps llegan los colores, sólo lectura
                    { id: "themeTargets", prop: "", kind: "info", name: "Applied to" },
                    { id: "openProfiles", prop: "", kind: "link", name: "Visual profiles", target: "theme" }
                ] },
                { title: "Palette", key: "", rows: [
                    { id: "swatches", prop: "", kind: "swatches", name: "Roles" }
                ] }
            ] },
            /**
             * 2026-10-28: Material vive en Theme (antes Shell → Material; `openPath` traduce la ruta
             * vieja). Los valores siguen en `theme.appearance.*`: mover la página no migra nada. Lo
             * global manda en TODO (surfaces, herramientas flotantes, barra, OSD…); Advanced → Surfaces
             * guarda sólo lo que una superficie cambia (Theme.materialFor), plegado como opción avanzada.
             */
            { id: "material", title: "Material", sections: [
                { title: "Global material", key: "Material", preview: "global", rows: [
                    { id: "material", prop: "material", kind: "choice", name: "Material",
                      options: [{ label: "Glass", value: "glass" }, { label: "Vidrio Satinado", value: "satin" }] },
                    { id: "materialEdge", prop: "materialEdge", kind: "choice", name: "Border",
                      options: [{ label: "None", value: "none" }, { label: "Subtle", value: "subtle" },
                                { label: "Defined", value: "defined" }] },
                    { id: "materialShadow", prop: "materialShadow", kind: "toggle", name: "Soft shadow" }
                ] },
                { title: "Global opacity", key: "Glass", rows: [
                    { id: "glass", prop: "glassOpacity", kind: "choice", name: "Glass opacity", options: root.glassOptions }
                ] },
                // sin `key`: «Reset section» del global no toca lo de cada superficie (lo hace su Reset).
                // Opción avanzada: plegada al abrir Settings; sin overrides todo sigue al global.
                { title: "Surfaces", key: "", preview: "surface", level: "advanced", rows: [
                    { id: "surfPick", prop: "", kind: "surfPick", name: "Surface" },
                    { id: "surfMaterial", prop: "", kind: "surfOpt", opt: "material", name: "Material" },
                    { id: "surfOpacity", prop: "", kind: "surfOpt", opt: "opacity", name: "Opacity" },
                    { id: "surfEffective", prop: "", kind: "info", name: "In use" },
                    { id: "surfReset", prop: "", kind: "action", name: "Reset this surface", label: "Reset" },
                    { id: "surfCustom", prop: "", kind: "info", name: "Customized surfaces" }
                ] }
            ] },
            /**
             * Estilo de interfaz (2026-11-14, ADR-34, theme/Style): la FORMA de la shell (geometría, marco, decoraciones
             * y presentación de los controles), aparte del color, el material, la tipografía y el movimiento. Las filas
             * de Terminal sólo valen con ese estilo (`styleOnly`: se ven, con su motivo, pero no se tocan). Los efectos
             * (F5) tendrán su sección aquí.
             */
            { id: "style", title: "Interface style", sections: [
                { title: "Style", key: "InterfaceStyle", rows: [
                    { id: "interfaceStyle", prop: "interfaceStyle", kind: "interfaceStyle", name: "Interface style" }
                ] },
                { title: "Terminal", key: "TerminalStyle", rows: [
                    { id: "termFrame", prop: "termFrame", kind: "choice", name: "Frame", styleOnly: "terminal",
                      options: [{ label: "Single", value: "single" }, { label: "Double", value: "double" },
                                { label: "Segmented", value: "segmented" }] },
                    { id: "termDecor", prop: "termDecor", kind: "choice", name: "Decorations", styleOnly: "terminal",
                      options: [{ label: "Off", value: "none" }, { label: "Minimal", value: "minimal" },
                                { label: "Full", value: "full" }] },
                    { id: "termMono", prop: "termMono", kind: "toggle", name: "Monospace interface text", styleOnly: "terminal" }
                ] },
                // F5 (ADR-23): todos apagados de serie; el glitch y el encendido sólo se mueven con Normal
                { title: "Effects", key: "TerminalEffects", rows: [
                    // «Interference» (2026-11-15): la ráfaga de estática al abrir y al cambiar de vista; antes «Glitch»
                    // (mismo ajuste `theme.effects.glitch`: lo guardado se conserva)
                    { id: "fxGlitch", prop: "fxGlitch", kind: "choice", name: "Interference", styleOnly: "terminal",
                      options: [{ label: "Off", value: "off" }, { label: "Subtle", value: "subtle" },
                                { label: "Strong", value: "strong" }] },
                    { id: "fxScanlines", prop: "fxScanlines", kind: "toggle", name: "Scanlines", styleOnly: "terminal" },
                    { id: "fxGlow", prop: "fxGlow", kind: "toggle", name: "Glow", styleOnly: "terminal" }
                    // Power-on (2026-11-17, ADR-36) pasó a Shell → Animations → Window style, para Soft y Terminal
                ] }
            ] },
            // T2: local draft editor; only Apply writes font preferences.
            { id: "typography", title: "Typography", sections: [
                { title: "Text", key: "Typography", rows: [
                    { id: "family", prop: "", kind: "action", name: "Font families", label: "Choose…" },
                    { id: "textSize", prop: "textScale", kind: "choice", name: "Text size",
                      options: [{ label: "Default", value: 1.0 }, { label: "Large", value: 1.08 },
                                { label: "Larger", value: 1.15 }] },
                    { id: "variants", prop: "", kind: "info", name: "Icon font" }
                ] },
                // T4: la misma elección en otras apps, destino a destino (components/TypographySync)
                { title: "Other apps", key: "", rows: [
                    { id: "fontSync", prop: "", kind: "action", name: "Other apps", label: "Choose…" }
                ] }
            ] },
            /**
             * Apariencia (2026-11-13): temas de iconos y de cursor de las apps (services/Appearance,
             * scripts/appearance.py). Elegir es un borrador con vista previa real; nada se escribe hasta Apply,
             * que dice qué cambia en cada app y deja vuelta atrás. Los iconos de la shell (glifos de
             * Icon.qml) no cambian: sólo los de las aplicaciones. Antes, sólo lectura (fase 12).
             */
            { id: "icons", title: "Icons & cursor", sections: [
                { title: "Icons", key: "", rows: [
                    { id: "apIconFamily", prop: "", kind: "apChoice", opt: "family", name: "Icon theme" },
                    { id: "apIconVariant", prop: "", kind: "apChoice", opt: "variant", name: "Variant" },
                    { id: "apIconFollow", prop: "iconFollowMode", kind: "toggle", name: "Follow light and dark" },
                    { id: "apIconPreview", prop: "", kind: "apPreview", which: "icons", name: "Preview" },
                    { id: "apIconGlyphs", prop: "", kind: "apPreview", which: "glyphs", name: "Small icons" },
                    // Apply rápido (2026-11-14): el mismo borrador en las dos pestañas; aplica iconos y cursor juntos
                    { id: "apApplyIcons", prop: "", kind: "action", name: "Apply to apps", label: "Apply" }
                ] },
                { title: "Cursor", key: "", rows: [
                    { id: "apCursor", prop: "", kind: "apChoice", opt: "cursor", name: "Cursor theme" },
                    { id: "apCursorSize", prop: "", kind: "apChoice", opt: "size", name: "Size" },
                    { id: "apCursorPreview", prop: "", kind: "apPreview", which: "cursors", name: "Preview" },
                    { id: "apApplyCursor", prop: "", kind: "action", name: "Apply to apps", label: "Apply" }
                ] },
                // Lo que Apply cambia por app y cómo volver atrás; el Apply vive en Icons y Cursor
                { title: "Changes", key: "", rows: [
                    { id: "apTargets", prop: "", kind: "info", name: "What changes" },
                    { id: "apUndo", prop: "", kind: "action", name: "Undo the last change", label: "Undo" },
                    { id: "apUndoAll", prop: "", kind: "action", name: "Restore what the apps had before", label: "Restore" },
                    { id: "apRecover", prop: "", kind: "action", name: "Finish an interrupted change", label: "Finish" }
                ] },
                { title: "In use", key: "", rows: [
                    { id: "iconTheme", prop: "", kind: "info", name: "Icon theme" },
                    { id: "cursorTheme", prop: "", kind: "info", name: "Cursor" }
                ] },
                // GTK, Qt y XSettings: otra cosa que el tema de iconos; aquí sólo se enseñan (ver Colors)
                { title: "Other apps' look", key: "", level: "advanced", rows: [
                    { id: "apGtkTheme", prop: "", kind: "info", name: "GTK theme" },
                    { id: "apQtStyle", prop: "", kind: "info", name: "Qt style" },
                    { id: "apXsettings", prop: "", kind: "info", name: "X11 apps (XSettings)" }
                ] },
                { title: "Installed", key: "", level: "advanced", rows: [
                    { id: "iconsInstalled", prop: "", kind: "info", name: "Icon themes" },
                    { id: "cursorsInstalled", prop: "", kind: "info", name: "Cursors" }
                ] }
            ] },
            // 12D (futureSettingssurface §12): presets de Appearance / Layout / Motion. Integrados
            // inmutables; los tuyos en ~/.config/sumi-shell/presets/. El tema global (perfil de
            // matugen) no entra: tiene su propia preview en Colors.
            { id: "presets", title: "Presets", sections: [
                { title: "Presets", key: "", dynamic: "presets", rows: [] },
                { title: "Selected preset", key: "", dynamic: "presetSel", rows: [] },
                { title: "New", key: "", rows: [
                    { id: "presetSaveCurrent", prop: "", kind: "action", name: "Save current settings as a preset", label: "Save" }
                ] }
            ] }
        ] },
        { id: "system", title: "System", glyph: "monitor", pages: [
            // 9D-2 (futureSettingssurface §7): un subconjunto útil sobre los servicios que ya
            // existen (Mixer, Net, Bt, PowerProfile). Settings no guarda nada de esto: el estado es
            // del servicio (PipeWire, NetworkManager, BlueZ, power-profiles-daemon) y se observa.
            { id: "audio", title: "Audio", sections: [
                { title: "Output", key: "", rows: [
                    { id: "outDev", prop: "", kind: "device", name: "Device", which: "sink" },
                    { id: "outVol", prop: "", kind: "volume", name: "Volume", which: "sink" },
                    { id: "outMute", prop: "", kind: "mute", name: "Mute", which: "sink" }
                ] },
                { title: "Input", key: "", rows: [
                    { id: "inDev", prop: "", kind: "device", name: "Device", which: "source" },
                    { id: "inVol", prop: "", kind: "volume", name: "Volume", which: "source" },
                    { id: "inMute", prop: "", kind: "mute", name: "Mute", which: "source" }
                ] },
                { title: "Applications", key: "", rows: [
                    { id: "appsNow", prop: "", kind: "info", name: "Active streams" },
                    { id: "openMixer", prop: "", kind: "link", name: "Audio mixer", target: "mixer" },
                    // antes de la fase 14: la configuración de audio vive en la Audio UI (target
                    // "audio" es su capa, no una surface: openLink la abre en su sección)
                    { id: "openAudioUi", prop: "", kind: "link", name: "Audio settings", target: "audio", key: "overview" },
                    { id: "openApps", prop: "", kind: "link", name: "Per-app devices", target: "audio", key: "applications" },
                    { id: "openEq", prop: "", kind: "link", name: "Equalizer", target: "audio", key: "equalizer" }
                ] },
                // 2026-11-09 (pedido del usuario): cómo se ve el reproductor del Mixer; sólo composición
                { title: "Media player", key: "Media player", rows: [
                    { id: "mediaBackdrop", prop: "mediaBackdrop", kind: "choice", name: "Background",
                      options: [{ label: "Blurred cover", value: "cover" }, { label: "Theme", value: "theme" }] },
                    { id: "mediaCoverShape", prop: "mediaCoverShape", kind: "choice", name: "Cover",
                      options: [{ label: "Square", value: "square" }, { label: "Disc", value: "disc" }] },
                    { id: "mediaEndTime", prop: "mediaEndTime", kind: "choice", name: "Track time",
                      options: [{ label: "Length", value: "total" }, { label: "Remaining", value: "remaining" }] }
                ] }
            ] },
            { id: "network", title: "Network", sections: [
                { title: "Connection", key: "", rows: [
                    { id: "netNow", prop: "", kind: "info", name: "Primary" },
                    { id: "netCheck", prop: "", kind: "info", name: "Internet" }
                ] },
                { title: "Ethernet", key: "", rows: [
                    { id: "wiredNow", prop: "", kind: "info", name: "Cable" },
                    { id: "openWired", prop: "", kind: "link", name: "Ethernet details", target: "wired" }
                ] },
                { title: "Wi-Fi", key: "", rows: [
                    { id: "wifiNow", prop: "", kind: "info", name: "Wi-Fi" },
                    { id: "openWifi", prop: "", kind: "link", name: "Networks", target: "wifi" }
                ] },
                // 14A: los perfiles guardados; 14D: elegir uno y editar lo admitido (decisión 4)
                { title: "Saved networks", key: "", dynamic: "netProfiles", rows: [] },
                { title: "Selected network", key: "", dynamic: "netSel", rows: [] },
                { title: "Changes", key: "", rows: [
                    { id: "netRollback", prop: "", kind: "info", name: "Undo protection" }
                ] }
            ] },
            { id: "bluetooth", title: "Bluetooth", sections: [
                { title: "Adapter", key: "", rows: [
                    { id: "btPower", prop: "", kind: "btPower", name: "Bluetooth" },
                    { id: "openBt", prop: "", kind: "link", name: "Pair a device", target: "bluetooth" }
                ] },
                // los emparejados, del servicio (sin escanear: eso sigue en su surface)
                { title: "Known devices", key: "", dynamic: "btDevices", rows: [] }
            ] },
            // `keepAwake` se presenta en System → Power (futureSettingssurface §11).
            { id: "power", title: "Power", sections: [
                { title: "Energy", key: "", rows: [
                    { id: "profile", prop: "", kind: "profile", name: "Power profile" },
                    { id: "batteryStatus", prop: "", kind: "info", name: "Battery" }
                ] },
                { title: "Battery alerts", key: "Battery", rows: [
                    { id: "batteryAlerts", prop: "batteryAlerts", kind: "toggle", name: "Battery warnings" },
                    { id: "batteryLow", prop: "batteryLow", kind: "choice", name: "Low battery", options: [15,20,25,30].filter(v => v > Settings.batteryVeryLow).map(v => ({label: v + "%", value: v})) },
                    { id: "batteryVeryLow", prop: "batteryVeryLow", kind: "choice", name: "Very low battery", options: [8,10,12,15].filter(v => v > Settings.batteryCritical && v < Settings.batteryLow).map(v => ({label: v + "%", value: v})) },
                    { id: "batteryCritical", prop: "batteryCritical", kind: "choice", name: "Critical battery", options: [2,3,5,7].filter(v => v < Settings.batteryVeryLow).map(v => ({label: v + "%", value: v})) }
                ] },
                { title: "Session", key: "Power", rows: [
                    { id: "keepAwake", prop: "keepAwake", kind: "toggle", name: "Keep awake" }
                ] },
                // 14A: los plazos de hypridle; 14E: editables (opt-in: el archivo gestionado)
                { title: "When idle", key: "", rows: [
                    { id: "idleLock", prop: "", kind: "idleChoice", key: "lock", name: "Lock after" },
                    { id: "idleScreen", prop: "", kind: "idleChoice", key: "screenOff", name: "Screen off after" },
                    { id: "idleSuspend", prop: "", kind: "info", name: "Suspend after" },
                    { id: "idleState", prop: "", kind: "info", name: "Idle manager" }
                ] },
                { title: "Editing the idle times", key: "", dynamic: "idleEdit", rows: [] }
            ] },
            // Displays, Input y Hyprland: SÓLO INFORMACIÓN (decisión del usuario, 2026-09-29): lo
            // efectivo, el archivo y la línea que lo fija y quién manda (services/HyprConfig, 14A); la
            // configuración se busca desde el proceso de Hyprland (14C). Se edita en el Lua del usuario.
            // Lo único editable aquí es Preferred display, que es del shell.
            { id: "displays", title: "Displays", sections: [
                { title: "Connected", key: "", dynamic: "monitors", rows: [] },
                { title: "Configuration", key: "", rows: [
                    { id: "prefDisplay", prop: "", kind: "info", name: "Preferred display" },
                    { id: "displaysEdit", prop: "", kind: "info", name: "Resolution, refresh rate and layout" }
                ] }
            ] },
            { id: "input", title: "Input", sections: [
                { title: "Keyboard", key: "", rows: SysCat.rows("input", "Keyboard") },
                { title: "Keyboards", key: "", dynamic: "keyboards", rows: [] },
                { title: "Pointer", key: "", rows: SysCat.rows("input", "Pointer") },
                { title: "Touchpad", key: "", rows: SysCat.rows("input", "Touchpad") },
                { title: "Per device", key: "", dynamic: "hyprDevices", rows: [] },
                { title: "Changes", key: "", rows: [
                    { id: "inputEdit", prop: "", kind: "info", name: "Mouse, touchpad and keyboard" }
                ] }
            ] },
            { id: "hyprland", title: "Hyprland", sections: [
                { title: "Compositor", key: "", rows: [
                    { id: "hyprVer", prop: "", kind: "info", name: "Version" },
                    { id: "hyprConfig", prop: "", kind: "info", name: "Configuration" }
                ] },
                { title: "Windows", key: "", rows: SysCat.rows("hyprland", "Windows") },
                { title: "Focus", key: "", rows: SysCat.rows("hyprland", "Focus") },
                { title: "Managed elsewhere", key: "", rows: SysCat.rows("hyprland", "Managed elsewhere") },
                { title: "Changes", key: "", rows: [
                    { id: "hyprEdit", prop: "", kind: "info", name: "Gaps, borders and window rules" }
                ] }
            ] },
            // Portabilidad F2b (2026-10-05): qué funciona en esta máquina, con qué y por qué no. Sólo
            // lectura: detecta services/Capabilities (una vez al cargar y con Refresh), no la página,
            // que no reclama nada. Las notificaciones y el agente de polkit ya tienen su página
            // (Shell → General, `Integrations`): aquí se enlazan, no se copian (un dato, una página).
            { id: "environment", title: "Environment", sections: [
                { title: "Detection", key: "", rows: [
                    { id: "envStatus", prop: "", kind: "info", name: "Last check" },
                    { id: "envRefresh", prop: "", kind: "action", name: "Check again", label: "Refresh" }
                ] },
                { title: "Session", key: "", dynamic: "env:session", rows: [] },
                { title: "Theme", key: "", dynamic: "env:theme", rows: [] },
                { title: "Wallpaper", key: "", dynamic: "env:wallpaper", rows: [] },
                { title: "Apps", key: "", dynamic: "env:apps", rows: [] },
                { title: "Audio", key: "", dynamic: "env:audio", rows: [] },
                { title: "Devices", key: "", dynamic: "env:devices", rows: [] },
                { title: "Desktop", key: "", dynamic: "env:desktop", rows: [] },
                { title: "Desktop modes", key: "", dynamic: "env:modes", rows: [] },
                { title: "Updates and maintenance", key: "", dynamic: "env:system", rows: [] },
                { title: "Integrations", key: "", rows: [
                    { id: "envNotif", prop: "", kind: "goto", name: "Notification server", path: "shell/general/notifServer" },
                    { id: "envPolkit", prop: "", kind: "goto", name: "Polkit agent", path: "shell/general/polkit" }
                ] }
            ] },
            { id: "about", title: "About", sections: [
                // SemVer (2026-11-07): la versión de la shell, de su única fuente (version.json)
                { title: "Sumi Shell", key: "", rows: [
                    { id: "shellVersion", prop: "", kind: "info", name: "Version" },
                    { id: "shellApi", prop: "", kind: "info", name: "Public API" }
                ] },
                // Etapa C del Dashboard (2026-11-10): lo que mostraba su pliegue Diagnostics y no es un ajuste (escala,
                // auto-hide, keep awake y reserva tienen su control en su página)
                { title: "Shell state", key: "", rows: [
                    { id: "stScreens", prop: "", kind: "info", name: "Screens" },
                    { id: "stFocused", prop: "", kind: "info", name: "Focused monitor" },
                    { id: "stPalette", prop: "", kind: "info", name: "Palette source" },
                    { id: "stWallpapers", prop: "", kind: "info", name: "Wallpapers" },
                    { id: "stResumes", prop: "", kind: "info", name: "Resumes this session" },
                    { id: "stSettings", prop: "", kind: "info", name: "Settings file" }
                ] },
                { title: "This computer", key: "", rows: [
                    { id: "os", prop: "", kind: "info", name: "Distribution" },
                    { id: "kernel", prop: "", kind: "info", name: "Kernel" },
                    { id: "wm", prop: "", kind: "info", name: "Compositor" },
                    { id: "cpu", prop: "", kind: "info", name: "Processor" },
                    { id: "gpu", prop: "", kind: "info", name: "Graphics" },
                    { id: "mem", prop: "", kind: "info", name: "Memory" },
                    { id: "displays", prop: "", kind: "info", name: "Displays" },
                    { id: "openMonitor", prop: "", kind: "link", name: "System monitor", target: "system" }
                ] }
            ] }
        ] }
    ]

    function destEntry(id) {
        for (let i = 0; i < root.tree.length; i++)
            if (root.tree[i].id === id) return root.tree[i];
        return root.tree[0];
    }
    function pageEntry(key) {
        const parts = key.split("/");
        const d = root.destEntry(parts[0]);
        for (let i = 0; i < d.pages.length; i++)
            if (d.pages[i].id === parts[1]) return d.pages[i];
        return d.pages[0];
    }
    readonly property var shownDest: root.destEntry(root.shownKey.length > 0 ? root.shownKey.split("/")[0] : root.destId)
    readonly property var shownPage: root.pageEntry(root.shownKey.length > 0 ? root.shownKey : root.pageKey)
    /** Todas las páginas en el orden de la barra lateral: el sentido del deslizamiento sale de aquí. */
    readonly property var order: Nav.order()
    /** El grupo de la barra lateral de la página que se ve (las migas lo nombran) y su descripción. */
    // sólo de `shownKey`: leer `pageKey` aquí dispararía `swapTo` en mitad de la evaluación (bucle)
    readonly property var shownGroup: Nav.groupOf(root.shownKey)
        || { id: root.shownDest.id, title: root.shownDest.title, glyph: root.shownDest.glyph }
    /** La zona de color de la página: la de su grupo (lib/accent-zones.js); la heredan todos los controles. */
    readonly property string groupZone: Zones.group(root.shownGroup ? root.shownGroup.id : "")
    palette.accent: Theme.zone(root.groupZone)
    readonly property string shownDesc: Nav.describe(root.shownKey)

    property bool showBitrate: false
    property var tabOf: ({})
    readonly property var sectionTabs: Sections.tabsFor(root.shownKey, root.shownPage.sections)
    readonly property string activeTab: {
        const saved = root.tabOf[root.shownKey];
        return root.sectionTabs.some(t => t.key === saved) ? saved : (root.sectionTabs[0] || {}).key || "";
    }
    function rememberTab(page, tab) {
        const map = Object.assign({}, root.tabOf);
        map[page] = tab;
        root.tabOf = map;
    }
    function selectTab(tab, focusTabs) {
        if (!root.sectionTabs.some(t => t.key === tab)) return false;
        const prev = root.activeTab;
        root.kbRowId = "";
        root.rememberTab(root.shownKey, tab);
        root.kbIndex = root.firstRowIndex();
        flick.contentY = 0;
        if (prev !== tab && root.open && root.settled) {
            const tabs = root.sectionTabs.map(t => t.key);
            root.playEnter(tabs.indexOf(tab) >= tabs.indexOf(prev) ? 1 : -1);
        }
        root.zone = focusTabs ? "sections" : "content";
        root.forceActiveFocus();
        return true;
    }
    function moveTab(delta) {
        const i = root.sectionTabs.findIndex(t => t.key === root.activeTab);
        return root.selectTab(root.sectionTabs[(i + delta + root.sectionTabs.length) % root.sectionTabs.length].key, root.zone === "sections");
    }
    /** Una opción que puede ir a media fila: pastillas (no las dos del grabador que siempre van enteras) que caben. */
    function halfEligible(r) {
        return r.kind === "choice" && r.id !== "recPreset" && r.id !== "recFormat" && !root.choiceLong(r);
    }
    /** La fila va a media fila (`pack` la emparejó con otra de su sección). */
    function gridField(r) { return r.half === true; }

    /**
     * ¿Las pastillas de `r` no caben en media fila? Se mide contra la media fila MÁS ESTRECHA que existe (la del umbral
     * de dos columnas, 652·s·Text size), así el orden y el reparto no cambian con el ancho de la ventana. Más de 4
     * opciones sin `pills` son el selector «< valor >», que siempre cabe.
     */
    function choiceLong(r) {
        const opts = root.optionsOf(r) || [];
        if (opts.length > 4 && r.pills !== true) return false;
        const s = root.s;
        let w = 0;
        for (let i = 0; i < opts.length; i++)
            w += Math.ceil(pillMetrics.advanceWidth(String(opts[i].label))) + Math.ceil(22 * s) + 3 * s;
        const half = (652 * s * Typography.textScale - 12 * s) / 2 - 22 * s;
        return w > half;
    }

    /**
     * JUNTAR Y ESTIRAR (2026-11-16, encuesta del autor): dentro de una sección, cada opción que cabe en media fila se
     * empareja con la SIGUIENTE que también cabe (sube a su lado); la que se queda sin pareja ocupa la fila entera
     * (`stretch`: nombre a la izquierda, pastillas a la derecha) en vez de dejar un hueco; las que no caben en media
     * fila, también `stretch` (SettingRow las apila si no caben junto al nombre). El resto, en su orden.
     * Devuelve copias de las filas emparejadas o estiradas (con `half`/`stretch`); las demás, tal cual. El teclado
     * (`flat`) recorre este mismo orden.
     */
    function pack(rows) {
        const out = [], used = {};
        for (let i = 0; i < rows.length; i++) {
            if (used[i]) continue;
            const r = rows[i];
            if (!root.halfEligible(r)) {
                // las que nunca caben en media fila (p. ej. las ocho escalas), también en línea con su nombre si caben
                // (SettingRow apila las que no: listas de dispositivos)
                const wide = r.kind === "choice" && r.id !== "recPreset" && r.id !== "recFormat";
                out.push(wide ? Object.assign({}, r, { stretch: true }) : r);
                continue;
            }
            let j = -1;
            for (let k = i + 1; k < rows.length; k++)
                if (!used[k] && root.halfEligible(rows[k])) { j = k; break; }
            if (j < 0) { out.push(Object.assign({}, r, { stretch: true })); continue; }
            used[j] = true;
            out.push(Object.assign({}, r, { half: true }), Object.assign({}, rows[j], { half: true }));
        }
        return out;
    }

    // ---- navegación -------------------------------------------------------------------

    /** Ir a una página: la página es de su destino; si el destino es otro, lo cambia el host (o, flotante, aquí). */
    function goPage(destId, pageId, rowId) {
        const key = destId + "/" + pageId;
        if (rowId) {
            const section = root.pageEntry(key).sections.find(sc =>
                (sc.dynamic ? root.dynRows(sc.dynamic) : sc.rows).some(r => r.id === rowId));
            if (section) root.rememberTab(key, Sections.tabFor(key, section));
        }
        root.followNav(key);
        // Navegación explícita: arriba y en la primera fila (o la pedida).
        const sc = Object.assign({}, root.scrollOf); delete sc[key]; root.scrollOf = sc;
        const rw = Object.assign({}, root.rowOf);
        if (rowId && rowId.length > 0) rw[key] = rowId; else delete rw[key];
        root.rowOf = rw;
        const p = Object.assign({}, root.pageOf);
        p[destId] = pageId;
        root.pageOf = p;
        root.goDest(destId);
        // Misma página (p. ej. `settingsOpen` a donde ya se está): aplicar aquí.
        if (root.pageKey === key && root.shownKey === key) root.applyState(key);
        return true;
    }

    function goDest(destId) {
        if (destId === root.destId) return;
        const name = root.destSurface[destId];
        if (root.host) root.host.requestSurface(name);
        else root.dest = name;              // sin host (preview-settings.qml)
    }

    /** Cambia lo que se ve: guarda la página que sale y restaura (o empieza) la que entra. */
    function swapTo(key) {
        if (key !== root.shownKey && fontEditor.editing) fontEditor.cancel();
        if (key !== root.shownKey && fontSync.open) fontSync.close();
        if (key === root.shownKey) return;
        const old = root.shownKey;
        if (old.length > 0) {
            const sc = Object.assign({}, root.scrollOf); sc[old] = flick.contentY; root.scrollOf = sc;
            const rw = Object.assign({}, root.rowOf); const cur = root.currentRowId(); if (cur) rw[old] = cur; root.rowOf = rw;
        }
        root.shownKey = key;
        root.followNav(key);
        root.visitPush(key);
        root.applyState(key);
        if (old.length > 0 && root.open && root.settled && !root.resuming) {
            const dir = root.order.indexOf(key) >= root.order.indexOf(old) ? 1 : -1;
            root.playEnter(dir);
        }
        if (key === "system/about") SystemInfo.load();
    }

    function applyState(key) {
        root.lastPointer = Qt.point(-1, -1);
        const row = root.rowOf[key];
        const i = row ? root.indexOfRow(row) : -1;
        root.kbIndex = i >= 0 ? i : root.firstRowIndex();
        const y = root.scrollOf[key] || 0;
        flick.contentY = 0;
        Qt.callLater(() => {
            // Settings UI: el contenido se descarga en el acto al bloquear; lo aplazado llega sin él
            if (!root || root.shownKey !== key) return;
            flick.contentY = Math.max(0, Math.min(y, flick.contentHeight - flick.height));
            const it = root.rowItems[root.currentRowId()];
            if (it && y === 0) root.reveal(it);
        });
    }

    function currentRowId() {
        const f = root.flat[root.kbIndex];
        return f && f.row ? f.row.id : "";
    }

    function firstRowIndex() {
        // En el aviso sólo si el archivo tiene un problema: es lo primero que resolver.
        return root.storeTrouble ? 0 : root.bannerActions.length;
    }

    readonly property var navGroups: Nav.groupsWithTitles(key => root.pageEntry(key).title)
    property string expandedGroup: "shell"
    readonly property var navKeys: Nav.visibleKeys(root.expandedGroup)
    readonly property string navFocus: root.zone === "nav" ? (root.navKeys[root.navIndex] || "") : ""

    function followNav(key) {
        const group = Nav.groupOf(key);
        if (!group) return;
        root.expandedGroup = group.id;
        root.navIndex = root.navKeys.indexOf(key);
    }
    function focusGroup(group, expand) {
        root.expandedGroup = expand ? group : "";
        root.navIndex = root.navKeys.indexOf(group);
        root.zone = "nav";
        root.forceActiveFocus();
    }
    function navActivate(key) {
        if (!key) return;
        const parts = key.split("/");
        if (parts.length === 1) {
            root.focusGroup(key, root.expandedGroup !== key);
            return;
        }
        root.goPage(parts[0], parts[1], "");
        root.zone = "content";
        root.forceActiveFocus();
    }

    // ---- Back / Forward entre páginas (Settings UI, 2026-11-07) -------------------------

    /**
     * Sin host del island, el historial es el de las páginas de esta ventana: cada página que
     * se ve es una visita; Back/Forward (Alt+←/→ y los botones del marco) vuelven a ella con su
     * scroll y su fila (los guarda `swapTo`). Una navegación nueva tras Back descarta la rama
     * Forward. Volver nunca ejecuta nada. Es lo que `FrameNav` espera de un host.
     */
    property var visits: []
    property int visitIndex: -1
    property bool visitMove: false
    readonly property QtObject pageHistory: QtObject {
        readonly property bool canBack: root.visitIndex > 0
        readonly property bool canForward: root.visitIndex >= 0 && root.visitIndex < root.visits.length - 1
        readonly property string historyNote: ""
        function historyBack() { return root.visitGo(-1); }
        function historyForward() { return root.visitGo(1); }
    }
    function visitPush(key) {
        if (root.visitMove || key.length === 0) return;
        if (root.visits[root.visitIndex] === key) return;
        const v = root.visits.slice(0, root.visitIndex + 1);
        v.push(key);
        const cut = v.slice(-30);              // nunca crece sin tope
        root.visits = cut;
        root.visitIndex = cut.length - 1;
    }
    function visitGo(delta) {
        const to = root.visitIndex + delta;
        if (to < 0 || to >= root.visits.length) return false;
        const parts = root.visits[to].split("/");
        root.visitMove = true;
        root.visitIndex = to;
        root.endSearch(false);
        const p = Object.assign({}, root.pageOf);
        p[parts[0]] = parts[1];
        root.pageOf = p;
        root.goDest(parts[0]);
        root.visitMove = false;
        root.zone = "content";
        root.forceActiveFocus();
        return true;
    }
    function setZone(z) {
        if (z === "nav") root.followNav(root.pageKey);
        if (z === "search") { root.startSearch(); return; }
        root.zone = z;
        root.forceActiveFocus();     // el campo suelta el teclado (lección de 9.f.2b)
    }
    /**
     * Tab recorre navegación → búsqueda → página (§3); Mayús+Tab al revés. Con resultados
     * en pantalla la página no se ve: se salta.
     */
    function tabZone(dir) {
        const stops = root.searching ? ["nav", "search"]
            : root.sectionTabs.length > 1 ? ["nav", "search", "sections", "content"] : ["nav", "search", "content"];
        const i = stops.indexOf(root.zone);
        root.setZone(stops[((i < 0 ? 0 : i) + dir + stops.length) % stops.length]);
    }

    // ---- apertura y contexto (DESIGN §3) ---------------------------------------------

    function resetForOpen() {
        PowerProfile.refresh();     // su presencia se comprueba una vez al abrir (no en reposo)
        root.pageOf = Object.assign({}, root.defaultPages);
        root.scrollOf = ({});
        root.rowOf = ({});
        root.expanded = ({});
        root.tabOf = ({});
        root.zone = "content";
        root.shownKey = "";
        searchField.clear();
        root.query = "";
        root.swapTo(root.pageKey);
        root.forceActiveFocus();
    }

    /**
     * Settings UI (2026-11-07): la ventana flotante VUELVE a donde se dejó (página, scroll, fila,
     * plegables), como el monitor y la Calendar UI; una ruta pedida (`settingsOpen`, un enlace
     * Configure…) la sustituye después. Lo que no se conserva: la búsqueda a medio escribir (se
     * vuelve a la página) y la presencia de perfiles de energía, que se comprueba al abrir.
     */
    function resume(ctx) {
        root.resuming = true;
        PowerProfile.refresh();
        searchField.clear();
        root.query = "";
        if (ctx && ctx.pageOf) {
            if (ctx.dest && root.destSurface[ctx.dest] !== undefined) root.dest = root.destSurface[ctx.dest];
            root.restoreContext(ctx);
        }
        if (root.shownKey.length === 0) root.swapTo(root.pageKey);
        if (root.zone === "search") root.zone = "content";
        root.resuming = false;
        root.forceActiveFocus();
    }

    // Un acceso directo empieza en la página inicial de cada destino. Volver con Esc desde
    // una surface enlazada (el host navega: `_navigating`) conserva dónde se estaba; Back /
    // Forward (`_historyMove`) restauran después con `restoreContext`. Flotante: `resume`.
    onOpenChanged: {
        if (!open && fontEditor.editing) fontEditor.cancel();
        if (!open && fontSync.open) fontSync.close();
        if (open) {
            if (root.floating) root.resume(null);
            else if (!(root.host && root.host._navigating)) root.resetForOpen();
        } else if (root.dockPreviewItem) {
            root.dockPreviewItem.stop();     // 8F-2: la muestra no sigue con Settings cerrado
        }
    }
    Component.onCompleted: {
        // la jerarquía y la tabla deben cuadrar: una página sin grupo no se alcanzaría desde la barra
        const problems = Nav.check(root.tree);
        if (problems.length > 0) console.warn("settings-nav:", problems.join("; "));
        if (!open) return;
        if (root.floating) root.resume(root.initialContext);
        else root.resetForOpen();
    }

    function saveContext() {
        const sc = Object.assign({}, root.scrollOf);
        const rw = Object.assign({}, root.rowOf);
        if (root.shownKey.length > 0) {
            sc[root.shownKey] = flick.contentY;
            const cur = root.currentRowId();
            if (cur) rw[root.shownKey] = cur;
        }
        // la búsqueda no entra en el historial: al volver se está en la página
        return { dest: root.destId, pageOf: root.pageOf, scrollOf: sc, rowOf: rw, expanded: root.expanded, tabOf: root.tabOf,
                 zone: root.zone === "nav" ? "nav" : "content", visits: root.visits, visitIndex: root.visitIndex };
    }
    function restoreContext(ctx) {
        if (!ctx || !ctx.pageOf) return true;
        root.scrollOf = ctx.scrollOf || {};
        root.rowOf = ctx.rowOf || {};
        root.expanded = ctx.expanded || {};
        root.tabOf = ctx.tabOf || {};
        // Una ventana anterior recordaba las tres familias dentro de Motion y el scroll de toda la galería.
        const animations = "shell/animations";
        if (!root.tabOf[animations] || root.tabOf[animations] === "Motion") {
            const row = root.rowOf[animations];
            const section = root.pageEntry(animations).sections.find(sc => sc.rows.some(r => r.id === row));
            if (section && section.title !== "Motion") {
                root.rememberTab(animations, section.title);
                root.scrollOf = Object.assign({}, root.scrollOf, { [animations]: 0 });
            }
        }
        root.pageOf = Object.assign({}, root.defaultPages, ctx.pageOf);
        if (root.shownKey === root.pageKey) root.applyState(root.pageKey);
        if (ctx.visits && ctx.visits.length > 0) {
            root.visits = ctx.visits.filter(k => root.order.indexOf(k) >= 0);
            root.visitIndex = Math.min(root.visits.length - 1, Math.max(0, ctx.visitIndex || 0));
        }
        root.zone = ctx.zone === "nav" ? "nav" : "content";
        root.followNav(root.pageKey);
        return true;
    }

    // ---- entrada de la página: deslizamiento corto y fundido --------------------------

    property real slideX: 0
    property real paneOpacity: 1
    function playEnter(dir) {
        const interrupted = enterAnim.running;
        enterAnim.stop();
        // con Interference (terminal, 2026-11-15) la estática ES la transición: ni desplazamiento ni fundido; apagada,
        // vuelve el desplazamiento de siempre (a petición del autor: no sumar los dos movimientos)
        if (Motion.off || Style.fx.glitch !== "off") { root.slideX = 0; root.paneOpacity = 1; return; }
        // Ventana flotante (2026-11-11): los números del estilo de ventana (con Reduced/Off, los de siempre); si no, 8 px.
        const shift = (root.floating ? Motion.pageShift : 8) * root.s;
        const fade = root.floating ? Motion.pageFadeFrom : 0.65;
        root.slideX = Motion.still ? 0 : interrupted
            ? Math.max(-shift, Math.min(shift, root.slideX)) : dir * shift;
        root.paneOpacity = Motion.off ? 1 : interrupted ? Math.max(fade, root.paneOpacity) : fade;
        enterAnim.start();
    }
    Connections {
        target: Motion
        function onModeChanged() {
            enterAnim.stop(); root.slideX = 0; root.paneOpacity = 1;
        }
    }
    ParallelAnimation {
        id: enterAnim
        NumberAnimation {
            target: root; property: "slideX"; to: 0
            duration: Motion.still ? 0 : (root.floating ? Motion.pageMs : Motion.page)
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: root; property: "paneOpacity"; to: 1
            duration: root.floating ? Motion.pageMs : Motion.page
            easing.type: Easing.OutCubic
        }
    }

    // ---- dock (8F-2): la preferencia es de la pantalla donde está abierto Settings -----

    readonly property var screenObj: {
        const list = Quickshell.screens;
        for (let i = 0; i < list.length; i++)
            if (list[i].name === root.screenName) return list[i];
        return list.length > 0 ? list[0] : null;
    }
    readonly property bool dockOn: Settings.monitorPref(root.screenObj, "dock", false) === true
    readonly property bool barHere: Settings.monitorPref(root.screenObj, "presentation", "island") === "bar"
    function setDock(on) { if (root.screenObj) Settings.setMonitorPref(root.screenObj, "dock", on); }
    /**
     * 9C-1: la barra persistente de esta pantalla. El mismo dato que Super+Ctrl+P
     * (`Screen.toggleBar`): `monitors[id].presentation`. Sin prop del catálogo: no entra en Reset.
     */
    function setBar(on) {
        if (root.screenObj && on !== root.barHere)
            Settings.setMonitorPref(root.screenObj, "presentation", on ? "bar" : "island");
    }
    /**
     * 2026-11-19: borde y longitud de la barra de esta pantalla (lib/bar-edge.js), lo mismo que lee Screen; siempre
     * centrada, la longitud la encoge hacia el centro hasta su límite (`barLimitPct`).
     * Sin prop del catálogo, como la presentación: su Reset es la fila «Default position and length» (o el punto de
     * cada fila), que quita la clave y la devuelve a la de serie.
     */
    readonly property string barEdgeHere: BarEdge.edgeOf(Settings.monitorPref(root.screenObj, "barEdge", "top"))
    readonly property int barLengthHere: BarEdge.lengthOf(Settings.monitorPref(root.screenObj, "barLength", 100))
    function setBarPref(key, v) { if (root.screenObj) Settings.setMonitorPref(root.screenObj, key, v); }
    function barPrefCustom(key) { return Settings.monitorPref(root.screenObj, key, undefined) !== undefined; }
    function resetBarPrefs(keys) { if (root.screenObj) Settings.clearMonitorPrefs(root.screenObj, keys); }
    /** Donde termina el deslizador: lo más corta que puede ser con lo que lleva (de Screen, para este borde). */
    readonly property int barLimitPct: BarEdge.limitPct(root.barLimit, root.barAvail)
    readonly property bool barAtLimit: root.barLengthHere <= root.barLimitPct
    /** Lo que mide de verdad, con el límite: para el pie de Length. */
    readonly property int barLengthPx: {
        const sc = root.screenObj;
        if (!sc) return 0;
        const along = BarEdge.vertical(root.barEdgeHere) ? sc.height : sc.width;
        return Math.round(BarEdge.span(along, Metrics.topGap * Settings.uiScale, root.barLengthHere, root.barLimit).len);
    }
    property var dockPreviewItem: null

    /** Acciones de fila (no ajustes): hoy sólo Random wallpaper, el mismo que R en Wallpaper List. */
    // ---- Sumi SDDM: Desktop tools → Login screen (2026-11-22) ------------------------------------------

    /** Con la página a la vista, SddmTheme carga y mantiene la vista previa; si no, no corre nada. */
    readonly property bool sddmPageShown: root.open && root.pageKey === "shell/sddm"
    onSddmPageShownChanged: SddmTheme.claim("settings", root.sddmPageShown)
    /** Buscar encuentra las claves de la ventana Login screen: sin esquema leído aún, se pide mientras se busca. */
    onSearchingChanged: {
        if (!root.searching) SddmTheme.claim("settingsSearch", false);
        else if (SddmTheme.order.length === 0) SddmTheme.claim("settingsSearch", true);
    }
    QtObject {
        Component.onDestruction: { SddmTheme.claim("settings", false); SddmTheme.claim("settingsSearch", false); }
    }
    /** Filas de un grupo del esquema (dependen del esquema y los avisos, no de los valores: un deslizador no se
     *  rehace mientras se arrastra). */
    function sddmRows(group) {
        // desde el 2026-11-23 no hay secciones dinámicas: las claves viven en la ventana Login screen
        return [];
    }
    function sddmInfo(id) { return SddmTheme.infoText(id); }
    function sddmCaption(r) {
        if (r.id === "sddmOpen") {
            const k = Keybinds.keyText("loginScreen");
            return "Look, Login Edge, clock, users and the preview, in their own window" + (k.length > 0 ? " · " + k : "");
        }
        const c = SddmTheme.captionText(r.id);
        return c.length > 0 ? c : (r.caption !== undefined ? r.caption : SddmTheme.captionFor(r.key || ""));
    }
    function sddmReason(r) { return r.id === "sddmOpen" ? "" : SddmTheme.reasonText(r.id); }
    function sddmAction(id) {
        if (id === "sddmOpen") {
            if (LoginUi.show(root.screenName, "", { from: "settings", path: "shell/sddm/sddmOpen" })) root.requestClose();
            return;
        }
        SddmTheme.runAction(id);
    }

    function runAction(id) {
        if (String(id).indexOf("sddm") === 0) { root.sddmAction(id); return; }       // Sumi SDDM
        if (id === "family") { fontEditor.begin(); return; }
        if (id === "fontSync") { fontSync.begin(); return; }
        if (id === "apApplyIcons" || id === "apApplyCursor") { Appearance.apply(); return; }   // Apariencia
        if (id === "apUndo") { Appearance.undoLast(); return; }
        if (id === "apUndoAll") { Appearance.undoAll(); return; }
        if (id === "apRecover") { Appearance.recover(); return; }
        if (id === "recProbe" && !ScreenRecorder.probing) ScreenRecorder.refreshProbe(true);     // Grabador 2.0
        if (id === "recOpenDir") ScreenRecorder.openFolder();
        if (id === "surfReset") Settings.resetSurface(root.matSurface);
        if (id === "barReset") root.resetBarPrefs(["barEdge", "barLength"]);                 // 2026-11-19
        if (id === "ovRandom") Wallpaper.random("all");
        if (id === "shortcutsHelp") {
            if (KeybindsUi.show(root.screenName, { from: "settings", path: "shell/interaction/shortcutsHelp" })) root.requestClose();
            return;
        }
        if (id === "envRefresh" && !Capabilities.checking) Capabilities.refresh("settings");
        if (id === "desktopRestore" && ThemePreview.desktopChanged > 0) ThemePreview.restoreDesktop();   // F4d
        // 15H (decisión 1 de la fase 15): la vista previa del Lock en su PROPIO proceso, sin PAM ni bloqueo, en
        // esta pantalla y con los datos reales del shell (`lockDataTest`); Esc la cierra. Una sola a la vez.
        if (id === "lockPreview")
            Quickshell.execDetached(["sh", "-c",
                "ps -eo args= | grep -q '^qs -p .*/lock-preview.qml' && exit 0; "
                + "XDG_STATE_HOME=$(mktemp -d) LOCK_PREVIEW_SCREENS=\"$1\" LOCK_PREVIEW_INTERACTIVE=1 "
                + "LOCK_PREVIEW_DATA=live LOCK_PREVIEW_ESC_QUITS=1 exec qs -p \"$2/lock-preview.qml\"",
                "sh", root.screenName, Quickshell.shellDir]);
        // 12C: la prueba del tema, por el mismo coordinador que el carrusel
        if (id === "themePreview" && root.themeCan("preview"))
            ThemePreview.preview(root.themeSelected, root.screenName, root.themeSelectedOpts);
        if (id === "themeKeep" && root.themeCan("keep")) ThemePreview.keep();
        if (id === "themeRevert" && root.themeCan("revert")) ThemePreview.revert("Reverted");
        if (id === "themeRegenerate" && root.themeCan("regenerate")) ThemePreview.regenerate();
        // 12E
        if (id === "exportSettings") Portability.exportNow(false);
        if (id === "exportAll") Portability.exportNow(true);
        if (id === "importApply" && root.rowReason({ id: id }).length === 0) Portability.importNow();
        if (id === "importDiscard") Portability.discard();
        if (id === "importUndo") Portability.undo();
        // 12D: presets
        if (id === "presetSaveCurrent") root.presetSel = Presets.saveCurrent("My preset");
        if (root.presetSelected) {
            const pid = root.presetSelected.id;
            if (id === "presetApply" && root.presetWhyNot({ id: id }).length === 0)
                Presets.apply(pid, root.presetGroupsChosen());
            if (id === "presetDuplicate") { const nid = Presets.duplicate(pid); if (nid.length > 0) root.presetSel = nid; }
            if (id === "presetUpdate") Presets.updateFromCurrent(pid);
            if (id === "presetRestore") Presets.restorePrevious(pid);
            if (id === "presetDelete") {
                if (root.presetDeleteArmed) { Presets.remove(pid); root.presetDeleteArmed = false; root.presetSel = ""; }
                else { root.presetDeleteArmed = true; presetDisarm.restart(); }
            }
        }
        // 10B: aplica de verdad (el anterior de Recent, con su esquema); el resultado se ve en la fila
        if (id === "wallRestore") Wallpaper.restorePrevious();
        // 10E-1a: Test connection pide sólo al pulsarlo; quitar la clave pide una segunda pulsación
        if (id === "whTest") WallhavenAccount.test();
        // 14E: activar o devolver la edición de los plazos (dos pulsaciones: toca hypridle.conf)
        if ((id === "idleOn" || id === "idleOff") && root.rowReason({ id: id }).length === 0) {
            if (!root.idleArmed) { root.idleArmed = true; idleDisarm.restart(); }
            else { root.idleArmed = false; Idle.manage(id === "idleOn", root.screenName); }
        }
        if (id === "idleUndo") Idle.undo(root.screenName);
        // 14D: el borrador del perfil de red
        if (id === "netApply" && root.rowReason({ id: id }).length === 0 && root.netSelected)
            NetProfiles.save(root.netSel, root.netDraft, root.screenName);
        if (id === "netDiscard") root.netDraft = ({});
        if (id === "netUndo") NetProfiles.undo(root.screenName);
        if (id === "whRemove") {
            if (root.whRemoveArmed) { WallhavenAccount.remove(); root.whRemoveArmed = false; }
            else { root.whRemoveArmed = true; whRemoveDisarm.restart(); }
        }
    }

    // ---- Grabador 2.0: Settings → Screen recording ----------------------------------------------------

    /** La página a la vista: el plan de Full screen en esta pantalla y lo que hay en la máquina, al día. */
    readonly property bool recPageShown: root.open && root.pageKey === "shell/recording"
    onRecPageShownChanged: if (root.recPageShown) {
        ScreenRecorder.refreshProbe();
        ScreenRecorder.wantPlan(root.screenName, "screen");
    }
    /** Lo que no se aceptó en un campo de texto (fps, altura, carpeta, nombre): se dice en su nota. */
    property var recFieldErrors: ({})
    function recFieldError(field, why) {
        const e = Object.assign({}, root.recFieldErrors);
        if (why.length > 0) e[field] = why;
        else delete e[field];
        root.recFieldErrors = e;
    }
    function recFieldNote(field) {
        if (root.recFieldErrors[field] !== undefined) return root.recFieldErrors[field];
        if (field === "fps") return Settings.recFps > 0 ? Settings.recFps + " fps" : "Automatic";
        if (field === "height") return Settings.recHeight > 0 ? Settings.recHeight + " px tall" : "Native";
        if (field === "dir") return Settings.recDir.length > 0 ? Settings.recDir : "Default · " + root.recPretty(ScreenRecorder.outputDir);
        if (field === "name") return Settings.recName;
        return "";
    }
    function recPretty(p) { return String(p || "").replace(Quickshell.env("HOME") || "\u0000", "~"); }
    /** Validar y guardar un campo; nunca se recorta en silencio: lo que no vale se dice y no cambia nada. */
    function recCommit(field, text) {
        const t = String(text || "").trim();
        let why = "";
        if (field === "fps") {
            const n = Number(t);
            if (t.length === 0) Settings.recFps = 0;
            else if (!/^\d+$/.test(t) || n < 1 || n > 240) why = "Type a whole number from 1 to 240";
            else Settings.recFps = n;
        } else if (field === "height") {
            const n = Number(t.replace(/p$/i, ""));
            if (t.length === 0) Settings.recHeight = 0;
            else if (!/^\d+p?$/i.test(t) || n < 144 || n > 4320) why = "Type a height from 144 to 4320";
            else Settings.recHeight = n - n % 2;
        } else if (field === "dir") {
            if (t.length > 0 && t.charAt(0) !== "/" && t.charAt(0) !== "~") why = "Only local folders: /… or ~/…";
            else if (t.indexOf("://") >= 0 || t.length > 4096) why = "Only local folders";
            else Settings.recDir = t;
        } else if (field === "name") {
            if (/[\/\x00-\x1f]/.test(t)) why = "No slashes or control characters";
            else if (t.length > 120) why = "At most 120 characters";
            else Settings.recName = t.length > 0 ? t : "Recording {date} {time}";
        }
        root.recFieldError(field, why);
    }
    function recOptions(kind) {
        const cur = Settings;
        if (kind === "recEncoder") {
            const out = [{ label: "Automatic", value: "auto" }];
            for (const e of ScreenRecorder.encoders) if (e.ok) out.push({ label: e.label, value: e.id });
            if (cur.recEncoder !== "auto" && !out.some(o => o.value === cur.recEncoder)) {
                const e = ScreenRecorder.encoders.find(x => x.id === cur.recEncoder);
                out.push({ label: (e ? e.label : cur.recEncoder) + (ScreenRecorder.probe ? " · not available" : ""), value: cur.recEncoder });
            }
            return out;
        }
        if (kind === "recFps") {
            // las de siempre y las que dividen el refresco de esta pantalla (en 200 Hz, 50/100/200): las fluidas
            const vals = [24, 30, 60, 120].concat(root.recSmooth().filter(d => d >= 45));
            const out = [{ label: "Auto", value: 0 }].concat(vals.filter((v, i) => vals.indexOf(v) === i)
                .sort((a, b) => a - b).map(v => ({ label: String(v), value: v })));
            if (!out.some(o => o.value === cur.recFps)) out.push({ label: cur.recFps + " fps", value: cur.recFps });
            return out;
        }
        if (kind === "recHeight") {
            const out = [{ label: "Native", value: 0 }, { label: "1080p", value: 1080 }, { label: "720p", value: 720 }];
            if (!out.some(o => o.value === cur.recHeight)) out.push({ label: cur.recHeight + "p", value: cur.recHeight });
            return out;
        }
        if (kind === "recFormat") {
            const out = [{ label: "MP4", value: "mp4" }, { label: "MKV", value: "mkv" }];
            // WebM sólo lleva AV1: se ofrece si algún AV1 funciona aquí (o si ya estaba elegido, para no perderlo)
            if (ScreenRecorder.encoders.some(e => e.codec === "av1" && e.ok) || cur.recFormat === "webm")
                out.push({ label: "WebM", value: "webm" });
            return out;
        }
        if (kind === "recSystemSource" || kind === "recMicSource") {
            const sys = kind === "recSystemSource";
            const list = sys ? ScreenRecorder.audioSources.system : ScreenRecorder.audioSources.mic;
            const out = [{ label: sys ? "Default output" : "Default input", value: "" }]
                .concat((list || []).map(x => ({ label: String(x.label).replace(/^Monitor of /, ""), value: x.name })));
            const v = sys ? cur.recSystemSource : cur.recMicSource;
            if (v.length > 0 && !out.some(o => o.value === v)) out.push({ label: v + " · not connected", value: v });
            return out;
        }
        return [];
    }
    function recInfo(id) {
        const p = ScreenRecorder.planNow;
        switch (id) {
        case "recNow":
            if (!p) return ScreenRecorder.probing ? "Checking…" : "—";
            return p.error ? "Can't record like this" : ScreenRecorder.specOf(p);
        case "recEncoders": {
            const ok = ScreenRecorder.encoders.filter(e => e.ok);
            if (ScreenRecorder.probing && ok.length === 0) return "Testing…";
            const gpu = ok.filter(e => e.kind === "gpu").map(e => e.label.replace(" (GPU)", ""));
            const cpu = ok.filter(e => e.kind === "cpu").map(e => e.label.replace(" (CPU)", ""));
            return [gpu.length ? gpu.join(", ") + " (GPU)" : "", cpu.length ? cpu.join(", ") + " (CPU)" : ""]
                .filter(x => x.length > 0).join(" · ") || "None";
        }
        case "recCursor": return "Always recorded";
        case "recPause": return "Supported";
        case "recMix": return !ScreenRecorder.micAvailable ? "No microphone found"
            : Settings.recSystemAudio && Settings.recMic ? "Mixed when saving" : "One source";
        case "recExisting": return "Never overwritten";
        }
        return "";
    }
    function recReason(r) {
        switch (r.id) {
        case "recBitrate": return Settings.recQuality !== "bitrate" ? "Only with the Bitrate quality" : "";
        case "recSystemSource":
            if (!Settings.recSystemAudio) return "Turn system audio on first";
            return ScreenRecorder.probe && ScreenRecorder.audioSources.system.length === 0 ? "No audio output found" : "";
        case "recMicSource":
            if (!Settings.recMic) return "Turn the microphone on first";
            return ScreenRecorder.probe && ScreenRecorder.audioSources.mic.length === 0 ? "No microphone found" : "";
        case "recSampleRate":
            return Settings.recAudioCodec === "opus" || Settings.recFormat === "webm" ? "Opus always records at 48 kHz" : "";
        case "recAudioCodec": return Settings.recFormat === "webm" ? "WebM always uses Opus" : "";
        case "recProbe": return ScreenRecorder.probing ? "Testing…" : "";
        }
        return "";
    }
    /** El refresco de esta pantalla según el helper (0 si aún no se sabe). */
    function recHz() {
        return ScreenRecorder.probe && ScreenRecorder.probe.screens
            ? (ScreenRecorder.probe.screens.find(x => x.name === root.screenName) || {}).refresh || 0 : 0;
    }
    /** Los fps que dividen el refresco (≥ 24): los únicos con pasos iguales (helper: `smooth_rates`, Fluidez 2026-11-12). */
    function recSmooth() {
        const hz = Math.round(root.recHz());
        const out = [];
        for (let d = 24; d <= hz; d++) if (hz % d === 0) out.push(d);
        return out;
    }
    /** El que toman los presets y Auto: el divisor más cercano a `target` (empate: el menor), como `smooth_fps`. */
    function recSmoothNear(target) {
        const hz = Math.round(root.recHz());
        if (hz < 1) return target;
        let best = 0;
        for (let d = 1; d <= hz; d++)
            if (hz % d === 0 && (best === 0 || Math.abs(d - target) < Math.abs(best - target))) best = d;
        return best;
    }
    function recCaption(r) {
        const p = ScreenRecorder.planNow;
        const hz = root.recHz();
        switch (r.id) {
        case "recPreset":
            return Settings.recPreset === "standard" ? "Native size · " + root.recSmoothNear(30) + " fps · automatic encoder · balanced quality"
                : Settings.recPreset === "high" ? "Native size · " + root.recSmoothNear(60) + " fps · the GPU when it works · high quality"
                : "Custom is below · Standard and High use the smooth rate nearest 30 or 60";
        case "recNow":
            if (ScreenRecorder.active) return "A recording is running: changes apply to the next one";
            if (p && p.error) return p.error;
            if (p && p.warnings && p.warnings.length > 0) return p.warnings[0];
            return "Full screen on " + root.screenName + (p && p.file ? " · " + p.file : "");
        case "recEncoder": {
            if (Settings.recPreset !== "custom")
                return "Custom preset · not in use: the recorder uses " + ScreenRecorder.presetName;
            const e = ScreenRecorder.encoders.find(x => x.id === Settings.recEncoder);
            if (e && !e.ok) return e.why.length > 0 ? e.why : "Not available here: H.264 is used instead";
            return Settings.recEncoder === "auto" ? "H.264 on the GPU when it works, otherwise on the CPU"
                : e && e.kind === "gpu" ? "Encoded by the GPU: almost no CPU" : "Encoded by the CPU: works everywhere, costs CPU";
        }
        case "recFps": {
            // fluido = el fps divide el refresco: 60 sobre 200 Hz toma 3,3,4 fotogramas y el movimiento tiembla
            const sm = root.recSmooth().filter(d => d >= 45);
            if (hz <= 0) return "Auto = the screen's refresh, up to 60";
            return "Auto = " + root.recSmoothNear(60) + " fps at " + Math.round(hz) + " Hz"
                + (sm.length > 0 ? " · smooth here: " + sm.join(", ") : "");
        }
        case "recFpsOther": return "1–240 · above the screen's refresh, frames only repeat";
        case "recQuality": return Settings.recQuality === "bitrate" ? "A fixed size per second, whatever is on screen"
            : "The same sharpness with every encoder, each on its own scale";
        case "recBitrate": return "Megabits per second of video";
        case "recHeight": return "Never upscaled · the width keeps the proportions";
        case "recHeightOther": return "144–4320 px · empty = native";
        case "recFormat": return "MP4 plays everywhere · MKV survives a cut · WebM is AV1 + Opus";
        case "recEncoders": {
            const pads = ScreenRecorder.encoders.filter(e => e.ok && e.pads).map(e => e.label);
            return (pads.length ? pads.join(", ") + " adds a black edge unless the size is a multiple of 64×16 (then H.264) · " : "")
                + "No NVENC, Quick Sync or Vulkan: untested with wf-recorder";
        }
        case "recProbe": return "Encodes one test frame with each encoder · about half a second";
        case "recCursor": return "wf-recorder always asks the compositor for the pointer: it can't be left out";
        case "recPause": return "Pausing closes a part; stopping joins the parts without re-encoding";
        case "recSystemAudio": return "What your speakers play";
        case "recSystemSource": return "The monitor of an output · Default follows the output in use";
        case "recMic": return ScreenRecorder.micAvailable ? "Your voice, mixed with system audio when both are on" : "No microphone found";
        case "recMicSource": return "A real input · Default follows the input in use";
        case "recAudioCodec": return "AAC plays everywhere · Opus is smaller at the same quality";
        case "recAudioBitrate": return "Encoded once, when saving";
        case "recSampleRate": return "48 kHz is what PipeWire uses";
        case "recMix": return "Recorded apart and mixed in when saving (~13 ms from system audio)";
        case "recDir": {
            const dc = ScreenRecorder.probe ? ScreenRecorder.probe.dirCheck : null;
            if (dc && dc.error) return dc.error;
            if (dc && dc.free >= 0) return ScreenRecorder.fmtBytes(dc.free) + " free" + (dc.exists ? "" : " · created when you record");
            return "Type a folder · empty = your Videos folder";
        }
        case "recName": return "{date} {time} {screen}" + (p && p.file ? " · " + p.file : "");
        case "recExisting": return "A number is added: “Recording … (2)”";
        case "recOpenDir": return root.recPretty(ScreenRecorder.outputDir);
        case "recDelay": return "Before recording starts · D in the recorder turns it off and on";
        case "recIndicator": return "Under the capsule or Edge and in the Dynamic Bar · the privacy dot always shows";
        case "recTimer": return "The elapsed time in the indicator";
        case "recIslandControls": return "Pause, stop and copy without opening the recorder";
        case "recBarControls": return "Pause, stop and copy in the bar's status area";
        case "recNotify": return "A notification with the file, its length and size";
        case "recOpenFolder": return "Opens your file manager on the recordings folder";
        case "recRememberMode": return "Otherwise the recorder always starts on Full screen";
        }
        return "";
    }

    // ---- Theme → Material → Surfaces (2026-10-28) -----------------------------------------

    /**
     * La superficie que se mira en la sección: estado de la vista, no se guarda. Lo que se elige
     * abajo es de ELLA y sólo esa propiedad: material y opacidad heredan por separado. Resolver los
     * valores efectivos es de Theme (materialFor / opacityFor); aquí sólo se enseñan.
     */
    property string matSurface: "settings"
    /** Sin sufijos: la marca de la fila y «Customized surfaces» dicen cuáles tienen algo propio. */
    readonly property var surfPickOptions: SurfaceMaterials.SURFACES.map(e => ({ label: e.label, value: e.id }))
    readonly property bool surfHasOwn: {
        const o = Settings.surfaceOverride(root.matSurface);
        return o.material !== undefined || o.opacity !== undefined;
    }
    function pct(v) { return v >= 1 ? "Opaque" : (Math.round(v * 1000) / 10) + "%"; }
    /** "inherit" o lo guardado para esta superficie. */
    function surfValue(opt) {
        const v = Settings.surfaceOverride(root.matSurface)[opt];
        return v === undefined ? "inherit" : v;
    }
    function setSurf(opt, v) { Settings.setSurfaceMaterial(root.matSurface, opt, v === "inherit" ? undefined : v); }
    /** La primera opción dice qué se hereda AHORA: cambia con el global. */
    function surfOptions(opt) {
        if (opt === "material")
            return [{ label: "Global (" + SurfaceMaterials.materialName(Settings.material) + ")", value: "inherit" },
                    { label: "Glass", value: "glass" }, { label: "Vidrio Satinado", value: "satin" }];
        return [{ label: "Global (" + root.pct(Settings.glassOpacity) + ")", value: "inherit" }].concat(root.glassOptions);
    }
    /** Lo que se ve en esa superficie: «Vidrio Satinado · 80%». */
    function surfSummary(key) {
        return SurfaceMaterials.materialName(Theme.materialFor(key)) + " · " + root.pct(Theme.opacityFor(key));
    }
    function surfCaption(r) {
        const name = SurfaceMaterials.labelOf(root.matSurface);
        const own = Settings.surfaceOverride(root.matSurface);
        if (r.kind === "surfPick") return "Without values of its own it follows the global material and opacity";
        if (r.kind === "surfOpt" && r.opt === "material")
            return own.material !== undefined ? "Custom for " + name + " · the global material no longer changes it"
                : "Inherited · follows the global material";
        if (r.kind === "surfOpt")
            return own.opacity !== undefined ? "Custom for " + name + " · the global opacity no longer changes it"
                    + (own.opacity < 0.94 ? " · text behind can show through below 94%" : "")
                : "Inherited · follows the global opacity";
        if (r.id === "surfEffective")
            return (own.material !== undefined ? "Material custom" : "Material inherited")
                + " · " + (own.opacity !== undefined ? "opacity custom" : "opacity inherited");
        if (r.id === "surfReset") return "Back to the global material and opacity · other surfaces keep theirs";
        if (r.id === "surfCustom") {
            const l = SurfaceMaterials.customized(Settings.surfaceMaterials).map(k => SurfaceMaterials.labelOf(k));
            return l.length === 0 ? "Every surface follows the global material" : l.join(", ");
        }
        return "";
    }

    // ---- 12C: el perfil del escritorio ------------------------------------------------

    /** La selección de ESTA vista ("" = sigue a lo que se ve: la prueba o lo confirmado). */
    property string themeSel: ""
    readonly property string themeSelected: root.themeSel.length > 0 ? root.themeSel
        : (ThemePreview.live && ThemePreview.requested.length > 0 ? ThemePreview.requested : ThemePreview.confirmed)
    /** Lo confirmado cambió (Keep aquí o fuera): la selección vuelve a seguirlo. */
    /** …y al empezar otra prueba (aquí o en el carrusel): las dos vistas enseñan lo mismo. */
    Connections {
        target: ThemePreview
        function onConfirmedKeyChanged() { root.themeSel = ""; root.themeSelOpts = ({}); }
        function onRequestedKeyChanged() { root.themeSel = ""; root.themeSelOpts = ({}); }
    }
    /** 12F: selección local de modo / contraste / origen (undefined = sigue a lo que se ve). */
    property var themeSelOpts: ({})
    readonly property var themeShownOpts: ThemePreview.live && ThemePreview.requested.length > 0
        ? ThemePreview.requestedOpts : ThemePreview.confirmedOpts
    readonly property var themeSelectedOpts: ThemePreview.normOpts(root.themeSelected, {
        lightness: root.themeSelOpts.lightness !== undefined ? root.themeSelOpts.lightness : root.themeShownOpts.lightness,
        contrast: root.themeSelOpts.contrast !== undefined ? root.themeSelOpts.contrast : root.themeShownOpts.contrast,
        source: root.themeSelOpts.source !== undefined ? root.themeSelOpts.source : root.themeShownOpts.source })
    readonly property string themeSelectedKey: ThemePreview.keyOf(root.themeSelected, root.themeSelectedOpts)
    /** El último hex escrito en el campo (se conserva al volver a Wallpaper y otra vez a Custom). */
    property string themeHexDraft: ""
    function setThemeOpt(opt, v) {
        // F-c: con un preset, Mode elige la variante de su familia (es otro perfil, no una opción)
        if (opt === "lightness" && ThemePreview.isPreset(root.themeSelected)) {
            const other = ThemePreview.variantFor(root.themeSelected, ThemePreview.normMode(v));
            if (other.length > 0) root.themeSel = other;
            return;
        }
        const t = Object.assign({}, root.themeSelOpts);
        if (opt === "sourceKind") {
            if (v === "wallpaper") t.source = "wallpaper";
            else {
                const cur = root.themeSelectedOpts.source;
                t.source = cur !== "wallpaper" ? cur : (root.themeHexDraft.length > 0 ? root.themeHexDraft : "#3a7bd5");
            }
        } else t[opt] = v;
        root.themeSelOpts = t;
    }
    readonly property bool themeBusy: ["restoring", "keeping", "recovering"].indexOf(ThemePreview.phase) >= 0
    readonly property bool themeElsewhere: ThemePreview.live && ThemePreview.owner.length > 0
        && ThemePreview.owner !== root.screenName
    /** Por qué no se puede ahora (o ""): el motivo de la fila. */
    function themeWhyNot(what) {
        if (root.themeElsewhere) return "Preview active on " + ThemePreview.owner;
        if (what === "preview") {
            if (root.themeBusy) return "Wait for the current step to finish";
            // F2c: sin proveedor (matugen, apply-static-colors.sh, python3) no se prueba aquí
            const cap = ThemePreview.whyNot(root.themeSelected);
            if (cap.length > 0) return cap;
            if (ThemePreview.baseWall.length === 0 && !ThemePreview.isStatic(root.themeSelected)
                    && root.themeSelectedOpts.source === "wallpaper")
                return "No wallpaper: use a custom colour or pick a wallpaper";
            if (ThemePreview.live ? root.themeSelectedKey === ThemePreview.requestedKey
                                  : root.themeSelectedKey === ThemePreview.confirmedKey)
                return ThemePreview.live ? "Already previewing this" : "Already applied";
            return "";
        }
        if (what === "keep")
            return ThemePreview.phase === "active" && ThemePreview.requestedKey === ThemePreview.previewingKey ? ""
                : ThemePreview.phase === "preparing" ? "Preparing the preview…" : "No preview to keep";
        if (what === "revert")
            return ThemePreview.live && !root.themeBusy ? "" : "No preview active";
        if (what === "regenerate") {
            if (ThemePreview.live) return "Keep or revert the preview first";
            if (!ThemePreview.baseEnabled) return "Static palette: nothing to regenerate";
            const cap = ThemePreview.whyNot(ThemePreview.confirmed);
            if (cap.length > 0) return cap;
            if (ThemePreview.baseWall.length === 0 && ThemePreview.confirmedOpts.source === "wallpaper") return "No wallpaper";
            return "";
        }
        return "";
    }
    function themeCan(what) { return root.themeWhyNot(what).length === 0; }
    /** Lo que pasa con la prueba, corto (pie de Preview). */
    readonly property string themeStatus: {
        const ph = ThemePreview.phase;
        if (ph === "failed") return ThemePreview.error;
        if (ph === "restoring") return "Restoring your theme…";
        if (ph === "keeping") return "Keeping " + ThemePreview.describe(ThemePreview.previewing, ThemePreview.previewingOpts) + "…";
        if (ph === "preparing") return "Preparing preview of " + ThemePreview.describe(ThemePreview.requested, ThemePreview.requestedOpts) + "…";
        if (ph === "active")
            return "Previewing " + ThemePreview.describe(ThemePreview.previewing, ThemePreview.previewingOpts)
                + " · " + (ThemePreview.reopenNow.length > 0
                           ? ThemePreview.reopenText(ThemePreview.reopenNow, ThemePreview.lightnessFrom !== ThemePreview.lightnessTo)
                           : "Some apps may need reopening to update their colors");
        const r = ThemePreview.lastResult;
        if (r && r.kind === "kept") return "Kept " + (r.label || ThemePreview.nameOf(r.profile))
            + (r.reopen && r.reopen.length > 0 ? " · " + ThemePreview.reopenText(r.reopen, r.modeChanged) : "");
        if (r && r.kind === "external") return "Preview stopped: the theme changed outside it";
        return "Try the selected profile on the whole desktop, then keep or revert it";
    }
    /** Esta página es un control de la prueba (12C): cuenta como vista abierta. */
    readonly property bool colorsShown: root.open && root.pageKey === "theme/colors" && root.screenName.length > 0
    onColorsShownChanged: {
        // al llegar a la página, la selección sigue a lo que se ve (no a una visita vieja)
        if (root.colorsShown) { root.themeSel = ""; root.themeSelOpts = ({}); ThemePreview.viewOpened(root.screenName, "settings"); }
        else ThemePreview.viewClosed(root.screenName, "settings");
    }

    /** Un enlace a otra surface: el host lo apila, así que Esc vuelve aquí (a esta página). */
    /** `key` (13F): la pista de la surface destino (el Mixer abre su EQ o Applications). */
    function openLink(name, key) {
        if (name === "audio" && key === "equalizer" && !Equalizer.supported) return;
        // antes de la fase 14: la Audio UI es una capa (como la del monitor); Settings le deja sitio
        if (name === "audio") {
            if (AudioUi.show(root.screenName, String(key || "overview"))) root.requestClose();
            return;
        }
        // Settings UI: la superficie se abre ENCIMA de la ventana, que sigue debajo; al cerrarla
        // (Esc) se vuelve a esta página tal cual estaba, como antes con la pila del host
        if (root.floating) { root.requestLink(name, key === undefined || key === null ? "" : String(key)); return; }
        if (!root.host) return;
        if (key !== undefined && key !== null && String(key).length > 0) root.host.forwardTo(name, key);
        else root.host.forward(name);
    }

    /**
     * Abrir una ruta `dest/página[/fila]` (enlaces contextuales, resultados de la búsqueda,
     * IPC `settingsOpen`). false si la página o la fila no existen: nunca enfoca otra fila
     * en su lugar (DESIGN §3, «no actuar sobre lo que ahora ocupe ese sitio»).
     */
    function openPath(path) {
        const parts = path.split("/");
        // Keep contextual links and existing IPC paths after grouping the small pages.
        if (parts[0] === "shell" && (parts[1] === "surfaces" || parts[1] === "launcher")) {
            const oldPage = parts[1];
            const oldRow = oldPage === "surfaces" ? "thumbs" : "scrollbar";
            if (parts.length > 2 && parts.slice(2).join("/") !== "" && parts.slice(2).join("/") !== oldRow) return false;
            parts[1] = "panels";
            if (parts.length < 3 || parts[2] === "") parts[2] = oldRow;
        }
        // 2026-10-28: Material pasó de Shell a Theme; la ruta vieja (IPC, enlaces) sigue llevando a ella
        if (parts[0] === "shell" && parts[1] === "material") parts[0] = "theme";
        if (root.destSurface[parts[0]] === undefined) return false;
        const d = root.destEntry(parts[0]);
        const page = parts.length > 1 && parts[1].length > 0 ? parts[1] : root.defaultPages[parts[0]];
        const pg = d.pages.find(p => p.id === page);
        if (!pg) return false;
        // la fila puede llevar «/» (las dinámicas: `recent:/home/…`); 12D: también se buscan en
        // las secciones dinámicas (antes sólo las fijas: un enlace a un preset o a una entrada de
        // Recent devolvía false y dejaba el foco donde cayera)
        const row = parts.length > 2 ? parts.slice(2).join("/") : "";
        const sec = row.length > 0
            ? pg.sections.find(sc => root.visibleRows(sc.dynamic ? root.dynRows(sc.dynamic) : sc.rows).some(r => r.id === row)) : null;
        if (row.length > 0 && !sec) return false;
        if (row === "recBitrate") root.showBitrate = true;
        // una fila de Advanced / Experimental: su bloque se abre para poder enfocarla (§8)
        if (sec && sec.level) root.setExpanded(parts[0] + "/" + page, sec.level, true);
        root.endSearch(false);
        root.goPage(parts[0], page, row);
        root.zone = "content";
        root.forceActiveFocus();
        return row.length === 0 || root.currentRowId() === row;
    }

    // ---- búsqueda (futureSettingssurface §8) ------------------------------------------

    /**
     * Sinónimos en inglés por fila (la etiqueta, la sección y los breadcrumbs ya cuentan).
     * Se indexan METADATOS: nunca valores del usuario, rutas ni resultados de red.
     */
    readonly property var synonyms: ({
        // Grabador 2.0
        recPreset: ["recording", "recorder", "screen recorder", "screencast", "capture", "video", "quality", "standard", "high", "custom"],
        recNow: ["recording", "recorder", "resolution", "fps", "codec"],
        recEncoder: ["codec", "encoder", "h264", "h.264", "hevc", "h265", "av1", "vaapi", "gpu", "hardware", "x264", "nvenc", "quick sync"],
        recFps: ["fps", "framerate", "frame rate", "frames", "60", "120", "refresh"],
        recQuality: ["bitrate", "crf", "qp", "quality", "sharpness"],
        recHeight: ["resolution", "1080p", "720p", "scale", "size"],
        recFormat: ["mp4", "mkv", "webm", "container", "format"],
        recSystemAudio: ["audio", "sound", "desktop audio", "speakers", "recording"],
        // Reproductor del Mixer (2026-11-09)
        mediaBackdrop: ["player", "media", "music", "album art", "artwork", "cover", "background", "blur"],
        mediaCoverShape: ["player", "media", "music", "album art", "artwork", "cover", "disc", "vinyl", "record", "round"],
        mediaEndTime: ["player", "media", "music", "remaining", "duration", "length", "time", "countdown"],
        recMic: ["microphone", "mic", "voice", "recording"],
        recAudioCodec: ["aac", "opus", "audio codec"],
        recDir: ["folder", "directory", "videos", "save", "recordings"],
        recName: ["filename", "file name", "name", "date"],
        recDelay: ["countdown", "delay", "timer", "recording"],
        recIndicator: ["hud", "capsule", "edge", "dynamic bar", "island", "notch", "bar", "indicator", "recording"],
        recNotify: ["notification", "recording"],
        recCursor: ["cursor", "pointer", "mouse"],
        // F3b
        terminal: ["terminal", "console", "emulator", "kitty", "foot", "alacritty", "wezterm", "ghostty",
                   "konsole", "programs", "apps"],
        terminalExec: ["terminal", "command", "exec", "-e", "arguments"],
        browser: ["browser", "web", "links", "firefox", "chromium", "zen", "default", "programs", "apps"],
        envStatus: ["environment", "capabilities", "dependencies", "missing", "installed", "requirements",
                    "diagnostics", "detected", "portability"],
        envRefresh: ["refresh", "detect", "recheck", "capabilities", "dependencies"],
        scale: ["size", "zoom", "dpi", "bigger", "smaller", "ui"],
        autoHide: ["hide", "retract", "hidden"],
        musicCircle: ["circle", "side", "music", "media", "album art", "capsule", "edge", "island", "notch", "hide", "show"],
        islandWheel: ["gesture", "gestures", "scroll", "wheel", "mouse", "volume", "capsule", "edge", "island", "notch"],
        islandMiddle: ["gesture", "gestures", "middle click", "middle", "click", "mouse", "play", "pause", "music", "media",
            "capsule", "edge", "island", "notch"],
        netCircle: ["circle", "side", "network", "wifi", "wi-fi", "ethernet", "capsule", "edge", "island", "notch", "hide", "show"],
        reserve: ["exclusive", "gap", "tiling", "margin"],
        hoverPreview: ["hover", "peek", "preview", "pointer"],
        ws: ["workspaces", "dots", "desktops"],
        polkit: ["root", "password", "sudo", "authentication", "agent"],
        motion: ["animation", "animations", "reduce motion", "speed", "transitions", "off"],
        windowStyle: ["window", "windows", "style", "minimalist", "expressive", "gnome", "open", "close", "dialog", "lift",
            "power", "power-on", "crt", "turn on", "transition", "bloom", "capsule", "mochi", "bounce", "spring", "ink",
            "scroll", "unroll", "mist", "blur", "focus", "animation", "effect"],
        barPanels: ["bar", "dynamic bar", "panel", "panels", "slide", "drawer", "grow", "open", "animation", "spring", "bounce", "unfold",
            "strip", "flap", "fold", "bloom", "glow", "ink", "drop", "mist", "blur", "focus", "style", "effect"],
        islandStyle: ["capsule", "dynamic capsule", "edge", "island", "dynamic island", "notch", "style", "open", "animation", "fluid", "mochi", "bounce", "drop",
            "jelly", "squash", "stretch", "power", "power-on", "line", "bloom", "glow", "ink", "mist", "blur", "focus", "effect"],
        // estilo de interfaz (2026-11-14, ADR-34)
        interfaceStyle: ["terminal", "tui", "retro", "crt", "soft", "rounded", "square", "corners", "shape", "geometry", "look", "appearance"],
        termFrame: ["terminal", "border", "frame", "double", "segmented", "dashed", "outline"],
        termDecor: ["terminal", "brackets", "corners", "decorations", "marks", "ornaments"],
        termMono: ["terminal", "monospace", "mono", "font", "code", "typeface"],
        fxGlitch: ["terminal", "interference", "static", "noise", "signal", "glitch", "camera", "effect", "effects", "retro", "crt"],
        fxScanlines: ["terminal", "scanlines", "scan", "lines", "crt", "retro", "effect", "effects"],
        fxGlow: ["terminal", "glow", "halo", "shadow", "neon", "effect", "effects"],
        dock: ["edge", "notch", "dynamic notch", "bar-edge", "dock", "macos", "presentation"],
        dockPreview: ["edge", "notch", "dock", "sample", "demo"],
        dockMotion: ["animation"],
        dockOsd: ["volume", "brightness"],
        dockGestures: ["gesture", "gestures", "scroll", "wheel", "middle click", "volume", "play", "pause"],
        notchCorners: ["edge", "bar-edge", "notch", "corner", "corners", "radius", "round", "rounded", "square", "shape"],
        notchFlare: ["bar-edge", "notch", "flare", "join", "edge", "curve", "shoulder", "shape"],
        notchColor: ["edge", "notch", "color", "colour", "black", "oled", "bezel", "dark"],
        notchRest: ["edge", "notch", "rest", "clock", "minimal", "idle", "time", "hide"],
        notchActMusic: ["edge", "notch", "activity", "live", "music", "media", "album art", "waves", "ears"],
        notchViz: ["edge", "notch", "visualizer", "cava", "waves", "spectrum", "bars", "fps", "music", "audio"],
        notchActRecording: ["edge", "notch", "activity", "live", "recorder", "recording", "rec", "timer", "ears"],
        notchActSpeed: ["edge", "notch", "activity", "live", "speed test", "speedtest", "network", "rocket", "ears"],
        notchActWork: ["edge", "notch", "activity", "live", "tasks", "jobs", "downloads", "wallhaven", "progress", "ears"],
        notchActPower: ["edge", "notch", "activity", "live", "charger", "battery", "power", "plugged", "laptop", "ears"],
        notchActCopy: ["edge", "notch", "activity", "live", "copied", "clipboard", "emoji", "paste", "ears"],
        notchActBluetooth: ["edge", "notch", "activity", "live", "bluetooth", "headphones", "headset", "battery", "ears"],
        notchActWorkspace: ["edge", "notch", "activity", "live", "workspace", "desktop", "switch", "ears"],
        speed: ["faster", "slower", "duration", "animation", "tempo"],
        themeCard: ["overview", "theme", "palette", "current"],
        outDev: ["speakers", "headphones", "output", "sink", "hdmi", "default"],
        outVol: ["volume", "sound", "loud", "output"], outMute: ["mute", "silence", "sound"],
        inDev: ["microphone", "mic", "input", "source"], inVol: ["microphone", "mic", "gain", "input"],
        inMute: ["microphone", "mic", "mute"], openMixer: ["mixer", "apps", "applications", "streams"],
        openApps: ["per-app", "routing", "app output", "app input", "move app", "applications"],
        openEq: ["equalizer", "eq", "bass", "treble", "preset", "preamp", "bands"],
        openAudioUi: ["audio settings", "balance", "channels", "sound card", "card profile", "ports", "devices"],
        netNow: ["network", "internet", "connection"], netCheck: ["internet", "online", "portal"],
        wiredNow: ["ethernet", "cable", "lan", "wired"], wifiNow: ["wifi", "wireless", "wlan", "ssid"],
        openWifi: ["wifi", "networks", "password"], openWired: ["ethernet", "ip", "dhcp"],
        btPower: ["bluetooth", "adapter", "radio"], openBt: ["bluetooth", "pair", "pairing", "devices"],
        profile: ["power", "performance", "balanced", "power saver", "battery", "energy"],
        idleLock: ["idle", "lock", "hypridle", "timeout", "minutes"], idleScreen: ["idle", "screen off", "dpms", "monitor", "timeout"],
        idleLock: ["lock", "idle", "timeout", "hypridle"], idleScreen: ["screen off", "dpms", "monitor", "idle"],
        idleSuspend: ["sleep", "suspend", "idle"], idleState: ["hypridle", "idle", "inhibit", "keep awake"],
        prefDisplay: ["monitor", "primary", "main screen", "anchor"], hyprConfig: ["lua", "config", "file", "hyprland.lua", "where"],
        netRollback: ["checkpoint", "rollback", "revert", "undo"],
        displaysEdit: ["monitor", "resolution", "refresh", "hz", "scale", "layout", "vrr"],
        inputEdit: ["mouse", "touchpad", "keyboard", "sensitivity", "repeat", "layout"],
        hyprEdit: ["gaps", "borders", "rules", "window"], hyprVer: ["hyprland", "version"],
        ovRandom: ["shuffle", "random", "wallpaper"],
        wallCurrent: ["favorite", "favourites", "star", "recent", "history", "background"],
        wallRestore: ["undo", "previous", "back", "revert", "last wallpaper"],
        rotOn: ["rotation", "slideshow", "cycle", "change", "timer", "automatic"],
        rotEvery: ["interval", "rotation", "minutes", "hours"], rotFrom: ["rotation", "favorites", "videos"],
        rotFullscreen: ["games", "fullscreen", "pause"], rotBattery: ["battery", "power", "pause"],
        rotModes: ["gaming", "cinema", "mode", "pause"],
        transition: ["animation", "effect", "fade", "wipe", "awww", "swww"],
        whKey: ["api", "key", "wallhaven", "token", "nsfw", "account", "secret"],
        pamInfo: ["pam", "authentication", "password", "faillock", "lockout", "login"],          // F5e
        pamChoice: ["pam", "authentication", "stack", "login"], pamTest: ["pam", "password", "test", "authentication"],
        lockEntry: ["lock", "logind", "hypridle", "loginctl"], lockHandler: ["lock", "hypridle", "hyprlock"],   // F5d
        whUser: ["username", "account", "wallhaven", "collections"],
        whTest: ["test", "check", "connection", "wallhaven", "validate"],
        whRemove: ["delete", "forget", "key", "wallhaven"],
        whAccount: ["filters", "purity", "account", "wallhaven"],
        swatches: ["palette", "colors", "colours", "contrast", "hex", "roles", "accent"],
        family: ["font", "iosevka", "typeface"],
        textSize: ["font size", "bigger", "smaller", "text", "readability"],
        variants: ["font", "nerd font", "mono", "propo"],
        iconTheme: ["icons", "icon pack"], cursorTheme: ["mouse", "pointer", "cursor size"],
        apIconFamily: ["icons", "icon pack", "icon theme", "papirus"], apIconVariant: ["icons", "dark", "light", "accent"],
        apCursor: ["mouse", "pointer", "cursor theme", "xcursor", "hyprcursor"], apCursorSize: ["mouse", "pointer", "cursor size"],
        apApplyIcons: ["apply", "icons", "gtk", "qt"], apApplyCursor: ["apply", "cursor", "mouse", "pointer", "gtk", "qt"],
        apUndo: ["undo", "revert", "icons", "cursor"], apUndoAll: ["restore", "revert", "icons", "cursor"],
        apGtkTheme: ["gtk", "adwaita", "theme"], apQtStyle: ["qt", "qt6ct", "kvantum", "style"],
        iconsInstalled: ["icons"], cursorsInstalled: ["mouse", "pointer"],
        srcImages: ["folder", "source", "pictures"], srcVideos: ["folder", "source", "videos", "live"],
        firstDay: ["week", "monday", "sunday", "start", "calendar"],
        // F3d-2: las frecuencias son filas por tarea (no se indexan); la fila del archivo las trae
        tasksFile: ["backup", "dotbackup", "diskbackup", "tasks", "maintenance", "overdue", "schedule",
                    "frequency", "health", "doctor", "tasks.json"],
        clock: ["time", "12-hour", "24-hour", "am", "pm", "format"],
        popupSec: ["notification", "popup", "timeout", "toast", "seconds"],
        notifPos: ["notification", "popup", "toast", "position", "corner", "place", "left", "right", "top", "bottom", "center"],
        notifMargin: ["notification", "popup", "toast", "margin", "gap", "edge", "distance", "spacing"],
        barEdge: ["bar", "panel", "taskbar", "position", "edge", "top", "bottom", "left", "right", "vertical", "side", "dock"],
        barLength: ["bar", "panel", "taskbar", "length", "width", "height", "size", "short", "long", "percent", "center", "shrink"],
        barReset: ["bar", "panel", "taskbar", "reset", "default", "position", "length"],
        dnd: ["do not disturb", "silence", "mute", "quiet", "focus"],
        osdMs: ["timeout", "volume", "brightness", "seconds", "indicator"],
        osdValue: ["percent", "percentage", "number", "volume", "brightness"],
        scrollbar: ["scroll", "launcher", "left", "right", "apps"],
        emojiAction: ["emoji", "kaomoji", "symbols", "glyphs", "nerd font", "picker", "paste", "copy", "clipboard"],
        focusInfo: ["keyboard", "focus", "hover", "pointer", "mouse"],
        shortcutsHelp: ["shortcuts", "keybinds", "keybindings", "hotkeys", "keys", "bindings", "help", "hyprland"],
        // la ventana Login screen (2026-11-23): sus ajustes ya no son filas de Settings; la búsqueda lleva a la puerta
        sddmOpen: ["sddm", "greeter", "login", "sign in", "login edge", "edge", "notch", "clock", "avatar", "users", "blur", "password",
                   "preview", "test window"],
        notifServer: ["notifications", "swaync", "dbus", "daemon"],
        bar: ["dynamic bar", "bar-edge", "hover bar", "panel", "persistent", "persistent bar", "taskbar", "waybar", "top bar"],
        modWeather: ["module"], modDock: ["module", "edge", "notch", "dock"],
        modPolkit: ["module"], modNotif: ["module"],
        unload: ["memory", "ram", "unload", "idle"],
        thumbs: ["thumbnails", "minimizer", "windows", "previews"],
        weather: ["forecast", "temperature", "open-meteo"],
        city: ["location", "place", "town"],
        units: ["celsius", "fahrenheit", "temperature"],
        osd: ["volume", "brightness", "overlay", "indicator", "popup"],
        avatar: ["picture", "photo", "face", "image", "lock"],
        fetch: ["fastfetch", "logo", "image", "lock"],
        lockPreview: ["preview", "lock", "screen", "try", "look"],
        video: ["video", "live", "animated", "wallpaper"],
        videoPause: ["pause", "video", "mpvpaper", "gaming", "cinema", "fullscreen", "battery"],
        libImages: ["library", "wallpapers", "count", "pictures"], libVideos: ["library", "live", "count"],
        wallSourceAdd: ["sources", "folder", "directory", "library", "add", "path"],
        wallDownloadDir: ["download", "wallhaven", "folder", "save", "destination"],
        openWallpapers: ["background", "wallpaper"],
        themeProfile: ["matugen", "colors", "colours", "palette", "dynamic", "static", "scheme", "tonal",
                       "vibrant", "expressive", "theme"],
        themePreview: ["try", "preview", "palette", "theme"],
        themeMode: ["light", "dark", "mode", "appearance", "night", "day"],
        themeContrast: ["contrast", "legibility", "accessibility", "readability"],
        themeSource: ["accent", "seed", "colour", "color", "custom", "source"],
        themeKeep: ["keep", "confirm", "apply", "theme"],
        themeRevert: ["revert", "undo", "restore", "theme"],
        themeRegenerate: ["regenerate", "matugen", "refresh", "colours", "colors"],
        glass: ["opacity", "transparency", "blur", "glass", "material", "translucent"],
        material: ["finish", "satin", "satinado", "glass", "frosted", "appearance"],
        surfPick: ["surface", "per-surface", "panel", "override", "individual", "material", "opacity", "wallhaven",
                   "notifications", "launcher", "settings", "media"],
        surfMaterial: ["per-surface", "override", "inherit", "satin", "satinado", "glass", "finish"],
        surfOpacity: ["per-surface", "override", "inherit", "transparency", "translucent"],
        surfEffective: ["effective", "current", "inherited", "material", "opacity"],
        surfReset: ["reset", "inherit", "global", "default"],
        surfCustom: ["overrides", "custom", "per-surface"],
        presetSaveCurrent: ["preset", "save", "profile", "compact", "minimal", "glass"],
        exportSettings: ["export", "backup", "save", "share", "portable", "json"],
        exportAll: ["export", "presets", "backup"],
        importFile: ["import", "restore", "load", "json", "backup"],
        openProfiles: ["theme", "palette", "scheme"],
        keepAwake: ["caffeine", "idle", "sleep", "suspend", "screen off", "inhibit"],
        shellVersion: ["version", "sumi", "release", "semver", "about"],
        shellApi: ["api", "ipc", "schema", "compatibility"],
        stScreens: ["screens", "monitors", "displays", "diagnostics", "shell state"],
        stFocused: ["focused", "monitor", "diagnostics", "shell state"],
        stPalette: ["palette", "colors", "matugen", "diagnostics", "shell state"],
        stWallpapers: ["wallpapers", "rotation", "bag", "diagnostics", "shell state"],
        stResumes: ["resume", "suspend", "wake", "diagnostics", "shell state"],
        stSettings: ["settings file", "config", "path", "json", "diagnostics", "shell state"],
        os: ["distro", "cachyos", "arch", "system"],
        kernel: ["linux", "version"],
        wm: ["hyprland", "wayland", "window manager"],
        cpu: ["processor", "ryzen"],
        gpu: ["graphics", "radeon", "video card"],
        mem: ["ram", "memory"],
        displays: ["monitor", "screen", "resolution"],
        openMonitor: ["cpu", "gpu", "usage", "performance", "sysmon"]
    })

    /**
     * Lo que se encuentra pero aún no se puede usar: aparece CON su motivo en vez de
     * desaparecer sin explicación (§8). Enter no abre nada.
     */
    // 13F: el Equalizer ya existe (System → Audio → Equalizer lleva al del Mixer); nada previsto.
    readonly property var planned: []
    function visibleRows(rows) {
        return rows.filter(r => r.id !== "openEq" || Equalizer.supported);
    }

    /** Todo lo que se puede buscar: filas y páginas de la tabla, y lo previsto. */
    readonly property var searchIndex: {
        const out = [];
        for (let i = 0; i < root.tree.length; i++) {
            const d = root.tree[i];
            for (let j = 0; j < d.pages.length; j++) {
                const p = d.pages[j];
                // Settings UI: las migas nombran el GRUPO de la barra lateral (Appearance › Colors);
                // el destino de antes (Theme) sigue contando para encontrarla (`area`)
                const g = Nav.groupOf(d.id + "/" + p.id);
                const top = g ? g.title : d.title;
                out.push({ kind: "page", id: p.id, label: p.title, crumbs: top, area: d.title,
                           path: d.id + "/" + p.id, syn: [], level: "common" });
                for (let k = 0; k < p.sections.length; k++) {
                    const sc = p.sections[k];
                    const rows = root.visibleRows(sc.rows);
                    for (let r = 0; r < rows.length; r++) {
                        const row = rows[r];
                        const lv = sc.level || "";
                        out.push({ kind: "row", id: row.id, label: row.name, row: row, area: d.title,
                                   crumbs: top + " › " + p.title + " › "
                                       + (lv.length > 0 ? root.levelTitle[lv] + " › " : "") + sc.title,
                                   path: d.id + "/" + p.id + "/" + row.id,
                                   syn: root.synonyms[row.id] || SysCat.SYNONYMS[String(row.id).replace(/^hypr:/, "")] || [],
                                   level: lv.length > 0 ? lv : "common" });
                    }
                }
            }
        }
        // la ventana Login screen (2026-11-23): cada clave de Sumi SDDM, para llegar a su fila en la ventana
        const sddmGroups = {};
        for (const g of SddmTheme.groups) sddmGroups[g.id] = g.label;
        for (const k of SddmTheme.order) {
            const se = SddmTheme.keys[k];
            out.push({ kind: "login", id: "sddm:" + k, key: k, label: String(se.label || k), area: "Desktop tools",
                       crumbs: "Desktop tools › Login screen window › " + (sddmGroups[se.group] || se.group),
                       path: "", syn: [String(k).toLowerCase()], level: "common" });
        }
        for (let i = 0; i < root.planned.length; i++) {
            const e = root.planned[i];
            out.push({ kind: "planned", id: e.id, label: e.label, crumbs: e.crumbs, path: "",
                       syn: e.syn, reason: e.reason, level: "common" });
        }
        return out;
    }

    /**
     * Puntuación: etiqueta exacta > prefijo > palabra que empieza así > sinónimo >
     * contiene > breadcrumbs > subsecuencia. Varias palabras: todas tienen que casar
     * en algún sitio. 0 = fuera.
     */
    function scoreOf(e, words) {
        const label = e.label.toLowerCase();
        const crumbs = (e.crumbs + (e.area ? " " + e.area : "")).toLowerCase();
        let total = 0;
        for (let w = 0; w < words.length; w++) {
            const q = words[w];
            let best = 0;
            if (label === q) best = 100;
            else if (label.startsWith(q)) best = 80;
            else if (label.split(/[\s·-]+/).some(t => t.startsWith(q))) best = 60;
            else if (e.syn.some(x => x === q)) best = 55;
            // un sinónimo de varias palabras («power saver») casa por cualquiera de ellas
            else if (e.syn.some(x => x.startsWith(q) || x.split(/\s+/).some(t => t.startsWith(q)))) best = 45;
            else if (label.indexOf(q) >= 0) best = 40;
            else if (crumbs.split(/[\s›]+/).some(t => t.startsWith(q))) best = 20;
            else if (q.length >= 3 && root.subsequence(label, q)) best = 10;
            if (best === 0) return 0;
            total += best;
        }
        // una página pesa algo menos que su fila homónima; lo previsto, al final de su nivel
        if (e.kind === "page") total -= 5;
        if (e.kind === "planned") total -= 8;
        return total;
    }
    function subsequence(text, q) {
        let i = 0;
        for (let k = 0; k < text.length && i < q.length; k++) if (text[k] === q[i]) i++;
        return i === q.length;
    }

    property string query: ""
    property int searchSel: 0
    readonly property bool searching: root.query.trim().length > 0
    readonly property var results: {
        const q = root.query.trim().toLowerCase();
        if (q.length === 0) return [];
        const words = q.split(/\s+/);
        const scored = [];
        for (let i = 0; i < root.searchIndex.length; i++) {
            const sc = root.scoreOf(root.searchIndex[i], words);
            if (sc > 0) scored.push({ e: root.searchIndex[i], score: sc, order: i });
        }
        scored.sort((a, b) => b.score - a.score || a.order - b.order);
        return scored.slice(0, 40).map(x => x.e);
    }
    onResultsChanged: root.searchSel = 0

    /** Por qué una fila de la página no se puede usar ahora (o ""): su segundo renglón lo dice. */
    function rowReason(r) {
        if (String(r.id).indexOf("sddm") === 0) { const sw = root.sddmReason(r); if (sw.length > 0) return sw; }   // Sumi SDDM
        if (r.styleOnly === "terminal" && Style.name !== "terminal") return "Used with the Terminal style";   // ADR-34
        if (r.rec === true) { const rw = root.recReason(r); if (rw.length > 0) return rw; }      // Grabador 2.0
        // borde y sombra son del satinado: valen si el global o alguna superficie lo usa
        if ((r.id === "materialEdge" && !Style.terminal || r.id === "materialShadow")
            && !Theme.satinInUse) return "Choose Vidrio Satinado first";
        if (r.id === "surfReset" && !root.surfHasOwn) return "Already follows the global material";
        if ((r.kind === "device" || r.kind === "volume" || r.kind === "mute") && root.nodeFor(r.which) === null)
            return r.which === "sink" ? "No output device" : "No input device";
        if (r.kind === "btPower" && !Bt.present) return "Bluetooth adapter unavailable";
        // F2c: aplicar fondos necesita el proveedor; mirar, buscar y configurar siguen
        if ((r.id === "wallRestore" || r.id === "ovRandom" || r.kind === "screenWall") && Wallpaper.applyWhy.length > 0)
            return Wallpaper.applyWhy;
        if (r.kind === "wallEntry" && Wallpaper.whyNot(r.path).length > 0) return Wallpaper.whyNot(r.path);
        if (r.id === "wallRestore" && !root.previousWall) return "Nothing to restore yet";
        if (r.id === "envRefresh" && Capabilities.checking) return "Checking…";
        if (r.id === "desktopRestore" && ThemePreview.desktopChanged === 0) return "Nothing changed by the shell";   // F4d
        if (r.kind === "screenWall" && !Wallpaper.hasOwn(r.screen))
            return Wallpaper.multiScreen ? "Already shows the shared wallpaper" : "Only one screen";
        if (r.id === "exportAll" && Presets.personal.filter(p => !p.broken).length === 0) return "You have no presets of your own";
        if (r.id === "importApply") {
            const a = Portability.analysis;
            if (!a || a.state !== "ready") return "Checking the file…";
            if (!Settings.writable) return "Settings can't be saved right now";
            const n = Portability.changes.length + (Portability.withPresets ? a.presets.valid.length : 0);
            return n === 0 ? "Nothing to import: your settings already match" : "";
        }
        if (r.kind === "presetGroup" || (r.id && r.id.indexOf("preset") === 0 && r.id !== "presetSaveCurrent"
                                         && r.kind !== "presetItem" && r.kind !== "info"))
            return root.presetWhyNot(r);
        if (/^ap[A-Z]/.test(String(r.id))) { const w = root.apWhyNot(r); if (w.length > 0) return w; }       // Apariencia
        if (r.id === "themePreview") return root.themeWhyNot("preview");
        if (r.kind === "themeOpt" || r.kind === "themeHex") {
            if (root.themeSelected === "static") return "Minimaru is a fixed dark palette";
            if (ThemePreview.isPreset(root.themeSelected)) {
                if (r.opt !== "lightness") return "A static palette has fixed colours";
                const o = ThemePreview.normOpts(root.themeSelected).lightness === "light" ? "dark" : "light";
                if (ThemePreview.variantFor(root.themeSelected, o).length === 0) return "This palette has no " + o + " variant";
            }
            if (r.kind === "themeHex" && root.themeSelectedOpts.source === "wallpaper") return "Choose Custom colour first";
        }
        if (r.id === "themeKeep") return root.themeWhyNot("keep");
        if (r.id === "themeRevert") return root.themeWhyNot("revert");
        if (r.id === "themeRegenerate") return root.themeWhyNot("regenerate");
        if (r.id === "rotBattery" && !Battery.present) return "No battery in this computer";
        // 14E
        if (r.kind === "idleChoice") {
            if (!Idle.editable) return Idle.runner && Idle.runner.mode === "none" ? "hypridle isn't running"
                                                                                 : "hypridle isn't a user service here";   // F5f
            if (!Idle.loaded) return Idle.error.length > 0 ? Idle.error : "Reading…";     // F5h: sin archivo, el motivo
            if (!Idle.managed) return "Turn on editing below first";
            if (Idle.busy.length > 0) return "Applying…";
        }
        if ((r.id === "idleOn" || r.id === "idleOff") && Idle.busy.length > 0) return "Working…";
        // F5e
        if (r.kind === "pamTest" && LockPam.pending.length === 0) return "Pick a stack above first";
        if (r.kind === "pamTest" && (LockPam.testState === "probing" || LockPam.testState === "checking")) return "Checking…";
        // 14D
        if (r.kind === "netText" && (r.key === "addresses" || r.key === "gateway") && root.netVal("ipv4Method") !== "manual")
            return "Only for manual IPv4";
        if (r.id === "netApply") {
            if (NetProfiles.saving) return "Saving…";
            if (SystemTest.live || SystemTest.launching) return SystemTest.kind === "network" ? "Testing…" : "Another test is running";
            if (!root.netDirty) return "Nothing changed";
            const e = root.netDraftError();
            if (e.length > 0) return e;
        }
        if (r.id === "netDiscard" && !root.netDirty) return "Nothing changed";
        if ((r.id === "whTest" || r.id === "whRemove") && !WallhavenAccount.hasKeyFile) return "No key saved";
        if (r.kind === "wallDownloadDir" && root.downloadChoices.length === 0 && Wallpaper.sourceInfo.length > 0)
            return "No writable folder in Sources";
        if (r.kind === "profile" && PowerProfile.checked && !PowerProfile.ok) return "power-profiles-daemon is not running";
        return "";
    }

    /** Por qué una fila no se puede usar ahora mismo (o ""): se enseña en el resultado. */
    function reasonOf(e) {
        if (e.kind === "planned") return e.reason;
        if (e.kind !== "row") return "";
        const why = root.rowReason(e.row);
        if (why.length > 0) return why;
        if (e.id === "city" && !Settings.weatherEnabled) return "Turn weather on first";
        return "";
    }

    /** El valor efectivo, corto, para la columna de la derecha. Nunca es un secreto. */
    function valueOf(e) {
        if (e.kind !== "row") return "";
        const r = e.row;
        switch (r.kind) {
        case "toggle": return Settings[r.prop] ? "On" : "Off";
        case "choice": {
            const o = root.optionsOf(r).find(x => String(x.value) === String(Settings[r.prop]));
            return o ? o.label : String(Settings[r.prop]);
        }
        case "apChoice": {                                                   // Apariencia (2026-11-13)
            const o = root.apOptions(r.opt).find(x => String(x.value) === String(root.apValue(r.opt)));
            return o ? o.label : String(root.apValue(r.opt));
        }
        case "taskEvery": {                                                  // F3d-2
            const o = r.options.find(x => x.value === Settings.taskEvery(r.task));
            return o ? o.label : Settings.taskEvery(r.task) + " days";
        }
        case "themeProfile": return ThemePreview.nameOf(root.themeSelected);
        case "themeOpt": {
            const o = root.themeSelectedOpts;
            const v = r.opt === "sourceKind" ? (o.source === "wallpaper" ? "wallpaper" : "custom") : o[r.opt];
            const f = r.options.find(x => String(x.value) === String(v));
            return f ? f.label : String(v);
        }
        case "themeHex": return root.themeSelectedOpts.source !== "wallpaper" ? root.themeSelectedOpts.source : "";
        case "surfPick": return SurfaceMaterials.labelOf(root.matSurface);
        case "surfOpt": {
            const o = root.surfOptions(r.opt).find(x => String(x.value) === String(root.surfValue(r.opt)));
            return o ? o.label : "";
        }
        case "dock": return root.dockOn ? "On" : "Off";
        case "bar": return root.barHere ? "On" : "Off";
        case "barEdge": return BarEdge.edgeLabel(root.barEdgeHere);
        case "barLength": return root.barAtLimit ? "Limit" : root.barLengthHere + " %";
        case "location": return Settings.weatherLocation && Settings.weatherLocation.name ? Settings.weatherLocation.name : "Not set";
        case "path": return Settings[r.prop] && Settings[r.prop].length > 0 ? "Custom" : "Default";
        case "wallSourceAdd": { const n = (Settings.wallpaperSources || []).length; return n + (n === 1 ? " folder" : " folders"); }
        case "wallDownloadDir": return Wallpaper.pretty(Wallpaper.downloadDir);
        case "whKey": return WallhavenAccount.statusText;
        case "whUser": return Settings.wallhavenUser || "Not set";
        case "info": return root.infoOf(r.id);
        case "recText": return root.recFieldNote(r.field);                                     // Grabador 2.0
        case "device": { const n = root.nodeFor(r.which); return n ? Mixer.shortLabel(n) : ""; }
        case "volume": { const n = root.nodeFor(r.which); return n ? Math.round(Mixer.shownVolume(n) * 100) + "%" : ""; }
        case "mute": { const n = root.nodeFor(r.which); return n ? (Mixer.shownMuted(n) ? "Muted" : "Off") : ""; }
        case "btPower": return Bt.powered ? "On" : "Off";
        case "profile": return PowerProfile.shownProfile;
        }
        return "";
    }

    /** Abrir el resultado elegido: la surface, la página y el foco en su control. */
    function openResult(i) {
        const e = root.results[i];
        if (!e || e.kind === "planned") return false;
        if (e.kind === "login") {
            const shown = LoginUi.show(root.screenName, "key:" + e.key, { from: "settings", path: "shell/sddm/sddmOpen" });
            if (shown) root.requestClose();
            return shown;
        }
        return root.openPath(e.path);
    }

    /** Empezar a buscar (desde la cabecera, Tab, o tecleando una letra en la página). */
    function startSearch(text) {
        if (text !== undefined) searchField.text = searchField.text + text;
        root.zone = "search";
        Qt.callLater(searchField.focusField);
    }
    /** Salir de la búsqueda: con `toPage`, el teclado vuelve a la página que se veía. */
    function endSearch(toPage) {
        searchField.clear();
        root.query = "";
        if (root.zone === "search") {
            root.zone = toPage ? "content" : root.zone;
            root.forceActiveFocus();
        }
    }

    // ---- Theme (9D-1): fondos, Recent/Favorites, iconos ----------------------------

    function baseName(p) { return String(p).substring(String(p).lastIndexOf("/") + 1); }
    /**
     * La miniatura de generate-thumbs si el fondo está en la biblioteca; si no, la imagen misma
     * SÓLO cuando ya se comprobó que existe: una `Image` con una ruta que falta deja un aviso en
     * el journal (medido con la entrada de prueba que faltaba).
     */
    function thumbOf(path) {
        const l = Wallpaper.entries;
        for (let i = 0; i < l.length; i++)
            // W4: sólo si la miniatura ya existe (la pide el escaneo: `hasThumb`)
            if (l[i].path === path) return l[i].hasThumb ? "file://" + l[i].thumb : "";
        return !Wallpaper.isVideo(path) && root.exists[path] === true ? "file://" + path : "";
    }
    function ago(ms) { return Clock.ago(ms, "long"); }

    /**
     * Las filas de Recent y Favorites, de `WallpaperMeta`. Id estable por ruta (el foco sigue a
     * la entrada, no al índice: DESIGN §3). No se indexan en la búsqueda: son datos del usuario.
     */
    /** F3d-2: los valores de una frecuencia esperada (los de siempre). */
    readonly property var everyOptions: [{ label: "Off", value: 0 }, { label: "Daily", value: 1 },
                                         { label: "Every 3 days", value: 3 }, { label: "Weekly", value: 7 }]
    /** F3d-2: una fila de frecuencia por tarea con `lastRun` (antes, dotbackup y diskbackup fijos). */
    function taskEveryRows() {
        const ts = Tasks.tasks.filter(t => !!t.lastRun);
        if (ts.length === 0)
            return [{ id: "taskEveryEmpty", prop: "", kind: "info", name: "No backups to watch", value: "",
                      caption: "A task with lastRun in tasks.json gets an expected frequency here" }];
        return ts.map(t => ({ id: "every:" + t.id, prop: "", kind: "taskEvery", task: t.id,
                              name: "Expected " + t.id + " frequency", options: root.everyOptions }));
    }

    function dynRows(which) {
        if (String(which).indexOf("sddm:") === 0) return root.sddmRows(String(which).slice(5));   // Sumi SDDM
        if (String(which).indexOf("env:") === 0) return root.envRows(String(which).slice(4));
        if (which === "taskEvery") return root.taskEveryRows();
        if (which === "presets" || which === "presetSel") return root.presetRows(which);
        if (which === "importPreview") return root.importRows();
        if (which === "screens") {
            const rows = Quickshell.screens.map(sc => ({ id: "screen:" + sc.name, prop: "", kind: "screenWall",
                                                         name: sc.name, screen: sc.name }));
            // una pantalla desconectada conserva su fondo propio para cuando vuelva (rice, 09-23)
            const here = Quickshell.screens.map(sc => sc.name);
            for (const o of Object.keys(Wallpaper.outputs))
                if (here.indexOf(o) < 0)
                    rows.push({ id: "screen:" + o, prop: "", kind: "screenWall", name: o, screen: o, gone: true });
            rows.push({ id: "paletteOrigin", prop: "", kind: "info", name: "Colours come from",
                        value: "", caption: Wallpaper.paletteOrigin.charAt(0).toUpperCase() + Wallpaper.paletteOrigin.substring(1)
                            + (Wallpaper.multiScreen ? " · a screen's own wallpaper never changes them" : "") });
            return rows;
        }
        if (which === "btDevices") {
            const l = Bt.pairedDevices;
            if (!Bt.present) return [{ id: "btNone", prop: "", kind: "info", name: "No Bluetooth adapter" }];
            if (l.length === 0) return [{ id: "btDevicesEmpty", prop: "", kind: "info", name: "No paired devices" }];
            return l.map(d => ({ id: "bt:" + d.address, prop: "", kind: "btDevice", name: Bt.labelOf(d), addr: String(d.address) }));
        }
        if (which === "monitors") {
            // 14A: todas las salidas (también las apagadas), con la regla escrita que les aplica
            if (!HyprConfig.loaded)
                return [{ id: "monitorsEmpty", prop: "", kind: "info", name: HyprConfig.error.length ? "Unavailable" : "Reading…",
                          value: "", caption: HyprConfig.error }];
            // dos filas por salida: qué es y dónde está; y sus modos, VRR, color y la regla que le aplica
            let rows = [];
            for (const x of HyprConfig.monitors) {
                const rule = HyprConfig.ruleFor(x);
                const bits = [];
                if (String(x.currentFormat).indexOf("2101010") >= 0) bits.push("10-bit");
                bits.push(x.vrr ? "VRR on" : "VRR off");
                if (x.transform) bits.push("rotated " + (x.transform % 4) * 90 + "°" + (x.transform >= 4 ? ", flipped" : ""));
                bits.push(!rule ? "Hyprland's default"
                          : (String(rule.fields.output || "") === "" ? "rule for any screen, " : "its own rule, ")
                            + HyprConfig.where(rule.file, rule.line));
                const drift = HyprConfig.monitorDrift(x);
                if (drift.length > 0) bits.push(drift.join(", ") + " changed while running");
                rows.push({ id: "mon:" + x.name, prop: "", kind: "info", name: x.name + (x.disabled ? " · off" : ""),
                            value: x.disabled ? "Disabled" : x.width + "×" + x.height + " @ " + Math.round(x.refreshRate)
                                + " Hz · scale " + (Math.round(x.scale * 100) / 100),
                            caption: [x.make, x.model].filter(v => v && v.length > 0).join(" ")
                                + " · at " + x.x + "," + x.y + (x.focused ? " · focused" : "") });
                rows.push({ id: "monRule:" + x.name, prop: "", kind: "info", name: "Modes and rule",
                            value: (x.availableModes || []).length + " modes", caption: bits.join(" · ") });
            }
            return rows;
        }
        if (which === "keyboards") {
            const k = HyprConfig.keyboards;
            if (k.length === 0) return [{ id: "keyboardsEmpty", prop: "", kind: "info", name: HyprConfig.loaded ? "No keyboard" : "Reading…" }];
            // hyprctl cuenta como teclado el bus de vídeo, los botones y hasta el ratón: el principal
            // con su distribución, y el resto sólo contado
            const main = k.filter(x => x.main);
            const rows = main.map(x => ({ id: "kb:" + x.name, prop: "", kind: "info", name: x.name,
                                          value: x.active_keymap || "", caption: "Main keyboard · the layout in use · "
                                              + (x.layout || "") + (x.options ? " · " + x.options : "") }));
            const others = k.length - main.length;
            if (others > 0)
                rows.push({ id: "kbOthers", prop: "", kind: "info", name: "Other key devices",
                            value: String(others), caption: "Buttons, receivers and virtual devices" });
            return rows;
        }
        if (which === "hyprDevices") {
            // Por dispositivo: SÓLO lo escrito (Hyprland no deja leerlo). Se enseña, no se edita.
            if (!HyprConfig.loaded) return [{ id: "devEmpty", prop: "", kind: "info", name: "Reading…" }];
            const b = HyprConfig.deviceBlocks();
            if (b.length === 0) return [{ id: "devEmpty", prop: "", kind: "info", name: "No per-device settings",
                                          value: "", caption: "Every device uses the values above" }];
            return b.map(d => ({ id: "dev:" + d.name, prop: "", kind: "info", name: d.name,
                                 value: d.present ? "Connected" : "Device unavailable",
                                 caption: d.values.map(v => v.key + " " + HyprConfig.format(null, v.value)).join(" · ")
                                     + " · set in " + HyprConfig.where(d.file, d.line)
                                     + " · can't be read back" }));
        }
        if (which === "netProfiles") {
            if (!NetProfiles.loaded)
                return [{ id: "netProfilesEmpty", prop: "", kind: "info",
                          name: NetProfiles.error.length ? "Unavailable" : "Reading…", value: "", caption: NetProfiles.error }];
            if (NetProfiles.profiles.length === 0)
                return [{ id: "netProfilesEmpty", prop: "", kind: "info", name: "No saved networks" }];
            return NetProfiles.profiles.map(p => ({ id: "np:" + p.uuid, prop: "", kind: "netItem", name: p.name, uuid: p.uuid,
                                                    caption: (p.active ? "In use · " + p.devices.join(", ") + " · " : "")
                                                        + NetProfiles.kindName(p.type) + " · " + NetProfiles.describe(p) }));
        }
        if (which === "netSel") return root.netRows();
        if (which === "idleEdit") return root.idleEditRows();
        if (which === "sources") {
            const l = Settings.wallpaperSources || [];
            if (l.length === 0)
                return [{ id: "sourcesEmpty", prop: "", kind: "info", name: "No folders",
                          value: "", caption: "The library is empty · add a folder below" }];
            const rows = l.map(p => ({ id: "src:" + Wallpaper.expand(p), prop: "", kind: "wallSource",
                                       name: Wallpaper.pretty(Wallpaper.expand(p)), dir: Wallpaper.expand(p) }));
            if (Wallpaper.collisions.length > 0)
                rows.push({ id: "srcCollisions", prop: "", kind: "info", name: "Repeated file names",
                            value: String(Wallpaper.collisions.length),
                            caption: "They share one thumbnail: " + Wallpaper.collisions.slice(0, 3).join(", ")
                                     + (Wallpaper.collisions.length > 3 ? "…" : "") });
            return rows;
        }
        const list = which === "recent" ? WallpaperMeta.recent : WallpaperMeta.favorites;
        if (list.length === 0)
            return [{ id: which + "Empty", prop: "", kind: "info", name: which === "recent" ? "Nothing yet" : "No favorites" }];
        return list.map(e => ({ id: which + ":" + e.path, prop: "", kind: "wallEntry", list: which,
                                name: root.baseName(e.path), path: e.path, at: e.at }));
    }

    // ---- portabilidad F2b: Environment -----------------------------------------------

    /**
     * Una fila por capacidad del grupo. Disponible: el valor lo dice y el pie nombra al proveedor;
     * si no, el pie es el motivo. Lo forzado por IPC lo avisa con lo detectado al lado.
     * Notificaciones vive en Shell → General: aquí sólo su enlace.
     */
    function envRows(group) {
        const caps = Capabilities.inGroup(group).filter(c => c.id !== "desktop.notifications");
        if (caps.length === 0)
            return [{ id: "env:" + group + "Empty", prop: "", kind: "info",
                      name: Capabilities.checking || Capabilities.helper === "idle" ? "Checking…" : "Not checked",
                      value: "", caption: Capabilities.helperText }];
        const rows = caps.map(c => ({ id: "env:" + c.id, prop: "", kind: "info", name: Capabilities.label(c.id),
                                value: Capabilities.stateText(c.state),
                                tone: c.state === "unavailable" ? "bad" : c.state === "available" ? "" : "warn",
                                // forzado: su motivo ES «Forced over IPC»; se dice una vez, con lo detectado
                                caption: c.forced ? "Forced over IPC · detected " + (c.detected || "nothing")
                                    : (c.state === "available" ? c.provider : (c.reason || c.provider)) }));
        // F3b/F3c: desde las capacidades de Apps, a los ajustes que las cambian (enlaces, no otra copia)
        if (group === "apps") {
            rows.push({ id: "env:appsTerminalGoto", prop: "", kind: "goto", name: "Choose the terminal",
                        path: "shell/apps/terminal" });
            rows.push({ id: "env:appsBrowserGoto", prop: "", kind: "goto", name: "Choose the browser",
                        path: "shell/apps/browser" });
        }
        return rows;
    }
    readonly property string envStatusText: Capabilities.checking ? "Checking…"
        : Capabilities.checkedAt > 0 ? "At " + Clock.fmt(Capabilities.checkedAt)
        : "Not checked"
    readonly property string envStatusCaption: {
        const n = Capabilities.summary().counts;
        const bits = [];
        if (Capabilities.report)
            bits.push(n.available + " available" + (n.degraded ? " · " + n.degraded + " limited" : "")
                      + (n.unavailable ? " · " + n.unavailable + " unavailable" : "")
                      + (n.unknown ? " · " + n.unknown + " unknown" : ""));
        if (Capabilities.source === "cache") bits.push("from the last session");
        if (Capabilities.helperText.length > 0 && !Capabilities.checking) bits.push(Capabilities.helperText);
        if (Capabilities.overrides && Object.keys(Capabilities.overrides).length > 0)
            bits.push(Object.keys(Capabilities.overrides).length + " forced over IPC");
        return bits.join(" · ");
    }

    // ---- 12D: presets ---------------------------------------------------------------

    /** El preset seleccionado en la página (id) y los grupos que el usuario QUITÓ de él. */
    property string presetSel: ""
    property var presetOff: ({})
    onPresetSelChanged: root.presetOff = ({})
    readonly property var presetSelected: { void Presets.personal; return Presets.byId(root.presetSel); }
    function presetGroupsChosen() {
        const p = root.presetSelected;
        return p ? Presets.groupsOf(p).filter(g => !root.presetOff[g]) : [];
    }
    readonly property var presetDiff: Presets.diff(root.presetSelected)
    // ---- 14D: editar un perfil de red ----------------------------------------------------------
    //
    // Un BORRADOR sobre el perfil elegido: los controles lo cambian, Save / Test and apply lo manda
    // (NetProfiles decide el camino: directo con Undo, o prueba con checkpoint y cuenta regresiva).
    // Se descarta al elegir otro perfil o con Discard; se vacía cuando el cambio quedó guardado.
    property string netSel: ""
    property var netDraft: ({})
    readonly property var netSelected: { void NetProfiles.profiles; return NetProfiles.byUuid(root.netSel); }
    onNetSelChanged: root.netDraft = ({})
    function netOf(p, k) {
        if (!p) return undefined;
        const v4 = p.ipv4 || {};
        return k === "autoconnect" ? p.autoconnect : k === "priority" ? p.priority : k === "metered" ? p.metered
            : k === "ipv4Method" ? v4.method : k === "addresses" ? (v4.addresses || [])
            : k === "gateway" ? (v4.gateway || "") : k === "dns" ? (v4.dns || [])
            : k === "ignoreAutoDns" ? !!v4.ignoreAutoDns : undefined;
    }
    function netVal(k) { return root.netDraft[k] !== undefined ? root.netDraft[k] : root.netOf(root.netSelected, k); }
    function netSame(a, b) { return JSON.stringify(a) === JSON.stringify(b); }
    function netSet(k, v) {
        const d = Object.assign({}, root.netDraft);
        if (root.netSame(v, root.netOf(root.netSelected, k))) delete d[k]; else d[k] = v;
        // automático: sin direcciones ni gateway fijos (el ayudante los vaciaría igual)
        if (k === "ipv4Method" && v === "auto") { delete d.addresses; delete d.gateway; }
        root.netDraft = d;
    }
    readonly property bool netDirty: Object.keys(root.netDraft).length > 0
    readonly property bool netNeedsTest: NetProfiles.needsTest(root.netSelected, root.netDraft)
    readonly property var netIpRe: /^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}$/
    /** Lo que ya se ve mal en el borrador (el ayudante valida de verdad; esto avisa antes). */
    function netDraftError() {
        const d = root.netDraft;
        for (const a of d.addresses || []) {
            const m = /^(.+)\/(\d{1,2})$/.exec(a);
            if (!m || !root.netIpRe.test(m[1]) || +m[2] < 8 || +m[2] > 32)
                return a + " is not an address with a prefix (192.168.1.20/24)";
        }
        for (const x of d.dns || []) if (!root.netIpRe.test(x)) return x + " is not an IPv4 address";
        if ((d.dns || []).length > 3) return "Up to three DNS servers";
        if (d.gateway && !root.netIpRe.test(d.gateway)) return d.gateway + " is not an IPv4 address";
        if (root.netVal("ipv4Method") === "manual" && root.netVal("addresses").length === 0) return "Manual IPv4 needs an address";
        if (root.netVal("ignoreAutoDns") && root.netVal("dns").length === 0) return "Add a DNS server first";
        return "";
    }
    /** Texto de un campo → valor: listas separadas por comas o espacios; «none» vacía. */
    function netParse(k, text) {
        const t = text.trim();
        if (/^(none|clear|-)$/i.test(t)) return k === "gateway" ? "" : [];
        return k === "gateway" ? t : t.split(/[\s,]+/).filter(x => x.length > 0);
    }
    function netShown(k) {
        const v = root.netVal(k);
        return Array.isArray(v) ? (v.length ? v.join(", ") : "None") : (v && String(v).length ? String(v) : "None");
    }
    // lo guardado quedó: el borrador sobra (si falló o se revirtió, se conserva para reintentar)
    Connections {
        target: NetProfiles
        function onLastSaveChanged() {
            const l = NetProfiles.lastSave;
            if (l && l.ok && l.uuid === root.netSel && !l.undone) root.netDraft = ({});
        }
    }
    Connections {
        target: SystemTest
        function onFinished(state, reason, screen) {
            const l = SystemTest.last;
            if (state === "kept" && l && l.kind === "network" && l.proposal && l.proposal.uuid === root.netSel)
                root.netDraft = ({});
        }
    }
    readonly property var netPriorities: [{ label: "Lowest", value: -999 }, { label: "Low", value: -10 },
                                          { label: "Normal", value: 0 }, { label: "High", value: 10 },
                                          { label: "Highest", value: 100 }]
    function netRows() {
        const p = root.netSelected;
        if (!p) return [{ id: "netNone", prop: "", kind: "info", name: "Choose a network above",
                          caption: "Then change how it connects, its DNS or its IPv4 address" }];
        if (!p.editable)
            return [{ id: "netNoEdit", prop: "", kind: "info", name: p.name,
                      caption: NetProfiles.kindName(p.type) + " connections can't be edited here" }];
        const ch = k => root.netDraft[k] !== undefined ? "Changed · not applied yet" : "";
        const pr = root.netVal("priority");
        const prOpts = root.netPriorities.some(o => o.value === pr) ? root.netPriorities
            : root.netPriorities.concat([{ label: String(pr), value: pr }]).sort((a, b) => a.value - b.value);
        const rows = [
            { id: "netAuto", prop: "", kind: "netToggle", key: "autoconnect", name: "Connect automatically",
              caption: ch("autoconnect") || "When it's in range or plugged in" },
            { id: "netPriority", prop: "", kind: "netChoice", key: "priority", name: "Priority", options: prOpts,
              caption: ch("priority") || "Which network wins when several are available" },
            { id: "netMetered", prop: "", kind: "netChoice", key: "metered", name: "Metered",
              options: [{ label: "Automatic", value: "auto" }, { label: "Yes", value: "yes" }, { label: "No", value: "no" }],
              caption: ch("metered") || "Apps can save data on a metered connection" }
        ];
        const m = root.netOf(p, "ipv4Method");
        if (m === "auto" || m === "manual") {
            rows.push({ id: "netMethod", prop: "", kind: "netChoice", key: "ipv4Method", name: "IPv4",
                        options: [{ label: "Automatic", value: "auto" }, { label: "Manual", value: "manual" }],
                        caption: ch("ipv4Method") || (root.netVal("ipv4Method") === "auto" ? "The router gives the address (DHCP)"
                                                                                           : "A fixed address you choose") });
            rows.push({ id: "netAddresses", prop: "", kind: "netText", key: "addresses", name: "Address",
                        placeholder: "192.168.1.20/24", caption: ch("addresses") || "With its prefix, like /24 · several with commas" });
            rows.push({ id: "netGateway", prop: "", kind: "netText", key: "gateway", name: "Gateway",
                        placeholder: "192.168.1.1", caption: ch("gateway") || "Usually your router · type none for no gateway" });
        } else {
            rows.push({ id: "netMethodOther", prop: "", kind: "info", name: "IPv4", value: m || "—",
                        caption: "This IPv4 mode can't be edited here" });
        }
        rows.push({ id: "netDns", prop: "", kind: "netText", key: "dns", name: "DNS servers", placeholder: "1.1.1.1, 9.9.9.9",
                    caption: ch("dns") || "Up to three · type none to use only the automatic ones" });
        rows.push({ id: "netDnsOnly", prop: "", kind: "netToggle", key: "ignoreAutoDns", name: "Use only these DNS servers",
                    caption: ch("ignoreAutoDns") || "Ignore the ones the router gives" });
        rows.push({ id: "netApply", prop: "", kind: "action", label: root.netNeedsTest ? "Test and apply" : "Save",
                    name: root.netNeedsTest ? "Test the changes" : "Save the changes",
                    caption: root.netNeedsTest
                        ? "Applies for 15 s, then reverts unless you keep it · asks for your password"
                        : p.active ? "Saves now · applies the next time it connects · you can undo it" : "Saves now · you can undo it" });
        rows.push({ id: "netDiscard", prop: "", kind: "action", label: "Discard", name: "Discard the changes",
                    caption: root.netDirty ? Object.keys(root.netDraft).length + " not applied" : "" });
        const l = NetProfiles.lastSave;
        if (l && l.ok && l.uuid === p.uuid && l.undo && !l.undone)
            rows.push({ id: "netUndo", prop: "", kind: "action", label: "Undo", name: "Undo the last change",
                        caption: "Back to how it was before: " + l.detail });
        const t = SystemTest.last;
        const tm = t && t.kind === "network" && t.proposal && t.proposal.uuid === p.uuid ? t : null;
        const sm = l && l.uuid === p.uuid ? l : null;
        if (SystemTest.live && SystemTest.kind === "network")
            rows.push({ id: "netResult", prop: "", kind: "info", name: "Last change",
                        value: SystemTest.state === "authorizing" ? "Waiting for your password" : "Testing…",
                        caption: SystemTest.detail });
        else if (tm && (!sm || (tm.updated || 0) > (sm.at || 0)))
            rows.push({ id: "netResult", prop: "", kind: "info", name: "Last change",
                        value: tm.state === "kept" ? "Kept" : tm.state === "reverted" ? "Reverted" : "Not applied",
                        caption: (tm.reason || "") + ((tm.remained || []).length ? " · still different: " + tm.remained.join("; ") : "") });
        else if (sm)
            rows.push({ id: "netResult", prop: "", kind: "info", name: "Last change",
                        value: sm.ok ? (sm.undone ? "Undone" : "Saved") : "Not saved", caption: NetProfiles.saveText(sm) });
        return rows;
    }

    // ---- 14E: los plazos de hypridle ---------------------------------------------------------
    readonly property var idleLockOptions: [{ label: "Never", value: 0 }, { label: "1 min", value: 60 }, { label: "2 min", value: 120 },
        { label: "3 min", value: 180 }, { label: "5 min", value: 300 }, { label: "10 min", value: 600 },
        { label: "15 min", value: 900 }, { label: "30 min", value: 1800 }, { label: "1 h", value: 3600 }]
    readonly property var idleOffOptions: [{ label: "Never", value: 0 }, { label: "1 min", value: 60 }, { label: "2 min", value: 120 },
        { label: "5 min", value: 300 }, { label: "10 min", value: 600 }, { label: "15 min", value: 900 },
        { label: "20 min", value: 1200 }, { label: "30 min", value: 1800 }, { label: "1 h", value: 3600 },
        { label: "2 h", value: 7200 }]
    /** Las opciones, con el valor actual si no está entre ellas (un plazo escrito a mano). */
    function idleOptions(key) {
        const base = key === "lock" ? root.idleLockOptions : root.idleOffOptions;
        const v = Idle.shown(key);
        return base.some(o => o.value === v) ? base
            : base.concat([{ label: Idle.minutes(v), value: v }]).sort((a, b) => a.value - b.value);
    }
    property bool idleArmed: false
    Timer { id: idleDisarm; interval: 5000; onTriggered: root.idleArmed = false }
    function idleEditRows() {
        const c = Idle.cfg;
        // F5f (H-23): sin un servicio de usuario que reiniciar, sólo lectura con el motivo (antes fallaba al aplicar);
        // F5h: también sin hypridle.conf (el motivo de hypridle primero; el del archivo detrás)
        if (!Idle.editable && Idle.runner)
            return [{ id: "idleRunner", prop: "", kind: "info", name: "Can't apply the times here",
                      caption: Idle.notEditable + (c.error ? " · " + c.error : "") }];
        if (!c.state) return [{ id: "idleEditWait", prop: "", kind: "info", name: c.error ? "Unavailable" : "Reading…",
                                caption: c.error || "" }];
        const rows = [];
        if (c.state === "off")
            rows.push({ id: "idleOn", prop: "", kind: "action", label: "Edit here", name: "Edit the idle times here",
                        caption: root.idleArmed
                            ? "Press again · moves the lock and screen-off timers to " + c.managedFile.replace(/^.*\//, "") + " (backup kept) · restarts hypridle"
                            : "hypridle.conf keeps everything else · you can give them back later" });
        else if (c.state === "on")
            rows.push({ id: "idleOff", prop: "", kind: "action", label: "Give back", name: "Stop editing them here",
                        caption: root.idleArmed ? "Press again · puts them back in hypridle.conf · hypridle restarts"
                                                : "Settings writes them to " + c.managedFile + " · included by " + c.config.main });
        else
            rows.push({ id: "idleForeign", prop: "", kind: "info", name: "Can't edit here",
                        caption: c.state === "foreign" ? c.managedFile + " exists and Settings did not write it"
                                                       : "hypridle.conf includes a file that isn't Settings' · check it by hand" });
        const r = Idle.result;
        if (r && r.ok && r.undo && !r.undone && Idle.busy.length === 0)
            rows.push({ id: "idleUndo", prop: "", kind: "action", label: "Undo", name: "Undo the last change",
                        caption: "Back to lock " + Idle.minutes(r.undo.lock).toLowerCase() + ", screen off " + Idle.minutes(r.undo.screenOff).toLowerCase() });
        if (Idle.busy.length > 0 || Idle.pending)
            rows.push({ id: "idleResult", prop: "", kind: "info", name: "Last change",
                        value: Idle.busy.length > 0 ? "Applying…" : "Waiting", caption: "hypridle restarts once it's done" });
        else if (r)
            rows.push({ id: "idleResult", prop: "", kind: "info", name: "Last change",
                        value: r.ok ? (r.undone ? "Undone" : "Done") : "Not applied", caption: Idle.resultText(r) });
        return rows;
    }

    property bool presetDeleteArmed: false
    Timer { id: presetDisarm; interval: 4000; onTriggered: root.presetDeleteArmed = false }

    // ---- 12E: importar ------------------------------------------------------------------

    /** El nombre de producto de un ajuste (la fila que lo muestra), o su id. */
    function nameOfSetting(id) {
        const e = Schema.entryById(id);
        if (!e) return id;
        // las listas de carpetas se editan con filas de acción: su nombre es el de la sección
        const own = { wallpaperSources: "Sources", wallpaperDownloadDir: "Download folder" };
        if (own[e.prop]) return own[e.prop];
        for (const d of root.tree)
            for (const pg of d.pages)
                for (const sc of pg.sections)
                    for (const r of sc.rows)
                        if (r.prop === e.prop) return r.name;
        return id;
    }
    function importRows() {
        const a = Portability.analysis;
        const li = Portability.lastImport;
        if (!a) {
            if (li && !li.undone)
                return [{ id: "importDone", prop: "", kind: "info", name: "Imported",
                          caption: li.changes + (li.changes === 1 ? " setting" : " settings") + ", " + li.presets
                              + (li.presets === 1 ? " preset" : " presets") + " · previous settings saved in "
                              + li.backup.split("/").pop() },
                        { id: "importUndo", prop: "", kind: "action", name: "Undo import", label: "Undo" }];
            return [{ id: "importNone", prop: "", kind: "info", name: "Nothing to review",
                      caption: li && li.undone ? "The last import was undone" : "Choose a file above; nothing is applied until you press Import" }];
        }
        if (a.state === "reading" || a.state === "checking")
            return [{ id: "importBusy", prop: "", kind: "info", name: "Checking the file…", caption: a.path }];
        if (a.state === "error")
            return [{ id: "importError", prop: "", kind: "info", name: a.error, caption: a.path },
                    { id: "importDiscard", prop: "", kind: "action", name: "Discard", label: "Discard" }];
        const rows = [];
        const ch = Portability.changes;
        rows.push({ id: "importSummary", prop: "", kind: "info",
                    name: ch.length + (ch.length === 1 ? " change" : " changes")
                        + (a.newer ? " · from a newer version of the shell" : ""),
                    caption: a.path });
        // por sección, en el orden del catálogo
        const secs = [];
        for (const c of ch) if (secs.indexOf(c.section) < 0) secs.push(c.section);
        // 2026-11-24: las secciones del esquema son claves internas (Reset las usa tal cual); aquí sólo se nombran con
        // la nomenclatura pública de las presentaciones (Dynamic Capsule, Edge, Bar-Edge)
        const secNames = { "Island": "Capsule & Edge", "Notch": "Edge shape", "NotchActivities": "Edge live activities" };
        for (const sname of secs)
            rows.push({ id: "importSec:" + sname, prop: "", kind: "info", name: secNames[sname] || sname,
                        caption: ch.filter(c => c.section === sname)
                            .map(c => root.nameOfSetting(c.id) + " " + c.from + " → " + c.to).join(" · ") });
        if (a.missing.length > 0)
            rows.push({ id: "importMissing", prop: "", kind: "info", name: "Missing on this machine",
                        caption: a.missing.map(m => root.nameOfSetting(m.id) + ": " + m.paths.join(", ")).join(" · ")
                            + " · the rest still imports" });
        // con el nombre de la fila y el motivo; lo desconocido, tal cual (no hay nombre que darle)
        const skipped = a.unknown.map(x => x + " (unknown)")
            .concat(a.notImportable.map(x => root.nameOfSetting(x) + " (not importable)"))
            .concat(a.invalid.map(x => root.nameOfSetting(x.id) + " (" + x.error + ")"));
        if (skipped.length > 0)
            rows.push({ id: "importSkipped", prop: "", kind: "info", name: "Not applied",
                        caption: skipped.join(" · ") });
        if (a.presets.valid.length + a.presets.invalid.length > 0)
            rows.push({ id: "importPresets", prop: "", kind: "importPresets", name: "Import its presets" });
        rows.push({ id: "importMode", prop: "", kind: "importMode", name: "How" });
        rows.push({ id: "importApply", prop: "", kind: "action", name: "Import", label: "Import" });
        rows.push({ id: "importDiscard", prop: "", kind: "action", name: "Discard", label: "Discard" });
        return rows;
    }

    function presetRows(which) {
        if (which === "presets") {
            const rows = [{ id: "presetStatus", prop: "", kind: "info", name: Presets.statusText(),
                            caption: Presets.error.length > 0 ? Presets.error : "Appearance, layout and motion of the shell" }];
            for (const p of Presets.all())
                rows.push({ id: "preset:" + p.id, prop: "", kind: "presetItem", name: p.name, presetId: p.id });
            // el servicio se crea al abrir la página: hasta que lea el disco, los tuyos aún no están
            if (!Presets.loaded)
                rows.push({ id: "presetLoading", prop: "", kind: "info", name: "Reading your presets…" });
            return rows;
        }
        const p = root.presetSelected;
        if (!p) return [{ id: "presetNone", prop: "", kind: "info", name: "Choose a preset above" }];
        const rows = [];
        for (const g of Presets.groups)
            rows.push({ id: "presetGroup:" + g, prop: "", kind: "presetGroup", group: g, name: Presets.groupNames[g] });
        rows.push({ id: "presetApply", prop: "", kind: "action", name: "Apply " + p.name, label: "Apply" });
        rows.push({ id: "presetDuplicate", prop: "", kind: "action", name: "Duplicate", label: "Duplicate" });
        if (p.builtin) {
            rows.push({ id: "presetBuiltin", prop: "", kind: "info", name: "Built-in preset",
                        caption: "Built-in presets can't be changed · duplicate it to make your own" });
        } else {
            rows.push({ id: "presetUpdate", prop: "", kind: "action", name: "Update from current settings", label: "Update" });
            rows.push({ id: "presetRename", prop: "", kind: "presetRename", name: "Rename" });
            rows.push({ id: "presetRestore", prop: "", kind: "action", name: "Restore previous version", label: "Restore" });
            rows.push({ id: "presetDelete", prop: "", kind: "action", name: "Delete", label: "Delete" });
        }
        return rows;
    }
    function presetWhyNot(r) {
        const p = root.presetSelected;
        if (r.kind === "presetGroup")
            return p && Presets.groupsOf(p).indexOf(r.group) < 0 ? "Not in this preset" : "";
        if (!p) return "";
        if (p.broken && r.id !== "presetDelete" && r.id !== "presetRestore") return "This preset file is invalid";
        if (r.id === "presetApply") {
            const gs = root.presetGroupsChosen();
            if (gs.length === 0) return "Choose at least one group";
            if (!Settings.writable) return "Settings can't be saved right now";
            let n = 0;
            for (const g of gs) n += root.presetDiff[g].length;
            return n === 0 ? "Nothing to change: your settings already match" : "";
        }
        if (r.id === "presetRestore" && (Presets.backupCount[p.id] || 0) === 0) return "No previous version";
        return "";
    }
    function presetCaption(r) {
        const p = r.kind === "presetItem" ? Presets.byId(r.presetId) : root.presetSelected;
        if (!p) return "";
        if (r.kind === "presetItem") {
            if (p.broken) return "Invalid file · " + p.broken;
            const gs = Presets.groupsOf(p).map(g => Presets.groupNames[g]).join(", ");
            return (p.builtin ? (p.note + " · ") : "Yours · ") + (gs.length > 0 ? gs : "empty");
        }
        if (r.kind === "presetGroup") {
            if (Presets.groupsOf(p).indexOf(r.group) < 0) return "Not in this preset";
            const d = root.presetDiff[r.group];
            if (d.length === 0) return "Already matches";
            return d.map(x => x.label + " " + x.from + " → " + x.to).join(" · ");
        }
        if (r.id === "presetApply") {
            let n = 0;
            for (const g of root.presetGroupsChosen()) n += root.presetDiff[g].length;
            return n + (n === 1 ? " change" : " changes") + " · only the groups turned on";
        }
        if (r.id === "presetDuplicate") return "Make an editable copy in your presets";
        if (r.id === "presetUpdate") return "Store your current values in its groups · the old version is kept";
        if (r.id === "presetRestore") return (Presets.backupCount[p.id] || 0) + " saved versions";
        if (r.id === "presetDelete") return root.presetDeleteArmed ? "Press again to delete " + p.name : "The file is kept in backups";
        return "";
    }

    /** 10E-1a: «Remove the key» armado (la segunda pulsación en 4 s la borra). */
    property bool whRemoveArmed: false
    Timer { id: whRemoveDisarm; interval: 4000; onTriggered: root.whRemoveArmed = false }
    /** Una clave escrita y sin guardar es un secreto sin enviar: la guarda del host pregunta. */
    guardReason: root.pathFields.whKey && root.pathFields.whKey.editing && root.pathFields.whKey.hasText
        ? "An unsaved API key"
        : root.pathFields.pamTest && root.pathFields.pamTest.editing && root.pathFields.pamTest.hasText ? "An unsent password" : ""
    function discardGuarded() {
        if (root.pathFields.whKey) root.pathFields.whKey.discard();
        if (root.pathFields.pamTest) root.pathFields.pamTest.discard();
    }
    function focusGuarded() {
        if (root.pathFields.pamTest && root.pathFields.pamTest.editing) root.pathFields.pamTest.startEdit();
        else if (root.pathFields.whKey) root.pathFields.whKey.startEdit();
    }

    /** 10B: el fondo al que volvería Restore previous (o null). */
    readonly property var previousWall: { void WallpaperMeta.recent; return WallpaperMeta.previous(Wallpaper.current); }

    /** 10A: carpetas de Sources que pueden recibir descargas (existen y se pueden escribir). */
    readonly property var downloadChoices: {
        const out = [];
        const l = Settings.wallpaperSources || [];
        for (let i = 0; i < l.length; i++) {
            const info = Wallpaper.infoOf(Wallpaper.expand(l[i]));
            if (info && info.status === "ok" && info.writable)
                out.push({ label: Wallpaper.pretty(Wallpaper.expand(l[i])), value: l[i] });
        }
        return out;
    }

    /** ¿Existe cada ruta de Recent/Favorites? Se mira al enseñar la página, no en reposo. */
    property var exists: ({})
    readonly property var metaPaths: {
        const out = [];
        const add = (l) => { for (let i = 0; i < l.length; i++) if (out.indexOf(l[i].path) < 0) out.push(l[i].path); };
        add(WallpaperMeta.recent); add(WallpaperMeta.favorites);
        return out;
    }
    function checkExists() {
        if (root.shownKey !== "theme/wallpaper" || root.metaPaths.length === 0 || existsProc.running) return;
        existsProc.paths = root.metaPaths.slice();
        existsProc.command = ["sh", "-c", 'for p in "$@"; do [ -e "$p" ] && echo 1 || echo 0; done', "_"].concat(existsProc.paths);
        existsProc.running = true;
    }
    onMetaPathsChanged: root.checkExists()
    Process {
        id: existsProc
        property var paths: []
        stdout: StdioCollector {
            onStreamFinished: {
                const bits = this.text.split("\n");
                const m = {};
                for (let i = 0; i < existsProc.paths.length; i++) m[existsProc.paths[i]] = bits[i] !== "0";
                root.exists = m;
            }
        }
    }
    function missing(path) { return root.exists[path] === false; }

    // ---- Apariencia: iconos y cursor (2026-11-13) -----------------------------------------------------------------

    readonly property var apSizes: [16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 96]
    function apOptions(opt) {
        const sc = Appearance.scan;
        if (opt === "family") return Appearance.familyNames.map(f => ({ label: f, value: f }));
        if (opt === "variant") return Appearance.draftVariants.map(n => {
            const i = Appearance.iconInfo(n);
            return { label: i ? i.variant : n, value: n };
        });
        if (opt === "cursor") return sc ? sc.cursors.map(c => ({ label: c.name, value: c.name })) : [];
        if (opt === "size") return root.apSizes.map(v => ({ label: String(v), value: v }));
        return [];
    }
    function apValue(opt) {
        if (opt === "family") return Appearance.draftFamily;
        if (opt === "variant") return Appearance.draft.icons;
        if (opt === "cursor") return Appearance.draft.cursor;
        if (opt === "size") return Appearance.draft.size;
        return "";
    }
    function apPick(opt, v) {
        if (opt === "family") Appearance.pickFamily(v);
        else if (opt === "variant") Appearance.setDraft("icons", v);
        else if (opt === "cursor") Appearance.setDraft("cursor", v);
        else if (opt === "size") Appearance.setDraft("size", v);
    }
    /** «2 to change» o «Up to date»: el resumen del plan del borrador. */
    readonly property string apTargetsValue: {
        const p = Appearance.plan;
        if (!p) return Appearance.overview ? "Checking…" : "";
        if (p.ok !== true) return "Can't apply";
        return p.changes > 0 ? p.changes + (p.changes === 1 ? " to change" : " to change") : "Up to date";
    }
    /** Una línea por app que cambia (o por qué no): lo que dice el plan antes de escribir nada. */
    readonly property string apTargetsCaption: {
        const p = Appearance.plan;
        if (!p) return "";
        if (p.ok !== true) return Object.keys(p.errors || {}).map(k => p.errors[k]).join(" · ");
        const parts = [];
        for (const x of p.slots || []) {
            if (x.action === "change") parts.push(x.label + ": " + (x.current === null || x.current === undefined ? "unset" : x.current)
                                                  + " → " + x.proposed + (x.restart === "reopen" ? " (when reopened)" : ""));
            else if (x.action === "unavailable" || x.action === "blocked") parts.push(x.label + ": not available · " + (x.reason || ""));
        }
        return parts.length ? parts.join("\n") : "Every app already uses this";
    }
    /** Lo que usa cada app, agrupado: deja ver a simple vista cuando no coinciden. */
    function apInUse(what) {
        const t = Appearance.targets;
        if (!Appearance.overview) return Appearance.error || "Reading…";
        const groups = {};
        const add = (v, who) => { if (v === null || v === undefined || v === "") return; const k = String(v); (groups[k] = groups[k] || []).push(who); };
        const short = { "gtk": "GTK 3", "gtk4": "GTK 4", "gtk3": "GTK 3 X11", "qt6": "Qt 6", "qt5": "Qt 5", "hyprland": "Hyprland" };
        for (const slot in t) {
            const x = t[slot];
            if (x.what !== what || x.state !== "available") continue;
            const who = short[slot.split(".")[0]] || slot;
            if (what === "cursor") {
                const sz = slot === "hyprland.cursor" ? x.size : (t[slot.split(".")[0] + ".cursorSize"] || {}).value;
                add(x.value + (sz ? " " + sz : ""), who);
            } else add(x.value, who);
        }
        const x = Appearance.desktop ? Appearance.desktop.xsettings : null;
        if (x) add(what === "icons" ? x["Net/IconThemeName"] : x["Gtk/CursorThemeName"], "XSettings (not managed)");
        const keys = Object.keys(groups);
        const managed = (Appearance.status ? Appearance.status.managed : []).some(m => m.slot.indexOf(what === "icons" ? ".icons" : ".cursor") > 0);
        const head = keys.length > 1 ? "Not the same everywhere · " : managed ? "Applied by the shell · " : "Set outside the shell · ";
        return head + keys.map(k => k + ": " + groups[k].join(", ")).join(" · ");
    }
    /**
     * Apply rápido de Icons y de Cursor (2026-11-14): un solo borrador, así que cualquiera de los dos aplica todo.
     * Primero lo de su pestaña y, si la otra también cambió, se dice. Si falló el último Apply, su resultado.
     */
    function apApplyCaption(own) {
        if (Appearance.lastBad && Appearance.lastLine.length) return Appearance.lastLine;
        const d = Appearance.draft;
        const icons = d.icons !== (Settings.iconTheme || Appearance.effectiveIcons);
        const cursor = d.cursor !== (Settings.cursorTheme || Appearance.effectiveCursor)
            || d.size !== (Settings.cursorSize || Appearance.effectiveSize);
        const iconPart = "Icons → " + (d.icons || "—");
        const cursorPart = "Cursor → " + (d.cursor || "—") + (d.size ? " " + d.size + " px" : "");
        const parts = own === "icons" ? [icons ? iconPart : "", cursor ? cursorPart + " too" : ""]
                                      : [cursor ? cursorPart : "", icons ? iconPart + " too" : ""];
        const what = parts.filter(s => s.length).join(" · ");
        const n = Appearance.changes;
        const many = n + (n === 1 ? " app setting changes" : " app settings change") + " · details in Changes";
        const head = what.length ? what + (n > 0 ? " · " + many : "")
                                 : n > 0 ? many : "Saves it as your choice · the apps already use this";
        return head + "\nGTK 3, Qt and Hyprland at once · GTK 4 apps when reopened · XWayland apps after a new login";
    }
    function apWhyNot(r) {
        if (!Appearance.overview) return Appearance.error.length ? Appearance.error : "Reading…";
        const busy = Appearance.busy;
        switch (r.id) {
        case "apIconVariant": return Appearance.draftVariants.length > 1 ? "" : "This theme has one variant";
        case "apIconFollow": return Appearance.counterpart(Appearance.draft.icons, Appearance.mode === "dark" ? "light" : "dark").length
            || Settings.iconFollowMode ? "" : "This theme has no light/dark pair";
        case "apApplyIcons": case "apApplyCursor": {
            if (busy === "apply") return "Applying…";
            if (busy.length) return "Working…";
            if (Appearance.interrupted) return "A change was cut halfway: finish it in Changes first";
            if (!Appearance.fresh) return "Checking…";
            if (Appearance.plan.ok !== true) return Object.keys(Appearance.plan.errors || {}).map(k => Appearance.plan.errors[k]).join(" · ");
            if (!Settings.writable) return "Settings can't be saved right now";
            if (Appearance.canApply) return "";
            // recién aplicado: el resultado se queda a la vista hasta el siguiente cambio del borrador
            // (en corto: la lista por app ocupaba tres renglones; el detalle sigue en Changes → What changes/In use)
            const l = Appearance.last;
            if (l === null || Appearance.lastBad || !Appearance.lastLine.length) return "Nothing to change";
            if (l.prefsOnly || !l.results) return Appearance.lastLine;
            const ok = l.results.filter(x => x.result === "applied").length;
            const kept = l.results.filter(x => x.result === "conflict").length;
            return ok ? "Applied · " + ok + " app " + (ok === 1 ? "setting" : "settings") + (kept ? " · " + kept + " left as you changed them" : "")
                        + " · undo it in Changes" : Appearance.lastLine;
        }
        case "apUndo": case "apUndoAll": return busy.length ? "Working…" : Appearance.canUndo ? "" : "Nothing applied by the shell";
        case "apRecover": return Appearance.interrupted ? "" : "Nothing was interrupted";
        }
        return "";
    }
    function apCaption(id) {
        const d = Appearance.draft;
        switch (id) {
        case "apIconFamily": {
            const i = Appearance.iconInfo(d.icons);
            if (!i) return d.icons ? d.icons + " isn't installed" : "Only app icons change · the shell's own icons keep their look";
            return (i.where === "user" ? "Yours" : "System") + (i.inherits.length ? " · missing icons come from " + i.inherits.join(", ") : "")
                + (i.duplicates.length ? " · also in " + i.duplicates.join(", ") + " (this copy wins)" : "")
                + " · the shell's own icons keep their look";
        }
        case "apIconVariant": return Appearance.draftVariants.length > 1 ? "Folder name " + d.icons : "This theme has one variant";
        case "apIconFollow": {
            const other = Appearance.counterpart(d.icons, Appearance.mode === "dark" ? "light" : "dark");
            return other ? "When you keep a " + (Appearance.mode === "dark" ? "light" : "dark") + " colour mode, " + other + " is applied"
                         : "This theme has no light/dark pair";
        }
        case "apIconPreview": {
            const pv = Appearance.draftIconPreview;
            const miss = pv.filter(x => !x.path).length;
            return "Real icons of " + (d.icons || "—") + " (inherited ones included) · nothing is applied"
                + (miss ? " · " + miss + " not in this theme: shown empty" : "");
        }
        case "apIconGlyphs": {
            const pv = Appearance.draftGlyphPreview;
            const miss = pv.filter(x => !x.path).length;
            return "24 px icons on dark and light · where light/dark variants differ"
                + (miss ? " · " + miss + " not in this theme: shown empty" : "");
        }
        case "apCursor": {
            const c = Appearance.cursorInfo(d.cursor);
            if (!c) return d.cursor ? d.cursor + " isn't installed" : "";
            return (c.xcursor && c.hyprcursor ? "XCursor and hyprcursor" : c.hyprcursor ? "hyprcursor only" : "XCursor only")
                + (c.where === "user" ? " · yours" : " · system");
        }
        case "apCursorSize": {
            const c = Appearance.cursorInfo(d.cursor);
            return c && c.sizes.length ? "Drawn at " + c.sizes.join(", ") + " px · other sizes are scaled" : "";
        }
        case "apCursorPreview": return "Pointer, link, text, busy and move · at " + Appearance.previewSize + " px";
        case "apTargets": return root.apTargetsCaption;
        case "apApplyIcons": return root.apApplyCaption("icons");
        case "apApplyCursor": return root.apApplyCaption("cursor");
        case "apUndo": return "Back to what each app had before the last Apply";
        case "apUndoAll": return "Each app back to its previous setting · later changes are kept";
        case "apRecover": return "Settles a change that was cut halfway (nothing is written blindly)";
        case "apGtkTheme": {
            const dd = Appearance.desktop;
            return "The look of GTK widgets, not their icons · " + (dd && dd.gtkThemes.length ? "installed: " + dd.gtkThemes.join(", ") : "")
                + " · light/dark follows Colors · libadwaita apps ignore it";
        }
        case "apQtStyle": return "The look of Qt widgets (not icons or colours) · change it in qt6ct";
        case "apXsettings": return "Read by GTK apps running through XWayland · not managed by the shell";
        }
        return "";
    }

    // ---- System (9D-2) --------------------------------------------------------------

    /** El nodo por defecto de salida o de entrada (el MISMO que usa el Mixer). */
    function nodeFor(which) { return which === "sink" ? Mixer.defaultSink : Mixer.defaultSource; }
    function nodesFor(which) { return which === "sink" ? Mixer.sinks : Mixer.sources; }
    /** Mientras se ve System → Audio el Mixer sigue los nodos (volúmenes, verificación de ops). */
    Claim {
        target: Mixer
        key: root.screenName.length > 0 ? "settings@" + root.screenName : ""
        value: root.open && root.shownKey === "system/audio"
    }

    /**
     * 14A: lo que leen las páginas de System, SÓLO mientras se ven (§1 «coste bajo en reposo»):
     * Displays, Input y Hyprland → HyprConfig; Power → Idle; Network → NetProfiles; Shell → General
     * (Integrations) → Integrations.
     */
    readonly property string claimKey: root.screenName.length > 0 ? "settings@" + root.screenName : ""
    Claim {
        target: HyprConfig
        key: root.claimKey
        value: root.open && ["system/displays", "system/input", "system/hyprland"].indexOf(root.shownKey) >= 0
    }
    Claim { target: Idle; key: root.claimKey; value: root.open && root.shownKey === "system/power" }
    Claim { target: NetProfiles; key: root.claimKey; value: root.open && root.shownKey === "system/network" }
    Claim { target: Integrations; key: root.claimKey; value: root.open && root.shownKey === "shell/general" }
    // Apariencia (2026-11-13): con la página a la vista, el borrador y la vigilancia barata de temas instalados
    Claim { target: Appearance; key: root.claimKey; value: root.open && root.shownKey === "theme/icons" }

    /** Lo que una página necesita leer al enseñarse (y sólo entonces: §1 «coste bajo en reposo»). */
    // interferencia de terminal (2026-11-15): al cambiar de pestaña; la página, en el manejador de abajo
    onActiveTabChanged: Style.interfere(root)
    onShownKeyChanged: {
        Style.interfere(root);                         // interferencia de terminal al cambiar de página (2026-11-15)
        if (root.shownKey !== "shell/recording") root.showBitrate = false;
        if (root.shownKey === "theme/wallpaper" || root.shownKey === "theme/overview") {
            Wallpaper.scan();
            root.checkExists();
        }
        if (root.shownKey === "system/power") PowerProfile.refresh();
    }

    readonly property var swatches: [
        { name: "Primary", color: Colors.primary, on: Colors.fgOnPrimary },
        // colors.json no trae on_secondary / on_tertiary / on_error (la plantilla del shell no los
        // genera): estos acentos se usan SOBRE la superficie, y ésa es su pareja (el contraste es simétrico)
        { name: "Secondary", color: Colors.secondaryRole, on: Colors.surface },
        { name: "Tertiary", color: Colors.tertiary, on: Colors.surface },
        { name: "Error", color: Colors.errorColor, on: Colors.surface },
        { name: "Surface", color: Colors.surface, on: Colors.fg },
        { name: "Container", color: Colors.surfaceContainer, on: Colors.fg },
        { name: "Text", color: Colors.fg, on: Colors.surface },
        { name: "Outline", color: Colors.outline, on: Colors.surface }
    ]
    readonly property string paletteText: !Colors.dynamicEnabled ? "Static · Minimaru"
        : "Dynamic · " + Colors.schemeShort + " · from the wallpaper"

    /** El valor de una fila informativa. Las dinámicas lo traen puesto (`value`). */
    /** La versión de la shell: la misma fuente que el IPC `api` (version.json), leída una vez al cargar. */
    FileView {
        id: shellVersionFile
        path: Quickshell.shellPath("version.json")
        blockLoading: true
        printErrors: false
    }
    readonly property var shellVersion: {
        try {
            const d = JSON.parse(shellVersionFile.text());
            return d && typeof d === "object" ? d : ({});
        } catch (e) {
            return ({});
        }
    }

    function infoValue(r) {
        if (String(r.id).indexOf("sddm") === 0) return root.sddmInfo(r.id);                       // Sumi SDDM
        return r.value !== undefined ? r.value : root.infoOf(r.id);
    }
    function infoOf(id) {
        if (id === "batteryStatus") return Battery.description;
        // 14A: las filas del catálogo de System (id «hypr:<clave de getoption>»)
        if (String(id).indexOf("hypr:") === 0) return HyprConfig.text(String(id).slice(5));
        if (/^rec[A-Z]/.test(String(id))) return root.recInfo(id);                             // Grabador 2.0
        switch (id) {
        case "surfEffective": return root.surfSummary(root.matSurface);
        case "surfCustom": {
            const n = SurfaceMaterials.customized(Settings.surfaceMaterials).length;
            return n === 0 ? "None" : n + (n === 1 ? " surface" : " surfaces");
        }
        case "pamInfo": return LockPam.label();                              // F5e
        case "lockHandler": {                                                // F5d
            const L = LockEntry.listener, eff = LockEntry.effective;
            if (eff === "direct") return "Sumi Shell (direct)";
            return ({ shell: "hypridle → Sumi Shell", hyprlock: "hypridle → hyprlock",
                      other: LockEntry.cap ? LockEntry.cap.provider : "Another program",
                      none: "Nobody", unknown: "Not checked yet" })[L] || L;
        }
        case "tasksFile": {                                                  // F3d-2
            if (Tasks.status === "ready") return Tasks.tasks.length + (Tasks.tasks.length === 1 ? " task" : " tasks");
            return ({ none: "Not set up", ignored: "Ignored", invalid: "Invalid", unreadable: "Unreadable",
                      loading: "Checking…" })[Tasks.status] || Tasks.status;
        }
        case "appsNow": {
            const p = Mixer.playback.length, c = Mixer.capture.length;
            return p + (p === 1 ? " playing" : " playing") + " · " + c + " recording";
        }
        case "libImages": return Wallpaper.filtered("images").length + " installed";
        case "videoPause": return "Paused in Gaming and Cinema and behind fullscreen";
        case "rotStatus": return WallpaperRotation.statusText;
        case "whAccount": return WallhavenAccount.accountText() || "—";
        case "themeTargets": return ThemePreview.targets.apps.length > 0
            ? ThemePreview.targets.apps.map(a => a.replace(/ /g, "\u00a0")).join(", ") : "—";   // «Qt 5» no se parte
        case "libVideos": return Wallpaper.filtered("videos").length + " installed";
        case "netNow": if (Net.unavailableWhy.length > 0) return Net.unavailableWhy;
            return Net.kind === "wired" ? "Ethernet" : Net.kind === "wifi" ? "Wi-Fi · " + Net.ssid : "Not connected";
        case "netCheck": return Net.connectivity;
        case "wiredNow": return Net.wiredDev === null ? "No adapter"
                : Net.wiredUp ? Net.wiredName + (Net.linkSpeed > 0 ? " · " + Net.linkSpeed + " Mb/s" : "")
                : Net.wiredLink ? "Cable in, not connected" : "Unplugged";
        case "wifiNow": return !Net.wifiHardware ? "Blocked by hardware" : !Net.wifiEnabled ? "Off"
                : Net.wifiUp ? Net.ssid + " · " + Net.signal + "%" : "On · not connected";
        case "hyprVer": return HyprConfig.version.tag || HyprConfig.version.version || (HyprConfig.active && !HyprConfig.loaded ? "Reading…" : "");
        case "hyprConfig": return !HyprConfig.config.main ? "" : HyprConfig.config.kind === "missing" ? "Not found"
                : HyprConfig.mainName + (HyprConfig.unsupported ? "" : " · " + (HyprConfig.data.files || []).length + " files");
        case "displaysEdit": case "inputEdit": case "hyprEdit": return "Read only";
        case "prefDisplay": return Settings.preferredDisplay.length > 0 ? Settings.preferredDisplay : "Automatic";
        case "netRollback": return NetProfiles.rollbackText || (NetProfiles.active && !NetProfiles.loaded ? "Reading…" : "");
        case "idleLock": return !Idle.loaded ? (Idle.active ? "Reading…" : "") : Idle.lock ? Idle.minutes(Idle.lock.timeout) : "Never";
        case "idleScreen": return !Idle.loaded ? "" : Idle.screenOff ? Idle.minutes(Idle.screenOff.timeout) : "Never";
        case "idleSuspend": return !Idle.loaded ? "" : Idle.suspend ? Idle.minutes(Idle.suspend.timeout) : "Never";
        case "idleState": return Idle.pausedBy.length > 0 ? "Paused by " + Idle.pausedBy
                : Idle.service === "active" ? (Idle.runner && Idle.runner.mode === "process" ? "hypridle · running (not a service)" : "hypridle · running")
                : Idle.service.length ? "hypridle · " + Idle.service : "";
        case "envStatus": return root.envStatusText;
        case "stScreens": return Quickshell.screens.length + (Quickshell.screens.length === 1 ? " screen" : " screens")
                + " · " + Hyprland.monitors.values.length + " in Hyprland";
        case "stFocused": return Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "—";
        case "stPalette": return Colors.source || "—";
        case "stWallpapers": return Wallpaper.count + " · " + Wallpaper.bag.length + " left in the rotation bag";
        case "stResumes": return String(Session.resumeCount);
        case "stSettings": return Settings.configPath + (Settings.status === "ready" ? "" : " · " + Settings.status);
        case "shellVersion": return root.shellVersion.version || "unknown";
        case "shellApi": return root.shellVersion.apiVersion ? "API " + root.shellVersion.apiVersion + " · settings schema "
                + root.shellVersion.settingsSchema : "";
        case "os": return SystemInfo.os;
        case "kernel": return SystemInfo.kernel;
        case "wm": return SystemInfo.wm;
        case "cpu": return SystemInfo.cpu;
        case "gpu": return SystemInfo.gpu;
        case "mem": return SystemInfo.memory;
        case "srcImages": return "~/Pictures/Wallpapers · " + Wallpaper.filtered("images").length;
        case "srcVideos": return "~/Videos/Wallpapers · " + Wallpaper.filtered("videos").length;
        case "family": return Typography.uiChosen;
        case "fontSync": return FontSync.summary;
        case "variants": return Typography.icons + " · " + Typography.iconReport.state;
        case "iconTheme": return Appearance.effectiveIcons;                  // Apariencia (2026-11-13)
        case "cursorTheme": return Appearance.effectiveCursor ? Appearance.effectiveCursor + " · " + Appearance.effectiveSize + " px" : "";
        case "iconsInstalled": return Appearance.scan ? Appearance.scan.icons.map(i => i.name).join(" · ") : "";
        case "cursorsInstalled": return Appearance.scan ? Appearance.scan.cursors.map(c => c.name).join(" · ") : "";
        case "apTargets": return root.apTargetsValue;
        case "apGtkTheme": return Appearance.desktop ? (Appearance.desktop.gtkTheme || "") : "";
        case "apQtStyle": {
            const d = Appearance.desktop;
            if (!d) return "";
            const q = d.qtPlatformTheme === "qt5ct" ? d.qt5ct : d.qt6ct;
            return d.qtPlatformTheme ? d.qtPlatformTheme + (q && q.style ? " · " + q.style : "") : "Qt's own";
        }
        case "apXsettings": {
            const x = Appearance.desktop ? Appearance.desktop.xsettings : null;
            return x ? [x["Net/ThemeName"], x["Net/IconThemeName"], x["Gtk/CursorThemeName"]].filter(v => v).join(" · ") : "Not configured";
        }
        case "notifServer": return Settings.notificationServer ? (Notifs.enabled ? "Shell" : "Shell · after restart") : "Off";
        case "focusInfo": return "Separate";
        case "displays": {
            const l = Quickshell.screens;
            const out = [];
            // píxeles reales: `width` de Quickshell es lógico (dividido por la escala)
            for (let i = 0; i < l.length; i++) {
                const r = l[i].devicePixelRatio || 1;
                out.push(l[i].name + " " + Math.round(l[i].width * r) + "×" + Math.round(l[i].height * r));
            }
            return out.join(" · ");
        }
        }
        return "";
    }

    /** El segundo renglón: lo que el ajuste hace, o su estado real cuando lo hay. */
    /**
     * F3b: las opciones de una fila `choice`. Las de siempre vienen en la tabla; la de la terminal se
     * construye con lo detectado: Auto (y qué eligió), las terminales de la lista instaladas y la
     * elegida aunque falte (para no perderla al recorrer con ←/→).
     */
    function optionsOf(r) {
        if (r.dynamic === "wallProvider") return root.wallProviderOptions();
        if (String(r.dynamic || "").indexOf("rec") === 0) return root.recOptions(r.dynamic);   // Grabador 2.0
        if (r.kind === "pamChoice") {                                        // F5e: Auto (login) + las que existen aquí
            const out = [{ label: "Auto (login)", value: "auto" }];
            for (const n of LockPam.candidates) out.push({ label: n, value: n });
            if (LockPam.setting !== "auto" && LockPam.candidates.indexOf(LockPam.setting) < 0)
                out.push({ label: LockPam.setting, value: LockPam.setting });
            return out;
        }
        if (r.dynamic !== "terminal" && r.dynamic !== "browser") return r.options;
        const term = r.dynamic === "terminal";
        const cap = term ? Apps.terminalCap : (Capabilities.caps["apps.browser"] || null);
        const cur = term ? Settings.appTerminal : Settings.appBrowser;
        const label = (b) => term ? Apps.labelOf(b) : Web.labelOf(b);
        const found = cap && cap.detail && Array.isArray(cap.detail.found) ? cap.detail.found : [];
        const auto = cur === "auto" && cap && cap.state === "available";
        const shown = term ? Apps.terminalName : Web.labelOf(Web.browser);
        const out = [{ label: auto ? "Auto (" + shown + ")" : "Auto", value: "auto" }];
        for (const n of found) out.push({ label: label(n), value: n });
        if (cur !== "auto" && found.indexOf(cur) < 0)
            out.push({ label: label(cur) + (cap && cap.state === "unavailable" ? " (missing)" : ""), value: cur });
        return out;
    }
    /**
     * F4b: las opciones del proveedor de fondos. Auto lleva entre paréntesis lo que detectó; un backend que
     * no está instalado se enseña igual (elegido a mano dice por qué no va), y Script sólo dice «providers.json».
     */
    function wallProviderOptions() {
        const cap = Capabilities.caps["wallpaper.apply"] || null;
        const auto = Settings.providerWallpaper === "auto" && cap && cap.state === "available" && cap.provider
            ? "Auto (" + cap.provider + ")" : "Auto";
        return [{ label: auto, value: "auto" }, { label: "awww", value: "awww" }, { label: "hyprpaper", value: "hyprpaper" },
                { label: "Script (providers.json)", value: "script" }, { label: "Off", value: "none" }];
    }
    readonly property string wallProviderCaption: {
        const r = Providers.resolve("wallpaper");
        const cap = Capabilities.caps["wallpaper.apply"] || null;
        if (r.mode === "none") return "No wallpapers here: Apply, Random and rotation are off";
        const why = Providers.whyNot("wallpaper", "apply") || (cap && cap.state === "unavailable" ? cap.reason : "");
        if (why.length > 0) return why;
        if (r.mode === "script") return "Wallpapers go through " + r.label + " (providers.json)";
        const d = cap && cap.detail ? cap.detail : {};
        return "Wallpapers go through " + (cap && cap.provider ? cap.provider : "the shell")
            + (d.startsOnApply ? " · started on the next Apply" : "")
            + (d.transitions === false ? " · no transitions" : "");
    }
    /** F4d: de dónde salen los colores. */
    readonly property string themeProviderCaption: {
        const r = Providers.resolve("theme");
        const cap = Capabilities.caps["theme.dynamic"] || null;
        if (r.mode === "builtin" && r.setting === "static") return "The fixed Minimaru palette; nothing follows the wallpaper";
        const why = Providers.whyNot("theme", "reload") || (cap && cap.state !== "available" ? cap.reason : "");
        if (why.length > 0) return why;
        if (r.mode === "script") return "Colours go through " + r.label + " (providers.json)";
        const d = cap && cap.detail ? cap.detail : {};
        return d.ownConfig === false ? "matugen with your config (" + d.config + ")"
            : "matugen, only for the shell's own colours";
    }
    /** F4d: qué toca fuera de la shell, y cuánto ha cambiado. */
    readonly property string desktopSyncCaption: {
        const n = ThemePreview.desktopChanged;
        const base = Settings.themeDesktopSync === "off" ? "Desktop preference sync is off; your Matugen templates still run"
            : Settings.themeDesktopSync === "colorScheme" ? "Follows light/dark with the desktop preference (color-scheme)"
            : "Syncs the desktop preference and Adwaita · custom GTK themes stay";
        return base + (n > 0 ? " · " + n + (n === 1 ? " setting" : " settings") + " changed by the shell" : "")
            + (ThemePreview.desktopWarning ? " · " + ThemePreview.desktopWarning : "");
    }
    readonly property string desktopRestoreCaption: {
        const r = ThemePreview.desktopRestoreResult;
        if (r && (r.unknown || []).length) return "Could not restore: " + r.unknown.join(", ") + " · you can retry";
        if (r && r.ok) {
            const parts = [];
            if ((r.restored || []).length > 0) parts.push("restored " + r.restored.join(", "));
            if ((r.changedByYou || []).length > 0) parts.push("left as you set " + r.changedByYou.join(", "));
            if (parts.length > 0) return parts.join(" · ");
        }
        return "Puts back what the shell changed, unless you changed it since";
    }
    /** F4e: de dónde salen las actualizaciones. */
    readonly property string updatesProviderCaption: {
        const r = Providers.resolve("updates");
        if (r.mode === "none") return "No updates source: the Overview doesn't show it";
        const cap = Capabilities.caps["system.updates"] || null;
        if (cap && cap.state === "unavailable") return cap.reason;
        if (r.mode === "script") return "Checked by " + r.label + " (providers.json)";
        return "Checked every 30 min with " + (cap && cap.provider ? cap.provider : "pacman") + " · the check never changes the system";
    }
    /** F4c: quién hace las miniaturas, o por qué no hay. */
    readonly property string thumbProviderCaption: {
        const r = Providers.resolve("thumbnails");
        const cap = Capabilities.caps["wallpaper.thumbnails"] || null;
        if (r.mode === "none") return "No thumbnails: the strip shows a generic icon";
        const why = Providers.whyNot("thumbnails", "refresh") || (cap && cap.state !== "available" ? cap.reason : "");
        if (why.length > 0) return why;
        if (r.mode === "script") return "Made by " + r.label + " (providers.json)";
        return "Made by the shell with " + (cap && cap.provider ? cap.provider : "ImageMagick");
    }
    readonly property string browserCaption: Web.browserWhy.length > 0 ? Web.browserWhy
        : "The web hub opens pages and searches in " + Web.browser
    readonly property string terminalCaption: Apps.terminalWhy.length > 0 ? Apps.terminalWhy
        : "Terminal apps, Run in terminal, Clean, Update and calcurse open in " + Apps.terminal

    function captionOf(r) {
        if (String(r.id).indexOf("sddm") === 0) return root.sddmCaption(r);                       // Sumi SDDM
        if (r.caption !== undefined) return r.caption;
        if (r.rec === true) return root.recCaption(r);                                          // Grabador 2.0
        if (r.kind === "taskEvery") {                                        // F3d-2 (antes, dotEvery/diskEvery)
            const d = Settings.taskEvery(r.task);
            const at = Issues.ageOf(r.task).at;
            const last = at > 0 ? " · last " + Issues.ago(at) : "";
            return (d > 0 ? "Older is an issue in Overview" : "Off · age only shown") + last;
        }
        if (String(r.id).indexOf("ap") === 0 && /^ap[A-Z]/.test(String(r.id))) return root.apCaption(r.id);   // Apariencia
        if (r.id === "terminal") return root.terminalCaption;      // F3b
        if (r.id === "browser") return root.browserCaption;        // F3c
        if (r.id === "wallProvider") return root.wallProviderCaption;  // F4b
        if (r.id === "thumbProvider") return root.thumbProviderCaption;  // F4c
        if (r.id === "themeProvider") return root.themeProviderCaption;  // F4d
        if (r.id === "desktopSync") return root.desktopSyncCaption;
        if (r.id === "desktopRestore") return root.desktopRestoreCaption;
        if (r.id === "updatesProvider") return root.updatesProviderCaption;  // F4e
        if (String(r.id).indexOf("hypr:") === 0) return HyprConfig.caption(String(r.id).slice(5));
        if (r.kind === "screenWall") {
            const own = Wallpaper.hasOwn(r.screen);
            if (r.gone) return "Disconnected · keeps " + Wallpaper.baseName(Wallpaper.currentFor(r.screen))
                + " for when it comes back";
            return Wallpaper.baseName(Wallpaper.currentFor(r.screen))
                + (own ? " · its own wallpaper" : Wallpaper.multiScreen ? " · shared" : " · the only screen: its wallpaper is everyone's")
                + (Wallpaper.clearState === "failed" && Wallpaper.clearScreen === r.screen ? " · could not switch back" : "");
        }
        if (r.kind === "presetItem" || r.kind === "presetGroup" || (r.id && r.id.indexOf("preset") === 0
                                                                    && r.id !== "presetSaveCurrent" && r.kind !== "info"))
            return root.presetCaption(r);
        if (r.id === "presetSaveCurrent") return "Appearance, layout and motion as they are now";
        if (r.id === "envStatus") return root.envStatusCaption;
        if (r.id === "envRefresh") return "Checks programs, services and files again · starts or changes nothing";
        if (r.id === "exportSettings") return "Your shell preferences · no keys, account, monitors or integrations";
        if (r.id === "lockPreview") return "With your real data, without locking anything · Esc closes";
        if (r.id === "exportAll") return "The same, plus the presets you made";
        if (r.id === "exportResult") {
            const le = Portability.lastExport;
            return !le ? "Nothing exported yet · files go to your home folder"
                : le.ok ? "Saved " + le.path + (le.presets > 0 ? " · " + le.presets + " presets" : "") : le.error;
        }
        if (r.id === "importFile") return "A sumi-settings JSON · it is only read, never run";
        if (r.id === "importApply") {
            const a = Portability.analysis;
            return Portability.error.length > 0 ? Portability.error
                : "A copy of your current settings is saved first" + (Portability.mode === "replace"
                    ? " · Replace resets exportable settings the file doesn't have" : "");
        }
        if (r.id === "importPresets") {
            const a = Portability.analysis;
            return a ? a.presets.valid.length + " valid" + (a.presets.invalid.length > 0
                ? ", " + a.presets.invalid.length + " invalid (skipped)" : "") + " · added next to yours" : "";
        }
        if (r.id === "importMode") return Portability.mode === "merge" ? "Only what the file has" : "What the file has; the rest back to default";
        if (r.id === "importUndo") return "Restore the settings from before this import and remove its presets";
        if (r.id === "glass") return Settings.glassOpacity < 0.94
            ? "Everywhere · text behind panels and UIs can show through below 94%"
            : "Everywhere · how much of the wallpaper panels and UIs let through";
        if (r.id === "material") return "Panels, windows, bar and popups · opacity, palette and motion stay";
        if (r.id === "materialEdge" && Style.terminal)                                   // ADR-34
            return "Also how strong the Terminal frame is · None still draws a faint one";
        if (r.id === "materialEdge" && Settings.material !== "satin" && Theme.satinInUse)
            return "For the surfaces that use Vidrio Satinado";
        if (r.kind === "surfPick" || r.kind === "surfOpt" || String(r.id).indexOf("surf") === 0) return root.surfCaption(r);
        if (r.id === "materialShadow") return "Soft edge separation without blurring the content";
        if (r.kind === "btDevice") {
            const d = Bt.byAddress(r.addr);
            if (!d) return "Gone";
            const b = Bt.batteryOf(d);
            return Bt.stateOf(d) + (b >= 0 ? " · battery " + b + "%" : "");
        }
        if (r.kind === "wallSource") {
            const info = Wallpaper.infoOf(r.dir);
            if (!info) return "Checking…";
            if (info.status !== "ok")
                return info.status === "notdir" ? "Not a folder" : info.status === "unreadable" ? "Can't read this folder"
                    : "Folder not found · its wallpapers are hidden until it's back";
            const parts = [info.images + (info.images === 1 ? " image" : " images"),
                           info.videos + (info.videos === 1 ? " video" : " videos")];
            if (r.dir === Wallpaper.downloadDir) parts.push("downloads go here");
            else if (!info.writable) parts.push("read only");
            return parts.join(" · ");
        }
        if (r.kind === "wallEntry")
            return root.missing(r.path) ? "Missing · the file is gone"
                : (r.list === "recent" ? "Applied " : "Added ") + root.ago(r.at)
                  + (r.list === "recent" && WallpaperMeta.isFavorite(r.path) ? " · favorite" : "");
        switch (r.id) {
        case "scale": return "Size of everything in the shell";
        case "autoHide": return "Retract until the pointer reaches the top edge";
        case "musicCircle": return "Left of the capsule and of Edge · only while something is playing";
        case "netCircle": return "Right of the capsule and of Edge · opens the control center";
        case "islandWheel": return Settings.islandWheel === "off" ? "Scrolling over the capsule or Edge does nothing"
                : "Over the capsule or Edge · 5% per wheel step";
        case "islandMiddle": return Settings.islandMiddleClick === "off" ? "Middle click over the capsule, Edge or Dynamic Bar does nothing"
                : "Over the capsule, Edge or Dynamic Bar · the player the Mixer shows";
        case "reserve": return "Claim the top edge so windows tile below the capsule or Edge";
        case "hoverPreview": return "Resting on an icon previews its panel; a click keeps it open";
        case "osd": return Settings.osdPlacement === "below"
                ? "Always below the open panel"
                : "Beside the open panel · below very wide ones like Wallpaper";
        case "ws": return "Dots always shown · live = only the workspaces in use";
        case "motion":
            return Settings.motionMode === "off" ? "No animation: every change lands at once"
                 : Settings.motionMode === "reduced" ? "Shorter reveals, softer effects and a fade between bar edges"
                 : "Ryūsui: quick to respond, gentle on arrival";
        case "unload": return "How long a closed surface stays built";
        case "thumbs": return "Previews in the minimizer, taken on open (+6 MB)";
        case "video": return "Play the focused video in the strip (+170 MB, 6% of a core)";
        case "videoPause": return "Desktop modes and mpvpaper · a video already playing needs a restart";
        case "openWallpapers": return "Browse and apply wallpapers";
        case "themeProfile": {
            const sel = root.themeSelected, conf = ThemePreview.confirmed;
            const px = ThemePreview.presetOf(sel);
            return (sel === "static" ? "Static palette"
                    : ThemePreview.isPreset(sel) ? "Static palette · " + (px ? px.familyName : "") + ", fixed colours"
                    : "From the wallpaper by matugen")
                + (sel === conf ? " · applied" : " · applied: " + ThemePreview.nameOf(conf))
                + " · choosing only selects";
        }
        case "themePreview": return root.themeStatus;
        case "themeMode": {
            // F-c: con un preset, Mode cambia a la otra variante de su familia
            if (ThemePreview.isPreset(root.themeSelected)) {
                const lt = root.themeSelectedOpts.lightness, other = ThemePreview.variantFor(root.themeSelected, lt === "light" ? "dark" : "light");
                return (lt === "light" ? "The light variant" : "The dark variant")
                    + (other.length > 0 ? " · " + (lt === "light" ? "Dark" : "Light") + " switches to " + ThemePreview.nameOf(other)
                                        : " · this palette has only one");
            }
            return root.themeSelectedOpts.lightness === "light"
                ? "Light wherever matugen reaches, plus GTK apps via the portal" : "Dark surfaces";
        }
        case "themeContrast": return "How far text and outlines stand from their background";
        case "themeSource": return root.themeSelectedOpts.source === "wallpaper"
            ? "The palette follows the wallpaper" : "The palette comes from one colour; wallpapers no longer change it";
        case "themeSourceHex": return "#rrggbb · the seed colour of the palette";
        case "themeKeep": return ThemePreview.previewing.length > 0
            ? "Make " + ThemePreview.nameOf(ThemePreview.previewing) + " the desktop theme" : "Confirm what the preview shows";
        case "themeRevert": return "Back to " + ThemePreview.nameOf(ThemePreview.confirmed);
        case "themeRegenerate":
            return Wallpaper.colorsState === "updating" ? "Updating colours…"
                : Wallpaper.colorsState === "failed" ? "Colours failed · " + Wallpaper.colorsReason
                : "Run matugen again on the current wallpaper";
        case "openProfiles": return "Try the palette schemes on the current wallpaper";
        case "polkit": return Settings.polkitAgent
                ? (Polkit.registered ? "Root prompts appear in the shell" : "On, but another agent holds the session")
                  + (Integrations.polkitOthers.length > 0 ? " · " + Integrations.polkitText : "")
                : (Integrations.polkitOthers.length > 0 ? Integrations.polkitText : "Off") + " · only one agent can run";
        case "weather": return Settings.weatherEnabled
                ? (Weather.state === "unconfigured" ? "On — choose a city below" : "Open-Meteo · shown in Calendar and the lock screen")
                : "Off · nothing is fetched until you turn it on and pick a city";
        case "city": return !Settings.weatherEnabled ? "Turn weather on to search"
                : Weather.state === "stale" ? "Last update " + Weather.ageText() + (Weather.lastError ? " · " + Weather.lastError : "")
                : Weather.state === "unavailable" ? "Weather unavailable · " + Weather.lastError
                : Weather.hasData ? "Updated " + Weather.ageText()
                : "Enter to search by name";
        case "units": return "Weather and system temperatures: Dynamic Bar, Monitor and the lock screen";
        case "dock": return root.barHere
                ? "The Dynamic Bar is on here · it becomes Bar-Edge, joined to the top edge"
                : "Joined to the top edge instead of the floating capsule · only on this monitor";
        case "dockPreview": return "Rest, expanded, OSD and a live activity · a sample, nothing changes";
        case "notchCorners": return Style.name === "terminal" ? "Terminal keeps Edge square"
                : "The two bottom corners · also Bar-Edge";
        case "notchFlare": return Style.name === "terminal" ? "Terminal keeps Edge straight"
                : "How Edge curves into the top edge · also Bar-Edge";
        case "notchColor": return "Black blends with the screen bezel, best on OLED";
        case "notchRest": return Settings.notchRest === "minimal"
                ? "Only the privacy dots at rest · the clock shows on hover"
                : "The clock between the privacy dots";
        case "notchActMusic": return "Album art and waves beside the clock · the Music circle steps aside";
        case "notchViz": return !Cava.probed ? "Real waves from cava while music plays"
                : !Cava.installed ? "cava is not installed · calm synthetic waves instead"
                : Settings.notchVisualizerFps === 0 ? "Calm synthetic waves · no audio capture"
                : "Real waves from cava while music plays · ≈ " + (Settings.notchVisualizerFps >= 60 ? 6
                    : Settings.notchVisualizerFps >= 30 ? 4 : 2) + "% of a core · no privacy warning";
        case "notchActRecording": return "REC and the elapsed time · the controls below keep only the buttons";
        case "notchActSpeed": return "The live speed while a test runs";
        case "notchActWork": return "How many tasks or downloads are running";
        case "notchActPower": return Battery.present ? "A few seconds when the charger is plugged in or out"
                : "No battery on this computer";
        case "notchActCopy": return "A moment after copying or pasting from the emoji picker";
        case "notchActBluetooth": return "Battery of headphones or speakers when they connect";
        case "notchActWorkspace": return "Its number when this monitor changes workspace";
        case "avatar": return "Local path only — empty uses ~/.face, or the initial";
        case "launchScope": return Apps.lastLaunchError || (Settings.appLaunchScope === "direct"
            ? "Direct launch shares the shell's cgroup: restarting it may close apps"
            : "Auto uses a scope if there's a user service manager, otherwise launches directly");
        case "lockEntry": return "Auto goes through logind if something handles it, otherwise locks directly";
        case "pamInfo": return LockPam.faillockText();                      // F5e
        case "pamChoice": return "Choosing one doesn't change anything until it's tested below";
        case "pamTest": return LockPam.testMessage.length > 0 ? LockPam.testMessage
            : "Type your password to test it without locking · a wrong one counts toward lockout";
        case "lockHandler": {                                                // F5d
            const c = LockEntry.cap;
            if (LockEntry.effective === "direct" && LockEntry.setting !== "direct")
                return "Nothing handles lock requests: idle and sleep won't lock without hypridle and the Sumi helper";
            if (c && c.state !== "available" && c.reason) return c.reason;
            return LockEntry.describe;
        }
        case "fetch": return "Local path only — empty uses the sumi logo";
        case "keepAwake": return Settings.keepAwake ? (Session.keepAwakeEffective
            ? "The screen stays on and the session does not lock on idle"
            : (Session.keepAwakeError || "Acquiring the sleep inhibitor…"))
                                                    : "Idle dims, locks and sleeps as usual";
        case "openMonitor": return "CPU, memory, GPU and disks in detail";
        // Medido (9C-1): Reduced escala exacto; en Normal los muelles tienen un tope estable,
        // así que Faster acelera menos ahí. Sin porcentajes que no se cumplan.
        case "themeCard": return root.paletteText;
        case "outDev": case "inDev": {
            const n = root.nodeFor(r.which);
            return n ? (root.nodesFor(r.which).length > 1 ? "←→ to switch · " : "") + Mixer.label(n) : "";
        }
        case "outVol": case "inVol": {
            const n = root.nodeFor(r.which);
            return n ? Math.round(Mixer.shownVolume(n) * 100) + "%" + (Mixer.failedOn(n) ? " · could not apply" : "") : "";
        }
        case "outMute": case "inMute": {
            const n = root.nodeFor(r.which);
            return n ? (Mixer.shownMuted(n) ? "Muted" : "Sound on") : "";
        }
        case "appsNow": return "Streams and their devices live in the Audio mixer";
        case "openMixer": return "Playback, output, input and applications in one view";
        case "openAudioUi": return "Devices, balance, equalizer and apps in detail";
        case "openApps": return "Each app's output or input · in Audio settings";
        case "openEq": {
            // el de la salida predeterminada, con su estado real (services/Equalizer)
            const n = Mixer.defaultSink;
            if (!n) return "No output device";
            const d = String(n.name), st = Equalizer.stateOf(d), v = Equalizer.view(d);
            const what = st.state === "loading" ? "…" : st.state === "failed" ? "Couldn't start"
                : (v.enabled ? "On · " : "Off · ") + Equalizer.presetName(v.preset);
            return Mixer.shortLabel(n) + " · " + what + " · in Audio settings";
        }
        case "netNow": return "The shell prefers the cable when both are up";
        case "netCheck": return "As NetworkManager reports it";
        case "wiredNow": return Net.wiredMac.length > 0 ? Net.wiredMac : "";
        case "wifiNow": return "Scanning only happens in the Wi-Fi view";
        case "openWired": return "Addresses, autoconnect and the connection itself";
        case "openWifi": return "Connect, forget and passwords";
        case "btPower": return !Bt.present ? "" : Bt.powered ? Bt.adapterName + " · " + Bt.connectedCount + " connected" : "Off";
        case "openBt": return "Discovery and pairing live in the Bluetooth view";
        case "btDevicesEmpty": return "Pair one from the Bluetooth view";
        case "profile": return PowerProfile.applying ? "Applying…"
                : PowerProfile.opState === "error" ? "Could not apply · " + PowerProfile.opReason
                : PowerProfile.degradation.length > 0 ? "Degraded · " + PowerProfile.degradation
                : "power-profiles-daemon";
        case "batteryAlerts": return "Only while discharging · turn it off if another power manager already warns";
        case "batteryLow": case "batteryVeryLow": case "batteryCritical": return "Rearmed after recovering 2 percentage points above this threshold";
        case "displaysEdit": return "Set in your Hyprland config · each screen shows its rule and where";
        case "inputEdit": case "hyprEdit": return "Set in your Hyprland config · each row shows the file and line";
        case "hyprConfig": return !HyprConfig.config.main ? HyprConfig.error
                : HyprConfig.tilde(HyprConfig.config.kind === "missing" ? HyprConfig.config.dir : HyprConfig.config.main)
                    + " · " + HyprConfig.foundHow
                    + (HyprConfig.configErrors.length ? " · Hyprland reports " + HyprConfig.configErrors.length
                       + " error" + (HyprConfig.configErrors.length > 1 ? "s" : "") + " in it" : "");
        case "prefDisplay": return "Where the shell opens when no screen has focus (a shell setting)";
        case "netRollback": return NetProfiles.checkpoints.supported
                ? "Risky changes undo themselves unless you keep them" : "";
        case "idleLock": return !Idle.loaded ? Idle.error : Idle.pending ? "Applies when you stop changing it"
                : (Idle.pausedBy.length > 0 ? "Temporarily overridden by " + Idle.pausedBy + " · " : "")
                  + (Idle.lock ? "The shell's lock · set in " + Idle.where(Idle.lock.file) : "Nothing locks the session when idle");
        case "idleScreen": return Idle.pending ? "Applies when you stop changing it" : Idle.orderProblem.length > 0 ? Idle.orderProblem
                : (Idle.pausedBy.length > 0 ? "Temporarily overridden by " + Idle.pausedBy + " · " : "")
                  + (Idle.screenOff ? "After locking · set in " + Idle.where(Idle.screenOff.file) : "The screen stays on");
        case "idleSuspend": return Idle.suspend ? "Set in " + Idle.suspend.file : "Not automatic on this computer";
        case "idleState": return Idle.pausedBy === "Keep awake" ? "Keep awake is on: nothing locks or turns off until you turn it off"
                : Idle.pausedBy.length > 0 ? "The mode holds idle off while it lasts · the timings don't change"
                : Idle.service === "active" ? "No mode or Keep awake is holding it" : "Without it the session never locks by itself";
        case "hyprVer": return "Read from hyprctl";
        case "ovWallpapers": return "Browse and apply wallpapers · Apply there is direct";
        case "ovProfiles": return "Try the palette schemes on the current wallpaper";
        case "ovRandom": return "Apply a random one from the library (it repaints the desktop)";
        case "wallCurrent": {
            // 10B: el apply en curso o fallido, observado, antes que el nombre
            if (Wallpaper.applyState === "applying") return "Applying " + root.baseName(Wallpaper.applyPath) + "…";
            if (Wallpaper.applyState === "failed" && Wallpaper.applyOrigin !== "restore")
                return "Could not apply · " + Wallpaper.applyReason;
            const colours = Wallpaper.colorsState === "updating" ? " · updating colours…"
                : Wallpaper.colorsState === "failed" ? " · colours failed"
                : Wallpaper.colorsState === "unknown" ? " · colours didn't report" : "";
            return Wallpaper.current.length > 0
                ? root.baseName(Wallpaper.current) + (WallpaperMeta.isFavorite(Wallpaper.current) ? " · favorite" : "") + colours
                : "None set";
        }
        case "recentEmpty": return "Wallpapers you apply from now on appear here";
        case "favoritesEmpty": return "Mark the current wallpaper with the star";
        case "libImages": case "libVideos": return "One library for Wallpaper list and this page · one folder level";
        case "wallRestore": {
            if (Wallpaper.applyOrigin === "restore" && Wallpaper.applyState === "applying") return "Restoring…";
            if (Wallpaper.applyOrigin === "restore" && Wallpaper.applyState === "failed") return Wallpaper.applyReason;
            const p = root.previousWall;
            if (!p) return "Wallpapers you apply from now on can be restored";
            return root.baseName(p.path) + " · applied " + root.ago(p.at)
                + (p.scheme ? " · " + p.scheme.replace("scheme-", "") : " · no theme recorded");
        }
        case "rotOn": return "Every screen, through the usual path · repaints colours each time";
        case "rotEvery": return "Counts from the last wallpaper change, whoever made it";
        case "rotFrom": return "The same shuffled bag as Random";
        case "rotFullscreen": return "Any screen with a fullscreen window · videos pause behind one anyway";
        case "rotBattery": return "While discharging";
        case "rotModes": return "Rotation only · video wallpapers pause in those modes on their own";
        case "rotStatus": return "One scheduler, in the shell · off when the shell isn't running";
        case "transition": return "Images only · videos switch without one";
        case "whKey": {
            const a = WallhavenAccount;
            const when = a.checkedAt > 0 ? " · checked " + root.ago(a.checkedAt) : "";
            if (a.status === "configured") return "Configured" + when + " · stored privately, never shown";
            if (a.status === "pending") return "Pending validation" + (a.reason ? " · " + a.reason : "");
            if (a.status === "rejected") return "Rejected · " + (a.reason || "Wallhaven refused it");
            return a.reason && a.reason !== "" ? a.reason : "Not set · SFW search works without one · not stored in settings.json";
        }
        case "whUser": return "Needed for My collections · your Wallhaven username";
        case "whTest": return WallhavenAccount.testing ? "Checking…" : "Asks Wallhaven only when pressed";
        case "whRemove": return root.whRemoveArmed ? "Press Remove again to delete the key" : "Deletes the key file; SFW search keeps working";
        case "whAccount": return "What your Wallhaven account allows · shown next to the filters";
        case "themeTargets": return ThemePreview.targets.origin === "own" ? "Managed by your matugen configuration"
            : ThemePreview.targets.origin === "apps" ? "Set up with install.sh theme-apps · undo it with --revert"
            : "Only the shell · install.sh theme-apps adds kitty, GTK, Qt and Hyprland";
        case "wallSourceAdd": return "Checked before it's added · Del resets to the two default folders";
        case "wallDownloadDir": switch (Wallpaper.downloadDirState) {
            case "notSource": return "Not in Sources any more · choose another before the next download";
            case "notWritable": return "This folder is read only · choose another";
            case "missing": return "Folder not found · choose another";
            default: return "Wallhaven downloads are saved here, never applied";
        }
        case "swatches": return "Name, hex and text contrast · amber below 4.5:1";
        // la elegida, no la que se ve: con Terminal y «Monospace interface text», `ui` es la de código (ADR-34)
        case "family": return "UI: " + Typography.uiChosen + " · Code: " + Typography.mono
                + (Typography.ui !== Typography.uiChosen ? " · Terminal shows Code everywhere" : "");
        case "fontSync": return "GTK 3/4, Qt 5/6, kitty and VSCodium · each off until you turn it on";
        case "textSize": return "Text only · Interface scale in Shell grows everything";
        case "variants": return "Independent icon font · coverage checked against Icon.qml";
        case "iconTheme": return root.apInUse("icons");                       // Apariencia (2026-11-13)
        case "cursorTheme": return root.apInUse("cursor");
        case "iconsInstalled": case "cursorsInstalled": return "In " + (Appearance.scan ? Appearance.scan.dirs.map(d => {
                const h = Quickshell.env("HOME") || "";
                return h.length > 0 && d.indexOf(h + "/") === 0 ? "~" + d.slice(h.length) : d;
            }).join(", ") : "your icon folders")
            + " · updated when you install or remove one";
        case "tasksFile": {                                                  // F3d-2
            if (Tasks.reason.length > 0) return Tasks.reason;
            const bad = Tasks.errors.length > 0 ? " · " + Tasks.errors.length + " ignored (see the shell log)" : "";
            const h = Quickshell.env("HOME") || "";
            return (h.length > 0 && Tasks.path.indexOf(h + "/") === 0 ? "~" + Tasks.path.slice(h.length) : Tasks.path) + bad;
        }
        case "firstDay": return Settings.calendarFirstDay === "locale"
                ? "From your locale · now " + (Qt.locale().firstDayOfWeek === 0 ? "Sunday" : "Monday")
                : "Weeks in Calendar start on " + (Settings.calendarFirstDay === "monday" ? "Monday" : "Sunday");
        case "clock": return "Capsule, Edge, Dynamic Bar, Calendar and the lock screen · now " + Clock.time;
        case "popupSec": return "Low priority: a second longer · critical: until dismissed";
        case "notifPos": {
            const names = { "top-left": "Top left", "top-right": "Top right", "bottom-left": "Bottom left",
                            "bottom-center": "Bottom center", "bottom-right": "Bottom right" };
            return (names[Settings.notifPosition] || "Bottom right")
                + (Settings.notifPosition.startsWith("top") ? " · below the Dynamic Bar, capsule or Edge" : "") + " · on the focused screen";
        }
        case "notifMargin": return Settings.notifMargin + " px from the screen edges";
        // 2026-11-19: la barra en cualquier borde (lib/bar-edge.js)
        case "barEdge": return BarEdge.edgeLabel(root.barEdgeHere) + " · panels open "
            + BarEdge.opensTowards(root.barEdgeHere) + (root.barHere ? "" : " · turn on Dynamic Bar to use it");
        // centrada; el mínimo lo pone su contenido (core/Bar `minLen`)
        case "barLength": return root.barAtLimit ? "At its limit · " + root.barLengthPx + " px, centered"
            : root.barLengthHere + " % of the edge · " + root.barLengthPx + " px, centered";
        case "barReset": return "Top · 100 %";
        case "dnd": return NotifHistory.dnd ? "On · popups are silenced (critical ones still show)" : "Off · toggle it in the notification center";
        case "osdMs": return "How long volume and brightness stay on screen";
        case "osdValue": return Settings.osdShowValue ? "The percentage next to the bar" : "Only the bar · muted still reads “off”";
        case "mediaBackdrop": return Settings.mediaBackdrop === "cover"
                ? "The album art, blurred and dimmed, behind the player" : "The panel colour behind the player";
        case "mediaCoverShape": return Settings.mediaCoverShape === "disc"
                ? "A round record with a centre hole" : "The album art as it comes";
        case "mediaEndTime": return Settings.mediaEndTime === "remaining"
                ? "Counts down to the end · click the time in the player to switch" : "The length of the track · click the time in the player to switch";
        case "scrollbar": return "Which side of the app list the scroll indicator sits on";
        case "emojiAction": return Settings.emojiAction === "paste"
                ? "Copies and pastes into your last window · Shift+Enter only copies"
                : "Copies · Shift+Enter also pastes into your last window";
        case "interfaceStyle": return Style.name === "terminal"                         // ADR-34
                ? "Square frames and text-mode controls · nothing else changes"
                : "The shape of panels and controls · nothing else changes";
        case "termFrame": return Settings.termFrame === "double" ? "Two lines around every panel"
                : Settings.termFrame === "segmented" ? "A dashed line around every panel" : "One line around every panel";
        case "termDecor": return Settings.termDecor === "full" ? "Corner brackets and edge ticks on panels"
                : Settings.termDecor === "minimal" ? "Corner brackets on panels" : "Only the frame";
        case "fxGlitch": return Settings.fxGlitch === "off" ? "Off · pages slide in · on, a burst of static replaces the slide"
                : Settings.motionMode !== "normal" ? "Paused · needs Normal motion (now " + Settings.motionMode + ")"
                : "Brief static when a window opens or changes page · replaces the slide";
        case "fxScanlines": return "Faint horizontal lines behind the content · never over the text";
        case "fxGlow": return "The panel shadow takes the accent colour";
        case "termMono": return Typography.uiChosen === Typography.mono
                ? "Your interface font is already monospace (" + Typography.mono + ")"
                : Settings.termMono ? "Uses your code font (" + Typography.mono + ") for the interface"
                : "Keeps your interface font (" + Typography.uiChosen + ")";
        case "barPanels": return Settings.motionMode === "off" ? "Paused · motion is Off"
                : "How panels open from the Dynamic Bar and go back into it";
        case "islandStyle": return Settings.motionMode === "off" ? "Paused · motion is Off"
                : "How the capsule and Edge open a panel and close it";
        case "windowStyle": return Settings.motionMode === "off" ? "Paused · motion is Off"
                : "How floating windows and notification popups open, close and change section";
        case "speed": return Settings.motionSpeed > 1 ? "Quicker transitions · waits and confirmations never change"
                : Settings.motionSpeed < 1 ? "Slower transitions · waits and confirmations never change"
                : "The base Ryūsui tempo · waits and confirmations never change";
        case "focusInfo": return "Hover only highlights; focus moves with keys or a click";
        case "shortcutsHelp": {
            // su propia tecla si la shell la conoce (la efectiva, nunca la de por defecto)
            const k = Keybinds.keyText("keybinds");
            return "What each shell shortcut opens, and its key in Hyprland" + (k.length > 0 ? " · " + k : " · read only");
        }
        case "notifServer": return (Integrations.loaded ? "Owner: " + Integrations.notifOwner + " · " : "")
                + "no other server is installed · notif-server shell|off restarts the shell";
        case "bar": {
            // la tecla de verdad si se conoce (ayuda de atajos); antes, «Super+Ctrl+P» fijo aunque fuera otra
            const k = Keybinds.keyText("barToggle");
            return "A bar along the " + root.barEdgeHere + " edge instead of the capsule" + (root.dockOn ? " · Bar-Edge, because Edge is on" : "")
                + (k.length > 0 ? " · " + k : "");
        }
        case "modWeather": return Settings.weatherEnabled ? "On · Calendar and the lock screen" : "Off";
        case "modDock": return root.dockOn ? "On on this monitor" : "Off on this monitor";
        case "modPolkit": return Settings.polkitAgent ? (Polkit.registered ? "On · registered" : "On · another agent holds the session") : "Off";
        case "modNotif": return Notifs.enabled ? "On · the shell owns notifications" : "Off";
        case "layoutDock": return "Preview and configure Edge on this monitor";
        case "dockMotion": return "Shared by every presentation · now " + Settings.motionMode.charAt(0).toUpperCase() + Settings.motionMode.slice(1);
        case "dockOsd": return "With Edge on, the indicator sits inside it";
        case "dockGestures": return "Scroll for volume, middle click to play or pause";
        }
        return "";
    }

    // ---- el aviso del ConfigStore y sus acciones -------------------------------------

    /** El ConfigStore no está bien: el aviso y sus acciones van arriba, en todas las páginas. */
    property bool noteDismissed: false
    readonly property bool storeTrouble: Settings.status !== "ready"
    readonly property bool showNote: !root.storeTrouble && !root.noteDismissed
        && (Settings.note.length > 0 || Settings.fieldErrors.length > 0)

    readonly property string bannerText: {
        if (root.storeTrouble) {
            if (Settings.status === "invalid") return Settings.statusText + ". Changes are kept in memory, not saved.";
            if (Settings.status === "newer") return Settings.statusText + ". Changes are not saved.";
            return Settings.statusText;
        }
        if (Settings.fieldErrors.length > 0)
            return Settings.fieldErrors.length + (Settings.fieldErrors.length === 1 ? " value was" : " values were")
                + " invalid and use the default: " + Settings.fieldErrors.map(e => e.id).join(", ");
        return Settings.note;
    }
    readonly property string bannerTone: Settings.status === "invalid" || Settings.status === "saveFailed" ? "danger"
        : root.storeTrouble || Settings.fieldErrors.length > 0 ? "warn" : "info"

    readonly property var bannerActions: {
        if (!root.storeTrouble && !root.showNote) return [];
        switch (Settings.status) {
        case "invalid": {
            const a = [{ id: "retry", label: "Retry" }];
            if (Settings.lastGoodText.length > 0) a.push({ id: "lastGood", label: "Restore last good" });
            if (Settings.backupOrder.length > 0) a.push({ id: "previous", label: "Restore previous" });
            a.push({ id: "defaults", label: "Restore defaults", danger: true });
            return a;
        }
        case "newer": return [{ id: "defaults", label: "Replace with defaults", danger: true }];
        case "conflict": return [{ id: "useFile", label: "Use file" }, { id: "keepMine", label: "Keep mine" }];
        case "saveFailed": return [{ id: "keepMine", label: "Try again" }];
        }
        return [{ id: "dismiss", label: "Dismiss" }];
    }

    function bannerAct(id) {
        if (id === "retry") Settings.retry();
        else if (id === "lastGood") Settings.restoreLastGood();
        else if (id === "previous") Settings.restorePrevious();
        else if (id === "defaults") Settings.restoreDefaults();
        else if (id === "useFile") Settings.useFile();
        else if (id === "keepMine") Settings.keepMine();
        else if (id === "dismiss") root.noteDismissed = true;
    }

    /**
     * Reset de sección en DOS pasos: el primero arma («Confirm reset (n)?», 3 s), el
     * segundo resetea. De un golpe, «Reset section» en Integrations apagaba el agente
     * de polkit del usuario (su default es false) y dejaba la sesión sin él.
     */
    property string armedSection: ""
    Timer { id: disarm; interval: 3000; onTriggered: root.armedSection = "" }
    function sectionReset(key) {
        if (root.armedSection !== key) {
            root.armedSection = key;
            disarm.restart();
            return;
        }
        root.armedSection = "";
        disarm.stop();
        Settings.resetSection(key);
    }

    // ---- recorrido de teclado del contenido: acciones del aviso y filas de la página --

    readonly property var flat: {
        const out = [];
        for (let i = 0; i < root.bannerActions.length; i++)
            out.push({ banner: true, action: root.bannerActions[i] });
        const bl = root.blocks;
        for (let b = 0; b < bl.length; b++) {
            if (bl[b].head) out.push({ banner: false, disc: bl[b].level });
            if (!bl[b].open) continue;
            const sec = bl[b].section;
            for (let r = 0; r < bl[b].rows.length; r++)
                out.push({ banner: false, row: bl[b].rows[r], section: sec.key, sectionTitle: sec.title, block: b });
        }
        return out;
    }

    // ---- Advanced / Experimental: plegados dentro de su página (9C-1) ------------------

    /** `dest/página#nivel` → abierto. Cerrados al abrir Settings (§3: «cerrados inicialmente»). */
    property var expanded: ({})
    function isExpanded(key, level) { return root.expanded[key + "#" + level] === true; }
    function setExpanded(key, level, on) {
        const m = Object.assign({}, root.expanded);
        if (on) m[key + "#" + level] = true; else delete m[key + "#" + level];
        root.expanded = m;
    }
    readonly property var levelTitle: ({ advanced: "Advanced", experimental: "Experimental" })

    /**
     * Lo que se dibuja de la página que se ve: cada sección, si lleva cabecera plegable
     * delante (la primera de su nivel) y si está abierta. Las comunes siempre lo están.
     */
    readonly property var allBlocks: {
        const out = [];
        const secs = root.shownPage.sections;
        const seen = {};
        for (let i = 0; i < secs.length; i++) {
            const lv = secs[i].level || "";
            const head = lv.length > 0 && !seen[lv];
            if (lv.length > 0) seen[lv] = true;
            let count = 0, custom = 0;
            if (head)
                for (let j = i; j < secs.length; j++)
                    if ((secs[j].level || "") === lv)
                        for (let r = 0; r < secs[j].rows.length; r++) {
                            count++;
                            const pr = secs[j].rows[r].prop;
                            if (pr.length > 0 && Settings.isCustom(pr)) custom++;
                        }
            // Advanced → Surfaces: «· n custom» = las superficies con algo propio
            if (head)
                for (let j = i; j < secs.length; j++)
                    if ((secs[j].level || "") === lv && secs[j].preview === "surface")
                        custom += SurfaceMaterials.customized(Settings.surfaceMaterials).length;
            out.push({ section: secs[i], level: lv, head: head, count: count, custom: custom,
                       rows: root.pack(root.visibleRows(secs[i].dynamic ? root.dynRows(secs[i].dynamic) : secs[i].rows).filter(r => r.id !== "recBitrate" || Settings.recQuality === "bitrate" || root.showBitrate)),
                       tab: Sections.tabFor(root.shownKey, secs[i]),
                       open: lv.length === 0 || root.activeTab === "Advanced" || root.activeTab === "Experimental" || root.activeTab === "Surfaces" || root.isExpanded(root.shownKey, lv) });
        }
        return out;
    }
    readonly property var blocks: root.allBlocks.filter(block => block.tab === root.activeTab).map(block => {
        // Un nivel que ya tiene pestaña propia no exige abrir un segundo control.
        if (root.activeTab === "Advanced" || root.activeTab === "Experimental" || root.activeTab === "Surfaces")
            return Object.assign({}, block, { head: false });
        return block;
    })
    /** Settings UI: las secciones de la página para «On this page» del panel contextual. */
    function sectionList() {
        const out = [];
        for (let i = 0; i < root.blocks.length; i++) {
            const b = root.blocks[i];
            if (b.rows.length === 0) continue;
            out.push({ index: i, title: b.section.title, key: b.section.key,
                       level: b.level.length > 0 ? root.levelTitle[b.level] : "" });
        }
        return out;
    }
    /** Lleva el foco a la primera fila de una sección (abre su plegable si hace falta). */
    function jumpToSection(i) {
        const b = root.blocks[i];
        if (!b) return false;
        if (!b.open) root.setExpanded(root.shownKey, b.level, true);
        root.endSearch(false);
        root.zone = "content";
        root.forceActiveFocus();
        Qt.callLater(() => {
            if (!root) return;
            for (let k = 0; k < root.flat.length; k++)
                if (root.flat[k].block === i && root.flat[k].row) { root.kbIndex = k; root.revealFocused(); return; }
        });
        return true;
    }
    function surfaceTitle() {
        return SurfaceMaterials.labelOf(root.matSurface) + " · " + root.surfSummary(root.matSurface);
    }
    /** Para el banco (IPC `settingsUiState`): la distribución que se ve, en px de la tarjeta. */
    function layoutInfo() {
        const g = (it) => { const p = it.mapToItem(root, 0, 0); return { x: Math.round(p.x), y: Math.round(p.y), w: Math.round(it.width), h: Math.round(it.height), visible: it.visible }; };
        return { compact: root.compact, aside: root.asideShown, frameW: Math.round(root.frameW),
                 page: root.shownKey, group: root.shownGroup.id, desc: root.shownDesc, tab: root.activeTab, tabs: root.sectionTabs,
                 header: g(header), sidebar: g(sidebar), pane: g(pane), asideBox: g(asidePanel),
                 nav: root.compact ? (pageListBox.visible ? compactNav.layoutInfo() : null) : sideNav.layoutInfo(),
                 heading: g(pageHeading), pinnedHeading: pane.pinnedHeading, asideInfo: asidePanel.visible ? asidePanel.layoutInfo() : null,
                 visits: root.visits, visitIndex: root.visitIndex, zone: root.zone,
                 contentY: Math.round(flick.contentY), contentH: Math.round(flick.contentHeight), viewH: Math.round(flick.height) };
    }
    function toggleDisclosure(level, on) {
        const want = on === undefined ? !root.isExpanded(root.shownKey, level) : on;
        root.setExpanded(root.shownKey, level, want);
        // el foco se queda en la cabecera (su índice no cambia: va antes de lo que se abre)
    }
    /**
     * 10A: el foco sigue a la FILA (su id), no al índice (DESIGN §3): al añadir una carpeta a
     * Sources se insertaba una fila antes y el foco saltaba a la vecina, con la página sin
     * desplazar hasta ella (medido). Si la fila desaparece (Supr en Recent), se queda en el mismo
     * índice: la siguiente, como antes.
     */
    property string kbRowId: ""
    property string flatPage: ""
    onKbIndexChanged: {
        const f = root.flat[root.kbIndex];
        root.kbRowId = f && f.row ? f.row.id : "";
    }
    onFlatChanged: {
        const samePage = root.flatPage === root.shownKey;
        root.flatPage = root.shownKey;
        const i = samePage && root.kbRowId.length > 0 ? root.indexOfRow(root.kbRowId) : -1;
        if (i >= 0 && i !== root.kbIndex) root.kbIndex = i;
        else if (root.kbIndex >= root.flat.length) root.kbIndex = Math.max(0, root.flat.length - 1);
        if (samePage && root.zone === "content") Qt.callLater(root.revealFocused);
    }
    function revealFocused() {
        if (!root) return;           // aplazado y el contenido ya descargado (Settings UI)
        const f = root.flat[root.kbIndex];
        if (f && f.row) root.reveal(root.rowItems[f.row.id]);
    }
    /**
     * `reveal` espera a `settled` (9D-1) y nada lo reintentaba: abrir Settings desde cerrado en una
     * fila de abajo (un enlace, la búsqueda, `settingsOpen`) la enfocaba fuera de la vista (visto en
     * las pruebas visuales de la fase 12). Al asentarse, se revela; si ya se ve, no se mueve nada.
     */
    onSettledChanged: if (root.settled && root.zone === "content") Qt.callLater(root.revealFocused)

    function indexOfRow(id) {
        for (let i = 0; i < root.flat.length; i++)
            if (root.flat[i].row && root.flat[i].row.id === id) return i;
        return -1;
    }
    function indexOfAction(id) {
        for (let i = 0; i < root.flat.length; i++)
            if (root.flat[i].banner && root.flat[i].action.id === id) return i;
        return -1;
    }

    function pointerHover(i, gx, gy) {
        // Las rejillas altas de Animations ya tienen hover propio. Darles foco al pasar las desplaza bajo el cursor.
        if (root.shownKey === "shell/animations") return;
        if (root.lastPointer.x < 0) { root.lastPointer = Qt.point(gx, gy); return; }
        if (Math.abs(gx - root.lastPointer.x) < 0.5 && Math.abs(gy - root.lastPointer.y) < 0.5) return;
        root.lastPointer = Qt.point(gx, gy);
        root.kbIndex = i;
        root.zone = "content";
    }

    /** Campos de ruta/ciudad vivos, por id de fila (para abrir su edición con Enter). */
    property var pathFields: ({})
    /** Filas vivas por id, para mantener a la vista la del foco. */
    property var rowItems: ({})
    function register(mapName, id, item, on) {
        const m = Object.assign({}, root[mapName]);
        if (on) m[id] = item;
        else if (m[id] === item) delete m[id];
        root[mapName] = m;
    }

    /** Un paso en una fila: toggle, choice (cíclico), tema, enlace, o abrir la edición de una ruta. */
    function adjust(i, dir) {
        const f = root.flat[i];
        if (!f) return;
        if (f.banner) { if (dir === 0) root.bannerAct(f.action.id); return; }
        if (f.disc) { root.toggleDisclosure(f.disc, dir === 0 ? undefined : dir > 0); return; }
        const r = f.row;
        if (root.rowReason(r).length > 0) return;
        if (r.kind === "toggle") {
            Settings[r.prop] = dir === 0 ? !Settings[r.prop] : dir > 0;
        } else if (r.kind === "sddm") {                                    // Sumi SDDM (2026-11-22)
            const sf = root.pathFields[r.id];
            if (sf) sf.activate(dir); else SddmTheme.step(r.key, dir);
        } else if (r.kind === "taskEvery") {                                // F3d-2
            const vals = r.options.map(o => o.value);
            let idx = vals.indexOf(Settings.taskEvery(r.task));
            if (idx < 0) idx = 0;
            const step = dir === 0 ? 1 : dir;
            Settings.setTaskEvery(r.task, vals[((idx + step) % vals.length + vals.length) % vals.length]);
        } else if (r.kind === "choice") {
            const vals = root.optionsOf(r).map(o => o.value);
            let idx = vals.findIndex(v => String(v) === String(Settings[r.prop]));
            if (idx < 0) idx = 0;
            const step = dir === 0 ? 1 : dir;
            Settings[r.prop] = vals[((idx + step) % vals.length + vals.length) % vals.length];
        } else if (r.kind === "apChoice") {                                // Apariencia (2026-11-13)
            const vals = root.apOptions(r.opt).map(o => o.value);
            if (vals.length === 0) return;
            let idx = vals.findIndex(v => String(v) === String(root.apValue(r.opt)));
            if (idx < 0) idx = 0;
            const step = dir === 0 ? 1 : dir;
            root.apPick(r.opt, vals[((idx + step) % vals.length + vals.length) % vals.length]);
        } else if (r.kind === "interfaceStyle") {                          // ADR-34
            const vals = Style.names;
            const idx = Math.max(0, vals.indexOf(Settings.interfaceStyle));
            const step = dir === 0 ? 1 : dir;
            Settings.interfaceStyle = vals[((idx + step) % vals.length + vals.length) % vals.length];
        } else if (r.kind === "notifPos") {                                // 2026-11-19
            const vals = Schema.entryByProp("notifPosition").values;
            const idx = Math.max(0, vals.indexOf(Settings.notifPosition));
            const step = dir === 0 ? 1 : dir;
            Settings.notifPosition = vals[((idx + step) % vals.length + vals.length) % vals.length];
        } else if (r.kind === "range") {                                   // 2026-11-19: ←/→ de `step` en `step`
            if (dir === 0) return;
            Settings[r.prop] = Math.max(r.min, Math.min(r.max, Settings[r.prop] + dir * r.step));
        } else if (r.kind === "windowStyle") {                             // 2026-11-11; familias 2026-11-21
            const vals = Motion.styleNames(r.family || "window");
            const idx = Math.max(0, vals.indexOf(Settings[r.prop]));
            const step = dir === 0 ? 1 : dir;
            Settings[r.prop] = vals[((idx + step) % vals.length + vals.length) % vals.length];
        } else if (r.kind === "surfPick") {
            const vals = root.surfPickOptions.map(o => o.value);
            const idx = Math.max(0, vals.indexOf(root.matSurface));
            const step = dir === 0 ? 1 : dir;
            root.matSurface = vals[((idx + step) % vals.length + vals.length) % vals.length];
        } else if (r.kind === "surfOpt") {
            const vals = root.surfOptions(r.opt).map(o => o.value);
            const idx = Math.max(0, vals.findIndex(v => String(v) === String(root.surfValue(r.opt))));
            const step = dir === 0 ? 1 : dir;
            root.setSurf(r.opt, vals[((idx + step) % vals.length + vals.length) % vals.length]);
        } else if (r.kind === "screenWall" && dir === 0) {
            Wallpaper.clearOutput(r.screen);
        } else if (r.kind === "importFile" && dir === 0) {
            const ff = root.pathFields[r.id];
            if (ff) ff.startEdit();
        } else if (r.kind === "importMode") {
            Portability.mode = Portability.mode === "merge" ? "replace" : "merge";
        } else if (r.kind === "importPresets") {
            Portability.withPresets = dir === 0 ? !Portability.withPresets : dir > 0;
        } else if (r.kind === "presetItem") {
            if (dir === 0) root.presetSel = r.presetId;
        } else if (r.kind === "idleChoice") {
            if (root.rowReason(r).length === 0) {
                const vals = root.idleOptions(r.key).map(o => o.value);
                const idx = Math.max(0, vals.indexOf(Idle.shown(r.key)));
                const step = dir === 0 ? 1 : dir;
                Idle.setTime(r.key, vals[((idx + step) % vals.length + vals.length) % vals.length], root.screenName);
            }
        } else if (r.kind === "netItem") {
            if (dir === 0) root.netSel = r.uuid;
        } else if (r.kind === "netToggle") {
            root.netSet(r.key, dir === 0 ? !root.netVal(r.key) : dir > 0);
        } else if (r.kind === "netChoice") {
            const vals = r.options.map(o => o.value);
            const idx = Math.max(0, vals.findIndex(v => root.netSame(v, root.netVal(r.key))));
            const step = dir === 0 ? 1 : dir;
            root.netSet(r.key, vals[((idx + step) % vals.length + vals.length) % vals.length]);
        } else if (r.kind === "recText" && dir === 0) {                       // Grabador 2.0
            const rf = root.pathFields[r.id];
            if (rf) rf.startEdit();
        } else if (r.kind === "netText" && dir === 0) {
            if (root.rowReason(r).length === 0) { const nf = root.pathFields[r.id]; if (nf) nf.startEdit(); }
        } else if (r.kind === "presetGroup") {
            const t = Object.assign({}, root.presetOff);
            t[r.group] = dir === 0 ? !t[r.group] : dir < 0;
            root.presetOff = t;
        } else if (r.kind === "presetRename" && dir === 0) {
            const rf = root.pathFields[r.id];
            if (rf) rf.startEdit();
        } else if (r.kind === "themeOpt") {
            const vals = r.options.map(o => o.value);
            const o = root.themeSelectedOpts;
            const cur = r.opt === "sourceKind" ? (o.source === "wallpaper" ? "wallpaper" : "custom") : o[r.opt];
            const idx = Math.max(0, vals.findIndex(v => String(v) === String(cur)));
            const step = dir === 0 ? 1 : dir;
            root.setThemeOpt(r.opt, vals[((idx + step) % vals.length + vals.length) % vals.length]);
        } else if (r.kind === "themeHex" && dir === 0) {
            const hf = root.pathFields[r.id];
            if (hf) hf.startEdit();
        } else if (r.kind === "themeProfile") {
            // 12C: sólo cambia la selección; la prueba la empieza Preview
            const vals = ThemePreview.profiles;
            const idx = Math.max(0, vals.indexOf(root.themeSelected));
            const step = dir === 0 ? 1 : dir;
            root.themeSel = vals[((idx + step) % vals.length + vals.length) % vals.length];
        } else if (r.kind === "dock") {
            root.setDock(dir === 0 ? !root.dockOn : dir > 0);
        } else if (r.kind === "bar") {
            root.setBar(dir === 0 ? !root.barHere : dir > 0);
        } else if (r.kind === "barEdge") {                                 // 2026-11-19
            const vals = BarEdge.EDGES;
            const step = dir === 0 ? 1 : dir;
            const i = Math.max(0, vals.indexOf(root.barEdgeHere));
            root.setBarPref("barEdge", vals[((i + step) % vals.length + vals.length) % vals.length]);
        } else if (r.kind === "barLength") {
            // de 5 en 5 entre el límite y 100 %; desde debajo del límite (otro borde), el primer paso va al límite
            if (dir === 0) return;
            const from = Math.max(root.barLimitPct, root.barLengthHere);
            root.setBarPref("barLength", Math.max(root.barLimitPct, Math.min(BarEdge.MAX_PCT, from + dir * BarEdge.STEP_PCT)));
        } else if (r.kind === "dockPreview") {
            if (dir === 0 && root.dockPreviewItem) root.dockPreviewItem.play();
        } else if (r.kind === "link") {
            if (dir === 0) root.openLink(r.target, r.key);
        } else if (r.kind === "goto") {
            if (dir === 0) root.openPath(r.path);
        } else if (r.kind === "device") {
            // ←/→ (o Enter) pasan al siguiente dispositivo: cambia el POR DEFECTO del sistema
            const l = root.nodesFor(r.which), cur = root.nodeFor(r.which);
            if (l.length > 1) {
                const i = Math.max(0, l.indexOf(cur));
                const n = l[((i + (dir < 0 ? -1 : 1)) % l.length + l.length) % l.length];
                if (r.which === "sink") Mixer.setDefaultSink(n); else Mixer.setDefaultSource(n);
            }
        } else if (r.kind === "volume") {
            const n = root.nodeFor(r.which);
            if (n && dir !== 0) Mixer.setVolume(n, Mixer.shownVolume(n) + 0.05 * dir);
        } else if (r.kind === "mute") {
            const n = root.nodeFor(r.which);
            if (n && (dir === 0 || (dir > 0) !== Mixer.shownMuted(n))) Mixer.toggleMute(n);
        } else if (r.kind === "btPower") {
            if (Bt.present) Bt.setPower(dir === 0 ? !Bt.powered : dir > 0);
        } else if (r.kind === "btDevice") {
            const d = Bt.byAddress(r.addr);
            if (d && dir === 0) { if (d.connected) Bt.disconnectFrom(r.addr); else Bt.connectTo(r.addr); }
        } else if (r.kind === "profile") {
            const l = PowerProfile.available;
            if (l.length > 0) {
                const i = Math.max(0, l.indexOf(PowerProfile.shownProfile));
                PowerProfile.setProfile(l[((i + (dir < 0 ? -1 : 1)) % l.length + l.length) % l.length]);
            }
        } else if (r.kind === "action") {
            if (dir === 0) root.runAction(r.id);
        } else if (r.kind === "wallCurrent") {
            // Enter alterna; → marca, ← desmarca (como un interruptor)
            if (Wallpaper.current.length > 0)
                WallpaperMeta.setFavorite(Wallpaper.current, dir === 0 ? !WallpaperMeta.isFavorite(Wallpaper.current) : dir > 0);
        } else if (r.kind === "wallEntry") {
            // Enter aplica (acción directa, como en Wallpaper List); ←/→ quitan y ponen el favorito
            if (dir === 0) { if (!root.missing(r.path) && r.path !== Wallpaper.current) Wallpaper.apply(r.path); }
            else WallpaperMeta.setFavorite(r.path, dir > 0);
        } else if (r.kind === "pamChoice") {                                  // F5e: elegir no guarda nada
            const vals = root.optionsOf(r).map(o => o.value);
            let idx = vals.indexOf(LockPam.pending.length ? LockPam.pending : LockPam.setting);
            if (idx < 0) idx = 0;
            const step = dir === 0 ? 1 : dir;
            LockPam.choose(vals[((idx + step) % vals.length + vals.length) % vals.length]);
        } else if (r.kind === "pamTest" && dir === 0) {
            const pf = root.pathFields[r.id];
            if (pf && LockPam.pending.length) pf.startEdit();
        } else if ((r.kind === "whKey" || r.kind === "whUser") && dir === 0) {
            const kf = root.pathFields[r.id];
            if (kf) kf.startEdit();
        } else if (r.kind === "wallSourceAdd" && dir === 0) {
            const ff = root.pathFields[r.id];
            if (ff) ff.startEdit();
        } else if (r.kind === "wallDownloadDir") {
            const l = root.downloadChoices.map(o => o.value);
            if (l.length > 0) {
                const i = l.indexOf(Settings.wallpaperDownloadDir);
                const step = dir === 0 ? 1 : dir;
                Wallpaper.setDownloadDir(l[((Math.max(0, i) + (i < 0 ? 0 : step)) % l.length + l.length) % l.length]);
            }
        } else if ((r.kind === "path" || r.kind === "location") && dir === 0) {
            const pf = root.pathFields[r.id];
            if (pf) pf.startEdit();
        }
    }

    function resetAt(i, wholeSection) {
        const f = root.flat[i];
        // 10A: Supr en una carpeta de Sources la quita de la lista (no borra nada del disco)
        if (f && f.row && f.row.kind === "wallSource") {
            Wallpaper.removeSource(f.row.dir);
            return;
        }
        // Supr en Recent / Favorites quita la entrada de esa lista (no borra el archivo)
        if (f && f.row && f.row.kind === "wallEntry") {
            if (f.row.list === "recent") WallpaperMeta.removeRecent(f.row.path);
            else WallpaperMeta.setFavorite(f.row.path, false);
            return;
        }
        // Supr en Material/Opacity de una superficie: esa propiedad vuelve a heredar; Mayús+Supr, las dos
        if (f && f.row && (f.row.kind === "surfOpt" || f.row.kind === "surfPick")) {
            if (wholeSection || f.row.kind === "surfPick") Settings.resetSurface(root.matSurface);
            else root.setSurf(f.row.opt, "inherit");
            return;
        }
        if (!f || !f.row || f.row.prop.length === 0) return;
        if (wholeSection) root.sectionReset(f.section);
        else Settings.resetField(f.row.prop);
    }

    function keyPressed(event) {
        if (fontEditor.editing) { fontEditor.handleKey(event); return; }
        if (fontSync.open) { fontSync.handleKey(event); return; }
        const k = event.key;
        if ((event.modifiers & Qt.ControlModifier) && root.sectionTabs.length > 1
                && (k === Qt.Key_PageUp || k === Qt.Key_PageDown)) {
            root.moveTab(k === Qt.Key_PageDown ? 1 : -1); event.accepted = true; return;
        }
        if (k === Qt.Key_F1) {
            const row = root.rowItems[root.currentRowId()];
            if (row && row.hasHelp) row.helpExpanded = !row.helpExpanded;
            event.accepted = true; return;
        }
        if (root.zone === "sections") {
            if (k === Qt.Key_Left || k === Qt.Key_Right) { root.moveTab(k === Qt.Key_Right ? 1 : -1); event.accepted = true; return; }
            if (k === Qt.Key_Down || k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) {
                root.zone = "content"; root.kbIndex = root.firstRowIndex(); root.revealFocused(); event.accepted = true; return;
            }
        }
        // Settings UI: Alt+←/→ recorren las páginas visitadas (en el island lo hacía el `Shortcut` de Screen)
        if (root.floating && (event.modifiers & Qt.AltModifier) && (k === Qt.Key_Left || k === Qt.Key_Right)) {
            if (k === Qt.Key_Left) root.pageHistory.historyBack(); else root.pageHistory.historyForward();
            event.accepted = true;
            return;
        }
        // Esc con la búsqueda activa: lo de `searchField.onDismissed` (el campo lo consume antes con el
        // teclado real; esto cubre la tecla que llega sin pasar por él: IPC `settingsUiKey`, foco fuera)
        if (k === Qt.Key_Escape) {
            for (const id of ["whKey", "pamTest"]) {
                const pf = root.pathFields[id];
                if (pf && pf.editing) { pf.discard(); event.accepted = true; return; }
            }
        }
        if (k === Qt.Key_Escape && root.zone === "search") {
            if (searchField.text.length > 0) { root.endSearch(false); root.startSearch(); }
            else root.endSearch(true);
            event.accepted = true;
            return;
        }
        if (k === Qt.Key_Tab || k === Qt.Key_Backtab) {
            const back = k === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) !== 0;
            root.tabZone(back ? -1 : 1);
            event.accepted = true;
            return;
        }
        // Teclear una letra empieza a buscar (no Espacio: activa). Ctrl+F también.
        const mods = event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier);
        if (k === Qt.Key_F && (event.modifiers & Qt.ControlModifier)) {
            root.startSearch();
            event.accepted = true;
            return;
        }
        // sólo un carácter IMPRIMIBLE: Supr lleva «\x7f» en `text` y abría la búsqueda (9D-1, medido)
        const code = event.text.length === 1 ? event.text.charCodeAt(0) : 0;
        const printable = (code > 32 && code < 127) || code >= 160;
        if (mods === 0 && printable && k !== Qt.Key_Space && k !== Qt.Key_Delete && k !== Qt.Key_Backspace) {
            root.startSearch(event.text);
            event.accepted = true;
            return;
        }
        if (root.zone === "nav") {
            const n = root.navKeys.length;
            const key = root.navFocus;
            switch (k) {
            case Qt.Key_Up:   root.navIndex = Math.max(0, root.navIndex - 1); event.accepted = true; break;
            case Qt.Key_Down: root.navIndex = Math.min(n - 1, root.navIndex + 1); event.accepted = true; break;
            case Qt.Key_Home: root.navIndex = 0; event.accepted = true; break;
            case Qt.Key_End:  root.navIndex = n - 1; event.accepted = true; break;
            case Qt.Key_Left: {
                const group = Nav.groupOf(key);
                if (group) root.focusGroup(group.id, true);
                else if (key === root.expandedGroup) root.focusGroup(key, false);
                event.accepted = true;
                break;
            }
            case Qt.Key_Right:
                if (key && key === root.expandedGroup) root.navIndex++;
                else if (!event.isAutoRepeat) root.navActivate(key);
                event.accepted = true;
                break;
            case Qt.Key_Return:
            case Qt.Key_Enter:
            case Qt.Key_Space:
                if (!event.isAutoRepeat) root.navActivate(key);
                event.accepted = true;
                break;
            }
            return;
        }
        const shift = (event.modifiers & Qt.ShiftModifier) !== 0;
        switch (k) {
        case Qt.Key_Up:    root.kbIndex = Math.max(0, root.kbIndex - 1); event.accepted = true; break;
        case Qt.Key_Down:  root.kbIndex = Math.min(root.flat.length - 1, root.kbIndex + 1); event.accepted = true; break;
        case Qt.Key_Left:  root.adjust(root.kbIndex, -1); event.accepted = true; break;
        case Qt.Key_Right: root.adjust(root.kbIndex, 1);  event.accepted = true; break;
        case Qt.Key_Delete:
        case Qt.Key_Backspace:
            root.resetAt(root.kbIndex, shift); event.accepted = true; break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Space:
            if (!event.isAutoRepeat) root.adjust(root.kbIndex, 0);
            event.accepted = true;
            break;
        }
    }

    /** La fila con el foco se mantiene a la vista (el host recorta el panel a la pantalla). */
    function reveal(item) {
        // Con el panel aún creciendo el alto visible es el de la animación: revelar entonces
        // bajaba el scroll (68 px al abrir en Theme → Wallpaper, medido). Se espera a `settled`.
        if (!item || !root.settled) return;
        const p = item.mapToItem(column, 0, 0);
        const pad = 8 * root.s;
        if (item.height + 2 * pad >= flick.height) {
            // Una galería puede ocupar varias pantallas. Mantener su comienzo si ya se ve, incluido su Reset.
            if (p.y < flick.contentY || p.y + Math.min(64 * root.s, flick.height / 2) > flick.contentY + flick.height)
                flick.contentY = Math.max(0, p.y - pad);
            return;
        }
        if (p.y - pad < flick.contentY)
            flick.contentY = Math.max(0, p.y - pad);
        else if (p.y + item.height + pad > flick.contentY + flick.height)
            flick.contentY = Math.min(flick.contentHeight - flick.height, p.y + item.height + pad - flick.height);
    }

    /** La miniatura de un fondo (la de generate-thumbs, o la imagen misma). */
    /**
     * 10E-1a: la clave de Wallhaven. En reposo, sólo el estado (nunca la clave). Al editar, un campo
     * SECRETO: Enter guarda (por stdin, en secrets/) y limpia el búfer; Esc descarta y limpia.
     */
    /**
     * F5e: probar una pila PAM. Como KeyField (la clave de Wallhaven): en reposo, el estado de la prueba; al editar, un
     * campo secreto (sin pegar desde el ratón, sin predicción); al aceptar, el texto sale del campo antes de ir a PAM.
     */
    component PamField: Item {
        id: pf
        property bool editing: false
        readonly property bool hasText: pinput.text.length > 0
        function startEdit() {
            if (LockPam.pending.length === 0) return;
            pf.editing = true;
            pinput.focusField();
        }
        function discard() {
            pinput.clear();
            pf.editing = false;
            root.forceActiveFocus();
        }
        implicitWidth: pf.editing ? 230 * root.s : pstate.implicitWidth
        implicitHeight: 28 * root.s

        Text {
            id: pstate
            visible: !pf.editing
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: ({ idle: LockPam.pending.length ? "Test " + LockPam.pending : "—", probing: "Checking…", checking: "Checking…",
                     ok: "In use", failed: "Not changed", error: "Not changed", missing: "Missing" })[LockPam.testState] || ""
            color: LockPam.testState === "ok" ? Theme.fam(palette.accent).text
                : (LockPam.testState === "failed" || LockPam.testState === "error" || LockPam.testState === "missing") ? Theme.errorColor
                : Theme.outline
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
            font.weight: Font.DemiBold
        }
        Rectangle {
            visible: pf.editing
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: 230 * root.s
            height: 22 * root.s
            radius: Metrics.r(5) * root.s
            color: Theme.tileBg
            border.width: 1
            border.color: Theme.fam(palette.accent).selBorder
            SearchField {
                id: pinput
                anchors.fill: parent
                anchors.leftMargin: 8 * root.s
                anchors.rightMargin: 8 * root.s
                s: root.s
                secret: true
                allowPaste: false
                placeholder: "Password for " + (LockPam.pending === "auto" ? "login" : LockPam.pending)
                onAccepted: {
                    const t = pinput.text;
                    pinput.clear();                 // el búfer, no sólo lo que se ve (I-8)
                    pf.editing = false;
                    root.forceActiveFocus();
                    if (t.length > 0) LockPam.test(t);
                }
                onDismissed: pf.discard()
            }
        }
    }

    component KeyField: Item {
        id: kf
        property bool editing: false
        readonly property bool hasText: kinput.text.length > 0
        function startEdit() {
            kf.editing = true;
            kinput.focusField();
        }
        function discard() {
            kinput.clear();
            kf.editing = false;
            root.forceActiveFocus();
        }
        implicitWidth: kf.editing ? 230 * root.s : kstate.implicitWidth
        implicitHeight: 28 * root.s

        Text {
            id: kstate
            visible: !kf.editing
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: WallhavenAccount.statusText
            color: WallhavenAccount.status === "configured" ? Theme.fam(palette.accent).text
                : WallhavenAccount.status === "rejected" ? Theme.errorColor
                : WallhavenAccount.status === "pending" ? Theme.warn : Theme.outline
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
            font.weight: Font.DemiBold
        }
        Rectangle {
            visible: kf.editing
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: 230 * root.s
            height: 22 * root.s
            radius: Metrics.r(5) * root.s
            color: Theme.tileBg
            border.width: 1
            border.color: Theme.fam(palette.accent).selBorder
            SearchField {
                id: kinput
                anchors.fill: parent
                anchors.leftMargin: 8 * root.s
                anchors.rightMargin: 8 * root.s
                s: root.s
                secret: true
                placeholder: "Paste your API key"
                onAccepted: {
                    const t = kinput.text;
                    kinput.clear();                 // el búfer, no sólo lo que se ve
                    kf.editing = false;
                    root.forceActiveFocus();
                    if (t.length > 0) WallhavenAccount.save(t);
                }
                onDismissed: kf.discard()
            }
        }
    }

    component WallThumb: Rectangle {
        property string path: ""
        readonly property string src: path.length > 0 ? root.thumbOf(path) : ""
        width: 64 * root.s
        height: 36 * root.s
        radius: Metrics.r(6) * root.s
        color: Theme.tileBg
        clip: true
        Image {
            anchors.fill: parent
            visible: status === Image.Ready
            source: parent.src
            asynchronous: true
            cache: true
            fillMode: Image.PreserveAspectCrop
            sourceSize.width: 128 * root.s
        }
        Icon {
            anchors.centerIn: parent
            visible: parent.src.length === 0
            name: "wallpaper"
            size: 14 * root.s
            color: Theme.outline
        }
    }
    /** Estrella de favorito: marca o desmarca esa ruta (sin aplicar nada). */
    component Star: Item {
        id: star
        property string path: ""
        readonly property bool on: WallpaperMeta.isFavorite(star.path)
        width: 28 * root.s
        height: 28 * root.s
        Accessible.role: Accessible.CheckBox
        Accessible.name: "Favorite"
        Accessible.checked: star.on
        Accessible.onPressAction: WallpaperMeta.toggleFavorite(star.path)
        Icon {
            anchors.centerIn: parent
            name: star.on ? "star" : "star-outline"
            size: 15 * root.s
            color: star.on ? Theme.fam(palette.accent).accent : (starArea.containsMouse ? Theme.fg : Theme.fgVariant)
        }
        MouseArea {
            id: starArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: WallpaperMeta.toggleFavorite(star.path)
        }
    }

    // ---- dibujo: cabecera ---------------------------------------------------------------

    component Crumb: Text {
        property bool strong: false
        color: strong ? Theme.fg : Theme.outlineText
        font.family: Typography.ui
        font.pixelSize: Typography.body * root.s
        font.weight: strong ? Typography.wStrong : Typography.wNormal
    }

    /**
     * Settings UI (2026-11-07): ya no cuelga del island, así que la cabecera no tiene que
     * apartarse de los círculos de Música y Red (8B-2). Se queda la propiedad por si un
     * contenedor sin ventana propia vuelve a necesitarla.
     */
    readonly property real headerInset: 0

    /**
     * La cabecera: «Settings», las migas (grupo › página), la búsqueda y Back/Forward/Close.
     * En la tarjeta flotante esta franja también la arrastra (la capa pone el asa debajo: lo
     * que no es un control deja pasar el clic).
     */
    Item {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: root.headerInset
        anchors.rightMargin: root.headerInset
        anchors.top: parent.top
        height: 36 * root.s

        Column {
            id: crumbs
            anchors.left: parent.left
            anchors.leftMargin: 6 * root.s
            anchors.right: searchBox.left
            anchors.rightMargin: 12 * root.s
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1 * root.s
            Accessible.role: Accessible.StaticText
            Accessible.name: "Settings, " + root.shownGroup.title + ", " + root.shownPage.title

            Text {
                width: parent.width
                elide: Text.ElideRight
                text: "Settings"
                color: Theme.fg
                font.family: Typography.ui
                font.pixelSize: Typography.title * root.s
                font.weight: Typography.wStrong
            }
            Row {
                width: parent.width
                spacing: 5 * root.s
                Crumb { text: root.shownGroup.title; color: Theme.famNamed(root.groupZone).text; font.pixelSize: Typography.caption * root.s }
                Crumb { text: "›"; font.pixelSize: Typography.caption * root.s }
                Crumb { text: root.shownPage.title; strong: true; font.pixelSize: Typography.caption * root.s }
            }
        }

        FrameNav {
            id: frameNav
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            s: root.s
            // flotante: el historial es el de las páginas de esta ventana (`pageHistory`)
            host: root.floating ? root.pageHistory : root.host
            onCloseRequested: root.requestClose()
        }

        /** Search settings: siempre en la cabecera, busca en todas las páginas (§3, §8). */
        Rectangle {
            id: searchBox
            anchors.right: frameNav.left
            anchors.rightMargin: 10 * root.s
            anchors.verticalCenter: parent.verticalCenter
            width: (root.compact ? 190 : root.asideShown ? 300 : 240) * root.s
            height: 28 * root.s
            radius: Metrics.r(8) * root.s
            color: Theme.tileBg
            border.width: root.zone === "search" ? Metrics.focusWidth * root.s : 0
            border.color: Theme.fam(palette.accent).selBorder

            Icon {
                id: searchGlyph
                anchors.left: parent.left
                anchors.leftMargin: 8 * root.s
                anchors.verticalCenter: parent.verticalCenter
                name: "search"
                size: 12 * root.s
                color: Theme.fgVariant
            }
            SearchField {
                id: searchField
                anchors.left: searchGlyph.right
                anchors.leftMargin: 6 * root.s
                anchors.right: parent.right
                anchors.rightMargin: 8 * root.s
                anchors.verticalCenter: parent.verticalCenter
                s: root.s
                placeholder: "Search settings"
                onTextChanged: root.query = text
                onMoved: (d) => root.searchSel = Math.max(0, Math.min(root.results.length - 1, root.searchSel + d))
                onAccepted: root.openResult(root.searchSel)
                // Esc: primero limpia; con el campo vacío vuelve a la página (§3).
                onDismissed: {
                    if (text.length > 0) { root.endSearch(false); root.startSearch(); }
                    else root.endSearch(true);
                }
                onTabbed: root.tabZone(1)
                backtabs: true
                onBacktabbed: root.tabZone(-1)
            }
            // Un clic en la caja lleva el teclado a la búsqueda (no sólo al TextInput).
            TapHandler { onTapped: root.startSearch() }
        }
    }

    // ---- índice por grupos, compartido con el desplegable estrecho -------------------

    readonly property string navHint: "← →  groups · Tab  focus\nCtrl+PgUp/PgDn  sections"

    Item {
        id: sidebar
        visible: !root.compact
        anchors.left: parent.left
        anchors.top: header.bottom
        anchors.topMargin: 10 * root.s
        anchors.bottom: parent.bottom
        width: Metrics.settingsSideW * root.s

        SettingsSidebar {
            id: sideNav
            anchors.fill: parent
            s: root.s
            groups: root.navGroups
            expandedGroup: root.expandedGroup
            currentKey: root.pageKey
            focusKey: root.navFocus
            hint: root.navHint
            onActivated: (key) => root.navActivate(key)
        }
    }

    Rectangle {
        visible: !root.compact
        anchors.left: sidebar.right
        anchors.leftMargin: 8 * root.s
        anchors.top: sidebar.top
        anchors.bottom: parent.bottom
        width: 1
        color: Qt.alpha(Theme.outline, 0.25)
    }

    // ---- estrecho: un desplegable con todas las páginas ---------------------------------

    Item {
        id: compactBar
        visible: root.compact
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: header.bottom
        anchors.topMargin: root.compact ? 6 * root.s : 0
        height: root.compact ? 34 * root.s : 0

        /** El desplegable de páginas: abierto mientras el teclado está en la navegación. */
        Item {
            id: pageButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(parent.width, 260 * root.s * Typography.textScale)
            height: 30 * root.s
            Accessible.role: Accessible.ComboBox
            Accessible.name: "Page: " + root.shownGroup.title + ", " + root.shownPage.title
            Accessible.onPressAction: root.setZone(root.zone === "nav" ? "content" : "nav")
            Rectangle {
                anchors.fill: parent
                radius: Metrics.r(8) * root.s
                color: Theme.controlBg(Theme.tileBg, pbArea.containsMouse, pbArea.pressed && pbArea.containsMouse, false)
                border.width: root.zone === "nav" ? Metrics.focusWidth * root.s : 0
                border.color: Theme.fam(palette.accent).selBorder
            }
            Text {
                id: pbText
                anchors.left: parent.left
                anchors.leftMargin: 10 * root.s
                anchors.right: pbChevron.left
                anchors.rightMargin: 6 * root.s
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                text: root.shownGroup.title + " › " + root.shownPage.title
                color: Theme.fg
                font.family: Typography.ui
                font.pixelSize: Typography.body * root.s
            }
            Icon {
                id: pbChevron
                anchors.right: parent.right
                anchors.rightMargin: 8 * root.s
                anchors.verticalCenter: parent.verticalCenter
                name: "chevron-down"
                size: 12 * root.s
                color: Theme.fgVariant
            }
            MouseArea {
                id: pbArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setZone(root.zone === "nav" ? "content" : "nav")
            }
        }
    }

    // Local draft. Not saved in navigation context or ThemePreview.
    TypographyEditor {
        id: fontEditor
        objectName: "typographyEditor"
        anchors.fill: parent
        z: 100
        s: root.s
        onFinished: root.forceActiveFocus()
    }
    // T4: sólo enseña e invoca a services/FontSync; cerrar no deshace nada de lo sincronizado.
    TypographySync {
        id: fontSync
        objectName: "typographySync"
        anchors.fill: parent
        z: 100
        s: root.s
        onFinished: root.forceActiveFocus()
    }

    // ---- contenido --------------------------------------------------------------------

    Item {
        id: pane
        anchors.left: root.compact ? parent.left : sidebar.right
        anchors.leftMargin: root.compact ? 0 : 18 * root.s
        anchors.right: root.asideShown ? asideRule.left : parent.right
        anchors.rightMargin: root.asideShown ? 14 * root.s : 0
        anchors.top: root.compact ? compactBar.bottom : header.bottom
        anchors.topMargin: (root.compact ? 6 : 10) * root.s
        anchors.bottom: parent.bottom
        clip: true
        readonly property bool pinnedHeading: height - pageHeading.implicitHeight >= 180 * root.s * Typography.textScale

        Column {
            id: pageHeading
            parent: pane.pinnedHeading ? pane : headingSlot
            width: pane.width
            visible: !root.searching && !fontEditor.editing && !fontSync.open
            Text {
                width: parent.width
                leftPadding: 10 * root.s
                rightPadding: 10 * root.s
                bottomPadding: 8 * root.s
                wrapMode: Text.WordWrap
                text: root.shownPage.title
                color: Theme.fg
                font.family: Typography.ui
                font.pixelSize: Typography.display * root.s
                font.weight: Typography.wStrong
                Accessible.role: Accessible.Heading
            }
            SettingsTabs {
                visible: root.sectionTabs.length > 1
                width: parent.width
                s: root.s
                tabs: root.sectionTabs
                current: root.activeTab
                focused: root.zone === "sections"
                onPicked: (key) => root.selectTab(key, true)
            }
        }

        Flickable {
            id: flick
            anchors.fill: parent
            anchors.topMargin: pane.pinnedHeading ? pageHeading.implicitHeight : 0
            opacity: root.paneOpacity
            clip: true
            visible: !root.searching && !fontEditor.editing && !fontSync.open
            contentWidth: width
            contentHeight: column.implicitHeight
            interactive: contentHeight > height + 1
            boundsBehavior: Flickable.StopAtBounds
            transform: Translate { x: root.slideX }

            Column {
                id: column
                width: flick.width
                topPadding: 6 * root.s

                Item {
                    id: headingSlot
                    width: parent.width
                    height: pane.pinnedHeading ? 0 : pageHeading.implicitHeight
                }

                /** El aviso del ConfigStore, con sus acciones en línea (también en el recorrido ↑↓). */
                Column {
                    width: parent.width
                    visible: root.storeTrouble || root.showNote
                    spacing: 6 * root.s
                    topPadding: 6 * root.s
                    bottomPadding: 4 * root.s

                    Notice {
                        width: parent.width
                        s: root.s
                        tone: root.bannerTone
                        text: root.bannerText
                    }
                    Flow {
                        width: parent.width
                        spacing: 6 * root.s
                        Repeater {
                            model: root.bannerActions
                            delegate: ActionButton {
                                required property var modelData
                                s: root.s
                                label: modelData.label
                                danger: modelData.danger === true
                                focused: root.zone === "content" && root.kbIndex === root.indexOfAction(modelData.id)
                                onTriggered: { root.kbIndex = root.indexOfAction(modelData.id); root.bannerAct(modelData.id); }
                            }
                        }
                    }
                }


                Column {
                    visible: root.shownKey === "theme/typography" && root.activeTab === "Text"
                    width: parent.width
                    topPadding: 16 * root.s
                    bottomPadding: 12 * root.s
                    spacing: 8 * root.s
                    Text {
                        width: parent.width; leftPadding: 12 * root.s; rightPadding: 12 * root.s
                        text: "The quick brown fox jumps over the lazy dog."
                        wrapMode: Text.WordWrap
                        color: Theme.fg; font.family: Typography.ui; font.pixelSize: Typography.title * root.s
                    }
                    Text {
                        width: parent.width; leftPadding: 12 * root.s; rightPadding: 12 * root.s
                        text: "Secondary text and captions · 0123456789"
                        wrapMode: Text.WordWrap
                        color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: Typography.label * root.s
                    }
                    Text {
                        width: parent.width; leftPadding: 12 * root.s; rightPadding: 12 * root.s
                        text: "0O 1lI {} => != // ~/.config"
                        wrapMode: Text.WordWrap
                        color: Theme.fg; font.family: Typography.mono; font.pixelSize: Typography.body * root.s
                    }
                }

                Repeater {
                    model: root.blocks
                    delegate: Column {
                        id: sec
                        required property var modelData
                        required property int index
                        /** Zona de la sección: rota desde la del grupo; dos seguidas nunca comparten color. */
                        palette.accent: Theme.zone(Zones.section(root.shownGroup ? root.shownGroup.id : "", sec.index, sec.modelData.section.title))
                        readonly property var acc: Theme.fam(palette.accent)
                        /** El bloque (sección + nivel + si abre cabecera) y su sección. */
                        readonly property var sd: sec.modelData.section
                        width: column.width

                        readonly property bool showTitle: root.sectionTabs.length < 2 || root.blocks.length > 1 || sec.sd.title !== root.activeTab
                        readonly property int customCount: sec.sd.key.length > 0
                            ? Settings.customInSection(sec.sd.key) : 0

                        /** Advanced / Experimental: la cabecera plegable, delante de la primera sección de su nivel. */
                        Item { visible: sec.modelData.head; width: 1; height: 8 * root.s }
                        Disclosure {
                            visible: sec.modelData.head
                            s: root.s
                            label: sec.modelData.head ? root.levelTitle[sec.modelData.level] : ""
                            summary: sec.modelData.count + (sec.modelData.count === 1 ? " setting" : " settings")
                                + (sec.modelData.custom > 0 ? " · " + sec.modelData.custom + " custom" : "")
                            expanded: sec.modelData.open
                            readonly property int flatIndex: {
                                for (let i = 0; i < root.flat.length; i++)
                                    if (root.flat[i].disc === sec.modelData.level) return i;
                                return -1;
                            }
                            focused: root.zone === "content" && root.kbIndex === flatIndex
                            onFocusedChanged: if (focused) root.reveal(this)
                            onHoveredAt: (gx, gy) => root.pointerHover(flatIndex, gx, gy)
                            onToggled: { root.kbIndex = flatIndex; root.zone = "content"; root.toggleDisclosure(sec.modelData.level); }
                        }

                        Item {
                            visible: sec.modelData.open && (sec.showTitle || sec.customCount > 0)
                            width: parent.width
                            height: secTitle.implicitHeight
                            Text {
                                id: secTitle
                                visible: sec.showTitle
                                topPadding: 16 * root.s
                                bottomPadding: 8 * root.s
                                leftPadding: 12 * root.s
                                text: sec.sd.title
                                color: sec.acc.text
                                font.family: Typography.ui
                                font.pixelSize: Typography.body * root.s
                                font.weight: Font.DemiBold
                            }
                            /** «Reset section» sólo si hay algo que resetear (teclado: Mayús+Supr). */
                            Text {
                                anchors.right: parent.right
                                anchors.rightMargin: 10 * root.s
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: 3 * root.s
                                visible: sec.customCount > 0
                                readonly property bool armed: root.armedSection === sec.sd.key
                                text: armed ? "Confirm reset (" + sec.customCount + ")?" : "Reset section (" + sec.customCount + ")"
                                color: armed ? Theme.danger : (secReset.containsMouse ? Theme.fg : Theme.fam(palette.accent).text)
                                font.family: Typography.ui
                                font.pixelSize: Typography.caption * root.s
                                MouseArea {
                                    id: secReset
                                    anchors.fill: parent
                                    anchors.margins: -6 * root.s
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.sectionReset(sec.sd.key)
                                }
                                Accessible.role: Accessible.Button
                                Accessible.name: "Reset section " + sec.sd.title
                                Accessible.onPressAction: root.sectionReset(sec.sd.key)
                            }
                        }

                        Flow {
                            id: rowFlow
                            width: sec.width
                            spacing: 12 * root.s
                        Repeater {
                            model: sec.modelData.open ? sec.modelData.rows : []
                            delegate: SettingRow {
                                id: rowItem
                                required property var modelData
                                required property int index
                                readonly property int flatIndex: root.indexOfRow(rowItem.modelData.id)
                                // cada fila es una tarjeta con su color, en rotación desde el de la sección (lib/accent-zones.js)
                                palette.accent: Theme.zone(Zones.row(sec.acc.name, rowItem.index, sec.sd.title))

                                width: root.gridField(rowItem.modelData) && rowFlow.width >= 652 * root.s * Typography.textScale
                                    ? Math.floor((rowFlow.width - rowFlow.spacing) / 2) : rowFlow.width
                                s: root.s
                                sectioned: true
                                // la que se estira (sin pareja) va como un interruptor: nombre a la izquierda, pastillas a la
                                // derecha (SettingRow la apila sola si el control pasa del 46 % de la fila)
                                vertical: rowItem.modelData.kind === "choice" && rowItem.modelData.stretch !== true
                                    || rowItem.modelData.kind === "sddmPreview"
                                captionEssential: rowItem.modelData.kind !== "choice" && rowItem.modelData.kind !== "toggle"
                                    || (rowItem.modelData.id === "recEncoder" && Settings.recPreset !== "custom")
                                onHelpRequested: { root.kbIndex = rowItem.flatIndex; root.zone = "content"; root.forceActiveFocus(); }
                                grouped: true
                                first: rowItem.index === 0
                                name: rowItem.modelData.name
                                caption: rowItem.modelData.id === "recNow" && !ScreenRecorder.active
                                    && ScreenRecorder.planNow && !ScreenRecorder.planNow.error
                                    && !(ScreenRecorder.planNow.warnings || []).length ? "" : root.captionOf(rowItem.modelData)
                                available: root.rowReason(rowItem.modelData).length === 0
                                reason: root.rowReason(rowItem.modelData)
                                last: rowItem.index === sec.modelData.rows.length - 1
                                focused: root.zone === "content" && root.kbIndex === rowItem.flatIndex
                                onFocusedChanged: if (focused) root.reveal(rowItem)
                                custom: (rowItem.modelData.prop.length > 0 && Settings.isCustom(rowItem.modelData.prop))
                                    || (rowItem.modelData.kind === "taskEvery" && Settings.taskEvery(rowItem.modelData.task) > 0)
                                    || (rowItem.modelData.kind === "surfOpt" && root.surfValue(rowItem.modelData.opt) !== "inherit")
                                    || (rowItem.modelData.kind === "surfPick" && root.surfHasOwn)
                                    || (["barEdge", "barLength"].indexOf(rowItem.modelData.kind) >= 0
                                        && root.barPrefCustom(rowItem.modelData.kind))
                                    || (rowItem.modelData.kind === "sddm" && SddmTheme.isSet(rowItem.modelData.key))
                                onHoveredAt: (gx, gy) => root.pointerHover(rowItem.flatIndex, gx, gy)
                                onActivated: { root.kbIndex = rowItem.flatIndex; root.zone = "content"; root.adjust(rowItem.flatIndex, 0); }
                                onResetRequested: rowItem.modelData.kind === "sddm" ? SddmTheme.unset(rowItem.modelData.key)
                                    : rowItem.modelData.kind === "taskEvery"
                                    ? Settings.setTaskEvery(rowItem.modelData.task, 0)
                                    : rowItem.modelData.kind === "surfOpt" ? root.setSurf(rowItem.modelData.opt, "inherit")
                                    : rowItem.modelData.kind === "surfPick" ? Settings.resetSurface(root.matSurface)
                                    : ["barEdge", "barLength"].indexOf(rowItem.modelData.kind) >= 0
                                        ? root.resetBarPrefs([rowItem.modelData.kind])
                                    : Settings.resetField(rowItem.modelData.prop)
                                Component.onCompleted: root.register("rowItems", rowItem.modelData.id, rowItem, true)
                                Component.onDestruction: root.register("rowItems", rowItem.modelData.id, rowItem, false)

                                Loader {
                                    sourceComponent: rowItem.modelData.kind === "toggle" ? toggleC
                                        : rowItem.modelData.kind === "choice" ? choiceC
                                        : rowItem.modelData.kind === "taskEvery" ? taskEveryC
                                        : rowItem.modelData.kind === "surfPick" ? surfPickC
                                        : rowItem.modelData.kind === "surfOpt" ? surfOptC
                                        : rowItem.modelData.kind === "themeProfile" ? themeProfileC
                                        : rowItem.modelData.kind === "themeOpt" ? themeOptC
                                        : rowItem.modelData.kind === "themeHex" ? themeHexC
                                        : rowItem.modelData.kind === "presetItem" ? presetItemC
                                        : rowItem.modelData.kind === "netItem" ? netItemC
                                        : rowItem.modelData.kind === "idleChoice" ? idleChoiceC
                                        : rowItem.modelData.kind === "netToggle" ? netToggleC
                                        : rowItem.modelData.kind === "netChoice" ? netChoiceC
                                        : rowItem.modelData.kind === "netText" ? netTextC
                                        : rowItem.modelData.kind === "importFile" ? importFileC
                                        : rowItem.modelData.kind === "screenWall" ? screenWallC
                                        : rowItem.modelData.kind === "importMode" ? importModeC
                                        : rowItem.modelData.kind === "importPresets" ? importPresetsC
                                        : rowItem.modelData.kind === "presetGroup" ? presetGroupC
                                        : rowItem.modelData.kind === "presetRename" ? presetRenameC
                                        : rowItem.modelData.kind === "location" ? locationC
                                        : rowItem.modelData.kind === "dock" ? dockC
                                        : rowItem.modelData.kind === "bar" ? barC
                                        : rowItem.modelData.kind === "barEdge" ? barEdgeC
                                        : rowItem.modelData.kind === "barLength" ? barLengthC
                                        : rowItem.modelData.kind === "dockPreview" ? dockPreviewC
                                        : rowItem.modelData.kind === "link" ? linkC
                                        : rowItem.modelData.kind === "goto" ? gotoC
                                        : rowItem.modelData.kind === "info" ? infoC
                                        : rowItem.modelData.kind === "sddm" ? sddmC
                                        : rowItem.modelData.kind === "sddmPreview" ? sddmPreviewC
                                        : rowItem.modelData.kind === "action" ? actionC
                                        : rowItem.modelData.kind === "themeCard" ? themeCardC
                                        : rowItem.modelData.kind === "wallCurrent" ? wallCurrentC
                                        : rowItem.modelData.kind === "wallEntry" ? wallEntryC
                                        : rowItem.modelData.kind === "swatches" ? swatchesC
                                        : rowItem.modelData.kind === "device" ? deviceC
                                        : rowItem.modelData.kind === "volume" ? volumeC
                                        : rowItem.modelData.kind === "mute" ? muteC
                                        : rowItem.modelData.kind === "btPower" ? btPowerC
                                        : rowItem.modelData.kind === "btDevice" ? btDeviceC
                                        : rowItem.modelData.kind === "profile" ? profileC
                                        : rowItem.modelData.kind === "path" ? pathC
                                        : rowItem.modelData.kind === "wallSource" ? wallSourceC
                                        : rowItem.modelData.kind === "wallSourceAdd" ? wallSourceAddC
                                        : rowItem.modelData.kind === "wallDownloadDir" ? wallDownloadDirC
                                        : rowItem.modelData.kind === "whKey" ? whKeyC
                                        : rowItem.modelData.kind === "pamChoice" ? pamChoiceC
                                        : rowItem.modelData.kind === "pamTest" ? pamTestC
                                        : rowItem.modelData.kind === "whUser" ? whUserC
                                        : rowItem.modelData.kind === "recText" ? recTextC
                                        : rowItem.modelData.kind === "windowStyle" ? windowStyleC
                                        : rowItem.modelData.kind === "notifPos" ? notifPosC
                                        : rowItem.modelData.kind === "range" ? rangeC
                                        : rowItem.modelData.kind === "interfaceStyle" ? interfaceStyleC
                                        : rowItem.modelData.kind === "apChoice" ? apChoiceC
                                        : rowItem.modelData.kind === "apPreview" ? apPreviewC
                                        : null
                                }

                                Component {
                                    id: interfaceStyleC                           // ADR-34
                                    InterfaceStyleChoice {
                                        s: root.s
                                        name: rowItem.modelData.name
                                        value: Settings.interfaceStyle
                                        focused: rowItem.focused
                                        onPicked: (v) => { root.kbIndex = rowItem.flatIndex; Settings.interfaceStyle = v; }
                                    }
                                }
                                Component {
                                    id: windowStyleC                              // 2026-11-11
                                    WindowStyleChoice {
                                        s: root.s
                                        kind: rowItem.modelData.family || "window"
                                        availableWidth: rowItem.controlMaxWidth
                                        name: rowItem.modelData.name
                                        value: Settings[rowItem.modelData.prop]
                                        focused: rowItem.focused
                                        active: root.open
                                        viewport: flick
                                        onPicked: (v) => {
                                            root.kbIndex = rowItem.flatIndex;
                                            root.zone = "content";
                                            Settings[rowItem.modelData.prop] = v;
                                        }
                                    }
                                }
                                Component {
                                    id: notifPosC                                 // 2026-11-19
                                    NotifPositionChoice {
                                        s: root.s
                                        name: rowItem.modelData.name
                                        value: Settings.notifPosition
                                        focused: rowItem.focused
                                        onPicked: (v) => { root.kbIndex = rowItem.flatIndex; Settings.notifPosition = v; }
                                    }
                                }
                                Component {
                                    // 2026-11-19: un entero entre `min` y `max` de `step` en `step` (el margen de los
                                    // popups); el número al lado, en anchura fija para que no baile al cambiar
                                    id: rangeC
                                    Row {
                                        readonly property var r: rowItem.modelData
                                        readonly property real span: Math.max(1, r.max - r.min)
                                        spacing: 10 * root.s
                                        Slider {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 180 * root.s
                                            s: root.s
                                            value: (Settings[parent.r.prop] - parent.r.min) / parent.span
                                            step: parent.r.step / parent.span
                                            focused: rowItem.focused
                                            ring: false     // el contorno es el de la fila
                                            label: parent.r.name
                                            Accessible.description: rangeDisplay.text
                                            onMoved: (v) => {
                                                const r = parent.r;
                                                root.kbIndex = rowItem.flatIndex;
                                                Settings[r.prop] = Math.max(r.min, Math.min(r.max,
                                                    r.min + Math.round(v * parent.span / r.step) * r.step));
                                            }
                                        }
                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            id: rangeDisplay
                                            // lo más ancho de lo medido y lo que ocupa (con cifras tabulares mide
                                            // más que `pillMetrics`: a 1,5 × 1,15 se salía de la fila)
                                            width: Math.max(Math.ceil(implicitWidth), Math.ceil(pillMetrics.advanceWidth("64 px") * 1.1))
                                            text: Settings[parent.r.prop] + " " + parent.r.unit
                                            color: Theme.fg
                                            font.family: Typography.ui
                                            font.pixelSize: Typography.body * root.s
                                            font.features: { "tnum": 1 }
                                        }
                                    }
                                }
                                Component {
                                    id: apChoiceC                                 // Apariencia (2026-11-13)
                                    Choice {
                                        s: root.s
                                        name: rowItem.modelData.name
                                        spacious: true
                                        availableWidth: rowItem.controlMaxWidth
                                        options: root.apOptions(rowItem.modelData.opt)
                                        value: root.apValue(rowItem.modelData.opt)
                                        onPicked: (v) => { root.kbIndex = rowItem.flatIndex; root.apPick(rowItem.modelData.opt, v); }
                                    }
                                }
                                Component {
                                    id: apPreviewC                                // iconos reales / punteros en PNG
                                    Row {
                                        id: apPv
                                        readonly property string which: rowItem.modelData.which
                                        readonly property bool glyphs: which === "glyphs"
                                        readonly property var items: which === "icons" ? Appearance.draftIconPreview
                                            : glyphs ? Appearance.draftGlyphPreview : Appearance.draftCursorPreview
                                        readonly property real cell: (which === "icons" ? 30 : glyphs ? 20 : 28) * root.s
                                        readonly property real gap: (glyphs ? 6 : 8) * root.s
                                        readonly property real pad: glyphs ? 6 * root.s : 0
                                        // iconos pequeños: una franja oscura y una clara fijas (una barra oscura / una
                                        // clara), no la paleta de la shell: cada variante dibuja para uno de los dos fondos
                                        readonly property var surfaces: glyphs ? ["#1d1f24", "#eceef2"] : ["transparent"]
                                        spacing: 8 * root.s
                                        Repeater {
                                            model: apPv.surfaces
                                            delegate: Rectangle {
                                                id: apStrip
                                                required property string modelData
                                                color: modelData
                                                radius: Metrics.r(8) * root.s
                                                width: apFlow.width + 2 * apPv.pad
                                                height: apFlow.implicitHeight + 2 * apPv.pad
                                                Flow {
                                                    id: apFlow
                                                    x: apPv.pad
                                                    y: apPv.pad
                                                    width: Math.min((rowItem.controlMaxWidth - (apPv.surfaces.length - 1) * apPv.spacing) / apPv.surfaces.length
                                                                    - 2 * apPv.pad, apPv.items.length * (apPv.cell + spacing))
                                                    spacing: apPv.gap
                                                    Repeater {
                                                        model: apPv.items
                                                        delegate: Item {
                                                            id: apCell
                                                            required property var modelData
                                                            width: apPv.cell
                                                            height: apPv.cell
                                                            Image {
                                                                anchors.fill: parent
                                                                visible: apCell.modelData.path.length > 0
                                                                source: apCell.modelData.path.length > 0
                                                                    ? "file://" + apCell.modelData.path.split("/").map(encodeURIComponent).join("/") : ""
                                                                sourceSize.width: Math.ceil(width * 2)
                                                                sourceSize.height: Math.ceil(height * 2)
                                                                fillMode: Image.PreserveAspectFit
                                                                asynchronous: true
                                                                smooth: true
                                                                mipmap: true
                                                            }
                                                            Rectangle {
                                                                // falta en el tema (y en lo que hereda): hueco, no un icono inventado
                                                                anchors.fill: parent
                                                                anchors.margins: 4 * root.s
                                                                visible: apCell.modelData.path.length === 0
                                                                radius: Metrics.r(6) * root.s
                                                                color: "transparent"
                                                                border.width: 1
                                                                border.color: Qt.alpha(Theme.outline, 0.5)
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                Component {
                                    id: toggleC
                                    Toggle {
                                        s: root.s
                                        label: rowItem.modelData.name
                                        on: Settings[rowItem.modelData.prop]
                                        onToggled: Settings[rowItem.modelData.prop] = !Settings[rowItem.modelData.prop]
                                    }
                                }
                                Component {
                                    id: choiceC
                                    Choice {
                                        s: root.s
                                        name: rowItem.modelData.name
                                        spacious: true
                                        forcePills: rowItem.modelData.pills === true
                                        availableWidth: rowItem.controlMaxWidth
                                        options: root.optionsOf(rowItem.modelData)
                                        value: Settings[rowItem.modelData.prop]
                                        onPicked: (v) => Settings[rowItem.modelData.prop] = v
                                    }
                                }
                                Component {
                                    id: taskEveryC                                // F3d-2
                                    Choice {
                                        s: root.s
                                        name: rowItem.modelData.name
                                        spacious: true
                                        availableWidth: rowItem.controlMaxWidth
                                        options: rowItem.modelData.options
                                        value: Settings.taskEvery(rowItem.modelData.task)
                                        onPicked: (v) => Settings.setTaskEvery(rowItem.modelData.task, v)
                                    }
                                }
                                Component {
                                    id: surfPickC
                                    Choice {
                                        s: root.s
                                        name: rowItem.modelData.name
                                        spacious: true
                                        availableWidth: rowItem.controlMaxWidth
                                        options: root.surfPickOptions
                                        value: root.matSurface
                                        onPicked: (v) => root.matSurface = v
                                    }
                                }
                                Component {
                                    id: surfOptC
                                    Choice {
                                        s: root.s
                                        name: rowItem.modelData.name
                                        spacious: true
                                        availableWidth: rowItem.controlMaxWidth
                                        options: root.surfOptions(rowItem.modelData.opt)
                                        value: root.surfValue(rowItem.modelData.opt)
                                        onPicked: (v) => root.setSurf(rowItem.modelData.opt, v)
                                    }
                                }
                                Component {
                                    id: screenWallC
                                    ActionButton {
                                        s: root.s
                                        label: Wallpaper.clearState === "clearing" && Wallpaper.clearScreen === rowItem.modelData.screen
                                            ? "Switching…" : "Use shared"
                                        enabled: Wallpaper.hasOwn(rowItem.modelData.screen)
                                        onTriggered: { root.kbIndex = rowItem.flatIndex; Wallpaper.clearOutput(rowItem.modelData.screen); }
                                    }
                                }
                                Component {
                                    id: importFileC
                                    FolderField {
                                        id: impField
                                        s: root.s
                                        glyph: "folder"
                                        placeholder: "~/sumi-settings-….json"
                                        idleText: "Type the path of an export"
                                        accessibleName: "File to import"
                                        note: Portability.analysis ? Portability.analysis.path : ""
                                        onCommitted: (text) => Portability.analyze(text)
                                        onFinished: root.forceActiveFocus()
                                        Component.onCompleted: root.register("pathFields", rowItem.modelData.id, impField, true)
                                        Component.onDestruction: root.register("pathFields", rowItem.modelData.id, impField, false)
                                    }
                                }
                                Component {
                                    id: importModeC
                                    Choice {
                                        s: root.s
                                        name: rowItem.modelData.name
                                        spacious: true
                                        availableWidth: rowItem.controlMaxWidth
                                        options: [{ label: "Merge", value: "merge" }, { label: "Replace", value: "replace" }]
                                        value: Portability.mode
                                        onPicked: (v) => Portability.mode = v
                                    }
                                }
                                Component {
                                    id: importPresetsC
                                    Toggle {
                                        s: root.s
                                        label: rowItem.modelData.name
                                        on: Portability.withPresets
                                        onToggled: Portability.withPresets = !Portability.withPresets
                                    }
                                }
                                Component {
                                    id: presetItemC
                                    ActionButton {
                                        s: root.s
                                        label: root.presetSel === rowItem.modelData.presetId ? "Selected" : "Select"
                                        accent: root.presetSel === rowItem.modelData.presetId
                                        onTriggered: { root.kbIndex = rowItem.flatIndex; root.presetSel = rowItem.modelData.presetId; }
                                    }
                                }
                                Component {
                                    id: idleChoiceC
                                    Choice {
                                        s: root.s
                                        name: rowItem.modelData.name
                                        spacious: true
                                        availableWidth: rowItem.controlMaxWidth
                                        options: root.idleOptions(rowItem.modelData.key)
                                        value: Idle.shown(rowItem.modelData.key)
                                        onPicked: (v) => { if (root.rowReason(rowItem.modelData).length === 0) Idle.setTime(rowItem.modelData.key, v, root.screenName); }
                                    }
                                }
                                // 14D: el editor del perfil de red (todo va al borrador; Save lo manda)
                                Component {
                                    id: netItemC
                                    ActionButton {
                                        s: root.s
                                        label: root.netSel === rowItem.modelData.uuid ? "Selected" : "Select"
                                        accent: root.netSel === rowItem.modelData.uuid
                                        onTriggered: { root.kbIndex = rowItem.flatIndex; root.netSel = rowItem.modelData.uuid; }
                                    }
                                }
                                Component {
                                    id: netToggleC
                                    Toggle {
                                        s: root.s
                                        label: rowItem.modelData.name
                                        on: !!root.netVal(rowItem.modelData.key)
                                        onToggled: root.netSet(rowItem.modelData.key, !root.netVal(rowItem.modelData.key))
                                    }
                                }
                                Component {
                                    id: netChoiceC
                                    Choice {
                                        s: root.s
                                        name: rowItem.modelData.name
                                        spacious: true
                                        availableWidth: rowItem.controlMaxWidth
                                        options: rowItem.modelData.options
                                        value: root.netVal(rowItem.modelData.key)
                                        onPicked: (v) => root.netSet(rowItem.modelData.key, v)
                                    }
                                }
                                Component {
                                    id: netTextC
                                    FolderField {
                                        id: netField
                                        s: root.s
                                        glyph: "info"
                                        placeholder: rowItem.modelData.placeholder || ""
                                        idleText: "Type to change"
                                        accessibleName: rowItem.modelData.name
                                        note: root.netShown(rowItem.modelData.key)
                                        onCommitted: (text) => root.netSet(rowItem.modelData.key, root.netParse(rowItem.modelData.key, text))
                                        onFinished: root.forceActiveFocus()
                                        Component.onCompleted: root.register("pathFields", rowItem.modelData.id, netField, true)
                                        Component.onDestruction: root.register("pathFields", rowItem.modelData.id, netField, false)
                                    }
                                }
                                /** Grabador 2.0: un valor escrito (fps, altura, carpeta, nombre), validado en `recCommit`. */
                                Component {
                                    id: recTextC
                                    FolderField {
                                        id: recField
                                        s: root.s
                                        glyph: rowItem.modelData.field === "dir" ? "folder" : "info"
                                        placeholder: rowItem.modelData.placeholder || ""
                                        idleText: "Type to change"
                                        accessibleName: rowItem.modelData.name
                                        note: root.recFieldNote(rowItem.modelData.field)
                                        noteError: root.recFieldErrors[rowItem.modelData.field] !== undefined
                                        onCommitted: (text) => root.recCommit(rowItem.modelData.field, text)
                                        onFinished: root.forceActiveFocus()
                                        Component.onCompleted: root.register("pathFields", rowItem.modelData.id, recField, true)
                                        Component.onDestruction: root.register("pathFields", rowItem.modelData.id, recField, false)
                                    }
                                }
                                Component {
                                    id: presetGroupC
                                    Toggle {
                                        s: root.s
                                        label: rowItem.modelData.name
                                        on: !root.presetOff[rowItem.modelData.group]
                                            && root.presetWhyNot(rowItem.modelData).length === 0
                                        onToggled: root.adjust(rowItem.flatIndex, 0)
                                    }
                                }
                                Component {
                                    id: presetRenameC
                                    FolderField {
                                        id: rnField
                                        s: root.s
                                        glyph: "info"
                                        placeholder: "Preset name"
                                        idleText: "Type a new name"
                                        accessibleName: "Preset name"
                                        note: root.presetSelected ? root.presetSelected.name : ""
                                        onCommitted: (text) => { if (root.presetSelected) Presets.rename(root.presetSelected.id, text); }
                                        onFinished: root.forceActiveFocus()
                                        Component.onCompleted: root.register("pathFields", rowItem.modelData.id, rnField, true)
                                        Component.onDestruction: root.register("pathFields", rowItem.modelData.id, rnField, false)
                                    }
                                }
                                Component {
                                    id: themeOptC
                                    Choice {
                                        s: root.s
                                        name: rowItem.modelData.name
                                        spacious: true
                                        availableWidth: rowItem.controlMaxWidth
                                        options: rowItem.modelData.options
                                        value: rowItem.modelData.opt === "sourceKind"
                                            ? (root.themeSelectedOpts.source === "wallpaper" ? "wallpaper" : "custom")
                                            : root.themeSelectedOpts[rowItem.modelData.opt]
                                        onPicked: (v) => root.setThemeOpt(rowItem.modelData.opt, v)
                                    }
                                }
                                Component {
                                    id: themeHexC
                                    FolderField {
                                        id: hexField
                                        s: root.s
                                        glyph: "palette"
                                        placeholder: "#3a7bd5"
                                        idleText: "Type a colour"
                                        accessibleName: "Custom colour"
                                        note: root.themeSelectedOpts.source !== "wallpaper" ? root.themeSelectedOpts.source : ""
                                        onCommitted: (text) => {
                                            const t = text.trim().replace(/^([0-9a-fA-F]{6})$/, "#$1");
                                            if (/^#[0-9a-fA-F]{6}$/.test(t)) {
                                                root.themeHexDraft = t.toLowerCase();
                                                root.setThemeOpt("source", t.toLowerCase());
                                            }
                                        }
                                        onFinished: root.forceActiveFocus()
                                        Component.onCompleted: root.register("pathFields", rowItem.modelData.id, hexField, true)
                                        Component.onDestruction: root.register("pathFields", rowItem.modelData.id, hexField, false)
                                    }
                                }
                                Component {
                                    id: themeProfileC
                                    Choice {
                                        s: root.s
                                        name: rowItem.modelData.name
                                        spacious: true
                                        availableWidth: rowItem.controlMaxWidth
                                        options: ThemePreview.profiles.map(function (n) {
                                            return { label: ThemePreview.nameOf(n), value: n };
                                        })
                                        value: root.themeSelected
                                        onPicked: (v) => root.themeSel = v
                                    }
                                }
                                Component {
                                    id: dockC
                                    Toggle {
                                        s: root.s
                                        label: rowItem.modelData.name
                                        on: root.dockOn
                                        onToggled: root.setDock(!root.dockOn)
                                    }
                                }
                                Component {
                                    id: barC
                                    Toggle {
                                        s: root.s
                                        label: rowItem.modelData.name
                                        on: root.barHere
                                        onToggled: root.setBar(!root.barHere)
                                    }
                                }
                                Component {
                                    id: barEdgeC                                  // 2026-11-19
                                    BarEdgeChoice {
                                        s: root.s
                                        name: rowItem.modelData.name
                                        value: root.barEdgeHere
                                        // la que se ve: bajo el límite, el límite
                                        length: Math.max(root.barLengthHere, root.barLimitPct)
                                        focused: rowItem.focused
                                        onPicked: (v) => { root.kbIndex = rowItem.flatIndex; root.setBarPref("barEdge", v); }
                                    }
                                }
                                Component {
                                    // del límite (izquierda) a 100 % de 5 en 5, con el número al lado en anchura fija
                                    // (como `rangeC`): la barra encoge hacia el centro; a la izquierda del todo, ya no más
                                    id: barLengthC
                                    Row {
                                        readonly property real lo: root.barLimitPct
                                        readonly property real span: Math.max(1, BarEdge.MAX_PCT - lo)
                                        spacing: 10 * root.s
                                        Slider {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 180 * root.s
                                            s: root.s
                                            value: Math.max(0, (root.barLengthHere - parent.lo) / parent.span)
                                            Accessible.description: lengthDisplay.text
                                            step: BarEdge.STEP_PCT / parent.span
                                            focused: rowItem.focused
                                            ring: false
                                            label: rowItem.modelData.name
                                            onMoved: (v) => {
                                                root.kbIndex = rowItem.flatIndex;
                                                root.setBarPref("barLength", Math.max(parent.lo, Math.min(BarEdge.MAX_PCT,
                                                    parent.lo + Math.round(v * parent.span / BarEdge.STEP_PCT) * BarEdge.STEP_PCT)));
                                            }
                                        }
                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            id: lengthDisplay
                                            width: Math.max(Math.ceil(implicitWidth), Math.ceil(pillMetrics.advanceWidth("Limit") * 1.1),
                                                            Math.ceil(pillMetrics.advanceWidth("100 %") * 1.1))
                                            text: root.barAtLimit ? "Limit" : root.barLengthHere + " %"
                                            color: Theme.fg
                                            font.family: Typography.ui
                                            font.pixelSize: Typography.body * root.s
                                            font.features: { "tnum": 1 }
                                        }
                                    }
                                }
                                Component {
                                    id: dockPreviewC
                                    Row {
                                        spacing: 8 * root.s
                                        DockPreview {
                                            id: dp
                                            anchors.verticalCenter: parent.verticalCenter
                                            s: root.s
                                            Component.onCompleted: root.dockPreviewItem = dp
                                            Component.onDestruction: if (root.dockPreviewItem === dp) root.dockPreviewItem = null
                                        }
                                        ActionButton {
                                            anchors.verticalCenter: parent.verticalCenter
                                            s: root.s
                                            label: dp.playing ? "Stop" : "Preview"
                                            glyph: dp.playing ? "" : "play"
                                            onTriggered: { root.kbIndex = rowItem.flatIndex; dp.play(); }
                                        }
                                    }
                                }
                                Component {
                                    id: linkC
                                    ActionButton {
                                        s: root.s
                                        label: "Open"
                                        glyph: "chevron-right"
                                        onTriggered: { root.kbIndex = rowItem.flatIndex; root.openLink(rowItem.modelData.target, rowItem.modelData.key); }
                                    }
                                }
                                Component {
                                    id: sddmC                                     // Sumi SDDM (2026-11-22)
                                    SddmField {
                                        id: sddmField
                                        s: root.s
                                        key: rowItem.modelData.key
                                        focused: rowItem.focused
                                        availableWidth: rowItem.controlMaxWidth
                                        onFinished: root.forceActiveFocus()
                                        Component.onCompleted: root.register("pathFields", rowItem.modelData.id, sddmField, true)
                                        Component.onDestruction: root.register("pathFields", rowItem.modelData.id, sddmField, false)
                                    }
                                }
                                Component {
                                    id: sddmPreviewC                              // Sumi SDDM (2026-11-22)
                                    SddmPreview {
                                        s: root.s
                                        availableWidth: rowItem.controlMaxWidth
                                    }
                                }
                                Component {
                                    id: actionC
                                    ActionButton {
                                        s: root.s
                                        label: rowItem.modelData.label || "Run"
                                        onTriggered: { root.kbIndex = rowItem.flatIndex; root.runAction(rowItem.modelData.id); }
                                    }
                                }
                                Component {
                                    id: themeCardC
                                    Row {
                                        spacing: 10 * root.s
                                        WallThumb { anchors.verticalCenter: parent.verticalCenter; path: Wallpaper.current }
                                        Row {
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: 4 * root.s
                                            Repeater {
                                                model: root.swatches.slice(0, 5)
                                                delegate: Rectangle {
                                                    required property var modelData
                                                    width: 14 * root.s
                                                    height: 14 * root.s
                                                    radius: Metrics.pill(width)
                                                    color: modelData.color
                                                    border.width: 1
                                                    border.color: Qt.alpha(Theme.outline, 0.4)
                                                }
                                            }
                                        }
                                    }
                                }
                                Component {
                                    id: wallCurrentC
                                    Row {
                                        spacing: 8 * root.s
                                        WallThumb { anchors.verticalCenter: parent.verticalCenter; path: Wallpaper.current }
                                        Star { anchors.verticalCenter: parent.verticalCenter; path: Wallpaper.current; visible: Wallpaper.current.length > 0 }
                                    }
                                }
                                Component {
                                    id: wallEntryC
                                    Row {
                                        spacing: 8 * root.s
                                        WallThumb {
                                            anchors.verticalCenter: parent.verticalCenter
                                            path: root.missing(rowItem.modelData.path) ? "" : rowItem.modelData.path
                                            opacity: root.missing(rowItem.modelData.path) ? 0.4 : 1
                                        }
                                        ActionButton {
                                            anchors.verticalCenter: parent.verticalCenter
                                            s: root.s
                                            label: "Apply"
                                            enabled: !root.missing(rowItem.modelData.path)
                                                && rowItem.modelData.path !== Wallpaper.current
                                            onTriggered: { root.kbIndex = rowItem.flatIndex; Wallpaper.apply(rowItem.modelData.path); }
                                        }
                                        Star { anchors.verticalCenter: parent.verticalCenter; path: rowItem.modelData.path }
                                    }
                                }
                                Component {
                                    id: deviceC
                                    Choice {
                                        readonly property var cur: root.nodeFor(rowItem.modelData.which)
                                        s: root.s
                                        name: rowItem.modelData.name
                                        spacious: true
                                        availableWidth: rowItem.controlMaxWidth
                                        visible: cur !== null
                                        options: root.nodesFor(rowItem.modelData.which).map(n => ({ label: Mixer.shortLabel(n), value: n.id }))
                                        value: cur ? cur.id : -1
                                        onPicked: (v) => {
                                            const n = Mixer.nodeById(v);
                                            if (!n) return;
                                            if (rowItem.modelData.which === "sink") Mixer.setDefaultSink(n); else Mixer.setDefaultSource(n);
                                        }
                                    }
                                }
                                Component {
                                    id: volumeC
                                    Slider {
                                        readonly property var node: root.nodeFor(rowItem.modelData.which)
                                        width: 220 * root.s
                                        s: root.s
                                        visible: node !== null
                                        value: node ? Mixer.shownVolume(node) : 0
                                        muted: node ? Mixer.shownMuted(node) : false
                                        focused: rowItem.focused
                                        ring: false     // el contorno es el de la fila
                                        label: rowItem.modelData.name
                                        onMoved: (v) => { root.kbIndex = rowItem.flatIndex; if (node) Mixer.setVolume(node, v); }
                                    }
                                }
                                Component {
                                    id: muteC
                                    Toggle {
                                        readonly property var node: root.nodeFor(rowItem.modelData.which)
                                        s: root.s
                                        label: rowItem.modelData.name
                                        visible: node !== null
                                        on: node ? Mixer.shownMuted(node) : false
                                        onToggled: if (node) Mixer.toggleMute(node)
                                    }
                                }
                                Component {
                                    id: btPowerC
                                    Toggle {
                                        s: root.s
                                        label: rowItem.modelData.name
                                        visible: Bt.present
                                        on: Bt.powered
                                        onToggled: Bt.setPower(!Bt.powered)
                                    }
                                }
                                Component {
                                    id: btDeviceC
                                    ActionButton {
                                        readonly property var dev: Bt.byAddress(rowItem.modelData.addr)
                                        s: root.s
                                        label: Bt.phaseFor(rowItem.modelData.addr) !== "idle" ? "…"
                                            : dev && dev.connected ? "Disconnect" : "Connect"
                                        enabled: dev !== null && Bt.powered && !Bt.busy
                                        onTriggered: { root.kbIndex = rowItem.flatIndex; root.adjust(rowItem.flatIndex, 0); }
                                    }
                                }
                                Component {
                                    id: profileC
                                    Choice {
                                        s: root.s
                                        name: rowItem.modelData.name
                                        spacious: true
                                        availableWidth: rowItem.controlMaxWidth
                                        options: PowerProfile.available.map(n => ({
                                            label: n === "power-saver" ? "Power saver" : n.charAt(0).toUpperCase() + n.slice(1), value: n }))
                                        value: PowerProfile.shownProfile
                                        onPicked: (v) => PowerProfile.setProfile(v)
                                    }
                                }
                                Component {
                                    id: swatchesC
                                    SwatchGrid { s: root.s; swatches: root.swatches }
                                }
                                Component {
                                    id: gotoC
                                    ActionButton {
                                        s: root.s
                                        label: "Go"
                                        glyph: "chevron-right"
                                        onTriggered: { root.kbIndex = rowItem.flatIndex; root.openPath(rowItem.modelData.path); }
                                    }
                                }
                                Component {
                                    id: infoC
                                    Text {
                                        readonly property string v: root.infoValue(rowItem.modelData)
                                        width: Math.min(implicitWidth, column.width * 0.62)
                                        horizontalAlignment: Text.AlignRight
                                        // listas largas (temas instalados): en líneas, no cortadas por el medio
                                        wrapMode: Text.WordWrap
                                        maximumLineCount: 3
                                        elide: Text.ElideRight
                                        // una fila de «lista vacía» no lleva guion: su texto ya lo dice
                                        // «AAC 160 kb/s» no se parte por dentro al crecer el texto (2026-11-12)
                                        text: v.length > 0 ? TextWrap.keepSegments(v)
                                            : (/(Empty|Later)$/.test(rowItem.modelData.id) ? "" : "—")
                                        // F2b: el estado de una capacidad lleva su tono (Environment)
                                        color: v.length === 0 ? Theme.outlineText
                                            : rowItem.modelData.tone === "bad" ? Theme.danger
                                            : rowItem.modelData.tone === "warn" ? Theme.warn : Theme.fg
                                        font.family: Typography.ui
                                        font.pixelSize: Typography.body * root.s
                                    }
                                }
                                Component {
                                    id: locationC
                                    LocationField {
                                        id: lf
                                        s: root.s
                                        location: Settings.weatherLocation
                                        enabled: Settings.weatherEnabled
                                        Component.onCompleted: root.register("pathFields", rowItem.modelData.id, lf, true)
                                        Component.onDestruction: root.register("pathFields", rowItem.modelData.id, lf, false)
                                    }
                                }
                                /** F5e: la candidata a probar (elegir no guarda nada). */
                                Component {
                                    id: pamChoiceC
                                    Choice {
                                        s: root.s
                                        name: rowItem.modelData.name
                                        spacious: true
                                        availableWidth: rowItem.controlMaxWidth
                                        options: root.optionsOf(rowItem.modelData)
                                        value: LockPam.pending.length ? LockPam.pending : LockPam.setting
                                        onPicked: (v) => LockPam.choose(v)
                                    }
                                }
                                /** F5e: la contraseña para probar la candidata — estado en reposo; campo secreto al editar. */
                                Component {
                                    id: pamTestC
                                    PamField {
                                        id: pfield
                                        Component.onCompleted: root.register("pathFields", rowItem.modelData.id, pfield, true)
                                        Component.onDestruction: root.register("pathFields", rowItem.modelData.id, pfield, false)
                                    }
                                }
                                /** 10E-1a: la clave — estado en reposo; campo secreto al editar. */
                                Component {
                                    id: whKeyC
                                    KeyField {
                                        id: kfield
                                        Component.onCompleted: root.register("pathFields", rowItem.modelData.id, kfield, true)
                                        Component.onDestruction: root.register("pathFields", rowItem.modelData.id, kfield, false)
                                    }
                                }
                                Component {
                                    id: whUserC
                                    FolderField {
                                        id: ufield
                                        s: root.s
                                        glyph: "info"
                                        placeholder: "username"
                                        idleText: "Type your username"
                                        accessibleName: "Wallhaven username"
                                        note: Settings.wallhavenUser
                                        onCommitted: (text) => {
                                            if (/^[A-Za-z0-9_.-]{1,64}$/.test(text)) Settings.wallhavenUser = text;
                                        }
                                        onFinished: root.forceActiveFocus()
                                        Component.onCompleted: root.register("pathFields", rowItem.modelData.id, ufield, true)
                                        Component.onDestruction: root.register("pathFields", rowItem.modelData.id, ufield, false)
                                    }
                                }
                                Component {
                                    id: wallSourceC
                                    ActionButton {
                                        s: root.s
                                        label: "Remove"
                                        onTriggered: { root.kbIndex = rowItem.flatIndex; Wallpaper.removeSource(rowItem.modelData.dir); }
                                    }
                                }
                                Component {
                                    id: wallSourceAddC
                                    FolderField {
                                        id: ff
                                        s: root.s
                                        note: Wallpaper.sourceNote.message || ""
                                        noteError: Wallpaper.sourceNote.state === "error"
                                        onCommitted: (text) => Wallpaper.addSource(text)
                                        onFinished: root.forceActiveFocus()
                                        Component.onCompleted: root.register("pathFields", rowItem.modelData.id, ff, true)
                                        Component.onDestruction: root.register("pathFields", rowItem.modelData.id, ff, false)
                                    }
                                }
                                /** Una ruta por valor (un `Choice` pintaba todas en línea y desbordaba): ←/→ o clic cambian. */
                                Component {
                                    id: wallDownloadDirC
                                    Row {
                                        spacing: 6 * root.s
                                        Accessible.role: Accessible.ComboBox
                                        Accessible.name: "Download folder"
                                        Accessible.description: Wallpaper.pretty(Wallpaper.downloadDir)
                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: Math.min(implicitWidth, 260 * root.s)
                                            elide: Text.ElideLeft
                                            text: Wallpaper.pretty(Wallpaper.downloadDir)
                                            color: Wallpaper.downloadDirState === "ok" ? Theme.fg : Theme.errorColor
                                            font.family: Typography.mono
                                            font.pixelSize: Typography.caption * root.s
                                        }
                                        Icon {
                                            anchors.verticalCenter: parent.verticalCenter
                                            visible: root.downloadChoices.length > 1
                                                || (root.downloadChoices.length === 1 && Wallpaper.downloadDirState !== "ok")
                                            name: "chevron-right"
                                            size: 12 * root.s
                                            color: dlArea.containsMouse ? Theme.fg : Theme.fgVariant
                                            MouseArea {
                                                id: dlArea
                                                anchors.fill: parent
                                                anchors.margins: -6 * root.s
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: { root.kbIndex = rowItem.flatIndex; root.adjust(rowItem.flatIndex, 1); }
                                            }
                                        }
                                    }
                                }
                                Component {
                                    id: pathC
                                    PathField {
                                        id: pf
                                        s: root.s
                                        round: rowItem.modelData.round === true
                                        value: Settings[rowItem.modelData.prop]
                                        // sin vista previa por defecto para el avatar: `~/.face` puede no
                                        // existir y una `Image` con una ruta que falta deja un aviso en el journal
                                        placeholder: rowItem.modelData.placeholder
                                        onCommitted: (text) => Settings[rowItem.modelData.prop] = text
                                        Component.onCompleted: root.register("pathFields", rowItem.modelData.id, pf, true)
                                        Component.onDestruction: root.register("pathFields", rowItem.modelData.id, pf, false)
                                    }
                                }
                            }
                        }

                        } // Flow de campos

                        // el material global bajo Finish; el efectivo de la superficie elegida bajo Surfaces
                        // con el panel contextual a la vista, la muestra vive allí (no dos veces)
                        MaterialPreview {
                            visible: sec.modelData.open && sec.sd.preview !== undefined && !root.asideShown
                            width: sec.width - 24 * root.s
                            s: root.s
                            x: 12 * root.s
                            surface: sec.sd.preview === "surface" ? root.matSurface : ""
                            title: sec.sd.preview === "surface"
                                ? SurfaceMaterials.labelOf(root.matSurface) + " · " + root.surfSummary(root.matSurface) : ""
                        }
                    }
                }

                Item { width: 1; height: 8 * root.s }
            }
        }

        ScrollHint { view: root.searching ? resultsFlick : flick; s: root.s }

        /** Resultados: «Shell › Animations › Motion» + etiqueta + valor efectivo. */
        Flickable {
            id: resultsFlick
            anchors.fill: parent
            visible: root.searching
            contentWidth: width
            contentHeight: resultsCol.implicitHeight
            clip: true
            interactive: contentHeight > height + 1
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: resultsCol
                width: resultsFlick.width

                Text {
                    leftPadding: 12 * root.s
                    bottomPadding: 6 * root.s
                    text: root.results.length === 0 ? "No settings match “" + root.query.trim() + "”"
                        : root.results.length + (root.results.length === 1 ? " result" : " results")
                    color: root.results.length === 0 ? Theme.fgVariant : Theme.outlineText
                    font.family: Typography.ui
                    font.pixelSize: (root.results.length === 0 ? Typography.body : Typography.caption) * root.s
                }

                Repeater {
                    model: root.results
                    delegate: Item {
                        id: res
                        required property var modelData
                        required property int index
                        readonly property bool sel: root.searchSel === res.index
                        readonly property string why: root.reasonOf(res.modelData)
                        width: resultsCol.width
                        height: 48 * root.s
                        onSelChanged: if (sel) {
                            const y = res.y;
                            if (y < resultsFlick.contentY) resultsFlick.contentY = y;
                            else if (y + height > resultsFlick.contentY + resultsFlick.height)
                                resultsFlick.contentY = y + height - resultsFlick.height;
                        }

                        Accessible.role: Accessible.ListItem
                        Accessible.name: res.modelData.crumbs + " › " + res.modelData.label
                        Accessible.description: res.why.length > 0 ? res.why : root.valueOf(res.modelData)
                        Accessible.selected: res.sel
                        Accessible.onPressAction: root.openResult(res.index)

                        Rectangle {
                            anchors.fill: parent
                            anchors.topMargin: 2 * root.s
                            anchors.bottomMargin: 2 * root.s
                            radius: Metrics.r(8) * root.s
                            color: res.sel ? Theme.tileBg : (resArea.containsMouse ? Theme.hoverBg : "transparent")
                            border.width: res.sel ? Metrics.focusWidth * root.s : 0
                            border.color: Theme.fam(palette.accent).selBorder
                        }
                        Column {
                            anchors.left: parent.left
                            anchors.leftMargin: 12 * root.s
                            anchors.right: resValue.left
                            anchors.rightMargin: 12 * root.s
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2 * root.s
                            Text {
                                width: parent.width
                                elide: Text.ElideRight
                                text: res.modelData.crumbs + (res.modelData.kind === "page" ? "" : " ›")
                                color: Theme.outlineText
                                font.family: Typography.ui
                                font.pixelSize: Typography.caption * root.s
                            }
                            Text {
                                width: parent.width
                                elide: Text.ElideRight
                                text: res.modelData.label + (res.modelData.kind === "page" ? "  · page" : "")
                                color: res.modelData.kind === "planned" ? Theme.fgVariant : Theme.fg
                                font.family: Typography.ui
                                font.pixelSize: Typography.body * root.s
                                font.weight: Typography.wMedium
                            }
                        }
                        Text {
                            id: resValue
                            anchors.right: parent.right
                            anchors.rightMargin: 12 * root.s
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.min(implicitWidth, resultsCol.width * 0.45)
                            horizontalAlignment: Text.AlignRight
                            elide: Text.ElideRight
                            text: res.why.length > 0 ? res.why : root.valueOf(res.modelData)
                            color: res.why.length > 0 ? Theme.warn : Theme.fgVariant
                            font.family: Typography.ui
                            font.pixelSize: Typography.caption * root.s
                        }
                        MouseArea {
                            id: resArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: res.modelData.kind === "planned" ? Qt.ArrowCursor : Qt.PointingHandCursor
                            onClicked: { root.searchSel = res.index; root.openResult(res.index); }
                        }
                    }
                }

                Text {
                    visible: root.results.length > 0
                    leftPadding: 12 * root.s
                    topPadding: 6 * root.s
                    text: "↑↓ select  ·  Enter open  ·  Esc return"
                    color: Theme.outlineText
                    font.family: Typography.ui
                    font.pixelSize: Typography.micro * root.s
                }
            }
        }
    }

    // ---- panel contextual (components/SettingsAside): sólo con sitio de sobra -----------

    Rectangle {
        id: asideRule
        visible: root.asideShown
        anchors.right: asidePanel.left
        anchors.rightMargin: 14 * root.s
        anchors.top: asidePanel.top
        anchors.bottom: parent.bottom
        width: 1
        color: Qt.alpha(Theme.outline, 0.25)
    }
    SettingsAside {
        id: asidePanel
        visible: root.asideShown
        anchors.right: parent.right
        anchors.top: header.bottom
        anchors.topMargin: 10 * root.s
        anchors.bottom: parent.bottom
        width: Metrics.settingsAsideW * root.s
        s: root.s
        ctl: root
        opacity: root.paneOpacity
    }

    /** Estrecho: la lista de páginas, sobre el contenido, mientras el teclado navega. */
    Rectangle {
        id: pageListBox
        visible: root.compact && root.zone === "nav"
        z: 5
        anchors.left: parent.left
        anchors.top: compactBar.bottom
        anchors.topMargin: 4 * root.s
        width: pageButton.width
        height: Math.max(0, Math.min(root.height - y, compactNav.implicitHeight + 12 * root.s))
        radius: Metrics.r(12) * root.s
        // opaco: translúcido, las filas de debajo se leían a través de la lista (banco 2026-11-07)
        color: Qt.alpha(Theme.bgFor("settings", true), 1)
        border.width: 1
        border.color: Qt.alpha(Theme.outline, 0.3)
        MouseArea { anchors.fill: parent }       // no atraviesa hacia las filas de debajo
        SettingsSidebar {
            id: compactNav
            anchors.fill: parent
            anchors.margins: 6 * root.s
            s: root.s
            groups: root.navGroups
            expandedGroup: root.expandedGroup
            currentKey: root.pageKey
            focusKey: root.navFocus
            onActivated: (key) => root.navActivate(key)
        }
    }
}
