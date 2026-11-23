pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Web hub (Fase 9.i). Dos niveles sobre `websites.conf`, mas un modo de
 * busqueda con sugerencias en vivo. Desde la F3c (portabilidad, H-27) el archivo es del usuario,
 * `$XDG_CONFIG_HOME/sumi-shell/websites.conf` (el de `hypr/` se copió UNA vez en la migración v3;
 * nada de enlaces), y el navegador es `apps.browser`.
 *
 * `websites.conf` ES LA UNICA FUENTE, y esa es la regla dura de la sub-fase: no
 * se copia, no se cachea a otro sitio y no se reescribe desde aqui. El shell lo
 * lee y ya; anadir una pagina sigue siendo editar ese archivo, igual que con
 * rofi.
 *
 * SOBRE BUSCAR DE VERDAD. Se investigo si el hub podia devolver **enlaces**
 * dentro del shell (2026-09-09). `XMLHttpRequest` funciona desde QML -- eso no
 * es el problema -- pero ninguna fuente gratuita sirve: la API publica de
 * DuckDuckGo no es un buscador (devuelve una ficha de entidad: `python` da
 * cero resultados), las instancias publicas de SearXNG tienen el modo JSON
 * apagado o limitan por tasa, y las APIs de Google y Brave piden clave. Raspar
 * el HTML de un buscador va contra sus terminos y acaba en CAPTCHA, asi que
 * **no se hace**.
 *
 * Lo que si es publico y esta pensado para esto son los endpoints de
 * **sugerencias** que usa la barra de direcciones de cualquier navegador. Eso
 * es lo que se consume aqui, y la fuente queda enchufable por si algun dia hay
 * un SearXNG propio con JSON.
 */
