#!/usr/bin/env python3
"""Prueba de velocidad de la red (Network → Speed test, 2026-11-14).

    speedtest.py path [--base URL] [--family auto|4|6] [--fake ESCENARIO]
    speedtest.py run  [--base URL] [--family auto|4|6] [--streams N] [--secs S]
                      [--budget-down-mb N] [--budget-up-mb N] [--fake ESCENARIO]

`path` no hace HTTP: resuelve el servidor y dice por dónde saldría el tráfico (interfaz de la ruta por defecto,
tipo, si NetworkManager la marca como medida). La UI lo usa para pedir confirmación ANTES de gastar datos.

`run` mide latencia, bajada y subida contra el borde de Cloudflare (`/__down?bytes=N`, `/__up`: el protocolo de su
motor MIT `@cloudflare/speedtest`). Sólo biblioteca estándar.

PROTOCOLO (v1): una línea JSON por evento en stdout, sin texto localizado; los errores llevan un código estable:
    hello · path · phase · ping · pingLost · latency · down · downDone · up · upDone · error · end
    códigos: offline dns connect tls timeout stalled refused ratelimited http internal
    (`ratelimited` = 429: Cloudflare limita las pruebas de esta IP un rato; `refused` = 403. Con `Retry-After`, el error
    lleva `retryAfter` en segundos.)
La IP pública NUNCA sale ni se registra (`/cdn-cgi/trace` sólo aporta `colo`).

QUÉ SE MIDE. Throughput medido de extremo a extremo por la ruta por defecto, no la velocidad de enlace. Varias
conexiones en paralelo durante un tiempo fijo; el resultado descarta el arranque (slow start de TCP) y promedia la
ventana estable. En la subida cuenta lo CONFIRMADO por TCP (enviado − cola del socket, `TIOCOUTQ`): contar lo
escrito en el socket inflaría el principio con lo que se queda en los búferes del kernel.

CANCELAR. `cancel` o EOF en stdin, SIGTERM/SIGINT, o la muerte del padre (PR_SET_PDEATHSIG): se cortan los sockets
desde fuera (shutdown) y sale en menos de un segundo. Un plazo absoluto cubre cualquier otra cosa.

Salida: 0 hecha · 2 cancelada · 3 fallida · 64 uso.
"""
import sys

sys.dont_write_bytecode = True

import argparse  # noqa: E402
import ctypes  # noqa: E402
import errno  # noqa: E402
import fcntl  # noqa: E402
import http.client  # noqa: E402
import json  # noqa: E402
import math  # noqa: E402
import os  # noqa: E402
import random  # noqa: E402
import shutil  # noqa: E402
import signal  # noqa: E402
import socket  # noqa: E402
import ssl  # noqa: E402
import statistics  # noqa: E402
import struct  # noqa: E402
import subprocess  # noqa: E402
import termios  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402
import urllib.parse  # noqa: E402

PROTO = 1
DEFAULT_BASE = "https://speed.cloudflare.com"
CONNECT_TIMEOUT = 5.0
READ_TIMEOUT = 5.0
STALL_SECS = 5.0
PING_SAMPLES = 10
# El trabajador de speed.cloudflare.com a veces tarda segundos en contestar un ping (medido el 2026-11-14:
# `cfSpeedWorker;dur=2557` entre dos de 17 ms). Un ping así se descarta y se sigue: no puede tumbar la prueba.
PING_TIMEOUT = 3.0
PING_MAX_LOST = 6
PING_PHASE_SECS = 15.0
PING_MIN_SAMPLES = 3
# Tope de 50 MB por petición: speed.cloudflare.com responde 403 desde 100 MB justos (medido el 2026-11-14: 99 999 999
# da 200, 100 000 000 da 403) y su propio motor no sube más de 50 MB. A 1 Gb/s con 4 conexiones, ~1,6 s por petición.
SIZES = (1_000_000, 10_000_000, 25_000_000, 50_000_000)
CHUNK = 64 * 1024
UP_BUFFER = 1024 * 1024

def _user_agent():
    """Un cliente que se identifica (2026-11-14): `http.client` no manda User-Agent. Versión de `version.json`."""
    try:
        here = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(here, "..", "version.json"), encoding="utf-8") as f:
            v = str(json.load(f).get("version", "")).strip()
    except (OSError, ValueError, AttributeError):
        v = ""
    return "sumi-shell-speedtest/" + (v if v and all(c.isalnum() or c in ".-+" for c in v) else "0")


