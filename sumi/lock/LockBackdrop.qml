import QtQuick
import QtQuick.Effects
import "../theme"

/**
 * Lo que hay detrás del vidrio de la pantalla de bloqueo (docs/lock/FONDO.md).
 *
 * De abajo arriba: el RESPALDO (degradado opaco, siempre debajo), la imagen
 * reducida y desenfocada, el oscurecido y el velo de acento. Todo sale de `Theme`:
 * cambia con el wallpaper y con matugen como el resto del shell (ADR-1, ADR-12).
 *
 * La imagen es `current.png`, el mismo fondo que hyprlock, a un cuarto de la
 * pantalla: un fondo desenfocado no necesita resolución (FONDO §3). Se decodifica
 * sólo con `source` puesto, y con un contador en la URL para no servir un
 * `current.png` viejo desde la caché de imágenes. Medido en S7: 23–41 ms, sin
 * precarga.
 *
 * El desenfoque se cachea (`layer.enabled`): sólo se recalcula cuando cambia la
 * imagen, no al repintar el minuto o el cursor.
 *
 * Opacidad: este componente es el VELO. La garantía de que en reposo no se ve el
 * escritorio es el color opaco de la ventana (FONDO §5, I-7), que pone quien la
 * tiene; aquí el respaldo también es opaco.
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
            sourceSize.width: 480
            sourceSize.height: 270
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
            blurMax: 64
            blur: 1.0
            saturation: -0.1
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
            GradientStop { position: 0.0;  color: Qt.alpha(Theme.primary, 0.06) }
            GradientStop { position: 0.45; color: "transparent" }
            GradientStop { position: 1.0;  color: "transparent" }
        }
    }
}
