import QtQuick
import QtQuick.Shapes
import "../theme"
import "../services"

/**
 * PREVIEW NOTCH (fase 8F-2, futuredocksurface.md §Activación; en la UI «Notch» desde el 2026-11-12,
 * antes «Dock»: un dock es otra cosa): una maqueta del borde superior
 * de la pantalla con el notch recorriendo sus tres estados —reposo, desplegado y OSD— con el
 * movimiento del shell (Normal / Reduced / Off). Es una MUESTRA (DESIGN §6, PreviewCard):
 * los valores son ficticios y nada toca el volumen ni el brillo.
 *
 * Va dentro de la fila de Settings y no en el island real: Settings ocupa justo el island
 * de esa pantalla, así que enseñar el dock de verdad obligaría a cerrarlo.
 */
Item {
    id: root

    property real s: 1
    /** Reproduciendo la secuencia (el botón y Enter la arrancan; vuelve sola al reposo). */
    property bool playing: false
    /** idle · expanded · osd */
    property string phase: "idle"

    function play() {
        if (root.playing) { root.stop(); return; }
        root.playing = true;
        root.step = 0;
        seq.restart();
    }
    function stop() {
        seq.stop();
        root.playing = false;
        root.phase = "idle";
    }

    property int step: 0
    /** [fase, ms que dura] */
    // 2026-11-17: y una actividad en vivo (orejas: carátula y ondas), como la música en el notch real
    readonly property var script: [["idle", 700], ["expanded", 1500], ["idle", 600], ["osd", 1400], ["idle", 500],
                                   ["activity", 1600], ["idle", 400]]
    Timer {
        id: seq
        interval: 10
        onTriggered: {
            if (root.step >= root.script.length) { root.stop(); return; }
            root.phase = root.script[root.step][0];
            seq.interval = root.script[root.step][1];
            root.step++;
            seq.restart();
        }
    }

    implicitWidth: 150 * root.s
    implicitHeight: 44 * root.s

    /** Los faldones de las uniones con el borde (`Metrics.notchFlare*`, 2026-11-12), a la escala de la maqueta. */
    readonly property real flareW: 7 * root.s * Metrics.notchFlareScale
    readonly property real flareH: 4.5 * root.s * Metrics.notchFlareScale

    /** La «pantalla»: sólo su borde de arriba. */
    Rectangle {
        anchors.fill: parent
        radius: Metrics.r(6) * root.s
        color: Theme.tileBg
        border.width: 1
        border.color: Theme.hair
        clip: true

        /**
         * Las piezas laterales (2026-10-01): Música y Red, pequeñas, junto a la muesca en
         * reposo; se apartan cuando la forma crece, como en el dock real.
         */
        Repeater {
            model: [-1, 1]
            Rectangle {
                required property int modelData
                width: 9 * root.s
                height: width
                radius: Metrics.pill(width)
                y: 6 * root.s - height / 2
                // apartadas también del faldón, como las del notch real
                x: parent.width / 2 + modelData * (notch.width / 2 + root.flareW + 2 * root.s) - (modelData < 0 ? width : 0)
                color: Theme.notchBg
                // con la oreja de música el círculo de Música se queda, fuera de la oreja (como en el notch real)
                opacity: root.phase === "osd" ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: Motion.fast } }
            }
        }

        /**
         * Las uniones con el borde, una a cada lado del notch: el mismo trazado que la muesca real (faldón
         * más largo que alto, tiradores largos). Debajo del notch y montadas un píxel sobre él (los dos opacos).
         */
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeWidth: -1
                fillColor: Theme.notchBg
                PathSvg {
                    path: {
                        const fw = root.flareW, fh = root.flareH, k = Metrics.notchFlareK;
                        const x0 = notch.x, x1 = notch.x + notch.width;
                        return "M " + (x0 - fw) + " 0 C " + (x0 - fw + k * fw) + " 0 " + x0 + " " + (fh - k * fh)
                            + " " + x0 + " " + fh + " L " + (x0 + 1) + " " + fh + " L " + (x0 + 1) + " 0 Z"
                            + " M " + (x1 + fw) + " 0 C " + (x1 + fw - k * fw) + " 0 " + x1 + " " + (fh - k * fh)
                            + " " + x1 + " " + fh + " L " + (x1 - 1) + " " + fh + " L " + (x1 - 1) + " 0 Z";
                    }
                }
            }
        }

        /** El notch: pegado al borde, esquinas de abajo redondeadas. */
        Rectangle {
            id: notch
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            readonly property real tw: root.phase === "expanded" ? 104 * root.s
                : root.phase === "osd" ? 72 * root.s : root.phase === "activity" ? 76 * root.s : 44 * root.s
            readonly property real th: root.phase === "expanded" ? 34 * root.s : 12 * root.s
            width: tw
            height: th
            // 2026-10-01: más redondo, como `Metrics.notchCorner` (casi medio alto)
            radius: Metrics.r(root.phase === "expanded" ? 9 : 6) * root.s * Metrics.notchCornerScale
            color: Theme.notchBg
            // el contenido nunca fuera de la forma (texto fantasma, memoria del proyecto)
            clip: true
            Behavior on width { NumberAnimation { duration: Motion.still ? Motion.calmMs : Motion.standard; easing.type: Easing.OutCubic } }
            Behavior on height { NumberAnimation { duration: Motion.still ? Motion.calmMs : Motion.standard; easing.type: Easing.OutCubic } }
            Behavior on radius { NumberAnimation { duration: Motion.still ? Motion.calmMs : Motion.standard } }

            // las esquinas de arriba, rectas
            Rectangle {
                anchors.top: parent.top
                width: parent.width
                height: Math.min(parent.radius, parent.height / 2)
                color: parent.color
            }

            /** Reposo: la hora, diminuta. */
            Text {
                anchors.centerIn: parent
                text: "9:41"
                color: Theme.fg
                font.family: Typography.ui
                font.pixelSize: 7 * root.s
                font.weight: Font.DemiBold
                // la hora espera a que la forma haya vuelto al reposo: nunca a la vez que lo que sale
                opacity: Settings.notchRest !== "minimal" && notch.height < 16 * root.s
                    && ((root.phase === "idle" && notch.width < 50 * root.s) || (root.phase === "activity" && notch.width > 70 * root.s)) ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: root.phase === "idle" ? Motion.fast : Motion.vanish } }
            }

            /** Desplegado: un panel con renglones (la forma primero, el contenido después). */
            Column {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.margins: 6 * root.s
                spacing: 3 * root.s
                opacity: root.phase === "expanded" && notch.height > 28 * root.s ? 1 : 0
                // entra con `fast` cuando ya cabe; sale en `vanish`, antes de que la forma encoja
                Behavior on opacity { NumberAnimation { duration: root.phase === "expanded" ? Motion.fast : Motion.vanish } }
                Repeater {
                    model: [0.9, 0.6, 0.75]
                    Rectangle {
                        required property real modelData
                        width: (104 - 12) * root.s * modelData
                        height: 4 * root.s
                        radius: Metrics.r(2) * root.s
                        color: Theme.fgVariant
                        opacity: 0.6
                    }
                }
            }

            /** Actividad: las orejas, una carátula ficticia a la izquierda y ondas quietas a la derecha. */
            Item {
                anchors.fill: parent
                opacity: root.phase === "activity" && notch.width > 70 * root.s ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: root.phase === "activity" ? Motion.fast : Motion.vanish } }
                Rectangle {
                    x: 4 * root.s
                    anchors.verticalCenter: parent.verticalCenter
                    width: 7 * root.s; height: 7 * root.s; radius: Metrics.r(2) * root.s
                    color: Theme.warn
                }
                Row {
                    anchors.right: parent.right
                    anchors.rightMargin: 4 * root.s
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1 * root.s
                    Repeater {
                        model: [0.5, 1, 0.7]
                        Rectangle {
                            required property real modelData
                            anchors.verticalCenter: parent.verticalCenter
                            width: 1.5 * root.s; height: 6 * root.s * modelData
                            color: Theme.primary
                        }
                    }
                }
            }

            /** OSD: glifo y nivel ficticios (60 %). */
            Row {
                anchors.centerIn: parent
                spacing: 4 * root.s
                opacity: root.phase === "osd" && notch.width > 64 * root.s ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: root.phase === "osd" ? Motion.fast : Motion.vanish } }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 5 * root.s; height: 5 * root.s; radius: Metrics.r(1)
                    color: Theme.fg
                }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 48 * root.s; height: 3 * root.s; radius: Metrics.pill(height)
                    color: Theme.hair
                    Rectangle {
                        width: parent.width * 0.6; height: parent.height; radius: parent.radius
                        color: Theme.primary
                    }
                }
            }
        }
    }

    Accessible.role: Accessible.Animation
    Accessible.name: "Edge preview: " + root.phase
}
