.pragma library
/*
 * Aperturas de las ventanas flotantes con línea de tiempo (2026-11-17, ADR-36): las curvas de Power-on, Bloom, Mochi,
 * Ink, Scroll y Mist como funciones puras, para que theme/Reveal (la forma: sx, sy, opacidad, escala, subida) y
 * theme/RevealEffect (máscara, desenfoque, color y luz) lean exactamente lo mismo. Sin QML: se prueban con node
 * (tools/window-open/curves-test.js).
 *
 * `v` es el avance lineal en el tiempo, 0 = cerrada y 1 = abierta. Abrir recorre 0 → 1 en `openMs` y cerrar 1 → 0 en
 * `closeMs`; las curvas van dentro de cada función, así que todas salvo Mochi son simétricas: cambiar de rumbo a mitad
 * no salta, sólo invierte el camino. Mochi abre con un muelle blando (con rebote) y cierra encogiendo; al invertirse
 * parte de la forma que tenía en ese instante (`snap`).
 *
 * Las medidas en píxeles van ya multiplicadas por la escala de la interfaz `s`; las de la ventana (W, H) y su radio `r`
 * las da quien dibuja.
 */

function clamp(x) { return Math.max(0, Math.min(1, x)); }
function lerp(a, b, t) { return a + (b - a) * t; }
function outCubic(x) { return 1 - Math.pow(1 - x, 3); }
function softStep(x) { x = clamp(x); return x * x * (3 - 2 * x); }
function spreading(v) { return outCubic(v * (0.55 + 0.45 * v)); }
function outQuint(x) { return 1 - Math.pow(1 - x, 5); }
function inOutQuad(x) { return x < 0.5 ? 2 * x * x : 1 - Math.pow(-2 * x + 2, 2) / 2; }

/** El último cuarto lleva el residuo del muelle a cero con velocidad final nula. */
function settleSpring(step, progress) {
    return progress <= 0.75 ? step : lerp(step, 1, softStep((progress - 0.75) * 4));
}

/** Respuesta al escalón (0 → 1) de un muelle subamortiguado; t en segundos. */
function springStep(t, w, z) {
    if (t <= 0) return 0;
    const wd = w * Math.sqrt(1 - z * z);
    return 1 - Math.exp(-z * w * t) * (Math.cos(wd * t) + z * w / wd * Math.sin(wd * t));
}

// Particiones y constantes de cada estilo (las de la maqueta aprobada, claude.ai/artifact/NeqzQovAPQHJf5So3jiEhE)
const POWER_SPLIT = 0.4;
const BLOOM_SPLIT = 0.36;
const BLOOM_PILL = 22;          // alto de la cápsula, px·s
const SCROLL_SPLIT = 0.22;
const SCROLL_TITLE = 46;        // la franja del título que aparece primero, px·s
const MOCHI_OPEN_S = 0.52;      // segundos nominales de la apertura (antes de la velocidad global)
const MOCHI_FROM = 0.82;

const NONE = { sx: 1, sy: 1, opacity: 1, scale: 1, dy: 0 };

/**
 * La forma (lo que ya aplican las siete ventanas): sx, sy, opacity, scale y dy (px, ya con `s`).
 * `opening` y `snap` sólo los usa Mochi.
 */
function shape(name, v, s, opening, snap, reduced) {
    v = clamp(v);
    if (name === "poweron") {
        const x = inOutQuad(v);
        return {
            sx: x < POWER_SPLIT ? 0.3 + 0.7 * softStep(x / POWER_SPLIT) : 1,
            sy: x < POWER_SPLIT ? 0.012 : 0.012 + 0.988 * softStep((x - POWER_SPLIT) / (1 - POWER_SPLIT)),
            opacity: Math.min(1, x / POWER_SPLIT), scale: 1, dy: 0
        };
    }
    // los fundidos de aparición son lineales y cortos (≈ 50 ms al abrir): con una curva rápida el primer fotograma
    // saltaba a un cuarto de opacidad (tools/window-open/curves-test.js)
    if (name === "bloom")
        return { sx: 1, sy: 1, opacity: clamp(v / 0.12), scale: 1, dy: 0 };
    if (name === "scroll") {
        if (v >= SCROLL_SPLIT) return NONE;
        const q = outCubic(v / SCROLL_SPLIT);
        return { sx: 1, sy: 1, opacity: v / SCROLL_SPLIT, scale: 1, dy: -(1 - q) * (reduced ? 2 : 6) * s };
    }
    if (name === "ink") {
        const e = spreading(v);
        return { sx: 1, sy: 1, opacity: clamp(v / 0.12), scale: 1 + (reduced ? 0.009 : 0.03) * (1 - e), dy: 0 };
    }
    if (name === "mist") {
        const e = spreading(v);
        return { sx: 1, sy: 1, opacity: clamp(e * 1.5), scale: 1 + (reduced ? 0.012 : 0.038) * (1 - e), dy: 0 };
    }
    if (name === "mochi") return mochi(v, opening, snap, reduced);
    return NONE;
}

/**
 * Mochi. Abrir: x adelanta 30 ms a y, ζ 0,5 (≈3 % de rebote), aparece en 110 ms. Cerrar: encoge (más a lo alto) y se
 * funde. `snap` = {sx, sy, opacity, v0}: la forma al invertir el rumbo; abriendo se mezcla con ella los primeros 100 ms,
 * cerrando parte de ella.
 */
