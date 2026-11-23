.pragma library
/*
 * `providers.json`: los proveedores externos que declara el usuario (portabilidad F4a, 2026-10-07;
 * H-10, H-11, H-15, HC-01…10). Vive en $XDG_CONFIG_HOME/sumi-shell/providers.json. `settings.json`
 * sólo ELIGE el proveedor de cada tipo (enums cerrados `providers.*`); con `script`, la orden sale de
 * aquí. Como `tasks.json`, es configuración ejecutable: la shell no lo escribe (salvo sembrarlo UNA vez
 * en la migración v3 → v4, si no existe), no se exporta ni se importa, y quien lo carga lo ignora entero
 * si no es del usuario o lo pueden escribir otros. Lo que el usuario declara aquí es una integración de
 * confianza, no código aislado: la shell lo ejecuta tal cual, sin interpolar nada en una línea de shell.
 *
 * Formato v1 (estricto: una clave desconocida invalida su tipo; una versión desconocida, el archivo):
 *   {
 *     "version": 1,
 *     "<tipo>": {                       wallpaper · theme · thumbnails · updates (todos opcionales)
 *       "label":   "…",                 cómo se nombra en la UI (≤ 80; por defecto, el tipo)
 *       "scripts": [                    1–8 órdenes (F4d: un `theme` puede no tener ninguna si declara
 *                                       `matugenConfig`: la config de matugen del usuario para el proveedor propio)
 *         { "argv": ["…", …], "supports": ["<verbo>", …] }
 *       ],
 *       <rutas del tipo>                ver PATHS
 *     }
 *   }
 *
 * argv: lista de 1–32 textos; argv[0] es un nombre (en el PATH), una ruta absoluta o ~/…. Cualquier
 * elemento que empiece por «~/» se expande con HOME (para que un `bash ~/…/script.sh` sea el mismo argv
 * que hoy). La shell AÑADE detrás los argumentos del verbo (VERBS) y nada más: sólo se llama a un verbo
 * declarado en `supports`, y cada verbo lo da una sola orden del tipo. Así un script que no conoce una
 * opción nunca la recibe (un script viejo la ignoraba y EJECUTABA: 12A, `apply-static-colors.sh --list`).
 *
 * Este archivo no ejecuta ni lee nada: valida, normaliza y compone argv.
 */

var VERSION = 1;
var KINDS = ["wallpaper", "theme", "thumbnails", "updates"];
var MAX_SCRIPTS = 8;

/**
 * Los verbos de cada tipo y los argumentos que la shell añade a su argv. Es el contrato del rice del
 * autor (apply-wallpaper.sh, wallpaper-video-pause.sh, matugen_reload.sh, matugen_toggle.sh,
 * apply-static-colors.sh, updates.sh; tools/f4/argv-before.json), que es también el de los proveedores
 * propios de la shell. «{x}» = un argumento que pone el consumidor.
 *   wallpaper  apply {path} · applyOutput {path} {output} · clear --clear {output} · sync --sync ·
 *              restore (sin argumentos: lo guardado) · pauseStatus status --json · pauseRestore restore {json}
 *   theme      reload {wall} (regenera con los ajustes de theme/) · toggle (conmuta; ningún argumento) ·
 *              staticList --list (imprime copy<TAB>origen<TAB>destino y script<TAB>ruta) ·
 *              preset {preset} (poner la paleta estática sumi/palettes/<id>.json; F-b, 2026-11-04) ·
 *              presetList --list (los presets que ofrece, JSON) · staticApply (poner Minimaru de una vez:
 *              con un preset puesto, `themeSet static`; F-c). Opcionales: el script del autor no los declara
 *              y sigue valiendo; sin ellos la shell no ofrece presets (whyNot lo dice).
 *   thumbnails refresh (genera y poda en la caché; vuelve enseguida)
 *   updates    check (refresca la caché) · list --list (lista legible; se abre en la terminal)
 */
var VERBS = {
    wallpaper: { apply: ["{path}"], applyOutput: ["{path}", "{output}"], clear: ["--clear", "{output}"],
                 sync: ["--sync"], restore: [], pauseStatus: ["status", "--json"], pauseRestore: ["restore", "{json}"] },
    theme: { reload: ["{wall}"], toggle: [], staticList: ["--list"], preset: ["{preset}"], presetList: ["--list"],
             staticApply: [] },
    thumbnails: { refresh: [] },
    updates: { check: [], list: ["--list"] }
};
/**
 * Marcas que no son verbos: `transition` (wallpaper) = la orden de apply/applyOutput entiende la variable
 * WALL_TRANSITION con el nombre de la transición (Settings → Theme → Wallpaper → Transitions).
 */
