import QtQuick
import Quickshell.Io

/**
 * Lo pedido frente a lo efectivo (fase 6C, 2026-09-25).
 *
 * Una tabla de operaciones por clave: «el perfil», «el volumen del nodo 57»,
 * «la apertura del navegador». Cada petición lleva una REVISIÓN (un contador
 * global que sólo crece) y cada resultado dice a qué revisión responde. Si ya
 * no es la última de su clave, se descarta y se cuenta en `stale`: gana
 * siempre lo último que se pidió.
 *
 * Por qué hace falta, medido con `qs -p` sobre el daemon real y Pipewire el
 * 2026-09-25: Quickshell escribe de forma OPTIMISTA (leer justo después de
 * escribir ya da lo pedido) y los ecos llegan después, en orden de petición.
 * Dos perfiles seguidos, performance → power-saver: el binding pasa por
 * power-saver, performance (+23 ms, el eco viejo) y power-saver (+33 ms). El
 * volumen igual: 0.90 → 0.95 → eco 0.90 → eco 0.95. Y con una sola petición
 * del perfil, o un mute, NO llega eco ninguno. O sea: el binding no sirve para
 * dar nada por hecho. El éxito lo decide quien sabe leer el sistema por otro
 * camino (busctl, wpctl, el metadato de Pipewire, un proceso que arrancó).
 *
 * Estados de una clave:
 *   idle     nunca se pidió nada (o se olvidó)
 *   pending  pedido; `requested` es lo que se pidió y aún no se ha visto
 *   ok       éxito OBSERVADO: el sistema dice que hay lo pedido
 *   error    el sistema dijo que no, o dejó otra cosa, o el objeto desapareció
 *   unknown  el sistema aceptó la orden pero su resultado no se ve desde aquí
 *            (apagar, reiniciar), o la comprobación misma no pudo hacerse
 *
 * Mismo espíritu que el `verdict()` de `services/Jobs` (6B): el estado sale de
 * lo observado, no de que la llamada volviera. Aquí no hay procesos largos.
 *
 *     Ops { id: ops; name: "profile" }
 *     const r = ops.request("", "performance");      // → revisión
 *     ops.resolve("", r, "ok", "", "performance");     // false si ya es vieja
 *     ops.shown("", PowerProfile.current)              // lo que se PINTA
 */
