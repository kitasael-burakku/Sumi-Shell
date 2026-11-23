import QtQuick
import QtQuick.Shapes
import "../theme"

/**
 * Un medidor del Lock (fase 15, LOCK-D09, futurelocksurface §8 «Métricas»): nombre, cifra y unidad
 * SIEMPRE visibles; el arco complementa, no sustituye.
 *
 * `metric` (del contexto) = { state, value, unit, frac, sub, note }:
 *   · state: `loading` (primera muestra) · `ok` · `stale` (dato viejo) · `unavailable`.
 *   · frac: 0–1 para llenar el arco, o `null` → arco neutro (temperatura sin límites válidos:
 *     no se inventa un máximo universal).
 *   · sub: segunda línea («3.1 / 15.0 GiB»); note: la explicación accesible de la escala.
 * Desconocido se escribe `—`, nunca 0. Un arco sin dato no gira ni se anima.
 */
Rectangle {
    id: root

    property real s: 1
    property string label: ""
    property var metric: ({ state: "loading" })

    readonly property string mstate: root.metric && root.metric.state ? root.metric.state : "unavailable"
    readonly property bool known: (root.mstate === "ok" || root.mstate === "stale")
        && typeof root.metric.value === "number" && isFinite(root.metric.value)
    readonly property bool hasFrac: root.known && typeof root.metric.frac === "number" && isFinite(root.metric.frac)
    readonly property real frac: root.hasFrac ? Math.max(0, Math.min(1, root.metric.frac)) : 0
    readonly property string valueText: root.known ? String(Math.round(root.metric.value)) : "—"
    readonly property string unitText: root.known ? (root.metric.unit || "") : ""
    readonly property string stateText: root.mstate === "loading" ? "Loading…"
        : root.mstate === "unavailable" ? "Unavailable"
        : root.mstate === "stale" ? "Not updated" : (root.metric.sub || "")
    readonly property color arcColor: root.frac >= 0.9 ? Theme.danger : root.frac >= 0.75 ? Theme.warn : Theme.primary

    radius: Metrics.rMd * root.s
    color: Theme.tileBg

    Accessible.role: Accessible.StaticText
    Accessible.name: root.label + ": " + (root.known ? root.valueText + " " + root.unitText : root.stateText)
        + (root.metric && root.metric.note ? ". " + root.metric.note : "")

    readonly property real ring: Math.min(root.height - Metrics.sp3 * 2 * root.s, 44 * root.s)

    Item {
        id: dial
        anchors.left: parent.left
        anchors.leftMargin: Metrics.sp3 * root.s
        anchors.verticalCenter: parent.verticalCenter
        width: root.ring
        height: root.ring

        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeColor: Qt.alpha(Theme.fg, 0.10)
                strokeWidth: 5 * root.s
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: dial.width / 2; centerY: dial.height / 2
                    radiusX: dial.width / 2 - 3 * root.s; radiusY: radiusX
                    startAngle: 135; sweepAngle: 270
                }
            }
            ShapePath {
                // sin fracción conocida (temperatura sin límites, sin dato): sólo la pista neutra
                strokeColor: !root.hasFrac ? "transparent" : root.mstate === "stale" ? Theme.outline : root.arcColor
                strokeWidth: 5 * root.s
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: dial.width / 2; centerY: dial.height / 2
                    radiusX: dial.width / 2 - 3 * root.s; radiusY: radiusX
                    startAngle: 135; sweepAngle: Math.max(0.01, 270 * root.frac)
                }
            }
        }
    }

    Column {
        anchors.left: dial.right
        anchors.leftMargin: Metrics.sp3 * root.s
        anchors.right: parent.right
        anchors.rightMargin: Metrics.sp2 * root.s
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2 * root.s

        Text {
            width: parent.width
            text: root.label
            elide: Text.ElideRight
            color: Theme.fgVariant
            font.family: Typography.uiChosen
            font.weight: Typography.wMedium
            font.pixelSize: Typography.caption * root.s
            font.letterSpacing: 0.8 * root.s
        }
        Text {
            width: parent.width
            text: root.known ? root.valueText + " " + root.unitText : "—"
            elide: Text.ElideRight
            color: root.known ? Theme.fg : Theme.outlineText
            font.family: Typography.uiChosen
            font.weight: Typography.wStrong
            font.pixelSize: Typography.title * root.s
            font.features: { "tnum": 1 }
        }
        Text {
            width: parent.width
            visible: text.length > 0
            text: root.stateText
            elide: Text.ElideRight
            color: root.mstate === "ok" ? Theme.fgVariant : Theme.outlineText
            font.family: Typography.uiChosen
            font.pixelSize: Typography.micro * root.s
        }
    }
}
