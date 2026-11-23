pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

/**
 * Mezclador (Fase 9.e): salidas, entradas y **volumen por aplicacion**.
 *
 * Sustituye a los modulos `pulseaudio` y `pulseaudio/slider` de Waybar y a
 * `rofi/scripts/audio.sh`, y da algo que ninguno de los tres tenia: el volumen
 * de cada aplicacion por separado. `audio.sh` solo sabia hacer una cosa,
 * `wpctl set-default`.
 *
 * `services/Audio` sigue siendo el dueno del sink y el source POR DEFECTO y de
 * la senal que dispara el OSD; esto es la vista completa. No se fusionan
 * porque tienen vidas distintas: Audio esta siempre vivo (lo necesita el OSD),
 * esto solo mientras el mezclador esta abierto.
 *
 * Clasificacion de nodos, comprobada ejecutando (2026-09-08):
 *
 *   Audio/Sink            isSink=true   isStream=false   dispositivo de salida
 *   Audio/Source          isSink=false  isStream=false   dispositivo de entrada
 *   Audio/Source/Virtual  isSink=false  isStream=false   entrada virtual (13C: también cuenta)
 *   Stream/Output/Audio   isSink=true   isStream=true    una app reproduciendo
 *   Stream/Input/Audio    isSink=false  isStream=true    una app capturando
 *
 * Ojo con `isSink` en los streams: para un stream de REPRODUCCION vale `true`,
 * porque alimenta a un sink. No sirve para distinguir dispositivo de stream;
 * para eso esta `isStream`.
 */
