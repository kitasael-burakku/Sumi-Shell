import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "components"
import "lock"
import "services"
import "theme"

/**
 * VISTA PREVIA DE LA PANTALLA DE BLOQUEO (docs/lock/COMPONENTES.md §6).
 *
 * NO BLOQUEA NADA Y NO USA PAM. Monta `lock/LockBoardSurface` —la misma pieza que usa
 * el lock real— sobre un CONTEXTO FALSO que implementa el contrato de ESTADO.md §7.
 * Lo tecleado no va a ninguna parte, y la energía y la música sólo se anotan en el
 * log: aquí nada llama a `Power` ni a `Media`.
 *
 * No importa `LockSession` ni `LockAuth`, ni `Quickshell.Services.Pam`. Lleva
 * SIEMPRE la banda «PREVIEW — NOT LOCKED», sin verbo que la oculte: nadie debe poder
 * confundir esto con un bloqueo.
 *
 * Vive en la raíz del shell porque un `qmldir` fuera de la raíz no carga los
 * módulos del shell (memoria del proyecto). `shell.qml` no la importa.
 *
 *   XDG_STATE_HOME=$(mktemp -d) qs -p ~/.config/quickshell/sumi/lock-preview.qml
 *
 * Entorno (todo opcional):
 *   LOCK_PREVIEW_SCREENS       pantallas donde se dibuja, separadas por comas; vacío = la enfocada.
 *                              La primera es la del foco (`hero`).
 *   LOCK_PREVIEW_INTERACTIVE=1 teclado exclusivo en la pantalla del foco. Se cierra con Ctrl+Shift+Q.
 *   LOCK_PREVIEW_SCALE         escala (si no, `Settings.uiScale`).
 *   LOCK_PREVIEW_BACKDROP      ruta del fondo (si no, `Wallpaper.lockStillPath`).
 *
 *   LOCK_PREVIEW_PHASE         fase inicial: `locked` (por defecto) o `unlocked` (para ver la entrada).
 *   LOCK_PREVIEW_DATA=live     el panel con los DATOS REALES del shell (15D): pide al shell vivo un
 *                              `LockData` de prueba (`lockDataTest`, concesión de 10 s) y lo lee cada 2 s
 *                              (`lockDataState`). Así la preview no levanta sus propios servicios. Los
 *                              escenarios no tocan esos datos; la autenticación sigue siendo falsa.
 *   LOCK_PREVIEW_ESC_QUITS=1   el modo del botón Preview de Settings (15H): Esc cierra la preview, y un
 *                              «desbloqueo» falso también. (La composición de ADR-30 se retiró en la 15H.)
 *
 * El IPC (`sumi-lock-preview`) lleva cada estado sin tocar el teclado, para
 * capturas: `scenario <nombre>`, `set <clave> <json>`, `state`, `quit`; y la
 * coreografía (L3): `enter` (entrada animada desde el island), `instant`, `success`
 * (lo que haría un `PamResult.Success`: la salida), `fail` y `animating`. No hay
 * verbo que «desbloquee»: aquí no hay bloqueo, y el lock real nunca lo tendrá (I-3).
 *
 * Debajo del lock se dibujan un escritorio y un island FALSOS (el wallpaper nítido y
 * una cápsula con la hora, con la geometría del island real leída de su `status`):
 * son lo que el xray dejaría ver al entrar y al salir, sin la ventana real del shell.
 *
 * Contraseñas falsas al pulsar ⏎: `ok` → éxito (la salida); `lockout` → cuenta bloqueada con
 * una salida de faillock inventada; `error` → PAM no disponible; `prompt` → PAM
 * pide una segunda respuesta; cualquier otra cosa → fallo a los 2 s.
 */
