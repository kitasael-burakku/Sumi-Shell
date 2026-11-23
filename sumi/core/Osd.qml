import QtQuick
import "../services"

/**
 * **El pregonero del island.** Decide qué tiene que decir la cápsula y durante
 * cuánto; dibujarlo es cosa del island (2026-09-15).
 *
 * Dos clases de mensaje, con prioridad:
 *
 *   notice  algo ha pasado y hay que enterarse — la red se cayó, la batería
 *           está baja, la comprobación de actualizaciones falló. Manda sobre el
 *           nivel: si ocurre mientras subes el volumen, el volumen espera.
 *   level   el flash de volumen o de micrófono de toda la vida.
 *
 * Antes esto era una cápsula hermana que salía en el mismo sitio que el island
 * mientras el island se desvanecía a 0. Resolvía el choque, pero apagaba el
 * objeto principal del escritorio justo cuando el sistema tenía algo que decir.
 * Ahora el island **se convierte** en el mensaje: se ensancha sin cambiar de
 * alto, lo dice, y vuelve.
 *
 * Sólo el monitor enfocado: son hechos globales y sin el filtro cada pantalla
 * anunciaría lo mismo.
 */
Item {
    id: osd

    property real s: 1
    property string screenName: ""

    readonly property bool onFocusedMonitor: Hypr.focusedName.length === 0
        || Hypr.focusedName === osd.screenName

    // ---- nivel (volumen / micrófono) ------------------------------------

    property bool flashing: false
    property string kind: "volume"

    // 8G-1: también el brillo (DDC) de ESTA pantalla, con lo pedido al instante
    readonly property real level: kind === "brightness" ? Math.max(0, Brightness.shown(osd.screenName))
        : kind === "mic" ? Audio.micVolume : Audio.volume
    readonly property bool off: kind === "brightness" ? false : (kind === "mic" ? Audio.micMuted : Audio.muted)
    readonly property string glyph: osd.kind === "brightness" ? "brightness"
        : osd.off ? "volume-off"
        : (osd.level > 0.66 ? "volume-high" : (osd.level > 0.33 ? "volume-mid" : "volume-low"))

    function flash(which) {
        if (!osd.onFocusedMonitor)
            return;
        osd.kind = which;
        osd.flashing = true;
        hideTimer.restart();
    }

    /** El brillo lo dice la pantalla cuyo monitor cambió, esté o no enfocada. */
    Connections {
        target: Brightness
        function onExternalChange(screen) {
            if (screen !== osd.screenName) return;
            osd.kind = "brightness";
            osd.flashing = true;
            hideTimer.restart();
        }
    }
    Connections {
        target: Audio
        function onChanged(kind) { osd.flash(kind); }
    }

    Timer {
        id: hideTimer
        // 9C-2: Settings → Shell → OSD (antes 1800 fijo)
        interval: Settings.osdMs
        onTriggered: osd.flashing = false
    }

    // ---- avisos ---------------------------------------------------------

    property bool noticing: false
    property string noticeText: ""
    property string noticeGlyph: "alert"
    property string noticeTone: "danger"

    /**
     * Lo dice el island y se va. El detalle y el arreglo viven en la superficie
     * que corresponda — decisión del usuario, 2026-09-15: «las dos cosas».
     */
    function announce(text, glyph, tone, holdMs) {
        if (!osd.onFocusedMonitor || text.length === 0)
            return;
        osd.noticeText = text;
        osd.noticeGlyph = glyph && glyph.length > 0 ? glyph : "alert";
        osd.noticeTone = tone && tone.length > 0 ? tone : "danger";
        osd.noticing = true;
        noticeTimer.interval = holdMs > 0 ? holdMs : 3000;
        noticeTimer.restart();
    }

    /** Paletas estáticas F-d (2026-11-04): tras confirmar un tema, las apps GTK abiertas que no se recolorean solas. */
    Connections {
        target: ThemePreview
        function onNotice(text, glyph, tone) { osd.announce(text, glyph, tone, 5000); }
    }

    /** El grabador (2026-10-29): guardada, fallida. Empezar no se anuncia: lo dice su pieza. */
    Connections {
        target: ScreenRecorder
        function onNotice(text, glyph, tone) { osd.announce(text, glyph, tone, 4000); }
    }

    Timer {
        id: noticeTimer
        interval: 3000
        onTriggered: osd.noticing = false
    }

    /** `notice` manda sobre `level`; "none" deja al island en reposo. */
    readonly property string mode: osd.noticing ? "notice" : (osd.flashing ? "level" : "none")
    readonly property bool active: osd.mode !== "none"

    // ---- de qué se avisa ------------------------------------------------

    /**
     * Al arrancar, los servicios pasan por estados intermedios mientras se
     * pueblan (`ready` tarda, la red aparece como desconectada un instante). Sin
     * esta espera el escritorio te saludaría con dos avisos rojos en cada
     * reinicio del shell. Mismo criterio que `bootSettled` de `Screen`.
     */
    property bool armed: false
    Timer { interval: 6000; running: true; onTriggered: osd.armed = true }

    /** La red se cayó estando conectada. Volver no se anuncia: no es una alarma. */
    property bool sawNet: false
    Connections {
        target: Net
        function onConnectedChanged() {
            if (!osd.armed || !Net.ready)
                return;
            if (Net.connected) { osd.sawNet = true; return; }
            if (osd.sawNet)
                osd.announce("Network disconnected", "wifi-off", "danger");
        }
    }

    // Los avisos de batería son globales en Battery, mediante Notifs.

    /**
     * Cambio de distribución de teclado (2026-09-24; antes, una notificación de
     * `kb-layout-notify.py`). Sin `armed`: Hyprland sólo lo emite cuando cambia
     * de verdad. Corto, porque se mira un segundo; cambiar cuatro veces seguidas
     * reinicia la cuenta, no apila nada. No pisa un aviso de alarma que siga en
     * pantalla: la red caída importa más que saber que ahora escribes en ES.
     */
    readonly property var layoutShort: ({
        "English (US)": "US",
        "Spanish": "ES",
        "Spanish (Latin American)": "LATAM",
        "Catalan": "CAT",
        "English (UK)": "UK"
    })
    function layoutCode(layout) {
        if (osd.layoutShort[layout])
            return osd.layoutShort[layout];
        return layout.split(" ")[0].slice(0, 3).toUpperCase();
    }
    Connections {
        target: Hypr
        function onKeyboardLayoutChanged() {
            const layout = Hypr.keyboardLayout;
            if (osd.noticing && (osd.noticeTone === "danger" || osd.noticeTone === "warn"))
                return;
            osd.announce(osd.layoutCode(layout) + " · " + layout, "keyboard", "info", 1200);
        }
    }

    /** La comprobación de actualizaciones falló: el aviso del island ya no lo dice. */
    Connections {
        target: Updates
        function onFailedChanged() {
            if (osd.armed && Updates.failed)
                osd.announce("Update check failed", "alert", "warn");
        }
    }
}