var FLAGS = { wallpaper: ["transition"], theme: [], thumbnails: [], updates: [] };
/**
 * Rutas que declara un tipo (absolutas o ~/…):
 *   wallpaper.lockStill      el PNG quieto que deja el proveedor para el Lock (HC-05; su consumidor es de F5)
 *   theme.matugenConfig      la config de matugen del usuario (si falta, la shell usa la suya: F4d)
 *   theme.xsettingsConfig   archivo dedicado del gestor opcional, creado sólo al habilitarlo
 *   updates.cache            la caché JSON (formato de Waybar) que deja `check`; por defecto
 *                            $XDG_RUNTIME_DIR/sumi-updates.cache
 */
var PATHS = { wallpaper: ["lockStill"], theme: ["matugenConfig", "xsettingsConfig"], thumbnails: [], updates: ["cache"] };

function str(v, max) { return typeof v === "string" && v.length <= max && !/[\x00]/.test(v); }

/** Una ruta: absoluta o ~/…; sin «..» como componente. */
function isPath(v) {
    if (!str(v, 4096) || v.length === 0) return false;
    if (v.charAt(0) !== "/" && v.indexOf("~/") !== 0) return false;
    return !/(^|\/)\.\.(\/|$)/.test(v);
}

/** Un nombre de programa suelto (lo que se busca en el PATH). */
function isName(v) { return typeof v === "string" && /^[A-Za-z0-9_][A-Za-z0-9._+-]{0,127}$/.test(v); }

function expand(v, home) {
    return typeof v === "string" && v.indexOf("~/") === 0 ? home + v.substring(1) : v;
}

function isObject(v) { return v !== null && typeof v === "object" && !Array.isArray(v); }

/** Un tipo → { ok, provider } o { ok: false, error }. */
function checkKind(kind, p, home) {
    if (!isObject(p)) return { ok: false, error: "must be an object" };
    var allowed = ["label", "scripts"].concat(PATHS[kind]);
    for (var k in p) if (allowed.indexOf(k) < 0) return { ok: false, error: "unknown key «" + k + "»" };
    var out = { kind: kind, label: kind, scripts: [], verbs: {}, flags: {} };
    if (p.label !== undefined) {
        if (!str(p.label, 80) || p.label.trim().length === 0) return { ok: false, error: "label must be text of at most 80 characters" };
        out.label = p.label;
    }
    for (var i = 0; i < PATHS[kind].length; i++) {
        var key = PATHS[kind][i];
        if (p[key] === undefined) continue;
        if (!isPath(p[key])) return { ok: false, error: key + " must be an absolute path" };
        out[key] = expand(p[key], home);
    }
    // F4d: un tema puede declarar sólo su config de matugen (sin órdenes): la usa el proveedor propio
    var bare = kind === "theme" && p.scripts === undefined && (typeof out.matugenConfig === "string" || typeof out.xsettingsConfig === "string");
    if (bare) return { ok: true, provider: out };
    if (!Array.isArray(p.scripts) || p.scripts.length === 0 || p.scripts.length > MAX_SCRIPTS)
        return { ok: false, error: "scripts must be a list of 1 to " + MAX_SCRIPTS + " commands" };
    for (var s = 0; s < p.scripts.length; s++) {
        var sc = p.scripts[s];
        var where = "scripts[" + s + "]";
        if (!isObject(sc)) return { ok: false, error: where + " must be an object" };
        for (var sk in sc) if (sk !== "argv" && sk !== "supports") return { ok: false, error: where + ": unknown key «" + sk + "»" };
        if (!Array.isArray(sc.argv) || sc.argv.length === 0 || sc.argv.length > 32)
            return { ok: false, error: where + ".argv must be a list of 1 to 32 entries" };
        for (var a = 0; a < sc.argv.length; a++)
            if (!str(sc.argv[a], 4096)) return { ok: false, error: where + ".argv entries must be text" };
        if (!isName(sc.argv[0]) && !isPath(sc.argv[0]))
            return { ok: false, error: where + ".argv[0] must be a program name or an absolute path" };
        if (!Array.isArray(sc.supports) || sc.supports.length === 0)
            return { ok: false, error: where + ".supports must list what it does" };
        var argv = sc.argv.map(function (x) { return expand(x, home); });
        var verbs = [];
        for (var v = 0; v < sc.supports.length; v++) {
            var name = sc.supports[v];
            var isVerb = typeof name === "string" && VERBS[kind].hasOwnProperty(name);
            var isFlag = typeof name === "string" && FLAGS[kind].indexOf(name) >= 0;
            if (!isVerb && !isFlag) return { ok: false, error: where + ": «" + name + "» is not something a " + kind + " provider does" };
            if (verbs.indexOf(name) >= 0) return { ok: false, error: where + ": «" + name + "» is listed twice" };
            if (isVerb && out.verbs[name] !== undefined) return { ok: false, error: "«" + name + "» is declared by two commands" };
            verbs.push(name);
        }
        for (var f = 0; f < verbs.length; f++) {
            if (FLAGS[kind].indexOf(verbs[f]) < 0) continue;
            if (verbs.indexOf("apply") < 0 && verbs.indexOf("applyOutput") < 0)
                return { ok: false, error: where + ": «" + verbs[f] + "» needs apply or applyOutput in the same command" };
        }
        for (var g = 0; g < verbs.length; g++) {
            if (FLAGS[kind].indexOf(verbs[g]) >= 0) out.flags[verbs[g]] = out.scripts.length;
            else out.verbs[verbs[g]] = out.scripts.length;
        }
        out.scripts.push({ argv: argv, supports: verbs });
    }
    return { ok: true, provider: out };
}

