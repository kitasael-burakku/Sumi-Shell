pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Actualizaciones pendientes.
 *
 * NO cuenta paquetes: lee la MISMA cache que ya escribe
 * `hypr/scripts/updates.sh`, alimentada por `updates-check.timer`. Ese
 * script no se retira con Waybar -- es tuberia del rice, y ademas lo leen
 * `hypr/scripts/updates-notify-actionable.sh`, `healthcheck-notify.sh` y
 * `rofi/scripts/dashboard.sh` (ADR-13: el shell no duplica lo que ya existe).
 *
 * El archivo es el JSON que Waybar consumia:
 *
 *     {"text":"󰚰 2","tooltip":"2 updates available\n...","class":["pending"]}
 *     {"text":"󰄬",  "tooltip":"System up to date\n...","class":["updated"]}
 *
 * Campos aditivos (2026-11-25): `risk` (texto; "" o ausente = sin riesgo) lo escribe el proveedor cuando
 * `sysupdate check` avisa de que un paquete correría contra dependencias para las que no se reconstruyó
 * (quickshell frente a un Qt nuevo). Con él, `risk_packages` y `risk_ignore` (listas JSON; los escriben el
 * propio y el updates.sh del rice desde el 2026-11-25). Una caché sin las listas (versión anterior del rice o de
 * otro proveedor) los saca del texto. La shell sólo informa: Upgrade nunca se bloquea.
 *
 * RENUNCIA CONSCIENTE (ADR-16): con el sistema al dia, Waybar dibuja un check.
 * El shell no dibuja nada: un aviso sin nada que avisar ocupa cero pixeles.
 */
