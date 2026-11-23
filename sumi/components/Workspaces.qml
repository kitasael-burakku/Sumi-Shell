pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Hyprland
import "../theme"
import "../services"

/**
 * Workspace dots for one monitor. The active one is a filled circle, the rest are
 * small dots; a workspace that exists but is empty of nothing in particular
 * looks the same as one that does not exist yet, only dimmer.
 *
 * Everything comes from `Hyprland.workspaces` by binding — no `hyprctl` calls,
 * no polling, no process per event. Ukishima shells out to
 * `hyprctl monitors -j; hyprctl workspaces -j` on every workspace event, three
 * times per monitor, because its early `refresh*()` left the typed models empty
 * (BUG-1). Without that mistake the models are simply correct.
 */
Item {
    id: root

    property string screenName: ""
    property real s: 1
    property bool interactive: false

    readonly property real dotW: 5 * s
    /** El activo: un círculo relleno (2026-11-12, pedido del usuario; antes un palito de 17 px). */
    readonly property real activeD: 9 * s
    readonly property real gap: 7 * s
    readonly property real pitch: root.dotW + root.gap

    /**
     * This monitor's workspaces, plus the persistent ones Waybar also always
     * shows (`persistent-workspaces: {"*": 5}`), so the island does not sit
     * with a single dot on a fresh session.
     */
    readonly property var list: {
        const seen = ({});
        const out = [];
        const all = Hyprland.workspaces.values;
        for (let i = 0; i < all.length; i++) {
            const w = all[i];
            if (!w || w.id < 1)
                continue;
            if (w.monitor && w.monitor.name !== root.screenName)
                continue;
            seen[w.id] = true;
            out.push({ id: w.id, active: w.active, urgent: w.urgent, exists: true });
        }
        for (let n = 1; n <= Settings.workspaceCount; n++)
            if (!seen[n])
                out.push({ id: n, active: false, urgent: false, exists: false });
        out.sort(function (a, b) { return a.id - b.id; });
        return out;
    }

    /** Índice del activo en `list`, o -1 si este monitor no tiene ninguno a la vista. */
    readonly property int activeIndex: {
        for (let i = 0; i < root.list.length; i++)
            if (root.list[i].active)
                return i;
        return -1;
    }

    implicitWidth: row.implicitWidth
    implicitHeight: 22 * s

    /**
     * **El cambio de workspace como un slime** (2026-11-12, pedido del usuario; sustituye al
     * palito que se estiraba del 2026-10-01). El círculo activo se encoge, se estira hacia el
     * destino con un cuello fino y se recoge allí, donde se vuelve a inflar.
     *
     * No hay curvas de tiempo hechas a mano: la forma son dos círculos, cabeza y cola, que
     * persiguen el mismo destino con dos muelles por fotograma (`SpringValue`, correcto a
     * 200 Hz). La cabeza va rápida y un pelo blanda; la cola, lenta y firme. La distancia
     * entre las dos es el estiramiento `k`, y de ella salen el cuello y los radios. Al
     * llegar la cola, la forma se recoge en círculo y se reinfla (`inflate`, también muelle):
     * si el destino cambia a mitad de vuelo, todo sigue desde donde está, sin tirones.
     *
     * El dibujo es un `Shape` con `CurveRenderer` (como el arco del Mixer): arco exterior en
     * cada círculo y dos cúbicas cóncavas entre ellos, tangentes a los arcos. En reposo, con
     * `k` = 0, es un círculo exacto.
     *
     * Reduce motion: el mismo viaje, sin cuello y casi sin encogerse (calma, no apaga).
     * Off: salta. Al cambiar la escala, salta también (el destino se mueve, no el workspace).
     *
     * El destino se calcula (todos los de antes del activo son puntos), no se lee de los
     * slots: éstos animan su ancho a la vez y estarían a medio camino.
     */
    function slotLeft(i) { return i * root.pitch; }

    /**
     * Ir al workspace `n` con un clic o con la acción accesible. Por `HyprCtl` (services/), el
     * mismo camino que `Hypr.focusWorkspace`: `Hypr` es un singleton de core/ y desde components/
     * no se ve, así que el clic lanzaba «ReferenceError: Hypr is not defined» y no hacía nada
     * (2026-11-12; fallaba casi desde el principio). `HyprCtl` valida el número igual.
     */
    function go(n) {
        if (!root.interactive) return false;
        return HyprCtl.dispatch("focusWorkspace", { workspace: Number(n) });
    }

    /** Centro del círculo activo en reposo; si no hay activo, se queda donde estaba. */
    property real goal: 0
    property bool armed: false

    function place() {
        const a = root.activeIndex;
        if (a < 0)
            return;
        root.goal = root.slotLeft(a) + root.activeD / 2;
        if (!root.armed) {
            headX.jump();
            tailX.jump();
            root.armed = true;
        }
    }

    onActiveIndexChanged: root.place()
    onPitchChanged: rescale()
    onActiveDChanged: rescale()
    function rescale() {
        root.place();
        headX.jump();
        tailX.jump();
        root.refresh();
        Qt.callLater(function () { headX.jump(); tailX.jump(); root.refresh(); });
    }
    Component.onCompleted: { root.place(); inflate.jump(); root.refresh(); }

    SpringValue { id: headX; target: root.goal; animate: root.armed; rate: 1.45; soft: true; epsilon: 0.05
                  onValueChanged: root.refresh() }
    SpringValue { id: tailX; target: root.goal; animate: root.armed; rate: 0.8; critical: true; epsilon: 0.05
                  onValueChanged: root.refresh() }

    /** 0 en reposo, 1 cuando cabeza y cola están a dos huecos y pico. */
    readonly property real stretch: Math.min(1, Math.abs(headX.value - tailX.value) / (2.2 * root.pitch))
    /** Viajando: la cola aún lejos del destino. Encoge al salir y reinfla al llegar. */
    // Sólo lo actualizan la posición y el destino. El target de inflate se envía
    // explícitamente en refresh(): su respuesta pinta sin realimentar un binding.
    property bool travelling: false
    onGoalChanged: root.refresh()
    SpringValue { id: inflate; target: 1; soft: true; epsilon: 0.004
                  onValueChanged: root.refreshGeometry() }

    readonly property bool calm: Motion.still
    readonly property real shrink: root.calm ? 0.88 : 0.64
    readonly property real fill: root.shrink + (1 - root.shrink) * Math.max(0, inflate.value)
    readonly property real kNeck: root.calm ? 0 : root.stretch
    readonly property real rHead: root.activeD / 2 * root.fill * (1 - 0.06 * root.kNeck)
    readonly property real rTail: root.activeD / 2 * root.fill * (1 - 0.32 * root.kNeck)

    /** Para el banco (IPC de prueba): el estado de la forma en este fotograma. */
    function slimeInfo() {
        return { goal: root.goal, head: headX.value, tail: tailX.value, k: root.stretch,
                 rHead: root.rHead, rTail: root.rTail, inflate: inflate.value,
                 neckHalf: root.g.neckHalf, active: root.activeIndex, s: root.s };
    }

    /**
     * La geometría de la forma, en UN objeto que se rehace cuando se mueve un muelle (o cambian
     * el tamaño o el modo), no en una red de enlaces: en la recarga en caliente los muelles fijan
     * su valor inicial al completarse, a mitad de la evaluación de esos enlaces, y Qt lo daba
     * por «binding loop» (2026-11-12, visto al entregar; en frío no salía).
     *
     * Círculo A a la izquierda y B a la derecha (cabeza o cola, según el sentido). Cada uno aporta
     * su arco exterior; arriba y abajo los unen cúbicas que salen tangentes al arco en el ángulo
     * `alpha` (90° = cápsula recta; menos = cuello cóncavo). Los tiradores se recortan para que
     * el cuello nunca baje de `neckMin`.
     */
    property var g: ({ pax: 0, pbx: 0, cy: 0, ra: 0, rb: 0, sa: 1, ca: 0, lenA: 0, lenB: 0, neckHalf: 0 })
    onHeightChanged: root.refresh()
    onCalmChanged: root.refresh()
    function refresh() {
        root.travelling = Math.abs(tailX.value - root.goal) > 0.35 * root.pitch;
        inflate.target = root.travelling ? 0 : 1;
        root.refreshGeometry();
    }
    function refreshGeometry() {
        const hl = headX.value <= tailX.value;
        const ax = hl ? headX.value : tailX.value, bx = hl ? tailX.value : headX.value;
        const ra = hl ? root.rHead : root.rTail, rb = hl ? root.rTail : root.rHead;
        const alpha = (90 - 30 * root.kNeck) * Math.PI / 180;
        const sa = Math.sin(alpha), ca = Math.cos(alpha);
        const neckMin = 1.5 * root.s;
        const pax = ax + ra * ca, pbx = bx - rb * ca;
        const span = Math.max(0, pbx - pax);
        const lenA = Math.max(0, Math.min(span * 0.5, ca > 0.001 ? (ra * sa - neckMin) / ca : span));
        const lenB = Math.max(0, Math.min(span * 0.5, ca > 0.001 ? (rb * sa - neckMin) / ca : span));
        root.g = { pax: pax, pbx: pbx, cy: root.height / 2, ra: ra, rb: rb, sa: sa, ca: ca, lenA: lenA, lenB: lenB,
                   neckHalf: Math.min(ra * sa - lenA * ca, rb * sa - lenB * ca) };
    }

    Row {
        id: row
        anchors.verticalCenter: parent.verticalCenter
        spacing: root.gap

        Repeater {
            // Por número, no por la lista: con un array JS el Repeater rehacía todos los slots
            // en cada evento de Hyprland y el ancho saltaba sin animarse.
            model: root.list.length

            delegate: Item {
                id: slot
                required property int index
                readonly property var modelData: root.list[index] ?? ({ id: index + 1, active: false, urgent: false, exists: false })

                // 16A-2: activo/urgente en palabras (aquí sólo lo dicen color y tamaño)
                Accessible.role: Accessible.Button
                Accessible.name: "Workspace " + slot.modelData.id
                Accessible.description: slot.modelData.active ? "Active" : slot.modelData.urgent ? "Urgent"
                    : slot.modelData.exists ? "" : "Empty"
                Accessible.onPressAction: root.go(slot.modelData.id)
                width: slotSpring.value
                SpringValue { id: slotSpring; target: slot.modelData.active ? root.activeD : root.dotW }
                height: root.dotW
                anchors.verticalCenter: parent.verticalCenter

                // Abre hueco al círculo que llega y lo cierra tras el que se va (el muelle de arriba).

                Rectangle {
                    anchors.centerIn: parent
                    width: root.dotW
                    height: root.dotW
                    radius: Metrics.pill(height)
                    color: slot.modelData.urgent ? Theme.errorColor : Theme.fg
                    // El activo lo pinta `blob`; aquí sólo queda el hueco.
                    opacity: slot.modelData.active ? 0
                        : (area.containsMouse ? 0.75 : (slot.modelData.exists ? 0.38 : 0.16))
                    Behavior on opacity { NumberAnimation { duration: Motion.fast } }
                }

                MouseArea {
                    id: area
                    anchors.fill: parent
                    anchors.margins: -root.gap / 2
                    anchors.topMargin: -8 * root.s
                    anchors.bottomMargin: -8 * root.s
                    enabled: root.interactive
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.go(slot.modelData.id)
                }
            }
        }
    }

    /**
     * Terminal (F6, ADR-34): en vez del slime, un bloque recto que se estira entre la cabeza y la cola (los mismos dos
     * muelles), como un cursor que salta: `■ ■ █ ■`. Radio 0 desde que existe (nunca cambia en caliente).
     */
    Rectangle {
        objectName: "styleMarks"
        visible: root.armed && Style.terminal
        opacity: blob.opacity
        readonly property real r: Math.max(root.rHead, root.rTail)
        x: Math.min(headX.value - root.rHead, tailX.value - root.rTail)
        width: Math.max(headX.value + root.rHead, tailX.value + root.rTail) - x
        height: 2 * r
        y: (root.height - height) / 2
        color: Theme.primary
    }

    Shape {
        id: blob
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        visible: root.armed && !Style.terminal
        opacity: root.activeIndex >= 0 ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Motion.fast } }

        ShapePath {
            fillColor: Theme.primary
            strokeColor: "transparent"
            strokeWidth: 0

            // arriba del círculo A, donde empieza el cuello
            startX: root.g.pax
            startY: root.g.cy - root.g.ra * root.g.sa
            // cuello de arriba, hasta B
            PathCubic {
                control1X: root.g.pax + root.g.lenA * root.g.sa
                control1Y: root.g.cy - root.g.ra * root.g.sa + root.g.lenA * root.g.ca
                control2X: root.g.pbx - root.g.lenB * root.g.sa
                control2Y: root.g.cy - root.g.rb * root.g.sa + root.g.lenB * root.g.ca
                x: root.g.pbx
                y: root.g.cy - root.g.rb * root.g.sa
            }
            // arco exterior de B (por la derecha)
            PathArc {
                x: root.g.pbx
                y: root.g.cy + root.g.rb * root.g.sa
                radiusX: root.g.rb
                radiusY: root.g.rb
                useLargeArc: true
                direction: PathArc.Clockwise
            }
            // cuello de abajo, de vuelta a A
            PathCubic {
                control1X: root.g.pbx - root.g.lenB * root.g.sa
                control1Y: root.g.cy + root.g.rb * root.g.sa - root.g.lenB * root.g.ca
                control2X: root.g.pax + root.g.lenA * root.g.sa
                control2Y: root.g.cy + root.g.ra * root.g.sa - root.g.lenA * root.g.ca
                x: root.g.pax
                y: root.g.cy + root.g.ra * root.g.sa
            }
            // arco exterior de A (por la izquierda), cerrando
            PathArc {
                x: root.g.pax
                y: root.g.cy - root.g.ra * root.g.sa
                radiusX: root.g.ra
                radiusY: root.g.ra
                useLargeArc: true
                direction: PathArc.Clockwise
            }
        }
    }
}
