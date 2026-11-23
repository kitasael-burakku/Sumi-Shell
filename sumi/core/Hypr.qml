pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import "../services"

/**
 * The only door to Hyprland. Reads the Quickshell models by binding and never
 * builds dispatcher strings from free text (ADR-2, ADR-6).
 */
Singleton {
    id: root

    /** Name of the focused monitor, "" while the models are still empty. */
    readonly property string focusedName: Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""

    /** F5a: el dialecto de la config (lua|hyprlang|unknown|pending). Leerlo aquí crea HyprCtl al arrancar y su sonda contesta antes del primer clic. */
    readonly property string configDialect: HyprCtl.dialect

    /**
     * La distribución de teclado cambió (2026-09-24). Sustituye a
     * `hypr/scripts/kb-layout-notify.py` y su servicio: aquel popup era una
     * notificación y, aun reemplazándose por el hint `synchronous`, entraba al
     * centro y contaba como no leída. Ahora lo dice el island (core/Osd).
     *
     * Hyprland emite `activelayout>>TECLADO,Distribución` POR DISPOSITIVO, así
     * que un Alt+Shift con varios teclados declarados llega varias veces: se
     * deduplica por nombre. Se corta en la PRIMERA coma, no en la última: los
     * nombres de teclado de Hyprland no llevan comas y los de xkb sí pueden
     * («English (US, intl., with dead keys)»).
     */
    property string keyboardLayout: ""

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name !== "activelayout")
                return;
            const data = event.data;
            const comma = data.indexOf(",");
            /**
             * Los teclados VIRTUALES no cuentan (decidido por el usuario, 8C-2): `wtype` crea
             * `hl-virtual-keyboard-wtype` y Hyprland anuncia para él la distribución «error»
             * (medido: `activelayout>>hl-virtual-keyboard-wtype,error`), y el island decía
             * «ERR · error». Lo mismo haría cualquier otro teclado virtual (ydotool, escritorio
             * remoto, teclado en pantalla): no es la distribución de quien escribe.
             */
            if (data.indexOf("hl-virtual-keyboard") === 0)
                return;
            const layout = (comma >= 0 ? data.slice(comma + 1) : "").trim();
            if (layout.length === 0 || layout === root.keyboardLayout)
                return;
            root.keyboardLayout = layout;   // su señal de cambio es el aviso
        }
    }

    /**
     * Resolve a monitor argument (IPC, scripts) to a real screen name:
     * explicit name → focused monitor → first screen. Never returns "" while
     * at least one screen exists, so an early IPC call cannot fall into the
     * "open on no monitor" hole Ukishima has.
     */
    /**
     * La pantalla de un atajo o de un verbo IPC sin monitor (DESIGN §4): la enfocada,
     * si de verdad existe (en plena desconexión Hyprland aún puede nombrar una que ya
     * se fue) → la preferida (`Settings.preferredDisplay`, conector o «modelo|serie»)
     * → la primera utilizable. Nunca «ninguna» mientras quede una salida.
     */
    function resolveScreen(name) {
        if (name && name.length > 0)
            return name;
        const sc = Quickshell.screens;
        const has = (n) => { for (let i = 0; i < sc.length; i++) if (sc[i].name === n) return true; return false; };
        if (root.focusedName.length > 0 && has(root.focusedName))
            return root.focusedName;
        const pref = Settings.preferredDisplay;
        if (pref.length > 0)
            for (let i = 0; i < sc.length; i++)
                if (sc[i].name === pref || Settings.monitorId(sc[i]) === pref)
                    return sc[i].name;
        return sc.length > 0 ? sc[0].name : "";
    }

    function monitor(name) {
        const m = Hyprland.monitors.values;
        for (let i = 0; i < m.length; i++)
            if (m[i] && m[i].name === name)
                return m[i];
        return null;
    }

    /**
     * True while the active workspace of `name` reports a fullscreen client.
     * Reads the typed property rather than digging through `lastIpcObject`.
     * Meant to be called from a binding: every read here registers as a
     * dependency of the caller.
     */
    function hasFullscreen(name) {
        const m = root.monitor(name);
        const ws = m ? m.activeWorkspace : null;
        return ws ? ws.hasFullscreen : false;
    }

    /**
     * Focus a workspace by id. The id is checked before it reaches the
     * dispatcher: everything the shell sends to Hyprland is built from
     * validated values, never from free text (ADR-2, SECURITY.md M1).
     */
    function focusWorkspace(id) {
        const n = Number(id);
        if (!Number.isInteger(n) || n < 1) {
            console.warn("hypr: refusing to focus workspace", JSON.stringify(id));
            return false;
        }
        // F5a: la forma la da el dialecto de la config (HyprCtl); con hyprland.conf el `hl.dsp.…` no hacía nada
        return HyprCtl.dispatch("focusWorkspace", { workspace: n });
    }
}
