import QtQuick
import Quickshell
import Quickshell.Io
import "../components"

/**
 * Los datos del panel del Lock (fase 15, entrega 15D; futurelocksurface §8 «Métricas», §9 «Widgets y
 * degradación», §11 «Datos y loaders»). UNO por sesión de bloqueo —no uno por pantalla—: las
 * reclamaciones las decide el número de consumidores visibles, no el de objetos QML (§9 «Varias
 * pantallas»).
 *
 * Separado de `LockSession` a propósito: aquí no hay nada de autenticación, y la autenticación no
 * espera nunca a nada de aquí (criterio 8). Un dato que falla se queda en su tarjeta.
 *
 * Reclama SÓLO mientras `active` (panel a la vista, fuera de la calma): clima (`Weather.claim`, la
 * caché y la suscripción compartidas con Calendar, 7D), métricas (`Sysmon.claim("lock:…")`, que no
 * cae con `Session.idle`: LK-13) y el disco raíz (`df /` cada minuto). En calma suelta todo y conserva
 * lo último: al despertar se enseña como viejo hasta la muestra nueva (§11).
 *
 * Contrato (lo mismo que finge la preview): `fetch`, `weather`, `metrics`, `notifs`, `music`,
 * `privacy`, `avatarSource`, `fetchImageSource`. Nada de esto se escribe a disco.
 */
