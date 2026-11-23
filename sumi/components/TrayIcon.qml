import QtQuick
import QtQuick.Effects
import Quickshell.Services.SystemTray
import "../theme"

/**
 * Un icono de la bandeja.
 *
 * `interactive` decide si escucha el raton. En la cara rest va SIEMPRE en
 * false: esa cara se desvanece al acercar el puntero, asi que un MouseArea
 * ahi es inalcanzable (lo mismo que se aprendio con los avisos en 9.b). La
 * copia clicable vive en la cara hover.
 *
 * `sourceSize` esta fijado a proposito: una Image decodifica al tamano de
 * origen aunque se dibuje pequena, y los iconos de tema pueden venir a 512 px
 * (ADR-14, el mismo defecto que costo 153 MB con las miniaturas).
 */
Item {
    id: root

    property var item: null
    property real s: 1
    property bool interactive: false

    signal menuRequested(var trayItem, var anchorItem)

    // 16A-2
    Accessible.role: Accessible.Button
    Accessible.name: root.item ? String(root.item.tooltipTitle || root.item.title || root.item.id || "") : ""
    Accessible.onPressAction: if (root.item && root.interactive) {
        if (root.item.onlyMenu) { if (root.item.hasMenu) root.menuRequested(root.item, root); }
        else root.item.activate();
    }

    readonly property bool attention:
        root.item !== null && root.item.status === SystemTrayItem.NeedsAttention

    implicitWidth: 16 * root.s
    implicitHeight: 16 * root.s

    Image {
        id: img
        anchors.fill: parent
        source: root.item !== null ? root.item.icon : ""
        // Fijo a 2x del tamano de dibujo: acota la decodificacion sin depender
        // de `Screen`, que aqui seria ambiguo (el proyecto tiene core/Screen).
        sourceSize.width: 32
        sourceSize.height: 32
        fillMode: Image.PreserveAspectFit
        smooth: true
        asynchronous: true
        opacity: root.interactive && area.containsMouse ? 1.0 : 0.85
        Behavior on opacity { NumberAnimation { duration: Motion.fast } }
        /*
         * Con paleta clara, el icono más oscuro (2026-10-01): hay apps que mandan su icono en blanco
         * pensando en barras oscuras (ChatGPT, el USB) y sobre el vidrio claro desaparecían. Bajar el
         * brillo deja lo blanco en un gris legible y a un icono de color sólo lo oscurece (un contorno
         * difuminado se probó antes: halo gris y el blanco seguía sin leerse). Con paleta oscura, ni se monta.
         */
        layer.enabled: Theme.light
        layer.effect: MultiEffect {
            brightness: -0.55
        }
    }

    /** El punto de "necesito atencion", que en Waybar era invisible al esconder la barra. */
    Rectangle {
        visible: root.attention
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: -1 * root.s
        width: 6 * root.s
        height: width
        radius: Metrics.pill(width)
        color: Theme.errorColor
        border.width: 1
        border.color: Theme.glassBg
    }

    MouseArea {
        id: area
        anchors.fill: parent
        anchors.margins: -3 * root.s
        enabled: root.interactive && root.item !== null
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor

        onClicked: function (mouse) {
            if (!root.item) return;
            // `onlyMenu` significa que el item no tiene accion primaria: el
            // clic izquierdo tiene que abrir el menu o no hace nada.
            if (mouse.button === Qt.RightButton || (mouse.button === Qt.LeftButton && root.item.onlyMenu)) {
                if (root.item.hasMenu) root.menuRequested(root.item, root);
            } else if (mouse.button === Qt.MiddleButton) {
                root.item.secondaryActivate();
            } else {
                root.item.activate();
            }
        }
        onWheel: function (wheel) {
            if (!root.item) return;
            const dy = wheel.angleDelta.y;
            if (dy !== 0) root.item.scroll(dy > 0 ? 1 : -1, false);
        }
    }
}
