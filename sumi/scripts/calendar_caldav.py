"""Cliente CalDAV mínimo del calendario local (2026-10-28): WebDAV con urllib, sin dependencias.

Sólo protocolo; la base y las decisiones de sincronización las lleva `calendar-store.py`.

- `discover(url)`: current-user-principal (en la URL o en /.well-known/caldav), calendar-home-set
  y las colecciones con VEVENT (nombre, color, sólo lectura, ctag, sync-token).
- `changes(cal, token)`: REPORT sync-collection (RFC 6578); `TokenInvalid` si el servidor ya no
  acepta el token. `etags(cal)`: PROPFIND Depth 1 con getetag (sincronización completa).
- `multiget(cal, hrefs)`: REPORT calendar-multiget por lotes.
- `put(href, data, etag)`: If-Match con etag, If-None-Match: * al crear; `Precondition` si 412.
- `delete(href, etag)`: If-Match; 404 cuenta como hecho.

Errores: `Offline` (sin red, DNS, tiempo agotado: no es un fallo de los datos), `AuthError`
(401/403), `HttpError`. Sólo https, salvo loopback (Radicale de pruebas en 127.0.0.1).
Las credenciales llegan en memoria (del llavero); nunca se escriben ni se registran.
"""
import base64
import http.client
import socket
import ssl
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

NS = {"d": "DAV:", "c": "urn:ietf:params:xml:ns:caldav", "cs": "http://calendarserver.org/ns/", "ical": "http://apple.com/ns/ical/"}
LOOPBACK = ("localhost", "127.0.0.1", "::1")


class Offline(Exception):
    pass


class AuthError(Exception):
    pass


class HttpError(Exception):
    def __init__(self, status, msg=""):
        super().__init__("HTTP %s %s" % (status, msg))
        self.status = status


class Precondition(Exception):
    pass


class TokenInvalid(Exception):
    pass


def check_url(url):
    u = urllib.parse.urlsplit(url)
    if u.scheme not in ("https", "http") or not u.hostname:
        raise ValueError("Use a full https:// address")
    if u.scheme == "http" and u.hostname not in LOOPBACK:
        raise ValueError("Use https:// (plain http is only allowed on this computer)")
    return url


def _t(tag):
    p, n = tag.split(":")
    return "{%s}%s" % (NS[p], n)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def css_color(c):
    """calendar-color (Apple): #RRGGBB o #RRGGBBAA → #RRGGBB. QML leería 9 dígitos como #AARRGGBB."""
    c = (c or "").strip()
    if len(c) in (7, 9) and c[0] == "#" and all(x in "0123456789abcdefABCDEF" for x in c[1:]):
        return c[:7].upper()
    return ""


