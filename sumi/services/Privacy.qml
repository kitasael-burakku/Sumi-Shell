pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Services.Pipewire
import Quickshell.Hyprland

/**
 * Quien esta escuchando o mirando: el equivalente del modulo `privacy` de
 * Waybar, que tambien lee Pipewire.
 *
 * Regla de deteccion, comprobada ejecutando (2026-09-08): un nodo de captura
 * aparece con `properties["media.class"]`
 *
 *     Stream/Input/Audio   microfono   (verificado lanzando `pw-record`)
 *     Stream/Input/Video   pantalla o camara
 *
 * y desaparece al cerrarse. Los nodos de reproduccion son Stream/Output/Audio
 * y el dispositivo es Audio/Sink, asi que no hay falsos positivos por tener
 * musica sonando.
 *
 * Lo que no pasa por Pipewire (wlr-screencopy: `wf-recorder`, `grim`) no crea
 * nodo; desde la fase 8A lo cuenta el evento `screencast` de Hyprland (abajo).
 * El portal (`xdg-desktop-portal-hyprland`), por donde comparten pantalla el
 * navegador y OBS, se ve en los dos.
 */
Singleton {
    id: root

    readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []

    /**
     * Hay que rastrear los nodos para que sus `properties` esten pobladas, y no
     * hay puerta posible: sin tracker `properties["media.class"]` no se lee, y es
     * el unico campo que distingue `Stream/Input/Audio` de `Stream/Output/Audio`.
     * `type`, `isStream` e `isSink` SI se leen sin rastrear, pero el enum de
     * Quickshell no es alcanzable desde QML y reescribir la deteccion sobre bits
     * deducidos (17 y 21 fueron los dos unicos valores observables) arriesga que
     * el aviso de microfono deje de avisar. No se hace.
     *
     * **Consecuencia, y conviene tenerla presente:** esto deja los nodos
     * vinculados las 24 horas, asi que la puerta de muestreo de `services/Mixer`
     * no ahorra nada. Alli tambien esta dicho.
     *
     * Coste medido con las dos corridas de ADR-23 (2026-09-08, arranque limpio,
     * lecturas a 40 y 60 s sin tocar nada): **con tracker 355,9 MB y 1 tick por
     * 20 s; sin tracker 365,3 MB y 1 tick**. La version SIN tracker salio mas
     * alta que la que lo lleva, es decir, el coste queda por debajo del ruido
     * entre corridas (~10 MB sobre 360). Con 6 nodos no hay nada que ahorrar.
     */
    PwObjectTracker { objects: root.nodes }

    /**
     * El visualizador del propio shell (`services/Cava`, retirado en la fase 15H) no avisaba: su nodo lleva
     * `sumi.visualizer = true` (PIPEWIRE_PROPS). Sin esto encendía el aviso rojo
     * cada vez que sonaba música.
     *
     * Corrección del mismo 2026-09-15: el primer filtro descartaba toda captura con
     * `stream.capture.sink` (el monitor de una salida). Era demasiado ancho: OBS
     * grabando el audio del escritorio y el visualizador de maly (`pw-record` sobre
     * `@DEFAULT_MONITOR@`) dejaron de avisar, y el usuario quiere verlos. Ahora sólo
     * se excluye lo marcado por el shell; un cava lanzado a mano sigue avisando.
     */
    function isOwnVisualizer(nd) {
        const v = nd.properties["sumi.visualizer"];
        return v === true || v === "true" || v === "1";
    }

    function countOf(cls) {
        const list = root.nodes;
        let n = 0;
        for (let i = 0; i < list.length; i++) {
            const nd = list[i];
            if (!nd || !nd.properties)
                continue;
            if (nd.properties["media.class"] === cls && !root.isOwnVisualizer(nd))
                n++;
        }
        return n;
    }

    /**
     * CÁMARA FRENTE A PANTALLA (fase 8A, 2026-09-25). `Stream/Input/Video` no dice
     * qué se mira: lo dice el ORIGEN al que está enlazado el flujo. Medido con una
     * cámara simulada (gst `pipewiresink mode=provide`, `Video/Source`,
     * `device.api=v4l2`) y un consumidor enlazado con `pw-link`: el enlace aparece en
     * `linkGroups` con el `Video/Source` de `source` y el flujo de `target`. El
     * consumidor puede no decir `Video` (el de gst sin `media.type` salía
     * `Stream/Input/Unknown`), así que se clasifica por el enlace y no por la clase del
     * flujo.
     *
     *   cámara    el origen es un dispositivo v4l2/libcamera o `media.role` Camera
     *   pantalla  cualquier otro origen de vídeo (el portal, xdph)
     *
     * Un `Stream/Input/Video` sin enlace todavía (arrancando, en pausa) cuenta como
     * pantalla, que es lo que avisaba antes: mejor un aviso de más que uno de menos.
     * Esta máquina no tiene cámara; el verde sólo se ha probado con la simulada.
     */
    readonly property var linkGroups: Pipewire.linkGroups ? Pipewire.linkGroups.values : []

    function isCamera(nd) {
        const p = nd.properties;
        const api = p["device.api"];
        return api === "v4l2" || api === "libcamera" || p["media.role"] === "Camera";
    }

    function isVideo(nd) {
        const c = nd && nd.properties ? (nd.properties["media.class"] || "") : "";
        return c.indexOf("Video") >= 0;
    }

    function isCaptureStream(nd) {
        const c = nd && nd.properties ? (nd.properties["media.class"] || "") : "";
        return c.indexOf("Stream/Input/") === 0 && !root.isOwnVisualizer(nd);
    }

    /** { camera: [nodos], screen: [nodos] }: cada flujo cuenta una vez. */
    readonly property var video: {
        const cam = [], scr = [];
        const gs = root.linkGroups;
        for (let i = 0; i < gs.length; i++) {
            const g = gs[i];
            if (!g || !g.source || !g.target || !g.source.properties)
                continue;
            if (!root.isVideo(g.source) || !root.isCaptureStream(g.target))
                continue;
            const bucket = root.isCamera(g.source) ? cam : scr;
            if (bucket.indexOf(g.target) < 0) bucket.push(g.target);
        }
        // un flujo de vídeo sin enlace (aún) → pantalla, como antes
        const list = root.nodes;
        for (let i = 0; i < list.length; i++) {
            const nd = list[i];
            if (!nd || !nd.properties || nd.properties["media.class"] !== "Stream/Input/Video" || root.isOwnVisualizer(nd))
                continue;
            if (cam.indexOf(nd) < 0 && scr.indexOf(nd) < 0) scr.push(nd);
        }
        return { camera: cam, screen: scr };
    }

    /**
     * CAPTURA SIN PORTAL. `wf-recorder`, `grim` o OBS con wlrobs usan
     * wlr-screencopy y no crean nodo de Pipewire; Hyprland sí lo cuenta:
     * `screencast>>1,monitor|region|window` al empezar y `>>0,…` al acabar, uno por
     * cliente (sin decir cuál, de ahí el contador). Medido el 2026-09-25: `grim` dura
     * 8 ms y las miniaturas del minimizador —el propio shell, tipo `window`— 500 ms;
     * `wf-recorder`, lo que dure la grabación. Por eso sólo avisa lo que siga activo
     * pasado `screencopyHoldMs`.
     *
     * LÍMITE: el estado no se puede preguntar a Hyprland. Si el shell se recarga en
     * mitad de una grabación, ésta no avisa hasta la siguiente (el portal sí, por
     * Pipewire). El contador no baja de 0 por si el shell vio el final y no el inicio.
     */
    readonly property int screencopyHoldMs: 1000
    property int screencopyClients: 0
    property bool screencopyActive: false

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name !== "screencast")
                return;
            const on = event.data.charAt(0) === "1";
            root.screencopyClients = Math.max(0, root.screencopyClients + (on ? 1 : -1));
            if (root.screencopyClients > 0) {
                if (!root.screencopyActive && !screencopyHold.running) screencopyHold.restart();
            } else {
                screencopyHold.stop();
                root.screencopyActive = false;
            }
        }
    }

    Timer {
        id: screencopyHold
        interval: root.screencopyHoldMs
        onTriggered: root.screencopyActive = root.screencopyClients > 0
    }

    readonly property int micStreams: root.countOf("Stream/Input/Audio")
    readonly property int cameraStreams: root.video.camera.length
    readonly property int screenStreams: root.video.screen.length

    readonly property bool micActive: root.micStreams > 0
    readonly property bool cameraActive: root.cameraStreams > 0
    /**
     * Pantalla compartida por el portal O grabada por screencopy, o por el grabador de la propia shell
     * (2026-10-29). Ése se sabe sin adivinar, y hacía falta: medido en el banco, con la pantalla quieta
     * Hyprland emite `screencast>>0` a los ~2 s aunque wf-recorder siga grabando (espera daño), y el
     * aviso se apagaba en mitad de la grabación.
     */
    readonly property bool screenActive: root.screenStreams > 0 || root.screencopyActive || ScreenRecorder.capturing
    readonly property bool any: root.micActive || root.cameraActive || root.screenActive

    /** Nombres de lo que esta capturando, para el tooltip. */
    function capturing() {
        const out = [];
        const add = function(nd) {
            const n = (nd.description && nd.description.length > 0) ? nd.description : nd.name;
            if (out.indexOf(n) < 0) out.push(n);
        };
        const list = root.nodes;
        for (let i = 0; i < list.length; i++) {
            const nd = list[i];
            if (nd && nd.properties && nd.properties["media.class"] === "Stream/Input/Audio" && !root.isOwnVisualizer(nd))
                add(nd);
        }
        root.video.camera.forEach(add);
        root.video.screen.forEach(add);
        if (root.screencopyActive || ScreenRecorder.capturing) out.push("Screen recording");
        return out;
    }
}
