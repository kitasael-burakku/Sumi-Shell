pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Widgets
import "../theme"
import "../services"
import "../components"
import "../lib/accent-zones.js" as Zones

/**
 * Audio Mixer + Media Player — la surface ÚNICA de reproducción y audio (rediseño, 9E-1;
 * rediseno/docs/futureAudio-Mixersurface.md, futureMedia-playersurface.md).
 *
 * Orden acordado: **reproducción → salida → ecualizador → entrada → aplicaciones**, en un
 * solo scroll. `media` ya no es otra surface: es un ALIAS de `mixer` (Screens.canonical), así
 * que Super+Ctrl+M, Super+A, el círculo de Música, la cara hover, la barra y el IPC llegan
 * aquí. Lo único que cambia según por dónde se llegue es el foco inicial: por `media`, el
 * transporte; por `mixer`, el volumen de salida (la pista la deja Screen en `sel`).
 *
 * Antes de la fase 14 (`rediseno/Antes-de-fase-14.md`): la surface es el CONTROL INMEDIATO y la
 * configuración vive en la Audio UI (Super+Shift+A, `core/AudioLayer`). Del ecualizador queda una
 * fila: encenderlo o apagarlo, qué preset suena en la salida predeterminada y «Open ↗» (la UI en
 * Equalizer). Output e Input llevan «Details ↗» (la UI en su sección); la surface se cierra al abrirla.
 *
 * Applications empieza PLEGADO en cada apertura directa (Back lo recuerda). Resume «N playing ·
 * M recording» y, abierto, enseña cada flujo con su volumen, silencio y ruta; los que graban llevan
 * la etiqueta **Recording**.
 *
 * Teclado: ↑↓ recorren; ←→ ajustan (pista anterior/siguiente en el transporte, reproductor
 * en el selector, ±5 s en la barra, ±5 % en un volumen, dispositivo en un selector, EQ apagado /
 * encendido, pliegan y despliegan); Enter / Espacio activan (play/pausa, silencio, EQ, Open,
 * plegar); D → la Audio UI en la sección de lo enfocado; S → Settings · Audio.
 *
 * Sólo cuesta abierta: rastrear los nodos de PipeWire (Mixer) y la posición MPRIS (Media)
 * van por reclamaciones que se sueltan al cerrar.
 *
 * 2026-11-09 (pedido del usuario): apaisada, como la tira de Wallpaper. El reproductor a la izquierda
 * y la mezcla a la derecha (Output e Input lado a lado); en pantallas estrechas, una columna. El
 * progreso es un arco que rodea la portada por arriba y los tiempos van con el título. Fondo de
 * carátula, portada en disco y tiempo final son ajustes (System → Audio → Media player). El giro del
 * disco se probó y se retiró a petición del usuario. El orden de los focos no cambia.
 */
