pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Resultado de `minimaru health` y `minimaru doctor` (Fase 10.d).
 *
 * Los dos son herramientas de terminal (273 y ~140 líneas, TUI con `_rui_pause`)
 * — se quedan en la CLI. Lo que el dashboard muestra es su **resultado**: cuándo
 * corrieron y cuántos hallazgos, leído de un resumen que cada uno deja en
 * `~/.cache/minimaru-{health,doctor}-summary` (`epoch|hallazgos[|desconocidos]`).
 * Sin sondeo: `FileView.watchChanges`.
 *
 * F3d-1 (portabilidad, 2026-10-06; HC-28): ya no son dos archivos fijos. Cada tarea de tasks.json con
 * `summary` declara el suyo (las del autor: health y doctor, los mismos archivos); sin tareas, nada
 * que leer. (F3d-2: ya sin las propiedades fijas `health` y `doctor`.)
 */
Singleton {
    id: root

    /** Pruebas (IPC `issuesTest checks <dir>`, 11A-2): otra carpeta de resúmenes (mismo nombre de archivo); "" = la real. */
    property string testDir: ""

    readonly property var empty: ({ ran: 0, findings: -1, unknown: 0 })
    /** id de tarea → { ran: epoch, findings: n (-1 = nunca), unknown: n } */
    property var results: ({})

    function of(id) { return root.results[id] || root.empty; }

    /** Las tareas que dejan resumen, con la ruta que se lee de verdad. */
    readonly property var watched: {
        const out = [];
        for (const t of Tasks.tasks) {
            if (!t.summary) continue;
            const base = t.summary.replace(/^.*\//, "");
            out.push({ id: t.id, path: root.testDir.length > 0 ? root.testDir + "/" + base : t.summary });
        }
        return out;
    }

    function _parse(s) {
        var p = String(s).trim().split("|");
        return {
            ran: parseInt(p[0], 10) || 0,
            findings: p.length > 1 ? (parseInt(p[1], 10) || 0) : -1,
            unknown: p.length > 2 ? (parseInt(p[2], 10) || 0) : 0
        };
    }
    function put(id, v) {
        const next = Object.assign({}, root.results);
        next[id] = v;
        root.results = next;
    }

    /** "2h" / "3d" / "now" / "" (nunca). */
    function ago(epoch) {
        if (!epoch || epoch <= 0) return "";
        var d = Math.floor(Date.now() / 1000) - epoch;
        if (d < 0) return "now";
        if (d < 90) return "now";
        if (d < 5400) return Math.round(d / 60) + "m";
        if (d < 172800) return Math.round(d / 3600) + "h";
        return Math.round(d / 86400) + "d";
    }

    Instantiator {
        model: root.watched
        delegate: FileView {
            required property var modelData
            path: modelData.path
            watchChanges: true
            // como antes (F3d-2): la lectura al crearse es síncrona; si no, tras una recarga el Overview
            // decía «has not run yet» un instante antes de leer el resumen
            blockLoading: true
            printErrors: false
            onLoaded: root.put(modelData.id, root._parse(text()))
            onLoadFailed: root.put(modelData.id, root.empty)
            onFileChanged: reload()
        }
    }

    function summary() {
        return { results: root.results, watched: root.watched };
    }
}
