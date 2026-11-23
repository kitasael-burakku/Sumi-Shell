pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/fuzzy.js" as Fuzzy
import "../lib/terminal.js" as Term
import "../lib/desktop-exec.js" as DesktopExec
import "../lib/app-launch.js" as Launch
import "../lib/xdg.js" as Xdg

/**
 * Installed applications, ranked.
 *
 * `DesktopEntries.applications` fills in asynchronously — it reads 0 entries in
 * `Component.onCompleted` and about 70 a third of a second later, the same
 * shape as the Hyprland models (BUG-1). Everything here is a binding, so the
 * list simply appears when it is ready; nothing reads it once and caches it.
 *
 * Launch counts are kept so the things you actually open float to the top of an
 * empty query. They are the only thing this service writes.
 */
Singleton {
    id: root

    readonly property string stateDir: Xdg.base(Quickshell.env("XDG_STATE_HOME"), Quickshell.env("HOME") + "/.local/state") + "/sumi-shell"

    /**
     * F3b (portabilidad, H-28): la terminal del USUARIO. Hasta aquí era `kitty` fijo (y otras cinco
     * copias en Updates, Commands, Jobs y Calendar). `apps.terminal` explícita manda; con «auto», la
     * que detectó scripts/capabilities.py (`detail.bin`: xdg-terminal-exec → $TERMINAL → lista). Sin
     * detección todavía, xdg-terminal-exec, el estándar: si no está, systemd-run sale con 1 sin crear
     * unidad y la detección lo explica. El argv lo construye `lib/terminal.js`, para TODOS los sitios.
     */
    readonly property var terminalCap: Capabilities.caps["apps.terminal"] || null
    readonly property string terminal: Settings.appTerminal !== "auto" ? Settings.appTerminal
        : (root.terminalCap && root.terminalCap.detail && root.terminalCap.detail.bin) ? String(root.terminalCap.detail.bin)
        : "xdg-terminal-exec"
    /** El nombre del ejecutable (el del scope de los lanzamientos a terminal). */
    readonly property string terminalName: Term.baseName(root.terminal)
    /** Para los textos («Opens in Kitty»). */
    readonly property string terminalLabel: Term.label(root.terminal)
    function labelOf(bin) { return Term.label(bin); }
    /** `argv` abierto en la terminal del usuario; opts { title, cwd }. */
    function terminalArgv(argv, opts) {
        return Term.build(root.terminal, Settings.appTerminalExec, argv, opts || {}).argv;
    }

    readonly property var entries: {
        const src = DesktopEntries.applications.values;
        const out = [];
        for (let i = 0; i < src.length; i++)
            if (src[i] && !src[i].noDisplay)
                out.push(src[i]);
        return out;
    }
    readonly property int count: root.entries.length

    property var usage: ({})

    function rank(query) {
        return Fuzzy.rank(root.entries, query, root.usage);
    }

    /** Sube el recuento de uso de cada clave y lo guarda (unico escritor del archivo). */
    function _bump(keys) {
        const next = Object.assign({}, root.usage);
        for (let i = 0; i < keys.length; i++)
            next[keys[i]] = (next[keys[i]] || 0) + 1;
        root.usage = next;
        usageFile.setText(JSON.stringify(root.usage));
    }

    /**
     * **Cada app en su propia unidad** (2026-10-02). Hasta hoy lo que lanzaba el shell (`execute()` o
     * `execDetached`) nacía DENTRO del cgroup de `sumi-shell.service`: Discord y Steam aparecían
     * ahí (la unidad marcó 8,6 GB de pico con un shell de 518 MB) y, con `KillMode=control-group`,
     * un `systemctl --user restart sumi-shell` o el reinicio tras una caída cerraba todas las apps
     * abiertas desde el launcher. Ahora van en un scope transitorio `app-sumi-<app>-<azar>.scope`
     * bajo `app.slice` (el nombre que pide la especificación de systemd para escritorios).
     *
     * Medido en esta máquina: `systemd-run --scope` hereda entorno y directorio (llega
     * `WAYLAND_DISPLAY`), se convierte en el programa (no deja un proceso intermedio) y comprueba el
     * ejecutable ANTES de crear la unidad: si no existe sale con 1 en ~11 ms, sin unidad.
     *
     * Sólo para lo que el usuario abre (apps, terminales, navegador, `xdg-open`); los scripts del
     * propio shell (tema, matugen, chmod…) siguen siendo suyos.
     */
    function scoped(argv, name, unit) {
        return Launch.scoped(argv, name, unit, root.launchBackend);
    }

    // F8b: caps[] puede estar forzado. Sólo el informe REAL selecciona auto.
    readonly property string launchBackend: Settings.loaded
        ? Launch.backend(Settings.appLaunchScope, Capabilities.source, Capabilities.helper,
                         Capabilities.checking, Capabilities.report) : ""
    property string lastLaunchError: ""
    property var launchQueue: []
    readonly property int launchWaitMs: 10000
    readonly property string launchHelper: Quickshell.shellPath("scripts/app-launch.py")
    onLaunchBackendChanged: root.flushLaunches()

    function launchFailure(why) {
        root.lastLaunchError = why;
        console.warn("apps:", why);
        Activity.record({ kind: "app-launch", label: "Launch application", result: "failed", summary: why });
    }
    /** true = petición aceptada (quizá en cola), nunca confirmación de una ventana. */
    function withBackend(done) {
        if (root.launchBackend.length > 0) { done(root.launchBackend, ""); return true; }
        if (root.launchQueue.length >= 32) { root.launchFailure("Too many pending app launches"); return false; }
        root.launchQueue = root.launchQueue.concat([{ done: done, until: Date.now() + root.launchWaitMs }]);
        root.flushLaunches();
        if (!Capabilities.checking) Capabilities.refresh("app launch");
        return true;
    }
    function flushLaunches() {
        launchDeadline.stop();
        const pending = root.launchQueue;
        root.launchQueue = [];
        const backend = root.launchBackend, now = Date.now();
        const keep = [];
        for (const item of pending) {
            if (backend) item.done(backend, "");
            else if (now >= item.until) {
                const why = "Can't choose how to launch apps: couldn't check the user service manager";
                root.launchFailure(why);
                item.done("", why);
            } else keep.push(item);
        }
        root.launchQueue = keep.concat(root.launchQueue);
        if (root.launchQueue.length > 0) {
            launchDeadline.interval = Math.max(1, Math.min.apply(null, root.launchQueue.map(x => x.until)) - Date.now());
            launchDeadline.start();
        }
    }
    Timer { id: launchDeadline; onTriggered: root.flushLaunches() }
    function withLaunch(argv, name, unit, done) {
        if (!argv || argv.length === 0) return false;
        const requested = Array.from(argv);
        return root.withBackend((backend, why) => done(Launch.scoped(requested, name, unit, backend), why, backend));
    }
    /** El programa directo sobrevive a la shell; el helper corto sólo confirma exec. */
    function detachedCommand(argv) { return ["python3", root.launchHelper, "start", "--"].concat(argv); }
    Component {
        id: detachedComp
        Process {
            id: p
            property var callback: null
            property bool began: false
            property bool done: false
            stderr: StdioCollector { id: launchErr }
            onStarted: p.began = true
            onExited: code => {
                if (p.done) return;
                p.done = true;
                const why = code === 0 ? "" : (launchErr.text.trim() || "Could not start the application");
                if (why) root.launchFailure(why);
                if (p.callback) p.callback(code === 0, why);
                p.destroy();
            }
            onRunningChanged: {
                if (p.running) return;
                if (!p.began && !p.done) {
                    p.done = true;
                    root.launchFailure("Could not start the app launch helper (python3)");
                    if (p.callback) p.callback(false, root.lastLaunchError);
                    p.destroy();
                }
            }
        }
    }
    function spawn(argv, name, done) {
        return root.withLaunch(argv, name, "", (command, why, backend) => {
            if (why) { if (done) done(false, why); return; }
            root.lastLaunchError = "";
            if (backend === "direct") {
                const p = detachedComp.createObject(root, { command: root.detachedCommand(command), callback: done || null });
                p.running = true;
            } else {
                Quickshell.execDetached(command);
                if (done) done(true, "");
            }
        });
    }

    /**
     * **El argv de una entrada o acción: SIEMPRE por aquí, nunca `.command` a pelo** (ADR-32,
     * 2026-10-11). `DesktopEntry.command` de Quickshell 0.3.2 toma el apóstrofe como comilla aunque
     * vaya dentro de comillas dobles: `umu-run "/…/Slave's Nightmare [Final]/Game_en.exe"` llegaba
     * partido en tres argumentos y el juego no abría (con `gio launch`, sí). Se trocea `execString`
     * (el `Exec=` crudo) con `lib/desktop-exec.js`, que sigue la especificación. Si no hay
     * `execString` (las entradas de ejemplo del verbo `terminalArgv`) o está mal formado (comilla
     * sin cerrar), se cae a `command`, lo de antes.
     */
    function argvOf(x) {
        if (!x)
            return [];
        const exec = String(x.execString || "");
        if (exec.length > 0) {
            const p = DesktopExec.parse(exec, { icon: x.icon || "", name: x.name || "" });
            if (p.error.length === 0 && p.argv.length > 0)
                return p.argv;
            console.warn("apps:", x.id || "?", "Exec= not parseable (" + (p.error || "empty") + "), using Quickshell's argv");
        }
        return x.command ? Array.from(x.command) : [];
    }

    /**
     * Lo que hacía `execute()` (el `Exec=` sin códigos de campo, en `Path=` si lo hay), pero en su
     * scope. Una entrada sin orden (sólo `DBusActivatable`) sigue con `execute()`.
     */
    function _exec(entry, target) {
        const cmd = root.argvOf(target);
        if (!cmd || cmd.length === 0) {
            target.execute();
            return true;
        }
        const wd = String(entry.workingDirectory || "");
        return root.spawn(wd.length > 0 ? ["env", "-C", wd].concat(cmd) : cmd, entry.id);
    }

    /**
     * Lanzar una entrada `.desktop`.
     *
     * `DesktopEntry.execute()` de Quickshell 0.3.1 **ignora `Terminal=true`**:
     * ejecuta el `Exec=` pelado, sin tty, y el proceso muere al instante.
     * Comprobado el 2026-09-08 con dos `.desktop` identicos salvo el `Terminal=`:
     * los dos corrieron el mismo script con `tty=not a tty` y `ppid=1`. Son 8
     * entradas en esta maquina (btop, nvim, vim, yazi, micro, nvtop, jshell x2)
     * y ninguna arrancaba desde el launcher, mientras que rofi si las lanzaba
     * porque tiene `terminal: "kitty"` en su config.
     *
     * `root.argvOf(entry)` ya viene con los codigos de campo (`%F`, `%f`) quitados;
     * medido: `Exec=nvim %F` da `["nvim"]` (antes era `entry.command`; ADR-32).
     *
     * El directorio de trabajo se pasa con la bandera de la terminal (o `env -C`
     * si su perfil no tiene; F3b, lib/terminal.js) porque `execDetached` NO acepta
     * la forma de objeto en 0.3.1: probado, responde `TypeError: Passing
     * incompatible arguments to C++ functions`. Hoy ninguna entrada con
     * `Terminal=true` del sistema trae `Path=`, asi que es un cinturon, no un parche.
     */
    /**
     * Portabilidad F2d: lo que va «en terminal» (Terminal=true, acciones, ⇧⏎ del modo run, abrir un
     * archivo con un manejador de terminal) usa la terminal del usuario (F3b). Sin ella no se lanza
     * nada a medias; el launcher lo dice antes (`terminalWhy`).
     */
    readonly property string terminalWhy: Capabilities.whyFirst(["apps.terminal"])
    /** El último lanzamiento rechazado, para quien quiera decirlo ({ id, why, at }). */
    property var refused: null
    function refuse(id) {
        root.refused = { id: String(id || ""), why: root.terminalWhy, at: Date.now() };
        console.warn("apps:", id, "needs a terminal ·", root.terminalWhy);
        return false;
    }

    /**
     * F3b: lo que lanza cada sitio de terminal, sin lanzar. Los usan el lanzamiento real y el verbo
     * de prueba `terminalArgv` (que así enseña EXACTAMENTE lo mismo).
     */
    function termLaunchArgv(entry) {
        return root.terminalArgv(root.argvOf(entry), { cwd: String(entry.workingDirectory || "") });
    }
    function termActionArgv(action) { return root.terminalArgv(root.argvOf(action), {}); }
    function termRunArgv(argv) { return root.terminalArgv(argv, {}); }
    function termOpenArgv(entry, path) {
        const dir = path.slice(0, path.lastIndexOf("/")) || "/";
        return root.terminalArgv(root.argvOf(entry).concat([path]), { cwd: dir });
    }

    function launch(entry) {
        if (!entry)
            return false;
        if (entry.runInTerminal && root.terminalWhy.length > 0) return root.refuse(entry.id);
        if (entry.id)
            root._bump([entry.id]);
        if (entry.runInTerminal && root.argvOf(entry).length > 0) {
            return root.spawn(root.termLaunchArgv(entry), entry.id);
        } else {
            return root._exec(entry, entry);
        }
        return true;
    }

    /**
     * ACCIONES DEL `.desktop` (QS-FUNC-010): «New Private Window» de Zen y
     * Chromium, los 9 verbos de Steam, «New Window» de Nautilus… Estaban
     * cargadas en `entry.actions` y nadie las ofrecia; tampoco rofi `drun`.
     * Medido: 6 de 58 entradas publican alguna. `argvOf(action)` llega sin los
     * codigos de campo (`zen-bin --private-window %u` -> `["zen-bin",
     * "--private-window"]`).
     *
     * `entry.actions` es una lista de C++, no un `Array`: se recorre con indice.
     * Ordenadas por uso (`<id>#<accion>` en el mismo `launcher-usage.json`;
     * `Fuzzy.rank` solo consulta por `entry.id`, las claves con `#` no le
     * afectan) y, a igualdad, en el orden del `.desktop`.
     */
    function actionsOf(entry) {
        if (!entry || !entry.actions)
            return [];
        const rows = [];
        for (let i = 0; i < entry.actions.length; i++) {
            const a = entry.actions[i];
            if (a)
                rows.push({ a: a, i: i, n: root.usage[entry.id + "#" + a.id] || 0 });
        }
        rows.sort(function (x, y) { return (y.n - x.n) || (x.i - y.i); });
        return rows.map(function (r) { return r.a; });
    }

    function hasActions(entry) {
        return !!entry && !!entry.actions && entry.actions.length > 0;
    }

    /**
     * Mismo reparto que `launch()`: con `Terminal=true` se envuelve en la
     * terminal por argv, porque `execute()` no lo honra (ADR-26) -- se asume
     * que la accion hereda el `Terminal=` de su entrada, que es lo que dice la
     * especificacion. Sin terminal, la orden de la accion en su scope (`_exec`). Cuenta el uso de
     * la accion y el de la app.
     */
    function launchAction(entry, action) {
        if (!entry || !action)
            return false;
        if (entry.runInTerminal && root.terminalWhy.length > 0) return root.refuse(entry.id);
        root._bump(entry.id ? [entry.id, entry.id + "#" + action.id] : []);
        if (entry.runInTerminal && root.argvOf(action).length > 0)
            return root.spawn(root.termActionArgv(action), entry.id);
        else
            return root._exec(entry, action);
    }

    /**
     * Ejecutar un comando escrito a mano: el modo `run` que tenia rofi y el
     * launcher no (`modi: "drun,run,…"` en `rofi/config.rasi`).
     *
     * **Siempre argv, nunca `sh -c`**: regla 3 de `docs/SECURITY.md`, la misma
     * por la que ese documento ya cuenta `execDetached` con argv en su lista de
     * positivos. Lo que se teclea son argumentos, no una linea de shell: no hay
     * expansion, ni tuberias, ni `;`. Ejecutar lo que escribes no es instalar lo
     * que sueltas (H2): esto no descarga, no extrae y no pide `pkexec`.
     */
    function run(argv, inTerminal) {
        if (!argv || argv.length === 0 || String(argv[0]).length === 0)
            return false;
        if (inTerminal && root.terminalWhy.length > 0) return root.refuse(argv[0]);
        return root.spawn(inTerminal ? root.termRunArgv(argv) : argv, argv[0]);
    }

    /**
     * Abrir un archivo con su manejador por defecto — para el modo archivo del
     * launcher (Fase 10.c.2). Es `xdg-open`, con una vuelta: si el manejador es
     * una app de terminal (aqui `text/plain` → `micro`), `xdg-open` la lanza sin
     * tty y no sale nada (mismo problema que ADR-26 con `DesktopEntry.execute()`).
     * Se resuelve mime → `.desktop` → si `Terminal=true`, se envuelve en la terminal del usuario.
     * Todo argv, sin `sh -c`.
     */
    property string _openPath: ""

    function openPath(path) {
        if (typeof path !== "string" || path.charAt(0) !== "/")
            return false;
        root._openPath = path;
        mimeProc.command = ["xdg-mime", "query", "filetype", path];
        mimeProc.running = true;
        return true;
    }

    function _entryById(id) {
        const base = String(id).replace(/\.desktop$/, "");
        const src = DesktopEntries.applications.values;
        for (let i = 0; i < src.length; i++)
            if (src[i] && (src[i].id === id || src[i].id === base))
                return src[i];
        return null;
    }

    Process {
        id: mimeProc
        stdout: StdioCollector { id: mimeOut }
        onExited: (code) => {
            const mime = mimeOut.text.trim();
            if (code !== 0 || mime.length === 0) {
                root.spawn(["xdg-open", root._openPath], "xdg-open");
                return;
            }
            defProc.command = ["xdg-mime", "query", "default", mime];
            defProc.running = true;
        }
    }

    Process {
        id: defProc
        stdout: StdioCollector { id: defOut }
        onExited: () => {
            const path = root._openPath;
            const entry = root._entryById(defOut.text.trim());
            if (entry && entry.runInTerminal && root.argvOf(entry).length > 0) {
                if (root.terminalWhy.length > 0) { root.refuse(entry.id); return; }
                root.spawn(root.termOpenArgv(entry, path), entry.id);
            } else {
                root.spawn(["xdg-open", path], entry ? entry.id : "xdg-open");
            }
        }
    }

    // ---- calcurse (Calendar) ------------------------------------------------

    /**
     * F3b: abrir o cerrar calcurse. Hasta aquí era una línea de `sh -c` (`hyprctl clients | grep …
     * && pkill -f 'kitty --title calcurse' || exec kitty --title calcurse -e calcurse`), atada a kitty.
     * Ahora: el mismo argv interior en la terminal del usuario, en un scope de NOMBRE FIJO; si ese scope
     * está activo, se para (cierra la ventana), y si no, se abre. Diferencia aceptada: una calcurse
     * abierta fuera de la shell ya no se cierra desde aquí.
     */
    readonly property string calcurseUnit: "app-sumi-calcurse.scope"
    property bool calcursePending: false
    property string calcurseBackend: ""
    /** Lo mismo que dice Calendar (F2d): sin calcurse o sin terminal, no. */
    function calcurseWhy() { return Capabilities.whyFirst(["agenda.calcurse", "apps.terminal"]); }
    function calcurseArgv() { return root.terminalArgv(["calcurse"], { title: "calcurse" }); }
    function toggleCalcurse() {
        if (calcurseProc.running || root.calcursePending) return false;
        root.calcursePending = true;
        const argv = root.calcurseArgv();
        const accepted = root.withBackend((backend, why) => {
            root.calcursePending = false;
            if (why) return;
            root.calcurseBackend = backend;
            calcurseProc.command = backend === "direct"
                ? ["python3", root.launchHelper, "calcurse", "--"].concat(argv)
                : ["systemctl", "--user", "is-active", "--quiet", root.calcurseUnit];
            calcurseProc.running = true;
        });
        if (!accepted) root.calcursePending = false;
        return accepted;
    }
    Process {
        id: calcurseProc
        stderr: StdioCollector { id: calcurseErr }
        onExited: (code) => {
            if (root.calcurseBackend === "direct") {
                if (code !== 0) root.launchFailure(calcurseErr.text.trim() || "Could not toggle the agenda");
                return;
            }
            if (code === 0) Quickshell.execDetached(["systemctl", "--user", "stop", root.calcurseUnit]);
            else Quickshell.execDetached(Launch.scoped(root.calcurseArgv(), "calcurse", root.calcurseUnit, "systemd"));
        }
    }

    // ---- ejecutables de PATH, para el modo `run` ---------------------------

    /** Mapa nombre -> true. Un objeto, no un array: la consulta es por clave. */
    property var commands: ({})
    property int commandCount: 0

    function hasCommand(name) {
        return typeof name === "string" && name.length > 0
            && root.commands[name] === true;
    }

    /**
     * Perezoso (ADR-9): se llama al abrir el launcher, no al arrancar. Medido
     * en esta maquina: 3787 nombres, ~40 KB.
     *
     * Se REESCANEA al abrir si el ultimo tiene mas de `pathMaxAgeMs`
     * (QS-FUNC-020). Antes era una vez por sesion: instalabas algo y aparecia
     * en la lista de apps (`DesktopEntries` se refresca solo) pero no en la de
     * comandos. Mientras reescanea, sigue valiendo el mapa anterior.
     */
    readonly property int pathMaxAgeMs: 5 * 60 * 1000
    property real pathScannedAt: 0

    function scanPath() {
        if (pathProc.running)
            return;
        if (root.commandCount === 0 || Date.now() - root.pathScannedAt > root.pathMaxAgeMs)
            pathProc.running = true;
    }

    property bool pathWarned: false

    Process {
        id: pathProc
        // Sin interpolar nada: `$PATH` lo lee el propio shell del entorno que ya
        // es del usuario. Mismo patron que el `scanProc` de services/Wallpaper.
        //
        // El `2>/dev/null` cuelga del `done`, o sea que se traga el ruido de
        // `find` directorio a directorio: una entrada de `$PATH` ilegible o un
        // enlace roto son normales y no son noticia. Al `stderr` de abajo llega
        // lo que falle FUERA de ese bucle (el propio `sh`, `sort`).
        command: ["sh", "-c",
            "IFS=:; for d in $PATH; do [ -d \"$d\" ] && "
            + "find -L \"$d\" -maxdepth 1 -type f -executable -printf '%f\\n'; "
            + "done 2>/dev/null | sort -u"]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = this.text.split("\n");
                const m = ({});
                let n = 0;
                for (let i = 0; i < lines.length; i++) {
                    if (lines[i].length === 0)
                        continue;
                    m[lines[i]] = true;
                    n++;
                }
                root.commands = m;
                root.commandCount = n;
                root.pathScannedAt = Date.now();
            }
        }
        /**
         * stderr recogido (QS-FUNC, §10 de la auditoria): era el ultimo
         * `Process` de la lista que lo tiraba. Este escaneo es lo UNICO que
         * llena la lista de comandos del lanzador, asi que si fallaba no
         * quedaba rastro: el lanzador se abria sin comandos y parecia que la
         * maquina no tuviera ninguno. Se avisa al entrar en fallo, no en cada
         * reescaneo (uno cada `pathMaxAgeMs` al abrir).
         */
        stderr: StdioCollector { id: pathErr }
        onExited: (code) => {
            if (code !== 0 && !root.pathWarned)
                console.warn("apps: el escaneo de $PATH salio con", code, "—",
                             pathErr.text.trim());
            root.pathWarned = code !== 0;
        }
    }

    /**
     * Un nombre de icono a algo que `Image` pueda cargar, o "" si no hay nada.
     *
     * NO VALE `Quickshell.iconPath(name, fallback)` a secas: devuelve
     * `image://icon/<name>` **aunque el icono no exista en el tema** (medido el
     * 2026-09-14: `"codium"` -> `image://icon/codium` con `hasThemeIcon` false),
     * y el proveedor pinta entonces el cuadro morado y negro de «falta la
     * textura» con `status` Ready -- asi que ningun respaldo por `status` se
     * entera. Era el icono roto del minimizador con VSCodium y de
     * `insect-prision` en el lanzador. Se pregunta a `hasThemeIcon` antes.
     */
    function iconSource(name, fallback) {
        const n = String(name || "");
        if (n.startsWith("/"))
            return "file://" + n;   // Icon= con ruta absoluta (osu-wine, xgps)
        if (n.length > 0 && Quickshell.hasThemeIcon(n))
            return Quickshell.iconPath(n);
        const f = String(fallback || "");
        if (f.length > 0 && Quickshell.hasThemeIcon(f))
            return Quickshell.iconPath(f);
        return "";
    }

    function iconFor(entry) {
        if (!entry)
            return "";
        return root.iconSource(entry.icon, "application-x-executable");
    }

    /** Not watched: the shell is the only writer, and re-reading our own write races the cached text. */
    FileView {
        id: usageFile
        path: root.stateDir + "/launcher-usage.json"
        blockLoading: true
        printErrors: false
        onLoadFailed: function (error) {
            if (error === FileViewError.FileNotFound)
                usageFile.setText("{}");
        }
    }

    Component.onCompleted: {
        try {
            const saved = JSON.parse(usageFile.text());
            if (saved && typeof saved === "object" && !Array.isArray(saved))
                root.usage = saved;
        } catch (e) {
            root.usage = ({});
        }
    }
}
