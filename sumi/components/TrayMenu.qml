import QtQuick
import QtQml
import Quickshell
import "../theme"

/**
 * El menu contextual de un icono de la bandeja, dibujado por el shell.
 *
 * Por que no el menu nativo: `QsMenuAnchor` funciona, pero exige arrancar
 * Quickshell en modo QApplication y dibuja un menu de QtWidgets con el tema de
 * Qt, que seria la unica pieza del shell fuera de Minimaru. Ademas una
 * superficie layer-shell solo puede abrir un popup con *grab* **en respuesta a
 * un clic real** (medido: `Failed to create grabbing popup ... parent window
 * has received input`), asi que ese camino no se podia probar sin una mano
 * humana. Esto se dibuja dentro de la capa que el shell ya tiene a pantalla
 * completa, asi que no hay popup, no hay grab, y los verbos IPC `trayMenu`,
 * `trayEnter`, `trayBack` y `trayDump` pueden recorrerlo entero.
 *
 * El contenido lo publica la aplicacion por DBusMenu; aqui no se inventa nada.
 * `QsMenuOpener.children` llega **asincrono**, asi que se consume por binding.
 *
 * GEOMETRIA, y aqui hubo un defecto que reporto el usuario: el ancho lo fija
 * **solo el contenido**. La primera version ataba `panel.width` a
 * `col.implicitWidth` y a la vez el ancho de cada fila a `panel.width`; como
 * `Column.implicitWidth` es el maximo del ancho de sus hijos, la cadena se
 * cerraba sobre si misma (`panel.width = max(min, panel.width)`) y la caja se
 * quedaba clavada en el minimo, con el texto saliendose por la derecha. No
 * daba aviso de "binding loop" porque no diverge: se auto-satisface.
 *
 * Regla para no repetirlo: la fila declara `implicitWidth` a partir de SU
 * contenido y nada mas; lo que tiene que ocupar todo el ancho (el resalte del
 * hover, la linea del separador, el area de clic) se estira con `x`/`width`
 * explicitos contra `panel.width`, que nunca realimenta a la fila.
 *
 * Segundo defecto, 2026-11-14 (reportado por el usuario: el resalte del hover y
 * la flecha `›` se dibujaban fuera de la caja). La columna estaba CENTRADA en el
 * panel, pero lo que va de borde a borde suponía que empezaba a `padX`. Con un
 * menú más estrecho que el mínimo de 160 px la columna se corría a la derecha y
 * todo eso se salía por el mismo desplazamiento. Ahora la columna se alinea a
 * `padX` y lo de borde a borde se coloca con `edgeX` (el borde del panel visto
 * desde la columna), así que no depende de dónde quede la columna.
 */
