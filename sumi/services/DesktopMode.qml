pragma Singleton
import QtQuick
import Quickshell

// Fachada de compatibilidad: toda decisión y estado pertenecen a Modes.
Singleton {
    readonly property var modes: Modes.modes
    readonly property string mode: Modes.mode
    function closesShell(m) { return false; }
    function set(m) { return Modes.set(m); }
    function summary() { return Modes.summary(); }
}
