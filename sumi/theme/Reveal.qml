import QtQuick
import "../lib/window-open.js" as WinOpen

/**
 * Entrada y salida de las ventanas flotantes (2026-11-11): una sola pieza para las siete (Audio, Settings, Tasks,
 * Calendar, Monitor, Wallhaven, Keybinds). El estilo lo elige el usuario en Settings → Shell → Animations → Window
 * style; sus números viven en `Motion.windowStyles`.
 *
 * Dos familias (2026-11-17, ADR-36):
 *  - Muelle (Minimalist, Expressive): `progress` lo lleva un `SpringValue` crítico (nunca se pasa). Al salir del reposo
 *    recibe el empujón de una desaceleración exponencial (responde en el primer fotograma, como un ease-out);
 *    interrumpido, conserva su velocidad y cambia de rumbo sin saltos. Cerrar usa un ritmo más vivo que abrir.
 *  - Línea de tiempo (Power-on, Bloom, Mochi, Ink, Scroll, Mist): `tlValue` avanza lineal en el tiempo y las curvas
 *    están en lib/window-open.js; la máscara, el desenfoque y la luz los dibuja theme/RevealEffect (el `layer.effect`
 *    de la tarjeta, que ya va en una capa mientras anima).
 * Todos valen con Normal y Reduced (2026-11-17, a petición del autor; antes Reduced era un fundido y sólo Power-on lo
 * saltaba) y en Soft y Terminal. Off: inmediato.
 *
 * Salidas, todas sólo visuales (la geometría, la posición y la región de entrada no cambian): `opacity`, `scale` (desde
 * el centro), `dy` (sube), `sx`/`sy` (un `Scale` de la ventana; 1 = nada) y, para RevealEffect, `name`, `value`,
 * `opening` y `effect`.
 *
 * Las miniaturas quietas usan el extremo abierto y detienen sus relojes.
 */
QtObject {
    id: rv

    property bool shown: false
    property real s: 1
    property string style: ""
    property bool animated: true
    property bool ready: false

    readonly property string name: Motion.windowStyles[rv.style.length > 0 ? rv.style : Motion.windowStyle]
        ? (rv.style.length > 0 ? rv.style : Motion.windowStyle) : "minimalist"
    readonly property var params: Motion.windowParams(rv.name)
    readonly property bool calm: Motion.off || !rv.animated
    readonly property bool timeline: rv.params.timeline === true && !rv.calm
    readonly property bool effect: rv.timeline && WinOpen.needsEffect(rv.name)

    property SpringValue spring: SpringValue {
        critical: true
        epsilon: 0.002
        forceNormal: true
        animate: !rv.calm
    }

    // Línea de tiempo. `tlValue` es un VALOR, nunca un enlace (2026-11-15, destello de Power-on visto por el autor: con
    // `shown ? 1 : 0` el enlace seguía vivo bajo la animación y una ventana que se recreaba ya abierta pintaba un
    // fotograma entera; tools/interface-style/open-record.py --user-rules). Se sincroniza a mano: al nacer, al cambiar
    // de estilo y en cada apertura o cierre. Lineal: las curvas van en lib/window-open.js. La duración es la del tramo
    // que falta (invertir a mitad no tarda un recorrido entero).
    property real tlValue: 0
    property bool opening: false
    property var snap: null              // Mochi: la forma al invertir el rumbo
    property NumberAnimation tlAnim: NumberAnimation {
        target: rv; property: "tlValue"; easing.type: Easing.Linear
    }
    function tlTo(to) {
        rv.tlAnim.stop();
        // lo que se ve AHORA (antes de cambiar `opening`, del que depende la forma de Mochi)
        const mid = rv.tlValue > 0 && rv.tlValue < 1;
        const seen = rv.name === "mochi" && mid
            ? WinOpen.shape("mochi", rv.tlValue, rv.s, rv.opening, rv.snap, Motion.still) : null;
        rv.opening = to > 0.5;
        // La forma y el reloj parten del mismo instante, incluso con varias inversiones seguidas.
        rv.snap = seen ? { sx: seen.sx, sy: seen.sy, opacity: seen.opacity, v0: rv.tlValue } : null;
        const ms = rv.opening ? rv.params.openMs : rv.params.closeMs;
        rv.tlAnim.from = rv.tlValue;
        rv.tlAnim.to = to;
        rv.tlAnim.duration = Math.max(1, Motion.styleMs(ms * Math.abs(to - rv.tlValue)));
        rv.tlAnim.start();
    }
    function settle() {
        rv.tlAnim.stop();
        rv.snap = null;
        rv.opening = rv.shown;
        rv.tlValue = rv.shown ? 1 : 0;
        rv.spring.target = rv.tlValue;
        rv.spring.jump();
    }
    onNameChanged: if (rv.ready) rv.settle()
    onCalmChanged: if (rv.ready) rv.settle()
    Component.onCompleted: {
        rv.ready = true;
        if (rv.shown && !rv.calm) rv.play();
        else rv.settle();
    }
    onShownChanged: if (rv.ready) rv.play()
    function play() {
        const to = rv.shown ? 1 : 0;
        if (rv.calm) { rv.settle(); return; }
        if (rv.timeline) { rv.tlTo(to); return; }
        rv.spring.rate = rv.shown ? rv.params.openRate : rv.params.closeRate;
        // Empujón al salir del reposo (o si va hacia el destino más lento que la exponencial): ease-out inmediato. Si va
        // en sentido contrario (se interrumpe), conserva su velocidad: frena y vuelve sin salto.
        const want = (to - rv.spring.value) * rv.spring.omega;
        const v = rv.spring.velocity;
        if (Math.abs(v) < 1e-6 || (Math.sign(v) === Math.sign(want) && Math.abs(v) < Math.abs(want)))
            rv.spring.velocity = want;
        rv.spring.target = to;
    }

    readonly property real progress: rv.timeline ? rv.tlValue : rv.calm ? (rv.shown ? 1 : 0)
        : Math.max(0, Math.min(1, rv.spring.value))
    readonly property real value: rv.progress
    readonly property bool moving: rv.spring.running || rv.tlAnim.running

    // la forma de la línea de tiempo (null con el muelle)
    readonly property var tl: rv.timeline ? WinOpen.shape(rv.name, rv.tlValue, rv.s, rv.opening, rv.snap, Motion.still) : null
    readonly property real sx: rv.tl ? rv.tl.sx : 1
    readonly property real sy: rv.tl ? rv.tl.sy : 1
    readonly property real opacity: rv.tl ? rv.tl.opacity
        : rv.calm ? rv.progress : Math.min(1, rv.progress * rv.params.fadeLead)
    readonly property real scale: rv.tl ? rv.tl.scale
        : rv.calm ? 1 : 1 - (1 - rv.params.scaleFrom) * (1 - rv.progress) * (Motion.still ? 0.32 : 1)
    readonly property real dy: rv.tl ? rv.tl.dy : rv.calm ? 0 : (1 - rv.progress) * rv.params.lift * rv.s * (Motion.still ? 0.32 : 1)
}
