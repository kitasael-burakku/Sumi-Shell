"""Repeticiones del calendario local (RFC 5545, nivel de FECHA) — 2026-10-28.

La hora del día la pone quien llama (la del DTSTART): aquí sólo se calculan los DÍAS.

Regla (dict): freq daily|weekly|monthly|yearly, interval, count | until (AAAA-MM-DD, incluida),
byday ["MO", "2TU", "-1FR"…] (ordinal sólo en monthly/yearly), bymonthday [1..31, -1..-31],
bymonth [1..12], bysetpos [±n], wkst "MO".."SU", rdate [AAAA-MM-DD] (días añadidos).

Lo que no cabe (BYHOUR, BYMINUTE, BYSECOND, BYWEEKNO, BYYEARDAY, frecuencias por hora, ordinales
en semanal/diario) se rechaza con `Unsupported`: quien llama deja esa serie en SÓLO LECTURA con
su original intacto. El DTSTART siempre es la primera ocurrencia y cuenta para COUNT (RFC 5545
§3.8.5.3), también si la regla no lo genera.
"""
import calendar as _cal
import datetime as dt
import re

DAYS = ("MO", "TU", "WE", "TH", "FR", "SA", "SU")
FREQS = ("daily", "weekly", "monthly", "yearly")
BYDAY_RE = re.compile(r"^([+-]?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)$")
MAX_PERIODS = 50000


class Unsupported(Exception):
    pass


def parse_byday(items, freq):
    out = []
    for x in items or []:
        m = BYDAY_RE.match(str(x))
        if not m:
            raise Unsupported("BYDAY=%s" % x)
        n = int(m.group(1)) if m.group(1) else 0
        if n and (abs(n) > 53 or freq in ("daily", "weekly")):
            raise Unsupported("BYDAY=%s with %s" % (x, freq.upper()))
        out.append((n, DAYS.index(m.group(2))))
    return out


def check(rule):
    """Normaliza y valida una regla; Unsupported si queda fuera del motor."""
    if rule.get("freq") not in FREQS:
        raise Unsupported("FREQ=%s" % str(rule.get("freq", "?")).upper())
    for key in ("byhour", "byminute", "bysecond", "byweekno", "byyearday"):
        if rule.get(key):
            raise Unsupported(key.upper())
    parse_byday(rule.get("byday"), rule["freq"])
    for v in rule.get("bymonthday") or []:
        if not isinstance(v, int) or v == 0 or abs(v) > 31:
            raise Unsupported("BYMONTHDAY=%s" % v)
    for v in rule.get("bymonth") or []:
        if not isinstance(v, int) or not 1 <= v <= 12:
            raise Unsupported("BYMONTH=%s" % v)
    for v in rule.get("bysetpos") or []:
        if not isinstance(v, int) or v == 0 or abs(v) > 366:
            raise Unsupported("BYSETPOS=%s" % v)
    if rule.get("wkst", "MO") not in DAYS:
        raise Unsupported("WKST=%s" % rule.get("wkst"))
    return rule


def _month_days(y, m):
    return _cal.monthrange(y, m)[1]


def _monthday_dates(y, m, mds):
    n = _month_days(y, m)
    out = []
    for md in mds:
        d = md if md > 0 else n + md + 1
        if 1 <= d <= n:
            out.append(dt.date(y, m, d))
    return out


def _weekday_dates(first, last, byday):
    """Días entre first y last (incluidos) que cumplen BYDAY; los ordinales cuentan en ese tramo."""
    out = set()
    for n, wd in byday:
        off = (wd - first.weekday()) % 7
        hits = []
        d = first + dt.timedelta(days=off)
        while d <= last:
            hits.append(d)
            d += dt.timedelta(days=7)
        if n == 0:
            out.update(hits)
        elif abs(n) <= len(hits):
            out.add(hits[n - 1] if n > 0 else hits[n])
    return out


