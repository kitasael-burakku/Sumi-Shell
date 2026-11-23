"""iCalendar del calendario local: leer un recurso CalDAV y reescribirlo SIN PERDER datos (2026-10-28).

Un recurso es un VCALENDAR con un VEVENT maestro (con su UID), quizá VEVENT hijos con
RECURRENCE-ID (ocurrencias cambiadas) y VTIMEZONE. Al leerlo se obtiene lo que la shell sabe
manejar (fechas, título, notas, regla, excepciones, avisos) y, si algo no cabe, un motivo de
SÓLO LECTURA. Al escribir se parte del ORIGINAL: sólo se reemplazan las propiedades que la
shell gestiona (SUMMARY, DESCRIPTION, DTSTART, DTEND/DURATION, RRULE, RDATE, EXDATE, los avisos
que entendió, DTSTAMP, LAST-MODIFIED, SEQUENCE); todo lo demás —asistentes, categorías, X-…,
avisos por correo, VTIMEZONE, componentes ajenos— se conserva con su línea desplegada idéntica.
"""
import datetime as dt
import re
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import calendar_rrule as R

UTC = dt.timezone.utc
MANAGED = {"SUMMARY", "DESCRIPTION", "DTSTART", "DTEND", "DURATION", "RRULE", "RDATE", "EXDATE",
           "DTSTAMP", "LAST-MODIFIED", "SEQUENCE"}
REGIONS = ("Africa", "America", "Antarctica", "Arctic", "Asia", "Atlantic", "Australia", "Europe",
           "Indian", "Pacific", "Etc")
# Los nombres de Windows más habituales (CLDR windowsZones, territorio 001).
WINDOWS = {
    "UTC": "Etc/UTC", "GMT Standard Time": "Europe/London", "Greenwich Standard Time": "Atlantic/Reykjavik",
    "W. Europe Standard Time": "Europe/Berlin", "Romance Standard Time": "Europe/Paris",
    "Central Europe Standard Time": "Europe/Budapest", "Central European Standard Time": "Europe/Warsaw",
    "E. Europe Standard Time": "Europe/Chisinau", "GTB Standard Time": "Europe/Bucharest", "FLE Standard Time": "Europe/Kiev",
    "Russian Standard Time": "Europe/Moscow", "Eastern Standard Time": "America/New_York", "Central Standard Time": "America/Chicago",
    "Mountain Standard Time": "America/Denver", "US Mountain Standard Time": "America/Phoenix", "Pacific Standard Time": "America/Los_Angeles",
    "Alaskan Standard Time": "America/Anchorage", "Hawaiian Standard Time": "Pacific/Honolulu",
    "Central Standard Time (Mexico)": "America/Mexico_City", "Mountain Standard Time (Mexico)": "America/Mazatlan",
    "Pacific Standard Time (Mexico)": "America/Tijuana", "Canada Central Standard Time": "America/Regina",
    "SA Pacific Standard Time": "America/Bogota", "Atlantic Standard Time": "America/Halifax", "E. South America Standard Time": "America/Sao_Paulo",
    "Argentina Standard Time": "America/Buenos_Aires", "Pacific SA Standard Time": "America/Santiago", "Venezuela Standard Time": "America/Caracas",
    "India Standard Time": "Asia/Calcutta", "China Standard Time": "Asia/Shanghai", "Tokyo Standard Time": "Asia/Tokyo",
    "Korea Standard Time": "Asia/Seoul", "Singapore Standard Time": "Asia/Singapore", "AUS Eastern Standard Time": "Australia/Sydney",
    "New Zealand Standard Time": "Pacific/Auckland", "South Africa Standard Time": "Africa/Johannesburg", "Egypt Standard Time": "Africa/Cairo",
    "Arabian Standard Time": "Asia/Dubai", "Israel Standard Time": "Asia/Jerusalem", "Turkey Standard Time": "Europe/Istanbul",
}


class Prop:
    __slots__ = ("name", "params", "value", "raw")

    def __init__(self, name, params, value, raw=None):
        self.name, self.params, self.value = name, params, value
        self.raw = raw if raw is not None else build_line(name, params, value)

    def param(self, key, default=None):
        for k, v in self.params:
            if k == key:
                return v
        return default


class Comp:
    def __init__(self, name):
        self.name = name
        self.props = []
        self.children = []

    def get(self, name):
        return next((p for p in self.props if p.name == name), None)

    def all(self, name):
        return [p for p in self.props if p.name == name]

    def remove(self, *names):
        self.props = [p for p in self.props if p.name not in names]

    def add(self, name, value, params=()):
        self.props.append(Prop(name, list(params), value))


