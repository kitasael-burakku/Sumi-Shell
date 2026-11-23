#!/usr/bin/env python3
"""15H: el aviso de PathField en Quickshell offscreen (copia del árbol, Session falso). Sale con los fallos."""
import json, os, re, shutil, subprocess, sys, tempfile
from pathlib import Path
HERE = Path(__file__).resolve().parent; SRC = HERE.parents[1] / 'sumi'
FAKE = (HERE / 'hold-probe.py').read_text().split("FAKE_SESSION = '''")[1].split("'''")[0]
with tempfile.TemporaryDirectory(prefix='kt-path-', dir='/tmp') as d:
    d = Path(d); root = d / 'k'; shutil.copytree(SRC, root, symlinks=True)
    (root / 'services/Session.qml').write_text(FAKE); (root / 'probe.qml').write_text((HERE / 'probe-pathfield.qml').read_text())
    cand = Path.home() / '.config/fastfetch/fastfetchlogo/minimaru.png'   # una imagen local que existe
    rt = d / 'rt'; rt.mkdir(mode=0o700)
    env = dict(os.environ, QT_QPA_PLATFORM='offscreen', XDG_RUNTIME_DIR=str(rt), XDG_STATE_HOME=str(d / 'st'), KT_IMG=str(cand))
    out = subprocess.run(['qs', '-p', str(root / 'probe.qml'), '--no-color'], env=env, capture_output=True, text=True, timeout=30).stdout
m = re.search(r'PROBE (\{.*\})', out); r = json.loads(m.group(1)) if m else {}
checks = [('una imagen que existe: sin aviso', r.get('ok') == ''),
          ('inexistente: «Not found» y la inicial', r.get('missing') == 'Not found · the lock screen shows your initial'),
          ('remota: «Only local files» y sin imagen', r.get('remote') == 'Only local files · the lock screen shows no image'),
          ('vacía sin respaldo: sin aviso', r.get('empty') == '')]
bad = 0
for n, ok in checks: print(('OK   ' if ok else 'FALLA'), n); bad += not ok
if not m: print(out[-1200:])
print(r); sys.exit(bad)
