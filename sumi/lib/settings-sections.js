/* Agrupación visual de Settings. Las rutas, claves y filas originales no cambian. */
var groups = {
    "shell/recording": {"Quality preset":"Video", "Custom preset":"Video", "Format":"Video", "Compatibility":"Video", "Custom values":"Video"},
    "shell/portability": {"Before importing":"Import"},
    "shell/dashboard": {"Maintenance tasks":"Tasks", "Backups":"Tasks"},
    "theme/wallpaper": {"Wallpaper":"Current", "Screens":"Current", "Rotation":"Playback", "Transitions":"Playback", "Recent":"Library", "Favorites":"Library", "Library":"Folders", "Sources":"Folders", "Folders":"Folders"},
    "theme/material": {"Global material":"Global", "Global opacity":"Global", "Surfaces":"Surfaces"},
    "theme/presets": {"Presets":"Library", "Selected preset":"Library"},
    "system/network": {"Saved networks":"Profiles", "Selected network":"Profiles", "Changes":"Profiles"},
    "system/power": {"Editing the idle times":"When idle"},
    "system/input": {"Keyboards":"Keyboard", "Per device":"Devices", "Changes":"Devices"},
    "system/environment": {"Detection":"Session", "Theme":"Appearance", "Wallpaper":"Appearance", "Apps":"Applications", "Audio":"Devices", "Desktop modes":"Desktop", "Updates and maintenance":"Maintenance", "Integrations":"Maintenance"}
};

function tabFor(page, section) {
    var map = groups[page] || {};
    return map[section.title] || (section.level === "advanced" ? "Advanced"
        : section.level === "experimental" ? "Experimental" : section.title);
}

function tabsFor(page, sections) {
    var tabs = [];
    sections.forEach(function(section) {
        var key = tabFor(page, section);
        if (!tabs.some(function(tab) { return tab.key === key; })) tabs.push({key:key, label:key});
    });
    return tabs;
}