def _period(rule, d0, byday, n):
    """Candidatos del n-ésimo periodo (ya filtrados y con BYSETPOS), ordenados."""
    freq, step = rule["freq"], rule.get("interval") or 1
    bymonth = rule.get("bymonth") or []
    bymd = rule.get("bymonthday") or []
    if freq == "yearly":
        y = d0.year + n * step
        if y > 9999:
            return None
        months = bymonth or None
        if bymd or byday:
            cand = None
            if bymd:
                cand = set()
                for m in (months or range(1, 13)):
                    cand.update(_monthday_dates(y, m, bymd))
            if byday:
                wd = set()
                if months:
                    for m in months:
                        wd |= _weekday_dates(dt.date(y, m, 1), dt.date(y, m, _month_days(y, m)), byday)
                else:
                    wd = _weekday_dates(dt.date(y, 1, 1), dt.date(y, 12, 31), byday)
                cand = wd if cand is None else cand & wd
        else:
            cand = set()
            for m in (months or [d0.month]):
                cand.update(_monthday_dates(y, m, [d0.day]))   # un 29-II sólo existe en bisiestos
    elif freq == "monthly":
        y, m = divmod(d0.year * 12 + d0.month - 1 + n * step, 12)
        m += 1
        if y > 9999:
            return None
        if bymonth and m not in bymonth:
            return []
        if bymd or byday:
            cand = set(_monthday_dates(y, m, bymd)) if bymd else None
            if byday:
                wd = _weekday_dates(dt.date(y, m, 1), dt.date(y, m, _month_days(y, m)), byday)
                cand = wd if cand is None else cand & wd
        else:
            cand = set(_monthday_dates(y, m, [d0.day]))       # meses sin ese día: se saltan
    elif freq == "weekly":
        wkst = DAYS.index(rule.get("wkst") or "MO")
        start = d0 - dt.timedelta(days=(d0.weekday() - wkst) % 7) + dt.timedelta(weeks=n * step)
        if start.year > 9999:
            return None
        days = [wd for _, wd in byday] or [d0.weekday()]
        cand = {start + dt.timedelta(days=(wd - wkst) % 7) for wd in days}
        if bymonth:
            cand = {d for d in cand if d.month in bymonth}
    else:
        try:
            d = d0 + dt.timedelta(days=n * step)
        except OverflowError:
            return None
        cand = {d}
        if bymonth:
            cand = {x for x in cand if x.month in bymonth}
        if bymd:
            cand = {x for x in cand if x in _monthday_dates(x.year, x.month, bymd)}
        if byday:
            cand = {x for x in cand if x.weekday() in [wd for _, wd in byday]}
    out = sorted(cand)
    pos = rule.get("bysetpos") or []
    if pos:
        out = sorted({out[p - 1] if p > 0 else out[p] for p in pos if abs(p) <= len(out) and p != 0})
    return out


