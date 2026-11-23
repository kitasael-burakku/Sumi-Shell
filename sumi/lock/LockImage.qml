import QtQuick
import QtQuick.Effects
import "../components"
import "../theme"

/**
 * Una imagen recortada con esquinas redondeadas y su hueco reservado (fase 15, §9 «Avatar / fetch»):
 * mientras carga, si falta o si está rota, el mismo tamaño con un glifo de respaldo. El resultado de
 * la carga nunca mueve nada de alrededor.
 *
 * `source` llega ya resuelto por el contexto (una URL `file://` o, sólo para la portada de la música,
 * remota: I-14). Se decodifica al doble del tamaño mostrado, nunca a la resolución del archivo
 * (decisión 3 de la fase 15).
 */
Item {
    id: root

    property real s: 1
    property string source: ""
    property real radius: Metrics.rMd * root.s
    property string fallbackIcon: "image"
    /** Recorte o encaje: el fetch encaja (figuras con transparencia), la portada recorta. */
    property int fillMode: Image.PreserveAspectCrop

    readonly property bool ready: img.status === Image.Ready
    readonly property bool broken: root.source.length > 0 && img.status === Image.Error

    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: Theme.tileBg
        visible: !root.ready || root.fillMode !== Image.PreserveAspectCrop
    }

    Image {
        id: img
        anchors.fill: parent
        source: root.source
        sourceSize.width: Math.ceil(root.width * 2)
        sourceSize.height: Math.ceil(root.height * 2)
        fillMode: root.fillMode
        asynchronous: true
        retainWhileLoading: true
        cache: false
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
            radius: root.radius
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

    Icon {
        anchors.centerIn: parent
        visible: !root.ready
        name: root.fallbackIcon
        size: Math.min(root.width, root.height) * 0.36
        color: Theme.outline
    }
}
