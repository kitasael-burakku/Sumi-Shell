.pragma library
// Pure resolver. Installed names come from Qt; no substring or fc-match availability.
function normal(s) { return String(s || "").trim().replace(/\s+/g, " ").toLowerCase(); }
function listed(names, installed) {
    for (var i = 0; i < names.length; i++)
        for (var j = 0; j < installed.length; j++)
            if (normal(names[i]) === normal(installed[j])) return installed[j];
    return "";
}
function preset(catalog, id) {
    return catalog.presets.filter(function(p) { return p.id === id; })[0] || null;
}
function resolve(catalog, selection, role, installed, known) {
    var p = preset(catalog, selection.preset);
    var names = selection[role] ? [selection[role]] : (p || catalog.presets[0])[role];
    var requested = names[0];
    var found = listed(names, installed);
    var fallback = listed(catalog.fallback[role], installed);
    return { requested: requested, selected: found || fallback || (role === "mono" ? "monospace" : "sans-serif"),
        available: known && !!found && !!p, state: !known ? "unknown" : found && p ? "available" : "unavailable",
        reason: !known ? "Font inventory unavailable; selection preserved"
            : !p ? "Unknown preset; selection preserved" : !found ? "Requested family is not installed"
            : normal(found) !== normal(requested) ? "Explicit catalog alias" : "", presetKnown: !!p };
}
function selection(presetId, ui, mono) { return {preset:presetId, ui:ui || "", mono:mono || ""}; }
function signature(s) { return JSON.stringify(selection(s.preset, s.ui, s.mono)); }
function canApply(catalog, s, installed, known) {
    return resolve(catalog,s,"ui",installed,known).available && resolve(catalog,s,"mono",installed,known).available;
}
if (typeof module !== "undefined") module.exports = {normal:normal,listed:listed,preset:preset,resolve:resolve,selection:selection,signature:signature,canApply:canApply};
