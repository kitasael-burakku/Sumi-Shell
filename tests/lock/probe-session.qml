import QtQuick
import Quickshell
import "lock"
import "services"

// Sonda 15G-1: LockSession cargada sola, SIN engage (nunca pide el bloqueo: persist.locked sigue en false y
// WlSessionLock no bloquea). La fase `locked` se SIMULA asignando `phase` para ver calma, datos y teclado.
ShellRoot {
    id: root
    function log(o) { console.log("PROBE " + JSON.stringify(o)); }
    LockSession { id: sess }

    property int n: 0
    property real t0: 0
    Timer {
        interval: 500; repeat: true; running: true
        onTriggered: {
            const i = root.n++;
            if (i === 2) {
                root.log({ step: "contract", phase: sess.phase, calm: sess.calm, visualizer: Lock.visualizer,
                           registered: Lock.session === sess,
                           keys: ["fetch", "weather", "metrics", "notifs", "music", "privacy", "avatarSource",
                                  "fetchImageSource", "buffer", "bufferLength", "auth", "layoutCode", "capsLock",
                                  "numLock", "suspendOk", "powerError", "notifications"].filter(function (k) { return sess[k] === undefined; }),
                           fns: ["touch", "setHolding", "setBuffer", "clearBuffer", "submit", "setFocusScreen",
                                 "enterDone", "leaveDone", "power", "media", "snapshot", "restTarget"].filter(function (k) { return typeof sess[k] !== "function"; }),
                           privacy: sess.privacy, musicKeys: Object.keys(sess.music), metricsKeys: Object.keys(sess.metrics) });
                sess.refreshDevices();
            } else if (i === 4) {
                root.log({ step: "devices", layoutCode: sess.layoutCode, layoutCount: sess.layoutCount });
                // simulación: la fase, sólo como número; el bloqueo no se pide
                sess.phase = "locked"; root.t0 = Date.now();
            } else if (i === 6) {
                root.log({ step: "simulated", phase: sess.phase, calm: sess.calm, weather: sess.weather.state,
                           metrics: sess.metrics.cpu.state });
            } else if (i === 26) {
                root.log({ step: "calm", calm: sess.calm, afterMs: Date.now() - root.t0, weather: sess.weather.state });
                sess.touch();
            } else if (i === 27) {
                root.log({ step: "woke", calm: sess.calm });
                sess.setHolding(true); root.t0 = Date.now();
            } else if (i === 50) {       // ~11,5 s sosteniendo
                root.log({ step: "holding", calm: sess.calm });
                sess.setHolding(false);
            } else if (i === 51) {
                sess.phase = "unlocked";
                root.log({ step: "end", phase: sess.phase, calm: sess.calm, persistLocked: false });
            } else if (i === 52) {
                Qt.quit();
            }
        }
    }
}
