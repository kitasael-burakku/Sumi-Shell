pragma Singleton
import QtQuick
import Quickshell

/**
 * One clock for the whole shell. Ukishima carries a SystemClock per monitor;
 * a single ticking source is cheaper and keeps every surface on the same
 * minute. It re-reads the wall clock when the machine wakes from suspend,
 * because its timer is monotonic and does not advance while asleep.
 */
Singleton {
    id: root

    readonly property date now: sysClock.date
    /** 9C-2: 24 h («20:28») o 12 h («8:28 PM»), Settings → Shell → Calendar. Un solo sitio: island, barra, Calendar y Lock. */
    readonly property string time: Qt.formatTime(sysClock.date, Settings.clockFormat === "12h" ? "h:mm AP" : "HH:mm")
    readonly property string date: Qt.locale().toString(sysClock.date, "ddd d MMM")
    /** La fecha larga de la pantalla de bloqueo: «Wednesday 16 September» (locale del sistema). */
    readonly property string longDate: Qt.locale().toString(sysClock.date, "dddd d MMMM")

    SystemClock {
        id: sysClock
        precision: SystemClock.Minutes
    }

    Connections {
        target: Session
        function onResumed() {
            sysClock.enabled = false;
            sysClock.enabled = true;
        }
    }
}
