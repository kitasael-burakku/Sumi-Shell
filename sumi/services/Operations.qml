pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * OperationCoordinator (fase 6D, 2026-09-25; DESIGN §4 y §6).
 *
 * Una operación GLOBAL —una petición de polkit, un trabajo con pregunta, una
 * autenticación Wi-Fi, y más adelante la preview de tema o la prueba de
 * monitores— tiene ID, estado y PROPIETARIO independientes del monitor. El
 * propietario es la pantalla que lleva su control; el resto de pantallas sólo
 * informan de que existe.
 *
 *   begin(kind, resource, surface, key, owner, opts)  → { id, conflict }
 *   claim(id, screen)   abrir su control de forma EXPLÍCITA (clic, atajo, IPC)
 *                       en otra pantalla traslada el propietario; hover no
 *   end(id, state, reason)
 *
 * Trasladar no repite efectos, no crea un snapshot nuevo ni reinicia el plazo
 * (`deadline` es absoluto): sólo cambia quién lleva el control. Quien la
 * presenta en pantalla es `core/Screens`, que escucha `moved` (cerrar la vista
 * vieja sin cancelar, avisar) y reubica las de una salida que desaparece.
 *
 * Por qué hacía falta, medido el 2026-09-25 con una salida headless: con la
 * superficie de polkit abierta en el HDMI, abrirla también en la headless y
 * cerrar la del HDMI CANCELABA la petición («Request dismissed», pkexec 126):
 * cada vista creía ser la dueña y la que se cerraba se la llevaba por delante.
 *
 * Registro en `$XDG_STATE_HOME/sumi-shell/operations.json` en cada cambio;
 * al arrancar, lo que estaba vivo pasa a `unknown` («the shell restarted»): el
 * proceso que la llevaba murió y su resultado no se observó (como Jobs, 6B).
 */
