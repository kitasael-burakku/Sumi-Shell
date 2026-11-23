import QtQuick
import "../components"
import "../theme"

/**
 * La música del Lock (fase 15, LOCK-D13): portada pequeña, título, artista y anterior/play-pausa/
 * siguiente. Sin visualizador (el Lock deja de reclamar Cava), sin seek ni progreso.
 *
 * Sin reproductor: «No active player» con el transporte deshabilitado y el glifo de música, en el
 * mismo alto. El título que no cabe se desplaza (excepción conservada del usuario, §10), también con
 * Reduced; con Off, elipsis. Se para en cuanto la tarjeta deja de verse (calma).
 */
Rectangle {
    id: root

    property var context
    property real s: 1
    /** `Motion.still` (Off) apaga el desplazamiento: elipsis. */
    property bool marqueeAllowed: !Motion.off
    /** En calma el título no se desplaza (§10): la tarjeta está a opacidad 0, no oculta. */
    property bool paused: false

    readonly property var music: root.context && root.context.music ? root.context.music : ({ has: false })
    readonly property bool has: root.music.has === true

    implicitHeight: 76 * root.s
    radius: Metrics.rMd * root.s
    color: Theme.tileBg

    Accessible.role: Accessible.Grouping
    Accessible.name: root.has ? "Now playing: " + (root.music.title || "Unknown title")
        + (root.music.artist ? " by " + root.music.artist : "") : "No active player"

    LockImage {
        id: cover
        anchors.left: parent.left
        anchors.leftMargin: Metrics.sp3 * root.s
        anchors.verticalCenter: parent.verticalCenter
        width: 52 * root.s
        height: width
        s: root.s
        radius: Metrics.rSm * root.s
        source: root.has ? (root.music.artUrl || "") : ""
        fallbackIcon: "music"
    }

    Row {
        id: transport
        anchors.right: parent.right
        anchors.rightMargin: Metrics.sp2 * root.s
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2 * root.s

        Repeater {
            model: [
                { glyph: "prev", action: "previous", can: root.has && root.music.canPrev === true, name: "Previous track" },
                { glyph: root.music.playing ? "pause" : "play", action: "toggle", can: root.has && root.music.canToggle === true,
                  name: root.music.playing ? "Pause" : "Play" },
                { glyph: "next", action: "next", can: root.has && root.music.canNext === true, name: "Next track" }
            ]
            delegate: Item {
                id: btn
                required property var modelData
                width: 30 * root.s
                height: 30 * root.s
                opacity: btn.modelData.can ? 1 : 0.35
                enabled: btn.modelData.can
                activeFocusOnTab: false   // recorrido explícito de la superficie (15C)
                Accessible.role: Accessible.Button
                Accessible.name: btn.modelData.name
                // recorrido de teclado del Lock (15C): sólo lo que el reproductor admite
                readonly property bool lockFocusable: btn.enabled
                readonly property string lockFocusName: btn.modelData.name

                Rectangle {
                    anchors.fill: parent
                    radius: Metrics.pill(width)
                    color: btn.activeFocus ? Theme.selBg
                        : area.containsMouse && btn.modelData.can ? Theme.hoverBg : "transparent"
                    border.width: btn.activeFocus ? Metrics.focusWidth * root.s : 0
                    border.color: Theme.focusRing
                }
                Keys.onPressed: (e) => {
                    if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) {
                        if (!e.isAutoRepeat && root.context) root.context.media(btn.modelData.action);
                        e.accepted = true;
                    }
                }
                Icon {
                    anchors.centerIn: parent
                    name: btn.modelData.glyph
                    size: 16 * root.s
                }
                MouseArea {
                    id: area
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: btn.modelData.can
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (root.context) root.context.media(btn.modelData.action)
                }
            }
        }
    }

    Column {
        anchors.left: cover.right
        anchors.leftMargin: Metrics.sp3 * root.s
        anchors.right: transport.left
        anchors.rightMargin: Metrics.sp2 * root.s
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2 * root.s

        Item {
            id: titleBox
            width: parent.width
            height: title.implicitHeight
            clip: true

            /**
             * El ancho natural se mide aparte: con `elide`, el `implicitWidth` del propio Text pasa a ser
             * el recortado y el desplazamiento movía «Umapyoi Densetsu …» hasta dejar la tarjeta en blanco.
             */
            TextMetrics { id: natural; font: title.font; text: title.text }
            readonly property real overflow: Math.max(0, Math.ceil(natural.advanceWidth) - titleBox.width)
            readonly property bool scrolls: root.marqueeAllowed && titleBox.overflow > 0
            property real offset: 0

            Text {
                id: title
                x: titleBox.scrolls ? -titleBox.offset : 0
                width: titleBox.scrolls ? Math.ceil(natural.advanceWidth) + 1 : titleBox.width
                elide: titleBox.scrolls ? Text.ElideNone : Text.ElideRight
                text: root.has ? (root.music.title || "Unknown title") : "No active player"
                color: root.has ? Theme.fg : Theme.fgVariant
                font.family: Typography.uiChosen
                font.weight: root.has ? Typography.wStrong : Typography.wNormal
                font.pixelSize: Typography.body * root.s
            }

            SequentialAnimation {
                running: titleBox.scrolls && root.visible && !root.paused
                loops: Animation.Infinite
                onRunningChanged: if (!running) titleBox.offset = 0
                PauseAnimation { duration: 1800 }
                NumberAnimation {
                    target: titleBox; property: "offset"; from: 0; to: titleBox.overflow
                    duration: Math.max(600, titleBox.overflow / (36 * root.s) * 1000)
                    easing.type: Easing.Linear
                }
                PauseAnimation { duration: 1400 }
                NumberAnimation { target: titleBox; property: "offset"; to: 0; duration: 360; easing.type: Easing.OutCubic }
            }
        }

        Text {
            width: parent.width
            visible: root.has && text.length > 0
            text: root.music.artist || ""
            elide: Text.ElideRight
            color: Theme.fgVariant
            font.family: Typography.uiChosen
            font.pixelSize: Typography.caption * root.s
        }
    }
}
