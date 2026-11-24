pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

/**
 * El catálogo de `sumi` y su ejecutor (rediseño 11B; futuresystem-CLIsurface).
 *
 * UN catálogo —nombres, descripciones, iconos y dónde acaba cada orden— y UN ejecutor, que usan
 * a la vez la paleta (Super+Ctrl+X), la pestaña Tasks del Dashboard y el mantenimiento del
 * Overview. Antes la paleta tenía su lista y lanzaba `diskbackup` en Kitty mientras el Dashboard
 * lo lanzaba por `Jobs`: dos ejecutores para lo mismo.
 *
 * Eran las diez acciones de la CLI. Desde la F3d-1 (portabilidad, 2026-10-06; HC-26) el catálogo es
 * las TAREAS DECLARADAS en tasks.json con `palette` (en el orden del archivo) más los cinco verbos
 * propios de la shell (theme, wall, mode, dashboard, menu). Sin tasks.json, sólo esos cinco. El
 * catálogo visible ES el conjunto de acciones ejecutables desde la interfaz; no se interpreta texto
 * libre. Las descargas de Wallhaven no son comandos: Tasks las sigue por id en su zona de trabajos.
 *
 *   runs  panel     corre en el shell y se sigue en Tasks (las tareas `runs: panel`)
 *         terminal  se entrega a la terminal del usuario (Apps.terminalArgv; hasta la F3e el valor
 *                   interno era «kitty»): sólo se sabe que se abrió («Opened in terminal»)
 *         surface  navega a una surface (`to`)
 *         menu     asoma la cara de iconos del island
 *
 * `run(id)` devuelve lo que la VISTA tiene que hacer después, porque la navegación y la
 * confirmación del diskbackup son de la vista:
 *   { ok, runs, to }   to = surface a la que ir ("tasks" para lo del panel, "" = cerrar)
 * Un `panel` NO arranca aquí: la vista que lo recibe (la capa Tasks, etapa B) pide la confirmación y
 * arranca por `Jobs`, que no admite dos del mismo tipo. `request(id, pantalla)` deja el encargo
 * para el Dashboard de esa pantalla, que lo recoge al abrirse (`take`).
 */
