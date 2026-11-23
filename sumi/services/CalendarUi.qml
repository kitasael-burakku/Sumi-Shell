pragma Singleton
import QtQuick
import Quickshell

/** View state only. Agenda and Weather remain the existing data providers. */
Singleton {
    id: root
    property bool open: false
    property string screen: ""
    property var context: null
    property var positions: ({})
    property var layer: null
    signal opening()

    function capture() {
        if (root.layer && root.layer.contentItem()) root.context = root.layer.contentItem().saveContext();
    }
    function show(name, ctx) {
        if (!name || Lock.engaged) return false;
        if (!ctx) root.capture();
        else root.context = ctx;
        root.opening();
        const same = root.screen === name;
        root.screen = name;
        root.open = true;
        if (same && ctx && root.layer) root.layer.restore(ctx);
        return true;
    }
    function close() {
        root.capture();
        root.open = false;
        return true;
    }
    function positionOf(name) { return root.positions[name] || null; }
    function remember(name, x, y) {
        const p = Object.assign({}, root.positions);
        p[name] = {x:Math.round(x), y:Math.round(y)};
        root.positions = p;
    }
    function summary() {
        return {open:root.open, screen:root.screen, context:root.context,
            positions:root.positions, layer:root.layer ? root.layer.geometry() : null};
    }
}
