#!/usr/bin/env node
/*
 * ADR-42: `sumi/lib/wheel.js` sin sesión.   node tests/lib/wheel-test.js [árbol-de-la-shell]
 */
"use strict";
const fs = require("fs");
const path = require("path");
const assert = require("assert");

const tree = process.argv[2] || path.join(__dirname, "..", "..", "sumi");
const src = fs.readFileSync(path.join(tree, "lib/wheel.js"), "utf8").replace(/^\.pragma library\s*\n/, "");
const W = new Function(src + "\nreturn { delta: delta, step: step };")();

let passed = 0;
const failures = [];
function t(name, fn) {
    try { fn(); passed++; console.log("ok   " + name); }
    catch (e) { failures.push(name); console.log("FAIL " + name + "\n     " + (e && e.message ? e.message : e)); }
}
function run(events, unit) {
    let acc = 0, total = 0;
    for (const dy of events) { const r = W.step(acc, dy, unit); acc = r.acc; total += r.steps; }
    return { acc, total };
}

t("una muesca = un paso, en los dos sentidos", () => {
    assert.deepStrictEqual(W.step(0, 120), { acc: 0, steps: 1 });
    assert.deepStrictEqual(W.step(0, -120), { acc: 0, steps: -1 });
});
t("trozos de touchpad se suman (3 × 40 = 1 paso)", () => {
    assert.deepStrictEqual(run([40, 40, 40]), { acc: 0, total: 1 });
    assert.deepStrictEqual(run([40, 40]), { acc: 80, total: 0 });
});
t("muchos trozos pequeños dan los pasos exactos", () => {
    assert.strictEqual(run(Array(30).fill(12)).total, 3);
});
t("cambiar de sentido empieza de cero", () => {
    assert.deepStrictEqual(run([100, -40]), { acc: -40, total: 0 });
    assert.deepStrictEqual(run([100, -120]), { acc: 0, total: -1 });
});
t("una ráfaga grande da varios pasos de golpe", () => {
    assert.deepStrictEqual(W.step(0, 360), { acc: 0, steps: 3 });
    assert.deepStrictEqual(W.step(60, 300), { acc: 0, steps: 3 });
});
t("dy 0 no cambia nada", () => {
    assert.deepStrictEqual(W.step(50, 0), { acc: 50, steps: 0 });
});
t("delta: vertical, o horizontal invertido", () => {
    assert.strictEqual(W.delta({ x: 0, y: -120 }), -120);
    assert.strictEqual(W.delta({ x: 120, y: 0 }), -120);
    assert.strictEqual(W.delta({ x: 30, y: 60 }), 60);
});

console.log("\n" + passed + " passed, " + failures.length + " failed");
process.exit(failures.length ? 1 : 0);
