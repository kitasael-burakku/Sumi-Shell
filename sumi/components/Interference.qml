import QtQuick
import "../theme"
import "../lib/noise-frames.js" as Noise

/**
 * Interferencia de Terminal (2026-11-15, a petición del autor; sustituye al «Glitch» de F5 en Settings, mismo ajuste
 * `theme.effects.glitch`). Sólo en las ventanas flotantes (el island quedó fuera, también a petición suya), donde
 * SUSTITUYE al desplazamiento de página: con ella activa, Settings, Monitor y Audio no deslizan la página nueva.
 * Al abrir una ventana y al cambiar de página o pestaña, una ráfaga corta de
 * «señal que entra», como al cambiar de cámara en un monitor de seguridad: estática a bloques, dos bandas que bajan y
 * una raya de acento, todo desvaneciéndose (≈ 0,26 s Subtle, 0,36 s Strong). Encima del contenido, sin recibir clics.
 *
 * Sólo con el estilo terminal y movimiento Normal (`Style.fx.glitch`; Reduced/Off y los modos Focus/Gaming la quitan).
 * Nunca en el bloqueo ni en los avisos (no se coloca allí). Intensidad baja y desvanecida: no es un destello de pantalla
 * completa. Sin ráfaga no existe ningún objeto ni repinta nada (el Loader sólo vive mientras dura).
 *
 * Disparo:
 *   open  — al pasar a verdadero (y si nace ya abierta) suena una ráfaga;
 *   key   — al cambiar con `open` verdadero (página, pestaña, sección…) suena otra;
 *   burst() — a mano; `Style.interfere(item)` la busca desde un descendiente (Settings, Dashboard).
 */
Item {
    id: root
    objectName: "interferenceHost"

    property real s: 1
    property bool open: false
    property var key: ""
    /** Cuántas ráfagas han sonado (banco). */
    property int bursts: 0

    readonly property string level: Style.fx.glitch
    readonly property bool live: root.level !== "off"
    property real phase: 1

    function burst() {
        if (!root.live || root.width < 48 * root.s || root.height < 32 * root.s)
            return false;
        root.bursts++;
        anim.restart();
        return true;
    }
    /** Desde dentro de una superficie (`Style.interfere`): sólo si la ventana o el panel está abierto. */
    function ping() { return root.open ? root.burst() : false; }
    onOpenChanged: if (root.open) root.burst()
    onKeyChanged: if (root.open) root.burst()
    Component.onCompleted: if (root.open) Qt.callLater(root.burst)

    NumberAnimation {
        id: anim
        target: root
        property: "phase"
        from: 0
        to: 1
        duration: Motion.dur(root.level === "strong" ? 360 : 260)
    }

    visible: anim.running
    z: 1000

    Loader {
        objectName: "styleMarks"
        anchors.fill: parent
        active: anim.running
        sourceComponent: Item {
            id: fx
            clip: true
            readonly property real fade: Math.pow(Math.max(0, 1 - root.phase), 1.4)
            readonly property real peak: root.level === "strong" ? 0.30 : 0.16

            // estática a bloques: cuatro cuadros de ruido de 64×40 (lib/noise-frames.js) alternados y ampliados sin
            // suavizar; uno nuevo cada ~1/12 de la ráfaga. Sin Canvas: ver lib/noise-frames.js
            Image {
                anchors.fill: parent
                readonly property int frame: Math.floor(root.phase * 12)
                source: Noise.FRAMES[frame % Noise.FRAMES.length]
                smooth: false
                cache: true
                fillMode: Image.Stretch
                opacity: fx.fade * fx.peak
            }
            // dos bandas que bajan (la señal que se sincroniza)
            Repeater {
                model: 2
                Rectangle {
                    required property int index
                    width: fx.width
                    height: (index === 0 ? 22 : 9) * root.s
                    y: ((root.phase * (1.6 + 0.7 * index) + 0.37 * index) % 1) * fx.height - height / 2
                    color: Theme.fg
                    opacity: (root.level === "strong" ? 0.14 : 0.09) * fx.fade
                }
            }
            // una raya fina del acento que salta (el barrido)
            Rectangle {
                width: fx.width
                height: Math.max(1, Math.round(root.s))
                y: Math.round(((root.phase * 7.3) % 1) * fx.height)
                color: Theme.primary
                opacity: 0.4 * fx.fade
            }
        }
    }
}
