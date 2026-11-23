pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import "../lib/xdg.js" as Xdg

/**
 * Rutas de audio por aplicación (fase 13A lectura, 13B mover; rediseno/docs/
 * futureAudio-Mixersurface.md). Mover un flujo (`moveTo`, abajo) escribe el mismo metadato
 * que `pactl move-sink-input` / `move-source-output` y WirePlumber lo recuerda por aplicación;
 * nunca toca el dispositivo predeterminado, ni el volumen ni el silencio. Vale igual para los
 * que reproducen (a una salida) y para los que graban (desde una entrada, 13C).
 *
 * Por cada flujo, tres rutas que pueden no coincidir:
 *
 *   efectiva    lo que dicen los ENLACES de Pipewire. Si el flujo entra en un filtro
 *               «smart» de WirePlumber (el EQ de la 13D), se atraviesa hasta el
 *               dispositivo real: la ruta de una app ecualizada sigue siendo «GS25F2».
 *   pedida      el destino que WirePlumber tiene que respetar AHORA: `target.object`
 *               (serial) o `target.node` (id) en los metadatos `default`, que ganan a
 *               los de las propiedades del flujo salvo `node.dont-move`
 *               (linking/find-defined-target.lua). `-1` = el predeterminado.
 *   recordada   lo que WirePlumber restaurará al próximo flujo de esa APLICACIÓN
 *               (`node.stream.restore-target`): el `node.name` del destino, guardado en
 *               ~/.local/state/wireplumber/stream-properties con la clave de `formKey`.
 *               Es por aplicación, no por flujo: dos flujos de una app comparten una.
 *
 * Quickshell no expone los metadatos ni el estado de WirePlumber (0.3.1: sólo el
 * sink/source predeterminado), así que se leen fuera: `pw-metadata -m` (un proceso
 * que imprime cada cambio, medido: `update: id:87 key:'target.object' value:'201'
 * type:'Spa:Id'` y `remove: id:87 key:'target.object'`) y el archivo de estado con un
 * FileView. Los dos, sólo con alguien mirando: van con las reclamaciones del Mixer.
 *
 * Identificadores estables: el dispositivo por `node.name` (el que guarda WirePlumber);
 * la aplicación por su clave de WirePlumber; y, dentro de una app, cada flujo por
 * `media.name`, pid y serial (el id de Pipewire cambia con cada flujo).
 */
