pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

/**
 * Session power actions (Fase 9.h).
 *
 * Reemplaza los **tres** caminos que habia -- wlogout en SUPER+ESCAPE,
 * `rofi/scripts/power.sh` en ALT+ESCAPE y el modulo `custom/power` de Waybar --
 * por uno solo. Es la unica excepcion a ADR-18: aqui si se retira una red de
 * seguridad, decidido por el usuario con la advertencia delante (ADR-21).
 *
 * BLOQUEAR ANTES DE SUSPENDER ya no se hace aqui (QS-FUNC-021, 2026-09-14).
 * Del 2026-09-09 al 14 el shell copiaba `wlogout/scripts/suspend.sh` (pedir el
 * lock y sondear `pgrep -x hyprlock` hasta 30 veces), con la duplicacion
 * anotada. El usuario pidio cambiarlo por un inhibidor `delay`, y ese
 * inhibidor **ya existe en el rice**: lo tiene hypridle. Ver `suspend()`.
 *
 * LO QUE NO SE TOCA: `lock` sigue siendo `loginctl lock-session` a traves de
 * `services/Session`, nunca PAM propio ni `hyprlock` a mano. Esa cadena
 * (logind -> hypridle -> hyprlock) es la de la Fase 3 y es **mejor** que la del
 * original, que lanzaba `hyprlock` directo saltandosela.
 */
