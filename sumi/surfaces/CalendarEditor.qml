pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../services"
import "../components"

/**
 * El formulario de un evento local de Calendar UI (2026-10-27). Sólo vista: el borrador,
 * guardar y los errores viven en `CalendarEdit`, así que cerrar la tarjeta o moverla de
 * monitor no pierde lo escrito.
 *
 * Campos: título, todo el día, inicio/fin (fecha AAAA-MM-DD y hora HH:MM, en la zona del
 * evento) o primer/último día, zona IANA y notas. Las fechas y horas se escriben; ↑ ↓
 * suman un día o 15 minutos, y al mover el inicio así el fin conserva la duración.
 *
 * Teclado: Tab/⇧Tab recorren los campos; Ctrl+S o Ctrl+Intro guardan; Esc cancela
 * (con cambios, pregunta: «Keep editing» primero, ← → lo cambian, Intro elige).
 *
 * 2026-10-28: **Repeat** (nunca, diario, semanal con sus días, mensual, anual; cada N; hasta
 * una fecha o N veces) y **Reminder** (un aviso; los importados con varios se conservan como
 * «Custom»). En las filas de opción, ← → cambian el valor; en los días, ← → mueven y Espacio
 * marca. Guardar una ocurrencia de una serie pregunta el alcance en el pie.
 */
