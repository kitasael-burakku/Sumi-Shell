import QtQuick
import "../components"
import "../theme"

/**
 * El campo de contraseña del panel (fase 15): la cápsula con los puntos, la distribución, Bloq Mayús /
 * Bloq Num y el botón de envío. Sin el avatar pequeño (LOCK-D07: el avatar grande va encima).
 *
 * El `TextInput` (un `SearchField` secreto, sin pegar, I-10) es transparente y sólo EDITA
 * `context.buffer`; los puntos salen de `bufferLength`.
 *
 * UN SOLO DUEÑO DEL TEXTO (15C, LK-02): el texto vive en `context.buffer`. El campo de la pantalla que
 * manda (`owner`) es un ESPEJO de ese buffer —al llegar el foco a otra pantalla, su campo nace con lo
 * ya escrito y el cursor al final—; los demás campos están vacíos. Antes, cada pantalla tenía su copia
 * y la primera tecla en otra sustituía el texto a medias. Si el contexto rechaza una edición (comprobando,
 * cuenta bloqueada), el espejo devuelve el campo a lo que hay.
 */
Rectangle {
    id: root

    property var context
    property real s: 1
    property bool focused: false
    property string lockoutText: ""
    /** El canto dice el estado (fallo, error, foco); lo decide la superficie. */
    property color edge: Theme.glassBorder
    /** Esta es la pantalla que manda y tiene el teclado: su campo refleja el buffer. */
    property bool owner: false
    /** Tab / Mayús+Tab dentro del campo: la superficie decide adónde (recorrido del Lock). */
    signal step(int dir)

    readonly property bool lockFocusable: true
    readonly property string lockFocusName: "Password"
    function lockTakeFocus() { field.focusField(); }

    readonly property string mirror: root.owner && root.context ? (root.context.buffer || "") : ""
    onMirrorChanged: root.syncField()
    onOwnerChanged: root.syncField()
    function syncField() {
        if (field.text === root.mirror)
            return;
        field.text = root.mirror;
        field.input.cursorPosition = field.text.length;
    }

    readonly property var auth: root.context ? root.context.auth : ({})
    readonly property string state: root.auth.state || "idle"
    readonly property int length: root.context ? root.context.bufferLength : 0
    readonly property bool checking: root.state === "checking"
    readonly property bool lockedOut: root.state === "lockedOut"
    readonly property bool canSubmit: root.length > 0 && !root.checking && !root.lockedOut

    readonly property string placeholder: root.lockedOut ? (root.lockoutText.length > 0 ? "Locked · " + root.lockoutText : "Locked")
        : root.state === "prompt" ? String(root.auth.prompt || "").replace(/:\s*$/, "")
        : "Password"

    function focusField() { field.focusField(); }

    implicitWidth: Metrics.lockFieldW * root.s
    implicitHeight: Metrics.lockCapsuleH * root.s
    radius: Metrics.pill(height)
    color: Qt.alpha(Theme.surfaceContainerHigh, 0.7)
    border.width: 1
    border.color: root.edge
    Behavior on border.color { ColorAnimation { duration: Motion.fast } }

    Connections {
        target: root.context
        ignoreUnknownSignals: true
        function onBufferCleared() { if (field.text.length > 0) field.clear(); }
    }

    Row {
        id: indicators
        anchors.right: send.left
        anchors.rightMargin: Metrics.sp2 * root.s
        anchors.verticalCenter: parent.verticalCenter
        spacing: Metrics.sp2 * root.s

        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.context && root.context.layoutCount > 1 && root.context.layoutCode.length > 0
            text: root.context ? root.context.layoutCode : ""
            color: Theme.fgVariant
            font.family: Typography.uiChosen
            font.weight: Typography.wMedium
            font.pixelSize: Typography.label * root.s
            font.letterSpacing: 0.6 * root.s
            Accessible.name: "Keyboard layout " + text
        }
        Icon {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.context ? root.context.capsLock : false
            name: "caps-lock"
            size: 15 * root.s
            color: Theme.warn
            Accessible.name: "Caps Lock is on"
        }
        Icon {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.context ? root.context.numLock : false
            name: "num-lock"
            size: 15 * root.s
            color: Theme.fgVariant
            Accessible.name: "Num Lock is on"
        }
    }

    /** Enviar: un botón de verdad (§3 «Campo con flecha»), no un adorno. */
    Rectangle {
        id: send
        anchors.right: parent.right
        anchors.rightMargin: 6 * root.s
        anchors.verticalCenter: parent.verticalCenter
        width: root.height - 12 * root.s
        height: width
        radius: Metrics.pill(width)
        color: root.canSubmit ? (sendArea.containsMouse ? Qt.alpha(Theme.primary, 0.32) : Theme.selBg) : "transparent"
        opacity: root.canSubmit ? 1 : 0.4
        Accessible.role: Accessible.Button
        Accessible.name: "Unlock"
        enabled: root.canSubmit
        activeFocusOnTab: false   // recorrido explícito de la superficie (15C)
        readonly property bool lockFocusable: send.enabled
        readonly property string lockFocusName: "Unlock"
        border.width: send.activeFocus ? Metrics.focusWidth * root.s : 0
        border.color: Theme.focusRing
        Keys.onPressed: (e) => {
            if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) {
                if (!e.isAutoRepeat && root.context) root.context.submit();
                e.accepted = true;
            }
        }

        Icon {
            anchors.centerIn: parent
            name: "chevron-right"
            size: 16 * root.s
            color: root.canSubmit ? Theme.primary : Theme.fgVariant
        }
        MouseArea {
            id: sendArea
            anchors.fill: parent
            hoverEnabled: true
            enabled: root.canSubmit
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.context) root.context.submit()
        }
    }

    Item {
        id: fieldArea
        anchors.left: parent.left
        anchors.leftMargin: Metrics.sp4 * root.s
        anchors.right: indicators.left
        anchors.rightMargin: Metrics.sp2 * root.s
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        opacity: root.lockedOut ? 0.55 : 1
        clip: true

        readonly property real dotStep: (6 + 4) * root.s
        readonly property int maxDots: Math.max(1, Math.min(24,
            Math.floor((fieldArea.width - 28 * root.s) / fieldArea.dotStep)))

        SearchField {
            id: field
            anchors.fill: parent
            s: root.s
            // el bloqueo toma sólo la geometría del estilo (ADR-34): cursor de siempre, también en terminal
            tui: false
            secret: true
            allowPaste: false
            clearKeys: true
            opacity: 0
            enabled: !root.checking
            onClearRequested: if (root.context) root.context.clearBuffer()
            backtabs: true
            // sólo lo tecleado aquí va al contexto; lo que pone el espejo ya es el buffer
            onTextChanged: if (root.context && root.owner && field.text !== root.mirror) {
                root.context.setBuffer(field.text);
                // rechazada (comprobando, bloqueada): el campo vuelve a lo que hay
                Qt.callLater(root.syncField);
            }
            onTabbed: root.step(1)
            onBacktabbed: root.step(-1)
            onAccepted: if (root.context) root.context.submit()
            onDismissed: if (root.context) root.context.clearBuffer()
        }

        Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.length === 0
            text: root.placeholder
            elide: Text.ElideRight
            color: Theme.fgVariant
            font.family: Typography.uiChosen
            font.pixelSize: Typography.body * root.s
        }

        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4 * root.s
            visible: root.length > 0
            opacity: root.checking ? 0.5 : 1

            Repeater {
                model: Math.min(root.length, fieldArea.maxDots)
                delegate: Rectangle {
                    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                    width: 6 * root.s
                    height: width
                    radius: Metrics.pill(width)
                    color: Theme.fg
                }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.length > fieldArea.maxDots
                text: "+" + (root.length - fieldArea.maxDots)
                color: Theme.fgVariant
                font.family: Typography.uiChosen
                font.pixelSize: Typography.label * root.s
            }
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.focused && !root.checking
                width: 2 * root.s
                height: 16 * root.s
                radius: Metrics.r(1)
                color: Theme.primary
            }
        }
    }
}
