.pragma library

/**
 * BORDE Y LONGITUD DE LA BARRA PERMANENTE (2026-11-19, encuesta del autor; informe
 * docs/SUMI-BARRA-BORDES-2026-11-19.md). JS puro: lo comparten core/Screen (dónde va la barra y de dónde cuelga el
 * island), core/Bar, core/Island (el contorno unido), components/TrayMenu y la página de Settings.
 *
 * Se guarda POR MONITOR, junto a la presentación y el Notch (`shell.monitors[id]`): `barEdge` y `barLength`
 * (porcentaje del borde). La barra siempre va centrada: la longitud la encoge hacia el centro (pedido del autor, «era
 * achicarla hacia el centro con un límite»), y el límite lo pone su contenido. Un valor desconocido cae en el de
 * serie: arriba, 100 %.
 *
 * EL MARCO CANÓNICO. Todo lo que se une a la barra (el contorno del panel que cuelga, la muesca de la barra hecha
 * Notch) se dibuja como si la barra estuviera ARRIBA: `u` corre a lo largo del borde y `v` es la profundidad desde el
 * lado pegado. `mapper()` lo lleva al borde real; las curvas son afines, así que basta con llevar cada punto (los
 * tiradores de las cúbicas incluidos). Arriba es la identidad: lo de siempre no cambia ni en un decimal.
 */

var EDGES = ["top", "bottom", "left", "right"];
var DEFAULTS = { edge: "top", length: 100 };
/** Límites del valor guardado (porcentaje del borde). El mínimo real lo pone además el contenido (`limitPct`). */
var MIN_PCT = 30;
var MAX_PCT = 100;
var STEP_PCT = 5;

function edgeOf(v) { return EDGES.indexOf(v) >= 0 ? v : DEFAULTS.edge; }
function lengthOf(v) {
    var n = Number(v);
    if (!isFinite(n)) return DEFAULTS.length;
    return Math.max(MIN_PCT, Math.min(MAX_PCT, Math.round(n)));
}
function vertical(e) { return e === "left" || e === "right"; }
/** Hacia dentro de la pantalla, en el eje normal: +1 desde arriba o la izquierda, −1 desde abajo o la derecha. */
function inward(e) { return (e === "bottom" || e === "right") ? -1 : 1; }
/** Lo que se abre desde la barra crece hacia aquí (para textos y pruebas). */
function opensTowards(e) {
    return e === "bottom" ? "up" : e === "left" ? "right" : e === "right" ? "left" : "down";
}
function edgeLabel(e) { return e.charAt(0).toUpperCase() + e.slice(1); }

/**
 * Tramo de la barra a lo largo de su borde, CENTRADO: { start, len } en px del área (ancho o alto de la pantalla,
 * `along`). `gap` es el margen con las esquinas de la pantalla; `minLen`, lo que su contenido no puede plegar. El
 * porcentaje es del borde sin los márgenes; nunca sale de la pantalla y nunca baja de `minLen` (salvo que la pantalla
 * sea menor).
 */
function span(along, gap, pct, minLen) {
    var avail = Math.max(0, along - 2 * gap);
    var want = avail * lengthOf(pct) / 100;
    var len = Math.min(avail, Math.max(want, Math.min(minLen || 0, avail)));
    return { start: gap + (avail - len) / 2, len: len };
}
/**
 * El límite en el deslizador: el porcentaje (múltiplo de `STEP_PCT`, hacia arriba) por debajo del cual la barra ya no
 * encoge, para `minLen` px de contenido en `avail` px de borde. Sin datos, `MIN_PCT`.
 */
function limitPct(minLen, avail) {
    if (!(avail > 0) || !(minLen > 0)) return MIN_PCT;
    var p = Math.ceil(minLen / avail * 100 / STEP_PCT) * STEP_PCT;
    return Math.max(MIN_PCT, Math.min(MAX_PCT, p));
}

/**
 * Rectángulo de la barra en el área W × H: `thick` es su grosor, `normal` la distancia al borde de la pantalla (el
 * hueco de siempre; 0 hecha muesca) y `sp` lo que dio `span()` en el eje del borde.
 */
