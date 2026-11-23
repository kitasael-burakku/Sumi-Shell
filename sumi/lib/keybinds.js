.pragma library
// Ayuda de atajos (2026-10-30): de `hyprctl -j binds` a «qué tecla abre cada acción de la shell». Puro (sin QML), lo prueba
// tools/keybinds/keybinds-test.js con binds reales de Hyprland 0.57 (tools/keybinds/binds-probe.py).
//
// Lo medido en 0.57 con config Lua (2026-10-30): un bind de `hl.dsp.global(…)` sale con `dispatcher`
// «HL.Dispatcher(global)» y un `arg` que es un NÚMERO interno (cambia al reordenar la config): Hyprland no dice QUÉ
// atajo global llama. Una función de Lua sale como «function: 0x…». La `description` es lo único que nombra la acción,
// y es texto libre: sólo vale si el bind es de verdad un global. Con hyprland.conf (≤ 0.56) `arg` es «sumi:<nombre>»
// y la acción sí se verifica.
//
// Tres estados por acción, y nunca una tecla sugerida como si fuera la de verdad:
//   bound    Hyprland tiene al menos un bind identificado (conf: por su arg; Lua: global + descripción de la convención)
//   unknown  no se identificó ninguno, pero Hyprland tiene binds globales sin nombre (o una función con su descripción):
//            puede ser uno de ellos; la combinación no se puede determinar
//   unbound  nada en Hyprland se puede verificar que la abra (las funciones de Lua no se pueden inspeccionar: se dice)
// Si los binds no se pudieron leer, el servicio no llama a resolve(): eso es otro estado («unread») en la vista.

var MODS = [[64, "SUPER"], [4, "CTRL"], [8, "ALT"], [1, "SHIFT"], [2, "CAPS"], [16, "MOD2"], [32, "MOD3"], [128, "MOD5"]];
var BITS = { SUPER: 64, WIN: 64, LOGO: 64, MOD4: 64, CTRL: 4, CONTROL: 4, ALT: 8, MOD1: 8, SHIFT: 1, CAPS: 2,
             MOD2: 16, MOD3: 32, MOD5: 128 };
var PRETTY_MOD = { SUPER: "Super", CTRL: "Ctrl", ALT: "Alt", SHIFT: "Shift", CAPS: "Caps", MOD2: "Mod2", MOD3: "Mod3",
                   MOD5: "Mod5" };
var PRETTY_KEY = { SPACE: "Space", ESCAPE: "Esc", RETURN: "Enter", TAB: "Tab", SLASH: "/", BACKSLASH: "\\",
                   PERIOD: ".", COMMA: ",", MINUS: "-", EQUAL: "=", SEMICOLON: ";", APOSTROPHE: "'", GRAVE: "`",
                   BRACKETLEFT: "[", BRACKETRIGHT: "]", BACKSPACE: "Backspace", DELETE: "Delete", PRINT: "Print",
                   UP: "↑", DOWN: "↓", LEFT: "←", RIGHT: "→", HOME: "Home", END: "End", PRIOR: "Page Up",
                   NEXT: "Page Down", INSERT: "Insert" };

function modNames(mask) {
    var out = [];
    for (var i = 0; i < MODS.length; i++)
        if ((mask & MODS[i][0]) !== 0) out.push(MODS[i][1]);
    return out;
}

function prettyKey(key) {
    var k = String(key || "");
    var up = k.toUpperCase();
    if (PRETTY_KEY[up]) return PRETTY_KEY[up];
    if (/^mouse:/i.test(k)) return "Mouse " + k.slice(6);
    if (/^code:/i.test(k)) return "Keycode " + k.slice(5);
    return k.length === 1 ? up : k.charAt(0).toUpperCase() + k.slice(1);
}

/** Las teclas visibles de un bind de `hyprctl binds -j`: ["Super", "Ctrl", "W"]. */
function capsOf(b) {
    var caps = modNames(b.modmask || 0).map(function (m) { return PRETTY_MOD[m] || m; });
    var key = String(b.key || "");
    if (key.length === 0 && b.keycode) key = "code:" + b.keycode;
    caps.push(prettyKey(key));
    return caps;
}

/** «SUPER + CTRL + W» (la forma del catálogo y de hl.bind) → {mask, key, caps}; null si no se entiende. */
function parseCombo(text) {
    var parts = String(text || "").split("+").map(function (p) { return p.trim(); }).filter(function (p) { return p.length > 0; });
    if (parts.length === 0) return null;
    var key = parts.pop();
    var mask = 0;
    for (var i = 0; i < parts.length; i++) {
        var bit = BITS[parts[i].toUpperCase()];
        if (bit === undefined) return null;
        mask |= bit;
    }
    return { mask: mask, key: key.toUpperCase(), caps: capsOf({ modmask: mask, key: key }) };
}

