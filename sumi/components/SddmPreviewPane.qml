pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../services"

/**
 * La vista previa grande de la ventana Login screen (2026-11-23): el PNG que genera `sumi-sddm preview` con lo
 * GUARDADO (lo que verá el greeter), al tamaño elegido (de serie, el de este monitor en píxeles físicos).
 *
 *   escena   cuatro pastillas (Compact · Password · Sessions · Error) y «More» con las 16 de la CLI. Mientras no se
 *            elija una a mano, la escena sigue al grupo a la vista (SddmTheme.sceneFor; la pone LoginScreen)
 *   tamaño   «This screen» o una de las medidas habituales
 *   ampliar  clic en la imagen: la ventana oculta los ajustes (lo decide LoginScreen con `zoomToggled`)
 *
 * `side`: los controles a la derecha de la imagen (ventana estrecha, la vista previa arriba); si no, debajo.
 */
Item {
    id: root

    property real s: 1
    property real availableWidth: 0
    /** Lo más que puede medir la imagen de alto (la columna o la franja). */
    property real imageMaxHeight: 0
    property bool side: false
    property bool zoomed: false
    /** «AnchoxAlto» de este monitor, en píxeles físicos. */
    property string screenSize: "1920x1080"
    signal zoomToggled()

    readonly property var sizes: {
        const out = [{ label: "This screen · " + root.screenSize.replace("x", "×"), value: "screen" }];
        for (const v of ["1920x1080", "2560x1440", "3840x2160", "1366x768"])
            if (v !== root.screenSize) out.push({ label: v.replace("x", "×"), value: v });
        return out;
    }
    readonly property real aspect: {
        const m = /^(\d+)x(\d+)$/.exec(SddmTheme.previewSize);
        return m ? Number(m[1]) / Math.max(1, Number(m[2])) : 16 / 9;
    }
    readonly property bool pinnedHere: LoginUi.scenePinned
    readonly property bool mainScene: SddmTheme.scenarios.some(x => x.value === SddmTheme.scenario)

    function pick(v) {
        LoginUi.scenePinned = true;
        SddmTheme.scenario = v;
        more.open = false;
    }

    /** Al lado (ventana estrecha) la imagen se queda con ~60 % y los controles con lo demás. */
    readonly property real frameW: {
        const w = root.side ? root.availableWidth * 0.6 : root.availableWidth;
        return Math.max(120 * root.s, Math.min(w, root.imageMaxHeight > 0 ? root.imageMaxHeight * root.aspect : w));
    }
    readonly property real controlsW: root.side ? Math.max(0, root.availableWidth - root.frameW - 14 * root.s) : root.availableWidth
    /** La imagen pedida ya está pintada (los bancos esperan a esto antes de capturar). */
    readonly property bool imageReady: shot.status === Image.Ready && !SddmTheme.previewStale
    implicitWidth: root.availableWidth
    implicitHeight: root.side ? Math.max(frame.height, controls.implicitHeight)
                              : frame.height + 10 * root.s + controls.implicitHeight

    Rectangle {
        id: frame
        width: Math.round(root.frameW)
        height: Math.round(root.frameW / root.aspect)
        radius: Metrics.r(10) * root.s
        color: Theme.tileBg
        border.width: 1
        border.color: frameArea.containsMouse ? Qt.alpha(Theme.fg, 0.35) : Theme.hair
        clip: true

        Image {
            id: shot
            anchors.fill: parent
            anchors.margins: 1
            source: SddmTheme.previewUrl
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            cache: false
            smooth: true
            mipmap: true
            // la de antes se queda a la vista hasta que llega la nueva, atenuada si ya no corresponde
            opacity: SddmTheme.previewStale ? 0.55 : 1
            Behavior on opacity { NumberAnimation { duration: Motion.fast } }
            Accessible.role: Accessible.Graphic
            Accessible.name: "Login screen preview · " + SddmTheme.scenarioLabel(SddmTheme.scenario)
        }
        Text {
            anchors.centerIn: parent
            visible: shot.status !== Image.Ready
            text: SddmTheme.previewFailed ? "No preview" : "Making a preview…"
            color: Theme.fgVariant
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }
        // la escena, arriba a la izquierda («auto» si sigue al grupo)
        Rectangle {
            x: 8 * root.s; y: 8 * root.s
            visible: shot.status === Image.Ready
            width: tag.implicitWidth + 12 * root.s; height: tag.implicitHeight + 4 * root.s
            radius: Metrics.r(6) * root.s
            color: Qt.alpha(Theme.surface, 0.78)
            Text {
                id: tag
                anchors.centerIn: parent
                text: SddmTheme.scenarioLabel(SddmTheme.scenario) + (root.pinnedHere ? "" : " · auto")
                color: Theme.fgVariant
                font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
            }
        }
        Rectangle {
            anchors.right: parent.right; anchors.bottom: parent.bottom
            anchors.margins: 8 * root.s
            visible: shot.status === Image.Ready && (frameArea.containsMouse || root.zoomed)
            width: zoomText.implicitWidth + 12 * root.s; height: zoomText.implicitHeight + 4 * root.s
            radius: Metrics.r(6) * root.s
            color: Qt.alpha(Theme.surface, 0.78)
            Text {
                id: zoomText
                anchors.centerIn: parent
                text: root.zoomed ? "Click to go back" : "Click to enlarge"
                color: Theme.fgVariant
                font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
            }
        }
        MouseArea {
            id: frameArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.zoomToggled()
        }
    }

    Column {
        id: controls
        x: root.side ? frame.width + 14 * root.s : 0
        y: root.side ? 0 : frame.height + 10 * root.s
        width: root.controlsW
        spacing: 8 * root.s

        Text {
            width: parent.width
            visible: SddmTheme.previewStale && !SddmTheme.previewFailed && shot.status === Image.Ready
            text: "Making a preview…"
            color: Theme.fgVariant
            font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
        }
        Flow {
            id: sceneFlow
            width: parent.width
            spacing: 8 * root.s
            Choice {
                s: root.s
                name: "Scene"
                forcePills: true
                availableWidth: root.side ? controls.width : Math.max(0, controls.width - moreBtn.width - 8 * root.s)
                options: SddmTheme.scenarios
                value: root.mainScene ? SddmTheme.scenario : ""
                onPicked: (v) => root.pick(v)
            }
            ActionButton {
                id: moreBtn
                s: root.s
                label: root.mainScene ? "More" : SddmTheme.scenarioLabel(SddmTheme.scenario)
                glyph: "chevron-down"
                accent: !root.mainScene
                onTriggered: more.open = !more.open
            }
        }
        Row {
            spacing: 8 * root.s
            Text {
                id: sizeLabel
                anchors.verticalCenter: parent.verticalCenter
                text: "Size"
                color: Theme.fgVariant
                font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
            }
            Choice {
                anchors.verticalCenter: parent.verticalCenter
                s: root.s
                name: "Preview size"
                availableWidth: Math.max(0, controls.width - sizeLabel.implicitWidth - 8 * root.s)
                options: root.sizes
                value: LoginUi.previewPick
                onPicked: (v) => LoginUi.previewPick = String(v)
            }
        }
        Item {
            width: parent.width
            height: tryBtn.height
            Text {
                anchors.left: parent.left; anchors.right: tryBtn.left; anchors.rightMargin: 10 * root.s
                anchors.verticalCenter: parent.verticalCenter
                // al lado de la imagen no cabe la explicación: sólo el aviso de la segunda pulsación
                visible: !root.side || SddmTheme.tryArmed
                wrapMode: Text.Wrap
                text: SddmTheme.tryArmed ? SddmTheme.captionText("sddmTry") : "Shows what is saved, as the login screen will"
                color: SddmTheme.tryArmed ? Theme.warn : Theme.fgVariant
                font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
            }
            ActionButton {
                id: tryBtn
                anchors.right: parent.right
                s: root.s
                label: "Test window"
                danger: SddmTheme.tryArmed
                enabled: SddmTheme.ready
                onTriggered: SddmTheme.openTestWindow()
            }
        }
    }

    // «More»: las 16 escenas de la CLI, agrupadas; se abre hacia arriba desde su botón
    Rectangle {
        id: more
        property bool open: false
        z: 20
        visible: more.open
        width: 220 * root.s
        height: moreCol.implicitHeight + 10 * root.s
        x: Math.max(0, Math.min(root.width - width, controls.x + sceneFlow.x + moreBtn.x))
        y: Math.max(-frame.height, controls.y + sceneFlow.y + moreBtn.y - height - 6 * root.s)
        radius: Metrics.rMd * root.s
        color: Theme.cardBg
        border.width: 1
        border.color: Theme.hair
        Column {
            id: moreCol
            x: 0; y: 5 * root.s
            width: parent.width
            Repeater {
                model: SddmTheme.allScenarios
                Column {
                    id: entry
                    required property var modelData
                    required property int index
                    readonly property bool head: entry.index === 0
                        || SddmTheme.allScenarios[entry.index - 1].section !== entry.modelData.section
                    width: moreCol.width
                    Text {
                        visible: entry.head
                        x: 12 * root.s
                        topPadding: entry.index === 0 ? 2 * root.s : 6 * root.s
                        text: entry.modelData.section
                        color: Theme.fgVariant; opacity: 0.8
                        font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                    }
                    Rectangle {
                        width: moreCol.width
                        height: 24 * root.s
                        color: SddmTheme.scenario === entry.modelData.value ? Qt.alpha(Theme.primary, 0.16)
                             : itemArea.containsMouse ? Theme.hoverBg : "transparent"
                        Text {
                            x: 12 * root.s; anchors.verticalCenter: parent.verticalCenter
                            text: entry.modelData.label
                            color: Theme.fg
                            font.family: Typography.ui; font.pixelSize: Typography.label * root.s
                        }
                        MouseArea {
                            id: itemArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.pick(entry.modelData.value)
                        }
                        Accessible.role: Accessible.MenuItem
                        Accessible.name: entry.modelData.label
                    }
                }
            }
        }
    }
}
