.pragma library
/*
 * Material y opacidad por superficie (2026-10-28, Theme → Material → Surfaces).
 *
 * El material global (`theme.appearance.material` / `glassOpacity`) sigue siendo el valor de
 * todas. Una superficie compatible puede guardar SÓLO lo que cambia, propiedad a propiedad, en
 * `theme.appearance.surfaces`: { "<clave>": { material?: "glass"|"satin", opacity?: 0.75–1 } }.
 * Lo que no guarda lo hereda, así que cambiar el global mueve a todas las que no lo pisan y una
 * superficie nueva nace heredando. Una clave que esta tabla ya no conoce se conserva y no se usa.
 *
 * Sin dependencias de QML: `theme/Theme` y Settings lo usan para resolver; la validación del
 * archivo es del catálogo (`lib/settings-schema.js`, tipo `surfaceMaterials`), que ya la hizo antes
 * de que un valor llegue aquí. Se carga en node para probarlo (`module.exports` al final).
 */

/**
 * Las superficies compatibles: las que se pintan con `components/Glass`. `names` son los nombres
 * del host (`core/SurfaceHost` registry) que comparten una entrada: las tres páginas de Settings,
 * una ficha y su lista. Sin entrada propia (Lock, polkit, barra, island en reposo, OSD, menús,
 * tooltips) se usa el global sin más.
 *
 * Desde el 2026-10-28 (petición del usuario: «que todo siga un mismo enfoque») TODAS heredan el
 * global, también las herramientas flotantes (Wallhaven, Audio UI, System Monitor, Calendar UI),
 * que hasta entonces tenían un fondo propio fijo al 98,5 %. Quien las quiera casi opacas lo elige
 * en Theme → Material → Advanced → Surfaces.
 */
var SURFACES = [
    { id: "settings", label: "Settings", names: ["settings", "settingsTheme", "settingsSystem"] },
    { id: "launcher", label: "Launcher", names: ["launcher"] },
    { id: "dashboard", label: "Dashboard", names: ["dashboard"] },
    { id: "controlCenter", label: "Control center", names: ["controlCenter"] },
    { id: "notifications", label: "Notification center", names: ["notifications"] },
    { id: "notifPopups", label: "Notification popups", names: [] },
    { id: "wallpaper", label: "Wallpaper selector", names: ["wallpaper"] },
    { id: "wallhaven", label: "Wallhaven browser", names: [] },
    { id: "mixer", label: "Media and mixer", names: ["mixer"] },
    { id: "audio", label: "Audio settings", names: [] },
    { id: "calendar", label: "Today", names: ["calendar"] },
    { id: "calendarUi", label: "Calendar", names: [] },
    { id: "network", label: "Wi-Fi and Ethernet", names: ["wifi", "wifiDetail", "wired", "speedtest"] },
    { id: "bluetooth", label: "Bluetooth", names: ["bluetooth", "btDetail"] },
    { id: "web", label: "Web hub", names: ["web"] },
    { id: "clipboard", label: "Clipboard", names: ["clipboard"] },
    { id: "emoji", label: "Emoji picker", names: ["emoji"] },
    { id: "minimizer", label: "Windows", names: ["minimizer"] },
    { id: "power", label: "Power menu", names: ["power"] },
    { id: "services", label: "Services", names: ["services", "serviceDetail", "serviceJournal"] },
    { id: "system", label: "System monitor (compact)", names: ["system"] },
    { id: "monitor", label: "System monitor", names: [] },
    // Etapa B del Dashboard (2026-11-09): la ventana flotante de tareas
    { id: "tasks", label: "Tasks", names: [] },
    { id: "theme", label: "Visual profiles", names: ["theme"] },
    // Grabador 2.0 (2026-10-29): la surface del grabador (primera entrega) no estaba en la lista
    { id: "recorder", label: "Screen recorder", names: ["recorder"] },
    { id: "cli", label: "Command palette", names: ["cli"] },
    // Ayuda de atajos (2026-10-30): la tarjeta flotante, como Calendar/Monitor (no es una surface del host)
    { id: "keybindsUi", label: "Keyboard shortcuts", names: [] },
    // Login screen (Sumi SDDM, 2026-11-23): la ventana flotante, como Calendar/Monitor
    { id: "loginUi", label: "Login screen", names: [] }
];

/** Los nombres que se enseñan; los valores válidos los dice el catálogo (`theme.appearance.material`). */
var MATERIAL_NAMES = { glass: "Glass", satin: "Vidrio Satinado" };

/** La clave de material de un nombre del host ("" = ninguna: hereda el global). */
function keyOf(name) {
    if (!name) return "";
    for (var i = 0; i < SURFACES.length; i++)
        if (SURFACES[i].id === name || SURFACES[i].names.indexOf(name) >= 0) return SURFACES[i].id;
    return "";
}

function byId(id) {
    for (var i = 0; i < SURFACES.length; i++)
        if (SURFACES[i].id === id) return SURFACES[i];
    return null;
}

function labelOf(id) { var s = byId(id); return s ? s.label : id; }
function materialName(m) { return MATERIAL_NAMES[m] || m; }

/** Lo guardado para una clave, o {} (nunca undefined). */
function overrideOf(all, key) {
    var o = all && key ? all[key] : undefined;
    return o && typeof o === "object" && !Array.isArray(o) ? o : {};
}

/** Los valores efectivos, propiedad a propiedad: lo guardado o, si falta, el global. */
function material(all, key, global) {
    var o = overrideOf(all, key);
    return typeof o.material === "string" ? o.material : global;
}
function opacity(all, key, global) {
    var o = overrideOf(all, key);
    return typeof o.opacity === "number" ? o.opacity : global;
}

/** ¿Alguna superficie conocida usa este material (por sí misma o heredándolo)? */
function anyUses(all, global, m) {
    if (global === m) return true;
    for (var i = 0; i < SURFACES.length; i++)
        if (material(all, SURFACES[i].id, global) === m) return true;
    return false;
}

/** Una copia con `field` de `key` puesto (o quitado con `undefined`); quita la entrada vacía. */
function withField(all, key, field, value) {
    var next = JSON.parse(JSON.stringify(all && typeof all === "object" && !Array.isArray(all) ? all : {}));
    var e = next[key] && typeof next[key] === "object" ? next[key] : {};
    if (value === undefined) delete e[field]; else e[field] = value;
    if (e.material === undefined && e.opacity === undefined) delete next[key]; else next[key] = e;
    return next;
}

function without(all, key) {
    var next = JSON.parse(JSON.stringify(all && typeof all === "object" && !Array.isArray(all) ? all : {}));
    delete next[key];
    return next;
}

/** Las superficies conocidas con algo propio, en el orden de la tabla. */
function customized(all) {
    var out = [];
    for (var i = 0; i < SURFACES.length; i++) {
        var o = overrideOf(all, SURFACES[i].id);
        if (o.material !== undefined || o.opacity !== undefined) out.push(SURFACES[i].id);
    }
    return out;
}

if (typeof module !== "undefined")
    module.exports = { SURFACES: SURFACES, keyOf: keyOf, byId: byId, labelOf: labelOf, materialName: materialName,
        overrideOf: overrideOf, material: material, opacity: opacity, anyUses: anyUses, withField: withField,
        without: without, customized: customized };