function comboText(caps) { return caps.join(" + "); }

/** La identidad de una combinación: lo que Hyprland compara (mods, tecla o keycode, submapa). */
function comboId(b) {
    return [b.modmask || 0, String(b.key || "").toUpperCase(), b.keycode || 0, b.submap || ""].join("|");
}

function isLuaGlobal(b) { return b.dispatcher === "HL.Dispatcher(global)"; }
function isConfGlobal(b) { return b.dispatcher === "global"; }
/** Lo que no se puede inspeccionar: una función de Lua (0.57) o `__lua` (Lua ≤ 0.56, cualquier dispatcher). */
function isOpaque(b) { return /^function: /.test(String(b.dispatcher || "")) || b.dispatcher === "__lua"; }

function flagsOf(b) {
    var f = [];
    if (b.locked) f.push("locked");
    if (b.release) f.push("release");
    if (b.repeat) f.push("repeat");
    if (b.longPress) f.push("long press");
    if (b.non_consuming) f.push("non-consuming");
    if (b.mouse) f.push("mouse");
    return f;
}

function keyEntry(b, how) {
    var caps = capsOf(b);
    return { caps: caps, text: comboText(caps), submap: String(b.submap || ""), flags: flagsOf(b), how: how,
             id: comboId(b), others: [] };
}

/**
 * actions: [{name, title}] del catálogo · binds: lo que devuelve `hyprctl -j binds` · opts: {appid, prefix}.
 * Devuelve {rows: {nombre: {state, keys, labelled, notes}}, summary}.
 */
function resolve(actions, binds, opts) {
    var appid = (opts && opts.appid) || "sumi";
    var prefix = (opts && opts.prefix !== undefined) ? opts.prefix : "Sumi Shell: ";
    var known = {};
    var rows = {};
    for (var i = 0; i < actions.length; i++) {
        known[actions[i].name] = actions[i];
        rows[actions[i].name] = { state: "unbound", keys: [], labelled: [], mislabeled: [], legacy: [], notes: [] };
    }
    var nameOfDesc = function (d) {
        d = String(d || "");
        if (d.indexOf(prefix) !== 0) return "";
        var n = d.slice(prefix.length).trim();
        return known[n] ? n : "";
    };
    // Sumi Shell (2026-11-07): las teclas que aún usan el nombre de antes (Kitasan-Shell: `kitasan:<n>` y la descripción
    // «KitasanShell: <n>») NO funcionan con esta shell: no cuentan como asignadas, se avisa en su fila.
    var legacyPrefix = (opts && opts.legacyPrefix !== undefined) ? opts.legacyPrefix : "KitasanShell: ";
    var legacyAppid = (opts && opts.legacyAppid !== undefined) ? opts.legacyAppid : "kitasan";
    var legacyOfDesc = function (d) {
        d = String(d || "");
        if (!legacyPrefix || d.indexOf(legacyPrefix) !== 0) return "";
        var n = d.slice(legacyPrefix.length).trim();
        return known[n] ? n : "";
    };
    var summary = { binds: binds.length, globals: 0, identified: 0, unnamedGlobals: 0, opaque: 0, strays: [],
                    mislabeled: 0, legacy: 0, dialect: "" };
    var markLegacy = function (n, b) {
        if (!n) return false;
        rows[n].legacy.push(keyEntry(b, "legacy"));
        summary.legacy++;
        return true;
    };
    var byCombo = {};      // comboId → [{bind, owner}] para ver qué más hace la misma combinación
    var owners = [];
    for (var j = 0; j < binds.length; j++) {
        var b = binds[j] || {};
        var owner = "";
        var how = "";
        if (isConfGlobal(b)) {
            summary.globals++;
            summary.dialect = "conf";
            var arg = String(b.arg || "");
            if (arg.indexOf(appid + ":") === 0) {
                var n = arg.slice(appid.length + 1);
                if (known[n]) { owner = n; how = "hyprland"; }
                else summary.strays.push(arg);
            } else if (legacyAppid && arg.indexOf(legacyAppid + ":") === 0) {
                if (!markLegacy(known[arg.slice(legacyAppid.length + 1)] ? arg.slice(legacyAppid.length + 1) : "", b))
                    summary.strays.push(arg);
            }
        } else if (isLuaGlobal(b)) {
            summary.globals++;
            summary.dialect = "lua";
            var dn = nameOfDesc(b.description);
            if (dn) { owner = dn; how = "description"; }
            else if (!markLegacy(legacyOfDesc(b.description), b)) summary.unnamedGlobals++;
        } else if (isOpaque(b)) {
            summary.opaque++;
            var ln = nameOfDesc(b.description);
            if (ln) rows[ln].labelled.push(keyEntry(b, "function"));
        } else {
            var mn = nameOfDesc(b.description);
            if (mn) { rows[mn].mislabeled.push(keyEntry(b, String(b.dispatcher || ""))); summary.mislabeled++; }
        }
        if (owner) {
            summary.identified++;
            rows[owner].keys.push(keyEntry(b, how));
        }
        var cid = comboId(b);
        (byCombo[cid] = byCombo[cid] || []).push({ bind: b, owner: owner });
        owners.push(owner);
    }
    // qué más hace cada combinación identificada (Hyprland ejecuta TODOS los binds de una combinación)
    for (var name in rows) {
        var r = rows[name];
        for (var k = 0; k < r.keys.length; k++) {
            var same = byCombo[r.keys[k].id] || [];
            var others = [];
            for (var m = 0; m < same.length; m++) {
                if (same[m].owner === name) continue;
                others.push(same[m].owner ? known[same[m].owner].title
                    : (isOpaque(same[m].bind) ? "a Lua function"
                       : String(same[m].bind.description || "") || String(same[m].bind.dispatcher || "another binding")));
            }
            r.keys[k].others = others;
        }
        var dups = {};
        r.keys = r.keys.filter(function (e) { if (dups[e.id]) return false; dups[e.id] = true; return true; });
        if (r.keys.length > 0) r.state = "bound";
        else if (summary.unnamedGlobals > 0 || r.labelled.length > 0) r.state = "unknown";
        else r.state = "unbound";
        if (r.labelled.length > 0)
            r.notes.push((r.labelled.length === 1 ? r.labelled[0].text + " is" : r.labelled.length + " bindings are")
                + " labelled for it but run a Lua function, which Hyprland can't show");
        if (r.legacy.length > 0)
            r.notes.push(r.legacy[0].text + " still uses the old name (kitasan:" + name + "), which this shell doesn't "
                + "answer: bind it to " + appid + ":" + name);
        if (r.mislabeled.length > 0)
            r.notes.push(r.mislabeled[0].text + " is labelled for it but runs something else ("
                + r.mislabeled[0].how.replace(/^HL\.Dispatcher\((.*)\)$/, "$1") + "): ignored");
    }
    var counts = { bound: 0, unknown: 0, unbound: 0 };
    for (var nm in rows) counts[rows[nm].state]++;
    summary.counts = counts;
    return { rows: rows, summary: summary };
}

