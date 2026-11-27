pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../services"
import "../components"

/**
 * Devices de la Audio UI (antes de la fase 14, en lectura; 14F: cambiar el perfil de una tarjeta).
 * Cambiarlo es una PRUEBA con vuelta atrás (AudioDevices.testProfile → sumi-guard): se elige un
 * perfil (←/→ o sus botones), se ve qué pasará, y Enter o Test lo aplican 15 s con cuenta regresiva
 * en todas las pantallas; sin Keep vuelve el perfil de antes. Pro Audio sólo con Advanced. Por tarjeta: perfil activo y los que ofrece con
 * su disponibilidad, puertos (conectado o no) y sus salidas/entradas con canales y formato. Aparte,
 * los dispositivos virtuales. Los datos son de `AudioDevices` (pw-dump a demanda, sin sondeo).
 *
 * No es un inspector de PipeWire: sólo lo que ayuda a entender por qué suena (o no) una salida.
 */
AudioSection {
    id: root

    readonly property var cards: AudioDevices.cards
    readonly property string defSink: AudioUi.defaultSinkName
    readonly property string defSource: Mixer.defaultSource ? String(Mixer.defaultSource.name) : ""

    contentHeight: col.implicitHeight
    focusList: ["refresh", "advanced"].concat(root.cards.map(c => "card:" + c.id)).concat(AudioDevices.others.length ? ["virtual"] : [])
    /** Lo elegido y aún no probado, por tarjeta: id → nombre de perfil. */
    property var sel: ({})
    function choose(c, name) {
        const t = Object.assign({}, root.sel);
        if (!name || (c.profile && c.profile.name === name)) delete t[c.id]; else t[c.id] = name;
        root.sel = t;
    }
    function chosen(c) { return root.sel[c.id] || (c.profile ? c.profile.name : ""); }
    function test(c) {
        const p = root.sel[c.id];
        if (!p || SystemTest.live || SystemTest.launching) return;
        if (AudioDevices.testProfile(c, p, Hypr.focusedName)) root.choose(c, "");
    }
    onActivate: (id, dir) => {
        if (id === "refresh" && dir === 0) AudioDevices.refresh();
        if (id === "advanced") AudioDevices.advanced = dir === 0 ? !AudioDevices.advanced : dir > 0;
        if (id.indexOf("card:") === 0) {
            const c = root.cards.find(x => "card:" + x.id === id);
            if (!c) return;
            if (dir === 0) { root.test(c); return; }
            const l = AudioDevices.choices(c).map(p => p.name);
            if (l.length === 0) return;
            const i = Math.max(0, l.indexOf(root.chosen(c)));
            root.choose(c, l[((i + dir) % l.length + l.length) % l.length]);
        }
    }

    function nodeLine(n) {
        const role = n.mediaClass === "Audio/Sink" ? "Output" : "Input";
        const def = n.name === root.defSink || n.name === root.defSource ? " · default" : "";
        const fmt = n.rate > 0 ? Math.round(n.rate / 100) / 10 + " kHz " + n.format : n.state;
        return role + def + "  ·  " + (n.position.length ? n.position.join(" ") : n.channels + " ch") + "  ·  " + fmt;
    }

    component Node: Text {
        required property var modelData
        width: parent ? parent.width : 0
        elide: Text.ElideRight
        text: modelData.label + "  —  " + root.nodeLine(modelData)
        color: modelData.name === root.defSink || modelData.name === root.defSource ? Theme.fg : Theme.fgVariant
        font.family: Typography.mono; font.pixelSize: Typography.caption * root.s
    }

    Column {
        id: col
        width: root.width
        spacing: 14 * root.s

        Item {
            width: parent.width
            height: 30 * root.s
            Text {
                anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                anchors.right: advToggle.left; anchors.rightMargin: 10 * root.s
                elide: Text.ElideRight
                text: AudioDevices.error ? AudioDevices.error
                    : !AudioDevices.loaded ? "Reading the audio devices…"
                    : root.cards.length + (root.cards.length === 1 ? " sound card" : " sound cards")
                      + (AudioDevices.others.length ? " · " + AudioDevices.others.length + " virtual" : "")
                      + " · read at " + Clock.fmt(AudioDevices.readAt, true)
                color: AudioDevices.error ? Theme.errorColor : Theme.fgVariant
                font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
            }
            Toggle {
                id: advToggle
                anchors.right: refreshBtn.left; anchors.rightMargin: 10 * root.s
                anchors.verticalCenter: parent.verticalCenter
                s: root.s
                label: "Advanced"
                on: AudioDevices.advanced
                focused: root.focusId === "advanced" && AudioUi.keyNav
                onToggled: { root.pick("advanced"); AudioDevices.advanced = !AudioDevices.advanced; }
            }
            ActionButton {
                id: refreshBtn
                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                s: root.s
                glyph: "reload"
                label: "Refresh"
                focused: root.focusId === "refresh" && AudioUi.keyNav
                onTriggered: { root.pick("refresh"); AudioDevices.refresh(); }
            }
        }

        Empty {
            visible: AudioDevices.loaded && !AudioDevices.error && root.cards.length === 0 && AudioDevices.others.length === 0
            width: parent.width
            s: root.s
            glyph: "speaker"
            text: "No audio devices"
            hint: "No sound card found. Check that it's connected and enabled."
        }

        Repeater {
            model: root.cards
            Rectangle {
                id: cardBox
                required property var modelData
                readonly property var c: cardBox.modelData
                readonly property var avail: cardBox.c.profiles.filter(p => p.name !== "off" && p.available !== "no")
                readonly property var unavail: cardBox.c.profiles.filter(p => p.name !== "off" && p.available === "no")
                readonly property bool focused: root.focusId === "card:" + cardBox.c.id
                onFocusedChanged: if (focused) root.reveal(cardBox)
                width: col.width
                height: body.implicitHeight + 20 * root.s
                radius: Metrics.rSm * root.s
                color: Theme.tileBg
                border.width: 1
                border.color: Theme.hair
                AudioFocus { on: cardBox.focused; s: root.s }
                Column {
                    id: body
                    anchors.left: parent.left; anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 10 * root.s
                    spacing: 4 * root.s
                    Item {
                        width: parent.width
                        height: cTitle.implicitHeight
                        Text {
                            id: cTitle
                            anchors.left: parent.left
                            anchors.right: cKind.left; anchors.rightMargin: 10 * root.s
                            elide: Text.ElideRight
                            text: cardBox.c.label + (cardBox.c.description && cardBox.c.description !== cardBox.c.label ? "  ·  " + cardBox.c.description : "")
                            color: Theme.fg
                            font.family: Typography.ui; font.pixelSize: Typography.body * root.s; font.weight: Typography.wStrong
                        }
                        Text {
                            id: cKind
                            anchors.right: parent.right; anchors.verticalCenter: cTitle.verticalCenter
                            text: [cardBox.c.bus.toUpperCase(), cardBox.c.api, cardBox.c.formFactor, cardBox.c.address].filter(x => x).join(" · ")
                            color: Theme.fgVariant
                            font.family: Typography.mono; font.pixelSize: Typography.micro * root.s
                        }
                    }
                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        text: "Profile  " + (cardBox.c.profile ? (cardBox.c.profile.name === "off" ? "Off (the card is disabled)" : cardBox.c.profile.description) : "—")
                        color: cardBox.c.profile && cardBox.c.profile.name === "off" ? Theme.fgVariant : Theme.fg
                        font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                    }
                    // 14F: elegir otro perfil y probarlo
                    Flow {
                        width: parent.width
                        spacing: 6 * root.s
                        visible: AudioDevices.choices(cardBox.c).length > 1
                        Text {
                            height: 26 * root.s
                            verticalAlignment: Text.AlignVCenter
                            text: "Change to"
                            color: Theme.fgVariant
                            font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                        }
                        Repeater {
                            model: AudioDevices.choices(cardBox.c)
                            ActionButton {
                                required property var modelData
                                s: root.s
                                label: modelData.name === "off" ? "Off" : modelData.description
                                accent: root.chosen(cardBox.c) === modelData.name
                                onTriggered: { root.pick("card:" + cardBox.c.id); root.choose(cardBox.c, modelData.name); }
                            }
                        }
                        ActionButton {
                            s: root.s
                            glyph: "check"
                            label: "Test"
                            primary: true
                            enabled: !!root.sel[cardBox.c.id] && !SystemTest.live && !SystemTest.launching
                                && SystemTest.whyNot("audio-profile").length === 0
                            focused: cardBox.focused && AudioUi.keyNav && !!root.sel[cardBox.c.id]
                            onTriggered: { root.pick("card:" + cardBox.c.id); root.test(cardBox.c); }
                        }
                    }
                    Text {
                        visible: !!root.sel[cardBox.c.id]
                        width: parent.width
                        wrapMode: Text.WordWrap
                        // F2d: sin systemd-run/pactl/playerctl no hay prueba con vuelta atrás: se dice
                        text: SystemTest.whyNot("audio-profile").length > 0
                              ? "Can't test profiles here · " + SystemTest.whyNot("audio-profile")
                              : AudioDevices.consequence(cardBox.c, root.sel[cardBox.c.id] || "")
                                + " · Test applies it for 15 s and it reverts unless you keep it"
                        color: SystemTest.whyNot("audio-profile").length > 0 ? Theme.warn : Theme.fg
                        font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                    }
                    Text {
                        visible: cardBox.focused && AudioUi.keyNav && !root.sel[cardBox.c.id] && AudioDevices.choices(cardBox.c).length > 1
                        width: parent.width
                        text: "← → choose another profile · Enter tests it"
                        color: Theme.fgVariant
                        font.family: Typography.ui; font.pixelSize: Typography.micro * root.s
                    }
                    Text {
                        visible: cardBox.avail.length > 1 || (cardBox.avail.length === 1 && !cardBox.avail[0].active)
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: "Also offers  " + cardBox.avail.filter(p => !p.active).map(p => p.description).join(" · ")
                        color: Theme.fgVariant
                        font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                    }
                    Text {
                        visible: cardBox.unavail.length > 0
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: "Unavailable now  " + cardBox.unavail.length + (cardBox.unavail.length === 1 ? " profile" : " profiles")
                              + " (nothing connected to " + (cardBox.unavail.length === 1 ? "its port" : "their ports") + ")"
                        color: Theme.fgVariant
                        opacity: 0.8
                        font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                    }
                    Text {
                        visible: cardBox.c.routes.length > 0
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: "Ports  " + cardBox.c.routes.map(r => r.description + (r.active ? " (in use)" : r.available === "no" ? " (unplugged)" : "")).join(" · ")
                        color: Theme.fgVariant
                        font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                    }
                    Item { width: 1; height: 2 * root.s }
                    Repeater { model: cardBox.c.nodes; Node {} }
                    Text {
                        visible: cardBox.c.nodes.length === 0
                        text: "No outputs or inputs with this profile"
                        color: Theme.fgVariant
                        font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                    }
                }
            }
        }

        Column {
            visible: AudioDevices.others.length > 0
            width: parent.width
            spacing: 4 * root.s
            MonitorHeading { s: root.s; text: "Virtual devices"; aside: "created by apps or by the system, without a sound card" }
            Item {
                width: parent.width
                height: virt.implicitHeight
                AudioFocus { on: root.focusId === "virtual"; s: root.s }
                Column {
                    id: virt
                    width: parent.width
                    spacing: 3 * root.s
                    Repeater { model: AudioDevices.others; Node {} }
                }
            }
        }

        Text {
            width: parent.width
            wrapMode: Text.WordWrap
            // F2d (visto en pantalla): sin prueba con vuelta atrás, se dice antes de elegir nada
            readonly property string why: SystemTest.whyNot("audio-profile")
            text: (why.length > 0 ? "Profiles can't be tested here · " + why + ". "
                                  : "A new profile is tried for 15 s, then reverts unless you keep it. ")
                + "Ports are not changed here."
            color: why.length > 0 ? Theme.warn : Theme.fgVariant
            font.family: Typography.ui; font.pixelSize: Typography.micro * root.s
        }
    }
}
