.pragma library

/** Índice visual de Settings; las rutas de página y fila también se usan en búsqueda, historial e IPC. */
var GROUPS = [
    { id: "shell", title: "Shell", glyph: "cog", pages: [
        "shell/general", "shell/panels", "shell/dock", "shell/animations", "shell/interaction", "shell/portability"
    ] },
    { id: "appearance", title: "Appearance", glyph: "palette", pages: [
        "theme/overview", "theme/wallpaper", "theme/colors", "theme/material", "theme/style", "theme/typography",
        "theme/icons", "theme/presets"
    ] },
    { id: "components", title: "Desktop tools", glyph: "window", pages: [
        "shell/dashboard", "shell/notifications", "shell/osd", "shell/calendar", "shell/recording", "shell/lock",
        "shell/sddm"
    ] },
    { id: "applications", title: "Apps & services", glyph: "terminal", pages: [
        "shell/apps", "shell/modules"
    ] },
    { id: "system", title: "System", glyph: "monitor", pages: [
        "system/audio", "system/network", "system/bluetooth", "system/power", "system/displays",
        "system/input", "system/hyprland", "system/environment", "system/about"
    ] }
];

/** Una línea por página: qué se configura ahí (el encabezado de la página y el panel contextual). */
var DESCRIPTIONS = {
    "shell/general": "Scale, auto-hide, workspace dots, gestures and integrations",
    "shell/animations": "Motion, speed and styles for windows, bar panels and the island",
    "shell/interaction": "Hover, keyboard focus and the shortcut reference",
    "shell/modules": "Optional modules and where each one is configured",
    "shell/portability": "Export your settings to a file, or import them on another machine",
    "theme/overview": "The current wallpaper, palette and visual profile at a glance",
    "theme/wallpaper": "Per-screen wallpaper, rotation, transitions, folders and Wallhaven",
    "theme/colors": "Profile, mode, contrast and colour source, with a preview",
    "theme/material": "Glass or satin, opacity, edge and shadow — globally or per surface",
    "theme/style": "Soft or Terminal: the shape of panels and controls",
    "theme/typography": "Font families, text size, icon font and other apps that follow them",
    "theme/icons": "Icon and cursor themes for your apps, with a preview",
    "theme/presets": "Save, compare and apply groups of settings",
    "shell/panels": "Persistent bar, window thumbnails and the launcher scrollbar",
    "shell/dock": "The notch: this monitor, its shape and live activities",
    "shell/dashboard": "Maintenance tasks and backup reminders",
    "shell/notifications": "Popup duration and Do Not Disturb",
    "shell/osd": "On-screen display over panels, its duration and value",
    "shell/lock": "Lock screen, how lock requests arrive and the authentication stack",
    "shell/sddm": "The Sumi SDDM login screen: wallpaper, colours, notch, clock and users, with a preview",
    "shell/recording": "Screen recording quality, format, audio, files and behaviour",
    "shell/apps": "Terminal, browser and providers: wallpapers, thumbnails, colours, updates",
    "shell/calendar": "First day of the week, clock format and weather",
    "system/audio": "Default output and input, volumes, and links to the audio tools",
    "system/network": "Connection status, Ethernet, Wi-Fi and saved network profiles",
    "system/bluetooth": "Adapter and known devices",
    "system/power": "Power profile, keep awake and idle times",
    "system/displays": "Connected monitors (read only: managed in your Hyprland configuration)",
    "system/input": "Keyboard and pointer (read only: set in Hyprland)",
    "system/hyprland": "Compositor information (read only: set in Hyprland)",
    "system/environment": "What the shell found here and why some features are limited",
    "system/about": "This computer and this shell"
};

function groupOf(key) {
    for (var i = 0; i < GROUPS.length; i++)
        if (GROUPS[i].pages.indexOf(key) >= 0) return GROUPS[i];
    return null;
}

function describe(key) {
    return DESCRIPTIONS[key] || "";
}

/** Todas las rutas en el orden de la barra lateral (el sentido del deslizamiento sale de aquí). */
function order() {
    var out = [];
    for (var i = 0; i < GROUPS.length; i++)
        for (var j = 0; j < GROUPS[i].pages.length; j++) out.push(GROUPS[i].pages[j]);
    return out;
}

/** Los títulos de las páginas proceden de la misma tabla que la búsqueda. */
function groupsWithTitles(titleOf) {
    return GROUPS.map(g => ({
        id: g.id, title: g.title, glyph: g.glyph,
        pages: g.pages.map(key => ({key: key, label: titleOf(key)}))
    }));
}

/** Orden de teclado. Las cabeceras tienen el id del grupo y las páginas su ruta completa. */
function visibleKeys(expanded) {
    var keys = [];
    for (var i = 0; i < GROUPS.length; i++) {
        var group = GROUPS[i];
        keys.push(group.id);
        if (group.id === expanded) keys = keys.concat(group.pages);
    }
    return keys;
}

/** Comprueba la jerarquía contra la tabla: [] si todo cuadra; si no, los problemas. */
function check(tree) {
    var problems = [];
    var known = {};
    for (var i = 0; i < tree.length; i++)
        for (var j = 0; j < tree[i].pages.length; j++) known[tree[i].id + "/" + tree[i].pages[j].id] = 0;
    for (var g = 0; g < GROUPS.length; g++)
        for (var p = 0; p < GROUPS[g].pages.length; p++) {
            var key = GROUPS[g].pages[p];
            if (known[key] === undefined) problems.push("unknown page " + key);
            else known[key]++;
        }
    for (var k in known) {
        if (known[k] === 0) problems.push("page without group " + k);
        if (known[k] > 1) problems.push("page in several groups " + k);
        if (!DESCRIPTIONS[k]) problems.push("page without description " + k);
    }
    return problems;
}
