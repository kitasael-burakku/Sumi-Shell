pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../services"
import "../components"

/**
 * Equalizer de la Audio UI (antes de la fase 14): el ecualizador entero, que sale de la surface.
 * Cuatro acciones (el pedido): encender/apagar, elegir preset, ajustar y resetear. El motor es el
 * de la 13D/13E (`services/Equalizer`, un filtro por salida en filter-chain) y NO cambia: esta vista
 * sólo lo enseña con espacio.
 *
 *   Salida      explícita siempre («Output: GS25F2 · default»): el EQ es por salida (modelo B). Por
 *               defecto sigue a la predeterminada; elegir otra sólo cambia qué se mira y edita.
 *   Gráfica     curva ESTÁTICA calculada con la misma respuesta que mide tools/eq-expect.py
 *               (`Equalizer.response`): línea llena = las bandas (los pomos van sobre ella);
 *               discontinua = lo que sale con el preamp, para ver cuándo pasa de 0 dB. Sin espectro
 *               en vivo (sería otra función, con su coste).
 *   Barras      Pre aparte (−12…0 dB, misma escala vertical) y diez bandas (−12…+12 dB) en su
 *               frecuencia. Arrastrar es RELATIVO (no salta al pulsar), pasos de 0,5 dB (Mayús:
 *               0,1); clic sin arrastrar fija ese valor; doble clic, 0 dB; rueda ±0,5.
 *   Presets     tocar una banda o el preamp pasa a Custom (la convención de la 13E, un Custom por
 *               salida: decisión del usuario, 2026-09-28); Custom guarda la última curva propia.
 *   Resets      Reset bands (bandas a 0, el preamp igual), Reset preamp (preamp a 0) y Flat (todo).
 *
 * Lo que no está aplicado no se pinta como aplicado: sin filtro (arrancando, error, salida
 * desconectada) la curva se atenúa y lo dice.
 */
