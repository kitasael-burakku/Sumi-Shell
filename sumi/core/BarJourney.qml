import QtQuick
import "../theme"
import "../lib/bar-edge.js" as BarEdge

/** La misma barra se recoge, recorre el perímetro y se despliega. Una instancia por monitor. */
Item {
    id: trip
    required property string destination
    required property bool permanent
    required property bool animate
    readonly property string stopEdge: permanent ? destination : "top"
    property string edge: "top"
    property real position: 0
    property real spread: 0
    property real exposure: 1
    property bool busy: false
    property bool ready: false
    property real islandPosition: 0

    function settle() {
        step.stop();
        edge = stopEdge;
        position = BarEdge.ringEdges.indexOf(edge);
        spread = permanent ? 1 : 0;
        exposure = 1;
        busy = false;
    }
    function leg(key, end, ms) {
        step.property = key;
        step.easing.type = key === "position" ? Easing.InOutSine : Easing.InOutCubic;
        step.from = trip[key];
        step.to = end;
        step.duration = Math.max(1, Motion.dur(ms));
        step.start();
    }
    function advance() {
        if (!ready) return;
        step.stop();
        if (!animate || Motion.off) { settle(); return; }
        const end = BarEdge.nearestStop(position, stopEdge);
        const distance = Math.abs(end - position);
        const targetSpread = permanent ? 1 : 0;
        busy = true;
        if (distance > 0.0001 && Motion.still) {
            // Reduced cambia de borde tras desvanecer la barra en el origen.
            if (exposure > 0) { leg("exposure", 0, 105 * exposure); return; }
            position = end;
            spread = targetSpread;
        } else if (distance > 0.0001) {
            if (spread > 0) { leg("spread", 0, 200 * spread); return; }
            leg("position", end, 110 + 255 * distance);
            return;
        }
        edge = stopEdge;
        if (exposure < 1) { leg("exposure", 1, 140 * (1 - exposure)); return; }
        if (spread !== targetSpread) {
            leg("spread", targetSpread, (Motion.still ? 170 : permanent ? 285 : 215) * Math.abs(targetSpread - spread));
            return;
        }
        settle();
    }
    // Varias preferencias pueden cambiar en el mismo turno (p. ej., al aplicar un preset).
    function retarget() {
        if (!ready) return;
        if (!animate || Motion.off) settle();
        else Qt.callLater(trip.advance);
    }
    onStopEdgeChanged: retarget()
    onPermanentChanged: {
        if (permanent && ready && !busy && animate && !Motion.off) position = islandPosition;
        retarget();
    }
    onAnimateChanged: if (ready && !animate) settle()
    Connections {
        target: Motion
        function onModeChanged() { if (trip.busy) trip.advance(); }
        function onSpeedChanged() { if (trip.busy) trip.retarget(); }
    }
    Component.onCompleted: { settle(); ready = true; }
    NumberAnimation {
        id: step
        target: trip
        onFinished: trip.advance()
    }
}