Surface {
    id: root

    mTop: Metrics.sp4
    mLeft: Metrics.sp4
    mRight: Metrics.sp4
    mBottom: Metrics.sp4

    Claim { target: Mixer; key: root.screenName.length > 0 ? "mixer@" + root.screenName : ""; value: root.active }
    /** La posición sólo avanza con alguien mirando (MPRIS no la anuncia; memoria del proyecto). */
    Claim { target: Media; key: root.screenName.length > 0 ? "media@" + root.screenName : ""; value: root.active }

    // ---- estado de la visita ------------------------------------------------------------

    property bool appsOpen: false
    property bool picking: false
    readonly property bool canPick: Media.pickable.length > 1
    onCanPickChanged: if (!root.canPick) root.picking = false

    /** El elemento con el foco del teclado, por id estable (no por índice). */
    property string focusId: "outVol"
    /** El puntero conserva selección y hover; el contorno se reserva al teclado. */
    property bool keyNav: false
    function pointerFocus(id) { root.keyNav = false; root.focusId = id; }

    readonly property var sink: Mixer.defaultSink
    readonly property var source: Mixer.defaultSource
    readonly property int playingCount: Mixer.playback.length
    readonly property int recordingCount: Mixer.capture.length

    /** Los focos que existen ahora, en orden visual. */
    readonly property var focusList: {
        const out = [];
        if (Media.has) {
            out.push("transport");
            if (root.canPick) out.push("picker");
            if (Media.canSeek && !Media.live) out.push("seek");
        }
        if (root.sink) out.push("outVol");
        if (Mixer.sinks.length > 1) out.push("outDev");
        if (root.eqDev.length > 0) out.push("eqOn", "eqUi");
        if (root.source) out.push("inVol");
        if (Mixer.sources.length > 1) out.push("inDev");
        out.push("apps");
        if (root.appsOpen) {
            for (let i = 0; i < Mixer.playback.length; i++) {
                const n = Mixer.playback[i];
                out.push("app:" + n.id);
                if (root.routeWanted(n)) out.push("route:" + n.id);
            }
            for (let i = 0; i < Mixer.capture.length; i++) {
                const n = Mixer.capture[i];
                out.push("app:" + n.id);
                if (root.routeWanted(n)) out.push("route:" + n.id);
            }
        }
        return out;
    }
    // Estrecha: el reproductor va arriba del scroll; con el foco en él, a la vista.
    onFocusIdChanged: if (!root.wide && ["transport", "picker", "seek"].indexOf(root.focusId) >= 0) flick.contentY = 0
    // Si lo enfocado desaparece (un flujo que termina), el foco pasa al más cercano que siga.
    onFocusListChanged: if (root.focusList.indexOf(root.focusId) < 0)
        root.focusId = root.focusList.indexOf("apps") >= 0 && root.focusId.startsWith("app:") ? "apps"
            : (root.focusList.length > 0 ? root.focusList[0] : "")

    /**
     * Apertura directa: plegables cerrados y el foco donde manda la entrada. La pista la pone
     * Screen al abrir (`sel` de esta pantalla: «playback» por `media`, «output» por `mixer`).
     * Volver por Back/Forward restaura después su propio contexto.
     */
    onOpenChanged: {
        if (!root.open) { root.picking = false; return; }
        root.appsOpen = false;
        root.picking = false;
        root.keyNav = false;
        const hint = root.host ? root.host.selOf("mixer") : "";
        root.focusId = hint === "playback" && Media.has ? "transport" : (root.sink ? "outVol" : "apps");
        flick.contentY = 0;
        // 13F: el enlace de Settings abre Applications desplegado con el foco en su cabecera (el
        // del Equalizer lleva desde antes de la fase 14 a la Audio UI, no aquí)
        if (hint === "apps") {
            root.appsOpen = true;
            root.focusId = hint;
            root.host.select("mixer", "output");   // la pista es de un solo uso
            Qt.callLater(() => root.reveal(appsHead));
        }
    }

    /**
     * El resumen del ecualizador (antes de la fase 14): el de la salida PREDETERMINADA, que es la que
     * suena. Editar bandas, presets, otra salida o Retry es de la Audio UI (`Open ↗`).
     */
    readonly property string eqDev: AudioUi.defaultSinkName
    readonly property string eqLabel: root.eqDev.length > 0 ? AudioRoutes.labelOf(root.eqDev) : ""
    readonly property var eqStatus: root.eqDev.length > 0 ? Equalizer.stateOf(root.eqDev) : ({ state: "none", reason: "" })
    readonly property var eqView: Equalizer.view(root.eqDev)
    readonly property string eqWord: {
        const st = root.eqStatus.state;
        if (st === "failed") return "Couldn't start";
        if (st === "starting") return "Starting…";
        if (st === "loading") return "…";
        return (root.eqView.enabled ? "On · " : "Off · ") + Equalizer.presetName(root.eqView.preset);
    }

    /** La Audio UI en esta pantalla y en esa sección; la surface le deja sitio (como System → Details). */
    function openAudio(section) {
        if (AudioUi.show(root.screenName, section || "overview")) root.requestClose();
    }
    /** D: la sección de la UI que corresponde a lo enfocado. */
    function sectionOf(id) {
        if (id === "outVol" || id === "outDev") return "output";
        if (id === "inVol" || id === "inDev") return "input";
        if (id === "apps" || id.startsWith("app:") || id.startsWith("route:")) return "applications";
        if (id === "eqOn" || id === "eqUi") return "equalizer";
        return "overview";
    }

    /** 9E-2, para el IPC: lo que enseña el fondo de la reproducción. */
    function backdropInfo() {
        return { showing: backdrop.showing, luminance: Math.round(backdrop.luminance * 100) / 100,
                 scrim: Math.round(backdrop.scrimAlpha * 100) / 100 };
    }

    function saveContext() {
        return { focus: root.focusId, apps: root.appsOpen, scroll: flick.contentY };
    }
    function restoreContext(ctx) {
        if (!ctx) return true;
        root.appsOpen = ctx.apps === true;
        const ok = root.focusList.indexOf(ctx.focus) >= 0;
        if (ok) root.focusId = ctx.focus;
        Qt.callLater(() => flick.contentY = Math.max(0, Math.min(ctx.scroll || 0, flick.contentHeight - flick.height)));
        return ok || !String(ctx.focus || "").startsWith("app:");
    }

    // ---- acciones -------------------------------------------------------------------

    function fmt(sec) {
        if (!(sec > 0)) return "0:00";
        const t = Math.floor(sec);
        const m = Math.floor(t / 60);
        const s = t % 60;
        return m + ":" + (s < 10 ? "0" + s : s);
    }
    function volGlyph(v, muted) {
        if (muted || v < 0.01) return "volume-off";
        if (v < 0.34) return "volume-low";
        if (v < 0.67) return "volume-mid";
        return "volume-high";
    }
    function nodeOf(id) {
        if (id === "outVol") return root.sink;
        if (id === "inVol") return root.source;
        if (id.startsWith("app:")) return Mixer.nodeById(parseInt(id.substring(4)));
        return null;
    }
    function cycleDevice(kind, dir) {
        const l = kind === "sink" ? Mixer.sinks : Mixer.sources;
        const cur = kind === "sink" ? root.sink : root.source;
        if (l.length < 2) return;
        const i = Math.max(0, l.indexOf(cur));
        const n = l[((i + dir) % l.length + l.length) % l.length];
        if (kind === "sink") Mixer.setDefaultSink(n); else Mixer.setDefaultSource(n);
    }
    // 13B/13C: el selector de ruta de cada app (antes de la fase 14, en AudioRoutes: lo comparte la Audio UI)
    function routeWanted(n) { return AudioRoutes.routeWanted(n); }
    function routeOptions(n) { return AudioRoutes.routeOptions(n); }
    function cycleRoute(n, dir) { AudioRoutes.cycleRoute(n, dir); }
    function retryRoute(n) { AudioRoutes.retryRoute(n); }
    function cyclePlayer(dir) {
        const l = Media.pickable;
        if (l.length < 2) return;
        const i = Math.max(0, l.indexOf(Media.active));
        Media.select(l[((i + dir) % l.length + l.length) % l.length]);
    }
    function seekBy(sec) {
        if (!Media.canSeek || !(Media.lengthSec > 0)) return;
        Media.seekTo(Math.max(0, Math.min(1, (Media.positionSec + sec) / Media.lengthSec)));
    }

    /** Un paso sobre el foco: dir −1/+1 (←/→), 0 = activar (Enter / Espacio). */
    function act(id, dir) {
        if (id === "transport") {
            if (dir === 0) Media.toggle(); else if (dir > 0) Media.next(); else Media.previous();
        } else if (id === "picker") {
            if (dir === 0) root.picking = !root.picking; else root.cyclePlayer(dir);
        } else if (id === "seek") {
            if (dir !== 0) root.seekBy(5 * dir);
        } else if (id === "outDev" || id === "inDev") {
            root.cycleDevice(id === "outDev" ? "sink" : "source", dir === 0 ? 1 : dir);
        } else if (id === "eqOn") {
            if (dir === 0) Equalizer.setEnabled(root.eqDev, !root.eqView.enabled);
            else Equalizer.setEnabled(root.eqDev, dir > 0);
        } else if (id === "eqUi") {
            if (dir === 0) root.openAudio("equalizer");
        } else if (id === "apps") {
            root.appsOpen = dir === 0 ? !root.appsOpen : dir > 0;
        } else if (id.startsWith("route:")) {
            const n = Mixer.nodeById(parseInt(id.substring(6)));
            if (!n) return;
            // 13F: con la fila en error, Enter repite lo último pedido (Retry)
            if (dir === 0 && AudioRoutes.rowStatus(n).state === "error") root.retryRoute(n);
            else root.cycleRoute(n, dir === 0 ? 1 : dir);
        } else {
            const n = root.nodeOf(id);
            if (!n) return;
            if (dir === 0) Mixer.toggleMute(n);
            else Mixer.setVolume(n, Mixer.shownVolume(n) + 0.05 * dir);
        }
    }

    function keyPressed(event) {
        const l = root.focusList;
        const i = l.indexOf(root.focusId);
        switch (event.key) {
        case Qt.Key_Up:    root.focusId = l[Math.max(0, i - 1)] || root.focusId; break;
        case Qt.Key_Down:  root.focusId = l[Math.min(l.length - 1, i + 1)] || root.focusId; break;
        // 16B: Tab/Mayús+Tab recorren como ↑/↓ (DESIGN §3); ←/→ siguen actuando dentro del control
        case Qt.Key_Tab:     root.focusId = l[Math.min(l.length - 1, i + 1)] || root.focusId; break;
        case Qt.Key_Backtab: root.focusId = l[Math.max(0, i - 1)] || root.focusId; break;
        case Qt.Key_Left:  root.act(root.focusId, -1); break;
        case Qt.Key_Right: root.act(root.focusId, 1); break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Space:
            if (!event.isAutoRepeat) root.act(root.focusId, 0);
            break;
        case Qt.Key_D:
            // antes de la fase 14: la Audio UI en la sección de lo enfocado
            if (!event.isAutoRepeat) root.openAudio(root.sectionOf(root.focusId));
            break;
        case Qt.Key_S:
            // 9D-2: S → Settings · System · Audio
            if (!event.isAutoRepeat && root.host) root.host.openSettingsAt("system/audio");
            break;
        default:
            return;
        }
        root.keyNav = true;
        event.accepted = true;
    }

    /** Lo enfocado, a la vista dentro del scroll. */
    function reveal(item) {
        if (!item || (!Motion.off && !root.settled)) return;
        const p = item.mapToItem(flick.contentItem, 0, 0);
        if (p.y < flick.contentY) flick.contentY = Math.max(0, p.y - 4 * root.s);
        else if (p.y + item.height > flick.contentY + flick.height)
            flick.contentY = Math.min(flick.contentHeight - flick.height, p.y + item.height + 4 * root.s - flick.height);
    }

    // ---- piezas -----------------------------------------------------------------------

    /** El contorno del foco del teclado (DESIGN §5: foco = contorno; hover = fondo tenue). */
    component FocusRing: Rectangle {
        property bool on: false
        anchors.fill: parent
        anchors.margins: -4 * root.s
        radius: Metrics.r(8) * root.s
        color: "transparent"
        border.width: on ? Metrics.focusWidth * root.s : 0
        border.color: Theme.selBorder
        visible: on && root.keyNav
    }

    /** Un rótulo con «Details ↗» a la derecha: la Audio UI en esa sección (antes de la fase 14). */
    component LinkHeading: Item {
        id: lh
        property string text: ""
        property string section: ""
        width: parent ? parent.width : 0
        height: lhText.implicitHeight
        Heading { id: lhText; text: lh.text }
        Text {
            anchors.right: parent.right
            anchors.bottom: lhText.bottom
            anchors.bottomMargin: lhText.bottomPadding
            text: "Details ↗"
            color: lhArea.containsMouse ? Theme.primary : Theme.fgVariant
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
            Accessible.role: Accessible.Link
            Accessible.name: "Open " + lh.text.toLowerCase() + " in Audio settings"
            MouseArea {
                id: lhArea
                anchors.fill: parent
                anchors.margins: -4 * root.s
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openAudio(lh.section)
            }
        }
    }

    component Heading: Text {
        color: Theme.fgVariant
        font.family: Typography.ui
        font.pixelSize: Typography.body * root.s
        font.weight: Typography.wStrong
        topPadding: Metrics.sp3 * root.s
        bottomPadding: 2 * root.s
    }

    /**
     * Una fila de volumen: icono de silencio, nombre, porcentaje y deslizador, y la ruta en su
     * propio renglón cuando la hay (QS-FUNC-011). Los flujos que graban llevan «Recording»:
     * no se distinguen sólo por estar atenuados (spec, «Estados y ciclo de vida»).
     */
    component Channel: Item {
        id: ch
        required property var node
        property string fid: ""
        property bool recording: false
        readonly property bool focused: root.focusId === ch.fid
        onFocusedChanged: if (ch.focused) root.reveal(ch)

        readonly property bool ready: !!ch.node && !!ch.node.audio
        readonly property real vol: ch.ready ? Mixer.shownVolume(ch.node) : 0
        readonly property bool muted: ch.ready ? Mixer.shownMuted(ch.node) : false
        readonly property bool failed: Mixer.failedOn(ch.node)
        readonly property string route: ch.node && ch.node.isStream ? Mixer.routeOf(ch.node) : ""
        readonly property bool routed: ch.route.length > 0

        width: parent ? parent.width : 0
        height: (ch.routed ? 90 : 76) * root.s

        Accessible.role: Accessible.Slider
        Accessible.name: Mixer.shortLabel(ch.node) + (ch.recording ? ", recording" : "")
        Accessible.description: !ch.ready ? "no volume control" : ch.muted ? "muted" : Math.round(ch.vol * 100) + " percent"
        Accessible.focusable: true
        Accessible.focused: ch.focused

        FocusRing { on: ch.focused }

        MouseArea {
            anchors.fill: parent
            onPressed: (m) => { root.pointerFocus(ch.fid); m.accepted = false; }
        }

        HoverHandler { id: channelHover }
        Rectangle {
            anchors.fill: parent; radius: Metrics.rSm * root.s; z: -1
            color: Theme.controlBg(Theme.tileBg, channelHover.hovered, false, false, Theme.fam(palette.accent))
            Behavior on color { ColorAnimation { duration: Motion.fast } }
        }
        Item {
            anchors.fill: parent; anchors.margins: 10 * root.s
            Icon {
                id: chIcon
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.topMargin: 1 * root.s
                name: root.volGlyph(ch.vol, ch.muted)
                size: 14 * root.s
                color: ch.muted ? Theme.errorColor : Theme.fgVariant
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4 * root.s
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.pointerFocus(ch.fid); Mixer.toggleMute(ch.node); }
                }
            }
            Text {
                id: chName
                anchors.left: chIcon.right
                anchors.leftMargin: 8 * root.s
                anchors.right: recTag.visible ? recTag.left : pct.left
                anchors.rightMargin: 8 * root.s
                anchors.top: parent.top
                text: Mixer.shortLabel(ch.node)
                color: Theme.fg
                font.family: Typography.ui
                font.pixelSize: Typography.body * root.s
                elide: Text.ElideRight
            }
            Rectangle {
                id: recTag
                visible: ch.recording
                anchors.right: pct.left
                anchors.rightMargin: 8 * root.s
                anchors.verticalCenter: chName.verticalCenter
                width: recText.implicitWidth + 10 * root.s
                height: recText.implicitHeight + 2 * root.s
                radius: Metrics.pill(height)
                color: Qt.alpha(Theme.errorColor, 0.18)
                Text {
                    id: recText
                    anchors.centerIn: parent
                    text: "Recording"
                    color: Theme.errorColor
                    font.family: Typography.ui
                    font.pixelSize: Typography.micro * root.s
                    font.weight: Typography.wStrong
                }
            }
            Text {
                anchors.left: chName.left
                anchors.right: parent.right
                anchors.top: chName.bottom
                anchors.topMargin: 1 * root.s
                visible: ch.routed
                text: (ch.node && ch.node.isSink ? "→ " : "← ") + ch.route
                color: Theme.fgVariant
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
                elide: Text.ElideRight
            }
            Text {
                id: pct
                anchors.right: parent.right
                anchors.top: parent.top
                // 13C: una entrada virtual no trae `audio` en Quickshell 0.3.1; «0 %» sería falso
                text: !ch.ready ? "—" : ch.failed ? "not applied" : ch.muted ? "muted" : Math.round(ch.vol * 100) + " %"
                color: ch.muted || ch.failed ? Theme.errorColor : Theme.fgVariant
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
                font.features: ({ "tnum": 1 })
            }
            Slider {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 4 * root.s
                s: root.s
                value: ch.vol
                muted: ch.muted
                // el foco lo marca el contorno de la fila entera; el del deslizador lo duplicaba
                label: Mixer.shortLabel(ch.node)
                onMoved: (v) => { root.pointerFocus(ch.fid); Mixer.setVolume(ch.node, v); }
            }
        }

    }

    /**
     * 13B/13C: a qué salida va ESTA app (o de qué entrada graba), bajo su fila. Pinta lo
     * pedido en vuelo y dice debajo lo que pasa: «Changing to X…» hasta que los enlaces lo
     * confirman, el error con la ruta que quedó, o la preferencia pendiente de un dispositivo
     * que no está. Una preferencia ausente no
     * marca ninguna pastilla: no se finge una selección que no rige.
     */
    component RouteChoice: Item {
        id: rc
        required property var node
        property string fid: ""
        readonly property var status: AudioRoutes.rowStatus(rc.node)
        readonly property bool focused: root.focusId === rc.fid
        onFocusedChanged: if (rc.focused) root.reveal(rc)
        width: parent ? parent.width : 0
        visible: root.routeWanted(rc.node)
        height: rcChoice.implicitHeight + (rcStatus.visible ? rcStatus.implicitHeight + 2 * root.s : 0) + 9 * root.s
        Accessible.role: Accessible.ComboBox
        Accessible.name: (rc.node && rc.node.isSink ? "Output for " : "Input for ") + Mixer.shortLabel(rc.node)
        Accessible.description: rcChoice.label + (rc.status.text.length > 0 ? ". " + rc.status.text : "")
        Accessible.focusable: true
        Accessible.focused: rc.focused
        FocusRing { on: rc.focused }
        Text {
            anchors.left: parent.left
            anchors.leftMargin: 22 * root.s
            anchors.verticalCenter: rcChoice.verticalCenter
            text: rc.node && rc.node.isSink ? "Output" : "Input"
            color: Theme.fgVariant
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }
        Choice {
            id: rcChoice
            anchors.right: parent.right
            optionMaxWidth: Math.max(60 * root.s, (width - Math.max(0, options.length - 1) * 3 * root.s) / Math.max(1, Math.min(4, options.length)))
            anchors.top: parent.top
            anchors.topMargin: 2 * root.s
            width: Math.max(0, parent.width - 80 * root.s)
            s: root.s
            // el foco lo marca el contorno de la fila (dos contornos a la vez, 9E-1)
            focused: false
            name: (rc.node && rc.node.isSink ? "Output for " : "Input for ") + Mixer.shortLabel(rc.node)
            options: root.routeOptions(rc.node)
            value: AudioRoutes.shownChoice(rc.node)
            onPicked: function (v) { root.pointerFocus(rc.fid); AudioRoutes.moveTo(rc.node, v); }
        }
        Text {
            id: rcStatus
            anchors.left: parent.left
            anchors.leftMargin: 22 * root.s
            anchors.right: parent.right
            anchors.top: rcChoice.bottom
            anchors.topMargin: 2 * root.s
            visible: text.length > 0
            text: rc.status.text + (rc.status.state === "error" ? " · Retry" : "")
            color: rc.status.state === "error" ? Theme.errorColor : Theme.fgVariant
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
            elide: Text.ElideRight
            MouseArea {
                anchors.fill: parent
                enabled: rc.status.state === "error"
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: { root.pointerFocus(rc.fid); root.retryRoute(rc.node); }
            }
        }
    }

    /** Un selector de dispositivo por defecto (salida o entrada); sólo con más de uno. */
    component DeviceChoice: Item {
        id: dc
        property string kind: "sink"
        property string fid: ""
        readonly property var list: dc.kind === "sink" ? Mixer.sinks : Mixer.sources
        readonly property var cur: dc.kind === "sink" ? root.sink : root.source
        width: parent ? parent.width : 0
        height: choice.implicitHeight + 4 * root.s
        visible: dc.list.length > 1
        FocusRing { on: root.focusId === dc.fid }
        Choice {
            id: choice
            width: parent.width
            optionMaxWidth: Math.max(60 * root.s, (width - Math.max(0, options.length - 1) * 3 * root.s) / Math.max(1, Math.min(4, options.length)))
            s: root.s
            focused: root.keyNav && root.focusId === dc.fid
            name: dc.kind === "sink" ? "Output device" : "Input device"
            // Se ENSEÑA el nombre corto y se IDENTIFICA por `node.name`, que es único.
            options: dc.list.map(n => ({ label: Mixer.shortLabel(n), value: String(n.name) }))
            value: Mixer.ops.shown(dc.kind, dc.cur ? String(dc.cur.name) : "")
            onPicked: function (v) {
                root.pointerFocus(dc.fid);
                for (const n of dc.list)
                    if (String(n.name) === String(v)) {
                        if (dc.kind === "sink") Mixer.setDefaultSink(n); else Mixer.setDefaultSource(n);
                        return;
                    }
            }
        }
    }

    // ---- dibujo -----------------------------------------------------------------------

    /**
     * Composición apaisada (2026-11-09, pedido del usuario; referencia: la tira de Wallpaper). A la
     * izquierda, el reproductor —carátula, metadatos, progreso y transporte— con su fondo; a la
     * derecha, la mezcla: Output e Input lado a lado, el resumen del EQ y Applications, con su propio
     * scroll. Por debajo de `Metrics.mixerWideMin` (pantalla estrecha o escala grande) vuelve a una
     * columna: el reproductor arriba y la mezcla debajo. Sólo cambia la composición: los focos, las
     * acciones y lo que se reclama a PipeWire/MPRIS son los de antes.
     */
    // Del ancho DESTINO (el del registro acotado a la pantalla), no de `width`: el alto depende de
    // esto y el marco del host sale de los dos (leer `width` aquí era un bucle de bindings).
    readonly property real targetW: Math.min(Metrics.mixerW * root.s, root.host ? root.host.maxW : Infinity)
        - (root.mLeft + root.mRight) * root.s
    readonly property bool wide: root.targetW >= Metrics.mixerWideMin * root.s
    readonly property real gutter: Metrics.sp4 * root.s
    /** Alto natural del reproductor: portada con su arco/metadatos y transporte, con su aire. */
    readonly property real playerH: Media.has ? playback.headerH + 84 * root.s : 64 * root.s
    implicitHeight: root.wide
        ? Math.max(root.playerH, Math.min(col.implicitHeight, Metrics.mixerMaxH * root.s))
        : root.playerH + root.gutter + col.implicitHeight

    /** Ajustes del reproductor (Settings → System → Audio → Media player): fondo, forma y tiempo final. */
    // en terminal no hay disco (no hay nada redondo): la portada es la de siempre, cuadrada (F6, ADR-34)
    readonly property bool disc: Settings.mediaCoverShape === "disc" && !Style.terminal

    /**
     * El progreso rodea la portada por ARRIBA (2026-11-09, pedido del usuario): sale de la mitad del
     * lado izquierdo, pasa por encima y acaba en la mitad del derecho, ceñido al disco (semicírculo) o al
     * cuadro (sus lados y esquinas redondeadas). `arcAt(t)` da el punto a la fracción t de LONGITUD del
     * recorrido, en coordenadas del bloque `seekRow`; el dibujo y el clic salen de la misma función.
     */
    readonly property real coverSize: (root.wide ? 112 : 96) * root.s
    readonly property real arcStroke: 5 * root.s
    /** Distancia del recorrido al borde de la portada, y margen del bloque (cabe el indicador de 12). */
    readonly property real arcOff: 5 * root.s + root.arcStroke / 2
    readonly property real arcExt: root.arcOff + 6 * root.s
    readonly property int arcSamples: 96
    function arcAt(t) {
        const C = root.coverSize, o = root.arcOff, e = root.arcExt;
        const cx = e + C / 2, cy = e + C / 2;
        t = Math.max(0, Math.min(1, t));
        if (root.disc) {
            const r = C / 2 + o, a = Math.PI * (1 + t);
            return Qt.point(cx + r * Math.cos(a), cy + r * Math.sin(a));
        }
        // terminal: esquinas rectas (Metrics.r da 0,01; sin el desfase, el recorrido ciñe un cuadrado)
        const h = C / 2 + o, rc = Math.min(h, Metrics.r(12) * root.s + (Style.terminal ? 0 : o));
        const a = h - rc, b = Math.PI * rc / 2, c = 2 * (h - rc);
        let d = t * (2 * a + 2 * b + c);
        if (d <= a) return Qt.point(cx - h, cy - d);
        d -= a;
        if (d <= b) { const g = Math.PI + d / rc; return Qt.point(cx - h + rc + rc * Math.cos(g), cy - h + rc + rc * Math.sin(g)); }
        d -= b;
        if (d <= c) return Qt.point(cx - h + rc + d, cy - h);
        d -= c;
        if (d <= b) { const g = 1.5 * Math.PI + d / rc; return Qt.point(cx + h - rc + rc * Math.cos(g), cy - h + rc + rc * Math.sin(g)); }
        d -= b;
        return Qt.point(cx + h, cy - h + rc + d);
    }
    /** El recorrido de 0 a f, en puntos (para `PathPolyline`). */
    function arcPath(f) {
        const n = Math.ceil(Math.max(0, Math.min(1, f)) * root.arcSamples);
        const pts = [];
        for (let i = 0; i < n; i++) pts.push(root.arcAt(i / root.arcSamples));
        pts.push(root.arcAt(f));
        if (pts.length < 2) pts.push(root.arcAt(f));
        return pts;
    }
    /** La fracción más cercana a (x, y) del bloque y a qué distancia queda del recorrido. */
    function arcNearest(x, y) {
        let best = 0, bd = Infinity;
        for (let i = 0; i <= root.arcSamples; i++) {
            const p = root.arcAt(i / root.arcSamples);
            const d = Math.hypot(p.x - x, p.y - y);
            if (d < bd) { bd = d; best = i / root.arcSamples; }
        }
        return { t: best, d: bd };
    }
    /** Para el banco: un punto del arco en coordenadas de la ventana. */
    function arcGlobal(t) {
        const p = root.arcAt(t);
        const g = seekRow.mapToItem(null, p.x, p.y);
        return { x: g.x, y: g.y };
    }

    // ---- 1. reproducción ---------------------------------------------------------------

    /**
     * Apaisada: a la izquierda, quieto. Estrecha: dentro del scroll, encima de la mezcla (el `parent`
     * cambia con la composición), para que una pantalla baja recorra todo como antes y no deje a la
     * mezcla una rendija.
     */
    Item {
        id: playerPane
        // el reproductor y la mezcla, cada uno con su color (lib/accent-zones.js)
        palette.accent: Theme.zone(Zones.of("player"))
        parent: root.wide ? root : flick.contentItem
        x: 0
        y: 0
        width: root.wide ? Metrics.mixerPlayerW * root.s : flick.width
        height: root.wide ? root.height : root.playerH

        /**
         * La zona de reproducción: la tarjeta de Media Player de antes, con la carátula de fondo
         * (9E-2, `CoverBackdrop`) si Settings lo pide: ampliada, desenfocada y con un velo según su
         * claridad; sin carátula o con «Theme», el fondo del tema. SÓLO esta zona: la mezcla y el EQ
         * conservan el fondo normal. Sin reproducción, un estado breve.
         */
        ClippingRectangle {
            id: playback
            anchors.fill: parent
            // Portada con su arco/metadatos y transporte; centrados si la mezcla hace la tarjeta más alta.
            readonly property real headerH: Math.max(seekRow.height, info.implicitHeight)
            readonly property real blockTop: Math.max(Metrics.sp4 * root.s, (playback.height - playback.headerH - 52 * root.s) / 2)
            radius: Metrics.rMd * root.s
            color: Theme.raisedBg

            CoverBackdrop {
                id: backdrop
                anchors.fill: parent
                s: root.s
                source: Media.has && Settings.mediaBackdrop === "cover" ? Media.artUrl : ""
            }

            /**
             * Sobre la carátula el fondo SIEMPRE es oscuro (el velo lo garantiza), así que el texto no
             * puede tomar los colores del tema (2026-10-01, captura del usuario: en claro, artista y
             * reproductor salían gris oscuro sobre la carátula oscurecida, ilegibles). Blanco con tres
             * opacidades —título, secundario, terciario— y el acento en su tono claro (`primaryFixed`,
             * el rol de Material pensado para fondos oscuros). Sin carátula, el tema de siempre.
             */
            readonly property bool onCover: Media.has && backdrop.showing
            readonly property color ink1: onCover ? "#ffffff" : Theme.fg
            readonly property color ink2: onCover ? Qt.rgba(1, 1, 1, 0.84) : Theme.fgVariant
            readonly property color ink3: onCover ? Qt.rgba(1, 1, 1, 0.70) : Theme.outlineText
            readonly property color accent: onCover ? Colors.primaryFixed : Theme.fam(palette.accent).fill

            Column {
                visible: !Media.has
                anchors.centerIn: parent
                spacing: Metrics.sp2 * root.s
                Icon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: "music"
                    size: (root.wide ? 22 : 16) * root.s
                    color: Theme.outline
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "No media playing"
                    color: Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.body * root.s
                }
            }

            /**
             * La portada y, rodeándola por arriba, la posición. ←/→ mueven 5 s con el foco aquí; un clic o
             * un arrastre SOBRE el arco busca (en el resto del bloque, la portada, no hace nada).
             */
            Item {
                id: seekRow
                visible: Media.has
                x: Metrics.sp4 * root.s
                y: playback.blockTop + (playback.headerH - height) / 2
                width: root.coverSize + 2 * root.arcExt
                height: root.coverSize + root.arcExt
                readonly property bool focused: root.focusId === "seek"
                FocusRing { on: seekRow.focused }
                Accessible.role: Accessible.Slider
                Accessible.name: "Position"
                Accessible.description: root.fmt(Media.positionSec) + " of " + root.fmt(Media.lengthSec)
                Accessible.focusable: Media.canSeek
                Accessible.focused: seekRow.focused

                Shape {
                    id: arc
                    anchors.fill: parent
                    visible: !Style.terminal
                    preferredRendererType: Shape.CurveRenderer
                    ShapePath {
                        strokeColor: playback.onCover ? Qt.rgba(1, 1, 1, 0.22) : Qt.alpha(Theme.fg, 0.13)
                        strokeWidth: root.arcStroke
                        fillColor: "transparent"
                        capStyle: ShapePath.RoundCap
                        joinStyle: ShapePath.RoundJoin
                        PathPolyline { path: root.arcPath(1) }
                    }
                    ShapePath {
                        // en directo no hay fracción: sólo la pista
                        strokeColor: Media.live ? "transparent" : playback.accent
                        strokeWidth: root.arcStroke
                        fillColor: "transparent"
                        capStyle: ShapePath.RoundCap
                        joinStyle: ShapePath.RoundJoin
                        PathPolyline { path: root.arcPath(Media.live ? 0 : Media.progress) }
                    }
                }
                // terminal (F6, ADR-34): el mismo recorrido en celdas cuadradas, como el Slider y ProgressTrack
                Item {
                    id: arcCells
                    objectName: "styleMarks"
                    anchors.fill: parent
                    visible: Style.terminal
                    readonly property real cell: root.arcStroke
                    // recorrido en cuadrado: medio lado + lado de arriba + medio lado = 4·(C/2 + desfase)
                    readonly property real len: 4 * (root.coverSize / 2 + root.arcOff)
                    readonly property int n: Math.max(8, Math.floor(arcCells.len / (arcCells.cell * 1.7)))
                    Repeater {
                        model: arcCells.visible ? arcCells.n : 0
                        Rectangle {
                            required property int index
                            readonly property real t: (index + 0.5) / arcCells.n
                            readonly property point at: root.arcAt(t)
                            x: Math.round(at.x - width / 2)
                            y: Math.round(at.y - height / 2)
                            width: arcCells.cell
                            height: arcCells.cell
                            color: !Media.live && t <= Media.progress ? playback.accent
                                : playback.onCover ? Qt.rgba(1, 1, 1, 0.22) : Qt.alpha(Theme.fg, 0.13)
                        }
                    }
                }
                Rectangle {
                    id: knob
                    visible: Media.canSeek && !Media.live
                    readonly property point at: root.arcAt(Media.progress)
                    x: knob.at.x - width / 2
                    y: knob.at.y - height / 2
                    width: 12 * root.s
                    height: 12 * root.s
                    radius: Metrics.pill(width)
                    color: playback.accent
                }

                /** La portada: cuadrada con esquinas redondeadas o, en disco, redonda con surcos y agujero. */
                ClippingRectangle {
                    id: art
                    x: root.arcExt
                    y: root.arcExt
                    width: root.coverSize
                    height: width
                    radius: root.disc ? Metrics.pill(width) : Metrics.r(12) * root.s
                    color: Theme.insetBg
                    border.width: 1
                    border.color: Theme.hair
                    Image {
                        anchors.fill: parent
                        source: Media.artUrl
                        sourceSize.width: Math.ceil(art.width * 2)
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        retainWhileLoading: true
                        cache: false
                        smooth: true
                        visible: status === Image.Ready
                    }
                    Icon {
                        anchors.centerIn: parent
                        name: "music"
                        size: 26 * root.s
                        color: Theme.outline
                        visible: Media.artUrl.length === 0 && !root.disc
                    }
                    Repeater {
                        model: root.disc ? [0.94, 0.8, 0.66, 0.52] : []
                        delegate: Rectangle {
                            required property real modelData
                            anchors.centerIn: parent
                            width: art.width * modelData
                            height: width
                            radius: Metrics.pill(width)
                            color: "transparent"
                            border.width: 1
                            border.color: Qt.rgba(0, 0, 0, 0.16)
                        }
                    }
                    Rectangle {
                        visible: root.disc
                        anchors.centerIn: parent
                        width: Math.round(art.width * 0.22)
                        height: width
                        radius: Metrics.pill(width)
                        color: Qt.rgba(0, 0, 0, 0.42)
                        border.width: 1
                        border.color: Qt.rgba(1, 1, 1, 0.28)
                        Rectangle {
                            anchors.centerIn: parent
                            width: Math.max(4, Math.round(parent.width * 0.3))
                            height: width
                            radius: Metrics.pill(width)
                            color: Theme.insetBg
                        }
                    }
                }

                MouseArea {
                    id: arcArea
                    anchors.fill: parent
                    enabled: Media.canSeek && !Media.live
                    hoverEnabled: true
                    property bool onArc: false
                    cursorShape: arcArea.onArc || arcArea.pressed ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onPressed: (e) => {
                        const h = root.arcNearest(e.x, e.y);
                        if (h.d > 14 * root.s) { e.accepted = false; return; }
                        root.pointerFocus("seek");
                        Media.seekTo(h.t);
                    }
                    onPositionChanged: (e) => {
                        if (arcArea.pressed) Media.seekTo(root.arcNearest(e.x, e.y).t);
                        else arcArea.onArc = root.arcNearest(e.x, e.y).d <= 14 * root.s;
                    }
                    onExited: arcArea.onArc = false
                }
            }

            Column {
                id: info
                visible: Media.has
                anchors.left: seekRow.right
                anchors.leftMargin: Metrics.sp4 * root.s
                anchors.right: parent.right
                anchors.rightMargin: Metrics.sp4 * root.s
                y: playback.blockTop + (playback.headerH - implicitHeight) / 2
                spacing: 6 * root.s

                /** El reproductor; con más de uno de verdad, un selector (←/→ en el teclado). */
                Item {
                    id: pickerRow
                    width: parent.width
                    height: 15 * root.s
                    readonly property bool focused: root.focusId === "picker"
                    FocusRing { on: pickerRow.focused }
                    Accessible.role: Accessible.ComboBox
                    Accessible.name: "Player: " + Media.sourceName
                    Accessible.focusable: root.canPick
                    Accessible.focused: pickerRow.focused

                    Row {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 5 * root.s
                        visible: !root.picking
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: Media.sourceName
                            color: playback.ink3
                            font.family: Typography.ui
                            font.pixelSize: Typography.caption * root.s
                        }
                        Icon {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: root.canPick
                            name: "chevron-down"
                            size: 10 * root.s
                            color: playback.accent
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        enabled: root.canPick && !root.picking
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { root.pointerFocus("picker"); root.picking = true; }
                    }
                    Row {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 5 * root.s
                        visible: root.picking
                        Repeater {
                            model: root.picking ? Media.pickable : []
                            delegate: Rectangle {
                                id: chip
                                required property var modelData
                                readonly property bool current: chip.modelData === Media.active
                                anchors.verticalCenter: parent.verticalCenter
                                width: chipLabel.implicitWidth + 12 * root.s
                                height: 15 * root.s
                                radius: Metrics.pill(height)
                                color: chip.current ? Theme.fam(palette.accent).sel : Theme.hoverBg
                                Text {
                                    id: chipLabel
                                    anchors.centerIn: parent
                                    text: chip.modelData.identity || chip.modelData.dbusName
                                    color: chip.current ? Theme.fam(palette.accent).text : Theme.fgVariant
                                    font.family: Typography.ui
                                    font.pixelSize: Typography.micro * root.s
                                    font.weight: Font.DemiBold
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: { Media.select(chip.modelData); root.picking = false; }
                                }
                            }
                        }
                    }
                }

                Text {
                    width: parent.width
                    objectName: "mediaTitle"
                    text: Media.title.length > 0 ? Media.title : "—"
                    color: playback.ink1
                    wrapMode: Text.Wrap
                    maximumLineCount: root.wide ? 3 : 2
                    elide: Text.ElideRight
                    font.family: Typography.ui
                    font.pixelSize: (root.wide ? Typography.title : Typography.body) * root.s
                    font.weight: Font.DemiBold
                }
                Text {
                    width: parent.width
                    visible: text.length > 0
                    text: [Media.artist, Media.album].filter(x => x.length > 0).join(" · ")
                    color: playback.ink2
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    font.family: Typography.ui
                    font.pixelSize: Typography.label * root.s
                }
                /**
                 * Transcurrido / duración o lo que queda (Settings · Time at the end); un clic en el texto
                 * cambia entre las dos. En directo, «live».
                 */
                Text {
                    id: dur
                    text: Media.live ? "live" : root.fmt(Media.positionSec) + " / " + (Settings.mediaEndTime === "remaining"
                        ? "-" + root.fmt(Math.max(0, Media.lengthSec - Media.positionSec))
                        : root.fmt(Media.lengthSec))
                    color: durArea.containsMouse ? playback.ink1 : playback.ink3
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                    font.features: { "tnum": 1 }
                    Accessible.role: Accessible.Button
                    Accessible.name: Settings.mediaEndTime === "remaining" ? "Show track length" : "Show remaining time"
                    MouseArea {
                        id: durArea
                        anchors.fill: parent
                        anchors.margins: -4 * root.s
                        enabled: !Media.live
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Settings.mediaEndTime = Settings.mediaEndTime === "remaining" ? "total" : "remaining"
                    }
                }
            }

            /** Transporte: ←/→ pista anterior / siguiente, Enter / Espacio reproducir o pausar. */
            Row {
                id: transport
                visible: Media.has
                anchors.horizontalCenter: parent.horizontalCenter
                y: playback.blockTop + playback.headerH + Metrics.sp3 * root.s
                spacing: Metrics.sp5 * root.s
                readonly property bool focused: root.focusId === "transport"
                Accessible.role: Accessible.Grouping
                Accessible.name: "Playback controls"
                Accessible.focusable: true
                Accessible.focused: transport.focused

                Control { glyph: "prev"; label: "Previous"; can: Media.canPrev; onActivated: Media.previous() }
                Control {
                    prominent: true
                    glyph: Media.playing ? "pause" : "play"
                    label: Media.playing ? "Pause" : "Play"
                    can: Media.canToggle
                    glyphSize: 21
                    onActivated: Media.toggle()
                }
                Control { glyph: "next"; label: "Next"; can: Media.canNext; onActivated: Media.next() }
            }
            /** El contorno del foco del transporte (la Row no puede llevar hijos anclados). */
            Rectangle {
                visible: Media.has && root.keyNav && transport.focused
                x: transport.x - 6 * root.s
                y: transport.y
                width: transport.width + 12 * root.s
                height: transport.height + 2 * root.s
                radius: Metrics.r(8) * root.s
                color: "transparent"
                border.width: Metrics.focusWidth * root.s
                border.color: Theme.selBorder
            }
        }
    }

    // ---- 2–5. la mezcla ------------------------------------------------------------------

    Item {
        id: mixPane
        palette.accent: Theme.zone(Zones.of("mix"))
        x: root.wide ? Metrics.mixerPlayerW * root.s + root.gutter : 0
        width: root.width - mixPane.x
        height: root.height

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: col.y + col.implicitHeight
        clip: true
        interactive: contentHeight > height + 1
        boundsBehavior: Flickable.StopAtBounds

    Column {
        id: col
        // el contorno del foco sale 4 px por fuera de cada fila: con este margen el recorte
        // del scroll no se lo come (en la última fila se perdía su borde inferior)
        x: 5 * root.s
        // estrecha: debajo del reproductor, que va en el mismo scroll
        y: root.wide ? 0 : root.playerH + root.gutter
        width: flick.width - 10 * root.s
        spacing: Metrics.sp2 * root.s

        Item {
            width: parent.width; height: 32 * root.s
            Text {
                anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                text: "Audio"; color: Theme.fg
                font.family: Typography.ui; font.pixelSize: Typography.display * root.s; font.weight: Typography.wStrong
            }
            /** Los ajustes de audio → Settings · System · Audio (teclado: S). */
            Item {
                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                width: 28 * root.s
                height: 28 * root.s
                Accessible.role: Accessible.Button
                Accessible.name: "Audio settings (S)"
                Accessible.onPressAction: if (root.host) root.host.openSettingsAt("system/audio")
                Icon {
                    anchors.centerIn: parent
                    name: "cog"
                    size: 12 * root.s
                    color: cfgArea.containsMouse ? Theme.fg : Theme.fgVariant
                }
                MouseArea {
                    id: cfgArea
                    anchors.fill: parent
                    anchors.margins: -8 * root.s
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (root.host) root.host.openSettingsAt("system/audio")
                }
            }
        }

        /**
         * 2 y 4. Salida y entrada: lado a lado en la composición apaisada (cada una con su volumen y,
         * con más de un dispositivo, su selector); una debajo de otra en la estrecha. Posiciones a
         * mano, no un Grid: los anchos de las filas dependen del de la columna.
         */
        Item {
            id: devices
            width: parent.width
            readonly property bool two: root.wide
            readonly property real colW: devices.two ? (devices.width - root.gutter) / 2 : devices.width
            height: devices.two ? Math.max(outCol.implicitHeight, inCol.implicitHeight)
                : outCol.implicitHeight + Metrics.sp2 * root.s + inCol.implicitHeight

            Column {
                id: outCol
                width: devices.colW
                spacing: Metrics.sp2 * root.s
                LinkHeading { text: "Output"; section: "output" }
                Channel { node: root.sink; fid: "outVol"; visible: root.sink !== null }
                Text {
                    visible: root.sink === null
                    text: "No output device"
                    color: Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.body * root.s
                }
                DeviceChoice { kind: "sink"; fid: "outDev" }
            }
            Column {
                id: inCol
                x: devices.two ? devices.colW + root.gutter : 0
                y: devices.two ? 0 : outCol.implicitHeight + Metrics.sp2 * root.s
                width: devices.colW
                spacing: Metrics.sp2 * root.s
                LinkHeading { text: "Input"; section: "input" }
                Channel { node: root.source; fid: "inVol"; visible: root.source !== null }
                Text {
                    visible: root.source === null
                    text: "No input device"
                    color: Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.body * root.s
                }
                DeviceChoice { kind: "source"; fid: "inDev" }
            }
        }

        // ---- 3. ecualizador: sólo el resumen (antes de la fase 14; el entero, en la Audio UI) ------

        Item { width: 1; height: 2 * root.s }
        Item {
            id: eqRow
            visible: root.eqDev.length > 0
            width: parent.width
            height: 40 * root.s
            Item {
                id: eqOnBox
                anchors.left: parent.left
                anchors.right: eqOpenBtn.left
                anchors.rightMargin: 10 * root.s
                anchors.verticalCenter: parent.verticalCenter
                height: parent.height
                readonly property bool focused: root.focusId === "eqOn"
                onFocusedChanged: if (focused) root.reveal(eqRow)
                Accessible.role: Accessible.CheckBox
                Accessible.name: "Equalizer on " + root.eqLabel
                Accessible.checked: root.eqView.enabled
                Accessible.description: root.eqWord
                FocusRing { on: eqOnBox.focused }
                Toggle {
                    id: eqToggle
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    s: root.s
                    on: root.eqView.enabled
                    label: "Equalizer on " + root.eqLabel
                    onToggled: { root.pointerFocus("eqOn"); Equalizer.setEnabled(root.eqDev, !root.eqView.enabled); }
                }
                Text {
                    anchors.left: eqToggle.right
                    anchors.leftMargin: 10 * root.s
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    text: "Equalizer  ·  " + root.eqWord
                    color: root.eqStatus.state === "failed" ? Theme.errorColor : Theme.fg
                    font.family: Typography.ui
                    font.pixelSize: Typography.label * root.s
                }
            }
            ActionButton {
                id: eqOpenBtn
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                s: root.s
                label: "Open ↗"
                focused: root.keyNav && root.focusId === "eqUi"
                onFocusedChanged: if (focused) root.reveal(eqRow)
                onTriggered: { root.pointerFocus("eqUi"); root.openAudio("equalizer"); }
            }
        }

        // ---- 5. aplicaciones (plegado) ------------------------------------------------------

        Disclosure {
            id: appsHead
            s: root.s
            height: 38 * root.s
            label: "Applications"
            summary: root.playingCount + " playing · " + root.recordingCount + " recording"
                + (root.recordingCount > 0 ? " · mic in use" : "")
            expanded: root.appsOpen
            focused: root.keyNav && root.focusId === "apps"
            onFocusedChanged: if (focused) root.reveal(appsHead)
            onToggled: { root.pointerFocus("apps"); root.appsOpen = !root.appsOpen; }
        }
        Repeater {
            model: root.appsOpen ? Mixer.playback : []
            Column {
                id: appCol
                required property var modelData
                width: parent ? parent.width : 0
                Channel { node: appCol.modelData; fid: "app:" + appCol.modelData.id }
                RouteChoice { node: appCol.modelData; fid: "route:" + appCol.modelData.id }
            }
        }
        Repeater {
            model: root.appsOpen ? Mixer.capture : []
            Column {
                id: capCol
                required property var modelData
                width: parent ? parent.width : 0
                Channel {
                    node: capCol.modelData
                    fid: "app:" + capCol.modelData.id
                    recording: true
                    opacity: 0.8
                }
                RouteChoice { node: capCol.modelData; fid: "route:" + capCol.modelData.id }
            }
        }
        Text {
            visible: root.appsOpen && root.playingCount === 0 && root.recordingCount === 0
            leftPadding: 30 * root.s
            text: "No apps are playing or recording"
            color: Theme.fgVariant
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }

        Item { width: 1; height: 8 * root.s }
    }
    }

    ScrollHint { view: flick; s: root.s }
    }

    /** Un botón del transporte. */
    component Control: Item {
        id: ctl
        property string glyph: ""
        property string label: ""
        property bool can: false
        property real glyphSize: 17
        property bool prominent: false
        signal activated()
        width: 40 * root.s
        height: 40 * root.s
        opacity: ctl.can ? 1 : Theme.disabledOpacity
        Rectangle {
            anchors.fill: parent
            radius: Metrics.pill(width)
            color: ctl.prominent ? playback.accent : ctlArea.containsMouse ? Theme.hoverBg : "transparent"
            scale: ctlArea.pressed && !Motion.still ? 0.94 : 1
            Behavior on scale { NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic } }
        }
        Accessible.role: Accessible.Button
        Accessible.name: ctl.label
        Accessible.onPressAction: if (ctl.can) ctl.activated()
        Icon {
            anchors.centerIn: parent
            name: ctl.glyph
            size: ctl.glyphSize * root.s
            color: ctl.prominent ? Theme.foregroundFor(playback.accent) : ctlArea.containsMouse ? playback.ink1 : playback.ink2
        }
        MouseArea {
            id: ctlArea
            anchors.fill: parent
            hoverEnabled: true
            enabled: ctl.can
            cursorShape: Qt.PointingHandCursor
            onClicked: { root.pointerFocus("transport"); ctl.activated(); }
        }
    }
}
