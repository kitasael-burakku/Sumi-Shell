pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.Notifications
import Quickshell.Hyprland

/**
 * El shell como servidor de notificaciones (ADR-29; Fase 1 de
 * docs/FASE9/NOTIFICACIONES.md): el servidor, los popups y sus tiempos.
 *
 * APAGADO POR DEFECTO y LEIDO SOLO AL ARRANCAR (`Settings.notificationServer`).
 * Lo que ordena este archivo, medido con sonda `qs -p` en un bus privado
 * (2026-09-15):
 *
 *   · `org.freedesktop.Notifications` tiene UN dueño. Con otro servidor vivo,
 *     Quickshell avisa («Could not register … presumably because one is already
 *     registered») y SE QUEDA EN COLA: toma el nombre ~0,5 s despues de que el
 *     otro lo suelte. Encender esto con SwayNC vivo no es inocuo: el dia que
 *     SwayNC se reinicie, el shell se queda con el nombre.
 *   · Destruir el `NotificationServer` (LazyLoader inactivo) NO suelta el
 *     nombre: el proceso sigue siendo el dueño, y lo que llegue se acepta y se
 *     cierra al instante (razon 2). Apagarlo en caliente seria perder avisos en
 *     silencio; por eso `enabled` es una foto del arranque y cambiar el ajuste
 *     pide reiniciar el shell (`restartPending`).
 *   · Sin `tracked = true` dentro de la señal, Quickshell la descarta.
 *   · Quickshell NO expira nada (`expireTimeout` en ms: -1 = por defecto,
 *     0 = nunca) ni entiende los hints `synchronous`: las dos cosas son de aqui.
 *   · `replaces_id` actualiza el MISMO objeto (cambian `summary`/`body`) y no
 *     vuelve a emitir `notification`.
 *   · `invoke()`, `dismiss()` y `sendInlineReply()` cierran la notificacion
 *     DENTRO de la llamada, y tras `invoke()` ya no esta en el modelo cuando
 *     llega `closed`. Por eso el popup se retira escuchando al MODELO
 *     (`objectRemoved`), y siempre diferido con `Qt.callLater`: quien llama
 *     suele ser la propia tarjeta que se va a destruir.
 *   · Tras una recarga en caliente, las conservadas se vuelven a emitir con
 *     `lastGeneration`: se rastrean, pero no sacan popup.
 *   · Una ruta de archivo en `image-path` llega envuelta como
 *     `image://icon//usr/...`; `imageOf()` la desenvuelve.
 *
 * Datos ajenos (SECURITY reglas 3 y 6): resumen, cuerpo, iconos y acciones los
 * escribe otra aplicacion. Nunca van a un shell; un enlace solo abre si es
 * http(s) o mailto; una imagen solo de archivo local o del proveedor interno de
 * Quickshell (nada de red, ADR-7).
 *
 * El centro, su historial persistente, el No molestar y las no leidas viven en
 * `services/NotifHistory.qml` (Fase 2): esto le avisa de cada alta, reemplazo y
 * salida. Un popup que caduca se va de la pantalla, no del centro.
 */
