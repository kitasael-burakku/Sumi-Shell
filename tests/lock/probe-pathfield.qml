import QtQuick
import Quickshell
import "components"
// Sonda 15H: el aviso de PathField (decisión 3) con rutas buenas, inexistentes y no locales. Offscreen.
ShellRoot {
    function log(o) { console.log("PROBE " + JSON.stringify(o)); }
    FloatingWindow {
        visible: true; implicitWidth: 600; implicitHeight: 200
        Column {
            PathField { id: ok; value: Quickshell.env("KT_IMG"); round: true }
            PathField { id: missing; value: "/nonexistent/kt15h.png"; round: true }
            PathField { id: remote; value: "https://example.com/a.png"; round: false }
            PathField { id: empty; value: ""; placeholder: ""; round: false }
        }
    }
    Timer { interval: 1500; running: true; onTriggered: {
        log({ ok: ok.problem, missing: missing.problem, remote: remote.problem, empty: empty.problem }); Qt.quit(); } }
}
