import QtQuick
import "../theme"

/**
 * El rectángulo que se transforma. Ancho, alto y radio persiguen su destino
 * con los muelles de Ryūsui (`theme/Motion`), y `closeness` dice **cuánto del
 * camino lleva hecho** para que el contenido entre detrás de la forma en vez de
 * a la vez.
 *
 * DOS CAMBIOS del 2026-09-15, los dos medidos:
 *
 * 1. **Muelles en vez de `Behavior`+bezier.** Un `Behavior` interrumpido
 *    reinicia con la duración completa desde el valor actual y **pierde la
 *    velocidad** (ANIMATIONS §4 lo daba por aceptado); un muelle la conserva y
 *    cambia de rumbo sin frenar. De regalo desaparece el motivo de `hop`: el
 *    tiempo de asentamiento de un muelle **no depende de la distancia**, así que
 *    el saltito rest↔hover y la apertura de un panel entero tardan lo mismo
 *    (~260 ms) sin ningún caso especial. `hop`, que era ese caso especial,
 *    se retiró el 2026-09-16: llevaba desde entonces escribiéndose sin que
 *    nadie lo leyera.
 *
 * 2. **`closeness` es progreso, no distancia.** Antes era
 *    `1 − d/(110·s)`, que se desplomaba de 1,000 a 0,068 **en el mismo
 *    fotograma** en que cambiaba el destino, antes de que nada se hubiera
 *    movido — ANIMATIONS §6.4 lo llamaba deuda y `settled` era su parche. Ahora
 *    se guarda la distancia de partida y se mide contra ella: 0 → 1, monótono.
 *    `settled` se queda, pero ya sólo para lo que siempre debió cubrir: que un
 *    relayout interno mueva el destino con el panel ya abierto.
 */
