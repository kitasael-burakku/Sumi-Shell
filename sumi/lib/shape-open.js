.pragma library
.import "window-open.js" as WinOpen
/*
 * Estilos de forma (2026-11-21, ADR-40): cómo sale la forma del island desde el reposo y cómo vuelve a él. Dos listas,
 * con los nombres de Window style donde se parecen (lib/window-open.js):
 *   - Bar panels (con la barra permanente): Slide y Grow son lo de antes (muelles de core/Morph); Spring, Unfold, Flap,
 *     Bloom, Ink y Mist tienen línea de tiempo.
 *   - Island style (island y notch, sin barra): Fluid es lo de antes; Mochi, Drop, Jelly, Power-on, Bloom, Ink y Mist
 *     tienen línea de tiempo.
 * Funciones puras (sin QML) para que core/Island, las miniaturas de Settings y node (tools/shape-open/curves-test.js)
 * lean exactamente lo mismo.
 *
 * Marco canónico: `a` es el largo A LO LARGO del lado pegado (el ancho con la island o la barra arriba/abajo) y `d` la
 * PROFUNDIDAD hacia dentro (el alto); `r` el radio. Todo en px ya multiplicados por la escala `s`.
 *
 * `v` avanza lineal en el tiempo: abrir 0 → 1 en `openMs`, cerrar 1 → 0 en `closeMs`. `rest` y `open` son los dos
 * extremos: abriendo, `rest` es lo que se veía al empezar (foto) y `open` el destino vivo; cerrando, al revés (`open`
 * la foto y `rest` el destino vivo). Así v = 1 da exactamente `open` y v = 0 exactamente `rest`: el muelle de siempre
 * recoge la forma al acabar sin salto.
 */

const clamp = WinOpen.clamp;
const lerp = WinOpen.lerp;
const outCubic = WinOpen.outCubic;
const outQuint = WinOpen.outQuint;
const inOutQuad = WinOpen.inOutQuad;
const springStep = WinOpen.springStep;

/** Muelle crítico (ζ = 1) desde el reposo; llega al 99 % con w·t ≈ 6,6. */
function critStep(t, w) { return t <= 0 ? 0 : 1 - (1 + w * t) * Math.exp(-w * t); }

/** El reloj ya está normalizado por la duración de cierre. */
function closeEase(v) {
    const t = 1 - v;
    return 1 - WinOpen.settleSpring(critStep(t, 7.2), t);
}

/** Respuesta elástica con un final continuo también en paneles grandes. */
function openSpring(t, w, damping, v) {
    return WinOpen.settleSpring(springStep(t, w, damping), v);
}
/** Motion.enter con el relevo de Normal (`handoff` ≈ 0,55): el contenido entra detrás de la forma. */
function enterOf(k) { return Math.pow(clamp((k - 0.55) / 0.37), 1.15); }

/** Fundido de Mochi y Jelly en función del espacio disponible en ambos ejes. */
function elasticContent(k) {
    const p = clamp((k - 0.2) / 0.7);
    return p * p * (3 - 2 * p);
}

/** Los estilos con línea de tiempo, por familia; los demás (slide, grow, fluid) no pasan por aquí. */
const BAR = ["spring", "unfold", "flap", "bloom", "ink", "mist"];
const ISLAND = ["mochi", "drop", "jelly", "poweron", "bloom", "ink", "mist"];
/** La línea de tiempo lleva también la geometría (si no, la llevan los muelles de Morph y la línea sólo los efectos). */
const GEOM = { bar: ["spring", "unfold", "flap", "bloom", "ink"], island: ["mochi", "drop", "jelly", "poweron", "bloom"] };
/** Simétricos: cerrar recorre la curva de abrir al revés. */
const SYM = { bar: ["unfold", "bloom", "ink", "mist"], island: ["poweron", "bloom", "ink", "mist"] };

function timeline(kind, name) { return (kind === "bar" ? BAR : ISLAND).indexOf(name) >= 0; }
function drivesGeometry(kind, name) { return (GEOM[kind] || []).indexOf(name) >= 0; }
function symmetric(kind, name) { return (SYM[kind] || []).indexOf(name) >= 0; }
/** Estos estilos revelan el panel desde la unión con la barra o el borde superior de la isla. */
function anchorsContent(kind, name) {
    // Spring conserva el deslizamiento del cajón; Flap gira contenido y forma juntos.
    return kind === "bar" ? BAR.includes(name) && name !== "spring" && name !== "flap" : ISLAND.includes(name);
}

