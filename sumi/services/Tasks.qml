pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/tasks-schema.js" as TasksSchema

/**
 * Las tareas de mantenimiento que declara el usuario (portabilidad F3d-1, 2026-10-06; H-14, HC-20…28).
 *
 *   $XDG_CONFIG_HOME/sumi-shell/tasks.json      formato v1 (lib/tasks-schema.js)
 *
 * Lo ÚNICO ejecutable de la configuración. Por eso:
 *   · la shell sólo lo LEE (la migración v3 lo sembró una vez; nada más lo escribe);
 *   · se ignora entero si no es del usuario o lo pueden escribir el grupo u otros (`stat -L`, en cada
 *     cambio): una tarea es una orden que la shell ejecutará cuando se pulse;
 *   · argv en lista, nunca una línea para `sh -c` construida aquí;
 *   · no se exporta ni se importa (Portability no lo conoce).
 *
 * Sin archivo no hay tareas: Jobs, Commands, Issues, Checks y (F3d-2) el Dashboard no ofrecen
 * mantenimiento. Lo inválido se descarta con su motivo; lo demás sigue.
 *
 * `status`: loading · none (no hay archivo) · ready · invalid (no se puede usar: JSON, estructura) ·
 * ignored (dueño o permisos) · unreadable.
 */
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string path: Settings.configDir + "/tasks.json"

    property string status: "loading"
    /** Por qué no hay tareas (inglés, para la UI); "" en ready/none. */
    property string reason: ""
    /** Las válidas, normalizadas (argv[0] y rutas con ~/ ya expandidas). */
    property var tasks: []
    /** [{ index, id, error }] lo descartado. */
    property var errors: []
    property bool newer: false
    /** Cuántas lecturas van (para pruebas: «se releyó»). */
    property int reads: 0

    readonly property bool ready: root.status === "ready"

    function byId(id) {
        for (let i = 0; i < root.tasks.length; i++) if (root.tasks[i].id === id) return root.tasks[i];
        return null;
    }
    function has(id) { return root.byId(id) !== null; }
    /** La tarea con ese papel (system-upgrade), o null. */
    function withRole(role) {
        for (let i = 0; i < root.tasks.length; i++) if (root.tasks[i].role === role) return root.tasks[i];
        return null;
    }
    /** Por qué una tarea no existe aquí ("" si existe). */
    function whyMissing(id) {
        if (root.has(id)) return "";
        if (root.status === "loading") return "";       // aún no se sabe: no se niega nada
        if (root.status === "none") return "Not set up in tasks.json";
        if (root.status === "ready") return "Not declared in tasks.json";
        return root.reason;
    }

    // ---- leer --------------------------------------------------------------------------------

    property string pendingText: ""
    property bool retried: false
    Timer { id: retry; interval: 200; onTriggered: file.reload() }
    /** La lectura de asentamiento (ver onFileChanged): una por ráfaga de cambios, nunca periódica. */
    Timer { id: settle; interval: 150; onTriggered: file.reload() }

    FileView {
        id: file
        path: root.path
        watchChanges: true
        printErrors: false
        // un editor que sustituye el archivo: el vigilante sigue al inodo viejo (como en Settings).
        // 2026-11-20 (docs/MINIMARU-CLIS-2026-11-20.md §12): con dos escrituras seguidas la segunda podía no leerse
        // nunca: caía en el hueco del re-armado, o FileView descartaba las lecturas pedidas casi a la vez (sin
        // `loaded` ni `loadFailed`). Cada aviso reinicia `settle` y, tras 150 ms sin cambios, se lee una vez más.
        onFileChanged: {
            reload();
            Qt.callLater(function () { file.watchChanges = false; file.watchChanges = true; });
            settle.restart();
        }
        onLoaded: {
            root.pendingText = file.text();
            root.loadGen++;
            root.lastLoadOk = true;
            root.startPerm();
        }
        onLoadFailed: (error) => {
            root.loadGen++;
            root.lastLoadOk = false;
            root.tasks = [];
            root.errors = [];
            root.reads++;
            if (error === FileViewError.FileNotFound) { root.status = "none"; root.reason = ""; }
            else { root.status = "unreadable"; root.reason = "tasks.json could not be read"; }
        }
    }

    /**
     * Un vigilante no sigue un directorio que aún no existe. Medido en el banco: en una instalación
     * nueva Settings crea ~/.config/sumi-shell DESPUÉS de que esto empiece a vigilar, y crear
     * tasks.json con la shell abierta no se veía hasta reiniciar. Se asegura el directorio (Settings lo
     * crearía igual) y se rearma el vigilante.
     */
    Process {
        id: ensureDir
        command: ["mkdir", "-p", "--", Settings.configDir]
        onExited: { file.watchChanges = false; file.watchChanges = true; file.reload(); }
    }
    Component.onCompleted: ensureDir.running = true

    /**
     * Dueño y permisos, ANTES de usar lo leído. Una orden fija con la ruta como argumento (nada se
     * interpola): primera línea `uid modo` del archivo (siguiendo enlaces), segunda el uid propio.
     *
     * 2026-11-20 (docs/MINIMARU-CLIS-2026-11-20.md §11): cada lectura reiniciaba el `stat` en curso
     * (`running = false; true`); el interrumpido salía ≠ 0 y `judge` marcaba «Could not check who owns
     * tasks.json» (`unreadable`) hasta el siguiente. Ahora no se interrumpe: cada lectura sube `loadGen`, el
     * `stat` recuerda la suya y, si al acabar ya hubo otra, su resultado no vale: se lanza otro si la última
     * lectura fue buena (si falló, onLoadFailed ya dejó el estado).
     */
    property int loadGen: 0
    property int permGen: -1
    property bool lastLoadOk: false
    function startPerm() {
        if (perm.running) return;          // al acabar verá que hubo otra lectura y repetirá
        root.permGen = root.loadGen;
        perm.running = true;
    }
    Process {
        id: perm
        command: ["sh", "-c", "stat -L -c '%u %a' -- \"$1\" && id -u", "sh", root.path]
        stdout: StdioCollector { id: permOut }
        onExited: (code) => {
            if (root.permGen !== root.loadGen) {
                if (root.lastLoadOk) Qt.callLater(root.startPerm);
                return;
            }
            root.judge(code, permOut.text);
        }
    }

    function judge(code, out) {
        root.reads++;
        const lines = String(out || "").trim().split("\n");
        const st = (lines[0] || "").split(" ");
        const me = (lines[1] || "").trim();
        if (code !== 0 || st.length < 2 || me.length === 0) {
            root.set("unreadable", "Could not check who owns tasks.json", [], []);
            return;
        }
        const mode = parseInt(st[1], 8);
        if (st[0] !== me) {
            root.set("ignored", "tasks.json is ignored: it does not belong to you", [], []);
            return;
        }
        if ((mode & 18) !== 0      /* 0o022: escribible por grupo u otros */) {
            root.set("ignored", "tasks.json is ignored: other users can change it (chmod go-w)", [], []);
            return;
        }
        let doc;
        try { doc = JSON.parse(root.pendingText); }
        catch (e) {
            // F3e: un editor que escribe EN EL SITIO vacía el archivo antes de escribir; si se lee en ese
            // hueco y el aviso de la escritura se pierde, se quedaba «not valid JSON» (medido en el banco,
            // intermitente). Como Settings: se relee una vez antes de darlo por roto.
            if (!root.retried) { root.retried = true; retry.restart(); return; }
            root.set("invalid", "tasks.json is not valid JSON", [], []);
            return;
        }
        root.retried = false;
        const r = TasksSchema.validate(doc, root.home);
        if (r.structure.length > 0) { root.set("invalid", "tasks.json: " + r.structure, [], []); return; }
        root.newer = r.newer;
        root.set("ready", "", r.tasks, r.errors);
        if (r.errors.length > 0)
            console.warn("tasks: ignored " + r.errors.map(e => (e.id || "#" + e.index) + " (" + e.error + ")").join(", "));
    }

    function set(status, reason, tasks, errors) {
        root.tasks = tasks;
        root.errors = errors;
        root.reason = reason;
        root.status = status;
        if (reason.length > 0) console.warn("tasks: " + reason);
    }

    function summary() {
        return { status: root.status, reason: root.reason, path: root.path, newer: root.newer, reads: root.reads,
                 tasks: root.tasks.map(t => ({ id: t.id, runs: t.runs, argv0: t.argv[0], output: t.output,
                                               prompts: t.prompts, palette: t.palette, role: t.role || "",
                                               lastRun: t.lastRun ? t.lastRun.kind : "", summary: !!t.summary })),
                 errors: root.errors };
    }
}
