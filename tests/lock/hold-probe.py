#!/usr/bin/env python3
"""LK-12: HoldButton en Quickshell offscreen (copia del árbol, Session falso). Nunca toca la sesión.

Lo que exige futurelocksurface §9: cada pulsación empieza de cero (dispara a ≥ holdMs de la
pulsación nueva) y el hold se cancela al perder el foco o al ocultarse. Sale con el número de fallos.
"""
import json, os, re, shutil, subprocess, sys, tempfile
from pathlib import Path
SRC = Path(__file__).resolve().parents[2] / 'sumi'
FAKE_SESSION = '''pragma Singleton
import QtQuick
// FALSO (sonda offscreen): el real usa PanelWindow, que no existe sin Wayland.
QtObject {
    property bool keepAwake: false; property int idleTimeoutSec: 120; property bool forceIdle: false
    property bool idle: false; property bool modeIdleWanted: false; property bool modeInhibited: false
    property var modeIdleCallback: null; function claimModeIdle(w, d) {} function modeSettled(ok, r) {}
    property int resumeCount: 0; signal resumed(); function lock() {} function setKeepAwake(on) {}
    function toggleKeepAwake() {} property int inhibitRestarts: 0; function syncInhibitor() {}
    property int sleepRestarts: 0; property bool watchingSleep: false
}
'''
PROBE = (Path(__file__).parent / 'probe-hold.qml').read_text()
with tempfile.TemporaryDirectory(prefix='kt-hold-', dir='/tmp') as d:
    root = Path(d) / 'k'; shutil.copytree(SRC, root, symlinks=True)
    (root / 'services/Session.qml').write_text(FAKE_SESSION)
    (root / 'probe-hold.qml').write_text(PROBE)
    rt = Path(d) / 'rt'; rt.mkdir(mode=0o700)
    env = dict(os.environ, QT_QPA_PLATFORM='offscreen', XDG_RUNTIME_DIR=str(rt), XDG_STATE_HOME=str(Path(d) / 'st'))
    out = subprocess.run(['qs', '-p', str(root / 'probe-hold.qml'), '--no-color'], env=env,
                         capture_output=True, text=True, timeout=30).stdout
ev = [json.loads(m) for m in re.findall(r'PROBE (\{.*\})', out)]
fired = {e['test']: e['ms'] for e in ev if e.get('fired')}
hold = 600
checks = [
    ('volver a pulsar empieza de cero', fired.get('resume', 0) >= hold - 10, f"disparó a {fired.get('resume')} ms"),
    ('perder el foco cancela', 'focus-lost' not in fired, f"disparó a {fired.get('focus-lost')} ms"),
    ('ocultarse cancela', 'hidden' not in fired, f"disparó a {fired.get('hidden')} ms"),
]
bad = 0
for name, ok, detail in checks:
    print(('OK   ' if ok else 'FALLA'), name, '' if ok else '— ' + detail); bad += not ok
if not ev: print('FALLA: la sonda no arrancó'); print(out[-2000:]); bad += 1
sys.exit(bad)
