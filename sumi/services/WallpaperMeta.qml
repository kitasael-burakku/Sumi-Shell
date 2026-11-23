pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/xdg.js" as Xdg

/**
 * Recent y Favorites de los fondos (rediseño, 9D-1; futureSettingssurface §6 Wallpaper).
 *
 * **Estado operativo, no preferencia** (§2, como `wallpaper-bag.json`): vive en
 * `$XDG_STATE_HOME/sumi-shell/wallpaper-meta.json`, fuera del `settings.json` exportable.
 *
 *   recent     aplicaciones recientes, la más nueva primero, con su momento (máx. 20).
 *              NO son «los más usados»: se anota cada CAMBIO observado del fondo, venga de
 *              donde venga (el shell, rofi, fish, `wallpaper.service`), porque lo alimenta
 *              `Wallpaper.current`, que sigue el archivo de estado del rice.
 *   favorites  marcadores explícitos por ruta; nunca se infieren.
 *
 * Los compartirá Wallpaper List en la fase 10 (sus filtros); hoy los enseña Settings → Theme.
 * Un archivo que ya no existe no se borra de la lista: se marca (`missing`) en quien la pinta.
 *
 * 10B: cada entrada de Recent lleva su CONTEXTO DE TEMA — `scheme` y `dynamic` (colores del
 * fondo encendidos) — tomado al observarla y puesto al día mientras siga siendo el fondo actual
 * (si se cambia el esquema con ese fondo puesto, lo que se restaura es el último). Restore
 * previous vuelve a `previous()`: la entrada más reciente que no es el fondo actual. Las
 * entradas anteriores a la 10B no traen contexto: se restaura sólo el fondo, y se dice.
 */
