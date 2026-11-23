.pragma library
/*
 * `tasks.json`: las tareas de mantenimiento que declara el usuario (portabilidad F3a, 2026-10-05;
 * H-14, HC-20…28). Vive en $XDG_CONFIG_HOME/sumi-shell/tasks.json y es lo ÚNICO ejecutable de
 * la configuración: por eso va aparte de settings.json, no se exporta ni se importa, y la shell
 * nunca lo escribe (salvo sembrarlo UNA vez, en la migración v2 → v3, si no existe).
 *
 * Formato v1:
 *   { "version": 1, "tasks": [ { … }, … ] }       en el orden en que se enseñan
 *
 * Cada tarea:
 *   id          ^[a-z][a-z0-9_-]{0,31}$, única; no puede ser un verbo de la shell (RESERVED)
 *   label       el nombre en las filas (inglés lo pone el usuario; ≤ 80)
 *   desc        la línea de la paleta (≤ 120; por defecto, label)
 *   console     el título de su consola en Tasks (≤ 80; por defecto, label)
 *   glyph       nombre de icono de la shell (≤ 32; uno desconocido cae al genérico)
 *   argv        la orden, en lista: argv[0] es un nombre, una ruta absoluta o ~/…; NUNCA una línea
 *               para `sh -c` que construya la shell (si el usuario quiere un intérprete, lo nombra él)
 *   runs        panel (corre en la shell y se sigue en Tasks) | terminal (se abre en apps.terminal)
 *   title       sólo terminal: el título de la ventana
 *   output      sólo panel: plain | jsonl-report (registros JSON por línea y un veredicto al final)
 *   prompts     sólo panel: none | dotbackup (el protocolo de preguntas conocido; el texto lo lee Jobs)
 *   confirm     sólo panel: la pregunta antes de arrancar (≤ 160)
 *   successText sólo panel+plain: el resumen al salir con 0 (≤ 80)
 *   sshAgent    sólo panel: le pasa el agente SSH propio de la shell (para un `git push`)
 *   sshKey      con sshAgent: la clave que se desbloquea (por defecto ~/.ssh/id_ed25519; F3d-1, HC-27)
 *   palette     false = no sale en la paleta de comandos (por defecto true)
 *   requires    lo que tiene que existir además de argv[0]: nombres (en el PATH) o rutas (archivo)
 *   lastRun     cómo saber la última vez: { kind: "git", repo } | { kind: "newest", dir, glob }
 *   summary     archivo de resumen `epoch|hallazgos[|desconocidos]` que deja la propia tarea
 *   role        system-upgrade: la usa el botón Upgrade de Updates
 *
 * Una tarea inválida se descarta con su motivo; las demás siguen. Este archivo no ejecuta ni lee
 * nada: valida y normaliza. Los permisos (dueño, escribible por otros) los comprueba quien lo carga.
 */

var VERSION = 1;
var TASK_ID = /^[a-z][a-z0-9_-]{0,31}$/;
/** Ids de la paleta y del Dashboard que ya son de la shell. */
var RESERVED = ["theme", "wall", "mode", "dashboard", "menu", "downed", "units", "updates"];
var MAX_TASKS = 32;

function str(v, max) { return typeof v === "string" && v.length <= max && !/[\x00]/.test(v); }

/** Una ruta de tarea: absoluta o ~/…; sin «..» como componente. */
function isPath(v) {
    if (!str(v, 4096) || v.length === 0) return false;
    if (v.charAt(0) !== "/" && v.indexOf("~/") !== 0) return false;
    return !/(^|\/)\.\.(\/|$)/.test(v);
}

/** Un nombre de programa suelto (lo que se busca en el PATH). */
function isName(v) { return typeof v === "string" && /^[A-Za-z0-9_][A-Za-z0-9._+-]{0,127}$/.test(v); }

function expand(path, home) {
    return typeof path === "string" && path.indexOf("~/") === 0 ? home + path.substring(1) : path;
}

