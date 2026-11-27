import QtQuick
import Quickshell
import Quickshell.Hyprland
import "../services"

/**
 * Atajos globales del shell (Fase 9.a).
 *
 * Hasta la Fase 8 cada tecla de SUPER+CTRL lanzaba `qs -c sumi ipc call`,
 * es decir un PROCESO NUEVO por pulsacion. Medido el 2026-09-08 con los dos
 * caminos en el mismo proceso y disparados por el mismo dispatcher, para que
 * el coste de `hyprctl` se cancele en la resta:
 *
 *     exec + cliente IPC   n=9   min 23   mediana 24   media 23.8   max 25 ms
 *     GlobalShortcut       n=9   min  4   mediana  4   media  4.1   max  5 ms
 *
 * Los ~4 ms que quedan son el `hyprctl` comun; con una tecla real el camino
 * de abajo es practicamente cero. La diferencia (19,7 ms) es exactamente el
 * spawn del cliente que se ahorra.
 *
 * El IPC NO se retira: sigue siendo la via para scripts, para `minimaru.fish`
 * y para depurar (docs/IPC.md). Las dos vias comparten las acciones a traves
 * de core/Screens para que no puedan divergir.
 *
 * Con el shell apagado, Hyprland despacha a un atajo sin cliente y no pasa
 * nada -- probado: responde `ok` y el compositor sigue vivo. Es el mismo modo
 * de fallo que tenia el `exec` de antes.
 *
 * Ayuda de atajos (2026-10-30): los `name` siguen aquí, literales (son el contrato público, api/contract-v1.json);
 * la descripción sale del catálogo `lib/shortcuts.json` (la misma, byte a byte) y lo que hace cada uno, de
 * `Screens.runShortcut`, que también usa el botón Open de la ayuda. Una descripción cambiada sólo llega a
 * `hyprctl globalshortcuts` tras reiniciar la shell (una recarga no vuelve a registrar el atajo).
 */
