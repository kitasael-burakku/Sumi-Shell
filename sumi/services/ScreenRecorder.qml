pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "../theme"
import "../lib/xdg.js" as Xdg

/**
 * El grabador de pantalla (2026-10-29, pedido del usuario: «una tool rápida», hermana de Wallpapers).
 *
 * Quien graba es `scripts/screen-recorder.py`: wf-recorder supervisado FUERA de la shell, en su propio
 * scope (`Apps.spawn`, como cualquier app), con la pausa por tramos y el guardado al parar. Esto sólo:
 *   · lanza la grabación con lo elegido y la sigue en su archivo de estado
 *     ($XDG_RUNTIME_DIR/sumi-shell/recorder/state.json, escrito por renombrado);
 *   · manda pausar, reanudar, parar o cancelar;
 *   · da el reloj de la grabación a la surface, a la pieza bajo el island y a la barra (UN reloj: nadie cuenta
 *     por su cuenta);
 *   · al arrancar (recarga o reinicio), recupera la grabación viva con su tiempo: el estado lleva
 *     instantes absolutos, no un contador de QML.
 * Igual que `SystemTest` con su guard: si la shell cae, la grabación sigue; al volver, se ve.
 *
 * Segunda entrega (2026-10-29, «empieza por esas 4»): bloquear PAUSA (no se reanuda sola), copiar la
 * grabación al portapapeles como archivo, la GPU codifica cuando puede y en Region un clic elige una ventana.
 *
 * Grabador 2.0 (2026-10-29): la configuración vive en `settings.json` (`Settings.rec*`, catálogo `recorder.*`)
 * y Settings → Screen recording la enseña entera; los chips de la surface editan ESOS valores. `recorder.json`
 * queda como estado de la herramienta (último modo, última grabación, último retardo); la primera vez se pasan
 * a Settings los valores que el usuario había cambiado allí (y el archivo conserva sus claves de antes, para volver
 * atrás). Lo que se grabará (codificador real, fps, tamaño, archivo, avisos) lo resuelve el helper (`plan`), con
 * los MISMOS argumentos que `run` (`argsFor`): la surface y Settings enseñan eso, no una copia de la lógica.
 * Después de grabar: la vista Completed (archivo, duración, tamaño) o Error (qué pasó y, si quedaron tramos,
 * Recover).
 */
