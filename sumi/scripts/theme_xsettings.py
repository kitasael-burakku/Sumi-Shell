"""Transporte opcional XSettings. Sin daemon Python, autoarranque ni configuración ajena.

Se invoca desde theme-preview bajo su cerrojo de transacción. xsettings-start/stop
son explícitos; sync nunca arranca ni reemplaza un gestor. Sólo se admite el proceso
registrado, con pidfd, UID, starttime, ejecutable, argv y propietario X11 coincidentes.
"""
import ctypes as C
import ctypes.util
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import struct
import subprocess
import time
import uuid


class Unavailable(Exception):
    pass


class XDisplay:
    def __init__(self):
        display = os.environ.get('DISPLAY', '')
        if not re.fullmatch(r'(?:unix/)?:\d+(?:\.\d+)?', display):
            raise Unavailable('no-local-display')
        lib = ctypes.util.find_library('X11')
        if not lib:
            raise Unavailable('no-libX11')
        try: self.x = C.CDLL(lib)
        except OSError: raise Unavailable("no-libX11")
        signatures = {
            'XOpenDisplay': ([C.c_char_p], C.c_void_p),
            'XCloseDisplay': ([C.c_void_p], C.c_int),
            'XDefaultScreen': ([C.c_void_p], C.c_int),
            'XInternAtom': ([C.c_void_p, C.c_char_p, C.c_int], C.c_ulong),
            'XGetSelectionOwner': ([C.c_void_p, C.c_ulong], C.c_ulong),
            'XGrabServer': ([C.c_void_p], C.c_int),
            'XUngrabServer': ([C.c_void_p], C.c_int),
            'XSync': ([C.c_void_p, C.c_int], C.c_int),
            'XFree': ([C.c_void_p], C.c_int),
            'XGetWindowProperty': ([C.c_void_p, C.c_ulong, C.c_ulong, C.c_long,
                C.c_long, C.c_int, C.c_ulong, C.POINTER(C.c_ulong), C.POINTER(C.c_int),
                C.POINTER(C.c_ulong), C.POINTER(C.c_ulong), C.POINTER(C.c_void_p)], C.c_int)}
        for name, (args, result) in signatures.items():
            f = getattr(self.x, name); f.argtypes = args; f.restype = result
        self.d = self.x.XOpenDisplay(display.encode())
        if not self.d:
            raise Unavailable('display-unavailable')
        self.screen = self.x.XDefaultScreen(self.d)
        self.atom = self.x.XInternAtom(self.d, f'_XSETTINGS_S{self.screen}'.encode(), 0)

    def close(self):
        self.x.XCloseDisplay(self.d)

    def prop(self, win, name):
        typ, fmt, n, left, data = C.c_ulong(), C.c_int(), C.c_ulong(), C.c_ulong(), C.c_void_p()
        atom = self.x.XInternAtom(self.d, name.encode(), 0)
        rc = self.x.XGetWindowProperty(self.d, win, atom, 0, 65536, 0, 0,
            C.byref(typ), C.byref(fmt), C.byref(n), C.byref(left), C.byref(data))
        try:
            if rc or left.value or not data.value:
                return b'', 0
            size = C.sizeof(C.c_ulong) if fmt.value == 32 else fmt.value // 8
            return C.string_at(data, n.value * size), fmt.value
        finally:
            if data.value: self.x.XFree(data)

    def read(self):
        # Evita consultar una ventana destruida entre owner y GetProperty.
        self.x.XGrabServer(self.d)
        try:
            owner = self.x.XGetSelectionOwner(self.d, self.atom)
            if not owner: return {'owner': 0, 'pid': None, 'theme': None}
            raw, fmt = self.prop(owner, '_NET_WM_PID')
            pid = C.c_ulong.from_buffer_copy(raw).value if fmt == 32 and raw else None
            raw, fmt = self.prop(owner, '_XSETTINGS_SETTINGS')
            return {'owner': owner, 'pid': pid, 'theme': parse_theme(raw) if fmt == 8 else None}
        finally:
            self.x.XUngrabServer(self.d); self.x.XSync(self.d, 0)


