.pragma library
/*
 * Rueda en pasos (2026-11-27, ADR-42 «un gesto, una implementación»).
 *
 * Una muesca de rueda son 120 unidades; una rueda fina o un touchpad mandan trozos y se suman, así que el paso es el
 * mismo con cualquier dispositivo. Cambiar de sentido empieza la cuenta de cero. Antes la isla acumulaba y la pieza de
 * volumen de la barra sumaba un paso por evento (con touchpad saltaba).
 *
 * Puro: quien lo usa guarda `acc` (un número) y aplica los pasos. Prueba en node: `tests/lib/wheel-test.js`.
 */

/** El desplazamiento útil de un WheelEvent: vertical, o el horizontal invertido si no hay vertical. */
function delta(angleDelta) {
    return angleDelta.y !== 0 ? angleDelta.y : -angleDelta.x;
}

/** Suma `dy` a `acc` y devuelve `{ acc, steps }`: pasos enteros de `unit` (120 si no se dice), con signo. */
function step(acc, dy, unit) {
    const u = unit || 120;
    let a = acc || 0;
    if (dy === 0) return { acc: a, steps: 0 };
    if (a * dy < 0) a = 0;
    a += dy;
    const steps = Math.trunc(a / u);
    return { acc: a - steps * u, steps: steps };
}
