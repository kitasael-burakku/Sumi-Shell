pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

/**
 * Importar y exportar el calendario local (2026-10-28), desde Calendar UI. Estado de vista;
 * el trabajo lo hace `scripts/calendar-store.py` por la cola de `CalendarStore`.
 *
 *   · **Export**: un .ics NUEVO (nunca sobrescribe) con todos los eventos locales, sus
 *     repeticiones, excepciones y avisos. Por defecto en el HOME con la fecha.
 *   · **Import** de un .ics o **de calcurse** (lo que exporta `calcurse --export=ical`):
 *     siempre en dos pasos. La vista previa dice qué entraría, qué ya está (importado
 *     antes: no se duplica) y qué no se admite y por qué; importar exige la huella del
 *     contenido visto (si cambió, hay que volver a previsualizar) y deja antes una copia de
 *     la base. calcurse y el archivo de origen nunca se modifican.
 */
Singleton {
    id: root

    property bool open: false
    property string exportPath: ""
    property string importPath: ""
    property bool busy: false
    /** { source, digest, newCount, new: [títulos], duplicates, unsupported: [{summary, reason}], unsupportedCount, request } */
    property var preview: null
    property string result: ""
    property var error: null
    /** PRUEBAS: calcurse -D <dir> (el helper sólo lo admite en un banco). */
    property string testCalcurseDir: ""

    readonly property string home: Quickshell.env("HOME") || ""

    function pad(n) { return (n < 10 ? "0" : "") + n; }
    function defaultExport() {
        const d = new Date();
        return root.home + "/sumi-calendar-" + d.getFullYear() + "-" + root.pad(d.getMonth() + 1) + "-" + root.pad(d.getDate()) + ".ics";
    }
    function expand(p) {
        const t = String(p || "").trim();
        return t.indexOf("~/") === 0 ? root.home + t.substring(1) : t;
    }

    function nextName(path) {
        const m = /-(\d+)\.ics$/.exec(path);
        return m ? path.replace(/-\d+\.ics$/, "-" + (Number(m[1]) + 1) + ".ics") : path.replace(/\.ics$/, "-2.ics");
    }
    function show() {
        if (root.exportPath.length === 0) root.exportPath = root.defaultExport();
        root.error = null;
        root.result = "";
        root.open = true;
        return true;
    }
    function close() {
        if (root.busy) return false;
        root.open = false;
        root.preview = null;
        root.error = null;
        return true;
    }

    function run(req, then) {
        if (root.busy) return false;
        root.busy = true;
        root.error = null;
        root.result = "";
        CalendarStore.submit(req, function (r) {
            root.busy = false;
            if (!r.ok) { root.error = r.error || { code: "internal", message: "The calendar helper failed" }; return; }
            then(r);
        });
        return true;
    }

    function exportNow() {
        const path = root.expand(root.exportPath);
        return root.run({ op: "export", path: path }, function (r) {
            root.result = "Exported " + r.events + (r.events === 1 ? " event to " : " events to ") + r.path;
            root.exportPath = root.nextName(r.path);   // ése ya existe: el siguiente propone otro
        });
    }
    function previewRequest(req) {
        root.preview = null;
        return root.run(Object.assign({ op: "import-preview" }, req), function (r) {
            root.preview = Object.assign({}, r, { request: req });
        });
    }
    function previewFile() { return root.previewRequest({ path: root.expand(root.importPath) }); }
    function previewCalcurse() {
        const req = { calcurse: true };
        if (root.testCalcurseDir.length > 0) req.calcurseDir = root.testCalcurseDir;
        return root.previewRequest(req);
    }
    function importNow() {
        if (!root.preview || root.preview.newCount === 0) return false;
        const p = root.preview;
        return root.run(Object.assign({ op: "import", digest: p.digest }, p.request), function (r) {
            root.preview = null;
            root.result = "Imported " + r.added + (r.added === 1 ? " event" : " events")
                + (r.duplicates > 0 ? " · " + r.duplicates + " already there" : "")
                + (r.unsupported > 0 ? " · " + r.unsupported + " not supported" : "");
        });
    }
    function discardPreview() { root.preview = null; return true; }

    function summary() {
        return { open: root.open, busy: root.busy, exportPath: root.exportPath, importPath: root.importPath,
                 preview: root.preview, result: root.result, error: root.error };
    }
}