AudioSection {
    id: root

    /** La familia de acento de la zona (Theme.fam; lib/accent-zones.js). */
    readonly property var acc: Theme.fam(palette.accent)
    readonly property string dev: AudioUi.eqDev
    readonly property var st: { void Equalizer.ops.table; void Equalizer.filters; return root.dev ? Equalizer.stateOf(root.dev) : {state: "none", reason: ""}; }
    readonly property var v: { void Equalizer.profiles; return Equalizer.view(root.dev); }
    readonly property bool live: root.st.state === "on" || root.st.state === "bypassed"
    readonly property bool applied: root.st.state === "on"
    readonly property var curveOp: { void Equalizer.ops.table; return Equalizer.ops.get("curve:" + root.dev); }
    readonly property var enOp: { void Equalizer.ops.table; return Equalizer.ops.get("enabled:" + root.dev); }
    readonly property var presetIds: Equalizer.presets.map(p => p.id).concat(["custom"])
    property int presetCursor: Math.max(0, root.presetIds.indexOf(root.v.preset))

    function fmt(x) {
        const r = Math.round(x * 10) / 10;
        return r > 0 ? "+" + r.toFixed(1) : r < 0 ? "−" + Math.abs(r).toFixed(1) : "0.0";
    }
    function freqLabel(i) {
        const f = Equalizer.freqs[i];
        return f >= 1000 ? (f / 1000) + "k" : String(f);
    }
    readonly property string stateText: {
        const s = root.st.state;
        const name = root.dev ? AudioRoutes.labelOf(root.dev) : "";
        if (Equalizer.readError) return Equalizer.readError + ".";
        if (s === "loading") return "Reading the equalizer settings…";
        if (s === "unavailable") return root.st.reason + ". The equalizer can't run on this computer; " + name + " plays without it.";
        if (s === "none") return "No equalizer yet for " + name + ". Turning it on, choosing a preset or moving a band creates it (it starts Flat and off).";
        if (s === "starting") return "Starting the equalizer for " + name + "…";
        if (s === "absent") return name + " isn't connected. Its equalizer is kept and comes back with it.";
        if (s === "failed") return root.st.reason + ". " + name + " keeps playing without the equalizer.";
        if (s === "bypassed") return "Off: the sound passes through unchanged. The values below are kept.";
        return "";
    }

    contentHeight: col.implicitHeight
    focusList: {
        if (!root.dev) return [];
        const l = [];
        if (AudioUi.eqOutputs.length > 1) l.push("eqOut");
        l.push("eqOn");
        if (root.st.state === "failed") l.push("eqRetry");
        l.push("pre");
        for (let i = 0; i < 10; i++) l.push("band:" + i);
        l.push("presets", "resetBands", "resetPre");
        if (root.v.clipRisk) l.push("safePre");
        return l;
    }
    onFocusIdChanged: if (root.focusId === "presets") root.presetCursor = Math.max(0, root.presetIds.indexOf(root.v.preset))
    onActivate: (id, dir) => {
        const d = root.dev;
        if (root.st.state === "unavailable" && id !== "eqOut") return;   // F2d: el texto dice por qué
        if (id === "eqOut") {
            const l = AudioUi.eqOutputs.map(o => o.value);
            const i = Math.max(0, l.indexOf(d));
            AudioUi.pickEq(l[((i + (dir === 0 ? 1 : dir)) % l.length + l.length) % l.length]);
        } else if (id === "eqOn") {
            Equalizer.setEnabled(d, dir === 0 ? !root.v.enabled : dir > 0);
        } else if (id === "eqRetry") {
            if (dir === 0) Equalizer.setup(d, Equalizer.labelFor(d));
        } else if (id === "pre") {
            Equalizer.setPreamp(d, dir === 0 ? 0 : root.v.preamp + 0.5 * dir);
        } else if (id.startsWith("band:")) {
            const b = parseInt(id.substring(5));
            Equalizer.setBand(d, b, dir === 0 ? 0 : root.v.bands[b] + 0.5 * dir);
        } else if (id === "presets") {
            // ←→ mueven el cursor; Enter aplica (recorrer presets no los va aplicando uno a uno)
            if (dir === 0) Equalizer.applyPreset(d, root.presetIds[root.presetCursor]);
            else root.presetCursor = Math.max(0, Math.min(root.presetIds.length - 1, root.presetCursor + dir));
        } else if (id === "resetBands") {
            if (dir === 0) Equalizer.resetBands(d);
        } else if (id === "resetPre") {
            if (dir === 0) Equalizer.resetPreamp(d);
        } else if (id === "safePre") {
            if (dir === 0) Equalizer.safePreamp(d);
        }
    }

    Column {
        id: col
        width: root.width
        spacing: 10 * root.s

        Empty {
            visible: !root.dev
            width: parent.width
            s: root.s
            glyph: "speaker"
            text: "No output device"
            hint: "The equalizer is set per output. Connect one to use it."
        }

        // ---- salida y encendido ----------------------------------------------------------------
        Item {
            visible: !!root.dev
            width: parent.width
            height: Math.max(34 * root.s, outBox.height, actions.height)
            Item {
                id: outBox
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                // Limitar el contenido de Choice, no sólo su caja: las opciones pueden ocupar varias filas.
                readonly property real room: Math.max(0, actions.x - outLabel.width - 20 * root.s)
                width: outLabel.width + 10 * root.s + (outChoice.visible ? outChoice.width : outName.width)
                height: Math.max(28 * root.s, outChoice.visible ? outChoice.implicitHeight : outName.implicitHeight)
                AudioFocus {
                    on: root.focusId === "eqOut"; s: root.s
                    anchors.leftMargin: 0   // el Flickable recorta en este borde
                }
                Text {
                    id: outLabel
                    anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                    text: "Output"
                    color: Theme.fgVariant
                    font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                }
                Choice {
                    id: outChoice
                    visible: AudioUi.eqOutputs.length > 1
                    anchors.left: outLabel.right; anchors.leftMargin: 10 * root.s
                    anchors.verticalCenter: parent.verticalCenter
                    availableWidth: Math.max(1, outBox.room)
                    s: root.s
                    name: "Equalizer output"
                    options: AudioUi.eqOutputs.map(o => ({value: o.value, label: o.label + (o.value === AudioUi.defaultSinkName ? " · default" : "")}))
                    value: root.dev
                    onPicked: function (val) { root.pick("eqOut"); AudioUi.pickEq(String(val)); }
                }
                Text {
                    id: outName
                    visible: !outChoice.visible
                    anchors.left: outLabel.right; anchors.leftMargin: 10 * root.s
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, outBox.room)
                    elide: Text.ElideRight
                    text: AudioRoutes.labelOf(root.dev) + (AudioUi.eqFollowsDefault ? " · default" : "")
                    color: Theme.fg
                    font.family: Typography.ui; font.pixelSize: Typography.body * root.s; font.weight: Typography.wStrong
                }
            }
            Row {
                id: actions
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 10 * root.s
                ActionButton {
                    visible: root.st.state === "failed"
                    anchors.verticalCenter: parent.verticalCenter
                    s: root.s
                    label: "Retry"
                    focused: root.focusId === "eqRetry" && AudioUi.keyNav
                    onTriggered: { root.pick("eqRetry"); Equalizer.setup(root.dev, Equalizer.labelFor(root.dev)); }
                }
                Item {
                    anchors.verticalCenter: parent.verticalCenter
                    width: onRow.width + 8 * root.s
                    height: 28 * root.s
                    AudioFocus { on: root.focusId === "eqOn"; s: root.s }
                    Row {
                        id: onRow
                        anchors.centerIn: parent
                        spacing: 8 * root.s
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.enOp.state === "error" ? root.enOp.reason : root.v.enabled ? "On" : "Off"
                            color: root.enOp.state === "error" ? Theme.errorColor : root.v.enabled ? root.acc.text : Theme.fgVariant
                            font.family: Typography.ui; font.pixelSize: Typography.body * root.s; font.weight: Typography.wStrong
                        }
                        Toggle {
                            anchors.verticalCenter: parent.verticalCenter
                            s: root.s
                            enabled: root.st.state !== "unavailable"
                            on: root.v.enabled
                            label: "Equalizer on " + AudioRoutes.labelOf(root.dev)
                            onToggled: { root.pick("eqOn"); Equalizer.setEnabled(root.dev, !root.v.enabled); }
                        }
                    }
                }
            }
        }
        Text {
            visible: !!root.dev && text.length > 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.stateText
            color: root.st.state === "failed" || Equalizer.readError ? Theme.errorColor
                : root.st.state === "unavailable" ? Theme.warn : Theme.fgVariant
            font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
        }

        // ---- curva y deslizadores ---------------------------------------------------------------
        /**
         * Geometría compartida (2026-10-01, pedido del usuario: «los deslizadores no están alineados
         * con donde deben ir»). Antes los pomos iban SOBRE la curva, pero la curva es la suma de las
         * diez campanas (se solapan) y cada pomo marca la ganancia de SU banda: +5 en 63 Hz quedaba
         * por debajo de una curva a +7. Ahora son dos piezas con las mismas columnas: la curva arriba
         * (con un punto donde la curva pasa por cada banda) y debajo el banco de deslizadores, cada
         * pomo exactamente en su valor. Las bandas son octavas: columnas iguales, y la escala de
         * frecuencia de la curva (logarítmica) cae en el centro de cada columna.
         */
        Item {
            id: lanes
            visible: false   // sólo geometría: invisible, la Column no le da hueco
            width: parent.width
            height: 0
            readonly property real preW: 52 * root.s
            readonly property real gapW: 14 * root.s
            readonly property real axisW: 30 * root.s
            readonly property real bankX: lanes.preW + lanes.gapW + lanes.axisW
            readonly property real bankW: lanes.width - lanes.bankX
            readonly property real colW: lanes.bankW / Equalizer.freqs.length
            /** Centro de la columna de la banda i. */
            function cx(i) { return lanes.bankX + (i + 0.5) * lanes.colW; }
            /** Frecuencia → x, la misma escala que las columnas (31,25 Hz · 2^i en el centro de la i). */
            function xOf(f) { return lanes.bankX + (Math.log(f / 31.25) / Math.LN2 + 0.5) * lanes.colW; }
            // atenuado si no suena así (apagado, arrancando, error, desconectada)
            readonly property real ink: root.applied ? 1 : 0.45
            /** Lo que se pinta: los valores animados de cada barra (un preset se desliza, no salta). */
            function shownBands() {
                const out = [];
                for (let i = 0; i < Equalizer.freqs.length; i++) {
                    const b = bandRep.itemAt(i);
                    out.push(b ? b.shown : (root.v.bands[i] || 0));
                }
                return out;
            }
        }

        Item {
            id: graph
            visible: !!root.dev
            width: parent.width
            height: 148 * root.s

            readonly property real plotY: 8 * root.s
            readonly property real plotH: graph.height - 2 * graph.plotY
            readonly property real span: 15     // la curva admite más que una banda (se suman)
            readonly property real pxPerDb: graph.plotH / (2 * graph.span)
            function yOf(db) { return graph.plotY + (graph.span - Math.max(-graph.span, Math.min(graph.span, db))) * graph.pxPerDb; }

            // a la izquierda, en la columna del preamp: el pico de lo que sale (la condición del aviso)
            Column {
                width: lanes.preW
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2 * root.s
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: "Peak"
                    color: Theme.fgVariant
                    font.family: Typography.ui; font.pixelSize: Typography.micro * root.s
                }
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: root.fmt(root.v.peak)
                    color: root.v.clipRisk ? Theme.errorColor : Theme.fg
                    font.family: Typography.mono; font.pixelSize: Typography.label * root.s; font.weight: Typography.wStrong
                }
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: "dB"
                    color: Theme.fgVariant
                    font.family: Typography.mono; font.pixelSize: Typography.micro * root.s
                }
            }

            Rectangle {   // el lienzo de la curva: sólo sobre el banco, como sus columnas
                x: lanes.bankX - 6 * root.s
                width: lanes.bankW + 6 * root.s
                height: parent.height
                radius: Metrics.rSm * root.s
                color: Qt.alpha(Theme.surfaceContainer, 0.45)
                border.width: 1
                border.color: Theme.hair
            }

            Canvas {
                id: curve
                anchors.fill: parent
                readonly property color line: root.acc.fill
                readonly property color grid: Theme.hair
                readonly property color danger: Theme.errorColor
                readonly property real pre: shownPre.value
                readonly property real ink: lanes.ink
                onLineChanged: requestPaint()
                onPreChanged: requestPaint()
                onInkChanged: requestPaint()
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                onPaint: {
                    const ctx = getContext("2d");
                    ctx.reset();
                    const x0 = lanes.bankX, x1 = lanes.bankX + lanes.bankW;
                    // rejilla: 0 y ±12 dB, y una vertical tenue por banda (lleva el ojo al deslizador)
                    ctx.lineWidth = 1;
                    ctx.strokeStyle = curve.grid;
                    for (const db of [12, 0, -12]) {
                        ctx.globalAlpha = db === 0 ? 0.9 : 0.4;
                        const y = Math.round(graph.yOf(db)) + 0.5;
                        ctx.beginPath(); ctx.moveTo(x0, y); ctx.lineTo(x1, y); ctx.stroke();
                    }
                    ctx.globalAlpha = 0.25;
                    for (let i = 0; i < Equalizer.freqs.length; i++) {
                        const x = Math.round(lanes.cx(i)) + 0.5;
                        ctx.beginPath(); ctx.moveTo(x, graph.plotY); ctx.lineTo(x, graph.plotY + graph.plotH); ctx.stroke();
                    }
                    ctx.globalAlpha = 1;
                    const bands = lanes.shownBands();
                    const n = 180, fs = [];
                    const fLo = 31.25 * Math.pow(2, -0.5), fHi = 31.25 * Math.pow(2, Equalizer.freqs.length - 0.5);
                    for (let i = 0; i <= n; i++) fs.push(fLo * Math.pow(fHi / fLo, i / n));
                    const bandsOnly = Equalizer.response(bands, 0, fs);
                    const total = Equalizer.response(bands, curve.pre, fs);
                    // relleno suave entre 0 dB y la curva de las bandas
                    ctx.beginPath();
                    ctx.moveTo(x0, graph.yOf(0));
                    for (let i = 0; i <= n; i++) ctx.lineTo(lanes.xOf(fs[i]), graph.yOf(bandsOnly[i]));
                    ctx.lineTo(x1, graph.yOf(0));
                    ctx.closePath();
                    ctx.fillStyle = Qt.alpha(curve.line, 0.14 * curve.ink);
                    ctx.fill();
                    // con el preamp: lo que sale; rojo por encima de 0 dB (puede saturar)
                    ctx.setLineDash([4 * root.s, 4 * root.s]);
                    ctx.lineWidth = 1.2 * root.s;
                    for (let i = 1; i <= n; i++) {
                        ctx.beginPath();
                        ctx.moveTo(lanes.xOf(fs[i - 1]), graph.yOf(total[i - 1]));
                        ctx.lineTo(lanes.xOf(fs[i]), graph.yOf(total[i]));
                        ctx.strokeStyle = total[i] > 0.05 ? Qt.alpha(curve.danger, 0.9 * curve.ink) : Qt.alpha(curve.line, 0.6 * curve.ink);
                        ctx.stroke();
                    }
                    ctx.setLineDash([]);
                    // las bandas
                    ctx.beginPath();
                    for (let i = 0; i <= n; i++) {
                        const x = lanes.xOf(fs[i]), y = graph.yOf(bandsOnly[i]);
                        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
                    }
                    ctx.strokeStyle = Qt.alpha(curve.line, curve.ink);
                    ctx.lineWidth = 2 * root.s;
                    ctx.stroke();
                    // dónde pasa la curva por cada banda: el punto, encima de su deslizador
                    const at = Equalizer.response(bands, 0, Equalizer.freqs.map((f, i) => 31.25 * Math.pow(2, i)));
                    for (let i = 0; i < at.length; i++) {
                        const hot = root.focusId === "band:" + i && AudioUi.keyNav || (bandRep.itemAt(i) && bandRep.itemAt(i).active);
                        ctx.beginPath();
                        // terminal (F6, ADR-34): nudos cuadrados
                        const nr = (hot ? 4 : 3) * root.s;
                        if (Style.terminal) ctx.rect(Math.round(lanes.cx(i) - nr), Math.round(graph.yOf(at[i]) - nr), Math.round(2 * nr), Math.round(2 * nr));
                        else ctx.arc(lanes.cx(i), graph.yOf(at[i]), nr, 0, 2 * Math.PI);
                        ctx.fillStyle = Qt.alpha(curve.line, curve.ink);
                        ctx.fill();
                    }
                }
                Connections {
                    target: root
                    function onFocusIdChanged() { curve.requestPaint(); }
                }
                Connections { target: Style; function onTerminalChanged() { curve.requestPaint(); } }
            }

            // eje: dB, en la columna del eje (la misma que la del banco de abajo)
            Repeater {
                model: [12, 0, -12]
                Text {
                    required property var modelData
                    x: lanes.preW + lanes.gapW
                    width: lanes.axisW - 12 * root.s
                    horizontalAlignment: Text.AlignRight
                    y: graph.yOf(modelData) - height / 2
                    text: modelData > 0 ? "+" + modelData : modelData < 0 ? "−" + Math.abs(modelData) : "0"
                    color: Theme.fgVariant
                    font.family: Typography.mono; font.pixelSize: Typography.micro * root.s
                }
            }
            Text {
                visible: !root.applied && root.st.state !== "none" && root.st.state !== "loading"
                anchors.right: parent.right; anchors.rightMargin: 8 * root.s
                y: graph.plotY + 2 * root.s
                text: root.st.state === "bypassed" ? "Off · not applied" : "Not applied"
                color: root.st.state === "failed" ? Theme.errorColor : Theme.fgVariant
                font.family: Typography.ui; font.pixelSize: Typography.micro * root.s; font.weight: Typography.wStrong
            }
            Text {
                anchors.right: parent.right; anchors.rightMargin: 8 * root.s
                y: graph.plotY + graph.plotH - height
                text: "— bands   - - with preamp"
                color: Theme.fgVariant
                opacity: 0.8
                font.family: Typography.ui; font.pixelSize: Typography.micro * root.s
            }
        }

        /** El preamp animado (la curva discontinua se desliza con él, como las bandas). */
        QtObject {
            id: shownPre
            property real value: preBar.shown
        }

        // ---- el banco: Pre y diez bandas, con la escala a la izquierda --------------------------
        Item {
            id: bank
            visible: !!root.dev
            width: parent.width
            height: 200 * root.s

            readonly property real topH: 20 * root.s      // la cifra de cada barra
            readonly property real botH: 20 * root.s      // la frecuencia
            readonly property real trackY: bank.topH + 8 * root.s
            readonly property real trackH: bank.height - bank.trackY - bank.botH - 8 * root.s
            readonly property real pxPerDb: bank.trackH / (Equalizer.bandMax - Equalizer.bandMin)
            function yOf(db) { return bank.trackY + (Equalizer.bandMax - db) * bank.pxPerDb; }
            function dbAt(y) { return Equalizer.bandMax - (y - bank.trackY) / bank.pxPerDb; }

            // la línea de 0 dB y las de ±6 a lo ancho del banco: cada pomo se compara de un vistazo
            Repeater {
                model: [12, 6, 0, -6, -12]
                Rectangle {
                    required property var modelData
                    x: lanes.bankX
                    width: lanes.bankW
                    y: Math.round(bank.yOf(modelData))
                    height: 1
                    color: Theme.hair
                    opacity: modelData === 0 ? 0.9 : 0.35
                }
            }
            Repeater {
                model: [12, 6, 0, -6, -12]
                Text {
                    required property var modelData
                    x: lanes.preW + lanes.gapW
                    width: lanes.axisW - 12 * root.s
                    horizontalAlignment: Text.AlignRight
                    y: bank.yOf(modelData) - height / 2
                    text: modelData > 0 ? "+" + modelData : modelData < 0 ? "−" + Math.abs(modelData) : "0"
                    color: Theme.fgVariant
                    font.family: Typography.mono; font.pixelSize: Typography.micro * root.s
                }
            }
            // separación del preamp
            Rectangle {
                x: lanes.preW + lanes.gapW / 2
                y: bank.trackY
                width: 1; height: bank.trackH
                color: Theme.hair
            }

            // el preamp, con la misma escala vertical (su carril va de 0 a −12)
            Bar {
                id: preBar
                fid: "pre"
                cx: lanes.preW / 2
                caption: "Pre"
                value: root.v.preamp
                lo: Equalizer.preMin
                hi: Equalizer.preMax
                onChanged: (x) => Equalizer.setPreamp(root.dev, x)
            }
            Repeater {
                id: bandRep
                model: Equalizer.freqs.length
                Bar {
                    required property int index
                    fid: "band:" + index
                    cx: lanes.cx(index)
                    caption: root.freqLabel(index)
                    value: root.v.bands[index] || 0
                    lo: Equalizer.bandMin
                    hi: Equalizer.bandMax
                    onChanged: (x) => Equalizer.setBand(root.dev, index, x)
                    onShownChanged: curve.requestPaint()
                    onActiveChanged: curve.requestPaint()
                }
            }
        }

        // ---- aviso de saturación (condición real: el pico calculado pasa de 0 dB) ------------------
        Item {
            visible: !!root.dev && root.v.clipRisk
            width: parent.width
            height: 28 * root.s
            Text {
                anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                anchors.right: safeBtn.left; anchors.rightMargin: 10 * root.s
                elide: Text.ElideRight
                text: "May clip: with this preamp the curve peaks at " + root.fmt(root.v.peak) + " dB."
                color: Theme.errorColor
                font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
            }
            ActionButton {
                id: safeBtn
                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                s: root.s
                label: "Lower preamp to " + root.fmt(root.v.safePre) + " dB"
                focused: root.focusId === "safePre" && AudioUi.keyNav
                onTriggered: { root.pick("safePre"); Equalizer.safePreamp(root.dev); }
            }
        }

        // ---- presets ---------------------------------------------------------------------------
        Item {
            visible: !!root.dev
            width: parent.width
            height: presetRow.height + 8 * root.s
            Row {
                id: presetRow
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6 * root.s
                Repeater {
                    model: root.presetIds
                    Rectangle {
                        id: chip
                        required property var modelData
                        required property int index
                        readonly property bool current: root.v.preset === chip.modelData
                        readonly property bool cursor: root.focusId === "presets" && root.presetCursor === chip.index
                        width: (presetRow.parent.width - 8 * presetRow.spacing) / 9
                        height: 28 * root.s
                        radius: Metrics.rSm * root.s
                        color: Theme.controlBg(Theme.tileBg, chipArea.containsMouse, chipArea.pressed && chipArea.containsMouse, chip.current, root.acc)
                        border.width: 1
                        border.color: chip.current ? root.acc.selBorder : chipArea.containsMouse ? Theme.hair : "transparent"
                        Behavior on color { ColorAnimation { duration: Motion.fast } }
                        Behavior on border.color { ColorAnimation { duration: Motion.fast } }
                        scale: chipArea.pressed ? 0.96 : 1
                        Behavior on scale { NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic } }
                        Accessible.role: Accessible.RadioButton
                        Accessible.name: Equalizer.presetName(chip.modelData) + " preset"
                        Accessible.checked: chip.current
                        AudioFocus { on: chip.cursor; s: root.s }
                        Text {
                            anchors.centerIn: parent
                            text: Equalizer.presetName(chip.modelData)
                            color: chip.current ? root.acc.text : Theme.fg
                            font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                            font.weight: chip.current ? Typography.wStrong : Typography.wNormal
                        }
                        MouseArea {
                            id: chipArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { root.pick("presets"); root.presetCursor = chip.index; Equalizer.applyPreset(root.dev, chip.modelData); }
                        }
                    }
                }
            }
        }

        // ---- resets y estado del guardado ----------------------------------------------------------
        // Pastillas del mismo alto y radio que los presets: el borde izquierdo es el de la columna
        // (un ActionButton sin fondo dejaba el texto 12 px dentro y parecía desalineado).
        Item {
            visible: !!root.dev
            width: parent.width
            height: 30 * root.s
            Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6 * root.s
                Pill {
                    label: "Reset bands"
                    glyph: "reload"
                    enabled: root.v.exists && root.v.bands.some(b => b !== 0)
                    focused: root.focusId === "resetBands" && AudioUi.keyNav
                    onTriggered: { root.pick("resetBands"); Equalizer.resetBands(root.dev); }
                }
                Pill {
                    label: "Reset preamp"
                    glyph: "reload"
                    enabled: root.v.exists && root.v.preamp !== 0
                    focused: root.focusId === "resetPre" && AudioUi.keyNav
                    onTriggered: { root.pick("resetPre"); Equalizer.resetPreamp(root.dev); }
                }
            }
            Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.curveOp.state === "error" ? root.curveOp.reason
                    : !root.v.exists ? "" : Equalizer.saving ? "Saving…" : "Saved"
                color: root.curveOp.state === "error" ? Theme.errorColor : Theme.fgVariant
                font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
            }
        }
        Text {
            visible: !!root.dev
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Moving a band switches to Custom (kept per output) · Flat resets · double-click: 0 dB · Shift-drag: 0.1 dB"
            color: Theme.fgVariant
            font.family: Typography.ui; font.pixelSize: Typography.micro * root.s
        }
    }

    /** Un botón en pastilla, de la familia de los presets (fondo de tile, borde fino). */
    component Pill: Rectangle {
        id: pill
        property string label: ""
        property string glyph: ""
        property bool enabled: true
        property bool focused: false
        signal triggered()
        width: pillRow.implicitWidth + 24 * root.s
        height: 28 * root.s
        radius: Metrics.rSm * root.s
        color: !pill.enabled ? "transparent" : Theme.controlBg(Theme.tileBg, pillArea.containsMouse, pillArea.pressed && pillArea.containsMouse, false, root.acc)
        border.width: 1
        border.color: pill.enabled ? Theme.hair : Qt.alpha(Theme.fg, 0.08)
        scale: pillArea.pressed ? 0.96 : 1
        Behavior on color { ColorAnimation { duration: Motion.fast } }
        Behavior on scale { NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic } }
        Accessible.role: Accessible.Button
        Accessible.name: pill.label
        Accessible.onPressAction: if (pill.enabled) pill.triggered()
        AudioFocus { on: pill.focused; s: root.s }
        Row {
            id: pillRow
            anchors.centerIn: parent
            spacing: 6 * root.s
            Icon {
                visible: pill.glyph.length > 0
                anchors.verticalCenter: parent.verticalCenter
                name: pill.glyph
                size: 12 * root.s
                color: pill.enabled ? Theme.fgVariant : Theme.disabledFg
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: pill.label
                color: pill.enabled ? Theme.fg : Theme.disabledFg
                font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
            }
        }
        MouseArea {
            id: pillArea
            anchors.fill: parent
            enabled: pill.enabled
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: pill.triggered()
        }
    }

    /**
     * Un deslizador vertical (banda o preamp) centrado en `cx`, con la escala del banco. El valor en
     * dB arriba (cifras tabulares: que −10.5 y 0.0 no muevan nada), la frecuencia abajo. `shown` es
     * el valor que se pinta: sigue al real con una transición corta cuando cambia solo (un preset,
     * Reset, el teclado) y al instante mientras se arrastra.
     */
    component Bar: Item {
        id: bar
        property string fid: ""
        property real cx: 0
        property string caption: ""
        property real value: 0
        property real lo: -12
        property real hi: 12
        signal changed(real v)
        readonly property bool focused: root.focusId === bar.fid
        /** Bajo el puntero o arrastrándose: realza su punto en la curva. */
        readonly property bool active: area.containsMouse || area.pressed
        property real shown: bar.value
        Behavior on shown {
            enabled: !area.pressed && !Motion.off
            NumberAnimation { duration: Motion.still ? Motion.calmMs : Motion.standard; easing.type: Easing.OutCubic }
        }
        onFocusedChanged: if (bar.focused) root.reveal(bank)
        x: bar.cx - width / 2
        y: 0
        width: Math.min(44 * root.s, lanes.colW - 4 * root.s)
        height: bank.height

        Accessible.role: Accessible.Slider
        Accessible.name: bar.caption === "Pre" ? "Preamp" : bar.caption + " hertz"
        Accessible.description: root.fmt(bar.value) + " dB"
        Accessible.focusable: true
        Accessible.focused: bar.focused

        Rectangle {   // hover tenue; contorno del foco sólo tras usar el teclado
            anchors.fill: parent
            radius: Metrics.rSm * root.s
            color: Theme.controlBg("transparent", area.containsMouse, area.pressed && area.containsMouse, false, root.acc)
            border.width: bar.focused && AudioUi.keyNav ? Metrics.focusWidth * root.s : 0
            border.color: root.acc.selBorder
            Behavior on color { ColorAnimation { duration: Motion.fast } }
        }
        Text {
            x: (bar.width - width) / 2
            y: (bank.topH - height) / 2 + 2 * root.s
            text: root.fmt(bar.value)
            color: area.pressed ? root.acc.text : bar.focused || area.containsMouse ? Theme.fg : Theme.fgVariant
            font.family: Typography.mono; font.pixelSize: Typography.micro * root.s
            font.weight: area.pressed || bar.value !== 0 ? Typography.wStrong : Typography.wNormal
        }
        // El pomo y el carril comparten el centro fraccionario incluso al crecer con el foco.
        // El carril sólo ocupa el tramo que admite (el preamp, de 0 a −12).
        Rectangle {
            readonly property real y0: bank.yOf(bar.hi)
            readonly property real y1: bank.yOf(bar.lo)
            x: (bar.width - width) / 2
            y: y0
            width: 6 * root.s
            height: y1 - y0
            radius: Metrics.pill(width)
            color: Theme.trackBg
        }
        Rectangle {   // de 0 al valor
            readonly property real y0: bank.yOf(Math.max(bar.lo, Math.min(bar.hi, 0)))
            readonly property real y1: bank.yOf(bar.shown)
            x: (bar.width - width) / 2
            width: 6 * root.s
            radius: Metrics.pill(width)
            y: Math.min(y0, y1)
            height: Math.max(2, Math.abs(y1 - y0))
            color: Qt.alpha(root.acc.fill, lanes.ink)
        }
        Rectangle {   // el pomo
            x: (bar.width - width) / 2
            y: bank.yOf(bar.shown) - height / 2
            width: (area.pressed ? 18 : area.containsMouse || bar.focused ? 16 : 14) * root.s
            height: width
            radius: Metrics.pill(width)
            color: root.applied ? root.acc.fill : Theme.fgVariant
            border.width: 2 * root.s
            border.color: Theme.surface
            Behavior on width { NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic } }
            // un halo mientras se arrastra: se ve qué se está moviendo
            Rectangle {
                anchors.centerIn: parent
                width: parent.width + 10 * root.s
                height: width
                radius: Metrics.pill(width)
                color: Qt.alpha(root.acc.fill, 0.18)
                opacity: area.pressed ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Motion.fast } }
            }
        }
        Text {
            x: (bar.width - width) / 2
            y: bank.height - bank.botH + (bank.botH - height) / 2
            text: bar.caption
            color: bar.focused || area.containsMouse ? Theme.fg : Theme.fgVariant
            font.family: Typography.ui; font.pixelSize: Typography.micro * root.s
            font.weight: bar.caption === "Pre" ? Typography.wStrong : Typography.wNormal
        }
        MouseArea {
            id: area
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.PointingHandCursor
            preventStealing: true
            property real startY: 0
            property real startV: 0
            property bool moved: false
            function snap(x, fine) {
                const step = fine ? 0.1 : 0.5;
                let r = Math.round(x / step) * step;
                if (fine && Math.abs(r) < 0.15) r = 0;
                return Math.max(bar.lo, Math.min(bar.hi, Math.round(r * 10) / 10));
            }
            onPressed: (m) => { root.pick(bar.fid); area.startY = m.y; area.startV = bar.value; area.moved = false; }
            onPositionChanged: (m) => {
                if (!area.pressed) return;
                if (!area.moved && Math.abs(m.y - area.startY) < 3 * root.s) return;
                area.moved = true;
                const want = area.snap(area.startV - (m.y - area.startY) / bank.pxPerDb, m.modifiers & Qt.ShiftModifier);
                if (want !== bar.value) bar.changed(want);
            }
            onReleased: (m) => {
                // un clic sin arrastrar fija el valor de ese punto (nunca al pulsar: sin saltos)
                if (!area.moved) {
                    const want = area.snap(bank.dbAt(m.y), m.modifiers & Qt.ShiftModifier);
                    if (want !== bar.value) bar.changed(want);
                }
            }
            onDoubleClicked: bar.changed(Math.max(bar.lo, Math.min(bar.hi, 0)))
            onWheel: (w) => {
                root.pick(bar.fid);
                const d = (w.modifiers & Qt.ShiftModifier ? 0.1 : 0.5) * (w.angleDelta.y > 0 ? 1 : -1);
                bar.changed(area.snap(bar.value + d, w.modifiers & Qt.ShiftModifier));
            }
        }
    }
}
