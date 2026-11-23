pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../services"

/**
 * Vista previa de la pantalla de inicio de sesión (Settings → Login screen, 2026-11-22): la imagen que genera
 * `sumi-sddm preview` con la configuración guardada, el wallpaper preparado y usuarios de ejemplo (la previa no
 * puede leer los avatares reales: tampoco puede el greeter). La genera SddmTheme 600 ms después del último cambio.
 * Mientras se rehace, la anterior queda atenuada; si falla, se dice debajo (el texto lo da SddmTheme.error).
 */
Item {
    id: root

    property real s: 1
    property real availableWidth: 0

    /** Como mucho 600 px a escala 1: una imagen a todo el ancho se comía la pestaña. */
    readonly property real cap: 600 * root.s
    // la fila entera (la fila alinea su control a la derecha); la imagen, a la izquierda y acotada
    implicitWidth: Math.max(240 * root.s, root.availableWidth)
    implicitHeight: col.implicitHeight

    Column {
        id: col
        width: Math.min(parent.width, root.cap)
        spacing: 8 * root.s

        Rectangle {
            id: frame
            width: parent.width
            height: Math.round(width * 9 / 16)
            radius: Metrics.r(10) * root.s
            color: Theme.tileBg
            border.width: 1
            border.color: Theme.hair
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
                Accessible.name: "Login screen preview"
            }
            Text {
                anchors.centerIn: parent
                visible: shot.status !== Image.Ready
                text: SddmTheme.previewFailed ? "No preview" : "Making a preview…"
                color: Theme.fgVariant
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
            }
        }

        Row {
            spacing: 10 * root.s
            Choice {
                anchors.verticalCenter: parent.verticalCenter
                s: root.s
                name: "Preview"
                forcePills: true
                availableWidth: Math.max(0, col.width - stateText.implicitWidth - 10 * root.s)
                options: SddmTheme.scenarios
                value: SddmTheme.scenario
                onPicked: (v) => SddmTheme.scenario = v
            }
            Text {
                id: stateText
                anchors.verticalCenter: parent.verticalCenter
                text: SddmTheme.previewStale && !SddmTheme.previewFailed ? "Updating…" : "Sample users"
                color: Theme.fgVariant
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
            }
        }
    }
}
