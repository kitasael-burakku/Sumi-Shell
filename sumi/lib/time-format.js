.pragma library
/*
 * Contrato de tiempo (2026-11-27, ADR-42 «Contratos compartidos»).
 *
 * Una sola regla para las horas y las antigüedades de toda la shell. Antes cada superficie tenía su ternaria de
 * `Settings.clockFormat` (o ninguna: Monitor, Services, Sumi SDDM y las horas de los eventos de Calendar salían
 * siempre en 24 h) y unos diez «hace X» con umbrales y textos distintos.
 *
 * JS puro: el formateo de Qt (con el locale) lo pone quien llama (`services/Clock.qml`) como función, así la
 * lógica se prueba en node (`tests/lib/time-format-test.js`) y en la shell sale lo mismo que antes con
 * `Qt.formatTime`.
 */

/** El patrón de Qt de una hora: «HH:mm» / «h:mm AP», con segundos si se piden. */
function pattern(fmt, seconds) {
    const twelve = fmt === "12h";
    return (twelve ? "h:mm" : "HH:mm") + (seconds ? ":ss" : "") + (twelve ? " AP" : "");
}

/**
 * Una hora «HH:MM» de datos (la del calendario, `calendar-store.py`) en el formato del usuario.
 * `..:..` (un tramo que sigue de otro día) y lo que no sea una hora pasan tal cual.
 */
function hm(text, fmt, formatTime) {
    const m = /^(\d{1,2}):(\d{2})$/.exec(String(text || ""));
    if (!m) return String(text || "");
    if (fmt !== "12h") return text;
    const d = new Date(2000, 0, 1, Number(m[1]), Number(m[2]));
    return formatTime(d, pattern(fmt, false));
}

/** Días civiles entre `ms` y `nowMs` (0 hoy, 1 ayer). */
function dayDiff(ms, nowMs) {
    const day = function (x) { return new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime(); };
    return Math.round((day(new Date(nowMs)) - day(new Date(ms))) / 86400000);
}

/** «today 10:42» · «yesterday 18:10» · «Sep 25 18:10». `formatDate(date, "MMM d")` con el locale. */
function when(ms, nowMs, fmt, formatTime, formatDate) {
    if (!(ms > 0)) return "";
    const d = new Date(ms);
    const diff = dayDiff(ms, nowMs);
    const pre = diff === 0 ? "today" : diff === 1 ? "yesterday" : formatDate(d, "MMM d");
    return pre + " " + formatTime(d, pattern(fmt, false));
}

/**
 * Antigüedad de `ms` (milisegundos de época) respecto de `nowMs`, con los mismos umbrales en toda la shell:
 * menos de 90 s «ahora», menos de 90 min en minutos, menos de 48 h en horas, después en días.
 * Tres caras, según el sitio que haya:
 *   compact  «now» · «5m» · «3h» · «2d»                 (tarjetas de aviso, chips)
 *   spaced   «now» · «5 min» · «3 h» · «2 d»            (filas con algo de aire)
 *   long     «just now» · «5 min ago» · «3 h ago» · «2 d ago»   (frases)
 * Sin fecha (`!(ms > 0)`) devuelve `never` (por defecto ""). Una fecha futura cuenta como «ahora».
 */
function ago(ms, nowMs, style, never) {
    if (!(ms > 0)) return never === undefined ? "" : never;
    const sec = Math.max(0, (nowMs - ms) / 1000);
    const long = style === "long", compact = style === "compact";
    if (sec < 90) return long ? "just now" : "now";
    let n, unit;
    if (sec < 5400) { n = Math.round(sec / 60); unit = compact ? "m" : " min"; }
    else if (sec < 172800) { n = Math.round(sec / 3600); unit = compact ? "h" : " h"; }
    else { n = Math.round(sec / 86400); unit = compact ? "d" : " d"; }
    return n + unit + (long ? " ago" : "");
}
