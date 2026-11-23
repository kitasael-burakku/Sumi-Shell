pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "components"
import "services"
import "theme"

/**
 * VISTA PREVIA DE LOS COMPONENTES (rediseño, ARR-02).
 *
 * Una galería de las piezas comunes de `components/` en sus estados —normal, foco,
 * hover, seleccionado, deshabilitado, error, vacío, cargando— para revisar la fase 1
 * del rediseño sin abrir ninguna superficie real. **No ejecuta nada**: cada
 * activación sólo se anota en el log (`PREVIEW {…}`) y en la línea de estado.
 *
 * Qué importa y por qué es seguro: sólo `components/` y `theme/`. Sus singletons son
 * `Theme` → `Colors` (lee `colors.json` y `matugen/`, no escribe) y `Motion` →
 * `Settings` (escribe `settings.json` en `XDG_STATE_HOME`: por eso se lanza con uno
 * temporal). Ni notificaciones, ni polkit, ni IPC del shell, ni procesos.
 *
 * Vive en la raíz del shell porque un `qmldir` fuera de la raíz no carga los
 * módulos (memoria del proyecto). `shell.qml` no la importa.
 *
 *   st=$(mktemp -d); mkdir -p $st/sumi-shell
 *   echo '{"reduceMotion":false,"uiScale":1}' > $st/sumi-shell/settings.json
 *   XDG_STATE_HOME=$st qs -p <árbol>/preview-components.qml
 *
 * Entorno (todo opcional):
 *   PREVIEW_SCALE   escala (si no, `Settings.uiScale`).
 *   PREVIEW_BG      `desktop` (por defecto: el escritorio real detrás), `light` o `dark`.
 *   PREVIEW_SCREEN  pantalla; vacío = la enfocada.
 *   PREVIEW_MOTION  `normal`, `reduced` u `off` (si no, el de `Settings`).
 *   PREVIEW_INTERACTIVE=1  teclado EXCLUSIVO desde el arranque (para `wtype`); sin
 *                   él, sólo al hacer clic. Se suelta solo a los PREVIEW_INTERACTIVE_SEC
 *                   segundos (15), o antes con `quit` por IPC.
 *
 * Teclado: la ventana toma el teclado **sólo al hacer clic** en ella (OnDemand).
 * `Tab`/`Shift+Tab` recorren los controles, `Enter`/`Espacio` activan el enfocado,
 * `←`/`→` cambian el valor de un Toggle/Slider/Choice, `Esc` suelta el foco.
 * El hover del ratón NO mueve el foco de teclado (DESIGN §3).
 *
 * IPC `sumi-preview`: `set <clave> <json>` (scale, bg, cursor, motion),
 * `state`, `quit`.
 */
