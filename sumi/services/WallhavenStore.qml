pragma Singleton

import QtQuick
import Quickshell

/**
 * La tienda de Wallhaven (antes de la fase 11, `rediseno/Antes-de-fase-11.md`): el ESTADO de su
 * interfaz, separado de la API (`Wallhaven`), de la cuenta (`WallhavenAccount`), del índice
 * (`WallhavenIndex`) y de las descargas (`Downloads`), que no cambian.
 *
 * Una sola instancia lógica: `open` + `screen` (el nombre de la pantalla donde está). La abren el
 * atajo (Super+Ctrl+W), el botón de Wallpaper List y el IPC, todos por `core/Screens.wallhavenOn`;
 * pedirla en otra pantalla la LLEVA allí, no crea otra. Cerrarla no borra nada: la búsqueda, los
 * resultados y las descargas viven en sus servicios, y lo propio de la vista (texto escrito,
 * scroll, ficha) vive aquí, así que al reabrir está como se dejó.
 *
 * La posición es por pantalla y de la sesión (`positions[nombre] = {x, y}`, esquina de la tarjeta
 * en píxeles lógicos de la capa). Sin posición guardada, centrada. `core/WallhavenLayer` la acota
 * al monitor al arrastrar y al cambiar el tamaño de la pantalla: nunca queda fuera.
 *
 * También las listas que pintaba Wallpaper List (`filterItems`, `moreItems`, `detailActions`,
 * `dlLabel`), extraídas en W1; desde W4 (la tira ya sin Wallhaven) sólo las lee la tienda.
 */
