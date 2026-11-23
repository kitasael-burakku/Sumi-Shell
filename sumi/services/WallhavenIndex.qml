pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/xdg.js" as Xdg

/**
 * Índice local PRIVADO de Wallhaven (rediseño 10E-1b; futureWallpaper-listsurface «Origen y
 * colecciones en la biblioteca local»).
 *
 *   `$XDG_STATE_HOME/sumi-shell/wallhaven-index.json`, 0600, separado de las imágenes y de la
 *   clave. Por id de Wallhaven: el archivo local, de dónde vino (search · collection), la cuenta y
 *   las colecciones de las que se obtuvo o reconoció. Una imagen está UNA vez en la biblioteca y
 *   puede pertenecer a varias colecciones. Los nombres se ponen al día cuando la API los da; el
 *   índice basta para enseñar y filtrar sin red. No borra nada si una colección cambia en la web.
 *
 * Lo alimentan las descargas (`Downloads`): al terminar, y también cuando un archivo de una
 * colección ya estaba (se anota la asociación sin bajar otra copia).
 *
 * La marca «Wallhaven» de la tira NO sale de aquí: es por el nombre (`wallhaven-<id>…`), así que
 * también los bajados a mano la llevan (decisión del usuario, 10 · división).
 */
Singleton {
    id: root

    readonly property string stateDir: Xdg.base(Quickshell.env("XDG_STATE_HOME"), Quickshell.env("HOME") + "/.local/state") + "/sumi-shell"
    /** Pruebas: la misma carpeta que la cuenta (IPC `whTestAccountDir`). */
    readonly property string path: (WallhavenAccount.testDir.length > 0 ? WallhavenAccount.testDir : root.stateDir) + "/wallhaven-index.json"

    /** { whId: { file, source, account, collections: [collectionId…], at } } */
    property var entries: ({})
    /** { collectionId: { name, account, public } } */
    property var names: ({})
    property bool loaded: false

    /** El id de Wallhaven de un nombre de archivo (`wallhaven-<id>.<ext>` o `wallhaven-<id>_WxH.<ext>`). */
    function idOfName(name) {
        const m = /^wallhaven-([a-z0-9]{1,12})(?:[._])/.exec(String(name || ""));
        return m ? m[1] : "";
    }

    /**
     * Anotar un archivo de Wallhaven. `ctx`: { collectionId, collectionName, account, public } o
     * nada (búsqueda general: la marca, sin colección).
     */
    /** Lo que llega antes de leer el archivo espera aquí (si no, `save` lo perdería). */
    property var pending: []
    function record(id, file, ctx) {
        if (!/^[a-z0-9]{1,12}$/.test(String(id))) return;
        if (!root.loaded) { root.pending = root.pending.concat([[id, file, ctx]]); return; }
        const c = ctx || {};
        const e = Object.assign({ file: "", source: "search", account: "", collections: [], at: Date.now() }, root.entries[id] || {});
        if (file) e.file = String(file).substring(String(file).lastIndexOf("/") + 1);
        if (c.collectionId) {
            const cid = String(c.collectionId);
            if (e.collections.indexOf(cid) < 0) e.collections = e.collections.concat([cid]);
            e.source = "collection";
            e.account = String(c.account || e.account || "");
            const n = Object.assign({}, root.names);
            n[cid] = { name: String(c.collectionName || (n[cid] && n[cid].name) || cid).substring(0, 80),
                       account: e.account, public: c.public !== false };
            root.names = n;
        }
        const m = Object.assign({}, root.entries);
        m[id] = e;
        root.entries = m;
        root.save();
    }

    /** Los nombres que da la API al listar colecciones (sin tocar asociaciones). */
    function updateNames(list, account) {
        if (!Array.isArray(list) || list.length === 0) return;
        const n = Object.assign({}, root.names);
        let changed = false;
        for (let i = 0; i < list.length; i++) {
            const cid = String(list[i].id);
            if (!n[cid] && !root.anyIn(cid)) continue;   // sólo las que ya tienen algo aquí
            const name = String(list[i].label || cid).substring(0, 80);
            if (!n[cid] || n[cid].name !== name) { n[cid] = { name: name, account: account || "", public: list[i].public !== 0 }; changed = true; }
        }
        if (changed) { root.names = n; root.save(); }
    }
    function anyIn(cid) {
        for (const k in root.entries) if (root.entries[k].collections.indexOf(cid) >= 0) return true;
        return false;
    }

    /** Las colecciones de las imágenes que HAY en la biblioteca: [{ id, name, count }], por nombre. */
    readonly property var localCollections: {
        void Wallpaper.entries;
        const have = {};
        const l = Wallpaper.entries;
        for (let i = 0; i < l.length; i++) {
            const id = root.idOfName(l[i].name);
            if (id && root.entries[id]) have[id] = true;
        }
        const count = {};
        for (const id in have) {
            const cs = root.entries[id].collections;
            for (let j = 0; j < cs.length; j++) count[cs[j]] = (count[cs[j]] || 0) + 1;
        }
        return Object.keys(count).map(cid => ({ id: cid, name: root.names[cid] ? root.names[cid].name : cid, count: count[cid] }))
            .sort((a, b) => a.name.localeCompare(b.name));
    }

    /** ¿El archivo (por su nombre) está en esa colección? */
    function inCollection(name, cid) {
        const id = root.idOfName(name);
        const e = id ? root.entries[id] : null;
        return !!e && e.collections.indexOf(String(cid)) >= 0;
    }
    /** Los nombres de las colecciones de un archivo (para la ficha local). */
    function collectionsOf(name) {
        const id = root.idOfName(name);
        const e = id ? root.entries[id] : null;
        if (!e) return [];
        return e.collections.map(cid => root.names[cid] ? root.names[cid].name : cid);
    }
    function collectionName(cid) { return root.names[cid] ? root.names[cid].name : String(cid); }

    // ---- archivo --------------------------------------------------------------------------

    function save() {
        if (!root.loaded) return;
        file.setText(JSON.stringify({ version: 1, entries: root.entries, names: root.names }) + "\n");
    }

    function clean(o) {
        const out = {}, nm = {};
        const src = o && typeof o.entries === "object" && o.entries ? o.entries : {};
        for (const k in src) {
            const e = src[k];
            if (!/^[a-z0-9]{1,12}$/.test(k) || !e || typeof e !== "object") continue;
            out[k] = { file: typeof e.file === "string" ? e.file.substring(0, 255) : "",
                       source: e.source === "collection" ? "collection" : "search",
                       account: typeof e.account === "string" ? e.account.substring(0, 64) : "",
                       collections: Array.isArray(e.collections) ? e.collections.map(String).filter(c => /^[0-9A-Za-z_-]{1,20}$/.test(c)) : [],
                       at: typeof e.at === "number" ? e.at : 0 };
        }
        const ns = o && typeof o.names === "object" && o.names ? o.names : {};
        for (const k in ns) if (/^[0-9A-Za-z_-]{1,20}$/.test(k) && ns[k] && typeof ns[k].name === "string")
            nm[k] = { name: ns[k].name.substring(0, 80), account: String(ns[k].account || "").substring(0, 64), public: ns[k].public !== false };
        root.entries = out;
        root.names = nm;
    }

    FileView {
        id: file
        path: root.path
        /**
         * FileView crea en 0644 (memoria del proyecto) y la escritura es asíncrona: un chmod justo
         * tras setText llegaba ANTES de que el archivo existiera (medido: quedó 0644). Aquí, cuando
         * ya está escrito.
         */
        onSaved: Quickshell.execDetached(["chmod", "600", "--", root.path])
        blockLoading: true
        printErrors: false
        onLoaded: {
            try { root.clean(JSON.parse(file.text())); } catch (e) { root.clean({}); }
            root.loaded = true;
            root.flush();
        }
        onLoadFailed: { root.clean({}); root.loaded = true; root.flush(); }
    }

    function flush() {
        const l = root.pending;
        root.pending = [];
        for (let i = 0; i < l.length; i++) root.record(l[i][0], l[i][1], l[i][2]);
    }

    function summary() {
        return { loaded: root.loaded, path: root.path, entries: root.entries, names: root.names,
                 local: root.localCollections };
    }
}
