pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../services"
import "../components"

/**
 * Speed test (Network, 2026-11-14). Superficie `speedtest`; el archivo se llama NetSpeed porque `SpeedTest` ya es
 * el singleton de `services/` y los dos módulos se importan juntos (un nombre de tipo repetido es ambiguo). Se llega desde la ficha del cable y desde la de la red Wi‑Fi conectada
 * (`requestDetail("speedtest", "wired"|"wifi")`: la selección de esta pantalla dice de dónde se vino).
 *
 * LA VISTA SÓLO MIRA: la prueba es de `services/SpeedTest`. Cerrar o volver no la cancela (lo dice el aviso);
 * al reabrir se ve donde va o su resultado.
 *
 * ALTO POR CONTENIDO CON EL AVISO RESERVADO (como Wired/WifiDetail, ancho constante): el hueco del aviso existe
 * siempre (una línea como mínimo), así el destino del morph no se mueve mientras la prueba cambia cifras y avisos
 * (ADR-25). Primero fue un alto fijo, y dejaba un hueco vacío bajo el botón que crecía o faltaba según «Text size».
 * Si la pantalla no da para tanto (`host.maxH`), el contenido hace scroll dentro (`Flickable` + `ScrollHint`).
 *
 * QUÉ ES CADA CIFRA. Download/Upload son throughput medido de extremo a extremo; el «link» del cable es la
 * velocidad de enlace y sólo se enseña como contexto. Las cifras sin medir son «—», nunca 0.
 */
