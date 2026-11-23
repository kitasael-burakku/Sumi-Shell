pragma Singleton

import QtQuick
import Quickshell

/**
 * Búsqueda en Wallhaven (rediseño 10C-1; futureWallpaper-listsurface «Buscar y descargar desde
 * Wallhaven»). La única fuente remota de Wallpaper List; independiente de la biblioteca local.
 *
 *   · SÓLO se pide con una acción explícita (`search`, `page`, `retry`): nunca al abrir ni al
 *     teclear. `requests` cuenta cada petición para comprobarlo.
 *   · Una petición a la vez: la nueva aborta la anterior; una respuesta vieja se descarta.
 *   · Estados: idle (nunca se buscó) · loading · ready · empty · unavailable (sin red, 5xx,
 *     tiempo agotado) · limited (429: se bloquea hasta `limitedUntil`) · rejected (401, clave;
 *     llega con la 10E) · error (respuesta que no se entiende o demasiado grande). Un fallo
 *     conserva los resultados anteriores a la vista (Stale), no los borra.
 *   · Paginación con `meta`; con orden aleatorio se reenvía el `seed` que dio la API para no
 *     repetir dentro de la búsqueda. Cambiar consulta u orden vuelve a la página 1.
 *   · Sólo se aceptan miniaturas de `https://th.wallhaven.cc/` y archivos de
 *     `https://w.wallhaven.cc/`; lo demás se descarta de la respuesta.
 *   · Sin clave: SFW público (`purity=100`). La clave y los filtros son de la 10E y la 10C-2;
 *     `params` ya lleva el sitio para ellos.
 *
 * Pruebas: `testBase` (IPC `whTestBase`, sólo `http://127.0.0.1:…`) sustituye a la API y a los
 * hosts de imágenes (todos en ese origen): `tools/kt-wallhaven.py`.
 *
 * 10C-2: FILTROS en un borrador (`draft`) que no pide nada al cambiar: Search lo manda (`sent`) y
 * vuelve a la página 1; `dirty` dice que hay cambios sin buscar. `problems()` lista lo que no se
 * puede enviar (sin categorías, sin contenido, NSFW sin clave) ANTES de pedir. Resolución mínima
 * y resoluciones exactas son alternativas: elegir una limpia la otra. El periodo sólo se manda con
 * Toplist. Formato = `type:png|jpg` añadido a la consulta. DETALLE: `info(id)` pide
 * `/w/<id>` (etiquetas y autor) una vez por id, con caché.
 */