Item {
    id: morph

    property real s: 1
    property real targetW: 0
    property real targetH: 0
    property real targetRadius: 0
    property bool returning: false
    readonly property real shapeRate: returning ? Motion.returnRate : 1
    /**
     * Two local drivers, one displayed geometry. Keep the selection separate from
     * Motion.mode so switching drivers can capture the OLD displayed coordinates first.
     * Ordinary target changes still use Behavior/Spring and preserve their velocity.
     */
    property bool useCalm: false
    property bool switchingDriver: false
    property bool initialized: false
    /**
     * 2026-11-19 (el cajón de la barra, core/Island `drawer`): un eje (o el radio) en «snap» salta a su destino sin muelle ni
     * Behavior; el otro sigue animándose. Así la forma puede tener ya su largo y crecer sólo en profundidad.
     */
    property bool snapW: false
    property bool snapH: false
    property bool snapR: false
    /**
     * 2026-11-21 (estilos de forma, ADR-40; core/Island, lib/shape-open.js): un tercer conductor. Con `tlOn` la forma
     * dibuja `tlW/tlH/tlR` (los pone la línea de tiempo del estilo) y `closeness` es `tlProgress`; los muelles siguen
     * por debajo hacia el destino sin verse. Al soltarse (`tlOn` → false) se siembran desde lo que se veía, sin
     * velocidad, como en `changeDriver`: la línea acaba en el destino exacto, así que no hay salto.
     */
    property bool tlOn: false
    property real tlW: 0
    property real tlH: 0
    property real tlR: 0
    property real tlProgress: 1
    // Muelles por fotograma (2026-11-11, theme/SpringValue): el SpringAnimation de Qt sólo avanzaba a 62 Hz.
    SpringValue { id: animW; rate: morph.shapeRate; animate: morph.initialized && !morph.useCalm && !morph.snapW }
    SpringValue { id: animH; rate: morph.shapeRate; animate: morph.initialized && !morph.useCalm && !morph.snapH }
    SpringValue { id: animR; rate: morph.shapeRate; animate: morph.initialized && !morph.useCalm && !morph.snapR; epsilon: 0.1 }
    readonly property real springW: animW.value
    readonly property real springH: animH.value
    readonly property real springR: animR.value

    property real calmW: 0
    property real calmH: 0
    property real calmR: 0
    Behavior on calmW { enabled: morph.initialized && !morph.switchingDriver && morph.useCalm && !morph.snapW; NumberAnimation { id: calmAnimW; duration: morph.returning ? Motion.returnMs : Motion.calmMs; easing.type: Easing.OutCubic } }
    Behavior on calmH { enabled: morph.initialized && !morph.switchingDriver && morph.useCalm && !morph.snapH; NumberAnimation { id: calmAnimH; duration: morph.returning ? Motion.returnMs : Motion.calmMs; easing.type: Easing.OutCubic } }
    Behavior on calmR { enabled: morph.initialized && !morph.switchingDriver && morph.useCalm && !morph.snapR; NumberAnimation { id: calmAnimR; duration: morph.returning ? Motion.returnMs : Motion.calmMs; easing.type: Easing.OutCubic } }

    width: morph.tlOn ? tlW : morph.useCalm ? calmW : springW
    height: morph.tlOn ? tlH : morph.useCalm ? calmH : springH
    property real radius: morph.tlOn ? tlR : morph.useCalm ? calmR : springR

    function retarget() {
        animW.target = morph.targetW; animH.target = morph.targetH; animR.target = morph.targetRadius;
        morph.calmW = morph.targetW; morph.calmH = morph.targetH; morph.calmR = morph.targetRadius;
    }
    function changeDriver() {
        const w = morph.width, h = morph.height, r = morph.radius;
        morph.switchingDriver = true;
        // Disabled Behaviors cancel their own jobs when the displayed values are seeded.
        morph.calmW = w; morph.calmH = h; morph.calmR = r;
        morph.useCalm = Motion.mode !== "normal";
        morph.switchingDriver = false;
        // El muelle sigue desde lo que se veía (sin velocidad); si no se usa, `animate` es falso y salta al destino.
        animW.place(w); animH.place(h); animR.place(r);
        morph.retarget();
    }
    Connections { target: Motion; function onModeChanged() { morph.changeDriver(); } }
    // la línea de tiempo suelta la forma: los conductores de siempre siguen desde lo que se veía
    onTlOnChanged: if (!morph.tlOn && morph.initialized) {
        const w = morph.tlW, h = morph.tlH, r = morph.tlR;
        morph.switchingDriver = true;
        morph.calmW = w; morph.calmH = h; morph.calmR = r;
        morph.switchingDriver = false;
        animW.place(w); animH.place(h); animR.place(r);
        morph.retarget();
    }
    Component.onCompleted: { morph.useCalm = Motion.mode !== "normal"; morph.retarget(); morph.initialized = true; }

    /**
     * Distancia que había que recorrer cuando se fijó el destino actual. Se
     * captura en el handler del cambio: ahí `width`/`height` siguen valiendo el
     * valor viejo (el `Behavior` arranca desde él), así que es el tramo completo.
     * Un destino que cambia a mitad de vuelo re-mide desde donde esté — el
     * progreso vuelve a 0 y sube a 1 sin saltos hacia atrás.
     */
    property real spanW: 1
    property real spanH: 1
    onTargetWChanged: {
        morph.spanW = Math.max(1, Math.abs(morph.targetW - morph.width));
        morph.retarget();
    }
    onTargetHChanged: {
        morph.spanH = Math.max(1, Math.abs(morph.targetH - morph.height));
        morph.retarget();
    }
    onTargetRadiusChanged: morph.retarget()
    // Al entrar en «snap» con una animación del eje ya en marcha (el destino cambió un instante antes), se planta
    // en el destino: el orden entre el enlace del destino y el del snap no está garantizado. (Con el Behavior
    // desactivado por `switchingDriver`, como en `changeDriver`: cancela su propia animación.)
    onSnapWChanged: if (morph.snapW) { morph.switchingDriver = true; morph.calmW = morph.targetW; morph.switchingDriver = false; animW.jump(); }
    onSnapHChanged: if (morph.snapH) { morph.switchingDriver = true; morph.calmH = morph.targetH; morph.switchingDriver = false; animH.jump(); }
    onSnapRChanged: if (morph.snapR) { morph.switchingDriver = true; morph.calmR = morph.targetRadius; morph.switchingDriver = false; animR.jump(); }

    readonly property real closeness: {
        if (morph.tlOn) return morph.tlProgress;
        const pw = 1 - Math.min(1, Math.abs(width - targetW) / morph.spanW);
        const ph = 1 - Math.min(1, Math.abs(height - targetH) / morph.spanH);
        return Math.min(pw, ph);
    }

    readonly property bool morphing: morph.tlOn || animW.running || animH.running || animR.running
        || calmAnimW.running || calmAnimH.running || calmAnimR.running
}