Singleton {
    id: root

    /** Foto de `Settings.notificationServer` al arrancar (ver arriba por que). */
    property bool enabled: false
    /** El ajuste en disco ya no coincide con lo que corre: hace falta reiniciar. */
    readonly property bool restartPending: Settings.notificationServer !== root.enabled

    readonly property var server: loader.item
    /** Rastreadas, la mas vieja primero. */
    readonly property var tracked: root.server ? root.server.trackedNotifications.values : []
    /** Lo que hay en el centro (vivas y restauradas; las `transient` no entran, como en SwayNC). */
    readonly property int count: NotifHistory.count

    /** «Reply» en un popup: el centro se abre con esa entrada y el campo enfocado (lo abre shell.qml). */
    signal replyRequested(string key)

    /**
     * Popups en pantalla, el mas nuevo en el indice 0. `ListModel` y no un array
     * de JS: reasignar un array reconstruye todos los delegados (y sus
     * temporizadores) cada vez que llega uno.
     */
    property ListModel popups: ListModel {}

    readonly property int maxPopups: 4

    /**
     * Fase 7B (spec de Notifications, «Pantalla completa»): con una app a pantalla
     * completa en el monitor enfocado —donde salen los popups— no salen los
     * normales ni los de prioridad baja; los críticos sí. Todo entra al centro como
     * siempre, y al salir de pantalla completa NO se reproduce lo suprimido. No toca
     * el No molestar. Misma lectura que `core/Hypr.hasFullscreen`, sin importar core/.
     */
    readonly property bool fullscreenFocused: {
        const m = Hyprland.focusedMonitor;
        const ws = m ? m.activeWorkspace : null;
        return ws ? ws.hasFullscreen === true : false;
    }
    onFullscreenFocusedChanged: if (root.fullscreenFocused) root.dropSuppressedPopups()
    /** 9C-2: Settings → Shell → Notifications (antes 4000 / 5000 fijos; los defaults siguen igual). */
    readonly property int timeoutNormal: Settings.notifPopupSec * 1000
    readonly property int timeoutLow: (Settings.notifPopupSec + 1) * 1000

    /** La foto se toma una vez y con el JSON ya cargado (`Settings.loaded`). */
    property bool snapped: false
    function snapshot() {
        if (root.snapped || !Settings.loaded)
            return;
        // El orden importaba mientras existio `services/Swaync.qml`, que
        // arrancaba su cliente con `snapped && !enabled` (Fase 3); retirado en
        // la Fase 4, `snapped` solo guarda que la foto se toma una vez.
        root.enabled = Settings.notificationServer;
        root.snapped = true;
        if (root.enabled)
            console.info("notifs: notification server enabled (ADR-29)");
    }
    Component.onCompleted: root.snapshot()
    Connections {
        target: Settings
        function onLoadedChanged() { root.snapshot(); }
    }

    LazyLoader {
        id: loader
        active: root.enabled

        NotificationServer {
            keepOnReload: true
            persistenceSupported: true
            bodySupported: true
            bodyMarkupSupported: true
            bodyHyperlinksSupported: true
            bodyImagesSupported: false
            actionsSupported: true
            actionIconsSupported: false
            imageSupported: true
            inlineReplySupported: true    // se responde desde el centro (los popups no piden teclado)

            onNotification: (n) => root.receive(n)
        }
    }

    /**
     * Un delegado por rastreada. Escucha los cambios de `replaces_id` y, sobre
     * todo, su salida del modelo, que es la unica señal que llega en todos los
     * cierres (tambien tras `invoke()`). Al recargar en caliente se rehace solo
     * sobre las que siguen vivas (`keepOnReload`), sin conexiones colgando del
     * motor anterior.
     */
    Instantiator {
        model: root.server ? root.server.trackedNotifications : null

        delegate: Connections {
            required property var modelData
            property int nid: -1
            target: modelData
            Component.onCompleted: nid = modelData ? modelData.id : -1
            function onSummaryChanged() { root.bumpLater(modelData); }
            function onBodyChanged() { root.bumpLater(modelData); }
        }

        onObjectRemoved: (index, object) => {
            const id = object ? object.nid : -1;
            Qt.callLater(function () {
                root.removePopup(id);
                NotifHistory.removeLive(id);
            });
        }
    }

    // --- Entrada ---------------------------------------------------------------

    function receive(n) {
        n.tracked = true;   // sin esto Quickshell la descarta (medido)
        // Tras una recarga en caliente, Quickshell VUELVE A EMITIR las que conserva
        // (`keepOnReload`), con `lastGeneration`. Medido: sin esta guarda, cada
        // archivo guardado resucitaba en pantalla popups que ya habian caducado.
        if (n.lastGeneration) {
            NotifHistory.relink(n);   // vuelve a ser viva en el centro, sin popup
            return;
        }
        const key = root.syncKey(n);
        if (key.length > 0) {
            // Reemplazo por hint (lo usaba kb-layout-notify.py, retirado el 2026-09-24): la anterior de la misma
            // app con la misma clave se descarta. Diferido: fuera de la señal.
            const stale = root.tracked.filter(function (o) {
                return o && o !== n && o.appName === n.appName && root.syncKey(o) === key;
            });
            if (stale.length > 0)
                Qt.callLater(function () {
                    for (let i = 0; i < stale.length; i++)
                        if (root.tracked.indexOf(stale[i]) >= 0)
                            stale[i].dismiss();
                });
        }
        NotifHistory.addLive(n);
        if (root.suppressed(n)) {
            // Sin popup, una transient no tendría quien la hiciera caducar. Antes se
            // cerraba ya; desde la 7B vive lo que habría vivido su popup, para que el
            // centro la alcance por teclado mientras tanto (razón 1 al caducar).
            if (n.transient)
                root.expireLater(n);
            return;
        }
        root.showPopup(n);
    }

    /** No molestar como SwayNC (medido): las criticas salen igual; todo entra al centro. */
    function silenced(n) { return NotifHistory.dnd && !root.isCritical(n); }
    /** Sin popup: No molestar o pantalla completa en el monitor enfocado. Las críticas, siempre. */
    function suppressed(n) { return !root.isCritical(n) && (NotifHistory.dnd || root.fullscreenFocused); }

    /** Al entrar en pantalla completa se van los popups que no son críticos (siguen en el centro). */
    function dropSuppressedPopups() {
        for (let i = root.popups.count - 1; i >= 0; i--) {
            const n = root.popups.get(i).notif;
            if (root.isCritical(n))
                continue;
            root.popups.remove(i);
            if (n && n.transient)
                root.expireLater(n);
        }
    }

    /** Caducidad de las transient sin popup: { id: instante }. Un solo reloj, sólo si hay alguna. */
    property var deadlines: ({})
    function expireLater(n) {
        const next = Object.assign({}, root.deadlines);
        next[n.id] = Date.now() + Math.max(1, root.popupTimeout(n) || root.timeoutNormal);
        root.deadlines = next;
    }
    Timer {
        interval: 500
        repeat: true
        running: Object.keys(root.deadlines).length > 0
        onTriggered: {
            const now = Date.now();
            const next = {};
            for (const id in root.deadlines) {
                if (root.deadlines[id] > now) {
                    next[id] = root.deadlines[id];
                    continue;
                }
                const n = root.find(Number(id));
                if (n)
                    n.expire();
            }
            root.deadlines = next;
        }
    }

    function syncKey(n) {
        const h = n && n.hints ? n.hints : {};
        return String(h["x-canonical-private-synchronous"] || h["synchronous"] || h["private-synchronous"] || "");
    }

    // --- Popups ----------------------------------------------------------------

    function indexOfPopup(id) {
        for (let i = 0; i < root.popups.count; i++)
            if (root.popups.get(i).nid === id)
                return i;
        return -1;
    }

    function showPopup(n) {
        const i = root.indexOfPopup(n.id);
        if (i >= 0) {
            root.popups.setProperty(i, "gen", root.popups.get(i).gen + 1);   // reinicia su cuenta atras
            return;
        }
        root.popups.insert(0, { nid: n.id, notif: n, gen: 0 });
        // Tope: fuera la mas vieja que no sea critica (sigue en el centro).
        while (root.popups.count > root.maxPopups) {
            let victim = root.popups.count - 1;
            for (let k = root.popups.count - 1; k >= 0; k--) {
                if (!root.isCritical(root.popups.get(k).notif)) {
                    victim = k;
                    break;
                }
            }
            root.popups.remove(victim);
        }
    }

    function removePopup(id) {
        const i = root.indexOfPopup(id);
        if (i >= 0)
            root.popups.remove(i);
    }

    /** `replaces_id`: `summary` y `body` cambian en la misma vuelta; se junta en un solo aviso. */
    property var pendingBumps: ({})
    function bumpLater(n) {
        if (!n)
            return;
        root.pendingBumps[n.id] = n;
        Qt.callLater(root.flushBumps);
    }
    function flushBumps() {
        const pending = root.pendingBumps;
        root.pendingBumps = {};
        for (const id in pending) {
            const n = pending[id];
            if (root.tracked.indexOf(n) < 0)
                continue;
            NotifHistory.updateLive(n);
            if (!root.suppressed(n))
                root.showPopup(n);
        }
    }

    /** Fin de la cuenta atras. Una `transient` se cierra (razon 1), como en SwayNC; el resto se queda en el centro. */
    function expirePopup(id) {
        const n = root.find(id);
        root.removePopup(id);
        if (n && n.transient)
            n.expire();
    }

    /** ms de vida del popup; 0 = hasta que se descarte (NOTIFICACIONES §7). */
    function popupTimeout(n) {
        if (!n || root.isCritical(n))
            return 0;
        if (n.expireTimeout > 0)
            return Math.round(n.expireTimeout);
        return n.urgency === NotificationUrgency.Low ? root.timeoutLow : root.timeoutNormal;
    }

    function isCritical(n) { return !!n && n.urgency === NotificationUrgency.Critical; }

    // --- Acciones ----------------------------------------------------------------

    function find(id) {
        const l = root.tracked;
        for (let i = 0; i < l.length; i++)
            if (l[i] && l[i].id === id)
                return l[i];
        return null;
    }

    /** Botones: todo menos `default` (es el clic en el cuerpo) e `inline-reply` (es «Reply», que abre el centro). */
    function actionsOf(n) {
        if (!n)
            return [];
        // `actions` es una lista de QObject: se recorre por indice, sin fiarse de los metodos de Array.
        const out = [];
        for (let i = 0; i < n.actions.length; i++) {
            const a = n.actions[i];
            if (a && a.identifier !== "default" && a.identifier !== "inline-reply")
                out.push(a);
        }
        return out;
    }

    function invokeAction(n, identifier) {
        if (!n)
            return false;
        for (let i = 0; i < n.actions.length; i++) {
            if (n.actions[i].identifier === identifier) {
                n.actions[i].invoke();   // cierra la notificacion dentro de la llamada
                return true;
            }
        }
        return false;
    }

    /**
     * Clic en el cuerpo: la accion `default` si la app la ofrece (ella sabe a
     * donde llevar); si no, la ventana de la app al frente y el popup fuera. La
     * notificacion se queda en el centro.
     */
    function activate(n) {
        if (!n)
            return false;
        if (root.invokeAction(n, "default"))
            return true;
        root.focusApp(n);
        root.removePopup(n.id);
        return true;
    }

    function dismiss(n) {
        if (!n)
            return false;
        n.dismiss();
        return true;
    }

    /** «Reply» en un popup: marca la entrada y pide el centro; el popup se va. */
    function requestReply(n) {
        if (!n || !n.hasInlineReply)
            return false;
        const i = NotifHistory.indexOfNid(n.id);
        if (i < 0)
            return false;
        NotifHistory.replyTarget = NotifHistory.entries[i].key;
        root.removePopup(n.id);
        root.replyRequested(NotifHistory.replyTarget);
        return true;
    }

    /**
     * ¿Tiene a donde llevar una entrada del centro? Viva con accion `default`, o
     * una ventana abierta de su app. El centro no se cierra si no (NotifHistory).
     */
    function hasTarget(e) {
        if (!e)
            return false;
        const n = NotifHistory.liveOf(e);
        if (n)
            for (let i = 0; i < n.actions.length; i++)
                if (n.actions[i].identifier === "default")
                    return true;
        const token = String(e.desktopEntry || e.app || "");
        const entryId = token.length > 0 ? Toplevels.entryIdOf(token) : "";
        return entryId.length > 0 && Toplevels.windowsFor(entryId).length > 0;
    }

    /** La ventana de la app, por su `.desktop` (`desktop-entry` o el nombre). Sin proceso. */
    function focusApp(n) {
        const token = String(n.desktopEntry || n.appName || "");
        const entryId = token.length > 0 ? Toplevels.entryIdOf(token) : "";
        const ws = entryId.length > 0 ? Toplevels.windowsFor(entryId) : [];
        return ws.length > 0 ? Toplevels.focus(ws[0]) : false;
    }

    /** Un enlace del cuerpo: solo http(s) y mailto (el resto es dato ajeno sin permiso para abrir nada). */
    function openLink(url) {
        const u = String(url || "");
        if (!/^(https?:\/\/|mailto:)/i.test(u)) {
            console.warn("notifs: link refused:", JSON.stringify(u.substring(0, 80)));
            return false;
        }
        Apps.spawn(["xdg-open", u], "xdg-open");   // en su scope (Apps.scoped), no en el del shell
        return true;
    }

    // --- Lo que se pinta ---------------------------------------------------------

    /**
     * El cuerpo para `Text.StyledText`: sin `<img>` (body-images no se anuncia y
     * cargaria rutas ajenas) y con `<a>` solo si el destino es http(s)/mailto;
     * cualquier otro enlace queda como su texto.
     */
    function bodyText(n) {
        if (!n)
            return "";
        let b = String(n.body || "");
        b = b.replace(/<img\b[^>]*>/gi, "");
        b = b.replace(/<a\b[^>]*?href\s*=\s*(["'])(.*?)\1[^>]*>([\s\S]*?)<\/a>/gi, function (m, q, href, txt) {
            return /^(https?:\/\/|mailto:)/i.test(href) ? '<a href="' + href + '">' + txt + "</a>" : txt;
        });
        return b.replace(/\n/g, "<br>");
    }

    /** Solo lo que se puede cargar sin red: archivo local, icono del tema o el proveedor de Quickshell. */
    function localImage(src) {
        const s = String(src || "");
        if (s.startsWith("/"))
            return "file://" + s;
        if (s.startsWith("file://") || s.startsWith("image://"))
            return s;
        return "";
    }

    /**
     * Fase 7A del rediseño: la IMAGEN y el ICONO DE LA APP son dos cosas. La
     * imagen (`image-data`, `image-path`) va en miniatura dentro del cuerpo; el
     * icono identifica a la app en la cabecera. Antes eran una sola (`iconOf`).
     *
     * `imageOf(n)`: la miniatura, o "" si no hay. Un `image-path` con NOMBRE de
     * icono del tema (`image://icon/<nombre>`) no es una imagen: cuenta como icono.
     * Un `image://qsimage/…` sólo vale mientras viva el objeto de Quickshell.
     */
    function imageOf(n) {
        if (!n)
            return "";
        const img = String(n.image || "");
        if (img.startsWith("image://icon/")) {
            const name = img.substring(13);
            return (name.startsWith("/") || name.startsWith("file://")) ? root.localImage(name) : "";   // ruta mal envuelta (medido)
        }
        return root.localImage(img);
    }

    /**
     * El icono de la app: `app_icon`, la `desktop-entry` o, como último recurso,
     * el nombre de icono que vino en `image-path`. Sirve para una notificación
     * viva y para una entrada del historial (`app` en vez de `appName`).
     * "" = la tarjeta pinta su glifo.
     */
    function appIconOf(n) {
        if (!n)
            return "";
        const names = [n.appIcon, n.desktopEntry];
        for (let i = 0; i < names.length; i++) {
            const c = String(names[i] || "");
            if (c.length === 0)
                continue;
            if (c.startsWith("/") || c.startsWith("file://"))
                return root.localImage(c);
            const s = Apps.iconSource(c, "");
            if (s.length > 0)
                return s;
        }
        const token = String(n.desktopEntry || n.appName || n.app || "");
        if (token.length > 0) {
            void DesktopEntries.applications.values.length;   // reevaluar cuando lleguen (~1 s)
            const e = DesktopEntries.heuristicLookup(token);
            if (e) {
                const s = Apps.iconSource(e.icon, "");
                if (s.length > 0)
                    return s;
            }
        }
        const img = String(n.image || "");
        if (img.startsWith("image://icon/") && !img.substring(13).startsWith("/"))
            return Apps.iconSource(img.substring(13), "");
        return "";
    }

    // --- IPC y status (core/Ipc.qml y la sonda notif-probe.qml) ------------------

    function summary() {
        return { enabled: root.enabled, restartPending: root.restartPending,
                 running: root.server !== null, count: root.count, unread: NotifHistory.unread,
                 dnd: NotifHistory.dnd, tracked: root.tracked.length, popups: root.popups.count,
                 fullscreen: root.fullscreenFocused, transientsPending: Object.keys(root.deadlines).length,
                 history: NotifHistory.summary() };
    }

    function listJson() {
        return JSON.stringify(root.tracked.map(function (n) {
            return { id: n.id, app: n.appName, summary: n.summary, urgency: n.urgency,
                     transient: n.transient, popup: root.indexOfPopup(n.id) >= 0,
                     // lo que se pinta, ya saneado: para comprobarlo sin mirar la pantalla
                     shownBody: root.bodyText(n), appIcon: root.appIconOf(n), image: root.imageOf(n),
                     actions: Array.prototype.map.call(n.actions, function (a) { return a.identifier; }) };
        }));
    }

    function actionById(id, identifier) { return root.invokeAction(root.find(id), identifier); }
    function activateById(id) { return root.activate(root.find(id)); }
    function dismissById(id) { return root.dismiss(root.find(id)); }
    function replyById(id, text) {
        const i = NotifHistory.indexOfNid(id);
        return i >= 0 ? NotifHistory.reply(NotifHistory.entries[i].key, text) : false;
    }
}
