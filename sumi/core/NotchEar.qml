import QtQuick
import Quickshell
import Quickshell.Widgets
import "../theme"
import "../services"
import "../components"
import "../lib/notch-activities.js" as Acts

/**
 * Una oreja del notch (2026-11-17): lo que se ve a un lado de la muesca mientras hay una actividad en vivo. A la
 * izquierda QUÉ es (carátula, «REC», cohete, batería…), a la derecha su DATO (ondas, tiempo, Mb/s, %…).
 *
 * Sólo pinta, como la cara de reposo: acercar el puntero despliega la fila hover, que es donde viven los clics. El
 * ancho es FIJO por actividad, el mismo a los dos lados (`lib/notch-activities.js`): nada se mide por su texto y el
 * reloj no se mueve del centro. El contenido va pegado al borde de FUERA (`pad`), con el aire junto al reloj.
 *
 * DINÁMICA (segunda pasada del 2026-11-17, pedido del usuario: «haz dinámicos los cambios del modo notch»). Todo con
 * los tokens de `Motion`: Off lo pone al final de golpe; Reduced (`Motion.still`) sólo funde, sin desplazar ni rebotar.
 *   · Relevo: al cambiar de actividad, lo que había se va (`vanish`) y lo nuevo EMERGE desde el reloj hacia fuera
 *     (`swap`: opacidad y 8 px hacia dentro → 0). La misma actividad con datos nuevos no se releva: se anima dentro.
 *   · Iconos con un pequeño rebote al llegar (`pop`); los porcentajes suben desde 0 (`count`).
 *   · Workspace: el número RUEDA hacia arriba o hacia abajo según suba o baje, y el punto encendido llega desde el lado
 *     del que venía (`wsRoll`).
 *   · Grabación: «REC» parpadea despacio mientras graba (un relevo cada 0,9 s, no una animación continua).
 *   · Speed test: el número se desliza entre lecturas.
 *   · Música: la carátula rebota al cambiar de pista; las ondas son las de cava a sus fps (`services/Cava`) o, con el
 *     visualizador en Off o sin cava, sintéticas a saltos (~5 Hz).
 * Nada anima por fotograma en reposo: cada animación es finita y sólo corre cuando algo cambia (memoria del proyecto:
 * una animación de reposo infinita cuesta un 8 % de CPU a 200 Hz).
 */
