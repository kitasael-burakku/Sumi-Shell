pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import "../lib/notch-activities.js" as Acts

/**
 * Qué actividad enseña el notch en sus orejas (2026-11-17). Sólo decide; dibuja `core/NotchEar` y la coloca
 * `core/Island`. El catálogo (qué hay, quién gana, cuánto dura, cuánto mide) es `lib/notch-activities.js`.
 *
 *   live   la persistente que gana ahora: grabación > speed test > música ("" ninguna).
 *   flash  un aviso breve (cargador, copiado, auriculares, workspace) que tapa a la live unos segundos.
 *          `flashScreen` limita el aviso a una pantalla ("" = todas): el workspace es de su monitor.
 *
 * Los avisos breves sólo salen por un CAMBIO real: nada se anuncia hasta `armed` (3 s tras construirse), así un
 * arranque o una recarga no enseñan «cargador» ni «auriculares» por lo que ya estaba así. La recarga reconstruye este
 * singleton, así que `armed` vuelve a empezar.
 */
Singleton {
    id: root

    property bool armed: false
    Timer {
        interval: 3000
        running: true
        onTriggered: root.armed = true
    }

    // ---- live -------------------------------------------------------------------------------------------------

    readonly property string live: Acts.pickLive({
        recording: ScreenRecorder.live,
        speed: SpeedTest.busy,
        work: root.workCount > 0,
        music: Media.has
    }, {
        notchActRecording: Settings.notchActRecording,
        notchActSpeed: Settings.notchActSpeed,
        notchActWork: Settings.notchActWork,
        notchActMusic: Settings.notchActMusic
    })

    /**
     * F10 (2026-11-27): trabajo en curso, para la oreja `work` del Edge y la marca del Dashboard en la cara hover y la
     * barra. Trabajos de Tasks que corren y descargas (Wallhaven) en marcha o en cola.
     */
    readonly property int jobCount: Jobs.runners.filter(r => r.busy).length
    readonly property int downloadCount: Downloads.runningCount + Downloads.queuedCount
    readonly property int workCount: root.jobCount + root.downloadCount
    readonly property string workText: root.workCount === 0 ? ""
        : root.jobCount > 0 && root.downloadCount === 0 ? root.jobCount + (root.jobCount === 1 ? " task" : " tasks")
        : root.jobCount === 0 ? root.downloadCount + " ↓"
        : root.workCount + " jobs"
    readonly property string workGlyph: root.jobCount > 0 ? "terminal" : "download"

    // ---- flash ------------------------------------------------------------------------------------------------

    property string flash: ""
    property string flashScreen: ""
    /** Lo que dice el aviso (cada uno el suyo): { text, glyph, value }. Se sustituye entero, nunca se muta. */
    property var flashData: ({})

    function announce(id, data, screenName) {
        if (!root.armed) return false;
        const prefs = {
            notchActPower: Settings.notchActPower, notchActCopy: Settings.notchActCopy,
            notchActBluetooth: Settings.notchActBluetooth, notchActWorkspace: Settings.notchActWorkspace
        };
        if (!Acts.flashAllowed(id, prefs)) return false;
        root.flashData = data || ({});
        root.flashScreen = screenName || "";
        root.flash = id;
        flashTimer.interval = Acts.holdOf(id);
        flashTimer.restart();
        return true;
    }
    Timer {
        id: flashTimer
        onTriggered: { root.flash = ""; root.flashScreen = ""; }
    }

    /** La actividad que enseña la pantalla `screenName`: la flash (si es suya) o la live. */
    function currentFor(screenName) {
        if (root.flash.length > 0 && (root.flashScreen.length === 0 || root.flashScreen === screenName)) return root.flash;
        return root.live;
    }

    // ---- fuentes de las flash -----------------------------------------------------------------------------------

    /** Cargador: al enchufar o desenchufar (sólo con batería: un sobremesa no tiene nada que decir). */
    Connections {
        target: Battery
        function onExternalPowerChanged() {
            if (Battery.present) root.announce("power", { value: Battery.percent });
        }
    }

    /** Copiado: lo elegido en el selector de emojis ya está en el portapapeles (o pegado). */
    Connections {
        target: Emoji
        function onSettled(rev, ok, reason) {
            if (ok) root.announce("copy", { text: Emoji.pickMode === "paste" ? "Pasted" : "Copied" });
        }
    }
    /** F6 (2026-11-27): también lo elegido en el historial del portapapeles, ya en la selección. */
    Connections {
        target: Clip.ops
        function onSettled(key, rev, state, reason) {
            if (key === "paste" && state === "ok") root.announce("copy", { text: "Copied" });
        }
    }

    /**
     * Auriculares y altavoces Bluetooth: al CONECTARSE uno (no al desconectarse), su batería si la da.
     * `known` son las direcciones conectadas la última vez; uno nuevo en la lista es el que se acaba de conectar.
     */
    property var known: []
    readonly property var audioConnected: {
        const out = [];
        const ds = Bt.connectedDevices;
        for (let i = 0; i < ds.length; i++) {
            const g = Bt.deviceGlyph(ds[i]);
            if (g === "headphones" || g === "headset" || g === "speaker") out.push(ds[i]);
        }
        return out;
    }
    onAudioConnectedChanged: {
        const now = root.audioConnected.map(d => String(d.address));
        for (let i = 0; i < root.audioConnected.length; i++) {
            const d = root.audioConnected[i];
            if (root.known.indexOf(String(d.address)) < 0) {
                root.announce("bluetooth", { glyph: Bt.deviceGlyph(d), value: Bt.batteryOf(d) });
                break;
            }
        }
        root.known = now;
    }

    /**
     * Workspace: al cambiar el workspace de UN monitor (no al pasar el foco a otro monitor, que no cambia nada en
     * ninguno). `perMonitor`: el último workspace visto en cada monitor. Los especiales (id < 0) no se anuncian.
     */
    property var perMonitor: ({})
    Component.onCompleted: {
        const m = {};
        const ms = Hyprland.monitors.values;
        for (let i = 0; i < ms.length; i++)
            if (ms[i].activeWorkspace) m[String(ms[i].name)] = ms[i].activeWorkspace.id;
        root.perMonitor = m;
    }
    Connections {
        target: Hyprland
        function onFocusedWorkspaceChanged() {
            const ws = Hyprland.focusedWorkspace;
            if (!ws || !ws.monitor) return;
            const mon = String(ws.monitor.name);
            const prev = root.perMonitor[mon];
            const next = Object.assign({}, root.perMonitor);
            next[mon] = ws.id;
            root.perMonitor = next;
            if (prev !== undefined && prev !== ws.id && ws.id > 0)
                root.announce("workspace", { value: ws.id, from: prev, text: String(ws.name || ws.id) }, mon);
        }
    }
}
