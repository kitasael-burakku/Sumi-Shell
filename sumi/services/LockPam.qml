pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam

/**
 * La pila PAM del Lock (portabilidad F5e, 2026-10-10; H-26, HC-53/54).
 *
 * `Settings.lockPamService` = `auto` (= `login`, la de siempre: la misma a la que llega hyprlock) o el nombre de un servicio.
 * `scripts/pam_stack.py` dice dónde está y si cuenta intentos con pam_faillock (y con qué argumentos). Reglas (P6):
 *   · una pila que se sabe AUSENTE no se usa: la shell no bloquea con ella (no podría desbloquear); el helper cae a
 *     hyprlock. Sin Python o sin respuesta, se sigue como antes (sólo una ausencia comprobada cambia algo, regla de F2);
 *   · una pila nueva SÓLO se guarda tras autenticar con ella en una prueba sin bloqueo (`test`); `other` nunca (esquema);
 *   · LockAuth la fija al empezar cada bloqueo (`reset`): no cambia con la sesión bloqueada.
 *
 * La prueba usa su propio PamContext (no el del Lock). Una contraseña equivocada cuenta para faillock como cualquier otra.
 * Lo tecleado no se guarda: se responde y se borra en el mismo paso (I-8, como en LockAuth). `Quickshell.Services.Pam` ya
 * era obligatorio (lock/LockAuth): no añade un módulo nuevo (H-02).
 */
Singleton {
    id: root

    readonly property string setting: Settings.lockPamService
    readonly property string service: root.setting === "auto" || root.setting.length === 0 ? "login" : root.setting
    /** El informe de pam_stack.py para `service` (null hasta que contesta). */
    property var info: null
    property bool checked: false
    readonly property bool missing: root.checked && !!root.info && root.info.exists === false
    readonly property string dir: root.info && root.info.exists ? root.info.dir : "/etc/pam.d"
    /** pam_faillock: null = no se sabe (se avisa como antes); true/false = comprobado. */
    readonly property var faillock: root.checked && root.info && root.info.exists ? root.info.faillock.present === true : null
    readonly property var faillockArgs: root.info && root.info.faillock ? root.info.faillock.args : ({})
    property var candidates: []

    // ── la prueba de una pila nueva ─────────────────────────────────────────────────────────────────────────────
    property string pending: ""
    /** idle · probing · checking · ok · failed · error · missing */
    property string testState: "idle"
    property string testMessage: ""
    property string testService: ""
    property string testDir: "/etc/pam.d"
    property string secret: ""
    property bool respondedOnce: false

    function label() {
        return root.service + (root.setting === "auto" ? " (Auto)" : "");
    }
    function faillockText() {
        if (root.missing) return "Missing: " + (root.info.error || root.service) + " · the shell won't lock with it (hyprlock will)";
        if (root.faillock === null) return "Lockout warnings as before (stack not checked)";
        if (!root.faillock) return "No pam_faillock in this stack: no lockout warnings";
        const a = root.faillockArgs || {};
        return "pam_faillock counts failed attempts" + (Object.keys(a).length ? " (" + Object.keys(a).map(k => k + "=" + a[k]).join(", ") + ")" : "");
    }

    function refresh() {
        stackProbe.target = root.service;
        stackProbe.command = ["python3", Quickshell.shellPath("scripts/pam_stack.py"), root.service];
        stackProbe.running = true;
        listProbe.running = true;
    }
    onServiceChanged: root.refresh()
    Component.onCompleted: root.refresh()

    /** Elegir una candidata para probar (no guarda nada). */
    function choose(name) {
        root.pending = name === root.setting ? "" : name;
        root.testState = "idle";
        root.testMessage = "";
    }

    /** Probar `pending` con `password` sin bloquear; si autentica, se guarda. Devuelve si empezó. */
    function test(password) {
        if (root.pending.length === 0 || root.testState === "probing" || root.testState === "checking") return false;
        if (Lock.phase !== "unlocked") return false;
        root.secret = password;
        root.testService = root.pending === "auto" ? "login" : root.pending;
        root.testState = "probing";
        root.testMessage = "";
        testStack.command = ["python3", Quickshell.shellPath("scripts/pam_stack.py"), root.testService];
        testStack.running = true;
        return true;
    }
    function endTest(state, message) {
        root.secret = "";
        root.respondedOnce = false;
        root.testState = state;
        root.testMessage = message;
        if (state === "ok") {
            Settings.lockPamService = root.pending;
            root.pending = "";
        }
    }

    function summary() {
        return { setting: root.setting, service: root.service, dir: root.dir, checked: root.checked, missing: root.missing,
                 faillock: root.faillock, faillockArgs: root.faillockArgs, candidates: root.candidates,
                 pending: root.pending, test: { state: root.testState, message: root.testMessage, service: root.testService } };
    }

    Process {
        id: stackProbe
        property string target: ""
        stdout: StdioCollector { id: stackOut }
        onExited: (code) => {
            if (stackProbe.target !== root.service) return;          // llegó tarde: ya se pidió otra
            try { root.info = JSON.parse(stackOut.text); root.checked = true; }
            catch (e) { root.info = null; root.checked = false; console.warn("lock: pam_stack.py unreadable"); }
        }
    }
    Process {
        id: listProbe
        command: ["python3", Quickshell.shellPath("scripts/pam_stack.py"), "--list"]
        stdout: StdioCollector { id: listOut }
        onExited: { try { root.candidates = JSON.parse(listOut.text).candidates || []; } catch (e) { root.candidates = []; } }
    }
    Process {
        id: testStack
        property bool begun: false
        onStarted: begun = true
        // sin python3: `running` cae sin `started` ni `exited` (memoria del proyecto)
        onRunningChanged: {
            if (running) return;
            if (!begun && root.testState === "probing") root.endTest("error", "Python is needed to check the PAM stack · nothing changed");
            begun = false;
        }
        stdout: StdioCollector { id: testStackOut }
        onExited: (code) => {
            let r = null;
            try { r = JSON.parse(testStackOut.text); } catch (e) {}
            if (r && r.exists === false) { root.endTest("missing", r.error || "That PAM service doesn't exist"); return; }
            root.testDir = r && r.dir ? r.dir : "/etc/pam.d";
            root.testState = "checking";
            if (!testPam.start()) root.endTest("error", "PAM could not start with " + root.testService);
        }
    }
    PamContext {
        id: testPam
        config: root.testService
        configDirectory: root.testDir
        onPamMessage: {
            if (!testPam.responseRequired) return;
            if (!root.respondedOnce) {
                root.respondedOnce = true;
                const w = root.secret;
                root.secret = "";                                  // fuera de la propiedad antes de salir del proceso
                testPam.respond(w);
            } else {
                testPam.abort();
                root.endTest("error", "This stack asks for more than a password: the lock can't use it");
            }
        }
        onCompleted: (result) => {
            if (result === PamResult.Success) root.endTest("ok", "Authenticated · now using " + root.testService);
            else if (result === PamResult.Failed || result === PamResult.MaxTries)
                root.endTest("failed", "Wrong password (it counts toward the lockout) · nothing changed");
            else root.endTest("error", "PAM error with " + root.testService + " · nothing changed");
        }
        onError: (err) => root.endTest("error", "PAM error with " + root.testService + " · nothing changed")
    }
}
