pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import "../theme"
import "../services"
import "../components"
import "../lib/accent-zones.js" as Zones
import "../lib/monitor.js" as Monitor

/**
 * La UI de inspección de System Monitor (antes de la fase 12, `rediseno/Antes-de-fase-12.md`).
 * Decidido con el usuario el 2026-09-27: **capa del shell** como la tienda de Wallhaven
 * (`WallhavenLayer`, W1): tarjeta flotante que se arrastra por la cabecera dentro del monitor, una
 * sola instancia (`MonitorUi`), fuera de Alt+Tab y del minimizador. Super+Ctrl+Y.
 *
 * La surface compacta es el vistazo; esto es el análisis: secciones a la izquierda, la elegida a la
 * derecha, Live/Paused y la ventana temporal arriba, el estado abajo. Sólo la sección visible está
 * instanciada (Loader): lo que no se ve no calcula. Cerrada, la reclamación inspect se suelta.
 *
 * Teclado: lo da el compositor al pulsar dentro (`OnDemand`, como la tienda). 1–8 secciones,
 * Espacio pausa/reanuda, / busca procesos, Esc cierra (antes vacía la búsqueda).
 */
PanelWindow {
    id: win

    required property var targetScreen
    readonly property string name: win.targetScreen ? win.targetScreen.name : ""
    readonly property real s: Settings.uiScale
    readonly property bool shown: MonitorUi.open && MonitorUi.screen === win.name && !Lock.engaged
    readonly property real margin: Metrics.storeMargin * win.s
    // Leave the resting Island/bar accessible even when the window fills a short screen.
    readonly property real topInset: Math.max(Metrics.reservedH(win.s), Metrics.reservedBarH(win.s))
    /** 2026-11-19: la barra permanente abajo o a un lado no se tapa: su franja, además del margen (Screen.barInset). */
    readonly property var barHost: Screens.byName(win.targetScreen ? String(win.targetScreen.name) : "")
    readonly property real leftInset: win.margin + (win.barHost ? win.barHost.barInset("left") : 0)
    readonly property real rightInset: win.margin + (win.barHost ? win.barHost.barInset("right") : 0)
    readonly property real bottomInset: win.margin + (win.barHost ? win.barHost.barInset("bottom") : 0)
    readonly property real areaW: win.targetScreen ? win.targetScreen.width : 0
    readonly property real areaH: win.targetScreen ? win.targetScreen.height : 0

    screen: win.targetScreen
    visible: win.shown || card.appear > 0.001
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "sumi-monitor"
    WlrLayershell.keyboardFocus: win.shown ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    anchors { top: true; left: true; right: true; bottom: true }

    mask: win.shown ? cardRegion : noRegion
    Region { id: noRegion }
    /**
     * La región de entrada es la geometría de la tarjeta, SIN la transformación de la entrada (escala y subida de
     * `Reveal`): `item: card` la tomaba con la escala/subida del primer fotograma y no se recalculaba al acabar la
     * animación (sólo al mover o redimensionar), así que con Expressive quedaban muertos ~28 px de la cabecera y
     * ~20 px por lado (2026-11-11, tools/sumi-drag/).
     */
    Region { id: cardRegion; x: card.x; y: card.y; width: card.width; height: card.height }

    function clampX(x) { return Math.max(win.leftInset, Math.min(win.areaW - card.width - win.rightInset, x)); }
    function clampY(y) { return Math.max(win.topInset, Math.min(win.areaH - card.height - win.bottomInset, y)); }
    function place() {
        if (win.areaW <= 0 || win.areaH <= 0) return;
        const p = MonitorUi.positionOf(win.name);
        card.x = win.clampX(p ? p.x : (win.areaW - card.width) / 2);
        card.y = win.clampY(p ? p.y : (win.areaH - card.height) / 2);
    }
    function placeAt(x, y) {
        card.x = win.clampX(x);
        card.y = win.clampY(y);
        MonitorUi.remember(win.name, card.x, card.y);
        return true;
    }
    /** El mismo manejo que una tecla real; para IPC (`monitorKey`), sin inyectar nada al compositor. */
    function key(name) {
        const map = {Escape: Qt.Key_Escape, Space: Qt.Key_Space, Slash: Qt.Key_Slash, Up: Qt.Key_Up, Down: Qt.Key_Down};
        const k = map[name] || (/^[1-8]$/.test(name) ? Qt.Key_1 + Number(name) - 1 : 0);
        return k ? keys.handle(k, 0) : false;
    }
    function geometry() {
        return {screen: win.name, shown: win.shown, x: Math.round(card.x), y: Math.round(card.y),
                w: Math.round(card.width), h: Math.round(card.height), screenW: Math.round(win.areaW), screenH: Math.round(win.areaH),
                dragging: head.drag.active, appear: Math.round(card.appear * 100) / 100,
                loaded: body.status === Loader.Ready ? MonitorUi.section : "", sideW: Math.round(side.width)};
    }

    onShownChanged: if (win.shown) { win.place(); keys.forceActiveFocus(); }
    onAreaWChanged: if (win.shown) win.place()
    onAreaHChanged: if (win.shown) win.place()
    Component.onCompleted: MonitorUi.layer = win
    Component.onDestruction: if (MonitorUi.layer === win) MonitorUi.layer = null

    /** Avisos por dominio, para marcar la barra lateral. */
    readonly property var alertDomains: {
        const o = {};
        for (const a of MonitorUi.alerts) o[a.domain] = a.level === "critical" || o[a.domain] === "critical" ? "critical" : "warning";
        return o;
    }
    /** La cifra de cada sección en la barra lateral: el pulso sin entrar. */
    function sideValue(id) {
        const c = MonitorUi.current;
        if (!c) return "";
        if (id === "cpu") return Monitor.number(c.cpu ? c.cpu.usagePct : null, "%");
        if (id === "gpu") return c.gpus && c.gpus.length ? Monitor.number(c.gpus[0].usagePct, "%") : "—";
        if (id === "memory") return Monitor.number(c.memory ? c.memory.usedPct : null, "%");
        if (id === "processes") return MonitorUi.processList.length ? String(MonitorUi.processList.length) : "";
        if (id === "disks") return c.disks ? String(c.disks.length) : "";
        if (id === "network") return c.network ? "↓ " + Monitor.bytes(c.network.rxBps, true) : "";
        if (id === "sensors") return MonitorUi.sensors ? String(MonitorUi.sensors.chips.length) : "";
        return MonitorUi.alerts.length ? String(MonitorUi.alerts.length) + " ⚠" : "";
    }

    Item {
        id: card
        /** La sección elegida tiñe la ventana con su color (lib/accent-zones.js): CPU, GPU, memoria… */
        palette.accent: Theme.zone(Zones.of(MonitorUi.section))
        readonly property var acc: Theme.fam(palette.accent)
        width: Math.min(Metrics.monW * win.s, win.areaW - win.leftInset - win.rightInset)
        height: Math.max(0, Math.min(Metrics.monH * win.s, win.areaH - win.topInset - win.bottomInset))

        onWidthChanged: if (win.shown) Qt.callLater(win.place)
        onHeightChanged: if (win.shown) Qt.callLater(win.place)

        // Entrada/salida (2026-11-11, theme/Reveal, estilo de Settings → Animations): opacidad, escala desde
        // el centro y subida; sólo visual (posición, tamaño y región de entrada no cambian).
        Reveal { id: cardReveal; shown: win.shown; s: win.s }
        readonly property real appear: cardReveal.progress
        opacity: cardReveal.opacity
        scale: cardReveal.scale
        transformOrigin: Item.Center
        // sx/sy: Power-on y Mochi (theme/Reveal); 1 con los demás
        transform: [Translate { y: cardReveal.dy }, Scale { origin.x: card.width / 2; origin.y: card.height / 2; xScale: cardReveal.sx; yScale: cardReveal.sy }]
        layer.enabled: card.appear > 0.001 && card.appear < 0.999
        // Bloom, Ink, Scroll y Mist dibujan sobre la capa de la apertura (theme/RevealEffect, ADR-36)
        layer.effect: cardReveal.effect ? cardFx : null
        Component { id: cardFx; RevealEffect { rv: cardReveal; s: win.s } }

        Glass {
            anchors.fill: parent
            s: win.s
            radius: Metrics.rLg * win.s
            // el material global, como todo; casi opaca si se elige en Theme → Material → Advanced
            surface: "monitor"
            shadowed: !head.drag.active
        }

        Item {
            id: keys
            anchors.fill: parent
            focus: true
            function handle(k, mods) {
                if (k === Qt.Key_Escape) { MonitorUi.close(); return true; }
                if (k === Qt.Key_Space || k === Qt.Key_P) { MonitorUi.togglePause(); return true; }
                if (k === Qt.Key_Slash || (k === Qt.Key_F && (mods & Qt.ControlModifier))) {
                    MonitorUi.section = "processes";
                    Qt.callLater(() => { if (body.item && body.item.focusSearch) body.item.focusSearch(); });
                    return true;
                }
                if (k >= Qt.Key_1 && k <= Qt.Key_8) { MonitorUi.section = MonitorUi.sections[k - Qt.Key_1].id; return true; }
                if ((k === Qt.Key_Up || k === Qt.Key_Down) && MonitorUi.section === "processes" && body.item) {
                    body.item.stepSelection(k === Qt.Key_Up ? -1 : 1); return true;
                }
                return false;
            }
            Keys.onPressed: event => { if (keys.handle(event.key, event.modifiers)) event.accepted = true; }
        }

        // ---- cabecera (arrastre) -----------------------------------------------------------
        MouseArea {
            id: head
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 92 * win.s
            cursorShape: head.drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            drag.target: card
            drag.threshold: 2
            drag.minimumX: win.leftInset
            drag.maximumX: win.areaW - card.width - win.rightInset
            drag.minimumY: win.topInset
            drag.maximumY: win.areaH - card.height - win.bottomInset
            onPressed: keys.forceActiveFocus()
            onReleased: MonitorUi.remember(win.name, card.x, card.y)
        }
        Row {
            id: titleRow
            anchors.left: parent.left
            anchors.leftMargin: 20 * win.s
            y: 14 * win.s
            spacing: 16 * win.s
            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Metrics.sp2 * win.s
                Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 5 * win.s; height: 5 * win.s; radius: Metrics.pill(width); color: card.acc.accent }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "System Monitor"
                    color: Theme.fg
                    font.family: Typography.ui; font.pixelSize: Typography.display * win.s; font.weight: Typography.wStrong
                }
            }
            // Live / Paused: el estado siempre a la vista, y el botón que lo cambia al lado
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(statusLabel.implicitWidth + 33 * win.s, Math.max(90 * win.s, card.width - 330 * win.s))
                height: 28 * win.s
                radius: Metrics.pill(height)
                color: MonitorUi.paused ? Qt.alpha(Theme.warn, 0.14) : Qt.alpha(Theme.primary, 0.12)
                Row {
                    id: liveRow
                    anchors.centerIn: parent
                    width: parent.width - 20 * win.s; spacing: 6 * win.s
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 7 * win.s; height: 7 * win.s; radius: Metrics.pill(width)
                        color: MonitorUi.paused ? Theme.warn : Sysmon.error ? Theme.errorColor : Theme.primary
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        id: statusLabel
                        width: parent.width - 13 * win.s; elide: Text.ElideRight
                        text: MonitorUi.paused ? "Paused · " + Clock.fmt(MonitorUi.current.at, true)
                              : Sysmon.error ? Sysmon.error : MonitorUi.current ? "Live" : "Starting…"
                        color: MonitorUi.paused ? Theme.warn : Sysmon.error ? Theme.errorColor : Theme.primary
                        font.family: Typography.mono; font.pixelSize: Typography.label * win.s; font.weight: Typography.wStrong
                    }
                }
            }
        }
        Row {
            anchors.left: parent.left; anchors.leftMargin: 20 * win.s
            y: 54 * win.s
            ActionButton {
                anchors.verticalCenter: parent.verticalCenter
                s: win.s
                height: 30 * win.s
                glyph: MonitorUi.paused ? "play" : "pause"
                label: MonitorUi.paused ? "Resume live" : "Pause"
                enabled: MonitorUi.paused || !!Sysmon.current
                onTriggered: MonitorUi.togglePause()
            }
        }
        Row {
            anchors.right: parent.right
            anchors.rightMargin: 20 * win.s
            y: 58 * win.s
            spacing: 8 * win.s
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "History"
                color: Theme.fgVariant
                font.family: Typography.ui; font.pixelSize: Typography.caption * win.s
            }
            Choice {
                anchors.verticalCenter: parent.verticalCenter
                s: win.s
                name: "History window"
                options: MonitorUi.ranges.map(r => ({value: r.id, label: r.label}))
                value: MonitorUi.range
                onPicked: v => MonitorUi.range = v
            }
        }
        Rectangle {
            id: closeBtn
            anchors.right: parent.right
            anchors.rightMargin: 12 * win.s
            y: 14 * win.s
            width: 30 * win.s; height: 30 * win.s; radius: Metrics.pill(width)
            color: closeArea.containsMouse ? Theme.hoverBg : "transparent"
            Accessible.role: Accessible.Button
            Accessible.name: "Close System Monitor"
            Icon { anchors.centerIn: parent; name: "close"; size: 15 * win.s; color: closeArea.containsMouse ? Theme.fg : Theme.fgVariant }
            MouseArea { id: closeArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: MonitorUi.close() }
        }
        Rectangle {
            id: rule
            anchors.top: head.bottom
            anchors.left: parent.left; anchors.right: parent.right
            anchors.leftMargin: 20 * win.s; anchors.rightMargin: 20 * win.s
            height: 1
            color: Theme.hair
        }

        // ---- barra lateral --------------------------------------------------------------------
        /**
         * La marca de la sección elegida es UNA pieza que se desliza a la nueva (2026-10-01): antes
         * cada entrada pintaba su fondo y el cambio era un salto. Va debajo de las entradas.
         */
        Flickable {
            id: sideView
            anchors.top: rule.bottom; anchors.topMargin: 12 * win.s
            anchors.bottom: footer.top; anchors.bottomMargin: 8 * win.s
            anchors.left: parent.left; anchors.leftMargin: 12 * win.s
            width: (card.width / win.s < 800 ? 132 : Metrics.monSideW) * win.s
            clip: true; contentWidth: width; contentHeight: side.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            function reveal() {
                const y = sideMark.at * 46 * win.s, bottom = y + 44 * win.s;
                if (y < contentY) contentY = y;
                else if (bottom > contentY + height) contentY = Math.min(bottom - height, Math.max(0, contentHeight - height));
            }
            onHeightChanged: Qt.callLater(reveal)
            Connections { target: MonitorUi; function onSectionChanged() { Qt.callLater(sideView.reveal); } }
            Rectangle {
                id: sideMark
                readonly property int at: Math.max(0, MonitorUi.sections.findIndex(x => x.id === MonitorUi.section))
                x: 0
                y: sideMark.at * (44 + 2) * win.s
                width: side.width
                height: 44 * win.s
                radius: Metrics.rSm * win.s
                color: card.acc.sel
                Behavior on color { ColorAnimation { duration: Motion.fast } }
                Behavior on y { NumberAnimation { duration: Motion.still ? 0 : Motion.page; easing.type: Easing.OutCubic } }
                Rectangle {   // el filo de acento, a la izquierda
                    x: 0; anchors.verticalCenter: parent.verticalCenter
                    width: 3 * win.s; height: parent.height * 0.5; radius: Metrics.pill(width)
                    color: card.acc.fill
                }
            }
            Column {
                id: side
                width: sideView.width
                spacing: 2 * win.s
                Repeater {
                    model: MonitorUi.sections
                    Rectangle {
                        id: entry
                        required property var modelData
                        required property int index
                        readonly property bool current: MonitorUi.section === entry.modelData.id
                        readonly property string alert: win.alertDomains[entry.modelData.id] || ""
                        width: side.width
                        height: 44 * win.s
                        radius: Metrics.rSm * win.s
                        color: !entry.current && entryArea.containsMouse ? Theme.hoverBg : "transparent"
                        Behavior on color { ColorAnimation { duration: Motion.fast } }
                        Accessible.role: Accessible.PageTab
                        Accessible.name: entry.modelData.label
                        Accessible.selected: entry.current
                        Text {
                            x: 12 * win.s; y: val.text ? 5 * win.s : (parent.height - height) / 2
                            width: parent.width - 24 * win.s; elide: Text.ElideRight
                            text: entry.modelData.label
                            color: entry.current ? Theme.famNamed(Zones.of(entry.modelData.id)).text : Theme.fgVariant
                            font.family: Typography.ui; font.pixelSize: Typography.body * win.s
                            font.weight: entry.current ? Typography.wStrong : Typography.wNormal
                        }
                        Rectangle {
                            visible: entry.alert !== ""
                            anchors.right: parent.right; anchors.rightMargin: 8 * win.s; y: 10 * win.s
                            width: 6 * win.s; height: 6 * win.s; radius: Metrics.r(3) * win.s
                            color: entry.alert === "critical" ? Theme.errorColor : Theme.warn
                        }
                        Text {
                            id: val
                            x: 12 * win.s; y: 24 * win.s; width: parent.width - 24 * win.s; elide: Text.ElideRight
                            text: win.sideValue(entry.modelData.id)
                            color: Theme.famNamed(Zones.of(entry.modelData.id)).text   // el valor, en el color de su sección
                            font.family: Typography.mono; font.pixelSize: Typography.caption * win.s
                        }
                        MouseArea { id: entryArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { MonitorUi.section = entry.modelData.id; keys.forceActiveFocus(); } }
                    }
                }
                Item { width: 1; height: 10 * win.s }
                Text {
                    width: side.width - 12 * win.s
                    x: 12 * win.s
                    wrapMode: Text.Wrap
                    text: "1–8 sections · Space pause · / search · Esc close"
                    color: Theme.fgVariant
                    opacity: 0.8
                    font.family: Typography.ui; font.pixelSize: Typography.caption * win.s
                }
            }
        }
        Rectangle {
            anchors.top: rule.bottom; anchors.bottom: footer.top
            anchors.topMargin: 12 * win.s; anchors.bottomMargin: 8 * win.s
            anchors.left: sideView.right; anchors.leftMargin: 12 * win.s
            width: 1
            color: Theme.hair
        }

        // ---- sección --------------------------------------------------------------------------
        Loader {
            id: body
            anchors.top: rule.bottom
            anchors.topMargin: 14 * win.s
            anchors.left: sideView.right
            anchors.leftMargin: 26 * win.s
            anchors.right: parent.right
            anchors.rightMargin: 20 * win.s
            anchors.bottom: footer.top
            anchors.bottomMargin: 8 * win.s
            // cerrada (y ya desvanecida) no hay sección: nada calcula para una vista que no existe
            active: win.shown || card.appear > 0.001
            sourceComponent: ({overview: overviewC, cpu: cpuC, gpu: gpuC, memory: memoryC, processes: processesC,
                               disks: disksC, network: networkC, sensors: sensorsC})[MonitorUi.section] || overviewC
            property real pageOffset: 0
            property real pageOpacity: 1
            opacity: pageOpacity
            transform: Translate { x: body.pageOffset }
            // Dirección (2026-11-11): bajar en la lista entra desde la derecha, subir desde la izquierda; con Normal, la
            // primera sección llega con la ventana sin deslizarse. Reduced/Off, como siempre (sin desplazamiento).
            property string shownSection: ""
            onActiveChanged: if (!active) body.shownSection = ""
            onLoaded: {
                const prev = body.shownSection, next = MonitorUi.section;
                body.shownSection = next;
                const interrupted = pageEnter.running;
                pageEnter.stop();
                if (prev === "" && !interrupted && !Motion.still) { body.pageOffset = 0; body.pageOpacity = 1; return; }
                // con Interference (terminal, 2026-11-15) la estática ES la transición: ni desplazamiento ni fundido;
                // apagada, vuelve el desplazamiento de siempre (a petición del autor: no sumar los dos movimientos)
                if (Style.fx.glitch !== "off") { body.pageOffset = 0; body.pageOpacity = 1; return; }
                const ids = MonitorUi.sections.map(x => x.id);
                const dir = prev === "" || ids.indexOf(next) >= ids.indexOf(prev) ? 1 : -1;
                const shift = Motion.pageShift * win.s;
                body.pageOffset = Motion.still ? 0 : interrupted ? Math.max(-shift, Math.min(shift, body.pageOffset)) : dir * shift;
                body.pageOpacity = Motion.off ? 1 : interrupted ? Math.max(Motion.pageFadeFrom, body.pageOpacity) : Motion.pageFadeFrom;
                pageEnter.start();
            }
            Connections {
                target: Motion
                function onModeChanged() { pageEnter.stop(); body.pageOffset = 0; body.pageOpacity = 1; }
            }
            ParallelAnimation {
                id: pageEnter
                NumberAnimation { target: body; property: "pageOffset"; to: 0; duration: Motion.still ? 0 : Motion.pageMs; easing.type: Easing.OutCubic }
                NumberAnimation { target: body; property: "pageOpacity"; to: 1; duration: Motion.pageMs; easing.type: Easing.OutCubic }
            }
        }
        Component { id: overviewC; MonitorOverview { s: win.s } }
        Component { id: cpuC; MonitorCpu { s: win.s } }
        Component { id: gpuC; MonitorGpu { s: win.s } }
        Component { id: memoryC; MonitorMemory { s: win.s } }
        Component { id: processesC; MonitorProcesses { s: win.s } }
        Component { id: disksC; MonitorDisks { s: win.s } }
        Component { id: networkC; MonitorNetwork { s: win.s } }
        Component { id: sensorsC; MonitorSensors { s: win.s } }
        // hijo del Loader (hermano de la sección): sólo así puede anclarse a ella
        ScrollHint { parent: body; view: body.item && body.item.contentHeight !== undefined ? body.item : null; s: win.s }

        // ---- pie: estado ----------------------------------------------------------------------
        Text {
            id: footer
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 10 * win.s
            anchors.left: parent.left; anchors.right: parent.right
            anchors.leftMargin: 20 * win.s; anchors.rightMargin: 20 * win.s
            elide: Text.ElideRight
            text: {
                const c = MonitorUi.current;
                if (!c) return Sysmon.error || "Waiting for the first sample…";
                const crit = MonitorUi.alerts.filter(a => a.level === "critical").length, warn = MonitorUi.alerts.length - crit;
                return (MonitorUi.paused ? "Paused at " : "Updated ") + Clock.fmt(c.at, true)
                    + "  ·  " + (crit ? crit + " critical" + (warn ? ", " + warn + " warnings" : "") : warn ? warn + (warn === 1 ? " warning" : " warnings") : "No anomalies")
                    + (MonitorUi.warmingUp ? "  ·  " + MonitorUi.ranges.find(r => r.id === MonitorUi.range).label + " window filling (" + Monitor.duration(MonitorUi.coveredMs / 1000) + " so far; history starts when a monitor view opens)" : "")
                    + (MonitorUi.paused ? "  ·  sampling continues in the background" : "");
            }
            color: MonitorUi.alerts.some(a => a.level === "critical") ? Theme.errorColor : MonitorUi.alerts.length ? Theme.warn : Theme.fgVariant
            font.family: Typography.ui; font.pixelSize: Typography.caption * win.s
        }
        // interferencia de terminal (2026-11-15): al abrir y al cambiar de vista; encima de todo (z), sin
        // recibir clics. Último hijo de la tarjeta: no corre los índices de los demás
        Interference { anchors.fill: parent; s: win.s; open: win.shown; key: MonitorUi.section }
    }
}
