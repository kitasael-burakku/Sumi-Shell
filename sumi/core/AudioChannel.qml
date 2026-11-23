import QtQuick
import "../theme"
import "../services"
import "../components"

/**
 * Una fila de volumen de la Audio UI: silencio, nombre, cifra y deslizador, y un renglón de apoyo
 * (ruta o descripción). Alto fijo: que un flujo pase de «9 %» a «muted» no mueve nada alrededor.
 * Misma lectura que la surface (`Mixer.shownVolume`, `failedOn`): lo pedido en vuelo, o el nodo.
 */
Item {
    id: ch
    /** La familia de acento de la zona (Theme.fam; lib/accent-zones.js). */
    readonly property var acc: Theme.fam(palette.accent)
    required property var node
    property real s: 1
    property bool focused: false
    property bool recording: false
    /** El nombre; por defecto el corto del nodo. */
    property string title: Mixer.shortLabel(ch.node)
    /** Renglón de apoyo (vacío = sin renglón). */
    property string sub: ""
    signal picked()

    readonly property bool ready: !!ch.node && !!ch.node.audio
    readonly property real vol: ch.ready ? Mixer.shownVolume(ch.node) : 0
    readonly property bool muted: ch.ready ? Mixer.shownMuted(ch.node) : false
    readonly property bool failed: Mixer.failedOn(ch.node)

    width: parent ? parent.width : 0
    height: (ch.sub.length > 0 ? 90 : 76) * ch.s

    Accessible.role: Accessible.Slider
    Accessible.name: ch.title + (ch.recording ? ", recording" : "")
    Accessible.description: !ch.ready ? "no volume control" : ch.muted ? "muted" : Math.round(ch.vol * 100) + " percent"
    Accessible.focusable: true
    Accessible.focused: ch.focused

    AudioFocus { on: ch.focused; s: ch.s }
    MouseArea { anchors.fill: parent; onPressed: (m) => { ch.picked(); m.accepted = false; } }

    HoverHandler { id: rowHover }
    Rectangle {
        anchors.fill: parent; radius: Metrics.rSm * ch.s; z: -1
        color: Theme.controlBg(Theme.tileBg, rowHover.hovered, false, false, ch.acc)
        Behavior on color { ColorAnimation { duration: Motion.fast } }
    }
    Item {
        anchors.fill: parent; anchors.margins: 10 * ch.s
        Icon {
            id: icon
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.topMargin: 1 * ch.s
            name: ch.muted || ch.vol < 0.01 ? "volume-off" : ch.vol < 0.34 ? "volume-low" : ch.vol < 0.67 ? "volume-mid" : "volume-high"
            size: 14 * ch.s
            color: ch.muted ? Theme.dangerText : Theme.fgVariant
            MouseArea {
                anchors.fill: parent
                anchors.margins: -5 * ch.s
                enabled: ch.ready
                cursorShape: Qt.PointingHandCursor
                onClicked: { ch.picked(); Mixer.toggleMute(ch.node); }
            }
        }
        Text {
            id: name
            anchors.left: icon.right
            anchors.leftMargin: 8 * ch.s
            anchors.right: tag.visible ? tag.left : pct.left
            anchors.rightMargin: 8 * ch.s
            anchors.top: parent.top
            text: ch.title
            color: Theme.fg
            font.family: Typography.ui
            font.pixelSize: Typography.body * ch.s
            elide: Text.ElideRight
        }
        Rectangle {
            id: tag
            visible: ch.recording
            anchors.right: pct.left
            anchors.rightMargin: 8 * ch.s
            anchors.verticalCenter: name.verticalCenter
            width: tagText.implicitWidth + 10 * ch.s
            height: tagText.implicitHeight + 2 * ch.s
            radius: Metrics.pill(height)
            color: Qt.alpha(Theme.dangerText, 0.18)
            Text {
                id: tagText
                anchors.centerIn: parent
                text: "Recording"
                color: Theme.dangerText
                font.family: Typography.ui
                font.pixelSize: Typography.micro * ch.s
                font.weight: Typography.wStrong
            }
        }
        Text {
            anchors.left: name.left
            anchors.right: parent.right
            anchors.top: name.bottom
            anchors.topMargin: 1 * ch.s
            visible: ch.sub.length > 0
            text: ch.sub
            color: Theme.fgVariant
            font.family: Typography.ui
            font.pixelSize: Typography.caption * ch.s
            elide: Text.ElideRight
        }
        Text {
            id: pct
            anchors.right: parent.right
            anchors.top: parent.top
            width: 70 * ch.s
            horizontalAlignment: Text.AlignRight
            text: !ch.ready ? "—" : ch.failed ? "not applied" : ch.muted ? "muted" : Math.round(ch.vol * 100) + " %"
            color: ch.muted || ch.failed ? Theme.dangerText : Theme.fgVariant
            font.family: Typography.mono
            font.pixelSize: Typography.caption * ch.s
        }
        Slider {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 4 * ch.s
            visible: ch.ready
            s: ch.s
            value: ch.vol
            muted: ch.muted
            label: ch.title
            onMoved: (v) => { ch.picked(); Mixer.setVolume(ch.node, v); }
        }
    }

}
