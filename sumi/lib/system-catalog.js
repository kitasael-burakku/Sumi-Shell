.pragma library
// Catálogo de System (fase 14A): las opciones de Hyprland e Input que Settings ENSEÑA (valor
// efectivo, archivo y línea). Sólo información: el 2026-09-29 el usuario descartó editarlas desde
// Settings (se editan en su Lua). Cada entrada:
//   key      nombre de getoption (con «:»); `path` es la misma clave con «.» (la del Lua)
//   type     int | float | sides (1 o 4 valores) | enum | bool | string — para dar formato
//   unit, options, labels   cómo se enseña

var OPTIONS = [
    // ---- System → Hyprland → Windows
    { id: "gapsIn", key: "general:gaps_in", page: "hyprland", section: "Windows", name: "Inner gaps",
      type: "sides", unit: "px" },
    { id: "gapsOut", key: "general:gaps_out", page: "hyprland", section: "Windows", name: "Outer gaps",
      type: "sides", unit: "px" },
    { id: "borderSize", key: "general:border_size", page: "hyprland", section: "Windows", name: "Border size",
      type: "int", unit: "px" },
    { id: "rounding", key: "decoration:rounding", page: "hyprland", section: "Windows", name: "Corner rounding",
      type: "int", unit: "px" },
    { id: "roundingPower", key: "decoration:rounding_power", page: "hyprland", section: "Windows",
      name: "Corner shape", type: "float" },
    { id: "activeOpacity", key: "decoration:active_opacity", page: "hyprland", section: "Windows",
      name: "Active window opacity", type: "float" },
    { id: "inactiveOpacity", key: "decoration:inactive_opacity", page: "hyprland", section: "Windows",
      name: "Inactive window opacity", type: "float" },
    { id: "layout", key: "general:layout", page: "hyprland", section: "Windows", name: "Tiling layout",
      type: "enum", options: ["dwindle", "master", "scrolling"] },
    { id: "resizeOnBorder", key: "general:resize_on_border", page: "hyprland", section: "Windows",
      name: "Resize from the border", type: "bool" },
    { id: "followMouse", key: "input:follow_mouse", page: "hyprland", section: "Focus", name: "Focus follows mouse",
      type: "enum", options: [0, 1, 2, 3], labels: ["Never", "Always", "On click · hover still scrolls", "Detached from the keyboard"] },

    // ---- System → Input → Keyboard
    { id: "kbLayout", key: "input:kb_layout", page: "input", section: "Keyboard", name: "Layouts",
      type: "string" },
    { id: "kbVariant", key: "input:kb_variant", page: "input", section: "Keyboard", name: "Variants",
      type: "string" },
    { id: "kbOptions", key: "input:kb_options", page: "input", section: "Keyboard", name: "Layout options",
      type: "string" },
    { id: "repeatRate", key: "input:repeat_rate", page: "input", section: "Keyboard", name: "Repeat rate",
      type: "int", unit: "/s" },
    { id: "repeatDelay", key: "input:repeat_delay", page: "input", section: "Keyboard", name: "Repeat delay",
      type: "int", unit: "ms" },

    // ---- System → Input → Touchpad (sólo lectura, como el resto de Input)
    { id: "padTap", key: "input:touchpad:tap-to-click", page: "input", section: "Touchpad", name: "Tap to click", type: "bool" },
    { id: "padTyping", key: "input:touchpad:disable_while_typing", page: "input", section: "Touchpad", name: "Disable while typing", type: "bool" },
    { id: "padNatural", key: "input:touchpad:natural_scroll", page: "input", section: "Touchpad", name: "Touchpad natural scroll", type: "bool" },
    { id: "padScroll", key: "input:touchpad:scroll_factor", page: "input", section: "Touchpad", name: "Touchpad scroll speed", type: "float" },
    { id: "padClick", key: "input:touchpad:clickfinger_behavior", page: "input", section: "Touchpad", name: "Click with fingers", type: "bool" },

    // ---- System → Input → Pointer
    { id: "sensitivity", key: "input:sensitivity", page: "input", section: "Pointer", name: "Sensitivity",
      type: "float", device: "sensitivity" },
    { id: "accelProfile", key: "input:accel_profile", page: "input", section: "Pointer", name: "Acceleration",
      type: "enum", options: ["", "adaptive", "flat"], labels: ["Default", "Adaptive", "Flat"],
      device: "accel_profile" },
    { id: "naturalScroll", key: "input:natural_scroll", page: "input", section: "Pointer", name: "Natural scroll",
      type: "bool", device: "natural_scroll" },
    { id: "scrollFactor", key: "input:scroll_factor", page: "input", section: "Pointer", name: "Scroll speed",
      type: "float", device: "scroll_factor" }
];

// Lo que se ve junto a estas opciones pero tiene OTRO dueño: se enseña, nunca se edita aquí.
var ELSEWHERE = [
    { id: "borderColours", key: "general:col.active_border", page: "hyprland", section: "Managed elsewhere",
      name: "Border colours", owner: "theme", caption: "Your theme sets them (matugen) · change them in Theme → Colors" },
    { id: "blur", key: "decoration:blur:enabled", page: "hyprland", section: "Managed elsewhere",
      name: "Blur", type: "bool", owner: "modes", caption: "System modes turn it off for Gaming · edit it in decoration.lua" },
    { id: "animations", key: "animations:enabled", page: "hyprland", section: "Managed elsewhere",
      name: "Animations", type: "bool", owner: "modes", caption: "System modes turn them off for Gaming · curves stay in animations.lua" }
];

function all() { return OPTIONS.concat(ELSEWHERE); }
function keys() { return all().map(function (o) { return o.key; }); }
function byKey(k) {
    var l = all();
    for (var i = 0; i < l.length; i++) if (l[i].key === k) return l[i];
    return null;
}
function path(k) { return String(k).replace(/:/g, "."); }

// Filas de Settings para una página y sección (estáticas: la búsqueda las indexa por nombre).
function rows(page, section) {
    return all().filter(function (o) { return o.page === page && o.section === section; })
        .map(function (o) { return { id: "hypr:" + o.key, prop: "", kind: "info", name: o.name }; });
}

// Sinónimos de búsqueda (en inglés, como la UI).
var SYNONYMS = {
    "general:gaps_in": ["gaps", "spacing", "windows"], "general:gaps_out": ["gaps", "margin", "edges"],
    "general:border_size": ["border", "outline"], "decoration:rounding": ["corners", "radius", "round"],
    "decoration:rounding_power": ["squircle", "corners"], "decoration:active_opacity": ["transparency", "opacity"],
    "decoration:inactive_opacity": ["transparency", "opacity", "dim"], "general:layout": ["tiling", "dwindle", "master", "scrolling"],
    "general:resize_on_border": ["resize", "drag"], "input:follow_mouse": ["focus", "hover", "click"],
    "input:kb_layout": ["keyboard", "language", "layout", "xkb"], "input:kb_variant": ["keyboard", "variant", "xkb"],
    "input:kb_options": ["keyboard", "switch", "toggle", "alt shift", "xkb"],
    "input:repeat_rate": ["keyboard", "repeat", "typing"], "input:repeat_delay": ["keyboard", "repeat", "typing"],
    "input:sensitivity": ["mouse", "speed", "pointer"], "input:accel_profile": ["mouse", "acceleration", "flat"],
    "input:natural_scroll": ["scroll", "reverse", "touchpad"], "input:scroll_factor": ["scroll", "wheel", "speed"],
    "general:col.active_border": ["border", "colour", "color"], "decoration:blur:enabled": ["blur", "glass"],
    "animations:enabled": ["animations", "motion"]
};