Singleton {
    id: root

    /** Lo que logind dice que se puede hacer, no lo que suponemos. */
    property string canSuspend: ""
    property string canHibernate: ""
    property bool probed: false

    readonly property bool suspendOk: root.canSuspend === "yes"
    readonly property bool hibernateOk: root.canHibernate === "yes"

    /**
     * `na` es "esta maquina no puede", distinto de `inhibited` ("puede, pero
     * algo lo bloquea ahora"). Merece la pena separarlos: el primero no se
     * arregla y el segundo si.
     */
    readonly property bool hibernateNa: root.canHibernate === "na"
    readonly property bool suspendInhibited: root.canSuspend === "inhibited"

    /**
     * Y si esta inhibido, lo normal es que sea **el propio shell**: el
     * keep-awake pone un inhibidor `block` sobre `sleep:idle`. Ni wlogout ni
     * `power.sh` avisaban de esto -- ofrecian "Suspend" y no pasaba nada.
     */
    readonly property bool selfInhibited: root.suspendInhibited && Session.keepAwakeEffective

    readonly property string suspendNote: {
        if (root.suspendOk) return "";
        if (root.selfInhibited) return "keep awake is on";
        if (root.suspendInhibited) return "inhibited by another program";
        if (root.canSuspend === "na") return "not available";
        return root.canSuspend;
    }

    readonly property string hibernateNote: {
        if (root.hibernateOk) return "";
        if (root.hibernateNa) return "needs disk swap";
        if (root.canHibernate === "inhibited") return "inhibited";
        return root.canHibernate;
    }

    Process {
        id: probe
        command: ["busctl", "--system", "--json=short", "call",
                  "org.freedesktop.login1", "/org/freedesktop/login1",
                  "org.freedesktop.login1.Manager", "CanSuspend"]
        stdout: StdioCollector {
            onStreamFinished: { root.canSuspend = root.readWord(this.text); hibProbe.running = true; }
        }
    }

    Process {
        id: hibProbe
        command: ["busctl", "--system", "--json=short", "call",
                  "org.freedesktop.login1", "/org/freedesktop/login1",
                  "org.freedesktop.login1.Manager", "CanHibernate"]
        stdout: StdioCollector {
            onStreamFinished: { root.canHibernate = root.readWord(this.text); root.probed = true; }
        }
    }

    /** `busctl --json=short` devuelve {"type":"s","data":["yes"]}. */
    function readWord(text) {
        try {
            const j = JSON.parse(text);
            if (j && j.data && j.data.length > 0) return String(j.data[0]);
        } catch (e) {}
        const m = /"([a-z]+)"/.exec(text || "");
        return m ? m[1] : "";
    }

    /** Se consulta al abrir la superficie: el estado cambia (keep-awake, otros programas). */
    function probeCapabilities() { probe.running = true; inhProbe.running = true; }

    // ---- acciones -----------------------------------------------------------

    /**
     * LO PEDIDO Y LO QUE SE VIO (fase 6C). Cada orden es una petición con
     * revisión en `ops`, y su estado sale de lo observado, no de que `systemctl`
     * volviera:
     *   clave "run"   reboot, shutdown, suspend, hibernate (y todas en simulación).
     *                 Código ≠ 0 → error con el stderr. Código 0 → `unknown`
     *                 «accepted»: logind aceptó la orden, pero que la máquina se
     *                 apague o duerma no se ve desde un shell que va a morir.
     *   clave "lock"  ok cuando `Lock` dice que la sesión está bloqueada; a los
     *                 5 s sin verlo, `unknown`.
     *   logout        se despacha a Hyprland y la sesión termina: `unknown`.
     * Un resultado que llega para una revisión vieja se descarta (`ops.stale`).
     */
    readonly property Ops ops: Ops { name: "power" }

    /**
     * `action` falló (R12 de docs/lock/SEGURIDAD.md): un inhibidor `block`, u
     * otro rechazo de logind. `message` es el `stderr` de `systemctl`, para que
     * el lock lo enseñe sin adivinar por qué. Desde la 6C se DERIVA de `ops`
     * (el lock, herencia de ADR-30, la sigue escuchando tal cual).
     */
    signal actionFailed(string action, string message)

    Connections {
        target: root.ops
        function onSettled(key, rev, state, reason) {
            if (state === "error")
                root.actionFailed(String(root.ops.get(key).requested), reason);
        }
    }

    /** Hay una orden en marcha: la superficie no deja lanzar otra encima. */
    readonly property bool busy: runner.running || root.ops.pending("run")

    /**
     * SIMULACIÓN, sólo para previews (rediseño, P-06). Con `SUMI_POWER_DRYRUN=ok`
     * las seis acciones «salen bien» y con `fail` las rechaza un proceso que
     * escribe «Access denied» y sale con 1. **Ninguna llega al sistema**: ni
     * `systemctl`, ni `loginctl lock-session`, ni el `exit` de Hyprland. La sesión no
     * tiene esta variable en su entorno; sin ella todo es como siempre.
     */
    readonly property string dryRun: Quickshell.env("SUMI_POWER_DRYRUN") || ""
    readonly property bool simulated: root.dryRun === "ok" || root.dryRun === "fail"

    function simulate(action) {
        console.log("power: SIMULATED " + action + " (" + root.dryRun + ")");
        // Medio segundo, como una orden real: así se puede probar que no se duplica.
        return root.run(action, root.dryRun === "fail"
            ? ["sh", "-c", "sleep 0.5; echo 'Access denied' >&2; exit 1"]
            : ["sleep", "0.5"]);
    }

    /** Lanza la orden `action`. Una a la vez: con otra en vuelo, se rechaza. */
    function run(action, argv) {
        if (root.busy) { console.warn("power: busy, refused", action); return false; }
        runner.rev = root.ops.request("run", action);
        runner.command = argv;
        runner.running = true;
        return true;
    }

    /** Systemd keeps its existing CLI path; elogind uses the shared login1 API. */
    function actionCommand(action) {
        if (Session.powerBackend === "systemd") {
            const unit = ({ reboot: "reboot", shutdown: "poweroff", suspend: "suspend", hibernate: "hibernate" })[action];
            return unit ? ["systemctl", unit] : [];
        }
        if (Session.powerBackend === "login1") {
            const method = ({ reboot: "Reboot", shutdown: "PowerOff", suspend: "Suspend", hibernate: "Hibernate" })[action];
            return method ? ["busctl", "--system", "call", "org.freedesktop.login1", "/org/freedesktop/login1",
                             "org.freedesktop.login1.Manager", method, "b", "true"] : [];
        }
        return [];
    }

    function runAction(action) {
        if (root.busy) return false;
        const argv = root.actionCommand(action);
        if (!argv.length) {
            const rev = root.ops.request("run", action);
            root.ops.resolve("run", rev, "error", "No verified power backend");
            Capabilities.refresh("power action");
            return false;
        }
        return root.run(action, argv);
    }

    Process {
        id: runner
        property int rev: 0
        stderr: StdioCollector { id: runnerErr }
        onExited: (code) => {
            if (code !== 0)
                root.ops.resolve("run", runner.rev, "error", runnerErr.text.trim());
            else
                root.ops.resolve("run", runner.rev, "unknown", "accepted");
        }
    }

    /** El bloqueo sí se puede ver: lo dice `Lock`. */
    Timer {
        id: lockDeadline
        interval: 5000
        onTriggered: root.ops.resolve("lock", root.ops.latest("lock"), "unknown", "Lock requested; not confirmed")
    }
    Connections {
        target: Lock
        function onPhaseChanged() {
            if (Lock.phase !== "unlocked" && root.ops.pending("lock")) {
                lockDeadline.stop();
                root.ops.resolve("lock", root.ops.latest("lock"), "ok", "", Lock.phase);
            }
        }
    }

    /**
     * Todo por **argv**, y los comandos estan **cableados aqui**: no se
     * construyen a partir de nada que venga de fuera. Es la misma idea que la
     * whitelist de `confirm-then.sh`, pero sin necesidad de whitelist porque no
     * hay cadena que filtrar.
     */
    function lock() {
        if (root.simulated) return root.simulate("lock");
        root.ops.request("lock", "lock");
        lockDeadline.restart();
        Session.lock();
        return true;
    }

    function logout() {
        if (root.simulated) return root.simulate("logout");
        const r = root.ops.request("logout", "logout");
        HyprCtl.dispatch("exit", {});   // F5a: `hl.dsp.exit()` con Lua, `exit` con hyprland.conf
        root.ops.resolve("logout", r, "unknown", "accepted");
        return true;
    }

    function reboot() {
        if (root.simulated) return root.simulate("reboot");
        return root.runAction("reboot");
    }

    function shutdown() {
        if (root.simulated) return root.simulate("shutdown");
        return root.runAction("shutdown");
    }

    function hibernate() {
        if (!root.hibernateOk) return false;
        if (root.simulated) return root.simulate("hibernate");
        return root.runAction("hibernate");
    }

    // ---- suspender: logind espera, el shell no adivina -----------------------

    /**
     * QS-FUNC-021. Antes: `Session.lock()` y sondear `pgrep -x hyprlock` cada
     * 100 ms con techo de 3 s -- 30 procesos en el camino mas delicado, y
     * adivinando: que el PROCESO hyprlock exista no es que la sesion este
     * bloqueada.
     *
     * Ahora lo garantiza logind, con el inhibidor que ya pone hypridle 0.1.8:
     *   · `hypridle.conf` tiene `before_sleep_cmd = loginctl lock-session`;
     *   · su `inhibit_sleep` automatico pasa a 3 porque `lock_cmd` nombra a
     *     hyprlock: guarda un inhibidor `sleep` en modo `delay` y lo SUELTA
     *     solo cuando hyprlock confirma el bloqueo por `hyprland_lock_notifier`.
     * Medido el 2026-09-14 en el journal, en un bloqueo real por inactividad:
     *   hyprlock  «onLockLocked called»
     *   hypridle  «Wayland session got locked» -> «Releasing the sleep inhibitor!»
     * Techo: `InhibitDelayMaxUSec` = 5 s. Con un hyprlock colgado la maquina se
     * suspende igual a los 5 s (antes, a los 3 s): no se queda sin dormir.
     *
     * Por eso `suspend()` es solo `systemctl suspend`. Sin hypridle no habria
     * bloqueo previo -- pero tampoco lo habia antes: `loginctl lock-session` lo
     * atiende hypridle, y el shell no lanza hyprlock a mano (Fase 3). Lo que si
     * se hace es DECIRLO: `lockBeforeSleep` mira la lista de inhibidores al
     * abrir la superficie.
     */
    function suspend() {
        if (root.simulated) return root.simulate("suspend");
        // F5d (P6.1): con la sesión ya bloqueada, o si un demonio de bloqueo retiene la suspensión (hypridle con su
        // inhibidor delay: bloqueará él antes), lo de siempre. Si nadie la retiene, la shell bloquea antes. Se vuelve a
        // mirar la lista de inhibidores ahora: `lockBeforeSleep` sólo se leía al abrir la superficie de energía.
        if (Lock.phase !== "unlocked") {
            if (Session.powerBackend === "login1" && !Lock.secure) {
                const rev = root.ops.request("run", "suspend");
                root.ops.resolve("run", rev, "error", "The lock is not secure");
                return false;
            }
            return root.runAction("suspend");
        }
        if (root.busy || root.sleepStage !== "") { console.warn("power: busy, refused suspend"); return false; }
        root.sleepStage = "probe";
        sleepDeadline.restart();
        inhProbe.running = true;
        return true;
    }

    /** F5d: «» · probe (mirando inhibidores) · locking (bloqueando antes de suspender). */
    property string sleepStage: ""
    /** Si no pudo bloquear antes de suspender (y suspendió igual): el motivo; si no, "". */
    property string sleepLockNote: ""

    function afterProbe() {
        if (root.sleepStage !== "probe") return;
        if (root.lockBeforeSleep) { root.goSleep(""); return; }
        root.sleepStage = "locking";
        sleepDeadline.restart();
        if (!Lock.request("instant")) { root.goSleep("The session could not be locked before suspending"); return; }
        if (Lock.secure) root.goSleep("");
    }

    function goSleep(note) {
        sleepDeadline.stop();
        root.sleepStage = "";
        root.sleepLockNote = note;
        if (note && Session.powerBackend === "login1") {
            const rev = root.ops.request("run", "suspend");
            root.ops.resolve("run", rev, "error", note);
            return;
        }
        if (note) console.warn("power: " + note + "; suspending anyway");
        root.runAction("suspend");
    }

    Connections {
        target: Lock
        function onSecureChanged() { if (root.sleepStage === "locking" && Lock.secure) root.goSleep(""); }
    }
    Timer {
        id: sleepDeadline
        interval: 2000
        onTriggered: {
            if (root.sleepStage === "probe") { root.sleepStage = "locking"; root.afterProbeFallback(); }
            else if (root.sleepStage === "locking") root.goSleep(Lock.secure ? "" : "The lock did not secure the session in 2 s");
        }
    }
    /** La lista de inhibidores no contestó a tiempo: tratar como «nadie la retiene» (bloquear es lo prudente). */
    function afterProbeFallback() {
        sleepDeadline.restart();
        if (!Lock.request("instant")) { root.goSleep("The session could not be locked before suspending"); return; }
        if (Lock.secure) root.goSleep("");
    }

    /** hypridle tiene su inhibidor `sleep`/`delay`: suspender bloqueara primero. */
    property bool lockBeforeSleep: false
    property bool inhibitorsProbed: false

    Process {
        id: inhProbe
        command: ["busctl", "--system", "--json=short", "call",
                  "org.freedesktop.login1", "/org/freedesktop/login1",
                  "org.freedesktop.login1.Manager", "ListInhibitors"]
        stdout: StdioCollector {
            // {"type":"a(ssssuu)","data":[[[what, who, why, mode, uid, pid], ...]]}
            onStreamFinished: {
                let found = false;
                try {
                    const rows = JSON.parse(this.text).data[0];
                    for (let i = 0; i < rows.length; i++) {
                        const r = rows[i];
                        // F5d: cualquier demonio de bloqueo con su inhibidor delay (antes, sólo hypridle)
                        if (["hypridle", "swayidle", "xss-lock"].indexOf(r[1]) >= 0 && r[3] === "delay"
                                && String(r[0]).split(":").indexOf("sleep") >= 0)
                            found = true;
                    }
                } catch (e) {
                    console.warn("power: ListInhibitors unreadable");
                }
                root.lockBeforeSleep = found;
                root.inhibitorsProbed = true;
                root.afterProbe();
            }
        }
    }

    // ---- resumen para el IPC ------------------------------------------------

    function summary() {
        return {
            probed: root.probed,
            canSuspend: root.canSuspend, canHibernate: root.canHibernate,
            suspendOk: root.suspendOk, hibernateOk: root.hibernateOk,
            suspendNote: root.suspendNote, hibernateNote: root.hibernateNote,
            selfInhibited: root.selfInhibited,
            lockBeforeSleep: root.lockBeforeSleep, inhibitorsProbed: root.inhibitorsProbed,
            sleepStage: root.sleepStage, sleepLockNote: root.sleepLockNote,
            busy: root.busy, simulated: root.simulated,
            backend: Session.powerBackend,
            ops: root.ops.snapshot()
        };
    }
}
