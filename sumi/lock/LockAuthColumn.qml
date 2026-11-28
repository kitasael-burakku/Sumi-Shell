import QtQuick
import QtQuick.Effects
import "../components"
import "../services"
import "../theme"

/**
 * La columna central del panel (fase 15, §8 «Mapa final»): hora, fecha, avatar grande, nombre, campo
 * y el estado de la autenticación. En la versión estrecha (`compact`) es el bloque fijo de arriba.
 *
 * La línea de estado es SÓLO de la autenticación (LK-07): `Checking…`, el fallo, la cuenta bloqueada o
 * PAM no disponible, y debajo los intentos fallidos o la pista de borrado. El fallo de energía va junto
 * a la energía. Las dos líneas tienen su hueco reservado: un mensaje no empuja el campo (§10).
 *
 * En calma sólo quedan hora y fecha (`calm`): lo demás se desvanece con opacidad — no `visible` — para
 * que el campo conserve el foco lógico (§9 «Calma»).
 */
Item {
    id: root

    property var context
    property real s: 1
    property bool compact: false
    property bool showName: true
    property bool accepted: false
    property int acceptMs: 0
    property bool focused: false
    property bool calm: false
    property string lockoutText: ""
    property color fieldEdge: Theme.glassBorder
    /** El campo refleja el buffer (pantalla que manda con el teclado): LK-02. */
    property bool owner: false
    signal step(int dir)
    /** Donde empieza el recorrido de teclado: el campo y su botón de envío. */
    readonly property Item focusRoot: field

    readonly property var auth: root.context ? root.context.auth : ({})
    readonly property string state: root.auth.state || "idle"
    readonly property int failed: root.auth.failed || 0
    /** La calma, animada UNA vez aquí (no un Behavior por pieza, que suavizaría la coreografía). */
    property real restOpacity: root.calm ? 0 : 1
    Behavior on restOpacity { NumberAnimation { duration: root.calm && !Motion.off ? Motion.lockCalmFade : Motion.fast; easing.type: Easing.InOutCubic } }
    readonly property Item clockItem: timeText
    readonly property Item fieldItem: field

    /** { text, tone }: neutral · warn · danger. */
    readonly property var message: {
        switch (root.state) {
        case "checking":  return { text: "Checking…", tone: "neutral" };
        case "failed":    return { text: root.auth.message && root.auth.message.length > 0 ? root.auth.message : "Wrong password", tone: "danger" };
        case "lockedOut": return { text: root.lockoutText.length > 0 ? "Too many attempts — try again in " + root.lockoutText
                                                                 : "Too many attempts — try again later", tone: "danger" };
        case "error":     return { text: "Authentication unavailable — try again", tone: "warn" };
        }
        return { text: "", tone: "" };
    }

    function focusField() { field.focusField(); }

    implicitWidth: Math.max(field.implicitWidth, timeText.implicitWidth)
    implicitHeight: col.implicitHeight

    /**
     * Sin panel (la calma), la hora y la fecha se leen directamente sobre el fondo, que ya no se oscurece entero
     * (LockBackdrop). Como en la pantalla de bloqueo de un móvil: pasan a blanco con una sombra negra amplia y muy
     * difusa, en los dos temas, porque lo que hay detrás es el escritorio y no el tema. Con el panel, los colores del
     * tema. Todo sigue a la calma (`bare`).
     */
    readonly property real bare: 1 - root.restOpacity
    function mix(a, b, t) { return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t); }
    RectangularShadow {
        readonly property real padX: 96 * root.s
        readonly property real padY: 64 * root.s
        readonly property real x0: col.x + Math.min(timeText.x, dateText.x)
        readonly property real x1: col.x + Math.max(timeText.x + timeText.width, dateText.x + dateText.width)
        x: x0 - padX
        y: col.y + timeText.y - padY
        width: x1 - x0 + 2 * padX
        height: dateText.y + dateText.height - timeText.y + 2 * padY
        radius: height / 2
        blur: 150 * root.s
        color: Qt.rgba(0, 0, 0, 0.6)
        opacity: root.bare
        visible: opacity > 0.01
    }

    Column {
        id: col
        width: parent.width
        spacing: (root.compact ? Metrics.sp2 : Metrics.sp3) * root.s

        RollingClock {
            id: timeText
            anchors.horizontalCenter: parent.horizontalCenter
            text: Clock.time
            color: root.mix(Theme.fg, Qt.rgba(1, 1, 1, 1), root.bare)
            family: Typography.uiChosen
            weight: Typography.wStrong
            pixelSize: (root.compact ? Typography.lockNarrowTime : Typography.lockBoardTime) * root.s
            rolling: root.visible
        }
        Text {
            id: dateText
            anchors.horizontalCenter: parent.horizontalCenter
            text: Clock.longDate.toUpperCase()
            color: root.mix(Theme.fgVariant, Qt.rgba(1, 1, 1, 1), root.bare)
            font.family: Typography.uiChosen
            font.weight: Typography.wMedium
            font.pixelSize: Typography.lockDate * root.s
            font.letterSpacing: Typography.tracking * root.s
        }

        Item { width: 1; height: (root.compact ? 0 : Metrics.sp2) * root.s }

        Avatar {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: !root.compact
            s: root.s
            size: Metrics.lockBoardAvatar
            source: root.context ? root.context.avatarSource : ""
            name: root.context ? root.context.userName : ""
            opacity: root.restOpacity
        }
        // en compacto, el avatar pequeño va en línea con el nombre (el alto es para los widgets)
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.compact
            spacing: Metrics.sp2 * root.s
            opacity: root.restOpacity
            Avatar {
                anchors.verticalCenter: parent.verticalCenter
                s: root.s
                size: 32
                source: root.context ? root.context.avatarSource : ""
                name: root.context ? root.context.userName : ""
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.showName
                width: Math.min(implicitWidth, col.width - 40 * root.s)
                text: root.context ? root.context.userName : ""
                elide: Text.ElideRight
                color: Theme.fg
                font.family: Typography.uiChosen
                font.weight: Typography.wMedium
                font.pixelSize: Typography.body * root.s
            }
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: !root.compact && root.showName
            width: Math.min(implicitWidth, col.width)
            text: root.context ? root.context.userName : ""
            elide: Text.ElideRight
            color: Theme.fg
            font.family: Typography.uiChosen
            font.weight: Typography.wMedium
            font.pixelSize: Typography.title * root.s
            opacity: root.restOpacity
        }

        LockField {
            id: field
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(implicitWidth, col.width)
            context: root.context
            s: root.s
            focused: root.focused
            lockoutText: root.lockoutText
            edge: root.fieldEdge
            owner: root.owner
            onStep: (dir) => root.step(dir)
            opacity: root.restOpacity
            accepted: root.accepted
            acceptMs: root.acceptMs
        }

        // ── estado: dos líneas con su hueco siempre reservado ────────────────
        Item {
            width: col.width
            // hasta dos líneas de mensaje (uno de PAM puede ser largo) y la de intentos: fijo
            height: Typography.body * 1.4 * 2 * root.s + Typography.caption * 1.6 * root.s
            opacity: root.restOpacity

            Row {
                id: msgRow
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Metrics.sp2 * root.s
                visible: root.message.text.length > 0

                Icon {
                    y: Math.round((Typography.body * 1.4 * root.s - height) / 2)
                    visible: root.message.tone === "danger" || root.message.tone === "warn"
                    name: "alert"
                    size: 14 * root.s
                    color: root.message.tone === "danger" ? Theme.danger : Theme.warn
                }
                Text {
                    width: Math.min(implicitWidth, col.width - 24 * root.s)
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    lineHeight: 1.1
                    text: root.message.text
                    color: root.message.tone === "danger" ? Theme.danger
                        : root.message.tone === "warn" ? Theme.warn : Theme.fgVariant
                    font.family: Typography.uiChosen
                    font.weight: Typography.wMedium
                    font.pixelSize: Typography.body * root.s
                    Accessible.role: Accessible.AlertMessage
                    Accessible.name: text
                }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                text: root.failed > 0
                    ? root.failed + (root.failed === 1 ? " failed attempt" : " failed attempts")
                    : (root.context && root.context.bufferLength > 0 && root.state === "idle" ? "Esc clear  ·  Ctrl+U reset" : "")
                color: root.failed > 0 ? Theme.warn : Theme.outlineText
                font.family: Typography.uiChosen
                font.pixelSize: Typography.caption * root.s
            }
        }
    }
}
