// Presentación pura: nunca rellena huecos ni atribuye procesos de otra muestra.
function known(n) { return typeof n === "number" && isFinite(n); }
function number(n, unit, digits) { return known(n) ? n.toFixed(digits === undefined ? 0 : digits) + unit : "No data"; }
// Antes de la primera muestra, el estado del monitor indica que está arrancando.
function cpuUsage(sample) { return sample ? number(sample.cpu && sample.cpu.usagePct, "%") : "—"; }
function bytes(n, rate) {
    if (!known(n)) return "No data";
    var units = ["B", "KiB", "MiB", "GiB", "TiB"], i = 0;
    while (Math.abs(n) >= 1024 && i < 4) { n /= 1024; i++; }
    return n.toFixed(i ? 1 : 0) + " " + units[i] + (rate ? "/s" : "");
}
/*
 * Temperaturas (F11, 2026-11-27): los datos y los umbrales siguen en °C (los del recolector); sólo lo que se dibuja
 * pasa a °F cuando el usuario eligió °F para el tiempo (`tu` = Settings.weatherUnits, vía `Sysmon.tempUnits`).
 */
function fahrenheit(tu) { return tu === "fahrenheit"; }
function tempNum(c, tu) { return known(c) && fahrenheit(tu) ? c * 9 / 5 + 32 : c; }
function tempUnit(tu) { return fahrenheit(tu) ? "°F" : "°C"; }
function tempText(c, tu, digits) { return number(tempNum(c, tu), " " + tempUnit(tu), digits); }
function temp(o, tu) {
    o = o || {};
    var limit = known(o.temperatureCriticalC) ? o.temperatureCriticalC : o.temperatureMaxC;
    return {text: tempText(o.temperatureC, tu), warning: known(limit) && known(o.temperatureC) && o.temperatureC >= limit,
        limit: known(limit) ? "Sensor limit " + tempText(limit, tu) : "Sensor limit unavailable"};
}
function line(label, text, warning) { return {label: label, text: text, warning: !!warning}; }
// Micrográfica: claves planas de Sysmon.flatten; max 0 = automático.
function micro(keys, unit, max) { return {keys: keys, unit: unit, max: max || 0}; }
// Tarjetas de la surface COMPACTA (antes de la fase 12, M4): valor principal, uno o dos secundarios,
// una micrográfica de 60 s y a qué sección de la UI de inspección lleva «Details». Nada más:
// procesos, núcleos, montajes y comparaciones viven en la UI (Super+Ctrl+Y).
function cards(sample, energy, alerts, tu) {
    var out = [], c = sample ? sample.cpu || {} : {}, t = temp(c, tu);
    // Aviso = alerta sostenida de Sysmon (lib/monitor-alerts.js), nunca una lectura suelta.
    var warnOf = function(domain) { return (alerts || []).some(function(a) { return a.domain === domain; }); };
    out.push({id: "cpu", section: "cpu", title: "CPU", headline: cpuUsage(sample), aside: t.text,
        sub: freq(c.frequencyMHz) + (c.logicalCount ? " · " + c.logicalCount + " threads" : ""), warning: warnOf("cpu"),
        graph: micro(["cpu.usage"], "%", 100)});
    var gpus = sample && sample.gpus ? sample.gpus : null;
    if (gpus && !gpus.length) out.push({id: "gpu:none", section: "gpu", title: "GPU", headline: "None", aside: "", sub: "No GPU detected", graph: null});
    for (var g of gpus || []) {
        out.push({id: "gpu:" + g.id, section: "gpu", title: gpus.length > 1 ? "GPU · " + g.card : "GPU", headline: number(g.usagePct, "%"), aside: temp(g, tu).text,
            sub: "VRAM " + bytes(g.vramUsedB) + " / " + bytes(g.vramTotalB), warning: warnOf("gpu"),
            graph: micro(["gpu/" + g.id + "/usage"], "%", 100)});
    }
    var m = sample ? sample.memory || {} : {}, sw = m.swap || {};
    out.push({id: "memory", section: "memory", title: "Memory", headline: known(m.usedB) ? bytes(m.usedB) + " / " + bytes(m.totalB) : "No data", aside: number(m.usedPct, "%"),
        sub: bytes(m.availableB) + " available" + (sw.present ? " · swap " + bytes(sw.usedB) : ""), warning: warnOf("memory"),
        graph: micro(["mem.used"], "B", m.totalB)});
    var n = sample ? sample.network || {} : {};
    out.push({id: "network", section: "network", title: "Network", headline: "↓ " + bytes(n.rxBps, true), aside: "↑ " + bytes(n.txBps, true),
        sub: n.interfaces ? (n.interfaces.length ? n.interfaces.map(function(i) { return i.name; }).join(" · ") : "No active interface") : "No data",
        warning: warnOf("network"), graph: micro(["net.rx", "net.tx"], "B/s")});
    var disks = sample ? sample.disks : null, vols = [], r = null, w = null;
    for (var d of disks || []) {
        for (var io of d.io || []) {
            if (known(io.readBps)) r = (r || 0) + io.readBps;
            if (known(io.writeBps)) w = (w || 0) + io.writeBps;
        }
        for (var v of d.volumes || []) vols.push(v);
    }
    // El más lleno primero: la pregunta de un vistazo es «¿se llena algo?».
    vols.sort(function(a, b) { return (b.usedPct || 0) - (a.usedPct || 0); });
    out.push({id: "disks", section: "disks", title: "Disks", headline: "R " + bytes(r, true), aside: "W " + bytes(w, true),
        sub: disks ? disks.length + (disks.length === 1 ? " device" : " devices") : "No data", warning: warnOf("disks"),
        volumes: vols.slice(0, 3), moreVolumes: Math.max(0, vols.length - 3), graph: micro(["io.read", "io.write"], "B/s")});
    out.push({id: "energy", section: "", title: "Energy", headline: energy.profile, aside: "Power profile", sub: "", lines: energy.lines, graph: null});
    return out;
}

