#!/usr/bin/env python3
"""Calendario local de la shell: eventos propios en SQLite (2026-10-27; v2 2026-10-28).

`services/CalendarStore.qml` y `services/Agenda.qml` lo lanzan bajo demanda, una petición por
proceso: un objeto JSON por stdin y una línea JSON por stdout (`ok` y lo demás). Sin daemon.

    $XDG_DATA_HOME/sumi-shell/calendar/events.sqlite3   (~/.local/share si no hay XDG)

Nunca en caché, runtime ni en el árbol de código. calcurse sólo se LEE, y sólo si se pide
una importación explícita (`calcurse -x ical`); nunca se modifica.

Órdenes (`op`):
    status                                  ruta, si existe, esquema y zona de la pantalla
    range   {from: AAAA-MM-DD, days: n}     ocurrencias por día civil de la zona del sistema
    get     {uuid}                          el evento con sus excepciones
    create  {uuid?, event}                  `uuid` del borrador: reintentar no duplica
    update  {uuid, revision, event, scope?, rid?}   scope: series (defecto) · occurrence · following
    delete  {uuid, revision, scope?, rid?}
    due     {from, to}                      recordatorios (UTC ISO) aún no registrados
    fire    {uuid, rid, offset, fire, state: shown|missed}   registra uno; `inserted` = era nuevo
    export  {path}                          ICS nuevo (nunca sobrescribe)
    import-preview {path | calcurse: true}  qué entraría, qué ya está y qué no se admite
    import  {… , digest}                    lo mismo, en una transacción, con copia previa

`event`: title, notes, allDay, reminders ([minutos antes], hasta 4), repeat (null o
{freq: daily|weekly|monthly|yearly, interval, byday: [MO…SU] (semanal), ends: {type: never |
until (date) | count (count)}}) y
    · todo el día: startDate y lastDate (último día, INCLUSIVO; se guarda el fin exclusivo);
    · con hora: tz (IANA), startDate/startTime, endDate/endTime (pared de esa zona) y,
      sólo si la hora es ambigua por un cambio de horario, startFold/endFold (0 la primera).
Recordatorios de todo el día: minutos antes de las 09:00 del primer día (zona de la pantalla).

Repeticiones (subconjunto de RFC 5545): DAILY, WEEKLY con BYDAY, MONTHLY por el día del mes
(los meses sin ese día se saltan), YEARLY por mes y día (29-II sólo en bisiestos); INTERVAL,
COUNT o UNTIL (fecha incluida). Las ocurrencias se calculan en la hora de pared de la zona del
evento: una hora inexistente se desplaza tras el salto y una ambigua toma la primera (RFC).
Cada ocurrencia tiene `rid` = su inicio original (AAAA-MM-DDTHH:MM, o AAAA-MM-DD todo el día);
las excepciones (cancelada o modificada) se guardan por `rid`. Editar «toda la serie» cambiando
su hora, fecha o regla descarta las excepciones (se devuelve cuántas); «desde aquí» parte la
serie: la vieja termina antes y nace otra con UUID nuevo.

Esquema 2 (desde 1, migrado en la primera escritura con copia previa
`events.sqlite3.v1-premigration-AAAAmmddTHHMMSS`). Un código de esquema 1 ante una base 2
responde `newer_schema`, nunca la reescribe.

Errores: {"ok": false, "error": {"code", "message", "field"?, ...}}. Salida 0 con ok, 1 con un
error explicado y 2 si falla el propio helper. Códigos: invalid, ambiguous_time,
nonexistent_time, not_found, conflict, exists, readonly, corrupt, newer_schema, foreign,
unavailable, io, bad_request, internal, unsupported.

Pruebas: con SUMI_CALENDAR_TEST=1 y la base bajo /tmp o /run/user, `.fail-next-write` junto
a la base hace fallar la siguiente escritura DESPUÉS de ejecutarla dentro de la transacción (se
revierte) y `.delay-next-write` (segundos) la retrasa; `calcurseDir` (calcurse -D) sólo se
admite entonces. Sin esas condiciones no existen.
"""
import sys
sys.dont_write_bytecode = True   # 2026-11-07: sin __pycache__ en el árbol de la shell (desinstalar lo dejaba a medias)
from bisect import bisect_left, bisect_right
import datetime as dt
import functools
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
import uuid as uuidlib
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

# `python3 -I` quita la carpeta del script de sys.path: los módulos hermanos se añaden a mano
# (pasó con hypr_dialect en F5f).
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import calendar_rrule as RR  # noqa: E402

SCHEMA = 3
APP_ID = 0x4B544341  # "KTCA"
MAX_TITLE = 200
MAX_NOTES = 8000
MAX_DAYS = 400
MAX_COUNT = 1000
MAX_REMINDER = 40320  # cuatro semanas
UTC = dt.timezone.utc
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
TIME_RE = re.compile(r"^([01]\d|2[0-3]):([0-5]\d)$")
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
TZ_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_+\-]*(/[A-Za-z0-9_+\-]+)*$")
RID_RE = re.compile(r"^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2})?$")
DAYS = ("MO", "TU", "WE", "TH", "FR", "SA", "SU")
FREQS = ("daily", "weekly", "monthly", "yearly")

EVENTS_V1 = """
CREATE TABLE events (
    uuid TEXT PRIMARY KEY NOT NULL CHECK (length(uuid) = 36),
    revision INTEGER NOT NULL CHECK (revision >= 1),
    title TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
    notes TEXT NOT NULL DEFAULT '' CHECK (length(notes) <= 8000),
    all_day INTEGER NOT NULL CHECK (all_day IN (0, 1)),
    tz TEXT,
    start_local TEXT,
    end_local TEXT,
    start_fold INTEGER NOT NULL DEFAULT 0 CHECK (start_fold IN (0, 1)),
    end_fold INTEGER NOT NULL DEFAULT 0 CHECK (end_fold IN (0, 1)),
    start_utc TEXT,
    end_utc TEXT,
    start_date TEXT,
    end_date TEXT,
    created_utc TEXT NOT NULL,
    updated_utc TEXT NOT NULL,
    CHECK ((all_day = 1 AND start_date IS NOT NULL AND end_date > start_date
                AND start_utc IS NULL AND tz IS NULL)
        OR (all_day = 0 AND start_utc IS NOT NULL AND end_utc > start_utc
                AND tz IS NOT NULL AND start_date IS NULL))
);
CREATE INDEX events_timed ON events (start_utc, end_utc) WHERE all_day = 0;
CREATE INDEX events_all_day ON events (start_date, end_date) WHERE all_day = 1
"""
# v1 → v2: sólo añade (columnas con valor por defecto y tablas nuevas).
UPGRADE_V2 = """
ALTER TABLE events ADD COLUMN rrule TEXT;
ALTER TABLE events ADD COLUMN reminders TEXT NOT NULL DEFAULT '[]';
ALTER TABLE events ADD COLUMN ext_uid TEXT;
CREATE UNIQUE INDEX events_ext_uid ON events (ext_uid) WHERE ext_uid IS NOT NULL;
CREATE TABLE exceptions (
    uuid TEXT NOT NULL REFERENCES events (uuid) ON DELETE CASCADE,
    rid TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('cancelled', 'modified')),
    title TEXT, notes TEXT, all_day INTEGER, tz TEXT, start_local TEXT, end_local TEXT,
    start_fold INTEGER, end_fold INTEGER, start_utc TEXT, end_utc TEXT, start_date TEXT, end_date TEXT,
    PRIMARY KEY (uuid, rid)
);
CREATE TABLE reminder_log (
    uuid TEXT NOT NULL,
    rid TEXT NOT NULL,
    offset_min INTEGER NOT NULL,
    fire_utc TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('shown', 'missed')),
    at_utc TEXT NOT NULL,
    PRIMARY KEY (uuid, rid, offset_min)
)
"""
# v2 → v3 (CalDAV): calendarios y cuentas, identidad remota, original iCalendar, borrados
# pendientes, conflictos y registro. Sólo añade; lo existente queda en «On this computer».
UPGRADE_V3 = """
ALTER TABLE events ADD COLUMN calendar_id TEXT NOT NULL DEFAULT 'local';
ALTER TABLE events ADD COLUMN href TEXT;
ALTER TABLE events ADD COLUMN etag TEXT;
ALTER TABLE events ADD COLUMN sync_state TEXT NOT NULL DEFAULT 'local';
ALTER TABLE events ADD COLUMN raw_ics TEXT;
ALTER TABLE events ADD COLUMN ical_uid TEXT;
ALTER TABLE events ADD COLUMN readonly_reason TEXT;
ALTER TABLE events ADD COLUMN floating INTEGER NOT NULL DEFAULT 0;
CREATE UNIQUE INDEX events_href ON events (calendar_id, href) WHERE href IS NOT NULL;
CREATE INDEX events_calendar ON events (calendar_id);
CREATE TABLE accounts (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    server_url TEXT NOT NULL,
    username TEXT NOT NULL,
    home_url TEXT,
    interval_min INTEGER NOT NULL DEFAULT 30 CHECK (interval_min BETWEEN 0 AND 1440),
    enabled INTEGER NOT NULL DEFAULT 1,
    last_sync_utc TEXT,
    last_ok_utc TEXT,
    last_error TEXT,
    created_utc TEXT NOT NULL
);
CREATE TABLE calendars (
    id TEXT PRIMARY KEY NOT NULL,
    account_id TEXT REFERENCES accounts (id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind IN ('local', 'caldav')),
    name TEXT NOT NULL,
    color TEXT,
    url TEXT,
    read_only INTEGER NOT NULL DEFAULT 0,
    visible INTEGER NOT NULL DEFAULT 1,
    sync_token TEXT,
    ctag TEXT,
    last_sync_utc TEXT
);
INSERT INTO calendars (id, kind, name, visible) VALUES ('local', 'local', 'On this computer', 1);
CREATE TABLE tombstones (
    calendar_id TEXT NOT NULL,
    href TEXT NOT NULL,
    etag TEXT,
    ical_uid TEXT,
    title TEXT,
    raw_ics TEXT,
    deleted_utc TEXT NOT NULL,
    PRIMARY KEY (calendar_id, href)
);
CREATE TABLE conflicts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    calendar_id TEXT NOT NULL,
    href TEXT NOT NULL,
    uuid TEXT,
    kind TEXT NOT NULL,
    title TEXT,
    local_ics TEXT,
    remote_ics TEXT,
    remote_etag TEXT,
    created_utc TEXT NOT NULL,
    UNIQUE (calendar_id, href)
);
CREATE TABLE remote_other (
    calendar_id TEXT NOT NULL,
    href TEXT NOT NULL,
    etag TEXT,
    reason TEXT,
    PRIMARY KEY (calendar_id, href)
);
CREATE TABLE sync_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id TEXT,
    started_utc TEXT,
    finished_utc TEXT,
    result TEXT,
    pulled INTEGER,
    pushed INTEGER,
    deleted INTEGER,
    conflicts INTEGER,
    error TEXT
)
"""


class Fail(Exception):
    def __init__(self, code, message, **extra):
        super().__init__(message)
        self.code = code
        self.message = message
        self.extra = extra


def reply(ok, **kw):
    kw["ok"] = ok
    sys.stdout.write(json.dumps(kw, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def statements(sql):
    return [s for s in sql.split(";") if s.strip()]


# ---- rutas y zonas -------------------------------------------------------------------------

def db_path():
    base = os.environ.get("XDG_DATA_HOME", "")
    if not base.startswith("/"):
        # La especificación XDG manda ignorar una ruta relativa.
        base = os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, "sumi-shell", "calendar", "events.sqlite3")


@functools.lru_cache(maxsize=1)
def display_zone():
    """La zona con la que la shell enseña las fechas: la del proceso (TZ o /etc/localtime)."""
    name = os.environ.get("TZ", "").lstrip(":")
    if name:
        try:
            return name, ZoneInfo(name)
        except (ZoneInfoNotFoundError, ValueError):
            pass
    try:
        target = os.path.realpath("/etc/localtime")
        if "/zoneinfo/" in target:
            key = target.split("/zoneinfo/", 1)[1]
            return key, ZoneInfo(key)
        with open("/etc/localtime", "rb") as f:
            return "localtime", ZoneInfo.from_file(f)
    except (OSError, ZoneInfoNotFoundError, ValueError):
        return "UTC", ZoneInfo("UTC")


@functools.lru_cache(maxsize=64)
def zone_of(name):
    return ZoneInfo(name)


def zone(name, field="tz"):
    if not isinstance(name, str) or not TZ_RE.match(name) or ".." in name or len(name) > 64:
        raise Fail("invalid", "Unknown time zone", field=field)
    try:
        return zone_of(name)
    except (ZoneInfoNotFoundError, ValueError):
        raise Fail("invalid", "Unknown time zone: " + name, field=field)


def iso_utc(t):
    return t.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def from_utc(s):
    return dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)


def now_utc():
    return iso_utc(dt.datetime.now(UTC))


# ---- validación ----------------------------------------------------------------------------

def parse_date(value, field):
    if not isinstance(value, str) or not DATE_RE.match(value):
        raise Fail("invalid", "Use the format YYYY-MM-DD", field=field)
    try:
        d = dt.date.fromisoformat(value)
    except ValueError:
        raise Fail("invalid", value + " is not a valid date", field=field)
    if not 1900 <= d.year <= 2200:
        raise Fail("invalid", "The year must be between 1900 and 2200", field=field)
    return d


def parse_time(value, field):
    if not isinstance(value, str):
        raise Fail("invalid", "Use the format HH:MM (24 h)", field=field)
    m = TIME_RE.match(value)
    if not m:
        raise Fail("invalid", "Use the format HH:MM (24 h)", field=field)
    return dt.time(int(m.group(1)), int(m.group(2)))


