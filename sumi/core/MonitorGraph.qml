import QtQuick
import "../theme"
import "../services"
import "../lib/monitor.js" as Monitor

/**
 * Gráfica de la UI de inspección (antes de la fase 12). Lee las filas de `MonitorUi.rows`: muestras
 * de 1 s (60 s) o cubos de 5 s (5 m…1 h, con media `v` y máximo `hi`). Hasta dos series por
 * gráfica, con dos colores (primario y secundario: el color es jerarquía, no un arcoíris).
 *
 * El eje temporal es siempre la ventana elegida y termina en la última fila (en pausa, la congelada).
 * Lo aún no medido queda vacío, un hueco corta la línea y nunca se dibuja un cero inventado. En los
 * cubos, el máximo del cubo se ve como una banda tenue sobre la media: un pico breve se reconoce
 * sin que la línea salte.
 *
 * El puntero enseña la lectura del punto más cercano en una fila de ancho fijo (las cifras no
 * empujan nada); no selecciona: la inspección de un instante es pausar.
 */
Item {
    id: root
    /** La familia de acento de la zona (Theme.fam; lib/accent-zones.js). */
    readonly property var acc: Theme.fam(palette.accent)
    property real s: 1
    property string title: ""
    /** [{key, label}] — claves planas de Sysmon.flatten. */
    property var series: []
    property string unit: "%"
    /** Techo fijo (p. ej. 100 %, VRAM total); 0 = automático sobre lo visible. */
    property real max: 0
    property var rows: MonitorUi.rows
    property real rangeMs: MonitorUi.rangeMs
    property bool trend: MonitorUi.usesTrend
    property bool painting: visible
    property real plotHeight: 96

    readonly property real endMs: root.rows.length ? root.rows[root.rows.length - 1].monoMs : 0
    readonly property var visibleRows: {
        const out = [], from = root.endMs - root.rangeMs;
        for (const r of root.rows) if (r.monoMs >= from) out.push(r);
        return out;
    }
    function val(row, key, peak) {
        const o = peak ? row.hi : row.v;
        const x = o ? o[key] : null;
        return typeof x === "number" && isFinite(x) ? x : null;
    }
    readonly property real ceiling: {
        if (root.max > 0) return root.max;
        let peak = 0;
        for (const r of root.visibleRows) for (const s of root.series) {
            const x = root.val(r, s.key, root.trend);
            if (x !== null && x > peak) peak = x;
        }
        if (root.unit === "°C") return Math.max(10, Math.ceil(peak / 10) * 10);
        if (root.unit === "%") return 100;
        return peak > 0 ? Math.pow(2, Math.ceil(Math.log2(peak))) : 1;
    }
    // la primera serie en el color de su zona; la segunda, en otra familia (2026-11-21)
    readonly property var colors: [root.acc.fill, root.acc.name === "tertiary" ? Theme.famPrimary.fill : Theme.famTertiary.fill]
    /** La fila bajo el puntero (null = la última). */
    property var hot: null
    readonly property var shown: root.hot || (root.visibleRows.length ? root.visibleRows[root.visibleRows.length - 1] : null)

    /** El ancho de la cifra más larga posible en esta unidad: fijo (no baila) y sin hueco de sobra. */
    TextMetrics {
        id: widest
        font.family: Typography.mono
        font.pixelSize: Typography.label * root.s
        text: root.unit === "%" ? "100.0%" : root.unit === "°C" ? "212 °F" : "1023.9 KiB/s"
    }
    TextMetrics {
        id: noDataWidth
        font: widest.font
        text: "No data"
    }
    /** La columna de la escala, a la derecha del trazado; su borde derecho es el de la leyenda. */
    readonly property real scaleW: 64 * root.s * Typography.grow   // la cifra crece con la familia y el Text size

    implicitHeight: head.height + 6 * root.s + root.plotHeight * root.s + 16 * root.s

    // ---- cabecera: título y lectura --------------------------------------------------------
    Item {
        id: head
        width: parent.width
        height: stacked ? 42 * root.s : 22 * root.s
        readonly property bool stacked: titleLabel.implicitWidth + legend.width + 24 * root.s > width
        Text {
            id: titleLabel
            anchors.left: parent.left
            y: head.stacked ? 0 : (head.height - height) / 2
            width: head.stacked ? parent.width : Math.max(0, parent.width - legend.width - 12 * root.s)
            elide: Text.ElideRight
            text: root.title
            color: Theme.fg
            font.family: Typography.ui
            font.pixelSize: Typography.label * root.s
            font.weight: Typography.wStrong
        }
        Row {
            id: legend
            anchors.right: parent.right
            y: head.stacked ? head.height - height : (head.height - height) / 2
            spacing: 12 * root.s
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.hot ? Monitor.ago(root.endMs - root.hot.monoMs) : ""
                color: Theme.fgVariant
                font.family: Typography.mono
                font.pixelSize: Typography.micro * root.s
            }
            Repeater {
                model: root.series
                Row {
                    required property var modelData
                    required property int index
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 5 * root.s
                    Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 8 * root.s; height: 2 * root.s; color: root.colors[index] }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.label
                        color: Theme.fgVariant
                        font.family: Typography.ui
                        font.pixelSize: Typography.caption * root.s
                    }
                    // ancho fijo: la cifra cambia cada segundo sin mover la leyenda
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.ceil(Math.max(widest.advanceWidth, noDataWidth.advanceWidth)) + 2 * root.s
                        horizontalAlignment: Text.AlignRight
                        text: root.shown ? Monitor.format(root.val(root.shown, modelData.key, false), root.unit, Sysmon.tempUnits) : "—"
                        color: Theme.fg
                        font.family: Typography.mono
                        font.pixelSize: Typography.label * root.s
                    }
                }
            }
        }
    }

    // ---- el trazado -------------------------------------------------------------------------
    Canvas {
        id: plot
        anchors.top: head.bottom
        anchors.topMargin: 6 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.rightMargin: root.scaleW
        height: root.plotHeight * root.s
        // Estrategia por defecto (Immediate), como el resto del shell: con Cooperative la ventana
        // presentaba a veces un fotograma sin la gráfica y parpadeaba al repintar (visto por el usuario).
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            // terminal (F6, ADR-34): rejilla punteada (también en vertical, por cuartos), línea en escalera de 1 px y
            // marcadores cuadrados; lo mismo de datos, otra forma
            const tui = Style.terminal;
            if (tui) {
                ctx.fillStyle = Theme.hair;
                for (const y of [0, Math.round(height / 2), height - 1])
                    for (let x = 0; x < width; x += 4) ctx.fillRect(x, y, 1, 1);
                for (const fx of [0.25, 0.5, 0.75])
                    for (let y = 0; y < height; y += 4) ctx.fillRect(Math.round(width * fx), y, 1, 1);
            } else {
                ctx.strokeStyle = Theme.hair;
                ctx.lineWidth = 1;
                for (const y of [0.5, height / 2, height - 0.5]) { ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(width, y); ctx.stroke(); }
            }
            const rows = root.visibleRows;
            if (!rows.length) return;
            const end = root.endMs, span = root.rangeMs, gap = root.trend ? 2 * Sysmon.bucketMs + 1000 : 2500;
            const xOf = t => width * (1 - (end - t) / span);
            const yOf = v => height - 1 - Math.max(0, Math.min(1, v / root.ceiling)) * (height - 2);
            for (let si = root.series.length - 1; si >= 0; si--) {
                const key = root.series[si].key, color = root.colors[si];
                // banda del máximo de cada cubo: tenue, sólo en tendencia
                if (root.trend) {
                    ctx.fillStyle = Qt.alpha(color, 0.16);
                    for (const r of rows) {
                        const hi = root.val(r, key, true), v = root.val(r, key, false);
                        if (hi === null || v === null || hi <= v) continue;
                        const x0 = xOf(r.startMs !== undefined ? r.startMs : r.monoMs - Sysmon.bucketMs), x1 = xOf(r.monoMs);
                        ctx.fillRect(x0, yOf(hi), Math.max(1, x1 - x0), yOf(v) - yOf(hi));
                    }
                }
                // relleno suave bajo la primera serie (sólo tramos continuos), línea en ambas
                if (si === 0) {
                    ctx.fillStyle = Qt.alpha(color, 0.10);
                    let seg = [];
                    const flush = () => {
                        if (seg.length > 1) {
                            ctx.beginPath();
                            ctx.moveTo(seg[0].x, height - 1);
                            let py = null;
                            for (const p of seg) { if (tui && py !== null) ctx.lineTo(p.x, py); ctx.lineTo(p.x, p.y); py = p.y; }
                            ctx.lineTo(seg[seg.length - 1].x, height - 1);
                            ctx.closePath();
                            ctx.fill();
                        }
                        seg = [];
                    };
                    let last = null;
                    for (const r of rows) {
                        const v = root.val(r, key, false);
                        if (v === null || (last && r.monoMs - last.monoMs > gap)) flush();
                        if (v !== null) seg.push({x: xOf(r.monoMs), y: yOf(v)});
                        last = v === null ? null : r;
                    }
                    flush();
                }
                ctx.strokeStyle = color;
                ctx.lineWidth = tui ? Math.max(1, Math.round(root.s)) : 1.6 * root.s;
                ctx.beginPath();
                let prev = null, prevY = 0;
                for (const r of rows) {
                    const v = root.val(r, key, false);
                    if (v === null) { prev = null; continue; }
                    const x = xOf(r.monoMs), y = yOf(v);
                    if (!prev || r.monoMs - prev.monoMs > gap) ctx.moveTo(x, y);
                    else { if (tui) ctx.lineTo(x, prevY); ctx.lineTo(x, y); }
                    prev = r;
                    prevY = y;
                }
                ctx.stroke();
                // la última lectura: un punto (dice «esto es ahora» sin mirar el eje); en terminal, un cuadrado
                if (prev) {
                    ctx.fillStyle = color;
                    const lx = xOf(prev.monoMs) - 1.5 * root.s, ly = yOf(root.val(prev, key, false));
                    if (tui) ctx.fillRect(Math.round(lx - 2.5 * root.s), Math.round(ly - 2.5 * root.s), Math.round(5 * root.s), Math.round(5 * root.s));
                    else { ctx.beginPath(); ctx.arc(lx, ly, 2.5 * root.s, 0, 2 * Math.PI); ctx.fill(); }
                }
            }
            if (root.hot) {
                const x = xOf(root.hot.monoMs);
                ctx.strokeStyle = Qt.alpha(Theme.fg, 0.35);
                ctx.lineWidth = 1;
                ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, height); ctx.stroke();
                // el punto leído de cada serie, con un anillo del fondo para separarlo de la línea
                for (let si = 0; si < root.series.length; si++) {
                    const v = root.val(root.hot, root.series[si].key, false);
                    if (v === null) continue;
                    ctx.beginPath();
                    if (tui) ctx.rect(Math.round(x - 3.5 * root.s), Math.round(yOf(v) - 3.5 * root.s), Math.round(7 * root.s), Math.round(7 * root.s));
                    else ctx.arc(x, yOf(v), 3.5 * root.s, 0, 2 * Math.PI);
                    ctx.fillStyle = root.colors[si];
                    ctx.fill();
                    ctx.lineWidth = 1.5 * root.s;
                    ctx.strokeStyle = Theme.surface;
                    ctx.stroke();
                }
            }
        }
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onPositionChanged: mouse => {
                const rows = root.visibleRows;
                if (!rows.length) { root.hot = null; return; }
                const at = root.endMs - root.rangeMs * (1 - Math.max(0, Math.min(1, mouse.x / width)));
                // no ofrecer un punto en el tramo todavía vacío
                if (at < rows[0].monoMs - (root.trend ? Sysmon.bucketMs : 1000)) { root.hot = null; return; }
                root.hot = rows.reduce((a, b) => Math.abs(a.monoMs - at) <= Math.abs(b.monoMs - at) ? a : b);
            }
            onExited: root.hot = null
        }
    }
    // escala a la derecha y eje temporal debajo
    Text {
        anchors.right: parent.right
        anchors.top: plot.top
        width: root.scaleW - 8 * root.s
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideLeft
        text: Monitor.format(root.ceiling, root.unit, Sysmon.tempUnits)
        color: Theme.fgVariant
        font.family: Typography.mono
        font.pixelSize: Typography.micro * root.s
    }
    Text {
        anchors.right: parent.right
        anchors.bottom: plot.bottom
        text: "0"
        color: Theme.fgVariant
        font.family: Typography.mono
        font.pixelSize: Typography.micro * root.s
    }
    Text {
        anchors.left: plot.left
        anchors.top: plot.bottom
        anchors.topMargin: 2 * root.s
        text: "−" + (root.rangeMs === 60000 ? "60 s" : Monitor.duration(root.rangeMs / 1000))
        color: Theme.fgVariant
        font.family: Typography.mono
        font.pixelSize: Typography.micro * root.s
    }
    Text {
        anchors.right: plot.right
        anchors.top: plot.bottom
        anchors.topMargin: 2 * root.s
        text: MonitorUi.paused ? "paused" : "now"
        color: MonitorUi.paused ? Theme.warn : Theme.fgVariant
        font.family: Typography.mono
        font.pixelSize: Typography.micro * root.s
    }

    onVisibleRowsChanged: if (root.painting) plot.requestPaint()
    onHotChanged: if (root.painting) plot.requestPaint()
    onCeilingChanged: if (root.painting) plot.requestPaint()
    onPaintingChanged: if (root.painting) plot.requestPaint()
    onSeriesChanged: if (root.painting) plot.requestPaint()
    Connections { target: Theme; function onPrimaryChanged() { plot.requestPaint(); } }
    // el dibujo cambia de forma con el estilo (F6)
    Connections { target: Style; function onTerminalChanged() { if (root.painting) plot.requestPaint(); } }
}