const NONE = { tint: 0, glow: 0, ink: -1, ring: 0, blur: 0, zoom: 1, rot: 0, shade: 0, cOp: -1, c: 1 };
function fx(o) { const r = {}; for (const k in NONE) r[k] = (k in o) ? o[k] : NONE[k]; return r; }

/**
 * Un fotograma. Devuelve { a, d, r } (sólo con `drivesGeometry`; si no, null) y los efectos:
 *   tint, glow  0–1  relleno del acento sobre la forma y halo alrededor
 *   ink         −1 = sin máscara; 0–1 radio de la gota (fracción de lo que hace falta para cubrirlo todo)
 *   ring        0–1  aro del acento en el borde de la gota
 *   blur        0–1  desenfoque del contenido (MultiEffect.blur)
 *   zoom        escala del contenido (1 = nada)
 *   rot, shade  la solapa (Flap): grados desde plana (positivo = levantada hacia quien mira) y sombra 0–1
 *   cOp         −1 = el relevo de siempre; 0–1 = opacidad del contenido que pide el estilo
 *   c           0–1  centro a lo largo: del acceso que lo abrió (0) a su sitio (1); sólo barra (Unfold, Bloom, Ink)
 * `o` = { s, openS, closeS, pill(h), btn } (escala, segundos de abrir y de cerrar, radio de cápsula del estilo de
 * interfaz y, con la barra, dónde cae el acceso a lo largo del panel abierto, en px desde su principio).
 */
function frame(kind, name, v, opening, rest, open, o) {
    const f = styledFrame(kind, name, v, opening, rest, open, o);
    if (o.reduced) {
        f.fx.tint *= 0.48;
        f.fx.glow *= 0.35;
        f.fx.ring *= 0.5;
        f.fx.blur *= 0.35;
        f.fx.zoom = 1 + (f.fx.zoom - 1) * 0.3;
    }
    return f;
}