Singleton {
    id: root

    // ---- los datos ----------------------------------------------------------

    /**
     * `SUMI_WEBSITES_CONF` sólo lo pone una preview (rediseño, ARR-04), para
     * probar un archivo ausente, ilegible o enorme sin tocar el del usuario. El
     * shell de la sesión no lo tiene en su entorno: lee el suyo (F3c: el de la
     * configuración de la shell, ya no el de hypr/).
     */
    readonly property string confPath: Quickshell.env("SUMI_WEBSITES_CONF")
        || (Settings.configDir + "/websites.conf")
    /** La ruta, para los textos («~/.config/sumi-shell/websites.conf»). */
    readonly property string confPretty: {
        const h = Quickshell.env("HOME") || "";
        return h.length > 0 && root.confPath.indexOf(h + "/") === 0 ? "~" + root.confPath.slice(h.length) : root.confPath;
    }

    /**
     * F3d-1: el mismo arreglo que services/Tasks: en una instalación nueva el directorio de la
     * configuración nace después de que esto vigile, y un websites.conf creado con la shell abierta no
     * se veía. Se asegura el directorio y se rearma el vigilante.
     */
    Process {
        id: ensureDir
        command: ["mkdir", "-p", "--", root.confPath.replace(/\/[^\/]*$/, "")]
        onExited: { conf.watchChanges = false; conf.watchChanges = true; conf.reload(); }
    }
    Component.onCompleted: ensureDir.running = true

    FileView {
        id: conf
        path: root.confPath
        watchChanges: true
        // 2026-11-20: sin websites.conf (instalación nueva) es un estado previsto, que la UI explica; sólo se
        // registran los demás fallos de lectura (docs/MINIMARU-CLIS-2026-11-20.md §12)
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.parseConf(this.text())
        onLoadFailed: (error) => {
            root.categories = [];
            root.confState = error === FileViewError.FileNotFound ? "missing" : "unreadable";
            if (root.confState !== "missing") console.warn("web: could not read " + root.confPretty);
            root.lastError = root.confState === "missing"
                ? "No websites.conf yet · create " + root.confPretty : "Could not read " + root.confPretty;
        }
    }

    /** [{ name, pages: [{ name, url }] }] en el orden del archivo. */
    property var categories: []
    property string lastError: ""
    /**
     * `loading` · `ready` · `empty` (se leyó y no tiene categorías) · `missing` ·
     * `unreadable`. Antes los tres últimos eran un mismo «empty or unreadable»: el
     * contrato pide distinguir «no se pudo leer» de «no hay nada» (DESIGN §7).
     */
    property string confState: "loading"

    /** Retry: volver a leer el archivo, sin esperar a que cambie. */
    function reloadConf() {
        root.confState = "loading";
        conf.reload();
    }

    readonly property int categoryCount: root.categories.length
    readonly property int pageCount: {
        let n = 0;
        for (let i = 0; i < root.categories.length; i++) n += root.categories[i].pages.length;
        return n;
    }

    /**
     * Mismo contrato que `web_common.sh`: `[Categoria]` abre seccion, y dentro
     * cada linea es `Nombre | URL`. Se ignoran comentarios y lineas vacias, y
     * **un `|` dentro de la URL se conserva** -- por eso se parte solo en el
     * primero y el resto se vuelve a unir.
     */
    function parseConf(text) {
        const cats = [];
        let cur = null;
        const lines = (text || "").split("\n");
        for (let i = 0; i < lines.length; i++) {
            const raw = lines[i];
            const line = raw.trim();
            if (line.length === 0 || line.charAt(0) === "#") continue;
            const head = /^\[(.+)\]$/.exec(line);
            if (head) { cur = { name: head[1].trim(), pages: [] }; cats.push(cur); continue; }
            if (!cur) continue;
            const bar = line.indexOf("|");
            if (bar < 0) continue;
            const name = line.substring(0, bar).trim();
            const url = line.substring(bar + 1).trim();
            if (name.length > 0 && url.length > 0) cur.pages.push({ name: name, url: url });
        }
        root.categories = cats;
        root.confState = cats.length === 0 ? "empty" : "ready";
        root.lastError = cats.length === 0 ? "websites.conf has no categories" : "";
    }

    function pagesOf(category) {
        for (let i = 0; i < root.categories.length; i++)
            if (root.categories[i].name === category) return root.categories[i].pages;
        return [];
    }

    // ---- abrir en el navegador ----------------------------------------------

    /**
     * F3c (portabilidad, HC-13): el navegador del USUARIO, `apps.browser`. Explícito, ése; «auto» =
     * `$BROWSER` y si no `xdg-open`. Hasta aquí había un segundo salto que leía `browser = "…"` de
     * `hypr/modules/programs.lua` del rice, porque bajo systemd `$BROWSER` no llega a la shell (medido
     * el 2026-09-09 y otra vez el 2026-10-05). La migración v3 copió ese valor UNA vez a `apps.browser`
     * (el autor: zen-browser); la shell ya no lee el Lua del rice.
     */
    readonly property string browser: {
        if (Settings.appBrowser !== "auto") return Settings.appBrowser;
        const b = Quickshell.env("BROWSER");
        if (b && b.length > 0) return b;
        return "xdg-open";
    }
    /** F3c: por qué no se puede abrir aquí ("" = sí; denegado o sin comprobar, se intenta). */
    readonly property string browserWhy: Capabilities.whyFirst(["apps.browser"])
    /** F3c: el nombre que ve el usuario («Zen»); uno desconocido, su ejecutable. */
    readonly property var browserLabels: ({ "firefox": "Firefox", "zen-browser": "Zen", "librewolf": "LibreWolf",
        "chromium": "Chromium", "google-chrome-stable": "Google Chrome", "brave": "Brave",
        "vivaldi-stable": "Vivaldi", "epiphany": "Epiphany", "falkon": "Falkon", "qutebrowser": "qutebrowser",
        "xdg-open": "the default browser" })
    function labelOf(bin) {
        const b = String(bin || "").replace(/^.*\//, "");
        return root.browserLabels[b] || b;
    }
    /** F3c: la orden de una apertura, sin lanzar (también la usa el verbo de prueba `webArgv`). */
    function browserArgv(url) { return [root.browser, url]; }

    /**
     * **Abrir sólo cierra si el navegador arrancó** (futureweb-hub, «Open sólo
     * cierra después de despachar correctamente la petición»). Antes `openUrl`
     * devolvía `true` al lanzar el proceso, arrancara o no, y la superficie se
     * cerraba igual con un `$BROWSER` inexistente: la página no salía y el
     * contexto se perdía.
     *
     * Desde la 6C es una operación de `ops` (clave "open"), el mismo modelo que
     * el perfil, el mezclador, Power y Clip: `openUrl` devuelve la revisión, y
     * `ops.settled` dice `ok` cuando el proceso ARRANCA (lo observable: el
     * navegador recibió la URL) o `error` si no llega a arrancar o la URL no es
     * http(s). Un navegador que arranca y falla después no se ve desde aquí (el
     * remoto de Firefox sale con 0 y el resto sigue vivo): ese caso queda fuera.
     * Antes eran las señales `opened` / `openFailed`.
     */
    readonly property Ops ops: Ops { name: "web" }

    /**
     * UN PROCESO POR APERTURA (6C). Con uno solo, si el navegador arrancaba en
     * frío ese proceso ERA el navegador y seguía vivo: la apertura siguiente
     * reasignaba `command` sobre un proceso en marcha, no arrancaba nada y la
     * petición se quedaba en vuelo para siempre. Cada uno lleva su revisión y se
     * destruye al salir, nunca antes (destruirlo mataría al navegador).
     *
     * Un binario que no existe NO emite `exited` (medido 2026-09-24: sólo el WARN
     * «Process failed to start»): lo que se ve es `running` volviendo a false sin
     * haber pasado por `started`. Por eso se escucha `runningChanged`.
     */
    /*
     * Desde el 2026-10-02 el navegador va en su scope (`Apps.scoped`): el proceso que arranca es
     * `systemd-run`, que siempre arranca. Si el navegador no existe sale con 1 en ~11 ms (medido),
     * sin unidad. Así que «arrancó» es ahora: sigue vivo a los `graceMs` (un arranque en frío: ese
     * proceso ES el navegador) o salió con 0 (el remoto de Firefox entrega y sale). Salir con otro
     * código antes de eso es «no pudo arrancar».
     */
    readonly property int graceMs: 150

    Component {
        id: openerComp
        Process {
            id: p
            property int rev: 0
            property string browser: ""
            property string url: ""
            property bool done: false
            property bool started: false
            property bool detached: false
            stderr: StdioCollector { id: openErr }
            function settle(state, why) {
                if (p.done) return;
                p.done = true;
                root.ops.resolve("open", p.rev, state, why, state === "ok" ? p.url : "");
            }
            onStarted: { p.started = true; if (!p.detached) p.graceTimer.start(); }
            onExited: (code) => {
                if (code === 0) p.settle("ok", "");
                else p.settle("error", openErr.text.trim() || "Could not start the browser (" + p.browser + ")");
            }
            onRunningChanged: {
                if (p.running) return;
                if (!p.started)
                    p.settle("error", "Could not start the browser (" + p.browser + ")");
                p.destroy();
            }
            property Timer graceTimer: Timer {
                interval: root.graceMs
                onTriggered: if (p.running) p.settle("ok", "")
            }
        }
    }

    function openUrl(url) {
        const r = root.ops.request("open", url);
        if (!/^https?:\/\//.test(url)) {
            console.warn("Web.openUrl: refused", url);
            root.ops.resolve("open", r, "error", "Only http(s) links can be opened");
            return r;   // ya resuelta: quien llama mira `ops.get("open")`
        }
        if (root.browserWhy.length > 0) {                      // F3c: el elegido no está; se dice antes
            root.ops.resolve("open", r, "error", root.browserWhy);
            return r;
        }
        // argv, sin shell: la URL nunca construye el comando (SECURITY.md, regla 3).
        const browser = root.browser;
        const accepted = Apps.withLaunch(root.browserArgv(url), browser, "", (command, why, backend) => {
            if (why) { root.ops.resolve("open", r, "error", why); return; }
            const p = openerComp.createObject(root, { rev: r, browser: browser, url: url, detached: backend === "direct",
                command: backend === "direct" ? Apps.detachedCommand(command) : command });
            p.running = true;
        });
        if (!accepted) root.ops.resolve("open", r, "error", Apps.lastLaunchError || "Could not queue the browser launch");
        return r;
    }

    // ---- buscadores ---------------------------------------------------------

    /**
     * `suggest` es el endpoint publico de autocompletado y `search` la URL a la
     * que se manda al navegador. Anadir un buscador es anadir una fila.
     */
    readonly property var engines: [
        {
            id: "ddg", name: "DuckDuckGo",
            suggest: "https://ac.duckduckgo.com/ac/?type=list&q=",
            search: "https://duckduckgo.com/?q="
        },
        {
            id: "google", name: "Google",
            suggest: "https://suggestqueries.google.com/complete/search?client=firefox&q=",
            search: "https://www.google.com/search?q="
        }
    ]

    property string engineId: "ddg"

    /**
     * Elegir buscador. Sustituye a `cycleEngine()`, que Tab disparaba desde el
     * campo: el contrato quiere que Tab recorra los controles y que el motor
     * cambie sólo al activarlo (DESIGN §3).
     */
    function setEngine(id) {
        if (root.engineId === id) return;
        root.engineId = id;
        if (root.query.trim().length > 0) root.fetchSuggestions();
    }

    /**
     * `SUMI_WEB_SUGGEST`: sólo para previews. Manda las sugerencias a otro
     * servidor (uno local que responde o un puerto cerrado que falla) en vez de al
     * buscador, para probar sin enviar lo tecleado a nadie.
     */
    readonly property string suggestOverride: Quickshell.env("SUMI_WEB_SUGGEST") || ""
    readonly property var engine: {
        for (let i = 0; i < root.engines.length; i++)
            if (root.engines[i].id === root.engineId) return root.engines[i];
        return root.engines[0];
    }

    // ---- sugerencias --------------------------------------------------------

    /**
     * OJO, PRIVACIDAD: esto manda lo tecleado al buscador elegido, igual que la
     * barra del navegador. Solo ocurre **dentro del modo busqueda** y solo con
     * lo que se escribe ahi; las categorias y las paginas no hacen ni una
     * peticion. El `debounce` no es cosmetico: sin el se mandaria una peticion
     * por pulsacion.
     */
    property string query: ""
    property var suggestions: []
    property bool fetching: false
    property string suggestError: ""

    property var xhr: null

    Timer {
        id: debounce
        interval: 180
        repeat: false
        onTriggered: root.fetchSuggestions()
    }

    onQueryChanged: {
        if (root.query.trim().length === 0) {
            root.suggestions = [];
            debounce.stop();
            return;
        }
        debounce.restart();
    }

    function fetchSuggestions() {
        const q = root.query.trim();
        if (q.length === 0) { root.suggestions = []; return; }
        if (root.xhr) { try { root.xhr.abort(); } catch (e) {} }
        const x = new XMLHttpRequest();
        root.xhr = x;
        root.fetching = true;
        root.suggestError = "";
        x.onreadystatechange = function () {
            if (x.readyState !== XMLHttpRequest.DONE) return;
            root.fetching = false;
            if (x.status !== 200) {
                // 0 = sin respuesta (sin red, puerto cerrado); el código sólo va al log.
                root.suggestError = "Suggestions unavailable";
                console.warn("Web: suggestions failed, HTTP", x.status);
                root.suggestions = [];
                return;
            }
            root.suggestions = root.parseSuggest(x.responseText);
        };
        x.open("GET", (root.suggestOverride || root.engine.suggest) + encodeURIComponent(q));
        x.send();
    }

    /** Formato OpenSearch: `["consulta", ["sug1","sug2",…], …]`. */
    function parseSuggest(text) {
        try {
            const j = JSON.parse(text);
            if (j && j.length > 1 && j[1] && j[1].length !== undefined) {
                const out = [];
                for (let i = 0; i < j[1].length && i < 10; i++) out.push(String(j[1][i]));
                return out;
            }
        } catch (e) {}
        return [];
    }

    function searchUrl(term) {
        return root.engine.search + encodeURIComponent(term);
    }

    function search(term) {
        const t = (term || "").trim();
        if (t.length === 0) return false;
        return root.openUrl(root.searchUrl(t));
    }

    // ---- resumen para el IPC ------------------------------------------------

    function summary() {
        return {
            categories: root.categoryCount, pages: root.pageCount,
            browser: root.browser, browserSetting: Settings.appBrowser, browserWhy: root.browserWhy,
            confPath: root.confPath,
            engine: root.engineId,
            query: root.query, suggestions: root.suggestions.length,
            fetching: root.fetching,
            error: root.lastError, confState: root.confState, suggestError: root.suggestError
        };
    }
}
