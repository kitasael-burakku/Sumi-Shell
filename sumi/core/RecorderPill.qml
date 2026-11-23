import QtQuick
import "../theme"
import "../services"
import "../components"

/**
 * La pieza de grabación bajo el island (2026-10-29, pedido del usuario: «un mini HUD» que diga que se
 * graba, cuánto y deje pausar o parar sin abrir la surface).
 *
 * Como las piezas laterales (`IslandCircle`), NO es hija del `Morph`: la coloca `core/Screen` bajo la
 * forma, sigue su borde de abajo al muelle (cara hover, OSD, un panel abierto) y tiene su propio
 * rectángulo en la máscara de entrada, fuera del hover del island. Por eso se puede pulsar: la cara de
 * reposo es sólo de lectura (acercarse la despliega) y aquí hacían falta botones.
 *
 *   ●  00:42  │ ⏸  ■     grabando: el punto rojo (el de privacidad), el tiempo, pausa y parar
 *   ⏸  00:42  │ ▶  ■     en pausa: la grabación sigue viva
 *   ○  Starting in 3 │ ✕  preparando (cuenta atrás, región): Cancel
 *   ○  Saving…            guardando; después ✓ Saved o ⚠ Failed unos segundos y se va
 *   ✓  Saved  │ ⧉        guardada (segunda entrega): Copy, la grabación al portapapeles como archivo
 *
 * Con el puntero encima, el aviso de guardada/copiada no se va (`ScreenRecorder.holdFlash`): 4 s no dan
 * para llegar a Copy con el ratón.
 *
 * Un clic fuera de los botones abre el grabador. Sin rebotes ni parpadeos: aparece y se va con el
 * fundido corto de las piezas, y su ancho sigue al contenido con el mismo muelle que la forma.
 *
 * Grabador 2.0 (Settings → Screen recording → Behavior): sin «Controls under the island» queda sólo el indicador
 * (un clic sigue abriendo el grabador); sin el temporizador dice «Recording»/«Paused». Que se vea o no (el
 * indicador) lo decide Screen. El reloj es el del servicio: la barra y la surface leen el mismo.
 */
