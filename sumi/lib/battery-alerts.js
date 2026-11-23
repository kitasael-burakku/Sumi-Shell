.pragma library
/* Política pura de avisos: sólo descarga real, un aviso por umbral, histéresis de
 * dos puntos para que 19,9 ↔ 20,1 no produzca una tormenta. El agregado lo calcula
 * UPower; no se suman porcentajes ni se generan avisos por cada batería física. */
function advance(previous, sample, thresholds, enabled) {
    var key = thresholds.join("/");
    var seen = previous && previous.key === key ? previous.seen.slice() : [false, false, false];
    var level = 0;
    if (sample.present && isFinite(sample.percent)) {
        for (var i = 0; i < thresholds.length; i++) {
            if (sample.percent >= thresholds[i] + 2) seen[i] = false;
            if (enabled && sample.discharging && sample.onBattery && sample.percent <= thresholds[i] && !seen[i])
                level = i + 1;
        }
    }
    // Un salto directo al 5 % produce sólo el aviso crítico, nunca tres avisos.
    if (level > 0) for (var j = 0; j < level; j++) seen[j] = true;
    return { state: { key: key, seen: seen }, level: level };
}

function timeText(seconds) {
    if (!isFinite(seconds) || seconds <= 0) return "";
    var minutes = Math.max(1, Math.ceil(seconds / 60));
    return minutes < 60 ? minutes + " min" : Math.floor(minutes / 60) + " h"
        + (minutes % 60 ? " " + minutes % 60 + " min" : "");
}

if (typeof module !== "undefined") module.exports = { advance: advance, timeText: timeText };
