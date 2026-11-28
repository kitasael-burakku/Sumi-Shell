import QtQuick
import QtQuick.Effects
import "../theme"

/**
 * Fondo del bloqueo: lo que había detrás, desenfocado y SIN color propio (2026-11-28, pedido del autor: «un blur
 * natural de lo que hay atrás, sin color»). La captura conserva su saturación y su brillo; encima sólo va un velo
 * neutro (negro con poco alfa: 0,20 en oscuro y 0,08 en claro), nunca un tono de la paleta ni el acento. Antes, un velo
 * `surfaceContainerLowest` al 62 % y brillo −0,25 lo dejaban casi negro en oscuro y blanco en claro.
 * Lo que se lee directamente sobre el fondo (la hora en calma y en las pantallas sin foco) lleva su propio halo
 * neutro (LockAuthColumn, LockBoardSurface), así que el velo ya no tiene que oscurecer toda la pantalla.
 * En sesión la imagen ya llega reducida desde LockSession; la vista previa admite también un fondo completo.
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
    property real dim: -1
    /** El velo neutro efectivo: `dim` si se fija (vista previa), si no según el tema. */
    readonly property real scrim: root.dim >= 0 ? root.dim : (Theme.light ? 0.08 : 0.20)
    /** Escala de la imagen: 1,03 → 1 al entrar (decorativa; con reduce motion, 1). */
    property real imageScale: 1
    property real brightness: 0
    /**
     * 0 = la captura casi nítida y sin velo, 1 = el tratamiento completo (2026-11-28): al entrar, el escritorio se
     * desenfoca y oscurece en vez de fundirse con el velo. Mientras va de 0 a 1 la capa se recalcula en cada fotograma;
     * quieto en 1, vuelve a ser una textura cacheada.
     */
    property real blurIn: 1

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
            // La captura ya llega al 8 %; este tope sólo frena un fondo grande (el wallpaper de reserva).
            sourceSize.width: 256
            sourceSize.height: 160
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
            blur: 0.15 + 0.85 * root.blurIn
            brightness: root.brightness * root.blurIn
        }
    }

    /** Velo neutro: sin tono de la paleta, sólo un poco de negro para asentar el panel. */
    Rectangle {
        anchors.fill: parent
        visible: root.ready
        color: Qt.rgba(0, 0, 0, root.scrim * root.blurIn)
    }
}