Item {
    id: pill

    property real s: 1
    /** Si se ve (lo decide Screen). Controla también la máscara y el hover. */
    property bool shown: false
    signal openRequested()

    readonly property bool hovered: hh.hovered
    /** La rojo de privacidad del island (`PrivacyDot`): fija, su significado no depende del fondo. */
    readonly property color recRed: Theme.dangerText
    readonly property bool buttons: Settings.recIslandControls
        && (ScreenRecorder.live || ScreenRecorder.preparing || ScreenRecorder.offerCopy)
    /**
     * Notch en vivo (2026-11-17): con la oreja de grabación en la muesca (punto y tiempo ya arriba), grabando sólo los
     * botones. Preparando, guardando o guardada sigue siendo la de siempre. Lo pone Screen.
     */
    property bool buttonsOnly: false
    readonly property bool compact: pill.buttonsOnly && pill.buttons && ScreenRecorder.live
    readonly property string label: ScreenRecorder.live ? (Settings.recTimer ? ScreenRecorder.clock : ScreenRecorder.paused ? "Paused" : "Recording")
        : ScreenRecorder.active ? ScreenRecorder.statusText
        : ScreenRecorder.flashText

    property real targetW: Math.ceil(row.implicitWidth + 2 * 11 * pill.s)
    width: widthSpring.value
    SpringValue { id: widthSpring; target: pill.targetW; animate: pill.visible; epsilon: 0.3 }
    height: Metrics.recPillH * pill.s

    property real shownOpacity: pill.shown ? 1 : 0
    opacity: pill.shownOpacity
    scale: pill.shown ? 1 : 0.9
    visible: pill.shown || pill.opacity > 0.01
    Behavior on shownOpacity { NumberAnimation { duration: pill.shown ? Motion.fast : Motion.vanish; easing.type: Easing.OutCubic } }
    Behavior on scale { NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic } }

    Glass {
        anchors.fill: parent
        radius: Metrics.pill(height)
        s: pill.s
        shadowed: pill.shown
    }

    // Debajo del contenido: un clic que no cae en un botón abre el grabador (los botones van encima).
    MouseArea {
        anchors.fill: parent
        enabled: pill.shown
        cursorShape: Qt.PointingHandCursor
        onClicked: pill.openRequested()
    }
    HoverHandler {
        id: hh
        enabled: pill.shown
        onHoveredChanged: ScreenRecorder.holdFlash("pointer", hh.hovered)
    }

    Item {
        anchors.fill: parent
        clip: true

        Row {
            id: row
            anchors.centerIn: parent
            spacing: 8 * pill.s

            /** El indicador: punto lleno grabando, aro preparando o guardando, pausa, o el resultado. */
            Item {
                anchors.verticalCenter: parent.verticalCenter
                visible: !pill.compact
                width: 12 * pill.s
                height: 12 * pill.s
                Rectangle {
                    anchors.centerIn: parent
                    visible: ScreenRecorder.active && !ScreenRecorder.paused
                    width: 8 * pill.s
                    height: width
                    radius: Metrics.pill(width)
                    color: ScreenRecorder.status === "recording" ? pill.recRed : "transparent"
                    border.width: ScreenRecorder.status === "recording" ? 0 : Math.max(1, 1.5 * pill.s)
                    border.color: ScreenRecorder.status === "saving" ? Theme.fgVariant : pill.recRed
                    Behavior on color { ColorAnimation { duration: Motion.fast } }
                }
                Icon {
                    anchors.centerIn: parent
                    visible: ScreenRecorder.paused || (!ScreenRecorder.active && ScreenRecorder.flashing)
                    name: ScreenRecorder.paused ? "pause" : ScreenRecorder.flashTone === "danger" || ScreenRecorder.flashTone === "warn"
                        ? "alert" : ScreenRecorder.flashTone === "ok" ? "check-circle" : "close"
                    size: 12 * pill.s
                    color: ScreenRecorder.paused ? Theme.warn : ScreenRecorder.flashTone === "danger" ? Theme.danger
                        : ScreenRecorder.flashTone === "warn" ? Theme.warn : ScreenRecorder.flashTone === "ok" ? Theme.ok : Theme.fgVariant
                }
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: !pill.compact
                text: pill.label
                color: ScreenRecorder.paused ? Theme.fgVariant : Theme.fg
                font.family: ScreenRecorder.live && Settings.recTimer ? Typography.mono : Typography.ui
                font.pixelSize: Typography.label * pill.s
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                visible: pill.buttons && !pill.compact
                width: Metrics.hair
                height: 14 * pill.s
                color: Theme.hair
            }

            Repeater {
                model: !pill.buttons ? []
                    : ScreenRecorder.offerCopy ? [{ key: "copy", glyph: "copy", label: "Copy the recording" }]
                    : ScreenRecorder.preparing ? [{ key: "cancel", glyph: "close", label: "Cancel recording" }]
                    : [{ key: "toggle", glyph: ScreenRecorder.paused ? "play" : "pause",
                         label: ScreenRecorder.paused ? "Resume recording" : "Pause recording" },
                       { key: "stop", glyph: "stop", label: "Stop and save the recording" }]
                delegate: Item {
                    id: btn
                    required property var modelData
                    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                    width: 22 * pill.s
                    height: 22 * pill.s
                    readonly property bool busy: ScreenRecorder.requested.length > 0
                    function press() {
                        if (btn.busy) return;
                        if (btn.modelData.key === "copy") ScreenRecorder.copyLast();
                        else if (btn.modelData.key === "toggle") ScreenRecorder.togglePause();
                        else if (btn.modelData.key === "stop") ScreenRecorder.stop();
                        else ScreenRecorder.cancel();
                    }
                    Accessible.role: Accessible.Button
                    Accessible.name: btn.modelData.label
                    Accessible.onPressAction: btn.press()

                    Rectangle {
                        anchors.fill: parent
                        radius: Metrics.pill(width)
                        color: btnArea.containsMouse ? Theme.hoverBg : "transparent"
                        Behavior on color { ColorAnimation { duration: Motion.fast } }
                    }
                    Icon {
                        anchors.centerIn: parent
                        name: btn.modelData.glyph
                        size: 13 * pill.s
                        opacity: btn.busy ? 0.45 : 1
                        color: btn.modelData.key === "stop" ? pill.recRed : btnArea.containsMouse ? Theme.fg : Theme.fgVariant
                    }
                    MouseArea {
                        id: btnArea
                        anchors.fill: parent
                        anchors.margins: -2 * pill.s
                        enabled: pill.shown
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: btn.press()
                    }
                }
            }
        }
    }

    Accessible.role: Accessible.Pane
    Accessible.name: ScreenRecorder.active ? "Screen recorder: " + ScreenRecorder.statusText : ScreenRecorder.flashText
}
