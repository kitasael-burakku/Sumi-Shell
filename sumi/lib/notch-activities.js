.pragma library

/**
 * Las actividades en vivo del notch (2026-11-17, pedido del usuario: «darle el mismo cariño al modo notch»).
 *
 * Mientras algo está en curso, la muesca en reposo crece a los lados y enseña una OREJA a cada lado (a la izquierda qué
 * es, a la derecha su dato); el reloj sigue en el centro. Sólo en el notch: la island conserva sus círculos.
 *
 * Esta tabla es la única fuente de qué actividades hay, cuál gana y cuánto mide cada oreja: `services/LiveActivity`
 * decide con ella y `core/NotchEar` sólo dibuja. Reordenar o añadir una actividad es cambiar DATOS aquí (y su dibujo).
 *
 *   kind     live   dura lo que dura lo que pasa (grabación, speed test, música); gana la de `prio` más alta.
 *            flash  un aviso breve (`holdMs`) que tapa a la live que haya; luego ésta vuelve. El último manda.
 *   setting  la preferencia de Settings → Notch que la enciende (`Settings[setting]`).
 *   left/right  lo que necesita cada lado, uno de `WIDTHS` (px lógicos a escala 1); las dos orejas miden el mayor
 *            (`width()`). FIJOS a propósito: ninguna oreja se mide por su texto, así el ancho de la muesca no depende
 *            de lo que dice (la trampa de `elide` re-maquetado y el bucle de medida del reposo del 2026-09-16; ver
 *            `reveal` en core/Island).
 */

var WIDTHS = { ear: 34, wide: 52, wider: 74 };

var CATALOG = [
    { id: "recording", kind: "live",  prio: 30, setting: "notchActRecording", left: "ear", right: "wide" },
    { id: "speed",     kind: "live",  prio: 20, setting: "notchActSpeed",     left: "ear", right: "wider" },
    { id: "music",     kind: "live",  prio: 10, setting: "notchActMusic",     left: "ear", right: "ear" },
    { id: "power",     kind: "flash", holdMs: 3000, setting: "notchActPower",     left: "ear", right: "wide" },
    { id: "copy",      kind: "flash", holdMs: 1500, setting: "notchActCopy",      left: "ear", right: "wider" },
    { id: "bluetooth", kind: "flash", holdMs: 3000, setting: "notchActBluetooth", left: "ear", right: "wide" },
    { id: "workspace", kind: "flash", holdMs: 1000, setting: "notchActWorkspace", left: "ear", right: "ear" }
];

function byId(id) {
    for (var i = 0; i < CATALOG.length; i++) if (CATALOG[i].id === id) return CATALOG[i];
    return null;
}

/**
 * El ancho (escala 1) de CADA oreja de `id`; 0 sin actividad. Las dos miden lo mismo (la mayor de `left`/`right`): la
 * muesca crece igual a los dos lados y el reloj no se mueve del centro de la pantalla. Con orejas asimétricas se
 * desplazaba hasta 20 px al empezar un speed test. El contenido va pegado al borde de fuera (`core/NotchEar`).
 */
function width(id) {
    var a = byId(id);
    return a ? Math.max(WIDTHS[a.left] || 0, WIDTHS[a.right] || 0) : 0;
}

/**
 * La live que gana. `on`: { id: bool } con lo que está pasando; `prefs`: objeto con las preferencias
 * (`Settings`). Devuelve el id o "".
 */
function pickLive(on, prefs) {
    var best = null;
    for (var i = 0; i < CATALOG.length; i++) {
        var a = CATALOG[i];
        if (a.kind !== "live" || !on[a.id] || !prefs[a.setting]) continue;
        if (!best || a.prio > best.prio) best = a;
    }
    return best ? best.id : "";
}

/** ¿Se puede avisar con esta flash? (existe, es flash y su preferencia está encendida). */
function flashAllowed(id, prefs) {
    var a = byId(id);
    return !!a && a.kind === "flash" && !!prefs[a.setting];
}

function holdOf(id) {
    var a = byId(id);
    return a && a.holdMs ? a.holdMs : 2000;
}
