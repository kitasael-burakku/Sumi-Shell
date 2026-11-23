import json, os, pathlib, shutil, subprocess, time

root = pathlib.Path('/tmp/sumi-mode-probe')
# F5a: SUMI_MODES_SRC prueba otro árbol (la copia de desarrollo) sin desplegar
src = pathlib.Path(os.environ.get('SUMI_MODES_SRC') or pathlib.Path(__file__).resolve().parents[2] / 'sumi')
for part in ['services','theme','lib','fake','runtime']:
    (root/part).mkdir(parents=True, exist_ok=True)
(root/'runtime').chmod(0o700)
for name in ['services/Modes.qml','lib/modes.js','lib/hypr-dialect.js']:
    shutil.copy2(src/name,root/name)
stubs = {
 'Settings': 'property string motionMode: "normal"',
 'NotifHistory': 'property bool loaded: true; property bool dnd: false; property string dndSource: "manual"; function restoreDnd(on, source) {}',
 'Notifs': 'property bool enabled: true',
 'Session': 'property bool modeInhibited: false; function claimModeIdle(value, done) { done({ok:false}); }',
 # F5a: Modes pide las órdenes de Hyprland a HyprCtl; aquí, siempre la forma Lua (la que entiende el hyprctl falso)
 'HyprCtl': 'function hotConfigArgs(key, value) { return Dialect.hotConfig("lua", key, value); }',
 'PowerProfile': 'property string opReason: ""; property QtObject ops: QtObject { signal settled(string key, int rev, string state, string reason) }; function setProfile(value) { return -1; }'
}
for name, body in stubs.items():
    imp = 'import "../lib/hypr-dialect.js" as Dialect\n' if name == 'HyprCtl' else ''
    (root/f'services/{name}.qml').write_text('pragma Singleton\nimport QtQuick\n'+imp+'QtObject { '+body+' }\n')
(root/'services/qmldir').write_text('\n'.join(f'singleton {n} {n}.qml' for n in ['Modes']+list(stubs)))
(root/'theme/qmldir').write_text('singleton Motion Motion.qml\n')
(root/'theme/Motion.qml').write_text('pragma Singleton\nimport QtQuick\nQtObject { property string override: "" }\n')
(root/'shell.qml').write_text('''import Quickshell
import Quickshell.Io
import "services"
ShellRoot {
    IpcHandler {
        target: "probe"
        function state(): string { return JSON.stringify(Modes.summary()); }
        function set(mode: string): bool { return Modes.set(mode); }
        function check(): bool { return Modes.refresh(); }
    }
}
''')
fake = root/'fake'
baseline = {'dnd': {'on': False, 'source': 'manual'}, 'motion': {'override':'', 'preference':'normal'},
    'idle':False, 'blur':True, 'animations':True, 'glass':{'enabled':1,'blur':1}, 'cursors':True,
    'power':'power-saver', 'video':{'sumi-mpvpaper-A.sock':False, 'sumi-mpvpaper-B.sock':True}}
(fake/'backend.json').write_text(json.dumps(baseline))
(fake/'faults.json').write_text('{}')
program = '''#!/usr/bin/env python3
import json, pathlib, sys, re
p=pathlib.Path(__file__).resolve().parent
name=pathlib.Path(sys.argv[0]).name
a=sys.argv[1:]; d=json.loads((p/'backend.json').read_text()); f=json.loads((p/'faults.json').read_text())
write=False; key=''; value=None
if name=='qs':
 key=a[1]; write=a[0]=='write'
 if write: value=json.loads(a[2])
elif name=='powerprofilesctl':
 key='power'; write=a[0]=='set'
 if a[0]=='list': print('performance:\\nbalanced:\\npower-saver:'); sys.exit(0)
 if write: value=a[1]
elif name=='wallpaper-fake':
 key='video'; write=a[0]=='restore'
 if write: value=json.loads(a[1])
elif name=='hyprctl':
 write=a[0]=='eval'; text=a[-1]
 key='glass' if 'hyprglass' in text else 'cursors' if 'dynamic_cursors' in text else 'animations' if 'animations' in text else 'blur'
 if write:
  value={'enabled':int(re.search(r'enabled = (\\d)',text)[1]),'blur':int(re.search(r'manage_window_blur = (\\d)',text)[1])} if key=='glass' else 'enabled = true' in text
with (p/'calls.jsonl').open('a') as log: log.write(json.dumps([name,a])+ '\\n')
if f.get(key)=='unavailable': sys.exit(127)
if write:
 if f.get(key)=='fail': sys.exit(1)
 if f.get(key)!='ignore': d[key]=value; (p/'backend.json').write_text(json.dumps(d))
 print('ok'); sys.exit(0)
if name=='hyprctl': print(json.dumps({'int':d[key]['blur' if 'manage_window_blur' in a[-1] else 'enabled']} if key=='glass' else {'bool':d[key]}))
elif name=='powerprofilesctl': print(d[key])
else: print(json.dumps(d[key]))
'''
for name in ['qs','hyprctl','powerprofilesctl','wallpaper-fake']:
    (fake/name).write_text(program); (fake/name).chmod(0o755)
