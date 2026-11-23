.pragma library
/*
 * Búsqueda del selector de emojis y glifos (services/Emoji.qml, 2026-11-17).
 *
 * No usa lib/fuzzy.js a propósito: con la consulta vacía ordena por nombre (aquí manda el
 * orden de Unicode/CLDR, que agrupa caras con caras) y su coincidencia por subsecuencia
 * contra todas las palabras clave llena de ruido 10 600 glifos («fire» casa con «fi…r…e»
 * en cientos de nombres). Aquí sólo cuentan principios de palabra y subcadenas.
 *
 * Datos (lib/emoji/*.json, tools/emoji/build-data.py): cada elemento trae `s`, las
 * palabras del nombre primero y luego las claves en/es, YA plegadas (minúsculas, sin
 * tildes) con la misma regla que fold() de aquí. La consulta se pliega igual: «corazón»,
 * «corazon» y «CORAZÓN» buscan lo mismo.
 *
 * Puntos por término (menos es mejor), sumados entre términos; todos deben casar:
 *   0  es la primera palabra del nombre        («fire» → 🔥 fire)
 *   1  el nombre empieza por el término         («fire» → 🧑‍🚒 firefighter)
 *   2  es una palabra entera en cualquier sitio («fuego» → 🔥, clave en español)
 *   3  alguna palabra empieza por el término
 *   4  subcadena en cualquier sitio
 * Pegar el carácter mismo (🔥, →) lo pone el primero; un nombre igual a la consulta entera
 * resta un punto. Empates: uso, luego nombre más corto («fire» antes que «fire engine»),
 * luego orden original.
 */

// Plegado sin String.prototype.normalize: no consta en todas las versiones del motor de QML,
// y para en/es basta esta tabla (la misma cobertura que deja el NFD de Python en los datos).
var FOLD = {
    "á": "a", "à": "a", "â": "a", "ä": "a", "ã": "a", "å": "a",
    "é": "e", "è": "e", "ê": "e", "ë": "e",
    "í": "i", "ì": "i", "î": "i", "ï": "i",
    "ó": "o", "ò": "o", "ô": "o", "ö": "o", "õ": "o",
    "ú": "u", "ù": "u", "û": "u", "ü": "u",
    "ñ": "n", "ç": "c", "ý": "y", "ÿ": "y"
};
var SEP = /[\s_\-:,.\/()|]+/;

function fold(s) {
    var low = String(s || "").toLowerCase();
    var out = "";
    for (var i = 0; i < low.length; i++) {
        var ch = low[i];
        out += FOLD[ch] !== undefined ? FOLD[ch] : ch;
    }
    return out;
}

function terms(query) {
    var parts = fold(query).split(SEP);
    var out = [];
    for (var i = 0; i < parts.length; i++) if (parts[i].length > 0) out.push(parts[i]);
    return out;
}

/**
 * Del JSON a la lista que usa la vista: { c, n, g, h, i }. `h` lleva espacios a los dos
 * lados para que « t» encuentre principios de palabra con un solo indexOf. También agrupa
 * por grupo (byGroup[g] = [elementos]) y por carácter (byChar[c] = elemento).
 */
function prepare(data) {
    var src = (data && data.items) || [];
    var items = [];
    var byGroup = [];
    var byChar = {};
    var groups = (data && data.groups) || [];
    for (var g = 0; g < groups.length; g++) byGroup.push([]);
    for (var i = 0; i < src.length; i++) {
        var it = src[i];
        var e = { c: String(it.c), n: String(it.n || ""), g: it.g | 0, h: " " + String(it.s || "") + " ", i: i };
        e.f = terms(e.n).join(" ");
        items.push(e);
        if (e.g >= 0 && e.g < byGroup.length) byGroup[e.g].push(e);
        byChar[e.c] = e;
    }
    return { groups: groups, items: items, byGroup: byGroup, byChar: byChar };
}

function termScore(h, t) {
    var at = h.indexOf(" " + t);
    if (at < 0) return h.indexOf(t) >= 0 ? 4 : -1;
    if (at === 0) return h.charAt(t.length + 1) === " " ? 0 : 1;
    if (h.indexOf(" " + t + " ") >= 0) return 2;
    return 3;
}

function usesOf(usage, key) {
    var u = usage ? usage[key] : undefined;
    return u && typeof u.n === "number" ? u.n : 0;
}

/**
 * Resultados de `query` en `set` (de prepare). `usage` es { clave: {n, t} } y `prefix` la
 * parte de la clave que identifica la pestaña («emoji:», …). `limit` corta la lista (0 = todo).
 */
function search(set, query, usage, prefix, limit) {
    var items = (set && set.items) || [];
    var raw = String(query || "").trim();
    var ts = terms(raw);
    if (ts.length === 0 && raw.length === 0) return [];
    var whole = ts.join(" ");
    var scored = [];
    for (var i = 0; i < items.length; i++) {
        var e = items[i];
        var total = 0;
        if (raw.length > 0 && e.c === raw) {
            total = -1;
        } else {
            if (ts.length === 0) continue;
            for (var k = 0; k < ts.length; k++) {
                var s = termScore(e.h, ts[k]);
                if (s < 0) { total = -2; break; }
                total += s;
            }
            if (total === -2) continue;
            if (e.f === whole) total -= 1;
        }
        scored.push({ e: e, s: total, u: usesOf(usage, (prefix || "") + e.c) });
    }
    scored.sort(function (a, b) {
        if (a.s !== b.s) return a.s - b.s;
        if (a.u !== b.u) return b.u - a.u;
        if (a.e.f.length !== b.e.f.length) return a.e.f.length - b.e.f.length;
        return a.e.i - b.e.i;
    });
    var n = limit > 0 ? Math.min(limit, scored.length) : scored.length;
    var out = [];
    for (var j = 0; j < n; j++) out.push(scored[j].e);
    return out;
}

/** Los `n` usados más recientemente de esta pestaña que siguen existiendo en `set`. */
function recent(set, usage, prefix, n) {
    var keys = [];
    for (var key in usage) {
        if (key.indexOf(prefix) !== 0) continue;
        var c = key.substring(prefix.length);
        if (set && set.byChar[c]) keys.push({ e: set.byChar[c], t: usage[key].t || 0 });
    }
    keys.sort(function (a, b) { return b.t - a.t; });
    var out = [];
    for (var i = 0; i < keys.length && i < n; i++) out.push(keys[i].e);
    return out;
}

/** Los `n` más usados de la pestaña (para ordenar «Frequent»); empate: el más reciente. */
function frequent(set, usage, prefix, n) {
    var keys = [];
    for (var key in usage) {
        if (key.indexOf(prefix) !== 0) continue;
        var c = key.substring(prefix.length);
        if (set && set.byChar[c]) keys.push({ e: set.byChar[c], n: usage[key].n || 0, t: usage[key].t || 0 });
    }
    keys.sort(function (a, b) { return a.n !== b.n ? b.n - a.n : b.t - a.t; });
    var out = [];
    for (var i = 0; i < keys.length && i < n; i++) out.push(keys[i].e);
    return out;
}

/** Uso nuevo con un elegido más: objeto NUEVO (QML compara `var` por referencia). */
function bump(usage, key, now) {
    var next = {};
    for (var k in usage) next[k] = usage[k];
    var prev = next[key];
    next[key] = { n: (prev && prev.n ? prev.n : 0) + 1, t: now };
    return next;
}

if (typeof module !== "undefined")
    module.exports = { fold: fold, terms: terms, prepare: prepare, search: search,
                       recent: recent, frequent: frequent, bump: bump };