Singleton {
    id: root

    // ---- puerta de muestreo, igual que en Sysmon (ADR-14) -------------------

    // Reclamaciones con nombre (fase 6A): el contador podía desincronizarse.
    property var claims: ({})
    readonly property int watchers: Object.keys(root.claims).length
    readonly property bool active: root.watchers > 0
    function claim(who, on) {
        if (!!on === !!root.claims[who]) return;
        const c = Object.assign({}, root.claims);
        if (on) c[who] = true; else delete c[who];
        root.claims = c;
    }

    readonly property var allNodes: Pipewire.nodes ? Pipewire.nodes.values : []

    /**
     * **No hay tracker propio.** `services/Privacy` ya rastrea TODOS los nodos
     * de Pipewire de forma permanente (no puede leer `media.class` de otra
     * manera), asi que `n.properties` y `n.audio` estan poblados con el
     * mezclador cerrado igual que abierto — comprobado el 2026-09-08.
     *
     * Antes habia aqui un `PwObjectTracker { objects: root.active ? allNodes : [] }`
     * "por si Privacy deja de necesitar el suyo". No ahorraba nada (lo decia su
     * propio comentario) y montar/desmontar el tracker de ~100 objetos en CADA
     * apertura congelaba el hilo ~90 ms: al abrir el mezclador con teclado desde
     * reposo, el morph se quedaba trabado ese rato (medido el 2026-09-10, Fase
     * 10.h). Si algun dia Privacy deja de rastrear, se re-anade aqui pero
     * SIEMPRE activo, nunca puerta por apertura.
     *
     * `watchers` / `claim` se quedan: `status()` los publica para
     * comprobar la simetria de abrir y cerrar (12 pares seguidos vuelven a 0).
     */

    function classOf(n) {
        return (n && n.properties) ? String(n.properties["media.class"] || "") : "";
    }

    /**
     * 13A: los nodos de un filtro smart (el EQ) no son ni salidas ni aplicaciones: son
     * parte de la ruta (AudioRoutes.isInternal). Fuera de todas las listas.
     */
    function pick(cls, anyNode) {
        const out = [];
        const list = root.allNodes;
        for (let i = 0; i < list.length; i++) {
            const n = list[i];
            if (n && (n.audio || anyNode) && root.classOf(n) === cls && !AudioRoutes.isInternal(n))
                out.push(n);
        }
        return out;
    }

    readonly property var sinks: root.pick("Audio/Sink")
    /**
     * 13C: también las entradas VIRTUALES (`Audio/Source/Virtual`: el micro de EasyEffects u
     * OBS, una supresión de ruido, una fuente nula). Medido: una de ellas era la entrada
     * predeterminada (el Mixer la enseñaba arriba) y no salía como elegible. Los nodos de un
     * filtro smart siguen fuera (pick → AudioRoutes.isInternal). Sin exigir `audio`: Quickshell
     * 0.3.1 no se la da a esta clase (medido: con `pick` salían 0 de 2), y para elegirla como
     * ruta basta el nodo; su volumen, si no la tiene, se enseña como no disponible.
     */
    readonly property var sources: root.pick("Audio/Source").concat(root.pick("Audio/Source/Virtual", true))
    readonly property var playback: root.pick("Stream/Output/Audio")
    readonly property var capture: root.pick("Stream/Input/Audio")

    readonly property var defaultSink: Pipewire.defaultAudioSink
    readonly property var defaultSource: Pipewire.defaultAudioSource

    /** Nombre legible de un nodo, con el mismo orden de preferencia en todos. */
    function label(n) {
        if (!n) return "";
        if (n.isStream && n.properties) {
            const app = n.properties["application.name"];
            if (app) return String(app);
        }
        return String(n.description || n.nickname || n.name || "");
    }

    /**
     * **El nombre corto, que es el que cabe.**
     *
     * `node.description` es la cadena larga de Pipewire, y en esta máquina mide
     * 51 caracteres: «Navi 31 HDMI/DP Audio Digital Stereo (HDMI) [GS25F2]».
     * En una fila del mezclador de 380 px eso se recortaba siempre —el usuario
     * lo reportó como «los nombres de dispositivo se cortan»— y lo que se perdía
     * era justo el final, que es donde va lo que distingue una salida de otra.
     *
     * El orden de preferencia se invierte respecto de `label()`:
     *
     *   1. `node.nick`, que es el nombre corto que el propio driver ya publica y
     *      que aquí vale «GS25F2» — el modelo del monitor, que es exactamente
     *      como el usuario llama a esa salida. Es también lo que enseña
     *      `wpctl status` entre corchetes.
     *   2. si no hay nick, la descripción **sin la morralla**: el `[...]` final
     *      (que es el nick otra vez), el `(HDMI)`/`(Analog)` del puerto, y el
     *      «Audio Digital Stereo» que repite el mismo tipo de dispositivo en
     *      todas las tarjetas del mundo.
     *   3. y si de ahí no queda nada, la descripción entera antes que un hueco.
     *
     * `label()` NO se toca: la ficha larga sigue haciendo falta para el
     * `Choice` de rutas y para cualquiera que quiera desambiguar.
     */
    function shortLabel(n) {
        if (!n) return "";
        if (n.isStream)
            return root.label(n);
        const nick = String(n.nickname || "");
        if (nick.length > 0)
            return nick;
        const full = String(n.description || n.name || "");
        const trimmed = full
            .replace(/\s*\[[^\]]*\]\s*$/, "")
            .replace(/\s*\([^)]*\)\s*$/, "")
            .replace(/\s+(Audio\s+)?(Digital|Analog)\s+(Stereo|Mono|Surround.*)$/i, "")
            .trim();
        return trimmed.length > 0 ? trimmed : full;
    }

    /**
     * ENRUTADO POR APLICACION (QS-FUNC-011): a que salida va un stream que
     * reproduce, o de que entrada viene uno que captura. Pipewire ya lo cuenta
     * en `linkGroups` y nadie lo leia; con dos salidas era invisible adonde iba
     * cada app. Medido con `mpv` sonando: `alsa_playback.mpv -> Navi 31 HDMI/DP
     * Audio Digital Stereo (HDMI)`, y `g.source === nodo` casa con los objetos de
     * `Pipewire.nodes`.
     *
     * SOLO LECTURA: `PwLink` y `PwLinkGroup` no tienen metodos en el
     * `.qmltypes`. Desde la 13A la lectura completa (efectiva, pedida y
     * recordada) vive en `AudioRoutes`; mover es de la 13B, por los metadatos de
     * WirePlumber. "" si no hay enlace (un stream en pausa puede no tenerlo).
     */

    function routeOf(n) {
        if (!n || !n.isStream)
            return "";
        // 13A: la ruta EFECTIVA atraviesa los filtros smart hasta el dispositivo (una app
        // ecualizada sigue yendo a «GS25F2», no a «Equalizer»). Nombre corto: la ruta es el
        // renglón de apoyo de la fila y la descripción larga de Pipewire no cabía.
        const out = [];
        for (const r of AudioRoutes.effectiveOf(n)) {
            const l = root.shortLabel(r.node);
            if (l.length > 0 && out.indexOf(l) < 0) out.push(l);
        }
        return out.join(", ");
    }

    function isDefaultSink(n) { return n !== null && n === root.defaultSink; }
    function isDefaultSource(n) { return n !== null && n === root.defaultSource; }

    // ---- acciones: lo pedido frente a lo efectivo (fase 6C) ------------------

    /**
     * EL VALOR DEL NODO ES OPTIMISTA. Medido el 2026-09-25 con `qs -p`: escribir
     * `audio.volume` cambia el valor local al instante y Pipewire contesta con un
     * eco POR PETICIÓN, en orden (0.90 → 0.95 → eco 0.90 → eco 0.95: el salto
     * del deslizador hacia atrás). Y escribir el mismo valor, o el mute, no trae
     * eco ninguno. Así que el binding no confirma nada.
     *
     * Cada acción es una petición con revisión en `ops`, por clave:
     *   vol:<id>, mute:<id>   se comprueban con `wpctl get-volume <id>` 250 ms
     *                         después de la ÚLTIMA petición de esa clave
     *                         (arrastrar el deslizador = muchas peticiones, una
     *                         comprobación);
     *   sink, source          por el metadato de Pipewire (`defaultAudioSink`),
     *                         que no es optimista: cambia cuando WirePlumber lo
     *                         aplica. Tiene que sostenerse 600 ms; plazo de 3 s.
     * Si el nodo desaparece antes de comprobarlo, error: una desconexión a mitad
     * no es un éxito.
     */
    readonly property Ops ops: Ops { name: "mixer" }

    function nodeById(id) {
        const list = root.allNodes;
        for (let i = 0; i < list.length; i++)
            if (list[i] && list[i].id === id) return list[i];
        return null;
    }

    /** Lo que se pinta: lo pedido en vuelo; si no, lo que dice el nodo. */
    function shownVolume(n) {
        if (!n || !n.audio) return 0;
        void root.ops.table;
        return root.ops.shown("vol:" + n.id, n.audio.volume);
    }
    function shownMuted(n) {
        if (!n || !n.audio) return false;
        void root.ops.table;
        return root.ops.shown("mute:" + n.id, n.audio.muted);
    }
    /** La última petición de volumen o silencio de este nodo quedó sin aplicar. */
    function failedOn(n) {
        if (!n) return false;
        void root.ops.table;
        return root.ops.stateOf("vol:" + n.id) === "error" || root.ops.stateOf("mute:" + n.id) === "error";
    }

    /** Lo que hacia `audio.sh` con `wpctl set-default`, sin proceso. */
    function setDefaultSink(n) { return root.setDefault("sink", n); }
    function setDefaultSource(n) { return root.setDefault("source", n); }

    function setDefault(kind, n) {
        if (!n) return -1;
        const r = root.ops.request(kind, String(n.name));
        if (kind === "sink") Pipewire.preferredDefaultAudioSink = n;
        else Pipewire.preferredDefaultAudioSource = n;
        defaultDeadline.restart();
        root.checkDefaults("event");
        return r;
    }

    /**
     * `sink`/`source`: el metadato tiene que decir lo pedido Y SOSTENERLO. Medido
     * el 2026-09-25 con un sink nulo de prueba descargado justo después de
     * elegirlo: el metadato llegó a nombrarlo unos milisegundos y la primera
     * versión dio `ok`, con el sink real ya de vuelta en el HDMI. Es el mismo
     * destello que `Bt` caza con su ventana `settle`: aquí, 600 ms.
     *   event     llega un cambio: si coincide, (re)arranca la confirmación
     *   confirm   pasó la ventana: coincide → ok; no → error
     *   deadline  3 s sin coincidir → error
     */
    function checkDefaults(why) {
        const pairs = [["sink", root.defaultSink], ["source", root.defaultSource]];
        for (const [k, cur] of pairs) {
            if (!root.ops.pending(k)) continue;
            const o = root.ops.get(k);
            const got = cur ? String(cur.name) : "";
            if (got === o.requested) {
                if (why === "confirm") root.ops.resolve(k, o.rev, "ok", "", got);
                else if (why === "event" || !defaultConfirm.running) defaultConfirm.restart();
            } else if (why === "confirm" || why === "deadline") {
                root.ops.resolve(k, o.rev, "error",
                    root.nodeByName(o.requested) ? "Pipewire kept " + (got || "none") : "The device went away", got);
            }
        }
        if (!root.ops.pending("sink") && !root.ops.pending("source")) {
            defaultDeadline.stop();
            defaultConfirm.stop();
        }
    }
    onDefaultSinkChanged: root.checkDefaults("event")
    onDefaultSourceChanged: root.checkDefaults("event")
    Timer { id: defaultConfirm; interval: 600; onTriggered: root.checkDefaults("confirm") }
    Timer { id: defaultDeadline; interval: 3000; onTriggered: root.checkDefaults("deadline") }

    function nodeByName(name) {
        const list = root.allNodes;
        for (let i = 0; i < list.length; i++)
            if (list[i] && String(list[i].name) === name) return list[i];
        return null;
    }

    /** `volume` escribe todos los canales; `volumes` es el detalle por canal. */
    function setVolume(n, v) {
        if (!n || !n.audio) return -1;
        const x = Math.max(0, Math.min(1, v));
        const r = root.ops.request("vol:" + n.id, x);
        n.audio.volume = x;
        root.queueVerify("vol:" + n.id);
        return r;
    }

    /**
     * Antes de la fase 14: balance de una salida o entrada ESTÉREO (dos canales, FL y FR). −1 todo
     * a la izquierda, 0 centrado, +1 a la derecha; el canal más alto conserva el volumen y el otro
     * baja. Con otra disposición de canales no se ofrece (no hay una sola «izquierda»).
     */
    function canBalance(n) {
        if (!n || !n.audio || n.isStream) return false;
        const ch = n.audio.channels;
        return ch.length === 2 && ch[0] === PwAudioChannel.FrontLeft && ch[1] === PwAudioChannel.FrontRight;
    }
    function balanceOf(n) {
        if (!root.canBalance(n)) return 0;
        void root.ops.table;
        const pend = root.ops.shown("bal:" + n.id, null);
        if (pend !== null && pend !== undefined) return pend;
        const v = n.audio.volumes;
        const m = Math.max(v[0], v[1]);
        return m > 0 ? Math.round((v[1] - v[0]) / m * 100) / 100 : 0;
    }
    function setBalance(n, b) {
        if (!root.canBalance(n)) return -1;
        const x = Math.round(Math.max(-1, Math.min(1, b)) * 100) / 100;
        const r = root.ops.request("bal:" + n.id, x);
        const v = n.audio.volumes;
        const m = Math.max(v[0], v[1]);
        n.audio.volumes = [m * (x > 0 ? 1 - x : 1), m * (x < 0 ? 1 + x : 1)];
        balanceCheck.restart();
        return r;
    }
    /**
     * Se comprueba por el eco: el valor local es optimista (memoria del proyecto), así que se
     * relee el nodo con `pw-dump` y se compara la proporción de `channelVolumes` (lineales, al
     * cubo de lo que enseña la UI) con la pedida.
     */
    Timer {
        id: balanceCheck
        interval: 300
        onTriggered: {
            for (const k in root.ops.table) {
                if (!k.startsWith("bal:") || !root.ops.pending(k)) continue;
                balanceProc.key = k;
                balanceProc.rev = root.ops.latest(k);
                balanceProc.command = ["timeout", "2", "pw-dump", k.substring(4)];
                balanceProc.running = true;
                return;
            }
        }
    }
    Process {
        id: balanceProc
        property string key: ""
        property int rev: 0
        stdout: StdioCollector { id: balanceOut }
        onExited: (code) => {
            const want = root.ops.get(balanceProc.key).requested;
            let got = null;
            try {
                // `pw-dump <id>` trae también los puertos del nodo, y primero (medido)
                const id = balanceProc.key.substring(4);
                const o = JSON.parse(balanceOut.text).find(x => String(x.id) === id && x.type.endsWith("Node"));
                const cv = o.info.params.Props.find(p => p.channelVolumes).channelVolumes;
                const l = Math.cbrt(cv[0]), r = Math.cbrt(cv[1]), m = Math.max(l, r);
                got = m > 0 ? (r - l) / m : 0;
            } catch (e) {}
            if (got === null) root.ops.resolve(balanceProc.key, balanceProc.rev, "error", "The device went away");
            else if (Math.abs(got - want) <= 0.02) root.ops.resolve(balanceProc.key, balanceProc.rev, "ok", "", Math.round(got * 100) / 100);
            else root.ops.resolve(balanceProc.key, balanceProc.rev, "error", "Pipewire kept another balance", Math.round(got * 100) / 100);
            if (root.ops.pending(balanceProc.key)) balanceCheck.restart();
        }
    }

    function toggleMute(n) {
        if (!n || !n.audio) return -1;
        const want = !root.shownMuted(n);
        const r = root.ops.request("mute:" + n.id, want);
        n.audio.muted = want;
        root.queueVerify("mute:" + n.id);
        return r;
    }

    // ---- comprobación con wpctl ----------------------------------------------

    /** Claves que esperan su comprobación (una por nodo y tipo, sin repetir). */
    property var verifyQueue: []

    function queueVerify(key) {
        if (root.verifyQueue.indexOf(key) < 0) root.verifyQueue = root.verifyQueue.concat([key]);
        verifyDelay.restart();
    }

    Timer {
        id: verifyDelay
        interval: 250
        onTriggered: root.nextVerify()
    }

    function nextVerify() {
        if (verifyProc.running || verifyDelay.running) return;
        while (root.verifyQueue.length > 0) {
            const key = root.verifyQueue[0];
            root.verifyQueue = root.verifyQueue.slice(1);
            if (!root.ops.pending(key)) continue;
            const id = parseInt(key.split(":")[1]);
            const rev = root.ops.latest(key);
            if (!root.nodeById(id)) {
                root.ops.resolve(key, rev, "error", "The device went away");
                continue;
            }
            verifyProc.key = key;
            verifyProc.rev = rev;
            verifyProc.command = ["timeout", "2", "wpctl", "get-volume", String(id)];
            verifyProc.running = true;
            return;
        }
    }

    /** `wpctl get-volume 57` → «Volume: 0.98» o «Volume: 0.98 [MUTED]». */
    Process {
        id: verifyProc
        property string key: ""
        property int rev: 0
        stdout: StdioCollector { id: verifyOut }
        onExited: (code) => {
            const key = verifyProc.key, rev = verifyProc.rev;
            const m = /Volume:\s*([0-9.]+)(\s*\[MUTED\])?/.exec(verifyOut.text || "");
            const n = root.nodeById(parseInt(key.split(":")[1]));
            if (code !== 0 || !m || !n) {
                root.ops.resolve(key, rev, "error", "The device went away");
            } else if (key.startsWith("vol:")) {
                const got = parseFloat(m[1]);
                const want = root.ops.get(key).requested;
                // wpctl imprime dos decimales.
                if (Math.abs(got - want) <= 0.006) root.ops.resolve(key, rev, "ok", "", got);
                else root.ops.resolve(key, rev, "error", "Pipewire kept " + Math.round(got * 100) + " %", got);
            } else {
                const got = !!m[2];
                if (got === root.ops.get(key).requested) root.ops.resolve(key, rev, "ok", "", got);
                else root.ops.resolve(key, rev, "error", got ? "Still muted" : "Still unmuted", got);
            }
            // Si llegó otra petición de esta clave mientras se leía, `resolve` la
            // descartó (vieja) y la clave sigue en vuelo: se vuelve a comprobar.
            if (root.ops.pending(key)) root.queueVerify(key);
            else root.nextVerify();
        }
    }

    /**
     * Acceso por indice, para el IPC. Existe por lo mismo que `trayEnter` en
     * 9.c: sin raton no habia forma de ejercitar "cambiar la salida por
     * defecto", que es un criterio de aceptacion del roadmap. Y de paso un
     * script puede bajar el volumen de una aplicacion concreta, que es algo
     * que ni Waybar ni `audio.sh` sabian hacer.
     */
    function group(kind) {
        if (kind === "sink") return root.sinks;
        if (kind === "source") return root.sources;
        if (kind === "playback") return root.playback;
        if (kind === "capture") return root.capture;
        return [];
    }

    function nodeAt(kind, i) {
        const g = root.group(kind);
        return (i >= 0 && i < g.length) ? g[i] : null;
    }

    /** Para `status()`: la foto completa sin exponer los nodos. */
    function summary() {
        function one(n) {
            return { label: root.label(n),
                     volume: (n && n.audio) ? Math.round(n.audio.volume * 100) : -1,
                     muted: (n && n.audio) ? n.audio.muted : false,
                     isDefault: n === root.defaultSink || n === root.defaultSource,
                     route: root.routeOf(n) };
        }
        return {
            watchers: root.watchers,
            sinks: root.sinks.map(one),
            sources: root.sources.map(one),
            playback: root.playback.map(one),
            capture: root.capture.map(one)
        };
    }
}
