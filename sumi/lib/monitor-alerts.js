.pragma library
// Umbrales de System Monitor (antes de la fase 12, M1). ÚNICO sitio donde viven: la surface, la UI
// y el IPC leen las alertas que Sysmon calcula con esto. Documentados en docs/IPC.md §Sysmon.
//
// Una alerta pide una condición SOSTENIDA en el historial de 60 s (muestras de 1 s): un pico breve
// no es un problema. Sin datos no hay alerta (ausencia nunca es éxito ni fallo), salvo la pérdida
// de una lectura que antes existía, que es su propia alerta.

var T = {
    // Temperatura: el límite que publica el sensor (crit, si no max). Sin límite publicado, el
    // de reserva por tipo. Sostenida 10 s.
    tempFallbackC: { cpu: 90, gpu: 95, storage: 75 },
    tempSustainS: 10,
    // Memoria disponible: aviso bajo el 10 % 10 s; crítica bajo el 5 % 5 s.
    memWarnAvailPct: 10, memWarnSustainS: 10,
    memCritAvailPct: 5, memCritSustainS: 5,
    // Swap creciendo: más de 256 MiB en los últimos 30 s.
    swapGrowthB: 256 * 1048576, swapGrowthWindowS: 30,
    // Disco casi lleno: disponible bajo el 10 % (aviso) o el 5 % (crítico) del volumen.
    diskWarnAvailPct: 10, diskCritAvailPct: 5,
    // E/S sostenida: dispositivo ocupado ≥ 90 % durante 30 s.
    ioBusyPct: 90, ioSustainS: 30,
    // Lectura perdida: existía en esta sesión de muestreo y lleva 5 muestras sin valor.
    lostSamples: 5
};

function known(n) { return typeof n === "number" && isFinite(n); }

// Las últimas `seconds` muestras cumplen `test` todas, y hay al menos ese número de muestras.
function sustained(rows, seconds, test) {
    if (!rows.length) return false;
    var end = rows[rows.length - 1].monoMs, n = 0;
    for (var i = rows.length - 1; i >= 0 && end - rows[i].monoMs < seconds * 1000; i--) {
        if (!test(rows[i])) return false;
        n++;
    }
    return n >= Math.max(2, seconds - 1);
}

function limitOf(o, kind) {
    if (known(o.temperatureCriticalC)) return { c: o.temperatureCriticalC, source: "sensor" };
    if (known(o.temperatureMaxC)) return { c: o.temperatureMaxC, source: "sensor" };
    return { c: T.tempFallbackC[kind], source: "default" };
}

