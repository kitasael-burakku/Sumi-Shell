import QtQuick
import Quickshell
import "services"

/**
 * sleep-probe.qml — ¿reacciona el shell al despertar, sin suspender la máquina?
 *
 * `services/Session` vigila el bus del SISTEMA con
 * `dbus-monitor --system type='signal',sender='org.freedesktop.login1',member='PrepareForSleep'`
 * y cuenta el flanco de vuelta (`boolean false`): `resumeCount++` y la señal
 * `resumed()`, que es la que hace a `services/Clock` re-sincronizar su
 * `SystemClock` (los timers monótonos no avanzan dormidos).
 *
 * En esta máquina el retorno desde `deep` falla por firmware, así que el camino
 * nunca se había ejercitado. Esto lo prueba SIN suspender: se levanta un bus
 * privado, se apunta ahí `DBUS_SYSTEM_BUS_ADDRESS`, y un emisor que sí posee el
 * nombre `org.freedesktop.login1` manda la pareja de señales. Lo que se mide es
 * el código real del shell —el singleton es el mismo archivo—, en un proceso
 * aparte y sin tocar la sesión viva.
 *
 * Uso (ver docs/MIGRATION.md, «Sonda de resume»):
 *   dbus-daemon --config-file=tools/private-bus.conf --print-address --nofork &
 *   DBUS_SYSTEM_BUS_ADDRESS=<addr> XDG_STATE_HOME=<tmp> qs -p sumi/sleep-probe.qml
 *   python3 tools/fake-sleep.py <addr>
 *
 * Aviso: con el bus privado, el inhibidor de logind de `Session` no puede
 * hablar con nadie y se reintenta con su presupuesto de 5 antes de rendirse.
 * Es ruido esperado de la sonda, no del shell.
 */
ShellRoot {
    id: probe

    property int seen: 0

    Component.onCompleted: console.log("probe: arriba · watchingSleep =", Session.watchingSleep,
                                       "· resumeCount =", Session.resumeCount)

    Connections {
        target: Session
        function onResumed() {
            probe.seen++;
            console.log("probe: resumed() emitida · resumeCount =", Session.resumeCount,
                        "· veces vistas =", probe.seen);
        }
    }

    /** Sin el vigilante vivo, `resumeCount` no significa nada: se dice. */
    Timer {
        interval: 1500
        running: true
        onTriggered: console.log("probe: watchingSleep =", Session.watchingSleep,
                                 "· sleepRestarts =", Session.sleepRestarts)
    }
}