ShellRoot {
    id: root

    property real scaleOverride: Number(Quickshell.env("PREVIEW_SCALE") || 0)
    readonly property real s: root.scaleOverride > 0 ? root.scaleOverride : Settings.uiScale
    property string bg: Quickshell.env("PREVIEW_BG") || "desktop"
    property string screenName: Quickshell.env("PREVIEW_SCREEN")
        || (Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "")

    /**
     * Teclado EXCLUSIVO: todo lo que se teclea va a la preview, atajos del usuario
     * incluidos. El 2026-09-24 una preview así quedó abierta entre dos pruebas y se
     * tragó una pulsación de Super del usuario. Desde entonces se suelta SOLA a los
     * `PREVIEW_INTERACTIVE_SEC` segundos (15 por defecto) y pasa a OnDemand.
     */
    property bool interactive: Quickshell.env("PREVIEW_INTERACTIVE") === "1"
    Timer {
        running: root.interactive
        interval: 1000 * Number(Quickshell.env("PREVIEW_INTERACTIVE_SEC") || 15)
        onTriggered: {
            root.interactive = false;
            root.log({ ev: "keyboard released (timeout)" });
        }
    }
    Component.onCompleted: {
        const m = Quickshell.env("PREVIEW_MOTION") || "";
        if (m.length > 0) Motion.override = m;
    }

    /** El objetivo del teclado: índice en `slots`. -1 = ninguno. */
    property int cursor: 0
    /** Lo último que se habría hecho. */
    property string lastAction: "nothing yet"

    // Valores ficticios de los controles.
    property bool toggleA: false
    property bool toggleB: true
    property real sliderA: 0.35
    property string choiceA: "balanced"
    property string choiceB: "four"

    /** El orden de Tab. Cada entrada nombra un control de la galería. */
    readonly property var slots: [
        "btn.plain", "btn.primary", "btn.accent", "btn.danger", "btn.disabled",
        "btn.stacked", "hold",
        "toggleA", "toggleB", "sliderA", "choiceA", "choiceB", "search",
        "row.a", "row.b"
    ]
    function isFocused(id) { return root.cursor >= 0 && root.slots[root.cursor] === id; }

    function log(o) { console.log("PREVIEW " + JSON.stringify(o)); }
    function act(id, what) {
        root.lastAction = id + " → " + what;
        root.log({ ev: "activate", id: id, what: what });
    }

    function step(dir) {
        const n = root.slots.length;
        root.cursor = ((root.cursor < 0 ? (dir > 0 ? -1 : 0) : root.cursor) + dir + n) % n;
    }
    function activate() {
        const id = root.slots[root.cursor];
        switch (id) {
        case "toggleA": root.toggleA = !root.toggleA; root.act(id, String(root.toggleA)); break;
        case "toggleB": root.toggleB = !root.toggleB; root.act(id, String(root.toggleB)); break;
        case "btn.disabled": root.act(id, "ignored (disabled)"); break;
        case "search": root.act(id, "focus field"); break;
        default: root.act(id, "triggered");
        }
    }
    function adjust(dir) {
        const id = root.slots[root.cursor];
        if (id === "toggleA") root.toggleA = dir > 0;
        else if (id === "toggleB") root.toggleB = dir > 0;
        else if (id === "sliderA") root.sliderA = Math.max(0, Math.min(1, root.sliderA + dir * 0.05));
        else if (id === "choiceA") choiceAItem.cycle(dir);
        else if (id === "choiceB") choiceBItem.cycle(dir);
        else return;
        root.act(id, "adjust " + dir);
    }

    readonly property string longText: "An unusually long network name that will not fit in one row of a compact panel"

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win
            required property var modelData

            screen: win.modelData
            visible: win.modelData.name === root.screenName
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "sumi-preview"
            WlrLayershell.keyboardFocus: root.interactive ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand
            anchors { top: true; left: true }
            margins { top: 60; left: 40 }
            implicitWidth: backdrop.width
            implicitHeight: backdrop.height

            Rectangle {
                id: backdrop
                width: panel.width + 48
                height: panel.height + 48
                radius: 26 * root.s
                color: root.bg === "light" ? "#ecebe7" : root.bg === "dark" ? "#0c0c0e" : "transparent"

                Glass {
                    id: panel
                    s: root.s
                    x: 24; y: 24
                    width: grid.width + 32 * root.s
                    height: grid.height + 32 * root.s
                    radius: 22 * root.s

                    focus: true
                    Keys.onPressed: (event) => {
                        root.log({ ev: "key", key: event.key, mods: event.modifiers });
                        const back = (event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab;
                        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) root.step(back ? -1 : 1);
                        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) root.activate();
                        else if (event.key === Qt.Key_Left) root.adjust(-1);
                        else if (event.key === Qt.Key_Right) root.adjust(1);
                        else if (event.key === Qt.Key_Escape) root.cursor = -1;
                        else return;
                        event.accepted = true;
                    }

                    Row {
                        id: grid
                        x: 16 * root.s; y: 16 * root.s
                        spacing: 28 * root.s

                        // ── columna 1: tipografía ─────────────────────────────
                        Column {
                            width: 300 * root.s
                            spacing: 6 * root.s

                            SurfaceHeader { s: root.s; title: "TYPOGRAPHY"; aside: Typography.ui + " / mono"; width: parent.width }
                            Repeater {
                                model: [["display", Typography.display], ["title", Typography.title], ["body", Typography.body],
                                        ["label", Typography.label], ["caption", Typography.caption], ["micro", Typography.micro]]
                                delegate: Row {
                                    id: spec
                                    required property var modelData
                                    spacing: 8 * root.s
                                    Text {
                                        width: 60 * root.s
                                        text: spec.modelData[0]
                                        color: Theme.outlineText
                                        font.family: Typography.mono
                                        font.pixelSize: Typography.micro * root.s
                                        anchors.baseline: sample.baseline
                                    }
                                    Text {
                                        id: sample
                                        text: "Wi-Fi 12:45 · 87%"
                                        color: Theme.fg
                                        font.family: Typography.ui
                                        font.pixelSize: spec.modelData[1] * root.s
                                    }
                                }
                            }
                            Text {
                                width: parent.width
                                text: "mono · minimaru update --dry-run"
                                color: Theme.fgVariant
                                font.family: Typography.mono
                                font.pixelSize: Typography.body * root.s
                            }
                            Rectangle { width: parent.width; height: 1; color: Theme.hair }
                            Text {
                                width: parent.width
                                text: root.longText
                                elide: Text.ElideRight
                                color: Theme.fg
                                font.family: Typography.ui
                                font.pixelSize: Typography.body * root.s
                            }
                            Text {
                                width: parent.width
                                text: root.longText
                                wrapMode: Text.Wrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                                color: Theme.fgVariant
                                font.family: Typography.ui
                                font.pixelSize: Typography.label * root.s
                            }
                            Rectangle { width: parent.width; height: 1; color: Theme.hair }
                            Text {
                                width: parent.width
                                wrapMode: Text.Wrap
                                text: "Last action: " + root.lastAction
                                color: Theme.primary
                                font.family: Typography.mono
                                font.pixelSize: Typography.label * root.s
                            }
                            Text {
                                width: parent.width
                                wrapMode: Text.Wrap
                                text: "PREVIEW — nothing here runs. Click to take the keyboard; Tab moves, Enter activates."
                                color: Theme.outlineText
                                font.family: Typography.ui
                                font.pixelSize: Typography.caption * root.s
                            }
                        }

                        // ── columna 2: botones y controles ────────────────────
                        Column {
                            width: 280 * root.s
                            spacing: 8 * root.s

                            SurfaceHeader { s: root.s; title: "BUTTONS"; aside: "focus follows Tab"; width: parent.width }
                            Flow {
                                width: parent.width
                                spacing: 6 * root.s
                                ActionButton { s: root.s; label: "Open"; glyph: "search"; focused: root.isFocused("btn.plain"); onTriggered: root.act("btn.plain", "click") }
                                ActionButton { s: root.s; label: "Connect"; primary: true; focused: root.isFocused("btn.primary"); onTriggered: root.act("btn.primary", "click") }
                                ActionButton { s: root.s; label: "Keep"; accent: true; focused: root.isFocused("btn.accent"); onTriggered: root.act("btn.accent", "click") }
                                ActionButton { s: root.s; label: "Forget"; danger: true; focused: root.isFocused("btn.danger"); onTriggered: root.act("btn.danger", "click") }
                                ActionButton { s: root.s; label: "Hibernate"; enabled: false; focused: root.isFocused("btn.disabled"); onTriggered: root.act("btn.disabled", "click") }
                            }
                            Row {
                                spacing: 8 * root.s
                                ActionButton { s: root.s; stacked: true; label: "Lock"; glyph: "lock"; focused: root.isFocused("btn.stacked"); onTriggered: root.act("btn.stacked", "click") }
                                HoldButton { id: holdItem; s: root.s; label: "Hold to shut down"; glyph: "power"; tone: "danger"; onFired: root.act("hold", "fired (hold)") }
                                // La pista de un HoldButton la pinta su dueño (así lo hace la esquina de energía del lock).
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: holdItem.hintVisible || root.isFocused("hold") ? holdItem.label : ""
                                    color: Theme.fgVariant
                                    font.family: Typography.ui
                                    font.pixelSize: Typography.caption * root.s
                                }
                            }

                            SurfaceHeader { s: root.s; title: "CONTROLS"; width: parent.width }
                            Row {
                                spacing: 12 * root.s
                                Toggle { id: toggleAItem; onKnobXChanged: root.knobA = knobX; Component.onCompleted: root.knobA = knobX; s: root.s; label: "Toggle A"; focused: root.isFocused("toggleA"); on: root.toggleA; onToggled: { root.toggleA = !root.toggleA; root.act("toggleA", String(root.toggleA)); } }
                                Toggle { s: root.s; label: "Toggle B"; focused: root.isFocused("toggleB"); on: root.toggleB; onToggled: { root.toggleB = !root.toggleB; root.act("toggleB", String(root.toggleB)); } }
                                Toggle { s: root.s; label: "Unavailable"; on: true; enabled: false }
                            }
                            Slider {
                                s: root.s
                                width: parent.width
                                label: "Volume"
                                focused: root.isFocused("sliderA")
                                value: root.sliderA
                                onMoved: (v) => { root.sliderA = v; root.act("sliderA", v.toFixed(2)); }
                            }
                            Choice {
                                id: choiceAItem
                                s: root.s
                                name: "Density"
                                focused: root.isFocused("choiceA")
                                value: root.choiceA
                                options: [{ label: "Compact", value: "compact" }, { label: "Balanced", value: "balanced" }, { label: "Roomy", value: "roomy" }]
                                onPicked: (v) => { root.choiceA = v; root.act("choiceA", v); }
                            }
                            Choice {
                                id: choiceBItem
                                s: root.s
                                name: "Count"
                                focused: root.isFocused("choiceB")
                                value: root.choiceB
                                options: ["one", "two", "three", "four", "five", "six"].map(n => ({ label: n.charAt(0).toUpperCase() + n.slice(1), value: n }))
                                onPicked: (v) => { root.choiceB = v; root.act("choiceB", v); }
                            }
                            SearchField { s: root.s; width: parent.width; placeholder: "Type to search" }
                            SearchField { s: root.s; width: parent.width; placeholder: "Search"; text: root.longText }
                            Text {
                                width: parent.width
                                wrapMode: Text.Wrap
                                text: "Keyboard target: " + (root.cursor >= 0 ? root.slots[root.cursor] : "none")
                                color: Theme.fgVariant
                                font.family: Typography.mono
                                font.pixelSize: Typography.caption * root.s
                            }
                        }

                        // ── columna 3: filas y estados ────────────────────────
                        Column {
                            width: 330 * root.s
                            spacing: 8 * root.s

                            SurfaceHeader { s: root.s; title: "ROWS"; aside: "3 settings"; width: parent.width }
                            Column {
                                width: parent.width
                                SettingRow {
                                    s: root.s; name: "Motion"; caption: "Mode: " + Motion.mode
                                    focused: root.isFocused("row.a")
                                    onActivated: root.act("row.a", "click")
                                    Toggle { s: root.s; label: "Motion"; on: Motion.mode === "normal" }
                                }
                                SettingRow {
                                    s: root.s; name: "Interface scale"; caption: root.longText
                                    focused: root.isFocused("row.b")
                                    onActivated: root.act("row.b", "click")
                                    Text { text: root.s.toFixed(2); color: Theme.fg; font.family: Typography.mono; font.pixelSize: Typography.body * root.s }
                                }
                                SettingRow {
                                    s: root.s; name: "Equalizer"; caption: "Per-device EQ"; last: true
                                    available: false; reason: "Unavailable: no equalizer backend installed"
                                    Toggle { s: root.s; label: "Equalizer"; on: false }
                                }
                            }

                            SurfaceHeader { s: root.s; title: "STATES"; width: parent.width }
                            Notice { s: root.s; width: parent.width; tone: "info"; text: "Ready — 25 pages" }
                            Notice { s: root.s; width: parent.width; tone: "ok"; text: "Connected" }
                            Notice { s: root.s; width: parent.width; tone: "warn"; text: "Stale — last update 3 min ago" }
                            Notice { s: root.s; width: parent.width; tone: "danger"; text: "Could not read websites.conf: permission denied" }
                            Row {
                                spacing: 8 * root.s
                                Empty { s: root.s; width: 160 * root.s; glyph: "search"; text: "No results"; hint: "Try another word" }
                                Empty { s: root.s; width: 160 * root.s; loading: true; text: "Loading" }
                            }
                        }
                    }
                }
            }
        }
    }

    /**
     * Muestreo de movimiento: cambia Toggle A y anota dónde está su pomo en cada
     * fotograma durante 400 ms. En `off` debe llegar en el primer fotograma.
     */
    property var samples: []
    property real knobA: 0
    FrameAnimation {
        id: sampler
        property real t0: 0
        onTriggered: {
            const t = Date.now() - sampler.t0;
            root.samples = root.samples.concat([[t, Math.round(root.knobA * 10) / 10]]);
            if (t > 400) sampler.stop();
        }
    }

    IpcHandler {
        target: "sumi-preview"

        function sample(): bool {
            root.samples = [[0, Math.round(root.knobA * 10) / 10]];
            sampler.t0 = Date.now();
            root.toggleA = !root.toggleA;
            sampler.start();
            return true;
        }
        function samples(): string { return JSON.stringify(root.samples); }

        function set(key: string, json: string): bool {
            let v;
            try { v = JSON.parse(json); } catch (e) { return false; }
            switch (key) {
            case "scale": root.scaleOverride = v; break;
            case "bg": root.bg = v; break;
            case "cursor": root.cursor = v; break;
            case "motion": Motion.override = v; break;
            default: return false;
            }
            return true;
        }
        function state(): string {
            return JSON.stringify({ s: root.s, bg: root.bg, cursor: root.cursor,
                target: root.cursor >= 0 ? root.slots[root.cursor] : null,
                last: root.lastAction, motion: Motion.mode,
                ui: Typography.ui, mono: Typography.mono });
        }
        function quit(): void { Qt.quit(); }
    }
}
