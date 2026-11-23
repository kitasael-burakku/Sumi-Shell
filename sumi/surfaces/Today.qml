pragma ComponentBehavior: Bound
import QtQuick
import "../theme"
import "../services"
import "../components"

/** The clock's glance: today and weather. Month navigation and agenda live in Calendar UI. */
Surface {
    id: root
    mTop: 14
    mBottom: 12
    implicitHeight: content.implicitHeight

    readonly property string dateKey: Qt.formatDate(Clock.now, "yyyy-MM-dd")
    readonly property bool weatherVisible: Weather.enabled
    readonly property var current: Weather.hasData ? Weather.data.current : null
    readonly property var forecast: { void Weather.data; return Weather.forecast(root.dateKey); }
    readonly property var condition: Weather.condition(root.current ? root.current.code : null, false)
    readonly property string place: Weather.location && Weather.location.name ? Weather.location.name : ""
    readonly property string weatherMessage: Weather.state === "unconfigured" ? "Choose a city in Settings → Calendar"
        : Weather.state === "loading" ? "Loading weather…" : "Weather unavailable"

    Claim { target: Weather; method: "claim"; key: "today@" + root.screenName; value: root.active }

    function expandCalendar() { return CalendarUi.show(root.screenName, null); }
    function keyPressed(event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space || event.key === Qt.Key_O) {
            root.expandCalendar(); event.accepted = true;
        }
    }
    function stateJson() {
        return JSON.stringify({open:root.open, layout:"today", date:root.dateKey, time:Clock.time,
            weather:{shown:root.weatherVisible, state:Weather.state, forecast:root.forecast}});
    }

    Flickable {
        id: view
        anchors.fill: parent
        contentWidth: width; contentHeight: content.implicitHeight
        clip:true; boundsBehavior:Flickable.StopAtBounds
        interactive: contentHeight > height + 1

        Column {
            id: content
            width: view.width
            spacing: 14 * root.s

            Column {
                width: parent.width; spacing: 2 * root.s
                Text {
                    width:parent.width; horizontalAlignment:Text.AlignHCenter
                    text:Clock.time; color:Theme.fg
                    font.family:Typography.ui; font.pixelSize:Typography.display * 2.4 * root.s
                    font.weight:Typography.wStrong; font.features:({"tnum":1})
                    elide:Text.ElideRight
                }
                Text {
                    width:parent.width; horizontalAlignment:Text.AlignHCenter
                    text:Qt.locale().toString(Clock.now, "dddd · d MMMM")
                    wrapMode:Text.Wrap; maximumLineCount:2; elide:Text.ElideRight
                    color:Theme.fgVariant; font.family:Typography.ui; font.pixelSize:Typography.body * root.s
                }
            }

            Rectangle {
                id: weatherCard
                width:parent.width
                visible:root.weatherVisible
                height:weatherBody.implicitHeight + 24 * root.s
                radius:Metrics.rMd * root.s; color:Theme.tileBg

                Column {
                    id: weatherBody
                    x:12 * root.s; y:12 * root.s; width:parent.width-24 * root.s
                    spacing:8 * root.s

                    Row {
                        visible:root.current !== null
                        width:parent.width; spacing:10 * root.s
                        Icon { anchors.verticalCenter:parent.verticalCenter; name:root.condition.icon; size:30 * root.s; color:Theme.primary }
                        Text {
                            id: temperature
                            anchors.verticalCenter:parent.verticalCenter
                            text:root.current ? Weather.temp(root.current.temp) : ""
                            color:Theme.fg; font.family:Typography.ui; font.pixelSize:Typography.display * 1.5 * root.s
                            font.weight:Typography.wStrong; font.features:({"tnum":1})
                        }
                        Text {
                            anchors.verticalCenter:parent.verticalCenter
                            width:Math.max(0,parent.width-temperature.width-50 * root.s)
                            text:root.condition.text; wrapMode:Text.Wrap; maximumLineCount:2; elide:Text.ElideRight
                            color:Theme.fg; font.family:Typography.ui; font.pixelSize:Typography.body * root.s
                        }
                    }
                    Text {
                        visible:root.current !== null && root.place.length > 0
                        width:parent.width; text:root.place; wrapMode:Text.Wrap; maximumLineCount:2; elide:Text.ElideRight
                        color:Theme.fgVariant; font.family:Typography.ui; font.pixelSize:Typography.label * root.s
                    }
                    Text {
                        visible:root.current === null
                        width:parent.width; text:root.weatherMessage; wrapMode:Text.Wrap
                        color:Theme.fgVariant; font.family:Typography.ui; font.pixelSize:Typography.body * root.s
                    }
                    Text {
                        visible:root.current !== null && root.forecast !== null
                        width:parent.width
                        text:root.forecast ? "↑ " + Weather.temp(root.forecast.max) + "   ↓ " + Weather.temp(root.forecast.min)
                            + (root.forecast.rain !== null ? "   ·   " + root.forecast.rain + "% rain" : "") : ""
                        wrapMode:Text.Wrap; maximumLineCount:2; elide:Text.ElideRight
                        color:Theme.fgVariant; font.family:Typography.ui; font.pixelSize:Typography.label * root.s
                    }
                    Text {
                        visible:Weather.hasData && Weather.state === "stale"
                        width:parent.width; text:"Updated · " + Weather.ageText(); wrapMode:Text.Wrap
                        color:Theme.outlineText; font.family:Typography.ui; font.pixelSize:Typography.caption * root.s
                    }
                }
            }

            Rectangle { width:parent.width; height:1; color:Theme.hair }
            ActionButton {
                width:parent.width
                s:root.s; glyph:"calendar"; label:"Open calendar"; accent:true
                onTriggered:root.expandCalendar()
            }
        }
    }
    ScrollHint { view:view; s:root.s }
}
