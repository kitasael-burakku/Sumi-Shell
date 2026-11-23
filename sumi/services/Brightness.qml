pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Brillo por monitor (rediseño, fase 7E-1; spec del Centro de control, «Sonido y
 * brillo»): SÓLO el monitor donde está el panel, y la fila no existe si ese
 * monitor no tiene control.
 *
 * Esta máquina es de sobremesa (sin /sys/class/backlight): el monitor va por HDMI
 * y el brillo es DDC/CI con `ddcutil`. Medido el 2026-09-25 en el GS25F2:
 *   · `ddcutil detect --brief`   77 ms   Display 1 · /dev/i2c-3 · card1-HDMI-A-1
 *   · `getvcp 10 --brief --bus 3`  ~100 ms   «VCP 10 C 100 100» (actual, máximo)
 *   · `setvcp 10 N --bus 3`        130-200 ms; sin root (ACL del grupo i2c)
 *   · una salida headless no tiene DDC: no aparece.
 *
 * Todo es por el bus, nunca por número de display (cambia con el orden de
 * detección). Una orden a la vez (el bus I²C no admite dos) en una cola.
 *
 * Pedido frente a efectivo (6C, `services/Ops`, clave `bri:<pantalla>`): el
 * deslizador pinta lo pedido; la escritura sale 250 ms después del último
 * movimiento (gana el último) y se comprueba LEYENDO con getvcp. Si no coincide,
 * error con lo que el monitor dice. DDC es lento y el monitor puede no aplicar:
 * nunca se da por hecho.
 *
 * Reclamaciones (6A): sin nadie mirando no corre nada. La primera reclamación
 * detecta (una vez; otra si cambian las pantallas) y lee el valor.
 *
 * Portabilidad F5g (H-18): un portátil no tiene DDC en su panel, tiene backlight. `scripts/backlight.py` lo lee de
 * /sys/class/backlight (la salida, por el conector DRM del dispositivo) y lo escribe con `SetBrightness` de logind
 * (sin root ni brightnessctl). Se detecta antes que DDC y gana en su salida; las demás siguen por ddcutil con los
 * mismos argv de siempre. Cada pantalla lleva su `kind` (`ddc` | `backlight`); lo de fuera (has/shown/set) no cambia.
 */
