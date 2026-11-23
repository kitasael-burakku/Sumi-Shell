#!/usr/bin/env python3
"""Banco de `scripts/speedtest.py` contra un servidor LOCAL (fixture_server.py): ni un byte a Internet.

    helper-test.py [ruta/al/speedtest.py] [-k filtro]

Cubre el protocolo v1, la precisión frente a un enlace simulado, el tope de datos, los códigos de error, la
cancelación (stdin «cancel», EOF, SIGTERM) en cada fase con salida en < 1,2 s, el plazo absoluto, IPv6 y los
escenarios `--fake` que usa el banco QML.
"""
import sys

sys.dont_write_bytecode = True

import json  # noqa: E402
import os  # noqa: E402
import signal  # noqa: E402
import socket  # noqa: E402
import subprocess  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fixture_server import Fixture  # noqa: E402

HELPER = os.path.normpath(os.path.join(HERE, "..", "..", "sumi", "scripts", "speedtest.py"))
EXIT_LIMIT = 1.2

results = []


def check(name, ok, detail=""):
    results.append((name, ok))
    print("%s  %s%s" % ("PASS" if ok else "FAIL", name, ("  · " + detail) if detail else ""), flush=True)


class Run:
    """El helper en marcha, con sus líneas y la hora a la que llegó cada una."""

    def __init__(self, *args, env=None):
        e = dict(os.environ)
        e.pop("SUMI_SPEEDTEST_BASE", None)
        e.update(env or {})
        self.p = subprocess.Popen([sys.executable, "-I", HELPER] + list(args), stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e)
        self.lines, self.raw, self.t0 = [], [], time.monotonic()
        self.bad = []
        self.cv = threading.Condition()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for raw in self.p.stdout:
            s = raw.decode("utf-8", "replace").rstrip("\n")
            with self.cv:
                self.raw.append(s)
                try:
                    o = json.loads(s)
                    o["_at"] = time.monotonic() - self.t0
                    self.lines.append(o)
                except ValueError:
                    self.bad.append(s)
                self.cv.notify_all()

    def wait_for(self, pred, timeout=20):
        end = time.monotonic() + timeout
        with self.cv:
            while True:
                for o in self.lines:
                    if pred(o):
                        return o
                left = end - time.monotonic()
                if left <= 0:
                    return None
                self.cv.wait(left)

    def finish(self, timeout=60):
        try:
            code = self.p.wait(timeout)
        except subprocess.TimeoutExpired:
            self.p.kill()
            code = None
        time.sleep(0.05)
        self.err = self.p.stderr.read().decode("utf-8", "replace")
        return code

    def types(self):
        return [o["t"] for o in self.lines]

    def first(self, t):
        return next((o for o in self.lines if o["t"] == t), None)

    def last(self):
        return self.lines[-1] if self.lines else {}


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def collapse(ts):
    out = []
    for t in ts:
        if not out or out[-1] != t:
            out.append(t)
    return out


# ---- casos --------------------------------------------------------------------------------------

def t_protocol():
    with Fixture() as fx:
        fx.set_rate(400)
        r = Run("run", "--base", fx.base, "--secs", "2", "--streams", "2")
        code = r.finish()
    seq = collapse(r.types())
    want = ["hello", "path", "phase", "ping", "latency", "phase", "down", "downDone", "phase", "up", "upDone", "end"]
    check("protocol: every line is JSON", not r.bad and r.raw, "%d lines" % len(r.raw))
    check("protocol: hello v1 first", r.lines and r.lines[0] == dict(r.lines[0], t="hello", v=1))
    check("protocol: event order", seq == want, " ".join(seq))
    check("protocol: ten pings", r.types().count("ping") == 10)
    p = r.first("path") or {}
    check("protocol: path is loopback IPv4 with colo", p.get("kind") == "loopback" and p.get("family") == 4
          and p.get("colo") == "TST", json.dumps(p))
    check("privacy: public IP from trace never emitted", all("203.0.113.77" not in s for s in r.raw))
    end = r.last()
    check("protocol: end done with numbers", end.get("state") == "done" and end.get("down", 0) > 0
          and end.get("up", 0) > 0 and end.get("latency", -1) >= 0, json.dumps(end))
    check("exit 0 on success", code == 0, "code %s · stderr %r" % (code, r.err[-200:]))
    phases = [o["name"] for o in r.lines if o["t"] == "phase"]
    check("protocol: phase names", phases == ["latency", "download", "upload"], str(phases))
    downs = [o for o in r.lines if o["t"] == "down"]
    gaps = [b["_at"] - a["_at"] for a, b in zip(downs, downs[1:])]
    check("partials: about every 250 ms", downs and max(gaps or [0]) < 0.6 and len(downs) >= 6,
          "%d partials, max gap %.2f s" % (len(downs), max(gaps or [0])))