USER_AGENT = _user_agent()
HEADERS = {"User-Agent": USER_AGENT}

STOP = threading.Event()
DEADLINE = threading.Event()
ENDED = threading.Event()
_out_lock = threading.Lock()
TARGETS = []


class Failure(Exception):
    def __init__(self, code, detail="", retry_after=None):
        super().__init__(detail or code)
        self.code = code
        self.detail = detail
        self.retry_after = retry_after


class Cancelled(Exception):
    pass


def emit(obj):
    line = json.dumps(obj, separators=(",", ":"))
    with _out_lock:
        if ENDED.is_set():
            return
        if obj.get("t") == "end":
            ENDED.set()
        try:
            sys.stdout.write(line + "\n")
            sys.stdout.flush()
        except (BrokenPipeError, ValueError):
            STOP.set()      # el lector se fue: no tiene sentido seguir midiendo


def check_stop():
    if STOP.is_set():
        raise Cancelled()


def wait(secs):
    """Dormir sin dejar de oír la cancelación."""
    if STOP.wait(secs):
        raise Cancelled()


# ---- ciclo de vida -----------------------------------------------------------------------------

def watch_parent():
    """El padre muere → SIGTERM. Si ya había muerto antes de pedirlo, salir."""
    ppid = os.getppid()
    try:
        libc = ctypes.CDLL("libc.so.6", use_errno=True)
        libc.prctl(1, int(signal.SIGTERM), 0, 0, 0)       # PR_SET_PDEATHSIG
    except (OSError, AttributeError):
        pass
    if os.getppid() != ppid:
        STOP.set()


def watch_stdin():
    def loop():
        try:
            for raw in sys.stdin.buffer:
                if raw.strip() == b"cancel":
                    break
        except (OSError, ValueError):
            pass
        STOP.set()          # «cancel» o EOF: el dueño ya no escucha
    threading.Thread(target=loop, name="stdin", daemon=True).start()


def on_signal(_signum, _frame):
    STOP.set()


def watch_stop():
    """Al cancelar: cortar los sockets y, si el hilo principal sigue atascado (un connect, un TLS), salir igual."""
    def loop():
        STOP.wait()
        for t in list(TARGETS):
            t.cut_all()
        time.sleep(0.8)
        if DEADLINE.is_set():
            emit({"t": "error", "code": "timeout", "detail": "The test took too long"})
            emit({"t": "end", "state": "failed", "code": "timeout"})
            code = 3
        else:
            emit({"t": "end", "state": "cancelled"})
            code = 2
        try:
            sys.stdout.flush()
        finally:
            os._exit(code)
    threading.Thread(target=loop, name="stop", daemon=True).start()


# ---- red: resolver, conectar, clasificar errores ----------------------------------------------

class Target:
    def __init__(self, base, family):
        u = urllib.parse.urlsplit(base)
        if u.scheme not in ("http", "https") or not u.hostname:
            raise Failure("internal", "Bad base URL")
        self.scheme = u.scheme
        self.host = u.hostname
        self.port = u.port or (443 if u.scheme == "https" else 80)
        self.prefix = u.path.rstrip("/")
        self.family = {"4": socket.AF_INET, "6": socket.AF_INET6}.get(family, socket.AF_UNSPEC)
        self.addr = None        # (af, ip) elegido una vez: todas las conexiones van al mismo sitio
        self.ctx = ssl.create_default_context() if self.scheme == "https" else None
        self._conns = set()
        self._lock = threading.Lock()
        TARGETS.append(self)

    def resolve(self):
        box = {}

        def work():
            try:
                box["r"] = socket.getaddrinfo(self.host, self.port, self.family, socket.SOCK_STREAM)
            except Exception as e:      # noqa: BLE001 — se reclasifica abajo
                box["e"] = e
        t = threading.Thread(target=work, name="dns", daemon=True)
        t.start()
        deadline = time.monotonic() + CONNECT_TIMEOUT
        while t.is_alive():
            if time.monotonic() > deadline:
                raise Failure("dns", "The name lookup timed out")
            wait(0.05)
        if "e" in box:
            raise classify(box["e"])
        if not box.get("r"):
            raise Failure("dns", "No address for " + self.host)
        af, _t, _p, _c, sa = box["r"][0]
        self.addr = (af, sa[0])
        return self.addr

    def connection(self):
        af, ip = self.addr
        cls = http.client.HTTPSConnection if self.ctx else http.client.HTTPConnection
        kw = {"context": self.ctx} if self.ctx else {}
        conn = cls(self.host, self.port, timeout=CONNECT_TIMEOUT, **kw)
        port = self.port
        conn._create_connection = lambda _a, timeout, src: socket.create_connection((ip, port), timeout, src)
        with self._lock:
            self._conns.add(conn)
        return conn

    def open(self):
        conn = self.connection()
        try:
            conn.connect()
            conn.sock.settimeout(READ_TIMEOUT)
        except Exception as e:      # noqa: BLE001
            self.drop(conn)
            if STOP.is_set():
                raise Cancelled()
            raise classify(e)
        return conn

    def drop(self, conn):
        with self._lock:
            self._conns.discard(conn)
        try:
            conn.close()
        except Exception:       # noqa: BLE001
            pass

    def cut_all(self):
        """Desbloquear cualquier recv/send en curso, desde otro hilo."""
        with self._lock:
            conns = list(self._conns)
        for c in conns:
            s = c.sock
            if s is not None:
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    def url(self, path):
        return self.prefix + path