Singleton {
    id: root

    property var claims: ({})
    readonly property bool wanted: Object.keys(root.claims).length > 0
    function claim(who, on) {
        const next = Object.assign({}, root.claims);
        if (on) next[who] = true; else delete next[who];
        root.claims = next;
    }
    onWantedChanged: if (root.wanted) {
        if (!root.detected) root.detect();
        else root.readAll();
    }

    /** { "<conector>": { kind: ddc|backlight, bus (ddc), dev (backlight), value, max, read: bool } } */
    property var displays: ({})
    property bool detected: false
    property string detectError: ""
    /** F5g: lo que dijo backlight.py list ({devices, outputs}) y su error, si lo hubo. */
    property var backlight: ({})
    property string backlightError: ""
    readonly property string blScript: Quickshell.shellPath("scripts/backlight.py")
    function parse(text) { try { return JSON.parse(text); } catch (e) { return null; } }

    readonly property Ops ops: Ops { name: "brightness" }

    function has(screen) { return root.displays[screen] !== undefined; }
    function valueOf(screen) {
        const d = root.displays[screen];
        return d && d.read ? d.value / Math.max(1, d.max) : -1;
    }
    /** Lo que se pinta (0-1): lo pedido en vuelo; si no, lo leído. -1 = aún no se sabe. */
    function shown(screen) {
        void root.ops.table;
        const v = root.valueOf(screen);
        return root.ops.shown("bri:" + screen, v);
    }
    function failed(screen) { void root.ops.table; return root.ops.stateOf("bri:" + screen) === "error"; }
    function reason(screen) { void root.ops.table; return root.ops.get("bri:" + screen).reason; }

    /** Las pantallas cambian: se vuelve a detectar (sólo si alguien mira). */
    Connections {
        target: Quickshell
        function onScreensChanged() {
            root.detected = false;
            if (root.wanted) root.detect();
        }
    }

    // ---- la cola de órdenes ------------------------------------------------------

    property var queue: []
    property var job: null
    function enqueue(j) {
        const q = root.queue.slice();
        q.push(j);
        root.queue = q;
        root.pump();
    }
    function pump() {
        if (root.job || root.queue.length === 0) return;
        const q = root.queue.slice();
        root.job = q.shift();
        root.queue = q;
        proc.command = root.job.argv;
        proc.running = true;
    }
    Process {
        id: proc
        stdout: StdioCollector { id: out }
        onExited: (code) => {
            const j = root.job;
            root.job = null;
            if (j) j.done(String(out.text), code);
            root.pump();
        }
        onRunningChanged: if (!running && root.job && !root.jobStarted) {
            // ddcutil no instalado: `running` cae sin `exited` (memoria del proyecto).
            const j = root.job;
            root.job = null;
            j.done("", -1);
            root.pump();
        }
        onStarted: root.jobStarted = true
    }
    property bool jobStarted: false
    onJobChanged: root.jobStarted = false

    // ---- detectar y leer -----------------------------------------------------------

    function detect() {
        // F5g: primero el backlight (sysfs; sin él, como antes)
        const bl = {};
        root.enqueue({ argv: ["python3", root.blScript, "list"], done: function (text, code) {
            const r = root.parse(text);
            root.backlight = r || {};
            root.backlightError = r ? "" : code === -1 ? "python3 is not available" : "backlight.py failed";
            const outs = r && r.outputs ? r.outputs : {};
            for (const o in outs) {
                const dev = (r.devices || []).filter(x => x.name === outs[o])[0];
                if (dev) bl[o] = { kind: "backlight", dev: dev.name, value: dev.brightness || 0, max: dev.max,
                                   read: dev.brightness !== null && dev.brightness !== undefined };
            }
        } });
        root.enqueue({ argv: ["ddcutil", "detect", "--brief"], done: function (text, code) {
            // F5g: las pantallas ANTES de `detected`: onDetectedChanged vacía las peticiones de fuera y una que llegara
            // sin pantallas se perdía (8G-1: el primer brightnessSet en frío no hacía nada)
            if (code !== 0) {
                root.detectError = code === -1 ? "ddcutil is not installed" : "ddcutil detect failed";
                root.displays = bl;
                root.detected = true;
                root.readAll();
                return;
            }
            root.detectError = "";
            const found = Object.assign({}, bl);
            let bus = -1;
            const lines = text.split("\n");
            for (let i = 0; i < lines.length; i++) {
                const l = lines[i].trim();
                if (/^(Display|Invalid display|Phantom display)/.test(l)) bus = /^Display/.test(l) ? -2 : -1;
                const b = l.match(/^I2C bus:\s*\/dev\/i2c-(\d+)/);
                if (b && bus === -2) bus = Number(b[1]);
                const c = l.match(/^DRM[_ ]connector:\s*card\d+-(.+)$/);
                if (c && bus >= 0 && !bl[c[1]]) found[c[1]] = { kind: "ddc", bus: bus, value: 0, max: 100, read: false };
            }
            root.displays = found;
            root.detected = true;
            root.readAll();
        } });
    }

    function readAll() {
        for (const s in root.displays) root.read(s, null);
    }

    function read(screen, then) {
        const d = root.displays[screen];
        if (!d) return;
        if (d.kind === "backlight") {
            root.enqueue({ argv: ["python3", root.blScript, "get", d.dev], done: function (text, code) {
                const r = root.parse(text);
                const ok = r && r.ok && r.max > 0;
                if (ok) {
                    const next = Object.assign({}, root.displays);
                    if (next[screen]) next[screen] = Object.assign({}, next[screen], { value: r.brightness, max: r.max, read: true });
                    root.displays = next;
                }
                if (then) then(ok ? r.brightness / r.max : -1);
            } });
            return;
        }
        root.enqueue({ argv: ["ddcutil", "getvcp", "10", "--brief", "--bus", String(d.bus)], done: function (text, code) {
            const m = text.match(/VCP 10 C (\d+) (\d+)/);
            if (code === 0 && m) {
                const next = Object.assign({}, root.displays);
                next[screen] = Object.assign({}, next[screen], { value: Number(m[1]), max: Number(m[2]), read: true });
                root.displays = next;
            }
            if (then) then(code === 0 && m ? Number(m[1]) / Math.max(1, Number(m[2])) : -1);
        } });
    }

    // ---- escribir -------------------------------------------------------------------

    /** Pide `v` (0-1) para `screen`. Devuelve la revisión (0 si esa pantalla no tiene control). */
    function set(screen, v) {
        if (!root.has(screen)) return 0;
        const x = Math.max(0, Math.min(1, v));
        const r = root.ops.request("bri:" + screen, x);
        root.pendingSet = Object.assign({}, root.pendingSet, { [screen]: r });
        settle.restart();
        return r;
    }
    property var pendingSet: ({})
    Timer {
        id: settle
        interval: 250
        onTriggered: {
            const p = root.pendingSet;
            root.pendingSet = {};
            for (const s in p) root.write(s, p[s]);
        }
    }

    function write(screen, rev) {
        const d = root.displays[screen];
        if (!d || !root.ops.isLatest("bri:" + screen, rev)) return;
        const want = root.ops.get("bri:" + screen).requested;
        if (d.kind === "backlight") { root.writeBacklight(screen, d, want, rev); return; }
        const raw = Math.round(want * d.max);
        root.enqueue({ argv: ["ddcutil", "setvcp", "10", String(raw), "--bus", String(d.bus), "--noverify"],
                       done: function (text, code) {
            if (!root.ops.isLatest("bri:" + screen, rev)) return;   // llegó otra petición: ella comprueba
            if (code !== 0) {
                root.ops.resolve("bri:" + screen, rev, "error", code === -1 ? "ddcutil is not installed" : "The monitor did not accept it");
                return;
            }
            // Efectivo = lo que el monitor dice al LEERLO.
            root.read(screen, function (got) {
                if (!root.ops.isLatest("bri:" + screen, rev)) return;
                if (got < 0) root.ops.resolve("bri:" + screen, rev, "unknown", "Could not read it back");
                else if (Math.round(got * d.max) === raw) root.ops.resolve("bri:" + screen, rev, "ok", "", got);
                else root.ops.resolve("bri:" + screen, rev, "error", "The monitor kept " + Math.round(got * 100) + "%", got);
            });
        } });
    }

    /**
     * F5g: por logind (backlight.py set). Nunca a 0: en muchos paneles es la pantalla negra; el mínimo es el 1 % (o
     * un paso del dispositivo). backlight.py relee sysfs: efectivo = lo leído.
     */
    function writeBacklight(screen, d, want, rev) {
        const raw = Math.max(Math.ceil(d.max / 100), Math.round(want * d.max));
        root.enqueue({ argv: ["python3", root.blScript, "set", d.dev, String(raw)], done: function (text, code) {
            if (!root.ops.isLatest("bri:" + screen, rev)) return;
            const r = root.parse(text);
            if (r && r.brightness !== undefined && r.brightness !== null && r.max > 0) {
                const next = Object.assign({}, root.displays);
                if (next[screen]) next[screen] = Object.assign({}, next[screen], { value: r.brightness, max: r.max, read: true });
                root.displays = next;
            }
            if (r && r.ok) root.ops.resolve("bri:" + screen, rev, "ok", "", r.brightness / r.max);
            else root.ops.resolve("bri:" + screen, rev, "error", r && r.error ? r.error : code === -1 ? "python3 is not available"
                                                                                                    : "The brightness did not change",
                                  r && r.max > 0 && r.brightness !== undefined && r.brightness !== null ? r.brightness / r.max : undefined);
        } });
    }

    // ---- cambios de FUERA del shell (8G-1): scripts y atajos, con OSD ----------------

    /**
     * El Centro de control ya enseña el brillo y no pasa por aquí. Un atajo o un script sí
     * (IPC `brightnessSet` / `brightnessStep`): se reclama el servicio el tiempo justo para
     * detectar y leer por DDC, se aplica y se avisa (`externalChange`) para que el OSD de ESA
     * pantalla lo diga. `relative`: paso sobre lo que se pinta (o lo leído).
     */
    signal externalChange(string screen)
    property var pendingExternal: []
    function setExternal(screen, v, relative) {
        root.claim("external", true);
        externalHold.restart();
        root.pendingExternal = root.pendingExternal.concat([{ screen: screen, v: v, rel: relative }]);
        root.flushExternal();
        return true;
    }
    function flushExternal() {
        if (root.pendingExternal.length === 0 || !root.detected) return;
        const keep = [];
        for (let i = 0; i < root.pendingExternal.length; i++) {
            const p = root.pendingExternal[i];
            if (!root.has(p.screen)) continue;                   // sin DDC en esa pantalla: nada
            const d = root.displays[p.screen];
            if (p.rel && !d.read) { keep.push(p); continue; }    // un paso necesita lo leído
            const base = p.rel ? Math.max(0, root.shown(p.screen)) : 0;
            if (root.set(p.screen, base + p.v) > 0) root.externalChange(p.screen);
        }
        root.pendingExternal = keep;
    }
    onDetectedChanged: root.flushExternal()
    onDisplaysChanged: root.flushExternal()
    Timer { id: externalHold; interval: 5000; onTriggered: root.claim("external", false) }

    function summary() {
        return { wanted: root.wanted, claims: Object.keys(root.claims), detected: root.detected,
                 detectError: root.detectError, backlightError: root.backlightError,
                 backlight: root.backlight, displays: root.displays, queue: root.queue.length,
                 busy: root.job !== null, ops: root.ops.snapshot() };
    }
}