Item {
    id: root

    property real s: 1
    readonly property var ed: CalendarEdit.editor
    readonly property var f: root.ed ? root.ed.fields : ({})
    readonly property var errs: root.ed ? root.ed.errors : ({})
    readonly property var err: root.ed ? root.ed.error : null
    readonly property bool saving: root.ed !== null && root.ed.saving
    readonly property bool confirming: root.ed !== null && root.ed.confirm === "discard"
    readonly property bool askingScope: root.ed !== null && root.ed.confirm === "scope"
    readonly property bool repeating: (root.f.repeat || "never") !== "never" && root.f.repeat !== "custom"
    /** Calendarios donde se puede escribir (CalDAV, 2026-10-28); con uno solo, la fila no aparece. */
    readonly property var calendarOptions: (Agenda.calendars || []).filter(c => !c.readOnly && (c.visible || c.id === root.f.calendarId))
        .map(c => ({ label: c.kind === "local" ? "On this computer" : c.name, value: c.id }))
    readonly property bool allDay: root.f.allDay === true
    /** Aviso general: lo que no señala un campo concreto (o la hora ambigua, que pide elegir). */
    readonly property bool bannerShown: root.err !== null && (!root.err.field || root.err.code === "ambiguous_time")
    property int confirmIndex: 0

    readonly property var order: {
        const o = [title];
        if (calendarRow.visible) o.push(calendarRow);
        o.push(allDayRow, startDate);
        if (root.allDay) o.push(lastDate);
        else o.push(startTime, endDate, endTime, tz);
        o.push(repeatRow);
        if (root.repeating) {
            o.push(interval);
            if (root.f.repeat === "weekly") o.push(daysRow);
            o.push(untilRow);
            if (root.f.ends === "until") o.push(untilField);
            if (root.f.ends === "count") o.push(countField);
        }
        o.push(reminderRow, notes);
        return o;
    }

    function focusFirst() {
        (root.ed && root.ed.confirm === "discard" ? confirmKeys : root.ed && root.ed.confirm === "scope" ? scopeKeys : title).focusField();
    }

    // ---- filas de opción (Choice) y días -----------------------------------------------------
    function choiceKeys(e, row, choice) {
        const ctrl = (e.modifiers & Qt.ControlModifier) !== 0;
        if (!ctrl && (e.key === Qt.Key_Left || e.key === Qt.Key_Right)) choice.cycle(e.key === Qt.Key_Right ? 1 : -1);
        else if (e.key === Qt.Key_Tab || e.key === Qt.Key_Backtab) root.move(row, e.key === Qt.Key_Backtab || (e.modifiers & Qt.ShiftModifier) !== 0);
        else if (e.key === Qt.Key_Escape) CalendarEdit.requestClose();
        else if (ctrl && (e.key === Qt.Key_S || e.key === Qt.Key_Return || e.key === Qt.Key_Enter)) CalendarEdit.save();
        else return;
        e.accepted = true;
    }
    readonly property var reminderOptions: {
        const base = root.allDay
            ? [{ label: "None", value: "none" }, { label: "09:00 that day", value: "0" }, { label: "09:00 the day before", value: "1440" }]
            : [{ label: "None", value: "none" }, { label: "At the start", value: "0" }, { label: "5 min before", value: "5" },
               { label: "15 min before", value: "15" }, { label: "30 min before", value: "30" }, { label: "1 hour before", value: "60" },
               { label: "1 day before", value: "1440" }];
        if (root.reminderValue === "custom")
            base.push({ label: (root.f.reminders || []).map(m => CalendarEdit.reminderLabel(m, root.allDay)).join(", "), value: "custom" });
        return base;
    }
    readonly property string reminderValue: {
        const r = root.f.reminders || [];
        if (r.length === 0) return "none";
        const known = root.allDay ? ["0", "1440"] : ["0", "5", "15", "30", "60", "1440"];
        return r.length === 1 && known.indexOf(String(r[0])) >= 0 ? String(r[0]) : "custom";
    }
    function pickReminder(v) {
        if (v === "custom") return;
        CalendarEdit.set("reminders", v === "none" ? [] : [Number(v)]);
    }
    readonly property string unitText: {
        const n = Number(root.f.interval) || 1;
        const u = { daily: "day", weekly: "week", monthly: "month", yearly: "year" }[root.f.repeat] || "";
        return u.length === 0 ? "" : (n === 1 ? u : u + "s");
    }

    // ---- la pregunta de alcance (una ocurrencia de una serie) -----------------------------------
    property int scopeIndex: 0
    readonly property var scopes: [
        { label: "This event", scope: "occurrence", enabled: !CalendarEdit.repeatChanged },
        { label: "This and following", scope: "following", enabled: true },
        { label: "All events", scope: "series", enabled: true },
        { label: "Cancel", scope: "", enabled: true }]
    function scopeStep(d) {
        let i = root.scopeIndex;
        for (let n = 0; n < 4; n++) {
            i = (i + d + 4) % 4;
            if (root.scopes[i].enabled) { root.scopeIndex = i; return; }
        }
    }
    function scopeActivate() {
        const sc = root.scopes[root.scopeIndex];
        if (!sc.enabled) return;
        if (sc.scope === "") CalendarEdit.keepEditing();
        else CalendarEdit.save(sc.scope);
    }
    onAskingScopeChanged: if (root.askingScope) { root.scopeIndex = CalendarEdit.repeatChanged ? 1 : 0; scopeKeys.forceActiveFocus(); }
                          else if (root.ed && !root.confirming) Qt.callLater(root.focusFirst)
    function move(from, back) {
        const i = root.order.indexOf(from);
        const n = root.order.length;
        root.order[((i < 0 ? 0 : i) + (back ? n - 1 : 1)) % n].focusField();
    }
    function reveal(item, extra) {
        if (!item || !item.visible) return;
        const p = item.mapToItem(form, 0, 0);
        const top = p.y - 8 * root.s, bottom = p.y + (extra !== undefined ? extra : item.height) + 8 * root.s;
        // Más alto que la vista (notas largas): se enseña su principio; el cursor manda después.
        if (top < flick.contentY || bottom - top > flick.height) flick.contentY = Math.max(0, Math.min(top, flick.contentHeight - flick.height));
        else if (bottom > flick.contentY + flick.height)
            flick.contentY = Math.min(Math.max(0, flick.contentHeight - flick.height), bottom - flick.height);
    }

    onConfirmingChanged: if (root.confirming) { root.confirmIndex = 0; confirmKeys.forceActiveFocus(); }
                         else if (root.ed) Qt.callLater(root.focusFirst)

    // ---- ↑ ↓ en fechas y horas ----------------------------------------------------------
    function parseDate(v) {
        const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(v || "");
        if (!m) return null;
        const d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), 12);
        return d.getMonth() === Number(m[2]) - 1 ? d : null;
    }
    function parseTime(v) {
        const m = /^(\d{2}):(\d{2})$/.exec(v || "");
        return m && Number(m[1]) < 24 && Number(m[2]) < 60 ? Number(m[1]) * 60 + Number(m[2]) : -1;
    }
    /** Minutos de pared desde una época común (sin zona: sólo para conservar la duración). */
    function wall(dv, tv) {
        const d = root.parseDate(dv), t = root.parseTime(tv);
        return d && t >= 0 ? Math.round(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()) / 60000) + t : null;
    }
    function fromWall(w) {
        const d = new Date(Math.floor(w / 1440) * 86400000);
        const t = ((w % 1440) + 1440) % 1440;
        return { date: d.getUTCFullYear() + "-" + CalendarEdit.pad(d.getUTCMonth() + 1) + "-" + CalendarEdit.pad(d.getUTCDate()),
                 time: CalendarEdit.pad(Math.floor(t / 60)) + ":" + CalendarEdit.pad(t % 60) };
    }
    function step(field, delta) {
        if (!root.ed) return;
        const isTime = field === "startTime" || field === "endTime";
        const dateField = field === "startTime" ? "startDate" : field === "endTime" ? "endDate" : field;
        const timeField = field === "startDate" ? "startTime" : field === "endDate" ? "endTime" : field;
        if (root.allDay || field === "lastDate") {
            const d = root.parseDate(root.f[field]);
            if (!d) return;
            d.setDate(d.getDate() + delta);
            CalendarEdit.set(field, CalendarEdit.isoDate(d));
            return;
        }
        const w = root.wall(root.f[dateField], root.f[timeField]);
        if (w === null) return;
        const next = isTime ? Math.round((w + delta * 15) / 15) * 15 : w + delta * 1440;
        const startSide = dateField === "startDate";
        const dur = startSide ? root.wall(root.f.endDate, root.f.endTime) - w : 0;
        const v = root.fromWall(next);
        CalendarEdit.set(dateField, v.date);
        CalendarEdit.set(timeField, v.time);
        if (startSide && dur > 0) {
            const e = root.fromWall(next + dur);
            CalendarEdit.set("endDate", e.date);
            CalendarEdit.set("endTime", e.time);
        }
    }

    // ---- el formulario -------------------------------------------------------------------
    Flickable {
        id: flick
        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
        anchors.bottom: footer.top; anchors.bottomMargin: 8 * root.s
        contentWidth: width; contentHeight: form.implicitHeight + 4 * root.s
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height + 1

        Column {
            id: form
            width: flick.width - 10 * root.s
            spacing: 12 * root.s

            Row {
                width: parent.width
                spacing: 8 * root.s
                Text {
                    id: heading
                    width: Math.min(implicitWidth, parent.width - (draftBadge.visible ? draftBadge.width + 8 * root.s : 0))
                    text: root.ed && root.ed.mode === "edit" ? "Edit event" : "New event"
                    elide: Text.ElideRight
                    color: Theme.fg
                    font.family: Typography.ui
                    font.pixelSize: Typography.title * root.s
                    font.weight: Font.DemiBold
                }
                Rectangle {
                    id: draftBadge
                    visible: root.ed !== null && root.ed.restored
                    anchors.verticalCenter: heading.verticalCenter
                    width: draftText.implicitWidth + 12 * root.s; height: draftText.implicitHeight + 4 * root.s
                    radius: Metrics.rXs * root.s
                    color: Qt.alpha(Theme.warn, 0.16)
                    Text { id: draftText; anchors.centerIn: parent; text: "Draft"; color: Theme.fg; font.family: Typography.ui; font.pixelSize: Typography.caption * root.s; font.weight: Font.DemiBold }
                }
            }
            Text {
                width: parent.width
                text: "Local calendar · saved on this computer" + (root.ed && root.ed.restored ? " · unsaved changes from before" : "")
                wrapMode: Text.Wrap
                color: Theme.fgVariant
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
            }

            // Lo que no es de un campo: base de sólo lectura o dañada, conflicto, borrado, plazo.
            Column {
                width: parent.width
                visible: root.bannerShown
                spacing: 6 * root.s
                Notice {
                    width: parent.width
                    s: root.s
                    tone: root.err && root.err.code === "ambiguous_time" ? "warn" : "danger"
                    // Un fallo de disco o del helper no se lleva lo escrito: se dice.
                    text: !root.err ? "" : root.err.message
                        + (["readonly", "io", "unavailable", "internal", "corrupt", "foreign", "newer_schema"].indexOf(root.err.code) >= 0
                           ? " · your changes are still here" : "")
                }
                Flow {
                    width: parent.width
                    spacing: 6 * root.s
                    Repeater {
                        model: root.err && root.err.code === "ambiguous_time" ? root.err.options || [] : []
                        ActionButton {
                            required property var modelData
                            s: root.s; accent: true; glyph: "clock"
                            label: "Use " + modelData.label
                            onTriggered: CalendarEdit.chooseFold(modelData.fold)
                        }
                    }
                    ActionButton {
                        visible: root.err !== null && root.err.code === "conflict"
                        s: root.s; accent: true; glyph: "reload"
                        label: "Discard mine, load the saved version"
                        onTriggered: CalendarEdit.loadLatest()
                    }
                    ActionButton {
                        visible: root.err !== null && root.err.code === "conflict"
                        s: root.s; glyph: "check"
                        label: "Save mine over it"
                        onTriggered: CalendarEdit.keepMine()
                    }
                    ActionButton {
                        visible: root.err !== null && root.err.code === "not_found"
                        s: root.s; accent: true; glyph: "plus"
                        label: "Save as a new event"
                        onTriggered: CalendarEdit.saveAsNew()
                    }
                }
            }

            FormField {
                id: title
                width: parent.width
                s: root.s
                label: "Title"
                placeholder: "What is it?"
                value: root.f.title || ""
                error: root.errs.title || ""
                maxLength: 200
                readOnly: root.saving
                onEdited: text => CalendarEdit.set("title", text)
                onTabbed: back => root.move(title, back)
                onEscaped: CalendarEdit.requestClose()
                onSubmitted: CalendarEdit.save()
                onFocusedChanged: if (focused) root.reveal(title)
            }

            Item {
                id: calendarRow
                visible: root.calendarOptions.length > 1
                width: parent.width
                height: Math.max(Metrics.hitMin * root.s, calendarLabel.implicitHeight)
                readonly property string label: "Calendar"
                function focusField() { calendarRow.forceActiveFocus(); }
                onActiveFocusChanged: if (activeFocus) root.reveal(calendarRow)
                Accessible.role: Accessible.ComboBox
                Accessible.name: "Calendar"
                Accessible.description: calendarChoice.label
                Keys.onPressed: e => root.choiceKeys(e, calendarRow, calendarChoice)
                Text {
                    id: calendarLabel
                    anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                    text: root.ed && root.ed.mode === "edit" && root.f.calendarId !== root.ed.base.calendarId ? "Calendar · moves the event" : "Calendar"
                    color: calendarRow.activeFocus ? Theme.fg : Theme.fgVariant
                    font.family: Typography.ui; font.pixelSize: Typography.caption * root.s; font.weight: Font.DemiBold
                }
                Choice {
                    id: calendarChoice
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    s: root.s; name: "Calendar"; focused: calendarRow.activeFocus
                    enabled: !root.saving && !(root.ed && root.ed.recurring)
                    optionMaxWidth: 200 * root.s
                    options: root.calendarOptions
                    value: root.f.calendarId || "local"
                    onPicked: v => { calendarRow.forceActiveFocus(); CalendarEdit.set("calendarId", v); }
                }
            }
            Text {
                width: parent.width
                visible: text.length > 0
                text: root.errs.calendarId || ""
                wrapMode: Text.Wrap
                color: Theme.errorColor
                font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
            }

            Item {
                id: allDayRow
                width: parent.width
                height: Math.max(Metrics.hitMin * root.s, allDayLabel.implicitHeight)
                activeFocusOnTab: false
                readonly property string label: "All day"
                function focusField() { allDayRow.forceActiveFocus(); }
                onActiveFocusChanged: if (activeFocus) root.reveal(allDayRow)
                Accessible.role: Accessible.CheckBox
                Accessible.name: "All day"
                Accessible.checkable: true
                Accessible.checked: root.allDay
                Keys.onPressed: e => {
                    const ctrl = (e.modifiers & Qt.ControlModifier) !== 0;
                    if (e.key === Qt.Key_Space || (!ctrl && (e.key === Qt.Key_Return || e.key === Qt.Key_Enter))) CalendarEdit.set("allDay", !root.allDay);
                    else if (e.key === Qt.Key_Tab || e.key === Qt.Key_Backtab) root.move(allDayRow, e.key === Qt.Key_Backtab || (e.modifiers & Qt.ShiftModifier) !== 0);
                    else if (e.key === Qt.Key_Escape) CalendarEdit.requestClose();
                    else if (ctrl && (e.key === Qt.Key_S || e.key === Qt.Key_Return || e.key === Qt.Key_Enter)) CalendarEdit.save();
                    else return;
                    e.accepted = true;
                }
                Toggle {
                    id: allDayToggle
                    anchors.left: parent.left; anchors.leftMargin: 4 * root.s
                    anchors.verticalCenter: parent.verticalCenter
                    s: root.s; on: root.allDay; focused: allDayRow.activeFocus; label: "All day"
                    enabled: !root.saving
                    onToggled: { allDayRow.forceActiveFocus(); CalendarEdit.set("allDay", !root.allDay); }
                }
                Text {
                    id: allDayLabel
                    anchors.left: allDayToggle.right; anchors.leftMargin: 10 * root.s
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.allDay ? "All day · dates only, no time zone" : "All day"
                    elide: Text.ElideRight
                    color: allDayRow.activeFocus ? Theme.fg : Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.label * root.s
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { allDayRow.forceActiveFocus(); CalendarEdit.set("allDay", !root.allDay); } }
                }
            }

            readonly property real half: (width - 10 * root.s) / 2
            Row {
                width: parent.width
                spacing: 10 * root.s
                FormField {
                    id: startDate
                    width: form.half
                    s: root.s; mono: true
                    label: root.allDay ? "First day" : "Starts"
                    placeholder: "YYYY-MM-DD"
                    value: root.f.startDate || ""
                    error: root.errs.startDate || ""
                    maxLength: 10
                    readOnly: root.saving
                    onEdited: text => CalendarEdit.set("startDate", text)
                    onTabbed: back => root.move(startDate, back)
                    onEscaped: CalendarEdit.requestClose()
                    onSubmitted: CalendarEdit.save()
                    onStepped: d => root.step("startDate", d)
                    onFocusedChanged: if (focused) root.reveal(startDate)
                }
                FormField {
                    id: startTime
                    visible: !root.allDay
                    width: form.half
                    s: root.s; mono: true
                    label: "Time"
                    placeholder: "HH:MM"
                    value: root.f.startTime || ""
                    error: root.errs.startTime || ""
                    maxLength: 5
                    readOnly: root.saving
                    onEdited: text => CalendarEdit.set("startTime", text)
                    onTabbed: back => root.move(startTime, back)
                    onEscaped: CalendarEdit.requestClose()
                    onSubmitted: CalendarEdit.save()
                    onStepped: d => root.step("startTime", d)
                    onFocusedChanged: if (focused) root.reveal(startTime)
                }
                FormField {
                    id: lastDate
                    visible: root.allDay
                    width: form.half
                    s: root.s; mono: true
                    label: "Last day"
                    placeholder: "YYYY-MM-DD"
                    hint: "Included"
                    value: root.f.lastDate || ""
                    error: root.errs.lastDate || ""
                    maxLength: 10
                    readOnly: root.saving
                    onEdited: text => CalendarEdit.set("lastDate", text)
                    onTabbed: back => root.move(lastDate, back)
                    onEscaped: CalendarEdit.requestClose()
                    onSubmitted: CalendarEdit.save()
                    onStepped: d => root.step("lastDate", d)
                    onFocusedChanged: if (focused) root.reveal(lastDate)
                }
            }
            Row {
                width: parent.width
                spacing: 10 * root.s
                visible: !root.allDay
                FormField {
                    id: endDate
                    width: form.half
                    s: root.s; mono: true
                    label: "Ends"
                    placeholder: "YYYY-MM-DD"
                    value: root.f.endDate || ""
                    error: root.errs.endDate || ""
                    maxLength: 10
                    readOnly: root.saving
                    onEdited: text => CalendarEdit.set("endDate", text)
                    onTabbed: back => root.move(endDate, back)
                    onEscaped: CalendarEdit.requestClose()
                    onSubmitted: CalendarEdit.save()
                    onStepped: d => root.step("endDate", d)
                    onFocusedChanged: if (focused) root.reveal(endDate)
                }
                FormField {
                    id: endTime
                    width: form.half
                    s: root.s; mono: true
                    label: "Time"
                    placeholder: "HH:MM"
                    value: root.f.endTime || ""
                    error: root.errs.endTime || ""
                    maxLength: 5
                    readOnly: root.saving
                    onEdited: text => CalendarEdit.set("endTime", text)
                    onTabbed: back => root.move(endTime, back)
                    onEscaped: CalendarEdit.requestClose()
                    onSubmitted: CalendarEdit.save()
                    onStepped: d => root.step("endTime", d)
                    onFocusedChanged: if (focused) root.reveal(endTime)
                }
            }
            FormField {
                id: tz
                visible: !root.allDay
                width: parent.width
                s: root.s; mono: true
                label: "Time zone"
                placeholder: "Area/City"
                hint: root.f.tz && Agenda.displayTz && root.f.tz !== Agenda.displayTz
                    ? "The agenda shows this event in " + Agenda.displayTz
                    : "IANA name, for example Europe/Lisbon"
                value: root.f.tz || ""
                error: root.errs.tz || ""
                maxLength: 64
                readOnly: root.saving
                onEdited: text => CalendarEdit.set("tz", text)
                onTabbed: back => root.move(tz, back)
                onEscaped: CalendarEdit.requestClose()
                onSubmitted: CalendarEdit.save()
                onFocusedChanged: if (focused) root.reveal(tz)
            }
            // ---- repetición ----
            Item {
                id: repeatRow
                width: parent.width
                height: Math.max(Metrics.hitMin * root.s, repeatLabel.implicitHeight)
                readonly property string label: "Repeat"
                function focusField() { repeatRow.forceActiveFocus(); }
                onActiveFocusChanged: if (activeFocus) root.reveal(repeatRow)
                Accessible.role: Accessible.ComboBox
                Accessible.name: "Repeat"
                Accessible.description: repeatChoice.label
                Keys.onPressed: e => root.choiceKeys(e, repeatRow, repeatChoice)
                Text {
                    id: repeatLabel
                    anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                    text: "Repeat"
                    color: repeatRow.activeFocus ? Theme.fg : Theme.fgVariant
                    font.family: Typography.ui; font.pixelSize: Typography.caption * root.s; font.weight: Font.DemiBold
                }
                Choice {
                    id: repeatChoice
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    s: root.s; name: "Repeat"; focused: repeatRow.activeFocus
                    enabled: !root.saving
                    options: [{ label: "Never", value: "never" }, { label: "Daily", value: "daily" }, { label: "Weekly", value: "weekly" },
                              { label: "Monthly", value: "monthly" }, { label: "Yearly", value: "yearly" }]
                        .concat(root.f.repeat === "custom" || (root.ed && root.ed.base.repeat === "custom")
                                ? [{ label: "Custom", value: "custom" }] : [])
                    value: root.f.repeat || "never"
                    onPicked: v => { repeatRow.forceActiveFocus(); CalendarEdit.set("repeat", v); }
                }
            }
            Text {
                width: parent.width
                visible: root.f.repeat === "custom"
                text: root.f.customRule ? CalendarEdit.repeatText(root.f.customRule) : ""
                wrapMode: Text.Wrap
                color: Theme.outlineText
                font.family: Typography.mono; font.pixelSize: Typography.caption * root.s
            }
            Column {
                id: repeatDetails
                width: parent.width
                spacing: 10 * root.s
                visible: root.repeating
                Row {
                    width: parent.width
                    spacing: 10 * root.s
                    FormField {
                        id: interval
                        width: 96 * root.s
                        s: root.s; mono: true
                        label: "Every"
                        value: root.f.interval || ""
                        error: root.errs.interval || ""
                        maxLength: 3
                        readOnly: root.saving
                        onEdited: text => CalendarEdit.set("interval", text)
                        onTabbed: back => root.move(interval, back)
                        onEscaped: CalendarEdit.requestClose()
                        onSubmitted: CalendarEdit.save()
                        onStepped: d => CalendarEdit.set("interval", String(Math.max(1, Math.min(999, (Number(root.f.interval) || 1) + d))))
                        onFocusedChanged: if (focused) root.reveal(interval)
                    }
                    Text {
                        y: interval.height - height - (interval.error.length > 0 ? 18 * root.s : 8 * root.s)
                        text: root.unitText
                        color: Theme.fgVariant
                        font.family: Typography.ui; font.pixelSize: Typography.body * root.s
                    }
                }
                Item {
                    id: daysRow
                    visible: root.f.repeat === "weekly"
                    width: parent.width
                    height: daysCol.implicitHeight
                    readonly property string label: "Days"
                    property int cursor: 0
                    function focusField() { daysRow.forceActiveFocus(); }
                    onActiveFocusChanged: if (activeFocus) root.reveal(daysRow)
                    Accessible.role: Accessible.Grouping
                    Accessible.name: "Repeat on days"
                    Keys.onPressed: e => {
                        const ctrl = (e.modifiers & Qt.ControlModifier) !== 0;
                        if (!ctrl && (e.key === Qt.Key_Left || e.key === Qt.Key_Right)) daysRow.cursor = (daysRow.cursor + (e.key === Qt.Key_Right ? 1 : 6)) % 7;
                        else if (e.key === Qt.Key_Space || (!ctrl && (e.key === Qt.Key_Return || e.key === Qt.Key_Enter))) CalendarEdit.toggleDay(CalendarEdit.weekdays[daysRow.cursor]);
                        else if (e.key === Qt.Key_Tab || e.key === Qt.Key_Backtab) root.move(daysRow, e.key === Qt.Key_Backtab || (e.modifiers & Qt.ShiftModifier) !== 0);
                        else if (e.key === Qt.Key_Escape) CalendarEdit.requestClose();
                        else if (ctrl && (e.key === Qt.Key_S || e.key === Qt.Key_Return || e.key === Qt.Key_Enter)) CalendarEdit.save();
                        else return;
                        e.accepted = true;
                    }
                    Column {
                        id: daysCol
                        width: parent.width
                        spacing: 4 * root.s
                        Text {
                            text: "On"
                            color: daysRow.activeFocus ? Theme.fg : Theme.fgVariant
                            font.family: Typography.ui; font.pixelSize: Typography.caption * root.s; font.weight: Font.DemiBold
                        }
                        Flow {
                            width: parent.width
                            spacing: 4 * root.s
                            Repeater {
                                model: CalendarEdit.weekdays
                                Rectangle {
                                    id: dayPill
                                    required property var modelData
                                    required property int index
                                    readonly property bool on: (root.f.byday || []).indexOf(dayPill.modelData) >= 0
                                    width: Math.max(40 * root.s, dayText.implicitWidth + 14 * root.s)
                                    height: Metrics.hitMin * root.s
                                    radius: Metrics.rSm * root.s
                                    color: Theme.controlBg(Theme.tileBg, dayArea.containsMouse, dayArea.pressed && dayArea.containsMouse, dayPill.on)
                                    border.width: daysRow.activeFocus && daysRow.cursor === dayPill.index ? Metrics.focusWidth * root.s : 1
                                    border.color: daysRow.activeFocus && daysRow.cursor === dayPill.index ? Theme.focusRing : dayPill.on ? Theme.selBorder : Theme.hair
                                    Accessible.role: Accessible.CheckBox
                                    Accessible.name: CalendarEdit.dayNames[dayPill.modelData]
                                    Accessible.checked: dayPill.on
                                    Text {
                                        id: dayText
                                        anchors.centerIn: parent
                                        text: CalendarEdit.dayNames[dayPill.modelData]
                                        color: dayPill.on ? Theme.fg : Theme.fgVariant
                                        font.family: Typography.ui; font.pixelSize: Typography.label * root.s
                                        font.weight: dayPill.on ? Font.DemiBold : Font.Normal
                                    }
                                    MouseArea {
                                        id: dayArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        enabled: !root.saving
                                        onClicked: { daysRow.cursor = dayPill.index; daysRow.forceActiveFocus(); CalendarEdit.toggleDay(dayPill.modelData); }
                                    }
                                }
                            }
                        }
                        Text {
                            width: parent.width
                            visible: text.length > 0
                            text: root.errs.byday || ""
                            wrapMode: Text.Wrap
                            color: Theme.errorColor
                            font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                        }
                    }
                }
                Item {
                    id: untilRow
                    width: parent.width
                    height: Math.max(Metrics.hitMin * root.s, untilLabel.implicitHeight)
                    readonly property string label: "Until"
                    function focusField() { untilRow.forceActiveFocus(); }
                    onActiveFocusChanged: if (activeFocus) root.reveal(untilRow)
                    Accessible.role: Accessible.ComboBox
                    Accessible.name: "Repeat until"
                    Accessible.description: untilChoice.label
                    Keys.onPressed: e => root.choiceKeys(e, untilRow, untilChoice)
                    Text {
                        id: untilLabel
                        anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                        text: "Until"
                        color: untilRow.activeFocus ? Theme.fg : Theme.fgVariant
                        font.family: Typography.ui; font.pixelSize: Typography.caption * root.s; font.weight: Font.DemiBold
                    }
                    Choice {
                        id: untilChoice
                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        s: root.s; name: "Repeat until"; focused: untilRow.activeFocus
                        enabled: !root.saving
                        options: [{ label: "Forever", value: "never" }, { label: "A date", value: "until" }, { label: "A number of times", value: "count" }]
                        value: root.f.ends || "never"
                        onPicked: v => {
                            untilRow.forceActiveFocus();
                            CalendarEdit.set("ends", v);
                            if (v === "until" && !root.f.until) CalendarEdit.set("until", CalendarEdit.shiftDate(root.f.startDate, 30));
                        }
                    }
                }
                FormField {
                    id: untilField
                    visible: root.f.ends === "until"
                    width: parent.width / 2
                    s: root.s; mono: true
                    label: "Last occurrence on"
                    placeholder: "YYYY-MM-DD"
                    hint: "Included"
                    value: root.f.until || ""
                    error: root.errs.until || ""
                    maxLength: 10
                    readOnly: root.saving
                    onEdited: text => CalendarEdit.set("until", text)
                    onTabbed: back => root.move(untilField, back)
                    onEscaped: CalendarEdit.requestClose()
                    onSubmitted: CalendarEdit.save()
                    onStepped: d => CalendarEdit.set("until", CalendarEdit.shiftDate(root.f.until, d))
                    onFocusedChanged: if (focused) root.reveal(untilField)
                }
                FormField {
                    id: countField
                    visible: root.f.ends === "count"
                    width: parent.width / 2
                    s: root.s; mono: true
                    label: "Number of times"
                    value: root.f.count || ""
                    error: root.errs.count || ""
                    maxLength: 4
                    readOnly: root.saving
                    onEdited: text => CalendarEdit.set("count", text)
                    onTabbed: back => root.move(countField, back)
                    onEscaped: CalendarEdit.requestClose()
                    onSubmitted: CalendarEdit.save()
                    onStepped: d => CalendarEdit.set("count", String(Math.max(1, Math.min(1000, (Number(root.f.count) || 1) + d))))
                    onFocusedChanged: if (focused) root.reveal(countField)
                }
                Text {
                    width: parent.width
                    visible: text.length > 0
                    text: root.errs.repeat || root.errs.ends || ""
                    wrapMode: Text.Wrap
                    color: Theme.errorColor
                    font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                }
            }

            // ---- aviso ----
            Item {
                id: reminderRow
                width: parent.width
                height: Math.max(Metrics.hitMin * root.s, reminderLabel.implicitHeight)
                readonly property string label: "Reminder"
                function focusField() { reminderRow.forceActiveFocus(); }
                onActiveFocusChanged: if (activeFocus) root.reveal(reminderRow)
                Accessible.role: Accessible.ComboBox
                Accessible.name: "Reminder"
                Accessible.description: reminderChoice.label
                Keys.onPressed: e => root.choiceKeys(e, reminderRow, reminderChoice)
                Text {
                    id: reminderLabel
                    anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                    text: "Reminder"
                    color: reminderRow.activeFocus ? Theme.fg : Theme.fgVariant
                    font.family: Typography.ui; font.pixelSize: Typography.caption * root.s; font.weight: Font.DemiBold
                }
                Choice {
                    id: reminderChoice
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    s: root.s; name: "Reminder"; focused: reminderRow.activeFocus
                    enabled: !root.saving
                    optionMaxWidth: 220 * root.s
                    options: root.reminderOptions
                    value: root.reminderValue
                    onPicked: v => { reminderRow.forceActiveFocus(); root.pickReminder(v); }
                }
            }
            Text {
                width: parent.width
                visible: text.length > 0
                text: root.errs.reminders || ""
                wrapMode: Text.Wrap
                color: Theme.errorColor
                font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
            }

            FormField {
                id: notes
                width: parent.width
                s: root.s
                multiline: true
                label: "Notes"
                placeholder: "Optional"
                hint: (root.f.notes || "").length > 7000 ? (root.f.notes || "").length + " / 8000 characters" : ""
                value: root.f.notes || ""
                error: root.errs.notes || ""
                maxLength: 8000
                readOnly: root.saving
                onEdited: text => CalendarEdit.set("notes", text)
                onTabbed: back => root.move(notes, back)
                onEscaped: CalendarEdit.requestClose()
                onSubmitted: CalendarEdit.save()
                onFocusedChanged: if (focused) root.reveal(notes)
                onCursorRectChanged: if (focused) {
                    const p = notes.mapToItem(form, cursorRect.x, cursorRect.y);
                    if (p.y + cursorRect.height + 8 * root.s > flick.contentY + flick.height)
                        flick.contentY = Math.min(Math.max(0, flick.contentHeight - flick.height), p.y + cursorRect.height + 8 * root.s - flick.height);
                    else if (p.y < flick.contentY) flick.contentY = Math.max(0, p.y - 8 * root.s);
                }
            }
        }
    }
    ScrollHint { view: flick; s: root.s; visible: flick.interactive }

    // ---- pie: confirmación de descarte o las acciones ------------------------------------
    Item {
        id: footer
        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
        height: root.confirming ? confirmBox.implicitHeight : root.askingScope ? scopeBox.implicitHeight : Math.max(actions.implicitHeight, 36 * root.s)

        Rectangle {
            id: scopeBox
            visible: root.askingScope
            width: parent.width
            implicitHeight: scopeCol.implicitHeight + 20 * root.s
            radius: Metrics.rSm * root.s
            color: Qt.alpha(Theme.primary, 0.08)
            border.width: 1
            border.color: Qt.alpha(Theme.primary, 0.40)
            FocusScope {
                id: scopeKeys
                anchors.fill: parent
                readonly property string label: "scope"
                function focusField() { scopeKeys.forceActiveFocus(); }
                Keys.onPressed: e => {
                    if (e.key === Qt.Key_Left || e.key === Qt.Key_Right || e.key === Qt.Key_Tab || e.key === Qt.Key_Backtab)
                        root.scopeStep(e.key === Qt.Key_Right || e.key === Qt.Key_Tab ? 1 : -1);
                    else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) root.scopeActivate();
                    else if (e.key === Qt.Key_Escape) CalendarEdit.keepEditing();
                    else return;
                    e.accepted = true;
                }
            }
            Column {
                id: scopeCol
                x: 12 * root.s; y: 10 * root.s
                width: parent.width - 24 * root.s
                spacing: 8 * root.s
                Text {
                    width: parent.width
                    text: "This event repeats. Save the changes to…"
                    wrapMode: Text.Wrap
                    color: Theme.fg
                    font.family: Typography.ui; font.pixelSize: Typography.body * root.s; font.weight: Font.DemiBold
                }
                Text {
                    width: parent.width
                    text: CalendarEdit.repeatChanged ? "You changed the repeat, so this applies beyond this occurrence."
                        : "All events also moves the series by the days you moved this one."
                    wrapMode: Text.Wrap
                    color: Theme.fgVariant
                    font.family: Typography.ui; font.pixelSize: Typography.caption * root.s
                }
                Flow {
                    width: parent.width
                    spacing: 6 * root.s
                    Repeater {
                        model: root.scopes
                        ActionButton {
                            required property var modelData
                            required property int index
                            s: root.s; label: modelData.label
                            accent: modelData.scope !== ""
                            enabled: modelData.enabled
                            focused: root.scopeIndex === index
                            onTriggered: { root.scopeIndex = index; root.scopeActivate(); }
                        }
                    }
                }
            }
        }

        Rectangle {
            id: confirmBox
            visible: root.confirming
            width: parent.width
            implicitHeight: confirmCol.implicitHeight + 20 * root.s
            radius: Metrics.rSm * root.s
            color: Qt.alpha(Theme.warn, 0.10)
            border.width: 1
            border.color: Qt.alpha(Theme.warn, 0.45)
            FocusScope {
                id: confirmKeys
                anchors.fill: parent
                readonly property string label: "confirm"
                function focusField() { confirmKeys.forceActiveFocus(); }
                Keys.onPressed: e => {
                    if (e.key === Qt.Key_Left || e.key === Qt.Key_Right || e.key === Qt.Key_Tab || e.key === Qt.Key_Backtab) root.confirmIndex = 1 - root.confirmIndex;
                    else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) { if (root.confirmIndex === 1) CalendarEdit.discard(); else CalendarEdit.keepEditing(); }
                    else if (e.key === Qt.Key_Escape) CalendarEdit.keepEditing();
                    else return;
                    e.accepted = true;
                }
            }
            Column {
                id: confirmCol
                x: 12 * root.s; y: 10 * root.s
                width: parent.width - 24 * root.s
                spacing: 8 * root.s
                Text {
                    width: parent.width
                    text: "Discard your unsaved changes?"
                    wrapMode: Text.Wrap
                    color: Theme.fg
                    font.family: Typography.ui
                    font.pixelSize: Typography.body * root.s
                    font.weight: Font.DemiBold
                }
                Text {
                    width: parent.width
                    text: root.ed && root.ed.mode === "edit" ? "The saved event stays as it was." : "The new event will not be created."
                    wrapMode: Text.Wrap
                    color: Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                }
                Row {
                    spacing: 8 * root.s
                    ActionButton { s: root.s; label: "Keep editing"; accent: true; focused: root.confirmIndex === 0; onTriggered: CalendarEdit.keepEditing() }
                    ActionButton { s: root.s; label: "Discard"; danger: true; focused: root.confirmIndex === 1; onTriggered: CalendarEdit.discard() }
                }
            }
        }

        Item {
            id: actions
            visible: !root.confirming && !root.askingScope
            anchors.fill: parent
            implicitHeight: Math.max(saveButton.implicitHeight, keysHint.implicitHeight)
            Rectangle { width: parent.width; height: 1; color: Theme.hair }
            Text {
                id: keysHint
                anchors.left: parent.left
                anchors.right: buttons.left; anchors.rightMargin: 10 * root.s
                anchors.verticalCenter: parent.verticalCenter
                text: root.saving ? "Saving…" : "Ctrl+S save · Esc cancel · ↑ ↓ change dates and times"
                elide: Text.ElideRight
                color: root.saving ? Theme.fg : Theme.outlineText
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
            }
            Row {
                id: buttons
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6 * root.s
                ActionButton { s: root.s; label: "Cancel"; enabled: !root.saving; onTriggered: CalendarEdit.requestClose() }
                ActionButton {
                    id: saveButton
                    s: root.s; primary: true; glyph: "check"
                    label: root.saving ? "Saving…" : "Save"
                    enabled: !root.saving
                    onTriggered: CalendarEdit.save()
                }
            }
        }
    }
}