def classify(e):
    if isinstance(e, Failure):
        return e
    if isinstance(e, socket.gaierror):
        return Failure("dns", "Couldn't resolve the test server")
    if isinstance(e, ssl.SSLError):
        return Failure("tls", "Secure connection failed")
    if isinstance(e, (socket.timeout, TimeoutError)):
        return Failure("timeout", "The server didn't answer in time")
    if isinstance(e, ConnectionRefusedError):
        return Failure("connect", "The test server refused the connection")
    if isinstance(e, OSError) and e.errno in (errno.ENETUNREACH, errno.EHOSTUNREACH, errno.ENETDOWN):
        return Failure("offline", "No route to the Internet")
    if isinstance(e, (ConnectionError, http.client.HTTPException, OSError)):
        return Failure("connect", "The connection to the test server dropped")
    return Failure("internal", type(e).__name__)


def check_status(resp):
    if resp.status == 429:
        ra = (resp.getheader("retry-after") or "").strip()
        raise Failure("ratelimited", "The test server is limiting tests from this connection (HTTP 429)",
                      int(ra) if ra.isdigit() and int(ra) < 86400 else None)
    if resp.status == 403:
        raise Failure("refused", "The test server refused the test (HTTP 403)")
    if resp.status != 200:
        raise Failure("http", "Unexpected answer from the test server (HTTP %d)" % resp.status)


# ---- la ruta (sin HTTP) -------------------------------------------------------------------------

def run_cmd(argv):
    if not shutil.which(argv[0]):
        return None
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=3, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return p


def route_dev(ip):
    p = run_cmd(["ip", "-j", "route", "get", ip])
    if p is None:
        return None, None
    if p.returncode != 0:
        msg = (p.stderr or "").lower()
        return None, ("offline" if "unreachable" in msg else None)
    try:
        r = json.loads(p.stdout)
        return (r[0].get("dev") or None) if r else None, None
    except (ValueError, IndexError, AttributeError):
        return None, None


def dev_facts(dev):
    """(tipo, medida): por NetworkManager; sin él, por el nombre y medida desconocida."""
    kind, metered = None, None
    p = run_cmd(["nmcli", "-g", "GENERAL.TYPE,GENERAL.METERED", "device", "show", dev])
    if p is not None and p.returncode == 0:
        lines = [ln.strip() for ln in p.stdout.splitlines()]
        t = lines[0] if lines else ""
        m = lines[1] if len(lines) > 1 else ""
        kind = {"ethernet": "ethernet", "wifi": "wifi", "wireguard": "vpn", "tun": "vpn",
                "vpn": "vpn", "ip-tunnel": "vpn"}.get(t, "other" if t else None)
        if m.startswith("yes"):
            metered = True
        elif m.startswith("no"):
            metered = False
    if kind is None:
        n = dev or ""
        kind = ("vpn" if n.startswith(("wg", "tun", "tap", "ppp")) else
                "wifi" if n.startswith("wl") else
                "ethernet" if n.startswith(("en", "eth")) else "other")
    return kind, metered


