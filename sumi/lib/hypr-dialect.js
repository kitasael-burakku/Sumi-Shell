.pragma library
/*
 * Cómo se le habla a Hyprland según el dialecto de su config (portabilidad F5a, 2026-10-10; H-03, HC-61/62).
 *
 * Hyprland 0.56 acepta dos gestores de config y el dispatch y la config en caliente cambian con él (medido en
 * F0 y en F5a, `tools/f5/dialect-measure.py`): con Lua, `hl.dsp.…` y `hyprctl eval "hl.config({…})"`; con
 * `hyprland.conf` (hyprlang), los dispatchers clásicos y `hyprctl keyword`. La forma cruzada falla SIN error
 * (rc 0, «Invalid dispatcher» o «eval is only supported with the lua config manager») y la shell creía
 * haberlo hecho. Este archivo sólo CONSTRUYE el texto: no detecta (eso es `services/HyprCtl`) ni ejecuta.
 *
 * Dialectos: "lua" | "hyprlang". Cualquier otro valor (`pending`, `unknown`) se trata como "lua": es lo que
 * emitía la shell antes de F5 (regla de F2: lo no comprobado se ofrece como hoy).
 * Las formas Lua son, byte a byte, las de antes (tools/f5/argv-before.json, D1–D5 y M1–M4).
 *
 * Hyprland 0.57 (2026-10-30) ya no lee hyprland.conf: la sonda de HyprCtl da "lua" (medido) y esta tabla emite la
 * forma Lua de siempre. La rama "hyprlang" queda CONGELADA para Hyprland ≤ 0.56: se conserva tal cual y no se le añade
 * nada nuevo (un verbo nuevo puede devolver null con hyprlang). Su retirada: portabilidad/ROADMAP.md.
 *
 * Todo valor se valida aquí, antes de llegar a Hyprland (ADR-2, SECURITY.md M1): un argumento inválido
 * devuelve null y quien llama no envía nada. La misma tabla vive en `scripts/hypr_dialect.py` (dpms y
 * monitores); `tools/f5/dialect-vectors.json` comprueba que coinciden.
 */

function norm(d) { return d === "hyprlang" ? "hyprlang" : "lua"; }

var ADDR = /^0x[0-9a-f]+$/;
var SPECIAL = /^special:[A-Za-z0-9_-]+$/;

function wsOk(ws) { return (typeof ws === "number" && ws === Math.floor(ws) && ws >= 1) || (typeof ws === "string" && SPECIAL.test(ws)); }

/**
 * dispatch(dialect, verb, a) → el argumento de `dispatch` (lo que va tras «dispatch »), o null.
 *   focusWorkspace {workspace: n}
 *   moveSilent     {workspace: n | "special:<nombre>", address: "0x…"}   (mover sin seguirla)
 *   focusWindow    {address: "0x…"}
 *   exit           {}
 *   dpms           {on: bool}
 *   sendShortcut   {mods: "CTRL" | "CTRL SHIFT", key: "V", address: "0x…"}   (selector de emojis, 2026-11-17:
 *                  «pegar» en la ventana de antes sin wtype; sólo Lua: con hyprlang, congelado, da null)
 */
function dispatch(dialect, verb, a) {
    var d = norm(dialect);
    a = a || {};
    if (verb === "focusWorkspace") {
        if (typeof a.workspace !== "number" || !wsOk(a.workspace)) return null;
        return d === "lua" ? "hl.dsp.focus({ workspace = " + a.workspace + " })" : "workspace " + a.workspace;
    }
    if (verb === "moveSilent") {
        if (!wsOk(a.workspace) || typeof a.address !== "string" || !ADDR.test(a.address)) return null;
        if (d === "hyprlang") return "movetoworkspacesilent " + a.workspace + ",address:" + a.address;
        var w = typeof a.workspace === "number" ? String(a.workspace) : "\"" + a.workspace + "\"";
        return "hl.dsp.window.move({ workspace = " + w + ", follow = false, window = \"address:" + a.address + "\" })";
    }
    if (verb === "focusWindow") {
        if (typeof a.address !== "string" || !ADDR.test(a.address)) return null;
        return d === "lua" ? "hl.dsp.focus({ window = \"address:" + a.address + "\" })" : "focuswindow address:" + a.address;
    }
    if (verb === "exit") return d === "lua" ? "hl.dsp.exit()" : "exit";
    if (verb === "sendShortcut") {
        if (d !== "lua") return null;
        if (a.mods !== "CTRL" && a.mods !== "CTRL SHIFT") return null;
        if (a.key !== "V") return null;
        if (typeof a.address !== "string" || !ADDR.test(a.address)) return null;
        return "hl.dsp.send_shortcut({ mods = \"" + a.mods + "\", key = \"" + a.key + "\", window = \"address:"
            + a.address + "\" })";
    }
    if (verb === "dpms") {
        if (typeof a.on !== "boolean") return null;
        return d === "lua" ? "hl.dsp.dpms({ action = \"" + (a.on ? "enable" : "disable") + "\" })" : "dpms " + (a.on ? "on" : "off");
    }
    return null;
}

/** Las opciones de los modos (services/Modes) y su forma Lua. */
var HOT = {
    blur: { option: "decoration:blur:enabled", lua: function (v) { return "decoration = { blur = { enabled = " + v + " } }"; } },
    animations: { option: "animations:enabled", lua: function (v) { return "animations = { enabled = " + v + " }"; } },
    cursors: { option: "plugin:dynamic_cursors:enabled", lua: function (v) { return "plugin = { dynamic_cursors = { enabled = " + v + " } }"; } }
};

/**
 * hotConfig(dialect, key, value) → los argumentos de `hyprctl` (sin el ejecutable), o null.
 *   blur | animations | cursors: value booleano
 *   glass: value {enabled: 0|1, blur: 0|1}
 * Lua: `eval "hl.config({ … })"`. hyprlang: `keyword <opción> <valor>` (dos opciones: `--batch`). En hyprlang,
 * `keyword` de una opción que no existe responde «ok» (medido): por eso Modes lee antes con getoption.
 */
function hotConfig(dialect, key, value) {
    var d = norm(dialect);
    if (HOT[key]) {
        if (typeof value !== "boolean") return null;
        var v = String(value);
        return d === "lua" ? ["eval", "hl.config({ " + HOT[key].lua(v) + " })"] : ["keyword", HOT[key].option, v];
    }
    if (key === "glass") {
        if (!value || typeof value !== "object") return null;
        var e = Number(value.enabled), b = Number(value.blur);
        if ((e !== 0 && e !== 1) || (b !== 0 && b !== 1)) return null;
        if (d === "lua")
            return ["eval", "hl.config({ plugin = { hyprglass = { enabled = " + e + ", manage_window_blur = " + b + " } } })"];
        return ["--batch", "keyword plugin:hyprglass:enabled " + e + " ; keyword plugin:hyprglass:manage_window_blur " + b];
    }
    return null;
}

/** La respuesta de la sonda `hyprctl eval 'local _ = 0'` → "lua" | "hyprlang" | "unknown". */
function classify(reply) {
    var t = String(reply || "").trim();
    if (t === "ok") return "lua";
    if (/only supported with the lua config manager/.test(t)) return "hyprlang";
    return "unknown";
}