(fake/'wallpaper-video-pause.sh').write_text('#!/bin/bash\nexec "'+str(fake/'wallpaper-fake')+'" "$@"\n')
env=dict(os.environ, QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='basic', SUMI_MODES_TEST_ROOT=str(fake), XDG_RUNTIME_DIR=str(root/'runtime'))

def call(verb,*args):
    r=subprocess.run(['qs','-p',str(root),'ipc','call','probe',verb,*args],env=env,capture_output=True,text=True,timeout=2)
    if r.returncode: raise RuntimeError(r.stderr+r.stdout)
    return json.loads(r.stdout)
def settled():
    limit=time.monotonic()+20
    while time.monotonic()<limit:
        try:
            state=call('state')
            if state['loaded'] and not state['busy']: return state
        except (RuntimeError,ValueError,subprocess.TimeoutExpired): pass
        time.sleep(.08)
    raise RuntimeError('Timeout: '+(root/'log').read_text())
def start():
    log=(root/'log').open('a')
    p=subprocess.Popen(['qs','-p',str(root),'--no-color'],env=env,stdout=log,stderr=log)
    return p,settled()
def backend(): return json.loads((fake/'backend.json').read_text())
def setmode(mode):
    assert call('set',mode) is True
    return settled()
if __name__=='__main__':
    # Sólo esta caja; nunca el shell vivo ni su estado.
    (fake/'mode-state.json').unlink(missing_ok=True)
    p=None
    try:
        p,s=start(); print('PASS initial normal',flush=True)
        for mode in ['focus','gaming','cinema']:
            s=setmode(mode); print('PASS '+mode,flush=True); assert s['state']=='applied'
            s=setmode('normal'); assert s['state']=='applied'; assert backend()==baseline,(backend(),baseline)
        print('PASS matrix and snapshot restore',flush=True)
        setmode('gaming')
        d=backend(); d['dnd']={'on':False,'source':'manual'}; d['power']='balanced'; (fake/'backend.json').write_text(json.dumps(d))
        call('check'); s=settled(); assert s['effects']['dnd']['status']=='modified'
        setmode('focus'); setmode('normal'); d=backend(); assert d['dnd']=={'on':False,'source':'manual'} and d['power']=='balanced'
        print('PASS manual DND and power across modes',flush=True)
        (fake/'faults.json').write_text('{"blur":"ignore"}')
        s=setmode('gaming'); assert s['state']=='partial',s
        (fake/'faults.json').write_text('{}'); s=setmode('gaming'); assert s['state']=='applied',s
        print('PASS partial and retry',flush=True)
        p.kill(); p.wait(); p,s=start(); assert s['mode']=='gaming' and s['state']=='applied',s
        setmode('normal'); print('PASS restart reconciliation',flush=True)
        (fake/'faults.json').write_text(json.dumps({k:'unavailable' for k in baseline}))
        s=setmode('gaming'); assert s['state']=='unavailable',s
        (fake/'faults.json').write_text('{}'); setmode('normal')
        print('PASS unavailable',flush=True)
    finally:
        if p is not None: p.terminate(); p.wait(timeout=5)
