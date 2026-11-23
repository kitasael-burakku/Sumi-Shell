pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

/**
 * Ecualizador por salida (fase 13D el motor; 13E presets, Custom, Reset y los controles).
 * rediseno/docs/futureAudio-Mixersurface.md §«Procesamiento y controles de ecualizador».
 *
 * Quién es dueño de qué (decisión del usuario, PREPARACION §Fase 13):
 *   perfiles   ~/.config/sumi-shell/audio-eq.json, uno por salida (node.name): enabled,
 *              diez bandas (dB), preamp (dB) y lo que añada la 13E (preset, curva Custom).
 *   filtro     `filter-chain.service` de PipeWire, con la config que `scripts/audio-eq.py`
 *              GENERA de los perfiles: un filtro smart por salida. Vive fuera del shell:
 *              cerrar o recargar el shell no interrumpe nada, y si el filtro cae, WirePlumber
 *              deja el audio directo en la salida (medido con sonda, 13A).
 *
 * Qué cuesta cada cambio (medido en la 13D, sink nulo + FFT):
 *   ganancias y preamp   en vivo con `pw-cli set-param <filtro> Props '{ params = [ "b6:Gain" 6 ] }'`
 *                        (sin cortes); el archivo se reescribe después sin reiniciar, para que el
 *                        próximo arranque diga lo mismo.
 *   On / Off             en vivo con el metadato `filter.smart.disabled` de `filters` (WirePlumber
 *                        puentea el filtro: la salida vuelve a ser idéntica, 0,00 dB).
 *   añadir o quitar una salida   reescribe la estructura y REINICIA el servicio: las salidas con
 *                        EQ suenan directas un instante mientras vuelve.
 *
 * Los nodos del filtro se reconocen por `kitasan.equalizer = <salida>` (la entrada, Audio/Sink);
 * AudioRoutes los oculta de salidas y aplicaciones (son filtros smart).
 */