def path_info(target):
    af, ip = target.resolve()
    dev, why = route_dev(ip)
    if why == "offline":
        raise Failure("offline", "No route to the Internet")
    kind, metered = dev_facts(dev) if dev else ("other", None)
    if ip in ("127.0.0.1", "::1"):
        kind = "loopback"
    return {"t": "path", "dev": dev or "", "kind": kind, "metered": metered,
            "family": 6 if af == socket.AF_INET6 else 4}


def colo_of(target):
    """El centro de datos que atiende (`colo`), si el servidor lo dice. Nunca la IP."""
    conn = None
    try:
        conn = target.open()
        conn.request("GET", target.url("/cdn-cgi/trace"), headers=HEADERS)
        resp = conn.getresponse()
        body = resp.read(4096).decode("ascii", "replace")
        if resp.status != 200:
            return ""
        for line in body.splitlines():
            k, _, v = line.partition("=")
            if k == "colo":
                return v.strip()[:8]
    except (Failure, Cancelled):
        raise
    except Exception:       # noqa: BLE001 — dato accesorio
        return ""
    finally:
        if conn is not None:
            target.drop(conn)
    return ""


# ---- latencia -----------------------------------------------------------------------------------

def server_ms(resp):
    """Lo que tardó el servidor, a descontar del tiempo hasta el primer byte: la SUMA de todos los `dur` de todas las
    cabeceras Server-Timing. Cloudflare manda dos (medido el 2026-11-14): `cfSpeedEdge;dur=3, cfSpeedWorker;dur=17` y
    `cfL4;desc=…` sin `dur`; descontar sólo el primero dejaba ~20 ms de servidor (y picos de 170) dentro del ping."""
    total = 0.0
    for st in resp.headers.get_all("server-timing") or []:
        for part in st.split(","):
            for kv in part.split(";"):
                k, _, v = kv.strip().partition("=")
                if k.lower() == "dur":
                    try:
                        total += max(0.0, float(v))
                    except ValueError:
                        pass
    return total


def measure_latency(target):
    emit({"t": "phase", "name": "latency"})
    samples, lost, conn, warmed = [], 0, None, False
    deadline = time.monotonic() + PING_PHASE_SECS
    try:
        while len(samples) < PING_SAMPLES and lost < PING_MAX_LOST and time.monotonic() < deadline:
            check_stop()
            if conn is None:
                conn = target.open()
                conn.sock.settimeout(PING_TIMEOUT)
            t0 = time.perf_counter()
            try:
                conn.request("GET", target.url("/__down?bytes=0"), headers=HEADERS)
                resp = conn.getresponse()
                t1 = time.perf_counter()
                resp.read()
            except Exception as e:      # noqa: BLE001
                if STOP.is_set():
                    raise Cancelled()
                f = classify(e)
                if f.code not in ("timeout", "connect"):
                    raise f
                lost += 1               # un ping que no vuelve a tiempo: fuera, conexión nueva y seguir
                emit({"t": "pingLost", "lost": lost})     # también mantiene vivo el vigilante de la shell
                target.drop(conn)
                conn = None
                continue
            check_status(resp)
            if not warmed:              # el primero calienta (keep-alive, caché del servidor)
                warmed = True
                continue
            ms = max(0.0, (t1 - t0) * 1000 - server_ms(resp))
            samples.append(ms)
            emit({"t": "ping", "i": len(samples), "ms": round(ms, 2)})
    finally:
        if conn is not None:
            target.drop(conn)
    if len(samples) < PING_MIN_SAMPLES:
        raise Failure("timeout", "The test server didn't answer in time")
    med = statistics.median(samples)
    jitter = statistics.fmean(abs(a - b) for a, b in zip(samples, samples[1:])) if len(samples) > 1 else 0.0
    out = {"ms": round(med, 2), "jitter": round(jitter, 2), "lost": lost}
    emit(dict({"t": "latency"}, **out))
    return out


# ---- throughput ---------------------------------------------------------------------------------

def outq(sock):
    """Bytes aún en la cola de envío del socket (sin confirmar por TCP)."""
    try:
        buf = fcntl.ioctl(sock.fileno(), termios.TIOCOUTQ, struct.pack("i", 0))
        return struct.unpack("i", buf)[0]
    except (OSError, ValueError, AttributeError):
        return 0