Singleton {
    id: root

    property string testBase: ""
    /**
     * Cambiar de API (pruebas ↔ Wallhaven) descarta lo que vino de la otra: resultados, caché de
     * detalles y bloqueos. Medido en la 10C-2: un 404 de la API real se servía luego desde la caché
     * con la falsa puesta.
     */
    onTestBaseChanged: {
        if (root.xhr) { try { root.xhr.abort(); } catch (e) {} root.xhr = null; }
        if (root.infoXhr) { try { root.infoXhr.abort(); } catch (e) {} root.infoXhr = null; }
        deadline.stop();
        root.infoId = "";
        root.infos = {};
        root.results = [];
        root.meta = { current_page: 0, last_page: 0, per_page: 0, total: 0, seed: "" };
        root.limitedUntil = 0;
        root.lastWanted = null;
        root.state = "idle";
        root.reason = "";
        if (root.collXhr) { try { root.collXhr.abort(); } catch (e) {} root.collXhr = null; }
        root.view = "search";
        root.collections = [];
        root.collectionsState = "idle";
        root.collection = null;
        root.searchSnap = null;
    }
    readonly property bool testing: root.testBase.length > 0
    readonly property string apiBase: root.testing ? root.testBase + "/api/v1" : "https://wallhaven.cc/api/v1"
    readonly property string thumbPrefix: root.testing ? root.testBase + "/th/" : "https://th.wallhaven.cc/"
    readonly property string filePrefix: root.testing ? root.testBase + "/w/" : "https://w.wallhaven.cc/"
    readonly property int timeoutMs: 15000
    /** Tope de la respuesta JSON (una página son ~24 resultados, unos 20 kB). */
    readonly property int maxResponseBytes: 2 * 1024 * 1024

    /**
     * Lo que se pidió por última vez (no lo que se está escribiendo: ése es de la surface).
     * `sorting`: relevance · date_added · random · views · favorites · toplist (10C-2 lo expone).
     */
    property string query: ""
    readonly property var defaults: ({ categories: "111", purity: "100", sorting: "", order: "desc", topRange: "1M",
                                       atleast: "", resolutions: [], ratios: [], color: "", format: "" })
    /** Lo que se enviará con el próximo Search (el panel de filtros lo edita). */
    property var draft: root.defaults
    /** Lo que se envió en la búsqueda a la vista (las páginas lo usan). */
    property var params: root.defaults
    readonly property bool dirty: root.state !== "idle" && JSON.stringify(root.draft) !== JSON.stringify(root.params)
    // ---- My collections (10E-1b) -------------------------------------------------------

    /**
     * search · collections (la lista de la cuenta) · collection (los fondos de una). En
     * «collection» los resultados usan `results`/`meta` como la búsqueda (misma cuadrícula, ficha,
     * páginas y descargas); la búsqueda se guarda al entrar (`searchSnap`) y vuelve intacta con
     * Back to search. En colecciones sólo vale el filtro Content (`purity`: lo único que admite
     * esa lista de la API).
     */
    property string view: "search"
    property var collections: []
    property string collectionsState: "idle"
    property string collectionsReason: ""
    property var collection: null
    property var searchSnap: null
    property var collXhr: null

    /** Por qué My collections no se puede abrir (o ""): hacen falta clave comprobada y usuario. */
    readonly property string accountProblem: !WallhavenAccount.usable
        ? (WallhavenAccount.hasKeyFile ? "Test your API key in Settings first" : "My collections needs your Wallhaven API key")
        : (Settings.wallhavenUser.length === 0 ? "My collections needs your Wallhaven username" : "")

    function snapshotSearch() {
        if (root.view !== "search") return;
        root.searchSnap = { query: root.query, params: root.params, results: root.results, meta: root.meta,
                            state: root.state, reason: root.reason, lastWanted: root.lastWanted };
    }
    function stopRequests() {
        if (root.xhr) { try { root.xhr.abort(); } catch (e) {} root.xhr = null; }
        if (root.collXhr) { try { root.collXhr.abort(); } catch (e) {} root.collXhr = null; }
        deadline.stop();
    }

    /** Abrir la lista de colecciones de la cuenta (una petición; sólo con cuenta). */
    function openCollections() {
        root.snapshotSearch();
        root.stopRequests();
        root.view = "collections";
        root.collection = null;
        if (root.accountProblem.length > 0) {
            root.collectionsState = "needsAccount";
            root.collectionsReason = root.accountProblem;
            return false;
        }
        if (root.limitedUntil > Date.now()) {
            root.collectionsState = "limited";
            root.collectionsReason = root.limitText();
            return false;
        }
        const x = new XMLHttpRequest();
        root.collXhr = x;
        root.collectionsState = "loading";
        root.collectionsReason = "";
        root.requests++;
        root.lastUrl = root.apiBase + "/collections";
        x.onreadystatechange = function () {
            if (x.readyState !== XMLHttpRequest.DONE || x !== root.collXhr) return;
            collDeadline.stop();
            root.collXhr = null;
            const st = x.status;
            if (st === 401) {
                root.collectionsState = "rejected";
                root.collectionsReason = "Wallhaven rejected the API key · check it in Settings";
                WallhavenAccount.setStatus("rejected", "Wallhaven rejected this key", {});
                WallhavenAccount.identityChanged();
                return;
            }
            if (st === 429) { root.limitedUntil = Date.now() + 60000; root.collectionsState = "limited"; root.collectionsReason = root.limitText(); return; }
            if (st !== 200) {
                root.collectionsState = "unavailable";
                root.collectionsReason = st === 0 ? "Wallhaven unavailable · no connection" : "Wallhaven unavailable (HTTP " + st + ")";
                return;
            }
            let o = null;
            try { o = JSON.parse((x.responseText || "").substring(0, root.maxResponseBytes)); } catch (e) { o = null; }
            if (!o || !Array.isArray(o.data)) { root.collectionsState = "error"; root.collectionsReason = "Wallhaven's answer could not be read"; return; }
            const out = [];
            for (let i = 0; i < o.data.length && out.length < 200; i++) {
                const c = o.data[i];
                if (!c || (typeof c.id !== "number" && typeof c.id !== "string") || !/^[0-9]{1,12}$/.test(String(c.id))) continue;
                out.push({ id: String(c.id), label: String(c.label || c.id).substring(0, 80),
                           count: parseInt(c.count) || 0, views: parseInt(c.views) || 0, public: c.public === 1 || c.public === true });
            }
            root.collections = out;
            root.collectionsState = out.length === 0 ? "empty" : "ready";
            WallhavenIndex.updateNames(out, Settings.wallhavenUser);
        };
        x.open("GET", root.apiBase + "/collections");
        x.setRequestHeader("Accept", "application/json");
        root.authorize(x);
        x.send();
        collDeadline.restart();
        return true;
    }
    Timer {
        id: collDeadline
        interval: root.timeoutMs
        onTriggered: {
            if (!root.collXhr) return;
            try { root.collXhr.abort(); } catch (e) {}
            root.collXhr = null;
            root.collectionsState = "unavailable";
            root.collectionsReason = "Wallhaven did not answer";
        }
    }

    /** Abrir una colección: sus fondos, página 1, con el Content del borrador. */
    function openCollection(c) {
        if (!c) return false;
        const bad = root.problems(root.draft).filter(p => p.indexOf("NSFW") >= 0 || p.indexOf("content") >= 0);
        root.view = "collection";
        root.collection = c;
        root.results = [];
        root.meta = { current_page: 0, last_page: 0, per_page: 0, total: 0, seed: "" };
        if (bad.length > 0) { root.state = "invalid"; root.reason = bad[0]; return false; }
        root.params = JSON.parse(JSON.stringify(root.draft));
        return root.fetch(1, "");
    }
    function backToCollections() {
        root.stopRequests();
        root.view = "collections";
        root.collection = null;
        root.results = [];
        root.state = "idle";
        root.reason = "";
        return true;
    }
    function backToSearch() {
        root.stopRequests();
        const sn = root.searchSnap;
        root.view = "search";
        root.collection = null;
        if (sn) {
            root.query = sn.query; root.params = sn.params; root.results = sn.results; root.meta = sn.meta;
            root.state = sn.state === "loading" ? (sn.results.length > 0 ? "ready" : "idle") : sn.state;
            root.reason = sn.reason; root.lastWanted = sn.lastWanted;
        } else {
            root.results = []; root.state = "idle"; root.reason = "";
        }
        root.searchSnap = null;
        return true;
    }
    /** Contexto de una descarga desde la colección abierta (para el índice). */
    function collectionCtx() {
        const c = root.collection;
        return root.view === "collection" && c
            ? { collectionId: c.id, collectionName: c.label, account: Settings.wallhavenUser, public: c.public } : null;
    }

    /** 10E-1a: la cuenta. Sin clave VÁLIDA no hay NSFW (Wallhaven lo exige). */
    readonly property bool hasKey: WallhavenAccount.usable

    /**
     * Otra identidad (clave nueva, quitada o rechazada): se cancela lo que dependía de la anterior
     * y se invalidan los datos restringidos en memoria (futureWallpaper-listsurface «Continuidad»).
     * Sin clave válida, el borrador vuelve a no pedir NSFW.
     */
    Connections {
        target: WallhavenAccount
        function onIdentityChanged() {
            if (root.xhr) { try { root.xhr.abort(); } catch (e) {} root.xhr = null; }
            if (root.infoXhr) { try { root.infoXhr.abort(); } catch (e) {} root.infoXhr = null; }
            deadline.stop();
            root.infoId = "";
            root.infos = {};
            root.results = [];
            root.meta = { current_page: 0, last_page: 0, per_page: 0, total: 0, seed: "" };
            root.lastWanted = null;
            root.state = "idle";
            root.reason = "";
            if (root.collXhr) { try { root.collXhr.abort(); } catch (e) {} root.collXhr = null; }
            root.view = "search";
            root.collections = [];
            root.collectionsState = "idle";
            root.collection = null;
            root.searchSnap = null;
            if (!WallhavenAccount.usable && root.draft.purity.charAt(2) === "1")
                root.setDraft("purity", root.draft.purity.substring(0, 2) + "0" === "000" ? "100" : root.draft.purity.substring(0, 2) + "0");
        }
    }
    /** La cabecera de la clave en una petición (nunca en la URL). */
    function authorize(x) {
        const k = WallhavenAccount.header;
        if (k.length > 0) x.setRequestHeader("X-API-Key", k);
    }

    readonly property var sortings: [
        { key: "", label: "Relevance" }, { key: "date_added", label: "Latest" }, { key: "random", label: "Random" },
        { key: "views", label: "Views" }, { key: "favorites", label: "Favorites" }, { key: "toplist", label: "Toplist" }
    ]
    readonly property var topRanges: ["1d", "3d", "1w", "1M", "3M", "6M", "1y"]
    readonly property var minimums: ["", "1920x1080", "2560x1440", "3840x2160"]
    readonly property var exactResolutions: ["1920x1080", "1920x1200", "2560x1080", "2560x1440", "2560x1600",
                                            "3440x1440", "3840x1600", "3840x2160", "5120x1440", "5120x2880"]
    readonly property var ratioOptions: ["landscape", "portrait", "16x9", "16x10", "21x9", "32x9", "4x3", "9x16", "10x16", "1x1"]
    /** La paleta que acepta Wallhaven en `colors` (su página de búsqueda). */
    readonly property var colorOptions: ["660000", "990000", "cc0000", "cc3333", "ea4c88", "993399", "663399", "333399",
        "0066cc", "0099cc", "66cccc", "77cc33", "669900", "336600", "666600", "999900", "cccc33", "ffff00", "ffcc33",
        "ff9900", "ff6600", "cc6633", "996633", "663300", "000000", "999999", "cccccc", "ffffff", "424153"]

    // ---- el borrador de filtros -----------------------------------------------

    /** Un bloqueo («invalid») se levanta en cuanto el borrador vuelve a poder enviarse. */
    onDraftChanged: {
        if (root.state !== "invalid") return;
        const bad = root.problems(root.draft);
        if (bad.length > 0) root.reason = bad[0];
        else { root.state = root.results.length > 0 ? "ready" : "idle"; root.reason = ""; }
    }

    function setDraft(key, value) {
        const d = Object.assign({}, root.draft);
        d[key] = value;
        root.draft = d;
    }
    /** Categorías / contenido: tres bits (General·Anime·People / SFW·Sketchy·NSFW). */
    function toggleBit(key, i) {
        const b = String(root.draft[key]).split("");
        b[i] = b[i] === "1" ? "0" : "1";
        root.setDraft(key, b.join(""));
    }
    function sortLabel(k) {
        for (let i = 0; i < root.sortings.length; i++) if (root.sortings[i].key === k) return root.sortings[i].label;
        return k;
    }
    function cycleSorting(dir) {
        const keys = root.sortings.map(o => o.key);
        const i = Math.max(0, keys.indexOf(root.draft.sorting));
        root.setDraft("sorting", keys[(i + (dir || 1) + keys.length) % keys.length]);
    }
    function cycleMinimum(dir) {
        const i = Math.max(0, root.minimums.indexOf(root.draft.atleast));
        root.setAtleast(root.minimums[(i + (dir || 1) + root.minimums.length) % root.minimums.length]);
    }
    /** Mínima y exactas son alternativas (la spec): elegir una limpia la otra. */
    function setAtleast(v) {
        const d = Object.assign({}, root.draft);
        d.atleast = v;
        if (v.length > 0) d.resolutions = [];
        root.draft = d;
    }
    function validCustom(v) { return /^[1-9][0-9]{2,4}x[1-9][0-9]{2,4}$/.test(String(v)); }
    function toggleIn(key, v) {
        const d = Object.assign({}, root.draft);
        const l = d[key].slice();
        const i = l.indexOf(v);
        if (i >= 0) l.splice(i, 1); else l.push(v);
        d[key] = l;
        if (key === "resolutions" && l.length > 0) d.atleast = "";
        root.draft = d;
    }
    function resetFilters() { root.draft = root.defaults; }
    /** Quitar UNA etiqueta activa (su clave; las listas, un valor). */
    function removeFilter(key, value) {
        const d = Object.assign({}, root.draft);
        if (key === "resolutions" || key === "ratios") d[key] = d[key].filter(x => x !== value);
        else d[key] = root.defaults[key];
        if (key === "sorting") d.order = root.defaults.order;
        root.draft = d;
    }

    /** Lo que impide enviar (en inglés, para la UI); vacío = se puede. */
    function problems(d) {
        const p = d || root.draft;
        const out = [];
        if (p.categories === "000") out.push("Pick at least one category");
        if (p.purity === "000") out.push("Pick at least one content level");
        if (p.purity.charAt(2) === "1" && !root.hasKey)
            out.push(WallhavenAccount.hasKeyFile ? "NSFW needs a checked API key · Test connection in Settings"
                                                 : "NSFW needs your Wallhaven API key · Settings");
        if (p.atleast.length > 0 && !root.validCustom(p.atleast)) out.push("Minimum resolution must look like 2560x1440");
        return out;
    }

    /** Las etiquetas de lo activo que no es el valor por defecto (para quitarlas una a una). */
    function activeFilters() {
        const d = root.draft, f = root.defaults, out = [];
        const names = ["General", "Anime", "People"], pur = ["SFW", "Sketchy", "NSFW"];
        if (d.categories !== f.categories)
            out.push({ key: "categories", value: "", label: names.filter((n, i) => d.categories.charAt(i) === "1").join(" + ") || "No category" });
        if (d.purity !== f.purity)
            out.push({ key: "purity", value: "", label: pur.filter((n, i) => d.purity.charAt(i) === "1").join(" + ") || "No content" });
        if (d.sorting !== f.sorting || d.order !== f.order)
            out.push({ key: "sorting", value: "", label: root.sortLabel(d.sorting) + (d.order === "asc" ? " ↑" : " ↓") });
        if (d.sorting === "toplist") out.push({ key: "topRange", value: "", label: "Top " + d.topRange });
        if (d.atleast.length > 0) out.push({ key: "atleast", value: "", label: "≥ " + d.atleast.replace("x", "×") });
        for (let i = 0; i < d.resolutions.length; i++)
            out.push({ key: "resolutions", value: d.resolutions[i], label: d.resolutions[i].replace("x", "×") });
        for (let i = 0; i < d.ratios.length; i++)
            out.push({ key: "ratios", value: d.ratios[i], label: d.ratios[i].replace("x", ":") });
        if (d.color.length > 0) out.push({ key: "color", value: "", label: "#" + d.color, color: "#" + d.color });
        if (d.format.length > 0) out.push({ key: "format", value: "", label: d.format.toUpperCase() + " only" });
        return out;
    }

    property string state: "idle"
    property string reason: ""
    property var results: []
    property var meta: ({ current_page: 0, last_page: 0, per_page: 0, total: 0, seed: "" })
    readonly property int page: root.meta.current_page || 0
    readonly property int lastPage: root.meta.last_page || 0
    readonly property int total: root.meta.total || 0
    readonly property bool loading: root.state === "loading"
    /** Hay resultados de una búsqueda anterior a la vista aunque la última haya fallado. */
    readonly property bool stale: root.results.length > 0 && root.state !== "ready" && root.state !== "loading"

    property int requests: 0
    property string lastUrl: ""
    property real limitedUntil: 0

    // ---- acciones --------------------------------------------------------------

    /** Una búsqueda NUEVA (página 1, sin seed). `sorting` "" = el de siempre. */
    function search(q, sorting) {
        const text = String(q || "").trim();
        if (sorting !== undefined && sorting !== "") root.setDraft("sorting", sorting === "relevance" ? "" : String(sorting));
        const bad = root.problems(root.draft);
        if (bad.length > 0) {
            // no se pide: la combinación no se puede enviar (se dice antes, no después)
            root.state = "invalid";
            root.reason = bad[0];
            return false;
        }
        if (root.view !== "search") { root.stopRequests(); root.view = "search"; root.collection = null; root.searchSnap = null; }
        root.query = text;
        root.params = JSON.parse(JSON.stringify(root.draft));
        return root.fetch(1, "");
    }

    /** Otra página de la MISMA búsqueda; con orden aleatorio, con su seed. */
    function goPage(n) {
        if (root.state === "idle" || n < 1 || (root.lastPage > 0 && n > root.lastPage)) return false;
        return root.fetch(n, root.params.sorting === "random" ? String(root.meta.seed || "") : "");
    }
    function nextPage() { return root.goPage(root.page + 1); }
    function prevPage() { return root.goPage(root.page - 1); }

    /** Repetir lo último (Retry): la misma página, el mismo seed. */
    function retry() {
        if (root.lastWanted === null) return false;
        return root.fetch(root.lastWanted.page, root.lastWanted.seed);
    }

    // ---- la petición -----------------------------------------------------------

    property var xhr: null
    property var lastWanted: null

    function buildUrl(page, seed) {
        const p = root.params;
        if (root.view === "collection" && root.collection)
            return root.apiBase + "/collections/" + encodeURIComponent(Settings.wallhavenUser) + "/"
                + encodeURIComponent(root.collection.id) + "?purity=" + encodeURIComponent(p.purity) + "&page=" + page;
        const parts = [];
        // formato guiado: `type:png` junto a los términos del usuario (la spec)
        const q = (root.query + (p.format ? " type:" + p.format : "")).trim();
        if (q.length > 0) parts.push("q=" + encodeURIComponent(q));
        parts.push("categories=" + encodeURIComponent(p.categories));
        parts.push("purity=" + encodeURIComponent(p.purity));
        // sin texto no hay relevancia: fecha (lo de Wallhaven por defecto); con texto, relevancia
        const sorting = p.sorting || (root.query.length > 0 ? "relevance" : "");
        if (sorting) parts.push("sorting=" + encodeURIComponent(sorting));
        if (p.order) parts.push("order=" + encodeURIComponent(p.order));
        if (sorting === "toplist" && p.topRange) parts.push("topRange=" + encodeURIComponent(p.topRange));
        if (p.atleast) parts.push("atleast=" + encodeURIComponent(p.atleast));
        if (p.resolutions.length > 0) parts.push("resolutions=" + encodeURIComponent(p.resolutions.join(",")));
        if (p.ratios.length > 0) parts.push("ratios=" + encodeURIComponent(p.ratios.join(",")));
        if (p.color) parts.push("colors=" + encodeURIComponent(p.color));
        if (seed) parts.push("seed=" + encodeURIComponent(seed));
        parts.push("page=" + page);
        return root.apiBase + "/search?" + parts.join("&");
    }

    function fetch(page, seed) {
        const now = Date.now();
        if (root.limitedUntil > now) {
            root.state = "limited";
            root.reason = root.limitText();
            return false;
        }
        if (root.xhr) { try { root.xhr.abort(); } catch (e) {} }
        const url = root.buildUrl(page, seed);
        root.lastWanted = { page: page, seed: seed };
        const x = new XMLHttpRequest();
        root.xhr = x;
        root.state = "loading";
        root.reason = "";
        root.requests++;
        root.lastUrl = url;
        x.onreadystatechange = function () {
            if (x.readyState !== XMLHttpRequest.DONE) return;
            if (x !== root.xhr) return;   // abortada por una más nueva
            deadline.stop();
            root.xhr = null;
            root.handle(x);
        };
        x.open("GET", url);
        x.setRequestHeader("Accept", "application/json");
        // 10E-1a: la clave va en la cabecera X-API-Key (nunca en la URL ni en los logs)
        root.authorize(x);
        x.send();
        deadline.restart();
        return true;
    }

    Timer {
        id: deadline
        interval: root.timeoutMs
        onTriggered: {
            const x = root.xhr;
            if (!x) return;
            root.xhr = null;
            try { x.abort(); } catch (e) {}
            root.fail("unavailable", "Wallhaven did not answer");
        }
    }

    function fail(state, reason) {
        root.state = state;
        root.reason = reason;
    }

    function limitText() {
        const s = Math.max(1, Math.ceil((root.limitedUntil - Date.now()) / 1000));
        return "Wallhaven rate limit · try again in " + s + " s";
    }

    function handle(x) {
        const st = x.status;
        if (st === 0) { root.fail("unavailable", "Wallhaven unavailable · no connection"); return; }
        if (st === 429) {
            const ra = parseInt(x.getResponseHeader("Retry-After") || "");
            root.limitedUntil = Date.now() + (ra > 0 && ra < 3600 ? ra : 60) * 1000;
            root.fail("limited", root.limitText());
            limitTick.restart();
            return;
        }
        if (st === 401) {
            root.fail("rejected", "Wallhaven rejected the API key · check it in Settings");
            // la cuenta se entera: su estado pasa a rechazado (y la cabecera deja de mandarse)
            if (WallhavenAccount.hasKeyFile) { WallhavenAccount.setStatus("rejected", "Wallhaven rejected this key", {}); WallhavenAccount.identityChanged(); }
            return;
        }
        if (st >= 500) { root.fail("unavailable", "Wallhaven unavailable (HTTP " + st + ")"); return; }
        if (st !== 200) { root.fail("error", "Wallhaven answered HTTP " + st); return; }
        const text = x.responseText || "";
        if (text.length > root.maxResponseBytes) { root.fail("error", "Wallhaven's answer was too large"); return; }
        let o = null;
        try { o = JSON.parse(text); } catch (e) { o = null; }
        if (!o || !Array.isArray(o.data) || typeof o.meta !== "object" || o.meta === null) {
            root.fail("error", "Wallhaven's answer could not be read");
            return;
        }
        const out = [];
        for (let i = 0; i < o.data.length; i++) {
            const r = root.clean(o.data[i]);
            if (r) out.push(r);
        }
        const m = o.meta;
        root.meta = {
            current_page: Math.max(1, parseInt(m.current_page) || 1),
            last_page: Math.max(1, parseInt(m.last_page) || 1),
            per_page: parseInt(m.per_page) || out.length,
            total: parseInt(m.total) || 0,
            seed: typeof m.seed === "string" && /^[A-Za-z0-9]{1,16}$/.test(m.seed) ? m.seed : ""
        };
        root.results = out;
        root.state = out.length === 0 ? "empty" : "ready";
        root.reason = "";
    }

    /** Un resultado, sólo con lo que se usa y sólo con URLs de los hosts permitidos. */
    function clean(r) {
        if (!r || typeof r.id !== "string" || !/^[a-z0-9]{1,12}$/.test(r.id)) return null;
        const t = r.thumbs || {};
        const thumb = typeof t.small === "string" && t.small.indexOf(root.thumbPrefix) === 0 ? t.small : "";
        const large = typeof t.large === "string" && t.large.indexOf(root.thumbPrefix) === 0 ? t.large : thumb;
        const path = typeof r.path === "string" && r.path.indexOf(root.filePrefix) === 0 ? r.path : "";
        if (thumb.length === 0) return null;
        const type = String(r.file_type || "");
        return {
            id: r.id,
            thumb: thumb,
            large: large,
            path: path,
            width: parseInt(r.dimension_x) || 0,
            height: parseInt(r.dimension_y) || 0,
            resolution: String(r.resolution || "").substring(0, 20),
            format: type === "image/png" ? "PNG" : type === "image/jpeg" ? "JPG" : type.replace("image/", "").toUpperCase().substring(0, 6),
            bytes: parseInt(r.file_size) || 0,
            purity: String(r.purity || ""),
            category: String(r.category || ""),
            favorites: parseInt(r.favorites) || 0,
            views: parseInt(r.views) || 0,
            ratio: String(r.ratio || "").substring(0, 8),
            created: String(r.created_at || "").substring(0, 10),
            colors: Array.isArray(r.colors) ? r.colors.filter(c => /^#[0-9a-fA-F]{6}$/.test(c)).slice(0, 5) : [],
            page: /^https:\/\/wallhaven\.cc\/w\/[a-z0-9]+$/.test(String(r.url || "")) ? r.url : ""
        };
    }

    // ---- detalle (10C-2) --------------------------------------------------------

    /**
     * Etiquetas y autor de un resultado: `/w/<id>`, UNA vez por id (caché en memoria). Lo pide la
     * ficha tras medio segundo sobre el mismo resultado, no cada flecha.
     */
    property var infos: ({})
    property var infoXhr: null
    property string infoId: ""
    function info(id) {
        if (!/^[a-z0-9]{1,12}$/.test(String(id))) return false;
        // lo bueno se guarda; un fallo se puede volver a pedir (al volver a la ficha)
        if ((root.infos[id] && root.infos[id].ok) || root.infoId === id) return true;
        if (root.limitedUntil > Date.now()) return false;
        if (root.infoXhr) { try { root.infoXhr.abort(); } catch (e) {} }
        const x = new XMLHttpRequest();
        root.infoXhr = x;
        root.infoId = id;
        root.requests++;
        root.lastUrl = root.apiBase + "/w/" + id;
        x.onreadystatechange = function () {
            if (x.readyState !== XMLHttpRequest.DONE || x !== root.infoXhr) return;
            root.infoXhr = null;
            root.infoId = "";
            const m = Object.assign({}, root.infos);
            if (x.status === 429) {
                root.limitedUntil = Date.now() + 60000;
                m[id] = { ok: false, reason: "Rate limited" };
            } else if (x.status !== 200) {
                m[id] = { ok: false, reason: x.status === 0 ? "No connection" : "HTTP " + x.status };
            } else {
                let o = null;
                try { o = JSON.parse((x.responseText || "").substring(0, root.maxResponseBytes)); } catch (e) { o = null; }
                const d = o && o.data ? o.data : null;
                m[id] = d ? {
                    ok: true,
                    tags: Array.isArray(d.tags) ? d.tags.filter(t => t && typeof t.name === "string")
                        .slice(0, 24).map(t => ({ id: parseInt(t.id) || 0, name: t.name.substring(0, 40) })) : [],
                    uploader: d.uploader && typeof d.uploader.username === "string" ? d.uploader.username.substring(0, 40) : ""
                } : { ok: false, reason: "Unreadable" };
            }
            root.infos = m;
        };
        x.open("GET", root.apiBase + "/w/" + id);
        x.setRequestHeader("Accept", "application/json");
        root.authorize(x);
        x.send();
        return true;
    }

    /** Mientras dura el 429, el motivo cuenta hacia atrás; al vencer, se puede volver a buscar. */
    Timer {
        id: limitTick
        interval: 1000
        repeat: true
        onTriggered: {
            if (Date.now() >= root.limitedUntil) {
                stop();
                if (root.state === "limited") root.fail(root.results.length > 0 ? "ready" : "idle", "");
            } else if (root.state === "limited") {
                root.reason = root.limitText();
            }
        }
    }

    function formatBytes(n) {
        if (!(n > 0)) return "";
        if (n < 1024 * 1024) return Math.round(n / 1024) + " KB";
        return (n / 1048576).toFixed(n < 10 * 1048576 ? 1 : 0) + " MB";
    }

    /** La ruta en la biblioteca de un id de Wallhaven (o ""). */
    function installedPath(id) {
        const l = Wallpaper.entries;
        const pre = "wallhaven-" + id;
        for (let i = 0; i < l.length; i++) {
            const n = l[i].name;
            if (n.indexOf(pre) === 0 && (n.length === pre.length || n.charAt(pre.length) === "." || n.charAt(pre.length) === "_"))
                return l[i].path;
        }
        return "";
    }

    /** ¿Ya está en la biblioteca local? Por el id en el nombre (`wallhaven-<id>…`). */
    function installed(id) {
        const l = Wallpaper.entries;
        const pre = "wallhaven-" + id;
        for (let i = 0; i < l.length; i++) {
            const n = l[i].name;
            if (n.indexOf(pre) === 0 && (n.length === pre.length || n.charAt(pre.length) === "." || n.charAt(pre.length) === "_"))
                return true;
        }
        return false;
    }

    function summary() {
        return { state: root.state, reason: root.reason, query: root.query, params: root.params,
                 draft: root.draft, dirty: root.dirty, problems: root.problems(),
                 view: root.view, collectionsState: root.collectionsState, collectionsReason: root.collectionsReason,
                 collections: root.collections.map(c => c.id + ":" + c.label + ":" + c.count + (c.public ? "" : ":private")),
                 collection: root.collection ? root.collection.id : "", accountProblem: root.accountProblem,
                 active: root.activeFilters().map(f => f.label), infos: Object.keys(root.infos),
                 page: root.page, lastPage: root.lastPage, total: root.total, seed: root.meta.seed || "",
                 count: root.results.length, ids: root.results.slice(0, 8).map(r => r.id),
                 requests: root.requests, lastUrl: root.lastUrl, testing: root.testing };
    }
}