QtObject {
    id: root

    /** Para el registro y para `ipc ops`. */
    property string name: ""

    /** clave → { rev, requested, effective, state, reason, at } */
    property var table: ({})
    /** Resultados que llegaron para una revisión que ya no era la última. */
    property int stale: 0
    /** La última revisión repartida, entre todas las claves. */
    property int seq: 0

    /** Una petición se resolvió (sólo la vigente; las viejas no avisan). */
    signal settled(string key, int rev, string state, string reason)

    readonly property var idleRecord: ({ rev: 0, requested: null, effective: null,
                                        state: "idle", reason: "", at: 0 })

    function put(key, rec) {
        // Objeto NUEVO: reasignar el mismo `var` no notifica (lección de Net.claimScan).
        const t = Object.assign({}, root.table);
        t[key] = rec;
        root.table = t;
    }

    function get(key) { return root.table[key] || root.idleRecord; }
    function stateOf(key) { return root.get(key).state; }
    function pending(key) { return root.get(key).state === "pending"; }
    function latest(key) { return root.get(key).rev; }
    function isLatest(key, rev) { return rev > 0 && root.get(key).rev === rev; }

    /** Alguna clave en vuelo: para los `busy` de los servicios. */
    readonly property bool anyPending: {
        for (const k in root.table)
            if (root.table[k].state === "pending") return true;
        return false;
    }

    /** Pide `value` para `key`. Devuelve la revisión, que el resultado tendrá que citar. */
    function request(key, value) {
        const old = root.get(key);
        const r = ++root.seq;
        root.put(key, { rev: r, requested: value, effective: old.effective,
                        state: "pending", reason: "", at: Date.now() });
        return r;
    }

    /**
     * El resultado de la revisión `rev`. Si ya no es la última de su clave, se
     * descarta y devuelve false. `effective` es lo que el sistema dice que hay
     * (undefined = no se sabe, se conserva lo anterior).
     */
    function resolve(key, rev, state, reason, effective) {
        const o = root.get(key);
        if (o.rev !== rev) {
            root.stale++;
            console.log("ops[" + root.name + "]: stale result for " + key + " rev " + rev
                        + " (latest " + o.rev + "), dropped");
            return false;
        }
        // Ya resuelta. `unknown` sí admite una observación tardía: una conexión que
        // llega después del plazo pasa a `ok` (lo mismo que hacían Net y Bt con su fase).
        if (o.state !== "pending" && o.state !== "unknown") return false;
        if (o.state === "unknown" && state === "unknown") return false;
        root.unwatch(key);
        root.put(key, { rev: rev, requested: o.requested,
                        effective: effective === undefined ? o.effective : effective,
                        state: state, reason: reason || "", at: Date.now() });
        root.settled(key, rev, state, reason || "");
        return true;
    }

    /**
     * Lo que se pinta: lo pedido mientras está en vuelo (para que un eco viejo
     * no haga saltar el control hacia atrás) y, resuelto, lo que el sistema dé.
     */
    function shown(key, actual) {
        const o = root.get(key);
        return o.state === "pending" ? o.requested : actual;
    }

    // ---- esperar a que el sistema lo diga (6C-2) -----------------------------

    /**
     * `expect`: resolver `key`/`rev` mirando el estado del sistema, sin proceso.
     * `check()` devuelve { met, fail, effective, reason }:
     *   met   lo pedido se ve; tiene que SOSTENERSE `hold` ms para dar `ok` (el
     *         destello del sink nulo, y el del mando de PS5 en Bt);
     *   fail  motivo definitivo de error (el objeto desapareció, la radio se apagó).
     * A los `timeout` ms sin cumplirse: `timeoutState` (error, o unknown si aún
     * puede llegar) con `reason` del último `check()` o `timeoutReason`.
     * Se mira cada 100 ms mientras haya algo esperando; sin nada, el reloj para.
     */
    property var watches: ({})
    readonly property bool watching: Object.keys(root.watches).length > 0

    function expect(key, rev, opts) {
        const w = Object.assign({}, root.watches);
        w[key] = { rev: rev, check: opts.check, hold: opts.hold === undefined ? 600 : opts.hold,
                   until: Date.now() + (opts.timeout || 10000),
                   timeoutState: opts.timeoutState || "error",
                   timeoutReason: opts.timeoutReason || "", heldSince: 0,
                   argv: null, judge: null, due: 0 };
        root.watches = w;
        root.tick();
    }

    /**
     * `verifyLater`: a los `delay` ms, si `rev` sigue siendo la última, lanzar
     * `argv` y que `judge(texto, código)` diga [estado, motivo, efectivo]. Para
     * lo que Quickshell escribe de forma optimista y sin eco (medido el
     * 2026-09-25: `trusted`, `autoconnect`, `enabled`; y antes el perfil y el
     * mute). Una lectura que vuelve para una revisión vieja se descarta.
     */
    function verifyLater(key, rev, delay, argv, judge) {
        const w = Object.assign({}, root.watches);
        w[key] = { rev: rev, check: null, argv: argv, judge: judge, due: Date.now() + delay };
        root.watches = w;
    }

    function unwatch(key) {
        if (!(key in root.watches)) return;
        const w = Object.assign({}, root.watches);
        delete w[key];
        root.watches = w;
    }

    function tick() {
        const now = Date.now();
        for (const key of Object.keys(root.watches)) {
            const w = root.watches[key];
            const o = root.get(key);
            // Sustituida por otra petición, o ya resuelta: esta espera no vale.
            if (!w || o.rev !== w.rev || (o.state !== "pending" && o.state !== "unknown")) {
                root.unwatch(key);
                continue;
            }
            if (w.argv !== null) {
                if (o.state !== "pending") { root.unwatch(key); continue; }
                if (now < w.due) continue;
                root.unwatch(key);
                root.spawnVerify(key, w.rev, w.argv, w.judge);
                continue;
            }
            let c = {};
            try { c = w.check() || {}; } catch (e) { c = { fail: "Could not read the state" }; }
            if (c.fail) { root.resolve(key, w.rev, "error", c.fail, c.effective); continue; }
            if (c.met) {
                if (w.heldSince === 0) w.heldSince = now;
                if (now - w.heldSince >= w.hold) root.resolve(key, w.rev, "ok", "", c.effective);
                continue;
            }
            w.heldSince = 0;
            if (now < w.until) continue;
            if (o.state === "unknown") { root.unwatch(key); continue; }   // ya se esperó de más
            root.resolve(key, w.rev, w.timeoutState, c.reason || w.timeoutReason, c.effective);
            if (w.timeoutState === "unknown") {
                // Un minuto más mirando: una observación tardía aún puede resolverla.
                w.until = now + 60000;
                const again = Object.assign({}, root.watches);
                again[key] = w;
                root.watches = again;
            }
        }
    }

    readonly property Timer ticker: Timer {
        interval: 100
        repeat: true
        running: root.watching
        onTriggered: root.tick()
    }

    readonly property Component verifier: Component {
        Process {
            id: vp
            property string key: ""
            property int rev: 0
            property var judge: null
            property bool started: false
            stdout: StdioCollector { id: vout }
            onStarted: vp.started = true
            onExited: (code) => {
                let v = ["error", "Could not read the state"];
                try { v = vp.judge(vout.text, code); } catch (e) {}
                root.resolve(vp.key, vp.rev, v[0], v[1], v[2]);
                vp.destroy();
            }
            onRunningChanged: {
                if (vp.running || vp.started) return;
                root.resolve(vp.key, vp.rev, "error", "Could not read the state");
                vp.destroy();
            }
        }
    }

    function spawnVerify(key, rev, argv, judge) {
        const p = root.verifier.createObject(root, { key: key, rev: rev, judge: judge, command: argv });
        p.running = true;
    }

    function forget(key) {
        if (!(key in root.table)) return;
        const t = Object.assign({}, root.table);
        delete t[key];
        root.table = t;
    }

    function snapshot() {
        const now = Date.now();
        const out = { name: root.name, stale: root.stale, seq: root.seq, ops: {} };
        for (const k in root.table) {
            const o = root.table[k];
            out.ops[k] = { rev: o.rev, requested: o.requested, effective: o.effective,
                           state: o.state, reason: o.reason, ageMs: now - o.at };
        }
        return out;
    }
}
