.pragma library

/**
 * REPARTO DEL COLOR POR ZONAS (2026-11-21). Qué familia de acento (primary · secondary · tertiary de la paleta activa,
 * ver `Theme.fam`) lleva cada parte de la shell. Sólo datos: las superficies piden aquí su zona y la declaran con
 * `palette.accent: Theme.zone(…)`; los controles de dentro la heredan solos.
 *
 * Criterio: lo que se ve junto lleva colores distintos (dos tarjetas vecinas no comparten familia) y lo que significa
 * lo mismo lleva el mismo en todas partes (la salida de audio es primary en Settings, en la ventana de Audio y en el
 * Control Center; la entrada, secondary). Los modos del sistema (Normal, Focus, Gaming, Cinema) tienen cada uno el suyo
 * en sus tarjetas y en el Control Center, pero no tiñen la shell: el reparto es igual en todos los modos, estilos
 * (Soft, Terminal), materiales y en claro/oscuro.
 */

var CYCLE = ["primary", "tertiary", "secondary"];

/** Grupos de la barra lateral de Settings (lib/settings-nav.js). */
var SETTINGS_GROUPS = {
    shell: "primary",
    appearance: "tertiary",
    components: "secondary",
    applications: "primary",
    system: "tertiary"
};

/** Significados fijos: el mismo concepto lleva el mismo color en cualquier superficie. */
var MEANING = {
    overview: "primary", output: "primary", input: "secondary", apps: "tertiary", applications: "tertiary", equalizer: "tertiary", devices: "secondary",
    network: "primary", bluetooth: "secondary", volume: "primary", brightness: "tertiary",
    cpu: "primary", gpu: "tertiary", memory: "secondary", disks: "secondary", sensors: "tertiary", uptime: "tertiary",
    processes: "secondary", player: "primary", mix: "secondary",
    normal: "primary", focus: "secondary", gaming: "tertiary", cinema: "primary",
    dnd: "secondary", mode: "tertiary",
    // F10 (2026-11-27): la fila de energía del Centro de control, en las familias de la fila de encima
    power: "tertiary", awake: "secondary"
};

function of(meaning) { return MEANING[meaning] || "primary"; }

function group(id) { return SETTINGS_GROUPS[id] || "primary"; }

/**
 * La n-ésima sección de una página de Settings: empieza por el color del grupo y rota, para que dos secciones
 * seguidas nunca compartan familia. Una sección con significado fijo (Output, Input) usa el suyo (`SECTION_TITLES`).
 */
function section(groupId, index, title) {
    var fixed = SECTION_TITLES[String(title || "").toLowerCase()];
    if (fixed) return fixed;
    var start = CYCLE.indexOf(group(groupId));
    return CYCLE[(start + Math.max(0, index)) % CYCLE.length];
}

/**
 * La n-ésima fila (tarjeta) de una sección de Settings: rota desde el color de la sección, así que la primera
 * coincide con el título. En las secciones con significado fijo, todas las filas conservan el suyo.
 */
function row(sectionZone, index, title) {
    if (SECTION_TITLES[String(title || "").toLowerCase()]) return sectionZone;
    var start = Math.max(0, CYCLE.indexOf(sectionZone));
    return CYCLE[(start + Math.max(0, index)) % CYCLE.length];
}

/** Secciones de Settings con significado fijo, por título (las de audio usan el color de la ventana de Audio). */
var SECTION_TITLES = { output: MEANING.output, input: MEANING.input };

/** Rotación simple, para listas de tarjetas sin significado propio (Overview del Dashboard, etc.). */
function nth(index) { return CYCLE[Math.max(0, index) % CYCLE.length]; }
