pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "../lib/keybinds.js" as Lib

/**
 * Los 28 atajos globales de la shell y qué tecla los dispara (ayuda de atajos, 2026-10-30). SÓLO LECTURA: Hyprland es
 * el dueño de las combinaciones (P4); esto lee y enseña, nunca escribe su configuración.
 *
 * Dos fuentes, separadas a propósito:
 *   · `lib/shortcuts.json`, el catálogo de la shell: nombre (el identificador público de api/contract-v1.json, intacto),
 *     título, categoría, descripción (la que registra core/Shortcuts.qml), la tecla POR DEFECTO de los ejemplos y del
 *     instalador, y si la acción cambia algo al momento. Es la única fuente de esos datos (también para install.sh).
 *   · `hyprctl -j binds`, lo EFECTIVO. Con Lua (Hyprland 0.57) un bind de `hl.dsp.global` no dice qué atajo llama: sólo
 *     se identifica por su `description` = «Sumi Shell: <nombre>» (lo que escribe `install.sh hyprland --apply`).
 *     lib/keybinds.js decide bound / unknown / unbound; la tecla por defecto nunca pasa por efectiva.
 *
 * Coste: nada en reposo. Lee al reclamarse (la ventana de ayuda abierta, IPC) y relee con `configreloaded` mientras siga
 * reclamado.
 */
