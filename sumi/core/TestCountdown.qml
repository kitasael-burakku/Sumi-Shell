pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import "../theme"
import "../services"
import "../components"

/**
 * La cuenta regresiva de una prueba de sistema (fase 14B; futureSettingssurface §7 «Displays y
 * confirmación»: «la cuenta regresiva aparece en todas las pantallas visibles y se puede confirmar
 * con mouse o teclado»).
 *
 * Una ventana por pantalla, propia (no una surface: cerrar Settings o cambiar de surface no la
 * toca), en la capa Overlay. Sólo PINTA: el plazo y la vuelta atrás son del guard
 * (`scripts/sumi-guard.py`), así que si esta ventana no llega a verse, revierte igual.
 *
 * Teclado: sólo en la pantalla enfocada, y en exclusiva mientras dura (≤ 15 s): es una
 * confirmación Guarded (DESIGN §2). Esc = Revert en cualquier distribución de teclado; ←/→ y Tab
 * mueven entre los dos botones; Enter o Espacio pulsan el enfocado. El foco empieza en Keep
 * changes. En el resto de pantallas, sólo ratón.
 *
 * Movimiento (ANIMATIONS): sin rebotes; la cifra cambia y la barra corre lineal. Reduced y Off,
 * la barra salta a cada lectura.
 */
PanelWindow {
    id: layer

    required property var targetScreen
    readonly property string screenName: String(layer.targetScreen ? layer.targetScreen.name : "")
    readonly property real s: Settings.uiScale
    readonly property bool focusedHere: Hypr.focusedName.length === 0 || Hypr.focusedName === layer.screenName
    property string pick: "keep"

    screen: layer.targetScreen
    visible: SystemTest.testing && !Lock.engaged
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "sumi-test"
    WlrLayershell.keyboardFocus: layer.focusedHere ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    anchors { top: true }
    margins { top: 72 * layer.s }
    implicitWidth: card.width + 24 * layer.s
    implicitHeight: card.height + 24 * layer.s

    onVisibleChanged: if (visible) layer.pick = "keep"
    // el nombre se guarda al registrarse: al destruirse con su pantalla, `targetScreen` ya es null
    property string registered: ""
    Component.onCompleted: { layer.registered = layer.screenName; SystemTest.registerLayer(layer.registered, layer); }
    Component.onDestruction: SystemTest.registerLayer(layer.registered, null)

    readonly property int secs: Math.ceil(SystemTest.remainingMs / 1000)
    readonly property real frac: SystemTest.testing && SystemTest.txn
        ? Math.max(0, Math.min(1, SystemTest.remainingMs / Math.max(1, SystemTest.txn.timeoutMs))) : 0

    /** Pruebas (IPC `sysTestKey`): la misma lógica que el teclado real. */
    function key(name) {
        if (!layer.visible) return false;
        if (name === "Escape") { SystemTest.revert(); return true; }
        if (name === "Left" || name === "Right" || name === "Tab") { layer.pick = layer.pick === "keep" ? "revert" : "keep"; return true; }
        if (name === "Return" || name === "Space") { if (layer.pick === "keep") SystemTest.keep(); else SystemTest.revert(); return true; }
        return false;
    }

    Item {
        anchors.fill: parent
        focus: true
        Keys.onPressed: (e) => {
            const n = e.key === Qt.Key_Escape ? "Escape" : e.key === Qt.Key_Left ? "Left" : e.key === Qt.Key_Right ? "Right"
                : e.key === Qt.Key_Tab || e.key === Qt.Key_Backtab ? "Tab"
                : e.key === Qt.Key_Return || e.key === Qt.Key_Enter ? "Return" : e.key === Qt.Key_Space ? "Space" : "";
            if (n.length > 0 && layer.key(n)) e.accepted = true;
        }
    }

    Glass {
        id: card
        s: layer.s
        deep: true
        anchors.centerIn: parent
        width: 460 * layer.s
        height: col.implicitHeight + 32 * layer.s
        radius: Metrics.r(16) * layer.s

        Column {
            id: col
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 16 * layer.s
            spacing: 10 * layer.s

            Text {
                text: SystemTest.title
                color: Theme.fg
                font.family: Typography.ui
                font.pixelSize: Typography.title * layer.s
                font.weight: Font.DemiBold
            }
            // 14D: qué se prueba (la red lo dice: perfil y cambios) y si hay internet ahora
            Text {
                width: parent.width
                visible: text.length > 0
                text: SystemTest.detail
                color: Theme.fg
                font.family: Typography.ui
                font.pixelSize: Typography.body * layer.s
                wrapMode: Text.WordWrap
            }
            Text {
                width: parent.width
                text: "Reverting in " + layer.secs + (layer.secs === 1 ? " second" : " seconds")
                    + " unless you keep them" + (layer.focusedHere ? " · Esc reverts now" : "")
                    + (SystemTest.connectivityText.length > 0 ? "\n" + SystemTest.connectivityText : "")
                color: Theme.fgVariant
                font.family: Typography.ui
                font.pixelSize: Typography.body * layer.s
                wrapMode: Text.WordWrap
            }
            ProgressTrack {
                width: parent.width
                height: 4 * layer.s
                s: layer.s
                trackColor: Theme.hair
                value: layer.frac
                Behavior on value {
                    enabled: !Motion.still
                    NumberAnimation { duration: 200; easing.type: Easing.Linear }
                }
            }
            Row {
                anchors.right: parent.right
                spacing: 8 * layer.s
                ActionButton {
                    s: layer.s
                    label: "Revert"
                    focused: layer.focusedHere && layer.pick === "revert"
                    onTriggered: { layer.pick = "revert"; SystemTest.revert(); }
                }
                ActionButton {
                    s: layer.s
                    label: "Keep changes"
                    accent: true
                    focused: layer.focusedHere && layer.pick === "keep"
                    onTriggered: { layer.pick = "keep"; SystemTest.keep(); }
                }
            }
        }
    }
}