class Worker(threading.Thread):
    def __init__(self, phase, direction, target, budget, payload):
        super().__init__(name="%s-%s" % (direction, id(self)), daemon=True)
        self.phase = phase
        self.direction = direction
        self.target = target
        self.budget = budget
        self.payload = payload
        self.done = 0           # bytes de peticiones terminadas (o confirmados, en la subida)
        self.cur = 0            # bytes de la petición en curso
        self.conn = None
        self.error = None

    def counted(self):
        if self.direction == "up":
            c = self.conn
            q = outq(c.sock) if c is not None and c.sock is not None else 0
            return self.done + max(0, self.cur - q)
        return self.done + self.cur

    def run(self):
        size_i = 0
        try:
            while not self.phase.over():
                conn = self.target.open()
                conn.sock.settimeout(STALL_SECS * 2)     # el atasco lo declara la fase (STALL_SECS), no el socket
                self.conn = conn
                try:
                    while not self.phase.over():
                        size = SIZES[size_i]
                        t0 = time.monotonic()
                        self.cur = 0
                        if self.direction == "down":
                            self._down(conn, size)
                        else:
                            self._up(conn, size)
                        self.done += self.cur
                        self.cur = 0
                        if time.monotonic() - t0 < 1.0 and size_i < len(SIZES) - 1:
                            size_i += 1         # peticiones cortas: más grandes, menos sobrecarga
                finally:
                    self.conn = None
                    self.done += self.cur
                    self.cur = 0
                    self.target.drop(conn)
        except Exception as e:      # noqa: BLE001
            if not self.phase.over() and not STOP.is_set():
                self.error = classify(e)
                self.phase.fail()

    def _down(self, conn, size):
        conn.request("GET", self.target.url("/__down?bytes=%d" % size), headers=HEADERS)
        resp = conn.getresponse()
        check_status(resp)
        buf = bytearray(256 * 1024)
        mv = memoryview(buf)
        while not self.phase.over():
            n = resp.readinto(mv)
            if not n:
                return
            self.cur += n
            if self.phase.spent() >= self.budget:
                self.phase.cap()
                return

    def _up(self, conn, size):
        conn.putrequest("POST", self.target.url("/__up"), skip_accept_encoding=True)
        conn.putheader("User-Agent", USER_AGENT)
        conn.putheader("Content-Type", "application/octet-stream")
        conn.putheader("Content-Length", str(size))
        conn.endheaders()
        sent, data = 0, memoryview(self.payload)
        off = random.randrange(0, len(data) - CHUNK)
        while sent < size:
            if self.phase.over():
                return
            n = min(CHUNK, size - sent)
            if off + n > len(data):
                off = 0
            conn.send(data[off:off + n])
            off += n
            sent += n
            self.cur = sent
            if self.phase.spent() >= self.budget:
                self.phase.cap()
                return
        resp = conn.getresponse()
        resp.read()
        check_status(resp)


class Phase:
    def __init__(self, name, target, secs, streams, budget):
        self.name = name
        self.target = target
        self.secs = secs
        self.streams = streams
        self.budget = budget
        self.workers = []
        self._over = threading.Event()
        self.capped = False
        self.limited = False

    def over(self):
        return self._over.is_set() or STOP.is_set()

    def cap(self):
        self.capped = True
        self._over.set()

    def fail(self):
        self._over.set()

    def spent(self):
        return sum(w.done + w.cur for w in self.workers)

    def counted(self):
        return sum(w.counted() for w in self.workers)

    def run(self):
        emit({"t": "phase", "name": "download" if self.name == "down" else "upload"})
        payload = os.urandom(UP_BUFFER) if self.name == "up" else b""
        self.workers = [Worker(self, self.name, self.target, self.budget, payload) for _ in range(self.streams)]
        cpu0, t0 = time.process_time(), time.monotonic()
        for w in self.workers:
            w.start()
        samples = [(0.0, 0)]
        last_emit, last_change, last_bytes = 0.0, 0.0, 0
        try:
            while True:
                if STOP.wait(0.1):
                    raise Cancelled()
                el = time.monotonic() - t0
                b = self.counted()
                samples.append((el, b))
                if b != last_bytes:
                    last_bytes, last_change = b, el
                err = next((w.error for w in self.workers if w.error), None)
                if err:
                    # Cloudflare corta con 429/403 cuando una IP pide mucho (medido el 2026-11-14 tras varias pruebas
                    # seguidas). Con al menos 1 s de ventana estable ya hay medida: la fase acaba ahí, marcada.
                    if err.code in ("refused", "ratelimited") and el >= min(2.0, self.secs * 0.25) + 1.0 and b > 0:
                        self.limited = True
                        break
                    raise err
                if el - last_change >= STALL_SECS:
                    raise Failure("stalled", "The transfer stalled")
                if el - last_emit >= 0.25 or self._over.is_set() or el >= self.secs:
                    last_emit = el
                    emit({"t": self.name, "mbps": round(window_mbps(samples, 1.0), 2), "bytes": b,
                          "elapsed": round(el, 2), "progress": round(min(1.0, el / self.secs), 3)})
                if el >= self.secs or self._over.is_set() or all(not w.is_alive() for w in self.workers):
                    break
        finally:
            self._over.set()
            self.target.cut_all()
            for w in self.workers:
                w.join(timeout=2)
        if samples[-1][1] == 0 and not STOP.is_set():
            raise Failure("stalled", "No data got through")      # 0 Mb/s no es un resultado
        wall = time.monotonic() - t0
        cpu = (time.process_time() - cpu0) / wall if wall > 0 else 0.0
        mbps = steady_mbps(samples, self.secs)
        out = {"mbps": round(mbps, 2), "bytes": samples[-1][1], "capped": self.capped,
               "limited": self.limited, "cpuBound": cpu >= 0.95}
        emit(dict({"t": self.name + "Done"}, **out))
        return out