Singleton {
    id: root

    /** id → { id, kind, resource, surface, key, owner, state, reason, startedAt,
     *          deadline, endedAt, moves, snapshot } */
    property var ops: ({})
    property int seq: 0
    property bool loaded: false

    /** El propietario cambió. `core/Screens` cierra la vista vieja y avisa. */
    signal moved(string id, string from, string to)

    readonly property var liveStates: ["running", "needs-input"]
    function isLive(o) { return !!o && root.liveStates.indexOf(o.state) >= 0; }

    function put(o) {
        const t = Object.assign({}, root.ops);
        t[o.id] = o;
        root.ops = t;
        root.save();
    }

    function get(id) { return root.ops[id] || null; }

    /** La operación viva sobre `resource`, o null. */
    function holder(resource) {
        for (const id in root.ops)
            if (root.ops[id].resource === resource && root.isLive(root.ops[id])) return root.ops[id];
        return null;
    }

    /**
     * Empezar. Si el recurso ya tiene una operación viva, NO se crea otra: la
     * incompatible se resuelve antes (DESIGN §4). `opts.replace` la da por
     * sustituida (Wi-Fi: conectar a otra red gana, como en Net).
     */
    function begin(kind, resource, surface, key, owner, opts) {
        const o = opts || {};
        const h = root.holder(resource);
        if (h) {
            if (!o.replace) return { id: "", conflict: h.id };
            root.end(h.id, "cancelled", "Replaced by a newer request");
        }
        const id = kind + "-" + (++root.seq) + "-" + Date.now().toString(36);
        root.put({ id: id, kind: kind, resource: resource, surface: surface, key: key || "",
                   owner: owner || "", state: o.state || "running", reason: "",
                   startedAt: Date.now(), deadline: o.deadline || 0, endedAt: 0, moves: 0,
                   snapshot: o.snapshot || null });
        return { id: id, conflict: "" };
    }

    function update(id, patch) {
        const o = root.get(id);
        if (!o) return false;
        root.put(Object.assign({}, o, patch));
        return true;
    }

    /**
     * Abrir su control de forma explícita en `screen`. Si otra pantalla lo
     * llevaba, el propietario pasa aquí: la misma operación, el mismo plazo.
     * Devuelve true si hubo traslado.
     */
    function claim(id, screen) {
        const o = root.get(id);
        if (!o || !root.isLive(o) || !screen || o.owner === screen) return false;
        const from = o.owner;
        root.put(Object.assign({}, o, { owner: screen, moves: o.moves + 1 }));
        console.info("operations:", id, "moved", from || "(none)", "→", screen);
        root.moved(id, from, screen);
        return true;
    }

    function end(id, state, reason) {
        const o = root.get(id);
        if (!o || !root.isLive(o)) return false;
        root.put(Object.assign({}, o, { state: state, reason: reason || "", endedAt: Date.now() }));
        return true;
    }

    function ownerOf(id) { const o = root.get(id); return o ? o.owner : ""; }

    /** Esta pantalla lleva el control (o no hay operación que llevar). */
    function owns(id, screen) {
        const o = root.get(id);
        return !o || !root.isLive(o) || o.owner === screen;
    }

    /** Las vivas cuyo propietario ya no está entre `names` (monitor retirado). */
    function orphans(names) {
        const out = [];
        for (const id in root.ops) {
            const o = root.ops[id];
            if (root.isLive(o) && o.owner.length > 0 && names.indexOf(o.owner) < 0) out.push(o);
        }
        return out;
    }

    function live() {
        const out = [];
        for (const id in root.ops) if (root.isLive(root.ops[id])) out.push(root.ops[id]);
        return out;
    }

    // ---- registro -----------------------------------------------------------

    readonly property string path: Settings.stateDir + "/operations.json"

    /** Sólo las últimas: las terminadas no hacen falta más que para `ipc operations`. */
    function trimmed() {
        const all = Object.keys(root.ops).map(k => root.ops[k]);
        all.sort((a, b) => b.startedAt - a.startedAt);
        const keep = {};
        for (let i = 0; i < all.length; i++)
            if (i < 20 || root.isLive(all[i])) keep[all[i].id] = all[i];
        return keep;
    }

    function save() {
        if (!root.loaded) return;
        file.setText(JSON.stringify({ seq: root.seq, ops: root.trimmed() }, null, 1));
    }

    FileView {
        id: file
        path: root.path
        blockLoading: true
        blockWrites: true
        printErrors: false
        onLoaded: root.restore(file.text())
        onLoadFailed: (error) => { root.loaded = true; }
    }

    /**
     * Lo que estaba vivo cuando el shell murió ya no tiene quien lo lleve: la
     * petición de polkit murió con su agente, el trabajo con su proceso. Pasa a
     * `unknown`; nunca se reanuda ni se da por terminado bien.
     */
    function restore(text) {
        let data = null;
        try { data = JSON.parse(text); } catch (e) { data = null; }
        const t = {};
        if (data && data.ops) {
            for (const id in data.ops) {
                const o = data.ops[id];
                t[id] = root.isLive(o)
                    ? Object.assign({}, o, { state: "unknown", reason: "The shell restarted", endedAt: Date.now() })
                    : o;
            }
        }
        root.seq = data && data.seq ? data.seq : 0;
        root.ops = t;
        root.loaded = true;
        root.save();
    }

    function snapshot() {
        const now = Date.now();
        const list = Object.keys(root.ops).map(k => root.ops[k]);
        list.sort((a, b) => b.startedAt - a.startedAt);
        return {
            loaded: root.loaded,
            live: list.filter(o => root.isLive(o)).map(o => o.id),
            ops: list.slice(0, 10).map(o => ({
                id: o.id, kind: o.kind, resource: o.resource, surface: o.surface, key: o.key,
                owner: o.owner, state: o.state, reason: o.reason, moves: o.moves,
                ageMs: now - o.startedAt,
                deadlineInMs: o.deadline > 0 ? o.deadline - now : null
            }))
        };
    }
}
