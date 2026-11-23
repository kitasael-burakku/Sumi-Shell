import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import "../theme"
import "../services"

/**
 * Autenticación (docs/lock/AUTENTICACION.md). Dentro de `LockSession`, que es
 * el único que la instancia (I-6: sólo `LockSession` importa
 * `Quickshell.Services.Pam`).
 *
 * Habla con PAM (pila `login`, la misma que hyprlock) y con faillock, y es el
 * único sitio donde vive el texto tecleado antes de enviarlo (§5): nunca sale
 * a disco, al journal, a `status()` ni a ningún IPC (I-8).
 *
 * Fase 15 (15G-1):
 *   · LK-03: una segunda respuesta (`prompt`) se ENVÍA a la conversación abierta con `respond()`; antes
 *     `submit()` volvía a `start()` y abría otra desde cero.
 *   · LK-04: `deny`, `fail_interval` y `unlock_time` se LEEN de `faillock.conf` (con los valores por defecto
 *     de pam_faillock si no aparecen), y `dir` si la cambia; `unlock_time = 0` es «hasta que lo desbloquee
 *     un administrador»: sin cuenta atrás.
 *   · La conversación (`pam`) se puede sustituir por un adaptador falso con la misma forma, SÓLO en las
 *     sondas (tests/lock/auth-probe.py): así se prueba el segundo prompt sin una pila PAM que lo pida.
 *     `LockSession` nunca lo cambia.
 */