Singleton {
    id: root

    property bool open: false
    /** La pantalla donde está (o estuvo por última vez) la tienda. */
    property string screen: ""
    /** Posiciones de la sesión por pantalla: `{ nombre: { x, y } }`. Se reasigna entera (un var mutado no notifica). */
    property var positions: ({})
    /** La capa que la pinta ahora (`core/WallhavenLayer` se registra): su geometría va al resumen. */
    property var layer: null
    /** Veces que se abrió (para comprobar por IPC que el atajo y el botón llegan a la misma instancia). */
    property int opens: 0

    // ---- lo que la vista conserva entre aperturas ------------------------------------------
    /** El texto del campo de búsqueda (no lo buscado: ése es `Wallhaven.query`). */
    property string text: ""
    property real scrollY: 0
    /** W2: el panel Filters abierto, y el resultado seleccionado (por id: sobrevive a la página). */
    property bool filtersOpen: false
    property string selectedId: ""
    /**
     * W3: la ficha abierta (la de `selectedId`). Un clic en una tarjeta la selecciona y abre la
     * ficha; se busca el resultado por id, así que sobrevive a que llegue otra página (y se cierra
     * sola si el id ya no está).
     */
    property bool detailOpen: false
    readonly property var detailItem: {
        if (!root.detailOpen || root.selectedId.length === 0) return null;
        const l = Wallhaven.results;
        for (let i = 0; i < l.length; i++) if (l[i].id === root.selectedId) return l[i];
        return null;
    }
    readonly property int detailIndex: {
        if (!root.detailItem) return -1;
        return Wallhaven.results.indexOf(root.detailItem);
    }
    function openDetail(id) {
        root.selectedId = id;
        root.filtersOpen = false;
        root.detailOpen = true;
    }
    /** La ficha del anterior o del siguiente de la página. */
    function stepDetail(dir) {
        const i = root.detailIndex + dir;
        const r = Wallhaven.results[i];
        if (r) root.selectedId = r.id;
    }

    /** Pruebas (IPC `whStoreHover`): la tarjeta de ese id se pinta como con el puntero encima. */
    property string testHot: ""

    /**
     * W2: «Reset filters» de la tienda quita sólo los AVANZADOS (periodo, resoluciones, proporción,
     * color, formato); categorías, contenido y orden están a la vista y se cambian allí.
     */
    function resetAdvanced() {
        const d = Object.assign({}, Wallhaven.draft), f = Wallhaven.defaults;
        for (const k of ["topRange", "atleast", "resolutions", "ratios", "color", "format"]) d[k] = f[k];
        Wallhaven.draft = d;
    }

    function show(name) {
        if (!name) return false;
        root.screen = name;
        if (!root.open) root.opens++;
        root.open = true;
        return true;
    }
    function close() {
        root.open = false;
        return true;
    }
    /** Mismo sitio y abierta → cierra; cerrada o en otra pantalla → se muestra en ésta. */
    function toggle(name) {
        if (root.open && root.screen === name) return root.close();
        return root.show(name);
    }

    function positionOf(name) {
        return root.positions[name] || null;
    }
    function remember(name, x, y) {
        const p = Object.assign({}, root.positions);
        p[name] = { x: Math.round(x), y: Math.round(y) };
        root.positions = p;
    }

    /** Resumen para IPC (`whStoreState`); la geometría la añade la capa que la pinta. */
    function summary() {
        return { open: root.open, screen: root.screen, opens: root.opens, positions: root.positions,
                 text: root.text, filtersOpen: root.filtersOpen, selectedId: root.selectedId,
                 detailOpen: root.detailOpen, detail: root.detailItem ? root.detailItem.id : "", layer: root.layer ? root.layer.geometry() : null };
    }

    // ---- listas compartidas con Wallpaper List (extraídas de surfaces/Wallpaper, 10C-2…10E-2) ----

    /** El estado de descarga de un id (lee `Downloads.items` para que el binding lo siga). */
    function dlItem(id) { void Downloads.items; return Downloads.itemOf(id); }
    function dlLabel(id) {
        const it = root.dlItem(id);
        if (!it) return "";
        if (it.state === "running") return it.bytes > 0 ? "↓ " + Math.floor(100 * it.got / it.bytes) + "%" : "↓ …";
        if (it.state === "queued") return "Queued";
        if (it.state === "validating") return "Checking…";
        if (it.state === "paused") return "Paused";
        if (it.state === "failed") return "Failed";
        if (it.state === "interrupted") return "Interrupted";
        if (it.state === "done") return "Downloaded";
        return "";
    }

    /** La fila de filtros rápida. `moreOpen`: el panel More filters está a la vista. */
    function filterItems(moreOpen) {
        const d = Wallhaven.draft;
        const out = [
            { kind: "cat", i: 0, label: "General", on: d.categories.charAt(0) === "1" },
            { kind: "cat", i: 1, label: "Anime", on: d.categories.charAt(1) === "1" },
            { kind: "cat", i: 2, label: "People", on: d.categories.charAt(2) === "1" },
            { kind: "pur", i: 0, label: "SFW", on: d.purity.charAt(0) === "1" },
            { kind: "pur", i: 1, label: "Sketchy", on: d.purity.charAt(1) === "1" },
            { kind: "pur", i: 2, label: "NSFW", on: d.purity.charAt(2) === "1",
              disabled: !Wallhaven.hasKey && d.purity.charAt(2) !== "1",
              why: WallhavenAccount.hasKeyFile ? "Needs a checked API key" : "Needs your API key" },
            { kind: "sort", label: Wallhaven.sortLabel(d.sorting), on: d.sorting !== "" },
            { kind: "order", label: d.order === "asc" ? "↑" : "↓", on: d.order !== "desc" },
            { kind: "min", label: d.atleast ? "≥ " + d.atleast.replace("x", "×") : "Any size", on: d.atleast !== "" },
            { kind: "more", label: "More filters", on: moreOpen },
            { kind: "collections", label: "My collections", on: Wallhaven.view !== "search" }
        ];
        // 10E-1b: en colecciones la API sólo admite Content (purity): lo demás, apagado con el motivo
        if (Wallhaven.view !== "search")
            for (let i = 0; i < out.length; i++)
                if (["pur", "collections"].indexOf(out[i].kind) < 0) { out[i].disabled = true; out[i].why = "Collections only filter by content"; }
        return out;
    }

    /**
     * Los elementos de More filters, en orden (`sec` es la sección). `on` es el estado del
     * borrador; `disabled` explica por qué no se puede.
     */
    readonly property var moreItems: {
        const d = Wallhaven.draft;
        const out = [];
        const top = d.sorting === "toplist";
        for (let i = 0; i < Wallhaven.topRanges.length; i++)
            out.push({ sec: 0, kind: "range", value: Wallhaven.topRanges[i], label: Wallhaven.topRanges[i],
                       on: top && d.topRange === Wallhaven.topRanges[i], disabled: !top });
        for (let i = 0; i < Wallhaven.minimums.length; i++)
            out.push({ sec: 1, kind: "min", value: Wallhaven.minimums[i],
                       label: Wallhaven.minimums[i] ? Wallhaven.minimums[i].replace("x", "×") : "Any",
                       on: d.atleast === Wallhaven.minimums[i] });
        const custom = d.atleast !== "" && Wallhaven.minimums.indexOf(d.atleast) < 0;
        out.push({ sec: 1, kind: "custom", value: "", label: custom ? d.atleast.replace("x", "×") : "Custom…", on: custom });
        for (let i = 0; i < Wallhaven.exactResolutions.length; i++)
            out.push({ sec: 2, kind: "res", value: Wallhaven.exactResolutions[i], label: Wallhaven.exactResolutions[i].replace("x", "×"),
                       on: d.resolutions.indexOf(Wallhaven.exactResolutions[i]) >= 0 });
        for (let i = 0; i < Wallhaven.ratioOptions.length; i++) {
            const r = Wallhaven.ratioOptions[i];
            out.push({ sec: 3, kind: "ratio", value: r, label: r.indexOf("x") > 0 ? r.replace("x", ":") : r.charAt(0).toUpperCase() + r.substring(1),
                       on: d.ratios.indexOf(r) >= 0 });
        }
        out.push({ sec: 4, kind: "color", value: "", label: "Any", on: d.color === "" });
        for (let i = 0; i < Wallhaven.colorOptions.length; i++)
            out.push({ sec: 4, kind: "color", value: Wallhaven.colorOptions[i], label: "", swatch: "#" + Wallhaven.colorOptions[i],
                       on: d.color === Wallhaven.colorOptions[i] });
        const fm = [["", "Any"], ["png", "PNG"], ["jpg", "JPG"]];
        for (let i = 0; i < fm.length; i++)
            out.push({ sec: 5, kind: "format", value: fm[i][0], label: fm[i][1], on: d.format === fm[i][0] });
        for (let i = 0; i < out.length; i++) out[i].index = i;
        return out;
    }
    readonly property var moreSections: [
        { title: "Toplist period", note: "Only with the Toplist order" },
        { title: "Minimum resolution", note: "Or pick exact resolutions below — one or the other" },
        { title: "Exact resolutions", note: "Any of these" },
        { title: "Aspect ratio", note: "Any of these" },
        { title: "Colour", note: "The dominant colour, from Wallhaven's palette" },
        { title: "Format", note: "Adds type:png or type:jpg to your search" }
    ]

    /**
     * Las acciones de la ficha de un resultado, en orden. «Downloaded» / Apply now / Show in
     * library salen de la biblioteca (lo que ya está, bajado aquí o a mano), no de la descarga.
     */
    function detailActions(item, info) {
        const out = [];
        if (item) {
            const d = root.dlItem(item.id);
            const path = (void Wallpaper.entries, Wallhaven.installedPath(item.id));
            if (path.length > 0) {
                // F2c: `why` = por qué no se puede aquí (el botón se apaga y la ficha lo dice)
                out.push({ kind: "apply", label: "Apply now", path: path, why: Wallpaper.whyNot(path) });
                out.push({ kind: "show", label: "Show in library", path: path });
            } else if (d && ["queued", "running", "validating"].indexOf(d.state) >= 0) {
                out.push({ kind: "cancel", label: "Cancel download", job: d.job });
            } else if (d && ["failed", "cancelled", "paused", "interrupted"].indexOf(d.state) >= 0) {
                out.push({ kind: "retry", label: "Retry download", job: d.job });
            } else {
                out.push({ kind: "download", label: "Download", why: Downloads.blocker() });
            }
        }
        out.push({ kind: "similar", label: "Similar" });
        if (item && item.page.length > 0) out.push({ kind: "open", label: "Open on wallhaven.cc" });
        const tags = info && info.ok ? info.tags : [];
        for (let i = 0; i < tags.length; i++) out.push({ kind: "tag", label: tags[i].name, tag: tags[i].id });
        return out;
    }
}
