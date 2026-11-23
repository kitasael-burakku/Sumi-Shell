import QtQuick
import QtQuick.Effects
import Quickshell
import "../theme"

/**
 * La cara del usuario, en círculo (docs/lock/COMPONENTES.md §4).
 *
 * `source` es una RUTA LOCAL (absoluta, o con `~`): nada de `http:` ni `data:`
 * (I-14). Si la imagen no está `Ready` —no basta con que la ruta exista: un archivo
 * que no es imagen también existe— se dibuja la inicial del nombre sobre el acento.
 *
 * La imagen se decodifica a 2× del tamaño y sólo si hay `source`: una `Image` con
 * `source` decodifica aunque esté invisible (README, notas de implementación).
 */
Item {
    id: root

    property real s: 1
    /** Ruta local. Vacía = la inicial. */
    property string source: ""
    /** Para la inicial: el primer carácter (キ para キタサンブラック). */
    property string name: ""
    property real size: 28

    readonly property real px: root.size * root.s
    /** La ruta ya expandida, o vacía si no es local (I-14). */
    readonly property string path: {
        const p = root.source.trim();
        if (p.length === 0 || p.indexOf("://") >= 0 || p.indexOf("data:") === 0)
            return "";
        if (p.indexOf("~/") === 0)
            return Quickshell.env("HOME") + p.slice(1);
        return p.indexOf("/") === 0 ? p : "";
    }
    readonly property bool ready: img.status === Image.Ready
    /** El primer carácter visible, sin partir un par sustituto. */
    readonly property string initial: {
        const chars = Array.from(root.name.trim());
        return chars.length > 0 ? chars[0].toLocaleUpperCase() : "?";
    }

    implicitWidth: root.px
    implicitHeight: root.px

    Image {
        id: img
        anchors.fill: parent
        source: root.path.length > 0 ? ("file://" + root.path) : ""
        sourceSize.width: root.px * 2
        sourceSize.height: root.px * 2
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        smooth: true
        visible: false
    }

    Item {
        id: mask
        anchors.fill: parent
        layer.enabled: true
        visible: false
        Rectangle {
            anchors.fill: parent
            radius: Metrics.pill(width)
            color: "black"
        }
    }

    MultiEffect {
        anchors.fill: parent
        source: img
        visible: root.ready
        maskEnabled: true
        maskSource: mask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
    }

    /** Respaldo: la inicial sobre el acento. */
    Rectangle {
        anchors.fill: parent
        radius: Metrics.pill(width)
        visible: !root.ready
        color: Qt.alpha(Theme.primary, 0.2)

        Text {
            anchors.centerIn: parent
            text: root.initial
            color: Theme.primary
            font.family: Typography.ui
            font.weight: Typography.wStrong
            font.pixelSize: root.px * 0.5
        }
    }
}
