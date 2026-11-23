pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland

/**
 * Ventanas del escritorio, para el minimizador (Fase 10.b).
 *
 * UNA SOLA FUENTE: `Hyprland.toplevels` (QS-FUNC-001, 2026-09-14).
 *
 * Hasta aqui eran dos: los `Toplevel` de `ToplevelManager` (titulo, appId,
 * foco) y un `hyprctl -j clients` puntual, unica fuente de la direccion y del
 * workspace, emparejados por `class`+`title`. Dos ventanas con clase Y titulo
 * identicos podian cruzar direcciones -- minimizar actuaba sobre la otra --,
 * el workspace no se movia con la superficie abierta y cada cambio de la lista
 * lanzaba un proceso. `ToplevelManager` no da workspace ni direccion, pero
 * `HyprlandToplevel` si, y trae el `Toplevel` de Wayland ya emparejado en
 * `.wayland`: nada que adivinar.
 *
 * Medido el 2026-09-14 con sonda `qs -p`, sin llamar a `refreshToplevels()`
 * (ADR-6 lo prohibe al arrancar):
 *   · poblado a 100-200 ms, con `lastIpcObject` ya relleno;
 *   · `address` llega SIN `0x` ("55a409557460"); el dispatcher y la validacion
 *     lo quieren con el, asi que se antepone aqui;
 *   · `HyprlandToplevel.activated` decia `false` con la ventana enfocada y
 *     `wayland.activated` decia `true`: el foco se lee del handle de Wayland.
 *
 * Se listan solo las que tienen `.wayland` -- el mismo conjunto que daba
 * `ToplevelManager` antes, ventanas de verdad.
 *
 * MINIMIZAR/RESTAURAR se hace por Hyprland, no por `Toplevel.setMinimized()`:
 * en este compositor esa peticion foreign-toplevel ni mueve la ventana ni
 * marca el flag (medido: `minimized` sigue `false` con la ventana en
 * `special:minimized`). Minimizar = mover a `special:minimized`; restaurar =
 * traer al workspace activo y enfocar. Identico a `window-switcher.sh`.
 *
 * Sin proceso y sin reclamacion: el modelo lo mantiene el socket de eventos de
 * Hyprland que el shell ya escucha para los workspaces. Una ventana que otra
 * herramienta mueva con el minimizador abierto se refleja al momento.
 */
