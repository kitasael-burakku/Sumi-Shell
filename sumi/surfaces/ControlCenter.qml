pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "../theme"
import "../services"
import "../components"
import "../lib/control-center-layout.js" as CcLayout
import "../lib/accent-zones.js" as Zones

/**
 * Centro de control (rediseño del 2026-11-15 sobre el boceto del autor; antes, fase 7E-1).
 *
 * Distribución (`lib/control-center-layout.js`, v1 fija; de ella sale también el orden del teclado):
 *   cabecera    «Control center» · batería con % (sólo si hay; abre Battery status, D5b) · Settings
 *   principal   Network y Bluetooth (tarjetas, izquierda) · volumen y brillo (columnas verticales, derecha)
 *   secundaria  Mode (el modo activo; abre Dashboard → Performance, D5) · Do not disturb
 *   avisos      «Notifications · N unread» · `≡` Clear all en rojo · hasta 3 sin leer con su `⊗` (D4) · «+N more»
 *
 * Acciones rápidas sobre servicios que YA existen; ni una lectura propia:
 *   · Network: el interruptor es SÓLO la radio Wi‑Fi (`Net.setRadio`), nunca el cable (D2: con cable, la tarjeta dice
 *     «Ethernet · velocidad» y debajo «Wi‑Fi on/off»). Bluetooth: el adaptador (`Bt.setPower`).
 *     En los dos estilos el cuerpo de la tarjeta abre Wi‑Fi o Bluetooth y el `Toggle` de siempre cambia la radio
 *     (`components/ControlTile`; la tarjeta-interruptor de D1 se retiró a petición del autor, 2026-11-15). Se apilan:
 *     Esc/Back vuelven aquí.
 *   · Volumen: la salida por defecto (`Mixer`, pedido/efectivo); su glifo abre el Mixer. Brillo: SÓLO el monitor de
 *     esta pantalla (`Brightness`); sin control, la columna se queda atenuada con «—» (D3) y nada cambia de sitio.
 *   · Do not disturb: el mismo estado que Notifications y el Dashboard (`NotifHistory.dnd`, con quién lo puso).
 *
 * Cada control lee su estado del servicio antes de presentarlo como aplicado (`ops.shown`); un fallo sale en el
 * propio control, sin popups.
 *
 * Avisos: los sin leer más recientes. Verlos aquí NO los marca (la lectura es del centro, por permanencia). `⊗` quita
 * ése y sube el siguiente; Clear all pregunta aquí mismo sobre las claves de ESE momento (`NotifHistory.clearSet`);
 * pulsar un aviso abre Notifications con la entrada localizada (Esc vuelve aquí), sin ejecutar la acción de la app.
 * Sin servidor, lo dice (nunca «0»).
 *
 * Teclado: ↑ ↓ / Tab recorren las paradas; ← → mueven un deslizador o fijan un interruptor; ⏎ / Espacio activan.
 * Esc cierra. Atajo: Super+Ctrl+N.
 */