Singleton {
    id: root

    /** Los verbos de la shell: siempre están, con o sin tasks.json. */
    readonly property var shellVerbs: [
        { id: "theme",      glyph: "palette",      desc: "Visual profile picker",             runs: "surface", to: "theme" },
        { id: "wall",       glyph: "wallpaper",    desc: "Wallpaper strip",                   runs: "surface", to: "wallpaper" },
        { id: "mode",       glyph: "monitor",      desc: "Desktop mode, in Dashboard → Performance", runs: "surface", to: "performance" },
        { id: "dashboard",  glyph: "info",         desc: "System control center",             runs: "surface", to: "dashboard" },
        { id: "login",      glyph: "lock",         desc: "Login screen (Sumi SDDM)",          runs: "surface", to: "login" },
        { id: "menu",       glyph: "keyboard",     desc: "The capsule icon menu",             runs: "menu" }
    ]
    /**
     * F3d-1: las tareas con `palette` (las del autor: update, diskbackup, clean, health y doctor;
     * dotbackup no sale aquí) y después los verbos. `runs`: panel · terminal (la del usuario; hasta la
     * F3e se llamaba «kitty») · surface · menu.
     */
    readonly property var catalog: {
        const out = [];
        for (const t of Tasks.tasks) {
            if (!t.palette) continue;
            out.push({ id: t.id, glyph: t.glyph || "cog", desc: t.desc, runs: t.runs, task: t });
        }
        return out.concat(root.shellVerbs);
    }
    /** Pruebas (IPC `commandsTestUnavailable`): el catálogo «no está disponible». */
    property bool testUnavailable: false
    readonly property bool available: !root.testUnavailable && root.catalog.length > 0

    function get(id) { return root.catalog.find(c => c.id === id) || null; }
    /** F2d: por qué no se puede aquí ("" = sí). Las que abren una surface o el menú, siempre. */
    function whyNot(id) {
        const c = root.get(id);
        return c && (c.runs === "panel" || c.runs === "terminal") ? Jobs.whyNot(id) : "";
    }

    /** Dónde acaba, en palabras (la etiqueta de cada fila). */
    function whereText(c) {
        if (root.whyNot(c.id).length > 0) return "Unavailable";      // F2d
        return c.runs === "panel" ? "In the panel" : c.runs === "terminal" ? Apps.terminalLabel      // F3b
             : c.runs === "menu" ? "Menu" : "Surface";
    }
    function whereLong(c) {
        const why = root.whyNot(c.id);
        if (why.length > 0) return "Unavailable · " + why;
        return c.runs === "panel" ? "Runs in the shell · follow it in Tasks"
             : c.runs === "terminal" ? "Opens in " + Apps.terminalLabel + " · the shell only knows the window opened"
             : c.runs === "menu" ? "Shows the capsule icon menu" : "Opens a surface";
    }

    /**
     * La búsqueda: nombre o una palabra de la descripción. Distingue los tres vacíos:
     *   unavailable  no hay catálogo (nunca debería pasar: es fijo)
     *   nomatch      hay catálogo y la búsqueda no coincide con nada
     *   ok           filas (con la búsqueda vacía, todas)
     */
    function filter(query) {
        if (!root.available) return { state: "unavailable", rows: [] };
        const q = String(query || "").trim().toLowerCase().replace(/^sumi\s+/, "");
        const rows = q.length === 0 ? root.catalog
            : root.catalog.filter(c => c.id.indexOf(q) >= 0 || c.desc.toLowerCase().indexOf(q) >= 0);
        return { state: rows.length > 0 ? "ok" : "nomatch", rows: rows };
    }

    /** El ejecutor. Ver la cabecera para lo que devuelve. */
    function run(id) {
        const c = root.get(id);
        if (!c || !root.available) return { ok: false, runs: "", to: "" };
        const why = root.whyNot(id);
        if (why.length > 0) return { ok: false, runs: c.runs, to: "", reason: why };
        switch (c.runs) {
        case "surface": return { ok: true, runs: c.runs, to: c.to };
        case "menu": return { ok: true, runs: c.runs, to: "peek" };
        case "panel": return { ok: true, runs: c.runs, to: "tasks" };
        }
        // terminal: la misma orden que teclearías. `-l` para el PATH y las funciones de fish.
        // `update` va por Updates (sysupdate + refrescar la caché de pendientes); todos dejan
        // «Opened in terminal» en la actividad, nunca un resultado inventado.
        if (c.task && c.task.role === "system-upgrade") {
            Updates.update();
        } else {
            // clean del autor (11C): pregunta antes de borrar y termina, así que su orden se pausa
            Jobs.launchTerminal(id, root.terminalArgvOf(id));
        }
        root.lastRun = { id: id, at: Date.now() };
        return { ok: true, runs: c.runs, to: "" };
    }
    /**
     * F3b → F3d-1: la orden de una tarea de terminal, en la terminal del usuario. Era
     * `kitty --title sumi-<id> -e fish -lc "sumi <id>; read …"` fijo; ahora es el argv y el
     * título de la tarea (los del autor, iguales). null si no hay tal tarea. La usan `run` y el verbo
     * de prueba `terminalArgv`.
     */
    function terminalArgvOf(id) {
        const t = Tasks.byId(id);
        return t ? Apps.terminalArgv(t.argv, { title: t.title || "" }) : null;
    }
    /** El último lanzamiento a terminal (para el detalle de Tasks). */
    property var lastRun: ({})
    function lastOpened(id) {
        const e = Activity.entries.find(x => x.kind === id && x.result === "opened");
        return e ? e.at : 0;
    }

    // ---- encargos para el Dashboard de una pantalla ------------------------------------------
    property var pending: ({})
    function request(id, screen) {
        const p = Object.assign({}, root.pending);
        p[screen || ""] = { id: id, at: Date.now() };
        root.pending = p;
    }
    /** El Dashboard de `screen` lo recoge una vez (caduca a los 10 s: un encargo viejo no se ejecuta). */
    function take(screen) {
        const e = root.pending[screen || ""];
        if (!e) return "";
        const p = Object.assign({}, root.pending);
        delete p[screen || ""];
        root.pending = p;
        return Date.now() - e.at < 10000 ? e.id : "";
    }
}
