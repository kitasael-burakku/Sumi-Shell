import QtQuick

/** La pausa de lectura empieza después de que se vea la llegada, incluso en Slower. */
Timer {
    id: cycle
    required property bool playing
    required property int openMs
    required property int closeMs
    property bool opened: true
    property bool first: true
    running: playing
    repeat: true
    interval: first ? 320 : opened ? openMs + 720 : closeMs + 320
    onTriggered: { first = false; opened = !opened; }
    onPlayingChanged: if (!playing) { first = true; opened = true; }
}
