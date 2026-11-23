pragma Singleton
import QtQuick
import Quickshell

/**
 * La fachada del lock (docs/lock/ESTADO.md §8). Para `core/Screen`,
 * `core/NotifLayer` y el IPC, que no deben conocer `lock/`
 * (ARQUITECTURA §4, regla 2).
 *
 * Sin estado propio: refleja la `LockSession` registrada. Como los singletons
 * se recrean en cada recarga, `session` empieza `null` en cada generación y
 * `LockSession` se re-registra al completarse (mismo patrón que
 * `core/Screens`).
 */
Singleton {
    id: root

    property var session: null

    function register(s) { root.session = s; }
    function unregister(s) { if (root.session === s) root.session = null; }

    readonly property string phase: root.session ? root.session.phase : "unlocked"
    readonly property bool engaged: root.phase !== "unlocked"
    readonly property bool secure: root.session ? root.session.secure : false
    /** Sólo hora y fecha (la calma, `LockCalm`). */
    readonly property bool calm: root.session ? root.session.calm : false

    /** `session` o `instant`; devuelve si queda sostenida (SERVICIOS §4, `lockNow`). */
    function request(reason) {
        if (!root.session) {
            console.warn("lock: no LockSession registered, cannot", reason);
            return false;
        }
        return root.session.engage(reason);
    }

    /** Para `status()` y `lockStatus`. Nada del texto tecleado (I-8). */
    function summary() {
        if (!root.session) {
            return { phase: "unlocked", secure: false, since: 0, reason: "",
                     failed: 0, calm: false, focusScreen: "",
                     layoutCode: "", layoutCount: 1, capsLock: false, numLock: false };
        }
        return root.session.summary();
    }

    /** `denied` · `unavailable`. `shell.qml` la convierte en aviso del island al desbloquear. */
    signal failed(string reason)
}
