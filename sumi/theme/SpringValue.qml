import QtQuick

/**
 * Muelle de Ryūsui por fotograma (2026-11-11). Sustituye a `Spring` (SpringAnimation de Qt), que integra en pasos fijos
 * de 16 ms y SALTA los ticks más cortos («capped at 62fps», qquickspringanimation.cpp): a 200 Hz la forma se quedaba
 * quieta el 68 % de los fotogramas (medido, tools/sumi-frames/). Esto avanza con el tiempo real de cada tick.
 *
 * Solución exacta del oscilador amortiguado (no un integrador): estable con cualquier paso, la misma curva a 60 Hz que a
 * 200 Hz, y la velocidad se conserva cuando el destino cambia a mitad de vuelo (lo que se buscaba al pasar a muelles).
 *
 * Uso: en vez de `Behavior on x { Spring {} }`, `x: sv.value` con `SpringValue { id: sv; target: <expresión> }`.
 * `animate: false` (el antiguo `Behavior.enabled`) salta al destino; con Animations: Off también, salvo
 * `honorOff: false` (los `Translate` de ocultar/mostrar de Screen.qml, que ya animaban con Off).
 * Carácter (de `Motion`): firme ζ = 1 (sin pasarse), `soft` ζ = 0.82 (~1 % de sobrepaso), Reduced ζ = 0.92 con su ω.
 * `epsilon` en las unidades del valor: píxeles por defecto; para fracciones 0–1, 0.004.
 */
QtObject {
    id: sv

    property real target: 0
    property bool animate: true
    property bool soft: false
    property real epsilon: Motion.epsilonPx
    property bool honorOff: true
    /** Multiplica ω (ventanas: abrir y cerrar a ritmos distintos sin otra física). */
    property real rate: 1
    /** ζ = 1 también en Reduced y en `soft`: nunca se pasa (ventanas). */
    property bool critical: false
    /** Física de Normal aunque el modo sea Reduced (las vistas previas de Settings, a petición). Off sigue mandando. */
    property bool forceNormal: false

    property real value: 0
    property real velocity: 0
    readonly property bool running: frames.running

    readonly property bool calm: Motion.still && !sv.forceNormal
    readonly property real omega: (sv.calm ? Motion.calmOmega : Motion.springOmega) * sv.rate
    readonly property real zeta: sv.critical ? 1 : (sv.calm ? 0.92 : (sv.soft ? 0.82 : 1))

    property bool ready: false

    /** Pone el valor sin animar y sin velocidad (el destino no cambia; si `animate`, sigue hacia él desde ahí). */
    function place(v) {
        sv.value = v;
        sv.velocity = 0;
        sv.kick();
    }

    function jump() {
        frames.stop();
        sv.velocity = 0;
        sv.value = sv.target;
    }

    function kick() {
        if (!sv.ready || !sv.animate || (sv.honorOff && Motion.off)) {
            sv.jump();
            return;
        }
        if (Math.abs(sv.target - sv.value) < sv.epsilon && Math.abs(sv.velocity) < sv.epsilon * sv.omega) {
            sv.jump();
            return;
        }
        if (!frames.running)
            frames.start();
    }

    onTargetChanged: sv.kick()
    onAnimateChanged: if (!sv.animate) sv.jump()
    Component.onCompleted: {
        sv.value = sv.target;
        sv.ready = true;
    }

    function step(dt) {
        if (sv.honorOff && Motion.off) {
            sv.jump();
            return;
        }
        // Un tick largo (ventana tapada, carga) no debe teletransportar ni desestabilizar: tope de 50 ms.
        const t = Math.max(0, Math.min(0.05, dt));
        const w = sv.omega, z = sv.zeta;
        const x0 = sv.value - sv.target, v0 = sv.velocity;
        let x, v;
        if (z >= 0.9999) {
            const e = Math.exp(-w * t), b = v0 + w * x0;
            x = (x0 + b * t) * e;
            v = (v0 - w * b * t) * e;
        } else {
            const wd = w * Math.sqrt(1 - z * z), e = Math.exp(-z * w * t);
            const c = Math.cos(wd * t), s = Math.sin(wd * t);
            const b = (v0 + z * w * x0) / wd;
            x = e * (x0 * c + b * s);
            v = e * (v0 * c - ((z * w * v0 + w * w * x0) / wd) * s);
        }
        if (Math.abs(x) < sv.epsilon && Math.abs(v) < sv.epsilon * w) {
            sv.jump();
            return;
        }
        sv.velocity = v;
        sv.value = sv.target + x;
    }

    property FrameAnimation frames: FrameAnimation {
        onTriggered: sv.step(frameTime)
    }
}
