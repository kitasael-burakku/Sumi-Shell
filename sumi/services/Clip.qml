pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Portapapeles (Fase 9.g). El almacen sigue siendo `cliphist` con sus dos
 * unidades de systemd: esto es una vista, no un historial propio (ADR-13).
 *
 * PUERTA IDEMPOTENTE. Nadie lee el historial hasta que alguien lo reclama, y
 * la reclamacion es **con nombre**, no un contador: un contador `++/--` se
 * desbalancea con la descarga perezosa de las superficies, y eso ya se pago en
 * 9.f.2.
 *
 * LO QUE NO SE HACE, A PROPOSITO: no se guarda, no se reordena y no se
 * reinterpreta nada. `cliphist list` ya viene de mas reciente a mas antiguo, y
 * ese orden se respeta.
 */
Singleton {
    id: root

    property var claims: ({})
    readonly property bool wanted: Object.keys(root.claims).length > 0

    function claim(who, on) {
        if (on === !!root.claims[who]) return;
        // Objeto NUEVO: reasignar el mismo no emite la senal de cambio (QML
        // compara `var` por referencia). Tropiezo ya pagado en 9.f.2.
        const c = Object.assign({}, root.claims);
        if (on) c[who] = true; else delete c[who];
        root.claims = c;
        if (root.wanted) root.refresh();
        else root.sweep();
    }

    // ---- el historial -------------------------------------------------------

    /**
     * Portabilidad F2d (H-16): sin cliphist/wl-clipboard no se lanza nada y se dice por qué;
     * instalado pero sin quien guarde (`wl-paste --watch cliphist store`), el historial no crece:
     * `notice` lo explica sin impedir leer lo que haya.
     */
    readonly property string whyNot: Capabilities.whyFirst(["clipboard.history"])
    readonly property string notice: Capabilities.get("clipboard.history").state === "degraded"
        ? Capabilities.get("clipboard.history").reason : ""

    /** [{ id, name, image, kind, w, h, size }] — `name` es lo que busca fuzzy. */
    property var entries: []
    property bool loading: false
    property string lastError: ""

    readonly property int count: root.entries.length
    readonly property int imageCount: {
        let n = 0;
        for (let i = 0; i < root.entries.length; i++) if (root.entries[i].image) n++;
        return n;
    }

    /**
     * 2026-10-28: sin historial todavía (primer uso, o la base de cliphist borrada),
     * `cliphist list` sale con 1 y dice «opening db: please store something first»
     * (medido, cliphist 0.7.0). Eso es un historial VACÍO, no un fallo: se enseñaba
     * «Could not read the clipboard history». Sólo ese mensaje exacto; cualquier otra
     * salida distinta de 0 sigue siendo un error con su código.
     */
    readonly property string emptyDbMessage: "please store something first"

    Process {
        id: listProc
        command: ["cliphist", "list"]
        stdout: StdioCollector {
            onStreamFinished: root.parseList(this.text)
        }
        stderr: StdioCollector { id: listErr }
        onExited: (code) => {
            root.loading = false;
            if (code === 1 && String(listErr.text).indexOf(root.emptyDbMessage) >= 0) root.entries = [];
            else if (code !== 0) root.lastError = "cliphist list exited " + code;
            if (root._refreshAgain) {
                root._refreshAgain = false;
                root.refresh();
            }
        }
    }

    /** Un cambio que llego con `cliphist list` en vuelo: se relee al volver. */
    property bool _refreshAgain: false

    function refresh() {
        if (root.whyNot.length > 0) { root.lastError = root.whyNot; root.loading = false; return false; }
        if (listProc.running) {
            root._refreshAgain = true;
            return false;
        }
        // «loading» solo la primera vez: con el historial en vivo (QS-FUNC-013)
        // cada copia relee, y la cabecera parpadearia «loading…» en cada una.
        root.loading = root.entries.length === 0;
        root.lastError = "";
        listProc.running = true;
        return true;
    }

    // ---- en vivo mientras se mira (QS-FUNC-013) -----------------------------

    /**
     * Antes el historial se leia al reclamar y nada mas: lo que se copiara con
     * la superficie abierta (un gestor de contrasenas, un script) no aparecia.
     *
     * `wl-paste --watch` es el mecanismo de las propias unidades
     * `cliphist-*.service`, vivo solo con reclamacion. El hijo es `wc -c` y no
     * `echo`: `wl-paste` le escribe el contenido por stdin, y un hijo que no lo
     * lee rompe la tuberia con una imagen grande. `wc` lo drena y escribe una
     * linea por cambio. Medido con sonda `qs -p` sobre la seleccion primaria
     * (cliphist no la guarda): una linea al arrancar y una por cambio, 266 KB
     * incluidos, y el proceso sigue vivo.
     *
     * Se relee con 400 ms de margen: `cliphist store` recibe el mismo cambio a
     * la vez, y leer antes de que guarde traeria la lista vieja.
     */
    Process {
        id: watcher
        command: ["wl-paste", "--watch", "wc", "-c"]
        stdout: SplitParser { onRead: (l) => changed.restart() }
        onStarted: watchStable.restart()
        onExited: {
            watchStable.stop();
            if (!root.wanted)
                return;
            // Mismo freno que Session (QS-FUNC-002).
            if (root.watchRestarts >= 5) {
                console.warn("clip: wl-paste --watch keeps dying, giving up");
                return;
            }
            root.watchRestarts++;
            watchRespawn.restart();
        }
    }

    property int watchRestarts: 0
    readonly property bool watching: watcher.running

    onWantedChanged: {
        if (root.wanted) {
            root.watchRestarts = 0;
            if (!watcher.running && root.whyNot.length === 0) watcher.running = true;
        } else {
            watchRespawn.stop();
            changed.stop();
            watcher.running = false;
        }
    }

    Timer { id: changed; interval: 400; onTriggered: if (root.wanted) root.refresh() }
    Timer { id: watchRespawn; interval: 2000; onTriggered: if (root.wanted && root.whyNot.length === 0) watcher.running = true }
    Timer { id: watchStable; interval: 10000; onTriggered: root.watchRestarts = 0 }

    /**
     * `cliphist list` entrega `<id>\\tTAB<preview>`. El preview viene truncado a
     * ~101 caracteres por su `preview-width 100`, y una imagen se anuncia como
     * `[[ binary data 1 MiB png 1920x1080 ]]` -- **con tamano, tipo y
     * dimensiones ya dentro**, asi que la miniatura puede reservar su hueco sin
     * decodificar un solo byte.
     */
    readonly property var imageRe: /^\[\[\s*binary data\s+(\S+\s*\S*)\s+(\w+)\s+(\d+)x(\d+)\s*\]\]$/

    function parseList(text) {
        const out = [];
        const lines = text.split("\n");
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i];
            if (line.length === 0) continue;
            const tab = line.indexOf("\t");
            if (tab < 0) continue;
            const id = line.substring(0, tab);
            if (!/^[0-9]+$/.test(id)) continue;      // el id es siempre numerico
            const preview = line.substring(tab + 1);
            const m = root.imageRe.exec(preview);
            out.push(m ? {
                id: id, name: preview, image: true,
                kind: m[2], size: m[1].trim(),
                w: parseInt(m[3], 10), h: parseInt(m[4], 10)
            } : {
                id: id, name: preview, image: false,
                kind: "", size: "", w: 0, h: 0
            });
        }
        // Solo si cambio: reasignar la misma lista reinicia el `ListView` (vuelve
        // arriba), y con el vigilante eso pasaria en cada lectura.
        if (JSON.stringify(out) !== JSON.stringify(root.entries))
            root.entries = out;
        root.loading = false;
    }

    // ---- miniaturas ---------------------------------------------------------

    /**
     * Van a `$XDG_RUNTIME_DIR`, que es **tmpfs con permisos 700**: el contenido
     * del portapapeles no toca el disco y no lo ve nadie mas. Se materializan
     * **bajo demanda** y se borran al soltar la ultima reclamacion.
     */
    readonly property string thumbDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/sumi-clip"

    /** ids ya materializados; el valor sube para invalidar la cache de Qt. */
    property var made: ({})

    function thumbUrl(id) {
        return root.made[id] ? ("file://" + root.thumbDir + "/" + id + ".img") : "";
    }

    Process { id: mkdirProc; command: ["mkdir", "-p", root.thumbDir] }

    Process {
        id: decodeProc
        property string forId: ""
        onExited: (code) => {
            if (code === 0 && decodeProc.forId.length > 0) {
                const m = Object.assign({}, root.made);
                m[decodeProc.forId] = true;
                root.made = m;
            }
            decodeProc.forId = "";
            root.drainQueue();
        }
    }

    property var queue: []

    /**
     * Pide la miniatura de `id`. Idempotente y en cola de uno en uno: pedir
     * veinte a la vez seria arrancar veinte procesos por un desplazamiento de
     * la lista.
     */
    function wantThumb(id) {
        if (!/^[0-9]+$/.test(id)) return false;
        if (root.made[id]) return true;
        if (decodeProc.forId === id || root.queue.indexOf(id) >= 0) return true;
        const q = root.queue.slice();
        q.push(id);
        root.queue = q;
        root.drainQueue();
        return true;
    }

    function drainQueue() {
        if (decodeProc.running || root.queue.length === 0) return;
        const q = root.queue.slice();
        const id = q.shift();
        root.queue = q;
        if (root.made[id]) { root.drainQueue(); return; }
        mkdirProc.running = true;
        decodeProc.forId = id;
        /**
         * EXCEPCION ACOTADA A LA REGLA 3 DE `SECURITY.md`, decidida por el
         * usuario el 2026-09-09 y anotada en `MIGRATION.md`.
         *
         * `Process` no encadena ni redirige, y aunque `StdioCollector` **lee**
         * binario (`data` es un `QByteArray`), `Process.write()` sólo acepta
         * `QString`: un PNG que pase por ahi se corrompe. Asi que hace falta un
         * shell para la redireccion.
         *
         * Lo que la regla quiere impedir es que un dato **construya** el
         * comando. Aqui no lo hace: la cadena es **literal y constante**, y los
         * dos datos van como **argumentos posicionales** (`$1`, `$2`). Ademas
         * el id se valida contra `^[0-9]+$` antes de llegar aqui, y el destino
         * lo compone el propio servicio.
         */
        decodeProc.command = ["sh", "-c", 'cliphist decode "$1" > "$2"', "_",
                              id, root.thumbDir + "/" + id + ".img"];
        decodeProc.running = true;
    }

    /** Al cerrar: fuera las miniaturas. No se dejan por ahi. */
    Process { id: sweepProc }

    function sweep() {
        root.queue = [];
        root.made = ({});
        sweepProc.command = ["rm", "-rf", root.thumbDir];
        sweepProc.running = true;
    }

    // ---- pegar --------------------------------------------------------------

    /**
     * Rediseño, fase 5B (futureclipboard §«Feedback»): la superficie sólo se cierra cuando
     * la entrada se RECUPERÓ y se ESCRIBIÓ en el portapapeles. Antes se cerraba al
     * pedirla; en imagen la tubería devolvía el código de `wl-copy` aunque el `decode`
     * hubiera fallado.
     *
     * Desde la 6C es una operación de `ops` (clave "paste"; antes, las señales
     * `pasted` / `pasteFailed`): `paste()` devuelve la revisión y `ops.settled` dice
     * `ok` cuando `wl-copy` salió con 0 (ya tiene la selección) o `error` con el
     * motivo. `pasteRev` es la revisión en vuelo; los procesos resuelven ESA.
     */
    readonly property Ops ops: Ops { name: "clip" }
    property int pasteRev: 0
    readonly property string pastingId: root.pasteRev > 0 ? String(root.ops.get("paste").requested) : ""
    property string decoded: ""

    function _fail(reason) {
        console.warn("Clip.paste failed:", reason);
        const r = root.pasteRev;
        root.pasteRev = 0;
        root.ops.resolve("paste", r, "error", reason);
    }

    function _done() {
        const r = root.pasteRev;
        root.pasteRev = 0;
        root.ops.resolve("paste", r, "ok", "", root.ops.get("paste").requested);
    }

    /** Texto recuperado, a la espera de irse a `wl-copy` por stdin. */
    Process {
        id: textDecode
        stdout: StdioCollector { onStreamFinished: root.decoded = this.text }
        // Primero el código de salida: un `decode` que falla ya no copia un vacío.
        onExited: (code) => {
            if (code !== 0) { root.decoded = ""; root._fail("Could not read the item"); return; }
            copyProc.running = false;
            // El historial ya identificó texto: la autodetección puede anunciarlo
            // como application/* y hacer que los campos de texto rechacen pegarlo.
            copyProc.command = ["wl-copy", "--sensitive", "--type", "text/plain;charset=utf-8"];
            /**
             * REABRIR stdin ANTES DE CADA ARRANQUE. Abajo se cierra poniendo
             * `stdinEnabled = false`, y se queda asi: en el segundo pegado
             * volver a ponerlo a false ya no es un cambio, stdin no se
             * cierra y `wl-copy`, que lee hasta EOF, se queda colgado sin
             * ofrecer nada. Medido el 2026-09-14 con este mismo orden de
             * llamadas sobre `tee`: sin esta linea el 2.o proceso sigue
             * vivo a los 1,3 s; con ella los tres salen con codigo 0.
             */
            copyProc.stdinEnabled = true;
            copyProc.running = true;
            copyProc.write(root.decoded);
            root.decoded = "";
            copyProc.stdinEnabled = false;   // cerrar stdin = fin del contenido
        }
    }

    Process {
        id: copyProc
        stdinEnabled: true
        onExited: (code) => {
            if (root.pasteRev === 0) return;
            if (code !== 0) root._fail("Could not write to the clipboard"); else root._done();
        }
    }

    Process {
        id: imageCopy
        onExited: (code) => {
            if (root.pasteRev === 0) return;
            if (code !== 0) root._fail("Could not copy the image"); else root._done();
        }
    }

    readonly property bool pasting: root.pasteRev > 0 || textDecode.running || copyProc.running || imageCopy.running

    /**
     * Pegar. **El contenido nunca pasa por argv**, que es lo que importa en un
     * portapapeles que puede tener contrasenas: quedaria a la vista en `ps`
     * para cualquier proceso del mismo usuario.
     *
     * Texto: dos procesos y ni un shell -- `cliphist decode` recogido con
     * `StdioCollector`, y de ahi a `wl-copy --sensitive --type text/plain;charset=utf-8` por **stdin**.
     * Imagen: la excepcion acotada de arriba, por la misma razon (binario).
     */
    function has(id) {
        for (let i = 0; i < root.entries.length; i++) if (root.entries[i].id === id) return true;
        return false;
    }

    function paste(id, isImage) {
        if (!/^[0-9]+$/.test(id)) { console.warn("Clip.paste: bad id"); return 0; }
        /**
         * Y ademas tiene que existir. Sin esto, un id que ya no esta en el
         * historial hace que `cliphist decode` no devuelva nada y `wl-copy`
         * copie ese vacio: **el portapapeles se queda en blanco** por un id
         * caducado. Medido el 2026-09-09 con un id inventado.
         */
        if (root.entries.length > 0 && !root.has(id)) {
            console.warn("Clip.paste: no entry", id);
            if (root.pasting) return 0;
            root.pasteRev = root.ops.request("paste", id);
            const r = root.pasteRev;
            root._fail("Item no longer available");
            return r;   // ya resuelta: quien llama mira `ops.get("paste")`
        }
        /**
         * Uno cada vez. Un segundo pegado con el primero en vuelo reasignaba
         * `textDecode` y `copyProc` a mitad -- dificil tecleando, facil por IPC
         * (`clipPaste` dos veces seguidas). Se rechaza en vez de encolar: el
         * pegado dura milisegundos. Es seguro atarlo a `running`: medido que
         * pasa a false al salir el hijo directo, aunque el `wl-copy` que se
         * queda sirviendo el portapapeles herede los pipes.
         */
        if (root.pasting) {
            console.warn("Clip.paste: busy");
            return 0;
        }
        root.pasteRev = root.ops.request("paste", id);
        if (isImage) {
            // pipefail: que falle el `decode` cuenta, no sólo el `wl-copy` del final.
            imageCopy.command = ["bash", "-c", 'set -o pipefail; cliphist decode "$1" | wl-copy', "_", id];
            imageCopy.running = true;
            return root.pasteRev;
        }
        textDecode.running = false;
        textDecode.command = ["cliphist", "decode", id];
        textDecode.running = true;
        return root.pasteRev;
    }

    // ---- resumen para el IPC ------------------------------------------------

    function summary() {
        return {
            wanted: root.wanted, watchers: Object.keys(root.claims).length,
            claims: Object.keys(root.claims),   // QS-FUNC-003
            watching: root.watching, watchRestarts: root.watchRestarts,   // QS-FUNC-013
            pasting: root.pasting, ops: root.ops.snapshot(),
            loading: root.loading, count: root.count, images: root.imageCount,
            thumbsMade: Object.keys(root.made).length,
            queued: root.queue.length,
            error: root.lastError,
            whyNot: root.whyNot, notice: root.notice      // F2d
        };
    }
}