def t_rate(mbps, tol):
    with Fixture() as fx:
        fx.set_rate(mbps)
        r = Run("run", "--base", fx.base, "--secs", "6", "--streams", "4")
        code = r.finish()
    d, u = r.first("downDone") or {}, r.first("upDone") or {}
    for key, o in (("download", d), ("upload", u)):
        got = o.get("mbps", 0)
        check("accuracy: %s at %g Mb/s within %d%%" % (key, mbps, tol * 100),
              abs(got - mbps) <= mbps * tol, "measured %.2f" % got)
    check("accuracy run exit 0 (%g Mb/s)" % mbps, code == 0, "code %s" % code)


def t_budget():
    with Fixture() as fx:
        r = Run("run", "--base", fx.base, "--secs", "6", "--streams", "4",
                "--budget-down-mb", "40", "--budget-up-mb", "20")
        code = r.finish()
    d, u = r.first("downDone") or {}, r.first("upDone") or {}
    slack = 4 * 256 * 1024 + 2 * 1024 * 1024
    check("budget: download capped", d.get("capped") is True and d.get("bytes", 1e12) <= 40e6 + slack,
          json.dumps(d))
    check("budget: upload capped", u.get("capped") is True and u.get("bytes", 1e12) <= 20e6 + slack, json.dumps(u))
    check("budget: end says capped", r.last().get("capped") is True and code == 0)


def t_failure(name, setup, code_want, secs="3"):
    with Fixture() as fx:
        setup(fx)
        r = Run("run", "--base", fx.base, "--secs", secs)
        code = r.finish(40)
    err = r.first("error") or {}
    end = r.last()
    check("error %s → code %s" % (name, code_want),
          err.get("code") == code_want and end.get("state") == "failed" and end.get("code") == code_want
          and code == 3, "got %s / %s · exit %s" % (err.get("code"), end.get("state"), code))
    check("error %s: detail is a plain string" % name, isinstance(err.get("detail"), str))


def t_connect_refused():
    port = free_port()
    r = Run("run", "--base", "http://127.0.0.1:%d" % port, "--secs", "2")
    code = r.finish(20)
    check("error closed port → code connect", (r.first("error") or {}).get("code") == "connect" and code == 3,
          json.dumps(r.first("error")))


def t_cancel(phase, how):
    with Fixture() as fx:
        fx.set_rate(50)
        if phase == "latency":
            fx.delay_ms = 400
        r = Run("run", "--base", fx.base, "--secs", "8")
        hit = r.wait_for(lambda o: o["t"] == "phase" and o["name"] == phase, 20)
        if phase != "latency":
            r.wait_for(lambda o: o["t"] in ("down", "up") and o.get("elapsed", 0) >= 1.0
                       and o["t"] == ("down" if phase == "download" else "up"), 20)
        t0 = time.monotonic()
        if how == "cancel":
            r.p.stdin.write(b"cancel\n")
            r.p.stdin.flush()
        elif how == "eof":
            r.p.stdin.close()
        else:
            r.p.send_signal(signal.SIGTERM)
        code = r.finish(10)
        dt = time.monotonic() - t0
    end = r.last()
    check("cancel by %s during %s: exits in < %.1f s" % (how, phase, EXIT_LIMIT),
          hit is not None and dt < EXIT_LIMIT, "%.2f s" % dt)
    check("cancel by %s during %s: end cancelled, exit 2" % (how, phase),
          end.get("t") == "end" and end.get("state") == "cancelled" and code == 2,
          "%s · exit %s" % (json.dumps(end), code))
    check("cancel by %s during %s: one end line" % (how, phase), r.types().count("end") == 1)


