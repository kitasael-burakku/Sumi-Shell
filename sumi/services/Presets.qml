pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/settings-schema.js" as Schema

/**
 * Presets de preferencias del shell (rediseño 12D, 2026-09-28; futureSettingssurface §12).
 *
 * Un preset es una LISTA BLANCA de ajustes del catálogo con grupo (`preset:` en
 * `lib/settings-schema.js`): Appearance, Layout y Motion. Nada de rutas, dispositivos,
 * secretos, integraciones ni el tema global (ese es de matugen y tiene su preview: 12A–12C).
 *
 *   - Integrados (Default, Compact, Glass, Vidrio Satinado, Minimal): en el código, inmutables; Duplicate crea
 *     uno personal. Una actualización del shell nunca toca `presets/`.
 *   - Personales: `~/.config/sumi-shell/presets/<id>.json`, por `scripts/presets.py`
 *     (escritura atómica, copia de la versión anterior en `backups/presets/`).
 *   - Aplicar = escribir los valores de los grupos ELEGIDOS por el mismo `Settings` (validados
 *     contra el catálogo antes de tocar nada; si uno no vale, no se aplica ninguno).
 *   - Estado: «Applied X», «Partially applied X (grupos)» o «Modified from X» si después se
 *     cambió algo de lo aplicado; nunca se finge que el preset entero coincide.
 */