Scope {
    id: root

    /** El único TextInput del lock edita esto (AUTENTICACION §5). */
    property string buffer: ""
    readonly property int bufferLength: root.buffer.length

    /** `state · message · failed · lockoutUntil · prompt · responseVisible` (ESTADO §7). */
    property var auth: ({ state: "idle", message: "", failed: 0, lockoutUntil: 0, prompt: "", responseVisible: false })

    /** La política leída (diagnóstico; LK-04). */
    readonly property var faillockPolicy: ({ deny: faillock.deny, failInterval: faillock.failInterval,
                                            unlockTime: faillock.unlockTime, dir: faillock.tallyDir })
    /**
     * F5e (H-26): la pila de ESTE bloqueo, fijada en `reset()` (al empezar cada bloqueo) desde `LockPam`: un cambio en
     * Settings vale para el siguiente, nunca con la sesión bloqueada. Por defecto, la de siempre.
     */
    property string service: "login"
    property string serviceDir: "/etc/pam.d"
    /** F5e: faillock sólo se consulta y avisa si la pila lo tiene (o si no se sabe: como antes). */
    readonly property bool faillockOn: LockPam.faillock !== false
    /** De dónde se leen los plazos y quién cuenta los fallos. Sólo las sondas los cambian (F5e: o el `conf=` de la pila). */
    property string faillockConf: (LockPam.info && LockPam.info.faillock && LockPam.info.faillock.conf) || "/etc/security/faillock.conf"
    property var faillockCommand: ["faillock", "--user", Quickshell.env("USER")]

    /** Para la sacudida de `LockSurface` (Connections sobre `context`). */
    signal failedAttempt()
    signal bufferCleared()
    /** `LockSession` la escucha para pasar a `leaving`. Nunca al revés (I-2). */
    signal success()

    function setAuth(patch) { root.auth = Object.assign({}, root.auth, patch); }

    // ── el texto tecleado (AUTENTICACION §5) ─────────────────────────────────

    function setBuffer(text) {
        if (root.auth.state === "checking" || root.auth.state === "lockedOut")
            return;
        root.buffer = text;
        bufferTimer.restart();
        // tras un fallo, el mensaje se queda hasta la siguiente pulsación
        if (text.length > 0 && (root.auth.state === "failed" || root.auth.state === "error"))
            root.setAuth({ state: "idle", message: "" });
    }

    function clearBuffer() {
        root.buffer = "";
        bufferTimer.stop();
        root.bufferCleared();
    }

    /** 30 s sin teclear: se pierde lo escrito (AUTENTICACION §5). */
    Timer { id: bufferTimer; interval: Motion.lockBufferMs; onTriggered: root.clearBuffer() }

    // ── el ciclo con PAM (AUTENTICACION §3) ──────────────────────────────────

    property bool respondedOnce: false

    /** La conversación PAM: la real, o (sólo sondas) un adaptador falso con start/respond/abort y sus señales. */
    property var pam: realPam

    function submit() {
        if (root.buffer.length === 0 || root.auth.state === "checking" || root.auth.state === "lockedOut")
            return;
        // LK-03: la segunda respuesta va a la conversación que la pidió, no a una nueva
        if (root.auth.state === "prompt" && root.pam.active) {
            const answer = root.buffer;
            root.clearBuffer();          // I-8: fuera del campo antes de salir del proceso
            root.setAuth({ state: "checking", message: "", prompt: "", responseVisible: false });
            root.pam.respond(answer);
            return;
        }
        root.respondedOnce = false;
        root.setAuth({ state: "checking", message: "" });
        // AUTENTICACION §3: `start()` puede devolver `false` sin disparar ninguna
        // señal (config inexistente, medido en P5) — sin este chequeo, el estado
        // se quedaría en `checking` para siempre y nadie podría volver a intentarlo.
        if (!root.pam.start()) {
            console.warn("lock: PamContext.start() devolvió false");
            root.setAuth({ state: "error", message: "" });
        }
    }

    PamContext {
        id: realPam
        config: root.service
        configDirectory: root.serviceDir
    }

    Connections {
        target: root.pam

        function onPamMessage() {
            const pam = root.pam;
            if (pam.responseRequired) {
                if (!root.respondedOnce) {
                    root.respondedOnce = true;
                    const word = root.buffer;
                    // se borra ANTES de que la respuesta salga del proceso: I-8
                    root.clearBuffer();
                    pam.respond(word);
                } else {
                    // PAM pide una segunda respuesta (R11, LK-03): su texto, sin ':' final; se contesta con
                    // `submit()` sobre ESTA conversación
                    root.setAuth({ state: "prompt", message: "",
                                   prompt: String(pam.message || "").replace(/:\s*$/, ""),
                                   responseVisible: pam.responseVisible === true });
                }
            } else if (pam.messageIsError && String(pam.message || "").length > 0) {
                root.setAuth({ message: pam.message });
            }
        }

        function onCompleted(result) {
            root.respondedOnce = false;
            if (result === PamResult.Success) {
                root.setAuth({ state: "idle", message: "", prompt: "" });
                root.success();
            } else if (result === PamResult.Failed || result === PamResult.MaxTries) {
                root.setAuth({ state: "failed", message: "", prompt: "" });
                root.failedAttempt();
                faillock.refresh();
            } else {
                // Error: sin texto tecleado en el aviso (I-8)
                console.warn("lock: PamContext completed with Error");
                root.setAuth({ state: "error", message: "", prompt: "" });
            }
        }

        function onError(err) {
            root.respondedOnce = false;
            console.warn("lock: PamContext error", err);
            root.setAuth({ state: "error", message: "", prompt: "" });
        }
    }

    /** `abort()` del subproceso PAM si lo hay: llamado por `LockSession.reset()` en cada `engage`. */
    function reset() {
        root.pam.abort();
        root.respondedOnce = false;
        root.buffer = "";
        bufferTimer.stop();
        root.auth = { state: "idle", message: "", failed: 0, lockoutUntil: 0, prompt: "", responseVisible: false };
        // F5e: la pila de este bloqueo (si se supiera ausente, LockSession ni siquiera habría bloqueado)
        if (!LockPam.missing) {
            root.service = LockPam.service;
            root.serviceDir = LockPam.dir;
        }
        faillock.refresh();
    }

    // ── faillock (AUTENTICACION §4) ───────────────────────────────────────────

    Scope {
        id: faillock

        /**
         * LK-04: lo que dice `faillock.conf`; si una clave no aparece, el valor por defecto de pam_faillock
         * (3 / 900 / 600). En esta máquina el archivo está entero comentado (medido 2026-09-29).
         */
        property int deny: 3
        property int failInterval: 900
        property int unlockTime: 600
        property string tallyDir: ""

        function parseConf(text) {
            let deny = 3, interval = 900, unlock = 600, dir = "";
            String(text || "").split("\n").forEach(function (raw) {
                const line = raw.replace(/#.*$/, "").trim();
                let m = /^(deny|fail_interval|unlock_time)\s*=\s*(\d+)$/.exec(line);
                if (m) {
                    const v = parseInt(m[2], 10);
                    if (m[1] === "deny") deny = v;
                    else if (m[1] === "fail_interval") interval = v;
                    else unlock = v;
                    return;
                }
                m = /^dir\s*=\s*(\/\S+)$/.exec(line);
                if (m) dir = m[1];
            });
            // F5e: los argumentos de pam_faillock en la pila mandan sobre faillock.conf (como en el módulo)
            const a = LockPam.faillockArgs || {};
            const num = function (k, d) { const v = parseInt(a[k], 10); return isNaN(v) ? d : v; };
            deny = num("deny", deny); interval = num("fail_interval", interval); unlock = num("unlock_time", unlock);
            if (typeof a.dir === "string" && /^\/\S+$/.test(a.dir)) dir = a.dir;
            faillock.deny = deny > 0 ? deny : 3;
            faillock.failInterval = interval > 0 ? interval : 900;
            faillock.unlockTime = unlock;              // 0 = hasta que lo desbloquee un administrador
            faillock.tallyDir = dir;
        }

        FileView {
            id: conf
            path: root.faillockConf
            blockLoading: true
            printErrors: false
            onLoaded: faillock.parseConf(conf.text())
            onLoadFailed: faillock.parseConf("")
        }

        function refresh() {
            conf.reload();
            if (root.faillockOn) probe.running = true;
            else root.setAuth({ failed: 0 });             // F5e: sin pam_faillock en la pila no hay cuenta que enseñar
        }

        Process {
            id: probe
            command: root.faillockCommand.concat(faillock.tallyDir.length > 0 ? ["--dir", faillock.tallyDir] : [])
            stdout: StdioCollector { id: out }
            onExited: faillock.parse(out.text)
        }

        /**
         * La marca `V` no caduca sola en la salida (trampa medida al preparar S1,
         * INVESTIGACION §9): se cuentan las líneas `V` dentro de `failInterval`,
         * no la columna.
         */
        function parse(text) {
            const lines = String(text || "").split("\n");
            const nowSec = Date.now() / 1000;
            const recent = [];
            for (let i = 0; i < lines.length; i++) {
                const m = /^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+\S+\s+\S+\s+.*\sV\s*$/.exec(lines[i]);
                if (!m)
                    continue;
                const t = new Date(m[1].replace(" ", "T")).getTime() / 1000;
                if (!isNaN(t) && nowSec - t < faillock.failInterval)
                    recent.push(t);
            }
            if (recent.length >= faillock.deny) {
                const last = Math.max.apply(null, recent);
                // unlock_time = 0: no caduca sola → sin plazo que enseñar (-1)
                root.setAuth({ state: "lockedOut", failed: recent.length,
                               lockoutUntil: faillock.unlockTime > 0 ? last + faillock.unlockTime : -1 });
            } else {
                root.setAuth({ failed: recent.length });
            }
        }
    }

    /** La cuenta atrás de `lockedOut` vuelve a `idle` sola cuando expira (AUTENTICACION §4). */
    Timer {
        interval: 1000
        repeat: true
        running: root.auth.state === "lockedOut" && (root.auth.lockoutUntil || 0) > 0
        onTriggered: {
            if (Date.now() / 1000 >= (root.auth.lockoutUntil || 0))
                root.setAuth({ state: "idle", message: "" });
        }
    }
}
