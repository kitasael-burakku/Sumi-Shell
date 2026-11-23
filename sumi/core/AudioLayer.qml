pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import "../theme"
import "../services"
import "../components"
import "../lib/accent-zones.js" as Zones

/**
 * La Audio UI (antes de la fase 14, `rediseno/Antes-de-fase-14.md`): el espacio de configuración del
 * audio. La surface del Mixer es el control remoto (lo que suena, volumen, dispositivo, apps y un
 * resumen del EQ); aquí va lo que pide precisión o comparación: el ecualizador entero, balance y
 * canales, dispositivos con su perfil y puertos, y las aplicaciones con detalle.
 *
 * Misma forma que la UI de System Monitor (capa del shell, tarjeta flotante que se arrastra por la
 * cabecera, una instancia en `AudioUi`, fuera de Alt+Tab). Super+Shift+A (decisión del usuario,
 * 2026-09-28). Sólo la sección visible está instanciada; cerrada, ninguna.
 *
 * Teclado (lo da el compositor al pulsar dentro, `OnDemand`): 1–6 secciones, ↑↓ recorren los
 * controles, ←→ ajustan, Enter/Espacio activan, Esc cierra.
 */
PanelWindow {
    id: win

    required property var targetScreen
    readonly property string name: win.targetScreen ? win.targetScreen.name : ""
    readonly property real s: Settings.uiScale
    readonly property bool shown: AudioUi.open && AudioUi.screen === win.name && !Lock.engaged
    readonly property real margin: Metrics.storeMargin * win.s
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
    WlrLayershell.namespace: "sumi-audio"
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
        const p = AudioUi.positionOf(win.name);
        card.x = win.clampX(p ? p.x : (win.areaW - card.width) / 2);
        card.y = win.clampY(p ? p.y : (win.areaH - card.height) / 2);
    }
    function placeAt(x, y) {
        card.x = win.clampX(x);
        card.y = win.clampY(y);
        AudioUi.remember(win.name, card.x, card.y);
        return true;
    }
    /** El mismo manejo que una tecla real; para IPC (`audioUiKey`), sin inyectar nada al compositor. */
    function key(name) {
        const map = {Escape: Qt.Key_Escape, Space: Qt.Key_Space, Return: Qt.Key_Return, Up: Qt.Key_Up, Down: Qt.Key_Down,
                     Left: Qt.Key_Left, Right: Qt.Key_Right, Tab: Qt.Key_Tab};
        const k = map[name] || (/^[1-6]$/.test(name) ? Qt.Key_1 + Number(name) - 1 : 0);
        return k ? keys.handle(k, 0, false) : false;
    }
    function focusInfo() {
        const it = body.item;
        return {section: AudioUi.section, focus: it ? it.focusId : "", list: it ? it.focusList : [], keyNav: AudioUi.keyNav};
    }
    function geometry() {
        return {screen: win.name, shown: win.shown, x: Math.round(card.x), y: Math.round(card.y),
                w: Math.round(card.width), h: Math.round(card.height), screenW: Math.round(win.areaW), screenH: Math.round(win.areaH),
                dragging: head.drag.active, appear: Math.round(card.appear * 100) / 100,
                loaded: body.status === Loader.Ready ? AudioUi.section : "", sideW: Math.round(side.width)};
    }

    onShownChanged: if (win.shown) { win.place(); keys.forceActiveFocus(); }
    onAreaWChanged: if (win.shown) win.place()
    onAreaHChanged: if (win.shown) win.place()
    Component.onCompleted: AudioUi.layer = win
    Component.onDestruction: if (AudioUi.layer === win) AudioUi.layer = null

    // ---- lo que dice la barra lateral de cada sección ---------------------------------------
    readonly property var sink: Mixer.defaultSink
    readonly property var source: Mixer.defaultSource
    function levelOf(n) {
        if (!n) return "—";
        if (!n.audio) return "";
        return Mixer.shownMuted(n) ? "muted" : Math.round(Mixer.shownVolume(n) * 100) + " %";
    }
    readonly property var eqNow: {
        void Equalizer.profiles;
        void Equalizer.ops.table;
        const d = AudioUi.defaultSinkName;
        return d.length > 0 ? {st: Equalizer.stateOf(d).state, v: Equalizer.view(d)} : null;
    }
    function sideValue(id) {
        if (id === "output") return win.levelOf(win.sink);
        if (id === "input") return win.levelOf(win.source);
        if (id === "applications") return String(Mixer.playback.length + Mixer.capture.length);
        if (id === "equalizer") {
            const e = win.eqNow;
            if (!e) return "";
            if (e.st === "failed") return "error";
            return e.v.enabled ? "on" : "off";
        }
        if (id === "devices") return AudioDevices.loaded ? String(AudioDevices.cards.length) : "";
        return "";
    }
    function sideWarn(id) {
        if (id === "equalizer") return !!win.eqNow && win.eqNow.st === "failed";
        if (id === "input") return Mixer.capture.length > 0;
        return false;
    }

    Item {
        id: card
        /** La sección elegida tiñe la ventana con su color (lib/accent-zones.js): salida, entrada, apps… */
        palette.accent: Theme.zone(Zones.of(AudioUi.section))
        readonly property var acc: Theme.fam(palette.accent)
        width: Math.min(Metrics.audioW * win.s, win.areaW - win.leftInset - win.rightInset)
        height: Math.max(0, Math.min(Metrics.audioH * win.s, win.areaH - win.topInset - win.bottomInset))
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
            surface: "audio"
            shadowed: !head.drag.active
        }

        Item {
            id: keys
            anchors.fill: parent
            focus: true
            function handle(k, mods, auto) {
                const it = body.item;
                if (k === Qt.Key_Escape) { AudioUi.close(); return true; }
                if (k >= Qt.Key_1 && k <= Qt.Key_6 && AudioUi.sections[k - Qt.Key_1]) {
                    AudioUi.section = AudioUi.sections[k - Qt.Key_1].id; return true;
                }
                if (!it) return false;
                if (k === Qt.Key_Up || k === Qt.Key_Backtab || (k === Qt.Key_Tab && (mods & Qt.ShiftModifier))) {
                    AudioUi.keyNav = true; return it.step(-1);
                }
                if (k === Qt.Key_Down || k === Qt.Key_Tab) { AudioUi.keyNav = true; return it.step(1); }
                if (k === Qt.Key_Left || k === Qt.Key_Right) {
                    AudioUi.keyNav = true;
                    if (it.focusId) it.activate(it.focusId, k === Qt.Key_Left ? -1 : 1);
                    return true;
                }
                if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) {
                    AudioUi.keyNav = true;
                    if (!auto && it.focusId) it.activate(it.focusId, 0);
                    return true;
                }
                return false;
            }
            Keys.onPressed: event => { if (keys.handle(event.key, event.modifiers, event.isAutoRepeat)) event.accepted = true; }
        }

        // ---- cabecera (arrastre) -----------------------------------------------------------
        MouseArea {
            id: head
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 60 * win.s
            cursorShape: head.drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            drag.target: card
            drag.threshold: 2
            drag.minimumX: win.leftInset
            drag.maximumX: win.areaW - card.width - win.rightInset
            drag.minimumY: win.topInset
            drag.maximumY: win.areaH - card.height - win.bottomInset
            onPressed: keys.forceActiveFocus()
            onReleased: AudioUi.remember(win.name, card.x, card.y)
        }
        Row {
            anchors.left: parent.left
            anchors.leftMargin: 20 * win.s
            anchors.verticalCenter: head.verticalCenter
            spacing: 16 * win.s
            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Metrics.sp2 * win.s
                Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 5 * win.s; height: 5 * win.s; radius: Metrics.pill(width); color: card.acc.accent }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Audio"
                    color: Theme.fg
                    font.family: Typography.ui; font.pixelSize: Typography.display * win.s; font.weight: Typography.wStrong
                }
            }
            // la salida que suena, siempre a la vista
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(outLabel.implicitWidth + 44 * win.s, Math.max(80 * win.s, card.width - 190 * win.s))
                height: 30 * win.s
                radius: Metrics.pill(height)
                color: win.sink ? Theme.famNamed(Zones.of("output")).sel : Qt.alpha(Theme.warn, 0.14)
                Row {
                    id: outRow
                    width: parent.width - 20 * win.s
                    anchors.centerIn: parent
                    spacing: 6 * win.s
                    Icon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: win.sink && !Mixer.shownMuted(win.sink) ? "volume-high" : "volume-off"
                        size: 12 * win.s
                        color: win.sink ? Theme.famNamed(Zones.of("output")).text : Theme.warn
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        id: outLabel
                        width: parent.width - 18 * win.s; elide: Text.ElideRight
                        text: win.sink ? Mixer.shortLabel(win.sink) + " · " + win.levelOf(win.sink) : "No output device"
                        color: win.sink ? Theme.famNamed(Zones.of("output")).text : Theme.warn
                        font.family: Typography.mono; font.pixelSize: Typography.label * win.s; font.weight: Typography.wStrong
                    }
                }
            }
        }
        Rectangle {
            id: closeBtn
            anchors.right: parent.right
            anchors.rightMargin: 12 * win.s
            anchors.verticalCenter: head.verticalCenter
            width: 32 * win.s; height: 32 * win.s; radius: Metrics.pill(width)
            color: closeArea.containsMouse ? Theme.hoverBg : "transparent"
            Accessible.role: Accessible.Button
            Accessible.name: "Close Audio"
            Icon { anchors.centerIn: parent; name: "close"; size: 15 * win.s; color: closeArea.containsMouse ? Theme.fg : Theme.fgVariant }
            MouseArea { id: closeArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: AudioUi.close() }
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
            width: (card.width / win.s < 800 ? 132 : Metrics.audioSideW) * win.s
            contentWidth: width; contentHeight: side.implicitHeight; clip: true
            boundsBehavior: Flickable.StopAtBounds
            function reveal() {
                const y = sideMark.at * 46 * win.s, bottom = y + 44 * win.s;
                if (y < contentY) contentY = y;
                else if (bottom > contentY + height) contentY = Math.min(bottom - height, Math.max(0, contentHeight - height));
            }
            onHeightChanged: Qt.callLater(reveal)
            Connections { target: AudioUi; function onSectionChanged() { Qt.callLater(sideView.reveal); } }
            Rectangle {
                id: sideMark
                readonly property int at: Math.max(0, AudioUi.sections.findIndex(x => x.id === AudioUi.section))
                x: 0
                y: sideMark.at * 46 * win.s
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
                    model: AudioUi.sections
                    Rectangle {
                        id: entry
                        required property var modelData
                        readonly property bool current: AudioUi.section === entry.modelData.id
                        readonly property bool warn: win.sideWarn(entry.modelData.id)
                        width: side.width
                        height: 44 * win.s
                        radius: Metrics.rSm * win.s
                        color: !entry.current && entryArea.containsMouse ? Theme.hoverBg : "transparent"
                        Behavior on color { ColorAnimation { duration: Motion.fast } }
                        Accessible.role: Accessible.PageTab
                        Accessible.name: entry.modelData.label
                        Accessible.selected: entry.current
                        Text {
                            x: 12 * win.s; y: sideVal.text ? 5 * win.s : (parent.height - height) / 2
                            width: parent.width - 24 * win.s; elide: Text.ElideRight
                            text: entry.modelData.label
                            color: entry.current ? Theme.famNamed(Zones.of(entry.modelData.id)).text : Theme.fgVariant
                            font.family: Typography.ui; font.pixelSize: Typography.body * win.s
                            font.weight: entry.current ? Typography.wStrong : Typography.wNormal
                        }
                        Text {
                            id: sideVal
                            x: 12 * win.s; y: 24 * win.s; width: parent.width - 24 * win.s; elide: Text.ElideRight
                            text: win.sideValue(entry.modelData.id)
                            color: entry.warn ? (entry.modelData.id === "input" ? Theme.errorColor : Theme.warn) : Theme.famNamed(Zones.of(entry.modelData.id)).text
                            font.family: Typography.mono; font.pixelSize: Typography.caption * win.s
                        }
                        MouseArea {
                            id: entryArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { AudioUi.section = entry.modelData.id; keys.forceActiveFocus(); }
                        }
                    }
                }
                Item { width: 1; height: 10 * win.s }
                Text {
                    width: side.width - 12 * win.s
                    x: 12 * win.s
                    wrapMode: Text.Wrap
                    text: "1–6 sections · ↑↓ move · ←→ adjust · Enter select · Esc close"
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
            sourceComponent: ({overview: overviewC, output: outputC, input: inputC, applications: appsC,
                               equalizer: eqC, devices: devicesC})[AudioUi.section] || overviewC
            property real pageOffset: 0
            property real pageOpacity: 1
            opacity: pageOpacity
            transform: Translate { x: body.pageOffset }
            // Dirección (2026-11-11): bajar en la lista entra desde la derecha, subir desde la izquierda; con Normal, la
            // primera sección llega con la ventana sin deslizarse. Reduced/Off, como siempre (sin desplazamiento).
            property string shownSection: ""
            onActiveChanged: if (!active) body.shownSection = ""
            onLoaded: {
                const prev = body.shownSection, next = AudioUi.section;
                body.shownSection = next;
                const interrupted = pageEnter.running;
                pageEnter.stop();
                if (prev === "" && !interrupted && !Motion.still) { body.pageOffset = 0; body.pageOpacity = 1; return; }
                // con Interference (terminal, 2026-11-15) la estática ES la transición: ni desplazamiento ni fundido;
                // apagada, vuelve el desplazamiento de siempre (a petición del autor: no sumar los dos movimientos)
                if (Style.fx.glitch !== "off") { body.pageOffset = 0; body.pageOpacity = 1; return; }
                const ids = AudioUi.sections.map(x => x.id);
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
        Component { id: overviewC; AudioOverview { s: win.s } }
        Component { id: outputC; AudioOutput { s: win.s } }
        Component { id: inputC; AudioInput { s: win.s } }
        Component { id: appsC; AudioApplications { s: win.s } }
        Component { id: eqC; AudioEqualizer { s: win.s } }
        Component { id: devicesC; AudioCards { s: win.s } }
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
                const p = Mixer.playback.length, r = Mixer.capture.length;
                const e = win.eqNow;
                const eq = !e ? "" : e.st === "failed" ? "Equalizer couldn't start"
                    : e.st === "unavailable" ? "Equalizer unavailable"
                    : e.st === "loading" ? "" : "Equalizer " + (e.v.enabled ? "on · " + Equalizer.presetName(e.v.preset) : "off");
                return [p + " playing", r + " recording", eq, Equalizer.saving ? "saving the equalizer…" : "changes apply immediately"]
                    .filter(x => x.length > 0).join("  ·  ");
            }
            color: Theme.fgVariant
            font.family: Typography.ui; font.pixelSize: Typography.caption * win.s
        }
        // interferencia de terminal (2026-11-15): al abrir y al cambiar de vista; encima de todo (z), sin
        // recibir clics. Último hijo de la tarjeta: no corre los índices de los demás
        Interference { anchors.fill: parent; s: win.s; open: win.shown; key: AudioUi.section }
    }
}
