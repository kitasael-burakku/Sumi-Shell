pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../services"
import "../components"

/**
 * Accounts & sync del calendario local (2026-10-28), en la columna de la agenda de Calendar UI.
 * Sólo vista: el estado y las llamadas viven en `CalendarSync`.
 *
 * - Estado general y **Sync now**; sin red, «Offline» con la última sincronización buena.
 * - **Conflictos**: cada uno con su versión de aquí y la del servidor, y la decisión del usuario:
 *   quedarse con la mía, con la del servidor o con las dos. Un borrado sólo admite dos salidas.
 * - «On this computer» y los calendarios de cada cuenta, con su visibilidad; cada cuenta con su
 *   intervalo (Manual, 15, 30, 60 min) y **Remove from this computer** (pregunta; el servidor no
 *   se toca).
 * - **Add account**: dirección, usuario, contraseña (al llavero, nunca a disco aquí) e intervalo.
 */
Item {
    id: root

    property real s: 1
    property string removing: ""
    property string url: ""
    property string username: ""
    property string password: ""
    property string interval: "30"
    property bool formOpen: CalendarSync.accounts.length === 0

    function focusFirst() { if (root.formOpen) urlField.focusField(); }
    function when(iso) {
        if (!iso) return "never";
        const d = new Date(iso);
        if (isNaN(d.getTime())) return "Unknown time";
        return Qt.formatDateTime(d, Settings.clockFormat === "12h" ? "ddd d MMM, h:mm AP" : "ddd d MMM, HH:mm");
    }
    /** The helper provides a civil date/time, not a UTC timestamp. Keep its clock values. */
    function conflictWhen(raw) {
        const text = String(raw || "");
        if (!text) return "Time unavailable";
        const m = /^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2}))?$/.exec(text);
        if (!m) return text;
        const y = Number(m[1]), month = Number(m[2]), day = Number(m[3]);
        const d = new Date(2000, 0, 1, 12, 0);
        d.setFullYear(y, month - 1, day);
        if (y < 1 || d.getFullYear() !== y || d.getMonth() !== month - 1 || d.getDate() !== day) return text;
        const date = Qt.formatDate(d, "ddd d MMM yyyy");
        if (m[4] === undefined) return date + " · All day";
        const hour = Number(m[4]), minute = Number(m[5]);
        if (hour > 23 || minute > 59) return text;
        const time = Settings.clockFormat === "12h"
            ? (hour % 12 || 12) + ":" + m[5] + " " + (hour < 12 ? (Qt.locale().amText || "AM") : (Qt.locale().pmText || "PM"))
            : m[4] + ":" + m[5];
        return date + " · " + time;
    }

    /** Presentation only: preserve the original helper error for diagnosis. */
    function errorText(raw) {
        const text = String(raw || "");
        if (/CERTIFICATE_VERIFY_FAILED|certificate verify failed|hostname mismatch/i.test(text))
            return "The server's secure connection could not be verified.";
        if (/timed out|timeout/i.test(text)) return "The server took too long to respond.";
        if (/Name or service not known|Temporary failure in name resolution|getaddrinfo failed|nodename nor servname/i.test(text))
            return "The server address could not be resolved.";
        if (/Connection refused/i.test(text)) return "The server is not accepting connections.";
        if (/Network is unreachable|No route to host/i.test(text)) return "The network cannot reach the server.";
        if (/HTTP 5[0-9][0-9]\b/.test(text)) return "The server could not complete the request. Try again later.";
        if (/^Offline:|^Could not reach the server:/i.test(text)) return "The server could not be reached.";
        return text;
    }
    property bool technicalOpen: false
    readonly property var technicalLines: {
        const out = [];
        function add(label, raw) {
            if (raw && root.errorText(raw) !== raw) out.push(label + ": " + raw);
        }
        for (const account of CalendarSync.accounts) add(account.name, account.lastError);
        add("Accounts", CalendarSync.panelError);
        add("Add account", CalendarSync.addError ? CalendarSync.addError.message : "");
        if (CalendarSync.accounts.length > 0 && !CalendarSync.accounts.some(a => a.lastError === CalendarSync.lastResult))
            add("Sync", CalendarSync.lastResult);
        return out;
    }
    onVisibleChanged: if (!root.visible) root.technicalOpen = false

    function submit() {
        if (CalendarSync.addAccount(root.url.trim(), root.username.trim(), root.password, root.interval)) root.password = "";
    }
    readonly property var kinds: ({
        changed_both: { label: "Changed here and on the server", here: "Keep mine", there: "Keep the server's", both: "Keep both" },
        exists_there: { label: "Already on the server with other content", here: "Keep mine", there: "Keep the server's", both: "Keep both" },
        deleted_here_changed_there: { label: "Deleted here, changed on the server", here: "Delete it there too", there: "Keep the server's", both: "" },
        deleted_there_changed_here: { label: "Deleted on the server, changed here", here: "Keep mine (upload again)", there: "Delete it here too", both: "" }
    })

    Flickable {
        id: flick
        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
        anchors.bottom: footer.top; anchors.bottomMargin: 8 * root.s
        contentWidth: width; contentHeight: col.implicitHeight + 4 * root.s
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height + 1

        Column {
            id: col
            width: flick.width - 10 * root.s
            spacing: 12 * root.s

            Item {
                width: parent.width
                height: Math.max(syncBtn.implicitHeight, head.implicitHeight)
                Column {
                    id: head
                    anchors.left: parent.left; anchors.right: syncBtn.left; anchors.rightMargin: 10 * root.s
                    spacing: 2 * root.s
                    Text {
                        text: "Accounts & sync"
                        color: Theme.fg
                        font.family: Typography.ui; font.pixelSize: Typography.title * root.s; font.weight: Font.DemiBold
                    }
                    Text {
                        width: parent.width
                        wrapMode: Text.Wrap
                        text: CalendarSync.syncing ? "Syncing…"
                            : CalendarSync.offline && CalendarSync.accounts.length > 0 ? "Offline · changes stay here until the server is reachable"
                            : CalendarSync.lastResult.length > 0 ? root.errorText(CalendarSync.lastResult)
                            : CalendarSync.accounts.length === 0 ? "No accounts · everything stays on this computer" : "Ready"
                        color: CalendarSync.conflicts.length > 0 ? Theme.warn : Theme.fgVariant
                        font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                    }
                }
                ActionButton {
                    id: syncBtn
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    s: root.s; glyph: "reload"; accent: true
                    label: CalendarSync.syncing ? "Syncing…" : "Sync now"
                    enabled: !CalendarSync.syncing && CalendarSync.accounts.length > 0
                    onTriggered: CalendarSync.sync("")
                }
            }

            Notice {
                width: parent.width
                visible: CalendarSync.panelError.length > 0
                s: root.s; tone: "danger"
                text: root.errorText(CalendarSync.panelError)
            }

            Column {
                width: parent.width
                spacing: 6 * root.s
                visible: root.technicalLines.length > 0
                ActionButton {
                    s: root.s
                    glyph: root.technicalOpen ? "close" : "info"
                    label: root.technicalOpen ? "Hide technical details" : "Technical details"
                    onTriggered: root.technicalOpen = !root.technicalOpen
                }
                Text {
                    width: parent.width
                    visible: root.technicalOpen
                    text: root.technicalLines.join("\n\n")
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    color: Theme.outlineText
                    font.family: Typography.mono; font.pixelSize: Typography.caption * root.s
                }
            }

            // ---- conflictos ----
            Repeater {
                model: CalendarSync.conflicts
                Rectangle {
                    id: conf
                    required property var modelData
                    readonly property var k: root.kinds[conf.modelData.kind] || root.kinds.changed_both
                    width: col.width
                    height: confCol.implicitHeight + 20 * root.s
                    radius: Metrics.rSm * root.s
                    color: Qt.alpha(Theme.warn, 0.10)
                    border.width: 1
                    border.color: Qt.alpha(Theme.warn, 0.45)
                    Column {
                        id: confCol
                        x: 12 * root.s; y: 10 * root.s
                        width: parent.width - 24 * root.s
                        spacing: 6 * root.s
                        Text {
                            width: parent.width
                            text: "“" + conf.modelData.title + "” · " + conf.modelData.calendar
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            color: Theme.fg
                            font.family: Typography.ui; font.pixelSize: Typography.body * root.s; font.weight: Font.DemiBold
                        }
                        Text {
                            width: parent.width
                            text: conf.k.label
                            wrapMode: Text.Wrap
                            color: Theme.warn
                            font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                        }
                        Text {
                            width: parent.width
                            textFormat: Text.PlainText
                            wrapMode: Text.Wrap
                            text: "Here: " + (conf.modelData.local ? conf.modelData.local.title + "  ·  " + root.conflictWhen(conf.modelData.local.when) : "deleted")
                                + "\nServer: " + (conf.modelData.remote ? conf.modelData.remote.title + "  ·  " + root.conflictWhen(conf.modelData.remote.when) : "deleted")
                            color: Theme.fgVariant
                            font.family: Typography.mono; font.pixelSize: Typography.caption * root.s
                        }
                        Flow {
                            width: parent.width
                            spacing: 6 * root.s
                            ActionButton { s: root.s; label: conf.k.here; accent: true; onTriggered: CalendarSync.resolve(conf.modelData.id, "local") }
                            ActionButton { s: root.s; label: conf.k.there; onTriggered: CalendarSync.resolve(conf.modelData.id, "remote") }
                            ActionButton { visible: conf.k.both.length > 0; s: root.s; label: conf.k.both; onTriggered: CalendarSync.resolve(conf.modelData.id, "both") }
                        }
                    }
                }
            }

            // ---- calendarios ----
            Text {
                text: "Calendars"
                color: Theme.fg
                font.family: Typography.ui; font.pixelSize: Typography.body * root.s; font.weight: Font.DemiBold
            }
            CalendarRow {
                s: root.s
                width: col.width
                name: CalendarSync.local.name
                detail: "Local · never uploaded unless you move an event to an account"
                shown: CalendarSync.local.visible !== false
                onToggled: CalendarSync.setVisible("local", !shown)
            }
            Repeater {
                model: CalendarSync.accounts
                Column {
                    id: acc
                    required property var modelData
                    width: col.width
                    spacing: 6 * root.s
                    Rectangle { width: parent.width; height: 1; color: Theme.hair }
                    Item {
                        width: parent.width
                        height: Math.max(accHead.implicitHeight, everyChoice.implicitHeight)
                        Column {
                            id: accHead
                            anchors.left: parent.left; anchors.right: everyChoice.left; anchors.rightMargin: 8 * root.s
                            spacing: 2 * root.s
                            Text {
                                width: parent.width
                                text: acc.modelData.name
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                color: Theme.fg
                                font.family: Typography.ui; font.pixelSize: Typography.label * root.s; font.weight: Font.DemiBold
                            }
                            Text {
                                width: parent.width
                                text: acc.modelData.lastError.length > 0
                                    ? root.errorText(acc.modelData.lastError) + " · last good sync " + root.when(acc.modelData.lastOk)
                                    : "Synced " + root.when(acc.modelData.lastSync)
                                wrapMode: Text.Wrap
                                textFormat: Text.PlainText
                                color: acc.modelData.lastError.length > 0 ? Theme.warn : Theme.outlineText
                                font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                            }
                        }
                        Choice {
                            id: everyChoice
                            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                            s: root.s; name: "Sync every"
                            options: [{ label: "Manual", value: 0 }, { label: "15 min", value: 15 }, { label: "30 min", value: 30 }, { label: "1 h", value: 60 }]
                            value: acc.modelData.interval
                            onPicked: v => CalendarSync.setInterval(acc.modelData.id, v)
                        }
                    }
                    Repeater {
                        model: acc.modelData.calendars
                        CalendarRow {
                            required property var modelData
                            s: root.s
                            width: acc.width
                            name: modelData.name
                            color_: modelData.color
                            detail: modelData.events + (modelData.events === 1 ? " event" : " events")
                                + (modelData.pending > 0 ? " · " + modelData.pending + " to upload" : "")
                                + (modelData.conflicts > 0 ? " · " + modelData.conflicts + " in conflict" : "")
                                + (modelData.readOnly ? " · read-only" : "")
                            shown: modelData.visible
                            onToggled: CalendarSync.setVisible(modelData.id, !modelData.visible)
                        }
                    }
                    Item {
                        width: parent.width
                        height: removeRow.implicitHeight
                        Flow {
                            id: removeRow
                            width: parent.width
                            spacing: 6 * root.s
                            ActionButton {
                                visible: root.removing !== acc.modelData.id
                                s: root.s; glyph: "delete"; label: "Remove from this computer"
                                onTriggered: root.removing = acc.modelData.id
                            }
                            Text {
                                visible: root.removing === acc.modelData.id
                                width: parent.width
                                wrapMode: Text.Wrap
                                text: "Remove “" + acc.modelData.name + "” and its copies from this computer? The server keeps everything."
                                    + (acc.modelData.calendars.some(c => c.pending > 0) ? " Changes not uploaded yet will be lost." : "")
                                color: Theme.fg
                                font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                            }
                            ActionButton { visible: root.removing === acc.modelData.id; s: root.s; label: "Cancel"; accent: true; onTriggered: root.removing = "" }
                            ActionButton {
                                visible: root.removing === acc.modelData.id
                                s: root.s; label: "Remove"; danger: true; glyph: "delete"
                                onTriggered: { CalendarSync.removeAccount(acc.modelData.id); root.removing = ""; }
                            }
                        }
                    }
                }
            }

            // ---- alta ----
            Rectangle { width: parent.width; height: 1; color: Theme.hair }
            ActionButton {
                visible: !root.formOpen
                s: root.s; glyph: "plus"; accent: true; label: "Add a CalDAV account"
                onTriggered: { root.formOpen = true; Qt.callLater(() => urlField.focusField()); }
            }
            Column {
                width: parent.width
                spacing: 10 * root.s
                visible: root.formOpen
                Text {
                    text: "Add a CalDAV account"
                    color: Theme.fg
                    font.family: Typography.ui; font.pixelSize: Typography.body * root.s; font.weight: Font.DemiBold
                }
                Notice {
                    width: parent.width
                    visible: CalendarSync.addError !== null
                    s: root.s; tone: "danger"
                    text: CalendarSync.addError ? root.errorText(CalendarSync.addError.message) : ""
                }
                FormField {
                    id: urlField
                    width: parent.width
                    s: root.s; mono: true
                    label: "Server address"
                    placeholder: "https://dav.example.org/"
                    hint: "https:// (plain http only on this computer)"
                    value: root.url
                    error: CalendarSync.addError && CalendarSync.addError.field === "url" ? " " : ""
                    readOnly: CalendarSync.adding
                    onEdited: text => root.url = text
                    onTabbed: back => (back ? passField : userField).focusField()
                    onSubmitted: root.submit()
                }
                FormField {
                    id: userField
                    width: parent.width
                    s: root.s
                    label: "User name"
                    value: root.username
                    readOnly: CalendarSync.adding
                    onEdited: text => root.username = text
                    onTabbed: back => (back ? urlField : passField).focusField()
                    onSubmitted: root.submit()
                }
                FormField {
                    id: passField
                    width: parent.width
                    s: root.s; secret: true
                    label: "Password"
                    hint: "Saved in the system keyring, never in the calendar files"
                    value: root.password
                    error: CalendarSync.addError && CalendarSync.addError.field === "password" ? " " : ""
                    readOnly: CalendarSync.adding
                    onEdited: text => root.password = text
                    onTabbed: back => (back ? userField : urlField).focusField()
                    onSubmitted: root.submit()
                }
                Item {
                    width: parent.width
                    height: Math.max(addEvery.implicitHeight, everyLabel.implicitHeight, Metrics.hitMin * root.s)
                    Text {
                        id: everyLabel
                        anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                        text: "Sync every"
                        color: Theme.fgVariant
                        font.family: Typography.ui; font.pixelSize: Typography.caption * root.s; font.weight: Font.DemiBold
                    }
                    Choice {
                        id: addEvery
                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        s: root.s; name: "Sync every"
                        options: [{ label: "Manual", value: "0" }, { label: "15 min", value: "15" }, { label: "30 min", value: "30" }, { label: "1 h", value: "60" }]
                        value: root.interval
                        onPicked: v => root.interval = v
                    }
                }
                Flow {
                    width: parent.width
                    spacing: 6 * root.s
                    ActionButton {
                        s: root.s; primary: true; glyph: "check"
                        label: CalendarSync.adding ? "Connecting…" : "Connect"
                        enabled: !CalendarSync.adding && root.url.trim().length > 0 && root.username.trim().length > 0 && root.password.length > 0
                        onTriggered: root.submit()
                    }
                    ActionButton {
                        visible: CalendarSync.accounts.length > 0
                        s: root.s; label: "Cancel"
                        enabled: !CalendarSync.adding
                        onTriggered: { root.password = ""; root.formOpen = false; CalendarSync.addError = null; }
                    }
                }
            }
        }
    }
    ScrollHint { view: flick; s: root.s; visible: flick.interactive }

    Item {
        id: footer
        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
        height: Math.max(back.implicitHeight, 36 * root.s)
        Rectangle { width: parent.width; height: 1; color: Theme.hair }
        ActionButton {
            id: back
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            s: root.s; glyph: "chevron-left"; label: "Back to the agenda"
            enabled: !CalendarSync.adding
            onTriggered: { root.password = ""; CalendarSync.close(); }
        }
    }

    Connections {
        target: CalendarSync
        function onAccountsChanged() { if (CalendarSync.accounts.length > 0 && !CalendarSync.adding && CalendarSync.addError === null) root.formOpen = false; }
    }
}
