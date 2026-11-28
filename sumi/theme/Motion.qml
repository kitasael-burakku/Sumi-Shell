pragma Singleton
import QtQuick
import Quickshell
import "../services"

/**
 * Ryūsui: geometría firme, salida pronta, llegada suave y un rebote pequeño sólo en decoración.
 * Normal va un paso por detrás de Reduced a propósito: se ve llegar la forma (2026-11-10, «Normal
 * se siente muy rápido»: con ω 42 abría un panel antes que Reduced y sin dejar ver el recorrido).
 * Los muelles conservan la velocidad al invertir el destino; las esperas de
 * interacción y confirmación no dependen del tempo de las animaciones.
 */
Singleton {
    id: motion

    // Overrides de pruebas/previews: nunca se guardan en Settings.
    property string override: ""
    property real speedOverride: 0
    readonly property string mode: motion.override !== "" ? motion.override : Settings.motionMode
    readonly property bool off: motion.mode === "off"
    readonly property bool still: motion.mode !== "normal"
    readonly property real speed: {
        const v = motion.speedOverride > 0 ? motion.speedOverride : Settings.motionSpeed;
        return Math.max(0.75, Math.min(1.5, v > 0 ? v : 1));
    }
    function dur(ms) { return Math.round(ms / motion.speed); }
    // Duración visible de una línea de estilo. Las esperas de lectura siguen en tiempo real.
    readonly property real styleTempo: motion.still ? 0.78 : 1
    function styleMs(ms) { return motion.off ? 0 : motion.dur(ms * motion.styleTempo); }
    function styleNote(params) {
        return !motion.off && params.openMs ? params.note + " · " + motion.styleMs(params.openMs) + " ms" : params.note;
    }

    // El cierre del cajón, Grow y Fluid recoge el contenido ya leído un poco antes.
    readonly property real returnRate: 1.18
    readonly property int returnMs: motion.off ? 0 : Math.round(motion.calmMs / motion.returnRate)

    // Reduced conserva su recorrido sin rebote y su duración exacta en core/Morph.
    readonly property int calmBaseMs: 180
    readonly property int calmMs: motion.off ? 0 : motion.dur(motion.calmBaseMs)
    readonly property real calmOmega: Math.min(29, 6.67 / (Math.max(60, motion.calmMs) / 1000))
    readonly property real calmSpring: motion.calmOmega * motion.calmOmega * 0.016
    readonly property real calmDamp: 2 * 0.92 * motion.calmOmega * 0.016

    // Duraciones de transición: Reduced mantiene su tempo anterior; Off es inmediato.
    readonly property int fast:     motion.off ? 0 : motion.dur(motion.still ? 140 : 120)
    readonly property int standard: motion.off ? 0 : motion.dur(motion.still ? 240 : 215)
    readonly property int morph:    motion.off ? 0 : motion.dur(motion.still ? 420 : 340)
    readonly property int glide:    motion.off ? 0 : motion.dur(motion.still ? 260 : 235)
    readonly property int snap:     motion.off ? 0 : motion.dur(40)
    readonly property int exit:     motion.off ? 0 : motion.dur(motion.still ? 220 : 180)
    readonly property int page:     motion.off ? 0 : motion.dur(motion.still ? 120 : 165)
    readonly property int vanish:   motion.off ? 0 : motion.dur(motion.still ? 80 : 72)

    /**
     * Ventanas flotantes (2026-11-11): dos estilos oficiales, elegibles en Settings → Shell → Animations → Window style
     * (`shell.animations.windowStyle`). Sólo los usa Normal; Reduced y Off conservan lo de siempre. theme/Reveal lleva la
     * entrada/salida de las siete ventanas con estos números; el cambio de sección dentro de una ventana, `page*`.
     *   openRate · closeRate   ritmo relativo al muelle firme (ω = 30 · speed); con el empujón exponencial de Reveal el
     *                          98 % llega en ln 50 / (30 · rate) s: Minimalist ~180 / ~110 ms, Expressive ~260 / ~160 ms
     *   scaleFrom · lift       escala inicial (desde el centro) y subida en px; sólo visuales
     *   fadeLead               la opacidad llega a 1 antes que la forma (sin velo al final)
     *   pageShift · pageFadeFrom · pageMs   cambio de sección: desplazamiento, opacidad de partida y duración
     * Validados en banco a 60 y 200 Hz (tools/sumi-windows/, tools/sumi-winstyle/).
     *
     * 2026-11-17 (ADR-36, tools/window-open/): seis estilos más, todos con su propia línea de tiempo en Reveal
     * (`timeline: true`, `openMs`/`closeMs` antes de la velocidad global) en vez del muelle: Power-on (antes un efecto
     * sólo de Terminal), Bloom, Mochi, Ink, Scroll y Mist. Valen en Soft y en Terminal, y con Normal y Reduced; sólo
     * Off los quita. Lo que dibuja cada uno está en theme/Reveal (formas) y theme/RevealEffect (máscara, color, luz).
     */
    readonly property var windowStyles: ({
        minimalist: { label: "Minimalist", note: "Subtle lift and scale",
                      openRate: 0.724, closeRate: 1.19, scaleFrom: 0.985, lift: 6, fadeLead: 1.25,
                      pageShift: 6, pageFadeFrom: 0.7, pageMs: 165 },
        expressive: { label: "Expressive", note: "A clearer lift and scale",
                      openRate: 0.50, closeRate: 0.81, scaleFrom: 0.957, lift: 12, fadeLead: 1.15,
                      pageShift: 14, pageFadeFrom: 0.45, pageMs: 210 },
        poweron:    { label: "Power-on", note: "A line widens, then opens",
                      timeline: true, openMs: 300, closeMs: 200,
                      pageShift: 6, pageFadeFrom: 0.7, pageMs: 165 },
        bloom:      { label: "Bloom", note: "A glowing capsule opens out",
                      timeline: true, openMs: 440, closeMs: 260,
                      pageShift: 10, pageFadeFrom: 0.55, pageMs: 190 },
        mochi:      { label: "Mochi", note: "Inflates with a soft bounce",
                      timeline: true, openMs: 520, closeMs: 200,
                      pageShift: 10, pageFadeFrom: 0.55, pageMs: 190 },
        ink:        { label: "Ink", note: "Spreads like a drop of ink",
                      timeline: true, openMs: 420, closeMs: 240,
                      pageShift: 6, pageFadeFrom: 0.6, pageMs: 180 },
        scroll:     { label: "Scroll", note: "Title first, then it unrolls",
                      timeline: true, openMs: 440, closeMs: 260,
                      pageShift: 10, pageFadeFrom: 0.55, pageMs: 190 },
        mist:       { label: "Mist", note: "Comes into focus from a blur",
                      timeline: true, openMs: 320, closeMs: 200,
                      pageShift: 6, pageFadeFrom: 0.6, pageMs: 180 }
    })
    readonly property var windowStyleNames: ["minimalist", "expressive", "poweron", "bloom", "mochi", "ink", "scroll", "mist"]
    /** Pruebas/previews: nunca se guarda (como `override`). */
    property string windowStyleOverride: ""
    readonly property string windowStyle: motion.windowStyleOverride !== "" ? motion.windowStyleOverride : Settings.windowStyle
    function windowParams(name) { return motion.windowStyles[name] || motion.windowStyles.minimalist; }
    readonly property var windowNow: motion.windowParams(motion.windowStyle)
    // Secciones de una ventana flotante: con Normal, las del estilo; con Reduced/Off, las de siempre (0,65 y `page`).
    readonly property real pageShift: motion.windowNow.pageShift
    readonly property real pageFadeFrom: motion.still ? 0.65 : motion.windowNow.pageFadeFrom
    readonly property int pageMs: motion.still ? motion.page : motion.dur(motion.windowNow.pageMs)

    /**
     * ESTILOS DE FORMA (2026-11-21, ADR-40, tools/shape-open/): cómo sale la forma del island desde el reposo y cómo
     * vuelve a él. `barPanelStyles` con la barra permanente (Settings → Animations → Bar panels) e `islandStyles` sin
     * ella, para la island y el notch (Island style). Slide, Grow y Fluid son lo de antes (los muelles de core/Morph);
     * los demás tienen línea de tiempo (`openMs`/`closeMs`, antes de la velocidad global) con las curvas de
     * lib/shape-open.js. Como las ventanas: valen con Normal y Reduced, en Soft y Terminal; sólo Off los quita.
     */
    readonly property var barPanelStyles: ({
        slide:  { label: "Slide",  note: "Slides out at full length" },
        grow:   { label: "Grow",   note: "Grows from the bar button" },
        spring: { label: "Spring", note: "Slides out with a soft bounce", timeline: true, openMs: 440, closeMs: 220 },
        unfold: { label: "Unfold", note: "A strip runs along the bar, then drops", timeline: true, openMs: 400, closeMs: 300 },
        flap:   { label: "Flap",   note: "Folds down from the bar like a flap", timeline: true, openMs: 460, closeMs: 240 },
        bloom:  { label: "Bloom",  note: "The bar edge glows, then opens", timeline: true, openMs: 440, closeMs: 300 },
        ink:    { label: "Ink",    note: "Spreads from the button like ink", timeline: true, openMs: 420, closeMs: 240 },
        mist:   { label: "Mist",   note: "Slides out and comes into focus", timeline: true, openMs: 340, closeMs: 220 }
    })
    readonly property var barPanelStyleNames: ["slide", "grow", "spring", "unfold", "flap", "bloom", "ink", "mist"]
    readonly property var islandStyles: ({
        fluid:   { label: "Fluid",    note: "Firm springs" },
        mochi:   { label: "Mochi",    note: "Width leads, soft bounce", timeline: true, openMs: 540, closeMs: 220 },
        drop:    { label: "Drop",     note: "Stretches wide, then drops", timeline: true, openMs: 460, closeMs: 260 },
        jelly:   { label: "Jelly",    note: "Squash and stretch", timeline: true, openMs: 600, closeMs: 240 },
        poweron: { label: "Power-on", note: "Flattens to a line, then opens", timeline: true, openMs: 320, closeMs: 220 },
        bloom:   { label: "Bloom",    note: "Glows, widens, then opens", timeline: true, openMs: 440, closeMs: 300 },
        ink:     { label: "Ink",      note: "Content spreads like ink", timeline: true, openMs: 420, closeMs: 240 },
        mist:    { label: "Mist",     note: "Grows and comes into focus", timeline: true, openMs: 320, closeMs: 200 }
    })
    readonly property var islandStyleNames: ["fluid", "mochi", "drop", "jelly", "poweron", "bloom", "ink", "mist"]
    /** Pruebas/previews: nunca se guardan (como `override`). */
    property string barPanelStyleOverride: ""
    property string islandStyleOverride: ""
    readonly property string barPanelStyle: {
        const v = motion.barPanelStyleOverride !== "" ? motion.barPanelStyleOverride : Settings.barPanels;
        return motion.barPanelStyles[v] ? v : "slide";
    }
    readonly property string islandStyle: {
        const v = motion.islandStyleOverride !== "" ? motion.islandStyleOverride : Settings.islandStyle;
        return motion.islandStyles[v] ? v : "fluid";
    }
    function barPanelParams(name) { return motion.barPanelStyles[name] || motion.barPanelStyles.slide; }
    function islandParams(name) { return motion.islandStyles[name] || motion.islandStyles.fluid; }
    /**
     * ESTILO DEL BLOQUEO (2026-11-28): `windows` sigue el Window style (de serie), `sumi` es la coreografía propia del
     * bloqueo (reloj y campo primero, laterales después) y los otros ocho fijan un estilo de ventana sólo para el
     * bloqueo. `lockStyle` es ya el nombre efectivo: "sumi" o uno de `windowStyles`.
     */
    readonly property var lockStyleNames: ["windows", "sumi"].concat(motion.windowStyleNames)
    property string lockStyleOverride: ""
    readonly property string lockStyleChoice: {
        const v = motion.lockStyleOverride !== "" ? motion.lockStyleOverride : Settings.lockStyle;
        return motion.lockStyleNames.indexOf(v) >= 0 ? v : "windows";
    }
    function resolveLockStyle(v) {
        if (v === "sumi") return "sumi";
        if (v !== "windows" && motion.windowStyles[v]) return v;
        return motion.windowStyles[motion.windowStyle] ? motion.windowStyle : "minimalist";
    }
    readonly property string lockStyle: motion.resolveLockStyle(motion.lockStyleChoice)
    function lockParams(name) {
        if (name === "windows") {
            const w = motion.windowParams(motion.windowStyle);
            return { label: "Same as windows", note: "Follows Window style · " + w.label, timeline: w.timeline, openMs: w.openMs, closeMs: w.closeMs };
        }
        if (name === "sumi")
            return { label: "Sumi", note: "Clock and field first, then the sides" };
        return motion.windowParams(name);
    }
    /**
     * Duraciones del bloqueo con un estilo (ms reales, ya con velocidad y modo). La apertura cubre la forma más el
     * escalonado del contenido (`lockStagger`); los muelles (Minimalist, Expressive) usan su tiempo nominal.
     */
    function lockOpenFor(name) {
        if (motion.off) return 0;
        if (name === "sumi") return motion.lockOpen;
        const p = motion.windowParams(name);
        return p.timeline ? motion.styleMs(p.openMs) : motion.dur(name === "expressive" ? 260 : 180);
    }
    function lockCloseFor(name) {
        if (motion.off) return 0;
        if (name === "sumi") return motion.lockClose;
        const p = motion.windowParams(name);
        return p.timeline ? motion.styleMs(p.closeMs) : motion.dur(name === "expressive" ? 170 : 120);
    }
    /** Cuánto tarda en entrar el contenido tras la forma: reloj y campo a 0, laterales a `lockStagger`. */
    readonly property int lockStagger: motion.off ? 0 : motion.dur(motion.still ? 60 : 110)
    readonly property int lockContentMs: motion.off ? 0 : motion.dur(motion.still ? 160 : 240)
    /** El pulso de éxito antes de salir: lo justo para verlo, sin retrasar el desbloqueo más de un parpadeo. */
    readonly property int lockAccept: motion.off ? 0 : motion.dur(motion.still ? 90 : 170)
    /** Los dígitos del reloj que ruedan al cambiar el minuto. */
    readonly property int lockDigit: motion.off ? 0 : motion.dur(motion.still ? 160 : 320)
    /** Una familia: "bar" (Bar panels), "island" (Island style), "lock" (Lock style) o "window" (Window style), para el selector de Settings. */
    function styleNames(kind) { return kind === "bar" ? motion.barPanelStyleNames : kind === "island" ? motion.islandStyleNames : kind === "lock" ? motion.lockStyleNames : motion.windowStyleNames; }
    function styleParams(kind, name) { return kind === "bar" ? motion.barPanelParams(name) : kind === "island" ? motion.islandParams(name) : kind === "lock" ? motion.lockParams(name) : motion.windowParams(name); }

    // Esperas de interacción: no son animaciones y no se escalan.
    readonly property int holdMs: 600
    readonly property int hoverOpenMs: 450
    readonly property int hoverCloseMs: 350
    readonly property int fsRevealMs: 350

    // Transiciones del bloqueo. Los topes y las esperas de abajo van en tiempo real.
    readonly property int lockOpen: motion.off ? 0 : motion.dur(motion.still ? 165 : 300)
    readonly property int lockClose: motion.off ? 0 : motion.dur(motion.still ? 110 : 160)
    readonly property int lockDot: motion.off ? 0 : motion.dur(motion.still ? 80 : 115)
    readonly property int lockShake: motion.still ? 0 : motion.dur(180)
    readonly property int lockCheckDelay: 140
    readonly property int lockCalmMs: 10000
    readonly property int lockCalmFade: 600
    /**
     * El tope de cada fase (LockSession `capTimer`): nunca menos de 900 ms y siempre por encima de la transición del
     * estilo elegido (Mochi con Slower y el escalonado pasaba de 900 y se cortaba a mitad).
     */
    readonly property int lockCap: Math.max(900, 400 + Math.max(
        motion.lockOpenFor(motion.lockStyle) + motion.lockStagger + motion.lockContentMs,
        motion.lockAccept + motion.lockCloseFor(motion.lockStyle)))
    readonly property int lockBufferMs: 30000

    readonly property real chaseTau: (motion.still ? 0.035 : 0.062) / motion.speed
    readonly property int easeStandard: Easing.OutCubic
    readonly property int easeMorph: Easing.BezierSpline
    readonly property var morphCurve: [0.16, 1, 0.3, 1, 1, 1]

    /**
     * QQuickSpringAnimation avanza en pasos de 16 ms:
     *   v' = (1 - damping) v + spring (target - x); x' = x + 0.016 v'.
     * Escalar k por speed² y c por speed cambia su amortiguación discreta;
     * el tope anterior, 1.18×, hacía que Faster desincronizara forma y fundidos.
     *
     * Situamos sus polos directamente dentro del círculo unidad. Con r = exp(-ω dt),
     * el firme tiene dos polos r: damping = 1-r²; spring = (1-r)²/dt.
     * Así no rebota desde reposo y todo el intervalo 0.75–1.5 acelera de verdad.
     * El suave usa polos conjugados r·exp(±i θ), con ζ = 0.82 (~1 % de sobrepaso).
     * La física sigue en Qt/C++; no añadimos un bucle JS por fotograma.
     *
     * ω 30 (era 42, y 24,5 con ζ 0,87 antes): en la simulación del integrador, el 98 % de un
     * recorrido de 600 px llega a ~190 ms en Default y ~160 ms en Faster (1,25), contra 144/112
     * de ω 42 y ~240/190 del muelle antiguo. Amortiguación crítica: no se pasa.
     * Fuente del integrador: qtdeclarative/src/quick/util/qquickspringanimation.cpp.
     */
    readonly property real springMass: 1
    readonly property real springOmega: 30 * motion.speed
    readonly property real firmPole: Math.exp(-motion.springOmega * 0.016)
    readonly property real softPole: Math.exp(-0.82 * motion.springOmega * 0.016)
    readonly property real softAngle: motion.springOmega * Math.sqrt(1 - 0.82 * 0.82) * 0.016
    readonly property real springStiff: Math.pow(1 - motion.firmPole, 2) / 0.016
    readonly property real springSoft: (1 - 2 * motion.softPole * Math.cos(motion.softAngle)
        + motion.softPole * motion.softPole) / 0.016
    readonly property real dampFirm: 1 - motion.firmPole * motion.firmPole
    readonly property real dampSoft: 1 - motion.softPole * motion.softPole
    readonly property real epsilonPx: 0.6

    /**
     * Lo entrante espera a que el fundido saliente esté al 3 %. Para el muelle
     * firme, el progreso tras n pasos es 1 - (1 + n(1-r)) r^n. Se deriva del
     * tempo actual para conservar el relevo también en Slower y Faster.
     */
    readonly property real handoff: {
        const n = motion.vanish * 0.69 / 16;
        return Math.min(0.9, 1 - (1 + n * (1 - motion.firmPole)) * Math.pow(motion.firmPole, n));
    }
    readonly property real calmHandoff: {
        const f = Math.min(0.9, (motion.vanish * 0.69) / Math.max(60, motion.calmMs));
        return Math.min(0.9, 1 - Math.pow(1 - f, 3));
    }
    // La cara de reposo espera a que la cápsula casi mida lo suyo.
    readonly property real settleHandoff: 0.82

    // Reparte el relevo de la cara en el progreso de la forma, con un final común.
    function stagger(progress: real, delay: real): real {
        if (motion.still) return progress;
        const t = Math.max(0, Math.min(1, (progress - delay) / (1 - delay)));
        return t * t * (3 - 2 * t);
    }

    function enter(closeness, late) {
        const h = late ? Math.max(motion.settleHandoff, motion.still ? motion.calmHandoff : 0)
                       : (motion.still ? motion.calmHandoff : motion.handoff);
        // Surface fija `settled` al 92 %: llegar ya a opacidad 1 ahí evita
        // el salto final de brillo. Reduced conserva su relevo anterior.
        const end = motion.still ? 1 : 0.92;
        const c = (closeness - h) / (end - h);
        return Math.pow(Math.max(0, Math.min(1, c)), 1.15);
    }
    // Cerrar hacia reposo sigue la misma geometría que abrir.
    function leave(closeness) {
        const h = Math.max(motion.settleHandoff, motion.still ? motion.calmHandoff : 0);
        const c = 1 - closeness / h;
        return Math.pow(Math.max(0, Math.min(1, c)), 1.15);
    }
}