def parse_theme(raw):
    """Decodifica sólo Net/ThemeName; límites estrictos frente a datos ajenos."""
    if len(raw) < 12 or raw[0] not in (0, 1): return None
    order = '<' if raw[0] == 0 else '>'
    try:
        count = struct.unpack_from(order+'I', raw, 8)[0]; pos = 12
        if count > len(raw) // 8: return None
        for _ in range(count):
            kind, _, size = struct.unpack_from(order+'BBH', raw, pos); pos += 4
            name = raw[pos:pos+size]; pos = (pos+size+3) & ~3
            pos += 4  # last-change-serial
            if kind == 0: pos += 4
            elif kind == 1:
                size = struct.unpack_from(order+'I', raw, pos)[0]; pos += 4
                if pos+size > len(raw): return None
                value = raw[pos:pos+size]; pos = (pos+size+3) & ~3
                if name == b'Net/ThemeName': return value.decode('utf-8')
            elif kind == 2: pos += 8
            else: return None
            if pos > len(raw): return None
    except (ValueError, struct.error): pass
    return None


def process_identity(pid):
    p = Path('/proc') / str(pid)
    stat = (p/'stat').read_text().rsplit(')', 1)[1].split()
    return {'pid': pid, 'start': stat[19], 'exe': os.readlink(p/'exe'),
            'argv': (p/'cmdline').read_bytes().split(b'\0')[:-1], 'uid': p.stat().st_uid}


def content_theme(body):
    lines = [line for line in body.splitlines() if re.match(r'^\s*Net/ThemeName(?:\s|$)', line)]
    if len(lines) != 1: raise Unavailable('ambiguous-config')
    m = re.fullmatch(r'\s*Net/ThemeName\s+("(?:[^"\\]|\\.)*")\s*(?:#.*)?', lines[0])
    if not m: raise Unavailable('ambiguous-config')
    return json.loads(m[1])


