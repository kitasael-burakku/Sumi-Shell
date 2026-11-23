pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Widgets
import "../theme"
import "../services"
import "../components"
import "../lib/text-wrap.js" as TextWrap

/**
 * Screen recorder: a quick tool, sibling of the wallpaper strip. Status on top, the few options in
 * the header, the choices as cards and the keys in the footer.
 *
 * 2026-10-29 (pedido del usuario: «como una surface hermana de Wallpapers»). De la tira de Wallpaper
 * se toma tal cual el esqueleto —fila superior, cabecera con chips, tira de tarjetas, pie con la ayuda
 * o un aviso del mismo alto—, las zonas de teclado (tarjetas ⇄ opciones con Tab), las letras directas,
 * el contexto de Back/Forward, y de la tira: el `pos` que persigue al foco con `Motion.chaseTau`, la
 * profundidad por oscurecimiento y la sombra sólo en la enfocada. Cambia lo que hay que enseñar:
 *
 *   en reposo     los MODOS (Full screen / Region / Choose screen con varias pantallas); la tarjeta
 *                 enfocada es el modo elegido y Enter graba con él;
 *   grabando      las ACCIONES (Pause o Resume, Stop and save); preparando (cuenta atrás, región),
 *                 Cancel; guardando, una sola tarjeta que lo dice.
 *
 * Lo que se graba lo lleva `services/ScreenRecorder`; la surface sólo elige y manda. Empezar la cierra:
 * el panel no sale en el vídeo y slurp tiene el puntero y el teclado para él solo. Mientras se graba, el
 * control persistente es la pieza bajo el island o el tramo de la barra; ésta sigue siendo el centro.
 *
 * Grabador 2.0 (2026-10-29): los chips editan los ajustes de Settings → Screen recording (no una copia), con el
 * preset Custom y la cuenta atrás con su duración; una línea dice lo que se grabará (el plan del helper: tamaño,
 * fps, codificador, formato, audio). Dos vistas más con las mismas tarjetas:
 *   Completed     Play · Show in folder · New recording, y los chips Copy file / Copy path; la línea dice
 *                 duración, tamaño y cómo se grabó;
 *   Error         qué pasó en una frase (el detalle en el pie) · Recover si quedaron tramos, o Settings si es
 *                 algo de la configuración · Try again · Dismiss.
 * Grabando, los chips quedan quietos (cambiarlos exigiría reiniciar el codificador); el engranaje (o «,») lleva a
 * Settings, donde lo de comportamiento se aplica al momento.
 */