Singleton {
    id: root

    /** Vivo mientras el Mixer tenga reclamaciones (surface, Settings · Audio o IPC). */
    readonly property bool active: Mixer.active

    readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
    readonly property var groups: Pipewire.linkGroups ? Pipewire.linkGroups.values : []

    function prop(n, k) {
        return (n && n.properties && n.properties[k] !== undefined) ? String(n.properties[k]) : "";
    }

    // ---- nodos internos de los filtros ---------------------------------------------

    /**
     * Los `node.link-group` de los filtros smart. Un filter-chain son dos nodos con el
     * mismo link-group: la entrada (Audio/Sink, lleva `filter.smart`) y la salida (un
     * Stream/Output que va al dispositivo, SIN esa propiedad). Se ocultan los dos: ni son
     * una salida que elegir ni una aplicación que suena. Un filtro NO smart (un sink
     * virtual que el usuario creó a propósito) sigue siendo una salida normal.
     */
    readonly property var smartGroups: {
        const out = {};
        const l = root.nodes;
        for (let i = 0; i < l.length; i++) {
            const g = root.prop(l[i], "node.link-group");
            if (g.length > 0 && root.prop(l[i], "filter.smart") === "true") out[g] = true;
        }
        return out;
    }

    function isInternal(n) {
        const g = root.prop(n, "node.link-group");
        return g.length > 0 && root.smartGroups[g] === true;
    }

    /** Nombre del filtro para enseñarlo en la ruta («via Equalizer»). */
    function filterName(n) {
        if (root.prop(n, "kitasan.equalizer").length > 0) return "Equalizer";   // el nuestro (13D)
        return root.prop(n, "filter.smart.name") || String(n.description || n.name || "");
    }

    // ---- ruta efectiva ---------------------------------------------------------------

    /**
     * Destinos de `n` siguiendo los enlaces: hacia abajo (reproducción: el flujo es la
     * fuente del enlace) o hacia arriba (captura). Un nodo interno se atraviesa por el
     * otro nodo de su link-group. Profundidad acotada: dos filtros encadenados caben.
     */
    function follow(n, down, depth, via) {
        const out = [];
        if (!n || depth > 4) return out;
        const gs = root.groups;
        for (let i = 0; i < gs.length; i++) {
            const g = gs[i];
            if (!g) continue;
            const other = down ? (g.source === n ? g.target : null) : (g.target === n ? g.source : null);
            if (!other) continue;
            if (root.isInternal(other)) {
                const lg = root.prop(other, "node.link-group");
                const v = via.concat([root.filterName(other)]);
                const l = root.nodes;
                for (let j = 0; j < l.length; j++) {
                    const m = l[j];
                    if (m && m !== other && root.prop(m, "node.link-group") === lg)
                        for (const r of root.follow(m, down, depth + 1, v)) out.push(r);
                }
            } else {
                out.push({ node: other, via: via });
            }
        }
        return out;
    }

    /**
     * Ruta efectiva de un flujo: [{ node, via }], sin repetir dispositivo. Sin el estado del
     * enlace: `PwLinkGroup.state` sale «unlinked» con el enlace activo (medido en la 13A;
     * haría falta rastrearlo). Que exista el enlace es lo que cuenta.
     */
    function effectiveOf(n) {
        if (!n || !n.isStream) return [];
        void root.groups;
        const seen = [];
        const out = [];
        for (const r of root.follow(n, n.isSink, 0, [])) {
            if (seen.indexOf(r.node) >= 0) continue;
            seen.push(r.node);
            out.push(r);
        }
        return out;
    }

    // ---- ruta pedida: metadatos `default` ------------------------------------------

    /** { "<id>": { "target.object": "201", "target.node": "67" } } del proceso vivo. */
    property var meta: ({})
    /** El proceso leyó su primera línea: sin eso, «sin destino» sería mentira. */
    property bool metaLive: false
    property int metaRestarts: 0

    Process {
        id: metaProc
        command: ["pw-metadata", "-n", "default", "-m"]
        running: root.active && root.metaRestarts < 5
        stdout: SplitParser { onRead: (l) => root.metaLine(l) }
        onStarted: { root.meta = ({}); metaStable.restart(); }
        onExited: {
            metaStable.stop();
            root.metaLive = false;
            root.meta = ({});
            // Mismo freno que Clip y Session (QS-FUNC-002): un proceso que muere solo se
            // relanza pocas veces; cerrar el Mixer (running → false) no cuenta.
            if (root.active) root.metaRestarts++;
        }
    }
    Timer { id: metaStable; interval: 5000; onTriggered: root.metaRestarts = 0 }
    // Sin nadie mirando, lo leído caduca: «no sé» no es «no hay destino».
    onActiveChanged: {
        if (root.active) { root.metaRestarts = 0; return; }
        root.remembered = ({});
        root.stateRead = false;
    }

    function metaLine(line) {
        if (line.startsWith("Found ")) { root.metaLive = true; return; }
        const m = /^(update|remove): id:(\d+)(?: key:'([^']*)')?(?: value:'(.*)' type:'[^']*')?/.exec(line);
        if (!m) return;
        root.metaLive = true;
        const id = m[2], key = m[3] || "";
        if (id === "0") return;   // los globales (predeterminados) los lleva Quickshell
        if (key.length > 0 && key !== "target.object" && key !== "target.node") return;
        const t = Object.assign({}, root.meta);
        const e = Object.assign({}, t[id] || {});
        if (m[1] === "update") root.learn();   // el destino existe ahora: apuntar su nombre
        if (m[1] === "remove") {
            if (key.length > 0) delete e[key];
            else { delete t[id]; root.meta = t; return; }
        } else {
            e[key] = m[4] !== undefined ? m[4] : "";
        }
        if (Object.keys(e).length > 0) t[id] = e; else delete t[id];
        root.meta = t;
    }

    /**
     * Nombres vistos por serial y por id. Cuando el dispositivo pedido desaparece, el
     * metadato sigue diciendo su serial y el nodo ya no existe: sin esto, la fila no
     * podría decir QUÉ salida falta. Las propiedades de un nodo llegan DESPUÉS del nodo
     * (medido en la 13A: la primera versión, al cambiar `nodes`, no tenía el serial del
     * sink que luego faltó), así que se rellena con un retardo y al llegar cada metadato.
     * Acotada: se vacía al pasar de 500 entradas.
     */
    property var known: ({ serial: {}, id: {}, label: {} })
    onNodesChanged: knownDelay.restart()
    Timer { id: knownDelay; interval: 300; onTriggered: root.learn() }

    function learn() {
        const k = Object.keys(root.known.serial).length > 500 ? { serial: {}, id: {}, label: {} }
            : { serial: Object.assign({}, root.known.serial), id: Object.assign({}, root.known.id),
                label: Object.assign({}, root.known.label) };
        let changed = false;
        for (const n of root.nodes) {
            if (!n || n.isStream) continue;
            const s = root.prop(n, "object.serial"), name = String(n.name || "");
            if (name.length === 0) continue;
            if (s.length > 0 && k.serial[s] !== name) { k.serial[s] = name; changed = true; }
            if (k.id[String(n.id)] !== name) { k.id[String(n.id)] = name; changed = true; }
            // El nombre corto («KT13b», «GS25F2»), para decir cuál falta cuando ya no está.
            const lbl = Mixer.shortLabel(n);
            if (lbl.length > 0 && k.label[name] !== lbl) { k.label[name] = lbl; changed = true; }
        }
        if (changed) root.known = k;
    }

    function nodeBySerial(s) {
        const l = root.nodes;
        for (let i = 0; i < l.length; i++)
            if (l[i] && root.prop(l[i], "object.serial") === String(s)) return l[i];
        return null;
    }
    function nodeById(id) {
        const l = root.nodes;
        for (let i = 0; i < l.length; i++)
            if (l[i] && String(l[i].id) === String(id)) return l[i];
        return null;
    }
    function nodeByName(name) {
        const l = root.nodes;
        for (let i = 0; i < l.length; i++)
            if (l[i] && String(l[i].name) === name) return l[i];
        return null;
    }

    /**
     * Lo que WirePlumber tiene que respetar para este flujo, con el mismo orden que
     * find-defined-target.lua: metadatos (target.object, luego target.node) salvo
     * `node.dont-move`; si no, las propiedades del flujo.
     *   mode   "device" · "default" (-1 explícito) · "none" (sin destino) · "unknown"
     *   from   "metadata" · "props" · ""
     *   device node.name del destino; present: si existe ahora
     */
    function requestedOf(n) {
        if (!n || !n.isStream) return { mode: "none", from: "", device: "", present: false };
        void root.meta;
        const dontMove = root.prop(n, "node.dont-move") === "true";
        let raw = "", key = "", from = "";
        const e = root.meta[String(n.id)];
        if (!dontMove && e) {
            if (e["target.object"] !== undefined) { raw = e["target.object"]; key = "object"; from = "metadata"; }
            else if (e["target.node"] !== undefined) { raw = e["target.node"]; key = "node"; from = "metadata"; }
        }
        if (from === "") {
            if (root.prop(n, "target.object").length > 0) { raw = root.prop(n, "target.object"); key = "object"; from = "props"; }
            else if (root.prop(n, "node.target").length > 0) { raw = root.prop(n, "node.target"); key = "node"; from = "props"; }
        }
        if (from === "")
            return { mode: root.metaLive || dontMove ? "none" : "unknown", from: "", device: "", present: false };
        if (raw === "-1") return { mode: "default", from: from, device: "", present: true };
        // target.object puede ser un serial o un node.name; target.node, un id.
        const num = /^\d+$/.test(raw);
        const t = key === "node" ? root.nodeById(raw) : (num ? root.nodeBySerial(raw) : root.nodeByName(raw));
        const gone = key === "node" ? root.known.id[raw] : (num ? root.known.serial[raw] : raw);
        return { mode: "device", from: from, device: t ? String(t.name) : (gone || ""),
                 present: t !== null, raw: raw };
    }

    // ---- ruta recordada: el estado de WirePlumber -----------------------------------

    readonly property string wpState: Xdg.base(Quickshell.env("XDG_STATE_HOME"), Quickshell.env("HOME") + "/.local/state") + "/wireplumber/stream-properties"

    /** { "<clave de formKey>": "<node.name recordado>" }, sólo las que tienen destino. */
    property var remembered: ({})
    property bool stateRead: false

    FileView {
        path: root.active ? root.wpState : ""
        watchChanges: true
        printErrors: false
        onLoaded: root.parseState(text())
        onLoadFailed: { root.remembered = ({}); root.stateRead = true; }
        onFileChanged: reload()
    }

    /**
     * El archivo es un GKeyFile que WirePlumber escribe con su propio escape de claves
     * (medido: «PipeWire\sALSA\s\ompv\c» = «PipeWire ALSA [mpv]»): \s espacio, \e =,
     * \o [, \c ], y \\ la barra.
     */
    function unescapeKey(k) {
        return k.replace(/\\(.)/g, (m, c) => c === "s" ? " " : c === "e" ? "=" : c === "o" ? "["
                                            : c === "c" ? "]" : c);
    }

    function parseState(txt) {
        const out = {};
        let inSection = false;
        for (const line of String(txt || "").split("\n")) {
            if (line.startsWith("[")) { inSection = line.trim() === "[stream-properties]"; continue; }
            if (!inSection) continue;
            const i = line.indexOf("=");
            if (i <= 0) continue;
            let v = null;
            try { v = JSON.parse(line.substring(i + 1)); } catch (e) { continue; }
            if (v && typeof v.target === "string" && v.target.length > 0)
                out[root.unescapeKey(line.substring(0, i))] = v.target;
        }
        root.remembered = out;
        root.stateRead = true;
    }

    /**
     * La clave con la que WirePlumber guarda un flujo (node/state-stream.lua, formKey):
     * «Output/Audio:application.id:mpv». Las notificaciones van por su rol.
     */
    function appKey(n) {
        const cls = root.prop(n, "media.class").replace(/^Stream\//, "");
        if (root.prop(n, "media.role") === "Notification") return cls + ":media.role:Notification";
        for (const k of ["application.id", "application.name", "media.name", "node.name"]) {
            const v = root.prop(n, k);
            if (v.length > 0) return cls + ":" + k + ":" + v;
        }
        return "";
    }

    /** { device, present } o null si WirePlumber no recuerda destino para esa app. */
    function rememberedOf(n) {
        void root.remembered;
        if (!root.stateRead) return null;
        const k = root.appKey(n);
        const d = k.length > 0 ? root.remembered[k] : undefined;
        if (d === undefined) return null;
        return { device: d, present: root.nodeByName(d) !== null };
    }

    // ---- mover un flujo (13B) -------------------------------------------------------

    /**
     * Cada movimiento es una petición con revisión, clave `route:<id del flujo>`, valor el
     * `node.name` pedido ("" = el predeterminado). Se escribe `target.object` en los
     * metadatos `default` —el serial del destino, o -1 para «Use default output», que además
     * hace que WirePlumber OLVIDE el destino de esa app (state-stream.lua: -1 → sin target)—
     * y se confirma por los ENLACES: la ruta efectiva tiene que ser exactamente el destino y
     * sostenerse 600 ms (el mismo destello que Mixer caza en el predeterminado); plazo 3 s.
     * Si el destino o el flujo desaparecen antes, error: nada se da por hecho sin verlo.
     */
    readonly property Ops ops: Ops { name: "routes" }

    function streamKey(n) { return "route:" + n.id; }

    /** El destino que vale como «predeterminado» para ese flujo. */
    function defaultFor(n) {
        const d = n && n.isSink ? Pipewire.defaultAudioSink : Pipewire.defaultAudioSource;
        return d ? String(d.name) : "";
    }

    function moveTo(n, deviceName) {
        if (!n || !n.isStream) return -1;
        const key = root.streamKey(n);
        const want = String(deviceName || "");
        const r = root.ops.request(key, want);
        // Los errores inmediatos llevan la ruta de ahora: la fila los enseña mientras siga igual.
        const cur = root.effectiveOf(n).map(x => String(x.node.name)).join(", ");
        if (root.prop(n, "node.dont-move") === "true") {
            root.ops.resolve(key, r, "error", "This app doesn't allow moving its audio", cur);
            return r;
        }
        let value = "-1";
        if (want.length > 0) {
            const t = root.nodeByName(want);
            const serial = t ? root.prop(t, "object.serial") : "";
            if (!t || serial.length === 0) {
                root.ops.resolve(key, r, "error", "That " + root.noun(n) + " is not connected", cur);
                return r;
            }
            value = serial;
        }
        const id = n.id;
        root.queueWrite(["pw-metadata", "-n", "default", "--", String(id), "target.object", value, "Spa:Id"], key, r);
        root.ops.expect(key, r, { hold: 600, timeout: 3000, check: () => root.checkMove(id, want) });
        return r;
    }

    /** Lo que se pinta en el selector: lo pedido en vuelo; si no, lo que hay. */
    function shownChoice(n) {
        if (!n) return "";
        void root.ops.table;
        const q = root.requestedOf(n);
        let cur = "";
        if (q.mode === "device" && q.present) cur = q.device;
        else if (q.mode === "device") {
            // Ausente: su nombre, o el que WirePlumber recuerda si el serial nunca se vio
            // (medido: «absent:» vacío casaba con Default y la → borró la preferencia).
            const m = root.rememberedOf(n);
            const name = q.device.length > 0 ? q.device : (m ? m.device : "");
            cur = name.length > 0 ? "absent:" + name : "absent";
        }
        return root.ops.shown(root.streamKey(n), cur);
    }

    /**
     * El selector de ruta de una fila (13B/13C; antes de la fase 14 pasa aquí desde la surface, para
     * que la surface y la Audio UI decidan igual). Se ofrece con más de un dispositivo compatible, o
     * si la app ya tiene una preferencia (para poder volver a Default aunque sólo quede uno); con uno
     * solo y sin preferencia, la fila se queda con su ruta y sin control. Default = seguir al
     * predeterminado; elegirlo hace que WirePlumber olvide la preferencia de esa app.
     */
    function devicesFor(n) { return n && n.isSink ? Mixer.sinks : Mixer.sources; }
    function routeWanted(n) {
        if (!n) return false;
        const st = root.rowStatus(n);
        return root.devicesFor(n).length > 1 || st.state !== "idle" || st.preferred.length > 0;
    }
    function routeOptions(n) {
        return [{ label: "Default", value: "" }]
            .concat(root.devicesFor(n).map(d => ({ label: Mixer.shortLabel(d), value: String(d.name) })));
    }
    function cycleRoute(n, dir) {
        const opts = root.routeOptions(n);
        const cur = root.shownChoice(n);
        let i = opts.findIndex(o => o.value === cur);
        // Sin pastilla marcada porque la preferida volvió («X is back»): el primer paso la elige
        // a ella; ir a Default borraría la preferencia de la app.
        const back = cur.startsWith("absent:") && cur.length > 7
            ? opts.findIndex(o => o.value === cur.substring(7)) : -1;
        if (back >= 0) i = back;
        else i = i < 0 ? (dir > 0 ? 0 : opts.length - 1) : ((i + dir) % opts.length + opts.length) % opts.length;
        return root.moveTo(n, opts[i].value);
    }
    /** 13F: con la fila en error, repetir lo último pedido. */
    function retryRoute(n) {
        const o = root.ops.get(root.streamKey(n));
        return root.moveTo(n, o.requested === null || o.requested === undefined ? "" : String(o.requested));
    }

    /** Para `Ops.expect`: la ruta efectiva es EXACTAMENTE el destino (sin quedarse en dos). */
    function checkMove(id, want) {
        const n = root.nodeByIdStream(id);
        if (!n) return { fail: "The app stopped playing" };
        const target = want.length > 0 ? want : root.defaultFor(n);
        const eff = root.effectiveOf(n).map(r => String(r.node.name));
        const got = eff.join(", ");
        if (eff.length === 1 && eff[0] === target) return { met: true, effective: got };
        const gone = want.length > 0 && root.nodeByName(want) === null;
        return { effective: got,
                 reason: gone ? "The " + root.noun(n) + " went away" : "Still on " + (eff.length > 0 ? root.labelOf(eff[0]) : "nothing") };
    }

    /** «output» para un flujo que reproduce, «input» para uno que graba (13C). */
    function noun(n) { return n && n.isSink ? "output" : "input"; }

    function nodeByIdStream(id) {
        const n = root.nodeById(id);
        return n && n.isStream ? n : null;
    }
    function labelOf(name) {
        const n = root.nodeByName(name);
        void root.known;
        return n ? Mixer.shortLabel(n) : (root.known.label[name] || name);
    }

    // Escrituras en cola, una a la vez (el orden importa: la última petición gana).
    property var writeQueue: []
    function queueWrite(cmd, key, rev) {
        root.writeQueue = root.writeQueue.concat([{ cmd: cmd, key: key, rev: rev }]);
        root.nextWrite();
    }
    function nextWrite() {
        if (writeProc.running || root.writeQueue.length === 0) return;
        const job = root.writeQueue[0];
        root.writeQueue = root.writeQueue.slice(1);
        writeProc.key = job.key;
        writeProc.rev = job.rev;
        writeProc.command = job.cmd;
        writeProc.running = true;
    }
    Process {
        id: writeProc
        property string key: ""
        property int rev: 0
        onExited: (code) => {
            if (code !== 0 && root.ops.latest(writeProc.key) === writeProc.rev && root.ops.pending(writeProc.key))
                root.ops.resolve(writeProc.key, writeProc.rev, "error", "PipeWire refused the change");
            root.nextWrite();
        }
    }

    /**
     * Lo que la fila tiene que decir además de la ruta:
     *   state      idle · changing · error · pending (preferencia de una salida que no está)
     *   text       la frase corta
     *   preferred  node.name preferido si lo hay ("" = el predeterminado)
     */
    function rowStatus(n) {
        if (!n) return { state: "idle", text: "", preferred: "" };
        void root.ops.table;
        const key = root.streamKey(n);
        const st = root.ops.stateOf(key);
        if (st === "pending") {
            const want = root.ops.get(key).requested;
            return { state: "changing", preferred: want,
                     text: "Changing to " + (want.length > 0 ? root.labelOf(want) : "the default " + root.noun(n)) + "…" };
        }
        if (st === "error") {
            const o = root.ops.get(key);
            // Un error viejo no tapa lo que pasó después: vale mientras la ruta siga siendo la
            // que había al fallar (si luego se mueve por otro lado, deja de decirse).
            const now = root.effectiveOf(n).map(r => String(r.node.name)).join(", ");
            if (o.effective === undefined || o.effective === null || String(o.effective) === now)
                return { state: "error", preferred: o.requested, text: "Couldn't move: " + o.reason };
        }
        const q = root.requestedOf(n);
        const m = root.rememberedOf(n);
        // Un serial pedido que el shell nunca vio (la salida se fue antes de una recarga) no
        // tiene nombre: entonces manda lo que WirePlumber recuerda para la app.
        const byMeta = q.mode === "device" && q.device.length > 0;
        const pref = byMeta ? q.device : (m ? m.device : "");
        // Pedido por metadato a una instancia que ya no existe: aunque la app «recuerde» una
        // salida presente, ESTE flujo no está en ella.
        const present = byMeta ? q.present : (q.mode === "device" ? false : (m ? m.present : true));
        if (pref.length > 0 && !present) {
            const eff = root.effectiveOf(n);
            // El metadato apunta al SERIAL de la instancia vieja: si la salida volvió (otro
            // serial), existe pero este flujo no vuelve solo (WirePlumber sólo restaura en
            // flujos nuevos, medido en la 13A). Decir «not connected» sería falso.
            if (root.nodeByName(pref) !== null)
                return { state: "pending", preferred: pref,
                         text: root.labelOf(pref) + " is back · select it to move this app" };
            return { state: "pending", preferred: pref,
                     text: "Prefers " + root.labelOf(pref) + " · not connected"
                         + (eff.length > 0 ? " · using " + Mixer.shortLabel(eff[0].node) : "") };
        }
        return { state: "idle", text: "", preferred: pref };
    }

    // ---- la foto por flujo -----------------------------------------------------------

    /** Todos los flujos visibles con su identidad y sus tres rutas. */
    function describe(n, kind) {
        const eff = root.effectiveOf(n);
        const key = root.appKey(n);
        return {
            id: n.id,
            serial: root.prop(n, "object.serial"),
            kind: kind,
            app: Mixer.label(n),
            appKey: key,
            mediaName: root.prop(n, "media.name"),
            pid: root.prop(n, "application.process.id"),
            dontMove: root.prop(n, "node.dont-move") === "true",
            effective: eff.map(r => ({ device: String(r.node.name), label: Mixer.shortLabel(r.node),
                                       via: r.via })),
            requested: root.requestedOf(n),
            remembered: root.rememberedOf(n),
            status: root.rowStatus(n),
            choice: root.shownChoice(n)
        };
    }

    /** Para el IPC `audioRoutes`. Numera las instancias de una misma app («2/3»). */
    function summary() {
        const rows = [];
        for (const n of Mixer.playback) rows.push(root.describe(n, "playback"));
        for (const n of Mixer.capture) rows.push(root.describe(n, "capture"));
        const byApp = {};
        for (const r of rows) (byApp[r.appKey] = byApp[r.appKey] || []).push(r);
        for (const k in byApp) {
            const l = byApp[k].sort((a, b) => Number(a.serial) - Number(b.serial));
            for (let i = 0; i < l.length; i++) l[i].instance = (i + 1) + "/" + l.length;
        }
        const hidden = [];
        for (const n of root.nodes) if (n && root.isInternal(n)) hidden.push(String(n.name));
        return {
            active: root.active, metaLive: root.metaLive, stateRead: root.stateRead,
            streams: rows,
            sinks: Mixer.sinks.map(n => String(n.name)),
            sources: Mixer.sources.map(n => String(n.name)),
            hidden: hidden,
            remembered: root.remembered
        };
    }
}
