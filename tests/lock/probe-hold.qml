import QtQuick
import Quickshell
import "components"

// Sonda 15A (LK-12): HoldButton, sin pantalla real. Nunca dispara nada fuera del proceso.
ShellRoot {
    id: root
    property var t0: 0
    property string test: ""
    function log(o) { console.log("PROBE " + JSON.stringify(o)); }

    FloatingWindow {
        visible: true
        implicitWidth: 200; implicitHeight: 100
        Item {
            anchors.fill: parent
            Item { id: other; focus: false; width: 10; height: 10 }
            HoldButton {
                id: btn
                x: 50
                glyph: "power"
                onFired: root.log({ test: root.test, fired: true, ms: Date.now() - root.t0 })
            }
        }
    }

    // T1: soltar a 300 ms y volver a pulsar a los 30 ms (con el relleno aún vaciándose)
    Timer { id: t1a; interval: 500; running: true; onTriggered: { root.test = "resume"; btn.press(); t1b.start(); } }
    Timer { id: t1b; interval: 300; onTriggered: { btn.release(); t1c.start(); } }
    Timer { id: t1c; interval: 30; onTriggered: { root.log({ test: "resume", fillAtRepress: btn.fill }); root.t0 = Date.now(); btn.press(); t2a.start(); } }
    // T2: foco de teclado que se pierde a mitad
    Timer { id: t2a; interval: 1200; onTriggered: { root.test = "focus-lost"; btn.fill = 0; btn.forceActiveFocus(); root.t0 = Date.now(); btn.pressKey(); t2b.start(); } }
    Timer { id: t2b; interval: 200; onTriggered: { other.forceActiveFocus(); root.log({ test: "focus-lost", btnFocus: btn.activeFocus, holding: btn.holding }); t3a.start(); } }
    // T3: el botón se oculta a mitad
    Timer { id: t3a; interval: 1200; onTriggered: { root.test = "hidden"; btn.release(); btn.fill = 0; root.t0 = Date.now(); btn.press(); t3b.start(); } }
    Timer { id: t3b; interval: 200; onTriggered: { btn.visible = false; root.log({ test: "hidden", visible: btn.visible, holding: btn.holding }); fin.start(); } }
    Timer { id: fin; interval: 1200; onTriggered: { root.log({ end: true }); Qt.quit(); } }
}
