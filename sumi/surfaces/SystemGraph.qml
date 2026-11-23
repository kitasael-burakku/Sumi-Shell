import QtQuick
import "../theme"
import "../lib/monitor.js" as Monitor

/**
 * Micrográfica de la surface compacta (antes de la fase 12, M4): el pulso de los últimos 60 s, una
 * o dos series con los colores de la UI (primario, secundario). Sin puntero ni selección: señalar un
 * instante es trabajo de la UI de inspección (Details / Super+Ctrl+Y). Los huecos cortan la línea,
 * lo aún no medido queda vacío; la escala sólo se rotula cuando no es fija (bytes).
 */
Item {
    id: root
    property real s: 1
    /** {keys, unit, max}: claves planas de Sysmon.flatten. */
    property var spec: ({})
    property var samples: []
    property bool painting: true
    readonly property var keys: root.spec.keys || []
    readonly property real peak: {
        let peak = 0;
        for (const p of root.samples) for (const k of root.keys) {
            const x = p.v ? p.v[k] : null;
            if (typeof x === "number" && x > peak) peak = x;
        }
        return peak;
    }
    readonly property real ceiling: root.spec.max > 0 ? root.spec.max : root.peak > 0 ? Math.pow(2, Math.ceil(Math.log2(root.peak))) : 1
    readonly property var colors: [Theme.primary, Theme.secondary]
    implicitHeight: 38 * root.s

    Canvas {
        id: plot
        anchors.fill: parent
        // Estrategia por defecto (Immediate), como el resto del shell: con Cooperative la ventana
        // presentaba a veces un fotograma sin la gráfica y parpadeaba al repintar (visto por el usuario).
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            // terminal (F6, ADR-34): la primera serie en columnas de bloque (▁▂▃▅▇), una por muestra, con un píxel de
            // aire; la segunda, en escalera de 1 px; la base, punteada
            const tui = Style.terminal;
            if (tui) {
                ctx.fillStyle = Theme.hair;
                for (let x = 0; x < width; x += 4) ctx.fillRect(x, height - 1, 1, 1);
            } else {
                ctx.strokeStyle = Theme.hair;
                ctx.lineWidth = 1;
                ctx.beginPath(); ctx.moveTo(0, height - 0.5); ctx.lineTo(width, height - 0.5); ctx.stroke();
            }
            if (!root.samples.length) return;
            const end = root.samples[root.samples.length - 1].monoMs;
            const xOf = p => width * (1 - (end - p.monoMs) / 60000);
            const yOfV = v => height - 1.5 - Math.max(0, Math.min(1, v / root.ceiling)) * (height - 3);
            for (let si = root.keys.length - 1; si >= 0; si--) {
                const key = root.keys[si];
                if (tui && si === 0) {
                    ctx.fillStyle = Qt.alpha(root.colors[0], 0.55);
                    const n = root.samples.length;
                    for (let i = 0; i < n; i++) {
                        const p = root.samples[i], v = p.v ? p.v[key] : null;
                        if (typeof v !== "number") continue;
                        const x1 = Math.round(xOf(p));
                        const x0 = i > 0 && p.monoMs - root.samples[i - 1].monoMs <= 2500 ? Math.round(xOf(root.samples[i - 1])) : x1 - 3;
                        const top = Math.round(yOfV(v));
                        if (x1 - x0 >= 2) ctx.fillRect(x0 + 1, top, x1 - x0 - 1, height - 1 - top);
                    }
                    continue;
                }
                // relleno suave bajo la primera serie: la tarjeta se lee aunque la línea vaya baja
                if (si === 0) {
                    ctx.fillStyle = Qt.alpha(root.colors[0], 0.12);
                    let seg = [], last = null;
                    const flush = () => {
                        if (seg.length > 1) {
                            ctx.beginPath();
                            ctx.moveTo(seg[0].x, height - 1);
                            for (const q of seg) ctx.lineTo(q.x, q.y);
                            ctx.lineTo(seg[seg.length - 1].x, height - 1);
                            ctx.closePath();
                            ctx.fill();
                        }
                        seg = [];
                    };
                    for (const p of root.samples) {
                        const v = p.v ? p.v[key] : null;
                        if (typeof v !== "number" || (last && p.monoMs - last.monoMs > 2500)) flush();
                        if (typeof v === "number") seg.push({x: xOf(p), y: height - 1.5 - Math.max(0, Math.min(1, v / root.ceiling)) * (height - 3)});
                        last = typeof v === "number" ? p : null;
                    }
                    flush();
                }
                ctx.strokeStyle = root.colors[si];
                ctx.lineWidth = tui ? Math.max(1, Math.round(root.s)) : 1.4 * root.s;
                ctx.beginPath();
                let prev = null, prevY = 0;
                for (const p of root.samples) {
                    const v = p.v ? p.v[key] : null;
                    if (typeof v !== "number") { prev = null; continue; }
                    const x = xOf(p), y = height - 1.5 - Math.max(0, Math.min(1, v / root.ceiling)) * (height - 3);
                    if (!prev || p.monoMs - prev.monoMs > 2500) ctx.moveTo(x, y);
                    else { if (tui) ctx.lineTo(x, prevY); ctx.lineTo(x, y); }
                    prev = p;
                    prevY = y;
                }
                ctx.stroke();
            }
        }
    }
    Text {
        visible: !(root.spec.max > 0) && root.peak > 0
        anchors.right: parent.right
        anchors.top: parent.top
        text: Monitor.format(root.ceiling, root.spec.unit)
        color: Theme.fgVariant
        opacity: 0.8
        font.family: Typography.mono
        font.pixelSize: Typography.micro * root.s
    }
    onSamplesChanged: if (root.painting) plot.requestPaint()
    onCeilingChanged: if (root.painting) plot.requestPaint()
    onPaintingChanged: if (root.painting) plot.requestPaint()
    Connections { target: Theme; function onPrimaryChanged() { plot.requestPaint(); } }
    // el dibujo cambia de forma con el estilo (F6)
    Connections { target: Style; function onTerminalChanged() { if (root.painting) plot.requestPaint(); } }
}