Item {
    id: ear

    /** La actividad pedida (Island la retiene mientras la oreja se va). */
    property string activity: ""
    /** "left" · "right" */
    property string side: "left"
    property real s: 1
    /** Se ve de verdad (en reposo y con opacidad): sólo entonces se mueven las ondas y parpadea REC. */
    property bool live: false
    /** Lo que dice una flash (`LiveActivity.flashData`). */
    property var info: ({})

    readonly property bool isLeft: ear.side === "left"
    /** La que se DIBUJA: sigue a `activity` con el relevo. */
    property string shown: ""
    width: Acts.width(ear.shown) * ear.s
    height: Metrics.restH * ear.s

    /** Del borde de fuera al contenido: lo que se come la esquina redonda de abajo, más aire. */
    readonly property real pad: 10 * ear.s

    readonly property string batteryGlyph: Battery.glyphFor(Battery.externalPower)
    readonly property bool btHasValue: !!ear.info && typeof ear.info.value === "number" && ear.info.value >= 0

    // ---- relevo entre actividades ------------------------------------------------------------------------------

    property real swap: 1
    property real pop: 1
    property real count: 1

    onActivityChanged: {
        if (ear.activity.length === 0 || ear.activity === ear.shown) return;
        if (ear.shown.length === 0 || Motion.off) {
            relay.stop();
            ear.shown = ear.activity;
            enter.restart();
            return;
        }
        relay.restart();
    }
    Component.onCompleted: if (ear.activity.length > 0) { ear.shown = ear.activity; enter.restart(); }

    SequentialAnimation {
        id: relay
        NumberAnimation { target: ear; property: "swap"; to: 0; duration: Motion.vanish; easing.type: Easing.InCubic }
        ScriptAction { script: { ear.shown = ear.activity; enter.restart(); } }
    }
    ParallelAnimation {
        id: enter
        NumberAnimation { target: ear; property: "swap"; from: 0; to: 1; duration: Motion.standard; easing.type: Easing.OutCubic }
        NumberAnimation {
            target: ear; property: "pop"; from: Motion.still ? 1 : 0.55; to: 1
            duration: Motion.still ? 0 : Motion.dur(320); easing.type: Easing.OutBack; easing.overshoot: 2.2
        }
        NumberAnimation {
            target: ear; property: "count"; from: Motion.off ? 1 : 0; to: 1
            duration: Motion.off ? 0 : Motion.dur(520); easing.type: Easing.OutCubic
        }
    }

    // ---- workspace: rueda el número, el punto llega del lado de antes --------------------------------------------

    property real wsRoll: 1
    property string wsOld: ""
    /** +1 subiendo de número (el nuevo entra por abajo), -1 bajando. */
    property int wsDir: 1
    readonly property string wsText: ear.info && ear.info.text !== undefined ? String(ear.info.text) : ""
    function wsStart() {
        const from = ear.info && typeof ear.info.from === "number" ? ear.info.from : 0;
        const to = ear.info && typeof ear.info.value === "number" ? ear.info.value : 0;
        ear.wsDir = to >= from ? 1 : -1;
        ear.wsOld = from > 0 && from !== to ? String(from) : "";
        if (Motion.off || ear.wsOld.length === 0) {
            roll.stop();
            ear.wsRoll = 1;
            return;
        }
        roll.restart();
    }
    onInfoChanged: if (ear.shown === "workspace" && ear.activity === "workspace") ear.wsStart()
    onShownChanged: if (ear.shown === "workspace") ear.wsStart()
    NumberAnimation {
        id: roll
        target: ear; property: "wsRoll"; from: 0; to: 1
        duration: Motion.dur(Motion.still ? 160 : 280); easing.type: Easing.OutCubic
    }

    // ---- grabación: REC parpadea despacio ---------------------------------------------------------------------

    property bool recDim: false
    Timer {
        interval: 900
        repeat: true
        running: ear.live && ear.isLeft && ear.shown === "recording" && ScreenRecorder.capturing && !Motion.still
        onTriggered: ear.recDim = !ear.recDim
        onRunningChanged: if (!running) ear.recDim = false
    }

    // ---- speed test: el número se desliza ---------------------------------------------------------------------

    property real mbpsShown: 0
    readonly property real mbpsTarget: isFinite(SpeedTest.liveMbps) ? SpeedTest.liveMbps : 0
    onMbpsTargetChanged: ear.mbpsShown = ear.mbpsTarget
    Behavior on mbpsShown {
        enabled: ear.shown === "speed" && !Motion.off
        NumberAnimation { duration: Motion.dur(Motion.still ? 160 : 380); easing.type: Easing.OutCubic }
    }

    // ---- música: la carátula rebota al cambiar de pista ------------------------------------------------------

    property real artPop: 1
    Connections {
        target: Media
        function onTrackKeyChanged() {
            if (ear.shown === "music" && ear.isLeft && !Motion.still) artBounce.restart();
        }
    }
    NumberAnimation {
        id: artBounce
        target: ear; property: "artPop"; from: 0.6; to: 1
        duration: Motion.dur(380); easing.type: Easing.OutBack; easing.overshoot: 1.8
    }

    /** cava: esta oreja la quiere mientras se ve con música (fps, reproductor y lock los decide el servicio). */
    readonly property bool wantsCava: ear.live && !ear.isLeft && ear.shown === "music" && Settings.notchVisualizerFps > 0
    readonly property string cavaKey: "ear-" + ear.side + "-" + Math.round(Math.random() * 1e9)
    onWantsCavaChanged: Cava.claim(ear.cavaKey, ear.wantsCava)
    Component.onDestruction: Cava.claim(ear.cavaKey, false)
    /** Ondas reales: cava instalado, encendido y corriendo. */
    readonly property bool realWaves: Settings.notchVisualizerFps > 0 && Cava.available && Cava.running

    // ---- el contenido -------------------------------------------------------------------------------------------

    Row {
        id: slot
        anchors.verticalCenter: parent.verticalCenter
        x: ear.isLeft ? ear.pad : ear.width - slot.width - ear.pad
        spacing: 0
        opacity: ear.swap
        /** Emerge desde el reloj hacia fuera (Reduced y Off: sólo el fundido). */
        transform: Translate { x: Motion.still ? 0 : (1 - ear.swap) * (ear.isLeft ? 8 : -8) * ear.s }

        // ---- izquierda: qué es -----------------------------------------------------------------------------------

        /** Música: la carátula; sin ella, el glifo. */
        ClippingRectangle {
            anchors.verticalCenter: parent.verticalCenter
            visible: ear.isLeft && ear.shown === "music"
            width: 22 * ear.s
            height: 22 * ear.s
            radius: Metrics.r(6) * ear.s
            color: Theme.tileBg
            scale: ear.pop * ear.artPop
            Image {
                id: art
                anchors.fill: parent
                source: ear.isLeft && ear.shown === "music" ? Media.artUrl : ""
                sourceSize.width: Math.ceil(44 * ear.s)
                sourceSize.height: Math.ceil(44 * ear.s)
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                retainWhileLoading: true
                cache: false
            }
            Icon {
                anchors.centerIn: parent
                name: "music"
                size: 13 * ear.s
                color: Theme.fg
                visible: !(art.status === Image.Ready && Media.artUrl.length > 0)
            }
        }

        /** Grabación: «REC» en el rojo de privacidad (fijo, como el punto: no depende del fondo). */
        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: ear.isLeft && ear.shown === "recording"
            text: "REC"
            color: Theme.privacyScreen
            opacity: ScreenRecorder.paused ? 0.55 : (ear.recDim ? 0.35 : 1)
            Behavior on opacity { NumberAnimation { duration: Motion.off ? 0 : Motion.dur(280); easing.type: Easing.InOutSine } }
            font.family: Typography.ui
            font.pixelSize: Typography.micro * ear.s
            font.weight: Font.Bold
            font.letterSpacing: Typography.tracking * ear.s
        }

        Icon {
            anchors.verticalCenter: parent.verticalCenter
            visible: ear.isLeft && ["speed", "work", "power", "copy", "bluetooth"].indexOf(ear.shown) >= 0
            size: 15 * ear.s
            scale: ear.pop
            name: ear.shown === "speed" ? (SpeedTest.phase === "upload" ? "upload" : "rocket")
                : ear.shown === "work" ? LiveActivity.workGlyph
                : ear.shown === "power" ? ear.batteryGlyph
                : ear.shown === "copy" ? "check"
                : (ear.info && ear.info.glyph ? ear.info.glyph : "headphones")
            color: ear.shown === "power" ? (Battery.externalPower ? Theme.ok : Theme.fgVariant)
                : ear.shown === "copy" ? Theme.ok
                : Theme.primary
        }

        /**
         * Workspace: tres huecos; el punto encendido llega al del medio desde el lado del workspace de antes (por la
         * izquierda si sube, por la derecha si baja).
         */
        Item {
            anchors.verticalCenter: parent.verticalCenter
            visible: ear.isLeft && ear.shown === "workspace"
            width: 24 * ear.s
            height: 8 * ear.s
            Repeater {
                model: 3
                Rectangle {
                    required property int index
                    anchors.verticalCenter: parent.verticalCenter
                    x: (index * 8 + 2) * ear.s
                    width: 4 * ear.s
                    height: width
                    radius: Metrics.pill(width)
                    color: Theme.fgVariant
                    opacity: 0.5
                }
            }
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                readonly property real fromX: (ear.wsDir > 0 ? 0 : 16) * ear.s
                x: fromX + (8 * ear.s - fromX) * ear.wsRoll
                width: 8 * ear.s
                height: width
                radius: Metrics.pill(width)
                color: Theme.primary
            }
        }

        // ---- derecha: el dato ------------------------------------------------------------------------------------

        /**
         * Música: las ondas. Con cava, sus niveles a sus fps (lo liso lo da su suavizado: sin `Behavior`). Sin cava o
         * con el visualizador en Off, sintéticas a saltos ~5 veces por segundo, sólo sonando y a la vista.
         */
        Row {
            id: waves
            anchors.verticalCenter: parent.verticalCenter
            visible: !ear.isLeft && ear.shown === "music"
            spacing: 3 * ear.s
            readonly property bool synthMoving: waves.visible && ear.live && Media.playing && !Motion.off && !ear.realWaves
            property var heights: [0.45, 0.8, 0.6, 0.95]
            Timer {
                interval: 190
                repeat: true
                running: waves.synthMoving
                onTriggered: waves.heights = [0, 1, 2, 3].map(() => 0.3 + Math.random() * 0.7)
            }
            Repeater {
                model: 4
                Rectangle {
                    required property int index
                    anchors.verticalCenter: parent.verticalCenter
                    width: 3 * ear.s
                    readonly property real level: ear.realWaves
                        ? (Cava.active ? 0.18 + 0.82 * (Cava.levels[index] || 0) : 0.25)
                        : (waves.synthMoving ? waves.heights[index] : 0.25)
                    height: Math.max(3, level * 16 * ear.count) * ear.s
                    radius: Metrics.r(1.5) * ear.s
                    color: Media.playing ? Theme.primary : Theme.fgVariant
                    opacity: Media.playing ? 1 : 0.6
                }
            }
        }

        /** Workspace: el número rueda (el de antes sale por un lado, el nuevo entra por el otro). */
        Item {
            id: wsBox
            anchors.verticalCenter: parent.verticalCenter
            visible: !ear.isLeft && ear.shown === "workspace"
            width: 16 * ear.s
            height: 20 * ear.s
            clip: true
            readonly property real travel: Motion.still ? 0 : 14 * ear.s
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                y: (wsBox.height - height) / 2 - ear.wsDir * wsBox.travel * ear.wsRoll
                opacity: 1 - ear.wsRoll
                visible: ear.wsOld.length > 0 && ear.wsRoll < 1
                text: ear.wsOld
                color: Theme.primary
                font.family: Typography.ui
                font.pixelSize: Typography.body * ear.s
                font.weight: Typography.wStrong
                font.features: { "tnum": 1 }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                y: (wsBox.height - height) / 2 + ear.wsDir * wsBox.travel * (1 - ear.wsRoll)
                opacity: ear.wsOld.length > 0 ? ear.wsRoll : 1
                text: ear.wsText
                color: Theme.primary
                font.family: Typography.ui
                font.pixelSize: Typography.body * ear.s
                font.weight: Typography.wStrong
                font.features: { "tnum": 1 }
            }
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: !ear.isLeft && ["recording", "speed", "work", "power", "copy"].indexOf(ear.shown) >= 0
                || (!ear.isLeft && ear.shown === "bluetooth" && ear.btHasValue)
            readonly property real powerPct: Battery.present ? Battery.percent
                : (ear.info && ear.info.value >= 0 ? ear.info.value : 0)
            text: ear.shown === "recording" ? ScreenRecorder.clock
                : ear.shown === "speed" ? (isFinite(SpeedTest.liveMbps) ? Math.round(ear.mbpsShown) + " Mb/s" : "···")
                : ear.shown === "work" ? LiveActivity.workText
                : ear.shown === "power" ? Math.round(powerPct * ear.count) + "%"
                : ear.shown === "copy" ? (ear.info && ear.info.text ? ear.info.text : "Copied")
                : ear.shown === "bluetooth" ? (ear.btHasValue ? Math.round(ear.info.value * ear.count) + "%" : "")
                : ""
            color: ear.shown === "recording" ? (ScreenRecorder.paused ? Theme.warn : Theme.fg)
                : ear.shown === "speed" ? Theme.primary
                : Theme.fg
            font.family: Typography.ui
            font.pixelSize: Typography.label * ear.s
            font.weight: ear.shown === "copy" ? Typography.wMedium : Typography.wStrong
            font.features: { "tnum": 1 }
        }

        /** Auriculares sin batería que decir: conectados, y basta. */
        Icon {
            anchors.verticalCenter: parent.verticalCenter
            visible: !ear.isLeft && ear.shown === "bluetooth" && !ear.btHasValue
            name: "check"
            size: 14 * ear.s
            scale: ear.pop
            color: Theme.ok
        }
    }
}
