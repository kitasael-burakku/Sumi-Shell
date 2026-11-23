pragma Singleton
import QtQuick
import Quickshell
import "../services"
import "../theme"

/**
 * Registry of live Screen objects, keyed by connector name. Screens register
 * on completion and unregister on destruction, so a hot-unplugged monitor
 * never leaves a dangling entry (Ukishima's Surfaces registry only appends).
 */
Singleton {
    id: root

    property var list: []

    function register(s) {
        if (root.list.indexOf(s) >= 0)
            return;
        root.list = root.list.concat([s]);
    }

    function unregister(s) {
        root.list = root.list.filter(function (x) { return x !== s; });
    }

    // ---- operaciones globales: quién las presenta (fase 6D) --------------------

    /** Nombre legible de la operación para los avisos (UI en inglés). */
    function opLabel(o) {
        if (o.kind === "polkit") return "Authentication";
        if (o.kind === "job") return "Job";
        if (o.kind === "wifi") return "Wi-Fi sign-in";
        if (o.kind === "theme-preview") return "Theme preview";
        if (o.kind === "system-test") return "Display test";
        return "Operation";
    }

    /**
     * El control pasó a otra pantalla. La vista vieja se libera SIN cancelar (la
     * superficie comprueba `Operations.owns` antes de hacerlo) y lo dice en su
     * island. Forzado: el control ya no es suyo, no hay nada que proteger allí.
     */
    Connections {
        target: Operations
        function onMoved(id, from, to) {
            const o = Operations.get(id);
            const old = root.byName(from);
            if (!o || !old) return;
            if (old.open === o.surface) old.closeSurface(true);
            old.announce(root.opLabel(o) + " moved to " + to, "monitor", "info");
        }
    }

    /**
     * 12B: una restauración del tema que falla después de cerrar Visual Profiles no se pierde
     * en silencio: la dice el island de la pantalla que llevaba la prueba (o la enfocada).
     */
    Connections {
        target: ThemePreview
        function onRestoreFailed(screen) {
            const sc = root.byName(screen) || root.resolve("");
            if (sc) sc.announce("Theme not restored · retry in Visual profiles", "palette", "danger");
        }
    }

    /**
     * 14B: el resultado de una prueba de sistema lo dice el island de la pantalla que la lanzó (o
     * la enfocada, si ya no está o terminó mientras el shell se reiniciaba).
     */
    Connections {
        target: SystemTest
        function onFinished(state, reason, screen) {
            const sc = root.byName(screen) || root.resolve("");
            if (sc) sc.announce(SystemTest.resultText(state, reason),
                                !SystemTest.last ? "monitor" : SystemTest.last.kind === "network" ? "ethernet"
                                    : SystemTest.last.kind === "audio-profile" ? "speaker" : "monitor",
                                state === "kept" ? "info" : state === "failed" ? "danger" : "warn");
        }
    }
    /**
     * Un monitor propietario desapareció: su control pasa a una salida utilizable
     * (la cadena de siempre: enfocada, preferida, cualquiera) y se abre allí si
     * estaba abierto… o siempre, si la operación espera al usuario: una petición
     * de polkit sin nadie delante dejaría a `pkexec` esperando para siempre.
     */
    onListChanged: Qt.callLater(root.rehome)
    function rehome() {
        if (KeybindsUi.screen.length > 0 && !root.byName(KeybindsUi.screen)) {
            const ks = root.list.length > 0 ? root.resolve("") : null;
            if (KeybindsUi.open && ks) KeybindsUi.screen = ks.name;
            else { KeybindsUi.close(false); KeybindsUi.screen = ""; }
        }
        // Settings UI (2026-11-07): igual que la ayuda de atajos; la vista viaja en `SettingsUi.context`
        if (SettingsUi.screen.length > 0 && !root.byName(SettingsUi.screen)) {
            const ss = root.list.length > 0 ? root.resolve("") : null;
            if (SettingsUi.open && ss) SettingsUi.screen = ss.name;
            else { SettingsUi.close(false, true); SettingsUi.screen = ""; }
        }
        // Login screen (2026-11-23): la ventana sigue en otro monitor; con pkexec esperando no se cierra (LoginUi)
        if (LoginUi.screen.length > 0 && !root.byName(LoginUi.screen)) {
            const ls = root.list.length > 0 ? root.resolve("") : null;
            if (LoginUi.open && ls) LoginUi.screen = ls.name;
            else { LoginUi.close(false); if (!LoginUi.open) LoginUi.screen = ""; }
        }
        if (root.list.length === 0) { CalendarUi.close(); CalendarUi.screen = ""; return; }
        if (CalendarUi.screen.length > 0 && !root.byName(CalendarUi.screen)) {
            const sc = root.resolve("");
            if (CalendarUi.open && sc) CalendarUi.show(sc.name, null);
            else CalendarUi.screen = "";
        }
        const names = root.list.map(sc => sc.name);
        for (const o of Operations.orphans(names)) {
            const sc = root.resolve("");
            if (!sc) return;
            const from = o.owner;
            Operations.claim(o.id, sc.name);
            // 12B: una preview de tema sin vista no tiene dónde confirmarse ni revertirse
            if ((o.state === "needs-input" || o.kind === "theme-preview") && sc.open !== o.surface) {
                if (o.key.length > 0) sc.openSurfaceWith(o.surface, o.key);
                else sc.openSurface(o.surface);
            }
            sc.announce(root.opLabel(o) + " moved here from " + from, "monitor", "info");
        }
    }

    /**
     * Dónde presentar una petición que llega sola (polkit, 6D): la pantalla
     * enfocada, salvo que tenga una edición sensible abierta (una clave sin enviar);
     * entonces otra sin guardia. Si todas la tienen, la enfocada, que preguntará.
     * Antes la enfocada preguntaba siempre, y con «Keep editing» la petición se
     * quedaba sin vista y `pkexec` esperando.
     */
    function pickForRequest() {
        const focused = root.resolve("");
        if (focused && !focused.isGuarded()) return focused;
        for (const sc of root.list)
            if (sc && !sc.isGuarded()) return sc;
        return focused;
    }

    function byName(name) {
        for (let i = 0; i < root.list.length; i++)
            if (root.list[i] && root.list[i].name === name)
                return root.list[i];
        return null;
    }

    /** Screen for an IPC monitor argument, with the Hypr fallback chain. */
    function resolve(mon) {
        return root.byName(Hypr.resolveScreen(mon));
    }

    /*
     * Acciones compartidas. Viven aqui, y no en core/Ipc.qml, porque desde la
     * Fase 9.a tienen DOS llamadores: el IpcHandler y los GlobalShortcut de
     * core/Shortcuts.qml. Duplicarlas era garantizar que un dia divergieran.
     * Devuelven false y avisan en vez de fallar en silencio, igual que el IPC.
     */

    /**
     * LA CARA DE LA PIEZA DE RED (fase 8B-1), la misma en todas las pantallas:
     * `{ glyph, tone, color, label }`. `tone` es unknown · ok · warn · off, y el halo
     * lleva el MISMO color que el glifo (futureDinamicIslandidlesurface.md):
     *
     *   unknown  los datos aún no llegaron: neutro, nunca una desconexión falsa
     *   ok       conectado (el cable manda si hay los dos: `Net.kind`)
     *   warn     conectando, o conectado con conectividad limitada/portal
     *   off      sin conexión, Wi-Fi apagado o sin adaptador (glifos de `Net.icon`)
     *
     * `netFaceTest` (IPC `islandTestNet`, sólo pruebas) falsea ESTA cara y nada más: la
     * red real no se toca.
     */
    property string netFaceTest: ""
    readonly property var netFaceTests: ({
        unknown: { glyph: "wifi", tone: "unknown", label: "Network" },
        wired: { glyph: "ethernet", tone: "ok", label: "Ethernet connected" },
        "wifi-1": { glyph: "wifi-1", tone: "ok", label: "Wi-Fi connected" },
        "wifi-4": { glyph: "wifi-4", tone: "ok", label: "Wi-Fi connected" },
        limited: { glyph: "wifi-alert", tone: "warn", label: "Limited connectivity" },
        connecting: { glyph: "wifi-none", tone: "warn", label: "Connecting" },
        none: { glyph: "wifi-none", tone: "off", label: "Disconnected" },
        off: { glyph: "wifi-off", tone: "off", label: "Wi-Fi off" },
        nohw: { glyph: "net-off", tone: "off", label: "No network adapter" }
    })
    readonly property var netFace: {
        let f;
        if (root.netFaceTest.length > 0 && root.netFaceTests[root.netFaceTest]) {
            f = root.netFaceTests[root.netFaceTest];
        } else if (!Net.ready) {
            f = { glyph: "wifi", tone: "unknown", label: "Network" };
        } else if (Net.busy) {
            f = { glyph: Net.icon.length > 0 ? Net.icon : "wifi-none", tone: "warn", label: "Connecting" };
        } else if (Net.connected) {
            const what = Net.kind === "wired" ? "Ethernet" : ("Wi-Fi " + Net.ssid);
            f = Net.degraded ? { glyph: Net.icon, tone: "warn", label: what + ": limited connectivity" }
                             : { glyph: Net.icon, tone: "ok", label: what + " connected" };
        } else {
            f = { glyph: Net.icon.length > 0 ? Net.icon : "wifi-none", tone: "off",
                  label: Net.icon === "wifi-off" ? "Wi-Fi off"
                       : (Net.icon === "net-off" ? "No network adapter" : "Disconnected") };
        }
        const color = f.tone === "ok" ? Theme.ok
            // naranja fijo (decisión del usuario, 8B-1): el `warn` de la paleta es tertiary y
            // con algunos fondos sale azul, que no se lee como aviso
            : f.tone === "warn" ? Theme.netWarn
            : f.tone === "off" ? Theme.danger
            : Theme.hair;
        return { glyph: f.glyph, tone: f.tone, label: f.label, color: color };
    }

    /**
     * Familia de una surface (9A): las tres de Settings son UNA para los accesos — el
     * engranaje se enciende con cualquiera, su atajo cierra cualquiera, y pasar de una a
     * otra conserva el origen del panel. Fuera de la familia, el nombre es su familia.
     */
    function familyOf(n) {
        const c = root.canonical(n);
        return c === "settingsTheme" || c === "settingsSystem" ? "settings" : c;
    }

    /**
     * Nombres retirados que siguen funcionando (9E-1): `media` se fundió en el Mixer, pero lo
     * siguen llamando Super+Ctrl+M (`sumiShell("media")`), el círculo de Música, la barra, el
     * IPC y scripts. Se resuelven aquí, en un solo sitio.
     */
    readonly property var aliases: ({ media: "mixer", performance: "dashboard" })
    /**
     * 11A-1: `performance` es una pestaña del Dashboard: el nombre por el que se llega decide la
     * pestaña inicial; `dashboard` a secas, Overview. `tasks` dejó de ser pestaña en la etapa B
     * (2026-11-09): es la ventana flotante de `core/TasksLayer` (`isTasks`).
     */
    readonly property var dashboardTabs: ({ dashboard: "overview", performance: "performance" })
    function isTasks(n) { return n === "tasks"; }
    /** La ventana Login screen (Sumi SDDM, 2026-11-23): `open/toggle login`, la paleta y el atajo `loginScreen`. */
    function isLogin(n) { return n === "login"; }
    function canonical(n) {
        const a = root.aliases[n];
        return a === undefined ? n : a;
    }

    function toggleSurfaceOn(name, mon, who) {
        const sc = root.resolve(mon);
        if (!sc) { console.warn(who, "toggle: no screen for", mon); return false; }
        if (!sc.hasSurface(name)) { console.warn(who, "toggle: unknown surface", name); return false; }
        return sc.toggleSurface(name);
    }

    /**
     * Settings UI independiente (2026-11-07): los tres nombres de Settings ya no son superficies del
     * island sino la ventana flotante (`SettingsUi`, `core/SettingsLayer`). Siguen valiendo en el IPC
     * `open/toggle/close`, el atajo, el engranaje y la paleta; cada uno empieza en su página inicial.
     */
    function isSettings(n) { return root.familyOf(n) === "settings"; }
    function settingsDefaultPath(n) {
        const c = root.canonical(n);
        return c === "settingsTheme" ? "theme" : c === "settingsSystem" ? "system" : "";
    }
    /** El contenido de la ventana de Settings si está abierta en esa pantalla (o null): IPC y pruebas. */
    function settingsItemOn(mon) {
        const sc = root.resolve(mon);
        if (!sc || !SettingsUi.open || SettingsUi.screen !== sc.name) return null;
        return SettingsUi.item();
    }

    /**
     * 9A: abrir Settings en `dest/página[/fila]` en la pantalla `mon` (IPC `settingsOpen`; desde
     * antes de la fase 11 también la tienda de Wallhaven, que no es una surface y no tiene host).
     * Settings UI: abre o trae la ventana flotante; `origin` ({from: superficie}) = Esc vuelve allí.
     * false si la ruta no existe (no enfoca otra fila en su lugar) o algo lo impide.
     */
    function settingsOpenOn(path, mon, origin) {
        const sc = root.resolve(mon);
        if (!sc) return false;
        const surf = ({ shell: "settings", theme: "settingsTheme", system: "settingsSystem" })[String(path).split("/")[0]];
        if (!surf) return false;
        return sc.showSettings(String(path), origin || null);
    }

    /**
     * Un enlace de Settings a una superficie del island (Wallpaper list, Networks, el Mixer…): se
     * abre ENCIMA de la ventana, que sigue debajo con su página. Esc la cierra y deja Settings
     * donde estaba (antes lo hacía la pila del host). `key`: la ficha que mira (wifi, servicio…).
     */
    function openFromSettings(mon, name, key) {
        const sc = root.resolve(mon);
        if (!sc || Lock.engaged) return false;
        return key && key.length > 0 ? sc.openSurfaceWith(name, key) : sc.openSurface(name);
    }
    /** Esc en Settings abierto desde una superficie del island (Configure…): se vuelve a ella. */
    Connections {
        target: SettingsUi
        function onReturnRequested(screen, origin) {
            const sc = root.byName(screen);
            if (sc && origin && origin.from && sc.open.length === 0) sc.openSurface(origin.from);
        }
    }

    /**
     * W3: «Show in library» desde la tienda de Wallhaven: Wallpaper List en `mon`, sin filtros y
     * con ese archivo enfocado (la tira queda encima de la tienda, que sigue abierta debajo).
     */
    function showInLibraryOn(path, mon) {
        const sc = root.resolve(mon);
        if (!sc) return false;
        if (sc.open !== "wallpaper" && !sc.openSurface("wallpaper")) return false;
        const it = sc.surfaceItem("wallpaper");
        if (!it) return false;
        it.showInLibrary(path);
        return true;
    }

    /**
     * La tienda de Wallhaven (Super+Ctrl+W, el IPC `whStore` y el botón de Wallpaper List): UNA
     * instancia. En la pantalla donde ya está, alterna; en otra, la trae (no abre una segunda).
     */
    function wallhavenOn(mon, who) {
        const sc = root.resolve(mon);
        if (!sc) { console.warn(who, "wallhaven: no screen for", mon); return false; }
        return WallhavenStore.toggle(sc.name);
    }

    /**
     * La UI de inspección de System Monitor (antes de la fase 12): Super+Ctrl+Y, los Details de la
     * surface, el Dashboard y el IPC `monitorUi`. UNA instancia: en su pantalla alterna (o cambia a
     * `section` si se pide otra), en otra pantalla la trae. `section` "" = la última vista.
     */
    function monitorOn(mon, section, who) {
        const sc = root.resolve(mon);
        if (!sc) { console.warn(who, "monitor: no screen for", mon); return false; }
        return MonitorUi.toggle(sc.name, section || "");
    }
    /**
     * La capa Tasks (etapa B del Dashboard): el IPC `tasksUi` y quien quiera abrirla con una tarea
     * elegida (`id`) y quizá arrancada (`start`). En otra pantalla la trae.
     */
    function tasksOn(mon, id, start, who) {
        const sc = root.resolve(mon);
        if (!sc) { console.warn(who, "tasks: no screen for", mon); return false; }
        return sc.showTasks(id || "", start === true);
    }
    /** Lo mismo, pero sólo abre (Details nunca cierra la UI si ya estaba en esa sección). */
    function monitorShowOn(mon, section, who) {
        const sc = root.resolve(mon);
        if (!sc) { console.warn(who, "monitor: no screen for", mon); return false; }
        return MonitorUi.show(sc.name, section || "");
    }

    /**
     * La Audio UI (antes de la fase 14): Super+Shift+A, los enlaces de la surface y de Settings y el
     * IPC `audioUi`. UNA instancia, igual que la del monitor: en su pantalla alterna (o cambia a
     * `section`), en otra pantalla la trae. `section` "" = la última vista.
     */
    function audioOn(mon, section, who) {
        const sc = root.resolve(mon);
        if (!sc) { console.warn(who, "audio: no screen for", mon); return false; }
        return AudioUi.toggle(sc.name, section || "");
    }
    /** Lo mismo, pero sólo abre (un enlace nunca cierra la UI si ya estaba en esa sección). */
    function audioShowOn(mon, section, who) {
        const sc = root.resolve(mon);
        if (!sc) { console.warn(who, "audio: no screen for", mon); return false; }
        return AudioUi.show(sc.name, section || "");
    }

    Connections {
        target: CalendarUi
        function onOpening() {
            // Agenda has one loaded range. Expanding hands ownership over to the wide view.
            for (const sc of root.list) if (sc.open === "calendar") sc.closeSurface(false);
        }
    }
    function calendarShowOn(mon, who) {
        const sc = root.resolve(mon);
        if (!sc || Lock.engaged) return false;
        return CalendarUi.show(sc.name, null);
    }
    function calendarOn(mon, who) {
        const sc = root.resolve(mon);
        if (!sc || Lock.engaged) return false;
        return CalendarUi.open && CalendarUi.screen === sc.name ? CalendarUi.close() : CalendarUi.show(sc.name, null);
    }

    /** Super+Ctrl+P (8C-1): island ⇄ barra persistente en el monitor enfocado. */
    function barToggleOn(mon, who) {
        const sc = root.resolve(mon);
        if (!sc) { console.warn(who, "barToggle: no screen for", mon); return false; }
        return sc.toggleBar();
    }

    function peekOn(mon, who) {
        const sc = root.resolve(mon);
        if (!sc) { console.warn(who, "peek: no screen for", mon); return false; }
        return sc.togglePin();
    }

    /**
     * Ayuda de atajos (2026-10-30): LO QUE HACE cada uno de los atajos globales (29 desde Super+F1), en un sitio. Lo llaman los
     * GlobalShortcut de core/Shortcuts.qml (who "shortcut") y el botón Open de la ayuda (who "keybinds"): la ayuda
     * ejecuta exactamente lo mismo que la tecla, sin simular pulsaciones. `mon` "" = la pantalla enfocada.
     */
    readonly property var shortcutSurfaces: ["launcher", "wallpaper", "recorder", "media", "settings", "system",
        "controlCenter", "calendar", "mixer", "web", "power", "clipboard", "emoji", "wifi", "bluetooth", "dashboard", "minimizer",
        "theme", "cli", "notifications", "tasks"]
    function runShortcut(name, mon, who) {
        switch (name) {
        case "wallhaven": return root.wallhavenOn(mon, who);
        case "monitor": return root.monitorOn(mon, "", who);
        case "audio": return root.audioOn(mon, "", who);
        case "calendarUi": return root.calendarOn(mon, who);
        case "loginScreen": return root.loginOn(mon, who);
        // F8d: sin gestor de usuario confirmado la fuente se niega (`Units.supported === false`); un árbol sin F8 (el
        // vivo del autor) no tiene la propiedad y abre como siempre. Una sola versión de este archivo para los dos.
        case "services": return Units.supported === false ? false : root.toggleSurfaceOn("services", mon, who);
        case "peek": return root.peekOn(mon, who);
        case "barToggle": return root.barToggleOn(mon, who);
        case "keybinds": return root.keybindsOn(mon, who);
        case "keepAwake": Session.toggleKeepAwake(); return true;
        case "wallRandom": {
            // F2c: sin vista que lo diga, el island explica por qué no hay fondo nuevo
            if (Wallpaper.applyWhy.length > 0) {
                const sc = root.resolve(mon);
                if (sc) sc.announce("Wallpaper unavailable · " + Wallpaper.applyWhy, "wallpaper", "warn");
                return false;
            }
            Wallpaper.random("all");
            return true;
        }
        }
        if (root.shortcutSurfaces.indexOf(name) !== -1) return root.toggleSurfaceOn(name, mon, who);
        console.warn(who, "shortcut: unknown action", name);
        return false;
    }
    /** Por qué una acción no se puede ejecutar ahora ("" = se puede); la ayuda lo enseña en vez de un botón muerto. */
    function shortcutWhyNot(name) {
        if (name === "services" && Units.supported === false) return "Needs a user service manager (systemd)";
        if (name === "wallRandom" && Wallpaper.applyWhy.length > 0) return Wallpaper.applyWhy;
        return "";
    }

    /** La ventana de ayuda de atajos: Settings → Shell → Interaction, el Launcher y el IPC `keybindsUi`. */
    function keybindsOn(mon, who) {
        const sc = root.resolve(mon);
        if (!sc || Lock.engaged) return false;
        return KeybindsUi.toggle(sc.name);
    }
    function keybindsShowOn(mon, who, origin) {
        const sc = root.resolve(mon);
        if (!sc || Lock.engaged) return false;
        return KeybindsUi.show(sc.name, origin || null);
    }
    Connections {
        target: KeybindsUi
        /** Abierta desde Settings: al cerrarla, Settings vuelve en la misma fila (Esc «vuelve», como entre surfaces). */
        function onReturnRequested(screen, origin) {
            if (origin && origin.path && root.byName(screen)) root.settingsOpenOn(origin.path, screen);
        }
    }

    /** La ventana Login screen (Sumi SDDM, 2026-11-23): Super+Ctrl+L, la paleta y el IPC `loginUi`. */
    function loginOn(mon, who) {
        const sc = root.resolve(mon);
        if (!sc || Lock.engaged) return false;
        return sc.loginHere ? LoginUi.close(false) : sc.showLogin("", null);
    }
    function loginShowOn(page, mon, who) {
        const sc = root.resolve(mon);
        if (!sc || Lock.engaged) return false;
        return sc.showLogin(page || "", null);
    }
    Connections {
        target: LoginUi
        /** Abierta desde Settings: Esc vuelve a Settings, a la fila «Open Login screen». */
        function onReturnRequested(screen, origin) {
            if (origin && origin.path && root.byName(screen)) root.settingsOpenOn(origin.path, screen);
        }
    }
}