Singleton {
    id: root

    // ---- el catálogo (síncrono: core/Shortcuts.qml registra las descripciones al construirse) -------------------------
    readonly property var catalog: {
        try {
            const d = JSON.parse(catalogFile.text());
            if (d.format === 1 && Array.isArray(d.shortcuts)) return d;
        } catch (e) {}
        return { format: 0, appid: "sumi", descriptionPrefix: "Sumi Shell: ", categories: [], shortcuts: [] };
    }
    /**
     * Las acciones de la ayuda. Etapa C del Dashboard (2026-11-10): un alias (`"alias": "<otra>"`, hoy `media` → `mixer`)
     * sigue registrado como atajo global —quien lo llame funciona— pero no tiene tecla por defecto ni fila propia.
     */
    readonly property var actions: root.catalog.shortcuts.filter(s => !s.alias)
    readonly property var categories: root.catalog.categories
    readonly property bool catalogOk: root.catalog.format === 1 && root.actions.length > 0
    function action(name) {
        const all = root.catalog.shortcuts;
        for (let i = 0; i < all.length; i++)
            if (all[i].name === name) return all[i];
        return null;
    }
    /** La descripción con la que se registra el GlobalShortcut (`hyprctl globalshortcuts`). */
    function description(name) {
        const a = root.action(name);
        return a ? a.description : name;
    }
    function categoryTitle(id) {
        for (const c of root.categories) if (c.id === id) return c.title;
        return id;
    }
    function defaultCaps(name) {
        const a = root.action(name);
        const p = a ? Lib.parseCombo(a.defaultKeys) : null;
        return p ? p.caps : [];
    }
    /** La línea que liga la acción en un hyprland.lua, con la descripción que la hace reconocible aquí. */
    function luaLine(name) {
        const a = root.action(name);
        if (!a) return "";
        return 'hl.bind("' + a.defaultKeys.toUpperCase() + '", hl.dsp.global("' + root.catalog.appid + ':' + name + '"), { description = "'
            + root.catalog.descriptionPrefix + name + '" })';
    }
    function descriptionOption(name) {
        return '{ description = "' + root.catalog.descriptionPrefix + name + '" }';
    }

    FileView {
        id: catalogFile
        path: Quickshell.shellPath("lib/shortcuts.json")
        blockLoading: true
        blockAllReads: true
        printErrors: false
    }

    // ---- lo efectivo, bajo demanda -----------------------------------------------------------------------------------
    property var claims: ({})
    readonly property bool active: Object.keys(root.claims).length > 0
    function claim(who, on) {
        if (!!on === !!root.claims[who]) return;
        const c = Object.assign({}, root.claims);
        if (on) c[who] = true; else delete c[who];
        root.claims = c;
    }
    onActiveChanged: if (root.active) root.refresh("claim")

    /** "idle" (nunca leído) · "reading" · "ready" · "error" (no se pudo leer: ninguna fila dice bound ni unbound). */
    property string status: "idle"
    property string error: ""
    property var binds: []
    property string hyprVersion: ""
    property double readAt: 0
    property int reads: 0
    readonly property bool reading: bindsProc.running
    readonly property var resolved: root.status === "ready"
        ? Lib.resolve(root.actions, root.binds, { appid: root.catalog.appid, prefix: root.catalog.descriptionPrefix })
        : null

    function refresh(why) {
        if (bindsProc.running) { root.again = true; return; }
        if (root.status !== "ready") root.status = "reading";
        bindsProc.running = true;
        if (root.hyprVersion.length === 0 && !versionProc.running) versionProc.running = true;
    }
    property bool again: false

    /** Una fila: {state, keys, labelled, notes}; state "unread" si no hay lectura válida. */
    function rowOf(name) {
        const r = root.resolved ? root.resolved.rows[name] : null;
        return r || { state: root.status === "error" ? "unread" : "reading", keys: [], labelled: [], mislabeled: [], notes: [] };
    }
    /**
     * La tecla EFECTIVA de una acción para una pista («Super + Ctrl + Y»), o "" si no se conoce: sin lectura vigente, sin
     * identificar o sin asignar. Nunca la tecla por defecto. No lee nada (una pista no lanza procesos): vale lo de la
     * última lectura, que una recarga de Hyprland sin nadie que la reclame invalida.
     */
    function keyText(name) {
        const r = root.resolved ? root.resolved.rows[name] : null;
        return r && r.state === "bound" ? r.keys[0].text : "";
    }
    function matches(query, name) {
        const a = root.action(name);
        return a ? Lib.matches(query, a, root.rowOf(name)) : false;
    }

    Process {
        id: bindsProc
        command: ["timeout", "3", "hyprctl", "-j", "binds"]
        stdout: StdioCollector {
            onStreamFinished: {
                let list = null;
                try { list = JSON.parse(this.text); } catch (e) {}
                if (Array.isArray(list)) {
                    root.binds = list;
                    root.error = "";
                    root.status = "ready";
                } else {
                    root.error = this.text.trim().length > 0 ? "Hyprland answered something that isn't a list of bindings"
                        : "Hyprland didn't answer";
                    root.status = "error";
                }
                root.readAt = Date.now();
                root.reads++;
            }
        }
        // hyprctl ausente: `running` cae sin `exited` (memoria del proyecto)
        onRunningChanged: {
            if (running) return;
            if (root.status === "reading") { root.status = "error"; root.error = "hyprctl didn't run"; }
            if (root.again) { root.again = false; root.refresh("again"); }
        }
    }
    Process {
        id: versionProc
        command: ["timeout", "3", "hyprctl", "-j", "version"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const v = JSON.parse(this.text);
                    root.hyprVersion = String(v.tag || v.version || "").replace(/^v/, "");
                } catch (e) {}
            }
        }
    }

    Timer { id: debounce; interval: 300; onTriggered: if (root.active) root.refresh("configreloaded") }
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name !== "configreloaded") return;
            if (root.active) debounce.restart();
            else if (root.status === "ready") root.status = "idle";   // sin nadie que relea: lo leído ya no vale
        }
    }

    function summary() {
        const r = root.resolved;
        return { status: root.status, error: root.error, reads: root.reads, readAt: root.readAt, hyprland: root.hyprVersion,
                 catalog: root.catalogOk, actions: root.actions.length, claims: Object.keys(root.claims),
                 counts: r ? r.summary.counts : null, unnamedGlobals: r ? r.summary.unnamedGlobals : 0,
                 opaque: r ? r.summary.opaque : 0, mislabeled: r ? r.summary.mislabeled : 0,
                 legacy: r ? r.summary.legacy : 0,
                 strays: r ? r.summary.strays : [], dialect: r ? r.summary.dialect : "" };
    }
}
