pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "../lib/system-catalog.js" as Catalog

/**
 * La configuración de Hyprland que ve Settings → System (fase 14A, sólo lectura).
 *
 * SÓLO INFORMACIÓN (decisión del usuario, 2026-09-29; la integración que escribía un módulo propio,
 * 14C primera versión, se descartó): Settings dice qué vale cada cosa y en qué archivo y línea vive,
 * y se edita a mano. La carpeta no se supone: `hypr-config.py` la busca desde el proceso de
 * Hyprland (`--config`, su XDG_CONFIG_HOME o HOME) — `config` dice cuál y cómo la encontró.
 *
 * Dos fuentes, y la diferencia entre ellas es lo que importa (futureSettingssurface §13,
 * requested frente a effective):
 *   · lo ESCRITO: `scripts/hypr-config.py` recorre hyprland.lua en el orden de sus `require` y
 *     dice en qué archivo y línea se fija cada clave (sin ejecutar el Lua);
 *   · lo EFECTIVO: `getoption` de las claves del catálogo, en el mismo proceso.
 * Si no coinciden, algo lo cambió en caliente (un modo, el tema, una prueba): se dice.
 *
 * Por dispositivo NO hay efectivo (medido en 0.56.2: `getoption` no los conoce y
 * `hl.get_config` da nil); sólo lo escrito en los `hl.device`. Por eso una opción global con
 * un dispositivo que la sobrescribe lo avisa: el global no le llega a ese aparato.
 *
 * Coste: nada en reposo. Lee al reclamarse (páginas Displays, Input y Hyprland a la vista, IPC)
 * y relee con `configreloaded` / `monitoradded` / `monitorremoved` mientras siga reclamado.
 */