Surface {
    id: root

    mTop: Metrics.sp4
    mLeft: Metrics.sp5
    mRight: Metrics.sp5
    mBottom: Metrics.sp4

    /** De dónde se vino: "wired" · "wifi" · "" (IPC u otra vía). */
    property string sel: ""
    property bool keyNav: false

    readonly property string phase: SpeedTest.phase
    readonly property bool running: SpeedTest.busy
    readonly property real innerW: Math.min((Metrics.speedtestW - root.mLeft - root.mRight) * root.s, root.width)
    readonly property bool compact: root.innerW < 420 * root.s

    // ---- textos ------------------------------------------------------------------------------------

    function fmtMbps(v) {
        if (!isFinite(v)) return { value: "—", unit: "" };
        if (v >= 1000) return { value: (v / 1000).toFixed(v >= 10000 ? 1 : 2), unit: "Gb/s" };
        return { value: v < 10 ? v.toFixed(1) : String(Math.round(v)), unit: "Mb/s" };
    }
    function fmtMs(v) { return isFinite(v) ? (v < 10 ? v.toFixed(1) : String(Math.round(v))) : "—"; }

    function ago(ms) {
        if (!ms) return "";
        const d = Math.floor((Date.now() - ms) / 1000);
        if (d < 90) return "just now";
        if (d < 5400) return Math.round(d / 60) + " min ago";
        if (d < 172800) return Math.round(d / 3600) + " h ago";
        return Math.round(d / 86400) + " d ago";
    }

    readonly property var kindLabels: ({ ethernet: "Ethernet", wifi: "Wi-Fi", vpn: "VPN", loopback: "Loopback",
                                         other: "Network" })

    /** Las cifras que se enseñan: las de la prueba en curso o recién hecha; en reposo, las de la última. */
    readonly property bool showingLast: root.phase === "idle" && SpeedTest.lastResult !== null
    readonly property var last: SpeedTest.lastResult || ({})
    readonly property real shownPing: root.showingLast ? Number(root.last.latency) : SpeedTest.latencyMs
    readonly property real shownJitter: root.showingLast ? Number(root.last.jitter) : SpeedTest.jitterMs
    readonly property real shownDown: root.showingLast ? Number(root.last.down)
        : (root.phase === "download" ? SpeedTest.liveMbps : SpeedTest.downMbps)
    readonly property real shownUp: root.showingLast ? Number(root.last.up)
        : (root.phase === "upload" ? SpeedTest.liveMbps : SpeedTest.upMbps)

    readonly property string stateLabel: {
        switch (root.phase) {
        case "preflight": return "starting…";
        case "confirm": return "waiting";
        case "latency": return "ping…";
        case "download": return "download…";
        case "upload": return "upload…";
        case "done": return "done";
        case "failed": return root.rateLimited ? "rate limited" : "failed";
        case "cancelled": return "cancelled";
        default: return root.showingLast ? "last test · " + root.ago(root.last.at) : "";
        }
    }
    /** El límite temporal de Cloudflare (429) no es una avería: aviso naranja, no rojo. */
    readonly property bool rateLimited: root.phase === "failed" && SpeedTest.errorCode === "ratelimited"
    readonly property color stateColor: root.rateLimited ? Theme.warn
        : root.phase === "failed" ? Theme.errorColor
        : (root.running || root.phase === "done") ? Theme.primary : Theme.outline

    /** Por dónde va (o iría) el tráfico. El enlace del cable sólo como contexto. */
    readonly property string routeLabel: {
        const p = SpeedTest.path;
        if (p && p.dev.length > 0 && root.phase !== "idle") {
            const parts = ["via " + p.dev, root.kindLabels[p.kind] || "Network"];
            if (p.family === 6) parts.push("IPv6");
            if (p.colo.length > 0) parts.push("Cloudflare " + p.colo);
            return parts.join(" · ");
        }
        if (Net.kind === "wired")
            return "Ethernet · " + Net.wiredName + (Net.linkSpeed > 0 ? " · link " + Net.linkSpeed + " Mb/s" : "");
        if (Net.kind === "wifi") return "Wi-Fi · " + Net.ssid;
        return "Not connected";
    }

    /** Abierta desde la ficha Wi‑Fi mientras el cable lleva el tráfico: se mide el cable y hay que decirlo. */
    readonly property bool routeMismatch: root.sel === "wifi" && Net.kind === "wired"

    readonly property bool offline: Net.ready && !Net.connected
    /** La capacidad (scripts/capabilities.py): sin Python 3.11 no se ofrece; degradada, se dice en reposo. */
    readonly property bool capOk: Capabilities.can("network.speedtest")
    readonly property string capWhy: Capabilities.why("network.speedtest")

    readonly property var notice: {
        // Sin red y sin nada en curso, eso es lo que importa (no el error de la prueba anterior).
        if (root.offline && !SpeedTest.active)
            return { tone: "info", text: Net.unavailableWhy.length > 0 ? Net.unavailableWhy + "." : "You're offline." };
        switch (root.phase) {
        case "confirm":
            return { tone: "warn", text: "Metered connection: the test can use up to ~700 MB." };
        case "failed":
            return { tone: root.rateLimited ? "warn" : "danger", text: SpeedTest.errorText };
        case "cancelled":
            return SpeedTest.errorCode.length > 0 ? { tone: "warn", text: SpeedTest.errorText }
                                                  : { tone: "info", text: "Test cancelled." };
        case "done":
            if (SpeedTest.cpuBound)
                return { tone: "info", text: "The processor limited the measurement; the result may read low." };
            if (SpeedTest.limited)
                return { tone: "info", text: "The test server cut the test short; the result covers a shorter run." };
            if (SpeedTest.capped)
                return { tone: "info", text: "Stopped early at the data limit; the result is still valid." };
            break;
        }
        if (root.running)
            return { tone: "info", text: root.routeMismatch
                ? "Traffic goes over Ethernet (" + Net.wiredName + "), so this measures that connection."
                : "You can close this panel; the test keeps running." };
        if (root.routeMismatch)
            return { tone: "info", text: "Traffic goes over Ethernet (" + Net.wiredName + "), so this measures that connection." };
        if (root.phase === "idle" && root.capWhy.length > 0)
            return { tone: root.capOk ? "info" : "warn", text: root.capWhy + "." };
        if (root.phase === "idle")
            return { tone: "info", text: "Measures latency, download and upload through Cloudflare. Uses data." };
        return { tone: "info", text: "" };
    }

    // ---- acciones ----------------------------------------------------------------------------------

    readonly property var actionList: {
        if (root.phase === "confirm")
            return [{ id: "confirm", glyph: "rocket", label: "Continue", primary: true },
                    { id: "cancel", label: "Cancel" }];
        if (root.running)
            return [{ id: "cancel", glyph: "stop", label: "Cancel" }];
        return [{ id: "start", glyph: "rocket", primary: true,
                  label: (root.phase === "idle" && SpeedTest.lastResult === null) ? "Start test" : "Run again",
                  enabled: SpeedTest.canStart && !root.offline && root.capOk }];
    }

    function run(id) {
        if (id === "start") SpeedTest.start();
        else if (id === "confirm") SpeedTest.confirm();
        else if (id === "cancel") SpeedTest.cancel("");
        Qt.callLater(() => { if (acts) acts.reset(); });
    }

    function back() { root.requestBack(); }

    function keyPressed(event) {
        if (event.key === Qt.Key_Escape) { root.back(); event.accepted = true; return; }
        if (acts && acts.handleKey(event)) {
            root.keyNav = true;
            event.accepted = true;
        }
    }

    onActiveChanged: {
        if (!acts) return;
        acts.reset();
        root.keyNav = false;
        flick.contentY = 0;
    }
    implicitHeight: col.implicitHeight

    /** Las acciones cambian con la fase: el foco vuelve a la primera (la que importa). */
    onPhaseChanged: if (acts) acts.reset()

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: col.implicitHeight
        clip: true
        interactive: contentHeight > height + 1
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: col
            width: root.innerW
            spacing: Metrics.sp3 * root.s

            // ---- cabecera -------------------------------------------------------------------------

            Item {
                width: col.width
                height: Math.max(22 * root.s, title.implicitHeight)

                Icon {
                    id: backIcon
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    name: "chevron-left"
                    size: 14 * root.s
                    color: backArea.containsMouse ? Theme.fg : Theme.fgVariant
                    Behavior on color { ColorAnimation { duration: Motion.fast } }

                    MouseArea {
                        id: backArea
                        Accessible.role: Accessible.Button
                        Accessible.name: "Back"
                        Accessible.onPressAction: root.back()
                        anchors.fill: parent
                        anchors.margins: -6 * root.s
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.back()
                    }
                }

                Text {
                    id: title
                    anchors.left: backIcon.right
                    anchors.leftMargin: 8 * root.s
                    anchors.right: stateTag.left
                    anchors.rightMargin: 8 * root.s
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Speed test"
                    elide: Text.ElideRight
                    color: Theme.fg
                    font.family: Typography.ui
                    font.pixelSize: Typography.title * root.s
                    font.weight: Font.DemiBold
                }

                Text {
                    id: stateTag
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, col.width * 0.5)
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideRight
                    text: root.stateLabel
                    color: root.stateColor
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                    font.features: ({ "tnum": 1 })
                }
            }

            Text {
                x: 22 * root.s
                width: col.width - x
                text: root.routeLabel
                elide: Text.ElideMiddle
                color: Theme.fgVariant
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
                font.features: ({ "tnum": 1 })
            }

            // ---- escenario y cifras -----------------------------------------------------------------

            Grid {
                id: board
                width: col.width
                columns: root.compact ? 1 : 2
                columnSpacing: Metrics.sp4 * root.s
                rowSpacing: Metrics.sp3 * root.s

                /** El escenario: el cohete (components/SpeedRocket) y la barra de progreso de toda la prueba. */
                Rectangle {
                    id: stage
                    width: root.compact ? board.width : Math.round(board.width * 0.42)
                    height: root.compact ? 120 * root.s : figures.implicitHeight
                    radius: Metrics.rMd * root.s
                    color: Theme.cardBg
                    border.color: Theme.cardBorder
                    border.width: 1

                    SpeedRocket {
                        id: rocket
                        anchors.fill: parent
                        anchors.margins: 4 * root.s
                        // la escena acaba encima de la barra de progreso (las estelas no pasan por debajo)
                        anchors.bottomMargin: Metrics.sp3 * root.s + 4 * root.s + 6 * root.s
                        s: root.s
                        phase: root.phase
                        liveMbps: SpeedTest.liveMbps
                        finalMbps: SpeedTest.downMbps
                        pings: SpeedTest.pings
                        // ni un fotograma con la vista cerrada o fundida
                        live: root.open && root.opacity > 0.01
                        Accessible.role: Accessible.Animation
                        Accessible.name: "Rocket, " + (root.stateLabel.length > 0 ? root.stateLabel : "ready")
                    }

                    ProgressTrack {
                        id: track
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.margins: Metrics.sp3 * root.s
                        height: 4 * root.s
                        s: root.s
                        trackColor: Theme.trackBg
                        visible: root.phase !== "idle"
                        value: SpeedTest.progress
                        tint: root.rateLimited ? Theme.warn : root.phase === "failed" ? Theme.errorColor
                            : root.phase === "upload" ? Theme.secondary : Theme.primary
                        Behavior on value { NumberAnimation { duration: Motion.standard; easing.type: Easing.OutCubic } }
                    }
                }

                Column {
                    id: figures
                    width: root.compact ? board.width : board.width - stage.width - board.columnSpacing
                    spacing: Metrics.sp2 * root.s

                    Repeater {
                        model: [
                            { key: "ping", glyph: "timer", label: "Ping",
                              value: root.fmtMs(root.shownPing), unit: isFinite(root.shownPing) ? "ms" : "",
                              note: isFinite(root.shownJitter) ? "jitter " + root.fmtMs(root.shownJitter) + " ms" : "",
                              live: root.phase === "latency" },
                            { key: "down", glyph: "download", label: "Download",
                              value: root.fmtMbps(root.shownDown).value, unit: root.fmtMbps(root.shownDown).unit,
                              note: "", live: root.phase === "download" },
                            { key: "up", glyph: "upload", label: "Upload",
                              value: root.fmtMbps(root.shownUp).value, unit: root.fmtMbps(root.shownUp).unit,
                              note: "", live: root.phase === "upload" }
                        ]
                        delegate: Rectangle {
                            id: tile
                            required property var modelData
                            width: figures.width
                            height: Math.max(48 * root.s, tileRow.implicitHeight + Metrics.sp2 * 2 * root.s)
                            radius: Metrics.rSm * root.s
                            color: Theme.controlBg(Theme.tileBg, false, false, tile.modelData.live)
                            border.color: tile.modelData.live ? Theme.selBorder : "transparent"
                            border.width: 1
                            Behavior on color { ColorAnimation { duration: Motion.standard } }

                            Accessible.role: Accessible.StaticText
                            Accessible.name: tile.modelData.label + " " + tile.modelData.value + " " + tile.modelData.unit

                            Item {
                                id: tileRow
                                anchors.fill: parent
                                anchors.leftMargin: Metrics.sp3 * root.s
                                anchors.rightMargin: Metrics.sp3 * root.s
                                implicitHeight: Math.max(labelCol.implicitHeight, valueRow.implicitHeight)

                                Icon {
                                    id: tileGlyph
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: tile.modelData.glyph
                                    size: 16 * root.s
                                }

                                Column {
                                    id: labelCol
                                    anchors.left: tileGlyph.right
                                    anchors.leftMargin: Metrics.sp2 * root.s
                                    anchors.right: valueRow.left
                                    anchors.rightMargin: Metrics.sp2 * root.s
                                    anchors.verticalCenter: parent.verticalCenter

                                    Text {
                                        width: parent.width
                                        text: tile.modelData.label
                                        elide: Text.ElideRight
                                        color: Theme.fg
                                        font.family: Typography.ui
                                        font.pixelSize: Typography.body * root.s
                                    }
                                    Text {
                                        width: parent.width
                                        visible: text.length > 0
                                        text: tile.modelData.note
                                        elide: Text.ElideRight
                                        color: Theme.outlineText
                                        font.family: Typography.ui
                                        font.pixelSize: Typography.caption * root.s
                                        font.features: ({ "tnum": 1 })
                                    }
                                }

                                Row {
                                    id: valueRow
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Metrics.sp1 * root.s

                                    Text {
                                        anchors.baseline: unitText.baseline
                                        text: tile.modelData.value
                                        color: tile.modelData.value === "—" ? Theme.outlineText
                                            : root.showingLast ? Theme.fgVariant : Theme.fg
                                        font.family: Typography.ui
                                        font.pixelSize: Typography.title * 1.25 * root.s
                                        font.weight: Font.DemiBold
                                        font.features: ({ "tnum": 1 })
                                    }
                                    Text {
                                        id: unitText
                                        anchors.bottom: parent.bottom
                                        anchors.bottomMargin: 3 * root.s
                                        text: tile.modelData.unit
                                        color: Theme.fgVariant
                                        font.family: Typography.ui
                                        font.pixelSize: Typography.caption * root.s
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ---- aviso -----------------------------------------------------------------------------

            /** El hueco del aviso, siempre: una línea como mínimo, haya texto o no. */
            Item {
                width: col.width
                height: Math.max(msg.implicitHeight, slotProbe.implicitHeight)

                Notice {
                    id: msg
                    width: parent.width
                    s: root.s
                    visible: text.length > 0
                    tone: root.notice.tone
                    text: root.notice.text
                }
                Notice {
                    id: slotProbe
                    width: parent.width
                    s: root.s
                    visible: false
                    text: "M"
                }
            }

            // ---- acciones --------------------------------------------------------------------------

            ActionGroup {
                id: acts
                width: col.width
                s: root.s
                orientation: "horizontal"
                stretch: false
                tabMoves: true
                active: root.keyNav
                hoverMovesFocus: false
                minimumRowHeight: Metrics.hitMin
                spacing: Metrics.sp2 * root.s
                actions: root.actionList
                onHovered: root.keyNav = false
                onTriggered: (id) => root.run(id)
            }
        }
    }
    ScrollHint { view: flick; s: root.s }
}