Singleton {
    id: root

    readonly property string script: Quickshell.shellPath("scripts/screen-recorder.py")
    readonly property string runDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/sumi-shell/recorder"
    readonly property string stateDir: Xdg.base(Quickshell.env("XDG_STATE_HOME"), Quickshell.env("HOME") + "/.local/state") + "/sumi-shell"

    // ---- pruebas (SÓLO BANCO; IPC `recorderTest`) ------------------------------------------------
    /** Sin scope de systemd (el banco no tiene gestor de usuario): proceso suelto. */
    property bool testDirect: false
    /** La región ya elegida: el banco no puede arrastrar con slurp. */
    property string testGeometry: ""
    /** Otra carpeta de salida (nunca la del usuario). */
    property string testDir: ""
    /** El codificador pedido (gpu: sin la comprobación previa) y otro nodo de render (uno inexistente = volver a x264). */
    property string testEncoder: ""
    property string testVaapiDevice: ""

    // ---- lo elegido: Settings (configuración) y recorder.json (estado de la herramienta) ----------------
    /** screen (esta pantalla entera) · region (slurp) · output (elegir otra pantalla con el ratón). */
    property string mode: "screen"
    readonly property bool systemAudio: Settings.recSystemAudio
    readonly property bool mic: Settings.recMic
    /** standard · high · custom (Custom = lo de Settings → Custom preset). */
    readonly property string preset: Settings.recPreset
    /** Compatibilidad (IPC y bancos de antes): el preset. */
    readonly property string quality: Settings.recPreset
    /** La cuenta atrás: Settings la da en segundos (0 = sin ella); el chip D alterna con la última distinta de 0. */
    readonly property bool delay: Settings.recDelay > 0
    property int lastDelay: 3
    readonly property int delaySec: Settings.recDelay > 0 ? Settings.recDelay : root.lastDelay
    property string lastFile: ""
    property bool prefsLoaded: false

    function setSystemAudio(on) { if (root.systemAvailable) Settings.recSystemAudio = on === true; }
    function setMic(on) { if (root.micAvailable) Settings.recMic = on === true; }
    function setPreset(p) { if (["standard", "high", "custom"].indexOf(p) >= 0) Settings.recPreset = p; }
    function cyclePreset() {
        const l = ["standard", "high", "custom"];
        root.setPreset(l[(l.indexOf(root.preset) + 1) % l.length]);
    }
    function toggleDelay() {
        if (Settings.recDelay > 0) { root.lastDelay = Settings.recDelay; Settings.recDelay = 0; }
        else Settings.recDelay = [3, 5, 10].indexOf(root.lastDelay) >= 0 ? root.lastDelay : 3;
    }

    onModeChanged: root.savePrefs()
    onLastFileChanged: root.savePrefs()
    onLastDelayChanged: root.savePrefs()
    Connections {
        target: Settings
        function onRecDelayChanged() { if (Settings.recDelay > 0) root.lastDelay = Settings.recDelay; }
        // Sin «recordar el modo», cada vez empieza en Full screen (lo guardado se olvida al apagarlo)
        function onRecRememberModeChanged() { if (!Settings.recRememberMode) root.savePrefs(); }
    }

    // ---- qué hay en esta máquina (`probe`) ---------------------------------------------------------
    property var probe: null
    function tool(name) { return !root.probe || root.probe.tools[name] === true; }
    /** Lo que impide grabar, dicho antes de pulsar (como `Wallpaper.whyNot`). */
    readonly property string whyNot: !root.probe ? ""
        : !root.tool("wf-recorder") ? "Install wf-recorder to record the screen"
        : !root.tool("ffmpeg") || !root.tool("ffprobe") ? "Install ffmpeg to record the screen" : ""
    function whyNotMode(m) {
        if (root.whyNot.length > 0) return root.whyNot;
        if ((m === "region" || m === "output") && !root.tool("slurp"))
            return "Install slurp to choose " + (m === "region" ? "a region" : "a screen");
        // la carpeta y lo elegido en Settings que no puede ser (WebM sin AV1…), antes de pulsar
        const dc = root.probe && root.probe.dirCheck ? root.probe.dirCheck : null;
        if (dc && dc.error && root.testDir.length === 0) return dc.error;
        const p = root.planNow;
        if (p && p.error && p.errorKind !== "audio" && root.planMode === m) return p.error;
        return "";
    }
    readonly property bool systemAvailable: !!root.probe && String(root.probe.audio.system).length > 0
    readonly property bool micAvailable: !!root.probe && String(root.probe.audio.mic).length > 0
    readonly property string outputDir: root.testDir.length > 0 ? root.testDir : (root.probe ? root.probe.dir : "")
    /** Los codificadores probados aquí ([{id, label, kind, ok, why, pads}]) y las fuentes de audio con nombre. */
    readonly property var encoders: root.probe && root.probe.encoders ? root.probe.encoders : []
    readonly property var audioSources: root.probe && root.probe.sources ? root.probe.sources : ({ system: [], mic: [] })
    function encoderOk(id) { return root.encoders.some(e => e.id === id && e.ok); }
    /** Lo que se grabará de verdad: un interruptor encendido sin su fuente no cuenta. */
    readonly property string audioArg: {
        const s = root.systemAudio && root.systemAvailable, m = root.mic && root.micAvailable;
        return s && m ? "both" : s ? "system" : m ? "mic" : "none";
    }
    readonly property bool multiScreen: Quickshell.screens.length > 1

    property bool probing: prober.running
    function refreshProbe(fresh) {
        if (prober.running) { root.probeAgain = root.probeAgain || fresh === true; return; }
        const dir = root.testDir.length > 0 ? root.testDir : Settings.recDir;
        prober.command = ["python3", root.script, "probe"].concat(dir.length > 0 ? ["--dir", dir] : [])
            .concat(fresh === true ? ["--fresh"] : []);
        prober.running = true;
    }
    property bool probeAgain: false
    Process {
        id: prober
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.probe = JSON.parse(this.text); } catch (e) { console.warn("recorder: probe unreadable"); }
            }
        }
        onRunningChanged: if (!running && root.probeAgain) { root.probeAgain = false; Qt.callLater(() => root.refreshProbe(true)); }
    }
    // La carpeta cambió en Settings: lo que se dice de ella (permisos, espacio) se vuelve a mirar
    Timer { id: probeSoon; interval: 400; onTriggered: root.refreshProbe() }
    Connections {
        target: Settings
        function onRecDirChanged() { probeSoon.restart(); }
    }

    // ---- el plan: lo que se grabará (lo resuelve el helper) ---------------------------------------------
    /**
     * Los argumentos de `run` y de `plan`, los mismos: lo que la surface enseña es lo que se graba. `m` el modo,
     * `screenName` la pantalla de Full screen.
     */
    function argsFor(m, screenName) {
        const a = ["--mode", m, "--audio", root.audioArg, "--preset", Settings.recPreset,
                   "--encoder", root.testEncoder.length > 0 ? root.testEncoder : Settings.recEncoder,
                   "--fps", String(Settings.recFps), "--rate-control", Settings.recQuality, "--bitrate", String(Settings.recBitrate),
                   "--height", String(Settings.recHeight), "--format", Settings.recFormat,
                   "--system-source", Settings.recSystemSource, "--mic-source", Settings.recMicSource,
                   "--audio-codec", Settings.recAudioCodec, "--audio-bitrate", String(Settings.recAudioBitrate),
                   "--sample-rate", String(Settings.recSampleRate), "--name", Settings.recName,
                   "--delay", String(Settings.recDelay)];
        const dir = root.testDir.length > 0 ? root.testDir : Settings.recDir;
        if (dir.length > 0) a.push("--dir", dir);
        if (m === "screen") a.push("--output", String(screenName || ""));
        if (m === "region" && root.testGeometry.length > 0) a.push("--geometry", root.testGeometry);
        if (root.testVaapiDevice.length > 0) a.push("--vaapi-device", root.testVaapiDevice);
        return a;
    }
    /** El plan que se mira (surface o Settings): su pantalla y su modo. "" = nadie lo pide. */
    property string planScreen: ""
    property string planMode: root.mode
    property var plan: null
    readonly property string planKey: root.planScreen.length === 0 || !root.probe ? ""
        : JSON.stringify(root.argsFor(root.planMode, root.planScreen))
    /** Los argumentos con los que se calculó `plan`. */
    property string planDoneKey: ""
    /**
     * El plan SÓLO si es el de lo que se grabaría ahora (mismos argumentos). Medido en el banco: cerrada la surface,
     * el plan viejo (WebM imposible) seguía ahí y bloqueaba un arranque válido con MP4.
     */
    readonly property var planNow: root.planKey.length > 0 && root.planDoneKey === root.planKey ? root.plan : null
    onPlanKeyChanged: if (root.planKey.length > 0) planSoon.restart()
    function wantPlan(screenName, m) {
        root.planScreen = String(screenName || "");
        root.planMode = m || root.mode;
        if (root.planKey.length > 0) planSoon.restart();
    }
    Timer {
        id: planSoon
        interval: 120
        onTriggered: {
            if (planner.running) { restart(); return; }
            planner.key = root.planKey;
            planner.command = ["python3", root.script, "plan"].concat(root.argsFor(root.planMode, root.planScreen));
            planner.running = true;
        }
    }
    Process {
        id: planner
        property string key: ""
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.plan = JSON.parse(this.text); } catch (e) { root.plan = null; }
                root.planDoneKey = planner.key;
            }
        }
    }
    /** «1920×1080 · 30 fps · H.264 (GPU) · MP4 · AAC 160 kb/s» de un plan o de los `params` de una grabación. */
    function specOf(p, withAudio) {
        if (!p || !p.encoder) return "";
        const sz = p.size && p.size[0] > 0 ? p.size[0] + "×" + p.size[1] + " · " : "";
        const q = p.quality === "bitrate" ? p.value + " Mb/s · " : "";
        const audio = withAudio !== false && p.audio && p.audio !== "none"
            ? " · " + (p.audioCodec === "opus" ? "Opus " : "AAC ") + p.audioBitrate + " kb/s" : "";
        return sz + p.fps + " fps · " + q + p.encoderLabel + " · " + (({ mp4: "MP4", mkv: "MKV", webm: "WebM" })[p.format] || p.format) + audio;
    }
    readonly property string presetName: ({ standard: "Standard", high: "High", custom: "Custom" })[root.preset] || root.preset

    // ---- la grabación ------------------------------------------------------------------------------
    /** El JSON del supervisor que se sigue (o el último, ya terminado). */
    property var st: null
    readonly property var liveStates: ["selecting", "countdown", "starting", "recording", "paused", "saving"]
    /** El token de la grabación que lanzó esta shell y aún no ha escrito su estado. */
    property string pendingToken: ""
    property double pendingSince: 0
    /**
     * idle · selecting · countdown · starting · recording · paused · saving. Lanzada y aún sin estado
     * propio = starting (el supervisor tarda unas décimas en escribir).
     */
    readonly property string status: root.pendingToken.length > 0 ? "starting"
        : root.st && root.liveStates.indexOf(root.st.state) >= 0 ? root.st.state : "idle"
    readonly property bool active: root.status !== "idle"
    /** Hay vídeo: grabando o en pausa. */
    readonly property bool live: root.status === "recording" || root.status === "paused"
    readonly property bool paused: root.status === "paused"
    /** Antes de que haya vídeo (lo que Cancel deshace sin perder nada). */
    readonly property bool preparing: ["selecting", "countdown", "starting"].indexOf(root.status) >= 0
    /** La pantalla se está capturando AHORA (la barra no repite su aviso de privacidad «Screen»). */
    readonly property bool capturing: root.status === "recording"

    property double now: Date.now()
    readonly property int elapsedMs: !root.st || !root.live ? 0
        : (root.st.elapsedMs || 0) + (root.status === "recording" && root.st.segmentStart > 0
            ? Math.max(0, root.now - root.st.segmentStart) : 0)
    readonly property string clock: root.fmt(root.elapsedMs)
    readonly property int countdown: root.status === "countdown" && root.st
        ? Math.max(1, Math.ceil((root.st.countdownUntil - root.now) / 1000)) : 0
    function fmt(ms) {
        const t = Math.floor(Math.max(0, ms) / 1000), h = Math.floor(t / 3600), m = Math.floor(t / 60) % 60, s = t % 60;
        const two = (n) => (n < 10 ? "0" : "") + n;
        return (h > 0 ? h + ":" + two(m) : two(m)) + ":" + two(s);
    }
    function fmtBytes(b) {
        if (!(b > 0)) return "";
        if (b >= 1073741824) return (b / 1073741824).toFixed(2) + " GB";
        if (b >= 1048576) return (b / 1048576).toFixed(1) + " MB";
        return Math.max(1, Math.round(b / 1024)) + " KB";
    }
    /** Una línea para el HUD y los nombres accesibles. */
    readonly property string statusText: root.status === "selecting" ? (root.st && root.st.mode === "output" ? "Click a screen" : "Drag an area or click a window")
        : root.status === "countdown" ? "Starting in " + root.countdown
        : root.status === "starting" ? "Starting…"
        : root.status === "recording" ? "Recording " + root.clock
        : root.status === "paused" ? "Paused " + root.clock
        : root.status === "saving" ? "Saving…"
        : "Ready"

    /**
     * El resultado de la última, unos segundos en el HUD (después desaparece: no invasivo). La surface
     * lo sigue diciendo en su pie hasta la siguiente grabación.
     */
    property string flashText: ""
    property string flashTone: ""
    /** La frase entera para el pie de la surface («Saved · archivo», «Copied · archivo»); "" = lo de siempre. */
    property string flashDetail: ""
    readonly property bool flashing: root.flashText.length > 0
    Timer { id: flashTimer; interval: 4000; onTriggered: { root.flashText = ""; root.flashTone = ""; root.flashDetail = ""; } }
    function flash(text, tone, detail) {
        root.flashText = text;
        root.flashTone = tone;
        root.flashDetail = detail || "";
        if (!root.flashHeld) flashTimer.restart();
    }
    /**
     * Con el puntero encima (la pieza o el tramo de la barra) o el foco de teclado en ese tramo, el aviso no se
     * va: ahí está Copy y 4 s no dan para llegar. Al soltarlo todo, otros 4 s. `src`: quién lo sostiene.
     */
    property var flashHolds: ({})
    readonly property bool flashHeld: Object.keys(root.flashHolds).some(k => root.flashHolds[k])
    function holdFlash(src, on) {
        const h = Object.assign({}, root.flashHolds);
        h[src] = on === true;
        root.flashHolds = h;
        if (root.flashHeld) { flashTimer.stop(); holdCap.restart(); }
        else if (root.flashing) flashTimer.restart();
    }
    /** Por si quien lo sostiene desaparece sin soltarlo (una pantalla que se va con el puntero encima). */
    Timer {
        id: holdCap
        interval: 30000
        onTriggered: { root.flashHolds = ({}); if (root.flashing) flashTimer.restart(); }
    }

    /** Hay una grabación terminada que copiar (sólo con el aviso de «guardada»/«copiada», o en la surface). */
    readonly property bool canCopy: root.lastFile.length > 0 && root.tool("wl-copy")
    /** Recién guardada o copiada: la pieza y la barra ofrecen Copy mientras dura el aviso. */
    readonly property bool offerCopy: !root.active && root.flashing && root.flashTone === "ok" && root.canCopy
    /**
     * Al portapapeles como ARCHIVO (text/uri-list): pegarla en un chat o en un gestor de archivos. Lo hace el
     * helper (comprueba que siga ahí); wl-copy se queda sirviendo la selección hasta que otro copie algo.
     * `copyPath`: la ruta como texto (Completed → Copy path).
     */
    function copyLast() { return root.copyAs("uri"); }
    function copyPath() { return root.copyAs("path"); }
    function copyAs(how) {
        if (!root.canCopy || copier.running) return false;
        copier.how = how;
        copier.command = ["python3", root.script, "copy", root.lastFile, "--as", how];
        copier.running = true;
        return true;
    }
    Process {
        id: copier
        property string how: "uri"
        stdout: StdioCollector {
            onStreamFinished: {
                let r = null;
                try { r = JSON.parse(this.text); } catch (e) { r = null; }
                if (r && r.ok) root.flash("Copied", "ok", (copier.how === "path" ? "Path copied · " : "Copied · ") + root.baseName(root.lastFile));
                else root.flash("Copy failed", "warn", "Couldn't copy · " + (r && r.error ? r.error : "wl-copy failed"));
            }
        }
    }
    /** El último error (texto completo) hasta la siguiente grabación. */
    property string lastError: ""
    /** Su tipo (del helper): tools · encoder · format · folder · space · audio · screen · nothing · interrupted · save · failed. */
    property string lastErrorKind: ""
    /** La carpeta de tramos que quedó (supervisor muerto, guardado fallido): Recover la une. */
    property string recoverWork: ""
    property string lastNote: ""
    /** warn: guardada con un problema (micro sin pista, cortada antes); info: cancelada. */
    property string lastNoteTone: "info"

    /** Qué se graba y con qué audio, en palabras (la surface y los nombres accesibles). */
    readonly property string targetLabel: {
        if (!root.st) return "";
        const g = String(root.st.target || "").match(/ (\d+x\d+)$/);
        const what = root.st.window ? "Window · " + root.st.window : "Region";
        return root.st.mode === "region" ? what + (g ? " · " + g[1].replace("x", "×") : "") : String(root.st.target || "Screen");
    }
    readonly property string audioLabel: {
        const a = root.st && root.active ? root.st.audio : root.audioArg;
        return a === "both" ? "System audio + mic" : a === "system" ? "System audio" : a === "mic" ? "Mic" : "No audio";
    }

    // ---- después de grabar: Completed y Error ----------------------------------------------------------
    /** La última terminada bien: { file, bytes, durationMs, note, params } (Completed en la surface). */
    property var result: null
    /**
     * La surface enseña Completed / Error hasta «New recording», Dismiss o cerrarla después de verlo. Completed caduca
     * a los 5 minutos: abrir el grabador mucho después de parar desde la pieza es para grabar otra (sin tecla extra).
     */
    property bool showResult: false
    property double resultAt: 0
    function resultFresh() { return root.showResult && Date.now() - root.resultAt < 300000; }
    property bool showError: false
    function dismissResult() { root.showResult = false; }
    function dismissError() {
        root.showError = false;
        root.lastError = "";
        root.lastErrorKind = "";
        root.recoverWork = "";
    }
    /** Una frase corta por tipo de error: lo que pasó, sin la jerga de wf-recorder (el detalle va debajo). */
    function errorTitle(kind) {
        return ({ tools: "The recorder is not installed", encoder: "The video encoder failed",
                  format: "That format can't hold this video", folder: "Can't write to the folder",
                  space: "Not enough free space", audio: "An audio device is missing", screen: "Nothing to record",
                  nothing: "Nothing was recorded", interrupted: "The recording was interrupted",
                  save: "The file could not be finished", failed: "Recording failed" })[kind] || "Recording failed";
    }
    readonly property bool canRecover: root.recoverWork.length > 0 && !recoverer.running
    function recover() {
        if (!root.canRecover) return false;
        recoverer.command = ["python3", root.script, "recover", "--work", root.recoverWork];
        recoverer.running = true;
        return true;
    }
    readonly property bool recovering: recoverer.running
    Process {
        id: recoverer
        stdout: StdioCollector {
            onStreamFinished: {
                let r = null;
                try { r = JSON.parse(this.text); } catch (e) { r = null; }
                if (r && r.ok) {
                    root.dismissError();
                    root.lastFile = r.file;
                    root.result = { file: r.file, bytes: r.bytes || 0, durationMs: r.durationMs || 0,
                                    note: r.note || "Recovered from its parts", params: root.st ? root.st.params || {} : {} };
                    root.showResult = true;
                    root.resultAt = Date.now();
                    root.flash("Recovered", "ok", "Recovered · " + root.baseName(r.file));
                    root.notice("Recording recovered · " + root.baseName(r.file), "check-circle", "ok");
                    stateFile.reload();
                } else {
                    root.lastError = r && r.error ? r.error : "Could not recover the recording";
                    if (r && r.kind) root.lastErrorKind = r.kind;
                    root.flash("Recover failed", "danger");
                }
            }
        }
    }

    /** Lo dice el island (core/Osd). */
    signal notice(string text, string glyph, string tone)

    function baseName(p) { return String(p || "").replace(/^.*\//, ""); }

    /**
     * Grabar. `screenName`: la pantalla de «Full screen» (la de la surface). La surface se cierra
     * antes: el supervisor arranca 450 ms después, para que el panel no salga en el vídeo ni tape a
     * slurp, que necesita el teclado y el puntero.
     */
    function start(m, screenName) {
        if (root.active || Lock.engaged) return false;
        const why = root.whyNotMode(m);
        if (why.length > 0) { root.lastError = why; root.flash(why, "warn"); return false; }
        if (m === "screen" && String(screenName || "").length === 0) return false;
        const token = Date.now().toString(36) + Math.floor(Math.random() * 0x100000).toString(36);
        const argv = ["python3", root.script, "run", "--token", token].concat(root.argsFor(m, screenName));
        root.dismissError();
        root.showResult = false;
        root.lastNote = "";
        root.endNote = "";
        root.flashText = "";
        root.flashDetail = "";
        root.pausedByLock = false;
        root.lastMode = m;
        root.lastScreen = String(screenName || "");
        root.pendingToken = token;
        root.pendingSince = Date.now();
        launch.argv = argv;
        launch.interval = Motion.off ? 50 : 450;
        launch.restart();
        return true;
    }
    /** Para «Try again» después de un error: lo mismo que la última vez. */
    property string lastMode: "screen"
    property string lastScreen: ""
    function retry(screenName) {
        root.dismissError();
        return root.start(root.lastMode, root.lastMode === "screen" ? (screenName || root.lastScreen) : screenName);
    }
    Timer {
        id: launch
        property var argv: []
        onTriggered: {
            if (root.testDirect) Quickshell.execDetached(launch.argv);
            else Apps.spawn(launch.argv, "recorder");
        }
    }

    function togglePause() { return root.paused ? root.control("resume") : root.status === "recording" ? root.control("pause") : false; }
    function stop() { return root.live ? root.control("stop") : root.preparing ? root.cancel() : false; }
    function cancel() {
        // lanzada pero el supervisor aún no ha escrito: se anula antes de que empiece
        if (root.pendingToken.length > 0 && launch.running) {
            launch.stop();
            root.pendingToken = "";
            root.lastNote = root.endNote.length > 0 ? root.endNote : "Cancelled";
            root.lastNoteTone = "info";
            root.endNote = "";
            root.flash(root.lastNote === "Cancelled" ? "Recording cancelled" : root.lastNote, "info");
            return true;
        }
        // ya lanzado y sin estado todavía: se cancela en cuanto lo escriba (`took`)
        if (root.pendingToken.length > 0) { root.cancelPending = true; return true; }
        return root.control("cancel");
    }
    property bool cancelPending: false
    /** pause · resume · stop · cancel: una a la vez (el botón espera a la respuesta). */
    property string requested: ""
    function control(verb) {
        if (controller.running || !root.active) return false;
        // con la sesión bloqueada no se reanuda (ni por IPC): lo que se vería es el Lock
        if (verb === "resume" && Lock.engaged) return false;
        if (verb === "resume") root.pausedByLock = false;
        root.requested = verb;
        controller.command = ["python3", root.script, verb];
        controller.running = true;
        return true;
    }
    Process {
        id: controller
        stdout: StdioCollector {
            onStreamFinished: {
                let r = null;
                try { r = JSON.parse(this.text); } catch (e) { r = null; }
                if (!r || !r.ok) console.warn("recorder:", root.requested, r && r.error ? r.error : "failed");
                root.requested = "";
                stateFile.reload();
            }
        }
        onRunningChanged: if (!running && root.requested.length > 0) root.requested = ""
    }

    /**
     * La pantalla que se graba desapareció (desenchufada, apagada): wf-recorder se queda esperando
     * fotogramas que no llegan y no sale (medido en el banco). Se para y se guarda lo que haya, y se dice.
     * En pausa no hace falta: reanudar falla al no encontrar la salida y el supervisor guarda solo.
     */
    property string endNote: ""
    function targetGone() {
        if (!root.st || root.status !== "recording") return false;
        const list = Quickshell.screens;
        const g = String(root.st.target || "").match(/^(-?\d+),(-?\d+) /);
        for (let i = 0; i < list.length; i++) {
            const sc = list[i];
            if (root.st.mode !== "region" ? sc.name === root.st.target
                    : g && +g[1] >= sc.x && +g[1] < sc.x + sc.width && +g[2] >= sc.y && +g[2] < sc.y + sc.height)
                return false;
        }
        return true;
    }
    Connections {
        target: Quickshell
        function onScreensChanged() {
            if (!root.targetGone()) return;
            root.endNote = "The recorded screen was disconnected";
            root.control("stop");
        }
    }

    /**
     * Bloquear PAUSA (segunda entrega): antes la grabación seguía y el Lock salía en el vídeo. No se reanuda sola
     * al desbloquear: la pieza dice «Paused» y el island lo cuenta, y reanudar es decisión del usuario. Preparando
     * (región, cuenta atrás) se cancela: aún no hay nada. Suspender pasa antes por el Lock en esta sesión (Power
     * bloquea primero; hypridle `inhibit_sleep = 3`), así que esto cubre también la suspensión; una suspensión sin
     * Lock (o un Lock que no es el de la shell, p. ej. hyprlock de rescate) no se ve desde aquí.
     *
     * Un reloj y no un solo intento: si en ese instante hay otra orden en curso (`controller`), se repite hasta que
     * el estado cambie. Lo que se cuela en el vídeo es lo que tarda la pausa (medido en el banco).
     */
    property bool pausedByLock: false
    onLiveChanged: if (!root.live) root.pausedByLock = false
    /** La grabación ya cancelada por el Lock: una sola orden (el estado tarda unas décimas en llegar). */
    property string lockCancelled: ""
    Timer {
        interval: 200
        repeat: true
        triggeredOnStart: true
        running: Lock.engaged && (root.status === "recording" || root.preparing)
        onTriggered: {
            const token = root.pendingToken.length > 0 ? root.pendingToken : root.st ? String(root.st.token || "") : "";
            if (root.status === "recording") {
                if (root.control("pause")) root.pausedByLock = true;
            } else if (root.preparing && root.lockCancelled !== token) {
                // la nota sólo si la orden salió: si no, se quedaría para la grabación siguiente
                const was = root.endNote;
                root.endNote = "Cancelled: the screen was locked";
                if (root.cancel()) root.lockCancelled = token;
                else root.endNote = was;
            }
        }
    }
    Connections {
        target: Lock
        function onEngagedChanged() {
            if (!Lock.engaged && root.pausedByLock && root.paused)
                root.notice("Recording paused while locked", "pause", "warn");
        }
    }

    // ---- seguir el estado --------------------------------------------------------------------------
    FileView {
        id: stateFile
        path: root.runDir + "/state.json"
        printErrors: false
        onLoaded: root.took(stateFile.text())
    }
    // El supervisor escribe por renombrado (el vigilante perdería el archivo nuevo): se relee con un reloj
    // mientras hay algo vivo, como `SystemTest`. Un archivo de ~1 KB en tmpfs; también mueve el reloj.
    Timer {
        id: poll
        interval: 250
        repeat: true
        running: root.active
        onTriggered: {
            root.now = Date.now();
            stateFile.reload();
            if (root.pendingToken.length > 0 && !launch.running && Date.now() - root.pendingSince > 6000) {
                root.pendingToken = "";
                root.cancelPending = false;
                root.lastError = "The recorder did not start";
                root.lastErrorKind = "failed";
                root.showError = true;
                root.flash("Recording failed", "danger");
                root.notice("Recording failed · the recorder did not start", "alert", "danger");
            }
        }
    }
    // Si el supervisor muere sin escribir (SIGKILL), `status` lo comprueba por su PID y corrige el estado.
    Timer {
        interval: 5000
        repeat: true
        running: root.active && root.pendingToken.length === 0
        onTriggered: if (!checker.running) checker.running = true
    }
    Process {
        id: checker
        command: ["python3", root.script, "status"]
        stdout: StdioCollector { onStreamFinished: stateFile.reload() }
    }

    /** El token que esta shell sigue: lo que termine con otro (de antes) no se anuncia. */
    property string followToken: ""
    function took(text) {
        let t = null;
        try { t = JSON.parse(text); } catch (e) { return; }
        if (!t || typeof t.state !== "string") return;
        if (root.pendingToken.length > 0) {
            if (t.token !== root.pendingToken) return;      // el estado viejo de la anterior
            root.followToken = root.pendingToken;
            root.pendingToken = "";
            if (root.cancelPending) {
                root.cancelPending = false;
                Qt.callLater(() => root.control("cancel"));
            }
        }
        // el estado de antes DE ESTA grabación: una nueva que falla al momento pasa de «error» (la anterior) a «error»
        // sin que el sondeo vea su «starting» (medido en el banco con «Try again»), y aun así hay que anunciarla
        const was = root.st && root.st.token === t.token ? root.st.state : "";
        root.now = Date.now();
        root.st = t;
        if (t.state === was || t.token !== root.followToken) return;
        if (t.state === "done") root.finished(t);
        else if (t.state === "error") root.failed(t);
        else if (t.state === "cancelled") {
            root.lastNote = root.endNote.length > 0 ? root.endNote : t.note || "Cancelled";
            root.endNote = "";
            root.lastNoteTone = "info";
            root.flash(root.lastNote, "info");
        }
        if (root.liveStates.indexOf(t.state) >= 0 && was !== t.state) console.info("recorder:", t.state);
    }
    function finished(t) {
        if (!t.note && root.endNote.length > 0) t.note = root.endNote;
        root.endNote = "";
        root.lastFile = t.file || "";
        root.lastNote = t.note || "";
        root.lastNoteTone = "warn";
        root.result = { file: t.file || "", bytes: t.bytes || 0, durationMs: t.durationMs || 0, note: t.note || "",
                        params: t.params || {} };
        root.showResult = true;
        root.resultAt = Date.now();
        root.flash("Saved", t.note ? "warn" : "ok", t.note ? "" : "Saved · " + root.baseName(t.file));
        root.notice((t.note ? "Recording saved · " + t.note : "Recording saved · " + root.baseName(t.file)), "check-circle", t.note ? "warn" : "ok");
        Activity.record({ kind: "screen-recording", label: "Screen recording", result: "succeeded",
                          summary: (t.file || "") + (t.note ? " · " + t.note : "") });
        // Settings → Behavior: una notificación (por el servidor de la shell) y abrir la carpeta
        if (Settings.recNotify && root.tool("notify-send")) {
            const parts = [root.fmt(t.durationMs || 0), root.fmtBytes(t.bytes || 0)].filter(x => x.length > 0);
            notifier.command = ["notify-send", "--app-name=Screen recorder", "--icon=video-x-generic",
                                t.note ? "Recording saved with a note" : "Recording saved",
                                root.baseName(t.file) + " · " + parts.join(" · ") + (t.note ? "\n" + t.note : "")];
            notifier.running = true;
        }
        if (Settings.recOpenFolder) root.openFolder();
    }
    function failed(t) {
        root.lastError = t.error || "Recording failed";
        root.lastErrorKind = t.errorKind || "failed";
        root.recoverWork = t.recoverable && t.work ? t.work : "";
        root.showError = true;
        root.showResult = false;
        root.flash("Recording failed", "danger");
        root.notice("Recording failed · " + root.errorTitle(root.lastErrorKind), "alert", "danger");
        Activity.record({ kind: "screen-recording", label: "Screen recording", result: "failed", summary: root.lastError });
    }
    Process { id: notifier }

    // ---- al arrancar: la grabación que siga viva (recarga o reinicio de la shell) -----------------
    Component.onCompleted: { atStart.running = true; root.refreshProbe(); }
    Process {
        id: atStart
        command: ["python3", root.script, "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                let t = null;
                try { t = JSON.parse(this.text); } catch (e) { t = null; }
                if (!t || typeof t.state !== "string" || t.state === "idle") return;
                if (root.liveStates.indexOf(t.state) >= 0) {
                    root.followToken = t.token || "";
                    console.info("recorder: recovered", t.state);
                } else if (t.state === "error" && t.errorKind === "interrupted" && t.recoverable && t.work) {
                    // murió mientras la shell no estaba (o con ella): quedaron tramos que unir
                    root.lastError = t.error || "";
                    root.lastErrorKind = "interrupted";
                    root.recoverWork = t.work;
                    root.showError = true;
                }
                root.st = t;
                root.now = Date.now();
            }
        }
    }

    // ---- abrir lo grabado --------------------------------------------------------------------------
    function openFolder() {
        const d = root.probe && !root.probe.dirExists && root.testDir.length === 0
            ? String(root.outputDir).replace(/\/[^/]*$/, "") : root.outputDir;
        if (d.length === 0) return false;
        Apps.spawn(["xdg-open", d], "xdg-open");
        return true;
    }
    function openLast() {
        if (root.lastFile.length === 0) return false;
        Apps.spawn(["xdg-open", root.lastFile], "xdg-open");
        return true;
    }

    // ---- recorder.json: estado de la herramienta (y la migración v1 → v2) ------------------------------
    /** Lo leído de un recorder.json v1 que aún no pasó a Settings (null = nada que pasar). */
    property var legacy: null
    /** Las claves del archivo tal cual: se conservan al reescribirlo (volver atrás a la segunda entrega las lee). */
    property var fileKeys: ({})
    readonly property bool migrateReady: root.prefsLoaded && Settings.loaded && root.legacy !== null
    onMigrateReadyChanged: if (root.migrateReady) Qt.callLater(root.migrate)
    /**
     * v1 → Settings, una vez: sólo lo que el usuario había cambiado (lo que difiere del default) y sólo si el
     * ajuste sigue en su default. `encoder: cpu` (la vía de escape sin UI) = el preset Custom con x264 y lo que
     * tenía su calidad. Settings sin poder escribir (versión futura, conflicto): se deja para otra vez.
     */
    function migrate() {
        const o = root.legacy;
        if (!o || !Settings.writable) return;
        const fresh = (p) => !Settings.isCustom(p);
        if (o.systemAudio === false && fresh("recSystemAudio")) Settings.recSystemAudio = false;
        if (o.mic === true && fresh("recMic")) Settings.recMic = true;
        if (o.delay === false && fresh("recDelay")) Settings.recDelay = 0;
        if (o.encoder === "cpu" && fresh("recPreset")) {
            Settings.recPreset = "custom";
            Settings.recEncoder = "libx264";
            Settings.recQuality = o.quality === "high" ? "high" : "balanced";
            Settings.recFps = o.quality === "high" ? 60 : 30;
        } else if (o.quality === "high" && fresh("recPreset")) Settings.recPreset = "high";
        root.legacy = null;
        root.imported = true;
        console.info("recorder: preferences moved to Settings");
        root.savePrefs();
    }
    property bool imported: false
    function savePrefs() {
        if (!root.prefsLoaded) return;      // nunca pisar un archivo que aún no se leyó
        // las claves de la segunda entrega siguen escritas con lo de ahora: volver atrás conserva lo elegido
        const o = Object.assign({}, root.fileKeys, {
            version: 2, settingsImported: root.imported || root.legacy === null,
            mode: Settings.recRememberMode ? root.mode : "screen", lastFile: root.lastFile, lastDelay: root.lastDelay,
            systemAudio: Settings.recSystemAudio, mic: Settings.recMic,
            quality: Settings.recPreset === "high" ? "high" : "standard", delay: Settings.recDelay > 0,
            encoder: Settings.recPreset === "custom" && Settings.recEncoder === "libx264" ? "cpu" : "auto" });
        if (root.legacy !== null) o.settingsImported = false;   // aún sin pasar: la próxima vez se intenta
        prefs.setText(JSON.stringify(o, null, 1) + "\n");
    }
    // Lo que se escribe en recorder.json como espejo de Settings (para volver atrás) se guarda al cambiar
    Connections {
        target: Settings
        function onRecSystemAudioChanged() { root.mirrorSoon(); }
        function onRecMicChanged() { root.mirrorSoon(); }
        function onRecPresetChanged() { root.mirrorSoon(); }
        function onRecEncoderChanged() { root.mirrorSoon(); }
        function onRecDelayChanged() { root.mirrorSoon(); }
    }
    function mirrorSoon() { if (root.prefsLoaded && Settings.loaded && root.legacy === null) mirror.restart(); }
    Timer { id: mirror; interval: 500; onTriggered: root.savePrefs() }
    /** Sólo la shell escribe; no se vigila (como `WallpaperMeta`). */
    FileView {
        id: prefs
        path: root.stateDir + "/recorder.json"
        blockLoading: true
        printErrors: false
        onLoaded: {
            try {
                const o = JSON.parse(prefs.text());
                if (o && typeof o === "object" && !Array.isArray(o)) {
                    root.fileKeys = o;
                    if (["screen", "region", "output"].indexOf(o.mode) >= 0) root.mode = o.mode;
                    if (typeof o.lastFile === "string" && o.lastFile.length < 4096) root.lastFile = o.lastFile;
                    if ([3, 5, 10].indexOf(o.lastDelay) >= 0) root.lastDelay = o.lastDelay;
                    if (o.settingsImported !== true) root.legacy = o;
                    else root.imported = true;
                }
            } catch (e) {
                console.warn("recorder: recorder.json unreadable, using defaults:", e);
            }
            root.prefsLoaded = true;
            if (!Settings.recRememberMode) root.mode = "screen";
        }
        // sin archivo: los valores por defecto; se escribe al primer cambio (escribir desde aquí, en la misma
        // FileView, deja «operation finished from dropped operation» en el registro)
        onLoadFailed: { root.imported = true; root.prefsLoaded = true; }
    }

    /** Para el IPC (`recorder`). */
    function summary() {
        return { status: root.status, clock: root.clock, elapsedMs: root.elapsedMs, countdown: root.countdown,
                 mode: root.mode, systemAudio: root.systemAudio, mic: root.mic, quality: root.quality, preset: root.preset,
                 delay: root.delay, delaySec: root.delaySec, recDelay: Settings.recDelay,
                 audio: root.audioArg, systemAvailable: root.systemAvailable, micAvailable: root.micAvailable,
                 whyNot: root.whyNot, outputDir: root.outputDir, lastFile: root.lastFile, lastError: root.lastError,
                 lastErrorKind: root.lastErrorKind, recoverWork: root.recoverWork, showError: root.showError,
                 showResult: root.showResult, result: root.result, recovering: root.recovering,
                 lastNote: root.lastNote, flash: root.flashText, flashTone: root.flashTone, flashDetail: root.flashDetail,
                 flashHeld: root.flashHeld, requested: root.requested, encoderPref: Settings.recEncoder,
                 canCopy: root.canCopy, offerCopy: root.offerCopy, pausedByLock: root.pausedByLock,
                 target: root.st ? root.st.target || "" : "", token: root.st ? root.st.token || "" : "",
                 window: root.st ? root.st.window || "" : "", encoder: root.st ? root.st.encoder || "" : "",
                 params: root.st ? root.st.params || {} : {}, warnings: root.st ? root.st.warnings || [] : [],
                 targetLabel: root.targetLabel, file: root.st ? root.st.file || "" : "",
                 plan: root.planNow ? { error: root.planNow.error, errorKind: root.planNow.errorKind, warnings: root.planNow.warnings,
                                        encoder: root.planNow.encoder, fps: root.planNow.fps, size: root.planNow.size,
                                        format: root.planNow.format, file: root.planNow.file, spec: root.specOf(root.planNow) } : null,
                 planMode: root.planMode, planScreen: root.planScreen, imported: root.imported,
                 encoders: root.encoders.map(e => e.id + (e.ok ? "" : "!") + (e.pads ? "~" : "")) };
    }
}
