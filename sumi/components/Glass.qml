import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import "../theme"
import "../services"

/**
 * El material del shell, en un solo sitio.
 *
 * Todo lo que flota —el cuerpo del island, el OSD, las tarjetas de
 * notificación, el menú de la bandeja, el tooltip— repetía a mano el mismo
 * montaje: rectángulo translúcido, borde de 1 px, un pelo de luz arriba y una
 * sombra por `layer.effect`. Cinco copias que se iban separando entre sí.
 *
 * Aquí eso es una pieza, y con ella el acento de matugen entra como **luz** y no
 * como contorno: un velo de `primary` cae sobre el tercio de arriba. Es lo que
 * hace que el panel parezca hecho del color del wallpaper en vez de tener un
 * marco de ese color. (Tuvo también un filo de luz de 1 px; ver abajo.)
 */
Rectangle {
    id: glass

    property real s: 1
    /** Con sombra o sin ella (se apaga mientras se arrastra una ventana: ya no cuesta un FBO, pero se queda el contrato). */
    property bool shadowed: true
    /** Para lo que tiene que leerse sobre cualquier fondo (notificaciones). */
    property bool deep: false
    /**
     * La superficie que lo lleva (clave de `lib/surface-materials.js`): material y opacidad efectivos
     * de Theme → Material → Surfaces. "" = el global, lo de siempre (barra, OSD, menús, tooltips).
     */
    property string surface: ""
    /** Tinte del borde: un estado (crítico, conectado) puede pedir el suyo. */
    property color edge: Style.terminal && !glass.geometryOnly ? Theme.frameFor(glass.surface) : Theme.borderFor(glass.surface)
    /**
     * Sólo la geometría del estilo (F7, ADR-34; el bloqueo): los radios de los tokens y nada más. Borde y velo de
     * siempre, sin marcas ni efectos, aunque el estilo sea terminal.
     */
    property bool geometryOnly: false
    /**
     * Marcas del estilo terminal (corchetes de esquina, marco doble o segmentado; ADR-34). Fuera en lo pequeño
     * (tooltips, círculos, la píldora del grabador: ahí sólo serían ruido) y en lo que lo pide (el bloqueo).
     */
    property bool decorated: !glass.geometryOnly && glass.width > 96 * glass.s && glass.height > 48 * glass.s
    /**
     * El velo de acento de arriba. Fuera en lo que cuelga de la barra persistente (2026-10-01,
     * pedido del usuario): justo bajo la barra se leía como una franja azulada que la separaba.
     */
    property bool veil: true
    /**
     * De qué lado nace el velo (2026-11-19): la luz entra por el borde de la pantalla. Arriba de serie; la barra
     * permanente pasa su borde (`core/Bar`). Con la barra abajo, un velo desde arriba caía justo en la unión con lo
     * que cuelga de ella y se leía como una franja verdosa que separaba panel y barra (captura del autor).
     */
    property string veilFrom: "top"
    readonly property bool veilFar: glass.veilFrom === "bottom" || glass.veilFrom === "right"
    /**
     * Efectos de terminal (F5; ADR-34, ADR-23): sólo donde hay marcas posibles (`decorated`: ni lo pequeño ni el
     * bloqueo) y nunca en lo que pide calma (`fxQuiet`: los avisos críticos). Lo que está vivo lo dice `Style.fx`.
     */
    property bool fxQuiet: false
    readonly property bool fxOn: glass.decorated && !glass.fxQuiet
    readonly property bool glowOn: Style.fx.glow && glass.fxOn
    readonly property bool satin: Theme.materialFor(glass.surface) === "satin"

    color: Theme.bgFor(glass.surface, glass.deep)
    // segmentado: el trazo continuo lo sustituye el discontinuo de `marks`
    border.width: glass.marksOn && Style.now.frame === "segmented" ? 0 : 1
    border.color: glass.edge
    Behavior on border.color { ColorAnimation { duration: Motion.fast } }

    /** El velo de acento: desde el filo de luz hacia abajo, hasta desaparecer. */
    Rectangle {
        anchors.fill: parent
        visible: !glass.satin && glass.veil && (Style.now.veil || glass.geometryOnly)
        radius: glass.radius
        // por esquina: quien pide un borde recto (el island colgando de la barra) lo tiene también aquí
        topLeftRadius: glass.topLeftRadius
        topRightRadius: glass.topRightRadius
        bottomLeftRadius: glass.bottomLeftRadius
        bottomRightRadius: glass.bottomRightRadius
        gradient: Gradient {
            orientation: glass.veilFrom === "left" || glass.veilFrom === "right" ? Gradient.Horizontal : Gradient.Vertical
            GradientStop { position: glass.veilFar ? 1.0 : 0.0;  color: Theme.accentVeil }
            GradientStop { position: glass.veilFar ? 0.58 : 0.42; color: "transparent" }
            GradientStop { position: glass.veilFar ? 0.0 : 1.0;  color: "transparent" }
        }
    }

    /**
     * Líneas de barrido (F5): un patrón de 1×3 px repetido, estático, DEBAJO del contenido (nunca sobre el texto). Una
     * línea clara cada tres sobre paletas oscuras y una oscura sobre las claras, muy tenue. Píxeles enteros y sin
     * suavizado: no tiembla ni hace moiré. Apagado, el Loader no tiene objeto.
     */
    Loader {
        objectName: "styleMarks"
        anchors.fill: parent
        anchors.margins: 1
        active: Style.fx.scanlines && glass.fxOn
        sourceComponent: Image {
            fillMode: Image.Tile
            smooth: false
            opacity: Theme.light ? 0.05 : 0.045
            source: Theme.light
                ? "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAADCAYAAABS3WWCAAAAD0lEQVR42mNgYGD4zwAHAAsEAQDBko+KAAAAAElFTkSuQmCC"
                : "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAADCAYAAABS3WWCAAAAEElEQVR42mP4////fwY4AAAx3QP9Kw9wDwAAAABJRU5ErkJggg=="
        }
    }

    /**
     * Las marcas del estilo terminal (ADR-34): marco doble (un segundo trazo por dentro), segmentado (discontinuo en vez
     * del borde) y corchetes en las esquinas (decoraciones Minimal; Full añade una marca en el centro de cada lado).
     * Todo en un Loader: con soft, o sin nada que dibujar, no existe ningún objeto. Estático: no anima ni repinta solo.
     * Por debajo del contenido que el padre ponga encima (z 0, antes que los hijos que declare quien usa Glass).
     */
    readonly property bool marksOn: Style.terminal && glass.decorated
        && (Style.now.frame !== "single" || Style.now.decor !== "none")
    Loader {
        id: marks
        objectName: "styleMarks"
        anchors.fill: parent
        active: glass.marksOn
        sourceComponent: Item {
            id: m
            readonly property real k: Math.max(1, Math.round(glass.s))
            /**
             * Glitch (F5): un tirón de las MARCAS (no del contenido) en tres pasos discretos, 120 ms en total, al aparecer
             * el panel. Ni repinta en reposo ni se repite antes de 2 s (`glass.glitch`).
             */
            property real jx: 0
            transform: Translate { x: m.jx }
            readonly property real amp: (Style.fx.glitch === "strong" ? 5 : 2) * m.k
            function jolt() { joltAnim.restart(); }
            SequentialAnimation {
                id: joltAnim
                PropertyAction { target: m; property: "jx"; value: m.amp }
                PauseAnimation { duration: 40 }
                PropertyAction { target: m; property: "jx"; value: -Math.round(m.amp * 0.6) }
                PauseAnimation { duration: 40 }
                PropertyAction { target: m; property: "jx"; value: Math.round(m.amp * 0.3) }
                PauseAnimation { duration: 40 }
                PropertyAction { target: m; property: "jx"; value: 0 }
            }
            Component.onCompleted: Qt.callLater(glass.glitch)
            readonly property real arm: Math.round(Math.min(10 * glass.s, glass.width / 6, glass.height / 4))
            readonly property color ink: Theme.frameMark
            // doble: el segundo trazo a 3 px por dentro
            Rectangle {
                anchors.fill: parent
                anchors.margins: 3 * m.k
                visible: Style.now.frame === "double"
                color: "transparent"
                border.width: 1
                border.color: glass.edge
            }
            // segmentado: discontinuo, medio píxel dentro para que el trazo de 1 px caiga entero en una fila
            Shape {
                anchors.fill: parent
                visible: Style.now.frame === "segmented"
                ShapePath {
                    strokeWidth: 1
                    strokeColor: glass.edge
                    fillColor: "transparent"
                    strokeStyle: ShapePath.DashLine
                    dashPattern: [4, 3]
                    startX: 0.5; startY: 0.5
                    PathLine { x: glass.width - 0.5; y: 0.5 }
                    PathLine { x: glass.width - 0.5; y: glass.height - 0.5 }
                    PathLine { x: 0.5; y: glass.height - 0.5 }
                    PathLine { x: 0.5; y: 0.5 }
                }
            }
            // corchetes: dos barras de 2 px por esquina, sobre el borde
            Repeater {
                model: Style.now.decor === "none" ? 0 : 4
                Item {
                    required property int index
                    readonly property bool atRight: index === 1 || index === 2
                    readonly property bool atBottom: index >= 2
                    x: atRight ? glass.width - m.arm : 0
                    y: atBottom ? glass.height - m.arm : 0
                    width: m.arm
                    height: m.arm
                    Rectangle { x: 0; y: parent.atBottom ? m.arm - 2 * m.k : 0; width: m.arm; height: 2 * m.k; color: m.ink }
                    Rectangle { x: parent.atRight ? m.arm - 2 * m.k : 0; y: 0; width: 2 * m.k; height: m.arm; color: m.ink }
                }
            }
            // Full: una marca corta en el centro de cada lado
            Repeater {
                model: Style.now.decor === "full" ? 4 : 0
                Rectangle {
                    required property int index
                    readonly property bool horiz: index % 2 === 0
                    width: horiz ? m.arm : 2 * m.k
                    height: horiz ? 2 * m.k : m.arm
                    x: horiz ? Math.round((glass.width - width) / 2) : (index === 1 ? glass.width - width : 0)
                    y: horiz ? (index === 0 ? 0 : glass.height - height) : Math.round((glass.height - height) / 2)
                    color: m.ink
                }
            }
        }
    }

    /** El glitch de las marcas, si está vivo y no hubo otro en este panel hace menos de 2 s. */
    property real lastGlitch: 0
    function glitch() {
        if (Style.fx.glitch === "off" || !glass.fxOn || !glass.visible || !marks.item) return;
        const now = Date.now();
        if (now - glass.lastGlitch < 2000) return;
        glass.lastGlitch = now;
        marks.item.jolt();
    }
    onVisibleChanged: if (glass.visible) glass.glitch()

    /*
     * Aquí iba el filo de luz: 1 px arriba teñido con `primary` al 34 %. Retirado
     * el 2026-09-16 a petición del usuario — con algunos esquemas se leía como una
     * raya de otro color pegada a la cápsula (con el oliva de `expressive`, caqui).
     * Como `primary` cambia con cada wallpaper, no hay alfa que quede bien con
     * todos. El acento queda en el velo de arriba, que al 3,5 % no dibuja línea.
     */

    /**
     * La sombra, DEBAJO y aparte (2026-10-01, pedido del usuario: «el menú de la bandeja se ve
     * difuminado»). Antes era `layer.enabled` + `MultiEffect`: el panel entero —texto incluido— se
     * pintaba en una textura y el efecto la volvía a muestrear con filtrado lineal; con `uiScale`
     * 0,9 el panel cae en medio píxel y todo el texto salía blando. `RectangularShadow` (Qt 6.9+)
     * dibuja sólo la sombra de la forma, sin FBO: el contenido se pinta directo y nítido, y además
     * es más barato. `z: -1` la pone por debajo del propio rectángulo.
     *
     * La fuerza imita a la anterior: aquella salía del alfa del vidrio (una sombra de lo translúcido
     * es más tenue), así que se multiplica por él.
     */
    RectangularShadow {
        z: -1
        anchors.fill: parent
        // halo (F5): la misma sombra, centrada y del color del acento; sin FBO y estática, como la de siempre
        visible: glass.shadowed && (glass.glowOn || !glass.satin || Settings.materialShadow)
        radius: glass.radius
        topLeftRadius: glass.topLeftRadius
        topRightRadius: glass.topRightRadius
        bottomLeftRadius: glass.bottomLeftRadius
        bottomRightRadius: glass.bottomRightRadius
        offset: glass.glowOn ? Qt.vector2d(0, 0) : Qt.vector2d(0, 3 * glass.s)
        blur: glass.glowOn ? 14 * glass.s : (glass.satin ? 18 : 20) * glass.s
        spread: glass.glowOn ? 1 * glass.s : 0
        color: glass.glowOn ? Qt.alpha(Theme.primary, 0.30) : Qt.alpha(Theme.shadow, Theme.shadow.a * Math.max(0.6, glass.color.a))
    }
}