Scope {
    id: root

    readonly property string appId: "sumi"

    // --- Superficies -------------------------------------------------------

    GlobalShortcut {
        appid: root.appId
        name: "launcher"
        description: Keybinds.description("launcher")
        onPressed: Screens.runShortcut("launcher", "", "shortcut")
    }

    GlobalShortcut {
        appid: root.appId
        name: "wallpaper"
        description: Keybinds.description("wallpaper")
        onPressed: Screens.runShortcut("wallpaper", "", "shortcut")
    }

    GlobalShortcut {
        appid: root.appId
        name: "wallhaven"
        description: Keybinds.description("wallhaven")
        onPressed: Screens.runShortcut("wallhaven", "", "shortcut")
    }

    /**
     * Super+R (2026-10-30, a petición del usuario): la surface del grabador sólo se abría desde la barra, el
     * círculo del island o el IPC. Abre y cierra como las demás; grabando, enseña pausa/parar (la grabación no
     * depende de que la surface esté abierta: Escape la cierra sin parar).
     */
    GlobalShortcut {
        appid: root.appId
        name: "recorder"
        description: Keybinds.description("recorder")
        onPressed: Screens.runShortcut("recorder", "", "shortcut")
    }

    GlobalShortcut {
        appid: root.appId
        name: "monitor"
        description: Keybinds.description("monitor")
        onPressed: Screens.runShortcut("monitor", "", "shortcut")
    }

    GlobalShortcut {
        appid: root.appId
        name: "audio"
        description: Keybinds.description("audio")
        onPressed: Screens.runShortcut("audio", "", "shortcut")
    }

    GlobalShortcut {
        appid: root.appId
        name: "media"
        description: Keybinds.description("media")
        onPressed: Screens.runShortcut("media", "", "shortcut")
    }

    GlobalShortcut {
        appid: root.appId
        name: "settings"
        description: Keybinds.description("settings")
        onPressed: Screens.runShortcut("settings", "", "shortcut")
    }

    GlobalShortcut {
        appid: root.appId
        name: "system"
        description: Keybinds.description("system")
        onPressed: Screens.runShortcut("system", "", "shortcut")
    }

    GlobalShortcut {
        appid: root.appId
        name: "controlCenter"
        description: Keybinds.description("controlCenter")
        onPressed: Screens.runShortcut("controlCenter", "", "shortcut")
    }

    GlobalShortcut {
        appid: root.appId
        name: "calendar"
        description: Keybinds.description("calendar")
        onPressed: Screens.runShortcut("calendar", "", "shortcut")
    }

    /** Super+Ctrl+C (2026-10-27): la Calendar UI de Codex (10-26) sólo se abría desde Hoy o por IPC. */
    GlobalShortcut {
        appid: root.appId
        name: "calendarUi"
        description: Keybinds.description("calendarUi")
        onPressed: Screens.runShortcut("calendarUi", "", "shortcut")
    }

    /** Super+Ctrl+L (2026-11-23): la ventana Login screen (Sumi SDDM); al lado de Super+L, que bloquea. */
    GlobalShortcut {
        appid: root.appId
        name: "loginScreen"
        description: Keybinds.description("loginScreen")
        onPressed: Screens.runShortcut("loginScreen", "", "shortcut")
    }

    GlobalShortcut {
        appid: root.appId
        name: "mixer"
        description: Keybinds.description("mixer")
        onPressed: Screens.runShortcut("mixer", "", "shortcut")
    }

    /**
     * El de power **faltaba**: el bind de `keybinds.lua` pedia
     * `sumi:power` y aqui no habia nadie escuchando, asi que la tecla no
     * hacia nada. Lo reporto el usuario. Cada `sumiShell("x")` del Lua
     * necesita su `GlobalShortcut` con el mismo `name` -- son dos archivos que
     * hay que tocar a la vez.
     */
    GlobalShortcut {
        appid: root.appId
        name: "web"
        description: Keybinds.description("web")
        onPressed: Screens.runShortcut("web", "", "shortcut")
    }

    GlobalShortcut {
        appid: root.appId
        name: "power"
        description: Keybinds.description("power")
        onPressed: Screens.runShortcut("power", "", "shortcut")
    }

    GlobalShortcut {
        appid: root.appId
        name: "clipboard"
        description: Keybinds.description("clipboard")
        onPressed: Screens.runShortcut("clipboard", "", "shortcut")
    }

    GlobalShortcut {
        appid: root.appId
        name: "emoji"
        description: Keybinds.description("emoji")
        onPressed: Screens.runShortcut("emoji", "", "shortcut")
    }

    GlobalShortcut {
        appid: root.appId
        name: "wifi"
        description: Keybinds.description("wifi")
        onPressed: Screens.runShortcut("wifi", "", "shortcut")
    }

    GlobalShortcut {
        appid: root.appId
        name: "bluetooth"
        description: Keybinds.description("bluetooth")
        onPressed: Screens.runShortcut("bluetooth", "", "shortcut")
    }

    GlobalShortcut {
        appid: root.appId
        name: "dashboard"
        description: Keybinds.description("dashboard")
        onPressed: Screens.runShortcut("dashboard", "", "shortcut")
    }

    // Etapa C del Dashboard (2026-11-10): la ventana Tasks (core/TasksLayer); alterna en la pantalla enfocada
    GlobalShortcut {
        appid: root.appId
        name: "tasks"
        description: Keybinds.description("tasks")
        onPressed: Screens.runShortcut("tasks", "", "shortcut")
    }

    GlobalShortcut {
        appid: root.appId
        name: "minimizer"
        description: Keybinds.description("minimizer")
        onPressed: Screens.runShortcut("minimizer", "", "shortcut")
    }

    GlobalShortcut {
        appid: root.appId
        name: "services"
        description: Keybinds.description("services")
        onPressed: Screens.runShortcut("services", "", "shortcut")
    }

    GlobalShortcut {
        appid: root.appId
        name: "theme"
        description: Keybinds.description("theme")
        onPressed: Screens.runShortcut("theme", "", "shortcut")
    }

    GlobalShortcut {
        appid: root.appId
        name: "cli"
        description: Keybinds.description("cli")
        onPressed: Screens.runShortcut("cli", "", "shortcut")
    }

    /**
     * SUPER+A (ADR-29, Fase 3): el centro de notificaciones del shell. Hasta la
     * Fase 4 (2026-09-22), con el ajuste apagado abria el panel de SwayNC, como
     * hacia `swaync-client -t`; retirado aquel, la superficie se abre igual y
     * dice que el servidor esta apagado, que es la verdad y no un atajo muerto.
     */
    GlobalShortcut {
        appid: root.appId
        name: "notifications"
        description: Keybinds.description("notifications")
        onPressed: Screens.runShortcut("notifications", "", "shortcut")
    }

    /**
     * Super+F1 por defecto (2026-10-30, a petición del usuario): la ayuda de atajos (core/KeybindsLayer), la tarjeta que
     * dice qué abre cada atajo de la shell y con qué tecla. Abre y cierra.
     */
    GlobalShortcut {
        appid: root.appId
        name: "keybinds"
        description: Keybinds.description("keybinds")
        onPressed: Screens.runShortcut("keybinds", "", "shortcut")
    }

    // --- Acciones sin superficie -------------------------------------------

    /** Super+Ctrl+Space desde la 8C-1 (era Super+Ctrl+P): la cara hover, o la barra, con teclado. */
    GlobalShortcut {
        appid: root.appId
        name: "peek"
        description: Keybinds.description("peek")
        onPressed: Screens.runShortcut("peek", "", "shortcut")
    }

    /** Super+Ctrl+P (8C-1): alterna la Hover Bar persistente en el monitor enfocado. */
    GlobalShortcut {
        appid: root.appId
        name: "barToggle"
        description: Keybinds.description("barToggle")
        onPressed: Screens.runShortcut("barToggle", "", "shortcut")
    }

    /** Super+Ctrl+E (F8, 2026-11-27): Edge encendido o apagado en el monitor enfocado (con la barra, Bar-Edge). */
    GlobalShortcut {
        appid: root.appId
        name: "dockToggle"
        description: Keybinds.description("dockToggle")
        onPressed: Screens.runShortcut("dockToggle", "", "shortcut")
    }

    GlobalShortcut {
        appid: root.appId
        name: "wallRandom"
        description: Keybinds.description("wallRandom")
        onPressed: Screens.runShortcut("wallRandom", "", "shortcut")
    }

    GlobalShortcut {
        appid: root.appId
        name: "keepAwake"
        description: Keybinds.description("keepAwake")
        onPressed: Screens.runShortcut("keepAwake", "", "shortcut")
    }
}