def offset_label(t):
    off = t.utcoffset()
    total = int(off.total_seconds() // 60)
    sign = "+" if total >= 0 else "\u2212"
    total = abs(total)
    name = t.tzname() or ""
    return "%s (UTC%s%02d:%02d)" % (name, sign, total // 60, total % 60)


def resolve_wall(day, clock, tz, tzname, fold, field):
    """Hora de pared → instante, tratando explícitamente huecos y repeticiones."""
    naive = dt.datetime.combine(day, clock)
    a = naive.replace(tzinfo=tz, fold=0)
    b = naive.replace(tzinfo=tz, fold=1)
    back = a.astimezone(UTC).astimezone(tz).replace(tzinfo=None)
    if back != naive and b.astimezone(UTC).astimezone(tz).replace(tzinfo=None) != naive:
        raise Fail("nonexistent_time", "%s does not exist on %s in %s: the clocks move forward"
                   % (clock.strftime("%H:%M"), day.isoformat(), tzname), field=field)
    if a.utcoffset() != b.utcoffset():
        if fold not in (0, 1):
            raise Fail("ambiguous_time", "%s happens twice on %s in %s: choose which one"
                       % (clock.strftime("%H:%M"), day.isoformat(), tzname), field=field,
                       options=[{"fold": 0, "label": clock.strftime("%H:%M") + " " + offset_label(a)},
                                {"fold": 1, "label": clock.strftime("%H:%M") + " " + offset_label(b)}])
        return (b if fold == 1 else a), fold
    return a, 0


def wall_instant(naive, tz, fold=0):
    """Ocurrencias generadas (RFC 5545): un hueco usa el desfase previo (cae tras el salto) y
    una hora repetida toma la primera, salvo que la serie guardara `fold`."""
    return naive.replace(tzinfo=tz, fold=fold).astimezone(UTC)


def clean_text(event):
    title = event.get("title")
    if not isinstance(title, str) or not title.strip():
        raise Fail("invalid", "The title is required", field="title")
    title = title.strip()
    if "\n" in title or "\r" in title:
        raise Fail("invalid", "The title must be a single line", field="title")
    if any(ord(c) < 32 for c in title):
        raise Fail("invalid", "The title contains control characters", field="title")
    if len(title) > MAX_TITLE:
        raise Fail("invalid", "The title can have up to %d characters" % MAX_TITLE, field="title")
    notes = event.get("notes", "")
    if notes is None:
        notes = ""
    if not isinstance(notes, str):
        raise Fail("invalid", "The notes must be text", field="notes")
    notes = notes.replace("\r\n", "\n").rstrip()
    if len(notes) > MAX_NOTES:
        raise Fail("invalid", "The notes can have up to %d characters" % MAX_NOTES, field="notes")
    return title, notes


def clean_reminders(value):
    if value is None:
        return []
    if not isinstance(value, list) or len(value) > 4:
        raise Fail("invalid", "Up to four reminders", field="reminders")
    out = []
    for v in value:
        if not isinstance(v, int) or isinstance(v, bool) or not 0 <= v <= MAX_REMINDER:
            raise Fail("invalid", "A reminder must be between 0 minutes and 4 weeks before", field="reminders")
        if v not in out:
            out.append(v)
    return sorted(out)


def clean_repeat(value, start):
    """→ dict normalizado o None. `start` es la fecha de inicio (pared del evento)."""
    if value is None:
        return None
    if isinstance(value, dict) and (value.get("custom") or any(not str(d).isalpha() for d in value.get("byday") or [])):
        return clean_custom(value, start)
    if not isinstance(value, dict) or value.get("freq") not in FREQS:
        raise Fail("invalid", "Choose how the event repeats", field="repeat")
    interval = value.get("interval", 1)
    if not isinstance(interval, int) or isinstance(interval, bool) or not 1 <= interval <= 999:
        raise Fail("invalid", "Repeat every 1 to 999", field="interval")
    rule = {"freq": value["freq"], "interval": interval, "byday": None, "count": None, "until": None}
    if value["freq"] == "weekly":
        byday = value.get("byday") or [DAYS[start.weekday()]]
        if not isinstance(byday, list) or not byday or any(d not in DAYS for d in byday):
            raise Fail("invalid", "Choose at least one weekday", field="byday")
        rule["byday"] = [d for d in DAYS if d in byday]
    ends = value.get("ends") or {"type": "never"}
    if not isinstance(ends, dict) or ends.get("type") not in ("never", "until", "count"):
        raise Fail("invalid", "Choose when the repetition ends", field="ends")
    if ends["type"] == "until":
        until = parse_date(ends.get("date"), "until")
        if until < start:
            raise Fail("invalid", "The repetition cannot end before the first day", field="until")
        rule["until"] = until.isoformat()
    elif ends["type"] == "count":
        count = ends.get("count")
        if not isinstance(count, int) or isinstance(count, bool) or not 1 <= count <= MAX_COUNT:
            raise Fail("invalid", "Repeat between 1 and %d times" % MAX_COUNT, field="count")
        rule["count"] = count
    return rule


def clean_custom(value, start):
    """Una regla ampliada que vuelve tal cual del formulario (o de la importación)."""
    rule = {"freq": value.get("freq"), "interval": value.get("interval") or 1}
    if value.get("byday"):
        rule["byday"] = list(value["byday"])
    for k in CUSTOM_KEYS:
        v = (value.get("custom") or {}).get(k)
        if v:
            rule[k] = v
    ends = value.get("ends") or {"type": "never"}
    if ends.get("type") == "count":
        rule["count"] = ends.get("count")
    elif ends.get("type") == "until":
        rule["until"] = ends.get("date")
    try:
        RR.check(rule)
        if rule.get("count") is not None and (not isinstance(rule["count"], int) or not 1 <= rule["count"] <= MAX_COUNT):
            raise RR.Unsupported("COUNT=%s" % rule["count"])
        if rule.get("until"):
            if parse_date(rule["until"], "until") < start:
                raise Fail("invalid", "The repetition cannot end before the first day", field="until")
    except RR.Unsupported as e:
        raise Fail("invalid", "Repetition not supported: %s" % e, field="repeat")
    return {k: rule[k] for k in sorted(rule)}


def validate(event, allow_repeat=True):
    """Un evento de entrada → columnas de la tabla (sin uuid, revisión ni fechas de registro)."""
    if not isinstance(event, dict):
        raise Fail("bad_request", "event must be an object")
    title, notes = clean_text(event)
    all_day = event.get("allDay")
    if not isinstance(all_day, bool):
        raise Fail("bad_request", "allDay must be true or false")
    reminders = clean_reminders(event.get("reminders"))
    if all_day:
        start = parse_date(event.get("startDate"), "startDate")
        last = parse_date(event.get("lastDate"), "lastDate")
        if last < start:
            raise Fail("invalid", "The last day cannot be before the first day", field="lastDate")
        cols = {"title": title, "notes": notes, "all_day": 1, "tz": None,
                "start_local": None, "end_local": None, "start_fold": 0, "end_fold": 0,
                "start_utc": None, "end_utc": None,
                "start_date": start.isoformat(), "end_date": (last + dt.timedelta(days=1)).isoformat()}
    else:
        tzname = event.get("tz")
        tz = zone(tzname)
        sd = parse_date(event.get("startDate"), "startDate")
        st = parse_time(event.get("startTime"), "startTime")
        ed = parse_date(event.get("endDate"), "endDate")
        et = parse_time(event.get("endTime"), "endTime")
        start_i, sfold = resolve_wall(sd, st, tz, tzname, event.get("startFold"), "startTime")
        end_i, efold = resolve_wall(ed, et, tz, tzname, event.get("endFold"), "endTime")
        if end_i <= start_i:
            raise Fail("invalid", "The end must be after the start", field="endTime")
        start = sd
        cols = {"title": title, "notes": notes, "all_day": 0, "tz": tzname,
                "start_local": sd.isoformat() + "T" + st.strftime("%H:%M"),
                "end_local": ed.isoformat() + "T" + et.strftime("%H:%M"),
                "start_fold": sfold, "end_fold": efold,
                "start_utc": iso_utc(start_i), "end_utc": iso_utc(end_i),
                "start_date": None, "end_date": None}
    repeat = event.get("repeat")
    if repeat is not None and not allow_repeat:
        raise Fail("invalid", "One occurrence cannot have its own repetition", field="repeat")
    rule = clean_repeat(repeat, start) if allow_repeat else None
    cols["rrule"] = json.dumps(rule, sort_keys=True) if rule else None
    cols["reminders"] = json.dumps(reminders)
    cols["floating"] = 1 if event.get("floating") is True and not all_day else 0
    return cols


# ---- la base ---------------------------------------------------------------------------------

def classify(e):
    msg = str(e)
    low = msg.lower()
    if "readonly" in low or "read-only" in low:
        return Fail("readonly", "The calendar database is read-only")
    if "not a database" in low or "malformed" in low or "corrupt" in low:
        return Fail("corrupt", "The calendar database is damaged: " + msg)
    if "disk is full" in low or "disk i/o" in low:
        return Fail("io", "Could not write the calendar database: " + msg)
    if "unable to open" in low:
        return Fail("unavailable", "Could not open the calendar database")
    if "locked" in low or "busy" in low:
        return Fail("unavailable", "The calendar database is busy; try again")
    return Fail("io", "Calendar database error: " + msg)


def check_schema(conn, fresh_ok):
    """→ ("empty"|"ok", versión)."""
    try:
        app = conn.execute("PRAGMA application_id").fetchone()[0]
        ver = conn.execute("PRAGMA user_version").fetchone()[0]
        tables = [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")]
        if conn.execute("PRAGMA quick_check").fetchone()[0] != "ok":
            raise Fail("corrupt", "The calendar database failed its integrity check")
    except sqlite3.DatabaseError as e:
        raise classify(e)
    if not tables and ver == 0 and app == 0:
        if fresh_ok:
            return "empty", 0
        raise Fail("unavailable", "The calendar database is not initialised")
    if app != APP_ID:
        raise Fail("foreign", "This file is not a Sumi Shell calendar")
    if ver > SCHEMA:
        raise Fail("newer_schema", "The calendar was saved by a newer version of the shell (schema %d)" % ver)
    if ver < 1 or "events" not in tables or (ver >= 2 and "exceptions" not in tables) or (ver >= 3 and "calendars" not in tables):
        raise Fail("corrupt", "The calendar database has an unknown layout")
    return "ok", ver


class Db:
    """Una conexión con la versión conocida: la lectura acepta el esquema 1 sin migrarlo."""

    def __init__(self, conn, version):
        self.conn = conn
        self.version = version

    def execute(self, *a):
        return self.conn.execute(*a)

    def close(self):
        self.conn.close()


def open_read(path):
    """Sólo lectura: una carpeta no escribible no impide leer. None si aún no hay base."""
    if not os.path.exists(path):
        return None
    try:
        conn = sqlite3.connect("file:%s?mode=ro" % path, uri=True, isolation_level=None, timeout=3)
    except sqlite3.Error as e:
        raise classify(e)
    state, ver = check_schema(conn, fresh_ok=True)
    if state == "empty":
        conn.close()
        return None
    return Db(conn, ver)


def snapshot(conn, path, label):
    """Copia consistente de la base (API de backup de SQLite), FUERA de cualquier transacción
    de esta conexión: hecha desde dentro de su propia escritura se bloquea (medido)."""
    stamp = dt.datetime.now(UTC).strftime("%Y%m%dT%H%M%S")
    copy = "%s.%s-%s" % (path, label, stamp)
    n = 1
    while os.path.exists(copy):
        n += 1
        copy = "%s.%s-%s-%d" % (path, label, stamp, n)
    dest = sqlite3.connect(copy)
    try:
        conn.backup(dest)
    finally:
        dest.close()
    os.chmod(copy, 0o600)
    return copy


def migrate(conn, ver):
    """Esquema `ver` → actual dentro de la transacción abierta (la copia ya está hecha)."""
    steps = {1: UPGRADE_V2, 2: UPGRADE_V3}
    while ver < SCHEMA:
        for stmt in statements(steps[ver]):
            conn.execute(stmt)
        ver += 1
    conn.execute("PRAGMA user_version = %d" % SCHEMA)


def open_write(path):
    os.umask(0o077)
    try:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    except OSError as e:
        raise Fail("readonly", "Cannot create the calendar folder: " + (e.strerror or str(e)))
    if os.path.exists(path) and not os.access(path, os.W_OK):
        raise Fail("readonly", "The calendar database is read-only")
    migrated = None
    try:
        conn = sqlite3.connect(path, isolation_level=None, timeout=3)
        conn.execute("PRAGMA busy_timeout = 3000")
        conn.execute("PRAGMA foreign_keys = ON")
        state, ver = check_schema(conn, fresh_ok=True)
        copy = snapshot(conn, path, "v%d-premigration" % ver) if state == "ok" and ver < SCHEMA else None
        old_ver = ver
        if state == "empty" or ver < SCHEMA:
            conn.execute("BEGIN IMMEDIATE")
            try:
                state, ver = check_schema(conn, fresh_ok=True)
                if state == "empty":
                    # Sentencia a sentencia: executescript() haría COMMIT de esta transacción.
                    for stmt in statements(EVENTS_V1) + statements(UPGRADE_V2) + statements(UPGRADE_V3):
                        conn.execute(stmt)
                    conn.execute("PRAGMA application_id = %d" % APP_ID)
                    conn.execute("PRAGMA user_version = %d" % SCHEMA)
                elif ver < SCHEMA:
                    migrate(conn, ver)
                    migrated = (old_ver, copy)
                conn.execute("COMMIT")
            except BaseException:
                rollback(conn)
                raise
    except sqlite3.Error as e:
        raise classify(e)
    db = Db(conn, SCHEMA)
    db.migrated = migrated
    return db


def rollback(conn):
    if conn.in_transaction:
        try:
            conn.execute("ROLLBACK")
        except sqlite3.Error:
            pass


def bench_path(path):
    if os.environ.get("SUMI_CALENDAR_TEST") != "1":
        return False
    real = os.path.realpath(path)
    return real.startswith("/tmp/") or real.startswith("/run/user/")


def test_hooks(path):
    """Fallos/esperas inyectables SOLO en bancos (ver la cabecera)."""
    if not bench_path(path):
        return
    folder = os.path.dirname(path)
    delay = os.path.join(folder, ".delay-next-write")
    if os.path.exists(delay):
        try:
            secs = float(open(delay).read().strip() or "1")
        finally:
            os.unlink(delay)
        time.sleep(max(0.0, min(secs, 20.0)))
    fail = os.path.join(folder, ".fail-next-write")
    if os.path.exists(fail):
        os.unlink(fail)
        raise Fail("io", "Simulated write failure (test bench)")


def write(path, fn):
    db = open_write(path)
    try:
        db.execute("BEGIN IMMEDIATE")
        try:
            result = fn(db)
            test_hooks(path)
            db.execute("COMMIT")
            if db.migrated:
                result = dict(result, migratedFrom=db.migrated[0], premigrationCopy=db.migrated[1])
            return result
        except BaseException:
            rollback(db.conn)
            raise
    except sqlite3.Error as e:
        raise classify(e)
    finally:
        db.close()


BASE_COLS = ("uuid", "revision", "title", "notes", "all_day", "tz", "start_local", "end_local",
             "start_fold", "end_fold", "start_utc", "end_utc", "start_date", "end_date",
             "created_utc", "updated_utc")
V2_COLS = ("rrule", "reminders", "ext_uid")
V3_COLS = ("calendar_id", "href", "etag", "sync_state", "raw_ics", "ical_uid", "readonly_reason", "floating")
COLS = BASE_COLS + V2_COLS + V3_COLS
V3_DEFAULTS = "'local' AS calendar_id, NULL AS href, NULL AS etag, 'local' AS sync_state, NULL AS raw_ics, NULL AS ical_uid, NULL AS readonly_reason, 0 AS floating"
SPAN = ("title", "notes", "all_day", "tz", "start_local", "end_local", "start_fold", "end_fold",
        "start_utc", "end_utc", "start_date", "end_date")


def select_cols(db):
    if db.version >= 3:
        return ", ".join(COLS)
    if db.version == 2:
        return ", ".join(BASE_COLS + V2_COLS) + ", " + V3_DEFAULTS
    return ", ".join(BASE_COLS) + ", NULL AS rrule, '[]' AS reminders, NULL AS ext_uid, " + V3_DEFAULTS


def span_fields(r):
    """Fechas de un registro (evento o excepción) en la forma de la API."""
    if r["all_day"]:
        last = dt.date.fromisoformat(r["end_date"]) - dt.timedelta(days=1)
        return dict(allDay=True, startDate=r["start_date"], lastDate=last.isoformat(), endDateExclusive=r["end_date"],
                    tz="", startTime="", endDate=last.isoformat(), endTime="", startFold=0, endFold=0,
                    displayDate=r["start_date"])
    sd, stime = r["start_local"].split("T")
    ed, etime = r["end_local"].split("T")
    return dict(allDay=False, tz=r["tz"], startDate=sd, startTime=stime, endDate=ed, endTime=etime,
                startFold=r["start_fold"], endFold=r["end_fold"],
                startUtc=r["start_utc"], endUtc=r["end_utc"], lastDate="", endDateExclusive="",
                # El día civil de la PANTALLA en que empieza (puede no ser startDate si la zona difiere).
                displayDate=from_utc(r["start_utc"]).astimezone(display_zone()[1]).date().isoformat())


CUSTOM_KEYS = ("bymonth", "bymonthday", "bysetpos", "wkst", "rdate")


def repeat_api(rule):
    if not rule:
        return None
    ends = {"type": "never"}
    if rule.get("count"):
        ends = {"type": "count", "count": rule["count"]}
    elif rule.get("until"):
        ends = {"type": "until", "date": rule["until"]}
    out = {"freq": rule["freq"], "interval": rule.get("interval") or 1, "byday": rule.get("byday"), "ends": ends}
    if not RR.is_simple(rule):
        # Una regla que el formulario no sabe editar (llega de un servidor o de un .ics): viaja entera.
        out["custom"] = {k: rule[k] for k in CUSTOM_KEYS if rule.get(k)}
        out["text"] = RR.to_ical(rule)
    return out


def record(row):
    r = dict(zip(COLS, row))
    rule = json.loads(r["rrule"]) if r["rrule"] else None
    out = {"source": "local", "uuid": r["uuid"], "revision": r["revision"], "title": r["title"],
           "notes": r["notes"], "created": r["created_utc"], "updated": r["updated_utc"],
           "repeat": repeat_api(rule), "reminders": json.loads(r["reminders"] or "[]"),
           "external": r["ext_uid"] or "", "calendarId": r["calendar_id"], "syncState": r["sync_state"],
           "readOnly": r["readonly_reason"] or "", "floating": bool(r["floating"])}
    out.update(span_fields(r))
    out["_row"] = r
    out["_rule"] = rule
    return out


def public(ev):
    return {k: v for k, v in ev.items() if not k.startswith("_")}


def fetch(db, uid):
    row = db.execute("SELECT %s FROM events WHERE uuid = ?" % select_cols(db), (uid,)).fetchone()
    return record(row) if row else None


EXC_COLS = ("uuid", "rid", "kind") + SPAN


def exceptions_of(db, uid):
    if db.version < 2:
        return {}
    rows = db.execute("SELECT %s FROM exceptions WHERE uuid = ?" % ", ".join(EXC_COLS), (uid,)).fetchall()
    return {r[1]: dict(zip(EXC_COLS, r)) for r in rows}


# ---- repeticiones ----------------------------------------------------------------------------------

def rule_dates(rule, start, upto, from_date=None):
    """Fechas de la serie (pared del evento) hasta `upto` incluido: `calendar_rrule` (RFC 5545;
    el DTSTART es siempre la primera). Una regla guardada que ya no se entiende enseña su inicio."""
    try:
        return RR.dates(rule, start, upto, from_date)
    except RR.Unsupported:
        return [start] if start <= upto else []


def master_occurrences(ev, upto_date, from_date=None):
    """[(rid, start, end)] de la serie SIN excepciones; start/end: instantes UTC o fechas civiles.
    `from_date` sólo permite saltar periodos (series largas sin COUNT); con margen por la duración."""
    r, rule = ev["_row"], ev["_rule"]
    if from_date is not None:
        span_days = ((dt.date.fromisoformat(r["end_date"]) - dt.date.fromisoformat(r["start_date"])).days if r["all_day"]
                     else (from_utc(r["end_utc"]) - from_utc(r["start_utc"])).days) + 2
        from_date = from_date - dt.timedelta(days=span_days)
    if r["all_day"]:
        s = dt.date.fromisoformat(r["start_date"])
        length = dt.date.fromisoformat(r["end_date"]) - s
        dates = rule_dates(rule, s, upto_date, from_date) if rule else [s]
        return [(d.isoformat(), d, d + length) for d in dates]
    tz = zone_of(r["tz"])
    s0 = dt.datetime.fromisoformat(r["start_local"])
    dur = from_utc(r["end_utc"]) - from_utc(r["start_utc"])
    if not rule:
        return [(r["start_local"], from_utc(r["start_utc"]), from_utc(r["end_utc"]))]
    out = []
    for d in rule_dates(rule, s0.date(), upto_date, from_date):
        naive = dt.datetime.combine(d, s0.time())
        start = from_utc(r["start_utc"]) if d == s0.date() else wall_instant(naive, tz, 0)
        out.append((naive.strftime("%Y-%m-%dT%H:%M"), start, start + dur))
    return out


def occurrences(db, ev, upto_date, from_date=None):
    """Genera inicios originales sin excepción y los intervalos efectivos de las modificadas."""
    exc = exceptions_of(db, ev["uuid"]) if ev["_rule"] else {}
    for rid, s, e in master_occurrences(ev, upto_date, from_date):
        if rid not in exc:
            yield rid, s, e, None
    # El rid identifica la cita incluso si la movieron desde fuera de la ventana, en ambos sentidos.
    for rid, x in exc.items():
        if x["kind"] != "modified" or not RID_RE.fullmatch(rid):
            continue
        if x["all_day"]:
            yield rid, dt.date.fromisoformat(x["start_date"]), dt.date.fromisoformat(x["end_date"]), x
        else:
            yield rid, from_utc(x["start_utc"]), from_utc(x["end_utc"]), x


def rid_exists(ev, rid):
    if not isinstance(rid, str) or not RID_RE.match(rid):
        raise Fail("bad_request", "rid must be an original start")
    upto = dt.date.fromisoformat(rid[:10])
    return any(o[0] == rid for o in master_occurrences(ev, upto, upto))


# ---- calendarios y sincronización (parte local) -------------------------------------------------

def calendars_map(db):
    if db.version < 3:
        return {"local": {"id": "local", "kind": "local", "name": "On this computer", "color": "", "readOnly": False, "visible": True,
                          "accountId": None, "url": None}}
    out = {}
    for cid, acc, kind, name, color, url, ro, vis in db.execute(
            "SELECT id, account_id, kind, name, color, url, read_only, visible FROM calendars"):
        out[cid] = {"id": cid, "accountId": acc, "kind": kind, "name": name, "color": ui_color(color), "url": url,
                    "readOnly": bool(ro), "visible": bool(vis)}
    return out


def target_calendar(db, cid):
    cals = calendars_map(db)
    c = cals.get(cid or "local")
    if not c:
        raise Fail("invalid", "That calendar no longer exists", field="calendarId")
    if c["readOnly"]:
        raise Fail("readonly_calendar", "The calendar \u201c%s\u201d is read-only" % c["name"], field="calendarId")
    return c


def editable_guard(db, ev):
    """Lo que no se puede tocar: original no admitido, calendario de sólo lectura, conflicto abierto."""
    if ev["readOnly"]:
        raise Fail("readonly_event", "This event is read-only here: %s" % ev["readOnly"])
    c = calendars_map(db).get(ev["calendarId"])
    if c and c["readOnly"]:
        raise Fail("readonly_calendar", "The calendar \u201c%s\u201d is read-only" % c["name"])
    if ev["syncState"] == "conflict":
        raise Fail("conflict_pending", "Resolve the sync conflict of this event first (Accounts)")


def remote_slot(cal, uid, ical_uid=None):
    """Identidad en un calendario CalDAV para un evento que todavía no está en el servidor."""
    base = cal["url"] if cal["url"].endswith("/") else cal["url"] + "/"
    return {"calendar_id": cal["id"], "href": base + uid + ".ics", "etag": None, "sync_state": "new",
            "ical_uid": ical_uid or (uid + "@sumi-shell")}


def mark_dirty(db, uid):
    """Tras cambiar un evento: lo sincronizado pasa a pendiente; lo nuevo sigue nuevo."""
    if db.version >= 3:
        db.execute("UPDATE events SET sync_state = 'dirty' WHERE uuid = ? AND sync_state = 'synced'", (uid,))


def tombstone(db, ev):
    """Borrado de algo que existe en el servidor: queda pendiente hasta que el servidor lo confirme."""
    r = ev["_row"]
    if db.version >= 3 and r["href"] and r["etag"] and r["sync_state"] in ("synced", "dirty"):
        db.execute("INSERT OR REPLACE INTO tombstones (calendar_id, href, etag, ical_uid, title, raw_ics, deleted_utc)"
                   " VALUES (?, ?, ?, ?, ?, ?, ?)", (r["calendar_id"], r["href"], r["etag"], r["ical_uid"], r["title"],
                                                      r["raw_ics"], now_utc()))
        return True
    return False


# ---- órdenes ---------------------------------------------------------------------------------

def need_uuid(req):
    uid = req.get("uuid")
    if not isinstance(uid, str) or not UUID_RE.match(uid):
        raise Fail("bad_request", "uuid must be a lowercase UUID")
    return uid


def need_revision(req):
    rev = req.get("revision")
    if not isinstance(rev, int) or isinstance(rev, bool) or rev < 1:
        raise Fail("bad_request", "revision must be a positive integer")
    return rev


def op_status(path, req):
    name, _ = display_zone()
    db = open_read(path)
    count, ver = 0, 0
    if db:
        try:
            count = db.execute("SELECT COUNT(*) FROM events").fetchone()[0]
            ver = db.version
        finally:
            db.close()
    return {"db": path, "exists": db is not None, "schema": SCHEMA, "fileSchema": ver, "events": count, "displayTz": name}


def op_range(path, req):
    first = parse_date(req.get("from"), "from")
    days = req.get("days")
    if not isinstance(days, int) or isinstance(days, bool) or not 1 <= days <= MAX_DAYS:
        raise Fail("bad_request", "days must be between 1 and %d" % MAX_DAYS)
    name, disp = display_zone()
    dates = [first + dt.timedelta(days=i) for i in range(days + 1)]
    # El primer instante de cada día civil de la pantalla (fold=0 cae en el salto si
    # la medianoche no existe).
    bounds = [dt.datetime.combine(d, dt.time(0, 0)).replace(tzinfo=disp).astimezone(UTC) for d in dates]
    out = {"displayTz": name, "from": first.isoformat(), "days": days, "items": []}
    db = open_read(path)
    if db is None:
        out["exists"] = False
        return out
    out["exists"] = True
    items = []
    try:
        cals = calendars_map(db)
        out["calendars"] = list(cals.values())
        rows = db.execute(
            "SELECT %s FROM events WHERE rrule IS NOT NULL OR (all_day = 0 AND start_utc < ? AND end_utc > ?)"
            " OR (all_day = 1 AND start_date < ? AND end_date > ?)"
            % select_cols(db) if db.version >= 2 else
            "SELECT %s FROM events WHERE (all_day = 0 AND start_utc < ? AND end_utc > ?)"
            " OR (all_day = 1 AND start_date < ? AND end_date > ?)" % select_cols(db),
            (iso_utc(bounds[-1]), iso_utc(bounds[0]), dates[-1].isoformat(), dates[0].isoformat())).fetchall()
        # La fecha de inicio en la zona del evento puede ir por delante de la pantalla.
        upto = dates[-1] + dt.timedelta(days=1)
        for row in rows:
            ev = record(row)
            cal = cals.get(ev["calendarId"]) or {"name": "?", "color": "", "readOnly": True, "visible": True, "kind": "local"}
            if not cal["visible"]:
                continue
            ev["_cal"] = cal
            for rid, s, e, x in occurrences(db, ev, upto, dates[0]):
                all_day = bool(x["all_day"]) if x else ev["allDay"]
                if all_day:
                    for i in range(max(0, (s - first).days), min(days, (e - first).days)):
                        items.append(occurrence(ev, rid, x, dates[i], "", "", 0))
                    continue
                # Sólo los días que se solapan con [s, e). Las medianoches ya están en UTC,
                # también cuando el día civil de la pantalla dura 23 o 25 horas.
                first_day = max(0, bisect_right(bounds, s) - 1)
                stop_day = min(days, bisect_left(bounds, e))
                for i in range(first_day, stop_day):
                    lo, hi = bounds[i], bounds[i + 1]
                    start = s.astimezone(disp).strftime("%H:%M") if s >= lo else "..:.."
                    end = e.astimezone(disp).strftime("%H:%M") if e <= hi else "..:.."
                    items.append(occurrence(ev, rid, x, dates[i], start, end, int((e - s).total_seconds())))
    except sqlite3.DatabaseError as e:
        raise classify(e)
    finally:
        db.close()
    items.sort(key=lambda it: (it["date"], not it["allDay"], "" if it["start"] == "..:.." else it["start"], it["message"].lower()))
    out["items"] = items
    return out


def occurrence(ev, rid, x, day, start, end, duration):
    recurring = ev["_rule"] is not None
    title = x["title"] if x else ev["title"]
    notes = x["notes"] if x else ev["notes"]
    span = span_fields(x) if x else {k: ev[k] for k in ("allDay", "tz", "startDate", "startTime", "endDate", "endTime",
                                                        "startFold", "endFold", "lastDate", "endDateExclusive", "displayDate")}
    if recurring and not x:
        # La ocurrencia, en su propia fecha: lo que el editor de «sólo ésta» empieza enseñando.
        span = occurrence_span(ev, rid)
    item_id = "local:%s~%s@%s" % (ev["uuid"], rid, day.isoformat()) if recurring else "local:%s@%s" % (ev["uuid"], day.isoformat())
    occ = dict(public(ev), title=title, notes=notes, **{k: v for k, v in span.items()})
    occ["rid"] = rid if recurring else ""
    occ["modified"] = x is not None
    cal = ev.get("_cal") or {"name": "On this computer", "color": "", "readOnly": False, "kind": "local"}
    read_only = ev["readOnly"] or ("read-only calendar" if cal["readOnly"] else "")
    return {"id": item_id, "source": "local", "editable": not read_only and ev["syncState"] != "conflict",
            "readOnly": read_only, "calendarId": ev["calendarId"], "calendarName": cal["name"], "calendarColor": cal["color"],
            "calendarKind": cal["kind"], "syncState": ev["syncState"], "uuid": ev["uuid"], "revision": ev["revision"],
            "rid": rid if recurring else "", "date": day.isoformat(), "kind": "event" if span["allDay"] else "apt",
            "recurring": recurring, "modified": x is not None, "allDay": span["allDay"], "start": start, "end": end,
            "duration": duration, "message": title, "hasNote": len(notes or "") > 0, "note": notes or "",
            "reminders": ev["reminders"], "event": public(ev), "occurrence": occ}


def occurrence_span(ev, rid):
    r = ev["_row"]
    if r["all_day"]:
        s = dt.date.fromisoformat(rid)
        length = dt.date.fromisoformat(r["end_date"]) - dt.date.fromisoformat(r["start_date"])
        last = s + length - dt.timedelta(days=1)
        return dict(allDay=True, tz="", startDate=rid, startTime="", endDate=last.isoformat(), endTime="", startFold=0,
                    endFold=0, lastDate=last.isoformat(), endDateExclusive=(s + length).isoformat(), displayDate=rid)
    tz = zone_of(r["tz"])
    naive = dt.datetime.fromisoformat(rid)
    start = from_utc(r["start_utc"]) if rid == r["start_local"] else wall_instant(naive, tz, 0)
    end = start + (from_utc(r["end_utc"]) - from_utc(r["start_utc"]))
    el = end.astimezone(tz)
    return dict(allDay=False, tz=r["tz"], startDate=rid[:10], startTime=rid[11:], endDate=el.date().isoformat(),
                endTime=el.strftime("%H:%M"), startFold=0, endFold=el.fold, lastDate="", endDateExclusive="",
                displayDate=start.astimezone(display_zone()[1]).date().isoformat())


def op_get(path, req):
    uid = need_uuid(req)
    db = open_read(path)
    if db is None:
        raise Fail("not_found", "The event no longer exists")
    try:
        ev = fetch(db, uid)
        exc = exceptions_of(db, uid) if ev else {}
    except sqlite3.DatabaseError as e:
        raise classify(e)
    finally:
        db.close()
    if not ev:
        raise Fail("not_found", "The event no longer exists")
    return {"event": public(ev), "exceptions": sorted([{"rid": k, "kind": v["kind"]} for k, v in exc.items()], key=lambda x: x["rid"])}


def insert_event(db, uid, cols, ext_uid=None, remote=None):
    stamp = now_utc()
    row = dict({"calendar_id": "local", "href": None, "etag": None, "sync_state": "local", "raw_ics": None, "ical_uid": None,
                "readonly_reason": None, "floating": 0}, **cols)
    row.update(uuid=uid, revision=1, created_utc=stamp, updated_utc=stamp, ext_uid=ext_uid)
    if remote:
        row.update(remote)
    db.execute("INSERT INTO events (%s) VALUES (%s)" % (", ".join(COLS), ", ".join("?" * len(COLS))), [row[c] for c in COLS])


def op_create(path, req):
    cols = validate(req.get("event"))
    uid = req.get("uuid")
    if uid is None:
        uid = str(uuidlib.uuid4())
    else:
        uid = need_uuid(req)

    def body(db):
        old = fetch(db, uid)
        if old:
            # Reintento del mismo borrador tras un fallo de transporte: misma cita, sin duplicarla.
            same = all(old["_row"].get(k) == v for k, v in cols.items())
            if same and old["revision"] == 1:
                return {"event": public(old), "repeated": True}
            raise Fail("exists", "An event with this identity already exists", current=public(old))
        cal = target_calendar(db, (req.get("event") or {}).get("calendarId"))
        insert_event(db, uid, cols, remote=remote_slot(cal, uid) if cal["kind"] == "caldav" else None)
        return {"event": public(fetch(db, uid))}
    return write(path, body)


def bump(db, uid, rev):
    db.execute("UPDATE events SET revision = ?, updated_utc = ? WHERE uuid = ? AND revision = ?", (rev + 1, now_utc(), uid, rev))


def guarded(db, uid, rev):
    old = fetch(db, uid)
    if not old:
        raise Fail("not_found", "The event no longer exists")
    if old["revision"] != rev:
        raise Fail("conflict", "The event changed since you opened it", current=public(old))
    return old


def count_before(ev, rid):
    upto = dt.date.fromisoformat(rid[:10])
    return sum(1 for o in master_occurrences(ev, upto) if o[0] < rid)


def op_update(path, req):
    uid = need_uuid(req)
    rev = need_revision(req)
    scope = req.get("scope", "series")
    if scope not in ("series", "occurrence", "following"):
        raise Fail("bad_request", "scope must be series, occurrence or following")
    cols = validate(req.get("event"), allow_repeat=scope != "occurrence")

    def body(db):
        old = guarded(db, uid, rev)
        editable_guard(db, old)
        if scope != "series" and not old["_rule"]:
            raise Fail("bad_request", "Only a repeating event has occurrences")
        if scope == "occurrence":
            rid = req.get("rid")
            if not rid_exists(old, rid):
                raise Fail("not_found", "That occurrence is not part of the series any more")
            vals = [cols[c] for c in SPAN]
            db.execute("INSERT OR REPLACE INTO exceptions (uuid, rid, kind, %s) VALUES (?, ?, 'modified', %s)"
                       % (", ".join(SPAN), ", ".join("?" * len(SPAN))), [uid, rid] + vals)
            bump(db, uid, rev)
            mark_dirty(db, uid)
            return {"event": public(fetch(db, uid)), "rid": rid}
        if scope == "following":
            rid = req.get("rid")
            if not rid_exists(old, rid):
                raise Fail("not_found", "That occurrence is not part of the series any more")
            if rid == old["_row"]["start_local"] or rid == old["_row"]["start_date"]:
                scope_series = True
            else:
                scope_series = False
            if not scope_series:
                rule = dict(old["_rule"])
                if rule.get("count"):
                    rule["count"] = count_before(old, rid)
                else:
                    rule["until"] = (dt.date.fromisoformat(rid[:10]) - dt.timedelta(days=1)).isoformat()
                db.execute("UPDATE events SET rrule = ? WHERE uuid = ?", (json.dumps(rule, sort_keys=True), uid))
                dropped = db.execute("DELETE FROM exceptions WHERE uuid = ? AND rid >= ?", (uid, rid)).rowcount
                bump(db, uid, rev)
                mark_dirty(db, uid)
                new_cols = dict(cols)
                new_rule = json.loads(cols["rrule"]) if cols["rrule"] else None
                if new_rule and new_rule.get("count") and old["_rule"].get("count") and new_rule["count"] == old["_rule"]["count"]:
                    new_rule["count"] = max(1, old["_rule"]["count"] - rule["count"])
                    new_cols["rrule"] = json.dumps(new_rule, sort_keys=True)
                new_uid = str(uuidlib.uuid4())
                cal = calendars_map(db).get(old["calendarId"])
                insert_event(db, new_uid, dict(new_cols, calendar_id=old["calendarId"]),
                             remote=remote_slot(cal, new_uid) if cal and cal["kind"] == "caldav" else None)
                return {"event": public(fetch(db, new_uid)), "split": {"from": uid, "droppedExceptions": dropped}}
        # Toda la serie (o un evento sin repetición).
        timing = ("all_day", "tz", "start_local", "end_local", "start_date", "end_date", "rrule", "start_fold")
        changed_timing = any(old["_row"].get(k) != cols[k] for k in timing)
        reset = 0
        if changed_timing and db.version >= 2:
            reset = db.execute("DELETE FROM exceptions WHERE uuid = ?", (uid,)).rowcount
        sets = dict(cols, revision=rev + 1, updated_utc=now_utc())
        moved = None
        want = (req.get("event") or {}).get("calendarId")
        if db.version >= 3 and want and want != old["calendarId"]:
            # Mover de calendario (explícito): lo del servidor de origen se borra allí al sincronizar.
            cal = target_calendar(db, want)
            tombstone(db, old)
            if cal["kind"] == "caldav":
                sets.update(remote_slot(cal, uid, old["_row"]["ical_uid"]))
            else:
                sets.update(calendar_id="local", href=None, etag=None, sync_state="local")
            moved = cal["id"]
        db.execute("UPDATE events SET %s WHERE uuid = ? AND revision = ?" % ", ".join(k + " = ?" for k in sets),
                   list(sets.values()) + [uid, rev])
        if not moved:
            mark_dirty(db, uid)
        return {"event": public(fetch(db, uid)), "resetExceptions": reset, "movedTo": moved}
    return write(path, body)


def op_delete(path, req):
    uid = need_uuid(req)
    rev = need_revision(req)
    scope = req.get("scope", "series")
    if scope not in ("series", "occurrence", "following"):
        raise Fail("bad_request", "scope must be series, occurrence or following")
    if not os.path.exists(path):
        raise Fail("not_found", "The event no longer exists")

    def body(db):
        old = guarded(db, uid, rev)
        if old["syncState"] == "conflict":
            raise Fail("conflict_pending", "Resolve the sync conflict of this event first (Accounts)")
        if scope != "series" and old["readOnly"]:
            raise Fail("readonly_event", "Only the whole series can be deleted here: %s" % old["readOnly"])
        if scope == "series":
            c = calendars_map(db).get(old["calendarId"])
            if c and c["readOnly"]:
                raise Fail("readonly_calendar", "The calendar \u201c%s\u201d is read-only" % c["name"])
        if scope != "series":
            if not old["_rule"]:
                raise Fail("bad_request", "Only a repeating event has occurrences")
            rid = req.get("rid")
            if not rid_exists(old, rid):
                raise Fail("not_found", "That occurrence is not part of the series any more")
            first = rid in (old["_row"]["start_local"], old["_row"]["start_date"])
            if scope == "occurrence":
                db.execute("INSERT OR REPLACE INTO exceptions (uuid, rid, kind) VALUES (?, ?, 'cancelled')", (uid, rid))
                bump(db, uid, rev)
                mark_dirty(db, uid)
                return {"deleted": uid, "rid": rid, "scope": scope, "title": old["title"]}
            if not first:
                rule = dict(old["_rule"])
                if rule.get("count"):
                    rule["count"] = count_before(old, rid)
                else:
                    rule["until"] = (dt.date.fromisoformat(rid[:10]) - dt.timedelta(days=1)).isoformat()
                db.execute("UPDATE events SET rrule = ? WHERE uuid = ?", (json.dumps(rule, sort_keys=True), uid))
                db.execute("DELETE FROM exceptions WHERE uuid = ? AND rid >= ?", (uid, rid))
                bump(db, uid, rev)
                mark_dirty(db, uid)
                return {"deleted": uid, "rid": rid, "scope": scope, "title": old["title"]}
        pending = tombstone(db, old)
        db.execute("DELETE FROM events WHERE uuid = ? AND revision = ?", (uid, rev))
        return {"deleted": uid, "scope": "series", "title": old["title"], "pendingRemote": pending}
    return write(path, body)


# ---- recordatorios ----------------------------------------------------------------------------------

def reminder_instances(db, lo, hi):
    """[(uuid, rid, offset, fire, start, end, title, allDay)] con `fire` en [lo, hi)."""
    if db.version < 2:
        return []
    _, disp = display_zone()
    rows = db.execute("SELECT %s FROM events WHERE reminders != '[]'" % select_cols(db)).fetchall()
    cals = calendars_map(db)
    out = []
    for row in rows:
        ev = record(row)
        if not ev["reminders"] or not (cals.get(ev["calendarId"]) or {"visible": True})["visible"]:
            continue
        # De la ventana de aviso al inicio del evento, en la zona de su repetición.
        # Las excepciones pueden incluso cambiar de zona o pasar a ser de día completo.
        tz = disp if ev["allDay"] else zone_of(ev["tz"])
        offsets = ev["reminders"]
        first = (lo + dt.timedelta(minutes=min(offsets))).astimezone(tz).date()
        # Una transición hacia atrás puede volver al día anterior antes del límite superior.
        upto = (hi + dt.timedelta(minutes=max(offsets))).astimezone(tz).date() + dt.timedelta(days=1)
        for rid, s, e, x in occurrences(db, ev, upto, first):
            all_day = bool(x["all_day"]) if x else ev["allDay"]
            if all_day:
                start = dt.datetime.combine(s, dt.time(9, 0)).replace(tzinfo=disp).astimezone(UTC)
                end = dt.datetime.combine(e, dt.time(0, 0)).replace(tzinfo=disp).astimezone(UTC)
            else:
                start, end = s, e
            for off in ev["reminders"]:
                fire = start - dt.timedelta(minutes=off)
                if lo <= fire < hi:
                    out.append({"uuid": ev["uuid"], "rid": rid if ev["_rule"] else "", "offset": off, "fire": iso_utc(fire),
                                "start": iso_utc(s if not all_day else start), "end": iso_utc(end), "allDay": all_day,
                                "title": x["title"] if x else ev["title"]})
    return out


def op_due(path, req):
    try:
        lo, hi = from_utc(req.get("from", "")), from_utc(req.get("to", ""))
    except (TypeError, ValueError):
        raise Fail("bad_request", "from/to must be UTC timestamps (YYYY-MM-DDTHH:MM:SSZ)")
    if hi <= lo or hi - lo > dt.timedelta(days=8):
        raise Fail("bad_request", "the window must be positive and at most 8 days")
    db = open_read(path)
    if db is None:
        return {"due": [], "exists": False}
    try:
        items = reminder_instances(db, lo, hi)
        logged = set()
        if db.version >= 2 and items:
            logged = {(u, r, o) for u, r, o in db.execute("SELECT uuid, rid, offset_min FROM reminder_log")}
    except sqlite3.DatabaseError as e:
        raise classify(e)
    finally:
        db.close()
    items = [i for i in items if (i["uuid"], i["rid"], i["offset"]) not in logged]
    items.sort(key=lambda i: (i["fire"], i["title"]))
    return {"due": items, "exists": True}


def op_fire(path, req):
    uid = need_uuid(req)
    rid = req.get("rid", "")
    off = req.get("offset")
    state = req.get("state")
    if not isinstance(rid, str) or (rid and not RID_RE.match(rid)) or not isinstance(off, int) or state not in ("shown", "missed"):
        raise Fail("bad_request", "rid, offset and state are required")
    try:
        fire = from_utc(req.get("fire", ""))
    except (TypeError, ValueError):
        raise Fail("bad_request", "fire must be a UTC timestamp")

    def body(db):
        cur = db.execute("INSERT OR IGNORE INTO reminder_log (uuid, rid, offset_min, fire_utc, state, at_utc) VALUES (?, ?, ?, ?, ?, ?)",
                         (uid, rid, off, iso_utc(fire), state, now_utc()))
        # Sólo se guarda lo de los últimos 60 días: el registro no crece sin fin.
        db.execute("DELETE FROM reminder_log WHERE fire_utc < ?", (iso_utc(dt.datetime.now(UTC) - dt.timedelta(days=60)),))
        return {"inserted": cur.rowcount == 1}
    return write(path, body)


# ---- ICS ----------------------------------------------------------------------------------------------

def ics_escape(s):
    return s.replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,").replace("\n", "\\n")


def ics_unescape(s):
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


def fold(line):
    raw = line.encode()
    if len(raw) <= 75:
        return line + "\r\n"
    parts, cur = [], b""
    for ch in line:
        b = ch.encode()
        if len(cur) + len(b) > (75 if not parts else 74):
            parts.append(cur)
            cur = b""
        cur += b
    parts.append(cur)
    return "\r\n ".join(p.decode() for p in parts) + "\r\n"


def rrule_text(rule):
    parts = ["FREQ=" + rule["freq"].upper()]
    if rule["interval"] != 1:
        parts.append("INTERVAL=%d" % rule["interval"])
    if rule.get("byday"):
        parts.append("BYDAY=" + ",".join(rule["byday"]))
    if rule.get("count"):
        parts.append("COUNT=%d" % rule["count"])
    if rule.get("until"):
        parts.append("UNTIL=" + rule["until"].replace("-", ""))
    return ";".join(parts)


def ics_when(prefix, r, which):
    if r["all_day"]:
        return "%s;VALUE=DATE:%s" % (prefix, r[which + "_date"].replace("-", ""))
    wall = r[which + "_local"].replace("-", "").replace(":", "") + "00"
    return "%s;TZID=%s:%s" % (prefix, r["tz"], wall)


def alarm_lines(ev):
    out = []
    for off in ev["reminders"]:
        if ev["allDay"]:
            trig = 540 - off   # minutos tras la medianoche del primer día
            text = ("-PT%dM" % -trig) if trig < 0 else ("PT%dM" % trig)
        else:
            text = "-PT%dM" % off if off else "PT0M"
        out += ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:" + ics_escape(ev["title"]), "TRIGGER:" + text, "END:VALARM"]
    return out


def op_export(path, req):
    dest = req.get("path")
    home = os.path.realpath(os.path.expanduser("~"))
    if not isinstance(dest, str) or not dest.startswith("/") or not dest.endswith(".ics"):
        raise Fail("invalid", "Choose an absolute path ending in .ics", field="path")
    parent = os.path.realpath(os.path.dirname(dest))
    if not (parent == home or parent.startswith(home + "/")) and not bench_path(dest):
        raise Fail("invalid", "Export inside your home folder", field="path")
    db = open_read(path)
    lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Sumi Shell//Local calendar//EN", "CALSCALE:GREGORIAN"]
    count = 0
    if db:
        try:
            for row in db.execute("SELECT %s FROM events ORDER BY created_utc" % select_cols(db)).fetchall():
                ev = record(row)
                r = ev["_row"]
                uid = r["ext_uid"][4:] if (r["ext_uid"] or "").startswith("ics:") else ev["uuid"] + "@sumi-shell"
                stamp = r["updated_utc"].replace("-", "").replace(":", "")
                lines += ["BEGIN:VEVENT", "UID:" + uid, "DTSTAMP:" + stamp, "SUMMARY:" + ics_escape(ev["title"]),
                          ics_when("DTSTART", r, "start"), ics_when("DTEND", r, "end")]
                if ev["notes"]:
                    lines.append("DESCRIPTION:" + ics_escape(ev["notes"]))
                exc = exceptions_of(db, ev["uuid"]) if ev["_rule"] else {}
                if ev["_rule"]:
                    lines.append("RRULE:" + rrule_text(ev["_rule"]))
                    for rid, x in sorted(exc.items()):
                        if x["kind"] == "cancelled":
                            lines.append(ics_rid("EXDATE", ev, rid))
                lines += alarm_lines(ev) + ["END:VEVENT"]
                for rid, x in sorted(exc.items()):
                    if x["kind"] != "modified":
                        continue
                    lines += ["BEGIN:VEVENT", "UID:" + uid, "DTSTAMP:" + stamp, ics_rid("RECURRENCE-ID", ev, rid),
                              "SUMMARY:" + ics_escape(x["title"]), ics_when("DTSTART", x, "start"), ics_when("DTEND", x, "end")]
                    if x["notes"]:
                        lines.append("DESCRIPTION:" + ics_escape(x["notes"]))
                    lines.append("END:VEVENT")
                count += 1
        except sqlite3.DatabaseError as e:
            raise classify(e)
        finally:
            db.close()
    lines.append("END:VCALENDAR")
    data = "".join(fold(l) for l in lines).encode()
    try:
        fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        raise Fail("exists", "That file already exists; choose another name", field="path")
    except OSError as e:
        raise Fail("io", "Could not create the file: " + (e.strerror or str(e)), field="path")
    with os.fdopen(fd, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    return {"path": dest, "events": count, "bytes": len(data)}


def ics_rid(name, ev, rid):
    if ev["allDay"]:
        return "%s;VALUE=DATE:%s" % (name, rid.replace("-", ""))
    return "%s;TZID=%s:%s00" % (name, ev["tz"], rid.replace("-", "").replace(":", ""))


def unfold(text):
    lines = []
    for raw in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if raw[:1] in (" ", "\t") and lines:
            lines[-1] += raw[1:]
        elif raw:
            lines.append(raw)
    return lines


def parse_prop(line):
    name_part, _, value = line.partition(":")
    bits = name_part.split(";")
    params = {}
    for b in bits[1:]:
        k, _, v = b.partition("=")
        params[k.upper()] = v.strip('"')
    return bits[0].upper(), params, value


def parse_ics(text):
    """→ [componentes VEVENT como {prop: [(params, value)]}] (sin VTIMEZONE: se exigen zonas IANA)."""
    events, cur, depth = [], None, []
    for line in unfold(text):
        name, params, value = parse_prop(line)
        if name == "BEGIN":
            depth.append(value.upper())
            if value.upper() == "VEVENT":
                cur = {"_alarms": []}
            elif value.upper() == "VALARM" and cur is not None:
                cur["_alarm"] = {}
            continue
        if name == "END":
            kind = depth.pop() if depth else ""
            if kind == "VEVENT" and cur is not None:
                events.append(cur)
                cur = None
            elif kind == "VALARM" and cur is not None and "_alarm" in cur:
                cur["_alarms"].append(cur.pop("_alarm"))
            continue
        if cur is None:
            continue
        if "_alarm" in cur:
            cur["_alarm"].setdefault(name, []).append((params, value))
        else:
            cur.setdefault(name, []).append((params, value))
    return events


def ics_time(params, value, disp):
    """→ ("date", date) | ("time", aware datetime, tzname)."""
    value = value.strip()
    if params.get("VALUE", "").upper() == "DATE" or re.match(r"^\d{8}$", value):
        return ("date", dt.datetime.strptime(value[:8], "%Y%m%d").date(), None)
    m = re.match(r"^(\d{8})T(\d{4})(\d{2})?(Z)?$", value)
    if not m:
        raise Fail("unsupported", "unreadable date " + value)
    naive = dt.datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M")
    if m.group(4):
        return ("time", naive.replace(tzinfo=UTC), "UTC")
    tzid = params.get("TZID")
    if tzid:
        import calendar_ical as IC
        name = IC.iana(tzid, {})      # IANA, prefijos de Mozilla o nombres de Windows
        if not name:
            raise Fail("unsupported", "time zone " + tzid + " is not an IANA name")
        return ("time", naive.replace(tzinfo=zone_of(name)), name)
    return ("time", naive.replace(tzinfo=disp[1]), disp[0])   # hora flotante: la de la pantalla


def ics_duration(value):
    m = re.match(r"^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$", value.strip())
    if not m:
        raise Fail("unsupported", "unreadable duration " + value)
    sign = -1 if m.group(1) == "-" else 1
    w, d, h, mi, s = (int(x or 0) for x in m.groups()[1:])
    return sign * dt.timedelta(weeks=w, days=d, hours=h, minutes=mi, seconds=s)


def ics_rule(value, start):
    """RRULE de un .ics con el motor ampliado; lo que no cabe se lista como no admitido."""
    try:
        rule = RR.from_ical(value)
    except (RR.Unsupported, ValueError) as e:
        raise Fail("unsupported", "repetition rule with %s is not supported yet" % e)
    if rule.get("count") is not None and not 1 <= rule["count"] <= MAX_COUNT:
        raise Fail("unsupported", "repetition COUNT=%s" % rule["count"])
    api = repeat_api(rule)
    return clean_repeat(api, start)

def one(comp, name):
    v = comp.get(name)
    return v[0] if v else None


def ics_events(text, source):
    """→ (válidos [{ext, cols, cancelled:[rid], overrides:{rid: cols}, summary}], no admitidos [{summary, reason}])."""
    disp = display_zone()
    comps = parse_ics(text)
    masters, overrides, bad = {}, [], []
    for c in comps:
        summary = ics_unescape(one(c, "SUMMARY")[1]) if one(c, "SUMMARY") else "(no title)"
        tz = None
        try:
            if one(c, "RECURRENCE-ID"):
                overrides.append(c)
                continue
            ds = one(c, "DTSTART")
            if not ds:
                raise Fail("unsupported", "no start")
            start = ics_time(ds[0], ds[1], disp)
            de, du = one(c, "DTEND"), one(c, "DURATION")
            if start[0] == "date":
                end = ics_time(de[0], de[1], disp)[1] if de else start[1] + (ics_duration(du[1]) if du else dt.timedelta(days=1))
                if isinstance(end, dt.datetime):
                    raise Fail("unsupported", "mixed date and time")
                event = {"title": summary[:MAX_TITLE].strip() or "(no title)", "allDay": True, "startDate": start[1].isoformat(),
                         "lastDate": (max(end, start[1] + dt.timedelta(days=1)) - dt.timedelta(days=1)).isoformat()}
                first = start[1]
            else:
                s = start[1]
                if de:
                    e = ics_time(de[0], de[1], disp)[1]
                    if not isinstance(e, dt.datetime):
                        raise Fail("unsupported", "mixed date and time")
                else:
                    e = s + (ics_duration(du[1]) if du else dt.timedelta(0))
                if e <= s:
                    e = s + dt.timedelta(minutes=1) if e == s else e
                tzname = start[2] if start[2] != "UTC" else disp[0]
                tz = zone_of(tzname) if tzname != "localtime" else disp[1]
                sl, el = s.astimezone(tz), e.astimezone(tz)
                event = {"title": summary[:MAX_TITLE].strip() or "(no title)", "allDay": False, "tz": tzname,
                         "startDate": sl.date().isoformat(), "startTime": sl.strftime("%H:%M"),
                         "endDate": el.date().isoformat(), "endTime": el.strftime("%H:%M"),
                         "startFold": sl.fold, "endFold": el.fold}
                first = sl.date()
            desc = one(c, "DESCRIPTION")
            event["notes"] = ics_unescape(desc[1])[:MAX_NOTES] if desc else ""
            rr = one(c, "RRULE")
            if rr:
                rule = ics_rule(rr[1], first)
                event["repeat"] = repeat_api(rule)
            rem = []
            for al in c["_alarms"]:
                trig = al.get("TRIGGER")
                if not trig or trig[0][0].get("RELATED", "START").upper() != "START" or trig[0][0].get("VALUE", "").upper() == "DATE-TIME":
                    continue
                mins = int(-ics_duration(trig[0][1]).total_seconds() // 60)
                if event["allDay"]:
                    mins = 540 + mins   # 09:00 del primer día como referencia de la shell
                if 0 <= mins <= MAX_REMINDER:
                    rem.append(mins)
            event["reminders"] = sorted(set(rem))[:4]
            cols = validate(event)
            uid = one(c, "UID")
            key = ("ics:" + uid[1].strip()) if uid and source == "ics" else (source + ":" + hashlib.sha256(
                json.dumps([summary, ds[1], (rr or (None, ""))[1], (de or du or (None, ""))[1]]).encode()).hexdigest()[:32])
            cancelled = []
            for ex in c.get("EXDATE", []):
                for v in ex[1].split(","):
                    t = ics_time(ex[0], v, disp)
                    if t[0] == "date":
                        cancelled.append(t[1].isoformat())
                    elif tz is not None:
                        cancelled.append(t[1].astimezone(tz).strftime("%Y-%m-%dT%H:%M"))
                    else:
                        cancelled.append(t[1].date().isoformat())
            masters.setdefault(key, {"ext": key, "uid": uid[1].strip() if uid else None, "cols": cols, "cancelled": cancelled,
                                     "overrides": {}, "summary": summary})
        except Fail as f:
            bad.append({"summary": summary, "reason": f.message})
        except (ValueError, KeyError, IndexError) as e:
            bad.append({"summary": summary, "reason": "unreadable (%s)" % e})
    by_uid = {m["uid"]: m for m in masters.values() if m["uid"]}
    for c in overrides:
        summary = ics_unescape(one(c, "SUMMARY")[1]) if one(c, "SUMMARY") else "(no title)"
        uid = one(c, "UID")
        m = by_uid.get(uid[1].strip()) if uid else None
        if not m:
            bad.append({"summary": summary, "reason": "changed occurrence without its series"})
            continue
        try:
            rid_p = one(c, "RECURRENCE-ID")
            t = ics_time(rid_p[0], rid_p[1], disp)
            mc = m["cols"]
            rid = t[1].isoformat() if t[0] == "date" else t[1].astimezone(zone_of(mc["tz"])).strftime("%Y-%m-%dT%H:%M")
            sub, _ = ics_events(wrap_vevent(c), "override")
            if not sub:
                raise Fail("unsupported", "unreadable changed occurrence")
            m["overrides"][rid] = sub[0]["cols"]
        except Fail as f:
            bad.append({"summary": summary, "reason": f.message})
    return list(masters.values()), bad


def wrap_vevent(c):
    lines = ["BEGIN:VCALENDAR", "BEGIN:VEVENT"]
    for k, vals in c.items():
        if k.startswith("_") or k in ("RECURRENCE-ID", "RRULE", "UID", "EXDATE"):
            continue
        for p, v in vals:
            lines.append(k + "".join(";%s=%s" % kv for kv in p.items()) + ":" + v)
    lines += ["END:VEVENT", "END:VCALENDAR"]
    return "".join(fold(l) for l in lines)


def import_source(req):
    if req.get("calcurse"):
        argv = ["calcurse"]
        cdir = req.get("calcurseDir")
        if cdir:
            if not bench_path(db_path()) or not str(cdir).startswith(("/tmp/", "/run/user/")):
                raise Fail("bad_request", "calcurseDir is only for test benches")
            argv += ["-D", cdir]
        argv += ["--export=ical"]
        try:
            r = subprocess.run(argv, capture_output=True, text=True, timeout=15)
        except FileNotFoundError:
            raise Fail("unavailable", "calcurse is not installed")
        except subprocess.TimeoutExpired:
            raise Fail("unavailable", "calcurse did not answer in 15 s")
        if r.returncode != 0:
            raise Fail("unavailable", "calcurse exited with %d" % r.returncode)
        return r.stdout, "calcurse"
    src = req.get("path")
    if not isinstance(src, str) or not src.startswith("/"):
        raise Fail("invalid", "Choose an absolute path to an .ics file", field="path")
    try:
        with open(src, "rb") as f:
            data = f.read(8 * 1024 * 1024 + 1)
    except OSError as e:
        raise Fail("invalid", "Could not read the file: " + (e.strerror or str(e)), field="path")
    if len(data) > 8 * 1024 * 1024:
        raise Fail("invalid", "The file is larger than 8 MB", field="path")
    try:
        return data.decode("utf-8"), "ics"
    except UnicodeDecodeError:
        raise Fail("invalid", "The file is not UTF-8 text", field="path")


def import_plan(path, req):
    text, source = import_source(req)
    if "BEGIN:VCALENDAR" not in text.upper():
        raise Fail("invalid", "Not an iCalendar file", field="path")
    good, bad = ics_events(text, source)
    known = set()
    db = open_read(path)
    if db:
        try:
            if db.version >= 2:
                known = {r[0] for r in db.execute("SELECT ext_uid FROM events WHERE ext_uid IS NOT NULL")}
            # Lo exportado por esta shell lleva UID <uuid>@sumi-shell: reimportarlo no duplica.
            known |= {"ics:%s@sumi-shell" % r[0] for r in db.execute("SELECT uuid FROM events")}
        finally:
            db.close()
    new = [g for g in good if g["ext"] not in known]
    return {"source": source, "digest": hashlib.sha256(text.encode()).hexdigest(), "new": new,
            "duplicates": [g["summary"] for g in good if g["ext"] in known], "unsupported": bad}


def op_import_preview(path, req):
    plan = import_plan(path, req)
    return {"source": plan["source"], "digest": plan["digest"], "new": [g["summary"] for g in plan["new"]][:200],
            "newCount": len(plan["new"]), "duplicates": len(plan["duplicates"]), "unsupported": plan["unsupported"][:200],
            "unsupportedCount": len(plan["unsupported"])}


def op_import(path, req):
    plan = import_plan(path, req)
    if req.get("digest") != plan["digest"]:
        raise Fail("conflict", "The source changed since the preview; preview it again")
    backup = None
    if os.path.exists(path) and plan["new"]:
        src = open_read(path)
        if src:
            try:
                backup = snapshot(src.conn, path, "pre-import")
            finally:
                src.close()

    def body(db):
        added = 0
        for g in plan["new"]:
            if db.execute("SELECT 1 FROM events WHERE ext_uid = ?", (g["ext"],)).fetchone():
                continue
            # Un evento exportado por esta shell conserva su identidad si el UUID está libre.
            own = re.match(r"^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})@sumi-shell$", g["uid"] or "")
            uid = own.group(1) if own and not fetch(db, own.group(1)) else str(uuidlib.uuid4())
            insert_event(db, uid, g["cols"], ext_uid=None if own and uid == own.group(1) else g["ext"])
            for rid in g["cancelled"]:
                db.execute("INSERT OR REPLACE INTO exceptions (uuid, rid, kind) VALUES (?, ?, 'cancelled')", (uid, rid))
            for rid, oc in g["overrides"].items():
                db.execute("INSERT OR REPLACE INTO exceptions (uuid, rid, kind, %s) VALUES (?, ?, 'modified', %s)"
                           % (", ".join(SPAN), ", ".join("?" * len(SPAN))), [uid, rid] + [oc[c] for c in SPAN])
            added += 1
        return {"added": added, "duplicates": len(plan["duplicates"]), "unsupported": len(plan["unsupported"]),
                "source": plan["source"], "backup": backup}
    return write(path, body)


# ---- CalDAV: cuentas, llavero y sincronización (2026-10-28) ------------------------------------------
#
# Local-first: la base es la fuente de trabajo y la red sólo se usa al sincronizar. Nada se
# sobrescribe en silencio: un cambio en los dos lados desde el último ETag conocido es un conflicto
# que el usuario resuelve (la mía, la del servidor o las dos). La contraseña vive en el llavero
# (Secret Service por `secret-tool`), nunca en la base ni en argv.

SECRET_BASE = ["application", "sumi-shell", "type", "caldav-account"]
# Antes del cambio de nombre (Kitasan-Shell, 2026-11-07) la contraseña se guardaba con `application kitasan-shell`. Sólo se
# LEE como segunda opción; se escribe y se borra siempre con el atributo nuevo. La entrada vieja nunca se toca desde aquí:
# la sigue usando la instalación anterior si se vuelve atrás, y retirarla es decisión del usuario.
SECRET_LEGACY = ["application", "kitasan-shell", "type", "caldav-account"]
PRESYNC_KEEP = 5


def secret_tool(args, stdin=None):
    try:
        r = subprocess.run(["secret-tool"] + args, input=stdin, capture_output=True, text=True, timeout=60)
    except FileNotFoundError:
        raise Fail("keyring", "secret-tool (libsecret) is not installed")
    except subprocess.TimeoutExpired:
        raise Fail("keyring", "The keyring did not answer (is it locked?)")
    return r


def secret_store(acc_id, label, password):
    r = secret_tool(["store", "--label=" + label] + SECRET_BASE + ["account", acc_id], password)
    if r.returncode != 0:
        raise Fail("keyring", "Could not save the password in the keyring: " + (r.stderr.strip()[:160] or "error %d" % r.returncode))


def secret_lookup(acc_id):
    r = secret_tool(["lookup"] + SECRET_BASE + ["account", acc_id])
    if r.returncode != 0 or not r.stdout:
        r = secret_tool(["lookup"] + SECRET_LEGACY + ["account", acc_id])
    if r.returncode != 0 or not r.stdout:
        raise Fail("keyring", "The password for this account is not in the keyring (or the keyring is locked)")
    return r.stdout


def secret_clear(acc_id):
    secret_tool(["clear"] + SECRET_BASE + ["account", acc_id])


def dav_module():
    import calendar_caldav as CD
    return CD


def ical_module():
    import calendar_ical as IC
    return IC


def ui_color(c):
    """Color guardado → #RRGGBB para QML (una base de antes podía guardar #RRGGBBAA tal cual)."""
    c = (c or "").strip()
    if len(c) in (7, 9) and c[0] == "#" and all(x in "0123456789abcdefABCDEF" for x in c[1:]):
        return c[:7].upper()
    return ""


def sanitize_title(t):
    t = " ".join((t or "").replace("\r", " ").replace("\n", " ").split())
    t = "".join(c for c in t if ord(c) >= 32)[:MAX_TITLE].strip()
    return t or "(no title)"


def span_cols(span, title, notes):
    """Tramo leído de un recurso → columnas (tolerante: hora inexistente tras el salto, repetida la 1.ª)."""
    if span["allDay"]:
        last = dt.date.fromisoformat(span["lastDate"])
        return {"title": sanitize_title(title), "notes": (notes or "")[:MAX_NOTES], "all_day": 1, "tz": None,
                "start_local": None, "end_local": None, "start_fold": 0, "end_fold": 0, "start_utc": None, "end_utc": None,
                "start_date": span["startDate"], "end_date": (last + dt.timedelta(days=1)).isoformat()}
    tz = zone_of(span["tz"])
    sn = dt.datetime.fromisoformat(span["startDate"] + "T" + span["startTime"])
    en = dt.datetime.fromisoformat(span["endDate"] + "T" + span["endTime"])
    s, e = wall_instant(sn, tz, 0), wall_instant(en, tz, 0)
    if e <= s:
        e = s + dt.timedelta(minutes=1)
    return {"title": sanitize_title(title), "notes": (notes or "")[:MAX_NOTES], "all_day": 0, "tz": span["tz"],
            "start_local": sn.strftime("%Y-%m-%dT%H:%M"), "end_local": en.strftime("%Y-%m-%dT%H:%M"), "start_fold": 0, "end_fold": 0,
            "start_utc": iso_utc(s), "end_utc": iso_utc(e), "start_date": None, "end_date": None}


def store_remote(db, cal_id, href, etag, data, info, uid=None):
    """Un recurso del servidor → evento local sincronizado (nuevo o sustituyendo `uid`)."""
    m = info["master"]
    cols = span_cols(m, m["title"], m["notes"])
    rule = info["rule"]
    cols.update(rrule=json.dumps(rule, sort_keys=True) if rule else None, reminders=json.dumps(info["reminders"]),
                floating=1 if info.get("floating") else 0, calendar_id=cal_id, href=href, etag=etag, sync_state="synced",
                raw_ics=data, ical_uid=info["uid"], readonly_reason=info["readonly"] or None)
    if uid:
        sets = dict(cols, updated_utc=now_utc())
        db.execute("UPDATE events SET %s, revision = revision + 1 WHERE uuid = ?" % ", ".join(k + " = ?" for k in sets),
                   list(sets.values()) + [uid])
        db.execute("DELETE FROM exceptions WHERE uuid = ?", (uid,))
    else:
        uid = str(uuidlib.uuid4())
        insert_event(db, uid, cols)
    for rid in info.get("cancelled") or []:
        db.execute("INSERT OR REPLACE INTO exceptions (uuid, rid, kind) VALUES (?, ?, 'cancelled')", (uid, rid))
    for rid, ov in (info.get("overrides") or {}).items():
        oc = span_cols(ov, ov["title"], ov["notes"])
        db.execute("INSERT OR REPLACE INTO exceptions (uuid, rid, kind, %s) VALUES (?, ?, 'modified', %s)"
                   % (", ".join(SPAN), ", ".join("?" * len(SPAN))), [uid, rid] + [oc[c] for c in SPAN])
    db.execute("DELETE FROM remote_other WHERE calendar_id = ? AND href = ?", (cal_id, href))
    return uid


def render_local(db, ev, new_uid=None):
    """El evento local → texto iCalendar, partiendo del original guardado (nada no gestionado se pierde)."""
    IC = ical_module()
    r = ev["_row"]
    keys = ("allDay", "tz", "startDate", "startTime", "endDate", "endTime", "lastDate")
    master = {k: ev[k] for k in keys}
    master.update(title=ev["title"], notes=ev["notes"], floating=ev["floating"])
    overrides, cancelled = {}, []
    for rid, x in exceptions_of(db, ev["uuid"]).items():
        if x["kind"] == "cancelled":
            cancelled.append(rid)
        else:
            sp = span_fields(x)
            overrides[rid] = dict({k: sp[k] for k in keys}, title=x["title"], notes=x["notes"], floating=ev["floating"])
    uid = new_uid or r["ical_uid"] or (ev["uuid"] + "@sumi-shell")
    return IC.render(r["raw_ics"], uid, master, ev["_rule"], ev["reminders"], cancelled, overrides, force_uid=bool(new_uid))


def read_remote(data):
    IC = ical_module()
    return IC.read(data, display_zone()[0] if display_zone()[0] != "localtime" else "UTC")


def need_db(path):
    db = open_read(path)
    if db is None or db.version < 3:
        if db:
            db.close()
        raise Fail("not_found", "No calendar accounts yet")
    return db


def accounts_view(db):
    accs = []
    for row in db.execute("SELECT id, name, server_url, username, interval_min, enabled, last_sync_utc, last_ok_utc, last_error FROM accounts ORDER BY created_utc"):
        aid = row[0]
        cals = []
        for cid, name, color, ro, vis, last in db.execute(
                "SELECT id, name, color, read_only, visible, last_sync_utc FROM calendars WHERE account_id = ? ORDER BY name", (aid,)):
            n = db.execute("SELECT COUNT(*), SUM(sync_state IN ('new','dirty')), SUM(sync_state = 'conflict') FROM events WHERE calendar_id = ?", (cid,)).fetchone()
            t = db.execute("SELECT COUNT(*) FROM tombstones WHERE calendar_id = ?", (cid,)).fetchone()[0]
            cals.append({"id": cid, "name": name, "color": ui_color(color), "readOnly": bool(ro), "visible": bool(vis), "lastSync": last,
                         "events": n[0] or 0, "pending": (n[1] or 0) + t, "conflicts": n[2] or 0})
        accs.append({"id": aid, "name": row[1], "server": row[2], "username": row[3], "interval": row[4], "enabled": bool(row[5]),
                     "lastSync": row[6], "lastOk": row[7], "lastError": row[8] or "", "calendars": cals})
    return accs


def op_accounts(path, req):
    db = open_read(path)
    if db is None or db.version < 3:
        if db:
            db.close()
        return {"accounts": [], "conflicts": [], "local": {"id": "local", "name": "On this computer"}}
    try:
        cals = calendars_map(db)
        conflicts = [{"id": c[0], "calendarId": c[1], "calendar": (cals.get(c[1]) or {}).get("name", "?"), "kind": c[2], "title": c[3],
                      "created": c[4]} for c in db.execute("SELECT id, calendar_id, kind, title, created_utc FROM conflicts ORDER BY id")]
        loc = cals.get("local")
        return {"accounts": accounts_view(db), "conflicts": conflicts,
                "local": {"id": "local", "name": loc["name"], "visible": loc["visible"]}}
    finally:
        db.close()


def op_account_add(path, req):
    CD = dav_module()
    name = str(req.get("name") or "").strip()[:80]
    url = str(req.get("url") or "").strip()
    user = str(req.get("username") or "").strip()
    pw = req.get("password")
    interval = req.get("interval", 30)
    try:
        CD.check_url(url)
    except ValueError as e:
        raise Fail("invalid", str(e), field="url")
    if not user:
        raise Fail("invalid", "The user name is required", field="username")
    if not isinstance(pw, str) or not pw:
        raise Fail("invalid", "The password is required", field="password")
    if not isinstance(interval, int) or isinstance(interval, bool) or not 0 <= interval <= 1440:
        raise Fail("invalid", "Sync every 0 (manual) to 1440 minutes", field="interval")
    try:
        client = CD.Dav(url, user, pw)
        home, cals = client.discover()
    except CD.AuthError as e:
        raise Fail("auth", str(e), field="password")
    except CD.Offline as e:
        raise Fail("offline", "Could not reach the server: %s" % e, field="url")
    except (CD.HttpError, ET_ERRORS) as e:
        raise Fail("invalid", "That address is not a CalDAV server (%s)" % e, field="url")
    if not cals:
        raise Fail("invalid", "The account has no calendars with events", field="url")
    aid = str(uuidlib.uuid4())
    host = urlsplit_host(url)
    secret_store(aid, "Sumi Shell calendar: %s@%s" % (user, host), pw)

    def body(db):
        db.execute("INSERT INTO accounts (id, name, server_url, username, home_url, interval_min, created_utc) VALUES (?, ?, ?, ?, ?, ?, ?)",
                   (aid, name or "%s@%s" % (user, host), url, user, home, interval, now_utc()))
        for c in cals:
            db.execute("INSERT INTO calendars (id, account_id, kind, name, color, url, read_only, visible) VALUES (?, ?, 'caldav', ?, ?, ?, ?, 1)",
                       (str(uuidlib.uuid4()), aid, c["name"], c["color"], c["url"], 1 if c["readOnly"] else 0))
        return {"account": aid, "calendars": len(cals)}
    try:
        return write(path, body)
    except BaseException:
        secret_clear(aid)          # sin cuenta guardada, la contraseña tampoco se queda en el llavero
        raise


ET_ERRORS = (ValueError, SyntaxError)   # xml ParseError hereda de SyntaxError


def urlsplit_host(url):
    import urllib.parse
    return urllib.parse.urlsplit(url).hostname or "server"


def op_account_update(path, req):
    aid = req.get("id")

    def body(db):
        if not db.execute("SELECT 1 FROM accounts WHERE id = ?", (aid,)).fetchone():
            raise Fail("not_found", "That account no longer exists")
        if "interval" in req:
            v = req["interval"]
            if not isinstance(v, int) or isinstance(v, bool) or not 0 <= v <= 1440:
                raise Fail("invalid", "Sync every 0 (manual) to 1440 minutes", field="interval")
            db.execute("UPDATE accounts SET interval_min = ? WHERE id = ?", (v, aid))
        if "enabled" in req:
            db.execute("UPDATE accounts SET enabled = ? WHERE id = ?", (1 if req["enabled"] else 0, aid))
        if "name" in req and str(req["name"]).strip():
            db.execute("UPDATE accounts SET name = ? WHERE id = ?", (str(req["name"]).strip()[:80], aid))
        return {"account": aid}
    return write(path, body)


def op_calendar_update(path, req):
    cid = req.get("id")

    def body(db):
        if not db.execute("SELECT 1 FROM calendars WHERE id = ?", (cid,)).fetchone():
            raise Fail("not_found", "That calendar no longer exists")
        if "visible" in req:
            db.execute("UPDATE calendars SET visible = ? WHERE id = ?", (1 if req["visible"] else 0, cid))
        return {"calendar": cid}
    return write(path, body)


def op_account_remove(path, req):
    """Quita la cuenta de ESTE equipo (sus copias locales, borrados y conflictos pendientes); el
    servidor no se toca. Antes, una copia de la base. Lo pendiente de subir se perdería: se informa."""
    aid = req.get("id")
    db = need_db(path)
    try:
        backup = snapshot(db.conn, path, "pre-account-remove")
    finally:
        db.close()

    def body(db):
        cids = [r[0] for r in db.execute("SELECT id FROM calendars WHERE account_id = ?", (aid,))]
        if not cids and not db.execute("SELECT 1 FROM accounts WHERE id = ?", (aid,)).fetchone():
            raise Fail("not_found", "That account no longer exists")
        q = ",".join("?" * len(cids)) or "''"
        pending = db.execute("SELECT COUNT(*) FROM events WHERE calendar_id IN (%s) AND sync_state IN ('new','dirty','conflict')" % q, cids).fetchone()[0]
        removed = db.execute("DELETE FROM events WHERE calendar_id IN (%s)" % q, cids).rowcount
        for t in ("tombstones", "conflicts", "remote_other"):
            db.execute("DELETE FROM %s WHERE calendar_id IN (%s)" % (t, q), cids)
        db.execute("DELETE FROM calendars WHERE account_id = ?", (aid,))
        db.execute("DELETE FROM accounts WHERE id = ?", (aid,))
        return {"removed": removed, "unsyncedLost": pending, "backup": backup}
    out = write(path, body)
    secret_clear(aid)
    return out


def prune_snapshots(path, label, keep):
    folder = os.path.dirname(path)
    pref = os.path.basename(path) + "." + label + "-"
    snaps = sorted(f for f in os.listdir(folder) if f.startswith(pref))
    for f in snaps[:-keep]:
        os.unlink(os.path.join(folder, f))


def sync_lock():
    import fcntl
    run = os.environ.get("XDG_RUNTIME_DIR") or os.path.dirname(db_path())
    fd = os.open(os.path.join(run, "sumi-calendar-sync.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return None
    return fd


def progress(**kw):
    sys.stdout.write(json.dumps(dict(kw, progress=True), ensure_ascii=False) + "\n")
    sys.stdout.flush()


def conflict(db, cal_id, href, uuid, kind, title, local_ics, remote_ics, remote_etag):
    db.execute("INSERT OR REPLACE INTO conflicts (calendar_id, href, uuid, kind, title, local_ics, remote_ics, remote_etag, created_utc)"
               " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", (cal_id, href, uuid, kind, title, local_ics, remote_ics, remote_etag, now_utc()))
    if uuid:
        db.execute("UPDATE events SET sync_state = 'conflict' WHERE uuid = ?", (uuid,))


def event_by_href(db, cal_id, href):
    row = db.execute("SELECT %s FROM events WHERE calendar_id = ? AND href = ?" % select_cols(db), (cal_id, href)).fetchone()
    return record(row) if row else None


def sync_calendar(path, client, cal, stats):
    CD = dav_module()
    cid, url = cal["id"], cal["url"]
    db = need_db(path)
    try:
        token = db.execute("SELECT sync_token FROM calendars WHERE id = ?", (cid,)).fetchone()[0]
        local = {r[0]: (r[1], r[2]) for r in db.execute("SELECT href, etag, sync_state FROM events WHERE calendar_id = ? AND href IS NOT NULL", (cid,))}
        tombs = {r[0]: r[1] for r in db.execute("SELECT href, etag FROM tombstones WHERE calendar_id = ?", (cid,))}
        others = {r[0]: r[1] for r in db.execute("SELECT href, etag FROM remote_other WHERE calendar_id = ?", (cid,))}
    finally:
        db.close()
    # 1. Qué cambió en el servidor.
    full = token is None
    if not full:
        try:
            changed, removed, new_token = client.changes(url, token)
        except CD.TokenInvalid:
            full = True
    if full:
        etags = client.etags(url)
        new_token = client.token(url)
        known = dict((h, v[0]) for h, v in local.items())
        known.update(tombs)
        known.update(others)
        changed = {h: e for h, e in etags.items() if known.get(h) != e}
        removed = [h for h, (e, st) in local.items() if h not in etags and st != "new"] + [h for h in tombs if h not in etags] \
            + [h for h in others if h not in etags]
    # Lo que ya tenemos con el mismo ETag no se descarga (p. ej. nuestras propias subidas).
    fetch_hrefs = [h for h, e in changed.items() if (local.get(h) or (None,))[0] != e and others.get(h) != e]
    bodies = client.multiget(url, fetch_hrefs) if fetch_hrefs else {}
    # 2. Aplicar, cada recurso en su propia transacción corta (la UI puede escribir entre medias).
    for href, (etag, data) in bodies.items():
        etag = etag or changed.get(href)

        def apply(db, href=href, etag=etag, data=data):
            row = event_by_href(db, cid, href)
            tomb = db.execute("SELECT etag, raw_ics, title FROM tombstones WHERE calendar_id = ? AND href = ?", (cid, href)).fetchone()
            try:
                info = read_remote(data)
            except Exception as e:  # noqa: BLE001 — un recurso ilegible no detiene la sincronización
                info = {"master": None, "readonly": "unreadable (%s)" % e, "uid": None}
            if tomb is not None:
                if tomb[0] == etag:
                    return
                db.execute("DELETE FROM tombstones WHERE calendar_id = ? AND href = ?", (cid, href))
                conflict(db, cid, href, None, "deleted_here_changed_there", tomb[2], tomb[1], data, etag)
                stats["conflicts"] += 1
                return
            if info.get("master") is None:
                db.execute("INSERT OR REPLACE INTO remote_other (calendar_id, href, etag, reason) VALUES (?, ?, ?, ?)",
                           (cid, href, etag, info.get("readonly") or "not an event"))
                return
            if row is None:
                store_remote(db, cid, href, etag, data, info)
                stats["pulled"] += 1
            elif row["_row"]["etag"] == etag:
                return
            elif row["syncState"] == "synced":
                store_remote(db, cid, href, etag, data, info, uid=row["uuid"])
                stats["pulled"] += 1
            elif row["syncState"] in ("dirty", "new"):
                conflict(db, cid, href, row["uuid"], "changed_both", row["title"], render_local(db, row), data, etag)
                stats["conflicts"] += 1
            elif row["syncState"] == "conflict":
                db.execute("UPDATE conflicts SET remote_ics = ?, remote_etag = ? WHERE calendar_id = ? AND href = ?", (data, etag, cid, href))
        write(path, apply)
    for href in removed:
        def drop(db, href=href):
            row = event_by_href(db, cid, href)
            db.execute("DELETE FROM tombstones WHERE calendar_id = ? AND href = ?", (cid, href))
            db.execute("DELETE FROM remote_other WHERE calendar_id = ? AND href = ?", (cid, href))
            if row is None:
                return
            if row["syncState"] == "synced":
                db.execute("DELETE FROM events WHERE uuid = ?", (row["uuid"],))
                stats["deleted"] += 1
            elif row["syncState"] == "dirty":
                conflict(db, cid, href, row["uuid"], "deleted_there_changed_here", row["title"], render_local(db, row), None, None)
                stats["conflicts"] += 1
        write(path, drop)
    # 3. Subir lo nuevo y lo cambiado aquí; borrar allí lo borrado aquí.
    db = need_db(path)
    try:
        pend = [record(r) for r in db.execute("SELECT %s FROM events WHERE calendar_id = ? AND sync_state IN ('new', 'dirty')"
                                              % select_cols(db), (cid,))]
        pend = [(ev, render_local(db, ev)) for ev in pend]
        tomb_rows = list(db.execute("SELECT href, etag, title, raw_ics FROM tombstones WHERE calendar_id = ?", (cid,)))
    finally:
        db.close()
    for ev, data in pend:
        r = ev["_row"]
        try:
            etag = client.put(r["href"], data, r["etag"] if r["sync_state"] == "dirty" else None)
            if not etag:
                etag = client.etag_of(r["href"])

            def done(db, ev=ev, data=data, etag=etag):
                # Si se editó durante la subida, se guarda el ETag nuevo pero sigue pendiente.
                cur = db.execute("SELECT revision FROM events WHERE uuid = ?", (ev["uuid"],)).fetchone()
                if cur is None:
                    return
                state = "synced" if cur[0] == ev["revision"] else "dirty"
                db.execute("UPDATE events SET etag = ?, raw_ics = ?, sync_state = ? WHERE uuid = ?", (etag, data, state, ev["uuid"]))
            write(path, done)
            stats["pushed"] += 1
        except CD.Precondition:
            remote = client.get(r["href"])

            def clash(db, ev=ev, data=data, remote=remote):
                if remote is None:
                    conflict(db, cid, r["href"], ev["uuid"], "deleted_there_changed_here", ev["title"], data, None, None)
                else:
                    conflict(db, cid, r["href"], ev["uuid"], "changed_both" if r["sync_state"] == "dirty" else "exists_there",
                             ev["title"], data, remote[1], remote[0])
            write(path, clash)
            stats["conflicts"] += 1
    for href, etag, title, raw in tomb_rows:
        try:
            client.delete(href, etag)
            write(path, lambda db, href=href: db.execute("DELETE FROM tombstones WHERE calendar_id = ? AND href = ?", (cid, href)) and {})
            stats["deleted"] += 1
        except CD.Precondition:
            remote = client.get(href)

            def clash2(db, href=href, title=title, raw=raw, remote=remote):
                db.execute("DELETE FROM tombstones WHERE calendar_id = ? AND href = ?", (cid, href))
                if remote is not None:
                    conflict(db, cid, href, None, "deleted_here_changed_there", title, raw, remote[1], remote[0])
            write(path, clash2)
            stats["conflicts"] += 1
    # 4. El token, sólo con todo aplicado.
    def tok(db):
        db.execute("UPDATE calendars SET sync_token = ?, last_sync_utc = ? WHERE id = ?", (new_token, now_utc(), cid))
        return {}
    write(path, tok)


def op_sync(path, req):
    CD = dav_module()
    lock = sync_lock()
    if lock is None:
        return {"busy": True, "accounts": []}
    try:
        db = open_read(path)
        if db is None or db.version < 3:
            if db:
                db.close()
            return {"accounts": []}
        try:
            only = req.get("account")
            accs = [a for a in accounts_view(db) if a["enabled"] and (not only or a["id"] == only)]
            urls = {r[0]: r[1] for r in db.execute("SELECT id, url FROM calendars WHERE kind = 'caldav'")}
            home = {r[0]: r[1] for r in db.execute("SELECT id, home_url FROM accounts")}
            backup = snapshot(db.conn, path, "pre-sync") if accs else None
        finally:
            db.close()
        if backup:
            prune_snapshots(path, "pre-sync", PRESYNC_KEEP)
        results = []
        for acc in accs:
            stats = {"pulled": 0, "pushed": 0, "deleted": 0, "conflicts": 0}
            started, error, result = now_utc(), None, "ok"
            progress(account=acc["id"], phase="start")
            try:
                client = CD.Dav(acc["server"], acc["username"], secret_lookup(acc["id"]))
                # Colecciones nuevas en la cuenta: se añaden (visibles); nunca se borra nada local por esto.
                if home.get(acc["id"]):
                    present = {urls[c["id"]] for c in acc["calendars"] if c["id"] in urls}
                    for c in client.calendars(home[acc["id"]]):
                        if c["url"] not in present:
                            write(path, lambda db, c=c: db.execute(
                                "INSERT INTO calendars (id, account_id, kind, name, color, url, read_only, visible) VALUES (?, ?, 'caldav', ?, ?, ?, ?, 1)",
                                (str(uuidlib.uuid4()), acc["id"], c["name"], c["color"], c["url"], 1 if c["readOnly"] else 0)) and {})
                db = need_db(path)
                try:
                    cals = [{"id": r[0], "url": r[1]} for r in db.execute("SELECT id, url FROM calendars WHERE account_id = ?", (acc["id"],))]
                finally:
                    db.close()
                for cal in cals:
                    sync_calendar(path, client, cal, stats)
            except CD.Offline as e:
                result, error = "offline", "Offline: %s" % e
            except CD.AuthError as e:
                result, error = "auth", str(e)
            except Fail as e:
                result, error = e.code, e.message
            except (CD.HttpError, ValueError, SyntaxError) as e:
                result, error = "error", str(e)
            finished = now_utc()

            def log(db, acc=acc, started=started, finished=finished, result=result, error=error, stats=stats):
                db.execute("INSERT INTO sync_log (account_id, started_utc, finished_utc, result, pulled, pushed, deleted, conflicts, error)"
                           " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", (acc["id"], started, finished, result, stats["pulled"], stats["pushed"],
                                                                stats["deleted"], stats["conflicts"], error))
                db.execute("DELETE FROM sync_log WHERE id NOT IN (SELECT id FROM sync_log ORDER BY id DESC LIMIT 200)")
                if result == "ok":
                    db.execute("UPDATE accounts SET last_sync_utc = ?, last_ok_utc = ?, last_error = NULL WHERE id = ?", (finished, finished, acc["id"]))
                else:
                    db.execute("UPDATE accounts SET last_sync_utc = ?, last_error = ? WHERE id = ?", (finished, error, acc["id"]))
                return {}
            write(path, log)
            results.append(dict(stats, account=acc["id"], result=result, error=error))
        check = open_read(path)
        integrity = check is not None
        if check:
            check.close()
        return {"accounts": results, "backup": backup, "integrity": "ok" if integrity else "absent"}
    finally:
        os.close(lock)


def op_conflicts(path, req):
    db = need_db(path)
    try:
        out = []
        names = dict(db.execute("SELECT id, name FROM calendars"))
        for row in db.execute("SELECT id, calendar_id, href, uuid, kind, title, local_ics, remote_ics, remote_etag, created_utc FROM conflicts ORDER BY id"):
            side = {}
            for name, text in (("local", row[6]), ("remote", row[7])):
                if text:
                    try:
                        info = read_remote(text)
                        m = info["master"] or {}
                        side[name] = {"title": m.get("title", ""), "when": (m.get("startDate", "") + " " + m.get("startTime", "")).strip(),
                                      "notes": (m.get("notes") or "")[:300]}
                    except Exception:  # noqa: BLE001
                        side[name] = {"title": "(unreadable)", "when": "", "notes": ""}
                else:
                    side[name] = None
            out.append({"id": row[0], "calendarId": row[1], "calendar": names.get(row[1], ""), "uuid": row[3], "kind": row[4], "title": row[5], "created": row[9],
                        "local": side["local"], "remote": side["remote"]})
        return {"conflicts": out}
    finally:
        db.close()


def op_resolve(path, req):
    """Resolución explícita de un conflicto: local · remote · both. Nada se decide solo."""
    cid_ = req.get("id")
    choice = req.get("choice")
    if choice not in ("local", "remote", "both"):
        raise Fail("bad_request", "choice must be local, remote or both")

    def body(db):
        row = db.execute("SELECT calendar_id, href, uuid, kind, title, local_ics, remote_ics, remote_etag FROM conflicts WHERE id = ?", (cid_,)).fetchone()
        if not row:
            raise Fail("not_found", "That conflict was already resolved")
        cal, href, uuid, kind, title, local_ics, remote_ics, remote_etag = row
        ev = fetch(db, uuid) if uuid else None
        result = {"kind": kind, "choice": choice}
        if kind in ("changed_both", "exists_there"):
            if choice == "local":
                db.execute("UPDATE events SET etag = ?, sync_state = 'dirty' WHERE uuid = ?", (remote_etag, uuid))
            else:
                if choice == "both" and ev:
                    new_uid = str(uuidlib.uuid4())
                    data = render_local(db, ev, new_uid + "@sumi-shell")
                    info = read_remote(data)
                    c = calendars_map(db).get(cal)
                    nid = store_remote(db, cal, None, None, data, info)
                    db.execute("UPDATE events SET href = ?, etag = NULL, sync_state = 'new', ical_uid = ? WHERE uuid = ?",
                               (remote_slot(c, nid)["href"], new_uid + "@sumi-shell", nid))
                    result["copy"] = nid
                store_remote(db, cal, href, remote_etag, remote_ics, read_remote(remote_ics), uid=uuid)
        elif kind == "deleted_there_changed_here":
            if choice in ("local", "both"):
                db.execute("UPDATE events SET etag = NULL, sync_state = 'new' WHERE uuid = ?", (uuid,))
            else:
                db.execute("DELETE FROM events WHERE uuid = ?", (uuid,))
        elif kind == "deleted_here_changed_there":
            if choice == "local":
                db.execute("INSERT OR REPLACE INTO tombstones (calendar_id, href, etag, title, raw_ics, deleted_utc) VALUES (?, ?, ?, ?, ?, ?)",
                           (cal, href, remote_etag, title, remote_ics, now_utc()))
            else:
                store_remote(db, cal, href, remote_etag, remote_ics, read_remote(remote_ics))
        db.execute("DELETE FROM conflicts WHERE id = ?", (cid_,))
        return result
    return write(path, body)


OPS = {"status": op_status, "range": op_range, "get": op_get, "create": op_create, "update": op_update,
       "delete": op_delete, "due": op_due, "fire": op_fire, "export": op_export,
       "import-preview": op_import_preview, "import": op_import, "accounts": op_accounts, "account-add": op_account_add,
       "account-update": op_account_update, "account-remove": op_account_remove, "calendar-update": op_calendar_update,
       "sync": op_sync, "conflicts": op_conflicts, "resolve": op_resolve}


def main():
    try:
        raw = sys.stdin.read(256 * 1024 + 1)
        if len(raw) > 256 * 1024:
            raise Fail("bad_request", "request too large")
        try:
            req = json.loads(raw)
        except ValueError:
            raise Fail("bad_request", "request is not JSON")
        if not isinstance(req, dict) or req.get("op") not in OPS:
            raise Fail("bad_request", "unknown op")
        result = OPS[req["op"]](db_path(), req)
        reply(True, op=req["op"], **result)
        return 0
    except Fail as e:
        reply(False, error=dict({"code": e.code, "message": e.message}, **e.extra))
        return 1
    except Exception as e:  # noqa: BLE001 — una línea JSON siempre, nunca un traceback mudo
        reply(False, error={"code": "internal", "message": "%s: %s" % (type(e).__name__, e)})
        return 2


if __name__ == "__main__":
    sys.exit(main())
