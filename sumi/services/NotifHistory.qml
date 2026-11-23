pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * El centro de notificaciones y su historial (ADR-29; Fase 2 de
 * docs/FASE9/NOTIFICACIONES.md). Unico escritor de
 *
 *     $XDG_STATE_HOME/sumi-shell/notifications.json
 *
 * Decisiones del usuario (NOTIFICACIONES §7 y §12):
 *   · CENTRO = HISTORIAL. Lo que se ve es lo que se guarda: descartar o
 *     «Clear all» lo borra tambien del archivo. Sobrevive a reiniciar el shell.
 *   · Purga: 100 entradas y 7 dias. Las `transient` no entran.
 *   · No molestar como SwayNC (medido: las criticas siguen saliendo, el resto
 *     no, todas entran al centro) y PERSISTENTE.
 *   · Aviso del island = no leidas: llegadas despues de la ultima vez que se
 *     abrio el centro (`lastSeen`). [7B: leido POR ENTRADA, ver abajo.]
 *   · Grupos por app plegados; las criticas, sueltas y arriba.
 *
 * Entradas vivas y restauradas. Una entrada es VIVA mientras su notificacion
 * sigue rastreada por el servidor: tiene acciones y respuesta. Tras reiniciar
 * el shell vuelve RESTAURADA: se ve y se descarta, pero sin botones, porque la
 * app que la envio ya no escucha ese id. Al recargar en caliente el servidor
 * vuelve a emitir las conservadas (`lastGeneration`) y `relink()` las devuelve a
 * vivas por el id que tenian (`prevNid`, solo si el `pid` es el mismo).
 *
 * LO QUE SE CARGA DEL DISCO NUNCA ES VIVO (`nid` -1). Medido en la Fase 3 con
 * SIGSEGV: el gestor de caidas de Quickshell reinicia el shell EN EL MISMO PID y
 * el servidor nuevo numera desde 1. Cuando se reenlazaba por «mismo pid + mismo
 * id», las notificaciones nuevas con id 3-6 SOBRESCRIBIERON a las cuatro de antes
 * de la caida (44 de 48). Ahora el id viejo solo lo mira `relink()`, que solo
 * llega con `lastGeneration`; una notificacion nueva solo coincide con una viva.
 *
 * PRIVACIDAD (ADR-29): el archivo guarda el texto de los mensajes. Medido que
 * `FileView` crea en 0644 pero CONSERVA el modo de un archivo existente al
 * escribir; por eso se crea vacio en 0600 (`install`, argv) al arrancar con el
 * servidor encendido. Queda fuera de `dotbackup` (solo copia ~/.config).
 *
 * Todo lo que guarda es dato ajeno: se recorta al guardar (resumen 512, cuerpo
 * 4096 caracteres) y se sanea al pintar (`Notifs.bodyText`), nunca aqui.
 *
 * Rediseño, fase 7A:
 *   · Archivo v2: el icono de la app (`appIcon`, `desktopEntry`) y la imagen
 *     (`image`, sólo una ruta local) van por separado. El v1 guardaba un único
 *     `icon` que podía ser cualquiera de los dos; al leerlo se migra: una ruta
 *     fuera de los directorios de iconos pasa a `image`, el resto se descarta
 *     (el icono de la app se vuelve a resolver desde `appIcon`).
 *   · Grupos: cada app con más de una entrada enseña la más nueva y una fila
 *     «more» (Show more / Show less, total y pendientes). Lo que el centro está
 *     leyendo o respondiendo (`hold`) no se pliega aunque llegue otra más nueva.
 *
 * Rediseño, fase 7B:
 *   · LEÍDO POR ENTRADA (`read`), no una marca única. Lo marca el centro, y sólo
 *     con la tarjeta a la vista un rato en el centro FIJADO (`markRead`); una
 *     vista previa por hover, un grupo plegado o una tarjeta fuera del viewport
 *     no marcan. Las entradas del archivo sin `read` lo toman de la marca vieja
 *     `lastSeen` (que ya no se mueve y se guarda sólo para leer archivos viejos).
 *   · CLEAR ALL SOBRE UN CONJUNTO: el centro captura las claves que enseña al
 *     pedir la confirmación y `clearSet(claves)` borra sólo esas; lo llegado
 *     después se queda. `clearAll()` sigue para el IPC de scripts.
 *   · TRANSITORIOS VIVOS: filas `transient` al principio (no se guardan) para
 *     llegar por teclado a los avisos `transient` mientras siguen vivos.
 *   · Borrador huérfano (DESIGN §2): si una notificación viva desaparece con un
 *     borrador de respuesta en `Drafts`, la entrada se queda como `gone` (sin
 *     acciones, Send deshabilitado) mientras exista el borrador. No se guarda en
 *     disco: el borrador tampoco sobrevive a un reinicio.
 */
