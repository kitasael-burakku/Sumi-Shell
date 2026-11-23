pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

/**
 * Las tarjetas de audio (antes de la fase 14, en lectura; 14F: cambiar el perfil). Cambiarlo va por
 * la prueba con vuelta atrás (SystemTest, tipo `audio-profile`: sumi-guard aplica con pactl, cuenta
 * 15 s y vuelve al perfil de antes y a la salida predeterminada si no se confirma). Decisión 6: sólo
 * perfiles disponibles; Pro Audio sólo en Advanced, avisando de que renombra las salidas. Quickshell 0.3.1 expone los nodos, no los
 * dispositivos: perfiles, puertos (rutas) y su disponibilidad sólo están en el objeto Device de
 * PipeWire, así que se leen con `pw-dump` (medido: 8 ms, ~180 KB en esta máquina).
 *
 * Se lee al reclamar (Audio UI en Output, Input o Devices) y otra vez cuando cambia la lista de
 * nodos de PipeWire (un perfil nuevo o un dispositivo que entra o sale rehace sus nodos), con 300 ms
 * de respiro. Lo que NO trae evento en Quickshell es el estado de un nodo (suspendido ↔ sonando) ni
 * el formato con que arranca, ni un puerto que se enchufa: para eso, una relectura cada 4 s mientras
 * haya reclamación (8 ms de pw-dump; al probar la UI el formato se quedaba en «suspended» con la
 * música ya sonando).
 * Sin reclamaciones no corre nada y se sueltan los datos.
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
        if (root.active) root.refresh();
        else { debounce.stop(); root.cards = []; root.others = []; root.loaded = false; root.error = ""; }
    }

    /** [{ id, name, label, api, bus, formFactor, profile, profiles, routes, nodes }] */
    property var cards: []
    /** Salidas y entradas sin tarjeta (virtuales), en el mismo formato de nodo. */
    property var others: []
    property bool loaded: false
    property string error: ""
    property real readAt: 0
    property int reads: 0

    readonly property int nodeCount: Pipewire.nodes ? Pipewire.nodes.values.length : 0
    onNodeCountChanged: if (root.active) debounce.restart()
    Timer { id: debounce; interval: 300; onTriggered: root.refresh() }
    Timer { interval: 4000; repeat: true; running: root.active; onTriggered: root.refresh() }

    function refresh() {
        if (!root.active) return false;
        if (dump.running) { debounce.restart(); return true; }
        dump.running = true;
        return true;
    }

    function cardOfNode(name) {
        for (const c of root.cards) for (const n of c.nodes) if (n.name === name) return c;
        return null;
    }
    function nodeInfo(name) {
        for (const c of root.cards) for (const n of c.nodes) if (n.name === name) return n;
        return root.others.find(n => n.name === name) || null;
    }

    function parse(txt) {
        const all = JSON.parse(txt);
        const devs = {};
        const cards = [];
        for (const o of all) {
            if (o.type !== "PipeWire:Interface:Device" || !o.info || !o.info.props) continue;
            const p = o.info.props;
            if (p["media.class"] !== "Audio/Device") continue;
            const par = o.info.params || {};
            const act = (par.Profile || [])[0] || null;
            const activeRoutes = (par.Route || []).map(r => r.name);
            const c = {
                id: o.id, name: String(p["device.name"] || ""),
                label: String(p["device.nick"] || p["device.description"] || p["device.name"] || ""),
                description: String(p["device.description"] || ""),
                api: String(p["device.api"] || ""), bus: String(p["device.bus"] || ""),
                formFactor: String(p["device.form-factor"] || ""),
                address: String(p["api.bluez5.address"] || ""),
                profile: act ? {index: act.index, name: String(act.name || ""), description: String(act.description || "")} : null,
                profiles: (par.EnumProfile || []).map(x => ({index: x.index, name: String(x.name || ""),
                    description: String(x.description || ""), available: String(x.available || "unknown"),
                    active: !!act && x.index === act.index})),
                routes: (par.EnumRoute || []).map(x => ({name: String(x.name || ""), description: String(x.description || ""),
                    direction: String(x.direction || ""), available: String(x.available || "unknown"),
                    active: activeRoutes.indexOf(x.name) >= 0})),
                nodes: []
            };
            devs[o.id] = c;
            cards.push(c);
        }
        const others = [];
        for (const o of all) {
            if (o.type !== "PipeWire:Interface:Node" || !o.info || !o.info.props) continue;
            const p = o.info.props;
            const cls = String(p["media.class"] || "");
            if (["Audio/Sink", "Audio/Source", "Audio/Source/Virtual"].indexOf(cls) < 0) continue;
            // los nodos del EQ (filtros smart) no son dispositivos
            if (p["kitasan.equalizer"] !== undefined || p["filter.smart"] === true) continue;
            const fmt = ((o.info.params || {}).Format || [])[0] || null;
            const n = {
                id: o.id, name: String(p["node.name"] || ""), mediaClass: cls,
                label: String(p["node.nick"] || p["node.description"] || p["node.name"] || ""),
                description: String(p["node.description"] || ""),
                state: String(o.info.state || ""),
                channels: Number(p["audio.channels"] || (fmt ? fmt.channels : 0)) || 0,
                position: String(p["audio.position"] || "").replace(/[\[\],]/g, " ").trim().split(/\s+/).filter(Boolean),
                rate: fmt && fmt.rate ? fmt.rate : 0,
                format: fmt && fmt.format ? String(fmt.format) : "",
                profile: String(p["device.profile.description"] || ""),
                codec: String(p["api.bluez5.codec"] || ""),
                path: String(p["api.alsa.path"] || "")
            };
            const d = devs[Number(p["device.id"])];
            if (d) d.nodes.push(n); else others.push(n);
        }
        return {cards: cards, others: others};
    }

    Process {
        id: dump
        command: ["timeout", "3", "pw-dump"]
        stdout: StdioCollector { id: dumpOut }
        onExited: (code) => {
            if (!root.active) return;
            try {
                if (code !== 0) throw new Error("pw-dump exited with " + code);
                const r = root.parse(dumpOut.text || "[]");
                root.cards = r.cards;
                root.others = r.others;
                root.error = "";
            } catch (e) {
                root.error = "Could not read the audio devices";
            }
            root.loaded = true;
            root.readAt = Date.now();
            root.reads++;
        }
    }

    // ---- 14F: cambiar el perfil ---------------------------------------------------------------
    /** Enseñar Pro Audio entre las opciones (decisión 6: sólo en Advanced). */
    property bool advanced: false
    /** Los perfiles que se pueden elegir: disponibles (no «no»), off siempre, Pro Audio sólo en Advanced. */
    function choices(card) {
        if (!card) return [];
        return card.profiles.filter(p => p.name === "off" || (p.available !== "no"
                                         && (p.name.indexOf("pro-audio") !== 0 || root.advanced || p.active)));
    }
    /** Qué pasa si se cambia a `prof`, en palabras (inglés, UI). */
    function consequence(card, prof) {
        if (!card || !prof) return "";
        const parts = [];
        if (prof === "off") parts.push("Turns the card off: its outputs and inputs disappear");
        else if (prof.indexOf("pro-audio") === 0) parts.push("Pro Audio renames outputs: the equalizer and app routes won't follow");
        else parts.push("Its outputs and inputs are rebuilt");
        const def = Mixer.defaultSink ? String(Mixer.defaultSink.name) : "";
        if (card.nodes.some(n => n.name === def))
            parts.push("it has your default output: the sound cuts and players may pause (they resume if it reverts)");
        else if (card.nodes.some(n => n.state === "running")) parts.push("sound on it stops and players may pause");
        return parts.join(" · ");
    }
    /** Pruebas (IPC): sólo tarjetas cuyo nombre case con SystemTest.testOnly. */
    function testProfile(card, prof, owner) {
        if (!card || !prof || (card.profile && card.profile.name === prof)) return false;
        return SystemTest.start("audio-profile", { card: card.name, profile: prof }, owner || "", SystemTest.titleFor("audio-profile"));
    }
    Connections {
        target: SystemTest
        function onFinished(state, reason, screen) { if (SystemTest.last && SystemTest.last.kind === "audio-profile") root.refresh(); }
    }

    function summary() {
        return {active: root.active, claims: Object.keys(root.claims), loaded: root.loaded, error: root.error,
            reads: root.reads, cards: root.cards, others: root.others, advanced: root.advanced};
    }
}
