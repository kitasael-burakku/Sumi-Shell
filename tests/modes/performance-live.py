# Sonda autorizada del shell vivo: todos los cambios de modos usan sustitutos.
import json,pathlib,subprocess,time,shutil
h=pathlib.Path.home();root=pathlib.Path('/tmp/kt-11d2-live');dest=h/'Pictures/rediseno-fase11'
shutil.copytree('/tmp/sumi-mode-probe/fake',root,dirs_exist_ok=True)
(root/'mode-state.json').unlink(missing_ok=True)
baseline={'dnd':{'on':False,'source':'manual'},'motion':{'override':'','preference':'normal'},'idle':False,
 'blur':True,'animations':True,'glass':{'enabled':1,'blur':1},'cursors':True,'power':'power-saver',
 'video':{'sumi-mpvpaper-A.sock':False,'sumi-mpvpaper-B.sock':True}}
(root/'backend.json').write_text(json.dumps(baseline));(root/'faults.json').write_text('{}')
for n in ['qs','hyprctl','powerprofilesctl','wallpaper-fake']:
 p=root/n;t=p.read_text();t=t.replace("write=False; key=''", "import time\ntime.sleep(f.get('delay',0))\nwrite=False; key=''");p.write_text(t)
(root/'wallpaper-video-pause.sh').write_text('#!/bin/bash\nexec "'+str(root/'wallpaper-fake')+'" "$@"\n')
def ipc(v,*a):
 r=subprocess.run(['qs','-c','sumi','ipc','call','sumi',v,*a],capture_output=True,text=True,check=True,timeout=5)
 return json.loads(r.stdout)
def state():return ipc('modes')
def view():return ipc('dashboardPerformance','')
def settled():
 for _ in range(300):
  s=state()
  if s['loaded'] and not s['busy']:return s
  time.sleep(.05)
 raise RuntimeError(state())
def guard(surface='dashboard'):
 assert ipc('lockStatus')['phase']=='unlocked'
 assert subprocess.run(['pgrep','-x','hyprlock'],capture_output=True).returncode==1
 assert ipc('status')['screens'][0]['open']==surface
 s=state();assert s['testing'] and s['testRoot']==str(root)
def shot(name):
 if name not in ['opening','applying']:time.sleep(.25)
 guard();subprocess.run(['grim','-t','jpeg','-q','80','-g','625,0 675x465',str(dest/('11d2-'+name+'.jpg'))],check=True)
def key(k,surface='dashboard'):
 guard(surface);subprocess.run(['wtype','-k',k],check=True);time.sleep(.15)
def select(mode):
 # Cambiar selección por teclado; Tab se queda dentro de las cuatro tarjetas.
 assert view()['section']=='mode',view()
 for _ in range(4):
  if view()['selected']==mode:return
  k='Left' if mode in ['normal','gaming'] else 'Right'
  if (view()['selected'] in ['normal','focus']) != (mode in ['normal','focus']): k='Down' if mode in ['gaming','cinema'] else 'Up'
  key(k)
 assert view()['selected']==mode,view()
def faults(data): (root/'faults.json').write_text(json.dumps(data))
def enter():
 guard();key('Return');return settled()
