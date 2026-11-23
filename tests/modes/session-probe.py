import json, os, pathlib, shutil, subprocess, time
root=pathlib.Path('/tmp/sumi-session-probe')
src=pathlib.Path(__file__).resolve().parents[2] / 'sumi'
for part in ['services','scripts','fake','runtime']: (root/part).mkdir(parents=True,exist_ok=True)
(root/'runtime').chmod(0o700)
for f in ['services/Session.qml','scripts/mode-idle-guard.py']: shutil.copy2(src/f,root/f)
(root/'services/qmldir').write_text('singleton Session Session.qml\nsingleton Settings Settings.qml\n')
(root/'services/Settings.qml').write_text('pragma Singleton\nimport QtQuick\nQtObject { property bool keepAwake: false }\n')
(root/'shell.qml').write_text('''import Quickshell
import Quickshell.Io
import "services"
ShellRoot {
    property string result: ""
    IpcHandler {
        target: "probe"
        function state(): string { return JSON.stringify({inhibited:Session.modeInhibited, wanted:Session.modeIdleWanted, result:result, pid:Quickshell.processId}); }
        function claim(on: bool): bool { result="pending"; Session.claimModeIdle(on, r => result=JSON.stringify(r)); return true; }
        function reload(): void { Quickshell.reload(true); }
    }
}
''')
(root/'fake/systemd-inhibit').write_text('''#!/usr/bin/env python3
import os,sys,pathlib
p=pathlib.Path(__file__).parent
(p/'argv').write_text(repr(sys.argv))
(p/'pid').write_text(str(os.getpid()))
args=sys.argv[sys.argv.index('python3'):]
os.execvp(args[0],args)
''')
(root/'fake/dbus-monitor').write_text('#!/bin/sh\nexit 0\n')
for f in (root/'fake').iterdir(): f.chmod(0o755)
env=dict(os.environ,QT_QPA_PLATFORMTHEME='basic',XDG_RUNTIME_DIR=str(root/'runtime'),PATH=str(root/'fake')+':'+os.environ['PATH'])
# Se conecta al compositor, pero Keep awake falso no crea ni muestra la ventana.
env['WAYLAND_DISPLAY']=str(pathlib.Path(os.environ['XDG_RUNTIME_DIR'])/os.environ['WAYLAND_DISPLAY'])
def call(v,*args):
 r=subprocess.run(['qs','-p',str(root),'ipc','call','probe',v,*args],env=env,capture_output=True,text=True,timeout=3)
 if r.returncode: raise RuntimeError(r.stdout+r.stderr)
 return json.loads(r.stdout) if r.stdout.strip() else None
def until(test):
 end=time.monotonic()+10
 while time.monotonic()<end:
  try:
   s=call('state')
   if test(s): return s
  except (ValueError,RuntimeError,subprocess.TimeoutExpired): pass
  time.sleep(.1)
 raise RuntimeError((root/'log').read_text())
def gone(pid):
 for _ in range(30):
  try:
   state=pathlib.Path('/proc')/str(pid)/'stat'
   if not state.exists() or state.read_text().split()[2]=='Z': return True
  except FileNotFoundError: return True
  time.sleep(.1)
 return False
p=subprocess.Popen(['qs','-p',str(root),'--no-color'],env=env,stdout=(root/'log').open('w'),stderr=subprocess.STDOUT)
try:
 until(lambda s: not s['inhibited'])
 call('claim','true'); until(lambda s:s['inhibited']); child=int((root/'fake/pid').read_text())
 assert '--what=idle' in (root/'fake/argv').read_text() and 'idle:sleep' not in (root/'fake/argv').read_text()
 call('claim','false'); until(lambda s: not s['inhibited']); assert gone(child)
 print('PASS Session claim/release; idle only',flush=True)
 call('claim','true'); until(lambda s:s['inhibited']); child=int((root/'fake/pid').read_text())
 call('reload'); until(lambda s:not s['inhibited']); assert gone(child),'orphan after reload'
 print('PASS Session reload closes inhibitor',flush=True)
 call('claim','true'); s=until(lambda s:s['inhibited']); child=int((root/'fake/pid').read_text())
 os.kill(s['pid'],9); assert gone(child),'orphan after process death'
 print('PASS Session process death closes inhibitor',flush=True)
finally:
 p.terminate()
 try:p.wait(timeout=5)
 except subprocess.TimeoutExpired:p.kill();p.wait()