function mochi(v, opening, snap, reduced) {
    const start = reduced ? 0.94 : MOCHI_FROM, damping = reduced ? 0.96 : 0.58;
    if (opening) {
        const t = v * MOCHI_OPEN_S;
        const o = {
            sx: start + (1 - start) * settleSpring(springStep(t, 26, damping), v),
            sy: start + (1 - start) * settleSpring(springStep(t - (reduced ? 0.012 : 0.03), 21, damping), v),
            opacity: clamp(t / 0.11), scale: 1, dy: 0
        };
        if (snap && v < 1) {
            // Una reapertura cerca del final también termina exactamente en la forma de reposo.
            const span = Math.max(0.000001, Math.min(0.2, 1 - snap.v0));
            const w = outCubic(clamp((v - snap.v0) / span));
            o.sx = lerp(snap.sx, o.sx, w); o.sy = lerp(snap.sy, o.sy, w); o.opacity = lerp(snap.opacity, o.opacity, w);
        }
        return o;
    }
    const from = snap || { sx: 1, sy: 1, opacity: 1, v0: 1 };
    const u = from.v0 > 0 ? clamp((from.v0 - v) / from.v0) : 1;
    const e = outCubic(u);
    return { sx: lerp(from.sx, reduced ? 0.976 : 0.92, e), sy: lerp(from.sy, reduced ? 0.96 : 0.87, e), opacity: from.opacity * (1 - clamp(u * 1.15)),
             scale: 1, dy: 0 };
}

/**
 * Lo que dibuja RevealEffect sobre la tarjeta (W×H, radio r). Campos:
 *   mask       "" | "rect" | "circle"
 *   mx,my,mw,mh,mr   el rectángulo de la máscara (px dentro de la tarjeta) y su radio
 *   cr, cf     círculo: radio exterior y ancho del borde difuminado (px), con centro en la tarjeta
 *   blur       0–1 (Mist)
 *   tint       0–1 hacia el acento (la cápsula de Bloom)
 *   glow       0–1 (el brillo de la cápsula)
 *   rimY, rim  el filo de luz de Scroll: posición y opacidad
 *   ringR, ring  el aro de Ink: radio y opacidad
 * `pill(h)` es el radio de cápsula del estilo de interfaz (Metrics.pill: recto en Terminal).
 */
function effect(name, v, W, H, r, s, pill) {
    v = clamp(v);
    const o = { mask: "", mx: 0, my: 0, mw: W, mh: H, mr: r, cr: 0, cf: 0, blur: 0, tint: 0, glow: 0,
                rimY: 0, rim: 0, ringR: 0, ring: 0 };
    if (name === "bloom") {
        const ph = Math.min(H, Math.max(6, BLOOM_PILL * s));
        o.mask = "rect";
        if (v < BLOOM_SPLIT) {
            const q = outCubic(v / BLOOM_SPLIT);
            o.mw = lerp(0.08, 1, q) * W; o.mh = ph; o.mr = pill(ph); o.tint = 1; o.glow = 1;
        } else {
            const t = (v - BLOOM_SPLIT) / (1 - BLOOM_SPLIT);
            const q = outCubic(t * t * (2 - t));
            o.mw = W; o.mh = lerp(ph, H, q); o.mr = lerp(pill(ph), r, q);
            // el color y el brillo se apagan con el tiempo, no con la forma (outQuint es casi un salto al empezar)
            // (2026-11-17, banco: con t·1,5 la ventana se veía como un panel turquesa casi toda la segunda fase)
            o.tint = 1 - inOutQuad(Math.min(1, t * 2.2)); o.glow = 1 - inOutQuad(Math.min(1, t * 1.4));
        }
        o.mx = (W - o.mw) / 2; o.my = (H - o.mh) / 2;
        return o;
    }
    if (name === "scroll") {
        const th = Math.min(H, SCROLL_TITLE * s);
        o.mask = "rect";
        if (v < SCROLL_SPLIT) { o.mh = th; o.rim = outCubic(v / SCROLL_SPLIT); }
        else {
            const phase = (v - SCROLL_SPLIT) / (1 - SCROLL_SPLIT);
            const q = outCubic(phase * phase * (2 - phase));
            o.mh = lerp(th, H, q); o.rim = Math.pow(1 - q, 0.7);
        }
        o.rimY = o.mh;
        return o;
    }
    if (name === "ink") {
        const e = spreading(v);
        const f = Math.max(10 * s, 0.16 * W);
        o.mask = "circle";
        o.cf = f * (1 - 0.5 * e);
        o.cr = e * (Math.hypot(W, H) / 2 + o.cf);
        o.ringR = Math.max(2 * s, o.cr - o.cf * 0.45);
        o.ring = 0.75 * (1 - e) * clamp(v * 8);
        return o;
    }
    if (name === "mist") {
        o.blur = 1 - spreading(v);
        return o;
    }
    return o;
}

/** ¿Este estilo necesita RevealEffect (máscara, desenfoque o luz)? Los demás sólo transforman. */
function needsEffect(name) { return name === "bloom" || name === "scroll" || name === "ink" || name === "mist"; }
