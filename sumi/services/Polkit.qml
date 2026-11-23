pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Services.Polkit

/**
 * Agente de autenticacion de polkit dentro del shell (QS-FUNC-017, Fase D).
 *
 * El dialogo de root lo pinta hoy `polkit-kde-authentication-agent-1`
 * (`polkit-agent.service`): Qt/KDE en un rice de Hyprland, sin la paleta ni la
 * tipografia. Esto lo sustituye por la superficie `auth`.
 *
 * APAGADO POR DEFECTO (`Settings.polkitAgent`), y es por lo que se midio:
 *   · polkit admite UN agente por sesion. Con el de KDE registrado, el del shell
 *     recibe «An authentication agent already exists for the given subject» y
 *     NO lo desplaza (medido con sonda `qs -p`, 2026-09-14). No pueden convivir:
 *     encenderlo solo sirve con `polkit-agent.service` parado.
 *   · RIESGO ALTO: si el agente del shell falla, no hay autenticacion de root en
 *     el escritorio. El de KDE no se retira: se para, no se deshabilita, y
 *     `systemctl --user start polkit-agent` lo devuelve (apagando antes esto).
 *
 * REINTENTOS ACOTADOS (2026-09-15). La Fase D decidio no reintentar para no
 * llenar el journal si el de KDE estaba registrado. Lo medido en la Fase 3 de
 * notificaciones lo cambia: tras un SIGSEGV, el gestor de caidas de Quickshell
 * reinicia el shell en el mismo PID en ~20 ms y el agente nuevo pide registro
 * cuando polkitd aun ve vivo al anterior («An authentication agent already
 * exists»). Sin reintento el escritorio se quedaba SIN dialogo de `pkexec` hasta
 * un reinicio limpio (reproducido dos veces). `PolkitAgent` no tiene metodo para
 * volver a registrarse, pero medido con sonda que RECREARLO hace un intento
 * nuevo: si 1,5 s despues de crearse no esta registrado, se recrea a los 2, 4, 8
 * y 16 s, y despues se rinde con un unico aviso. Son como mucho 8 lineas de
 * journal (2 por intento) en el caso del agente de KDE registrado.
 *
 * La contrasena nunca pasa por aqui como estado: la superficie la entrega a
 * `flow.submit()` y vacia el campo.
 */
Singleton {
    id: root

    readonly property bool enabled: Settings.polkitAgent
    readonly property var agent: loader.item
    readonly property bool registered: root.agent !== null && root.agent.isRegistered
    readonly property bool active: root.agent !== null && root.agent.isActive
    readonly property var flow: root.agent !== null ? root.agent.flow : null

    /** Esperas entre reintentos de registro (ms). Su longitud es el tope. */
    readonly property var retryDelays: [2000, 4000, 8000, 16000]
    property int retries: 0
    /** Mientras es true el LazyLoader destruye el agente, para recrearlo. */
    property bool cycling: false
    property bool gaveUp: false

    /** Empieza una peticion: `shell.qml` abre `auth` en el monitor enfocado. */
    signal requestStarted()

    LazyLoader {
        id: loader
        active: root.enabled && !root.cycling

        PolkitAgent {
            onAuthenticationRequestStarted: root.requestStarted()
            onIsRegisteredChanged: {
                console.info("polkit: agent registered =", isRegistered);
                if (isRegistered) {
                    root.retries = 0;
                    root.gaveUp = false;
                    retry.stop();
                } else {
                    root.scheduleRetry();
                }
            }
            // El registro fallido no siempre avisa por `isRegisteredChanged`: se mira a los 1,5 s.
            Component.onCompleted: settle.restart()
        }
    }

    Timer {
        id: settle
        interval: 1500
        onTriggered: root.scheduleRetry()
    }

    function scheduleRetry() {
        if (!root.enabled || root.registered || root.cycling || retry.running)
            return;
        if (root.retries >= root.retryDelays.length) {
            if (!root.gaveUp) {
                root.gaveUp = true;
                console.warn("polkit: agent still not registered after", root.retries,
                             "retries; restart the shell (systemctl --user restart sumi-shell)");
            }
            return;
        }
        retry.interval = root.retryDelays[root.retries];
        retry.start();
    }

    Timer {
        id: retry
        onTriggered: {
            if (root.registered || !root.enabled)
                return;
            root.retries++;
            console.info("polkit: retrying agent registration", root.retries + "/" + root.retryDelays.length);
            root.cycling = true;   // destruye el agente…
            recreate.restart();    // …y lo vuelve a crear: intento nuevo (medido)
        }
    }

    Timer {
        id: recreate
        interval: 200
        onTriggered: root.cycling = false
    }

    onEnabledChanged: {
        settle.stop();
        retry.stop();
        root.retries = 0;
        root.gaveUp = false;
    }

    // ---- la petición como operación global (fase 6D) --------------------------

    /**
     * Cada petición es una operación de `Operations` (tipo y recurso "polkit":
     * el agente lleva una a la vez). La empieza `shell.qml`, que es quien sabe en
     * qué pantalla la abre; aquí se termina cuando el flujo se completa, se
     * sustituye o desaparece. La superficie `auth` la usa como `opId`: así una
     * vista que se cierra porque el control se TRASLADÓ no cancela la petición.
     */
    property string opId: ""

    function beginOp(owner) {
        if (root.opId.length > 0) Operations.end(root.opId, "cancelled", "Replaced by a newer request");
        const r = Operations.begin("polkit", "polkit", "auth", "", owner,
                                   { state: "needs-input",
                                     snapshot: { actionId: root.flow ? String(root.flow.actionId) : "" } });
        root.opId = r.id;
        return r.id;
    }

    function endOp() {
        if (root.opId.length === 0) return;
        const f = root.watchedFlow;
        const st = !f ? "unknown" : f.isSuccessful ? "succeeded" : f.isCancelled ? "cancelled" : "failed";
        Operations.end(root.opId, st, st === "unknown" ? "The request went away" : "");
        root.opId = "";
    }

    /** El flujo de la operación; al completarse (o al irse sin completar) la termina. */
    property var watchedFlow: null
    onFlowChanged: {
        if (root.watchedFlow && root.flow !== root.watchedFlow) { endLater.stop(); root.endOp(); }
        root.watchedFlow = root.flow;
    }
    Connections {
        target: root.watchedFlow
        ignoreUnknownSignals: true
        // 16G: «completado» llega ANTES que «éxito» (medido en la 6D): leído en el acto, una acción
        // autorizada quedaba como `failed` en Operations. Se espera lo mismo que Auth (300 ms).
        function onIsCompletedChanged() { if (root.watchedFlow && root.watchedFlow.isCompleted) endLater.restart(); }
    }
    Timer { id: endLater; interval: 300; onTriggered: root.endOp() }

    function summary() {
        return {
            enabled: root.enabled, registered: root.registered, active: root.active,
            retries: root.retries, gaveUp: root.gaveUp, opId: root.opId,
            actionId: root.flow ? String(root.flow.actionId) : "",
            responseRequired: root.flow ? root.flow.isResponseRequired : false
        };
    }
}