/** Una tarea → { ok, task } o { ok: false, error }. `home` expande ~/ en argv[0], rutas y requires. */
function checkTask(t, home) {
    if (t === null || typeof t !== "object" || Array.isArray(t)) return { ok: false, error: "not an object" };
    if (typeof t.id !== "string" || !TASK_ID.test(t.id)) return { ok: false, error: "invalid id" };
    if (RESERVED.indexOf(t.id) >= 0) return { ok: false, error: "id is reserved by the shell" };
    if (!str(t.label, 80) || t.label.trim().length === 0) return { ok: false, error: "missing label" };
    var out = { id: t.id, label: t.label };
    var opt = [["desc", 120], ["console", 80], ["glyph", 32], ["title", 80], ["confirm", 160], ["successText", 80]];
    for (var i = 0; i < opt.length; i++) {
        var k = opt[i][0];
        if (t[k] === undefined) continue;
        if (!str(t[k], opt[i][1])) return { ok: false, error: k + " must be text of at most " + opt[i][1] + " characters" };
        out[k] = t[k];
    }
    if (out.desc === undefined) out.desc = out.label;
    if (out.console === undefined) out.console = out.label;
    if (!Array.isArray(t.argv) || t.argv.length === 0 || t.argv.length > 64)
        return { ok: false, error: "argv must be a non-empty list" };
    for (var a = 0; a < t.argv.length; a++)
        if (!str(t.argv[a], 4096)) return { ok: false, error: "argv entries must be text" };
    if (!isName(t.argv[0]) && !isPath(t.argv[0]))
        return { ok: false, error: "argv[0] must be a program name or an absolute path" };
    out.argv = t.argv.slice();
    out.argv[0] = expand(out.argv[0], home);
    if (t.runs !== "panel" && t.runs !== "terminal") return { ok: false, error: "runs must be panel or terminal" };
    out.runs = t.runs;
    var panelOnly = ["output", "prompts", "confirm", "successText", "sshAgent"];
    for (var p = 0; p < panelOnly.length; p++)
        if (t.runs !== "panel" && t[panelOnly[p]] !== undefined)
            return { ok: false, error: panelOnly[p] + " only applies to panel tasks" };
    if (t.runs !== "terminal" && t.title !== undefined) return { ok: false, error: "title only applies to terminal tasks" };
    out.output = t.output === undefined ? "plain" : t.output;
    if (out.output !== "plain" && out.output !== "jsonl-report") return { ok: false, error: "output must be plain or jsonl-report" };
    out.prompts = t.prompts === undefined ? "none" : t.prompts;
    if (out.prompts !== "none" && out.prompts !== "dotbackup") return { ok: false, error: "prompts must be none or dotbackup" };
    if (out.successText !== undefined && out.output !== "plain") return { ok: false, error: "successText only applies to plain output" };
    var bools = ["sshAgent", "palette"];
    for (var b = 0; b < bools.length; b++) {
        if (t[bools[b]] !== undefined && typeof t[bools[b]] !== "boolean") return { ok: false, error: bools[b] + " must be true or false" };
    }
    out.sshAgent = t.sshAgent === true;
    out.palette = t.palette !== false;
    out.requires = [];
    if (t.requires !== undefined) {
        if (!Array.isArray(t.requires) || t.requires.length > 16) return { ok: false, error: "requires must be a list" };
        for (var r = 0; r < t.requires.length; r++) {
            if (isName(t.requires[r])) out.requires.push(t.requires[r]);
            else if (isPath(t.requires[r])) out.requires.push(expand(t.requires[r], home));
            else return { ok: false, error: "requires entries must be program names or absolute paths" };
        }
    }
    if (t.lastRun !== undefined) {
        var l = t.lastRun;
        if (l === null || typeof l !== "object" || Array.isArray(l)) return { ok: false, error: "lastRun must be an object" };
        if (l.kind === "git") {
            if (!isPath(l.repo)) return { ok: false, error: "lastRun.repo must be an absolute path" };
            out.lastRun = { kind: "git", repo: expand(l.repo, home) };
        } else if (l.kind === "newest") {
            if (!isPath(l.dir)) return { ok: false, error: "lastRun.dir must be an absolute path" };
            if (!str(l.glob, 128) || l.glob.length === 0 || l.glob.indexOf("/") >= 0)
                return { ok: false, error: "lastRun.glob must be a file name pattern" };
            out.lastRun = { kind: "newest", dir: expand(l.dir, home), glob: l.glob };
        } else return { ok: false, error: "lastRun.kind must be git or newest" };
    }
    if (t.sshKey !== undefined) {
        if (!out.sshAgent) return { ok: false, error: "sshKey only applies with sshAgent" };
        if (!isPath(t.sshKey)) return { ok: false, error: "sshKey must be an absolute path" };
        out.sshKey = expand(t.sshKey, home);
    }
    if (t.summary !== undefined) {
        if (!isPath(t.summary)) return { ok: false, error: "summary must be an absolute path" };
        out.summary = expand(t.summary, home);
    }
    if (t.role !== undefined) {
        if (t.role !== "system-upgrade") return { ok: false, error: "role must be system-upgrade" };
        out.role = t.role;
    }
    return { ok: true, task: out };
}

/**
 * El documento entero:
 *   structure  "" o por qué no se puede usar (entonces no hay tareas)
 *   newer      versión futura: se usa lo que se entienda, sin escribir nada (la shell nunca escribe)
 *   tasks      las válidas, normalizadas
 *   errors     [{ index, id, error }]
 */
function validate(doc, home) {
    var r = { structure: "", newer: false, tasks: [], errors: [] };
    if (doc === null || typeof doc !== "object" || Array.isArray(doc)) { r.structure = "the file is not a JSON object"; return r; }
    if (typeof doc.version !== "number" || Math.floor(doc.version) !== doc.version || doc.version < 1) {
        r.structure = "missing or invalid version"; return r;
    }
    r.newer = doc.version > VERSION;
    if (!Array.isArray(doc.tasks)) { r.structure = "tasks must be a list"; return r; }
    var seen = {};
    var roles = {};
    for (var i = 0; i < doc.tasks.length; i++) {
        var id = doc.tasks[i] && typeof doc.tasks[i].id === "string" ? doc.tasks[i].id : "";
        if (r.tasks.length >= MAX_TASKS) { r.errors.push({ index: i, id: id, error: "more than " + MAX_TASKS + " tasks" }); continue; }
        var c = checkTask(doc.tasks[i], home || "");
        if (!c.ok) { r.errors.push({ index: i, id: id, error: c.error }); continue; }
        if (seen[c.task.id]) { r.errors.push({ index: i, id: id, error: "duplicate id" }); continue; }
        if (c.task.role && roles[c.task.role]) { r.errors.push({ index: i, id: id, error: "another task already has role " + c.task.role }); continue; }
        seen[c.task.id] = true;
        if (c.task.role) roles[c.task.role] = true;
        r.tasks.push(c.task);
    }
    return r;
}

function serialize(doc) { return JSON.stringify(doc, null, 2) + "\n"; }

if (typeof module !== "undefined")
    module.exports = { VERSION: VERSION, TASK_ID: TASK_ID, RESERVED: RESERVED, validate: validate,
        checkTask: checkTask, expand: expand, serialize: serialize };