/**
 * El documento entero:
 *   structure  "" o por qué no se puede usar (entonces no hay ningún proveedor declarado)
 *   providers  { tipo: { kind, label, scripts, verbs: { verbo: índice }, flags, <rutas> } } — los válidos
 *   errors     [{ kind, error }] — los tipos descartados (los demás siguen)
 * Una versión distinta de la 1 no se usa: las órdenes de un formato que esta shell no conoce no se
 * ejecutan a medias.
 */
function validate(doc, home) {
    var r = { structure: "", providers: {}, errors: [] };
    if (!isObject(doc)) { r.structure = "the file is not a JSON object"; return r; }
    if (doc.version !== VERSION) {
        r.structure = typeof doc.version === "number" && doc.version > VERSION
            ? "made for a newer version of the shell (version " + doc.version + ")" : "missing or invalid version";
        return r;
    }
    for (var k in doc) {
        if (k === "version") continue;
        if (KINDS.indexOf(k) < 0) { r.errors.push({ kind: k, error: "unknown provider type" }); continue; }
        var c = checkKind(k, doc[k], home || "");
        if (c.ok) r.providers[k] = c.provider;
        else r.errors.push({ kind: k, error: c.error });
    }
    return r;
}

/**
 * El argv de `verb` con sus argumentos (`args`: { path, output, json, wall, preset }), o null si el proveedor
 * no lo declara o falta un argumento. Nada se interpola en una línea de shell: cada argumento es un
 * elemento del argv.
 */
function command(provider, verb, args) {
    if (!provider || !provider.verbs || provider.verbs[verb] === undefined) return null;
    var tmpl = VERBS[provider.kind][verb];
    var tail = [];
    args = args || {};
    for (var i = 0; i < tmpl.length; i++) {
        var m = /^\{(\w+)\}$/.exec(tmpl[i]);
        if (!m) { tail.push(tmpl[i]); continue; }
        var v = args[m[1]];
        if (typeof v !== "string" || v.length === 0) return null;
        // un id de preset es un nombre de archivo de sumi/palettes/: nunca una opción ni una ruta
        if (m[1] === "preset" && !/^[a-z0-9]+(-[a-z0-9]+)+$/.test(v)) return null;
        tail.push(v);
    }
    return provider.scripts[provider.verbs[verb]].argv.concat(tail);
}

/** El entorno extra de `verb` (hoy sólo WALL_TRANSITION con la marca `transition`). */
function env(provider, verb, args) {
    var out = {};
    if (!provider || provider.kind !== "wallpaper" || (verb !== "apply" && verb !== "applyOutput")) return out;
    var at = provider.flags ? provider.flags.transition : undefined;
    if (at !== undefined && at === provider.verbs[verb] && args && typeof args.transition === "string")
        out.WALL_TRANSITION = args.transition;
    return out;
}

function serialize(doc) { return JSON.stringify(doc, null, 2) + "\n"; }

if (typeof module !== "undefined")
    module.exports = { VERSION: VERSION, KINDS: KINDS, VERBS: VERBS, FLAGS: FLAGS, PATHS: PATHS,
        validate: validate, command: command, env: env, expand: expand, serialize: serialize };