Surface {
    id: root

    mBottom: 12

    signal requestSurface(string name)

    implicitHeight: col.implicitHeight

    // ---- reclamaciones: sólo lo que lee esta vista, soltado al cerrar -----------------
    Claim { target: Mixer; method: "claim"; key: "cc@" + root.screenName; value: root.active }
    Claim { target: Brightness; method: "claim"; key: "cc@" + root.screenName; value: root.active }

    // ---- distribución --------------------------------------------------------------------
    /** La distribución que se dibuja (v1: la de serie; nadie la cambia todavía). */
    readonly property var layout: CcLayout.resolve(null, [])

    readonly property var sink: Mixer.defaultSink
    readonly property bool hasBrightness: { void Brightness.displays; return Brightness.has(root.screenName); }
    /** F10 (2026-11-27): el perfil de energía sólo con power-profiles-daemon; sin él, Keep awake ocupa la fila. */
    readonly property bool hasPower: PowerProfile.present && PowerProfile.ok
    readonly property var tertiaryShown: root.layout.tertiary.filter(x => x.id !== "power" || root.hasPower)
    function profileLabel(p) {
        return p === "power-saver" ? "Power saver" : p.length > 0 ? p.charAt(0).toUpperCase() + p.slice(1) : "";
    }
    /**
     * E10 (2026-11-27, pedido del autor): lo que falta en este equipo se dice debajo de los módulos, no sólo en el
     * nombre accesible. Hoy: el brillo, con la razón de Environment (Capabilities) si la hay.
     */
    readonly property var notices: {
        const out = [];
        if (!root.hasBrightness && Brightness.detected) {
            const why = Capabilities.whyFirst([root.screenName.startsWith("eDP") ? "brightness.backlight" : "brightness.external"]);
            out.push({ glyph: "brightness", text: why.length > 0 ? "No brightness control on this display: " + why
                                                            : "This display doesn't offer brightness control (DDC/CI)" });
        }
        return out;
    }

    /** El orden del teclado: sale de la distribución y de lo que existe ahora. */
    readonly property var slots: {
        if (root.confirming) return ["cancel", "clear"];
        return CcLayout.slots(root.layout, { battery: Battery.present, brightness: root.hasBrightness, power: root.hasPower,
            notifs: root.shownNotifs.length, more: root.moreUnread > 0,
            clear: Notifs.enabled && NotifHistory.count > 0 });
    }
    onSlotsChanged: if (root.kb >= root.slots.length) root.kb = Math.max(0, root.slots.length - 1)

    // ---- notificaciones ------------------------------------------------------------------
    /** Los sin leer más recientes que se enseñan (D4: 3). `entries` va de la más nueva a la más vieja. */
    readonly property var shownNotifs: {
        void NotifHistory.revision;
        if (!Notifs.enabled || !root.layout.notifications.show) return [];
        const out = [];
        const all = NotifHistory.entries;
        for (let i = 0; i < all.length && out.length < root.layout.notifications.max; i++)
            if (NotifHistory.isUnread(all[i])) out.push(all[i]);
        return out;
    }
    readonly property int moreUnread: Notifs.enabled ? Math.max(0, NotifHistory.unread - root.shownNotifs.length) : 0
    /** Clear all: las claves de ESE momento (null = sin pregunta). */
    property var confirmKeys: null
    readonly property bool confirming: root.confirmKeys !== null
    onConfirmingChanged: Qt.callLater(root.revealFocus)
    property string notifNote: ""
    Timer { id: noteTimer; interval: 2500; onTriggered: root.notifNote = "" }

    function openNotif(i) {
        const e = root.shownNotifs[i];
        if (!e || !NotifHistory.entry(e.key)) {
            root.notifNote = "Notification no longer available";
            noteTimer.restart();
            return;
        }
        NotifHistory.locateTarget = e.key;
        root.requestSurface("notifications");
    }
    function dismissNotif(i) {
        const e = root.shownNotifs[i];
        if (e) NotifHistory.dismiss(e.key);
    }
    function askClear(keys) {
        if (!keys || keys.length === 0) return false;
        root.confirmKeys = keys;
        root.kb = 0;   // Cancel: la acción segura
        return true;
    }
    function answerClear(clear) {
        const keys = root.confirmKeys;
        root.confirmKeys = null;
        if (clear && keys) NotifHistory.clearSet(keys);
        root.focusOn("clearAll");
    }
    onActiveChanged: {
        if (!root.active) root.confirmKeys = null;   // cerrar cancela
        else PowerProfile.refresh();                 // F10: ¿está el daemon? (un proceso al abrir, ninguno en uso)
    }

    // ---- foco ------------------------------------------------------------------------------
    property int kb: 0
    onKbChanged: Qt.callLater(root.revealFocus)
    onHeightChanged: Qt.callLater(root.revealFocus)
    onSettledChanged: if (settled) Qt.callLater(root.revealFocus)
    function isFocused(id) { return root.slots[root.kb] === id; }
    // al abrir, el foco en la primera tarjeta (no en la cabecera): lo de siempre es la red
    onOpenChanged: if (open) { root.focusOn(root.slots.indexOf("netOpen") >= 0 ? "netOpen" : root.slots[0]); content.contentY = 0; }

    // A short output can cap the host's height. Keep keyboard controls reachable there.
    function revealFocus() {
        // Off can reopen at the same closeness, without emitting the settled signal.
        if (!root.open || (!Motion.off && !root.settled)) return;
        const id = String(root.slots[root.kb] || "");
        const notif = id.startsWith("notif:") || id.startsWith("dismiss:")
            ? notifRows.itemAt(Number(id.split(":")[1])) : null;
        const item = id === "battery" || id === "settings" ? header
            : ["netToggle", "netOpen", "btToggle", "btOpen", "sound", "brightness"].indexOf(id) >= 0 ? mainRow
            : id === "mode" || id === "dnd" ? secondaryRow
            : id === "power" || id === "awake" ? tertiaryRow
            : id === "clearAll" ? notifHeader
            : id === "more" ? moreRow : notif || notifArea;
        if (!item || !content) return;
        const y = item.mapToItem(content.contentItem, 0, 0).y;
        let next = content.contentY;
        if (y < next) next = y;
        else if (y + item.height > next + content.height) next = y + item.height - content.height;
        content.contentY = Math.max(0, Math.min(Math.max(0, content.contentHeight - content.height), next));
    }

    // ---- red --------------------------------------------------------------------
    readonly property bool wifiShownOn: { void Net.ops.table; return Net.ops.shown("radio", Net.wifiEnabled); }
    readonly property bool wifiAvailable: Net.wifiDev !== null && Net.wifiHardware
    readonly property bool wired: Net.kind === "wired"
    readonly property string netState: {
        if (Net.unavailableWhy.length > 0) return "Unavailable";      // F2d: el detalle, en Wi-Fi y Settings
        if (!Net.ready) return "…";
        if (root.wired) return "Ethernet" + (Net.linkSpeed > 0 ? " · " + Net.linkSpeed + " Mb/s" : "");
        if (Net.kind === "wifi") return Net.ssid;
        if (Net.wifiDev === null) return "No Wi-Fi adapter";
        return root.wifiShownOn ? "Not connected" : "Wi-Fi off";
    }
    /** D2: con cable, la radio aparte (el interruptor es ella, no el cable). */
    readonly property string netDetail: !root.wired || Net.unavailableWhy.length > 0 ? ""
        : Net.wifiDev === null ? "No Wi-Fi adapter" : root.wifiShownOn ? "Wi-Fi on" : "Wi-Fi off"
    readonly property string netIcon: root.wired ? "ethernet"
        : Net.kind === "wifi" ? (Net.degraded ? "wifi-alert" : "wifi")
        : (root.wifiShownOn ? "wifi-none" : "wifi-off")
    readonly property string netError: {
        void Net.ops.table;
        if (Net.wifiDev !== null && !Net.wifiHardware) return "Blocked by the hardware switch";
        return Net.ops.stateOf("radio") === "error" ? Net.ops.get("radio").reason : "";
    }
    function toggleWifi() {
        if (!root.wifiAvailable) return;
        Net.setRadio(!root.wifiShownOn);
    }

    // ---- bluetooth -----------------------------------------------------------------
    readonly property bool btShownOn: { void Bt.ops.table; return Bt.ops.shown("power", Bt.powered); }
    readonly property bool btAvailable: Bt.present && !Bt.blocked
    readonly property string btState: {
        if (!Bt.ready) return "…";
        if (!Bt.present) return "No adapter";
        if (Bt.blocked) return "Blocked";
        if (!root.btShownOn) return "Off";
        if (Bt.connectedCount === 1) return Bt.connectedDevices[0].name || "1 connected";
        if (Bt.connectedCount > 1) return Bt.connectedCount + " connected";
        return "On";
    }
    readonly property string btError: {
        void Bt.ops.table;
        if (!Bt.ready) return "";
        if (!Bt.present) return "Bluetooth adapter unavailable";
        if (Bt.blocked) return "Blocked by rfkill";
        return Bt.ops.stateOf("power") === "error" ? Bt.ops.get("power").reason : "";
    }
    function toggleBt() {
        if (!root.btAvailable) return;
        Bt.setPower(!root.btShownOn);
    }

    // ---- sonido y brillo ------------------------------------------------------------
    readonly property real volume: Mixer.shownVolume(root.sink)
    readonly property bool muted: Mixer.shownMuted(root.sink)
    readonly property string soundError: {
        if (!root.sink) return "No output device";
        return Mixer.failedOn(root.sink) ? "Volume not applied" : "";
    }
    function nudgeVolume(d) { if (root.sink) Mixer.setVolume(root.sink, root.volume + d); }

    readonly property real brightness: Brightness.shown(root.screenName)
    readonly property string brightnessError: root.hasBrightness && Brightness.failed(root.screenName) ? Brightness.reason(root.screenName) : ""
    /** Por qué no hay brillo (D3), dicho sin inventar: aún detectando, o esta pantalla no lo tiene. */
    readonly property string brightnessNote: !Brightness.detected ? "Detecting…" : "No brightness control on this display"
    function nudgeBrightness(d) {
        if (root.hasBrightness && root.brightness >= 0) Brightness.set(root.screenName, root.brightness + d);
    }

    // ---- batería ---------------------------------------------------------------------
    /** Glifo y color de la batería: los de `Battery` (ADR-42), los mismos que en la barra. */
    readonly property color batteryInk: Battery.ink
    readonly property string batteryGlyph: Battery.glyph

    // ---- modo y DND --------------------------------------------------------------------
    function modeLabel(m) { return m.length > 0 ? m.charAt(0).toUpperCase() + m.slice(1) : ""; }
    readonly property string modeIcon: Modes.mode === "focus" ? "target"
        : Modes.mode === "gaming" ? "controller"
        : Modes.mode === "cinema" ? "tv" : "monitor"
    readonly property string dndCaption: {
        const m = Modes.mode;
        const special = m !== "normal";
        if (!Notifs.enabled) return "The shell notification server is off";
        if (NotifHistory.dnd)
            return NotifHistory.dndSource === "mode"
                 ? (special ? "Turned on by " + root.modeLabel(m) + " mode" : "Turned on by a script · critical ones still show")
                 : "Turned on by hand · critical ones still show";
        if (special && NotifHistory.dndSource === "manual")
            return "Turned off by hand during " + root.modeLabel(m) + " mode";
        return "Popups show normally";
    }
    /** La línea corta de la tarjeta (la larga, `dndCaption`, va en su descripción accesible y en el estado). */
    readonly property string dndShort: {
        if (!Notifs.enabled) return "Server off";
        if (NotifHistory.dnd)
            return NotifHistory.dndSource === "mode" && Modes.mode !== "normal"
                 ? "On · " + root.modeLabel(Modes.mode) + " mode" : "On";
        return "Off";
    }

    // ---- teclado ------------------------------------------------------------------------
    function activate(id) {
        const k = String(id);
        if (k.indexOf("notif:") === 0) { root.openNotif(Number(k.slice(6))); return; }
        if (k.indexOf("dismiss:") === 0) { root.dismissNotif(Number(k.slice(8))); return; }
        switch (k) {
        case "netToggle": root.toggleWifi(); break;
        case "netOpen": root.requestSurface("wifi"); break;
        case "btToggle": root.toggleBt(); break;
        case "btOpen": root.requestSurface("bluetooth"); break;
        case "sound": root.requestSurface("mixer"); break;
        case "brightness": break;
        case "battery": if (root.host) root.host.openSettingsAt("system/power/batteryStatus"); break;
        case "settings": SettingsUi.show(root.screenName, "", { from: "controlCenter" }); root.requestClose(); break;
        case "mode": root.requestSurface("performance"); break;   // 11A-1: Dashboard → Performance (D5)
        case "dnd": if (Notifs.enabled) NotifHistory.toggleDnd(); break;
        case "power": root.requestSurface("performance"); break;   // F10: donde se eligen perfil y modo
        case "awake": Session.toggleKeepAwake(); break;
        case "more": root.requestSurface("notifications"); break;
        case "clearAll": root.askClear(NotifHistory.keys()); break;
        case "cancel": root.answerClear(false); break;
        case "clear": root.answerClear(true); break;
        }
    }
    function adjust(id, dir) {
        switch (id) {
        case "sound": root.nudgeVolume(0.05 * dir); break;
        case "brightness": root.nudgeBrightness(0.05 * dir); break;
        case "netToggle": if (root.wifiShownOn !== (dir > 0)) root.toggleWifi(); break;
        case "btToggle": if (root.btShownOn !== (dir > 0)) root.toggleBt(); break;
        case "dnd": if (Notifs.enabled && NotifHistory.dnd !== (dir > 0)) NotifHistory.toggleDnd(); break;
        }
    }
    function keyPressed(e) {
        if (root.confirming && e.key === Qt.Key_Escape) { root.answerClear(false); e.accepted = true; return; }
        if (root.confirming && (e.key === Qt.Key_Left || e.key === Qt.Key_Right)) { root.kb = 1 - root.kb; e.accepted = true; return; }
        const n = root.slots.length;
        if (e.key === Qt.Key_Down || e.key === Qt.Key_Tab) { root.kb = (root.kb + 1) % n; e.accepted = true; }
        else if (e.key === Qt.Key_Up || e.key === Qt.Key_Backtab) { root.kb = (root.kb - 1 + n) % n; e.accepted = true; }
        else if (e.key === Qt.Key_Left) { root.adjust(root.slots[root.kb], -1); e.accepted = true; }
        else if (e.key === Qt.Key_Right) { root.adjust(root.slots[root.kb], 1); e.accepted = true; }
        else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) {
            if (!e.isAutoRepeat) root.activate(root.slots[root.kb]);
            e.accepted = true;
        }
    }
    function focusOn(id) { const i = root.slots.indexOf(id); if (i >= 0) root.kb = i; }

    /** Pruebas (IPC `controlCenterState`): lo que enseña, sin tocar nada. Campos de antes conservados. */
    function stateJson() {
        return JSON.stringify({ focus: root.slots[root.kb], slots: root.slots, layout: root.layout,
            net: { state: root.netState, detail: root.netDetail, wifiOn: root.wifiShownOn, available: root.wifiAvailable, error: root.netError, kind: Net.kind },
            bt: { state: root.btState, on: root.btShownOn, available: root.btAvailable, error: root.btError },
            sound: { volume: Math.round(root.volume * 100), muted: root.muted, error: root.soundError, sink: root.sink ? String(root.sink.description || root.sink.name) : "" },
            brightness: root.hasBrightness ? { value: Math.round(root.brightness * 100), error: root.brightnessError } : null,
            brightnessNote: root.hasBrightness ? "" : root.brightnessNote,
            notices: root.notices.map(n => n.text), tertiary: root.tertiaryShown.map(x => x.id),
            battery: { present: Battery.present, percent: Battery.percent, charging: Battery.charging, description: Battery.description, low: Battery.low, glyph: root.batteryGlyph },
            mode: Modes.mode, dnd: { on: NotifHistory.dnd, source: NotifHistory.dndSource, caption: root.dndCaption, short: root.dndShort },
            notif: { server: Notifs.enabled, shown: root.shownNotifs.map(e => ({ key: e.key, app: e.app, summary: e.summary })),
                     latest: root.shownNotifs.length > 0 ? { key: root.shownNotifs[0].key, app: root.shownNotifs[0].app, summary: root.shownNotifs[0].summary } : null,
                     more: root.moreUnread, count: NotifHistory.count, unread: NotifHistory.unread, note: root.notifNote,
                     confirm: root.confirming ? root.confirmKeys.length : null } });
    }

    // ---- medidas -----------------------------------------------------------------------------
    // enteros: las columnas de deslizador caen en píxel entero y su carril y su pomo comparten eje (ver VSlider)
    readonly property int gap: Math.round(8 * root.s)
    readonly property real pad: 12 * root.s
    /** Ancho de una columna de deslizador y de la zona que ocupan las dos. */
    readonly property int sliderW: Math.round(54 * root.s)
    readonly property real sliderZoneW: root.layout.right.length * root.sliderW + Math.max(0, root.layout.right.length - 1) * root.gap
    /**
     * Alto de las tarjetas de la columna izquierda: tres líneas (título, estado y el detalle de D2) SIEMPRE, aunque el
     * detalle no esté: así el alto no depende de los datos (cable sí/no) y no salta al abrir. El glifo va a la izquierda
     * del texto (2026-11-15: el autor vio «huecos» con el glifo encima). Sale de los tamaños de Typography (crece con
     * «Text size»), no de una cifra fija.
     */
    readonly property real lineK: 1.34
    // Auditoría tipográfica (2026-11-18): `lineK` fijo se quedaba corto con familias de renglón alto (Noto Sans 1,36);
    // ahora el diseño (lineK con Iosevka a Text size 1) es el mínimo y la familia activa decide el resto
    readonly property real tileH: Math.ceil(Typography.box(24 + 36.5 * root.lineK,
        [Typography.body, Typography.label, Typography.caption], root.s))
    readonly property real smallTileH: Math.ceil(Math.max(Typography.box(24 + 25 * root.lineK, [Typography.body, Typography.label], root.s),
        (Metrics.hitMin + 16) * root.s))
    /**
     * El ancho que pide la fila secundaria (Mode, DND) para no cortar título ni estado: cada tarjeta dice el
     * suyo (`ControlTile.want`, medido sobre sus textos) y se respeta el reparto por pesos. SurfaceHost lo usa
     * como mínimo del panel, nunca menos que el diseño (auditoría tipográfica, 2026-11-18).
     */
    readonly property real wantW: {
        void secondaryRep.count;   // itemAt no notifica: repetir al crearse las tarjetas
        const sec = root.layout.secondary;
        const total = sec.reduce((a, x) => a + x.weight, 0);
        let need = 0;
        for (let i = 0; i < sec.length; i++) {
            const ld = secondaryRep.itemAt(i);
            if (ld && ld.item && ld.item.want > 0) need = Math.max(need, ld.item.want * total / Math.max(1, sec[i].weight));
        }
        return Math.ceil(need + Math.max(0, sec.length - 1) * root.gap);
    }
    readonly property real mainH: root.layout.left.length * root.tileH + Math.max(0, root.layout.left.length - 1) * root.gap

    // ---- dibujo ---------------------------------------------------------------------------

    Flickable {
        id: content
        anchors.fill: parent
        contentWidth: width
        contentHeight: col.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
            id: col
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            spacing: 10 * root.s

            // ---- cabecera ----
            Item {
                id: header
                width: parent.width
                height: Metrics.hitMin * root.s
                Text {
                    anchors.left: parent.left
                    y: Math.round((parent.height - height) / 2)
                    // sin `elide` ni ancho atado a la batería (2026-11-15, banco de la fase D): con ellos los glifos
                    // quedaban 0,2 px a un lado u otro según la apertura; el título siempre cabe
                    text: "Control center"
                    color: Theme.fg
                    font.family: Typography.ui
                    font.pixelSize: Typography.display * root.s
                    font.weight: Typography.wStrong
                    Accessible.role: Accessible.Heading
                }
                Row {
                    id: headerRow
                    anchors.right: parent.right
                    y: Math.round((parent.height - height) / 2)
                    spacing: 4 * root.s
                    Repeater {
                        model: root.layout.header
                        Loader {
                            required property string modelData
                            y: parent ? Math.round((parent.height - height) / 2) : 0
                            sourceComponent: modelData === "battery" ? batteryPiece : modelData === "settings" ? settingsPiece : null
                        }
                    }
                }
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: Metrics.hair
                    color: Theme.cardBorder
                }
            }

            // ---- principal: tarjetas a la izquierda, deslizadores a la derecha ----
            Item {
                id: mainRow
                width: parent.width
                height: root.mainH
                Column {
                    id: leftCol
                    anchors.left: parent.left
                    width: parent.width - root.sliderZoneW - (root.layout.right.length > 0 ? root.gap : 0)
                    spacing: root.gap
                    Repeater {
                        model: root.layout.left
                        Loader {
                            required property string modelData
                            width: leftCol.width
                            height: root.tileH
                            sourceComponent: modelData === "network" ? networkPiece : modelData === "bluetooth" ? bluetoothPiece : null
                        }
                    }
                }
                Row {
                    anchors.right: parent.right
                    height: parent.height
                    spacing: root.gap
                    Repeater {
                        model: root.layout.right
                        Loader {
                            required property string modelData
                            width: root.sliderW
                            height: root.mainH
                            sourceComponent: modelData === "volume" ? volumePiece : modelData === "brightness" ? brightnessPiece : null
                        }
                    }
                }
            }

            // ---- secundaria: Mode y DND, con su parte del ancho ----
            Row {
                id: secondaryRow
                width: parent.width
                height: root.smallTileH
                spacing: root.gap
                readonly property real weights: root.layout.secondary.reduce((a, x) => a + x.weight, 0)
                readonly property real free: width - Math.max(0, root.layout.secondary.length - 1) * spacing
                Repeater {
                    id: secondaryRep
                    model: root.layout.secondary
                    Loader {
                        required property var modelData
                        width: Math.floor(secondaryRow.free * modelData.weight / Math.max(1, secondaryRow.weights))
                        height: root.smallTileH
                        sourceComponent: modelData.id === "mode" ? modePiece : modelData.id === "dnd" ? dndPiece : null
                    }
                }
            }

            // ---- terciaria (F10): perfil de energía y Keep awake, con los pesos de la de encima ----
            Row {
                id: tertiaryRow
                visible: root.tertiaryShown.length > 0
                width: parent.width
                height: root.smallTileH
                spacing: root.gap
                readonly property real weights: root.tertiaryShown.reduce((a, x) => a + x.weight, 0)
                readonly property real free: width - Math.max(0, root.tertiaryShown.length - 1) * spacing
                Repeater {
                    model: root.tertiaryShown
                    Loader {
                        required property var modelData
                        width: Math.floor(tertiaryRow.free * modelData.weight / Math.max(1, tertiaryRow.weights))
                        height: root.smallTileH
                        sourceComponent: modelData.id === "power" ? powerPiece : modelData.id === "awake" ? awakePiece : null
                    }
                }
            }

            // ---- avisos de lo que falta en este equipo (E10) ----
            Column {
                visible: root.notices.length > 0
                width: parent.width
                spacing: root.gap
                Repeater {
                    model: root.notices
                    Notice {
                        required property var modelData
                        width: parent.width
                        s: root.s
                        tone: "info"
                        glyph: modelData.glyph
                        text: modelData.text
                    }
                }
            }

            Rectangle { width: parent.width; height: 1; color: Theme.hair; visible: root.layout.notifications.show }

            // ---- avisos ----
            Item {
                id: notifHeader
                visible: root.layout.notifications.show
                width: parent.width
                height: Metrics.hitMin * root.s
                Row {
                    anchors.left: parent.left
                    y: Math.round((parent.height - height) / 2)
                    spacing: 6 * root.s
                    Text {
                        y: Math.round((parent.height - height) / 2)
                        text: "Notifications"
                        color: Theme.fg
                        font.family: Typography.ui
                        font.pixelSize: Typography.body * root.s
                        font.weight: Font.DemiBold
                    }
                    Rectangle {
                        visible: unreadText.visible
                        y: Math.round((parent.height - height) / 2)
                        width: 6 * root.s
                        height: width
                        radius: Metrics.pill(width)
                        color: Theme.primary
                    }
                    Text {
                        id: unreadText
                        y: Math.round((parent.height - height) / 2)
                        visible: Notifs.enabled && NotifHistory.unread > 0
                        text: NotifHistory.unread + " unread"
                        color: Theme.fgVariant
                        font.family: Typography.ui
                        font.pixelSize: Typography.label * root.s
                        font.features: ({ "tnum": 1 })
                    }
                }
                GlyphButton {
                    anchors.right: parent.right
                    y: Math.round((parent.height - height) / 2)
                    visible: Notifs.enabled && !root.confirming
                    s: root.s
                    glyph: "clear-all"
                    label: "Clear all notifications"
                    danger: NotifHistory.count > 0
                    enabled: NotifHistory.count > 0
                    focused: root.isFocused("clearAll")
                    glyphSize: 17
                    onTriggered: { root.focusOn("clearAll"); root.activate("clearAll"); }
                }
            }

            Item {
                id: notifArea
                visible: root.layout.notifications.show
                width: parent.width
                height: root.confirming ? confirmBox.height
                      : root.shownNotifs.length === 0 ? 54 * root.s
                      : notifList.implicitHeight

                Text {
                    x: Math.round((parent.width - width) / 2); y: Math.round((parent.height - height) / 2)
                    width: parent.width - 24 * root.s
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    visible: !root.confirming && root.shownNotifs.length === 0
                    text: !Notifs.enabled ? "The shell notification server is off"
                        : NotifHistory.count > 0 ? "No unread notifications" : "No notifications"
                    color: Theme.outlineText
                    font.family: Typography.ui
                    font.pixelSize: Typography.label * root.s
                }

                Column {
                    id: notifList
                    width: parent.width
                    spacing: 8 * root.s
                    visible: !root.confirming && root.shownNotifs.length > 0
                    Repeater {
                        id: notifRows
                        model: root.shownNotifs
                        NotifRow {
                            required property var modelData
                            required property int index
                            width: notifList.width
                            height: implicitHeight
                            s: root.s
                            entry: modelData
                            focused: root.isFocused("notif:" + index)
                            dismissFocused: root.isFocused("dismiss:" + index)
                            onActivated: { root.focusOn("notif:" + index); root.openNotif(index); }
                            onDismissed: { root.focusOn("dismiss:" + index); root.dismissNotif(index); }
                        }
                    }
                    // «+N more ›»: el resto, en Notifications
                    Item {
                        id: moreRow
                        visible: root.moreUnread > 0
                        width: parent.width
                        height: visible ? 24 * root.s : 0
                        Rectangle {
                            anchors.centerIn: moreText
                            width: moreText.width + 16 * root.s
                            height: parent.height
                            radius: Metrics.rSm * root.s
                            color: moreArea.containsMouse ? Theme.hoverBg : "transparent"
                            border.width: root.isFocused("more") ? Metrics.focusWidth : 0
                            border.color: Theme.primary
                        }
                        Text {
                            id: moreText
                            x: Math.round((parent.width - width) / 2); y: Math.round((parent.height - height) / 2)
                            text: "+" + root.moreUnread + " more  ›"
                            color: moreArea.containsMouse ? Theme.fg : Theme.fgVariant
                            font.family: Typography.ui
                            font.pixelSize: Typography.label * root.s
                        }
                        MouseArea {
                            id: moreArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            Accessible.role: Accessible.Button
                            Accessible.name: root.moreUnread + " more unread notifications"
                            Accessible.onPressAction: root.activate("more")
                            onClicked: { root.focusOn("more"); root.activate("more"); }
                        }
                    }
                }

                // Clear all: la pregunta, aquí mismo (Cancel por defecto; Esc cancela).
                Rectangle {
                    id: confirmBox
                    width: parent.width
                    height: 64 * root.s
                    visible: root.confirming
                    radius: Metrics.rMd * root.s
                    color: Theme.cardBg
                    border.width: 1
                    border.color: Qt.alpha(Theme.errorColor, 0.5)
                    Text {
                        x: 10 * root.s
                        y: Math.round((parent.height - height) / 2)
                        width: parent.width - x - confirmRow.width - 16 * root.s
                        wrapMode: Text.Wrap
                        readonly property int n: root.confirmKeys ? root.confirmKeys.length : 0
                        text: "Clear " + n + (n === 1 ? " notification?" : " notifications?") + "\nLater arrivals stay."
                        color: Theme.fg
                        font.family: Typography.ui
                        font.pixelSize: Typography.label * root.s
                    }
                    Row {
                        id: confirmRow
                        anchors.right: parent.right
                        anchors.rightMargin: 8 * root.s
                        y: Math.round((parent.height - height) / 2)
                        spacing: 4 * root.s
                        ActionButton { s: root.s; label: "Cancel"; focused: root.isFocused("cancel"); onTriggered: root.answerClear(false) }
                        ActionButton { s: root.s; label: "Clear"; danger: true; focused: root.isFocused("clear"); onTriggered: root.answerClear(true) }
                    }
                }
            }

            Text {
                width: parent.width
                height: 12 * root.s
                text: root.notifNote
                color: Theme.errorColor
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
            }
        }
    }

    ScrollHint { view: content; s: root.s }

    // ---- piezas (las nombra la distribución) ------------------------------------------------

    Component {
        id: batteryPiece
        Item {
            visible: Battery.present
            width: visible ? batRow.width + 12 * root.s : 0
            height: Metrics.hitMin * root.s
            Accessible.role: Accessible.Button
            Accessible.name: "Battery"
            Accessible.description: Battery.description
            Accessible.onPressAction: root.activate("battery")
            Rectangle {
                anchors.fill: parent
                anchors.margins: 2 * root.s
                radius: Metrics.rSm * root.s
                color: batArea.containsMouse ? Theme.hoverBg : "transparent"
                border.width: root.isFocused("battery") ? Metrics.focusWidth : 0
                border.color: Theme.primary
            }
            Row {
                id: batRow
                x: Math.round((parent.width - width) / 2); y: Math.round((parent.height - height) / 2)
                spacing: 5 * root.s
                Icon {
                    y: Math.round((parent.height - height) / 2)
                    name: root.batteryGlyph
                    size: 16 * root.s
                    color: root.batteryInk
                }
                Text {
                    y: Math.round((parent.height - height) / 2)
                    text: Battery.percent + "%"
                    color: Battery.low ? Theme.errorColor : Theme.fg
                    font.family: Typography.ui
                    font.pixelSize: Typography.label * root.s
                    font.weight: Font.DemiBold
                    font.features: ({ "tnum": 1 })
                }
            }
            MouseArea {
                id: batArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.focusOn("battery"); root.activate("battery"); }
            }
        }
    }

    Component {
        id: settingsPiece
        GlyphButton {
            s: root.s
            glyph: "cog"
            label: "Settings"
            focused: root.isFocused("settings")
            onTriggered: { root.focusOn("settings"); root.activate("settings"); }
        }
    }

    Component {
        id: networkPiece
        ControlTile {
            palette.accent: Theme.zone(Zones.of("network"))
            s: root.s
            glyph: root.netIcon
            title: "Network"
            status: root.netState
            detail: root.netDetail
            error: root.netError
            on: root.wifiShownOn
            available: root.wifiAvailable
            toggleLabel: "Wi-Fi"
            toggleFocused: root.isFocused("netToggle")
            openFocused: root.isFocused("netOpen")
            onToggled: { root.focusOn("netToggle"); root.toggleWifi(); }
            onOpened: { root.focusOn("netOpen"); root.activate("netOpen"); }
        }
    }

    Component {
        id: bluetoothPiece
        ControlTile {
            palette.accent: Theme.zone(Zones.of("bluetooth"))
            s: root.s
            glyph: Bt.icon.length > 0 ? Bt.icon : "bt"
            title: "Bluetooth"
            status: root.btState
            error: root.btError
            on: root.btShownOn
            available: root.btAvailable
            toggleLabel: "Bluetooth"
            toggleFocused: root.isFocused("btToggle")
            openFocused: root.isFocused("btOpen")
            onToggled: { root.focusOn("btToggle"); root.toggleBt(); }
            onOpened: { root.focusOn("btOpen"); root.activate("btOpen"); }
        }
    }

    Component {
        id: volumePiece
        ControlSlider {
            palette.accent: Theme.zone(Zones.of("volume"))
            s: root.s
            glyph: root.muted || root.volume <= 0.001 ? "volume-off" : root.volume < 0.34 ? "volume-low" : root.volume < 0.67 ? "volume-mid" : "volume-high"
            label: "Volume"
            value: root.volume
            muted: root.muted
            available: root.sink !== null
            note: root.soundError
            error: root.sink !== null ? root.soundError : ""
            opens: true
            focused: root.isFocused("sound")
            onMoved: (v) => { root.focusOn("sound"); if (root.sink) Mixer.setVolume(root.sink, v); }
            onOpened: { root.focusOn("sound"); root.activate("sound"); }
        }
    }

    Component {
        id: brightnessPiece
        ControlSlider {
            palette.accent: Theme.zone(Zones.of("brightness"))
            s: root.s
            glyph: "brightness"
            label: "Brightness"
            value: Math.max(0, root.brightness)
            available: root.hasBrightness
            known: root.brightness >= 0
            note: root.brightnessNote
            error: root.brightnessError
            focused: root.isFocused("brightness")
            onMoved: (v) => { root.focusOn("brightness"); Brightness.set(root.screenName, v); }
        }
    }

    Component {
        id: modePiece
        ControlTile {
            // el modo del sistema con su color (Normal, Focus, Gaming, Cinema): sólo su casilla, no la shell
            palette.accent: Theme.zone(Zones.of(Modes.mode))
            s: root.s
            glyph: root.modeIcon
            title: root.modeLabel(Modes.mode)
            status: Modes.state === "applied" || Modes.state === "loading" ? "System mode" : Modes.statusText
            switchable: false
            opens: true
            openFocused: root.isFocused("mode")
            onOpened: { root.focusOn("mode"); root.activate("mode"); }
        }
    }

    Component {
        id: powerPiece
        ControlTile {
            palette.accent: Theme.zone(Zones.of("power"))
            s: root.s
            glyph: "gauge"
            title: "Power profile"
            status: root.profileLabel(PowerProfile.shownProfile) + (PowerProfile.degradation.length > 0 ? " · " + PowerProfile.degradation : "")
            switchable: false
            opens: true
            openFocused: root.isFocused("power")
            onOpened: { root.focusOn("power"); root.activate("power"); }
        }
    }

    Component {
        id: awakePiece
        ControlTile {
            palette.accent: Theme.zone(Zones.of("awake"))
            s: root.s
            glyph: "awake"
            title: "Keep awake"
            status: Session.keepAwakeEffective ? "On" : Session.keepAwake ? (Session.keepAwakeError || "Starting…") : "Off"
            on: Session.keepAwake
            opens: false
            toggleLabel: "Keep awake"
            toggleFocused: root.isFocused("awake")
            onToggled: { root.focusOn("awake"); root.activate("awake"); }
        }
    }

    Component {
        id: dndPiece
        ControlTile {
            palette.accent: Theme.zone(Zones.of("dnd"))
            s: root.s
            glyph: NotifHistory.dnd ? "bell-off" : "bell"
            title: "Do not disturb"
            status: root.dndShort
            on: NotifHistory.dnd
            available: Notifs.enabled
            opens: false
            toggleLabel: "Do not disturb"
            toggleFocused: root.isFocused("dnd")
            onToggled: { root.focusOn("dnd"); root.activate("dnd"); }
        }
    }
}
