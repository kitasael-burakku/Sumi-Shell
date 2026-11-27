#!/usr/bin/env node
/* F9 (ADR-42): `sumi/lib/nav-keys.js` sin sesión.   node tests/lib/nav-keys-test.js [árbol] */
"use strict";
const fs = require("fs"), path = require("path"), assert = require("assert");
const tree = process.argv[2] || path.join(__dirname, "..", "..", "sumi");
const src = fs.readFileSync(path.join(tree, "lib/nav-keys.js"), "utf8").replace(/^\.pragma library\s*\n/, "");
const N = new Function(src + "\nreturn { step: step };")();
// Los valores de Qt 6 (Qt::Key, Qt::KeyboardModifier)
const Q = { Key_Right: 0x01000014, Key_Left: 0x01000012, Key_Up: 0x01000013, Key_Down: 0x01000015,
            Key_Tab: 0x01000001, Key_Backtab: 0x01000002, Key_Home: 0x01000010, Key_End: 0x01000011,
            Key_Return: 0x01000004, Key_Enter: 0x01000005, Key_Space: 0x20, Key_Menu: 0x01000055,
            ShiftModifier: 0x02000000 };
let passed = 0; const failures = [];
function t(name, fn) { try { fn(); passed++; console.log("ok   " + name); } catch (e) { failures.push(name); console.log("FAIL " + name + "\n     " + e.message); } }
const s = (k, m, i, n) => N.step(Q[k], m ? Q.ShiftModifier : 0, i, n, Q);
t("avanzar: → ↓ Tab", () => { for (const k of ["Key_Right", "Key_Down", "Key_Tab"]) assert.deepStrictEqual(s(k, 0, 2, 5), { idx: 3, act: "", accepted: true }); });
t("retroceder: ← ↑ Shift+Tab Backtab", () => {
    for (const k of ["Key_Left", "Key_Up", "Key_Backtab"]) assert.strictEqual(s(k, 0, 2, 5).idx, 1);
    assert.strictEqual(s("Key_Tab", 1, 2, 5).idx, 1);
});
t("topes", () => { assert.strictEqual(s("Key_Right", 0, 4, 5).idx, 4); assert.strictEqual(s("Key_Left", 0, 0, 5).idx, 0); });
t("sin cursor: el primer paso cae en 0", () => { assert.strictEqual(s("Key_Right", 0, -1, 5).idx, 0); assert.strictEqual(s("Key_Left", 0, -1, 5).idx, 0); });
t("Inicio y Fin", () => { assert.strictEqual(s("Key_Home", 0, 3, 5).idx, 0); assert.strictEqual(s("Key_End", 0, 1, 5).idx, 4); });
t("activar: ⏎ Enter Espacio", () => { for (const k of ["Key_Return", "Key_Enter", "Key_Space"]) assert.strictEqual(s(k, 0, 1, 5).act, "activate"); });
t("secundaria: Shift+⏎ y Menú", () => { assert.strictEqual(s("Key_Return", 1, 1, 5).act, "secondary"); assert.strictEqual(s("Key_Menu", 0, 1, 5).act, "secondary"); });
t("sin cursor no se activa nada (pero se acepta)", () => { assert.deepStrictEqual(s("Key_Return", 0, -1, 5), { idx: -1, act: "", accepted: true }); });
t("cursor fuera de una lista que encogió", () => { assert.strictEqual(s("Key_Return", 0, 9, 5).idx, 4); });
t("otras teclas y lista vacía no se aceptan", () => { assert.strictEqual(s("Key_Space", 0, 1, 0).accepted, false); assert.strictEqual(N.step(0x41, 0, 1, 5, Q).accepted, false); });
console.log("\n" + passed + " passed, " + failures.length + " failed");
process.exit(failures.length ? 1 : 0);
