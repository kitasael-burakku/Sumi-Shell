import QtQuick
import "../theme"

/**
 * Miniatura animada de un estilo del bloqueo (2026-11-28, Settings → Animations → Lock style): un escritorio que se
 * vela y un panel de bloqueo con reloj, campo y dos columnas. Con un estilo de ventana, el panel abre con theme/Reveal
 * (y theme/RevealEffect) y después entran reloj y campo, y las columnas; con Sumi, el centro primero y las columnas
 * desde él. «Same as windows» enseña el Window style de ahora. Sólo se mueve mientras `playing`; quieta, abierta.
 */
Item {
    id: root

    property real s: 1
    property string style: "windows"
    property bool playing: false

    readonly property string resolved: Motion.resolveLockStyle(root.style)
    readonly property bool sumi: root.resolved === "sumi"

    implicitWidth: 136 * s
    implicitHeight: 80 * s

    Reveal {
        id: prv
        style: root.sumi ? "minimalist" : root.resolved
        animated: cycle.playing && !root.sumi
        s: root.s * 0.5
        shown: cycle.opened
    }

    PreviewCycle {
        id: cycle
        playing: root.playing && !Motion.off
        openMs: Motion.lockOpenFor(root.resolved) + Motion.lockStagger + Motion.lockContentMs
        closeMs: Motion.lockAccept + Motion.lockCloseFor(root.resolved)
    }

    // El contenido: el mismo escalonado que el bloqueo (LockBoardSurface), en el tiempo de la miniatura.
    property real core: 1
    property real details: 1
    property real veil: 1
    readonly property int openMs: Motion.lockOpenFor(root.resolved)
    readonly property int closeMs: Motion.lockCloseFor(root.resolved)
    readonly property int coreDelay: root.sumi ? 0 : Math.round(root.openMs * (Motion.still ? 0.2 : 0.35))
    Connections {
        target: cycle
        function onOpenedChanged() {
            if (!cycle.playing) return;
            if (cycle.opened) { leave.stop(); enter.restart(); }
            else { enter.stop(); leave.restart(); }
        }
        function onPlayingChanged() {
            if (cycle.playing) return;
            enter.stop(); leave.stop();
            root.core = 1; root.details = 1; root.veil = 1;
        }
    }
    ParallelAnimation {
        id: enter
        NumberAnimation { target: root; property: "veil"; from: 0; to: 1; duration: Math.max(1, Math.max(root.openMs, Motion.lockOpen)); easing.type: Easing.OutCubic }
        SequentialAnimation {
            PropertyAction { target: root; property: "core"; value: 0 }
            PauseAnimation { duration: root.coreDelay }
            NumberAnimation { target: root; property: "core"; to: 1; duration: Math.max(1, root.sumi ? Math.round(root.openMs * 0.68) : Motion.lockContentMs); easing.type: Easing.OutCubic }
        }
        SequentialAnimation {
            PropertyAction { target: root; property: "details"; value: 0 }
            PauseAnimation { duration: root.sumi ? Math.round(root.openMs * 0.2) : root.coreDelay + Motion.lockStagger }
            NumberAnimation { target: root; property: "details"; to: 1; duration: Math.max(1, root.sumi ? Math.round(root.openMs * 0.8) : Motion.lockContentMs); easing.type: Easing.OutCubic }
        }
    }
    SequentialAnimation {
        id: leave
        PauseAnimation { duration: Motion.lockAccept }
        ParallelAnimation {
            NumberAnimation { target: root; property: "veil"; to: 0; duration: Math.max(1, root.closeMs); easing.type: Easing.InCubic }
            NumberAnimation { target: root; property: "core"; to: root.sumi ? 0 : 1; duration: Math.max(1, root.closeMs); easing.type: Easing.InCubic }
            NumberAnimation { target: root; property: "details"; to: root.sumi ? 0 : 1; duration: Math.max(1, root.closeMs); easing.type: Easing.InCubic }
        }
    }

    Rectangle {
        id: desk
        anchors.fill: parent
        radius: Metrics.r(9) * root.s
        color: Qt.alpha(Theme.fg, 0.045)
        border.width: Math.max(1, root.s)
        border.color: Theme.hair
        clip: true

        // el velo del bloqueo sobre el escritorio
        Rectangle {
            anchors.fill: parent
            radius: desk.radius
            color: Qt.alpha(Theme.surfaceContainerLowest, 0.62)
            opacity: root.veil
        }

        Rectangle {
            id: panel
            width: desk.width * 0.74
            height: desk.height * 0.64
            anchors.centerIn: parent
            radius: Metrics.r(6) * root.s
            color: Theme.raisedBg
            border.width: Math.max(1, root.s)
            border.color: Theme.cardBorder
            antialiasing: true
            opacity: root.sumi ? 1 : prv.opacity
            scale: root.sumi ? 1 : prv.scale
            transformOrigin: Item.Center
            transform: [Translate { y: root.sumi ? 0 : prv.dy },
                        Scale { origin.x: panel.width / 2; origin.y: panel.height / 2
                                xScale: root.sumi ? 1 : prv.sx; yScale: root.sumi ? 1 : prv.sy }]
            layer.enabled: !root.sumi && prv.effect && prv.progress > 0.001 && prv.progress < 0.999
            layer.effect: prv.effect ? panelFx : null
            Component { id: panelFx; RevealEffect { rv: prv; s: root.s * 0.5; radius: panel.radius } }

            readonly property real travel: Motion.still ? 0 : 4 * root.s * (1 - root.details)
            // columnas laterales
            Repeater {
                model: [-1, 1]
                Column {
                    required property var modelData
                    x: modelData < 0 ? 6 * root.s : panel.width - width - 6 * root.s
                    y: 8 * root.s
                    width: panel.width * 0.2
                    spacing: 4 * root.s
                    opacity: root.details
                    transform: Translate { x: modelData < 0 ? panel.travel : -panel.travel }
                    Repeater {
                        model: [1, 0.7, 0.85]
                        Rectangle {
                            required property var modelData
                            width: parent.width * modelData; height: 3 * root.s; radius: Metrics.pill(height)
                            color: Theme.fgVariant
                            opacity: 0.35
                        }
                    }
                }
            }
            // centro: reloj y campo
            Column {
                anchors.centerIn: parent
                spacing: 5 * root.s
                opacity: root.core
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: panel.width * 0.26; height: 7 * root.s; radius: Metrics.pill(height)
                    color: Theme.fg
                    opacity: 0.85
                }
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: panel.width * 0.36; height: 8 * root.s; radius: Metrics.pill(height)
                    color: "transparent"
                    border.width: Math.max(1, root.s)
                    border.color: Theme.primary
                }
            }
        }
    }
}