def escape(s):
    return s.replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,").replace("\r\n", "\n").replace("\n", "\\n")


def unescape(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            out.append("\n" if n in "nN" else n)
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def build_line(name, params, value):
    ps = "".join(";%s=%s" % (k, ('"%s"' % v) if any(c in v for c in ",;:") else v) for k, v in params)
    return name + ps + ":" + value


def split_line(line):
    """`NOMBRE;P=V;P2="a:b":valor` → (NOMBRE, [(P, V)…], valor), respetando comillas."""
    i, inq = 0, False
    while i < len(line):
        c = line[i]
        if c == '"':
            inq = not inq
        elif c == ":" and not inq:
            break
        i += 1
    head, value = line[:i], line[i + 1:]
    parts, cur, inq = [], "", False
    for c in head:
        if c == '"':
            inq = not inq
            continue
        if c == ";" and not inq:
            parts.append(cur)
            cur = ""
        else:
            cur += c
    parts.append(cur)
    params = []
    for p in parts[1:]:
        k, _, v = p.partition("=")
        params.append((k.upper(), v))
    return parts[0].upper(), params, value


def unfold(text):
    lines = []
    for raw in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if raw[:1] in (" ", "\t") and lines:
            lines[-1] += raw[1:]
        elif raw:
            lines.append(raw)
    return lines


def parse(text):
    """→ lista de componentes de nivel superior (normalmente un VCALENDAR)."""
    roots, stack = [], []
    for line in unfold(text):
        name, params, value = split_line(line)
        if name == "BEGIN":
            c = Comp(value.upper())
            (stack[-1].children if stack else roots).append(c)
            stack.append(c)
        elif name == "END":
            if stack:
                stack.pop()
        elif stack:
            stack[-1].props.append(Prop(name, params, value, line))
    return roots


def fold(line):
    if len(line.encode()) <= 75:
        return line + "\r\n"
    out, cur, limit = [], b"", 75
    for ch in line:
        b = ch.encode()
        if len(cur) + len(b) > limit:
            out.append(cur)
            cur, limit = b"", 74
        cur += b
    out.append(cur)
    return "\r\n ".join(x.decode() for x in out) + "\r\n"


def serialize(comp):
    lines = ["BEGIN:" + comp.name] + [p.raw for p in comp.props]
    text = "".join(fold(l) for l in lines)
    for ch in comp.children:
        text += serialize(ch)
    return text + fold("END:" + comp.name)


# ---- zonas -------------------------------------------------------------------------------------

def iana(tzid, vtimezones):
    """TZID → nombre IANA, o None si no se puede saber con certeza."""
    if not tzid:
        return None
    t = tzid.strip().strip('"')
    for cand in [t, t.lstrip("/")]:
        try:
            ZoneInfo(cand)
            return cand
        except (ZoneInfoNotFoundError, ValueError):
            pass
    m = re.search(r"((?:%s)/[A-Za-z0-9_+\-/]+)$" % "|".join(REGIONS), t)
    if m:
        try:
            ZoneInfo(m.group(1))
            return m.group(1)
        except (ZoneInfoNotFoundError, ValueError):
            pass
    if t in WINDOWS:
        return WINDOWS[t]
    vt = vtimezones.get(t)
    if vt is not None:
        loc = vt.get("X-LIC-LOCATION")
        if loc:
            return iana(loc.value, {})
    return None


def when(prop, vtimezones, display):
    """DTSTART/DTEND/RECURRENCE-ID → ('date', date) | ('time', naive, tzname, floating) | Unsupported."""
    value = prop.value.strip()
    if prop.param("VALUE", "").upper() == "DATE" or re.match(r"^\d{8}$", value):
        return ("date", dt.datetime.strptime(value[:8], "%Y%m%d").date())
    m = re.match(r"^(\d{8})T(\d{2})(\d{2})(\d{2})?(Z)?$", value)
    if not m:
        raise R.Unsupported("date %s" % value)
    naive = dt.datetime.strptime(m.group(1) + m.group(2) + m.group(3), "%Y%m%d%H%M")
    if m.group(5):
        return ("time", naive.replace(tzinfo=UTC).astimezone(ZoneInfo(display)).replace(tzinfo=None), display, False, "utc")
    tzid = prop.param("TZID")
    if not tzid:
        return ("time", naive, display, True, "floating")
    name = iana(tzid, vtimezones)
    if not name:
        raise R.Unsupported("time zone %s" % tzid)
    return ("time", naive, name, False, "tzid")


def duration(value):
    m = re.match(r"^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$", value.strip())
    if not m:
        raise R.Unsupported("duration %s" % value)
    sign = -1 if m.group(1) == "-" else 1
    w, d, h, mi, s = (int(x or 0) for x in m.groups()[1:])
    return sign * dt.timedelta(weeks=w, days=d, hours=h, minutes=mi, seconds=s)


# ---- recurso → modelo -----------------------------------------------------------------------------

def _span(ev, vtz, display):
    """El tramo de un VEVENT → dict con allDay, startDate/lastDate o tz/start/end (pared)."""
    ds = ev.get("DTSTART")
    if not ds:
        raise R.Unsupported("event without DTSTART")
    s = when(ds, vtz, display)
    de, du = ev.get("DTEND"), ev.get("DURATION")
    if s[0] == "date":
        if de:
            e = when(de, vtz, display)
            if e[0] != "date":
                raise R.Unsupported("all-day start with a timed end")
            end = e[1]
        else:
            end = s[1] + (duration(du.value) if du else dt.timedelta(days=1))
        end = max(end, s[1] + dt.timedelta(days=1))
        return {"allDay": True, "startDate": s[1].isoformat(), "lastDate": (end - dt.timedelta(days=1)).isoformat()}, s
    naive, tzname = s[1], s[2]
    if de:
        e = when(de, vtz, display)
        if e[0] != "time":
            raise R.Unsupported("timed start with an all-day end")
        tz = ZoneInfo(tzname)
        end = e[1].replace(tzinfo=ZoneInfo(e[2])).astimezone(tz).replace(tzinfo=None)
    else:
        end = naive + (duration(du.value) if du else dt.timedelta(0))
    if end <= naive:
        end = naive + dt.timedelta(minutes=1)   # sin duración: un minuto, para poder enseñarla
    return {"allDay": False, "tz": tzname, "floating": s[3], "startDate": naive.date().isoformat(),
            "startTime": naive.strftime("%H:%M"), "endDate": end.date().isoformat(), "endTime": end.strftime("%H:%M")}, s


def _rid_key(prop, master_start, vtz, display):
    """RECURRENCE-ID/EXDATE → clave local (pared en la zona del maestro, o fecha)."""
    t = when(prop, vtz, display)
    if t[0] == "date":
        return t[1].isoformat()
    if master_start[0] != "time":
        return t[1].date().isoformat()
    naive = t[1].replace(tzinfo=ZoneInfo(t[2])).astimezone(ZoneInfo(master_start[2])).replace(tzinfo=None) if not t[3] else t[1]
    return naive.strftime("%Y-%m-%dT%H:%M")


def _alarms(ev, all_day):
    """→ (minutos antes entendidos, cuántos se conservan sin interpretar)."""
    mins, kept = [], 0
    for al in [c for c in ev.children if c.name == "VALARM"]:
        trig = al.get("TRIGGER")
        act = (al.get("ACTION").value.upper() if al.get("ACTION") else "DISPLAY")
        if (not trig or trig.param("VALUE", "").upper() == "DATE-TIME" or trig.param("RELATED", "START").upper() != "START"
                or act not in ("DISPLAY", "AUDIO") or al.get("REPEAT")):
            kept += 1
            continue
        try:
            m = int(-duration(trig.value).total_seconds() // 60)
        except R.Unsupported:
            kept += 1
            continue
        m = 540 + m if all_day else m          # todo el día: la shell avisa respecto a las 09:00
        if 0 <= m <= 40320:
            mins.append(m)
        else:
            kept += 1
    return sorted(set(mins))[:4], kept


def read(text, display):
    """Recurso CalDAV → {uid, master, overrides: {rid: span+text}, cancelled, rule, reminders,
    readonly (motivo o ''), floating, extras}. Nunca falla por algo no admitido: lo deja en
    sólo lectura y, si ni siquiera hay fecha legible, `master` es None."""
    roots = parse(text)
    cal = next((c for c in roots if c.name == "VCALENDAR"), None)
    if cal is None:
        raise ValueError("not a VCALENDAR")
    vtz = {}
    for c in cal.children:
        if c.name == "VTIMEZONE" and c.get("TZID"):
            vtz[c.get("TZID").value] = c
    events = [c for c in cal.children if c.name == "VEVENT"]
    others = [c.name for c in cal.children if c.name not in ("VEVENT", "VTIMEZONE")]
    if not events:
        return {"uid": None, "master": None, "readonly": "no event in this resource (%s)" % ", ".join(others or ["empty"]), "others": others}
    master = next((e for e in events if not e.get("RECURRENCE-ID")), None)
    uid = (master or events[0]).get("UID").value if (master or events[0]).get("UID") else None
    out = {"uid": uid, "master": None, "overrides": {}, "cancelled": [], "rule": None, "reminders": [],
           "readonly": "", "others": others}
    reasons = []
    if master is None:
        reasons.append("changed occurrences without their series")
        master = events[0]
    try:
        span, start = _span(master, vtz, display)
    except R.Unsupported as e:
        out["readonly"] = str(e)
        return out
    title = unescape(master.get("SUMMARY").value) if master.get("SUMMARY") else ""
    notes = unescape(master.get("DESCRIPTION").value) if master.get("DESCRIPTION") else ""
    out["master"] = dict(span, title=title, notes=notes)
    rr = master.all("RRULE")
    if len(rr) > 1 or master.get("EXRULE"):
        reasons.append("several repetition rules")
    elif rr:
        try:
            rule = R.from_ical(rr[0].value)
            rd = []
            for p in master.all("RDATE"):
                if p.param("VALUE", "").upper() == "PERIOD":
                    raise R.Unsupported("RDATE periods")
                for v in p.value.split(","):
                    t = when(Prop("RDATE", p.params, v), vtz, display)
                    rd.append(t[1].isoformat() if t[0] == "date" else t[1].date().isoformat())
            if rd:
                rule["rdate"] = sorted(set(rd))
            out["rule"] = rule
        except R.Unsupported as e:
            reasons.append("repeats with %s" % e)
    elif master.all("RDATE"):
        reasons.append("extra dates without a repetition rule")
    for p in master.all("EXDATE"):
        for v in p.value.split(","):
            try:
                out["cancelled"].append(_rid_key(Prop("EXDATE", p.params, v), start, vtz, display))
            except R.Unsupported as e:
                reasons.append("excluded date %s" % e)
    for ch in events:
        rid = ch.get("RECURRENCE-ID")
        if not rid or ch is master:
            continue
        if rid.param("RANGE", "").upper() == "THISANDFUTURE":
            reasons.append("a change for this and following occurrences")
            continue
        try:
            key = _rid_key(rid, start, vtz, display)
            s2, _ = _span(ch, vtz, display)
            out["overrides"][key] = dict(s2, title=unescape(ch.get("SUMMARY").value) if ch.get("SUMMARY") else title,
                                         notes=unescape(ch.get("DESCRIPTION").value) if ch.get("DESCRIPTION") else notes)
        except R.Unsupported as e:
            reasons.append("changed occurrence: %s" % e)
    out["reminders"], kept = _alarms(master, span["allDay"])
    out["keptAlarms"] = kept
    out["floating"] = bool(span.get("floating"))
    out["readonly"] = "; ".join(dict.fromkeys(reasons))
    return out


# ---- modelo → recurso -------------------------------------------------------------------------------

def _fmt_when(name, span, which, master_tz=None):
    if span["allDay"]:
        d = span["startDate"] if which == "start" else (dt.date.fromisoformat(span["lastDate"]) + dt.timedelta(days=1)).isoformat()
        return Prop(name, [("VALUE", "DATE")], d.replace("-", ""))
    date = span["startDate"] if which == "start" else span["endDate"]
    clock = span["startTime"] if which == "start" else span["endTime"]
    wall = date.replace("-", "") + "T" + clock.replace(":", "") + "00"
    if span.get("floating"):
        return Prop(name, [], wall)
    return Prop(name, [("TZID", span["tz"])], wall)


def _rid_prop(name, key, master):
    if len(key) == 10:
        return Prop(name, [("VALUE", "DATE")], key.replace("-", ""))
    wall = key.replace("-", "").replace(":", "") + "00"
    if master.get("floating"):
        return Prop(name, [], wall)
    return Prop(name, [("TZID", master["tz"])], wall)


def _stamp():
    return dt.datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")


def _patch_event(ev, span, title, notes, extra_lines=()):
    """Sustituye las propiedades gestionadas de un VEVENT, en su sitio, conservando el resto."""
    keep = [p for p in ev.props if p.name not in MANAGED]
    seq = ev.get("SEQUENCE")
    new = [Prop("DTSTAMP", [], _stamp()), Prop("LAST-MODIFIED", [], _stamp()),
           Prop("SEQUENCE", [], str((int(seq.value) if seq and seq.value.isdigit() else 0) + 1)),
           Prop("SUMMARY", [], escape(title)), _fmt_when("DTSTART", span, "start"), _fmt_when("DTEND", span, "end")]
    if notes:
        new.append(Prop("DESCRIPTION", [], escape(notes)))
    new += list(extra_lines)
    ev.props = keep[:1] + new + keep[1:]       # tras el UID, que suele ir primero


def _set_alarms(ev, reminders, all_day, title):
    """Quita los avisos que la shell entendía y pone los actuales; los demás se quedan."""
    keep = []
    for al in [c for c in ev.children if c.name == "VALARM"]:
        mins, kept = _alarms(Comp_with(al), all_day)
        if kept:
            keep.append(al)
    ev.children = [c for c in ev.children if c.name != "VALARM"] + keep
    for m in reminders:
        al = Comp("VALARM")
        al.add("ACTION", "DISPLAY")
        al.add("DESCRIPTION", escape(title))
        trig = (540 - m) if all_day else -m
        al.add("TRIGGER", ("-PT%dM" % -trig) if trig < 0 else ("PT%dM" % trig))
        ev.children.append(al)


def Comp_with(alarm):
    c = Comp("VEVENT")
    c.children = [alarm]
    return c


def render(original, uid, master, rule, reminders, cancelled, overrides, force_uid=False):
    """Modelo → texto del recurso. `original` (texto o None): se conserva todo lo no gestionado.
    master: dict de span + title + notes (+ floating). overrides: {rid: span+title+notes}."""
    cal = None
    if original:
        roots = parse(original)
        cal = next((c for c in roots if c.name == "VCALENDAR"), None)
    if cal is None:
        cal = Comp("VCALENDAR")
        cal.add("VERSION", "2.0")
        cal.add("PRODID", "-//Sumi Shell//Local calendar//EN")
    events = [c for c in cal.children if c.name == "VEVENT"]
    if force_uid:
        # Copia («las dos»): mismo contenido, identidad nueva en todos los VEVENT.
        for e in events:
            e.remove("UID")
            e.props.insert(0, Prop("UID", [], uid))
    vtz = {c.get("TZID").value: c for c in cal.children if c.name == "VTIMEZONE" and c.get("TZID")}
    mev = next((e for e in events if not e.get("RECURRENCE-ID")), None)
    if mev is None:
        mev = Comp("VEVENT")
        mev.add("UID", uid)
        cal.children.append(mev)
    extra = []
    if rule:
        extra.append(Prop("RRULE", [], R.to_ical(rule)))
        for d in rule.get("rdate") or []:
            if master["allDay"]:
                extra.append(Prop("RDATE", [("VALUE", "DATE")], d.replace("-", "")))
            else:
                extra.append(_rid_prop("RDATE", d + "T" + master["startTime"], master))
        for key in sorted(cancelled):
            extra.append(_rid_prop("EXDATE", key, master))
    _patch_event(mev, master, master["title"], master.get("notes", ""), extra)
    _set_alarms(mev, reminders, master["allDay"], master["title"])
    # Ocurrencias cambiadas: las que siguen se actualizan en su sitio; las nuevas se añaden;
    # las que ya no existen (canceladas o descartadas) se quitan.
    by_rid = {}
    for e in events:
        r = e.get("RECURRENCE-ID")
        if r:
            try:
                start = ("time", None, master.get("tz"), master.get("floating"), "") if not master["allDay"] else ("date",)
                by_rid[_rid_key(r, start, vtz, master.get("tz") or "UTC")] = e
            except Exception:  # noqa: BLE001 — una que no se entiende se conserva tal cual
                by_rid[r.value] = e
    keep_children = [c for c in cal.children if not (c.name == "VEVENT" and c.get("RECURRENCE-ID"))]
    for key, ov in sorted((overrides or {}).items()):
        e = by_rid.pop(key, None)
        if e is None:
            e = Comp("VEVENT")
            e.add("UID", uid)
            e.props.append(_rid_prop("RECURRENCE-ID", key, master))
        _patch_event(e, ov, ov["title"], ov.get("notes", ""))
        keep_children.append(e)
    for key, e in by_rid.items():
        if not RID_LIKE.match(key):
            keep_children.append(e)       # no la entendimos: se queda como estaba
    cal.children = keep_children
    return serialize(cal)


RID_LIKE = re.compile(r"^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2})?$")
