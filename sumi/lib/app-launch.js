.pragma library

/** F8b: política pura. Sólo el informe REAL fresco selecciona auto; nunca overrides. */
function backend(preference, source, helper, checking, report) {
    if (preference === "direct" || preference === "systemd") return preference;
    if (preference !== "auto" || source !== "fresh" || helper !== "ok" || checking) return "";
    const c = report && report.caps ? report.caps["session.systemd"] : null;
    if (!c) return "";
    if (c.state === "available") return "systemd";
    if (c.state === "unavailable" && c.detail && c.detail.managerAbsent === true) return "direct";
    return "";
}

function scoped(argv, name, unit, kind) {
    if (!argv || argv.length === 0) return [];
    if (kind === "direct") return Array.from(argv);
    if (kind !== "systemd") return [];
    const id = String(name || argv[0] || "app").replace(/^.*\//, "").replace(/\.desktop$/, "")
        .replace(/[^A-Za-z0-9_.:]/g, "_").slice(0, 64) || "app";
    const rnd = Date.now().toString(16) + Math.floor(Math.random() * 0x10000).toString(16);
    return ["systemd-run", "--user", "--scope", "--quiet", "--collect",
            "--unit=" + (unit || ("app-sumi-" + id + "-" + rnd + ".scope")), "--"].concat(argv);
}

if (typeof module !== "undefined") module.exports = { backend: backend, scoped: scoped };