Singleton {
    id: root

    /**
     * Portabilidad F4e: la caché la escribe el PROVEEDOR de actualizaciones (el del autor: su updates.sh por
     * updates-check.service; el propio: scripts/updates-provider.py), con el mismo formato. Una ruta declarada
     * en providers.json (`updates.cache`) manda; si no, la de siempre.
     */
    readonly property string cachePath: Providers.pathOf("updates", "cache")
        || ((Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/sumi-updates.cache")
    /** F4e: con providers.updates = none la fuente no existe aquí (ni aviso en el Overview ni botón). */
    readonly property bool off: root.testPath.length === 0 && Providers.resolve("updates").mode === "none"
    readonly property bool builtinProvider: root.testPath.length === 0 && Providers.resolve("updates").mode === "builtin"
    /** F4e: de dónde salen (lo dice el proveedor: «pacman + AUR» del autor, o lo detectado por el propio). */
    readonly property string sourceLabel: {
        if (root.testPath.length > 0) return "pacman + AUR";
        const r = Providers.resolve("updates");
        if (r.mode === "script") return r.label;
        const c = Capabilities.caps["system.updates"];
        return c && c.provider ? c.provider : "System updates";
    }

    property int count: 0
    property string tooltip: ""
    /** "updated" | "pending" | "critical" | "" si aun no se ha leido nada. */
    property string state: ""
    /**
     * `updates.sh` marca la clase "error" cuando `checkupdates` no pudo
     * consultar (red caida, base de pacman bloqueada). Encontrado en vivo el
     * 2026-09-08: la cache traia class ["updated","error"] y una primera
     * version de este servicio, que solo miraba class[0], escondia el aviso
     * justo cuando habia algo de lo que enterarse. Waybar si pintaba un
     * simbolo de advertencia, y esto tambien.
     */
    property bool failed: false
    property bool stale: true

    /**
     * 2026-11-25: el riesgo de sysupdate, si la caché lo trae (opcional; una caché vieja sin el campo = sin
     * riesgo). `riskPackages` lo que se rompería; `riskIgnore` los globs que sysupdate propone retener.
     */
    property string riskText: ""
    property var riskPackages: []
    property var riskIgnore: []
    readonly property bool risky: root.riskText.length > 0
    /** Lo que dice la UI en una frase corta: «quickshell may break» (los nombres, o «Some packages»). */
    readonly property string riskShort: !root.risky ? ""
        : (root.riskPackages.length > 0 ? root.riskPackages.join(", ") : "Some packages") + " may break"

    readonly property bool any: root.count > 0 || root.failed

    /**
     * 11A-2 (Overview): cuándo se comprobó por última vez (mtime de la caché, ms; 0 = nunca en
     * esta sesión) y si hay una comprobación pedida en curso (`recheck`), con un plazo: si la
     * caché no cambia en 90 s, `checking` vuelve a false y `recheckStalled` lo dice.
     */
    property double checkedAt: 0
    property bool checking: false
    property bool recheckStalled: false
    /** Pruebas (IPC `updatesTestCache`): otra caché en vez de la real. "" = la real. */
    property string testPath: ""
    onTestPathChanged: { root.checkedAt = 0; cache.reload(); }

    Process {
        id: statProc
        command: ["stat", "-c", "%Y", cache.path]
        stdout: StdioCollector { id: statOut }
        onExited: (code) => { if (code === 0) root.checkedAt = (parseInt(statOut.text.trim(), 10) || 0) * 1000; }
    }
    Timer {
        id: checkTimeout
        interval: 90000
        onTriggered: { root.checking = false; root.recheckStalled = true; }
    }

    FileView {
        id: cache
        path: root.testPath.length > 0 ? root.testPath : root.cachePath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            root.parse(cache.text());
            root.checking = false;
            root.recheckStalled = false;
            checkTimeout.stop();
            if (!statProc.running) statProc.running = true;
        }
        onLoadFailed: {
            // Aun no ha corrido `updates-check.timer` en esta sesion.
            root.stale = true;
            root.count = 0;
            root.state = "";
            root.failed = false;
            root.checkedAt = 0;
            root.riskText = "";
            root.riskPackages = [];
            root.riskIgnore = [];
        }
    }

    /** Los globs que se pueden pasar a `sysupdate -i` tal cual (como `clean_globs` del proveedor). */
    function cleanGlobs(items) {
        const out = [];
        for (const g of items || [])
            for (const part of String(g).split(",")) {
                const t = part.trim();
                if (t.length > 0 && /^[A-Za-z0-9@._+*?\[\]-]+$/.test(t) && out.indexOf(t) < 0) out.push(t);
            }
        return out;
    }
    function parseRisk(o) {
        const text = typeof o.risk === "string" ? o.risk.trim() : "";
        root.riskText = text;
        if (text.length === 0) { root.riskPackages = []; root.riskIgnore = []; return; }
        // el propio los da aparte; con el updates.sh del rice, del texto («<paquetes> would run … -i '<globs>'»)
        const pk = Array.isArray(o.risk_packages) ? o.risk_packages.map(String).filter(x => x.length > 0) : null;
        const ig = Array.isArray(o.risk_ignore) ? o.risk_ignore : null;
        const mp = /^(.+?) would run against /.exec(text);
        const mi = /sysupdate -i '([^']+)'/.exec(text);
        root.riskPackages = pk ? pk : mp && mp[1] !== "some packages" ? mp[1].split(",").map(x => x.trim()).filter(x => x.length > 0) : [];
        root.riskIgnore = root.cleanGlobs(ig ? ig : mi ? [mi[1]] : []);
    }

    function parse(text) {
        if (!text || text.length === 0)
            return;
        let o;
        try {
            o = JSON.parse(text);
        } catch (e) {
            console.warn("updates: cache ilegible");
            return;
        }
        const m = /(\d+)/.exec(String(o.text !== undefined ? o.text : ""));
        root.count = m ? parseInt(m[1], 10) : 0;
        root.tooltip = String(o.tooltip !== undefined ? o.tooltip : "");
        const cls = o["class"];
        const list = Array.isArray(cls) ? cls.map(String) : (cls !== undefined ? [String(cls)] : []);
        root.failed = list.indexOf("error") >= 0;
        // El estado visible es el primero que no sea "error".
        let st = "";
        for (let i = 0; i < list.length; i++)
            if (list[i] !== "error") { st = list[i]; break; }
        root.state = st;
        root.parseRisk(o);
        root.stale = false;
    }

    // F4e: ya no hay ruta fija del rice: comprobar y listar son verbos del proveedor
    readonly property string providerScript: Quickshell.shellDir + "/scripts/updates-provider.py"

    /*
     * Las tres acciones del modulo `custom/updates` de Waybar, con los mismos
     * comandos. La unica diferencia es que Waybar terminaba con
     * `pkill -RTMIN+8 waybar` para refrescarse: aqui sobra, porque el FileView
     * vigila la cache y el contador se actualiza solo.
     */

    /**
     * Portabilidad F2d: la tubería es del rice (updates.sh + updates-check.timer + checkupdates de
     * pacman-contrib). Sin ella la fuente NO EXISTE en esta máquina («not set up»), en vez de quedarse
     * sin comprobar para siempre; los proveedores por distribución son la F4. Con `testPath`, no aplica.
     */
    readonly property string notSetUp: root.testPath.length > 0 || root.off ? "" : Capabilities.whyFirst(["system.updates"])
    /**
     * F3d-1: el botón Upgrade es la tarea con `role: system-upgrade` de tasks.json (la del autor: `update`,
     * sysupdate + refrescar la caché). Sin ella no hay Upgrade («No upgrade task in tasks.json»).
     */
    readonly property var upgradeTask: Tasks.withRole("system-upgrade")
    readonly property string upgradeWhy: root.testPath.length > 0 ? ""
        : root.upgradeTask ? Jobs.whyNot(root.upgradeTask.id)
        // F4e: sin tarea, el propio sabe actualizar (gestor de AUR o sudo pacman, en la terminal)
        : root.builtinProvider ? (root.notSetUp || Capabilities.whyFirst(["apps.terminal"]))
        : Tasks.status === "loading" ? "" : "No upgrade task in tasks.json"
    /**
     * 2026-11-25: «Safe upgrade», la actualización reteniendo lo que sysupdate propone (`-i <globs>`). Sólo
     * existe con riesgo y sysupdate instalado; es una opción más, no sustituye a Upgrade.
     */
    readonly property bool sysupdateFound: {
        const c = Capabilities.caps["system.updates"];
        return !!(c && c.detail && c.detail.sysupdate);
    }
    readonly property string safeWhy: !root.risky || root.riskIgnore.length === 0 ? "No risky packages to hold back"
        : root.testPath.length > 0 ? ""
        : root.off ? "Updates are turned off in Settings"
        : root.notSetUp.length > 0 ? root.notSetUp
        : !root.sysupdateFound ? "sysupdate is not installed"
        : Capabilities.whyFirst(["apps.terminal"])
    readonly property string listWhy: root.off ? "Updates are turned off in Settings"
        : root.notSetUp || (root.testPath.length > 0 ? "" : (Providers.whyNot("updates", "list") || Capabilities.whyFirst(["apps.terminal"])))

    /**
     * F3b: las dos órdenes en la terminal del usuario (antes con `kitty` fijo); también para `terminalArgv`.
     * F3d-1: la de Upgrade es el argv de la tarea (null sin ella); la lista sigue siendo la del proveedor
     * del rice (`updates.sh --list`, F4).
     */
    function updateArgv() {
        const t = root.upgradeTask;
        if (t) return Apps.terminalArgv(t.argv, { title: t.title || "" });
        // F4e: sin tarea, la orden del proveedor propio (actualiza, vuelve a comprobar y espera ⏎)
        return root.builtinProvider ? Apps.terminalArgv(["python3", root.providerScript, "--upgrade"], { title: "system-upgrade" }) : null;
    }
    /**
     * Con el propio, su --upgrade (vuelve a comprobar la caché al acabar); con otro proveedor, sysupdate
     * directo (su `after` refresca la caché del rice).
     */
    function safeArgv() {
        if (root.riskIgnore.length === 0) return null;
        const globs = root.riskIgnore.join(",");
        const argv = root.builtinProvider ? ["python3", root.providerScript, "--upgrade", "--ignore", globs]
                                          : ["sysupdate", "-i", globs];
        return Apps.terminalArgv(argv, { title: "system-upgrade" });
    }
    /** F4e: la lista la da el proveedor (el del autor: los mismos argv de siempre, `updates.sh --list`). */
    function listArgv() {
        const argv = Providers.command("updates", "list", {});
        return argv ? Apps.terminalArgv(argv, { title: "updates-list" }) : null;
    }

    function summary() {
        return { count: root.count, state: root.state, failed: root.failed, stale: root.stale, checking: root.checking,
                 checkedAt: root.checkedAt, off: root.off, builtin: root.builtinProvider, source: root.sourceLabel,
                 notSetUp: root.notSetUp, upgradeWhy: root.upgradeWhy, listWhy: root.listWhy, cache: cache.path,
                 provider: Providers.resolve("updates"), upgradeTask: root.upgradeTask ? root.upgradeTask.id : "",
                 updateArgv: root.updateArgv(), listArgv: root.listArgv(), checkArgv: Providers.command("updates", "check", {}),
                 risky: root.risky, riskText: root.riskText, riskShort: root.riskShort, riskPackages: root.riskPackages,
                 riskIgnore: root.riskIgnore, sysupdate: root.sysupdateFound, safeWhy: root.safeWhy, safeArgv: root.safeArgv() };
    }

    /** on-click: actualizar el sistema en una terminal (F4e: la tarea si la hay; si no, la del proveedor propio). */
    function update() {
        if (root.upgradeWhy.length > 0) return false;
        const t = root.upgradeTask;
        const argv = root.updateArgv();
        if (!argv) return false;
        Apps.spawn(argv, Apps.terminalName);
        // 11A-2: sólo se sabe que se abrió la terminal (nunca «Completed»)
        Activity.record({ kind: t ? t.id : "update", label: t ? t.label : "Update the system", result: "opened",
                          summary: "Opened in terminal" });
        return true;
    }

    /** «Safe upgrade»: actualizar en una terminal reteniendo los paquetes de riesgo (sysupdate -i). */
    function updateSafe() {
        if (root.safeWhy.length > 0) return false;
        const argv = root.safeArgv();
        if (!argv) return false;
        Apps.spawn(argv, Apps.terminalName);
        Activity.record({ kind: "update-safe", label: "Safe upgrade", result: "opened",
                          summary: "Opened in terminal · holding back " + root.riskIgnore.join(", ") });
        return true;
    }

    /** on-click-right: ver la lista de paquetes pendientes. */
    function list() {
        if (root.listWhy.length > 0) return false;
        const argv = root.listArgv();
        if (!argv) return false;
        Apps.spawn(argv, Apps.terminalName);
        return true;
    }

    /** on-click-middle: forzar una comprobacion. */
    function recheck() {
        if (root.testPath.length > 0) { root.checking = true; checkTimeout.restart(); return; }
        if (root.off || root.notSetUp.length > 0) return;      // F2d/F4e: no hay a quién pedirlo
        // F4e: la comprobación es del proveedor (la del autor: `systemctl --user start updates-check.service`)
        const argv = Providers.command("updates", "check", {});
        if (!argv) return;
        Quickshell.execDetached(argv);
        root.checking = true;
        root.recheckStalled = false;
        checkTimeout.restart();
    }

    /**
     * F4e: con el proveedor PROPIO nadie más comprueba (al autor se lo hace updates-check.timer cada 30 min): la
     * shell lo hace con la misma cadencia, y una vez al poco de arrancar si la caché falta o tiene más de 30 min.
     * Es la función (como el temporizador del rice), no un sondeo de capacidades; la comprobación corre en una
     * unidad transitoria y no toca la base real de pacman.
     */
    Timer {
        interval: 30 * 60 * 1000
        repeat: true
        running: root.builtinProvider && root.notSetUp.length === 0
        onTriggered: root.recheck()
    }
    Timer {
        interval: root.firstCheckMs
        running: root.builtinProvider && root.notSetUp.length === 0 && Providers.settled
        onTriggered: if (root.stale || Date.now() - root.checkedAt > 30 * 60 * 1000) root.recheck()
    }
    /** Pruebas: el retraso de la primera comprobación (por defecto 90 s). */
    property int firstCheckMs: parseInt(Quickshell.env("KT_UPDATES_FIRST_CHECK_MS") || "90000", 10)
}
