#!/usr/bin/env python3
"""Servidor local que imita el borde de Cloudflare para probar `scripts/speedtest.py` sin tocar Internet.

    GET  /__down?bytes=N    N bytes (ceros) con `server-timing: cfRequestDuration;dur=1.0`
    POST /__up              se traga el cuerpo
    GET  /cdn-cgi/trace     `colo=TST` y una IP falsa (el helper no debe repetirla)

Comportamientos inyectables (atributos de `Fixture`): `rate_mbps` (cubo de fichas COMPARTIDO por todas las
conexiones: imita un enlace), `status` (p. ej. 429), `stall_after` (bytes y luego silencio con la conexión abierta),
`silent` (acepta y no contesta nunca), `delay_ms` (antes de las cabeceras).

El búfer de recepción del servidor es pequeño (64 KB): sin eso el kernel del loopback confirma megas que la «red»
aún no ha llevado, y la subida se mediría contra el kernel y no contra el ritmo del enlace simulado.
"""
import sys

sys.dont_write_bytecode = True

import http.server  # noqa: E402
import socket  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402
import urllib.parse  # noqa: E402

ZEROS = bytes(64 * 1024)


class Bucket:
    """Ritmo de un enlace: cada `consume(n)` espera lo que toque a `rate` bytes/s, entre todas las conexiones."""

    def __init__(self, mbps):
        self.rate = mbps * 1e6 / 8
        self.t = time.monotonic()
        self.lock = threading.Lock()

    def consume(self, n):
        with self.lock:
            now = time.monotonic()
            start = max(now, self.t)
            self.t = start + n / self.rate
            delay = self.t - now - 0.02       # 20 ms de ráfaga permitida
        if delay > 0:
            time.sleep(delay)


class Fixture:
    def __init__(self, family=socket.AF_INET, host="127.0.0.1"):
        self.rate_mbps = None
        self.status = 200
        self.stall_after = None
        self.silent = False
        self.delay_ms = 0
        self.worker_ms = 0          # tiempo de servidor declarado en Server-Timing (y dormido de verdad)
        self.max_bytes = 99_999_999  # como speed.cloudflare.com: 403 desde 100 MB
        self.refuse_after = 0       # tras N bajadas con cuerpo, 429 (el límite por IP de Cloudflare)
        self._downs = 0
        self.slow_ping_every = 0    # cada N pings (bytes=0) el «trabajador» tarda 4 s, como Cloudflare a veces
        self._pings = 0
        self.requests = []
        self.agents = set()         # User-Agent de cada petición (el helper debe identificarse)
        self.bucket = None
        fx = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            def _prelude(self):
                fx.requests.append((self.command, self.path))
                fx.agents.add(self.headers.get("User-Agent", ""))
                if fx.silent:
                    time.sleep(3600)
                if fx.delay_ms:
                    time.sleep(fx.delay_ms / 1000)
                if fx.status != 200:
                    body = b"no"
                    self.send_response(fx.status)
                    if fx.status == 429:
                        self.send_header("Retry-After", "120")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return False
                return True

            def do_GET(self):
                if not self._prelude():
                    return
                u = urllib.parse.urlsplit(self.path)
                if u.path == "/cdn-cgi/trace":
                    body = b"fl=1\nh=localhost\nip=203.0.113.77\ncolo=TST\nloc=ZZ\n"
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                if u.path != "/__down":
                    self.send_error(404)
                    return
                n = int(urllib.parse.parse_qs(u.query).get("bytes", ["0"])[0])
                if n > 0 and fx.refuse_after:
                    fx._downs += 1
                    if fx._downs > fx.refuse_after:
                        n = fx.max_bytes + 1        # misma respuesta corta que el 403, pero 429
                        body = b"slow down"
                        self.send_response(429)
                        self.send_header("Retry-After", "120")
                        self.send_header("Content-Length", str(len(body)))
                        self.end_headers()
                        self.wfile.write(body)
                        return
                if n > fx.max_bytes:
                    body = b"forbidden"
                    self.send_response(403)
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                if fx.worker_ms:
                    time.sleep(fx.worker_ms / 1000)
                if n == 0 and fx.slow_ping_every:
                    fx._pings += 1
                    if fx._pings % fx.slow_ping_every == 0:
                        time.sleep(4)
                self.send_response(200)
                self.send_header("Content-Length", str(n))
                # como Cloudflare: dos cabeceras, la segunda sin `dur`
                self.send_header("Server-Timing", "cfSpeedEdge;dur=1, cfSpeedWorker;dur=%d" % fx.worker_ms)
                self.send_header("server-timing", 'cfL4;desc="?proto=TCP&rtt=100"')
                self.end_headers()
                sent = 0
                try:
                    while sent < n:
                        k = min(16 * 1024, n - sent)
                        if fx.stall_after is not None and sent >= fx.stall_after:
                            time.sleep(3600)
                        if fx.bucket:
                            fx.bucket.consume(k)
                        self.wfile.write(ZEROS[:k])
                        sent += k
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def do_POST(self):
                if not self._prelude():
                    return
                n = int(self.headers.get("Content-Length", "0"))
                got = 0
                try:
                    while got < n:
                        k = min(16 * 1024, n - got)
                        if fx.bucket:
                            fx.bucket.consume(k)
                        d = self.rfile.read(k)
                        if not d:
                            return
                        got += len(d)
                except (BrokenPipeError, ConnectionResetError):
                    return
                body = b"ok"
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        class Server(http.server.ThreadingHTTPServer):
            address_family = family
            daemon_threads = True
            allow_reuse_address = True

            def server_bind(self):
                # heredado por los sockets aceptados ANTES de negociar la ventana
                self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 64 * 1024)
                super().server_bind()

        self.httpd = Server((host, 0), Handler)
        self.port = self.httpd.server_address[1]
        self.host = host
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def set_rate(self, mbps):
        self.rate_mbps = mbps
        self.bucket = Bucket(mbps) if mbps else None

    @property
    def base(self):
        h = "[%s]" % self.host if ":" in self.host else self.host
        return "http://%s:%d" % (h, self.port)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.httpd.shutdown()
        self.httpd.server_close()
