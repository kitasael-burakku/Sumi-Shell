import QtQuick
import QtQuick.Layouts
import "../components"
import "../services"
import "../theme"

/**
 * El panel del Lock (fase 15, LOCK-D06, futurelocksurface §8 «Mapa final» y §10 «Adaptación»).
 *
 * Ancho — tres columnas dentro de un vidrio con ancho acotado:
 *   izquierda  clima · fetch (imagen + 6 filas) · música
 *   centro     hora · fecha · avatar · nombre · campo · estado (LockAuthColumn)
 *   derecha    CPU · temperatura · RAM · disco (2 × 2) · notificaciones con scroll propio
 *   y la privacidad en la esquina superior derecha del panel (LOCK-D20).
 *
 * Estrecho (LOCK-D18) — cuando las tres columnas no caben con su mínimo en `availW` × `availH`: la
 * autenticación fija arriba y debajo UNA región con scroll (clima, fetch, música, métricas,
 * notificaciones); el campo nunca entra en el scroll ni lo cubre nada.
 *
 * No sabe de bloqueos ni de PAM: todo sale del contrato (`context`). En calma quedan hora y fecha;
 * el resto se va con opacidad (el foco del campo se conserva).
 */
Item {
    id: root

    property var context
    property real s: 1
    /** El espacio donde puede estar: la superficie ya descontó la esquina de energía. */
    property real availW: 1920
    property real availH: 1080
    property bool focused: false
    property bool calm: false
    property string lockoutText: ""
    property color fieldEdge: Theme.glassBorder
    /** La pantalla que manda con el teclado: su campo refleja el buffer (LK-02). */
    property bool owner: false
    property bool accepted: false
    readonly property bool minimal: Settings.lockLayout === "minimal"
    readonly property bool showWeather: !root.minimal && Settings.lockWeather
    readonly property bool showFetch: !root.minimal && Settings.lockFetch
    readonly property bool showMusic: !root.minimal && Settings.lockMusic
    readonly property bool showMetrics: !root.minimal && Settings.lockMetrics
    readonly property bool showNotifs: !root.minimal && Settings.lockNotifications !== "hidden"
    readonly property bool countOnly: Settings.lockNotifications === "count"
    readonly property bool hasModules: root.showWeather || root.showFetch || root.showMusic
        || root.showMetrics || root.showNotifs
    /** Tab / Mayús+Tab desde el campo; el recorrido lo lleva la superficie. */
    signal step(int dir)
    /** Al traer la lista nueva desapareció el control enfocado de las notificaciones (15D). */
    signal notifsFocusLost()
    /** Expandir, desplazar o traer notificaciones: actividad para la calma (15E). */
    signal interacted()
    function notifsRoot() { return root.showNotifs ? (root.narrow ? slimNotifs : wideNotifs) : null; }

    /**
     * Las secciones del recorrido de teclado, en su orden (futurelocksurface §9 «Teclado»): campo y
     * envío → transporte → privacidad → notificaciones. La energía la añade la superficie.
     */
    function focusRoots() {
        return root.narrow
            ? [slimAuthLoader.item, slimMusic, slimPrivacy, slimNotifs]
            : [auth.item, wideMusic, widePrivacy, wideNotifs];
    }

    // Un plano un paso por encima del velo, con el alfa del material elegido.
    readonly property color panelFill: Qt.alpha(Theme.surfaceContainerLow, Theme.materialDeep.a)
    readonly property color panelEdge: Qt.alpha(Theme.fg, Math.max(Theme.hair.a, Theme.materialBorder.a))
    readonly property real pad: Metrics.lockBoardPad * root.s
    readonly property real gap: Metrics.sp4 * root.s
    readonly property real needW: (Metrics.lockColLeftMin + Metrics.lockColCenterMin + Metrics.lockColRightMin
                                   + 2 * Metrics.sp4 + 2 * Metrics.lockBoardPad) * root.s
    readonly property real needH: 460 * root.s
    readonly property bool narrow: !root.hasModules || root.availW < root.needW || root.availH < root.needH
    onNarrowChanged: if (root.owner && !root.accepted) Qt.callLater(root.focusField)
    /** La calma, animada una vez (15F: sin Behavior por pieza). */
    property real sideOpacity: root.calm ? 0 : 1
    Behavior on sideOpacity { NumberAnimation { duration: root.fadeMs; easing.type: Easing.InOutCubic } }
    /** El panel y los widgets alrededor del núcleo al entrar y salir (15F, LOCK-D11). */
    property real around: 1
    property real centerProgress: 1
    property real sideTravel: 0
    /** El estilo del bloqueo ("sumi" o uno de ventana) y lo que dura la salida tras el éxito (pulso + cierre). */
    property string styleName: "sumi"
    property int acceptMs: 0

    /**
     * Despertar de la calma (2026-11-28): el vidrio del panel vuelve a abrir con el estilo del bloqueo (Reveal, como al
     * entrar) y los laterales entran después, desde el centro. Al calmarse se funde como siempre (`lockCalmFade`) y,
     * ya invisible, el Reveal pasa a cerrado sin animar. Con Sumi sólo vuelven los laterales.
     */
    readonly property bool wakeStyled: root.styleName !== "sumi"
    property bool glassShown: true
    property bool glassAnimated: true
    Reveal {
        id: wakeRv
        style: root.wakeStyled ? root.styleName : "minimalist"
        s: root.s
        animated: root.glassAnimated && root.wakeStyled
        shown: root.glassShown
    }
    Timer {
        id: calmSettle
        interval: Motion.lockCalmFade + 50
        onTriggered: if (root.calm) {
            root.glassAnimated = false;
            root.glassShown = false;
            root.glassAnimated = true;
        }
    }
    property real wake: 1
    NumberAnimation {
        id: wakeAnim
        target: root; property: "wake"; from: 0; to: 1
        duration: Motion.lockContentMs
        easing.type: Easing.OutCubic
    }
    SequentialAnimation {
        id: wakeSeq
        PauseAnimation { duration: root.wakeStyled ? Math.round(Motion.lockOpenFor(root.styleName) * 0.35) + Motion.lockStagger : Motion.lockStagger }
        ScriptAction { script: wakeAnim.restart() }
    }
    onCalmChanged: {
        if (root.calm) {
            wakeSeq.stop(); wakeAnim.stop();
            root.wake = 1;
            calmSettle.restart();
        } else {
            calmSettle.stop();
            if (Motion.off) { root.glassShown = true; return; }
            // sólo si el vidrio llegó a cerrarse: un despertar a mitad del fundido vuelve con el fundido
            if (!root.glassShown) {
                root.wake = 0;
                root.glassShown = true;
                wakeSeq.restart();
            }
        }
    }
    readonly property real wakeTravel: Motion.still ? 0 : Metrics.sp5 * root.s * (1 - root.wake)
    /** Con un estilo de ventana el vidrio ES la forma (Reveal en la superficie): no espera a los laterales (`around`). */
    readonly property real glassOpacity: root.wakeStyled ? wakeRv.opacity : 1
    readonly property bool glassLayer: root.wakeStyled && wakeRv.effect && wakeRv.progress > 0.001 && wakeRv.progress < 0.999
    function authItem() { return root.narrow ? slimAuthLoader.item : auth.item; }
    function clockItem() { const a = root.authItem(); return a ? a.clockItem : null; }
    function fieldItem() { const a = root.authItem(); return a ? a.fieldItem : null; }
    readonly property int fadeMs: root.calm && !Motion.off ? Motion.lockCalmFade : Motion.fast

    readonly property real boardW: Math.min(Metrics.lockBoardMaxW * root.s, root.availW)
    readonly property real boardH: Math.min(Metrics.lockBoardH * root.s, root.availH)

    function focusField() {
        const a = root.narrow ? slimAuthLoader.item : auth.item;
        if (a) a.focusField();
    }

    width: root.narrow ? Math.min(Metrics.lockNarrowW * root.s, root.availW) : root.boardW
    height: !root.hasModules ? Math.min(root.availH, slimTop.height) : root.narrow ? root.availH : root.boardH

    readonly property var ctxData: root.context ? root.context : ({})

    // ═════════════════════════════ ANCHO ═════════════════════════════════════
    Item {
        id: wide
        anchors.fill: parent
        visible: !root.narrow

        Glass {
            id: wideGlass
            anchors.fill: parent
            s: root.s
            color: root.panelFill
            edge: root.panelEdge
            // el bloqueo toma SÓLO la geometría del estilo (ADR-34, F7): radios por los tokens; borde, velo y letra
            // ELEGIDA de siempre (`Typography.uiChosen` en todo lock/, no la mono de terminal), cursor de siempre, y
            // nunca marcas ni efectos
            geometryOnly: true
            radius: Metrics.openCorner * root.s
            opacity: root.sideOpacity * (root.wakeStyled ? 1 : root.around) * root.glassOpacity
            scale: root.wakeStyled ? wakeRv.scale : 1
            transform: [
                Translate { y: root.wakeStyled ? wakeRv.dy : 0 },
                Scale { origin.x: wideGlass.width / 2; origin.y: wideGlass.height / 2
                        xScale: root.wakeStyled ? wakeRv.sx : 1; yScale: root.wakeStyled ? wakeRv.sy : 1 }
            ]
            layer.enabled: root.glassLayer
            layer.effect: root.glassLayer ? wideFx : null
            Component { id: wideFx; RevealEffect { rv: wakeRv; s: root.s; radius: Metrics.openCorner * root.s } }
        }

        RowLayout {
            anchors.fill: parent
            anchors.margins: root.pad
            spacing: root.gap

            // ── izquierda ────────────────────────────────────────────────
            ColumnLayout {
                enabled: root.around > 0 && !root.accepted
                transform: Translate { x: root.sideTravel + root.wakeTravel }
                Layout.preferredWidth: Metrics.lockColLeft * root.s
                Layout.minimumWidth: Metrics.lockColLeftMin * root.s
                Layout.fillHeight: true
                spacing: Metrics.sp2 * root.s
                opacity: root.sideOpacity * root.around * root.wake

                WeatherSummary {
                    visible: root.showWeather
                    Layout.fillWidth: true
                    Layout.preferredHeight: implicitHeight
                    s: root.s
                    weather: root.ctxData.weather
                }
                LockFetch {
                    visible: root.showFetch
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    context: root.context
                    s: root.s
                    vertical: true
                    // la imagen crece con el hueco que dejan las filas, hasta 180
                    imageSide: Math.max(72 * root.s, Math.min(180 * root.s, width - Metrics.sp4 * 2 * root.s,
                        height - (6 * 21 + 3 * 12) * root.s))
                }
                LockMusic {
                    id: wideMusic
                    visible: root.showMusic
                    paused: root.calm || !visible || root.accepted
                    Layout.fillWidth: true
                    Layout.preferredHeight: implicitHeight
                    context: root.context
                    s: root.s
                }
                Item { visible: !root.showFetch; Layout.fillHeight: true }
            }

            // ── centro ───────────────────────────────────────────────────
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: Metrics.lockColCenter * root.s
                Layout.minimumWidth: Metrics.lockColCenterMin * root.s

                Loader {
                    id: auth
                    anchors.centerIn: parent
                    width: parent.width
                    active: !root.narrow
                    opacity: root.centerProgress
                    sourceComponent: LockAuthColumn {
                        context: root.context
                        s: root.s
                        compact: false
                        focused: root.focused
                        calm: root.calm
                        lockoutText: root.lockoutText
                        fieldEdge: root.fieldEdge
                        accepted: root.accepted
                        acceptMs: root.acceptMs
                        owner: root.owner && !root.narrow
                        onStep: (dir) => root.step(dir)
                    }
                }
            }

            // ── derecha ──────────────────────────────────────────────────
            ColumnLayout {
                enabled: root.around > 0 && !root.accepted
                transform: Translate { x: -root.sideTravel - root.wakeTravel }
                Layout.preferredWidth: Metrics.lockColRight * root.s
                Layout.minimumWidth: Metrics.lockColRightMin * root.s
                Layout.fillHeight: true
                spacing: Metrics.sp2 * root.s
                opacity: root.sideOpacity * root.around * root.wake

                // la fila de la privacidad: su sitio reservado arriba a la derecha (LOCK-D20)
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 26 * root.s
                    LockPrivacy {
                        id: widePrivacy
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        s: root.s
                        privacy: root.ctxData.privacy
                    }
                }
                MetricGrid {
                    visible: root.showMetrics
                    Layout.fillWidth: true
                    Layout.preferredHeight: implicitHeight
                    s: root.s
                    metrics: root.ctxData.metrics
                }
                LockNotifications {
                    id: wideNotifs
                    visible: root.showNotifs
                    countOnly: root.countOnly
                    Layout.fillWidth: true
                    Layout.fillHeight: !root.countOnly
                    s: root.s
                    notifs: root.ctxData.notifs
                    ownScroll: true
                    onFocusLost: root.notifsFocusLost(); onInteracted: root.interacted()
                }
                Item { visible: !root.showNotifs || root.countOnly; Layout.fillHeight: true }
            }
        }
    }

    // ════════════════════════════ ESTRECHO ═══════════════════════════════════
    Item {
        id: slim
        anchors.fill: parent
        visible: root.narrow

        // autenticación fija arriba, fuera del scroll
        Glass {
            id: slimTop
            width: parent.width
            height: (slimAuthLoader.item ? slimAuthLoader.item.implicitHeight : 0) + root.pad * 2
            s: root.s
            color: root.panelFill
            edge: root.panelEdge
            // el bloqueo toma SÓLO la geometría del estilo (ADR-34, F7): ver arriba
            geometryOnly: true
            radius: Metrics.openCorner * root.s
            opacity: root.sideOpacity * (root.wakeStyled ? 1 : root.around) * root.glassOpacity
            scale: root.wakeStyled ? wakeRv.scale : 1
            transform: [
                Translate { y: root.wakeStyled ? wakeRv.dy : 0 },
                Scale { origin.x: slimTop.width / 2; origin.y: slimTop.height / 2
                        xScale: root.wakeStyled ? wakeRv.sx : 1; yScale: root.wakeStyled ? wakeRv.sy : 1 }
            ]
            layer.enabled: root.glassLayer
            layer.effect: root.glassLayer ? slimFx : null
            Component { id: slimFx; RevealEffect { rv: wakeRv; s: root.s; radius: Metrics.openCorner * root.s } }
        }
        Loader {
            id: slimAuthLoader
            x: root.pad
            y: root.pad
            width: parent.width - root.pad * 2
            active: root.narrow
            opacity: root.centerProgress
            sourceComponent: LockAuthColumn {
                context: root.context
                s: root.s
                compact: !root.minimal || root.availH < 430 * root.s
                showName: !root.minimal
                focused: root.focused
                calm: root.calm
                lockoutText: root.lockoutText
                fieldEdge: root.fieldEdge
                accepted: root.accepted
                acceptMs: root.acceptMs
                owner: root.owner && root.narrow
                onStep: (dir) => root.step(dir)
            }
        }
        LockPrivacy {
            id: slimPrivacy
            anchors.right: slimTop.right
            anchors.top: slimTop.top
            anchors.margins: Metrics.sp3 * root.s
            s: root.s
            privacy: root.ctxData.privacy
            opacity: root.sideOpacity * root.around
        }

        Flickable {
            id: slimFlick
            visible: root.hasModules
            enabled: root.around > 0 && !root.accepted
            transform: Translate { y: -root.sideTravel - root.wakeTravel }
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: slimTop.bottom
            anchors.topMargin: Metrics.sp3 * root.s
            anchors.bottom: parent.bottom
            contentHeight: slimCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            opacity: root.sideOpacity * root.around * root.wake

            Column {
                id: slimCol
                width: slimFlick.width
                spacing: Metrics.sp2 * root.s

                WeatherSummary { visible: root.showWeather; width: parent.width; height: implicitHeight; s: root.s; weather: root.ctxData.weather }
                LockFetch { visible: root.showFetch; width: parent.width; height: implicitHeight; context: root.context; s: root.s; vertical: false }
                LockMusic { id: slimMusic; visible: root.showMusic; paused: root.calm || !visible || root.accepted; width: parent.width; height: implicitHeight; context: root.context; s: root.s }
                MetricGrid { visible: root.showMetrics; width: parent.width; height: implicitHeight; s: root.s; metrics: root.ctxData.metrics }
                LockNotifications { id: slimNotifs; visible: root.showNotifs; countOnly: root.countOnly; width: parent.width; height: implicitHeight; s: root.s; notifs: root.ctxData.notifs; ownScroll: false; onFocusLost: root.notifsFocusLost(); onInteracted: root.interacted() }
            }
        }
        ScrollHint { visible: root.hasModules; view: slimFlick; s: root.s; opacity: root.sideOpacity * root.around }
    }
}
