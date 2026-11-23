pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "../theme"
import "../services"
import "../components"

/**
 * Journal de un servicio, superficie propia (Fase 10.c).
 *
 * La ficha (`serviceDetail`) tiene una vista previa de las últimas líneas; esto
 * muestra el journal entero con tope, envuelto (una línea `… Failed with result
 * …` cortada no dice nada) y tintado por nivel.
 *
 * EN VIVO (QS-FUNC-007, decisión del usuario del 2026-09-14, que revierte la del
 * 10-09): `journalctl -f` mientras esta superficie o la ficha lo reclaman,
 * empezando por las últimas 200 líneas y con tope de `Units.journalCap`. Es el
 * caso de uso que antes no funcionaba: reiniciar la unidad y quedarse mirando
 * si arranca bien.
 *
 * Altura fija; el `ListView` desplaza por dentro.
 *
 * 11F-1: por CLAVE (ámbito + unidad) — el journal de una unidad de sistema es el del sistema. Sin
 * permiso para leerlo dice **Permission required** (nunca «No entries»). Si subes, la vista se
 * queda donde estás aunque entren líneas y aparece **Resume live** (End) para volver al final; y
 * **Copy** (C) copia lo que hay. Las líneas nuevas nunca roban el foco.
 */
Surface {
    id: root

    mTop: 12
    mLeft: 14
    mRight: 14
    mBottom: 12

    signal requestSurface(string name)

    /**
     * La unidad de ESTA pantalla (core/SurfaceHost §`sel`). El seguidor
     * (`journalctl -f`) sigue siendo **uno solo** y lo posee quien abrio el
     * ultimo: si esta pantalla no es la duena, se dice, en vez de pintar las
     * lineas de otra unidad como si fueran suyas (decision del usuario,
     * 2026-09-22).
     */
    property string sel: ""
    readonly property string ukey: root.sel.length > 0 ? Units.normKey(root.sel) : Units.journalKey
    readonly property var parsed: Units.parseKey(root.ukey)
    readonly property string unit: root.parsed.unit
    readonly property bool owns: root.ukey === Units.journalKey && root.ukey.length > 0

    /** Clave con el monitor; vacía mientras se construye y entonces no se reclama (QS-FUNC-003). */
    readonly property string claimKey: root.screenName.length > 0 ? "serviceJournal@" + root.screenName : ""
    /**
     * La unidad se carga ANTES de reclamar: si no, la reclamación arrancaría el
     * seguidor con la unidad vieja y `loadJournal` lo reiniciaría. Por eso el
     * `Claim` sigue a `following`, que se sube después de cargar.
     */
    property bool following: false
    function follow(on) {
        if (on && root.unit.length > 0)
            Units.loadJournal(root.ukey);   // idempotente si ya la sigue
        root.following = on;
    }
    Claim { target: Units; method: "claimJournal"; key: root.claimKey; value: root.following }

    onActiveChanged: {
        root.follow(root.active);
        if (root.active) root.stick = true;
    }
    Component.onCompleted: root.follow(root.active)

    /**
     * PEGADO AL FINAL, sólo si ya estabas al final. Con líneas entrando en vivo,
     * saltar abajo en cada lote te arrancaría de lo que estás leyendo si subiste.
     */
    property bool stick: true

    function rebuild() {
        jmodel.clear();
        jmodel.append(Units.journalLines.map(function (l) { return { line: l }; }));
    }

    /** Volver a donde se vino (la pila del host, QS-FUNC-004). */
    function back() {
        root.requestBack();
    }

    /** Para el IPC (`unitJournalState`). */
    function stateInfo() {
        return { key: root.ukey, owns: root.owns, stick: root.stick, permission: Units.journalPermission,
                 busy: Units.journalBusy, lines: Units.journalLines.length, following: Units.journalFollowing,
                 atEnd: jlist.atYEnd, contentY: Math.round(jlist.contentY) };
    }

    /** Resume live: al final y pegado otra vez. */
    function resumeLive() {
        root.stick = true;
        jlist.positionViewAtEnd();
    }
    property double copiedAt: 0
    function copyAll() {
        if (!root.owns || Units.journalLines.length === 0) return;
        Quickshell.clipboardText = Units.journalLines.join("\n");
        root.copiedAt = Date.now();
        copiedReset.restart();
    }
    Timer { id: copiedReset; interval: 2000; onTriggered: root.copiedAt = 0 }

    function keyPressed(event) {
        if (event.key === Qt.Key_Escape) { root.back(); event.accepted = true; return; }
        if (event.key === Qt.Key_End) { root.resumeLive(); event.accepted = true; return; }
        if (event.key === Qt.Key_C && !(event.modifiers & Qt.ControlModifier)) { root.copyAll(); event.accepted = true; return; }
        if (event.key === Qt.Key_PageUp) {
            jlist.contentY = Math.max(jlist.originY, jlist.contentY - jlist.height * 0.9);
            root.stick = false; event.accepted = true; return;
        }
        if (event.key === Qt.Key_PageDown) {
            jlist.contentY = Math.min(jlist.contentHeight + jlist.originY - jlist.height, jlist.contentY + jlist.height * 0.9);
            Qt.callLater(function () { root.stick = jlist.atYEnd; });
            event.accepted = true; return;
        }
        if (event.key === Qt.Key_Up) {
            jlist.contentY = Math.max(jlist.originY, jlist.contentY - 60 * root.s);
            root.stick = false;
            event.accepted = true;
        } else if (event.key === Qt.Key_Down) {
            jlist.contentY += 60 * root.s;
            if (jlist.contentY >= jlist.contentHeight + jlist.originY - jlist.height)
                jlist.positionViewAtEnd();
            Qt.callLater(function () { root.stick = jlist.atYEnd; });
            event.accepted = true;
        }
    }

    function jColor(l) {
        const s = l.toLowerCase();
        if (s.indexOf("error") >= 0 || s.indexOf("failed") >= 0 || s.indexOf("fatal") >= 0)
            return Theme.errorColor;
        if (s.indexOf("warn") >= 0) return Theme.secondary;
        return Theme.fgVariant;
    }

    // ---- cabecera --------------------------------------------------------

    Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 22 * root.s

        Icon {
            id: backIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            name: "chevron-left"
            size: 14 * root.s
            color: backArea.containsMouse ? Theme.fg : Theme.fgVariant
            Behavior on color { ColorAnimation { duration: Motion.fast } }
            MouseArea {
                id: backArea
                Accessible.role: Accessible.Button
                Accessible.name: "Back"
                Accessible.onPressAction: root.back()
                anchors.fill: parent
                anchors.margins: -6 * root.s
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.back()
            }
        }
        Text {
            anchors.left: backIcon.right
            anchors.leftMargin: 8 * root.s
            anchors.right: tag.left
            anchors.rightMargin: 8 * root.s
            anchors.verticalCenter: parent.verticalCenter
            text: root.unit
            elide: Text.ElideMiddle
            color: Theme.fg
            font.family: Typography.ui
            font.pixelSize: Typography.body * root.s
            font.weight: Font.DemiBold
        }
        Text {
            id: tag
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: (root.parsed.scope === "system" ? "system · " : "user · ")
                + (Units.journalBusy ? "reading…"
                   : Units.journalPermission && root.owns ? "no access"
                   : Units.journalFollowing ? (root.stick ? "journal · live" : "journal · paused view") : "journal")
            color: Theme.outlineText
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }
    }

    // el pie: alto fijo, con la ayuda a la izquierda y los botones a la derecha
    Item {
        id: footer
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 24 * root.s
    }

    Text {
        id: hint
        anchors.verticalCenter: footer.verticalCenter
        anchors.left: parent.left
        anchors.right: jButtons.left
        anchors.rightMargin: 8 * root.s
        elide: Text.ElideRight
        height: 13 * root.s
        verticalAlignment: Text.AlignVCenter
        text: root.stick ? "↑↓ PgUp PgDn scroll   C copy   Esc · back"
            : "End · resume live   ↑↓ scroll   C copy   Esc · back"
        color: Theme.fgVariant
        font.family: Typography.ui
        font.pixelSize: Typography.caption * root.s
    }

    Row {
        id: jButtons
        anchors.verticalCenter: footer.verticalCenter
        anchors.right: parent.right
        spacing: 6 * root.s
        ActionButton {
            visible: !root.stick && root.owns
            s: root.s
            label: "Resume live"
            primary: true
            onTriggered: root.resumeLive()
        }
        ActionButton {
            visible: root.owns && Units.journalLines.length > 0
            s: root.s
            label: root.copiedAt > 0 ? "Copied" : "Copy"
            onTriggered: root.copyAll()
        }
    }

    Rectangle {
        anchors.top: header.bottom
        anchors.topMargin: 6 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        anchors.bottomMargin: 6 * root.s
        radius: Metrics.r(8) * root.s
        color: Theme.tileBg
        clip: true

        Empty {
            anchors.centerIn: parent
            visible: !root.owns || Units.journalBusy || Units.journalPermission || Units.journalLines.length === 0
            s: root.s
            maxWidth: parent.width - 16 * root.s
            loading: root.owns && Units.journalBusy
            glyph: root.owns && Units.journalPermission ? "lock" : "history"
            // Sin la propiedad del seguidor no se pintan lineas: serian de otra
            // unidad. Mismo criterio que la previsualizacion de `ServiceDetail`.
            text: !root.owns ? "Journal is following " + Units.journalKey
                : Units.journalBusy ? "Reading journal…"
                : Units.journalPermission ? "Permission required"
                : "No entries yet"
            hint: !root.owns ? "Only one live log at a time: the last card opened has it"
                : Units.journalBusy ? ""
                : Units.journalPermission ? "This account cannot read the " + root.parsed.scope + " journal (groups wheel, adm or systemd-journal can)"
                : "Nothing logged since the unit started"
        }

        /**
         * `ListView`, no `Column`+`Repeater`: virtualiza las líneas (delegado de
         * alto variable por el envuelto). Anclado en un rectángulo de alto fijo,
         * no alimenta ningún `implicitHeight` — no reabre 9.f.2.
         *
         * Modelo propio, no `Units.journalLines`: reasignar un array JS de
         * modelo reinicia la vista y la devuelve arriba en cada lote en vivo, y
         * al llegar al tope el `count` ya no cambia. Aquí sólo se añade por el
         * final y se recorta por el principio.
         */
        ListModel { id: jmodel }

        Connections {
            target: Units
            function onJournalReset() { jmodel.clear(); }
            function onJournalAppended(lines, dropped) {
                jmodel.append(lines.map(function (l) { return { line: l }; }));
                if (dropped > 0)
                    jmodel.remove(0, Math.min(dropped, jmodel.count));
                if (jmodel.count !== Units.journalLines.length)
                    root.rebuild();   // por si algo se desincronizó: la verdad es el servicio
                if (root.stick)
                    Qt.callLater(jlist.positionViewAtEnd);
            }
        }

        ListView {
            id: jlist
            anchors.fill: parent
            anchors.margins: 8 * root.s
            visible: root.owns && !Units.journalBusy && !Units.journalPermission
            model: jmodel
            boundsBehavior: Flickable.StopAtBounds
            clip: true
            cacheBuffer: 400
            onMovementEnded: root.stick = jlist.atYEnd
            Component.onCompleted: {
                root.rebuild();   // la ficha pudo dejar el journal ya siguiéndose
                Qt.callLater(jlist.positionViewAtEnd);
            }

            delegate: Text {
                required property string line
                width: jlist.width
                text: line
                wrapMode: Text.Wrap
                color: root.jColor(line)
                font.family: Typography.mono
                font.pixelSize: Typography.caption * root.s
            }
        }

        /**
         * La barra de desplazamiento (2026-09-15). Hermana de la lista, no hija:
         * un hijo de un `ListView` viaja dentro del contenido y se iria con el
         * scroll.
         *
         * Y **dentro del mismo padre que la lista**: `ScrollHint` se ancla a
         * `view`, asi que colgando de la superficie no era ni padre ni hermano
         * del `ListView` y Qt se negaba a anclarlo -- «Cannot anchor to an item
         * that isn't a parent or sibling», tres veces al abrir, y la barra no se
         * pintaba. Las otras diez superficies ya lo tenian bien; esta se quedo
         * fuera porque aqui la lista vive dentro del recuadro. Visto al abrir
         * las 24 superficies seguidas el 2026-09-21.
         */
        ScrollHint { view: jlist; s: root.s }
    }

}
