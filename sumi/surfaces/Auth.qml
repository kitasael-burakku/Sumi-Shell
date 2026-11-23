pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../services"
import "../components"

/**
 * Autenticacion de polkit (QS-FUNC-017, Fase D).
 *
 * La abre `shell.qml` sola cuando polkit pide credenciales (`pkexec`, una
 * actualizacion, montar un disco…) y el agente del shell esta encendido
 * (`services/Polkit`). Todo lo que ensena lo trae el `AuthFlow`: el mensaje de
 * polkit, la accion, el aviso de «contrasena incorrecta» y si lo tecleado se
 * enmascara (`responseVisible`).
 *
 * `⏎` entrega la respuesta y vacia el campo; `Esc` cancela la peticion. Si la
 * superficie se cierra por otra via con una peticion pendiente (clic fuera),
 * tambien se cancela: una peticion huerfana dejaria a `pkexec` esperando.
 *
 * Sale sobre una ventana a pantalla completa (excepcion en `core/Screen`): si
 * no, un `pkexec` lanzado con un juego delante esperaria un dialogo invisible.
 */
Surface {
    id: root

    mTop: 14
    mLeft: 16
    mRight: 16
    mBottom: 12

    readonly property real innerW: Metrics.authW * root.s - (root.mLeft + root.mRight) * root.s
    implicitHeight: col.implicitHeight

    readonly property var flow: Polkit.flow
    /** 6D: la petición es una operación global; abrir aquí de forma explícita la trae. */
    opId: Polkit.opId
    readonly property bool pending: root.flow !== null && !root.flow.isCompleted

    /**
     * El ultimo intento fallo. Polkit NO rellena `supplementaryMessage` al
     * fallar la contrasena: el fallo llega por `authenticationFailed` / `failed`.
     * Primera prueba en vivo (2026-09-14): dos contrasenas mal y ningun aviso.
     * Se borra al entregar la siguiente respuesta.
     */
    property bool lastFailed: false

    /**
     * Entre `⏎` y la respuesta de polkit. Con una contrasena MAL eso son ~2 s:
     * `pam_unix` va sin `nodelay` en `system-auth` y espera a proposito tras
     * cada fallo. Sin este estado el dialogo parecia colgado (lo noto el
     * usuario, 2026-09-15). Se apaga con el fallo, con el siguiente intento o al
     * completarse.
     */
    property bool checking: false

    /**
     * Guarded (fase 4): con una contraseña tecleada, salir pregunta antes. Salir cancela
     * la petición de polkit (`deferredCancel`), así que perderla sin avisar era perder la
     * autorización entera por un clic fuera.
     */
    guardReason: field.text.length > 0 && !root.checking ? "An unsent password" : ""
    function discardGuarded() { field.clear(); }
    function focusGuarded() { field.focusField(); }

    function submit() {
        if (!root.flow || !root.flow.isResponseRequired)
            return;
        root.lastFailed = false;
        root.checking = true;
        root.flow.submit(field.text);
        field.clear();
    }

    function cancel() {
        if (root.pending) root.flow.cancelAuthenticationRequest();
        root.requestClose();
    }

    function keyPressed(event) {
        if (event.key === Qt.Key_Escape) { root.cancel(); event.accepted = true; }
    }

    onActiveChanged: {
        // Puede dispararse al construir, antes de que exista `field`.
        if (typeof field === "undefined" || !field) return;
        if (root.active) {
            root.lastFailed = false;
            root.checking = false;
            field.clear();
            Qt.callLater(field.focusField);
        } else if (root.flow !== null) {
            /**
             * CERRAR NO CANCELA EN EL ACTO. Primera prueba en vivo (2026-09-14):
             * con la contrasena BUENA, polkit la acepto (sin fallo de PAM) y aun
             * asi `pkexec` recibio «Request dismissed», con un
             * `g_task_return_boolean: assertion '!task->ever_returned'` en el
             * mismo segundo. Esta rama cancelaba de forma sincrona, dentro de la
             * notificacion de «completado», donde `pending` todavia podia leerse
             * `true`: la cancelacion devolvia la tarea antes que el exito.
             *
             * Ahora se espera a que Quickshell acabe de procesar y se relee el
             * flujo real (no el binding): solo si ESE mismo flujo sigue sin
             * completarse se cancela -- la superficie se cerro con una peticion
             * viva, y sin cancelar `pkexec` esperaria para siempre.
             */
            deferredCancel.flowAtClose = root.flow;
            deferredCancel.screenAtClose = root.screenName;
            deferredCancel.restart();
        }
    }

    Timer {
        id: deferredCancel
        property var flowAtClose: null
        property string screenAtClose: ""
        interval: 300
        onTriggered: {
            const f = deferredCancel.flowAtClose;
            deferredCancel.flowAtClose = null;
            if (root.active || !f || Polkit.flow !== f)
                return;   // terminado, sustituido o reabierto
            if (f.isCompleted || f.isSuccessful || f.isCancelled)
                return;   // ya completado: cancelar ahora devolveria la tarea dos veces
            /**
             * TRASLADADA (6D): la vista se cerró porque el control pasó a otra
             * pantalla, o su monitor desapareció y el control se reubicó. La
             * petición sigue viva allí: cancelar aquí era el fallo medido
             * («Request dismissed» al abrirla en la headless y cerrar el HDMI).
             */
            if (!Operations.owns(Polkit.opId, deferredCancel.screenAtClose))
                return;
            f.cancelAuthenticationRequest();
        }
    }

    Connections {
        target: root.flow
        ignoreUnknownSignals: true
        function onIsCompletedChanged() {
            if (root.flow && root.flow.isCompleted) {
                root.checking = false;
                // Fuera de la notificacion: no reentrar en la finalizacion de Quickshell.
                Qt.callLater(root.requestClose);
            }
        }
        function onAuthenticationFailed() { root.lastFailed = true; root.checking = false; }
        function onFailedChanged() { if (root.flow && root.flow.failed) { root.lastFailed = true; root.checking = false; } }
        function onIsResponseRequiredChanged() {
            if (root.flow && root.flow.isResponseRequired) {
                root.checking = false;
                Qt.callLater(field.focusField);
            }
        }
    }

    function identityLabel(id) {
        if (!id) return "";
        return String(id.displayName || id.userName || id.name || id);
    }

    Column {
        id: col
        anchors.top: parent.top
        anchors.left: parent.left
        width: root.innerW
        spacing: 8 * root.s

        Item {
            width: col.width
            height: 20 * root.s

            Icon {
                id: lockIcon
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                name: "lock"
                size: 13 * root.s
                color: Theme.primary
            }
            Text {
                anchors.left: lockIcon.right
                anchors.leftMargin: 8 * root.s
                anchors.verticalCenter: parent.verticalCenter
                text: "AUTHENTICATION"
                color: Theme.fgVariant
                font.family: Typography.ui
                font.pixelSize: Typography.label * root.s
                font.weight: Typography.wStrong
                font.letterSpacing: Typography.tracking * root.s
            }
        }

        Text {
            width: col.width
            wrapMode: Text.WordWrap
            text: root.flow ? String(root.flow.message)
                : (Polkit.enabled ? (Polkit.registered ? "No authentication pending."
                                    : "The shell agent is not registered — another agent is running.")
                   : "The shell polkit agent is off (Settings).")
            color: Theme.fg
            font.family: Typography.ui
            font.pixelSize: Typography.body * root.s
        }

        Text {
            width: col.width
            visible: root.flow !== null && text.length > 0
            elide: Text.ElideMiddle
            text: {
                if (!root.flow) return "";
                const who = root.identityLabel(root.flow.selectedIdentity);
                return (who.length > 0 ? "as " + who + "   ·   " : "") + String(root.flow.actionId);
            }
            color: Theme.outlineText
            font.family: Typography.mono
            font.pixelSize: Typography.caption * root.s
        }

        /** Varias identidades posibles (varios administradores): se elige cual. */
        Choice {
            width: col.width
            s: root.s
            visible: root.flow !== null && root.flow.identities && root.flow.identities.length > 1
            options: {
                const out = [];
                const ids = root.flow ? root.flow.identities : [];
                for (let i = 0; ids && i < ids.length; i++)
                    out.push({ label: root.identityLabel(ids[i]), value: i });
                return out;
            }
            value: {
                const ids = root.flow ? root.flow.identities : [];
                for (let i = 0; ids && i < ids.length; i++)
                    if (ids[i] === root.flow.selectedIdentity) return i;
                return 0;
            }
            onPicked: (v) => { if (root.flow) root.flow.selectedIdentity = root.flow.identities[v]; }
        }

        /** 6D: la lleva otra pantalla (vista previa por hover): se informa, no se contesta. */
        Text {
            width: col.width
            visible: root.pending && root.opElsewhere
            wrapMode: Text.WordWrap
            text: "Waiting on " + root.opOwner + " · click here to answer on this screen"
            color: Theme.secondary
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }

        Rectangle {
            width: col.width
            height: 30 * root.s
            radius: Metrics.r(8) * root.s
            visible: root.pending && !root.opElsewhere
            opacity: root.checking ? 0.5 : 1
            color: Theme.tileBg
            border.width: 1
            border.color: field.input.activeFocus ? Qt.alpha(Theme.primary, 0.45) : Theme.hair

            Icon {
                id: keyIcon
                anchors.left: parent.left
                anchors.leftMargin: 9 * root.s
                anchors.verticalCenter: parent.verticalCenter
                name: "lock"
                size: 11 * root.s
                color: Theme.primary
            }
            SearchField {
                id: field
                anchors.left: keyIcon.right
                anchors.leftMargin: 8 * root.s
                anchors.right: parent.right
                anchors.rightMargin: 10 * root.s
                anchors.verticalCenter: parent.verticalCenter
                height: 18 * root.s
                s: root.s
                secret: !(root.flow && root.flow.responseVisible)
                placeholder: (root.flow && String(root.flow.inputPrompt).length > 0)
                    ? String(root.flow.inputPrompt).replace(/:\s*$/, "") : "Password"
                onAccepted: root.submit()
                onDismissed: root.cancel()
            }
        }

        /**
         * Avisos: el de polkit si lo manda, y si no el de intento fallido
         * (`lastFailed`), que polkit no manda como texto. Solo cuando dicen algo.
         */
        Text {
            width: col.width
            readonly property string supp: root.flow ? String(root.flow.supplementaryMessage) : ""
            visible: root.flow !== null && text.length > 0
            wrapMode: Text.WordWrap
            text: root.checking ? "Checking…"
                : supp.length > 0 ? supp
                : (root.lastFailed ? "Wrong password — try again." : "")
            color: root.checking ? Theme.fgVariant
                : (root.lastFailed || (root.flow && root.flow.supplementaryIsError)) ? Theme.errorColor : Theme.fgVariant
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }

        Text {
            width: col.width
            text: root.opElsewhere ? "Click to take it here" : root.pending ? "⏎ authenticate   Esc cancel" : "Esc close"
            color: Theme.outlineText
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }
    }
}
