#!/usr/bin/env node
/*
 * Contrato de tiempo (ADR-42): `sumi/lib/time-format.js` sin sesión.
 *
 *   node tests/lib/time-format-test.js [árbol-de-la-shell]
 *
 * El formateo con locale de Qt se sustituye por uno fijo en inglés: aquí se prueba la lógica (patrones, umbrales,
 * días civiles), no el locale.
 */
"use strict";
const fs = require("fs");
const path = require("path");
const assert = require("assert");

const tree = process.argv[2] || path.join(__dirname, "..", "..", "sumi");
function load(file) {
    const src = fs.readFileSync(file, "utf8").replace(/^\.pragma library\s*\n/, "");
    const names = ["pattern", "hm", "dayDiff", "when", "ago"];
    return new Function(src + "\nreturn {" + names.map(n => n + ":" + n).join(",") + "};")();
}
const T = load(path.join(tree, "lib/time-format.js"));

// Sustituto de Qt.formatTime / Qt.formatDate para los patrones que usa la lib.
const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const p2 = n => (n < 10 ? "0" : "") + n;
function fmtTime(d, pat) {
    const H = d.getHours(), h = H % 12 === 0 ? 12 : H % 12;
    return pat.replace("HH", p2(H)).replace(/\bh\b/, String(h)).replace("mm", p2(d.getMinutes()))
        .replace("ss", p2(d.getSeconds())).replace("AP", H < 12 ? "AM" : "PM");
}
function fmtDate(d, pat) {
    assert.strictEqual(pat, "MMM d");
    return MON[d.getMonth()] + " " + d.getDate();
}

let passed = 0;
const failures = [];
function t(name, fn) {
    try { fn(); passed++; console.log("ok   " + name); }
    catch (e) { failures.push(name); console.log("FAIL " + name + "\n     " + (e && e.message ? e.message : e)); }
}
const eq = assert.strictEqual;

t("pattern 24h / 12h, con y sin segundos", () => {
    eq(T.pattern("24h", false), "HH:mm");
    eq(T.pattern("24h", true), "HH:mm:ss");
    eq(T.pattern("12h", false), "h:mm AP");
    eq(T.pattern("12h", true), "h:mm:ss AP");
    eq(T.pattern(undefined, false), "HH:mm");
});

t("hm: 24h deja el dato tal cual", () => {
    eq(T.hm("09:05", "24h", fmtTime), "09:05");
    eq(T.hm("23:59", "24h", fmtTime), "23:59");
});
t("hm: 12h reformatea", () => {
    eq(T.hm("09:05", "12h", fmtTime), "9:05 AM");
    eq(T.hm("00:00", "12h", fmtTime), "12:00 AM");
    eq(T.hm("12:30", "12h", fmtTime), "12:30 PM");
    eq(T.hm("23:59", "12h", fmtTime), "11:59 PM");
});
t("hm: ..:.. y textos que no son hora pasan", () => {
    eq(T.hm("..:..", "12h", fmtTime), "..:..");
    eq(T.hm("", "12h", fmtTime), "");
    eq(T.hm(undefined, "12h", fmtTime), "");
    eq(T.hm("All day", "12h", fmtTime), "All day");
});

const now = new Date(2026, 10, 27, 10, 0, 0).getTime();
t("when: hoy, ayer, otro día", () => {
    eq(T.when(new Date(2026, 10, 27, 8, 42).getTime(), now, "24h", fmtTime, fmtDate), "today 08:42");
    eq(T.when(new Date(2026, 10, 26, 23, 59).getTime(), now, "24h", fmtTime, fmtDate), "yesterday 23:59");
    eq(T.when(new Date(2026, 8, 25, 18, 10).getTime(), now, "12h", fmtTime, fmtDate), "Sep 25 6:10 PM");
    eq(T.when(0, now, "24h", fmtTime, fmtDate), "");
    eq(T.when(-5, now, "24h", fmtTime, fmtDate), "");
});
t("when: medianoche cuenta como hoy", () => {
    eq(T.when(new Date(2026, 10, 27, 0, 0).getTime(), now, "24h", fmtTime, fmtDate), "today 00:00");
});
t("dayDiff a través del cambio de hora (marzo)", () => {
    const a = new Date(2026, 2, 28, 12).getTime(), b = new Date(2026, 2, 30, 12).getTime();
    eq(T.dayDiff(a, b), 2);
});

const S = 1000, M = 60 * S, H = 60 * M, D = 24 * H;
t("ago: umbrales comunes", () => {
    eq(T.ago(now - 59 * S, now, "compact"), "now");
    eq(T.ago(now - 89 * S, now, "compact"), "now");
    eq(T.ago(now - 90 * S, now, "compact"), "2m");
    eq(T.ago(now - 5 * M, now, "compact"), "5m");
    eq(T.ago(now - 89 * M, now, "compact"), "89m");
    eq(T.ago(now - 90 * M, now, "compact"), "2h");
    eq(T.ago(now - 47 * H, now, "compact"), "47h");
    eq(T.ago(now - 48 * H, now, "compact"), "2d");
    eq(T.ago(now - 10 * D, now, "compact"), "10d");
});
t("ago: las tres caras", () => {
    eq(T.ago(now - 30 * S, now, "spaced"), "now");
    eq(T.ago(now - 30 * S, now, "long"), "just now");
    eq(T.ago(now - 5 * M, now, "spaced"), "5 min");
    eq(T.ago(now - 5 * M, now, "long"), "5 min ago");
    eq(T.ago(now - 3 * H, now, "spaced"), "3 h");
    eq(T.ago(now - 3 * H, now, "long"), "3 h ago");
    eq(T.ago(now - 3 * D, now, "spaced"), "3 d");
    eq(T.ago(now - 3 * D, now, "long"), "3 d ago");
});
t("ago: sin fecha y futuro", () => {
    eq(T.ago(0, now, "long"), "");
    eq(T.ago(undefined, now, "long"), "");
    eq(T.ago(NaN, now, "long", "never"), "never");
    eq(T.ago(0, now, "spaced", "never"), "never");
    eq(T.ago(now + 10 * M, now, "compact"), "now");
});

console.log("\n" + passed + " passed, " + failures.length + " failed");
process.exit(failures.length ? 1 : 0);