Item {
    id: root

    property real s: 1
    /** Pila de handles: el ultimo es el submenu que se esta viendo. */
    property var stack: []
    property real anchorCx: 0
    property real anchorBottom: 0
    /**
     * Hacia dónde se abre (2026-11-19, la barra en cualquier borde): el borde de lo que lo abre. «top» (el island y
     * la barra arriba) cuelga hacia abajo desde (`anchorCx`, `anchorBottom`), como siempre; «bottom» sube desde ese
     * punto; «left»/«right» salen hacia el otro lado, centrados en `anchorBottom` (que entonces es una y).
     */
    property string anchorEdge: "top"
    readonly property bool sideways: root.anchorEdge === "left" || root.anchorEdge === "right"

    readonly property bool active: root.stack.length > 0 && !root.closing
    /**
     * Recogiéndose hacia el icono (2026-11-12): el contenido se queda hasta el final de la
     * animación; `closed()` (y con él la máscara de input de Screen) llega al terminar.
     */
    property bool closing: false
    /** Hueco entre el borde visible de lo que lo abre (la barra, el island o su círculo) y el menú. */
    readonly property real gap: Metrics.appGap * root.s

    /**
     * EMERGE DEL ICONO (2026-11-12, pedido del usuario; antes aparecía de golpe). Un muelle
     * firme (`SpringValue`, el pulso de las surfaces) lleva `reveal` de 0 a 1: el panel crece
     * hacia abajo y hacia los lados desde el punto bajo el icono, con el contenido entrando un
     * poco después; al cerrar hace lo mismo al revés y sólo entonces se vacía. Escala, no
     * tamaño: la geometría del contenido (y lo que mide el IPC `trayDump`) no cambia.
     * Reduced: casi sólo fundido. Off: instantáneo.
     */
    SpringValue {
        id: revealSpring
        target: root.active ? 1 : 0
        critical: true
        epsilon: 0.004
        onValueChanged: if (root.closing && revealSpring.value <= 0.004) root.finishClose()
    }
    readonly property real reveal: Math.max(0, Math.min(1, revealSpring.value))
    readonly property real fromScale: Motion.still ? 0.94 : 0.55

    /** Margen interior a cada lado del panel. */
    readonly property real padX: 12 * root.s
    /** Tope de ancho del texto: una entrada patologica no agranda el panel. */
    readonly property real maxTextW: 300 * root.s
    /** x, en coordenadas de una fila, de lo que va de borde a borde (resalte, separador, área de clic). */
    readonly property real edgeX: root.padX / 2 - col.x
    /** Su ancho: el panel menos medio margen a cada lado. */
    readonly property real edgeW: panel.width - root.padX

    signal opened()
    signal closed()

    visible: root.stack.length > 0

    function openFor(menuHandle, cx, bottom, edge) {
        if (!menuHandle) return false;
        const reopen = root.stack.length > 0;
        root.closing = false;
        root.anchorCx = cx;
        root.anchorBottom = bottom;
        root.anchorEdge = ["bottom", "left", "right"].indexOf(edge) >= 0 ? edge : "top";
        root.stack = [menuHandle];
        // otro icono con el menú abierto: nace de nuevo desde el suyo
        if (reopen) revealSpring.place(0);
        root.opened();
        return true;
    }

    function close() {
        if (!root.active) return;
        root.closing = true;
        // con Off (o si ya estaba plegado) no hay animación que esperar
        if (revealSpring.value <= 0.004 || Motion.off) root.finishClose();
    }

    function finishClose() {
        if (!root.closing) return;
        root.closing = false;
        root.stack = [];
        revealSpring.jump();
        root.closed();
    }

    function back() {
        if (root.stack.length <= 1) { root.close(); return; }
        root.stack = root.stack.slice(0, root.stack.length - 1);
    }

    /**
     * Entrar en el submenu de la entrada `i`. Lo usa el verbo IPC `trayEnter`,
     * que es la unica forma de recorrer el menu sin raton -- y con la que se
     * encontraron los dos defectos de los submenus.
     */
    function enter(i) {
        const c = root.entries;
        if (i < 0 || i >= c.length) return false;
        const e = c[i];
        if (!e.hasChildren) return false;
        // La entrada CON HIJOS es ella misma el handle de su submenu.
        // `e.menuHandle` apunta al menu que la contiene: usarlo dibujaba el
        // submenu identico a su padre.
        root.stack = root.stack.concat([e]);
        return true;
    }

    /** Que hay en el nivel actual, para las pruebas. */
    function dump() {
        const c = root.entries;
        const out = [];
        for (let i = 0; i < c.length; i++)
            out.push({ i: i, text: String(c[i].text), sep: c[i].isSeparator,
                       enabled: c[i].enabled, hasChildren: c[i].hasChildren });
        return { depth: root.stack.length, entries: out };
    }

    /*
     * UN OPENER POR NIVEL, y hace falta. Con un solo `QsMenuOpener` reasignado
     * al entrar en un submenu, el menu padre se cierra -- y un submenu de
     * DBusMenu solo es valido mientras su padre sigue abierto, asi que llegaba
     * siempre vacio. Con la cadena entera abierta, el ultimo opener es el que
     * tiene las entradas que se dibujan.
     */
    Instantiator {
        id: openers
        model: root.stack
        delegate: QsMenuOpener {
            required property var modelData
            menu: modelData
        }
    }

    readonly property var entries: {
        const n = openers.count;   // dependencia explicita para reevaluar
        if (n === 0) return [];
        const last = openers.objectAt(n - 1);
        return (last && last.children) ? last.children.values : [];
    }

    // Centrado bajo el icono, sin salirse de la pantalla (a un lado: centrado en su altura, del otro lado del punto).
    // en píxeles enteros: el texto en medio píxel sale blando (2026-10-01)
    x: Math.round(root.anchorEdge === "left" ? root.anchorCx + root.gap
        : root.anchorEdge === "right" ? root.anchorCx - root.gap - panel.width
        : Math.max(8 * root.s, Math.min(root.parent ? root.parent.width - panel.width - 8 * root.s : 0,
                                        root.anchorCx - panel.width / 2)))
    y: Math.round(root.anchorEdge === "bottom" ? root.anchorBottom - root.gap - panel.height
        : root.sideways ? Math.max(8 * root.s, Math.min(root.parent ? root.parent.height - panel.height - 8 * root.s : 0,
                                                        root.anchorBottom - panel.height / 2))
        : root.anchorBottom + root.gap)
    width: panel.width
    height: panel.height

    Glass {
        id: panel
        s: root.s
        // nace del punto bajo el icono (el borde de lo que lo abre, `gap` más arriba)
        opacity: Math.min(1, root.reveal * 1.8)
        // crece desde el punto frente al icono: hacia dentro se estira más (0,3) que a lo largo (`fromScale`)
        readonly property real deep: Motion.still ? root.fromScale : 0.3
        transform: Scale {
            origin.x: root.anchorEdge === "left" ? -root.gap : root.anchorEdge === "right" ? panel.width + root.gap
                : Math.max(0, Math.min(panel.width, root.anchorCx - root.x))
            origin.y: root.anchorEdge === "bottom" ? panel.height + root.gap
                : root.sideways ? Math.max(0, Math.min(panel.height, root.anchorBottom - root.y)) : -root.gap
            xScale: root.sideways ? panel.deep + (1 - panel.deep) * root.reveal : root.fromScale + (1 - root.fromScale) * root.reveal
            yScale: root.sideways ? root.fromScale + (1 - root.fromScale) * root.reveal : panel.deep + (1 - panel.deep) * root.reveal
        }
        // Solo depende del contenido. Nada de aqui dentro vuelve a leer esto
        // para calcular su propio implicitWidth.
        width: Math.ceil(Math.max(160 * root.s, col.implicitWidth + 2 * root.padX))
        height: Math.ceil(col.implicitHeight + 10 * root.s)
        radius: Metrics.rMd * root.s

        Column {
            id: col
            // el contenido entra cuando el panel ya tiene cuerpo
            opacity: Math.max(0, Math.min(1, (root.reveal - 0.35) / 0.65))
            // alineada al margen, no centrada: ver la nota de geometría (2026-11-14)
            x: Math.round(root.padX)
            y: Math.round((panel.height - col.implicitHeight) / 2)
            spacing: 1 * root.s

            /** Volver, solo dentro de un submenu. */
            Item {
                id: backRow
                visible: root.stack.length > 1
                implicitWidth: backContent.implicitWidth
                implicitHeight: visible ? 24 * root.s : 0
                width: implicitWidth
                height: implicitHeight

                Rectangle {
                    visible: backArea.containsMouse
                    x: root.edgeX
                    y: 0
                    width: root.edgeW
                    height: parent.height
                    radius: Metrics.r(8) * root.s
                    color: Theme.tileBg
                }

                Row {
                    id: backContent
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6 * root.s
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "‹"
                        color: Theme.fgVariant
                        font.family: Typography.ui
                        font.pixelSize: Typography.body * root.s
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Back"
                        color: Theme.fgVariant
                        font.family: Typography.ui
                        font.pixelSize: Typography.label * root.s
                    }
                }

                MouseArea {
                    id: backArea
                    Accessible.role: Accessible.Button
                    Accessible.name: "Back"
                    Accessible.onPressAction: root.back()
                    x: root.edgeX
                    y: 0
                    width: root.edgeW
                    height: parent.height
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.back()
                }
            }

            Repeater {
                model: root.entries

                Item {
                    id: row
                    required property var modelData

                    readonly property bool sep: row.modelData.isSeparator
                    // 16A-2
                    Accessible.role: row.sep ? Accessible.Separator : Accessible.MenuItem
                    Accessible.name: row.sep ? "" : String(row.modelData.text || "")
                    Accessible.onPressAction: if (!row.sep && row.modelData.enabled) {
                        if (row.modelData.hasChildren) { root.stack = root.stack.concat([row.modelData]); return; }
                        row.modelData.triggered(); root.close();
                    }
                    readonly property real arrowW: row.modelData.hasChildren ? 14 * root.s : 0

                    // SOLO contenido. Ver la nota de geometria de arriba.
                    implicitWidth: row.sep ? 0 : (rowContent.implicitWidth + row.arrowW)
                    implicitHeight: row.sep ? 7 * root.s : 26 * root.s
                    width: implicitWidth
                    height: implicitHeight

                    /** Separador: una linea de pelo de borde a borde. */
                    Rectangle {
                        visible: row.sep
                        x: root.edgeX
                        y: parent.height / 2
                        width: root.edgeW
                        height: 1
                        color: Theme.hair
                    }

                    /** Resalte del hover, tambien de borde a borde. */
                    Rectangle {
                        visible: !row.sep && rowArea.containsMouse && row.modelData.enabled
                        x: root.edgeX
                        y: 0
                        width: root.edgeW
                        height: parent.height
                        radius: Metrics.r(8) * root.s
                        color: Theme.tileBg
                    }

                    Row {
                        id: rowContent
                        visible: !row.sep
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 7 * root.s

                        /** Marca de casilla o de radio, si la entrada la tiene. */
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: row.modelData.buttonType !== undefined && row.modelData.buttonType !== 0
                            text: row.modelData.checkState === Qt.Checked ? "󰄬" : " "
                            color: Theme.primary
                            font.family: Typography.mono
                            font.pixelSize: Typography.label * root.s
                        }

                        Image {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: String(row.modelData.icon).length > 0
                            source: String(row.modelData.icon)
                            sourceSize.width: 28
                            sourceSize.height: 28
                            // Sin `visible ? … : 0`: el `Row` ya se salta lo invisible (QS-FUNC-005).
                            width: 14 * root.s
                            height: 14 * root.s
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                        }

                        Text {
                            id: label
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.modelData.text
                            color: row.modelData.enabled ? Theme.fg : Theme.fgVariant
                            opacity: row.modelData.enabled ? 1 : 0.45
                            font.family: Typography.ui
                            font.pixelSize: Typography.body * root.s
                            // El tope es una CONSTANTE, no el ancho del panel:
                            // asi el texto puede ensanchar la caja hasta el tope
                            // y solo entonces se elide.
                            width: Math.min(implicitWidth, root.maxTextW)
                            elide: Text.ElideRight
                        }
                    }

                    /** Flecha de submenu, a `padX` del borde derecho del panel (dentro del resalte). */
                    Text {
                        visible: row.modelData.hasChildren
                        x: panel.width - root.padX - width - col.x
                        anchors.verticalCenter: parent.verticalCenter
                        text: "›"
                        color: Theme.fgVariant
                        font.family: Typography.ui
                        font.pixelSize: Typography.body * root.s
                    }

                    MouseArea {
                        id: rowArea
                        x: root.edgeX
                        y: 0
                        width: root.edgeW
                        height: parent.height
                        enabled: !row.sep && row.modelData.enabled
                        hoverEnabled: true
                        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: {
                            if (row.modelData.hasChildren) {
                                root.stack = root.stack.concat([row.modelData]);
                                return;
                            }
                            row.modelData.triggered();
                            root.close();
                        }
                    }
                }
            }
        }
    }
}
