pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Espectro de audio para la oreja de música del notch (2026-11-17, pedido del usuario: ondas REALES, sin el aviso de
 * privacidad). Vuelve el servicio retirado en la 15H (`880db32`), con un solo consumidor: la oreja.
 *
 * `cava` sin interfaz lee el monitor de la salida por defecto (pipewire) y escribe cada fotograma como texto; aquí sólo
 * se parte en niveles 0..1.
 *
 * PRIVACIDAD: el nodo de captura de ESTE cava lleva `sumi.visualizer = true` (`PIPEWIRE_PROPS`, PipeWire lo aplica a
 * cada stream) y `services/Privacy.isOwnVisualizer()` lo excluye, sólo a él: un cava lanzado a mano, OBS o el
 * visualizador de maly siguen encendiendo el aviso (decisión del usuario del 2026-09-15).
 *
 * Coste y cuándo corre:
 *   · Medido en la fase 9 (shell entero, con música): 30 fps +3,8 % de un núcleo, 15 fps +1,9 %. La oreja se repinta a
 *     ese ritmo, no a los 200 Hz del monitor (sin `Behavior` en las barras: lo liso lo da el suavizado de cava).
 *   · Sólo con fps > 0 (Settings → Notch → Audio visualizer), un reproductor SONANDO (`Media.playing`), alguna oreja
 *     de música a la vista (`claim`) y la sesión DESBLOQUEADA (LOCK-D13: con el lock no se captura audio).
 *   · Al dejar de quererse, 3 s de gracia antes de parar cava (no se relanza entre pistas ni al pasar el puntero).
 *
 * Diferencias con el de Ukishima, a propósito: sin `sh -c "printf … | cava"` (parar el `sh` puede dejar a cava huérfano
 * capturando audio): la config va a un archivo y el proceso es cava directamente; `autosens = 1`.
 */
Singleton {
    id: root

    readonly property int bars: 4
    /** Niveles 0..1, del grave al agudo. */
    property var levels: [0, 0, 0, 0]
    /** Hay señal ahora (1,2 s de silencio la quitan). */
    property bool active: false

    /** cava instalado (`command -v`), y no roto: 5 salidas seguidas lo apagan hasta reiniciar. */
    property bool installed: false
    property bool probed: false
    property int failures: 0
    readonly property bool available: root.installed && root.failures < 5
    readonly property bool running: proc.running

    readonly property int fps: Math.max(0, Math.min(60, Settings.notchVisualizerFps))

    /** Quién la quiere: { clave: true } (una por oreja de música visible). */
    property var claims: ({})
    function claim(who, on) {
        const has = root.claims[who] === true;
        if (has === !!on) return;
        const c = Object.assign({}, root.claims);
        if (on) c[who] = true;
        else delete c[who];
        root.claims = c;
    }

    readonly property bool wanted: root.fps > 0 && root.available && Media.playing && !Lock.engaged
        && Object.keys(root.claims).length > 0

    readonly property string confPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/sumi-cava.conf"
    readonly property string config: "[general]\n"
        + "bars = " + root.bars + "\nframerate = " + root.fps + "\nautosens = 1\n"
        + "[input]\nmethod = pipewire\nsource = auto\n"
        + "[output]\nmethod = raw\nraw_target = /dev/stdout\ndata_format = ascii\n"
        + "ascii_max_range = 1000\nbar_delimiter = 59\nframe_delimiter = 10\n"
        + "channels = mono\nmono_option = average\n"
        + "[smoothing]\nnoise_reduction = 0.77\n"

    /** ¿Está cava? Un Process que no arranca no avisa con `exited` (memoria del proyecto): se pregunta a `sh`. */
    Process {
        id: probe
        command: ["sh", "-c", "command -v cava >/dev/null 2>&1"]
        running: true
        onExited: (code) => { root.installed = code === 0; root.probed = true; if (root.wanted) root.start(); }
    }

    FileView {
        id: conf
        path: root.confPath
        blockWrites: true
        printErrors: false
    }

    function start() {
        if (proc.running || !root.wanted)
            return;
        conf.setText(root.config);
        proc.running = true;
    }

    onWantedChanged: {
        if (root.wanted) {
            stopDelay.stop();
            root.start();
        } else {
            stopDelay.restart();
        }
    }

    /** Cambiar los fps en caliente: la config sólo se lee al arrancar cava. */
    onFpsChanged: if (proc.running && root.fps > 0) { restartAfterStop.pending = true; proc.running = false; }
    QtObject { id: restartAfterStop; property bool pending: false }

    Timer {
        id: stopDelay
        interval: 3000
        onTriggered: if (!root.wanted) proc.running = false
    }
    /** Con la sesión bloqueada, fuera YA (sin gracia): con el lock no se captura audio. */
    Connections {
        target: Lock
        function onEngagedChanged() { if (Lock.engaged) proc.running = false; }
    }

    Process {
        id: proc
        command: ["cava", "-p", root.confPath]
        environment: ({ PIPEWIRE_PROPS: "{ sumi.visualizer = true }" })
        stdout: SplitParser {
            onRead: (line) => {
                if (!line)
                    return;
                const parts = line.split(";");
                const out = [];
                let peak = 0;
                for (let i = 0; i < root.bars; i++) {
                    const v = Math.min(1, (parseInt(parts[i], 10) || 0) / 1000);
                    out.push(v);
                    if (v > peak)
                        peak = v;
                }
                // En silencio y con las barras ya abajo, no se reasigna nada a 30 Hz.
                if (peak > 0.001 || root.active)
                    root.levels = out;
                if (peak > 0.02) {
                    root.active = true;
                    idle.restart();
                }
            }
        }
        onStarted: healthy.restart()
        onExited: (code) => {
            healthy.stop();
            root.levels = [0, 0, 0, 0];
            if (restartAfterStop.pending) {   // parado a propósito para cambiar los fps
                restartAfterStop.pending = false;
                root.start();
                return;
            }
            if (!root.wanted) {
                root.active = false;
                return;
            }
            // Murió con música sonando: reintento con freno.
            root.failures++;
            if (root.failures >= 5) {
                root.active = false;
                console.warn("cava: keeps exiting (code", code + "); visualizer off until restart");
                return;
            }
            relaunch.restart();
        }
    }

    Timer { id: relaunch; interval: 1500; onTriggered: root.start() }
    /** Diez segundos vivo borran la cuenta de fallos. */
    Timer { id: healthy; interval: 10000; onTriggered: root.failures = 0 }

    /** 1,2 s sin señal: las barras bajan (la pausa entre pistas no las hace parpadear). */
    Timer {
        id: idle
        interval: 1200
        onTriggered: root.active = false
    }

    function summary() {
        return { installed: root.installed, available: root.available, running: proc.running, active: root.active,
                 fps: root.fps, wanted: root.wanted, claims: Object.keys(root.claims).length, failures: root.failures,
                 levels: root.levels.map(function (v) { return Math.round(v * 100) / 100; }) };
    }
}
