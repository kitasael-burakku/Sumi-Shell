import QtQuick
import "../components"
import "../theme"

/**
 * El clima del Lock (fase 15, LOCK-D16): temperatura actual, condición y humedad; la ciudad y la
 * antigüedad como contexto secundario. Sin enlaces: desde el Lock no se abre Calendar ni Settings.
 *
 * `weather` (del contexto) = { state, temp, condition, icon, humidity, place, age }, con los estados de
 * `services/Weather` (7D): off · unconfigured · loading · ok · stale · unavailable. El alto no
 * cambia entre estados: un dato que llega no empuja nada (criterio 2).
 */
Rectangle {
    id: root

    property real s: 1
    property var weather: ({ state: "loading" })

    readonly property string wstate: root.weather && root.weather.state ? root.weather.state : "unavailable"
    readonly property bool hasData: root.wstate === "ok" || root.wstate === "stale"
    readonly property string emptyText: root.wstate === "loading" ? "Loading weather…"
        : (root.wstate === "off" || root.wstate === "unconfigured") ? "Weather not configured"
        : "Weather unavailable"

    implicitHeight: 76 * root.s
    radius: Metrics.rMd * root.s
    color: Theme.tileBg

    Accessible.role: Accessible.StaticText
    Accessible.name: root.hasData
        ? "Weather: " + root.weather.temp + ", " + root.weather.condition
          + (typeof root.weather.humidity === "number" ? ", humidity " + root.weather.humidity + " percent" : "")
          + (root.weather.place ? ", " + root.weather.place : "") + (root.wstate === "stale" ? ", updated " + root.weather.age : "")
        : root.emptyText

    // ── con dato ───────────────────────────────────────────────────────────
    Item {
        anchors.fill: parent
        anchors.margins: Metrics.sp3 * root.s
        visible: root.hasData
        opacity: root.wstate === "stale" ? 0.72 : 1

        Icon {
            id: glyph
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            name: root.weather.icon || "weather-cloudy"
            size: 34 * root.s
            color: Theme.primary
        }

        Text {
            id: temp
            anchors.left: glyph.right
            anchors.leftMargin: Metrics.sp3 * root.s
            anchors.top: parent.top
            text: root.weather.temp || "—"
            color: Theme.fg
            font.family: Typography.uiChosen
            font.weight: Typography.wStrong
            font.pixelSize: Typography.display * 1.2 * root.s
            font.features: { "tnum": 1 }
        }

        Text {
            anchors.left: temp.right
            anchors.leftMargin: Metrics.sp2 * root.s
            anchors.right: parent.right
            anchors.baseline: temp.baseline
            text: root.weather.condition || ""
            elide: Text.ElideRight
            color: Theme.fg
            font.family: Typography.uiChosen
            font.weight: Typography.wMedium
            font.pixelSize: Typography.body * root.s
        }

        Row {
            anchors.left: temp.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            spacing: Metrics.sp1 * root.s

            Icon {
                anchors.verticalCenter: parent.verticalCenter
                visible: typeof root.weather.humidity === "number"
                name: "humidity"
                size: 12 * root.s
                color: Theme.fgVariant
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - (Metrics.sp1 + 12) * root.s
                text: (typeof root.weather.humidity === "number" ? root.weather.humidity + "%" : "")
                    + (root.weather.place ? (typeof root.weather.humidity === "number" ? "  ·  " : "") + root.weather.place : "")
                    + (root.wstate === "stale" && root.weather.age ? "  ·  " + root.weather.age : "")
                elide: Text.ElideRight
                color: Theme.fgVariant
                font.family: Typography.uiChosen
                font.pixelSize: Typography.caption * root.s
            }
        }
    }

    // ── sin dato: un mensaje contenido en el mismo hueco ───────────────────
    Row {
        anchors.left: parent.left
        anchors.leftMargin: Metrics.sp3 * root.s
        anchors.verticalCenter: parent.verticalCenter
        spacing: Metrics.sp2 * root.s
        visible: !root.hasData

        Icon {
            anchors.verticalCenter: parent.verticalCenter
            name: "weather-cloudy"
            size: 20 * root.s
            color: Theme.outline
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.emptyText
            color: Theme.fgVariant
            font.family: Typography.uiChosen
            font.pixelSize: Typography.label * root.s
        }
    }
}
