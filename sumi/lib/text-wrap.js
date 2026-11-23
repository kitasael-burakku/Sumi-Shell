.pragma library
/*
 * Dónde puede partirse un texto de la shell (2026-11-12, «Text size»).
 *
 * Los valores y pies se escriben como segmentos unidos por « · » («1920×1080 · 200 fps · AAC 160 kb/s»).
 * Con WordWrap, Qt parte en cualquier espacio, y al crecer el texto quedaba «AAC 160» en un renglón y «kb/s»
 * en el siguiente. Aquí los espacios de dentro de un segmento CORTO pasan a U+00A0 (no separable), así que el
 * renglón se parte entre segmentos. Un segmento largo (una frase) conserva sus espacios: debe poder partirse.
 */

/** Segmentos de hasta `max` caracteres (por defecto 28) sin cortes por dentro. */
function keepSegments(text, max) {
    const limit = max === undefined ? 28 : max;
    return String(text).split(" · ").map(function (part) {
        return part.length <= limit ? part.replace(/ /g, " ") : part;
    }).join(" · ");
}

/**
 * Pies de teclado («← →  move    ⏎  apply    /  search», auditoría tipográfica 2026-11-18): cada grupo tecla-acción
 * queda unido (U+00A0) y el renglón se parte ENTRE grupos. Los grupos van separados por 3 o más espacios o por « · ».
 */
function keepHints(text) {
    return String(text).split(/(\s{3,}|\s+·\s+)/).map(function (part, i) {
        return i % 2 === 1 ? part : part.replace(/ /g, "\u00a0");
    }).join("");
}
