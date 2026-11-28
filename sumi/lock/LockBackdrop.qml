import QtQuick
import QtQuick.Effects
import "../theme"

/**
 * Fondo del bloqueo. Sobre un respaldo opaco se muestra una imagen reducida, con
 * desenfoque moderado y un velo neutro de la paleta. En sesión la imagen ya llega
 * reducida desde LockSession; la vista previa admite también un fondo completo.
 *
 * La capa cachea el efecto. El color opaco de la ventana, fuera de esta pieza,
 * protege el escritorio en reposo incluso cuando no se puede cargar la imagen.
 */
Item {
    id: root

    property real s: 1
    /** Ruta local de la imagen; vacía = sólo el respaldo. */
    property string source: ""
    /** Se incrementa para volver a leer el archivo sin caché. */
    property int generation: 0
    /**
     * El tratamiento (FONDO §4). `dim` 0,62 decidido por el usuario en L2 con el
     * contraste medido: es el mínimo que deja la fecha y el estado a ≥ 4,5:1 sobre el
     * wallpaper más claro (0,45 daba 3,0:1). Se ajusta el velo, no el texto (INTERFAZ §9).
     */
    property real dim: 0.62
    /** Escala de la imagen: 1,03 → 1 al entrar (decorativa; con reduce motion, 1). */
    property real imageScale: 1
    property real brightness: -0.25

    readonly property bool ready: img.status === Image.Ready
    readonly property bool failed: root.source.length > 0 && img.status === Image.Error

    property bool warned: false
    onFailedChanged: if (root.failed && !root.warned) {
        root.warned = true;
        console.warn("lock: the lock-screen background could not be loaded:", root.source);
    }
    onSourceChanged: root.warned = false

    /** Respaldo: degradado opaco con los tokens del tema (FONDO §7). */
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: Theme.surfaceContainerLowest }
            GradientStop { position: 1.0; color: Theme.surface }
        }
    }

    Item {
        id: still
        anchors.fill: parent
        visible: root.ready
        layer.enabled: root.ready
        scale: root.imageScale

        Image {
            id: img
            anchors.fill: parent
            source: root.source.length > 0 ? ("file://" + root.source + "?n=" + root.generation) : ""
            // Limita el detalle también en salidas de alta resolución.
            sourceSize.width: 128
            sourceSize.height: 80
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: false
            smooth: true
            visible: false
        }

        MultiEffect {
            anchors.fill: parent
            source: img
            autoPaddingEnabled: false
            blurEnabled: true
            blurMax: 40
            blur: 1.0
            saturation: -0.35
            brightness: root.brightness
        }
    }

    /** Oscurecido: lo justo para que `fg` se lea sobre un wallpaper claro (INTERFAZ §9). */
    Rectangle {
        anchors.fill: parent
        color: Qt.alpha(Theme.surfaceContainerLowest, root.dim)
    }

    /** Velo de acento desde arriba: «el acento es luz, no contorno» (DESIGN.md §1). */
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0;  color: Qt.alpha(Theme.primary, 0.02) }
            GradientStop { position: 0.45; color: "transparent" }
            GradientStop { position: 1.0;  color: "transparent" }
        }
    }
}