function rect(e, W, H, thick, normal, sp) {
    switch (edgeOf(e)) {
    case "bottom": return { x: sp.start, y: H - thick - normal, w: sp.len, h: thick };
    case "left": return { x: normal, y: sp.start, w: thick, h: sp.len };
    case "right": return { x: W - thick - normal, y: sp.start, w: thick, h: sp.len };
    }
    return { x: sp.start, y: normal, w: sp.len, h: thick };
}

/**
 * Del marco canónico (u a lo largo, v hacia dentro desde el lado pegado) a coordenadas de un objeto de w × h pegado
 * a la barra por su lado `e`. Devuelve "x y" para escribir en un trazado SVG.
 */
function mapper(e, w, h) {
    switch (edgeOf(e)) {
    case "bottom": return function (u, v) { return u + " " + (h - v); };
    case "left": return function (u, v) { return v + " " + u; };
    case "right": return function (u, v) { return (w - v) + " " + u; };
    }
    return function (u, v) { return u + " " + v; };
}
/** Largo (a lo largo del borde) y fondo (hacia dentro) de un objeto de w × h pegado por `e`. */
function alongOf(e, w, h) { return vertical(e) ? h : w; }
function depthOf(e, w, h) { return vertical(e) ? w : h; }

/**
 * Las dos esquinas del lado pegado a la barra, para un `Rectangle` con radios por esquina: { tl, tr, bl, br } con
 * true en las que tocan la barra.
 */
function joinedCorners(e) {
    switch (edgeOf(e)) {
    case "bottom": return { tl: false, tr: false, bl: true, br: true };
    case "left": return { tl: true, tr: false, bl: true, br: false };
    case "right": return { tl: false, tr: true, bl: false, br: true };
    }
    return { tl: true, tr: true, bl: false, br: false };
}

/**
 * Dónde va algo de w × h que sale de la barra (menú, tooltip, More), pegado a `gap` de su lado interior y centrado en
 * `c` a lo largo, sin salirse de [lo, hi] en ese eje. `inner` es la coordenada del lado interior de la barra en el eje
 * normal. Devuelve { x, y }.
 */
function popup(e, inner, c, w, h, gap, lo, hi) {
    var ed = edgeOf(e);
    var len = vertical(ed) ? h : w;
    var a = Math.max(lo, Math.min(hi - len, c - len / 2));
    switch (ed) {
    case "bottom": return { x: a, y: inner - gap - h };
    case "left": return { x: inner + gap, y: a };
    case "right": return { x: inner - gap - w, y: a };
    }
    return { x: a, y: inner + gap };
}

/** Centros en orden horario. Una unidad recorre de un centro al siguiente, en píxeles de arco. */
var ringEdges = ["top", "right", "bottom", "left"];
function nearestStop(position, edge) {
    var delta = (ringEdges.indexOf(edgeOf(edge)) - position) % 4;
    if (delta > 2) delta -= 4;
    if (delta <= -2) delta += 4;
    return position + delta;
}

function rimPoint(position, width, height, inset, bend) {
    var pos = ((position % 4) + 4) % 4;
    var side = Math.floor(pos), vertical = side % 2 === 1;
    var a = Math.max(0, (vertical ? height : width) / 2 - inset);
    var b = Math.max(0, (vertical ? width : height) / 2 - inset);
    var r = Math.max(0, Math.min(bend, a, b));
    var arc = r * Math.PI / 2;
    var d = (pos - side) * (a + b - 2 * r + arc);
    var u, v, angle;
    if (d <= a - r) {
        u = d; v = -b; angle = 0;
    } else if (d < a - r + arc) {
        angle = (d - a + r) / r;
        u = a - r + r * Math.sin(angle);
        v = -b + r * (1 - Math.cos(angle));
    } else {
        u = a; v = -b + r + (d - (a - r + arc)); angle = Math.PI / 2;
    }
    var x = [u, -v, -u, v][side], y = [v, u, -v, -u][side];
    return { x: width / 2 + x, y: height / 2 + y, angle: side * 90 + angle * 180 / Math.PI };
}
