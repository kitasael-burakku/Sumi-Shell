import QtQuick
import Quickshell
import "services"

/**
 * battery-probe.qml — la rama POSITIVA de `services/Battery`, en un sobremesa.
 *
 * Aquí `UPower.displayDevice` dice `isPresent: false`, así que hasta hoy sólo
 * se había ejercitado la rama negativa (que es la correcta: el island no pinta
 * nada). Esto prueba la otra sin portátil y sin mentirle al servicio: se le
 * pone delante un **upowerd de verdad** —el binario del sistema— hablando con
 * un sysfs falso de umockdev, en un bus privado.
 *
 *   dbus-daemon --config-file=tools/private-bus.conf --print-address --nofork &
 *   DBUS_SYSTEM_BUS_ADDRESS=<addr> umockdev-run -d tools/battery/<estado>.umockdev \
 *       -- /usr/lib/upowerd -v &
 *   DBUS_SYSTEM_BUS_ADDRESS=<addr> XDG_STATE_HOME=<tmp> qs -p sumi/battery-probe.qml
 *
 * Los tres estados de `tools/battery/` cubren lo que el servicio deriva:
 * `discharging` (65 %), `low` (15 % descargando → `low` verdadero) y
 * `charging-low` (15 % cargando → `low` FALSO, porque enchufada no avisa).
 *
 * Lo que NO prueba: que esta máquina tenga batería. Prueba que el código que la
 * leería hace lo que dice cuando la hay.
 */
ShellRoot {
    id: probe

    function report(why) {
        console.log("probe:", why,
                    "· present =", Battery.present,
                    "· percent =", Battery.percent,
                    "· charging =", Battery.charging,
                    "· low =", Battery.low,
                    "· periféricos =", Battery.peripherals.length);
    }

    Component.onCompleted: probe.report("al arrancar")

    /** Los modelos de Quickshell se pueblan tarde (55 ms medidos): se remira. */
    Timer {
        interval: 1200
        running: true
        repeat: true
        property int n: 0
        onTriggered: {
            n++;
            probe.report("t+" + (n * 1.2) + "s");
            if (n >= 3)
                running = false;
        }
    }
}