Singleton {
    id: root

    readonly property string minimizedWs: "special:minimized"

    readonly property var hyprWindows: Hyprland.toplevels.values

    /** Hay datos. Con cero ventanas no llega nunca: la superficie añade su `settled`. */
    readonly property bool ready: root.hyprWindows.length > 0

    /**
     * ORDEN DE USO RECIENTE (QS-FUNC-012c). Dentro de cada seccion, la ultima
     * enfocada primero, con `focusHistoryID` (0 = la ultima). Antes era
     * alfabetico por `appId`, que no es lo que quiere un conmutador.
     *
     * `focusHistoryID` vive en `lastIpcObject`, que Hyprland solo renueva con
     * `refreshToplevels()`: los eventos mueven workspace y titulo, no el orden.
     * Por eso `refreshOrder()` se llama al abrir el minimizador y el lanzador --
     * no al arrancar (ADR-6) --, y mientras estan abiertos el foco no cambia:
     * son modales.
     */
    function refreshOrder() { Hyprland.refreshToplevels(); }

    readonly property var windows: {
        var out = [];
        var hs = root.hyprWindows;
        for (var i = 0; i < hs.length; i++) {
            var w = hs[i];
            var t = w ? w.wayland : null;
            if (!t || !w.address)
                continue;
            var ws = w.workspace ? String(w.workspace.name) : "";
            var ipc = w.lastIpcObject || {};
            out.push({
                handle: t,
                hypr: w,
                appId: String(t.appId),
                entryId: root.entryIdOf(t.appId),
                title: String(t.title),
                address: "0x" + String(w.address),
                workspace: ws,
                monitor: w.monitor ? String(w.monitor.name) : "",
                minimized: ws === root.minimizedWs,
                activated: t.activated === true,
                fullscreen: t.fullscreen === true,
                maximized: t.maximized === true,
                focusHistory: typeof ipc.focusHistoryID === "number" ? ipc.focusHistoryID : 1000000
            });
        }
        out.sort(function (a, b) {
            if (a.minimized !== b.minimized)
                return a.minimized ? -1 : 1;
            if (a.focusHistory !== b.focusHistory)
                return a.focusHistory - b.focusHistory;
            var c = a.appId.toLowerCase().localeCompare(b.appId.toLowerCase());
            return c !== 0 ? c : a.title.toLowerCase().localeCompare(b.title.toLowerCase());
        });
        return out;
    }

    /**
     * La app (`DesktopEntry.id`) de una ventana, para que el lanzador sepa que
     * esta abierto (QS-FUNC-012a). La clase no siempre es el id: VSCodium es
     * `codium` y su `.desktop` `vscodium`; `heuristicLookup` lo resuelve.
     */
    function entryIdOf(appId) {
        const id = String(appId || "");
        if (id.length === 0)
            return "";
        void DesktopEntries.applications.values.length;   // reevaluar cuando lleguen
        const e = DesktopEntries.heuristicLookup(id);
        return e ? String(e.id) : "";
    }

    /** Ventanas de una app, la ultima enfocada primero (minimizadas incluidas). */
    function windowsFor(entryId) {
        const id = String(entryId || "");
        if (id.length === 0)
            return [];
        return root.windows.filter(function (w) { return w.entryId === id; })
            .sort(function (a, b) { return a.focusHistory - b.focusHistory; });
    }

    readonly property var minimizedWindows: root.windows.filter(function (w) { return w.minimized; })
    readonly property var openWindows: root.windows.filter(function (w) { return !w.minimized; })
    readonly property var activeWindow: {
        var ws = root.windows;
        for (var i = 0; i < ws.length; i++)
            if (ws[i].activated) return ws[i];
        return null;
    }

    /**
     * Icono de una ventana; "" si no resuelve (el minimizador pinta entonces su
     * glifo). La CLASE no es el nombre del icono: VSCodium es `codium` y su
     * icono `vscodium`; Zen es `zen` y su icono `zen-browser`. El `.desktop` lo
     * sabe, asi que se pregunta primero a `heuristicLookup` y solo despues a la
     * clase tal cual. Antes esto devolvia `image://icon/codium`, que no existe:
     * el cuadro morado y negro (ver `Apps.iconSource`).
     */
    function iconFor(appId) {
        const id = String(appId || "");
        if (id.length === 0)
            return "";
        // Las entradas llegan ~1 s tarde: leerlas aqui hace que el binding que
        // llama se reevalue cuando lleguen.
        void DesktopEntries.applications.values.length;
        const e = DesktopEntries.heuristicLookup(id);
        return (e ? Apps.iconSource(e.icon, "") : "")
            || Apps.iconSource(id, "")
            || Apps.iconSource(id.toLowerCase(), "");
    }

    // --- acciones ---------------------------------------------------
    readonly property var _addrRe: /^0x[0-9a-f]+$/

    function _validAddr(a) {
        if (typeof a === "string" && root._addrRe.test(a))
            return true;
        console.warn("toplevels: bad window address", JSON.stringify(a));
        return false;
    }

    function minimize(w) {
        if (!w || !root._validAddr(w.address))
            return false;
        // F5a: forma del dialecto (HyprCtl); `hl.dsp.window.move` con Lua, `movetoworkspacesilent` con hyprlang
        return HyprCtl.dispatch("moveSilent", { workspace: root.minimizedWs, address: w.address });
    }

    function restore(w) {
        if (!w || !root._validAddr(w.address))
            return false;
        var mon = Hyprland.focusedMonitor;
        var aws = mon ? mon.activeWorkspace : null;
        var id = aws ? Number(aws.id) : NaN;
        if (!Number.isInteger(id) || id < 1) {
            console.warn("toplevels: no active workspace to restore into");
            return false;
        }
        return HyprCtl.dispatch("moveSilent", { workspace: id, address: w.address })
            && HyprCtl.dispatch("focusWindow", { address: w.address });
    }

    /** Enter sobre una fila: minimizar si esta abierta, restaurar si esta minimizada. */
    function toggle(w) {
        return (w && w.minimized) ? root.restore(w) : root.minimize(w);
    }

    /**
     * Enfocar una ventana — el modi `window` de rofi (10.c.3). Si esta
     * minimizada es un restaurar; si esta abierta, `hl.dsp.focus` trae el foco
     * y con el la ventana al frente y a su workspace si estaba en otro (es lo
     * que hace `focuswindow` de Hyprland).
     */
    function focus(w) {
        if (!w || !root._validAddr(w.address))
            return false;
        if (w.minimized)
            return root.restore(w);
        return HyprCtl.dispatch("focusWindow", { address: w.address });
    }

    /** Para `status()` del IPC y para P2. */
    function summary() {
        return {
            ready: root.ready,
            count: root.windows.length,
            minimized: root.minimizedWindows.length,
            open: root.openWindows.length,
            active: root.activeWindow ? root.activeWindow.appId : "",
            windows: root.windows.map(function (w) {
                return {
                    appId: w.appId, title: w.title, address: w.address,
                    workspace: w.workspace, monitor: w.monitor,
                    minimized: w.minimized, activated: w.activated,
                    entryId: w.entryId, focusHistory: w.focusHistory
                };
            })
        };
    }
}