Singleton {
    id: root

    /** PRUEBAS (IPC `presetsTestRoot`, sólo bajo /tmp/): presets, copias y estado salen de ahí. */
    property string testRoot: ""
    readonly property bool testing: root.testRoot.length > 0
    readonly property string dir: root.testing ? root.testRoot + "/presets" : Settings.configDir + "/presets"
    readonly property string backupDir: root.testing ? root.testRoot + "/backups" : Settings.stateDir + "/backups/presets"
    readonly property string statePath: root.testing ? root.testRoot + "/preset-state.json" : Settings.stateDir + "/preset-state.json"
    readonly property string helper: Quickshell.shellDir + "/scripts/presets.py"

    function setTestRoot(d) {
        const s = String(d || "");
        if (s.length > 0 && (s.indexOf("/tmp/") !== 0 || s.indexOf("..") >= 0)) return false;
        root.testRoot = s;
        root.lastApplied = null;
        root.error = "";
        root.reload();
        return true;
    }

    readonly property var groups: Schema.PRESET_GROUPS
    readonly property var groupNames: ({ appearance: "Appearance", layout: "Layout", motion: "Motion" })

    /** id del catálogo → { prop, group, label } de lo presetable. */
    readonly property var fields: {
        const m = {};
        for (const e of Schema.presetable()) m[e.id] = { prop: e.prop, group: e.preset };
        return m;
    }
    readonly property var labels: ({
        "shell.interface.scale": "Scale", "shell.interface.osdPlacement": "OSD placement",
        "shell.interface.workspaceIndicators": "Workspace dots", "shell.osd.showValue": "OSD value",
        "shell.launcher.scrollbar": "Launcher scrollbar", "shell.animations.mode": "Motion",
        "shell.animations.speed": "Global speed", "shell.animations.windowStyle": "Window style",
        "shell.animations.barPanels": "Bar panels", "shell.animations.islandStyle": "Island style",
        "theme.typography.textSize": "Text size",
        "theme.appearance.glassOpacity": "Glass opacity",
        "theme.appearance.material": "Material",
        "theme.appearance.materialEdge": "Material border",
        "theme.appearance.materialShadow": "Material shadow"
    })
    function labelOf(id) { return root.labels[id] || id; }
    function show(id, v) {
        if (id === "theme.appearance.glassOpacity") return Math.round(v * 100) + "%";
        if (id === "shell.interface.scale" || id === "shell.animations.speed" || id === "theme.typography.textSize")
            return "×" + Number(v).toFixed(2).replace(/0$/, "");
        if (typeof v === "boolean") return v ? "On" : "Off";
        return String(v);
    }

    // ---- los integrados ------------------------------------------------------

    readonly property var builtins: {
        const def = {};
        for (const e of Schema.presetable()) def[e.id] = Schema.def(e.prop);
        return [
            { id: "default", name: "Default", builtin: true, values: def,
              note: "The shell as it ships" },
            { id: "compact", name: "Compact", builtin: true, note: "Smaller shell, quieter OSD",
              values: { "shell.interface.scale": 0.9, "shell.interface.osdPlacement": "below",
                        "shell.osd.showValue": false, "theme.typography.textSize": 1.0 } },
            { id: "glass", name: "Glass", builtin: true, note: "Original material · keeps your glass opacity",
              values: { "theme.appearance.material": "glass" } },
            { id: "satin", name: "Vidrio Satinado", builtin: true,
              note: "Soft tonal surfaces · keeps your glass opacity",
              values: { "theme.appearance.material": "satin",
                        "theme.appearance.materialEdge": "subtle",
                        "theme.appearance.materialShadow": true } },
            { id: "minimal", name: "Minimal", builtin: true, note: "Calm motion, fewer indicators",
              values: { "shell.animations.mode": "reduced", "shell.interface.workspaceIndicators": 0,
                        "shell.osd.showValue": false, "theme.appearance.glassOpacity": 0.98 } }
        ];
    }

    // ---- los personales -------------------------------------------------------

    /** [{ id, name, values, builtin:false, errors:[…] }] — un archivo roto sale con `broken`. */
    property var personal: []
    property bool loaded: false
    property string error: ""
    property var backupCount: ({})

    function all() { return root.builtins.concat(root.personal); }
    function byId(id) { return root.all().find(p => p.id === id) || null; }

    /** Un documento de preset contra el catálogo: sólo ids presetables y valores válidos. */
    function validate(doc) {
        const errs = [];
        if (!doc || typeof doc !== "object" || Array.isArray(doc)) return { ok: false, errors: ["not an object"] };
        if (doc.schemaVersion !== 1) errs.push("unsupported schemaVersion");
        if (typeof doc.name !== "string" || doc.name.trim().length === 0 || doc.name.length > 48) errs.push("invalid name");
        const vals = {};
        const src = doc.values && typeof doc.values === "object" && !Array.isArray(doc.values) ? doc.values : null;
        if (!src) errs.push("no values");
        else for (const k in src) {
            const f = root.fields[k];
            if (!f) { errs.push(k + ": not a preset setting"); continue; }
            const c = Schema.check(Schema.entryById(k), src[k]);
            if (c.ok) vals[k] = c.value;
            else errs.push(k + ": " + c.error);
        }
        return { ok: errs.length === 0, errors: errs, name: doc.name, values: vals };
    }

    function reload() {
        listProc.command = ["python3", root.helper, "list", "--dir", root.dir];
        listProc.running = true;
    }
    Process {
        id: listProc
        stdout: StdioCollector { id: listOut }
        onExited: (code) => {
            let r = null;
            try { r = JSON.parse(listOut.text); } catch (e) { r = null; }
            if (!r || !r.ok) { root.error = "Could not read your presets"; root.loaded = true; return; }
            const out = [];
            for (const rec of r.presets) {
                if (rec.error) { out.push({ id: rec.id, name: rec.file, builtin: false, broken: rec.error, values: {} }); continue; }
                const v = root.validate(rec.doc);
                out.push({ id: rec.id, name: v.name || rec.id, builtin: false, values: v.values,
                           broken: v.ok ? "" : v.errors.join("; ") });
            }
            root.personal = out;
            root.loaded = true;
            root.refreshBackups();
        }
    }
    Component.onCompleted: root.reload()

    function refreshBackups() {
        backupsProc.pending = root.personal.map(p => p.id);
        backupsProc.counts = ({});
        backupsProc.next();
    }
    Process {
        id: backupsProc
        property var pending: []
        property var counts: ({})
        property string cur: ""
        function next() {
            if (backupsProc.pending.length === 0) { root.backupCount = backupsProc.counts; return; }
            backupsProc.cur = backupsProc.pending[0];
            backupsProc.pending = backupsProc.pending.slice(1);
            backupsProc.command = ["python3", root.helper, "backups", "--backup", root.backupDir, "--id", backupsProc.cur];
            backupsProc.running = true;
        }
        stdout: StdioCollector { id: bOut }
        onExited: {
            try { const r = JSON.parse(bOut.text); if (r.ok) { const t = Object.assign({}, backupsProc.counts); t[backupsProc.cur] = r.count; backupsProc.counts = t; } } catch (e) {}
            backupsProc.next();
        }
    }

    // ---- escribir (una orden a la vez) -------------------------------------------

    property var queue: []
    function run(args, stdin, then) {
        root.queue = root.queue.concat([{ args: args, stdin: stdin || "", then: then || null }]);
        if (!writeProc.running) root.pump();
    }
    function pump() {
        if (root.queue.length === 0) return;
        const job = root.queue[0];
        root.queue = root.queue.slice(1);
        writeProc.job = job;
        writeProc.stdinEnabled = true;           // hay que reabrirlo en cada arranque (memoria)
        writeProc.command = ["python3", root.helper].concat(job.args);
        writeProc.running = true;
    }
    Process {
        id: writeProc
        property var job: null
        stdout: StdioCollector { id: wOut }
        onStarted: {
            if (writeProc.job && writeProc.job.stdin.length > 0) writeProc.write(writeProc.job.stdin);
            writeProc.stdinEnabled = false;
        }
        onExited: (code) => {
            let r = null;
            try { r = JSON.parse(wOut.text); } catch (e) { r = null; }
            const ok = code === 0 && r && r.ok;
            if (!ok) root.error = "Could not save the preset" + (r && r.detail ? ": " + r.detail : "");
            const then = writeProc.job ? writeProc.job.then : null;
            writeProc.job = null;
            if (then) then(ok, r);
            if (root.queue.length > 0) root.pump();
            else root.reload();
        }
    }

    function slug(name) {
        let s = String(name).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").substring(0, 40);
        if (s.length === 0) s = "preset";
        let id = s, n = 2;
        while (root.byId(id)) id = s + "-" + (n++);
        return id;
    }
    function uniqueName(base) {
        let name = base, n = 2;
        while (root.all().some(p => p.name === name)) name = base + " " + (n++);
        return name;
    }
    function store(id, name, values, then) {
        const doc = { schemaVersion: 1, id: id, name: name, values: values };
        root.run(["write", "--dir", root.dir, "--backup", root.backupDir, "--id", id],
                 JSON.stringify(doc, null, 2) + "\n", then);
    }

    /**
     * Un personal nuevo: nombre e id únicos reservados YA (se añade a `personal` antes de que el
     * disco conteste), así dos creaciones seguidas con el mismo nombre no comparten id.
     */
    function create(name, values) {
        const n = root.uniqueName(String(name || "").trim().substring(0, 48) || "My preset");
        const nid = root.slug(n);
        root.store(nid, n, Object.assign({}, values));
        root.personal = root.personal.concat([{ id: nid, name: n, builtin: false, values: Object.assign({}, values), broken: "" }]);
        return nid;
    }

    /** Duplicate: un personal con los mismos valores. Devuelve el id nuevo. */
    function duplicate(id) {
        const p = root.byId(id);
        if (!p || p.broken) return "";
        return root.create(p.name + " copy", p.values);
    }
    /** Lo actual de TODOS los grupos, como preset personal nuevo. */
    function saveCurrent(name) {
        const vals = {};
        for (const k in root.fields) vals[k] = Settings[root.fields[k].prop];
        return root.create(name, vals);
    }
    /** Personal: sus grupos, con los valores actuales (la versión anterior va a backups/). */
    function updateFromCurrent(id) {
        const p = root.byId(id);
        if (!p || p.builtin) return false;
        const vals = {};
        const gs = root.groupsOf(p);
        for (const k in root.fields)
            if (gs.indexOf(root.fields[k].group) >= 0 || gs.length === 0) vals[k] = Settings[root.fields[k].prop];
        root.store(id, p.name, vals);
        root.personal = root.personal.map(x => x.id === id ? Object.assign({}, x, { values: vals, broken: "" }) : x);
        return true;
    }
    function rename(id, name) {
        const p = root.byId(id);
        const n = String(name || "").trim();
        if (!p || p.builtin || n.length === 0 || n.length > 48) return false;
        if (root.all().some(x => x.id !== id && x.name === n)) { root.error = "Another preset has that name"; return false; }
        root.store(id, n, p.values);
        root.personal = root.personal.map(x => x.id === id ? Object.assign({}, x, { name: n }) : x);
        return true;
    }
    function remove(id) {
        const p = root.byId(id);
        if (!p || p.builtin) return false;
        root.run(["delete", "--dir", root.dir, "--backup", root.backupDir, "--id", id]);
        root.personal = root.personal.filter(x => x.id !== id);
        return true;
    }
    function restorePrevious(id) {
        if ((root.backupCount[id] || 0) === 0) return false;
        root.run(["restore", "--dir", root.dir, "--backup", root.backupDir, "--id", id]);
        return true;
    }

    // ---- aplicar y comparar --------------------------------------------------------

    function groupsOf(p) {
        const out = [];
        for (const g of root.groups)
            for (const k in (p ? p.values : {}))
                if (root.fields[k] && root.fields[k].group === g) { out.push(g); break; }
        return out;
    }
    /** Lo que cambiaría, por grupo: [{ id, label, from, to }] (sólo lo distinto). */
    function diff(p) {
        const out = { appearance: [], layout: [], motion: [] };
        if (!p) return out;
        for (const k in p.values) {
            const f = root.fields[k];
            if (!f) continue;
            const cur = Settings[f.prop];
            if (JSON.stringify(cur) !== JSON.stringify(p.values[k]))
                out[f.group].push({ id: k, label: root.labelOf(k), from: root.show(k, cur), to: root.show(k, p.values[k]) });
        }
        return out;
    }

    /** Lo último aplicado: { id, name, groups, values } (estado, no preferencia). */
    property var lastApplied: null

    /**
     * Aplicar los grupos elegidos. Todo se valida ANTES; con Settings sin poder escribirse
     * (archivo roto, versión futura, conflicto) no se toca nada.
     */
    function apply(id, groups) {
        const p = root.byId(id);
        if (!p || p.broken) { root.error = "This preset can't be applied"; return false; }
        if (!Settings.writable) { root.error = "Settings can't be saved right now"; return false; }
        const gs = (groups || root.groupsOf(p)).filter(g => root.groupsOf(p).indexOf(g) >= 0);
        if (gs.length === 0) { root.error = "Choose at least one group"; return false; }
        const batch = {};
        for (const k in p.values) {
            const f = root.fields[k];
            if (!f || gs.indexOf(f.group) < 0) continue;
            const c = Schema.check(Schema.entryById(k), p.values[k]);
            if (!c.ok) { root.error = root.labelOf(k) + ": " + c.error; return false; }
            batch[k] = c.value;
        }
        for (const k in batch) Settings[root.fields[k].prop] = batch[k];
        root.error = "";
        root.lastApplied = { id: p.id, name: p.name, groups: gs, all: root.groupsOf(p), values: batch, at: Date.now() };
        stateFile.setText(JSON.stringify(root.lastApplied));
        return true;
    }

    /** { kind: none|applied|partial|modified, id, name, groups } */
    readonly property var status: {
        const a = root.lastApplied;
        if (!a) return { kind: "none" };
        let same = true;
        for (const k in a.values) {
            const f = root.fields[k];
            if (!f) continue;
            if (JSON.stringify(Settings[f.prop]) !== JSON.stringify(a.values[k])) { same = false; break; }
        }
        if (!same) return { kind: "modified", id: a.id, name: a.name, groups: a.groups };
        return { kind: a.groups.length < (a.all || a.groups).length ? "partial" : "applied",
                 id: a.id, name: a.name, groups: a.groups };
    }
    function statusText() {
        const s = root.status;
        const gl = (s.groups || []).map(g => root.groupNames[g]).join(", ");
        return s.kind === "applied" ? "Applied " + s.name
            : s.kind === "partial" ? "Partially applied " + s.name + " · " + gl
            : s.kind === "modified" ? "Modified from " + s.name
            : "No preset applied";
    }

    FileView {
        id: stateFile
        path: root.statePath
        blockLoading: true
        printErrors: false
        onLoaded: {
            try {
                const d = JSON.parse(text());
                root.lastApplied = d && typeof d.id === "string" && d.values ? d : null;
            } catch (e) { root.lastApplied = null; }
        }
        onLoadFailed: root.lastApplied = null
    }

    function summary() {
        return { testing: root.testing, dir: root.dir, loaded: root.loaded, error: root.error,
                 presets: root.all().map(p => ({ id: p.id, name: p.name, builtin: !!p.builtin, broken: p.broken || "",
                                                  groups: root.groupsOf(p), backups: root.backupCount[p.id] || 0 })),
                 status: root.status, statusText: root.statusText() };
    }
}