Singleton {
    id: root

    readonly property string stateDir: Xdg.base(Quickshell.env("XDG_STATE_HOME"), Quickshell.env("HOME") + "/.local/state") + "/sumi-shell"
    /**
     * Pruebas (10B, IPC `wallTestRoot`): otra carpeta para el archivo, para que un apply falso
     * no escriba en el Recent del usuario. Al cambiarla se relee y la primera lectura vuelve a ser
     * sólo la referencia.
     */
    property string testDir: ""
    readonly property string filePath: (root.testDir.length > 0 ? root.testDir : root.stateDir) + "/wallpaper-meta.json"
    function setTestDir(dir) {
        // la misma carpeta: nada (vaciar sin que cambie la ruta dejaba Recent en blanco hasta reiniciar)
        if (dir === root.testDir) return;
        root.loaded = false;
        root.primed = false;
        root.recent = [];
        root.favorites = [];
        root.testDir = dir;
    }
    readonly property int maxRecent: 20

    property var recent: []
    property var favorites: []
    property bool loaded: false

    /**
     * La primera lectura del fondo al arrancar es la REFERENCIA, no una aplicación: si no,
     * cada arranque del shell subiría el fondo actual a Recent con la hora del arranque.
     */
    property bool primed: false
    property string last: ""

    /** Lo llama `Wallpaper` en cada cambio de `current`. */
    function noteApplied(path) {
        const p = String(path || "");
        if (!root.primed) {
            root.primed = true;
            root.last = p;
            return;
        }
        if (p.length === 0 || p === root.last) return;
        root.last = p;
        root.record(p);
    }

    /** El contexto de tema de ahora mismo (lo que Restore devolverá con este fondo). */
    function context() {
        // F-c: también el preset (vacío = Minimaru o dinámico)
        return Colors.contextReady ? { scheme: Colors.scheme, dynamic: Colors.dynamicEnabled,
                                       preset: Colors.presetActive ? Colors.preset : "" } : {};
    }

    function record(path) {
        const c = root.context();
        const entry = { path: path, at: Date.now() };
        if (c.scheme !== undefined) { entry.scheme = c.scheme; entry.dynamic = c.dynamic; entry.preset = c.preset; }
        const next = [entry];
        for (let i = 0; i < root.recent.length && next.length < root.maxRecent; i++)
            if (root.recent[i].path !== path) next.push(root.recent[i]);
        root.recent = next;
        root.save();
    }

    /** Si cambia el esquema o el modo con el fondo puesto, su entrada lo sigue. */
    function refreshContext() {
        if (!root.loaded || !Colors.contextReady || root.recent.length === 0 || root.recent[0].path !== root.last) return;
        const c = root.context();
        const e = root.recent[0];
        if (e.scheme === c.scheme && e.dynamic === c.dynamic && (e.preset || "") === c.preset) return;
        const next = root.recent.slice();
        next[0] = { path: e.path, at: e.at, scheme: c.scheme, dynamic: c.dynamic, preset: c.preset };
        root.recent = next;
        root.save();
    }
    Connections {
        target: Colors
        function onSchemeChanged() { root.refreshContext(); }
        function onDynamicEnabledChanged() { root.refreshContext(); }
        function onPresetActiveChanged() { root.refreshContext(); }
        function onPresetChanged() { root.refreshContext(); }
        function onContextReadyChanged() { root.refreshContext(); }
    }

    /** Restore previous: la entrada más reciente que no es el fondo actual (o null). */
    function previous(current) {
        for (let i = 0; i < root.recent.length; i++)
            if (root.recent[i].path !== current) return root.recent[i];
        return null;
    }

    function removeRecent(path) {
        root.recent = root.recent.filter(e => e.path !== path);
        root.save();
    }

    function isFavorite(path) {
        void root.favorites;
        for (let i = 0; i < root.favorites.length; i++)
            if (root.favorites[i].path === path) return true;
        return false;
    }

    function setFavorite(path, on) {
        if (!path || path.length === 0) return false;
        const has = root.isFavorite(path);
        if (on === has) return on;
        root.favorites = on ? [{ path: path, at: Date.now() }].concat(root.favorites)
                            : root.favorites.filter(e => e.path !== path);
        root.save();
        return on;
    }
    function toggleFavorite(path) { return root.setFavorite(path, !root.isFavorite(path)); }

    function save() {
        if (!root.loaded) return;       // nunca pisar un archivo que aún no se leyó
        file.setText(JSON.stringify({ version: 1, recent: root.recent, favorites: root.favorites }, null, 1) + "\n");
    }

    function clean(list) {
        if (!Array.isArray(list)) return [];
        return list.filter(e => e && typeof e.path === "string" && e.path.length > 0 && e.path.length < 4096)
                   .map(function (e) {
                       const o = { path: e.path, at: typeof e.at === "number" ? e.at : 0 };
                       // 10B: el contexto sólo si es válido (un esquema de matugen y un booleano)
                       if (typeof e.scheme === "string" && /^scheme-[a-z-]+$/.test(e.scheme)) o.scheme = e.scheme;
                       if (typeof e.dynamic === "boolean") o.dynamic = e.dynamic;
                       return o;
                   });
    }

    /** Sólo el shell escribe; no se vigila (releer la escritura propia compite con su caché). */
    FileView {
        id: file
        path: root.filePath
        blockLoading: true
        printErrors: false
        onLoaded: {
            try {
                const o = JSON.parse(file.text());
                root.recent = root.clean(o.recent).slice(0, root.maxRecent);
                root.favorites = root.clean(o.favorites);
            } catch (e) {
                console.warn("wallpaper-meta: unreadable, starting empty:", e);
            }
            root.loaded = true;
            root.refreshContext();
        }
        onLoadFailed: function (error) {
            root.loaded = true;
            if (error === FileViewError.FileNotFound) root.save();
        }
    }

    /** Resumen para el IPC (`wallMeta`). */
    function summary() {
        return { loaded: root.loaded, primed: root.primed, last: root.last, file: root.filePath,
                 recent: root.recent, favorites: root.favorites };
    }
}
