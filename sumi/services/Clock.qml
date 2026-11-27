pragma Singleton
import QtQuick
import Quickshell
import "../lib/time-format.js" as TimeFormat

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
    readonly property string time: Qt.formatTime(sysClock.date, TimeFormat.pattern(Settings.clockFormat, false))
    readonly property string date: Qt.locale().toString(sysClock.date, "ddd d MMM")
    /** La fecha larga de la pantalla de bloqueo: «Wednesday 16 September» (locale del sistema). */
    readonly property string longDate: Qt.locale().toString(sysClock.date, "dddd d MMMM")

    /*
     * Contrato de tiempo (2026-11-27, ADR-42): toda hora y toda antigüedad que se dibuje sale de aquí, con el
     * formato del usuario (12/24 h). La lógica está en `lib/time-format.js`; Qt pone el locale. `when` y `ago`
     * leen `now`, así que un enlace que las use se renueva cada minuto sin temporizador propio.
     */
    function qtTime(d, p) { return Qt.formatTime(d, p); }
    function qtDate(d, p) { return Qt.formatDate(d, p); }
    /** Una hora (ms de época o Date): «20:28» / «8:28 PM»; con `seconds`, «20:28:05» / «8:28:05 PM». */
    function fmt(ms, seconds) {
        return Qt.formatTime(ms instanceof Date ? ms : new Date(ms), TimeFormat.pattern(Settings.clockFormat, !!seconds));
    }
    /** Fecha y hora con un prefijo de fecha propio («ddd d MMM, »): la hora sigue el formato del usuario. */
    function fmtDated(ms, datePattern) {
        return Qt.formatDateTime(ms instanceof Date ? ms : new Date(ms),
                                 datePattern + TimeFormat.pattern(Settings.clockFormat, false));
    }
    /** Una hora de datos «HH:MM» (calendario) en el formato del usuario; `..:..` pasa tal cual. */
    function hm(text) { return TimeFormat.hm(text, Settings.clockFormat, root.qtTime); }
    /** «today 10:42» · «yesterday 18:10» · «Sep 25 18:10». */
    function when(ms) {
        return TimeFormat.when(ms, root.now.getTime(), Settings.clockFormat, root.qtTime, root.qtDate);
    }
    /**
     * Antigüedad: `style` compact («5m») · spaced («5 min») · long («5 min ago»). `nowMs` opcional, para quien ya
     * tiene su propio reloj (las tarjetas de aviso, Issues); sin él, la hora actual. `never` para «sin fecha».
     */
    function ago(ms, style, nowMs, never) {
        void root.now;
        return TimeFormat.ago(ms, nowMs === undefined ? Date.now() : nowMs, style, never);
    }

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