def power(data):guard();assert ipc('performanceTestPower',json.dumps(data),'') is True
try:
 assert ipc('modeTestRoot',str(root)) is True;settled();assert state()['testing']
 assert ipc('open','performance','') is True;time.sleep(.07);shot('opening');time.sleep(.5);settled()
 key('Down');assert view()['selected']=='gaming';print('PASS Down probe selects Gaming',flush=True)
 key('Up');key('Right');assert view()['selected']=='focus';shot('keyboard-focus')
 s=enter();assert s['mode']=='focus' and s['activeMode']=='focus';shot('focus-applied')
 select('gaming');faults({'blur':'ignore','delay':.06});key('Return');s=state();assert s['busy'] and s['activeMode']=='';assert s['progress']['mode']=='gaming';shot('applying')
 s=settled();assert s['state']=='partial' and s['activeMode']=='';assert any(r['key']=='blur' and r['warning'] for r in view()['rows']);shot('partial')
 key('Down');assert view()['section']=='modeActions' and view()['action']=='Retry';shot('retry-keyboard')
 faults({});s=enter();assert s['state']=='applied' and s['activeMode']=='gaming';shot('gaming-applied')
 # Volver a normal con el botón, desde el snapshot y no valores fijos.
 assert view()['action']=='Back to normal';s=enter();assert s['activeMode']=='normal';assert json.loads((root/'backend.json').read_text())==baseline
 print('PASS keyboard apply, progress, partial, Retry, Back to normal and snapshot',flush=True)
 # Unavailable entra por la misma tarjeta y la recuperación por teclado.
 assert view()['section']=='mode';select('gaming');faults({k:'unavailable' for k in baseline});s=enter();assert s['state']=='unavailable' and s['activeMode']=='';shot('unavailable')
 key('Down');key('Right');assert view()['action']=='Back to normal';faults({});s=enter();assert s['activeMode']=='normal'
 select('gaming');s=enter();assert s['activeMode']=='gaming'
 d=json.loads((root/'backend.json').read_text());d['dnd']={'on':False,'source':'manual'};(root/'backend.json').write_text(json.dumps(d))
 # Reabrir relee los efectos y mantiene la selección del modo activo.
 assert ipc('close','dashboard');assert ipc('open','performance','');time.sleep(.4);settled()
 assert view()['selected']=='gaming';assert next(r for r in view()['rows'] if r['key']=='dnd')['status']=='Kept your change';shot('manual-change')
 cli=subprocess.run(['fish','-c','source ~/.config/fish/functions/minimaru.fish; minimaru mode status'],capture_output=True,text=True,check=True)
 assert json.loads(cli.stdout)['activeMode']==view()['activeMode']=='gaming'
 assert ipc('open','controlCenter','');time.sleep(.4);cc=ipc('controlCenterState','');assert cc['mode']=='gaming'
 key('Down','controlCenter');cc=ipc('controlCenterState','');print('CC probe',json.dumps(cc),flush=True)
 # Sólo navegar hasta System mode; Enter no toca DND ni otros controles.
 for _ in range(20):
  cc=ipc('controlCenterState','')
  if cc.get('focus')=='mode' or cc.get('focused')=='mode':break
  key('Down','controlCenter')
 else:raise RuntimeError('Cannot find CC mode focus: '+str(cc))
 key('Return','controlCenter');time.sleep(.4);settled();assert ipc('dashboardJob','')['tab']=='performance';assert view()['selected']=='gaming'
 print('PASS manual change, reopen, CLI / IPC / Control Center and CC link',flush=True)
 # La energía usa una sustitución visual con controles reales bloqueados.
 pv={'checked':True,'present':True,'available':['performance','balanced','power-saver'],'current':'performance','shown':'performance','applying':False,'error':'','degradation':'high temperature','holds':[]}
 power(pv);key('Down');key('Down');assert view()['section']=='profile';shot('power-degraded');assert 'high temperature' in view()['powerNote']
 pv['degradation']='lap detected';power(pv);assert 'lap detected' in view()['powerNote']
 pv.update(present=False);power(pv);shot('power-unavailable');assert 'Unavailable' in view()['powerNote']
 pv.update(present=True,checked=False);power(pv);assert 'Checking' in view()['powerNote']
 pv.update(checked=True,degradation='',available=['balanced','power-saver'],holds=[{'app':'Example app','profile':'balanced','reason':'A task is running'}]);power(pv);assert 'Performance unavailable' in view()['powerNote'];assert 'Example app' in view()['powerNote'];shot('power-held')
 pv.update(applying=True,shown='performance',current='balanced');power(pv);assert 'Applying performance' in view()['powerNote']
 pv.update(applying=False,error='The daemon kept balanced');power(pv);shot('power-error')
 power(None);print('PASS power checking, absent, degraded, holds, capability, pending and error',flush=True)
 # System Monitor y Back conservan tarjeta y sección. No se ejecuta un modo al volver.
 key('Down');assert view()['section']=='monitor';key('Return');time.sleep(.4)
 guard('system');subprocess.run(['wtype','-M','alt','-k','Left','-m','alt'],check=True);time.sleep(.4);settled();guard();assert view()['selected']=='gaming' and view()['section']=='monitor',view()
 print('PASS System Monitor / Back context',flush=True)
 key('Tab');assert view()['section']=='tabs';key('Tab');assert view()['section']=='mode' and view()['selected']=='normal'
 for m in ['focus','gaming','cinema']:
  key('Tab');assert view()['selected']==m
 assert state()['mode']=='gaming'
 print('PASS Tab traverses four cards without applying',flush=True)
 # Fallo de persistencia y reintento idéntico, siempre en el backend falso.
 guard();assert ipc('modeTest','normal');settled()
 (root/'backend.json').write_text(json.dumps(baseline))
 assert ipc('close','dashboard');assert ipc('open','performance','');time.sleep(.4);settled()
 key('Down');assert view()['selected']=='gaming';key('Up');key('Right')
 root.chmod(0o500)
 s=enter();assert s['state']=='error' and s['activeMode']=='';shot('snapshot-error')
 assert json.loads((root/'backend.json').read_text())==baseline
 root.chmod(0o700)
 key('Down');key('Down');assert view()['section']=='modeActions' and view()['action']=='Retry'
 s=enter();assert s['activeMode']=='focus';shot('focus-recovered')
 print('PASS snapshot failure changes nothing; keyboard Retry recovers',flush=True)

finally:
 root.chmod(0o700);faults({});s=settled()
 if s['testing']:
  if s['mode']!='normal':assert ipc('modeTest','normal');settled()
  assert ipc('modeTestRoot','');settled();assert not state()['testing']
 ipc('close','dashboard');ipc('close','controlCenter');ipc('close','system')
 print('CLEANUP real backend restored, views closed',flush=True)