function styledFrame(kind, name, v, opening, rest, open, o) {
    v = clamp(v);
    const s = o.s || 1, openS = o.openS || 0.4;
    const pill = o.pill || ((h) => h / 2);
    const t = v * openS;
    const g = (a, d, r) => ({ a: a, d: d, r: Math.max(0, r) });
    if (kind === "bar") {
        if (name === "spring") {
            const k = opening ? openSpring(t, 19, o.reduced ? 0.98 : 0.69, v) : closeEase(v);
            return { geom: g(open.a, lerp(rest.d, open.d, k), open.r), fx: fx({}) };
        }
        if (name === "unfold") {
            const sp = 0.4, thin = Math.min(open.d, 3 * s);
            if (v < sp) {
                const q = outCubic(v / sp);
                return { geom: g(lerp(0.1 * open.a, open.a, q), lerp(rest.d, thin, clamp(v / 0.06)), Math.min(open.r, thin / 2)),
                         fx: fx({ tint: 0.85, glow: 0.7 * q, c: q }) };
            }
            const t2 = (v - sp) / (1 - sp), q = outCubic(t2 * t2 * (2 - t2));
            // el color se apaga con el tiempo, no con la forma (como Bloom en lib/window-open.js)
            return { geom: g(open.a, lerp(thin, open.d, q), lerp(Math.min(open.r, thin / 2), open.r, q)),
                     fx: fx({ tint: 0.85 * (1 - inOutQuad(Math.min(1, t2 * 2.2))), glow: 0.7 * (1 - inOutQuad(Math.min(1, t2 * 1.4))), c: 1 }) };
        }
        if (name === "flap") {
            const k = opening ? openSpring(t, 18, 0.76, v) : closeEase(v);
            const rot = (o.reduced ? 14 : 88) * (1 - k);
            return { geom: g(open.a, o.reduced ? lerp(rest.d, open.d, clamp(k)) : v > 0 ? open.d : rest.d, open.r),
                     fx: fx({ rot: rot, shade: 0.5 * Math.sin(Math.max(0, rot) * Math.PI / 180) }) };
        }
        if (name === "bloom") {
            const sp = 0.34, cap = Math.min(open.d, 6 * s);
            if (v < sp) {
                const q = outCubic(v / sp);
                return { geom: g(lerp(0.08 * open.a, open.a, q), lerp(rest.d, cap, clamp(v / 0.05)), pill(cap)),
                         fx: fx({ tint: 1, glow: 1, cOp: 0, c: q }) };
            }
            const t2 = (v - sp) / (1 - sp), q = outCubic(t2 * t2 * (2 - t2));
            return { geom: g(open.a, lerp(cap, open.d, q), lerp(pill(cap), open.r, q)),
                     fx: fx({ tint: 1 - inOutQuad(Math.min(1, t2 * 2.2)), glow: 1 - inOutQuad(Math.min(1, t2 * 1.4)),
                              cOp: clamp((t2 - 0.12) / 0.4), c: 1 }) };
        }
        if (name === "ink") {
            // una gota de verdad: la forma es el trozo del círculo (centro en el acceso, sobre el borde de la barra) que
            // cae dentro del panel, con las esquinas de una gota que se vuelven las del panel; el contenido, con la
            // misma máscara circular (core/Island la aplica sólo al contenido: una capa en la forma entera recortaría
            // los filetes, que quedan fuera del Item; medido con tools/shape-open/qmltest.py)
            const e = WinOpen.spreading(v);
            const btn = Math.max(0, Math.min(open.a, (o.btn !== undefined) ? o.btn : open.a / 2));
            const reach = Math.max(Math.hypot(btn, open.d), Math.hypot(open.a - btn, open.d));
            const R = e * reach;
            const lo = Math.max(0, btn - R), hi = Math.min(open.a, btn + R);
            const a = Math.max(0, hi - lo), d = Math.min(open.d, R);
            const mid = (lo + hi) / 2, far = open.a / 2 - btn;
            const c = v >= 1 ? 1 : Math.abs(far) < 0.5 ? 1 : clamp((mid - btn) / far);
            const blobR = Math.min(a / 2, d);
            const k = clamp((R - open.d) / Math.max(1, reach - open.d));
            return { geom: g(v >= 1 ? open.a : a, v >= 1 ? open.d : lerp(rest.d, d, clamp(v * 40)), lerp(blobR, open.r, k * k * (3 - 2 * k))),
                     fx: fx({ ink: e, ring: 0.75 * (1 - e) * clamp(v * 8), c: c }) };
        }
        if (name === "mist") {
            const e = WinOpen.spreading(v);
            return { geom: null, fx: fx({ blur: 1 - e, zoom: 1.05 - 0.05 * e, cOp: clamp(e * 1.6) }) };
        }
        return { geom: null, fx: fx({}) };
    }
    // island y notch
    if (name === "mochi") {
        if (!opening) {
            const k = closeEase(v);
            return { geom: g(lerp(rest.a, open.a, k), lerp(rest.d, open.d, k), lerp(rest.r, open.r, k)), fx: fx({ cOp: elasticContent(k) }) };
        }
        const kw = openSpring(t, 24, o.reduced ? 0.98 : 0.58, v);
        const kh = openSpring(t - 0.035, 20, o.reduced ? 0.98 : 0.58, v);
        return { geom: g(lerp(rest.a, open.a, kw), lerp(rest.d, open.d, kh), lerp(rest.r, open.r, clamp(Math.min(kw, kh)))),
                 fx: fx({ cOp: elasticContent(Math.min(kw, kh)) }) };
    }
    if (name === "jelly") {
        if (!opening) {
            const k = closeEase(v);
            return { geom: g(lerp(rest.a, open.a, k), lerp(rest.d, open.d, k), lerp(rest.r, open.r, k)), fx: fx({ cOp: elasticContent(k) }) };
        }
        const kw = openSpring(t, 18, o.reduced ? 0.94 : 0.49, v);
        const kh0 = openSpring(t - (o.reduced ? 0.025 : 0.06), 18, o.reduced ? 0.94 : 0.49, v);
        const kh = Math.max(-0.25, kh0 - 1.6 * Math.max(0, kw - 1));
        return { geom: g(lerp(rest.a, open.a, kw), lerp(rest.d, open.d, kh), lerp(rest.r, open.r, clamp(Math.min(kw, kh)))),
                 fx: fx({ cOp: elasticContent(Math.min(kw, kh)) }) };
    }
    if (name === "drop") {
        if (!opening) {
            const u = 1 - v, ka = outCubic(clamp(u / 0.5)), kb = outCubic(clamp((u - 0.5) / 0.5));
            return { geom: g(lerp(open.a, rest.a, kb), lerp(open.d, rest.d, ka), lerp(open.r, rest.r, ka)), fx: fx({}) };
        }
        const sp = 0.42;
        if (v < sp) return { geom: g(lerp(rest.a, open.a, outCubic(v / sp)), rest.d, rest.r), fx: fx({ cOp: 0 }) };
        const kh = openSpring((v - sp) * openS, 24, o.reduced ? 0.98 : 0.74, v);
        return { geom: g(open.a, lerp(rest.d, open.d, kh), lerp(rest.r, open.r, clamp(kh))), fx: fx({ cOp: enterOf(clamp(kh)) }) };
    }
    if (name === "poweron") {
        const x = inOutQuad(v), sp = 0.4, line = Math.min(rest.d, 3 * s), lr = Math.min(rest.r, 1.5 * s);
        if (x < sp) {
            const q = WinOpen.softStep(x / sp);
            // la línea llega antes que el ancho: se ve ensancharse ya hecha línea (como el Power-on de las ventanas)
            const ql = clamp(q / 0.65);
            return { geom: g(lerp(rest.a, open.a, q), lerp(rest.d, line, ql), lerp(rest.r, lr, ql)),
                     fx: fx({ tint: 0.55 * q, glow: 0.8 * q, cOp: 0 }) };
        }
        const q = WinOpen.softStep((x - sp) / (1 - sp));
        return { geom: g(open.a, lerp(line, open.d, q), lerp(lr, open.r, q)),
                 fx: fx({ tint: 0.55 * (1 - q), glow: 0.8 * (1 - q), cOp: clamp((q - 0.35) / 0.5) }) };
    }
    if (name === "bloom") {
        const sp = 0.36;
        if (v < sp) {
            const q = outCubic(v / sp);
            return { geom: g(lerp(rest.a, open.a, q), rest.d, rest.r), fx: fx({ tint: 1, glow: 1, cOp: 0 }) };
        }
        const t2 = (v - sp) / (1 - sp), q = outCubic(t2 * t2 * (2 - t2));
        return { geom: g(open.a, lerp(rest.d, open.d, q), lerp(rest.r, open.r, q)),
                 fx: fx({ tint: 1 - inOutQuad(Math.min(1, t2 * 2.2)), glow: 1 - inOutQuad(Math.min(1, t2 * 1.4)),
                          cOp: clamp((t2 - 0.2) / 0.45) }) };
    }
    if (name === "ink") {
        const e = WinOpen.spreading(v);
        return { geom: null, fx: fx({ ink: e, ring: 0.75 * (1 - e) * clamp(v * 8), cOp: 1 }) };
    }
    if (name === "mist") {
        const e = WinOpen.spreading(v);
        return { geom: null, fx: fx({ blur: 1 - e, zoom: 1.045 - 0.045 * e, cOp: clamp(e * 1.5) }) };
    }
    return { geom: null, fx: fx({}) };
}

