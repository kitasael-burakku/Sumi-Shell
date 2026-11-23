import QtQuick
import QtQuick.Layouts
import "../components"
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
    /** Tab / Mayús+Tab desde el campo; el recorrido lo lleva la superficie. */
    signal step(int dir)
    /** Al traer la lista nueva desapareció el control enfocado de las notificaciones (15D). */
    signal notifsFocusLost()
    /** Expandir, desplazar o traer notificaciones: actividad para la calma (15E). */
    signal interacted()
    function notifsRoot() { return root.narrow ? slimNotifs : wideNotifs; }

    /**
     * Las secciones del recorrido de teclado, en su orden (futurelocksurface §9 «Teclado»): campo y
     * envío → transporte → privacidad → notificaciones. La energía la añade la superficie.
     */
    function focusRoots() {
        return root.narrow
            ? [slimAuthLoader.item, slimMusic, slimPrivacy, slimNotifs]
            : [auth.item, wideMusic, widePrivacy, wideNotifs];
    }

    readonly property real pad: Metrics.lockBoardPad * root.s
    readonly property real gap: Metrics.sp4 * root.s
    readonly property real needW: (Metrics.lockColLeftMin + Metrics.lockColCenterMin + Metrics.lockColRightMin
                                   + 2 * Metrics.sp4 + 2 * Metrics.lockBoardPad) * root.s
    readonly property real needH: 460 * root.s
    readonly property bool narrow: root.availW < root.needW || root.availH < root.needH
    /** La calma, animada una vez (15F: sin Behavior por pieza). */
    property real sideOpacity: root.calm ? 0 : 1
    Behavior on sideOpacity { NumberAnimation { duration: root.fadeMs; easing.type: Easing.InOutCubic } }
    /** El panel y los widgets alrededor del núcleo al entrar y salir (15F, LOCK-D11). */
    property real around: 1
    property bool coreShown: true
    function authItem() { return root.narrow ? slimAuthLoader.item : auth.item; }
    function clockItem() { const a = root.authItem(); return a ? a.clockItem : null; }
    function fieldItem() { const a = root.authItem(); return a ? a.fieldItem : null; }
    readonly property int fadeMs: root.calm ? Motion.lockCalmFade : Motion.fast

    readonly property real boardW: Math.min(Metrics.lockBoardMaxW * root.s, root.availW)
    readonly property real boardH: Math.min(Metrics.lockBoardH * root.s, root.availH)

    function focusField() {
        const a = root.narrow ? slimAuthLoader.item : auth.item;
        if (a) a.focusField();
    }

    width: root.narrow ? Math.min(Metrics.lockNarrowW * root.s, root.availW) : root.boardW
    height: root.narrow ? root.availH : root.boardH

    readonly property var ctxData: root.context ? root.context : ({})

    // ═════════════════════════════ ANCHO ═════════════════════════════════════
    Item {
        id: wide
        anchors.fill: parent
        visible: !root.narrow

        Glass {
            anchors.fill: parent
            s: root.s
            deep: true
            // el bloqueo toma SÓLO la geometría del estilo (ADR-34, F7): radios por los tokens; borde, velo y letra
            // ELEGIDA de siempre (`Typography.uiChosen` en todo lock/, no la mono de terminal), cursor de siempre, y
            // nunca marcas ni efectos
            geometryOnly: true
            radius: Metrics.openCorner * root.s
            opacity: root.sideOpacity * root.around
        }

        RowLayout {
            anchors.fill: parent
            anchors.margins: root.pad
            spacing: root.gap

            // ── izquierda ────────────────────────────────────────────────
            ColumnLayout {
                Layout.preferredWidth: Metrics.lockColLeft * root.s
                Layout.minimumWidth: Metrics.lockColLeftMin * root.s
                Layout.fillHeight: true
                spacing: Metrics.sp2 * root.s
                opacity: root.sideOpacity * root.around

                WeatherSummary {
                    Layout.fillWidth: true
                    Layout.preferredHeight: implicitHeight
                    s: root.s
                    weather: root.ctxData.weather
                }
                LockFetch {
                    id: wideFetch
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
                    paused: root.calm
                    Layout.fillWidth: true
                    Layout.preferredHeight: implicitHeight
                    context: root.context
                    s: root.s
                }
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
                    sourceComponent: LockAuthColumn {
                        context: root.context
                        s: root.s
                        compact: false
                        focused: root.focused
                        calm: root.calm
                        lockoutText: root.lockoutText
                        fieldEdge: root.fieldEdge
                        around: root.around
                        coreShown: root.coreShown
                        owner: root.owner && !root.narrow
                        onStep: (dir) => root.step(dir)
                    }
                }
            }

            // ── derecha ──────────────────────────────────────────────────
            ColumnLayout {
                Layout.preferredWidth: Metrics.lockColRight * root.s
                Layout.minimumWidth: Metrics.lockColRightMin * root.s
                Layout.fillHeight: true
                spacing: Metrics.sp2 * root.s
                opacity: root.sideOpacity * root.around

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
                    Layout.fillWidth: true
                    Layout.preferredHeight: implicitHeight
                    s: root.s
                    metrics: root.ctxData.metrics
                }
                LockNotifications {
                    id: wideNotifs
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    s: root.s
                    notifs: root.ctxData.notifs
                    ownScroll: true
                    onFocusLost: root.notifsFocusLost(); onInteracted: root.interacted()
                }
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
            deep: true
            // el bloqueo toma SÓLO la geometría del estilo (ADR-34, F7): ver arriba
            geometryOnly: true
            radius: Metrics.openCorner * root.s
            opacity: root.sideOpacity * root.around
        }
        Loader {
            id: slimAuthLoader
            x: root.pad
            y: root.pad
            width: parent.width - root.pad * 2
            active: root.narrow
            sourceComponent: LockAuthColumn {
                context: root.context
                s: root.s
                compact: true
                focused: root.focused
                calm: root.calm
                lockoutText: root.lockoutText
                fieldEdge: root.fieldEdge
                around: root.around
                coreShown: root.coreShown
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
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: slimTop.bottom
            anchors.topMargin: Metrics.sp3 * root.s
            anchors.bottom: parent.bottom
            contentHeight: slimCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            opacity: root.sideOpacity * root.around

            Column {
                id: slimCol
                width: slimFlick.width
                spacing: Metrics.sp2 * root.s

                WeatherSummary { width: parent.width; height: implicitHeight; s: root.s; weather: root.ctxData.weather }
                LockFetch { width: parent.width; height: implicitHeight; context: root.context; s: root.s; vertical: false }
                LockMusic { id: slimMusic; paused: root.calm; width: parent.width; height: implicitHeight; context: root.context; s: root.s }
                MetricGrid { width: parent.width; height: implicitHeight; s: root.s; metrics: root.ctxData.metrics }
                LockNotifications { id: slimNotifs; width: parent.width; height: implicitHeight; s: root.s; notifs: root.ctxData.notifs; ownScroll: false; onFocusLost: root.notifsFocusLost(); onInteracted: root.interacted() }
            }
        }
        ScrollHint { view: slimFlick; s: root.s; opacity: root.sideOpacity * root.around }
    }
}