Singleton {
    id: root

    property var claims: ({})
    readonly property bool active: Object.keys(root.claims).length > 0
    function claim(who, on) {
        if (!!on === !!root.claims[who]) return;
        const c = Object.assign({}, root.claims);
        if (on) c[who] = true; else delete c[who];
        root.claims = c;
    }
    onActiveChanged: {
        if (root.active) root.read();
        else { debounce.stop(); root.data = ({}); root.loaded = false; root.error = ""; }
    }

    property var data: ({})
    property bool loaded: false
    property bool reading: proc.running
    property string error: ""
    property double readAt: 0
    /** Cuántas lecturas hizo (pruebas: una recarga de Hyprland debe sumar una). */
    property int reads: 0

    function read() {
        if (proc.running) { root.again = true; return; }
        proc.running = true;
    }
    property bool again: false

    Process {
        id: proc
        command: ["python3", Quickshell.shellPath("scripts/hypr-config.py"), "read"].concat(Catalog.keys())
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const o = JSON.parse(this.text);
                    if (o.error) { root.error = o.error; }
                    else { root.data = o; root.error = o.scanError || ""; root.loaded = true; }
                } catch (e) {
                    root.error = "Could not read Hyprland's configuration";
                }
                root.readAt = Date.now();
                root.reads++;
            }
        }
        onRunningChanged: if (!running && root.again) { root.again = false; root.read(); }
    }

    Timer { id: debounce; interval: 300; onTriggered: if (root.active) root.read() }
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (!root.active) return;
            const n = event.name;
            if (n === "configreloaded" || n.indexOf("monitoradded") === 0 || n.indexOf("monitorremoved") === 0)
                debounce.restart();
        }
    }

    // ---- consultas ---------------------------------------------------------------------

    function effective(key) {
        const e = root.data.effective;
        return e && e[key] ? e[key] : null;
    }
    /** Dónde se escribe `key` (y sus subclaves: gaps_out.top…), en orden de carga. */
    function sources(key) {
        const opts = root.data.options || {};
        const p = Catalog.path(key);
        let out = [];
        for (const k of Object.keys(opts))
            if (k === p || k.indexOf(p + ".") === 0)
                out = out.concat(opts[k].map(x => Object.assign({ path: k }, x)));
        out.sort((a, b) => a.order - b.order || a.line - b.line);
        return out;
    }
    /** El valor escrito que gana (el último cargado); para lados, los cuatro juntos. */
    function written(key) {
        const s = root.sources(key);
        if (s.length === 0) return undefined;
        const c = Catalog.byKey(key);
        if (c && c.type === "sides") {
            const last = s[s.length - 1];
            if (last.path === Catalog.path(key)) {
                const v = last.value;
                return typeof v === "number" ? [v, v, v, v] : (Array.isArray(v) ? v : undefined);
            }
            // escrito por lados: el último de cada uno
            const side = n => { const l = s.filter(x => x.path.endsWith("." + n)); return l.length ? l[l.length - 1].value : undefined; };
            const r = [side("top"), side("right"), side("bottom"), side("left")];
            return r.some(x => typeof x !== "number") ? undefined : r;
        }
        return s[s.length - 1].value;
    }
    function origin(key) {
        const s = root.sources(key);
        return s.length ? s[s.length - 1] : null;
    }
    function same(a, b) {
        if (Array.isArray(a) && Array.isArray(b))
            return a.length === b.length && a.every((x, i) => root.same(x, b[i]));
        if (typeof a === "number" && typeof b === "number") return Math.abs(a - b) < 1e-4;
        if (typeof a === "boolean" || typeof b === "boolean") return !!a === !!b;
        return String(a) === String(b);
    }
    /** Lo escrito y lo efectivo no coinciden (o hay algo escrito que no es literal). */
    function drift(key) {
        const e = root.effective(key), w = root.written(key);
        if (!e || w === undefined || e.value === null) return false;
        if (w && typeof w === "object" && !Array.isArray(w)) return false;   // expresión: no se compara
        const ev = e.type === "bool" ? !!e.value : e.value;
        return !root.same(w, ev);
    }

    function num(v) {
        const r = Math.round(v * 100) / 100;
        return String(r);
    }
    function format(c, v) {
        if (v === undefined || v === null) return "";
        if (c && c.type === "sides" && Array.isArray(v))
            return v.every(x => x === v[0]) ? v[0] + (c.unit ? " " + c.unit : "")
                : v.join(" · ") + (c.unit ? " " + c.unit : "");
        if (c && c.type === "bool") return v ? "On" : "Off";
        if (c && c.type === "enum") {
            const i = c.options.map(String).indexOf(String(v));
            if (i >= 0 && c.labels) return c.labels[i];
            return String(v).length ? String(v).charAt(0).toUpperCase() + String(v).slice(1) : "Default";
        }
        if (c && c.type === "string") return String(v).length ? String(v) : "None";
        if (typeof v === "number") return root.num(v) + (c && c.unit ? " " + c.unit : "");
        if (typeof v === "object" && v.expr) return "(computed)";
        return String(v);
    }
    /** El valor efectivo, corto. */
    function text(key) {
        const e = root.effective(key);
        // sin reclamación no se lee nada: vacío, no «Reading…» (la búsqueda enseña valores con la página cerrada)
        if (!root.loaded) return root.error.length ? "Unavailable" : root.active ? "Reading…" : "";
        if (!e || e.type === "missing") return "Unknown";
        if (e.type === "gradient") return "From the theme";
        return root.format(Catalog.byKey(key), e.type === "bool" ? !!e.value : e.value);
    }
    /** Dispositivos con su propio valor para una opción global (`device` del catálogo). */
    function overrides(key) {
        const c = Catalog.byKey(key);
        if (!c || !c.device) return [];
        const devs = root.data.devices || {}, out = [];
        const present = root.presentDevices();
        for (const name of Object.keys(root.data.devices || {})) {
            const d = devs[name][c.device];
            if (d && d.length) {
                const last = d[d.length - 1];
                out.push({ device: name, value: last.value, file: last.file, line: last.line,
                           present: present.indexOf(name) >= 0 });
            }
        }
        return out;
    }
    /** El segundo renglón: dónde se fija y qué lo tapa. Nunca promete que se pueda editar. */
    function caption(key) {
        if (!root.loaded) return root.error;
        const c = Catalog.byKey(key);
        if (c && c.owner) return c.caption;
        const o = root.origin(key), e = root.effective(key);
        const parts = [];
        if (root.unsupported) return "Your configuration is " + root.mainName + " · Settings reads Lua configurations only";
        if (o) parts.push("Set in " + root.where(o.file, o.line));
        else parts.push(e && e.set ? "Set at runtime" : "Hyprland default");
        if (root.drift(key)) parts.push("changed while running · the file says " + root.format(c, root.written(key)));
        for (const ov of root.overrides(key))
            parts.push(ov.device + " has its own (" + root.format(c, ov.value) + ", "
                       + ov.file + ":" + ov.line + ")"
                       + (ov.present ? "" : " · not connected"));
        return parts.join(" · ");
    }

    /** Nombres de los dispositivos conectados ahora (ratones y teclados; hyprctl devices). */
    function presentDevices() {
        const d = root.data.inputDevices || {};
        return [].concat(d.mice || [], d.keyboards || [], d.touch || [], d.tablets || []).map(x => x.name);
    }
    /** Los bloques `hl.device` escritos, con si el aparato está conectado. */
    function deviceBlocks() {
        const devs = root.data.devices || {}, present = root.presentDevices();
        return Object.keys(devs).map(name => {
            const keys = Object.keys(devs[name]);
            const first = keys.length ? devs[name][keys[0]][0] : null;
            return { name: name, present: present.indexOf(name) >= 0, file: first ? first.file : "",
                     line: first ? first.line : 0,
                     values: keys.map(k => ({ key: k, value: devs[name][k][devs[name][k].length - 1].value })) };
        });
    }
    readonly property var keyboards: (root.data.inputDevices && root.data.inputDevices.keyboards) || []
    readonly property var mainKeyboard: root.keyboards.find(k => k.main) || null

    // ---- monitores -------------------------------------------------------------------------

    readonly property var monitors: root.data.monitorsAll || []
    readonly property var monitorRules: root.data.monitors || []
    readonly property var version: root.data.version || ({})
    // ---- dónde vive (14C) -------------------------------------------------------------------
    /** {main, dir, kind: lua|conf|missing, from: cmdline|environment|default|override, pid, home} */
    readonly property var config: root.data.config || ({})
    readonly property bool unsupported: !!root.data.unsupported
    readonly property string mainName: String(root.config.main || "").split("/").pop()
    /** Los errores que Hyprland enseña en su barra roja (los de su última evaluación). */
    readonly property var configErrors: root.data.configErrors || []
    function tilde(p) {
        const h = String(root.config.home || "");
        const s = String(p || "");
        return h.length > 0 && s.indexOf(h + "/") === 0 ? "~" + s.slice(h.length) : s;
    }
    /** Ruta completa (con ~) de un archivo de la configuración, y su línea. */
    function where(file, line) { return root.tilde(root.config.dir + "/" + file) + (line ? ":" + line : ""); }
    /** Cómo se encontró, para la UI (inglés). */
    readonly property string foundHow: ({ cmdline: "the --config Hyprland was started with",
                                          environment: "found through Hyprland's XDG_CONFIG_HOME",
                                          default: "Hyprland's default location",
                                          override: "a test folder" })[root.config.from] || ""

    /** La regla escrita que aplica a una salida: la última específica (nombre o desc:), si no la genérica. */
    function ruleFor(m) {
        let specific = null, generic = null;
        for (const r of root.monitorRules) {
            const out = String(r.fields.output === undefined ? "" : r.fields.output);
            if (out === "") generic = r;
            else if (out === m.name || (out.indexOf("desc:") === 0 && String(m.description || "").indexOf(out.slice(5)) === 0))
                specific = r;
        }
        return specific || generic;
    }
    /**
     * Lo que la salida tiene y su regla escrita no dice (una regla puesta en caliente con
     * `hl.monitor`, una prueba, otra herramienta): [] si coincide o la regla no es concreta.
     * Sólo compara lo que la regla fija con un valor concreto (no «preferred», «auto», «highrr»).
     */
    function monitorDrift(m) {
        const r = root.ruleFor(m);
        if (!r || m.disabled) return [];
        const f = r.fields, out = [];
        const mode = /^(\d+)x(\d+)(?:@([\d.]+))?/.exec(String(f.mode || ""));
        if (mode && (+mode[1] !== m.width || +mode[2] !== m.height
                     || (mode[3] !== undefined && Math.abs(parseFloat(mode[3]) - m.refreshRate) > 0.5)))
            out.push("mode");
        const pos = /^(-?\d+)x(-?\d+)$/.exec(String(f.position || ""));
        if (pos && (+pos[1] !== m.x || +pos[2] !== m.y)) out.push("position");
        if (typeof f.scale === "number" && Math.abs(f.scale - m.scale) > 0.01) out.push("scale");
        if (typeof f.transform === "number" && f.transform !== m.transform) out.push("rotation");
        return out;
    }
    /** Modos anunciados agrupados por resolución, de mayor a menor. */
    function modesOf(m) {
        const groups = {};
        for (const s of (m.availableModes || [])) {
            const x = /^(\d+)x(\d+)@([\d.]+)Hz$/.exec(s);
            if (!x) continue;
            const res = x[1] + "×" + x[2];
            const hz = Math.round(parseFloat(x[3]) * 100) / 100;
            if (!groups[res]) groups[res] = { w: +x[1], h: +x[2], rates: [] };
            if (groups[res].rates.indexOf(hz) < 0) groups[res].rates.push(hz);
        }
        return Object.keys(groups).map(k => ({ res: k, w: groups[k].w, h: groups[k].h,
                                                rates: groups[k].rates.sort((a, b) => b - a) }))
            .sort((a, b) => b.w * b.h - a.w * a.h);
    }

    function summary() {
        const opts = {};
        for (const k of Catalog.keys())
            opts[k] = { text: root.text(k), caption: root.caption(k), drift: root.drift(k),
                        written: root.written(k), effective: root.effective(k) ? root.effective(k).value : null,
                        origin: root.origin(k) };
        return {
            active: root.active, claims: Object.keys(root.claims), loaded: root.loaded, error: root.error,
            reads: root.reads, readAt: root.readAt, files: root.data.files || [], config: root.config,
            unsupported: root.unsupported, configErrors: root.configErrors,
            options: opts, devices: root.deviceBlocks(),
            monitors: root.monitors.map(m => ({ name: m.name, description: m.description, mode: m.width + "x" + m.height
                                                + "@" + m.refreshRate, scale: m.scale, x: m.x, y: m.y,
                                                transform: m.transform, vrr: m.vrr, disabled: m.disabled,
                                                modes: (m.availableModes || []).length,
                                                rule: root.ruleFor(m), drift: root.monitorDrift(m) })),
            version: root.version.version || ""
        };
    }
}