Singleton {
    id: root

    readonly property string path: Settings.stateDir + "/notifications.json"
    readonly property int maxEntries: 100
    readonly property real maxAgeMs: 7 * 24 * 3600 * 1000

    /** La mas nueva primero. Objetos planos; la verdad de lo que hay en el centro. */
    property var entries: []
    property bool dnd: false
    /**
     * Quién puso el No molestar como está (7E-1; spec del Centro de control): "mode"
     * (lo cambió `desktop-mode.sh` por el IPC `notifDnd`), "manual" (un interruptor
     * del shell) o "" (no se sabe: archivos anteriores). Con esto la fila del Centro
     * de control dice si lo activó el modo o se tocó a mano.
     */
    property string dndSource: ""
    /** Marca vieja (hasta la 7A): sólo para dar `read` a entradas de archivos que no lo traen. */
    property real lastSeen: 0
    /** «Clear all» pedido desde fuera del centro (clic central en el island): el centro lo confirma al abrirse. */
    property bool clearWanted: false
    /** Sube con cada cambio: los delegados se reevaluan leyendolo. */
    property int revision: 0

    readonly property int count: root.entries.length
    readonly property int unread: {
        void root.revision;
        let u = 0;
        for (let i = 0; i < root.entries.length; i++)
            if (root.isUnread(root.entries[i]))
                u++;
        return u;
    }

    /** Grupos desplegados (no se guarda). */
    property var expanded: ({})
    /**
     * Claves de entrada que el centro tiene entre manos (seleccionada, con el campo
     * de respuesta): siguen a la vista aunque su grupo esté plegado y llegue otra.
     */
    property var hold: []
    /** Sube al final de cada `rebuild()`: quien busque una fila por clave lo relee. */
    property int rowsRev: 0
    /** Entrada a la que se quiere responder: el centro la busca al abrirse. */
    property string replyTarget: ""
    /**
     * Entrada que el centro tiene que LOCALIZAR al abrirse (7E-2: la vista previa del
     * Centro de control): la selecciona, la deja a la vista aunque su grupo esté
     * plegado y no ejecuta nada. Leerla sigue la regla de permanencia del centro.
     */
    property string locateTarget: ""

    /** La no leída más reciente (la vista previa del Centro de control), o null. */
    readonly property var latestUnread: {
        void root.revision;
        for (let i = 0; i < root.entries.length; i++)
            if (root.isUnread(root.entries[i])) return root.entries[i];
        return null;
    }

    /**
     * Filas del centro, en un `ListModel` reconciliado por clave: un array de
     * JS reasignado devolveria la lista arriba en cada notificacion (lo pagado
     * en QS-FUNC-007 y -013).
     *   { rkey, kind: "entry" | "more", key, depth }
     * `more` es el pie de un grupo (su `key` es la del grupo, `app:<nombre>`).
     */
    property ListModel rows: ListModel {}

    // --- Carga -------------------------------------------------------------------

    property bool loaded: false
    property bool fileExists: false
    property bool dirty: false

    /**
     * Lo que llega del servidor ANTES de leer el archivo. Medido el 2026-09-25: al
     * recargar en caliente, el servidor reemite las conservadas (`relink`) antes
     * de que `load()` corra, y la carga las pisaba — ninguna volvía viva, y un
     * aviso nuevo en esa ventana se perdía del historial. Se guarda y se reproduce
     * en orden al terminar de cargar (`replay`).
     */
    property var pending: []
    function defer(op, arg) {
        if (root.loaded)
            return false;
        root.pending.push({ op: op, arg: arg });
        return true;
    }
    function replay() {
        const list = root.pending;
        root.pending = [];
        for (let i = 0; i < list.length; i++) {
            const p = list[i];
            if (p.op === "relink") root.relink(p.arg);
            else if (p.op === "add") root.addLive(p.arg);
            else if (p.op === "remove") root.removeLive(p.arg);
        }
    }

    FileView {
        id: file
        path: root.path
        blockLoading: true
        // Escrituras sincronas: el volcado de `onDestruction` (systemctl restart)
        // tiene que acabar antes de que el proceso salga. Son pocos KB.
        blockWrites: true
        printErrors: false
        // Sin watchChanges: el shell es el unico escritor, y releer su propia
        // escritura compite con el texto en cache (lo mismo que launcher-usage).
        onLoaded: {
            root.fileExists = true;
            root.load(file.text());
        }
        onLoadFailed: function (error) {
            root.fileExists = error !== FileViewError.FileNotFound;
            if (root.fileExists)
                console.warn("notifs: history unreadable, starting empty");
            root.loaded = true;
            root.rebuild();
            root.replay();
            root.ensureFile();
        }
    }

    function load(text) {
        let o = null;
        if (String(text || "").trim().length > 0) {   // recien creado en 0600: vacio, no roto
            try {
                o = JSON.parse(text);
            } catch (e) {
                console.warn("notifs: history is not valid JSON, starting empty");
            }
        }
        const out = [];
        if (o && Array.isArray(o.entries)) {
            const v1 = o.version !== 2;
            const seen = typeof o.lastSeen === "number" ? o.lastSeen : 0;
            for (let i = 0; i < o.entries.length; i++) {
                const e = root.clean(o.entries[i], v1, seen);
                if (e)
                    out.push(e);
            }
            root.dnd = o.dnd === true;
            root.dndSource = (o.dndSource === "mode" || o.dndSource === "manual") ? o.dndSource : "";
            root.lastSeen = typeof o.lastSeen === "number" ? o.lastSeen : 0;
        }
        out.sort(function (a, b) { return b.time - a.time; });
        root.entries = out;
        root.loaded = true;
        if (root.purge())
            root.save();
        root.rebuild();
        root.replay();
    }

    /** Valida una entrada leida del disco; `null` si no sirve. */
    function clean(x, v1, seen) {
        if (!x || typeof x !== "object" || typeof x.key !== "string" || typeof x.time !== "number")
            return null;
        const image = v1 === true ? root.migratedImage(x.icon, x.appIcon) : root.localPath(x.image);
        return {
            key: x.key.substring(0, 64),
            nid: -1,
            // El id que tenia, para `relink()` tras una recarga en caliente del mismo
            // proceso. NO sirve para `addLive`: tras una caida el mismo pid reusa ids.
            prevNid: (x.pid === Quickshell.processId && typeof x.nid === "number" && x.nid >= 0) ? x.nid : -1,
            pid: typeof x.pid === "number" ? x.pid : 0,
            app: String(x.app || "").substring(0, 128),
            appIcon: String(x.appIcon || "").substring(0, 512),
            desktopEntry: String(x.desktopEntry || "").substring(0, 128),
            image: image,
            summary: String(x.summary || "").substring(0, 512),
            body: String(x.body || "").substring(0, 4096),
            urgency: (x.urgency === 0 || x.urgency === 2) ? x.urgency : 1,
            time: x.time,
            read: typeof x.read === "boolean" ? x.read : x.time <= (seen || 0)
        };
    }

    /** Sólo una ruta local (`file://…` o absoluta) se guarda como imagen; lo demás, "". */
    function localPath(v) {
        const s = String(v || "");
        if (s.startsWith("/"))
            return ("file://" + s).substring(0, 1024);
        return s.startsWith("file://") ? s.substring(0, 1024) : "";
    }

    /**
     * El `icon` del v1 era la imagen de la notificación O el icono de la app ya
     * resuelto. Es lo segundo si coincide con `appIcon` (kitty manda su logo como
     * ruta en `app_icon`, medido el 2026-09-25) o vive en un directorio de iconos:
     * se vuelve a resolver desde `appIcon`. Cualquier otra ruta local es la imagen
     * (las capturas de Hyprshot).
     */
    function migratedImage(icon, appIcon) {
        const p = root.localPath(icon);
        if (p.length === 0 || p === root.localPath(appIcon))
            return "";
        return /\/(icons|pixmaps)\//.test(p) ? "" : p;
    }

    // --- Escritura (un escritor, inmediata con tope) --------------------------------

    /**
     * Se escribe EN CADA CAMBIO (`minGapMs` 0; si algun dia hiciera falta, >0
     * agrupa las escrituras). Medido el 2026-09-15:
     *   · Quickshell muere con SIGTERM/SIGINT/SIGHUP SIN destruir el QML
     *     (`onDestruction` no corre): una espera de 500 ms perdia lo pendiente en
     *     cada `systemctl restart` — un SIGTERM a 100 ms de llegar la perdia.
     *   · Con un tope de 300 ms, una rafaga de 5 + SIGTERM guardaba 1 de 5.
     *   · Sin tope, con el archivo lleno (100 entradas, 420 KB) y 50
     *     notificaciones en 0,37 s: 13 ticks del proceso EN TOTAL (popups y filas
     *     incluidos) y 50 de 50 en disco tras SIGTERM.
     */
    readonly property int minGapMs: 0
    property real lastWrite: 0

    function save() {
        root.dirty = true;
        const wait = root.lastWrite + root.minGapMs - Date.now();
        if (wait <= 0) {
            saveTimer.stop();
            root.flush();
        } else if (!saveTimer.running) {
            saveTimer.interval = Math.max(1, Math.round(wait));
            saveTimer.start();
        }
    }

    Timer {
        id: saveTimer
        onTriggered: root.flush()
    }

    /**
     * Crear el archivo en 0600 en cuanto el servidor esta encendido, no en la
     * primera escritura: `install` es un proceso, y un `systemctl restart` justo
     * despues de la primera notificacion lo mataria antes de que existiera
     * (medido: con la creacion perezosa, un SIGTERM a 100 ms la perdia). Con el
     * servidor apagado no se crea nada.
     */
    function ensureFile() {
        if (!root.fileExists && root.loaded && Notifs.enabled && !creator.running)
            creator.running = true;
    }
    Connections {
        target: Notifs
        function onEnabledChanged() { root.ensureFile(); }
        // Un transitorio que llega o se va cambia las filas aunque el historial no.
        function onTrackedChanged() { if (root.loaded) root.rebuild(); }
    }

    function flush() {
        if (!root.dirty || !root.loaded)
            return;
        if (!root.fileExists) {
            // Crear en 0600 ANTES de escribir: FileView conserva el modo existente.
            if (!creator.running)
                creator.running = true;
            return;
        }
        root.dirty = false;
        root.lastWrite = Date.now();
        // Las `gone` (borrador huérfano) no se guardan: el borrador no sobrevive a un reinicio.
        const out = root.entries.filter(function (e) { return e.gone !== true; }).map(function (e) {
            return { key: e.key, nid: e.nid, pid: Quickshell.processId, app: e.app, appIcon: e.appIcon,
                     desktopEntry: e.desktopEntry, image: e.image, summary: e.summary, body: e.body,
                     urgency: e.urgency, time: e.time, read: e.read === true };
        });
        file.setText(JSON.stringify({ version: 2, dnd: root.dnd, dndSource: root.dndSource, lastSeen: root.lastSeen, entries: out }));
    }

    /**
     * Solo cubre la recarga en caliente (que si destruye el QML). Un
     * `systemctl restart` NO pasa por aqui: por eso `save()` escribe al momento.
     */
    Component.onDestruction: if (root.dirty) root.flush()

    Process {
        id: creator
        command: ["install", "-D", "-m", "600", "/dev/null", root.path]
        onExited: (code) => {
            if (code !== 0) {
                console.warn("notifs: could not create", root.path, "exit", code);
                return;
            }
            root.fileExists = true;
            root.flush();
        }
    }

    // --- Entrada desde el servidor (services/Notifs.qml) --------------------------

    function indexOfNid(nid) {
        for (let i = 0; i < root.entries.length; i++)
            if (root.entries[i].nid === nid)
                return i;
        return -1;
    }

    function indexOfKey(key) {
        for (let i = 0; i < root.entries.length; i++)
            if (root.entries[i].key === key)
                return i;
        return -1;
    }

    function fromLive(n, key, time) {
        const image = Notifs.imageOf(n);
        return {
            key: key, nid: n.id, prevNid: -1, pid: Quickshell.processId,
            app: String(n.appName || "").substring(0, 128),
            // Sin `app_icon`, el nombre de icono que vino en `image-path` (notify-send -i,
            // el aviso de actualizaciones): guardado aquí sobrevive a un reinicio.
            appIcon: String(n.appIcon || root.themedName(n.image)).substring(0, 512),
            desktopEntry: String(n.desktopEntry || "").substring(0, 128),
            // `image://qsimage/…` (image-data) muere con el proceso: no se guarda.
            image: root.localPath(image),
            summary: String(n.summary || "").substring(0, 512),
            body: String(n.body || "").substring(0, 4096),
            urgency: n.urgency, time: time,
            read: false   // también un reemplazo (`replaces_id`): texto nuevo, sin leer
        };
    }

    function themedName(img) {
        const s = String(img || "");
        return s.startsWith("image://icon/") && !s.substring(13).startsWith("/") ? s.substring(13) : "";
    }

    /** Una notificacion nueva (no transient). */
    function addLive(n) {
        if (!n || n.transient || root.defer("add", n))
            return;
        const i = root.indexOfNid(n.id);
        const now = Date.now();
        const e = root.fromLive(n, i >= 0 ? root.entries[i].key : ("e" + now + "-" + n.id), now);
        const next = root.entries.slice();
        if (i >= 0)
            next.splice(i, 1);
        next.unshift(e);
        root.entries = next;
        root.purge();
        root.changed();
    }

    /** `replaces_id`: mismo objeto, texto nuevo; sube arriba como recien llegada. */
    function updateLive(n) { root.addLive(n); }

    /**
     * Recarga en caliente: la conservada vuelve a ser viva. Se busca por el id que
     * tenia al guardarse (`prevNid`) y la misma app, nunca por `nid`.
     */
    function relink(n) {
        if (!n || n.transient || root.defer("relink", n))
            return;
        if (root.indexOfNid(n.id) >= 0)
            return;   // ya enlazada
        for (let i = 0; i < root.entries.length; i++) {
            const e = root.entries[i];
            if (e.nid < 0 && e.prevNid === n.id && e.app === String(n.appName || "").substring(0, 128)) {
                const next = root.entries.slice();
                next[i] = Object.assign({}, e, { nid: n.id, prevNid: -1, pid: Quickshell.processId });
                root.entries = next;
                root.changed();
                return;
            }
        }
        root.addLive(n);   // no estaba guardada (llego justo antes de la recarga)
    }

    /**
     * Salio del modelo del servidor (descartada, accion, respuesta, la app la cerro).
     * Con un borrador de respuesta pendiente, la entrada se queda como `gone`: el
     * texto sigue recuperable y el envío, deshabilitado (DESIGN §2). Descartar
     * desde el centro borra antes el borrador (`dismiss`), así que eso sí la quita.
     */
    function removeLive(nid) {
        if (root.defer("remove", nid))
            return;
        const i = root.indexOfNid(nid);
        if (i < 0)
            return;
        const e = root.entries[i];
        const next = root.entries.slice();
        if (Drafts.has(root.draftKeyOf(e.key)))
            next[i] = Object.assign({}, e, { nid: -1, prevNid: -1, gone: true });
        else
            next.splice(i, 1);
        root.entries = next;
        root.changed();
    }

    function draftKeyOf(key) { return "notif-reply:" + key; }

    /** Al tirar el borrador de una `gone`, la entrada ya no tiene nada que enseñar. */
    Connections {
        target: Drafts
        function onDraftsChanged() {
            const keep = root.entries.filter(function (e) {
                return e.gone !== true || Drafts.has(root.draftKeyOf(e.key));
            });
            if (keep.length !== root.entries.length) {
                root.entries = keep;
                root.changed(false);
            }
        }
    }

    function changed(persist) {
        root.revision++;
        root.rebuild();
        if (persist !== false)
            root.save();
    }

    /** Purga por antiguedad y por numero. Las vivas se descartan por el servidor. */
    function purge() {
        const now = Date.now();
        const keep = [];
        const drop = [];
        for (let i = 0; i < root.entries.length; i++) {
            const e = root.entries[i];
            if (now - e.time > root.maxAgeMs || keep.length >= root.maxEntries)
                drop.push(e);
            else
                keep.push(e);
        }
        if (drop.length === 0)
            return false;
        root.entries = keep;
        const live = drop.map(function (e) { return root.liveOf(e); }).filter(function (n) { return n !== null; });
        if (live.length > 0)
            Qt.callLater(function () { for (let i = 0; i < live.length; i++) live[i].dismiss(); });
        return true;
    }

    // --- Consultas para el centro ---------------------------------------------------

    function entry(key) {
        const i = root.indexOfKey(key);
        return i >= 0 ? root.entries[i] : null;
    }

    /** La notificacion viva de una entrada, o null (restaurada o ya cerrada). */
    function liveOf(e) {
        if (!e || e.nid < 0 || e.pid !== Quickshell.processId)
            return null;
        return Notifs.find(e.nid);
    }

    function isLive(key) { return root.liveOf(root.entry(key)) !== null; }

    /** Clave de grupo: las criticas van solas; el resto, por app. */
    function groupKeyOf(e) {
        return e.urgency === 2 ? ("crit:" + e.key) : ("app:" + (e.app.length > 0 ? e.app : e.desktopEntry).toLowerCase());
    }

    function groupEntries(gkey) {
        void root.revision;
        return root.entries.filter(function (e) { return root.groupKeyOf(e) === gkey; });
    }

    /** Pendiente de leer (7B: por entrada). Una `gone` ya no es un aviso que leer. */
    function isUnread(e) { return !!e && e.gone !== true && e.read !== true; }

    function unreadIn(gkey) {
        const list = root.groupEntries(gkey);
        let u = 0;
        for (let i = 0; i < list.length; i++)
            if (root.isUnread(list[i]))
                u++;
        return u;
    }

    function setHold(keys) {
        const next = (keys || []).filter(function (k) { return typeof k === "string" && k.length > 0; });
        if (JSON.stringify(next) === JSON.stringify(root.hold))
            return;
        root.hold = next;
        root.rebuild();
    }

    /**
     * Filas deseadas, en orden: criticas (nuevas primero), luego grupos por su mas
     * nueva. Un grupo de varias: su mas nueva, las demas si esta desplegado (o las
     * que el centro retiene), y el pie `more`.
     */
    function desiredRows() {
        // Los transitorios vivos, arriba y sin guardar: el acceso por teclado a lo que
        // no entra en el historial (spec: «separado del historial persistido»).
        const trans = [];
        const tr = Notifs.tracked;
        for (let i = tr.length - 1; i >= 0; i--)
            if (tr[i] && tr[i].transient)
                trans.push({ rkey: "t:" + tr[i].id, kind: "transient", key: String(tr[i].id), depth: 0 });
        const crit = [];
        const groups = {};
        const order = [];
        for (let i = 0; i < root.entries.length; i++) {
            const e = root.entries[i];
            const g = root.groupKeyOf(e);
            if (e.urgency === 2) {
                crit.push({ rkey: "e:" + e.key, kind: "entry", key: e.key, depth: 0 });
                continue;
            }
            if (!groups[g]) {
                groups[g] = [];
                order.push(g);
            }
            groups[g].push(e);
        }
        const out = trans.concat(crit);
        for (let i = 0; i < order.length; i++) {
            const g = order[i];
            const list = groups[g];
            out.push({ rkey: "e:" + list[0].key, kind: "entry", key: list[0].key, depth: 0 });
            if (list.length === 1)
                continue;
            const open = root.expanded[g] === true;
            for (let k = 1; k < list.length; k++)
                if (open || root.hold.indexOf(list[k].key) >= 0)
                    out.push({ rkey: "e:" + list[k].key, kind: "entry", key: list[k].key, depth: 1 });
            out.push({ rkey: "m:" + g, kind: "more", key: g, depth: 1 });
        }
        return out;
    }

    /**
     * Lleva `rows` a lo deseado con insert/move/remove: los delegados de las
     * filas que no cambian se quedan (y la lista no salta).
     */
    function rebuild() {
        const want = root.desiredRows();
        for (let i = 0; i < want.length; i++) {
            const w = want[i];
            if (i < root.rows.count && root.rows.get(i).rkey === w.rkey) {
                if (root.rows.get(i).depth !== w.depth)
                    root.rows.setProperty(i, "depth", w.depth);
                continue;
            }
            let j = -1;
            for (let k = i + 1; k < root.rows.count; k++)
                if (root.rows.get(k).rkey === w.rkey) { j = k; break; }
            if (j >= 0) {
                root.rows.move(j, i, 1);
                if (root.rows.get(i).depth !== w.depth)
                    root.rows.setProperty(i, "depth", w.depth);
            } else {
                root.rows.insert(i, w);
            }
        }
        while (root.rows.count > want.length)
            root.rows.remove(root.rows.count - 1);
        root.rowsRev++;
    }

    // --- Acciones del centro ----------------------------------------------------------

    function setExpanded(gkey, on) {
        const x = Object.assign({}, root.expanded);
        if (on) x[gkey] = true; else delete x[gkey];
        root.expanded = x;
        root.rebuild();
    }

    function dismiss(key) {
        const e = root.entry(key);
        if (!e)
            return false;
        Drafts.discard(root.draftKeyOf(key));   // descartar es decidir: el borrador se va con ella
        const n = root.liveOf(e);
        if (n) {
            n.dismiss();   // vuelve por Notifs → removeLive
            return true;
        }
        const next = root.entries.slice();
        next.splice(root.indexOfKey(key), 1);
        root.entries = next;
        root.changed();
        return true;
    }

    function dismissGroup(gkey) {
        const list = root.groupEntries(gkey);
        for (let i = 0; i < list.length; i++)
            root.dismiss(list[i].key);
        return list.length > 0;
    }

    /**
     * Borra las entradas de `keys` que SIGAN existiendo (DESIGN §7): lo llegado
     * después de capturar el conjunto no está en él y se queda. Devuelve cuántas.
     */
    function clearSet(keys) {
        const want = {};
        for (let i = 0; i < (keys || []).length; i++)
            want[keys[i]] = true;
        const live = [];
        const keep = [];
        let n = 0;
        for (let i = 0; i < root.entries.length; i++) {
            const e = root.entries[i];
            if (want[e.key] !== true) {
                keep.push(e);
                continue;
            }
            n++;
            Drafts.discard(root.draftKeyOf(e.key));
            const l = root.liveOf(e);
            if (l) { live.push(l); keep.push(e); }
        }
        // Las restauradas se van ya; las vivas, por el servidor (una señal por cada una).
        root.entries = keep;
        root.changed();
        for (let i = 0; i < live.length; i++)
            live[i].dismiss();
        return n;
    }

    /** Todo lo que hay ahora. Sólo el IPC de scripts: la interfaz confirma y usa `clearSet`. */
    function clearAll() {
        return root.clearSet(root.entries.map(function (e) { return e.key; })) > 0;
    }

    function keys() { return root.entries.map(function (e) { return e.key; }); }

    /** Clic o ⏎: la viva por `Notifs.activate`; la restaurada solo lleva a la ventana de la app. */
    function activate(key) {
        const e = root.entry(key);
        if (!e)
            return false;
        const n = root.liveOf(e);
        if (n)
            return Notifs.activate(n);
        return Notifs.focusApp({ desktopEntry: e.desktopEntry, appName: e.app });
    }

    function reply(key, text) {
        const n = root.liveOf(root.entry(key));
        const t = String(text || "");
        if (!n || !n.hasInlineReply || t.length === 0)
            return false;
        n.sendInlineReply(t);   // cierra la notificacion: vuelve por removeLive
        return true;
    }

    /** `source`: "mode" (el IPC del script de modos) o "manual" (interfaz, por defecto). */
    function setDnd(on, source) {
        const src = source === "mode" ? "mode" : "manual";
        if (root.dnd === (on === true) && root.dndSource === src)
            return root.dnd;
        root.dnd = on === true;
        root.dndSource = src;
        root.revision++;
        root.save();
        return root.dnd;
    }
    // Restaurar incluye el origen vacío de los historiales anteriores.
    function restoreDnd(on, source) {
        root.dnd = on === true;
        root.dndSource = ["mode", "manual", ""].indexOf(source) >= 0 ? source : "";
        root.revision++;
        root.save();
    }
    function toggleDnd() { return root.setDnd(!root.dnd, "manual"); }

    /** Leída: la tarjeta estuvo a la vista el tiempo de permanencia en el centro fijado. */
    function markRead(key) {
        const i = root.indexOfKey(key);
        if (i < 0 || root.entries[i].read === true)
            return false;
        const next = root.entries.slice();
        next[i] = Object.assign({}, next[i], { read: true });
        root.entries = next;
        root.changed();
        return true;
    }

    function summary() {
        return { loaded: root.loaded, count: root.count, unread: root.unread, dnd: root.dnd,
                 rows: root.rows.count, expanded: Object.keys(root.expanded) };
    }

    function rowsJson() {
        const out = [];
        for (let i = 0; i < root.rows.count; i++) {
            const r = root.rows.get(i);
            const e = r.kind === "entry" ? root.entry(r.key) : null;
            out.push({ kind: r.kind, key: r.key, depth: r.depth,
                       read: e ? e.read === true : undefined,
                       live: e ? root.liveOf(e) !== null : undefined,
                       gone: e ? e.gone === true : undefined,
                       image: e ? e.image : undefined,
                       summary: e ? e.summary : undefined,
                       n: r.kind === "more" ? root.groupEntries(r.key).length : undefined,
                       unread: r.kind === "more" ? root.unreadIn(r.key) : undefined });
        }
        return JSON.stringify(out);
    }
}