// rows: historial (cada fila con `.v`, las métricas planas); seen: claves que alguna vez tuvieron valor.
function evaluate(rows, seen, tu) {
    // F11: el texto en la unidad del usuario; el umbral, siempre en °C
    var deg = function(c) { return tu === "fahrenheit" ? Math.round(c * 9 / 5 + 32) + " °F" : Math.round(c) + " °C"; };
    var out = [];
    if (!rows.length) return out;
    var now = rows[rows.length - 1];
    function v(row, key) { var x = row.v ? row.v[key] : null; return known(x) ? x : null; }
    function add(id, level, domain, title, detail) { out.push({ id: id, level: level, domain: domain, title: title, detail: detail }); }

    // Temperaturas: CPU, cada GPU, cada disco con sensor.
    var temps = [];
    if (now.cpu) temps.push({ key: "cpu.temp", o: now.cpu, kind: "cpu", name: "CPU", domain: "cpu" });
    (now.gpus || []).forEach(function(g) { temps.push({ key: "gpu/" + g.id + "/temp", o: g, kind: "gpu", name: "GPU " + (g.card || g.id), domain: "gpu" }); });
    (now.disks || []).forEach(function(d) { temps.push({ key: "disk/" + d.id + "/temp", o: d, kind: "storage", name: "Disk " + d.id, domain: "disks" }); });
    temps.forEach(function(t) {
        var lim = limitOf(t.o, t.kind);
        if (!known(lim.c)) return;
        if (sustained(rows, T.tempSustainS, function(r) { var x = v(r, t.key); return x !== null && x >= lim.c; }))
            add("temp:" + t.key, "warning", t.domain, t.name + " temperature high",
                deg(v(now, t.key)) + " for " + T.tempSustainS + " s · limit " + deg(lim.c) + (lim.source === "default" ? " (default)" : " (sensor)"));
    });

    // Memoria disponible.
    function availPct(r) { var a = v(r, "mem.avail"), t = r.memory ? r.memory.totalB : null; return a !== null && known(t) && t > 0 ? a * 100 / t : null; }
    if (sustained(rows, T.memCritSustainS, function(r) { var p = availPct(r); return p !== null && p < T.memCritAvailPct; }))
        add("memory:low", "critical", "memory", "Memory critically low", Math.round(availPct(now)) + "% available");
    else if (sustained(rows, T.memWarnSustainS, function(r) { var p = availPct(r); return p !== null && p < T.memWarnAvailPct; }))
        add("memory:low", "warning", "memory", "Memory running low", Math.round(availPct(now)) + "% available");

    // Swap creciendo.
    var first = null;
    for (var i = rows.length - 1; i >= 0 && now.monoMs - rows[i].monoMs <= T.swapGrowthWindowS * 1000; i--)
        if (v(rows[i], "swap.used") !== null) first = rows[i];
    if (first && v(now, "swap.used") !== null && v(now, "swap.used") - v(first, "swap.used") > T.swapGrowthB)
        add("swap:growing", "warning", "memory", "Swap growing quickly",
            "+" + Math.round((v(now, "swap.used") - v(first, "swap.used")) / 1048576) + " MiB in " + Math.round((now.monoMs - first.monoMs) / 1000) + " s");

    // Volúmenes casi llenos (dato lento: basta la muestra actual).
    (now.disks || []).forEach(function(d) {
        (d.volumes || []).forEach(function(vol) {
            if (!known(vol.availableB) || !known(vol.totalB) || vol.totalB <= 0) return;
            var p = vol.availableB * 100 / vol.totalB;
            if (p < T.diskWarnAvailPct)
                add("disk:full:" + vol.id, p < T.diskCritAvailPct ? "critical" : "warning", "disks",
                    (vol.label || vol.device) + " almost full", Math.round(p) + "% available · " + vol.mounts.join(", "));
        });
        (d.io || []).forEach(function(io) {
            var key = "io/" + io.device + "/busy";
            if (sustained(rows, T.ioSustainS, function(r) { var x = v(r, key); return x !== null && x >= T.ioBusyPct; }))
                add("io:" + io.device, "warning", "disks", io.device + " busy", "≥ " + T.ioBusyPct + "% busy for " + T.ioSustainS + " s");
        });
    });

    // Lecturas perdidas. Las de GPU sólo si la GPU sigue presente (retirarla no es perder su sensor).
    var names = { "cpu.usage": ["CPU usage", "cpu"], "cpu.temp": ["CPU temperature", "cpu"], "mem.used": ["Memory", "memory"], "net.rx": ["Network counters", "network"] };
    (now.gpus || []).forEach(function(g) {
        names["gpu/" + g.id + "/usage"] = ["GPU " + (g.card || g.id) + " usage", "gpu"];
        names["gpu/" + g.id + "/temp"] = ["GPU " + (g.card || g.id) + " temperature", "gpu"];
    });
    for (var key in names) {
        if (!seen[key] || rows.length < T.lostSamples) continue;
        var lost = true;
        for (var j = rows.length - T.lostSamples; j < rows.length; j++) if (v(rows[j], key) !== null) { lost = false; break; }
        if (lost) add("lost:" + key, "warning", names[key][1], names[key][0] + " no longer reported", "Was available earlier in this session");
    }
    return out;
}
