pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import "../theme"

/**
 * El fondo musical de la zona de reproducción (rediseño, 9E-2; futureAudio-Mixersurface.md
 * «Reproducción integrada», referencia future-use/dynamic-island2.0.png).
 *
 * La carátula ampliada, muy desenfocada y un poco apagada llena la zona; encima, un VELO
 * oscuro cuya fuerza depende de lo clara que sea la carátula (el texto del tema es claro: una
 * carátula blanca necesita más velo que una oscura para que título, tiempos y botones se
 * lean). La luminancia sale de la media de la carátula reducida a 8×8 en un Canvas.
 *
 * Al cambiar de pista las dos capas se FUNDEN (la nueva entra cuando ya cargó; nunca un
 * hueco negro); sin carátula, se funde al fondo del tema. Todo con `Motion` (Off = directo).
 * Sólo pinta cuando cambia: el desenfoque de una imagen quieta no cuesta nada en reposo.
 *
 *   CoverBackdrop { anchors.fill: parent; s: root.s; source: Media.artUrl }
 */
Item {
    id: root

    property real s: 1
    property string source: ""

    /** Luminancia media (0–1) de la carátula que se ve; −1 si no hay. Para el IPC y el velo. */
    property real luminance: -1
    /**
     * 2026-10-01: más velo en las claras y un suelo más alto (0,38 → 0,46): el texto encima es blanco
     * fijo (Mixer `ink1…3`) y una carátula media dejaba los tiempos y el artista por debajo de 4,5:1.
     */
    readonly property real scrimAlpha: root.luminance < 0 ? 0 : 0.46 + 0.40 * root.luminance
    readonly property bool showing: layerA.shown || layerB.shown

    readonly property int fadeMs: Motion.off ? 0 : Motion.morph

    /** 0 = A delante, 1 = B delante. */
    property int front: 0

    onSourceChanged: root.swap()
    Component.onCompleted: root.swap()

    function swap() {
        const back = root.front === 0 ? layerB : layerA;
        const fr = root.front === 0 ? layerA : layerB;
        if (root.source.length === 0) {
            fr.shown = false;
            back.shown = false;
            root.luminance = -1;
            return;
        }
        if (fr.url === root.source && fr.shown) return;
        back.url = root.source;           // entra cuando cargue (`onReady`)
        if (back.ready) back.reveal();
    }

    component Layer: Item {
        id: layer
        property string url: ""
        property bool shown: false
        // Sin comparar `img.source` con `url`: QUrl codifica el fragmento (el «|» del artUrl de
        // Malody sale «%7C») y la comparación no casaba nunca. `url` sólo cambia aquí, y al
        // cambiar el estado pasa por Loading, así que Ready es el de la carátula pedida.
        readonly property bool ready: img.status === Image.Ready
        onReadyChanged: if (layer.ready && layer.url === root.source) layer.reveal()

        function reveal() {
            const other = layer === layerA ? layerB : layerA;
            layer.shown = true;
            other.shown = false;
            root.front = layer === layerA ? 0 : 1;
            lum.measure(layer.url);
        }

        anchors.fill: parent
        opacity: layer.shown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: root.fadeMs; easing.type: Easing.InOutQuad } }
        visible: opacity > 0.01

        Image {
            id: img
            anchors.centerIn: parent
            // ampliada: los bordes del desenfoque no se ven dentro de la zona
            width: parent.width * 1.3
            height: parent.height * 1.3
            source: layer.url
            // pequeña a propósito (el detalle se va con el desenfoque), pero no tanto: con 160 px el
            // blur ampliaba bloques y se veía turbio, de baja calidad (2026-10-01, el usuario)
            sourceSize.width: 320
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: false
            visible: false
        }
        MultiEffect {
            anchors.fill: img
            source: img
            visible: img.status === Image.Ready
            blurEnabled: true
            blur: 1.0
            // 64 → 44: sigue siendo un fondo (no se lee la imagen) pero conserva forma y color, y no
            // queda la mancha lechosa que se comía el contraste
            blurMax: 44
            saturation: 0.05
            brightness: -0.08
        }
    }

    Layer { id: layerA }
    Layer { id: layerB }

    /**
     * El velo: oscuro, más fuerte cuanto más clara es la carátula. Se funde con ella. Además un
     * degradado horizontal (2026-10-01): más denso a la derecha, donde va el texto, y más ligero
     * a la izquierda, donde va la carátula nítida; así el fondo conserva color sin perder lectura.
     */
    Rectangle {
        anchors.fill: parent
        opacity: root.showing ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: root.fadeMs; easing.type: Easing.InOutQuad } }
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0) }
            GradientStop { position: 0.35; color: Qt.rgba(0, 0, 0, 0.10) }
            GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.22) }
        }
    }
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, root.scrimAlpha)
        opacity: root.showing ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: root.fadeMs; easing.type: Easing.InOutQuad } }
        Behavior on color { ColorAnimation { duration: root.fadeMs } }
    }

    /**
     * La luminancia de la carátula: se dibuja reducida a 8×8 y se promedia. Tiene que estar
     * «visible» para que el Canvas pinte, así que va con opacidad mínima y 8 px en una esquina.
     */
    Canvas {
        id: lum
        width: 8
        height: 8
        opacity: 0.01
        property string pending: ""
        function measure(url) {
            lum.pending = url;
            if (lum.isImageLoaded(url)) lum.requestPaint();
            else lum.loadImage(url);
        }
        onImageLoaded: lum.requestPaint()
        onPaint: {
            if (lum.pending.length === 0 || !lum.isImageLoaded(lum.pending)) return;
            const ctx = lum.getContext("2d");
            ctx.clearRect(0, 0, 8, 8);
            ctx.drawImage(lum.pending, 0, 0, 8, 8);
            const d = ctx.getImageData(0, 0, 8, 8).data;
            let sum = 0, n = 0;
            const lin = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
            for (let i = 0; i < d.length; i += 4) {
                if (d[i + 3] === 0) continue;
                sum += 0.2126 * lin(d[i]) + 0.7152 * lin(d[i + 1]) + 0.0722 * lin(d[i + 2]);
                n++;
            }
            // luminancia relativa lineal → perceptual (raíz), para que el velo crezca parejo
            if (n > 0 && lum.pending === root.source) root.luminance = Math.sqrt(sum / n);
        }
    }
}