Surface {
    id: root

    mTop: 10
    mLeft: 0
    mRight: 0
    mBottom: Metrics.sp3
    clip: true
    // Crecer hacia abajo cuando el mensaje necesita más sitio; las tarjetas conservan su área.
    implicitHeight: Metrics.recorderH * root.s + Math.max(0, footer.height - 14 * root.s)
        + (root.mBottom - 8) * root.s

    /** El ancho de DESTINO de las filas de texto (como la tira): se recortan con el panel al abrir. */
    readonly property real rowW: Math.max(0, Math.min((Metrics.recorderW - 48) * root.s, root.width - 24 * root.s))
    /** El estado se comunica con etiqueta, forma y un tono legible de la paleta. */
    readonly property color recRed: Theme.dangerText

    readonly property var here: {
        const list = Quickshell.screens;
        for (let i = 0; i < list.length; i++)
            if (list[i].name === root.screenName) return list[i];
        return null;
    }
    readonly property string hereText: root.screenName + (root.here ? " · " + root.here.width + "×" + root.here.height : "")

    // ---- tarjetas ------------------------------------------------------------------------------

    readonly property var modeCards: {
        const out = [
            { key: "screen", glyph: "monitor", label: ScreenRecorder.multiScreen ? "This screen" : "Full screen",
              hint: root.hereText },
            { key: "region", glyph: "region", label: "Region", hint: "Area or window" }
        ];
        if (ScreenRecorder.multiScreen)
            out.push({ key: "output", glyph: "monitor-multiple", label: "Choose screen", hint: "Click a screen" });
        return out;
    }
    readonly property var actionCards: {
        const st = ScreenRecorder.status;
        if (ScreenRecorder.preparing)
            return [{ key: "cancel", glyph: "close", label: "Cancel", hint: ScreenRecorder.statusText }];
        if (st === "saving")
            return [{ key: "saving", glyph: "recorder", label: "Saving…", hint: "Joining the parts into one video" }];
        return [
            ScreenRecorder.paused ? { key: "resume", glyph: "play", label: "Resume", hint: "Space" }
                                  : { key: "pause", glyph: "pause", label: "Pause", hint: "Space" },
            { key: "stop", glyph: "stop", label: "Stop and save", hint: "S" }
        ];
    }
    /** Completed: lo guardado (Play, carpeta) y volver a los modos. */
    readonly property var resultCards: {
        const r = ScreenRecorder.result || {};
        return [{ key: "play", glyph: "play", label: "Play", hint: (r.durationMs > 0 ? ScreenRecorder.fmt(r.durationMs) : "")
                  + (r.bytes > 0 ? " · " + ScreenRecorder.fmtBytes(r.bytes) : "") },
                { key: "folder", glyph: "folder-open", label: "Show in folder", hint: "O" },
                { key: "new", glyph: "record", label: "New recording", hint: "N" }];
    }
    /** Error: recuperar los tramos o ir a lo que hay que cambiar; reintentar; descartar. */
    readonly property bool errorFixable: ["folder", "space", "format", "encoder", "audio"].indexOf(ScreenRecorder.lastErrorKind) >= 0
    readonly property var errorCards: {
        const out = [];
        if (ScreenRecorder.recoverWork.length > 0)
            out.push({ key: "recover", glyph: "history", label: ScreenRecorder.recovering ? "Recovering…" : "Recover",
                       hint: "Join the recorded parts" });
        else if (root.errorFixable) out.push({ key: "settings", glyph: "cog", label: "Settings", hint: "Screen recording" });
        out.push({ key: "retry", glyph: "record", label: "Try again", hint: "R" });
        out.push({ key: "dismiss", glyph: "close", label: "Dismiss", hint: "Back to modes" });
        return out;
    }
    readonly property bool acting: ScreenRecorder.active
    /** modes · actions (grabando) · result (Completed) · error. */
    readonly property string view: root.acting ? "actions" : ScreenRecorder.showError ? "error"
        : ScreenRecorder.showResult && ScreenRecorder.result ? "result" : "modes"
    readonly property var cards: root.view === "actions" ? root.actionCards : root.view === "result" ? root.resultCards
        : root.view === "error" ? root.errorCards : root.modeCards
    readonly property int cardCount: root.cards.length
    property int focusIndex: 0
    property real pos: 0
    readonly property var focused: root.focusIndex >= 0 && root.focusIndex < root.cardCount ? root.cards[root.focusIndex] : null

    function indexOfKey(k) {
        for (let i = 0; i < root.cards.length; i++)
            if (root.cards[i].key === k) return i;
        return -1;
    }
    /**
     * El foco al cambiar de juego de tarjetas: el modo elegido, Stop (lo que se viene a hacer), Play si se acaba de
     * guardar con la surface abierta o New recording si se abre después, y la primera de un error.
     */
    property bool justFinished: false
    function resetFocus() {
        const k = root.view === "actions" ? "stop" : root.view === "result" ? (root.justFinished ? "play" : "new")
            : root.view === "error" ? root.cards[0].key : ScreenRecorder.mode;
        const i = root.indexOfKey(k);
        root.focusIndex = Math.max(0, i);
        root.pos = root.focusIndex;
        if (root.zone === "options" && root.options.length === 0) root.zone = "cards";
        root.optionIndex = Math.min(root.optionIndex, Math.max(0, root.options.length - 1));
    }
    onViewChanged: {
        root.justFinished = root.open && root.view === "result";
        // Las tarjetas dependen de view: esperar a que el binding vea el juego nuevo.
        Qt.callLater(root.resetFocus);
    }
    onFocusIndexChanged: if (Motion.off) root.pos = root.focusIndex
    Connections {
        target: Motion
        function onOffChanged() { if (Motion.off) root.pos = root.focusIndex; }
    }
    onCardCountChanged: if (root.focusIndex >= root.cardCount) root.focusIndex = Math.max(0, root.cardCount - 1)

    function move(delta) {
        if (root.cardCount === 0) return;
        root.focusIndex = Math.max(0, Math.min(root.cardCount - 1, root.focusIndex + delta));
        // en reposo, la tarjeta enfocada ES el modo (se recuerda para la próxima vez)
        if (root.view === "modes" && root.focused) {
            ScreenRecorder.mode = root.focused.key;
            ScreenRecorder.wantPlan(root.screenName, root.focused.key);
        }
    }

    /** Lo que impide grabar en el modo enfocado, fijo en el pie (F2c: dicho ANTES de pulsar). */
    readonly property string capNote: root.view !== "modes" ? "" : ScreenRecorder.whyNotMode(root.focused ? root.focused.key : "screen")
    /** Lo que avisa el plan (fps por encima del refresco, un codificador que no se puede y su sustituto…). */
    readonly property string planWarning: root.view === "modes" && ScreenRecorder.planNow && ScreenRecorder.planNow.warnings
        && ScreenRecorder.planNow.warnings.length > 0 ? ScreenRecorder.planNow.warnings[0] : ""

    function openSettings() { if (root.host) root.host.openSettingsAt("shell/recording"); }
    function activate(k) {
        if (!k) return;
        if (k === "play") ScreenRecorder.openLast();
        else if (k === "folder") ScreenRecorder.openFolder();
        else if (k === "new") ScreenRecorder.dismissResult();
        else if (k === "recover") ScreenRecorder.recover();
        else if (k === "settings") root.openSettings();
        else if (k === "dismiss") ScreenRecorder.dismissError();
        else if (k === "retry") { if (ScreenRecorder.retry(root.screenName)) root.requestClose(); }
        else if (k === "copy") ScreenRecorder.copyLast();
        else if (k === "copyPath") ScreenRecorder.copyPath();
        if (k === "screen" || k === "region" || k === "output") {
            ScreenRecorder.mode = k;
            if (ScreenRecorder.start(k, root.screenName)) root.requestClose();
        } else if (k === "pause" || k === "resume") {
            ScreenRecorder.togglePause();
        } else if (k === "stop") {
            ScreenRecorder.stop();
        } else if (k === "cancel") {
            ScreenRecorder.cancel();
        }
    }

    // ---- opciones (chips) ----------------------------------------------------------------------

    /** cards · options (Tab las alterna; las opciones sólo en reposo). */
    property string zone: "cards"
    property int optionIndex: 0
    /** Los chips: en reposo (y en un error) lo que se usará; en Completed, copiar. Son los ajustes de Settings. */
    readonly property var modeOptions: [
        { key: "system", label: "System audio", on: ScreenRecorder.systemAudio && ScreenRecorder.systemAvailable,
          usable: ScreenRecorder.systemAvailable, off: "No system audio" },
        { key: "mic", label: ScreenRecorder.micAvailable ? "Mic" : "No mic", on: ScreenRecorder.mic && ScreenRecorder.micAvailable,
          usable: ScreenRecorder.micAvailable, off: "No microphone found" },
        { key: "standard", label: "Standard", on: ScreenRecorder.preset === "standard", usable: true, group: true, radio: true },
        { key: "high", label: "High", on: ScreenRecorder.preset === "high", usable: true, radio: true },
        { key: "custom", label: "Custom", on: ScreenRecorder.preset === "custom", usable: true, radio: true },
        { key: "delay", label: ScreenRecorder.delay ? ScreenRecorder.delaySec + " s delay" : "No delay", on: ScreenRecorder.delay,
          usable: true, group: true }
    ]
    readonly property var resultOptions: [
        { key: "copy", label: "Copy file", on: false, usable: ScreenRecorder.canCopy, off: "Copy needs wl-clipboard", action: true },
        { key: "copyPath", label: "Copy path", on: false, usable: ScreenRecorder.canCopy, off: "Copy needs wl-clipboard", action: true }
    ]
    readonly property var options: root.view === "result" ? root.resultOptions : root.modeOptions
    function toggleOption(k) {
        if (root.acting) return;
        if (k === "copy" || k === "copyPath") { root.activate(k); return; }
        if (k === "system") ScreenRecorder.setSystemAudio(!ScreenRecorder.systemAudio);
        else if (k === "mic") ScreenRecorder.setMic(!ScreenRecorder.mic);
        else if (k === "standard" || k === "high" || k === "custom") ScreenRecorder.setPreset(k);
        else if (k === "quality") ScreenRecorder.cyclePreset();
        else if (k === "delay") ScreenRecorder.toggleDelay();
    }
    function goZone(z) {
        root.zone = z === "options" && !root.acting ? "options" : "cards";
        if (root.zone === "options") root.optionIndex = 0;
        root.forceActiveFocus();
    }

    // ---- contexto, estado y teclado ------------------------------------------------------------

    function saveContext() { return { zone: root.zone, focus: root.focused ? root.focused.key : "" }; }
    function restoreContext(ctx) {
        if (!ctx) return true;
        root.zone = ctx.zone === "options" && !root.acting ? "options" : "cards";
        root.optionIndex = Math.min(root.optionIndex, Math.max(0, root.options.length - 1));
        const i = root.indexOfKey(String(ctx.focus || ""));
        if (i >= 0) { root.focusIndex = i; root.pos = i; }
        return true;
    }

    /** Para el IPC (`recorderView`). */
    function viewState() {
        return { view: root.view, spec: specText.text, warning: root.planWarning,
                 zone: root.zone, cards: root.cards.map(c => c.key), focus: root.focused ? root.focused.key : "",
                 focusIndex: root.focusIndex, optionFocus: root.zone === "options" ? root.options[root.optionIndex].key : "",
                 options: root.options.map(o => ({ key: o.key, label: o.label, on: o.on, usable: o.usable })),
                 status: statusLabel.text, title: titleText.text, side: sideText.text, hint: footerHint.text,
                 notice: root.footerNotice, noticeTone: root.footerTone, capNote: root.capNote, footerWarn: root.footerWarn,
                 copyVisible: copyButton.visible, cardHints: root.cards.map(c => c.hint || "") };
    }

    /** Keys arrive from the Screen's FocusScope; Escape is left to the host (except in the options). */
    function keyPressed(event) {
        if (event.isAutoRepeat && [Qt.Key_Left, Qt.Key_Right].indexOf(event.key) < 0) { event.accepted = true; return; }
        if (root.zone === "options") {
            switch (event.key) {
            case Qt.Key_Left:  root.optionIndex = Math.max(0, root.optionIndex - 1); event.accepted = true; return;
            case Qt.Key_Right: root.optionIndex = Math.min(root.options.length - 1, root.optionIndex + 1); event.accepted = true; return;
            case Qt.Key_Return:
            case Qt.Key_Enter:
            case Qt.Key_Space: root.toggleOption(root.options[root.optionIndex].key); event.accepted = true; return;
            case Qt.Key_Up: event.accepted = true; return;
            case Qt.Key_Down:
            case Qt.Key_Escape:
            case Qt.Key_Tab:
            case Qt.Key_Backtab: root.goZone("cards"); event.accepted = true; return;
            }
        }
        switch (event.key) {
        case Qt.Key_Left:  root.move(-1); event.accepted = true; break;
        case Qt.Key_Right: root.move(1); event.accepted = true; break;
        case Qt.Key_Home:  root.move(-root.cardCount); event.accepted = true; break;
        case Qt.Key_End:   root.move(root.cardCount); event.accepted = true; break;
        case Qt.Key_Return:
        case Qt.Key_Enter: root.activate(root.focused ? root.focused.key : ""); event.accepted = true; break;
        // Espacio: con vídeo, pausa o reanuda esté donde esté el foco; si no, como Enter
        case Qt.Key_Space:
            if (ScreenRecorder.live) ScreenRecorder.togglePause();
            else root.activate(root.focused ? root.focused.key : "");
            event.accepted = true;
            break;
        case Qt.Key_Tab:
        case Qt.Key_Backtab:
        case Qt.Key_Up: root.goZone("options"); event.accepted = true; break;
        case Qt.Key_S: if (ScreenRecorder.live) ScreenRecorder.stop(); event.accepted = true; break;
        // C: preparando, cancela; en reposo, copia la última (nunca a la vez: preparar no deja nada que copiar)
        case Qt.Key_C:
            if (ScreenRecorder.preparing) ScreenRecorder.cancel();
            else if (!root.acting) ScreenRecorder.copyLast();
            event.accepted = true;
            break;
        // P: la ruta como texto (Completed); N: otra grabación; R: reintentar tras un error
        case Qt.Key_P: if (!root.acting) ScreenRecorder.copyPath(); event.accepted = true; break;
        case Qt.Key_N: if (root.view === "result") ScreenRecorder.dismissResult(); event.accepted = true; break;
        case Qt.Key_R: if (root.view === "error") root.activate("retry"); event.accepted = true; break;
        case Qt.Key_A: if (root.view !== "result") root.toggleOption("system"); event.accepted = true; break;
        case Qt.Key_M: if (root.view !== "result") root.toggleOption("mic"); event.accepted = true; break;
        case Qt.Key_Q: if (root.view !== "result") root.toggleOption("quality"); event.accepted = true; break;
        case Qt.Key_D: if (root.view !== "result") root.toggleOption("delay"); event.accepted = true; break;
        case Qt.Key_O: ScreenRecorder.openFolder(); event.accepted = true; break;
        case Qt.Key_L: if (!root.acting) ScreenRecorder.openLast(); event.accepted = true; break;
        // «,»: Settings → Screen recording (como S en Wallpaper; aquí S para y guarda)
        case Qt.Key_Comma: if (!event.isAutoRepeat) root.openSettings(); event.accepted = true; break;
        }
    }

    onOpenChanged: if (open) {
        // Completed de hace más de 5 minutos: se abre para grabar otra
        if (ScreenRecorder.showResult && !ScreenRecorder.resultFresh()) ScreenRecorder.dismissResult();
        // sin «recordar el modo» (Settings), cada vez empieza en Full screen
        if (!Settings.recRememberMode && !root.acting) ScreenRecorder.mode = "screen";
        ScreenRecorder.refreshProbe();
        root.zone = "cards";
        root.justFinished = false;
        root.resetFocus();
        ScreenRecorder.wantPlan(root.screenName, root.view === "modes" && root.focused ? root.focused.key : ScreenRecorder.mode);
    } else {
        // Completed se ve una vez: al cerrar después de verlo, la próxima vez vuelve a los modos
        if (root.view === "result") ScreenRecorder.dismissResult();
        ScreenRecorder.planScreen = "";
    }

    /** El chase de la tira (`surfaces/Wallpaper`): `pos` cierra 1/e del hueco cada `Motion.chaseTau`. */
    FrameAnimation {
        running: !Motion.off && root.open && root.pos !== root.focusIndex
        onTriggered: {
            const k = 1 - Math.exp(-frameTime / Motion.chaseTau);
            const next = root.pos + (root.focusIndex - root.pos) * k;
            root.pos = Math.abs(next - root.focusIndex) < 0.001 ? root.focusIndex : next;
        }
    }
    function lerp(arr, d) { return arr[0] + (arr[1] - arr[0]) * Math.min(1, d); }

    // ---- estado (el sitio de la búsqueda en la tira) -------------------------------------------

    Item {
        id: statusRow
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.rowW
        height: 26 * root.s

        Rectangle {
            id: statusPill
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: statusInner.implicitWidth + 20 * root.s
            height: 26 * root.s
            radius: Metrics.r(8) * root.s
            readonly property color tone: root.view === "error" || ScreenRecorder.status === "recording" ? Theme.dangerText
                : ScreenRecorder.paused || ScreenRecorder.status === "saving" ? Theme.warningText
                : root.view === "result" ? Theme.successText : Theme.fgVariant
            color: Theme.mix(Theme.cardBg, statusPill.tone, 0.10)
            Accessible.role: Accessible.StaticText
            Accessible.name: statusLabel.text

            Row {
                id: statusInner
                anchors.centerIn: parent
                spacing: 7 * root.s
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !ScreenRecorder.paused
                    width: 8 * root.s
                    height: width
                    radius: Metrics.pill(width)
                    color: ScreenRecorder.status === "recording" ? root.recRed : "transparent"
                    border.width: ScreenRecorder.status === "recording" ? 0 : Math.max(1, 1.5 * root.s)
                    border.color: ScreenRecorder.active ? root.recRed : Theme.outline
                    Behavior on color { ColorAnimation { duration: Motion.fast } }
                }
                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: ScreenRecorder.paused
                    name: "pause"
                    size: 12 * root.s
                    color: Theme.warn
                }
                Text {
                    id: statusLabel
                    anchors.verticalCenter: parent.verticalCenter
                    text: ScreenRecorder.status === "recording" ? "Recording"
                        : ScreenRecorder.status === "paused" ? "Paused"
                        : root.view === "result" ? "Saved"
                        : root.view === "error" ? (ScreenRecorder.recovering ? "Recovering…" : "Failed")
                        : ScreenRecorder.status === "idle" ? (root.capNote.length > 0 ? "Unavailable" : "Ready")
                        : ScreenRecorder.statusText
                    color: Theme.legibleOn(statusPill.tone, statusPill.color, 4.5)
                    font.family: Typography.ui
                    font.pixelSize: Typography.body * root.s
                    font.weight: Font.DemiBold
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: ScreenRecorder.live
                    text: ScreenRecorder.clock
                    color: ScreenRecorder.paused ? Theme.fgVariant : Theme.fg
                    font.family: Typography.mono
                    font.pixelSize: Typography.body * root.s
                    font.features: { "tnum": 1 }
                }
            }
        }

        /** El último archivo (o la carpeta donde irá), con abrir (L) y la carpeta (O). */
        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6 * root.s

            Text {
                id: sideText
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, root.rowW - statusPill.width - 122 * root.s)
                elide: Text.ElideMiddle
                text: ScreenRecorder.lastFile.length > 0 ? "Last · " + ScreenRecorder.baseName(ScreenRecorder.lastFile)
                    : ScreenRecorder.outputDir.length > 0 ? "Saves to " + ScreenRecorder.outputDir.replace(Quickshell.env("HOME") || "\u0000", "~")
                    : ""
                color: Theme.fgVariant
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
            }
            /** Abrir la última (L): sólo en reposo y si la hay. */
            Item {
                anchors.verticalCenter: parent.verticalCenter
                visible: ScreenRecorder.lastFile.length > 0 && !root.acting
                width: 20 * root.s
                height: 18 * root.s
                Accessible.role: Accessible.Button
                Accessible.name: "Play the last recording (L)"
                Accessible.onPressAction: ScreenRecorder.openLast()
                Icon {
                    anchors.centerIn: parent
                    name: "play"
                    size: 13 * root.s
                    color: lastArea.containsMouse ? Theme.fg : Theme.fgVariant
                }
                MouseArea {
                    id: lastArea
                    anchors.fill: parent
                    anchors.margins: -5 * root.s
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: ScreenRecorder.openLast()
                }
            }
            /** Copiarla al portapapeles como archivo (C), para pegarla en un chat o un gestor de archivos. */
            Item {
                id: copyButton
                anchors.verticalCenter: parent.verticalCenter
                visible: ScreenRecorder.canCopy && !root.acting
                width: 20 * root.s
                height: 18 * root.s
                Accessible.role: Accessible.Button
                Accessible.name: "Copy the last recording (C)"
                Accessible.onPressAction: ScreenRecorder.copyLast()
                Icon {
                    anchors.centerIn: parent
                    name: "copy"
                    size: 13 * root.s
                    color: copyArea.containsMouse ? Theme.fg : Theme.fgVariant
                }
                MouseArea {
                    id: copyArea
                    anchors.fill: parent
                    anchors.margins: -5 * root.s
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: ScreenRecorder.copyLast()
                }
            }
            /** La carpeta de las grabaciones (O). */
            Item {
                anchors.verticalCenter: parent.verticalCenter
                width: 20 * root.s
                height: 18 * root.s
                Accessible.role: Accessible.Button
                Accessible.name: "Open the recordings folder (O)"
                Accessible.onPressAction: ScreenRecorder.openFolder()
                Icon {
                    anchors.centerIn: parent
                    name: "folder-open"
                    size: 13 * root.s
                    color: folderArea.containsMouse ? Theme.fg : Theme.fgVariant
                }
                MouseArea {
                    id: folderArea
                    anchors.fill: parent
                    anchors.margins: -5 * root.s
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: ScreenRecorder.openFolder()
                }
            }
            /** Settings → Screen recording («,»): formato, audio, carpeta, el HUD… */
            Item {
                id: settingsButton
                anchors.verticalCenter: parent.verticalCenter
                width: 20 * root.s
                height: 18 * root.s
                Accessible.role: Accessible.Button
                Accessible.name: "Recording settings (,)"
                Accessible.onPressAction: root.openSettings()
                Icon {
                    anchors.centerIn: parent
                    name: "cog"
                    size: 12 * root.s
                    color: cfgArea.containsMouse ? Theme.fg : Theme.fgVariant
                }
                MouseArea {
                    id: cfgArea
                    anchors.fill: parent
                    anchors.margins: -5 * root.s
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openSettings()
                }
            }
        }
    }

    // ---- cabecera: qué hace la tarjeta enfocada y las opciones --------------------------------

    Item {
        id: header
        anchors.top: statusRow.bottom
        anchors.topMargin: Metrics.sp3 * root.s
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.rowW
        height: chipRow.implicitHeight + (root.view === "modes" ? 0 : 28 * root.s)

        Row {
            anchors.left: parent.left
            anchors.top: parent.top
            height: 20 * root.s
            spacing: 7 * root.s
            Text {
                id: titleText
                visible: root.view !== "modes"
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, root.rowW)
                elide: Text.ElideRight
                // lo que hará Enter (la tarjeta ya dice el detalle): modo y audio; grabando, qué y con qué;
                // Completed, el archivo; un error, lo que pasó en una frase
                text: root.view === "result" ? ScreenRecorder.baseName(ScreenRecorder.result.file)
                    : root.view === "error" ? ScreenRecorder.errorTitle(ScreenRecorder.lastErrorKind)
                    : !root.focused ? "" : (root.acting ? ScreenRecorder.targetLabel : root.focused.label)
                        + "  ·  " + ScreenRecorder.audioLabel
                color: Theme.fg
                font.family: Typography.ui
                font.pixelSize: Typography.body * root.s
                font.weight: Font.DemiBold
            }
        }

        /** Las opciones, como los filtros de la tira; quietas mientras se graba (valen al empezar). */
        Flow {
            id: chipRow
            width: parent.width
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            spacing: 8 * root.s
            opacity: root.acting ? 0.45 : 1
            Behavior on opacity { NumberAnimation { duration: Motion.fast } }

            Repeater {
                model: root.options
                delegate: Row {
                    id: opt
                    required property var modelData
                    required property int index
                    spacing: 4 * root.s
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: opt.modelData.group === true
                        width: 1
                        height: 12 * root.s
                        color: Theme.hair
                    }
                    Rectangle {
                        id: chip
                        readonly property bool on: opt.modelData.on
                        anchors.verticalCenter: parent.verticalCenter
                        width: chipLabel.implicitWidth + 12 * root.s
                        height: 24 * root.s
                        radius: Metrics.pill(height)
                        opacity: opt.modelData.usable ? 1 : 0.45
                        color: Theme.controlBg("transparent", chipArea.containsMouse && opt.modelData.usable, chipArea.pressed && chipArea.containsMouse, chip.on)
                        border.width: root.zone === "options" && root.optionIndex === opt.index ? Metrics.focusWidth * root.s : 0
                        border.color: Theme.selBorder
                        Accessible.role: opt.modelData.action === true ? Accessible.Button
                            : opt.modelData.radio === true ? Accessible.RadioButton : Accessible.CheckBox
                        Accessible.name: opt.modelData.usable ? opt.modelData.label : opt.modelData.off
                        Accessible.checked: chip.on
                        Accessible.onPressAction: root.toggleOption(opt.modelData.key)
                        Behavior on color { ColorAnimation { duration: Motion.fast } }
                        Text {
                            id: chipLabel
                            anchors.centerIn: parent
                            text: opt.modelData.label
                            color: chip.on ? Theme.primary : Theme.fgVariant
                            font.family: Typography.ui
                            font.pixelSize: Typography.caption * root.s
                            font.weight: Font.DemiBold
                        }
                        MouseArea {
                            id: chipArea
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: !root.acting
                            cursorShape: opt.modelData.usable ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: root.toggleOption(opt.modelData.key)
                        }
                    }
                }
            }
        }
    }

    // ---- lo que se grabará (o lo grabado) -------------------------------------------------------

    /**
     * Una línea, del plan del helper (no calculada aquí): en reposo el preset y lo que dará con lo elegido; grabando,
     * lo que se está usando; en Completed, duración, tamaño y cómo se grabó. Custom se dice siempre por su nombre.
     */
    readonly property var shownParams: (root.view === "actions" || root.view === "error") && ScreenRecorder.st ? ScreenRecorder.st.params
        : root.view === "result" && ScreenRecorder.result ? ScreenRecorder.result.params : ScreenRecorder.planNow
    readonly property string presetOf: {
        const p = root.shownParams && root.shownParams.preset ? root.shownParams.preset : ScreenRecorder.preset;
        return ({ standard: "Standard", high: "High", custom: "Custom" })[p] || "";
    }
    Text {
        id: specText
        anchors.top: header.bottom
        anchors.topMargin: Metrics.sp2 * root.s
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.rowW
        height: 15 * root.s
        elide: Text.ElideRight
        verticalAlignment: Text.AlignVCenter
        text: {
            const spec = ScreenRecorder.specOf(root.shownParams, root.view !== "result");
            if (root.view === "result") {
                const r = ScreenRecorder.result || {};
                const head = [r.durationMs > 0 ? ScreenRecorder.fmt(r.durationMs) : "", ScreenRecorder.fmtBytes(r.bytes)]
                    .filter(x => x.length > 0).join(" · ");
                return head + (spec.length > 0 ? (head.length > 0 ? " · " : "") + spec : "");
            }
            // un error: lo que se intentó (si llegó a decidirse), para saber qué cambiar
            if (root.view === "error") return spec.length > 0 ? "Tried · " + spec : "";
            return spec.length > 0 ? root.presetOf + " · " + spec : (ScreenRecorder.planNow ? "" : root.presetOf);
        }
        color: Theme.fgVariant
        font.family: Typography.ui
        font.pixelSize: Typography.caption * root.s
        font.features: { "tnum": 1 }
        Accessible.role: Accessible.StaticText
        Accessible.name: text
    }

    // ---- tarjetas ------------------------------------------------------------------------------

    Item {
        id: strip
        anchors.top: specText.bottom
        anchors.topMargin: Metrics.sp2 * root.s
        anchors.bottom: footer.top
        anchors.bottomMargin: Metrics.sp3 * root.s
        anchors.left: parent.left
        anchors.right: parent.right

        Row {
            anchors.centerIn: parent
            spacing: Metrics.sp5 * root.s

            Repeater {
                model: root.cards
                delegate: Item {
                    id: card
                    required property int index
                    required property var modelData
                    readonly property real d: Math.abs(card.index - root.pos)
                    readonly property bool isFocused: card.index === root.focusIndex
                    readonly property bool busy: card.modelData.key === "saving"
                        || (ScreenRecorder.requested.length > 0 && ["pause", "resume", "stop", "cancel"].indexOf(card.modelData.key) >= 0)
                        || (card.modelData.key === "recover" && ScreenRecorder.recovering)
                    readonly property color accent: card.modelData.key === "stop" || card.modelData.key === "retry" ? root.recRed
                        : card.modelData.key === "pause" || card.modelData.key === "resume" ? Theme.warningText : Theme.primaryText
                    anchors.verticalCenter: parent.verticalCenter
                    width: root.lerp(Metrics.recCardW, card.d) * root.s * Typography.grow
                        * Math.min(1, (root.rowW - Math.max(0, root.cardCount - 1) * Metrics.sp5 * root.s)
                            / ((Metrics.recCardW[0] + Math.max(0, root.cardCount - 1) * Metrics.recCardW[1]) * root.s * Typography.grow))
                    height: root.lerp(Metrics.recCardH, card.d) * root.s
                    Accessible.role: Accessible.Button
                    Accessible.name: card.modelData.label + (card.modelData.hint ? ", " + card.modelData.hint : "")
                    Accessible.onPressAction: root.activate(card.modelData.key)

                    // Sombra de la forma: el texto no se rasteriza en un FBO que cambia de tamaño.
                    RectangularShadow {
                        z: -1
                        anchors.fill: face
                        radius: face.radius
                        visible: card.isFocused && Settings.materialShadow
                        blur: 14 * root.s
                        offset: Qt.vector2d(0, 4 * root.s)
                        color: Theme.shadow
                    }
                    ClippingRectangle {
                        id: face
                        anchors.fill: parent
                        radius: Metrics.rMd * root.s
                        color: card.isFocused ? Theme.raisedBg : Theme.cardBg

                        Column {
                            anchors.centerIn: parent
                            width: parent.width - 16 * root.s
                            spacing: 5 * root.s
                            Icon {
                                anchors.horizontalCenter: parent.horizontalCenter
                                name: card.modelData.glyph
                                size: 24 * root.s
                                color: card.isFocused ? card.accent : Theme.fgVariant
                                Behavior on color { ColorAnimation { duration: Motion.fast } }
                            }
                            Text {
                                width: parent.width
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideRight
                                text: card.modelData.label
                                color: Theme.fg
                                font.family: Typography.ui
                                font.pixelSize: Typography.body * root.s
                                font.weight: Font.DemiBold
                            }
                            Text {
                                width: parent.width
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideMiddle
                                text: card.modelData.hint || ""
                                color: Theme.fgVariant
                                font.family: Typography.ui
                                font.pixelSize: Typography.caption * root.s
                            }
                        }

                        // La profundidad la dan tamaño y fondo; los metadatos conservan su contraste.

                    }

                    Rectangle {
                        anchors.fill: parent
                        radius: face.radius
                        color: "transparent"
                        border.width: card.isFocused ? 2 : 1
                        border.color: card.isFocused && root.zone === "cards" ? card.accent : Theme.hair
                        opacity: card.busy ? 0.5 : 1
                        Behavior on border.color { ColorAnimation { duration: Motion.fast } }
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: !card.busy
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.focusIndex = card.index;
                            if (root.view === "modes") ScreenRecorder.mode = card.modelData.key;
                            root.goZone("cards");
                            root.activate(card.modelData.key);
                        }
                    }
                }
            }
        }
    }

    // ---- pie -----------------------------------------------------------------------------------

    /**
     * Lo recién hecho mientras dura su aviso («Saved · …», «Copied · …»: con la surface abierta el island no lo
     * dice); si no, el error de la última, su nota (p. ej. micro sin pista) o lo cancelado, hasta la siguiente.
     * Grabando, la pausa que puso el Lock.
     */
    readonly property bool flashFirst: !root.acting && ScreenRecorder.flashing && ScreenRecorder.flashDetail.length > 0
    readonly property bool lockPaused: root.acting && ScreenRecorder.pausedByLock && ScreenRecorder.paused
    readonly property string footerNotice: root.flashFirst ? ScreenRecorder.flashDetail
        : root.lockPaused ? "Paused while the screen was locked"
        : ScreenRecorder.lastError.length > 0 && root.view !== "actions" ? ScreenRecorder.lastError
        : root.view === "result" && ScreenRecorder.result && ScreenRecorder.result.note ? ScreenRecorder.result.note
        : root.view === "modes" && ScreenRecorder.lastNote.length > 0 && !ScreenRecorder.showResult ? ScreenRecorder.lastNote : ""
    readonly property string footerTone: root.flashFirst ? ScreenRecorder.flashTone
        : root.lockPaused ? "warn"
        : ScreenRecorder.lastError.length > 0 && root.view !== "actions" ? "danger"
        : root.view === "result" ? "warn"
        : ScreenRecorder.lastNote.length > 0 ? ScreenRecorder.lastNoteTone : "ok"
    /** Lo que avisa el plan, si no hay nada más que decir (con prioridad lo que impide grabar). */
    readonly property string footerWarn: root.capNote.length > 0 ? root.capNote : root.planWarning
    /** La ayuda de teclado en los renglones que pida (hasta tres), medida con un Text oculto (2026-11-18; ver Wallpaper). */
    Text { id: hintFit; visible: false; width: (Metrics.recorderW - 48) * root.s; text: footerHint.text; font: footerHint.font
           wrapMode: Text.WordWrap; maximumLineCount: 3 }
    readonly property int hintLines: Math.max(1, hintFit.lineCount)

    Item {
        id: footer
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.rowW
        // El aviso puede ocupar varias líneas: su caja entera cuenta para el pie y para la tira.
        height: root.footerNotice.length > 0 ? footerNote.implicitHeight
            : root.footerWarn.length > 0 ? footerWarning.implicitHeight
            : hintFit.implicitHeight

        Text {
            id: footerHint
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            visible: root.footerNotice.length === 0 && root.footerWarn.length === 0
            elide: Text.ElideRight
            wrapMode: Text.WordWrap
            maximumLineCount: root.hintLines
            text: TextWrap.keepHints(root.zone === "options" ? (root.view === "result" ? "← →  choose    ⏎  copy    Esc ↓ ⇥  back"
                                                                   : "← →  choose    ⏎  toggle    Esc ↓ ⇥  back to modes")
                : ScreenRecorder.preparing ? "⏎ C  cancel    O  folder"
                : ScreenRecorder.status === "saving" ? "Saving…    O  folder"
                : ScreenRecorder.live ? (ScreenRecorder.paused ? "Space  resume" : "Space  pause") + "    S  stop and save    O  folder    ,  settings"
                : root.view === "result" ? "⏎  open    C  copy    P  copy path    O  folder    N  new recording"
                : "← →  mode   ⏎  record   ⇥  options   A M  audio   Q  preset   D  delay   ,  settings")
            color: Theme.outlineText
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }
        Notice {
            id: footerNote
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            visible: root.footerNotice.length > 0
            s: root.s
            tone: root.footerTone
            text: root.footerNotice
        }
        Notice {
            id: footerWarning
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            visible: root.footerNotice.length === 0 && root.footerWarn.length > 0
            s: root.s
            tone: "warn"
            text: root.footerWarn
        }
    }
}