Singleton {
    id: root

    readonly property var freqs: [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    readonly property real bandMin: -12
    readonly property real bandMax: 12
    readonly property real preMin: -12
    readonly property real preMax: 0

    /**
     * Presets (decisión del usuario, 2026-09-28, PREPARACION §Fase 13): dB por banda de 31 Hz a
     * 16 kHz y su preamp. Custom es la curva propia de cada salida: tocar una banda o el preamp la
     * crea a partir de lo que suena.
     *
     * Preamp: al principio compensaba la banda más alta; medido en la 13E, el PICO real de la
     * curva (bandas vecinas sumadas) seguía por encima de 0 dB (Bass +1,10, Vocal +1,17, Pop
     * +1,12, Rock +0,80, Treble y Jazz +0,41). El usuario decidió bajarlo hasta que el pico no
     * pase de 0 dB, en pasos de 0,5 (2026-09-28).
     */
    readonly property var presets: [
        { id: "flat",    name: "Flat",    bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],         preamp: 0 },
        { id: "bass",    name: "Bass",    bands: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0],         preamp: -7.5 },
        { id: "treble",  name: "Treble",  bands: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6],         preamp: -6.5 },
        { id: "vocal",   name: "Vocal",   bands: [-2, -2, -1, 0, 2, 4, 4, 2, 0, -1],     preamp: -5.5 },
        { id: "pop",     name: "Pop",     bands: [-1, 1, 3, 4, 3, 0, -1, -1, 1, 2],      preamp: -5.5 },
        { id: "rock",    name: "Rock",    bands: [5, 4, 2, -1, -2, -1, 2, 3, 4, 4],      preamp: -6 },
        { id: "jazz",    name: "Jazz",    bands: [3, 2, 1, 2, -1, -1, 0, 1, 2, 3],       preamp: -3.5 },
        { id: "classic", name: "Classic", bands: [0, 0, 0, 0, 0, 0, -3, -3, -3, -4],     preamp: 0 }
    ]

    /**
     * El pico REAL de la curva (dB), no la banda más alta: la respuesta de las diez peaking en
     * cascada (RBJ, Q 1,41, 48 kHz, la misma que mide tools/eq-expect.py al 0,01 dB) en 121
     * frecuencias de 20 Hz a 20 kHz, más el preamp.
     */
    readonly property var peakGrid: {
        const out = [];
        for (let i = 0; i <= 120; i++) out.push(20 * Math.pow(1000, i / 120));
        return out;
    }
    /**
     * La respuesta de la curva (dB) en las frecuencias `freqsHz`: las diez peaking en cascada (RBJ,
     * Q 1,41, 48 kHz; la misma que mide tools/eq-expect.py al 0,01 dB) más el preamp. La usan el
     * pico (aviso de saturación) y la gráfica de la Audio UI: lo dibujado es lo que suena.
     */
    function response(bands, pre, freqsHz) {
        const fs = 48000, q = 1.41;
        const coefs = [];
        for (let k = 0; k < 10; k++) {
            const g = Number(bands[k]) || 0;
            if (g === 0) continue;
            const A = Math.pow(10, g / 40), w0 = 2 * Math.PI * root.freqs[k] / fs, al = Math.sin(w0) / (2 * q), c = Math.cos(w0);
            coefs.push([1 + al * A, -2 * c, 1 - al * A, 1 + al / A, -2 * c, 1 - al / A]);
        }
        const out = [];
        for (const f of freqsHz) {
            const w = 2 * Math.PI * f / fs, c1 = Math.cos(w), s1 = Math.sin(w), c2 = Math.cos(2 * w), s2 = Math.sin(2 * w);
            let db = Number(pre) || 0;
            for (const [b0, b1, b2, a0, a1, a2] of coefs) {
                const nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2);
                const dr = a0 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2);
                db += 10 * Math.log10((nr * nr + ni * ni) / (dr * dr + di * di));
            }
            out.push(db);
        }
        return out;
    }
    function peakDb(bands, pre) {
        return Math.max.apply(null, root.response(bands, pre, root.peakGrid));
    }
    function presetById(id) { return root.presets.find(p => p.id === id) || null; }
    function presetName(id) { const p = root.presetById(id); return p ? p.name : (id === "custom" ? "Custom" : "Flat"); }

    /**
     * Lo que enseñan los controles de una salida, exista o no su perfil: una salida nueva es
     * Flat y apagada (spec) sin crear nada hasta que se toque algo. `clipRisk`: el pico real de
     * la curva pasa de 0 dB (aviso «May clip»).
     */
    function view(dev) {
        void root.profiles;
        const p = root.profileOf(dev);
        const bands = p ? p.bands.slice() : root.freqs.map(() => 0);
        const pre = p ? Number(p.preamp) : 0;
        const peak = root.peakDb(bands, pre);
        // «May clip»: el pico real pasa de 0 dB; `safePre` es el preamp que lo deja en 0 (a 0,5)
        return { exists: p !== null, enabled: p ? p.enabled === true : false, preset: p ? (p.preset || "flat") : "flat",
                 bands: bands, preamp: pre, peak: Math.round(peak * 100) / 100, clipRisk: peak > 0.05,
                 safePre: Math.max(root.preMin, Math.floor((pre - Math.max(0, peak)) * 2) / 2) };
    }

    /** PRUEBAS (IPC `eqTestRoot`, sólo bajo /tmp/): perfiles, config y un servicio propio. */
    property string testRoot: ""
    readonly property bool testing: root.testRoot.length > 0
    readonly property bool supported: root.testing || Capabilities.userManagerState === "available"
    readonly property string unavailableReason: "The equalizer needs a systemd user service manager"
    readonly property string helper: Quickshell.shellDir + "/scripts/audio-eq.py"
    readonly property string profilesPath: root.testing
        ? root.testRoot + "/config/sumi-shell/audio-eq.json" : Settings.configDir + "/audio-eq.json"

    function setTestRoot(d) {
        const s = String(d || "");
        if (s.length > 0 && (s.indexOf("/tmp/") !== 0 || s.indexOf("..") >= 0)) return false;
        root.testRoot = s;
        root.profiles = ({});
        root.loaded = false;
        profilesFile.reload();
        root.refreshService();
        return true;
    }

    function helperArgs(args) {
        const a = ["python3", root.helper].concat(args);
        return root.testing ? a.concat(["--root", root.testRoot]) : a;
    }

    // ---- perfiles --------------------------------------------------------------------

    /** node.name → { enabled, bands[10], preamp, label, … } tal como está en disco. */
    property var profiles: ({})
    property bool loaded: false
    property string readError: ""

    FileView {
        id: profilesFile
        path: root.profilesPath
        watchChanges: true
        printErrors: false
        onLoaded: {
            try {
                const d = JSON.parse(text());
                root.profiles = (d && d.version === 1 && d.devices) ? d.devices : ({});
                root.readError = "";
            } catch (e) {
                root.readError = "The equalizer settings can't be read";
            }
            root.loaded = true;
        }
        onLoadFailed: { root.profiles = ({}); root.loaded = true; }
        onFileChanged: reload()
    }

    function profileOf(dev) { return root.profiles[dev] || null; }

    function copyProfiles() { return JSON.parse(JSON.stringify(root.profiles)); }

    // ---- los filtros vivos -------------------------------------------------------------

    readonly property var filters: {
        const out = {};
        const l = Pipewire.nodes ? Pipewire.nodes.values : [];
        for (let i = 0; i < l.length; i++) {
            const n = l[i];
            if (!n || !n.properties) continue;
            const dev = n.properties["kitasan.equalizer"];
            if (dev !== undefined && String(n.properties["media.class"] || "") === "Audio/Sink") out[String(dev)] = n;
        }
        return out;
    }
    function filterOf(dev) { return root.filters[dev] || null; }

    /** Estado del servicio: «active», «inactive», «failed», «unknown». */
    property string service: "unknown"
    function refreshService() {
        if (!root.supported) { root.service = "unavailable"; return; }
        root.run(root.helperArgs(["service", "status"]), "service", 0);
    }
    onSupportedChanged: root.refreshService()

    /**
     * Qué pasa con el EQ de una salida:
     *   loading   aún no se leyeron los perfiles (no es «apagado»)
     *   none      sin perfil (una salida nueva empieza aquí: Flat y apagado, sin filtro)
     *   starting  preparándose (un cambio de estructura en vuelo)
     *   absent    hay perfil pero la salida no está conectada
     *   on        filtro vivo y procesando          bypassed  filtro vivo y apagado
     *   failed    hay perfil y salida, pero no hay filtro: `reason` dice por qué; la salida
     *             suena igual (sin EQ)
     */
    /**
     * Portabilidad F2d: el EQ vive en `filter-chain.service` de PipeWire (y `pw-cli`). Sin él no se
     * crea ningún perfil: crearlo reiniciaría un servicio que no existe. Quitar uno sigue pudiéndose.
     * Con `testRoot` no aplica: el filtro es el propio del banco.
     */
    readonly property string whyNot: !root.supported ? root.unavailableReason
        : root.testing ? "" : Capabilities.whyFirst(["audio.equalizer"])

    function stateOf(dev) {
        void root.ops.table;
        // 13F: antes de leer el archivo no se sabe (medido tras reiniciar el shell: «none» falso)
        if (!root.loaded) return { state: "loading", reason: "" };
        const p = root.profileOf(dev);
        if (!p) return root.whyNot.length > 0 ? { state: "unavailable", reason: root.whyNot } : { state: "none", reason: "" };
        if (root.ops.pending("setup:" + dev)) return { state: "starting", reason: "" };
        if (!AudioRoutes.nodeByName(dev)) return { state: "absent", reason: "" };
        if (!root.filterOf(dev)) {
            const o = root.ops.get("setup:" + dev);
            const why = o.state === "error" && o.reason.length > 0 ? o.reason
                : root.service !== "active" ? "The equalizer service is " + root.service
                : "The equalizer didn't start for this output";
            return { state: "failed", reason: why };
        }
        return { state: p.enabled ? "on" : "bypassed", reason: "" };
    }

    // ---- acciones ----------------------------------------------------------------------

    readonly property Ops ops: Ops { name: "eq" }

    function clampBand(v) { return Math.round(Math.max(root.bandMin, Math.min(root.bandMax, Number(v) || 0)) * 10) / 10; }
    function clampPre(v) { return Math.round(Math.max(root.preMin, Math.min(root.preMax, Number(v) || 0)) * 10) / 10; }

    /**
     * Crea el perfil de una salida (Flat, apagado) y su filtro. Cambia la ESTRUCTURA: el
     * servicio se reinicia. `ok` cuando el nodo del filtro aparece (plazo 8 s).
     */
    function setup(dev, label, patch) {
        const key = "setup:" + dev;
        if (!/^[A-Za-z0-9._:@+-]{1,200}$/.test(dev)) return -1;
        if (root.whyNot.length > 0) return -1;             // F2d: todo primer gesto pasa por aquí
        const r = root.ops.request(key, dev);
        const all = root.copyProfiles();
        // `patch` (13E): lo que el primer gesto pidió (encender, un preset, una banda) va ya en
        // el perfil nuevo; así el filtro nace con ello y no hace falta un segundo cambio.
        if (!all[dev])
            all[dev] = Object.assign({ label: String(label || ""), enabled: false, preset: "flat",
                                       bands: root.freqs.map(() => 0), preamp: 0 }, patch || {});
        // Sin filtro vivo (primera vez o Retry tras un fallo), el servicio se reinicia siempre.
        root.writeProfiles(all, key, r, root.filterOf(dev) ? "auto" : "always");
        root.ops.expect(key, r, { hold: 300, timeout: 8000,
            timeoutReason: "The equalizer didn't start for this output",
            check: () => root.filterOf(dev) ? { met: true, effective: dev } : { reason: root.service !== "active"
                ? "The equalizer service is " + root.service : "The equalizer didn't start for this output" } });
        return r;
    }

    /** Quita el perfil y su filtro (estructura: reinicia; sin perfiles, para el servicio). */
    function remove(dev) {
        if (!root.supported) return -1;
        const key = "setup:" + dev;
        const r = root.ops.request(key, "");
        const all = root.copyProfiles();
        delete all[dev];
        root.writeProfiles(all, key, r);
        root.ops.expect(key, r, { hold: 300, timeout: 8000, timeoutReason: "The equalizer is still running",
            check: () => root.filterOf(dev) ? {} : { met: true, effective: "" } });
        return r;
    }

    /** On/Off en vivo (metadato) y guardado. Comprobado leyendo el metadato después. */
    function setEnabled(dev, on) {
        if (!root.supported) return -1;
        const p = root.profileOf(dev);
        const key = "enabled:" + dev;
        if (!p && on) return root.setup(dev, root.labelFor(dev), { enabled: true });
        const r = root.ops.request(key, !!on);
        if (!p) { root.ops.resolve(key, r, "error", "This output has no equalizer yet"); return r; }
        const all = root.copyProfiles();
        all[dev].enabled = !!on;
        root.profiles = all;              // optimista: se pinta ya; el archivo llega después
        root.persistSoon();
        const f = root.filterOf(dev);
        if (!f) { root.ops.resolve(key, r, "ok", "", !!on); return r; }   // se aplicará al arrancar
        const id = String(f.id);
        root.run(["pw-metadata", "-n", "filters", "--", id, "filter.smart.disabled", on ? "false" : "true"], "live", 0);
        root.ops.verifyLater(key, r, 250, ["pw-metadata", "-n", "filters", id, "filter.smart.disabled"],
            (txt, code) => {
                const m = /value:'(true|false)'/.exec(txt || "");
                const disabled = m ? m[1] === "true" : false;
                return disabled === !on ? ["ok", "", !!on] : ["error", "PipeWire kept the equalizer " + (disabled ? "off" : "on"), !disabled];
            });
        return r;
    }

    /**
     * Curva en vivo: diez bandas y preamp (dB, acotados). Se escribe al filtro enseguida y al
     * archivo con retardo; se comprueba releyendo los parámetros del nodo (`pw-dump`).
     */
    /** El nombre corto de la salida, para la etiqueta del filtro («Equalizer · GS25F2»). */
    function labelFor(dev) {
        const n = AudioRoutes.nodeByName(dev);
        return n ? Mixer.shortLabel(n) : "";
    }

    /** Aplica un preset (o vuelve a Custom con su curva guardada). Sin perfil, lo crea con él. */
    function applyPreset(dev, id) {
        const p = root.profileOf(dev);
        let curve;
        if (id === "custom") {
            const c = p && p.custom ? p.custom : null;
            curve = c ? { bands: c.bands, preamp: c.preamp } : { bands: root.view(dev).bands, preamp: root.view(dev).preamp };
        } else {
            const pr = root.presetById(id);
            if (!pr) return -1;
            curve = { bands: pr.bands.slice(), preamp: pr.preamp };
        }
        if (!p) return root.setup(dev, root.labelFor(dev), { preset: id, bands: curve.bands, preamp: curve.preamp });
        return root.setCurve(dev, curve.bands, curve.preamp, { preset: id });
    }

    /** Tocar una banda o el preamp: pasa a Custom desde la curva que suena, y la guarda como tal. */
    function editCurve(dev, bands, preamp) {
        const b = bands.map(root.clampBand);
        const pre = root.clampPre(preamp);
        if (!root.profileOf(dev))
            return root.setup(dev, root.labelFor(dev), { preset: "custom", bands: b, preamp: pre,
                                                         custom: { bands: b, preamp: pre } });
        return root.setCurve(dev, b, pre, { preset: "custom", custom: { bands: b, preamp: pre } });
    }
    function setBand(dev, i, v) {
        const cur = root.view(dev);
        const b = cur.bands.slice();
        if (i < 0 || i > 9) return -1;
        b[i] = v;
        return root.editCurve(dev, b, cur.preamp);
    }
    function setPreamp(dev, v) {
        const cur = root.view(dev);
        return root.editCurve(dev, cur.bands, v);
    }

    /** Reset: un preset vuelve a sus valores; Custom vuelve a plano (spec: «la curva activa a su estado inicial»). */
    function reset(dev) {
        const cur = root.view(dev);
        if (!cur.exists) return -1;
        if (cur.preset !== "custom") return root.applyPreset(dev, cur.preset);
        const z = root.freqs.map(() => 0);
        return root.setCurve(dev, z, 0, { preset: "custom", custom: { bands: z, preamp: 0 } });
    }

    /**
     * Antes de la fase 14: resets con UN significado cada uno (el pedido: no mezclar acciones bajo
     * el mismo botón). Los dos primeros son una edición: la curva pasa a Custom, como tocar una
     * banda. «Reset equalizer» es elegir Flat (applyPreset). `reset` sigue para el IPC `eqReset`.
     *   resetBands    las diez bandas a 0 dB, el preamp como está
     *   resetPreamp   el preamp a 0 dB, las bandas como están (el aviso de saturación lo dirá)
     */
    function resetBands(dev) {
        const cur = root.view(dev);
        if (!cur.exists) return -1;
        return root.editCurve(dev, root.freqs.map(() => 0), cur.preamp);
    }
    function resetPreamp(dev) {
        const cur = root.view(dev);
        if (!cur.exists) return -1;
        return root.editCurve(dev, cur.bands, 0);
    }
    /** Baja el preamp hasta que el pico real no pase de 0 dB (el valor que sugiere el aviso). */
    function safePreamp(dev) {
        const cur = root.view(dev);
        if (!cur.exists || !cur.clipRisk) return -1;
        return root.editCurve(dev, cur.bands, cur.safePre);
    }

    function setCurve(dev, bands, preamp, extra) {
        if (!root.supported) return -1;
        const key = "curve:" + dev;
        const b = (bands || []).slice(0, 10).map(root.clampBand);
        while (b.length < 10) b.push(0);
        const pre = root.clampPre(preamp);
        const r = root.ops.request(key, { bands: b, preamp: pre });
        const p = root.profileOf(dev);
        if (!p) { root.ops.resolve(key, r, "error", "This output has no equalizer yet"); return r; }
        const all = root.copyProfiles();
        all[dev] = Object.assign(all[dev], extra || {});
        all[dev].bands = b;
        all[dev].preamp = pre;
        root.profiles = all;
        root.persistSoon();
        const f = root.filterOf(dev);
        if (!f) { root.ops.resolve(key, r, "ok", "", { bands: b, preamp: pre }); return r; }
        const id = String(f.id);
        const params = ["\"pre:Mult\"", Math.pow(10, pre / 20).toFixed(6)];
        for (let i = 0; i < 10; i++) params.push("\"b" + (i + 1) + ":Gain\"", b[i].toFixed(2));
        root.pushLive(id, params);
        root.ops.verifyLater(key, r, 300, ["pw-dump", id], (txt) => {
            try {
                const o = JSON.parse(txt).find(x => String(x.id) === id);
                const props = o.info.params.Props.find(x => x.params && x.params.indexOf("b1:Gain") >= 0).params;
                const got = (k) => props[props.indexOf(k) + 1];
                for (let i = 0; i < 10; i++)
                    if (Math.abs(got("b" + (i + 1) + ":Gain") - b[i]) > 0.05) return ["error", "PipeWire kept another curve", null];
                if (Math.abs(got("pre:Mult") - Math.pow(10, pre / 20)) > 0.001) return ["error", "PipeWire kept another preamp", null];
                return ["ok", "", { bands: b, preamp: pre }];
            } catch (e) { return ["error", "Could not read the equalizer", null]; }
        });
        return r;
    }

    /**
     * Escrituras en vivo agrupadas: arrastrar una banda son decenas de cambios por segundo y cada
     * uno sería un `pw-cli`. Se manda el último de cada filtro cada 40 ms; la comprobación
     * (verifyLater) mira la última revisión, así que un valor intermedio perdido no importa.
     */
    property var liveParams: ({})
    function pushLive(id, params) {
        const m = Object.assign({}, root.liveParams);
        m[id] = params;
        root.liveParams = m;
        if (!liveTimer.running) liveTimer.start();
    }
    Timer {
        id: liveTimer
        interval: 40
        onTriggered: {
            const m = root.liveParams;
            root.liveParams = ({});
            for (const id in m)
                root.run(["pw-cli", "set-param", id, "Props", "{ params = [ " + m[id].join(" ") + " ] }"], "live", 0);
        }
    }

    // ---- escritura y procesos ------------------------------------------------------------

    /**
     * Guardar la curva y el On/Off: 700 ms después del último cambio, en modo «auto» — sólo
     * reinicia si el archivo tenía OTRA estructura (medido en la 13D: con «never», este guardado
     * arregló en silencio una config rota sin reiniciar el proceso roto, y el Retry posterior ya
     * no vio nada que cambiar).
     */
    function persistSoon() { persistTimer.restart(); }
    /**
     * Antes de la fase 14: hay un cambio aún sin escribir en disco (el retardo de 700 ms o la
     * escritura en curso). La curva ya suena; esto sólo dice si el archivo la tiene ya.
     */
    readonly property bool saving: persistTimer.running || proc.writing || root.queue.some(j => j.tag.startsWith("write:"))
    Timer { id: persistTimer; interval: 700; onTriggered: root.writeProfiles(root.profiles, "", 0, "auto") }

    function writeProfiles(devs, key, rev, restart) {
        persistTimer.stop();
        root.profiles = devs;
        const doc = JSON.stringify({ version: 1, devices: devs });
        root.run(root.helperArgs(["write", "--restart", restart || "auto"]), "write:" + key, rev, doc);
    }

    /** Cola de procesos, uno a la vez y en orden (la última escritura gana). */
    property var queue: []
    function run(argv, tag, rev, stdin) {
        // Un set-param en cola para el mismo filtro queda obsoleto con el nuevo: se sustituye.
        const q = argv[0] === "pw-cli" && argv[1] === "set-param"
            ? root.queue.filter(j => !(j.argv[0] === "pw-cli" && j.argv[1] === "set-param" && j.argv[2] === argv[2]))
            : root.queue;
        root.queue = q.concat([{ argv: argv, tag: tag, rev: rev, stdin: stdin || "" }]);
        root.next();
    }
    function next() {
        if (proc.running || root.queue.length === 0) return;
        const j = root.queue[0];
        root.queue = root.queue.slice(1);
        proc.tag = j.tag;
        proc.rev = j.rev;
        proc.input = j.stdin;
        proc.stdinEnabled = j.stdin.length > 0;   // hay que reabrirlo en cada arranque (memoria)
        proc.command = j.argv;
        proc.running = true;
    }
    Process {
        id: proc
        property string tag: ""
        readonly property bool writing: proc.running && proc.tag.startsWith("write:")
        property int rev: 0
        property string input: ""
        stdout: StdioCollector { id: procOut }
        onStarted: if (proc.input.length > 0) { proc.write(proc.input); proc.stdinEnabled = false; }
        onExited: (code) => {
            const txt = procOut.text || "";
            let res = null;
            try { res = JSON.parse(txt.trim().split("\n").pop()); } catch (e) {}
            if (res && res.service) root.service = res.service;
            if (proc.tag.startsWith("write:")) {
                const key = proc.tag.substring(6);
                if (key.length > 0 && (!res || !res.ok) && root.ops.pending(key))
                    root.ops.resolve(key, proc.rev, "error", res && res.error ? res.error : "Could not save the equalizer");
            }
            root.next();
        }
    }

    /**
     * Cada filtro que aparece (arranque, reinicio, Retry) recibe en vivo lo que dice su perfil.
     * Cierra la carrera de tocar la curva mientras el servicio arranca: el proceso pudo leer el
     * archivo anterior a ese cambio, y el guardado siguiente no reinicia (mismo filtro).
     */
    property var synced: ({})
    function reconcile() {
        const seen = {};
        for (const dev in root.filters) {
            const f = root.filters[dev];
            const id = String(f.id);
            seen[dev] = id;
            if (root.synced[dev] === id) continue;
            const p = root.profileOf(dev);
            if (!p) continue;
            const params = ["\"pre:Mult\"", Math.pow(10, Number(p.preamp) / 20).toFixed(6)];
            for (let i = 0; i < 10; i++) params.push("\"b" + (i + 1) + ":Gain\"", Number(p.bands[i]).toFixed(2));
            root.run(["pw-cli", "set-param", id, "Props", "{ params = [ " + params.join(" ") + " ] }"], "live", 0);
            root.run(["pw-metadata", "-n", "filters", "--", id, "filter.smart.disabled", p.enabled ? "false" : "true"], "live", 0);
        }
        root.synced = seen;
    }

    // El servicio puede caer por su cuenta: si un filtro que había desaparece, se relee.
    onFiltersChanged: { serviceDelay.restart(); reconcileDelay.restart(); }
    Timer { id: reconcileDelay; interval: 250; onTriggered: root.reconcile() }
    Timer { id: serviceDelay; interval: 400; onTriggered: root.refreshService() }
    Component.onCompleted: root.refreshService()

    /** Para el IPC `eqState`. */
    function summary() {
        const out = {};
        const devs = Object.keys(root.profiles);
        for (const s of Mixer.sinks) if (devs.indexOf(String(s.name)) < 0) devs.push(String(s.name));
        for (const d of devs) {
            const p = root.profileOf(d);
            const f = root.filterOf(d);
            out[d] = Object.assign({ filter: f ? f.id : -1 }, root.stateOf(d),
                                   p ? { enabled: p.enabled, preset: p.preset, bands: p.bands, preamp: p.preamp,
                                         clipRisk: root.view(d).clipRisk, peak: root.view(d).peak } : {});
        }
        return { testing: root.testing, supported: root.supported, reason: root.whyNot,
                 service: root.service, loaded: root.loaded, readError: root.readError, saving: root.saving,
                 profilesPath: root.profilesPath, devices: out, queue: root.queue.length };
    }
}