class Adapter:
    def __init__(self, state_dir, write_json, write_atomic):
        self.write_json, self.write_atomic = write_json, write_atomic
        self.display = os.environ.get('DISPLAY', '')
        key = hashlib.sha256(self.display.encode()).hexdigest()[:20]
        self.root = Path(state_dir)/'xsettings'/key
        self.record = self.root/'record.json'
        self.config = os.environ.get('KT_XSETTINGS_CONFIG', '')
        self.scope = os.environ.get('KT_DESKTOP_SYNC', 'full')

    def load(self):
        try:
            r = json.loads(self.record.read_text())
            return r if r.get('display') == self.display else None
        except (OSError, ValueError): return None

    def result(self, status, **kw):
        return {'status': status, **kw}

    def owned_fd(self, r):
        if not r or not hasattr(os, 'pidfd_open') or not hasattr(signal, 'pidfd_send_signal'):
            raise Unavailable('no-owned-process')
        fd = os.pidfd_open(r['pid'])
        try:
            p = process_identity(r['pid'])
            argv = [a.decode() for a in p['argv']]
            if (p['uid'] != os.getuid() or p['start'] != r['start'] or p['exe'] != r['exe']
                or argv != r['argv']): raise Unavailable('process-identity-changed')
            return fd
        except BaseException:
            os.close(fd); raise

    def read_body(self, r):
        path = Path(r['config'])
        if path.is_symlink() or path.resolve() != path or path.stat().st_uid != os.getuid():
            raise Unavailable('config-not-owned')
        body = path.read_text()
        if not body.startswith('# Minimal-Shell XSettings '+r['token']+'\n'):
            raise Unavailable('config-not-owned')
        return body

    def snapshot(self):
        r = self.load()
        if not r: return None
        try:
            return {'token': r['token'], 'theme': content_theme(self.read_body(r))}
        except (OSError, ValueError, Unavailable): return None

    def check(self, x, r):
        now = x.read()
        if not r or now['pid'] != r.get('pid') or now['owner'] != r.get('owner'):
            raise Unavailable('foreign-manager' if now['owner'] else 'manager-unavailable')
        return now

    def status(self):
        if not self.config: return self.result('disabled')
        x = XDisplay()
        try:
            now = x.read(); r = self.load()
            if not now['owner']: return self.result('unavailable', reason='manager-unavailable')
            if not r or now['pid'] != r.get('pid') or now['owner'] != r.get('owner'):
                return self.result('skipped', reason='foreign-manager', published=now['theme'])
            fd = self.owned_fd(r); os.close(fd)
            return self.result('running', theme=now['theme'], pid=r['pid'], config=r['config'])
        finally: x.close()

    def start(self, theme):
        if not self.config or self.scope != 'full': return self.result('disabled')
        binary = shutil.which(os.environ.get('KT_XSETTINGSD', 'xsettingsd'))
        guard = Path(os.environ.get('KT_XSETTINGS_GUARD', str(Path(__file__).with_name('xsettings-no-replace.so'))))
        if not binary or not guard.is_file(): return self.result('unavailable', reason='missing-daemon-or-guard')
        if not hasattr(os, 'pidfd_open') or not hasattr(signal, 'pidfd_send_signal'):
            return self.result('unavailable', reason='no-pidfd')
        try: os.close(os.pidfd_open(os.getpid()))
        except OSError: return self.result('unavailable', reason='no-pidfd')
        if not isinstance(theme, str) or not theme or any(ord(c) < 32 for c in theme):
            return self.result('unavailable', reason='gtk-theme-unavailable')
        # No permitir que ld.so ignore la protección por un binario privilegiado/estático.
        st = os.stat(binary)
        if st.st_mode & 0o6000: return self.result('unavailable', reason='unsafe-daemon')
        try:
            os.getxattr(binary, 'security.capability')
            return self.result('unavailable', reason='unsafe-daemon')
        except OSError: pass
        elf = Path(binary).read_bytes()
        if elf[:4] != b'\x7fELF' or elf[4:6] != b'\x02\x01':
            return self.result('unavailable', reason='unsupported-daemon-format')
        phoff = struct.unpack_from('<Q', elf, 32)[0]
        phsize, phnum = struct.unpack_from('<HH', elf, 54)
        if not any(struct.unpack_from('<I', elf, phoff+i*phsize)[0] == 3 for i in range(phnum)):
            return self.result('unavailable', reason='static-daemon')
        try:
            if C.CDLL(str(guard.resolve())).minimal_shell_xsettings_guard_version() != 1:
                raise ValueError('guard-version')
        except (OSError, AttributeError, ValueError):
            return self.result('unavailable', reason='invalid-guard')
        x = XDisplay()
        try:
            now = x.read(); r = self.load()
            if now['owner']:
                try:
                    self.check(x, r); fd = self.owned_fd(r); os.close(fd)
                    if r['config'] != self.config: return self.result('skipped', reason='config-changed-stop-first')
                    return self.sync(theme)
                except (Unavailable, OSError): return self.result('skipped', reason='foreign-manager', published=now['theme'])
            if r:
                try:
                    fd = self.owned_fd(r); os.close(fd)
                    return self.result('skipped', reason='owned-process-still-running')
                except (OSError, Unavailable): pass
                if r['config'] != self.config: return self.result('skipped', reason='config-changed-stop-first')
                body = self.read_body(r)
                if content_theme(body) != r['theme']: return self.result('skipped', reason='config-changed-by-user')
            else:
                path = Path(self.config)
                if not path.is_absolute() or path.resolve() != path or path.exists():
                    return self.result('skipped', reason='config-not-new-owned-path')
                token = uuid.uuid4().hex
                body = '# Minimal-Shell XSettings '+token+'\nNet/ThemeName '+json.dumps(theme, ensure_ascii=False)+'\n'
                r = {'token': token, 'display': self.display, 'config': self.config,
                     'originalTheme': theme, 'theme': theme}
                # Exclusión: no sobrescribir un archivo creado mientras se comprobaba.
                path.parent.mkdir(parents=True, exist_ok=True)
                with open(path, 'x') as f: os.chmod(path, 0o600); f.write(body)
            self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
            # Un LD_PRELOAD heredado no se propaga al gestor administrado.
            env = {**os.environ, 'LD_PRELOAD': str(guard.resolve())}
            argv = [os.path.realpath(binary), '-c', self.config, '-s', str(x.screen)]
            r.update(pid=0, start='', exe=argv[0], argv=argv, owner=0)
            self.write_json(str(self.record), r)
            with open(self.root/'manager.log', 'ab') as log:
                p = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=log,
                                     stderr=log, start_new_session=True)
            identity = process_identity(p.pid)
            r.update(pid=p.pid, start=identity['start'], exe=argv[0], argv=argv, owner=0)
            self.write_json(str(self.record), r)
            deadline = time.monotonic()+2
            while time.monotonic() < deadline:
                now = x.read()
                if now['pid'] == p.pid:
                    r['owner'] = now['owner']; self.write_json(str(self.record), r)
                    return self.sync(theme)
                if p.poll() is not None: return self.result('failed', reason='start-failed', exitCode=p.returncode)
                time.sleep(.04)
            # Sólo el hijo recién creado; jamás el owner encontrado en el display.
            p.terminate(); p.wait(timeout=2)
            return self.result('failed', reason='start-timeout')
        finally: x.close()

    def sync(self, theme, target=None):
        r = self.load()
        if target is None and (not self.config or self.scope != 'full'): return self.result('disabled')
        if not r: return self.status()
        if target is None and r['config'] != self.config: return self.result('skipped', reason='config-changed-stop-first')
        if target is not None:
            if 'expected' in target and r['theme'] != target['expected']:
                return self.result('skipped', reason='theme-changed-after-preview')
            if target.get('token') != r['token']: return self.result('skipped', reason='resource-changed')
            theme = target['theme']
        if not isinstance(theme, str) or not theme or any(ord(c) < 32 for c in theme):
            return self.result('unavailable', reason='gtk-theme-unavailable')
        body = self.read_body(r); current = content_theme(body)
        if current not in (r['theme'], r.get('previousTheme')): return self.result('skipped', reason='config-changed-by-user')
        x = XDisplay()
        try:
            now = self.check(x, r)
            fd = self.owned_fd(r)
            try:
                if now['theme'] == theme and current == theme: return self.result('unchanged', theme=theme)
                # Registrar intención antes de escribir: una recuperación puede reintentar.
                if current != theme:
                    new = re.sub(r'(?m)^(\s*Net/ThemeName\s+)"(?:[^"\\]|\\.)*"',
                                 lambda m: m[1]+json.dumps(theme, ensure_ascii=False), body)
                    if self.read_body(r) != body: return self.result('skipped', reason='config-changed-by-user')
                    r['previousTheme'] = current
                    r['theme'] = theme; self.write_json(str(self.record), r)
                    self.write_atomic(r['config'], new.encode(), 0o600)
                self.check(x, r)
                signal.pidfd_send_signal(fd, signal.SIGHUP)
                deadline = time.monotonic()+2
                while time.monotonic() < deadline:
                    now = self.check(x, r)
                    if now['theme'] == theme:
                        r.pop('previousTheme', None); self.write_json(str(self.record), r)
                        return self.result('applied', theme=theme)
                    time.sleep(.04)
                return self.result('failed', reason='publication-timeout')
            finally: os.close(fd)
        finally: x.close()

    def restore(self, target=None):
        r = self.load()
        if not r: return self.result('unchanged')
        return self.sync(None, target or {'token': r['token'], 'theme': r['originalTheme']})

    def stop(self):
        r = self.load()
        if not r: return self.result('unchanged')
        try:
            if not r.get('pid'): raise ProcessLookupError()
            fd = self.owned_fd(r)
            try: signal.pidfd_send_signal(fd, signal.SIGTERM)
            finally: os.close(fd)
        except (ProcessLookupError, FileNotFoundError): pass
        # Si el PID ha cambiado, no borrar el registro ni asumir que hemos parado el proceso.
        deadline = time.monotonic()+2
        while time.monotonic() < deadline:
            try:
                p = process_identity(r['pid'])
                if p['start'] != r['start']: break
                if Path('/proc', str(r['pid']), 'stat').read_text().rsplit(')',1)[1].split()[0] == 'Z': break
            except OSError: break
            time.sleep(.04)
        else: return self.result('failed', reason='stop-timeout')
        try: body = self.read_body(r)
        except (OSError, Unavailable): body = None
        expected = '# Minimal-Shell XSettings '+r['token']+'\nNet/ThemeName '+json.dumps(r['theme'], ensure_ascii=False)+'\n'
        kept = body != expected
        if not kept: Path(r['config']).unlink()
        self.record.unlink()
        return self.result('stopped', configPreserved=kept)

    def ledger(self):
        r = self.load()
        if not r or r['theme'] == r['originalTheme']: return None
        return {'before': r['originalTheme'], 'set': r['theme'], 'config': r['config']}

    def call(self, action, theme=None, target=None):
        try:
            if action == 'ledger': return self.ledger()
            if action == 'status': return self.status()
            if action == 'snapshot': return self.snapshot()
            if action == 'start': return self.start(theme)
            if action == 'stop': return self.stop()
            if action == 'restore': return self.restore(target)
            return self.sync(theme)
        except Unavailable as e: return self.result('unavailable', reason=str(e))
        except (OSError, ValueError, KeyError, struct.error, subprocess.SubprocessError) as e:
            return self.result('failed', reason=str(e))