def _first_period(rule, d0, from_date):
    """Salto aproximado (sin COUNT) para no recorrer décadas de periodos diarios o semanales."""
    if not from_date or rule.get("count") or from_date <= d0:
        return 0
    step = rule.get("interval") or 1
    days = (from_date - d0).days
    if rule["freq"] == "daily":
        return max(0, days // step - 1)
    if rule["freq"] == "weekly":
        return max(0, days // (7 * step) - 1)
    if rule["freq"] == "monthly":
        return max(0, (days // 31) // step - 1)
    return max(0, (days // 366) // step - 1)


def dates(rule, d0, upto, from_date=None):
    """Días de la serie hasta `upto` incluido (más los RDATE), con COUNT/UNTIL aplicados."""
    check(rule)
    byday = parse_byday(rule.get("byday"), rule["freq"])
    until = dt.date.fromisoformat(rule["until"][:10]) if rule.get("until") else None
    count = rule.get("count")
    last = min(upto, until) if until else upto
    out = [d0]                     # el DTSTART siempre es la primera ocurrencia
    n = _first_period(rule, d0, from_date)
    empty_run = 0
    for _ in range(MAX_PERIODS):
        cand = _period(rule, d0, byday, n)
        n += 1
        if cand is None:
            break
        if not cand:
            empty_run += 1
            if empty_run > 4000:   # una regla que nunca produce nada (31-II…): se acaba aquí
                break
            continue
        empty_run = 0
        stop = False
        for d in cand:
            if d <= d0:
                continue
            if d > last or (count and len(out) >= count):
                stop = True
                break
            out.append(d)
        if stop or cand[0] > last:
            break
    extra = []
    for r in rule.get("rdate") or []:
        d = dt.date.fromisoformat(str(r)[:10])
        if d != d0 and d <= upto and d not in out:
            extra.append(d)
    if count:
        out = out[:count]
    return sorted(set(out + extra))


def to_ical(rule):
    """Regla → texto RRULE (sin RDATE, que va aparte)."""
    parts = ["FREQ=" + rule["freq"].upper()]
    if (rule.get("interval") or 1) != 1:
        parts.append("INTERVAL=%d" % rule["interval"])
    for key in ("bymonth", "bymonthday", "bysetpos"):
        if rule.get(key):
            parts.append("%s=%s" % (key.upper(), ",".join(str(v) for v in rule[key])))
    if rule.get("byday"):
        parts.append("BYDAY=" + ",".join(rule["byday"]))
    if rule.get("wkst") and rule["wkst"] != "MO":
        parts.append("WKST=" + rule["wkst"])
    if rule.get("count"):
        parts.append("COUNT=%d" % rule["count"])
    if rule.get("until"):
        parts.append("UNTIL=" + rule["until"][:10].replace("-", ""))
    return ";".join(parts)


def from_ical(text):
    """Texto RRULE → regla (Unsupported si no cabe). UNTIL con hora se reduce a su fecha."""
    parts = {}
    for p in text.strip().split(";"):
        if "=" in p:
            k, v = p.split("=", 1)
            parts[k.upper()] = v
    rule = {"freq": parts.get("FREQ", "").lower(), "interval": int(parts.get("INTERVAL", "1") or 1)}
    for key in ("BYHOUR", "BYMINUTE", "BYSECOND", "BYWEEKNO", "BYYEARDAY"):
        if key in parts:
            raise Unsupported(key)
    known = {"FREQ", "INTERVAL", "BYDAY", "BYMONTHDAY", "BYMONTH", "BYSETPOS", "WKST", "COUNT", "UNTIL"}
    extra = set(parts) - known
    if extra:
        raise Unsupported(", ".join(sorted(extra)))
    if "BYDAY" in parts:
        rule["byday"] = [x.strip().upper() for x in parts["BYDAY"].split(",") if x.strip()]
    for key in ("BYMONTHDAY", "BYMONTH", "BYSETPOS"):
        if key in parts:
            try:
                rule[key.lower()] = [int(x) for x in parts[key].split(",") if x.strip()]
            except ValueError:
                raise Unsupported("%s=%s" % (key, parts[key]))
    if "WKST" in parts:
        rule["wkst"] = parts["WKST"].upper()
    if "COUNT" in parts:
        rule["count"] = int(parts["COUNT"])
    elif "UNTIL" in parts:
        u = parts["UNTIL"]
        rule["until"] = "%s-%s-%s" % (u[0:4], u[4:6], u[6:8])
    return check(rule)


def is_simple(rule):
    """¿Cabe en el formulario de la shell? (frecuencia, cada N, días de la semana, fin)."""
    if not rule:
        return True
    if rule.get("bymonth") or rule.get("bymonthday") or rule.get("bysetpos") or rule.get("rdate"):
        return False
    if (rule.get("wkst") or "MO") != "MO":
        return False
    if rule.get("byday"):
        if rule["freq"] != "weekly" or any(not x.isalpha() for x in rule["byday"]):
            return False
    return True