def t_deadline():
    with Fixture() as fx:
        fx.set_rate(5)
        r = Run("run", "--base", fx.base, "--secs", "8", "--deadline", "2")
        code = r.finish(10)
    end = r.last()
    check("deadline → failed timeout", end.get("state") == "failed" and end.get("code") == "timeout" and code == 3,
          "%s · exit %s" % (json.dumps(end), code))


def t_ipv6():
    try:
        fx = Fixture(socket.AF_INET6, "::1")
    except OSError as e:
        check("ipv6 loopback available", False, str(e))
        return
    with fx:
        r = Run("run", "--base", fx.base, "--secs", "2", "--streams", "2", "--family", "6")
        code = r.finish()
    p = r.first("path") or {}
    check("ipv6: family 6 and done", p.get("family") == 6 and r.last().get("state") == "done" and code == 0,
          json.dumps(p))


def t_path():
    with Fixture() as fx:
        r = Run("path", "--base", fx.base)
        code = r.finish()
        reqs = list(fx.requests)
    check("path: one line, no HTTP", len(r.lines) == 1 and r.lines[0]["t"] == "path" and not reqs and code == 0,
          "%s · %d requests" % (r.raw, len(reqs)))


def t_fakes():
    for name in ("slow", "fast", "extreme", "flaky", "metered"):
        r = Run("run", "--fake", name, "--secs", "1")
        code = r.finish(20)
        check("fake %s: done" % name, r.last().get("state") == "done" and code == 0 and not r.bad)
    r = Run("path", "--fake", "metered")
    r.finish(10)
    check("fake path metered", (r.first("path") or {}).get("metered") is True)
    r = Run("run", "--fake", "fail-dns")
    code = r.finish(10)
    check("fake fail-dns → dns", (r.first("error") or {}).get("code") == "dns" and code == 3)
    r = Run("run", "--fake", "ratelimited")
    code = r.finish(10)
    check("fake ratelimited → ratelimited with retryAfter", (r.first("error") or {}).get("code") == "ratelimited"
          and (r.first("error") or {}).get("retryAfter") == 300 and code == 3)
    r = Run("run", "--fake", "fail-upload", "--secs", "1")
    code = r.finish(20)
    check("fake fail-upload → connect during upload", (r.first("error") or {}).get("code") == "connect"
          and "up" in r.types() and code == 3)
    r = Run("run", "--fake", "stall", "--secs", "4")
    r.wait_for(lambda o: o["t"] == "down" and o["elapsed"] >= 1.0, 20)
    time.sleep(1.5)
    n = len(r.lines)
    time.sleep(1.0)
    silent = len(r.lines) == n
    r.p.stdin.close()
    code = r.finish(10)
    check("fake stall: goes silent, EOF still ends it", silent and code == 2)


def t_consecutive():
    with Fixture() as fx:
        codes = []
        for _ in range(3):
            r = Run("run", "--base", fx.base, "--secs", "1", "--streams", "2")
            codes.append(r.finish())
    check("consecutive runs", codes == [0, 0, 0], str(codes))


def t_cloudflare_quirks():
    """Lo medido contra speed.cloudflare.com el 2026-11-14: 403 desde 100 MB y dos cabeceras Server-Timing."""
    with Fixture() as fx:
        fx.worker_ms = 40
        r = Run("run", "--base", fx.base, "--secs", "4", "--streams", "4")
        code = r.finish()
        sizes = [int(p.split("bytes=")[1]) for m, p in fx.requests if "bytes=" in p]
    lat = (r.first("latency") or {}).get("ms", 999)
    check("cloudflare: no request above 50 MB, test done", max(sizes) <= 50_000_000 and code == 0
          and r.last().get("state") == "done", "max %d · exit %s" % (max(sizes), code))
    check("cloudflare: server time (sum of every dur) is not counted as latency", lat < 15,
          "latency %.1f ms with 41 ms of declared server time" % lat)