/**
 * El texto de la búsqueda frente a una fila. Dos maneras de coincidir, nunca mezcladas (una palabra del texto y otra de
 * la tecla no suman: «super ctrl w» no encuentra Network por la «w» de su nombre):
 *   · texto: cada palabra está en el título, el nombre, el identificador o la descripción;
 *   · tecla: cada palabra es una tecla de UNA misma combinación efectiva («super w», «ctrl+alt+t»). Con «+» la
 *     combinación tiene que ser exactamente ésa («super+w» no encuentra Super+Ctrl+W).
 * Sólo se buscan las teclas efectivas: la tecla por defecto no se busca como si fuera la de verdad.
 */
function matches(query, action, row) {
    var q = String(query || "").trim().toLowerCase();
    if (q.length === 0) return true;
    var exact = q.indexOf("+") !== -1;
    var words = q.replace(/\+/g, " ").split(/\s+/).filter(function (w) { return w.length > 0; });
    if (!exact) {
        var hay = [action.title, action.name, action.description, "sumi:" + action.name].join(" ").toLowerCase();
        var all = true;
        for (var i = 0; i < words.length && all; i++) all = hay.indexOf(words[i]) !== -1;
        if (all) return true;
    }
    var keys = row && row.keys ? row.keys : [];
    for (var k = 0; k < keys.length; k++) {
        var caps = keys[k].caps.map(function (c) { return String(c).toLowerCase(); });
        var used = {};
        var ok = true;
        for (var j = 0; j < words.length && ok; j++) {
            var w = KEY_ALIAS[words[j]] || words[j];
            var at = caps.indexOf(w);
            ok = at !== -1;
            if (ok) used[at] = true;
        }
        if (ok && (!exact || Object.keys(used).length === caps.length)) return true;
    }
    return false;
}

var KEY_ALIAS = { win: "super", meta: "super", logo: "super", control: "ctrl", escape: "esc", "return": "enter",
                  slash: "/", period: ".", spacebar: "space" };

if (typeof module !== "undefined")
    module.exports = { resolve: resolve, matches: matches, parseCombo: parseCombo, capsOf: capsOf, comboText: comboText,
                       modNames: modNames };
