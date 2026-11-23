#!/usr/bin/env python3
"""15G-1: LockAuth con un adaptador PAM falso (LK-03) y faillock.conf / faillock falsos (LK-04). Offscreen, sobre
una copia del árbol con Session falso. Nunca usa la pila PAM real ni bloquea. Sale con el número de fallos."""
import json, os, re, shutil, subprocess, sys, tempfile, time
from pathlib import Path
HERE = Path(__file__).resolve().parent
# F5e: SUMI_LOCK_SRC prueba otro árbol (la copia de desarrollo) sin desplegar
SRC = Path(os.environ['SUMI_LOCK_SRC']) if os.environ.get('SUMI_LOCK_SRC') else HERE.parents[1] / 'sumi'
FAKE_SESSION = (HERE / 'hold-probe.py').read_text().split("FAKE_SESSION = '''")[1].split("'''")[0]

def run(conf, fl_lines):
    with tempfile.TemporaryDirectory(prefix='kt-auth-', dir='/tmp') as d:
        d = Path(d); root = d / 'k'; shutil.copytree(SRC, root, symlinks=True)
        (root / 'services/Session.qml').write_text(FAKE_SESSION)
        (root / 'probe-auth.qml').write_text((HERE / 'probe-auth.qml').read_text())
        (d / 'faillock.conf').write_text(conf)
        now = time.time()
        out = 'kitasa:\nWhen                Type  Source                                           Valid\n'
        for ago in fl_lines:
            out += time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(now - ago)) + ' RHOST  login   V\n'
        (d / 'faillock.out').write_text(out)
        rt = d / 'rt'; rt.mkdir(mode=0o700)
        env = dict(os.environ, QT_QPA_PLATFORM='offscreen', XDG_RUNTIME_DIR=str(rt), XDG_STATE_HOME=str(d / 'st'), KT_DIR=str(d))
        txt = subprocess.run(['qs', '-p', str(root / 'probe-auth.qml'), '--no-color'], env=env, capture_output=True, text=True, timeout=40).stdout
        ev = [json.loads(m) for m in re.findall(r'PROBE (\{.*\})', txt)]
        if not ev: print(txt[-1500:])
        return {e.get('step', 'success' if e.get('ev') == 'success' else 'end'): e for e in ev}

bad = 0
def check(name, ok, detail=''):
    global bad
    print(('OK   ' if ok else 'FALLA'), name, '' if ok else '— ' + str(detail)); bad += not ok

# 1) faillock.conf entero comentado (como esta máquina): 3 / 900 / 600; dos fallos recientes → no bloquea
r = run('# deny = 3\n# fail_interval = 900\n# unlock_time = 600\n', [30, 60])
a = r.get('A-prompt', {}); e = r.get('A-end', {}); b = r.get('B-end', {})
check('LK-03: la segunda respuesta la pide PAM (estado prompt con su texto)', a.get('state') == 'prompt' and a.get('prompt') == 'Verification code', a)
check('LK-03: se contesta en la MISMA conversación (1 start, 2 respuestas) y desbloquea', e.get('starts') == 1 and e.get('answers') == [7, 6] and 'success' in r, e)
check('I-8: el buffer ya estaba vacío al responder, las dos veces', e.get('bufferAtRespond') == [0, 0], e)
check('código mal: fallo, sin segunda conversación', b.get('state') == 'failed' and b.get('starts') == 1, b)
check('conf comentada: 3 / 900 / 600', b.get('policy') == {'deny': 3, 'failInterval': 900, 'unlockTime': 600, 'dir': ''}, b.get('policy'))
check('2 fallos recientes con deny 3: no se bloquea', b.get('failed') == 2 and b.get('state') == 'failed', b)
# 2) conf con valores propios: deny 5, fail_interval 60, unlock_time 0 (sin plazo), dir propio; 5 fallos en 60 s
r = run('deny = 5\n# fail_interval = 900\nfail_interval = 60\nunlock_time = 0\ndir = /tmp/kt-tally\n', [5, 10, 15, 20, 25, 400])
b = r.get('B-end', {})
check('LK-04: la política se lee de faillock.conf', b.get('policy') == {'deny': 5, 'failInterval': 60, 'unlockTime': 0, 'dir': '/tmp/kt-tally'}, b.get('policy'))
check('5 fallos dentro de 60 s (el de hace 400 s no cuenta) → lockedOut', b.get('state') == 'lockedOut' and b.get('failed') == 5, b)
sys.exit(bad)