Item {
    id: root

    /** Panel a la vista y fuera de la calma. */
    property bool active: false
    /** Nombre de la reclamación (varias instancias no se pisan). */
    property string who: "lock"

    // ── reclamaciones ─────────────────────────────────────────────────────────
    Claim { target: Weather; key: "lock:" + root.who; value: root.active }
    Claim { target: Sysmon; key: "lock:" + root.who; value: root.active ? "summary" : "" }

    // ── reloj propio: sólo para envejecer lo mostrado, y sólo mientras se ve ──
    property real now: Date.now()
    Timer { interval: 5000; repeat: true; running: root.active; onTriggered: root.now = Date.now() }
    onActiveChanged: {
        root.now = Date.now();
        if (root.active) {
            if (Sysmon.current) root.lastSample = Sysmon.current;
            diskProbe.running = true;
            root.checkImages();
        }
    }

    // ── fetch (LK-09: por el contrato; sin memoria, LOCK-D14) ─────────────────
    readonly property var fetch: ({ os: SystemInfo.os, kernel: SystemInfo.kernel, wm: SystemInfo.wm,
                                   shell: SystemInfo.shell, cpu: SystemInfo.cpu, gpu: SystemInfo.gpu })
    Component.onCompleted: { SystemInfo.load(); root.checkImages(); }

    // ── imágenes: sólo rutas locales, comprobadas antes de dárselas a una Image ─
    // (una ruta rota dejaría «Cannot open» en el journal con la sesión bloqueada)
    function localPath(p) {
        const s = String(p || "").trim();
        if (s.length === 0 || s.indexOf("://") >= 0 || s.indexOf("data:") === 0) return "";
        if (s === "~") return Quickshell.env("HOME");
        if (s.indexOf("~/") === 0) return Quickshell.env("HOME") + s.slice(1);
        return s.indexOf("/") === 0 ? s : "";
    }
    readonly property string avatarCandidate: root.localPath(Settings.lockAvatar) || (Quickshell.env("HOME") + "/.face")
    readonly property string fetchCandidate: root.localPath(Settings.lockFetchImage)
        || (Quickshell.env("HOME") + "/.config/fastfetch/fastfetchlogo/minimaru.png")
    property string avatarSource: ""
    property string fetchImageSource: ""
    onAvatarCandidateChanged: root.checkImages()
    onFetchCandidateChanged: root.checkImages()
    function checkImages() { avatarProbe.running = true; fetchProbe.running = true; }
    Process { id: avatarProbe; command: ["test", "-r", root.avatarCandidate]
        onExited: (code) => root.avatarSource = code === 0 ? root.avatarCandidate : "" }
    Process { id: fetchProbe; command: ["test", "-r", root.fetchCandidate]
        onExited: (code) => root.fetchImageSource = code === 0 ? root.fetchCandidate : "" }

    // ── clima (LOCK-D16) ───────────────────────────────────────────────────────
    readonly property var weather: {
        void root.now;
        const st = Weather.state;
        if (st !== "ok" && st !== "stale")
            return { state: st };
        const c = Weather.data.current || {};
        const h = new Date().getHours();
        const cond = Weather.condition(c.code, h < 6 || h >= 20);
        return { state: st, temp: Weather.temp(c.temp), condition: cond.text, icon: cond.icon,
                 humidity: typeof c.humidity === "number" ? Math.round(c.humidity) : null,
                 place: Weather.location ? (Weather.location.name || "") : "",
                 age: st === "stale" ? Weather.ageText() : "" };
    }

    // ── métricas (LOCK-D09) ────────────────────────────────────────────────────
    /** La última muestra VISTA: se conserva en calma para enseñarla como vieja al despertar. */
    property var lastSample: null
    Connections {
        target: Sysmon
        function onCurrentChanged() { if (Sysmon.current && root.active) root.lastSample = Sysmon.current; }
    }
    /** Más de tres intervalos de summary (5 s) sin muestra nueva, o el recolector con error: viejo. */
    readonly property bool sampleStale: root.lastSample === null ? false
        : (root.now - (root.lastSample.at || 0) > 15000) || Sysmon.error.length > 0 || !root.active
    function gib(b) { return (b / 1073741824).toFixed(1); }
    function known(v) { return typeof v === "number" && isFinite(v); }
    function metric(value, unit, frac, sub, note) {
        if (root.lastSample === null) return { state: "loading" };
        if (!root.known(value)) return { state: "unavailable" };
        return { state: root.sampleStale ? "stale" : "ok", value: value, unit: unit,
                 frac: frac, sub: sub || "", note: note || "" };
    }
    readonly property var metrics: {
        const s = root.lastSample;
        const c = s ? (s.cpu || {}) : {};
        const m = s ? (s.memory || {}) : {};
        // la primera muestra no trae uso (hace falta un delta): cargando, no «no disponible»
        const cpu = s && c.usagePct === null && root.lastSample.intervalMs === null ? { state: "loading" }
            : root.metric(c.usagePct, "%", root.known(c.usagePct) ? c.usagePct / 100 : null,
                          c.logicalCount ? c.logicalCount + " threads" : "");
        // límite válido (0–200 °C, como el monitor): arco de 20 °C al límite; sin él, arco neutro
        const lim = root.known(c.temperatureCriticalC) && c.temperatureCriticalC > 20 && c.temperatureCriticalC <= 200
            ? c.temperatureCriticalC
            : (root.known(c.temperatureMaxC) && c.temperatureMaxC > 20 && c.temperatureMaxC <= 200 ? c.temperatureMaxC : null);
        const t = c.temperatureC;
        const temp = root.metric(t, "°C", lim !== null && root.known(t) ? (t - 20) / (lim - 20) : null,
                                 lim !== null ? "Limit " + Math.round(lim) + " °C" : "No limit reported",
                                 lim !== null ? "Arc from 20 to " + Math.round(lim) + " degrees, the sensor's limit"
                                              : "The sensor reports no limit, so the arc stays neutral");
        const ram = root.metric(m.usedPct, "%", root.known(m.usedPct) ? m.usedPct / 100 : null,
                                root.known(m.usedB) && root.known(m.totalB) ? root.gib(m.usedB) + " / " + root.gib(m.totalB) + " GiB" : "");
        return { cpu: cpu, cpuTemp: temp, ram: ram, disk: root.disk };
    }

    // ── disco raíz: `df /`, sin tocar el nivel del recolector ─────────────────
    property var disk: ({ state: "loading" })
    Timer { interval: 60000; repeat: true; running: root.active; onTriggered: diskProbe.running = true }
    Process {
        id: diskProbe
        command: ["df", "-P", "-B1", "/"]
        stdout: StdioCollector { id: diskOut }
        onExited: (code) => {
            const line = String(diskOut.text || "").trim().split("\n")[1] || "";
            const f = line.split(/\s+/);
            const used = Number(f[2]), avail = Number(f[3]);
            if (code !== 0 || !root.known(used) || !root.known(avail) || used + avail <= 0) {
                root.disk = root.disk.state === "ok" ? Object.assign({}, root.disk, { state: "stale" }) : { state: "unavailable" };
                return;
            }
            const pct = 100 * used / (used + avail);   // como el Use% de df: sobre lo disponible al usuario
            root.disk = { state: "ok", value: pct, unit: "%", frac: pct / 100,
                          sub: root.gib(used) + " / " + root.gib(used + avail) + " GiB",
                          note: "Root partition /" };
        }
    }

    // ── notificaciones (LOCK-D08/D12/D17) ─────────────────────────────────────
    /** Texto plano: sin etiquetas ni entidades (§8: el texto es contenido, nunca enlaces ni markup). */
    function plain(t) {
        return String(t || "").replace(/<br\s*\/?>/gi, "\n").replace(/<[^>]*>/g, "")
            .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'")
            .replace(/&amp;/g, "&");
    }
    /**
     * Las NO LEÍDAS de la misma fuente que el contador de siempre (`NotifHistory`), agrupadas por
     * aplicación. Nada de aquí marca como leído: sólo se lee `entries`.
     */
    readonly property var notifs: {
        if (!Notifs.enabled)
            return { state: "unavailable", count: 0, groups: [] };
        void NotifHistory.revision;
        const groups = {};
        const order = [];
        const list = NotifHistory.entries || [];
        for (let i = 0; i < list.length; i++) {
            const e = list[i];
            if (!NotifHistory.isUnread(e)) continue;
            const name = e.app && e.app.length > 0 ? e.app : (e.desktopEntry || "Unknown app");
            const k = name.toLowerCase();
            if (!groups[k]) { groups[k] = { app: k, name: name, count: 0, items: [], newest: 0 }; order.push(k); }
            const g = groups[k];
            g.count++;
            g.newest = Math.max(g.newest, e.time || 0);
            g.items.push({ id: e.key, title: root.plain(e.summary), body: root.plain(e.body), time: e.time || 0 });
        }
        const out = order.map(function (k) { return groups[k]; });
        out.forEach(function (g) { g.items.sort(function (a, b) { return b.time - a.time; }); });
        out.sort(function (a, b) { return b.newest - a.newest; });
        return { state: "ok", count: out.reduce(function (t, g) { return t + g.count; }, 0), groups: out };
    }

    // ── música (LOCK-D13: sin Cava) y privacidad (LOCK-D20: micrófono y pantalla) ─
    readonly property var music: ({
        has: Media.has, playing: Media.playing, title: Media.title, artist: Media.artist,
        artUrl: Media.artUrl, canPrev: Media.canPrev, canToggle: Media.canToggle, canNext: Media.canNext
    })
    /** La cámara NO se pinta como pantalla (LK-14). */
    readonly property var privacy: ({ mic: Privacy.micActive, screen: Privacy.screenActive })

    /** Para `status()`/IPC: cuántos consumidores reclama y qué estado tiene cada dato, sin contenido. */
    function summary() {
        return { active: root.active, weather: root.weather.state, metrics: {
                     cpu: root.metrics.cpu.state, cpuTemp: root.metrics.cpuTemp.state,
                     ram: root.metrics.ram.state, disk: root.metrics.disk.state },
                 notifs: { state: root.notifs.state, count: root.notifs.count, groups: root.notifs.groups.length },
                 music: root.music.has, avatar: root.avatarSource.length > 0, fetchImage: root.fetchImageSource.length > 0 };
    }
}