def t_slow_pings():
    """Un ping de cada tres tarda 4 s (más que su plazo de 3 s): se descartan, la prueba sigue y lo cuenta."""
    with Fixture() as fx:
        fx.slow_ping_every = 3
        r = Run("run", "--base", fx.base, "--secs", "2", "--streams", "2")
        code = r.finish(90)
    lat = r.first("latency") or {}
    check("slow pings: dropped, test still done", code == 0 and r.last().get("state") == "done"
          and lat.get("lost", 0) >= 1 and r.types().count("ping") >= 3, json.dumps(lat))


def t_limited():
    """429 a mitad de la bajada con datos ya medidos: la fase vale (marcada) y la prueba sigue hasta el final."""
    with Fixture() as fx:
        fx.set_rate(100)
        fx.refuse_after = 8
        r = Run("run", "--base", fx.base, "--secs", "6", "--streams", "4")
        code = r.finish(60)
    d = r.first("downDone") or {}
    check("limited: 429 after enough data keeps the phase (marked) and the test ends done",
          code == 0 and d.get("limited") is True and abs(d.get("mbps", 0) - 100) < 15
          and r.last().get("state") == "done" and r.last().get("limited") is True, json.dumps(d))


def t_retry_after():
    """429 con Retry-After: el error lo lleva en segundos (la vista dice cuánto esperar)."""
    with Fixture() as fx:
        fx.status = 429
        r = Run("run", "--base", fx.base, "--secs", "2")
        r.finish(30)
    err = r.first("error") or {}
    check("429 carries retryAfter seconds", err.get("code") == "ratelimited" and err.get("retryAfter") == 120,
          json.dumps(err))


def t_user_agent():
    """Cada petición se identifica: sumi-shell-speedtest/<versión de version.json, o 0>."""
    with Fixture() as fx:
        r = Run("run", "--base", fx.base, "--secs", "1", "--streams", "2")
        code = r.finish()
        agents = set(fx.agents)
    check("every request sends the sumi-shell-speedtest User-Agent", code == 0 and agents
          and all(a.startswith("sumi-shell-speedtest/") for a in agents), str(agents))


def t_usage():
    r = Run("run", "--streams", "99")
    check("usage error → 64", r.finish(10) == 64)


CASES = [
    ("protocol", t_protocol),
    ("path", t_path),
    ("rate20", lambda: t_rate(20, 0.10)),
    ("rate200", lambda: t_rate(200, 0.10)),
    ("budget", t_budget),
    ("refused", lambda: t_failure("HTTP 403", lambda fx: setattr(fx, "status", 403), "refused")),
    ("ratelimited", lambda: t_failure("HTTP 429", lambda fx: setattr(fx, "status", 429), "ratelimited")),
    ("retryafter", t_retry_after),
    ("useragent", t_user_agent),
    ("http", lambda: t_failure("HTTP 500", lambda fx: setattr(fx, "status", 500), "http")),
    ("connect", t_connect_refused),
    ("timeout", lambda: t_failure("silent server", lambda fx: setattr(fx, "silent", True), "timeout")),
    ("stalled", lambda: t_failure("stall mid-download", lambda fx: setattr(fx, "stall_after", 2_000_000),
                                  "stalled", secs="8")),
    ("nodata", lambda: t_failure("no byte in a whole phase", lambda fx: setattr(fx, "stall_after", 0),
                                 "stalled", secs="2")),
    ("cancel", lambda: [t_cancel(ph, how) for ph in ("latency", "download", "upload")
                        for how in ("cancel", "eof", "sigterm")]),
    ("deadline", t_deadline),
    ("ipv6", t_ipv6),
    ("fakes", t_fakes),
    ("consecutive", t_consecutive),
    ("usage", t_usage),
    ("cloudflare", t_cloudflare_quirks),
    ("slowpings", t_slow_pings),
    ("limited", t_limited),
]


def main():
    global HELPER
    args = sys.argv[1:]
    only = None
    if "-k" in args:
        i = args.index("-k")
        only = args[i + 1]
        del args[i:i + 2]
    if args:
        HELPER = os.path.abspath(args[0])
    print("helper:", HELPER)
    for name, fn in CASES:
        if only and only not in name:
            continue
        fn()
    bad = [n for n, ok in results if not ok]
    print("\n%d/%d passed" % (len(results) - len(bad), len(results)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