ShellRoot {
    id: root

    property string screensCsv: Quickshell.env("LOCK_PREVIEW_SCREENS") || ""
    property bool interactive: Quickshell.env("LOCK_PREVIEW_INTERACTIVE") === "1"
    property real scaleOverride: Number(Quickshell.env("LOCK_PREVIEW_SCALE") || 0)
    property string backdrop: Quickshell.env("LOCK_PREVIEW_BACKDROP") || Wallpaper.lockStillPath
    readonly property bool liveData: Quickshell.env("LOCK_PREVIEW_DATA") === "live"
    readonly property bool escQuits: Quickshell.env("LOCK_PREVIEW_ESC_QUITS") === "1"

    // ── datos reales del shell (15D) ──────────────────────────────────────────
    Process { id: liveOn; command: ["qs", "-c", "sumi", "ipc", "call", "sumi", "lockDataTest", "true"] }
    Process {
        id: livePull
        command: ["qs", "-c", "sumi", "ipc", "call", "sumi", "lockDataState"]
        stdout: StdioCollector { id: liveOut }
        onExited: {
            let d = null;
            try { d = JSON.parse(liveOut.text); } catch (e) { return; }
            if (!d || !d.summary) { liveOn.running = true; return; }
            ctx.fetch = d.fetch; ctx.weather = d.weather; ctx.metrics = d.metrics; ctx.notifs = d.notifs;
            ctx.music = d.music; ctx.privacy = d.privacy;
            ctx.avatarSource = d.avatarSource; ctx.fetchImageSource = d.fetchImageSource;
        }
    }
    Timer { interval: 2000; repeat: true; running: root.liveData; triggeredOnStart: true
            onTriggered: livePull.running = true }
    /** La primera lectura de verdad llega en cuanto el shell tiene el LockData: no esperar 2 s. */
    Timer { interval: 400; running: root.liveData; onTriggered: livePull.running = true }
    /** Desde Settings, «desbloquear» (la contraseña falsa `ok`) también cierra la preview. */
    Connections {
        target: ctx
        enabled: root.escQuits
        function onPhaseChanged() { if (ctx.phase === "unlocked") Qt.quit(); }
    }
    readonly property real s: root.scaleOverride > 0 ? root.scaleOverride : Settings.uiScale
    /** Para afinar el velo con capturas (FONDO §4). */
    property real dim: 0.62
    property real brightness: -0.25

    readonly property var shown: root.screensCsv.length > 0
        ? root.screensCsv.split(",").map(n => n.trim()).filter(n => n.length > 0)
        : [Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""]

    /** La ventana de la pantalla del foco tiene el teclado: guarda de las pruebas con `wtype` (RP-1). */
    property bool heroActive: false

    /** Lo que se dice en la banda un momento («SUCCESS — would unlock»). */
    property string bandNote: ""

    function log(o) { console.log("LOCK-PREVIEW " + JSON.stringify(o)); }

    // ── el contexto falso (ESTADO.md §7) ─────────────────────────────────────
    QtObject {
        id: ctx

        property string phase: Quickshell.env("LOCK_PREVIEW_PHASE") || "locked"
        property bool instant: false
        property bool secure: true
        property real since: Date.now() / 1000
        property string focusScreen: root.shown.length > 0 ? root.shown[0] : ""
        /** De `LockCalm` (15E): la misma lógica que tendrá el lock real. */
        readonly property bool calm: calmCtl.calm
        property bool holding: false
        property string buffer: ""
        readonly property int bufferLength: ctx.buffer.length
        property var auth: ({ state: "idle", message: "", failed: 0, lockoutUntil: 0, prompt: "", responseVisible: false })
        property string layoutCode: "US"
        property int layoutCount: 2
        property bool capsLock: false
        property bool numLock: false
        readonly property string userName: SystemInfo.userName
        /** `~/.face` si existe (se comprueba abajo); si no, la inicial. */
        property string avatarSource: ""
        /** Las mismas rutas que el lock real (Settings → Lock screen), con sus respaldos. */
        property string fetchImageSource: root.localPath(Settings.lockFetchImage)
            || (Quickshell.env("HOME") + "/.config/fastfetch/fastfetchlogo/minimaru.png")

        // ── fase 15: lo que pinta el panel (el lock real lo reenviará en la 15D) ──
        /** El fetch pasa por el contexto (LK-09): aquí, de `SystemInfo`; `set fetch` lo finge. */
        property var fetch: ({ os: SystemInfo.os, kernel: SystemInfo.kernel, wm: SystemInfo.wm,
                              shell: SystemInfo.shell, cpu: SystemInfo.cpu, gpu: SystemInfo.gpu })
        // con datos reales, «cargando» hasta la primera lectura: nunca se enseñan los inventados
        property var weather: root.liveData ? ({ state: "loading" }) : root.fakeWeather("ok")
        property var metrics: root.liveData ? root.fakeMetrics("loading") : root.fakeMetrics("ok")
        property var notifs: root.liveData ? ({ state: "ok", count: 0, groups: [] }) : root.fakeNotifs("some")

        // No están en ESTADO §7 todavía: lo que LockStatus pinta. El lock real los
        // reenvía de Media, Privacy y NotifHistory; aquí se fingen.
        property var music: ({ has: false, playing: false, title: "", artist: "", canPrev: false, canToggle: false, canNext: false, artUrl: "", levels: [0, 0, 0, 0, 0], vizActive: false })
        property var privacy: ({ mic: false, screen: false })
        property int notifications: 0
        property bool suspendOk: true
        property string suspendNote: ""
        property string powerError: ""

        signal failedAttempt()
        signal bufferCleared()

        function setAuth(patch) {
            const a = Object.assign({}, ctx.auth, patch);
            ctx.auth = a;
        }

        function setBuffer(text) {
            ctx.touch();
            if (ctx.auth.state === "checking")
                return;
            ctx.buffer = text;
            // tras un fallo, el mensaje se queda hasta la siguiente pulsación (AUTENTICACION §3)
            if (text.length > 0 && (ctx.auth.state === "failed" || ctx.auth.state === "error"))
                ctx.setAuth({ state: "idle", message: "" });
        }
        function clearBuffer() {
            ctx.touch();
            ctx.buffer = "";
            ctx.bufferCleared();
        }
        function submit() {
            ctx.touch();
            if (ctx.buffer.length === 0 || ctx.auth.state === "checking" || ctx.auth.state === "lockedOut")
                return;
            const word = ctx.buffer;
            ctx.clearBuffer();
            ctx.setAuth({ state: "checking" });
            fakePam.word = word;
            fakePam.interval = word === "ok" ? 40 : 2000;
            fakePam.restart();
        }
        function touch() { calmCtl.activity(); }
        /** Un hold de energía en curso suspende la calma (15E). */
        function setHolding(on) { ctx.holding = on; }
        function setFocusScreen(name) { ctx.focusScreen = name; }

        /** Pantallas que ya avisaron en esta fase; con todas, la fase avanza (ESTADO §3). */
        property var reported: ({})
        function report(screen, from, to) {
            if (ctx.phase !== from)
                return;
            const r = Object.assign({}, ctx.reported);
            r[screen] = true;
            ctx.reported = r;
            if (root.shown.every(n => r[n] === true)) {
                capTimer.stop();
                root.log({ ev: from + "-done", ms: Date.now() - root.phaseT0 });
                ctx.phase = to;
            }
        }
        function enterDone(screen) { ctx.report(screen, "entering", "locked"); }
        function leaveDone(screen) { ctx.report(screen, "leaving", "unlocked"); }
        function power(action) { ctx.touch(); root.log({ ev: "power (preview: nothing happens)", action: action }); }
        function media(action) { ctx.touch(); root.log({ ev: "media (preview: nothing happens)", action: action }); }
    }

    LockCalm {
        id: calmCtl
        phase: ctx.phase
        checking: ctx.auth.state === "checking"
        holding: ctx.holding
    }
    /** Un fallo de energía se lee entero: espera completa desde que aparece (15E). */
    Connections { target: ctx; function onPowerErrorChanged() { if (ctx.powerError.length > 0) calmCtl.holdMessage(); } }

    Timer {
        id: fakePam
        property string word: ""
        onTriggered: {
            switch (fakePam.word) {
            case "ok":
                ctx.setAuth({ state: "idle", message: "", failed: 0 });
                root.success();
                break;
            case "lockout":
                ctx.setAuth({ state: "lockedOut", failed: 3, lockoutUntil: Date.now() / 1000 + 581 });
                break;
            case "error":
                ctx.setAuth({ state: "error" });
                break;
            case "prompt":
                ctx.setAuth({ state: "prompt", prompt: "Verification code:" });
                break;
            default:
                ctx.setAuth({ state: "failed", message: "", failed: (ctx.auth.failed || 0) + 1 });
                ctx.failedAttempt();
            }
            fakePam.word = "";
        }
    }
    Timer { id: bandNoteTimer; interval: 2000; onTriggered: root.bandNote = "" }

    // ── fases (L3) ────────────────────────────────────────────────────────────
    property real phaseT0: 0
    /** El tope: si alguna pantalla no avisa, se fuerza el estado final y queda escrito. */
    Timer {
        id: capTimer
        interval: Motion.lockCap
        onTriggered: {
            const to = ctx.phase === "entering" ? "locked" : ctx.phase === "leaving" ? "unlocked" : ctx.phase;
            if (to !== ctx.phase) {
                console.warn("lock-preview: cap reached in phase", ctx.phase, "— forcing", to);
                ctx.phase = to;
            }
        }
    }
    function beginPhase(phase, instant) {
        ctx.reported = ({});
        ctx.instant = instant;
        root.phaseT0 = Date.now();
        ctx.phase = phase;
        if (phase === "entering" || phase === "leaving")
            capTimer.restart();
        root.log({ ev: "phase", phase: phase, instant: instant });
    }
    function enter() {
        if (ctx.phase !== "unlocked") return false;
        islandProbe.running = true;
        root.beginPhase("entering", false);
        return true;
    }
    function lockInstant() {
        if (ctx.phase !== "unlocked") return false;
        root.beginPhase("locked", true);
        return true;
    }
    function success() {
        if (ctx.phase !== "locked") return false;
        ctx.clearBuffer();
        root.beginPhase("leaving", false);
        return true;
    }
    function fail() {
        if (ctx.phase !== "locked") return false;
        ctx.setAuth({ state: "failed", message: "", failed: (ctx.auth.failed || 0) + 1 });
        ctx.failedAttempt();
        return true;
    }

    /**
     * De dónde sale la cápsula en cada pantalla (15F): `lockOrigin` del shell vivo —el island, el dock o el
     * tramo del reloj de la barra—, una línea «NOMBRE {json}» por pantalla. `set origin` lo finge (para la
     * barra sin cambiar la presentación del usuario).
     */
    property var origins: ({})
    Process {
        id: islandProbe
        command: ["sh", "-c", "for m in \"$@\"; do printf '%s ' \"$m\"; qs -c sumi ipc call sumi lockOrigin \"$m\"; echo; done",
                  "sh"].concat(root.shown)
        stdout: StdioCollector { id: islandOut }
        onExited: function (code) {
            const m = Object.assign({}, root.origins);
            String(islandOut.text || "").split("\n").forEach(function (line) {
                const i = line.indexOf(" ");
                if (i <= 0) return;
                try {
                    const g = JSON.parse(line.slice(i + 1));
                    if (g && typeof g.w === "number" && g.w > 0) m[line.slice(0, i)] = g;
                } catch (e) {}
            });
            root.origins = m;
        }
    }
    function homeFor(name, width) {
        const g = root.origins[name];
        if (g) return g;
        const w = Math.round(Metrics.restW * root.s), h = Math.round(Metrics.restH * root.s);
        return { x: Math.round((width - w) / 2), y: Math.round(Metrics.topGap * root.s), w: w, h: h, r: Metrics.restCorner * root.s };
    }
    property var surfaces: ({})

    /** Sin esto, una `Image` con una ruta que no existe deja un aviso en el log. */
    Process {
        id: faceCheck
        command: ["test", "-r", Quickshell.env("HOME") + "/.face"]
        onExited: function (code) {
            const set = root.localPath(Settings.lockAvatar);
            if (set.length > 0) ctx.avatarSource = set;
            else if (code === 0) ctx.avatarSource = Quickshell.env("HOME") + "/.face";
        }
    }

    /** Ruta local absoluta, o "" (I-14): el mismo filtro que `LockSession.localPath`. */
    function localPath(p) {
        const v = String(p || "").trim();
        if (v.length === 0 || v.indexOf("://") >= 0 || v.indexOf("data:") === 0) return "";
        if (v === "~") return Quickshell.env("HOME");
        if (v.indexOf("~/") === 0) return Quickshell.env("HOME") + v.slice(1);
        return v.indexOf("/") === 0 ? v : "";
    }

    // ── datos falsos del panel (fase 15, escenarios de futurelocksurface §13) ──
    function fakeWeather(kind) {
        const ok = { state: "ok", temp: "24°", condition: "Partly cloudy", icon: "weather-partly",
                     humidity: 58, place: "Lisbon", age: "" };
        switch (kind) {
        case "stale": return Object.assign({}, ok, { state: "stale", age: "3 h ago" });
        case "loading": return { state: "loading" };
        case "unavailable": return { state: "unavailable" };
        case "unconfigured": return { state: "unconfigured" };
        }
        return ok;
    }
    function fakeMetrics(kind) {
        const m = {
            cpu: { state: "ok", value: 23, unit: "%", frac: 0.23, sub: "16 threads" },
            cpuTemp: { state: "ok", value: 54, unit: "°C", frac: (54 - 20) / (95 - 20), sub: "Limit 95 °C",
                       note: "Arc from 20 to 95 degrees, the sensor's limit" },
            ram: { state: "ok", value: 41, unit: "%", frac: 0.41, sub: "6.2 / 15.0 GiB" },
            disk: { state: "ok", value: 61, unit: "%", frac: 0.61, sub: "285 / 468 GB" }
        };
        switch (kind) {
        case "loading": return { cpu: { state: "loading" }, cpuTemp: { state: "loading" }, ram: { state: "loading" }, disk: { state: "loading" } };
        case "stale": return { cpu: Object.assign({}, m.cpu, { state: "stale" }), cpuTemp: Object.assign({}, m.cpuTemp, { state: "stale" }),
                               ram: Object.assign({}, m.ram, { state: "stale" }), disk: Object.assign({}, m.disk, { state: "stale" }) };
        case "sensor-missing": return Object.assign({}, m, { cpuTemp: { state: "unavailable" } });
        case "temp-nolimit": return Object.assign({}, m, { cpuTemp: { state: "ok", value: 61, unit: "°C", frac: null, sub: "No limit reported",
                                                                     note: "The sensor reports no limit, so the arc stays neutral" } });
        case "high": return Object.assign({}, m, { cpu: Object.assign({}, m.cpu, { value: 97, frac: 0.97 }),
                                                   ram: Object.assign({}, m.ram, { value: 82, frac: 0.82, sub: "12.3 / 15.0 GiB" }) });
        }
        return m;
    }
    function fakeNotifs(kind) {
        const now = Date.now();
        const min = 60000;
        const some = [
            { app: "discord", name: "Discord", count: 3, items: [
                { id: "d3", title: "Yani", body: "are we still on for tonight? I finished the map pack", time: now - 4 * min },
                { id: "d2", title: "Yani", body: "sent a picture", time: now - 9 * min },
                { id: "d1", title: "#general", body: "Tokai: the patch is out", time: now - 42 * min } ] },
            { app: "thunderbird", name: "Thunderbird", count: 1, items: [
                { id: "t1", title: "Invoice #2291 from your ISP", body: "Your statement for September is ready. The amount due is $540.00 MXN and will be charged on October 5. You can review the details in your account at any time.", time: now - 26 * min } ] },
            { app: "sumi", name: "Sumi Shell", count: 2, items: [
                { id: "k2", title: "Updates available", body: "5 packages can be updated", time: now - 70 * min },
                { id: "k1", title: "Healthcheck", body: "All checks passed", time: now - 3 * 60 * min } ] }
        ];
        switch (kind) {
        case "empty": return { state: "ok", count: 0, groups: [] };
        case "unavailable": return { state: "unavailable", count: 4, groups: [] };
        case "many": {
            const apps = ["Discord", "Firefox", "Thunderbird", "Steam", "Telegram", "Spotify", "Sumi Shell", "Signal"];
            const groups = apps.map(function (a, i) {
                const n = (i % 4) + 2;
                const items = [];
                for (let k = 0; k < n; k++)
                    items.push({ id: a + k, title: a + " message " + (n - k), body: "Message body number " + (n - k) + " from " + a + ", long enough to wrap onto a second line in the card.", time: now - (i * 11 + k * 3) * min });
                return { app: a.toLowerCase(), name: a, count: n, items: items };
            });
            return { state: "ok", count: groups.reduce(function (t, g) { return t + g.count; }, 0), groups: groups };
        }
        }
        return { state: "ok", count: 6, groups: some };
    }

    // ── escenarios para capturas ─────────────────────────────────────────────
    function scenario(name) {
        const quiet = { has: false, playing: false, title: "", artist: "", canPrev: false, canToggle: false, canNext: false, artUrl: "", levels: [0, 0, 0, 0, 0], vizActive: false };
        const art = Quickshell.env("LOCK_PREVIEW_ART") || "";
        const song = { has: true, playing: true, title: "Umapyoi Densetsu (Special Week, Silence Suzuka & Tokai Teio)", artist: "Special Week",
                       canPrev: true, canToggle: true, canNext: true, artUrl: art.length > 0 ? "file://" + art : "",
                       levels: [0.42, 0.86, 0.61, 0.93, 0.37], vizActive: true };
        calmCtl.activity();
        ctx.capsLock = false;
        ctx.numLock = false;
        ctx.powerError = "";
        ctx.music = quiet;
        ctx.privacy = { mic: false, screen: false };
        ctx.notifications = 0;
        ctx.buffer = "";
        ctx.bufferCleared();
        fakePam.stop();
        ctx.auth = { state: "idle", message: "", failed: 0, lockoutUntil: 0, prompt: "", responseVisible: false };
        ctx.focusScreen = root.shown.length > 0 ? root.shown[0] : "";
        if (root.liveData) { root.log({ ev: "scenario", name: name, live: true }); return true; }
        ctx.weather = root.fakeWeather("ok");
        ctx.metrics = root.fakeMetrics("ok");
        ctx.notifs = root.fakeNotifs("some");
        ctx.fetch = { os: SystemInfo.os, kernel: SystemInfo.kernel, wm: SystemInfo.wm,
                      shell: SystemInfo.shell, cpu: SystemInfo.cpu, gpu: SystemInfo.gpu };
        ctx.fetchImageSource = root.localPath(Settings.lockFetchImage)
            || (Quickshell.env("HOME") + "/.config/fastfetch/fastfetchlogo/minimaru.png");
        // síncrono: si no, `faceCheck` (asíncrono) pisaría la ruta rota de `image-lost`
        ctx.avatarSource = root.localPath(Settings.lockAvatar);
        if (ctx.avatarSource.length === 0) faceCheck.running = true;

        switch (name) {
        case "rest": break;
        case "rest-music": ctx.music = song; break;
        case "music-short": ctx.music = Object.assign({}, song, { title: "Umapyoi Densetsu" }); break;
        case "music-paused": ctx.music = Object.assign({}, song, { playing: false, vizActive: false, levels: [0, 0, 0, 0, 0] }); break;
        case "music-noart": ctx.music = Object.assign({}, song, { artUrl: "" }); break;
        case "typing": ctx.buffer = "preview-pw"; break;
        case "typing-long": ctx.buffer = "x".repeat(31); break;
        case "checking": ctx.buffer = "preview"; ctx.auth = Object.assign({}, ctx.auth, { state: "checking" }); break;
        case "failed": ctx.auth = Object.assign({}, ctx.auth, { state: "failed", failed: 2 }); ctx.notifications = 2; break;
        case "lockedOut": ctx.auth = Object.assign({}, ctx.auth, { state: "lockedOut", failed: 3, lockoutUntil: Date.now() / 1000 + 581 }); break;
        case "error": ctx.auth = Object.assign({}, ctx.auth, { state: "error" }); break;
        case "prompt": ctx.auth = Object.assign({}, ctx.auth, { state: "prompt", prompt: "Verification code:" }); break;
        case "calm": ctx.music = song; ctx.notifications = 2; calmCtl.forceCalm(); break;
        case "alarms": ctx.privacy = { mic: true, screen: true }; ctx.notifications = 1; ctx.auth = Object.assign({}, ctx.auth, { failed: 1 }); break;
        case "full": ctx.music = song; ctx.privacy = { mic: true, screen: false }; ctx.notifications = 5;
            ctx.auth = Object.assign({}, ctx.auth, { state: "failed", failed: 2 }); ctx.capsLock = true; ctx.numLock = true; break;
        case "locks": ctx.capsLock = true; ctx.numLock = true; break;
        case "power-failed": ctx.powerError = "Couldn't shut down"; break;
        case "nofocus": ctx.focusScreen = "__none__"; break;
        // ── fase 15: el panel (futurelocksurface §13) ──
        case "board": ctx.music = song; ctx.privacy = { mic: true, screen: false }; break;
        case "notifs-empty": ctx.notifs = root.fakeNotifs("empty"); break;
        case "notifs-many": ctx.notifs = root.fakeNotifs("many"); ctx.music = song; break;
        case "notifs-unavailable": ctx.notifs = root.fakeNotifs("unavailable"); break;
        case "metrics-loading": ctx.metrics = root.fakeMetrics("loading"); ctx.weather = root.fakeWeather("loading"); break;
        case "metrics-stale": ctx.metrics = root.fakeMetrics("stale"); ctx.weather = root.fakeWeather("stale"); break;
        case "sensor-missing": ctx.metrics = root.fakeMetrics("sensor-missing"); break;
        case "temp-nolimit": ctx.metrics = root.fakeMetrics("temp-nolimit"); break;
        case "metrics-high": ctx.metrics = root.fakeMetrics("high"); break;
        case "weather-unavailable": ctx.weather = root.fakeWeather("unavailable"); break;
        case "weather-unconfigured": ctx.weather = root.fakeWeather("unconfigured"); break;
        case "image-lost": ctx.fetchImageSource = "/nonexistent/kt15b.png"; ctx.avatarSource = "/nonexistent/kt15b-face.png"; break;
        case "cover-broken": ctx.music = Object.assign({}, song, { artUrl: "file:///nonexistent/kt15b-cover.png" }); break;
        case "error-long": ctx.auth = Object.assign({}, ctx.auth, { state: "failed", failed: 1,
            message: "The authentication service reported an unexpected condition while checking your password" }); break;
        case "privacy": ctx.privacy = { mic: true, screen: true }; break;
        case "power-and-checking": ctx.buffer = "preview"; ctx.auth = Object.assign({}, ctx.auth, { state: "checking" });
            ctx.powerError = "Couldn't shut down — the request was refused"; break;
        default: return false;
        }
        root.log({ ev: "scenario", name: name });
        return true;
    }

    // ── una ventana por pantalla mostrada ────────────────────────────────────
    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win
            required property var modelData
            readonly property string name: win.modelData.name
            readonly property bool hero: ctx.focusScreen === win.name

            screen: win.modelData
            visible: root.shown.indexOf(win.name) >= 0
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "sumi-lock-preview"
            WlrLayershell.keyboardFocus: root.interactive && win.hero
                ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
            anchors { top: true; left: true; right: true; bottom: true }

            Item {
                id: frame
                anchors.fill: parent
                readonly property bool active: Window.active

                onActiveChanged: {
                    if (frame.active && lockLoader.item)
                        lockLoader.item.focusField();
                    if (win.hero)
                        root.heroActive = frame.active;
                }

                Shortcut {
                    sequence: "Ctrl+Shift+Q"
                    context: Qt.WindowShortcut
                    onActivated: Qt.quit()
                }
                // desde Settings (15H): Esc cierra, antes de que el campo lo tome para borrar
                Shortcut {
                    sequence: "Escape"
                    enabled: root.escQuits
                    context: Qt.WindowShortcut
                    onActivated: Qt.quit()
                }

                /** El escritorio falso: lo que el xray dejaría ver (sin ventanas reales del shell). */
                Image {
                    anchors.fill: parent
                    visible: !(lockLoader.item && lockLoader.item.wantsOpaque)
                    source: "file://" + Wallpaper.lockStillPath
                    sourceSize.width: 960
                    sourceSize.height: 540
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                }

                /** El island falso, con la geometría del real: sólo mientras no hay lock (el relevo, ISLAND §2). */
                Glass {
                    readonly property var g: root.homeFor(win.name, frame.width)
                    visible: ctx.phase === "unlocked"
                    x: g.x; y: g.y; width: g.w; height: g.h
                    radius: g.r
                    s: root.s
                    Text {
                        anchors.centerIn: parent
                        text: Clock.time
                        color: Theme.fg
                        font.family: Typography.ui
                        font.weight: Typography.wStrong
                        font.pixelSize: Typography.restTime * root.s
                        font.features: { "tnum": 1 }
                    }
                }

                /** El lock NACE con el bloqueo, como una `WlSessionLockSurface`. */
                Loader {
                    id: lockLoader
                    anchors.fill: parent
                    active: ctx.phase !== "unlocked" && win.visible
                    onItemChanged: {
                        const m = Object.assign({}, root.surfaces);
                        m[win.name] = lockLoader.item;
                        root.surfaces = m;
                    }
                    sourceComponent: boardSurface
                }
                Component {
                    id: boardSurface
                    LockBoardSurface {
                        context: ctx
                        s: root.s
                        screenName: win.name
                        hero: win.hero
                        focused: frame.active
                        backdropSource: root.backdrop
                        backdropDim: root.dim
                        backdropBrightness: root.brightness
                        home: root.homeFor(win.name, frame.width)
                    }
                }

                /** LA BANDA. Siempre visible, sin verbo que la oculte. */
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 22 * root.s
                    color: Theme.warn
                    z: 1000

                    Text {
                        anchors.centerIn: parent
                        text: "PREVIEW — NOT LOCKED" + (root.bandNote.length > 0 ? "   ·   " + root.bandNote : "")
                            + (root.interactive && win.hero ? (root.escQuits ? "   ·   Esc closes" : "   ·   Ctrl+Shift+Q closes") : "")
                        color: Theme.surfaceContainerLowest
                        font.family: Typography.ui
                        font.weight: Typography.wStrong
                        font.pixelSize: Typography.label * root.s
                        font.letterSpacing: Typography.tracking * root.s
                    }
                }
            }
        }
    }

    IpcHandler {
        target: "sumi-lock-preview"

        function scenario(name: string): bool { return root.scenario(name); }
        /** Coreografía (L3). */
        function enter(): bool { return root.enter(); }
        function instant(): bool { return root.lockInstant(); }
        function success(): bool { return root.success(); }
        function fail(): bool { return root.fail(); }
        /** ¿Se mueve algo en alguna pantalla? «Cero animaciones en reposo» (ANIMACIONES §14). */
        function animating(): string {
            const out = {};
            Object.keys(root.surfaces).forEach(n => { const it = root.surfaces[n]; out[n] = it ? it.animating : null; });
            return JSON.stringify({ phase: ctx.phase, screens: out });
        }
        /** `set capsLock true`, `set notifications 3`, `set auth '{"state":"failed","failed":1}'`… */
        function set(key: string, json: string): bool {
            let v;
            try { v = JSON.parse(json); } catch (e) { return false; }
            switch (key) {
            case "phase": ctx.phase = v; break;
            case "calm": if (v) calmCtl.forceCalm(); else calmCtl.activity(); break;
            case "focusScreen": ctx.focusScreen = v; break;
            case "auth": ctx.auth = Object.assign({}, ctx.auth, v); break;
            case "layoutCode": ctx.layoutCode = v; break;
            case "layoutCount": ctx.layoutCount = v; break;
            case "capsLock": ctx.capsLock = v; break;
            case "numLock": ctx.numLock = v; break;
            case "avatarSource": ctx.avatarSource = v; break;
            case "fetchImageSource": ctx.fetchImageSource = v; break;
            case "music": ctx.music = Object.assign({}, ctx.music, v); break;
            case "privacy": ctx.privacy = Object.assign({}, ctx.privacy, v); break;
            case "notifications": ctx.notifications = v; break;
            case "suspendOk": ctx.suspendOk = v; break;
            case "suspendNote": ctx.suspendNote = v; break;
            case "powerError": ctx.powerError = v; break;
            case "backdrop": root.backdrop = v; break;
            case "scale": root.scaleOverride = v; break;
            case "dim": root.dim = v; break;
            case "brightness": root.brightness = v; break;
            case "screens": root.screensCsv = v; break;
            case "fetch": ctx.fetch = Object.assign({}, ctx.fetch, v); break;
            case "weather": ctx.weather = v; break;
            case "metrics": ctx.metrics = Object.assign({}, ctx.metrics, v); break;
            case "notifs": ctx.notifs = v; break;
            // Normal / Reduced / Off sólo en esta preview (`Motion.override`), sin tocar el ajuste del usuario
            case "motion": Motion.override = (v === "normal" || v === "reduced" || v === "off") ? v : ""; break;
            case "origin": { const m = Object.assign({}, root.origins); m[ctx.focusScreen] = v; root.origins = m; break; }
            default: return false;
            }
            return true;
        }
        /** El estado, SIN lo tecleado: sólo su longitud (la costumbre de I-8, también aquí). */
        function state(): string {
            return JSON.stringify({
                preview: true, pid: Quickshell.processId, shown: root.shown, s: root.s, backdrop: root.backdrop, heroActive: root.heroActive,
                notifsView: root.surfaces[ctx.focusScreen] ? root.surfaces[ctx.focusScreen].notifsView : null,
                focus: (root.surfaces[ctx.focusScreen] && root.surfaces[ctx.focusScreen].focusName !== undefined)
                    ? root.surfaces[ctx.focusScreen].focusName : null,
                narrow: Object.keys(root.surfaces).reduce(function (o, n) {
                    const it = root.surfaces[n]; o[n] = it && it.narrow !== undefined ? it.narrow : null; return o; }, {}),
                phase: ctx.phase, instant: ctx.instant, focusScreen: ctx.focusScreen, origins: root.origins, motion: Motion.mode, calm: ctx.calm, bufferLength: ctx.bufferLength,
                auth: ctx.auth, layout: [ctx.layoutCode, ctx.layoutCount], capsLock: ctx.capsLock, numLock: ctx.numLock,
                userName: ctx.userName, music: ctx.music, privacy: ctx.privacy, notifications: ctx.notifications,
                sysinfo: { os: SystemInfo.os, kernel: SystemInfo.kernel, wm: SystemInfo.wm, shell: SystemInfo.shell,
                           cpu: SystemInfo.cpu, gpu: SystemInfo.gpu, memory: SystemInfo.memory,
                           memTotal: SystemInfo.memTotal, memAvailable: SystemInfo.memAvailable, userName: SystemInfo.userName }
            });
        }
        /**
         * Un paso del recorrido de teclado (15C) en la pantalla que manda: `-1` es lo que haría Mayús+Tab,
         * que `wtype` no sabe mandar a Qt. Devuelve el control enfocado.
         */
        function step(dir: int): string {
            const it = root.surfaces[ctx.focusScreen];
            if (!it || !it.stepFocus) return "";
            it.stepFocus(dir < 0 ? -1 : 1);
            return it.focusName;
        }
        /** Lo que haría pulsar «New notifications» (15D). */
        function adoptNotifications(): bool {
            const it = root.surfaces[ctx.focusScreen];
            if (!it || !it.adoptNotifications) return false;
            it.adoptNotifications();
            return true;
        }
        function refreshMemory(): string { SystemInfo.refreshMemory(); return SystemInfo.memory; }
        function quit(): void { Qt.quit(); }
    }

    /** La memoria se relee con cada minuto, como hará el lock (SERVICIOS §3). */
    Connections {
        target: Clock
        function onTimeChanged() { SystemInfo.refreshMemory(); }
    }

    Component.onCompleted: {
        SystemInfo.load();
        faceCheck.running = true;
        islandProbe.running = true;
        if (root.liveData) liveOn.running = true;
        root.log({ ev: "ready", pid: Quickshell.processId, shown: root.shown, interactive: root.interactive, live: root.liveData });
    }
}
