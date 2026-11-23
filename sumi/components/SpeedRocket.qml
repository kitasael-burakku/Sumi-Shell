import QtQuick
import QtQuick.Shapes
import "../theme"

/**
 * El cohete del Speed test (2026-11-14). No decora: su empuje sale del throughput MEDIDO que le pasa la vista.
 *
 * DOS MAGNITUDES, las dos suavizadas:
 *   thrust    lo que mueve: largo de la llama, velocidad de las estelas y de las estrellas. Sigue la medida en vivo
 *             (ventana de 1 s del helper) durante la bajada y la subida; 0 fuera de ellas.
 *   altitude  dónde está el cohete: sube con la medida y, al terminar, se QUEDA a la altura de la bajada final
 *             (es el resultado); con un fallo o una cancelación vuelve a la plataforma.
 *
 * Mb/s → intensidad (escala log con suelo y techo): I = 0,12 + 0,88 · clamp(log10(mbps/0,5) / log10(5000)).
 *   1 Mb/s → 0,19 · 10 → 0,43 · 100 → 0,67 · 1000 → 0,90 · ≥ 2500 → 1. El suelo deja el motor encendido y las
 *   estelas en marcha en una conexión lenta; el techo evita que una muy rápida rompa la escena. Lo nervioso de TCP lo
 *   absorben la ventana del helper, el logaritmo y el suavizado (τ 0,6 s).
 *
 * UN SOLO RELOJ: un `FrameAnimation` que corre sólo con la vista abierta, en Normal y mientras haya algo que mover;
 * cada fotograma integra una fase (`travel`) y suaviza las dos magnitudes con el tiempo real del fotograma (igual a
 * 60 que a 200 Hz, sin el tope de 62 Hz de SpringAnimation). Las estelas y estrellas son bindings de `travel`. Al
 * terminar, la llama se apaga, las estelas se paran y el reloj también: en reposo no hay trabajo por fotograma (el
 * balanceo de reposo son dos ciclos de una animación de Qt y se para).
 *
 * Las formas son `Shape` ESTÁTICAS: la llama crece con una transformación (`Scale`), nunca cambiando la ruta (eso
 * volvería a teselar en cada fotograma).
 *
 * Movimiento: Normal = todo lo anterior, con el carácter del estilo de ventana (Minimalist: 6 estelas, sin temblor;
 * Expressive: 8 estelas y un temblor de ±0,6 px con mucho empuje). Reduced = sin estelas ni parpadeo ni balanceo: la
 * llama y la altura cambian con una transición calmada. Off = saltos.
 */