def window_mbps(samples, span):
    """Mb/s en el último `span` s (lo que la UI enseña mientras corre)."""
    t_end, b_end = samples[-1]
    for t, b in reversed(samples):
        if t_end - t >= span:
            return (b_end - b) * 8 / (t_end - t) / 1e6
    t0, b0 = samples[0]
    return (b_end - b0) * 8 / (t_end - t0) / 1e6 if t_end > t0 else 0.0


def steady_mbps(samples, secs):
    """El resultado: la media de la ventana estable, sin el arranque (slow start, búferes)."""
    t_end, b_end = samples[-1]
    warm = min(2.0, secs * 0.25, t_end * 0.25)
    for t, b in samples:
        if t >= warm:
            if t_end - t >= 0.5:
                return (b_end - b) * 8 / (t_end - t) / 1e6
            break
    return b_end * 8 / t_end / 1e6 if t_end > 0 else 0.0


# ---- escenarios falsos (banco: sin red) ---------------------------------------------------------

FAKES = {
    "slow": (0.8, 0.3), "fast": (940.0, 310.0), "extreme": (9000.0, 4000.0), "flaky": (60.0, 12.0),
    "metered": (120.0, 20.0), "fail-dns": None, "ratelimited": None, "fail-upload": (300.0, 40.0), "stall": (200.0, 30.0),
}


def fake_path(name):
    if name == "fail-dns":
        raise Failure("dns", "Couldn't resolve the test server")
    if name == "ratelimited":
        return {"t": "path", "dev": "fake0", "kind": "ethernet", "metered": False, "family": 4}
    return {"t": "path", "dev": "fake0", "kind": "ethernet", "metered": name == "metered", "family": 4}


def fake_run(name, secs):
    emit(dict(fake_path(name), colo="TST"))
    if name == "ratelimited":
        emit({"t": "phase", "name": "latency"})
        raise Failure("ratelimited", "The test server is limiting tests from this connection (HTTP 429)", 300)
    down, up = FAKES[name]
    rng = random.Random(7)
    emit({"t": "phase", "name": "latency"})
    pings = []
    for i in range(1, PING_SAMPLES + 1):
        wait(0.08)
        ms = 14 + rng.uniform(-2, 2)
        pings.append(ms)
        emit({"t": "ping", "i": i, "ms": round(ms, 2)})
    jitter = statistics.fmean(abs(a - b) for a, b in zip(pings, pings[1:]))
    lat = {"ms": round(statistics.median(pings), 2), "jitter": round(jitter, 2)}
    emit(dict({"t": "latency"}, **lat))
    res = {}
    for key, target in (("down", down), ("up", up)):
        emit({"t": "phase", "name": "download" if key == "down" else "upload"})
        total, el = 0.0, 0.0
        while el < secs:
            wait(0.25)
            el += 0.25
            if name == "stall" and key == "down" and el > 1.0:
                STOP.wait()             # deja de hablar: lo descubre el watchdog de la shell
                raise Cancelled()
            if name == "fail-upload" and key == "up" and el >= secs / 2:
                raise Failure("connect", "The connection to the test server dropped")
            ramp = 1 - math.exp(-el / 0.8)
            wob = 1 + (0.4 * math.sin(el * 3.1) if name == "flaky" else rng.uniform(-0.04, 0.04))
            mbps = target * ramp * wob
            total += mbps * 1e6 / 8 * 0.25
            emit({"t": key, "mbps": round(mbps, 2), "bytes": int(total), "elapsed": el,
                  "progress": round(min(1.0, el / secs), 3)})
        res[key] = {"mbps": target, "bytes": int(total), "capped": False, "cpuBound": False}
        emit(dict({"t": key + "Done"}, **res[key]))
    return lat, res["down"], res["up"]


