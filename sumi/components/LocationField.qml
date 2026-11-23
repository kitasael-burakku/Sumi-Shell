import QtQuick
import "../theme"
import "../services"

/**
 * La ciudad del clima en Settings (rediseño, fase 7D).
 *
 * En reposo: la ciudad elegida («Mexico City, Mexico») o «Not set». Activar la
 * fila (clic o Enter desde `SettingRow`) abre un campo: Enter BUSCA (la única
 * consulta de red de aquí, y sólo cuando se pide), ↑ ↓ eligen un resultado,
 * Enter lo guarda y Esc cancela sin tocar nada. Sin el clima encendido no se
 * busca: la fila lo dice.
 *
 * Los resultados salen de `Weather.search` (geocodificación de Open-Meteo) y se
 * guardan con coordenadas y zona horaria; el ConfigStore valida al escribir.
 */
Item {
    id: root

    property real s: 1
    property var location: ({})
    property bool enabled: true

    property bool editing: false
    property int pick: -1

    function startEdit() {
        if (!root.enabled) return;
        Weather.clearSearch();
        field.text = "";
        root.pick = -1;
        root.editing = true;
        Qt.callLater(function () { field.focusField(); });
    }
    function cancelEdit() {
        root.editing = false;
        Weather.clearSearch();
    }
    function accept() {
        if (Weather.results.length > 0 && root.pick >= 0) {
            Weather.choose(Weather.results[root.pick]);
            root.editing = false;
            return;
        }
        root.pick = -1;
        Weather.search(field.text);
    }

    Connections {
        target: Weather
        function onResultsChanged() { root.pick = Weather.results.length > 0 ? 0 : -1; }
    }

    readonly property string placeText: root.location && root.location.name
        ? root.location.name + (root.location.country ? ", " + root.location.country : "") : "Not set"

    implicitWidth: 210 * s
    implicitHeight: col.implicitHeight

    Column {
        id: col
        width: root.implicitWidth
        spacing: 4 * root.s

        Text {
            visible: !root.editing
            width: parent.width
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
            text: root.placeText
            color: !root.enabled ? Theme.outlineText : (root.location && root.location.name ? Theme.fgVariant : Theme.outlineText)
            font.family: Typography.ui
            font.pixelSize: Typography.label * root.s
        }

        Rectangle {
            visible: root.editing
            width: parent.width
            height: 26 * root.s
            radius: Metrics.r(8) * root.s
            color: Theme.tileBg
            border.width: 1
            border.color: Qt.alpha(Theme.primary, 0.45)

            SearchField {
                id: field
                anchors.fill: parent
                anchors.leftMargin: 8 * root.s
                anchors.rightMargin: 8 * root.s
                s: root.s
                placeholder: "City name, then Enter"
                onAccepted: root.accept()
                onDismissed: root.cancelEdit()
                onMoved: (delta) => {
                    const n = Weather.results.length;
                    if (n > 0) root.pick = Math.max(0, Math.min(n - 1, root.pick + delta));
                }
                // Escribir otra vez invalida la lista vieja: Enter vuelve a buscar.
                onTextChanged: if (Weather.results.length > 0) { Weather.clearSearch(); root.pick = -1; }
            }
        }

        Text {
            visible: root.editing && Weather.searchState !== "ok"
            width: parent.width
            wrapMode: Text.Wrap
            text: Weather.searchState === "searching" ? "Searching…"
                : Weather.searchState === "empty" ? "No places found"
                : Weather.searchState === "error" ? Weather.searchError
                : "Enter searches · Esc cancels"
            color: Weather.searchState === "error" ? Theme.errorColor : Theme.outlineText
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }

        Repeater {
            model: root.editing ? Weather.results : []
            Rectangle {
                id: res
                required property var modelData
                required property int index
                width: col.width
                height: resText.implicitHeight + 8 * root.s
                radius: Metrics.r(6) * root.s
                color: root.pick === res.index ? Qt.alpha(Theme.primary, 0.12) : (resArea.containsMouse ? Theme.tileBg : "transparent")
                border.width: root.pick === res.index ? Metrics.focusWidth : 0
                border.color: Qt.alpha(Theme.primary, 0.65)
                Text {
                    id: resText
                    x: 6 * root.s
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 12 * root.s
                    elide: Text.ElideRight
                    text: res.modelData.name + (res.modelData.admin ? ", " + res.modelData.admin : "")
                          + (res.modelData.country ? " · " + res.modelData.country : "")
                    color: Theme.fg
                    font.family: Typography.ui
                    font.pixelSize: Typography.label * root.s
                }
                MouseArea {
                    id: resArea
                    Accessible.role: Accessible.ListItem
                    Accessible.name: resText.text
                    Accessible.onPressAction: { Weather.choose(res.modelData); root.editing = false; }
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { Weather.choose(res.modelData); root.editing = false; }
                }
            }
        }
    }
}
