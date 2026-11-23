pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

/**
 * Edición de eventos LOCALES desde Calendar UI (2026-10-27; repeticiones y recordatorios
 * 2026-10-28): el borrador, la confirmación de borrado y adónde volver tras guardar. Estado
 * de vista, en memoria y fuera de la superficie, para que cerrar la tarjeta, bloquear o
 * llevarla a otro monitor no pierda lo escrito (DESIGN §2, «Política de edición»: al volver
 * se marca **Draft**; nunca se guarda solo). No sobrevive a un reinicio de la shell.
 *
 *   editor   null | { mode: "create"|"edit", uuid, revision, fields, base, errors, error,
 *                     saving, confirm: ""|"discard"|"scope", restored,
 *                     recurring, rid, occStart, series }
 *   deleting null | { uuid, revision, title, when, recurring, rid, busy, error }
 *   landing  null | { date, id }: lo guardado, que la vista selecciona al verlo cargado
 *
 * Una ocurrencia de una serie se edita con sus propios valores; al guardar se pregunta el
 * alcance: **This event** (una excepción), **This and following** (parte la serie) o **All
 * events** (la serie: el desplazamiento de días que se le dio a esta ocurrencia se aplica al
 * inicio de la serie). Si se cambió la repetición, «sólo ésta» no se ofrece. Borrar una
 * ocurrencia pregunta lo mismo.
 *
 * Guardar pide al helper (`CalendarStore`) y sólo cierra el editor con su respuesta `ok`.
 * Un fallo deja el borrador intacto con el error del campo o un aviso.
 */