# ---- órdenes ------------------------------------------------------------------------------------

def cmd_path(a):
    if a.fake:
        emit(fake_path(a.fake))
        return 0
    emit(path_info(Target(a.base, a.family)))
    return 0


def cmd_run(a):
    emit({"t": "hello", "v": PROTO, "engine": "fake" if a.fake else "cloudflare"})
    if a.fake:
        lat, down, up = fake_run(a.fake, a.secs)
    else:
        target = Target(a.base, a.family)
        info = path_info(target)
        info["colo"] = colo_of(target)
        emit(info)
        lat = measure_latency(target)
        down = Phase("down", target, a.secs, a.streams, a.budget_down_mb * 1_000_000).run()
        check_stop()
        up = Phase("up", target, a.secs, a.streams, a.budget_up_mb * 1_000_000).run()
    check_stop()
    emit({"t": "end", "state": "done", "latency": lat["ms"], "jitter": lat["jitter"],
          "down": down["mbps"], "up": up["mbps"], "capped": down["capped"] or up["capped"],
          "limited": down.get("limited", False) or up.get("limited", False),
          "bytes": down["bytes"] + up["bytes"]})
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(prog="speedtest.py")
    p.add_argument("verb", choices=("path", "run"))
    p.add_argument("--base", default=os.environ.get("SUMI_SPEEDTEST_BASE", DEFAULT_BASE))
    p.add_argument("--family", choices=("auto", "4", "6"), default="auto")
    p.add_argument("--streams", type=int, default=4)
    p.add_argument("--secs", type=float, default=8.0)
    p.add_argument("--budget-down-mb", type=int, default=500)
    p.add_argument("--budget-up-mb", type=int, default=200)
    p.add_argument("--fake", choices=sorted(FAKES))
    p.add_argument("--deadline", type=float, default=0, help=argparse.SUPPRESS)
    try:
        a = p.parse_args(argv)
    except SystemExit:
        return 64
    if not (1 <= a.streams <= 8 and 1 <= a.secs <= 30 and a.budget_down_mb > 0 and a.budget_up_mb > 0):
        return 64

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    watch_parent()
    watch_stop()
    if a.verb == "run":
        watch_stdin()
    # Plazo absoluto: nada de esto debería pasar de aquí aunque todo se tuerza.
    limit = a.deadline or (CONNECT_TIMEOUT * 3 + a.secs * 2 + 30)
    timer = threading.Timer(limit, lambda: (DEADLINE.set(), STOP.set()))
    timer.daemon = True
    timer.start()
    try:
        return cmd_path(a) if a.verb == "path" else cmd_run(a)
    except Cancelled:
        if DEADLINE.is_set():
            emit({"t": "error", "code": "timeout", "detail": "The test took too long"})
            emit({"t": "end", "state": "failed", "code": "timeout"})
            return 3
        emit({"t": "end", "state": "cancelled"})
        return 2
    except Failure as f:
        err = {"t": "error", "code": f.code, "detail": f.detail}
        if f.retry_after is not None:
            err["retryAfter"] = f.retry_after
        emit(err)
        emit({"t": "end", "state": "failed", "code": f.code})
        return 3
    except Exception as e:      # noqa: BLE001 — nunca un traceback como protocolo
        emit({"t": "error", "code": "internal", "detail": type(e).__name__})
        emit({"t": "end", "state": "failed", "code": "internal"})
        return 3
    finally:
        timer.cancel()


if __name__ == "__main__":
    rc = main()
    try:
        sys.stdout.flush()
    except (OSError, ValueError):
        pass
    # Hilos daemon (stdin, dns) pueden seguir bloqueados en una lectura: un cierre normal del intérprete aborta
    # («could not acquire lock for stdin at interpreter shutdown»). Todo lo que importa ya está escrito.
    os._exit(rc)