Item {
    id: root

    property real s: 1
    /** Fase del servicio (`SpeedTest.phase`). */
    property string phase: "idle"
    /** Mb/s de la ventana en curso (bajada o subida); NaN si aún no hay. */
    property real liveMbps: NaN
    /** Resultado de la bajada (para la altitud final). */
    property real finalMbps: NaN
    property int pings: 0
    /** La vista está abierta y visible: sin esto, ni un fotograma. */
    property bool live: false

    clip: true

    // ---- intensidad -------------------------------------------------------------------------------

    function intensity(mbps) {
        if (!isFinite(mbps) || mbps <= 0) return 0;
        const x = Math.log(mbps / 0.5) / Math.log(5000);
        return 0.12 + 0.88 * Math.max(0, Math.min(1, x));
    }

    readonly property bool measuring: root.phase === "download" || root.phase === "upload"
    readonly property bool lit: root.measuring || root.phase === "latency" || root.phase === "preflight"
    readonly property real thrustTarget: root.measuring ? Math.max(0.12, root.intensity(root.liveMbps))
        : (root.phase === "latency" || root.phase === "preflight") ? 0.06 : 0
    readonly property real altitudeTarget: root.measuring ? root.thrustTarget
        : root.phase === "done" ? root.intensity(root.finalMbps) : 0

    readonly property bool normal: Motion.mode === "normal"
    readonly property bool expressive: Motion.windowStyle === "expressive"

    property real thrust: 0
    property real altitude: 0
    /** Recorrido acumulado de la escena, en px: las estelas y estrellas lo leen. */
    property real travel: 0
    /** Tiempo de llama, para el parpadeo. */
    property real flameT: 0

    // Fuera de Normal: Reduced anima con calma, Off salta (el reloj de Normal no corre).
    Behavior on thrust { enabled: !root.normal && !Motion.off; NumberAnimation { duration: Motion.standard; easing.type: Easing.OutCubic } }
    Behavior on altitude { enabled: !root.normal && !Motion.off; NumberAnimation { duration: Motion.morph; easing.type: Easing.OutCubic } }
    onThrustTargetChanged: if (!root.normal) root.thrust = root.thrustTarget
    onAltitudeTargetChanged: if (!root.normal) root.altitude = root.altitudeTarget
    onNormalChanged: if (!root.normal) { root.thrust = root.thrustTarget; root.altitude = root.altitudeTarget; }

    readonly property real tau: 0.6 / Motion.speed
    readonly property real eps: 0.002
    /** ¿Hay algo que mover? Llama encendida, o una magnitud que aún no llegó. */
    readonly property bool moving: root.lit || Math.abs(root.thrust - root.thrustTarget) > root.eps
        || Math.abs(root.altitude - root.altitudeTarget) > root.eps || root.thrust > root.eps

    readonly property bool clockRunning: clock.running

    FrameAnimation {
        id: clock
        running: root.live && root.normal && !Motion.off && root.moving
        onTriggered: {
            const dt = Math.min(0.05, clock.frameTime);
            const k = 1 - Math.exp(-dt / root.tau);
            let th = root.thrust + (root.thrustTarget - root.thrust) * k;
            let al = root.altitude + (root.altitudeTarget - root.altitude) * k;
            if (Math.abs(th - root.thrustTarget) < root.eps) th = root.thrustTarget;
            if (Math.abs(al - root.altitudeTarget) < root.eps) al = root.altitudeTarget;
            root.thrust = th;
            root.altitude = al;
            // px/s de la escena: algo de vida con poco empuje, de verdad rápido con mucho (cuadrático)
            root.travel += dt * 60 * root.s * Motion.speed * (0.25 + 2.75 * th * th) * (th > root.eps ? 1 : 0);
            root.flameT += dt;
        }
    }

    property color tone: root.phase === "upload" ? Theme.secondary : Theme.primary
    Behavior on tone { ColorAnimation { duration: Motion.standard } }

    // ---- estrellas (parallax lenta) ---------------------------------------------------------------

    Repeater {
        model: [[.08, .12, .30], [.18, .55, .18], [.27, .30, .40], [.34, .82, .22], [.46, .08, .16],
                [.58, .66, .34], [.66, .22, .20], [.74, .48, .38], [.83, .78, .26], [.91, .36, .18],
                [.12, .90, .28], [.52, .42, .14]]
        delegate: Rectangle {
            required property var modelData
            readonly property real span: root.height
            width: 2.4 * root.s * (0.6 + modelData[2])
            height: width
            radius: width / 2
            color: Theme.fgVariant
            opacity: 0.25 + modelData[2]
            x: modelData[0] * root.width
            y: (modelData[1] * span + root.travel * modelData[2]) % span
        }
    }

    // ---- estelas: pasan hacia abajo; su velocidad es el empuje ------------------------------------

    Repeater {
        model: root.expressive ? 8 : 6
        delegate: Rectangle {
            required property int index
            readonly property var lane: [[.14, .10, 22, 1.0], [.82, .45, 30, 1.25], [.26, .70, 16, .8],
                                         [.72, .20, 26, 1.1], [.36, .38, 14, .7], [.64, .86, 20, .9],
                                         [.20, .58, 12, .6], [.88, .74, 18, .85]][index]
            readonly property real len: lane[2] * root.s * (0.6 + root.thrust)
            readonly property real span: root.height + len
            width: 2 * root.s
            height: len
            radius: width / 2
            x: lane[0] * root.width
            y: ((lane[1] * span + root.travel * lane[3] * 2.2) % span) - len
            color: root.tone
            visible: root.normal && !Motion.off
            opacity: Math.min(1, root.thrust * 2.2) * 0.5
        }
    }

    // ---- la plataforma ----------------------------------------------------------------------------

    Rectangle {
        id: pad
        width: rocket.width * 1.4
        height: 3 * root.s
        radius: height / 2
        anchors.horizontalCenter: parent.horizontalCenter
        y: rocket.restY + rocket.height + 2 * root.s
        color: Theme.outline
        opacity: Math.max(0, 1 - root.altitude * 4) * 0.6
    }

    // ---- el cohete --------------------------------------------------------------------------------

    /** Unidad de dibujo: 40 × 70 (cuerpo y aletas) + la llama debajo. */
    readonly property real unit: Math.min(root.height * 0.5 / 70, root.width * 0.36 / 40)

    /**
     * Balanceo de reposo: DOS ciclos (8 s) al abrir la vista o al llegar a reposo o al resultado, y quieto después.
     * Infinito costaba repintar a 200 Hz sin fin con el panel abierto (medido: 8 % de CPU de la shell en el banco,
     * contra 0 % de cualquier otra superficie en reposo). Es una animación de Qt: sin JS por fotograma.
     */
    property real bob: 0
    readonly property bool bobWanted: root.live && root.normal && !Motion.off
        && (root.phase === "idle" || root.phase === "done")
    function restartBob() {
        if (root.bobWanted) bobAnim.restart();
        else { bobAnim.stop(); root.bob = 0; }
    }
    onBobWantedChanged: root.restartBob()
    Component.onCompleted: root.restartBob()
    onPhaseChanged: if (root.phase === "done") root.restartBob()
    SequentialAnimation {
        id: bobAnim
        loops: 2
        NumberAnimation { target: root; property: "bob"; from: 0; to: 1; duration: 2000; easing.type: Easing.InOutSine }
        NumberAnimation { target: root; property: "bob"; from: 1; to: 0; duration: 2000; easing.type: Easing.InOutSine }
    }

    Item {
        id: rocket
        width: 40 * root.unit
        height: 70 * root.unit
        readonly property real restY: root.height - height - 10 * root.s
        readonly property real lift: root.height * 0.30
        readonly property real shake: root.expressive && root.normal && root.thrust > 0.8
            ? 0.6 * root.s * Math.sin(root.flameT * 47) : 0
        x: (root.width - width) / 2 + shake
        y: restY - root.altitude * lift - root.bob * 2 * root.s

        // la llama, detrás del cuerpo: crece desde la tobera
        Shape {
            id: flame
            width: 20 * root.unit
            height: 34 * root.unit
            x: 10 * root.unit
            y: 63 * root.unit
            preferredRendererType: Shape.CurveRenderer
            readonly property real flicker: root.normal && !Motion.off
                ? 1 + (root.expressive ? 0.12 : 0.05) * Math.sin(root.flameT * 31) * Math.sin(root.flameT * 17 + 1)
                : 1
            opacity: root.lit && root.thrust > 0 ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Motion.fast } }
            transform: Scale {
                origin.x: flame.width / 2
                origin.y: 0
                xScale: 0.75 + 0.25 * Math.min(1, root.thrust * 2)
                yScale: (0.3 + 0.7 * root.thrust) * flame.flicker
            }
            ShapePath {
                strokeWidth: -1
                fillGradient: LinearGradient {
                    x1: 0; y1: 0; x2: 0; y2: flame.height
                    GradientStop { position: 0; color: root.tone }
                    GradientStop { position: 1; color: Qt.rgba(root.tone.r, root.tone.g, root.tone.b, 0) }
                }
                startX: 0; startY: 0
                PathLine { x: 20 * root.unit; y: 0 }
                PathCubic { x: 10 * root.unit; y: 34 * root.unit
                            control1X: 19 * root.unit; control1Y: 12 * root.unit
                            control2X: 14 * root.unit; control2Y: 24 * root.unit }
                PathCubic { x: 0; y: 0
                            control1X: 6 * root.unit; control1Y: 24 * root.unit
                            control2X: 1 * root.unit; control2Y: 12 * root.unit }
            }
        }

        // cuerpo y aletas
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {     // aletas
                strokeWidth: -1
                fillColor: root.tone
                startX: 9 * root.unit; startY: 40 * root.unit
                PathLine { x: 0; y: 58 * root.unit }
                PathLine { x: 0; y: 66 * root.unit }
                PathLine { x: 10 * root.unit; y: 60 * root.unit }
                PathMove { x: 31 * root.unit; y: 40 * root.unit }
                PathLine { x: 40 * root.unit; y: 58 * root.unit }
                PathLine { x: 40 * root.unit; y: 66 * root.unit }
                PathLine { x: 30 * root.unit; y: 60 * root.unit }
            }
            ShapePath {     // fuselaje
                strokeColor: Theme.outline
                strokeWidth: 1 * root.s
                fillColor: Theme.fg
                startX: 20 * root.unit; startY: 0
                PathCubic { x: 33 * root.unit; y: 48 * root.unit
                            control1X: 31 * root.unit; control1Y: 9 * root.unit
                            control2X: 34 * root.unit; control2Y: 26 * root.unit }
                PathLine { x: 30 * root.unit; y: 62 * root.unit }
                PathLine { x: 10 * root.unit; y: 62 * root.unit }
                PathLine { x: 7 * root.unit; y: 48 * root.unit }
                PathCubic { x: 20 * root.unit; y: 0
                            control1X: 6 * root.unit; control1Y: 26 * root.unit
                            control2X: 9 * root.unit; control2Y: 9 * root.unit }
            }
        }

        // ventanilla
        Rectangle {
            width: 12 * root.unit
            height: width
            radius: width / 2
            x: 14 * root.unit
            y: 20 * root.unit
            color: root.tone
            border.color: Theme.cardBg
            border.width: 2 * root.unit
        }

        // tobera
        Rectangle {
            width: 14 * root.unit
            height: 4 * root.unit
            radius: 1.5 * root.unit
            x: 13 * root.unit
            y: 61 * root.unit
            color: Theme.fgVariant
        }

        // el pulso de cada ping, desde la punta (sólo Normal)
        Rectangle {
            id: pulse
            width: 16 * root.unit
            height: width
            radius: width / 2
            x: (rocket.width - width) / 2
            y: -width / 2
            color: "transparent"
            border.color: root.tone
            border.width: 1.5 * root.s
            opacity: 0
            scale: 0.3
            ParallelAnimation {
                id: pulseAnim
                NumberAnimation { target: pulse; property: "scale"; from: 0.3; to: 2.2; duration: 520; easing.type: Easing.OutCubic }
                NumberAnimation { target: pulse; property: "opacity"; from: 0.9; to: 0; duration: 520; easing.type: Easing.OutCubic }
            }
        }
    }

    onPingsChanged: if (root.pings > 0 && root.live && root.normal && !Motion.off) pulseAnim.restart()
}