Singleton {
    id: root

    property var editor: null
    property var deleting: null
    property var landing: null
    /** Una línea de confirmación breve («Event saved»), que caduca sola. */
    property string notice: ""
    property int saves: 0
    /** Un evento local acaba de borrarse (la vista cierra su detalle antes de releer el rango). */
    signal deleted(string uuid)

    readonly property var fieldNames: ["title", "allDay", "startDate", "startTime", "endDate", "endTime", "lastDate", "tz", "notes",
        "repeat", "interval", "byday", "ends", "until", "count", "reminders", "calendarId"]
    readonly property var weekdays: ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]

    function pad(n) { return (n < 10 ? "0" : "") + n; }
    function isoDate(d) { return d.getFullYear() + "-" + root.pad(d.getMonth() + 1) + "-" + root.pad(d.getDate()); }
    function hhmm(d) { return root.pad(d.getHours()) + ":" + root.pad(d.getMinutes()); }
    function copy(o) { return JSON.parse(JSON.stringify(o)); }
    /** Días civiles entre dos AAAA-MM-DD (sin zona: UTC a medianoche). NaN si alguna no vale. */
    function dayDiff(a, b) {
        const pa = /^(\d{4})-(\d{2})-(\d{2})$/.exec(a || ""), pb = /^(\d{4})-(\d{2})-(\d{2})$/.exec(b || "");
        if (!pa || !pb) return NaN;
        return Math.round((Date.UTC(+pb[1], +pb[2] - 1, +pb[3]) - Date.UTC(+pa[1], +pa[2] - 1, +pa[3])) / 86400000);
    }
    function shiftDate(iso, days) {
        const p = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso || "");
        if (!p || isNaN(days)) return iso;
        const d = new Date(Date.UTC(+p[1], +p[2] - 1, +p[3] + days));
        return d.getUTCFullYear() + "-" + root.pad(d.getUTCMonth() + 1) + "-" + root.pad(d.getUTCDate());
    }
    function weekdayOf(iso) {
        const p = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso || "");
        return p ? root.weekdays[(new Date(Date.UTC(+p[1], +p[2] - 1, +p[3])).getUTCDay() + 6) % 7] : "MO";
    }

    readonly property bool open: root.editor !== null
    readonly property bool dirty: root.editor !== null && JSON.stringify(root.editor.fields) !== JSON.stringify(root.editor.base)
    /** Se tocó la repetición: «sólo esta ocurrencia» ya no tiene sentido. */
    readonly property bool repeatChanged: root.editor !== null
        && JSON.stringify(root.repeatOf(root.editor.fields)) !== JSON.stringify(root.repeatOf(root.editor.base))

    function emptyRepeat(start) {
        return { repeat: "never", interval: "1", byday: [root.weekdayOf(start)], ends: "never", until: "", count: "10" };
    }

    /** Un evento nuevo el día `date` (AAAA-MM-DD). Hoy: la próxima hora en punto; otro día, 09:00. */
    function startCreate(date, now, tz) {
        if (root.editor && root.editor.saving) return false;
        const p = date.split("-");
        const today = root.isoDate(now) === date;
        const start = new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]),
                               today ? Math.min(23, now.getHours() + 1) : 9, 0);
        const end = new Date(start.getTime() + 3600000);
        const fields = Object.assign({ title: "", allDay: false, notes: "", tz: tz || "",
                         startDate: root.isoDate(start), startTime: root.hhmm(start),
                         endDate: root.isoDate(end), endTime: root.hhmm(end),
                         lastDate: root.isoDate(start), startFold: null, endFold: null, reminders: [], calendarId: "local" },
                         root.emptyRepeat(root.isoDate(start)));
        root.deleting = null;
        root.editor = { mode: "create", uuid: CalendarStore.newUuid(), revision: 0,
                        fields: fields, base: root.copy(fields), errors: ({}), error: null,
                        saving: false, confirm: "", restored: false, recurring: false, rid: "", occStart: "", series: null };
        return true;
    }

    /** Editar la cita local de una ocurrencia (el helper trae `event` y, si repite, `occurrence`). */
    function startEdit(item) {
        if (!item || item.source !== "local" || !item.event) return false;
        if (root.editor && root.editor.saving) return false;
        const recurring = item.recurring === true && item.occurrence;
        const fields = root.fieldsOf(recurring ? item.occurrence : item.event, item.event);
        root.deleting = null;
        root.editor = { mode: "edit", uuid: item.event.uuid, revision: item.event.revision,
                        fields: fields, base: root.copy(fields), errors: ({}), error: null,
                        saving: false, confirm: "", restored: false,
                        recurring: !!recurring, rid: recurring ? item.rid : "",
                        occStart: recurring ? item.occurrence.startDate : "",
                        series: recurring ? { startDate: item.event.startDate, endDate: item.event.endDate, lastDate: item.event.lastDate } : null };
        return true;
    }
    /** `ev`: lo que se enseña (la ocurrencia o el evento); `master`: de dónde salen repetición y avisos. */
    function fieldsOf(ev, master) {
        const m = master || ev;
        const rep = m.repeat;
        const f = { title: ev.title, allDay: ev.allDay, notes: ev.notes, tz: ev.allDay ? "" : ev.tz,
                 startDate: ev.startDate, startTime: ev.allDay ? "" : ev.startTime,
                 endDate: ev.allDay ? ev.lastDate : ev.endDate, endTime: ev.allDay ? "" : ev.endTime,
                 lastDate: ev.allDay ? ev.lastDate : ev.endDate,
                 startFold: ev.allDay ? null : ev.startFold, endFold: ev.allDay ? null : ev.endFold,
                 reminders: (m.reminders || []).slice(), calendarId: m.calendarId || "local" };
        Object.assign(f, root.emptyRepeat(ev.startDate));
        if (rep && rep.custom) {
            // Regla que el formulario no sabe editar (de un servidor o de un .ics): viaja entera.
            f.repeat = "custom";
            f.customRule = JSON.parse(JSON.stringify(rep));
        } else if (rep) {
            f.repeat = rep.freq;
            f.interval = String(rep.interval);
            if (rep.byday) f.byday = rep.byday.slice();
            f.ends = rep.ends.type;
            if (rep.ends.type === "until") f.until = rep.ends.date;
            if (rep.ends.type === "count") f.count = String(rep.ends.count);
        }
        return f;
    }

    /** Cambia un campo del borrador; su error (y el aviso general de ese campo) se van con él. */
    function set(field, value) {
        if (!root.editor || root.editor.saving || root.fieldNames.indexOf(field) < 0) return false;
        const e = root.copy(root.editor);
        if (field === "allDay") e.fields.allDay = value === true || value === "true";
        else if (field === "byday" || field === "reminders") e.fields[field] = Array.isArray(value) ? value.slice() : [];
        else e.fields[field] = String(value);
        if (field === "allDay") {
            // Al pasar a todo el día, el último día sale del fin; al volver, se rellenan horas.
            if (e.fields.allDay) e.fields.lastDate = e.fields.endDate || e.fields.startDate;
            else {
                if (!e.fields.startTime) e.fields.startTime = "09:00";
                if (!e.fields.endTime) e.fields.endTime = "10:00";
                if (!e.fields.endDate) e.fields.endDate = e.fields.lastDate || e.fields.startDate;
                if (!e.fields.tz) e.fields.tz = Agenda.displayTz;
            }
            // Los avisos de una cita con hora no significan lo mismo en todo el día (09:00).
            e.fields.reminders = [];
        }
        if (field === "repeat" && e.fields.repeat === "weekly" && e.fields.byday.length === 0)
            e.fields.byday = [root.weekdayOf(e.fields.startDate)];
        // Una hora o fecha nueva deshace la elección de una hora ambigua anterior.
        if (field === "startDate" || field === "startTime" || field === "tz") e.fields.startFold = null;
        if (field === "endDate" || field === "endTime" || field === "tz") e.fields.endFold = null;
        delete e.errors[field];
        if (e.error && (e.error.field === field || !e.error.field)) e.error = null;
        e.confirm = "";
        root.editor = e;
        return true;
    }
    function toggleDay(day) {
        if (!root.editor) return false;
        const d = root.editor.fields.byday.slice();
        const i = d.indexOf(day);
        if (i >= 0) d.splice(i, 1); else d.push(day);
        return root.set("byday", root.weekdays.filter(x => d.indexOf(x) >= 0));
    }

    function repeatOf(f) {
        if (!f || f.repeat === "never") return null;
        if (f.repeat === "custom") return f.customRule || null;
        const n = Number(f.interval);
        const ends = f.ends === "until" ? { type: "until", date: f.until }
            : f.ends === "count" ? { type: "count", count: /^\d+$/.test(f.count) ? Number(f.count) : f.count }
            : { type: "never" };
        return { freq: f.repeat, interval: /^\d+$/.test(f.interval) ? n : f.interval,
                 byday: f.repeat === "weekly" ? f.byday : null, ends: ends };
    }
    function payload(f, withRepeat) {
        const ev = f.allDay
            ? { title: f.title, notes: f.notes, allDay: true, startDate: f.startDate, lastDate: f.lastDate }
            : { title: f.title, notes: f.notes, allDay: false, tz: f.tz,
                startDate: f.startDate, startTime: f.startTime, endDate: f.endDate, endTime: f.endTime };
        if (!f.allDay && (f.startFold === 0 || f.startFold === 1)) ev.startFold = f.startFold;
        if (!f.allDay && (f.endFold === 0 || f.endFold === 1)) ev.endFold = f.endFold;
        ev.reminders = f.reminders || [];
        ev.repeat = withRepeat ? root.repeatOf(f) : null;
        ev.calendarId = f.calendarId || "local";
        return ev;
    }
    /** Toda la serie desde una ocurrencia: el mismo desplazamiento de días, aplicado a su inicio. */
    function seriesPayload(e) {
        const f = root.copy(e.fields);
        const delta = root.dayDiff(e.occStart, f.startDate);
        const span = root.dayDiff(f.startDate, f.allDay ? f.lastDate : f.endDate);
        if (!isNaN(delta) && !isNaN(span) && e.series) {
            f.startDate = root.shiftDate(e.series.startDate, delta);
            if (f.allDay) f.lastDate = root.shiftDate(f.startDate, span);
            else f.endDate = root.shiftDate(f.startDate, span);
            if (f.repeat !== "never" && f.ends === "until" && root.dayDiff(f.startDate, f.until) < 0) f.until = f.startDate;
        }
        return root.payload(f, true);
    }

    /** Guarda. En una ocurrencia de una serie, primero pregunta el alcance (`scope` lo responde). */
    function save(scope) {
        if (!root.editor || root.editor.saving) return false;
        if (root.editor.recurring && !scope) {
            const q = root.copy(root.editor);
            q.confirm = "scope";
            root.editor = q;
            return true;
        }
        if (scope === "occurrence" && root.repeatChanged) return false;
        const e = root.copy(root.editor);
        e.saving = true;
        e.error = null;
        e.errors = ({});
        e.confirm = "";
        e.scope = scope || "series";
        root.editor = e;
        const uuid = e.uuid, mode = e.mode;
        const then = function (r) { root.saved(uuid, r); };
        if (mode === "create") CalendarStore.create(uuid, root.payload(e.fields, true), then);
        else if (!e.recurring) CalendarStore.update(uuid, e.revision, root.payload(e.fields, true), then);
        else if (scope === "occurrence") CalendarStore.submit({ op: "update", uuid: uuid, revision: e.revision, scope: "occurrence", rid: e.rid, event: root.payload(e.fields, false) }, then);
        else if (scope === "following") CalendarStore.submit({ op: "update", uuid: uuid, revision: e.revision, scope: "following", rid: e.rid, event: root.payload(e.fields, true) }, then);
        else CalendarStore.submit({ op: "update", uuid: uuid, revision: e.revision, scope: "series", event: root.seriesPayload(e) }, then);
        return true;
    }
    function saved(uuid, r) {
        // El borrador pudo descartarse mientras se guardaba: el resultado ya no tiene a quién volver.
        if (!root.editor || root.editor.uuid !== uuid) {
            if (r.ok && r.event) root.land(r.event, null);
            return;
        }
        if (r.ok) {
            const e = root.editor;
            root.editor = null;
            root.saves++;
            root.land(r.event, e);
            root.say(r.repeated ? "Event was already saved"
                     : r.resetExceptions > 0 ? "Series saved · " + r.resetExceptions + (r.resetExceptions === 1 ? " changed occurrence reset" : " changed occurrences reset")
                     : r.split ? "Saved from this occurrence on" : "Event saved");
            return;
        }
        const e = root.copy(root.editor);
        e.saving = false;
        e.error = r.error || { code: "internal", message: "Could not save" };
        // La hora ambigua ya se explica arriba con sus dos opciones: bajo el campo, sólo el aviso breve.
        if (e.error.field) e.errors[e.error.field] = e.error.code === "ambiguous_time" ? "Choose one of the two times above" : e.error.message;
        root.editor = e;
        // Otro editor cambió o borró el evento: la agenda que se ve está vieja.
        if (e.error.code === "conflict" || e.error.code === "not_found") Agenda.refreshLocal();
    }
    function land(ev, e) {
        const repeating = ev.repeat !== null && ev.repeat !== undefined;
        if (!repeating) {
            root.landing = { date: ev.displayDate || ev.startDate, id: "local:" + ev.uuid + "@" + (ev.displayDate || ev.startDate) };
            return;
        }
        // Una serie: el día en que se editó (o su primer día); el detalle si la ocurrencia está a la vista.
        const f = e ? e.fields : null;
        const date = f ? f.startDate : (ev.displayDate || ev.startDate);
        const rid = e && e.scope === "occurrence" ? e.rid
            : (ev.allDay ? date : date + "T" + (f && !f.allDay ? f.startTime : ev.startTime));
        root.landing = { date: date, id: "local:" + ev.uuid + "~" + rid + "@" + date };
    }

    /** Hora ambigua: el usuario eligió cuál de las dos (fold) y se vuelve a guardar. */
    function chooseFold(fold) {
        if (!root.editor || !root.editor.error || root.editor.error.code !== "ambiguous_time") return false;
        const e = root.copy(root.editor);
        if (e.error.field === "endTime") e.fields.endFold = fold;
        else e.fields.startFold = fold;
        delete e.errors[e.error.field];
        e.error = null;
        const scope = e.scope;
        root.editor = e;
        return root.save(e.recurring ? scope : undefined);
    }
    /** Conflicto: cargar la versión guardada (se pierde lo escrito aquí: el botón lo dice). */
    function loadLatest() {
        if (!root.editor || !root.editor.error || !root.editor.error.current) return false;
        const cur = root.editor.error.current;
        const fields = root.fieldsOf(cur, cur);
        root.editor = { mode: "edit", uuid: cur.uuid, revision: cur.revision, fields: fields, base: root.copy(fields),
                        errors: ({}), error: null, saving: false, confirm: "", restored: false,
                        recurring: false, rid: "", occStart: "", series: null };
        return true;
    }
    /** Conflicto: guardar lo de aquí sobre la versión nueva, por decisión explícita. */
    function keepMine() {
        if (!root.editor || !root.editor.error || !root.editor.error.current) return false;
        const e = root.copy(root.editor);
        e.revision = e.error.current.revision;
        e.error = null;
        const scope = e.scope;
        root.editor = e;
        return root.save(e.recurring ? scope : undefined);
    }
    /** El evento se borró en otra parte: guardar el borrador como uno nuevo. */
    function saveAsNew() {
        if (!root.editor || !root.editor.error || root.editor.error.code !== "not_found") return false;
        const e = root.copy(root.editor);
        e.mode = "create";
        e.uuid = CalendarStore.newUuid();
        e.revision = 0;
        e.recurring = false;
        e.error = null;
        root.editor = e;
        return root.save();
    }

    /** Cancelar/Esc: sin cambios cierra; con cambios pregunta. Mientras guarda no hace nada. */
    function requestClose() {
        if (!root.editor || root.editor.saving) return false;
        if (root.editor.confirm !== "") { root.keepEditing(); return true; }
        if (!root.dirty) { root.editor = null; return true; }
        const e = root.copy(root.editor);
        e.confirm = "discard";
        root.editor = e;
        return true;
    }
    function discard() {
        if (!root.editor || root.editor.saving) return false;
        root.editor = null;
        return true;
    }
    function keepEditing() {
        if (!root.editor) return false;
        const e = root.copy(root.editor);
        e.confirm = "";
        root.editor = e;
        return true;
    }
    /** La tarjeta se cerró con el editor abierto y cambios: al volver se marca como borrador. */
    function markDraft() {
        if (!root.editor || !root.dirty || root.editor.restored) return;
        const e = root.copy(root.editor);
        e.restored = true;
        root.editor = e;
    }

    // ---- borrar ----------------------------------------------------------------------------

    function askDelete(item, when) {
        if (!item || item.source !== "local" || !item.event || root.editor) return false;
        const recurring = item.recurring === true;
        root.deleting = { uuid: item.event.uuid, revision: item.event.revision,
                          title: recurring && item.occurrence ? item.occurrence.title : item.event.title,
                          when: when || "", recurring: recurring, rid: recurring ? item.rid : "", busy: false, error: null };
        return true;
    }
    function cancelDelete() {
        if (!root.deleting || root.deleting.busy) return false;
        root.deleting = null;
        return true;
    }
    /** `scope`: occurrence · following · series (un evento sin repetición siempre es series). */
    function confirmDelete(scope) {
        if (!root.deleting || root.deleting.busy) return false;
        const d = root.copy(root.deleting);
        const sc = d.recurring ? (scope || "occurrence") : "series";
        d.busy = true;
        d.error = null;
        root.deleting = d;
        const req = { op: "delete", uuid: d.uuid, revision: d.revision, scope: sc };
        if (sc !== "series") req.rid = d.rid;
        CalendarStore.submit(req, function (r) {
            if (!root.deleting || root.deleting.uuid !== d.uuid) return;
            if (r.ok) {
                root.deleting = null;
                root.deleted(d.uuid);
                root.say(sc === "occurrence" ? "Occurrence deleted" : sc === "following" ? "Deleted from this occurrence on" : "Event deleted");
                return;
            }
            const x = root.copy(root.deleting);
            x.busy = false;
            x.error = r.error || { code: "internal", message: "Could not delete" };
            root.deleting = x;
            if (x.error.code === "conflict" || x.error.code === "not_found") Agenda.refreshLocal();
        });
        return true;
    }

    function say(text) {
        root.notice = text;
        noticeTimer.restart();
    }
    Timer { id: noticeTimer; interval: 4000; onTriggered: root.notice = "" }

    // ---- textos para la vista -----------------------------------------------------------------

    readonly property var dayNames: ({ MO: "Mon", TU: "Tue", WE: "Wed", TH: "Thu", FR: "Fri", SA: "Sat", SU: "Sun" })
    function repeatText(rep) {
        if (!rep) return "";
        const unit = { daily: ["day", "days"], weekly: ["week", "weeks"], monthly: ["month", "months"], yearly: ["year", "years"] }[rep.freq];
        let t = rep.interval === 1 ? "Repeats " + ({ daily: "daily", weekly: "weekly", monthly: "monthly", yearly: "yearly" }[rep.freq])
                                   : "Repeats every " + rep.interval + " " + unit[1];
        if (rep.custom) return "Repeats: " + (rep.text || "custom rule") + " (kept as received)";
        if (rep.freq === "weekly" && rep.byday) t += " on " + rep.byday.map(d => root.dayNames[d]).join(", ");
        if (rep.ends.type === "count") t += " · " + rep.ends.count + (rep.ends.count === 1 ? " time" : " times");
        if (rep.ends.type === "until") t += " · until " + rep.ends.date;
        return t;
    }
    function reminderText(list, allDay) {
        if (!list || list.length === 0) return "";
        return "Reminder: " + list.map(m => root.reminderLabel(m, allDay)).join(", ");
    }
    function reminderLabel(m, allDay) {
        if (allDay) {
            if (m === 0) return "09:00 that day";
            if (m === 1440) return "09:00 the day before";
            return m + " min before 09:00";
        }
        if (m === 0) return "at the start";
        if (m % 1440 === 0) return (m / 1440) + (m === 1440 ? " day" : " days") + " before";
        if (m % 60 === 0) return (m / 60) + (m === 60 ? " hour" : " hours") + " before";
        return m + " min before";
    }

    function summary() {
        return { editor: root.editor, dirty: root.dirty, repeatChanged: root.repeatChanged, deleting: root.deleting, landing: root.landing,
                 notice: root.notice, saves: root.saves, store: CalendarStore.summary() };
    }
}