class Dav:
    def __init__(self, base, user, password, timeout=15):
        self.base = check_url(base)
        self.auth = "Basic " + base64.b64encode(("%s:%s" % (user, password)).encode()).decode()
        self.timeout = timeout
        self.opener = urllib.request.build_opener(_NoRedirect, urllib.request.HTTPSHandler(context=ssl.create_default_context()))

    def url(self, href):
        return urllib.parse.urljoin(self.base, href)

    def request(self, method, href, body=None, headers=None, redirects=3):
        url = self.url(href)
        check_url(url)
        h = {"Authorization": self.auth, "User-Agent": "SumiShell-Calendar/1"}
        if body is not None:
            h["Content-Type"] = headers.pop("Content-Type") if headers and "Content-Type" in headers else 'application/xml; charset="utf-8"'
        h.update(headers or {})
        req = urllib.request.Request(url, data=body.encode() if isinstance(body, str) else body, method=method, headers=h)
        try:
            with self.opener.open(req, timeout=self.timeout) as r:
                return r.status, dict(r.headers), r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            status = e.code
            if status in (301, 302, 303, 307, 308) and redirects > 0 and e.headers.get("Location"):
                loc = urllib.parse.urljoin(url, e.headers["Location"])
                if urllib.parse.urlsplit(loc).scheme != urllib.parse.urlsplit(url).scheme:
                    raise HttpError(status, "redirect changes the scheme")
                return self.request(method, loc, body, headers, redirects - 1)
            if status in (401, 403) and method in ("PROPFIND",) and "Authorization" in h and status == 401:
                raise AuthError("The server rejected the user name or password")
            text = e.read().decode("utf-8", "replace") if e.fp else ""
            return status, dict(e.headers or {}), text
        except (urllib.error.URLError, socket.timeout, TimeoutError, ConnectionError, http.client.HTTPException, OSError) as e:
            raise Offline(str(getattr(e, "reason", e)))

    # ---- WebDAV -------------------------------------------------------------------------------

    def propfind(self, href, props, depth):
        body = '<?xml version="1.0" encoding="utf-8"?><d:propfind %s><d:prop>%s</d:prop></d:propfind>' % (
            " ".join('xmlns:%s="%s"' % kv for kv in NS.items()), "".join("<%s/>" % p for p in props))
        status, headers, text = self.request("PROPFIND", href, body, {"Depth": str(depth)})
        if status == 401:
            raise AuthError("The server rejected the user name or password")
        if status != 207:
            raise HttpError(status, "PROPFIND %s" % href)
        return self.multistatus(text)

    @staticmethod
    def multistatus(text):
        """→ [(href, {prop: Element}, status_de_la_respuesta)]."""
        out = []
        root = ET.fromstring(text)
        for resp in root.findall(_t("d:response")):
            href = urllib.parse.unquote(resp.findtext(_t("d:href")) or "")
            props, rstatus = {}, resp.findtext(_t("d:status")) or ""
            for ps in resp.findall(_t("d:propstat")):
                st = ps.findtext(_t("d:status")) or ""
                if " 200 " not in st:
                    continue
                for prop in ps.find(_t("d:prop")) or []:
                    props[prop.tag] = prop
            out.append((href, props, rstatus))
        return out

    def discover(self):
        """→ (home_url, [calendar dicts])."""
        principal = None
        for start in (self.base, "/.well-known/caldav"):
            try:
                res = self.propfind(start, ["d:current-user-principal"], 0)
            except HttpError:
                continue
            for _, props, _ in res:
                el = props.get(_t("d:current-user-principal"))
                if el is not None and el.findtext(_t("d:href")):
                    principal = el.findtext(_t("d:href"))
            if principal:
                break
        if not principal:
            raise HttpError(404, "no CalDAV principal found at this address")
        res = self.propfind(principal, ["c:calendar-home-set"], 0)
        home = None
        for _, props, _ in res:
            el = props.get(_t("c:calendar-home-set"))
            if el is not None and el.findtext(_t("d:href")):
                home = el.findtext(_t("d:href"))
        if not home:
            raise HttpError(404, "the server did not say where the calendars are")
        return home, self.calendars(home)

    def calendars(self, home):
        res = self.propfind(home, ["d:resourcetype", "d:displayname", "ical:calendar-color", "c:supported-calendar-component-set",
                                   "d:current-user-privilege-set", "cs:getctag", "d:sync-token"], 1)
        out = []
        for href, props, _ in res:
            rt = props.get(_t("d:resourcetype"))
            if rt is None or rt.find(_t("c:calendar")) is None:
                continue
            comps = props.get(_t("c:supported-calendar-component-set"))
            if comps is not None and comps.findall(_t("c:comp")) and not any(c.get("name") == "VEVENT" for c in comps.findall(_t("c:comp"))):
                continue
            privs = props.get(_t("d:current-user-privilege-set"))
            writable = True
            if privs is not None:
                names = {p[0].tag for p in privs.findall(_t("d:privilege")) if len(p)}
                writable = bool(names & {_t("d:write"), _t("d:all"), _t("d:write-content")})
            name = (props[_t("d:displayname")].text if _t("d:displayname") in props else "") or href.rstrip("/").split("/")[-1]
            color = props[_t("ical:calendar-color")].text if _t("ical:calendar-color") in props else ""
            out.append({"url": href if href.endswith("/") else href + "/", "name": name.strip(), "color": css_color(color),
                        "readOnly": not writable,
                        "ctag": props[_t("cs:getctag")].text if _t("cs:getctag") in props else None,
                        "syncToken": props[_t("d:sync-token")].text if _t("d:sync-token") in props else None})
        return out

    def token(self, cal):
        res = self.propfind(cal, ["d:sync-token", "cs:getctag"], 0)
        for _, props, _ in res:
            if _t("d:sync-token") in props:
                return props[_t("d:sync-token")].text
        return None

    def etags(self, cal):
        """Sincronización completa: {href: etag} de los objetos de la colección."""
        out = {}
        for href, props, _ in self.propfind(cal, ["d:getetag", "d:resourcetype"], 1):
            rt = props.get(_t("d:resourcetype"))
            if rt is not None and len(rt):
                continue          # la propia colección
            if _t("d:getetag") in props and href.rstrip("/") != urllib.parse.urlsplit(self.url(cal)).path.rstrip("/"):
                out[href] = props[_t("d:getetag")].text
        return out

    def changes(self, cal, token):
        """→ ({href: etag} cambiados o nuevos, [hrefs] borrados, token nuevo)."""
        body = ('<?xml version="1.0" encoding="utf-8"?><d:sync-collection xmlns:d="DAV:"><d:sync-token>%s</d:sync-token>'
                '<d:sync-level>1</d:sync-level><d:prop><d:getetag/></d:prop></d:sync-collection>') % _xml(token or "")
        status, _, text = self.request("REPORT", cal, body, {"Depth": "1"})
        if status in (403, 409, 412, 400) and token:
            raise TokenInvalid(text[:200])
        if status == 401:
            raise AuthError("The server rejected the user name or password")
        if status != 207:
            raise HttpError(status, "sync-collection")
        root = ET.fromstring(text)
        changed, removed = {}, []
        for resp in root.findall(_t("d:response")):
            href = urllib.parse.unquote(resp.findtext(_t("d:href")) or "")
            st = resp.findtext(_t("d:status")) or ""
            if " 404 " in st:
                removed.append(href)
                continue
            for ps in resp.findall(_t("d:propstat")):
                if " 200 " in (ps.findtext(_t("d:status")) or ""):
                    et = ps.find(_t("d:prop")).findtext(_t("d:getetag"))
                    if et:
                        changed[href] = et
        return changed, removed, root.findtext(_t("d:sync-token"))

    def multiget(self, cal, hrefs):
        """→ {href: (etag, calendar-data)}."""
        out = {}
        hrefs = list(hrefs)
        for i in range(0, len(hrefs), 50):
            chunk = hrefs[i:i + 50]
            body = ('<?xml version="1.0" encoding="utf-8"?><c:calendar-multiget xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
                    '<d:prop><d:getetag/><c:calendar-data/></d:prop>%s</c:calendar-multiget>') % "".join(
                        "<d:href>%s</d:href>" % _xml(urllib.parse.quote(h)) for h in chunk)
            status, _, text = self.request("REPORT", cal, body, {"Depth": "1"})
            if status != 207:
                raise HttpError(status, "calendar-multiget")
            for href, props, _ in self.multistatus(text):
                data = props.get(_t("c:calendar-data"))
                et = props.get(_t("d:getetag"))
                if data is not None and data.text:
                    out[href] = (et.text if et is not None else None, data.text)
        return out

    def get(self, href):
        status, headers, text = self.request("GET", href)
        if status == 404:
            return None
        if status != 200:
            raise HttpError(status, "GET")
        return headers.get("ETag") or headers.get("Etag"), text

    def put(self, href, data, etag=None):
        """Crea (etag None: If-None-Match: *) o sustituye (If-Match). → etag nuevo o None."""
        h = {"Content-Type": "text/calendar; charset=utf-8"}
        if etag:
            h["If-Match"] = etag
        else:
            h["If-None-Match"] = "*"
        status, headers, _ = self.request("PUT", href, data, h)
        if status == 412:
            raise Precondition(href)
        if status == 401:
            raise AuthError("The server rejected the user name or password")
        if status not in (200, 201, 204):
            raise HttpError(status, "PUT")
        return headers.get("ETag") or headers.get("Etag")

    def delete(self, href, etag):
        status, _, _ = self.request("DELETE", href, None, {"If-Match": etag} if etag else {})
        if status == 412:
            raise Precondition(href)
        if status not in (200, 204, 404):
            raise HttpError(status, "DELETE")

    def etag_of(self, href):
        for h, props, _ in self.propfind(href, ["d:getetag"], 0):
            if _t("d:getetag") in props:
                return props[_t("d:getetag")].text
        return None


def _xml(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
