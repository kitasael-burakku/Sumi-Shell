pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/xdg.js" as Xdg

/**
 * Muestras de color de las tarjetas de Visual Profiles (rediseño 12B, 2026-09-28).
 *
 * futurevisual-profilesurface §«Previsualización y aplicación»: se calculan SIN aplicar el
 * esquema (`theme-preview.py samples`: `matugen --dry-run -j hex` con la misma config, el mismo
 * fondo o fotograma y modo oscuro), en segundo plano, con caché en disco por fondo, esquema y
 * config de generación. Una tarjeta pendiente dice «Generating samples» y nunca inventa una
 * paleta; una línea que llega de un fondo que ya no es se descarta.
 *
 * Static no se calcula: sus colores son los de `colors.static.json` (`Colors.sta`). Un preset (F-c) tampoco: sus
 * muestras vienen en su JSON (`ThemePreview.presets[].samples`).
 */
Singleton {
    id: root

    /** perfil → { state: "ready"|"pending"|"error"|"nowall", roles, cached } */
    property var samples: ({})
    readonly property string wall: ThemePreview.baseWall
    /** 12F: las muestras dependen también del modo, el contraste y el color de origen. */
    readonly property var opts: ThemePreview.sampleOpts
    readonly property string context: root.wall + "|" + root.opts.lightness + "|" + root.opts.contrast + "|" + root.opts.source
    readonly property string cacheDir: ThemePreview.testing ? ThemePreview.testRoot + "/samples"
        : Xdg.base(Quickshell.env("XDG_CACHE_HOME"), Quickshell.env("HOME") + "/.cache") + "/sumi-theme-samples"

    /** Lo que se pidió y aún no llegó, en el orden pedido (el enfocado primero). */
    property var wanted: []

    function sampleOf(profile) {
        if (profile === "static") {
            const sta = Colors.sta || {};
            return { state: Object.keys(sta).length > 0 ? "ready" : "error", roles: sta, cached: true };
        }
        if (ThemePreview.isPreset(profile)) {
            const x = ThemePreview.presetOf(profile);
            return x ? { state: "ready", roles: x.samples, cached: true } : { state: "error", roles: null, reason: "Unknown palette" };
        }
        return root.samples[profile] || { state: "idle", roles: null };
    }

    /** Pedir las muestras que falten, en este orden. Lo ya calculado para este fondo no se repite. */
    function ensure(order) {
        const need = [];
        const t = Object.assign({}, root.samples);
        let blocked = false;
        for (const p of order) {
            if (ThemePreview.isStatic(p) || Colors.schemes.indexOf(p) < 0) continue;
            const cur = root.samples[p];
            if (cur && (cur.state === "ready" || cur.state === "pending" || cur.state === "nowall")) continue;
            // F2c: sin matugen no se lanza el auxiliar: la muestra dice por qué (se reintenta al volver)
            const why = ThemePreview.whyNot(p);
            if (why.length > 0) {
                if (!cur || cur.reason !== why) { t[p] = { state: "error", roles: null, reason: why }; blocked = true; }
                continue;
            }
            need.push(p);
        }
        if (blocked && need.length === 0) root.samples = t;
        if (need.length === 0) return;
        for (const p of need) t[p] = { state: "pending", roles: null };
        root.samples = t;
        root.wanted = root.wanted.concat(need.filter(p => root.wanted.indexOf(p) < 0));
        root.kick();
    }

    /** Volver a intentar una que falló («Sample unavailable» → Retry). */
    function retry(profile) {
        const t = Object.assign({}, root.samples);
        delete t[profile];
        root.samples = t;
        root.ensure([profile]);
    }

    function kick() {
        if (proc.running || root.wanted.length === 0) return;
        proc.forWall = root.context;
        proc.batch = root.wanted.slice();
        root.wanted = [];
        proc.command = ["python3", ThemePreview.helper, "samples", "--profiles", proc.batch.join(","),
                        "--mode", root.opts.lightness, "--contrast", String(root.opts.contrast),
                        "--source", root.opts.source,
                        "--cache", root.cacheDir];
        proc.environment = ThemePreview.env;
        proc.running = true;
    }

    /** Otro fondo (o el árbol de prueba): lo calculado ya no representa nada. */
    onContextChanged: root.reset()
    Connections {
        target: ThemePreview
        function onTestingChanged() { root.reset(); }
    }
    function reset() {
        const pending = Object.keys(root.samples).filter(p => root.samples[p].state === "pending");
        root.samples = ({});
        root.wanted = [];
        if (proc.running) proc.running = false;
        // lo que se estaba esperando se vuelve a pedir, ya para el fondo nuevo
        if (pending.length > 0) Qt.callLater(() => root.ensure(pending));
    }

    Process {
        id: proc
        property string forWall: ""
        property var batch: []
        stdout: SplitParser {
            onRead: (line) => root.onLine(line, proc.forWall)
        }
        onExited: {
            // lo del lote que no llegó (proceso cortado o muerto) queda pendiente de nuevo
            const t = Object.assign({}, root.samples);
            let again = [];
            for (const p of proc.batch)
                if (t[p] && t[p].state === "pending") again.push(p);
            proc.batch = [];
            if (again.length > 0 && proc.forWall === root.context)
                for (const p of again) t[p] = { state: "error", roles: null, reason: "Sample unavailable" };
            root.samples = t;
            Qt.callLater(root.kick);
        }
    }

    function onLine(line, forWall) {
        let r = null;
        try { r = JSON.parse(line); } catch (e) { return; }
        // descartar lo que llega tarde de otro fondo
        if (!r || r.wall !== root.wall || forWall !== root.context) return;
        const t = Object.assign({}, root.samples);
        if (r.roles) t[r.profile] = { state: "ready", roles: r.roles, cached: r.cached === true };
        else if (r.error === "no-wallpaper") t[r.profile] = { state: "nowall", roles: null };
        else t[r.profile] = { state: "error", roles: null, reason: r.error || "Sample unavailable" };
        root.samples = t;
    }

    function summary() {
        const out = {};
        const primary = {};
        for (const p of Colors.schemes) {
            const sm = root.sampleOf(p);
            out[p] = sm.state;
            if (sm.roles) primary[p] = sm.roles.primary;
        }
        return { wall: root.wall, context: root.context, running: proc.running, batch: proc.batch, states: out, primary: primary };
    }
}