/** Mezcla de efectos (el relevo al cambiar de rumbo a mitad): de `a` a `b` con w 0–1. */
function mixFx(a, b, w) {
    const r = {};
    for (const k in NONE) {
        const x = (a && k in a) ? a[k] : NONE[k], y = (b && k in b) ? b[k] : NONE[k];
        // la máscara y la opacidad pedida tienen −1 = «nada»: sin mezcla con un valor real (se toma el destino)
        r[k] = (k === "ink" || k === "cOp") && (x < 0 || y < 0) ? y : lerp(x, y, w);
    }
    return r;
}
/** ¿Hace falta la capa de efecto sobre el contenido (máscara de la gota, desenfoque)? */
function contentLayer(kind, name) { return name === "mist" || name === "ink"; }

/**
 * Las miniaturas de Settings (components/ShapeStylePreview): también los estilos de muelle (Slide, Grow, Fluid, y la
 * forma de Ink y Mist de la island), aproximados con el muelle crítico de core/Morph, para dibujar todos igual.
 */
function preview(kind, name, v, opening, rest, open, o) {
    const f = frame(kind, name, v, opening, rest, open, o);
    if (f.geom) return f;
    const elapsed = (opening ? v * o.openS : (1 - v) * o.closeS) * (o.tempo || 1);
    const rate = opening ? 1 : (o.returnRate || 1);
    const p = o.reduced ? outCubic(clamp(elapsed * rate / 0.18)) : critStep(elapsed, 30 * rate);
    const k = v <= 0 ? 0 : v >= 1 ? 1 : opening ? p : 1 - p;
    if (kind === "bar" && name !== "grow")
        f.geom = { a: open.a, d: lerp(rest.d, open.d, k), r: open.r };
    else
        f.geom = { a: lerp(rest.a, open.a, k), d: lerp(rest.d, open.d, k), r: lerp(rest.r, open.r, k) };
    if (kind === "bar" && name === "grow") f.fx.c = k;
    if (f.fx.cOp < 0) f.fx.cOp = kind === "bar" && name !== "grow" ? 1 : (opening ? enterOf(k) : clamp(k * 1.6 - 0.6));
    return f;
}