// ---- antes de la fase 12 (M2): unidades compartidas por la UI de inspección ---------------
// Frecuencia: MHz bajo 1 GHz, GHz con dos decimales encima. Nunca mezcla unidades en una misma cifra.
function freq(mhz) {
    if (!known(mhz)) return "No data";
    return mhz >= 1000 ? (mhz / 1000).toFixed(2) + " GHz" : Math.round(mhz) + " MHz";
}
// Duración legible: 3 d 4 h, 2 h 10 m, 5 m 3 s, 42 s.
function duration(seconds) {
    if (!known(seconds) || seconds < 0) return "No data";
    var s = Math.floor(seconds), d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
    if (d) return d + " d " + h + " h";
    if (h) return h + " h" + (m ? " " + m + " m" : "");
    if (m) return m + " m" + (s % 60 ? " " + (s % 60) + " s" : "");
    return s + " s";
}
// Posición en la ventana: "now", "−12 s", "−4 m 10 s".
function ago(ms) {
    if (!known(ms)) return "";
    return ms < 1500 ? "now" : "−" + duration(ms / 1000);
}
function volts(v) { return known(v) ? v.toFixed(v < 10 ? 3 : 2) + " V" : "No data"; }
// Formato de una métrica por su unidad (la del recolector): %, °C, MHz, B, B/s, W, RPM.
function format(n, unit, tu) {
    if (unit === "B") return bytes(n);
    if (unit === "B/s") return bytes(n, true);
    if (unit === "MHz") return freq(n);
    if (unit === "%") return number(n, "%", known(n) && n < 10 ? 1 : 0);
    if (unit === "°C") return tempText(n, tu);
    if (unit === "W") return number(n, " W", 1);
    return number(n, unit ? " " + unit : "");
}
