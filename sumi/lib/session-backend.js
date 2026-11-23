.pragma library

/** F8c: only an actual, fresh bus report selects the power/inhibitor backend. */
function backend(source, helper, report) {
    // A running refresh does not revoke a previously verified inhibitor.
    if (source !== "fresh" || helper !== "ok" || !report || !report.caps) return "";
    const system = report.caps["session.systemdSystem"];
    const login = report.caps["session.logind"];
    if (!system) return "";
    if (system.state === "available") return "systemd";
    if (system.state === "unavailable" && system.detail && system.detail.managerAbsent === true
            && login && login.state === "available") return "login1";
    return "";
}

if (typeof module !== "undefined") module.exports = { backend: backend };
