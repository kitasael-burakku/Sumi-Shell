import QtQuick
import "../components"
import "../theme"

/**
 * Suspender, reiniciar y apagar desde la pantalla de bloqueo, SIN contraseña y
 * manteniendo pulsado (decisión del usuario, docs/lock/ENTREVISTA.md preguntas 8 y
 * 13; ENTRADA.md §8). Pequeño y en una esquina: es lo último de la jerarquía
 * (INTERFAZ.md §2).
 *
 * Una sola línea de pista para los tres, encima y alineada a la derecha, con la
 * del botón que se toca, se sostiene o tiene el foco.
 */
Column {
    id: root

    property var context
    property real s: 1
    /** Deshabilitados mientras se comprueba una contraseña o se sale. */
    property bool locked: false
    /** false en el Lock del rediseño: el recorrido de teclado lo lleva la superficie (15C). */
    property bool tabStops: true
    /**
     * 2026-10-01 (pedido del usuario): en el Lock la energía va DEBAJO del panel, centrada y mediana,
     * no en la esquina. `centered` centra la pista y la fila; `buttonSize` es el diámetro de cada botón.
     */
    property bool centered: false
    property real buttonSize: 32
    /** Algún botón se está sosteniendo: la calma espera (15E). */
    readonly property bool holding: suspendBtn.holding || restartBtn.holding || powerBtn.holding

    readonly property var focusedButton: suspendBtn.hintVisible ? suspendBtn
        : restartBtn.hintVisible ? restartBtn
        : powerBtn.hintVisible ? powerBtn : null

    spacing: Metrics.sp2 * root.s

    Text {
        anchors.right: root.centered ? undefined : parent.right
        anchors.horizontalCenter: root.centered ? parent.horizontalCenter : undefined
        height: Typography.caption * 1.5 * root.s
        text: root.focusedButton ? root.focusedButton.label
            : (root.context && !root.context.suspendOk && suspendArea.containsMouse ? root.context.suspendNote : "")
        color: root.focusedButton && root.focusedButton.tone === "danger" && root.focusedButton.holding
            ? Theme.danger : Theme.fgVariant
        font.family: Typography.uiChosen
        font.pixelSize: Typography.caption * root.s
    }

    Row {
        anchors.right: root.centered ? undefined : parent.right
        anchors.horizontalCenter: root.centered ? parent.horizontalCenter : undefined
        spacing: (root.centered ? Metrics.sp4 : Metrics.sp2) * root.s

        Item {
            width: suspendBtn.width
            height: suspendBtn.height

            /**
             * Debajo del botón y siempre activa: si suspender está deshabilitado
             * (logind no puede, o hay un inhibidor), su área no recibe el ratón y
             * ésta sí, para decir por qué en la pista.
             */
            MouseArea {
                id: suspendArea
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
            }

            HoldButton {
            tabStop: root.tabStops
                id: suspendBtn
                diameter: root.buttonSize
                s: root.s
                glyph: "suspend"
                label: "Hold to suspend"
                enabled: !root.locked && (root.context ? root.context.suspendOk : false)
                onFired: if (root.context) root.context.power("suspend")
            }
        }
        HoldButton {
            tabStop: root.tabStops
            id: restartBtn
            diameter: root.buttonSize
            s: root.s
            glyph: "restart"
            label: "Hold to restart"
            enabled: !root.locked
            onFired: if (root.context) root.context.power("reboot")
        }
        HoldButton {
            tabStop: root.tabStops
            id: powerBtn
            diameter: root.buttonSize
            s: root.s
            glyph: "power"
            label: "Hold to shut down"
            tone: "danger"
            enabled: !root.locked
            onFired: if (root.context) root.context.power("shutdown")
        }
    }
}
