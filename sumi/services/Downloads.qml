pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/xdg.js" as Xdg

/**
 * Descargas de Wallhaven (rediseño 10D-1; futureWallpaper-listsurface «Continuidad de las
 * descargas», «Después de descargar»). Un gestor COMPARTIDO fuera de cualquier Loader: cerrar
 * Wallpaper List no pausa ni cancela nada; al volver, la vista mira el mismo trabajo por su id.
 *
 *   · Un TRABAJO agrupa archivos (hoy uno; «Download collection» de la 10E-2, muchos). Cada
 *     trabajo es una operación de `Operations` (tipo "download"): id, estado y, tras un reinicio,
 *     «unknown» — nunca se afirma que una transferencia sobrevivió al proceso.
 *   · Como mucho DOS archivos a la vez en total (`maxParallel`), con curl, a un temporal en
 *     `~/.cache/sumi-shell/downloads/<id>.part`: fuera de la biblioteca, así que el escaneo no
 *     lo ve nunca. Mismo sistema de archivos que la biblioteca: el paso final es un `mv -n`.
 *   · VALIDACIÓN antes de entrar: tamaño = el que dio la API, tipo MIME = el formato anunciado,
 *     dimensiones = las anunciadas (`identify -ping`). Si no, el temporal se borra y el archivo
 *     falla con el motivo. Nombre estable: `wallhaven-<id>.<ext>`; si ya hay uno con ese id
 *     (también `wallhaven-<id>_WxH.png`, de los bajados a mano) → «Already in your library».
 *   · Falta de espacio (antes de empezar, y un error de escritura) → «Download paused: not enough
 *     space»; 429 → pausa todo hasta `Retry-After` y sigue solo; Cancel mata lo que corre y borra
 *     SÓLO sus temporales (lo terminado se queda); Retry pending vuelve a poner en cola lo fallido,
 *     cancelado, pausado o interrumpido, sin duplicar lo que ya está.
 *   · Registro `$XDG_STATE_HOME/sumi-shell/downloads.json` en cada cambio (onDestruction no
 *     corre con SIGTERM). Al cargar: lo que estaba vivo pasa a «interrupted» (o a «done» si el
 *     archivo final existe) y se borran los temporales; Retry pending lo retoma.
 *   · DESCARGAR NUNCA APLICA: sólo Apply now (la vista) llama a `Wallpaper.apply`.
 *
 * Pruebas: `testDir` (IPC `dlTestDir`, sólo bajo /tmp/) lleva registro y temporales a esa carpeta;
 * con Wallhaven en pruebas, la carpeta de destino TIENE que estar bajo /tmp/ o no se descarga.
 * `testFreeBytes` finge el espacio libre.
 */
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME")
    readonly property string stateDir: Xdg.base(Quickshell.env("XDG_STATE_HOME"), root.home + "/.local/state") + "/sumi-shell"
    property string testDir: ""
    readonly property string registryPath: (root.testDir.length > 0 ? root.testDir : root.stateDir) + "/downloads.json"
    readonly property string tempDir: root.testDir.length > 0 ? root.testDir + "/tmp" : Wallpaper.tempDir + "/downloads"
    readonly property int maxParallel: 2
    /** Tope por archivo (los originales de Wallhaven rondan unos MB; 100 MB es un disparate). */
    readonly property int maxBytes: 100 * 1024 * 1024
    /** Margen que se deja libre además del archivo. */
    readonly property int spaceMargin: 64 * 1024 * 1024
    /** Pruebas: si > -1, el espacio libre que se «mide». */
    property real testFreeBytes: -1

    /** [{ id, label, source, createdAt, opId, finishedAt }] (más nuevo delante; máx. 20). */
    property var jobs: []
    /**
     * { whId: { id, job, url, ext, bytes, width, height, mime, state, got, reason, dest, at } }
     * state: queued · running · validating · done · exists · failed · cancelled · paused · interrupted
     */
    property var items: ({})
    property bool loaded: false
    property real limitedUntil: 0

    signal finished(string id, string path)

    // ---- consultas ----------------------------------------------------------------

    readonly property var activeStates: ["queued", "running", "validating"]
    function itemOf(id) { void root.items; return root.items[id] || null; }
    function itemsOf(jobId) {
        const out = [];
        for (const k in root.items) if (root.items[k].job === jobId) out.push(root.items[k]);
        return out;
    }
    function count(states) {
        let n = 0;
        for (const k in root.items) if (states.indexOf(root.items[k].state) >= 0) n++;
        return n;
    }
    readonly property int runningCount: { void root.items; return root.count(["running", "validating"]); }
    readonly property int queuedCount: { void root.items; return root.count(["queued"]); }
    readonly property int pausedCount: { void root.items; return root.count(["paused"]); }
    readonly property bool busy: root.runningCount + root.queuedCount > 0

    /** El estado de un trabajo, derivado de sus archivos. */
    function jobState(jobId) {
        const l = root.itemsOf(jobId);
        if (l.length === 0) return "done";
        const has = (s) => l.some(i => i.state === s);
        if (has("running") || has("validating")) return "running";
        if (has("queued")) return "queued";
        if (has("paused")) return "paused";
        if (has("interrupted")) return "interrupted";
        if (has("failed")) return "failed";
        if (has("cancelled")) return l.some(i => i.state === "done") ? "partial" : "cancelled";
        return "done";
    }
    function jobSummary(jobId) {
        const l = root.itemsOf(jobId);
        const c = (s) => l.filter(i => i.state === s).length;
        // 10E-2: los omitidos de una colección se cuentan en el trabajo (no tienen entrada propia)
        const j = root.jobById(jobId);
        const skipped = j && j.skipped > 0 ? j.skipped : 0;
        return { total: l.length + skipped, done: c("done"), exists: c("exists") + skipped, running: c("running") + c("validating"),
                 queued: c("queued"), failed: c("failed"), cancelled: c("cancelled"), paused: c("paused"),
                 interrupted: c("interrupted") };
    }
    /** El trabajo más reciente de una colección (o null). */
    function jobOfCollection(cid) {
        for (let i = 0; i < root.jobs.length; i++) if (root.jobs[i].collectionId === String(cid)) return root.jobs[i];
        return null;
    }
    /** «3/28 downloaded · 2 in progress · 2 skipped · 1 failed» (la spec: descargadas/total, en curso, omitidas, errores). */
    function progressText(jobId) {
        const c = root.jobSummary(jobId);
        const parts = [c.done + "/" + (c.total - c.exists) + " downloaded"];
        if (c.running > 0) parts.push(c.running + " in progress");
        if (c.queued > 0) parts.push(c.queued + " queued");
        if (c.exists > 0) parts.push(c.exists + " already here");
        if (c.failed > 0) parts.push(c.failed + " failed");
        if (c.paused > 0) parts.push(c.paused + " paused");
        if (c.cancelled > 0) parts.push(c.cancelled + " cancelled");
        if (c.interrupted > 0) parts.push(c.interrupted + " interrupted");
        return parts.join(" · ");
    }

    function jobById(id) {
        for (let i = 0; i < root.jobs.length; i++) if (root.jobs[i].id === id) return root.jobs[i];
        return null;
    }

    // ---- empezar --------------------------------------------------------------------

    /** Por qué no se puede descargar ahora mismo (o ""). */
    function blocker() {
        if (!root.loaded) return "Downloads are still loading";
        // F2c: curl e identify (ImageMagick) bajan y validan; sin ellos no se empieza nada
        if (!Capabilities.can("wallpaper.download")) return Capabilities.why("wallpaper.download");
        const st = Wallpaper.downloadDirState;
        if (st === "notSource") return "Choose a download folder in Settings · Theme · Wallpaper";
        if (st === "notWritable") return "The download folder is read only";
        if (st === "missing") return "The download folder is missing";
        if (Wallhaven.testing && Wallpaper.downloadDir.indexOf("/tmp/") !== 0)
            return "Test downloads only go to a /tmp folder";
        return "";
    }

    /** La URL del archivo completo, sólo del host permitido y con el nombre que corresponde al id. */
    function validUrl(r) {
        const u = String(r.path || "");
        if (u.indexOf(Wallhaven.filePrefix) !== 0) return false;
        const name = u.substring(u.lastIndexOf("/") + 1);
        return Wallhaven.testing ? name === r.id + ".png"
                                 : new RegExp("^wallhaven-" + r.id + "\\.(png|jpg|jpeg)$").test(name);
    }

    /**
     * Descargar UN resultado de Wallhaven. Devuelve { ok, state, reason, job }. Ya instalado →
     * «exists» sin bajar nada; ya en cola o bajando → el mismo trabajo.
     */
    function download(r, ctx) {
        if (!r || !/^[a-z0-9]{1,12}$/.test(String(r.id))) return { ok: false, reason: "Nothing to download" };
        const cur = root.items[r.id];
        if (cur && root.activeStates.indexOf(cur.state) >= 0) return { ok: true, state: cur.state, job: cur.job };
        if (Wallhaven.installed(r.id)) {
            // 10E-1b: ya está; si viene de una colección, se anota la asociación SIN otra copia
            if (ctx && ctx.collectionId) WallhavenIndex.record(r.id, Wallhaven.installedPath(r.id), ctx);
            return { ok: true, state: "exists", reason: "Already in your library" };
        }
        const why = root.blocker();
        if (why.length > 0) return { ok: false, reason: why };
        if (!root.validUrl(r)) return { ok: false, reason: "Wallhaven gave an unexpected file address" };
        const ext = r.path.substring(r.path.lastIndexOf(".") + 1).toLowerCase() === "png" ? "png" : "jpg";
        const jobId = "dl-" + Date.now().toString(36) + "-" + r.id;
        const op = Operations.begin("download", "download:" + jobId, "wallpaper", r.id, "", {});
        root.jobs = [{ id: jobId, label: "wallhaven-" + r.id, source: "search", createdAt: Date.now(),
                       opId: op.id || "", finishedAt: 0 }].concat(root.jobs).slice(0, 20);
        root.setItem(r.id, { id: r.id, job: jobId, url: r.path, ext: ext, bytes: r.bytes || 0,
                             width: r.width || 0, height: r.height || 0,
                             mime: ext === "png" ? "image/png" : "image/jpeg",
                             state: "queued", got: 0, reason: "", dest: "", at: Date.now(),
                             ctx: ctx && ctx.collectionId ? { collectionId: String(ctx.collectionId),
                                 collectionName: String(ctx.collectionName || ""), account: String(ctx.account || ""),
                                 public: ctx.public !== false } : null });
        root.pump();
        return { ok: true, state: "queued", job: jobId };
    }

    // ---- Download collection (10E-2) ------------------------------------------------------

    /**
     * La preparación de «Download collection»: se recorren TODAS las páginas de la colección con el
     * Content elegido (también las que no se han abierto), una tras otra y espaciadas (Wallhaven
     * admite ~45 peticiones por minuto; un 429 pausa y sigue tras `Retry-After`). Con la lista
     * completa, la confirmación dice qué se va a hacer; nada se baja antes de confirmar.
     *   state: listing · limited · ready · failed
     *   { state, reason, collection, account, purity, page, lastPage, items: [resultado…], installed }
     */
    property var prep: null
    property var prepXhr: null
    readonly property int pageGapMs: Wallhaven.testing ? 150 : 1500

    function prepareCollection(c) {
        if (!c) return false;
        const why = root.blocker();
        if (why.length > 0) { root.prep = { state: "failed", reason: why, collection: c, items: [], page: 0, lastPage: 0, installed: 0 }; return false; }
        if (Wallhaven.accountProblem.length > 0) { root.prep = { state: "failed", reason: Wallhaven.accountProblem, collection: c, items: [], page: 0, lastPage: 0, installed: 0 }; return false; }
        root.cancelPrep();
        root.prep = { state: "listing", reason: "", collection: c, account: Settings.wallhavenUser,
                      purity: Wallhaven.draft.purity, page: 0, lastPage: 0, items: [], installed: 0 };
        root.fetchPrepPage(1);
        return true;
    }
    function cancelPrep() {
        if (root.prepXhr) { try { root.prepXhr.abort(); } catch (e) {} root.prepXhr = null; }
        prepGap.stop();
        root.prep = null;
    }
    function setPrep(fields) { root.prep = Object.assign({}, root.prep, fields); }

    function fetchPrepPage(n) {
        const p = root.prep;
        if (!p) return;
        const x = new XMLHttpRequest();
        root.prepXhr = x;
        Wallhaven.requests++;
        const url = Wallhaven.apiBase + "/collections/" + encodeURIComponent(p.account) + "/"
            + encodeURIComponent(p.collection.id) + "?purity=" + encodeURIComponent(p.purity) + "&page=" + n;
        Wallhaven.lastUrl = url;
        x.onreadystatechange = function () {
            if (x.readyState !== XMLHttpRequest.DONE || x !== root.prepXhr) return;
            root.prepXhr = null;
            if (!root.prep) return;
            if (x.status === 429) {
                // se pausa la obtención de páginas y se reintenta después
                const ra = parseInt(x.getResponseHeader("Retry-After") || "");
                const wait = (ra > 0 && ra < 3600 ? ra : 60) * 1000;
                root.setPrep({ state: "limited", reason: "Wallhaven rate limit · continuing in " + Math.round(wait / 1000) + " s" });
                prepGap.next = n;
                prepGap.interval = wait;
                prepGap.restart();
                return;
            }
            if (x.status !== 200) {
                root.setPrep({ state: "failed", reason: x.status === 0 ? "Wallhaven unavailable · no connection"
                    : x.status === 401 ? "Wallhaven rejected the API key" : "Wallhaven answered HTTP " + x.status });
                return;
            }
            let o = null;
            try { o = JSON.parse((x.responseText || "").substring(0, Wallhaven.maxResponseBytes)); } catch (e) { o = null; }
            if (!o || !Array.isArray(o.data)) { root.setPrep({ state: "failed", reason: "Wallhaven's answer could not be read" }); return; }
            const got = root.prep.items.slice();
            const seen = {};
            for (let i = 0; i < got.length; i++) seen[got[i].id] = true;
            for (let i = 0; i < o.data.length; i++) {
                const r = Wallhaven.clean(o.data[i]);
                if (r && !seen[r.id]) { got.push(r); seen[r.id] = true; }
            }
            const last = Math.max(1, parseInt(o.meta && o.meta.last_page) || 1);
            root.setPrep({ state: "listing", reason: "", page: n, lastPage: last, items: got });
            if (n < last && n < 200) {
                prepGap.next = n + 1;
                prepGap.interval = root.pageGapMs;
                prepGap.restart();
            } else {
                let installed = 0;
                for (let i = 0; i < got.length; i++) if (Wallhaven.installed(got[i].id)) installed++;
                root.setPrep({ state: "ready", installed: installed });
            }
        };
        x.open("GET", url);
        x.setRequestHeader("Accept", "application/json");
        Wallhaven.authorize(x);
        x.send();
    }
    Timer {
        id: prepGap
        property int next: 1
        onTriggered: if (root.prep) { root.setPrep({ state: "listing", reason: "" }); root.fetchPrepPage(prepGap.next); }
    }

    /**
     * Confirmado: UN trabajo con todos los archivos. Los que ya están se anotan en el índice con
     * esta colección y cuentan como omitidos («exists»); el resto, a la cola de siempre (dos a la
     * vez, validación, Cancel, Retry pending, espacio, 429).
     */
    function confirmCollection() {
        const p = root.prep;
        if (!p || p.state !== "ready") return "";
        const why = root.blocker();
        if (why.length > 0) { root.setPrep({ state: "failed", reason: why }); return ""; }
        const c = p.collection;
        const ctx = { collectionId: c.id, collectionName: c.label, account: p.account, public: c.public };
        const jobId = "dl-" + Date.now().toString(36) + "-c" + c.id;
        const op = Operations.begin("download", "download:" + jobId, "wallpaper", "collection:" + c.id, "", {});
        root.jobs = [{ id: jobId, label: "Collection · " + c.label, source: "collection", collectionId: c.id,
                       createdAt: Date.now(), opId: op.id || "", finishedAt: 0, purity: p.purity }].concat(root.jobs).slice(0, 20);
        const m = Object.assign({}, root.items);
        const now = Date.now();
        let skipped = 0;
        for (let i = 0; i < p.items.length; i++) {
            const r = p.items[i];
            const cur = m[r.id];
            if (cur && root.activeStates.indexOf(cur.state) >= 0) continue;   // ya en camino (otro trabajo)
            if (Wallhaven.installed(r.id)) {
                // se anota la asociación y se CUENTA en el trabajo; la entrada del archivo no se toca
                // (si no, otra colección con el mismo fondo se lo quitaba a la primera: medido)
                WallhavenIndex.record(r.id, Wallhaven.installedPath(r.id), ctx);
                skipped++;
                continue;
            }
            if (!root.validUrl(r)) {
                m[r.id] = { id: r.id, job: jobId, url: "", ext: "", bytes: 0, width: 0, height: 0, mime: "",
                            state: "failed", got: 0, reason: "Wallhaven gave an unexpected file address", dest: "", at: now + i, ctx: ctx };
                continue;
            }
            const ext = r.path.substring(r.path.lastIndexOf(".") + 1).toLowerCase() === "png" ? "png" : "jpg";
            m[r.id] = { id: r.id, job: jobId, url: r.path, ext: ext, bytes: r.bytes || 0, width: r.width || 0,
                        height: r.height || 0, mime: ext === "png" ? "image/png" : "image/jpeg",
                        state: "queued", got: 0, reason: "", dest: "", at: now + i, ctx: ctx };
        }
        root.items = m;
        root.jobs = root.jobs.map(j => j.id === jobId ? Object.assign({}, j, { skipped: skipped }) : j);
        root.save();
        root.prep = null;
        root.settleJob(jobId);
        root.pump();
        return jobId;
    }

    // ---- la cola ----------------------------------------------------------------------

    function setItem(id, obj) {
        const m = Object.assign({}, root.items);
        m[id] = obj;
        root.items = m;
        root.save();
    }
    function patch(id, fields) {
        const cur = root.items[id];
        if (!cur) return;
        root.setItem(id, Object.assign({}, cur, fields));
        root.settleJob(cur.job);
    }

    /** Arranca lo que quepa: como mucho dos, y nada mientras dura un 429. */
    function pump() {
        if (!root.loaded) return;
        if (root.limitedUntil > Date.now()) return;
        for (let s = 0; s < slots.length; s++) {
            const slot = slots[s];
            if (slot.busy) continue;
            let next = null;
            for (const k in root.items) {
                const it = root.items[k];
                if (it.state === "queued" && (!next || it.at < next.at)) next = it;
            }
            if (!next) return;
            slot.begin(next);
        }
    }

    /** Cierra la operación de un trabajo cuando ya no le queda nada vivo. */
    function settleJob(jobId) {
        const j = root.jobById(jobId);
        if (!j) return;
        const st = root.jobState(jobId);
        if (["running", "queued", "paused"].indexOf(st) >= 0) return;
        if (j.opId && Operations.isLive(Operations.get(j.opId)))
            Operations.end(j.opId, st === "done" ? "succeeded" : st === "failed" ? "failed"
                                 : st === "interrupted" ? "unknown" : "cancelled", "");
        if (!j.finishedAt) {
            root.jobs = root.jobs.map(x => x.id === jobId ? Object.assign({}, x, { finishedAt: Date.now() }) : x);
            root.save();
        }
    }

    /** Cancel: lo que corre se mata y su temporal se borra; lo terminado se queda. */
    function cancel(jobId) {
        let any = false;
        for (const k in root.items) {
            const it = root.items[k];
            if (it.job !== jobId) continue;
            if (it.state === "queued" || it.state === "paused") { root.patch(it.id, { state: "cancelled", reason: "Cancelled" }); any = true; }
            else if (it.state === "running" || it.state === "validating") {
                for (let s = 0; s < slots.length; s++) if (slots[s].itemId === it.id) slots[s].stop();
                any = true;
            }
        }
        return any;
    }

    /** Retry pending: lo fallido, cancelado, pausado o interrumpido vuelve a la cola (sin duplicar). */
    function retry(jobId) {
        const why = root.blocker();
        if (why.length > 0) return false;
        let any = false;
        for (const k in root.items) {
            const it = root.items[k];
            if (it.job !== jobId || ["failed", "cancelled", "paused", "interrupted"].indexOf(it.state) < 0) continue;
            if (Wallhaven.installed(it.id)) root.patch(it.id, { state: "exists", reason: "Already in your library" });
            else root.patch(it.id, { state: "queued", reason: "", got: 0, at: Date.now() });
            any = true;
        }
        if (any) {
            const j = root.jobById(jobId);
            if (j && (!j.opId || !Operations.isLive(Operations.get(j.opId)))) {
                const op = Operations.begin("download", "download:" + jobId, "wallpaper", "", "", {});
                root.jobs = root.jobs.map(x => x.id === jobId ? Object.assign({}, x, { opId: op.id || "", finishedAt: 0 }) : x);
            }
            root.pump();
        }
        return any;
    }

    /** Quitar de la lista los trabajos terminados (no borra archivos). */
    function clearFinished() {
        const keep = root.jobs.filter(j => ["running", "queued", "paused"].indexOf(root.jobState(j.id)) >= 0);
        const ids = keep.map(j => j.id);
        const m = {};
        for (const k in root.items) if (ids.indexOf(root.items[k].job) >= 0) m[k] = root.items[k];
        root.jobs = keep;
        root.items = m;
        root.save();
    }

    Timer {
        id: limitTimer
        onTriggered: {
            // el 429 venció: lo pausado por el límite vuelve a la cola
            for (const k in root.items)
                if (root.items[k].state === "paused" && root.items[k].reason.indexOf("rate limit") >= 0)
                    root.patch(k, { state: "queued", reason: "" });
            root.pump();
        }
    }

    // ---- una ranura de descarga ------------------------------------------------------------

    component Slot: QtObject {
        id: slot
        property string itemId: ""
        property bool stopping: false
        property real need: 0
        readonly property bool busy: itemId.length > 0

        /** El espacio libre en el temporal y en el destino (el menor de los dos). */
        property Process spaceProc: Process {
            stdout: StdioCollector {
                onStreamFinished: {
                    const nums = this.text.split(/\s+/).filter(x => x.length > 0).map(x => parseFloat(x));
                    let avail = nums.length > 0 ? Math.min.apply(null, nums) : 0;
                    if (root.testFreeBytes > -1) avail = root.testFreeBytes;
                    slot.afterSpace(avail >= slot.need, avail);
                }
            }
        }
        readonly property string part: root.tempDir + "/" + slot.itemId + ".part"

        function begin(it) {
            slot.itemId = it.id;
            slot.stopping = false;
            root.patch(it.id, { state: "running", reason: "", got: 0 });
            slot.need = (it.bytes > 0 ? it.bytes : 20 * 1024 * 1024) + root.spaceMargin;
            slot.spaceProc.command = ["sh", "-c", 'mkdir -p -- "$1" && df --output=avail -B1 -- "$1" "$2" | tail -n +2',
                                      "_", root.tempDir, Wallpaper.downloadDir];
            slot.spaceProc.running = true;
        }
        function afterSpace(ok, avail) {
            const it = root.items[slot.itemId];
            if (!it) { slot.itemId = ""; return; }
            if (slot.stopping) { slot.finish("cancelled", "Cancelled"); return; }
            if (!ok) { slot.finish("paused", "Download paused: not enough space"); return; }
            const test = Wallhaven.testing;
            // --no-buffer: escribe según llega (si no, curl junta ~16 kB y el progreso va a saltos;
            // con los 7,7 kB del Wallhaven falso no avanzaba nada hasta el final — medido)
            slot.curl.command = ["curl", "-sS", "--no-buffer", "--proto", test ? "=http" : "=https", "--max-redirs", "0",
                            "--connect-timeout", "15", "--max-time", "900",
                            "--max-filesize", String(root.maxBytes),
                            "-o", slot.part, "-w", "%{http_code} %{size_download} %header{retry-after}", "--", it.url];
            slot.curl.running = true;
            slot.progress.start();
        }
        function stop() {
            slot.stopping = true;
            if (slot.curl.running) slot.curl.signal(15);
        }
        function finish(state, reason, extra) {
            slot.progress.stop();
            const id = slot.itemId;
            slot.itemId = "";
            // un temporal nunca se queda (ni si falló ni si se canceló)
            Quickshell.execDetached(["rm", "-f", "--", root.tempDir + "/" + id + ".part"]);
            root.patch(id, Object.assign({ state: state, reason: reason }, extra || {}));
            Qt.callLater(root.pump);
        }

        property Process curl: Process {
            stdout: StdioCollector { id: curlOut }
            stderr: StdioCollector { id: curlErr }
            onExited: function (code) {
                const it = root.items[slot.itemId];
                if (!it) { slot.itemId = ""; slot.progress.stop(); return; }
                if (slot.stopping) { slot.finish("cancelled", "Cancelled"); return; }
                const w = curlOut.text.trim().split(" ");
                const http = parseInt(w[0]) || 0;
                if (http === 429) {
                    const ra = parseInt(w[2] || "");
                    root.limitedUntil = Date.now() + (ra > 0 && ra < 3600 ? ra : 60) * 1000;
                    limitTimer.interval = Math.max(1000, root.limitedUntil - Date.now());
                    limitTimer.restart();
                    slot.finish("paused", "Download paused: Wallhaven rate limit · resumes by itself");
                    return;
                }
                if (code === 23 || code === 27) { slot.finish("paused", "Download paused: not enough space"); return; }
                if (code !== 0) {
                    slot.finish("failed", code === 6 || code === 7 ? "No connection to Wallhaven"
                        : code === 28 ? "The download timed out" : code === 63 ? "The file is too large"
                        : code === 18 ? "The download was cut short" : "curl exited " + code);
                    return;
                }
                if (http !== 200) { slot.finish("failed", "Wallhaven answered HTTP " + http); return; }
                root.patch(slot.itemId, { state: "validating" });
                slot.check.command = ["sh", "-c", 'stat -c %s -- "$1"; file -b --mime-type -- "$1"; identify -ping -format "%wx%h\\n" -- "$1[0]" 2>/dev/null',
                                 "_", slot.part];
                slot.check.running = true;
            }
        }

        /** Validar el archivo COMPLETO antes de que entre en la biblioteca. */
        property Process check: Process {
            stdout: StdioCollector { id: checkOut }
            onExited: {
                const it = root.items[slot.itemId];
                if (!it) { slot.itemId = ""; return; }
                if (slot.stopping) { slot.finish("cancelled", "Cancelled"); return; }
                const l = checkOut.text.split("\n");
                const size = parseInt(l[0]) || 0, mime = String(l[1] || "").trim(), dims = String(l[2] || "").trim();
                if (it.bytes > 0 && size !== it.bytes) { slot.finish("failed", "The file is incomplete (" + size + " of " + it.bytes + " bytes)"); return; }
                if (mime !== it.mime) { slot.finish("failed", "The file is not the image Wallhaven announced (" + (mime || "unknown") + ")"); return; }
                if (it.width > 0 && dims !== it.width + "x" + it.height) { slot.finish("failed", "The image size does not match (" + dims + ")"); return; }
                // un archivo con el mismo id pudo llegar entretanto (a mano, otra descarga)
                if (Wallhaven.installed(it.id)) {
                    if (it.ctx) WallhavenIndex.record(it.id, Wallhaven.installedPath(it.id), it.ctx);
                    slot.finish("exists", "Already in your library");
                    return;
                }
                const dest = Wallpaper.downloadDir + "/wallhaven-" + it.id + "." + it.ext;
                slot.mover.dest = dest;
                slot.mover.command = ["sh", "-c", '[ -e "$2" ] && exit 3; mv -n -- "$1" "$2" && [ -e "$2" ] && [ ! -e "$1" ]',
                                 "_", slot.part, dest];
                slot.mover.running = true;
            }
        }

        property Process mover: Process {
            property string dest: ""
            onExited: function (code) {
                const id = slot.itemId;
                if (!root.items[id]) { slot.itemId = ""; return; }
                if (code === 3) { slot.finish("exists", "Already in your library"); return; }
                if (code !== 0) { slot.finish("failed", "Could not move the file into the library"); return; }
                const dest = slot.mover.dest;
                // 10E-1b: al índice privado (de dónde vino y, si fue de una colección, cuál)
                WallhavenIndex.record(id, dest, root.items[id].ctx);
                slot.finish("done", "", { dest: dest, got: root.items[id].bytes });
                // la biblioteca y sus miniaturas por el camino de siempre; nunca se aplica
                Wallpaper.scan();
                Wallpaper.refreshThumbs();
                root.finished(id, dest);
            }
        }

        /** Progreso: el tamaño del temporal, cada 400 ms mientras baja. */
        property Timer progress: Timer {
            interval: 400
            repeat: true
            onTriggered: if (!slot.sizeProc.running) { slot.sizeProc.command = ["stat", "-c", "%s", "--", slot.part]; slot.sizeProc.running = true; }
        }
        property Process sizeProc: Process {
            stdout: StdioCollector {
                onStreamFinished: {
                    const n = parseInt(this.text) || 0;
                    const it = root.items[slot.itemId];
                    if (it && it.state === "running" && n !== it.got) root.patch(slot.itemId, { got: n });
                }
            }
        }
    }

    readonly property var slots: [slotA, slotB]
    Slot { id: slotA }
    Slot { id: slotB }

    // ---- registro y reconciliación -------------------------------------------------------

    function save() {
        if (!root.loaded) return;
        registry.setText(JSON.stringify({ version: 1, jobs: root.jobs, items: root.items }) + "\n");
    }

    /**
     * Al cargar, nada de lo que estaba vivo sigue vivo (el proceso murió): si el archivo final ya
     * está, «done»; si no, «interrupted» y su temporal fuera. No se afirma que nada sobrevivió.
     */
    function reconcile(o) {
        const items = {};
        const src = o && typeof o.items === "object" && o.items ? o.items : {};
        for (const k in src) {
            const it = src[k];
            if (!it || typeof it.id !== "string" || !/^[a-z0-9]{1,12}$/.test(it.id)) continue;
            items[it.id] = it;
        }
        root.jobs = Array.isArray(o && o.jobs) ? o.jobs.filter(j => j && typeof j.id === "string").slice(0, 20) : [];
        root.items = items;
        reconProc.ids = Object.keys(items).filter(k => ["queued", "running", "validating"].indexOf(items[k].state) >= 0);
        reconProc.command = ["sh", "-c", 'dir="$1"; tmp="$2"; shift 2; rm -f -- "$tmp"/*.part 2>/dev/null; '
            + 'for id in "$@"; do f=$(ls -1 -- "$dir" 2>/dev/null | grep -E "^wallhaven-$id([._])" | head -1); '
            + 'printf "%s\\t%s\\n" "$id" "$f"; done', "_", Wallpaper.downloadDir, root.tempDir].concat(reconProc.ids);
        reconProc.running = true;
    }
    Process {
        id: reconProc
        property var ids: []
        stdout: StdioCollector {
            onStreamFinished: {
                const found = {};
                const lines = this.text.split("\n");
                for (let i = 0; i < lines.length; i++) {
                    const t = lines[i].indexOf("\t");
                    if (t > 0) found[lines[i].substring(0, t)] = lines[i].substring(t + 1);
                }
                const m = Object.assign({}, root.items);
                for (let i = 0; i < reconProc.ids.length; i++) {
                    const id = reconProc.ids[i];
                    // 10E-2: si el archivo llegó pero el shell murió antes de anotarlo, el índice también
                    if (found[id]) WallhavenIndex.record(id, found[id], m[id].ctx || null);
                    m[id] = Object.assign({}, m[id], found[id]
                        ? { state: "done", reason: "", dest: Wallpaper.downloadDir + "/" + found[id] }
                        : { state: "interrupted", reason: "The shell restarted before it finished", got: 0 });
                }
                root.items = m;
                root.loaded = true;
                root.save();
                for (let i = 0; i < root.jobs.length; i++) root.settleJob(root.jobs[i].id);
            }
        }
    }

    FileView {
        id: registry
        path: root.registryPath
        blockLoading: true
        printErrors: false
        onLoaded: {
            let o = null;
            try { o = JSON.parse(registry.text()); } catch (e) { o = null; }
            root.reconcile(o || {});
        }
        onLoadFailed: function (error) { root.reconcile({}); }
    }

    /** Pruebas: registro y temporales en otra carpeta (sólo bajo /tmp/). */
    function setTestDir(dir) {
        const d = String(dir || "");
        if (d.length > 0 && (d.indexOf("/tmp/") !== 0 || d.indexOf("..") >= 0)) return false;
        if (root.runningCount > 0) return false;
        // la misma carpeta: nada que cambiar (vaciar sin que cambie la ruta dejaba el estado en blanco
        // hasta reiniciar, porque FileView no relee; con la cuenta, la clave desaparecía de memoria)
        if (d === root.testDir) return true;
        root.loaded = false;
        root.jobs = [];
        root.items = {};
        root.limitedUntil = 0;
        root.testFreeBytes = -1;
        root.testDir = d;
        return true;
    }

    function prepSummary() {
        const p = root.prep;
        return p ? { state: p.state, reason: p.reason, collection: p.collection ? p.collection.label : "",
                     purity: p.purity, page: p.page, lastPage: p.lastPage, count: p.items.length, installed: p.installed } : null;
    }

    function summary() {
        const jobs = root.jobs.slice(0, 8).map(j => Object.assign({ state: root.jobState(j.id) }, j, root.jobSummary(j.id)));
        const items = {};
        for (const k in root.items) {
            const it = root.items[k];
            items[k] = { state: it.state, got: it.got, bytes: it.bytes, reason: it.reason, dest: it.dest, job: it.job };
        }
        return { loaded: root.loaded, running: root.runningCount, queued: root.queuedCount, paused: root.pausedCount,
                 limitedFor: Math.max(0, Math.round((root.limitedUntil - Date.now()) / 1000)),
                 blocker: root.blocker(), tempDir: root.tempDir, registry: root.registryPath,
                 testFreeBytes: root.testFreeBytes, jobs: jobs, items: items, prep: root.prepSummary() };
    }
}
