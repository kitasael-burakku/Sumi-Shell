pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/settings-schema.js" as Schema

/**
 * Importar y exportar las preferencias del shell (rediseño 12E, 2026-09-28;
 * futureSettingssurface §12 «Importar y exportar»).
 *
 *   Export  un JSON portable con los ajustes EXPORTABLES del catálogo (`export: false` no sale:
 *           sesión, integraciones, monitores, cuenta, ubicación, imágenes del lock) y, si se pide,
 *           tus presets. Las rutas de fondos van marcadas como dependencias locales. Nunca pisa un
 *           archivo: nombre con fecha en la carpeta personal.
 *   Import  se ANALIZA sin aplicar: formato, versión, cada id contra el catálogo (desconocidos,
 *           no importables e inválidos se enumeran y no se aplican), rutas locales comprobadas
 *           («Missing on this machine»), diff por sección y presets. Después Merge (sólo lo que
 *           trae) o Replace (lo exportable que no trae vuelve a su default). Antes de escribir,
 *           copia de settings.json; si el guardado falla, se vuelve a lo de antes. Nunca se
 *           importan comandos, hooks, código ni secretos: no hay dónde ponerlos.
 */
Singleton {
    id: root

    /** PRUEBAS (IPC `portabilityTestRoot`, bajo /tmp/): exports y copias van ahí. Importar escribe Settings. */
    property string testRoot: ""
    readonly property bool testing: root.testRoot.length > 0
    readonly property string exportDir: root.testing ? root.testRoot : Quickshell.env("HOME")
    readonly property string backupDir: root.testing ? root.testRoot + "/backups" : Settings.backupDir
    readonly property string helper: Quickshell.shellDir + "/scripts/portability.py"
    function setTestRoot(d) {
        const s = String(d || "");
        if (s.length > 0 && (s.indexOf("/tmp/") !== 0 || s.indexOf("..") >= 0)) return false;
        root.testRoot = s;
        root.discard();
        root.lastExport = null;
        return true;
    }

    readonly property string format: "sumi-settings"
    readonly property string legacyFormat: "kitasan-settings"
    readonly property int formatVersion: 1

    // ---- exportar -------------------------------------------------------------

    /** { ok, path, error, at, presets } */
    property var lastExport: null

    function pad(n) { return (n < 10 ? "0" : "") + n; }
    function exportNow(withPresets) {
        const values = {};
        const local = [];
        for (const e of Schema.exportable()) {
            values[e.id] = JSON.parse(JSON.stringify(Settings[e.prop]));
            if (e.local) local.push(e.id);
        }
        const presets = withPresets
            ? Presets.personal.filter(p => !p.broken).map(p => ({ id: p.id, name: p.name, values: p.values })) : [];
        const d = new Date();
        const doc = { format: root.format, formatVersion: root.formatVersion,
                      shellSchemaVersion: Schema.VERSION, exportedAt: d.toISOString(),
                      values: values, localPaths: local, presets: presets };
        const name = "sumi-settings-" + d.getFullYear() + "-" + root.pad(d.getMonth() + 1) + "-" + root.pad(d.getDate())
            + "-" + root.pad(d.getHours()) + root.pad(d.getMinutes()) + root.pad(d.getSeconds()) + ".json";
        root.run("export", ["write", "--out", root.exportDir + "/" + name], JSON.stringify(doc, null, 2) + "\n",
                 { presets: presets.length });
        return true;
    }

    // ---- analizar un archivo ----------------------------------------------------

    /**
     * null o { state: reading|checking|ready|error, path, error,
     *          changes: [{ id, prop, section, from, to }], unknown, notImportable,
     *          invalid: [{ id, error }], missing: [id], newer, presets: { valid:[…], invalid:[…] },
     *          values: { id: valor } (lo aplicable), mode }
     */
    property var analysis: null
    /** Merge | Replace, y si se traen los presets del archivo (elecciones de la vista). */
    property string mode: "merge"
    property bool withPresets: true

    function analyze(path) {
        const p = String(path || "").trim();
        if (p.length === 0) return false;
        root.analysis = { state: "reading", path: p };
        root.run("read", ["read", "--file", p], "", null);
        return true;
    }
    function discard() { root.analysis = null; }

    function show(v) {
        if (typeof v === "boolean") return v ? "On" : "Off";
        if (Array.isArray(v)) {
            // carpetas: por su nombre corto (las dos últimas partes), hasta tres
            const short = v.map(x => String(x).split("/").filter(y => y.length > 0).slice(-2).join("/"));
            return v.length === 0 ? "None" : v.length <= 3 ? short.join(", ") : v.length + " folders";
        }
        if (v !== null && typeof v === "object") return Object.keys(v).length === 0 ? "None" : "Set";
        return String(v);
    }

    function examine(r) {
        const a = { state: "error", path: root.analysis ? root.analysis.path : "" };
        if (!r || !r.ok) {
            a.error = !r ? "Could not read the file"
                : r.error === "not-found" ? "File not found"
                : r.error === "too-large" ? "The file is too large to be a settings export"
                : r.error === "not-json" ? "Not a JSON file" : "Could not read the file";
            root.analysis = a;
            return;
        }
        const doc = r.doc;
        // Sumi Shell (2026-11-07): también las exportaciones de antes del cambio de nombre (mismo contenido, otro rótulo)
        if (!doc || typeof doc !== "object" || (doc.format !== root.format && doc.format !== root.legacyFormat)) {
            a.error = "Not a Sumi Shell settings export";
            root.analysis = a;
            return;
        }
        if (typeof doc.formatVersion !== "number" || doc.formatVersion < 1) {
            a.error = "Missing or invalid formatVersion";
            root.analysis = a;
            return;
        }
        a.newer = doc.formatVersion > root.formatVersion
            || (typeof doc.shellSchemaVersion === "number" && doc.shellSchemaVersion > Schema.VERSION);
        const vals = doc.values && typeof doc.values === "object" && !Array.isArray(doc.values) ? doc.values : {};
        a.unknown = []; a.notImportable = []; a.invalid = []; a.values = {}; a.localIds = [];
        for (const id in vals) {
            const e = Schema.entryById(id);
            if (!e) { a.unknown.push(id); continue; }
            if (e.export === false) { a.notImportable.push(id); continue; }
            const c = Schema.check(e, vals[id]);
            if (!c.ok) { a.invalid.push({ id: id, error: c.error }); continue; }
            a.values[id] = c.value;
            if (e.local) a.localIds.push(id);
        }
        // presets del archivo: validados como los de disco
        a.presets = { valid: [], invalid: [] };
        for (const p of Array.isArray(doc.presets) ? doc.presets : []) {
            const v = Presets.validate({ schemaVersion: 1, name: p && p.name, values: p && p.values });
            if (v.ok) a.presets.valid.push({ name: v.name, values: v.values });
            else a.presets.invalid.push({ name: p && typeof p.name === "string" ? p.name : "(unnamed)", error: v.errors.join("; ") });
        }
        // las rutas locales se comprueban antes de dar el análisis por listo
        const paths = [];
        for (const id of a.localIds) {
            const v = a.values[id];
            for (const q of Array.isArray(v) ? v : [v]) if (typeof q === "string" && q.length > 0) paths.push(q);
        }
        a.state = "checking";
        root.analysis = a;
        root.run("exists", ["exists"], JSON.stringify(paths), null);
    }

    function finishCheck(exists) {
        const a = Object.assign({}, root.analysis);
        a.missing = [];
        for (const id of a.localIds) {
            const v = a.values[id];
            if (Array.isArray(v)) {
                // Sources: la lista se importa sólo con las carpetas que existen aquí
                const here = v.filter(q => exists[q] === true);
                const gone = v.filter(q => exists[q] !== true);
                if (gone.length > 0) a.missing.push({ id: id, paths: gone });
                a.values[id] = here;
            } else if (typeof v === "string" && v.length > 0 && exists[v] !== true) {
                a.missing.push({ id: id, paths: [v] });
                delete a.values[id];
            }
        }
        a.state = "ready";
        root.analysis = a;
    }

    /** Lo que cambiaría con el modo actual: [{ id, prop, section, from, to }]. */
    readonly property var changes: {
        const a = root.analysis;
        if (!a || a.state !== "ready") return [];
        const out = [];
        for (const e of Schema.exportable()) {
            let target;
            if (e.id in a.values) target = a.values[e.id];
            else if (root.mode === "replace" && !a.missing.some(m => m.id === e.id)) target = Schema.def(e.prop);
            else continue;
            const cur = Settings[e.prop];
            if (JSON.stringify(cur) !== JSON.stringify(target))
                out.push({ id: e.id, prop: e.prop, section: e.section || "Other",
                           from: root.show(cur), to: root.show(target), value: target });
        }
        return out;
    }

    // ---- aplicar -------------------------------------------------------------------

    /** { at, changes, presets, backup, undone } y lo que había antes (para Undo). */
    property var lastImport: null
    property var before: null
    property string error: ""

    function importNow() {
        const a = root.analysis;
        if (!a || a.state !== "ready") return false;
        if (!Settings.writable) { root.error = "Settings can't be saved right now"; return false; }
        const ch = root.changes;
        const pr = root.withPresets ? a.presets.valid : [];
        if (ch.length === 0 && pr.length === 0) { root.error = "Nothing to import"; return false; }
        root.error = "";
        a.state = "importing";
        root.analysis = Object.assign({}, a);
        // copia exacta ANTES de tocar nada; sin copia, no se importa
        root.run("backup", ["backup", "--src", Settings.configPath, "--dir", root.backupDir], "",
                 { changes: ch, presets: pr });
        return true;
    }

    function applyNow(ch, pr, backupFile) {
        const prev = {};
        for (const c of ch) prev[c.prop] = JSON.parse(JSON.stringify(Settings[c.prop]));
        for (const c of ch) Settings[c.prop] = c.value;
        const created = pr.map(p => Presets.create(p.name, p.values));
        root.before = prev;
        root.lastImport = { at: Date.now(), changes: ch.length, presets: pr.length, presetIds: created,
                            backup: backupFile, undone: false };
        root.analysis = null;
        verify.restart();
    }
    /** Si el guardado falla, se vuelve a lo de antes (futureSettingssurface §12: revertir la revisión). */
    Timer {
        id: verify
        interval: 1200
        onTriggered: if (Settings.status === "saveFailed" && root.before) {
            root.undo();
            root.error = "Could not save the imported settings · nothing was changed";
            recheck.restart();
        }
    }
    /**
     * Tras deshacer, lo de memoria vuelve a ser lo del archivo, pero el almacén seguiría diciendo
     * «Could not save settings». Se relee cuando el guardado pendiente ya vio que no hay nada que
     * escribir (antes, `retry` lo tomaría por un conflicto).
     */
    Timer {
        id: recheck
        interval: 600
        onTriggered: if (Settings.status === "saveFailed") Settings.retry()
    }
    function undo() {
        if (!root.before || !root.lastImport || root.lastImport.undone) return false;
        for (const p in root.before) Settings[p] = root.before[p];
        // los presets que trajo el import se retiran también (van a backups/presets, no se pierden)
        for (const id of root.lastImport.presetIds || []) Presets.remove(id);
        root.lastImport = Object.assign({}, root.lastImport, { undone: true });
        root.before = null;
        return true;
    }

    // ---- el helper, una orden a la vez ------------------------------------------------

    property var queue: []
    function run(kind, args, stdin, ctx) {
        root.queue = root.queue.concat([{ kind: kind, args: args, stdin: stdin || "", ctx: ctx }]);
        if (!proc.running) root.pump();
    }
    function pump() {
        if (root.queue.length === 0) return;
        const job = root.queue[0];
        root.queue = root.queue.slice(1);
        proc.job = job;
        proc.stdinEnabled = true;
        proc.command = ["python3", root.helper].concat(job.args);
        proc.running = true;
    }
    Process {
        id: proc
        property var job: null
        stdout: StdioCollector { id: pOut }
        onStarted: {
            if (proc.job && proc.job.stdin.length > 0) proc.write(proc.job.stdin);
            proc.stdinEnabled = false;
        }
        onExited: (code) => {
            let r = null;
            try { r = JSON.parse(pOut.text); } catch (e) { r = null; }
            const job = proc.job;
            proc.job = null;
            if (job.kind === "export")
                root.lastExport = r && r.ok ? { ok: true, path: r.path, at: Date.now(), presets: job.ctx.presets }
                    : { ok: false, error: r && r.error === "exists" ? "A file with that name already exists" : "Could not write the export", at: Date.now() };
            else if (job.kind === "read") root.examine(r);
            else if (job.kind === "exists") root.finishCheck(r && r.ok ? r.exists : {});
            else if (job.kind === "backup") {
                if (r && r.ok) root.applyNow(job.ctx.changes, job.ctx.presets, r.file);
                else {
                    root.error = "Could not back up your settings · nothing was imported";
                    if (root.analysis) root.analysis = Object.assign({}, root.analysis, { state: "ready" });
                }
            }
            root.pump();
        }
    }

    function summary() {
        const a = root.analysis;
        return {
            testing: root.testing, mode: root.mode, withPresets: root.withPresets, error: root.error,
            lastExport: root.lastExport, lastImport: root.lastImport,
            analysis: a ? { state: a.state, path: a.path, error: a.error || "", newer: !!a.newer,
                            unknown: a.unknown || [], notImportable: a.notImportable || [],
                            invalid: a.invalid || [], missing: a.missing || [],
                            presets: a.presets ? { valid: a.presets.valid.map(p => p.name),
                                                   invalid: a.presets.invalid } : null,
                            changes: root.changes.map(c => c.id + ": " + c.from + " → " + c.to) } : null
        };
    }
}
