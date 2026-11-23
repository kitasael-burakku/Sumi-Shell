pragma Singleton

import QtQuick
import Quickshell

/**
 * La Audio UI (antes de la fase 14, `rediseno/Antes-de-fase-14.md`): el ESTADO de su vista. Los
 * datos no viven aquí: son de `Mixer`, `AudioRoutes`, `Equalizer` y `AudioDevices`, los mismos que
 * usa la surface compacta. Separación pedida por el usuario: la surface es el control inmediato;
 * esto, la configuración (el ecualizador entero, dispositivos, balance, aplicaciones con detalle).
 *
 * Una sola instancia lógica, como la UI de System Monitor: `open` + `screen`. La abren Super+Shift+A
 * (decisión del usuario, 2026-09-28), los enlaces de la surface y de Settings y el IPC, todos por
 * `core/Screens.audioOn`; pedirla en otra pantalla la LLEVA allí. Cerrarla suelta las reclamaciones
 * pero conserva sección y salida del ecualizador.
 *
 * `eqPick` es de la vista y la comparten surface y UI: qué salida se mira en Equalizer. Vacío =
 * seguir a la predeterminada. Una salida elegida que se desconecta NO se cambia por otra en
 * silencio: sigue elegida con su estado «absent» (su perfil se conserva), para no enseñar la curva
 * de una salida con el nombre de otra. (Sin perfil no hay curva que confundir: entonces vuelve a
 * la predeterminada.)
 */
Singleton {
    id: root

    property bool open: false
    property string screen: ""
    property var positions: ({})
    property var layer: null
    property int opens: 0

    readonly property var sections: [
        {id: "overview", label: "Overview"},
        {id: "output", label: "Output"},
        {id: "input", label: "Input"},
        {id: "applications", label: "Applications"}
    ].concat(Equalizer.supported ? [{id: "equalizer", label: "Equalizer"}] : [])
     .concat([{id: "devices", label: "Devices"}])
    property string section: "overview"
    onSectionsChanged: if (!root.sections.some(s => s.id === root.section)) root.section = "overview"
    /** Se usó el teclado en esta apertura: sólo entonces se pinta el contorno del foco. */
    property bool keyNav: false

    // ---- la salida del ecualizador ------------------------------------------------------------
    property string eqPick: ""
    readonly property string defaultSinkName: Mixer.defaultSink ? String(Mixer.defaultSink.name) : ""
    readonly property string eqDev: {
        void Equalizer.profiles;
        if (root.eqPick.length > 0
            && (Mixer.sinks.some(n => String(n.name) === root.eqPick) || Equalizer.profileOf(root.eqPick)))
            return root.eqPick;
        return root.defaultSinkName;
    }
    readonly property bool eqFollowsDefault: root.eqDev.length > 0 && root.eqDev === root.defaultSinkName
    /** Las salidas que se pueden mirar: las conectadas y las que tienen perfil aunque no estén. */
    readonly property var eqOutputs: {
        void Equalizer.profiles;
        const out = Mixer.sinks.map(n => ({value: String(n.name), label: Mixer.shortLabel(n), present: true}));
        for (const d in Equalizer.profiles)
            if (!out.some(o => o.value === d))
                out.push({value: d, label: (Equalizer.profiles[d].label || d) + " (not connected)", present: false});
        return out;
    }
    function pickEq(dev) {
        const d = String(dev || "");
        if (d.length > 0 && !root.eqOutputs.some(o => o.value === d)) return false;
        // elegir la predeterminada vuelve a «seguirla»
        root.eqPick = d === root.defaultSinkName ? "" : d;
        return true;
    }

    /**
     * Abierta (y no tapada por el bloqueo): el Mixer sigue rutas y verifica cambios; Devices lee
     * las tarjetas sólo con su sección (o Output, que enseña perfil y puerto) a la vista.
     */
    readonly property bool claiming: root.open && !Lock.engaged
    onClaimingChanged: Mixer.claim("audio-ui", root.claiming)
    readonly property bool wantsCards: root.claiming && ["devices", "output", "input"].indexOf(root.section) >= 0
    onWantsCardsChanged: AudioDevices.claim("audio-ui", root.wantsCards)

    // ---- abrir / cerrar ---------------------------------------------------------------------
    function show(name, section) {
        if (!name) return false;
        if (section === "equalizer" && !Equalizer.supported) return false;
        if (section && root.sections.some(s => s.id === section)) root.section = section;
        root.screen = name;
        if (!root.open) { root.opens++; root.keyNav = false; }
        root.open = true;
        return true;
    }
    function close() {
        root.open = false;
        return true;
    }
    /** Mismo sitio, abierta y sin sección pedida (o la misma) → cierra; si no, se muestra allí. */
    function toggle(name, section) {
        if (root.open && root.screen === name && (!section || section === root.section)) return root.close();
        return root.show(name, section);
    }
    function positionOf(name) { return root.positions[name] || null; }
    function remember(name, x, y) {
        const p = Object.assign({}, root.positions);
        p[name] = {x: Math.round(x), y: Math.round(y)};
        root.positions = p;
    }

    function summary() {
        return {open: root.open, screen: root.screen, opens: root.opens, section: root.section,
            sections: root.sections.map(s => s.id),
            eqDev: root.eqDev, eqPick: root.eqPick, eqFollowsDefault: root.eqFollowsDefault,
            eqOutputs: root.eqOutputs, claiming: root.claiming, wantsCards: root.wantsCards,
            positions: root.positions, layer: root.layer ? root.layer.geometry() : null};
    }
}
