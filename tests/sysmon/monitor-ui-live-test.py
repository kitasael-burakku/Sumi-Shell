# M2/M3 (antes de la fase 12): la UI de inspección en el shell vivo. Sólo lectura: abre y cierra
# la UI y la surface, pausa la vista y elige procesos; no pulsa teclas en el compositor (las teclas
# van por monitorUiKey, el mismo manejador), no toca energía, modos ni procesos.
import json,subprocess,time
def ipc(v,*a):
 out=subprocess.check_output(['qs','-c','sumi','ipc','call','sumi',v,*a],text=True).strip()
 try:return json.loads(out)
 except ValueError:return out
def ui():return ipc('monitorUiState')
def sm():return ipc('sysmon','false')
def wait(fn,get=ui,limit=10):
 end=time.monotonic()+limit
 while time.monotonic()<end:
  s=get()
  if fn(s):return s
  time.sleep(.2)
 raise AssertionError(s)
def shortcut():subprocess.run(['hyprctl','dispatch','hl.dsp.global("sumi:monitor")'],check=True,capture_output=True)
def guard():assert ipc('lockStatus')['phase']=='unlocked'
guard()
s0=sm();assert s0['claims']=={} and not s0['testing'],s0['claims']
assert not ui()['open']
try:
 # 1. una instancia: atajo, IPC y «Details» llegan a la misma
 shortcut();s=wait(lambda s:s['open']);opens=s['opens'];screen=s['screen']
 assert sm()['claims'].get('monitor-ui')=='inspect'
 assert ipc('monitorUiShow','','cpu') is True;s=ui();assert s['open'] and s['section']=='cpu' and s['opens']==opens and s['screen']==screen
 assert ipc('monitorUiShow','','cpu') is True and ui()['open'],'Details never closes'
 shortcut();s=wait(lambda s:not s['open']);assert s['section']=='cpu'
 s=wait(lambda s:'monitor-ui' not in s['claims'] and not s['running'],get=sm);assert s['trendCount']==0 and s['processListCount']==0
 shortcut();s=wait(lambda s:s['open']);assert s['opens']==opens+1 and s['section']=='cpu'
 assert wait(lambda s:s['layer'] and s['layer']['loaded']=='cpu')
 print('PASS one instance: shortcut / IPC / Details, reopen keeps the section, close releases inspect and stops sampling',flush=True)
 # 2. pausa: la vista se congela, el muestreo sigue
 wait(lambda s:s['processListCount']>0 and s['historyCount']>=4,get=sm)
 assert ipc('monitorUiPause','true') is True;f=ui()['frozenId'];ticks=sm()['ticks']
 wait(lambda s:s['ticks']>=ticks+3,get=sm);s=ui();assert s['paused'] and s['shownId']==f and sm()['current']['id']!=f
 assert ipc('monitorUiKey','Space') is True;s=ui();assert not s['paused'] and s['shownId']==sm()['current']['id']
 assert ipc('monitorUiKey','Space') is True and ui()['paused'];assert ipc('monitorUiPause','false') is True
 print('PASS pause freezes the view while sampling continues; Space toggles; resume returns to the present',flush=True)
 # 3. ventanas: 60 s son muestras, 5 m+ cubos de 5 s que se van llenando
 assert ipc('monitorUiRange','5m') is True;s=ui();assert s['range']=='5m' and s['rows']==sm()['trendCount'] and s['warmingUp']
 assert ipc('monitorUiRange','1h') is True and ui()['warmingUp'];assert ipc('monitorUiRange','bogus') is False
 assert ipc('monitorUiRange','60s') is True;s=ui();assert s['rows']==sm()['historyCount']
 print('PASS ranges: 60 s uses samples, 5 m / 1 h use the 5 s trend and report warming up; unknown range refused',flush=True)
 # 4. teclas por el manejador real y secciones cargadas de una en una
 for k,sec in [('1','overview'),('3','gpu'),('4','memory'),('6','disks'),('7','network'),('8','sensors'),('2','cpu')]:
  assert ipc('monitorUiKey',k) is True;wait(lambda s:s['section']==sec and s['layer']['loaded']==sec)
 assert ipc('monitorUiKey','Slash') is True;wait(lambda s:s['section']=='processes' and s['layer']['loaded']=='processes')
 print('PASS keys 1–8 and / switch sections; only the shown section is loaded',flush=True)
 # 5. procesos: búsqueda, orden y selección por identidad; el foco sólo con la UI abierta
 p=ipc('sysmonProcesses','memory','3')['rows'][0]
 assert ipc('monitorUiQuery',p['name'],'memory','false') is True
 assert ipc('monitorUiSelect',str(p['pid']),str(p['startTicks'])) is True
 s=wait(lambda s:s['focus'] and s['focus']['pid']==p['pid'],get=sm);assert s['focusTarget']['startTicks']==p['startTicks']
 assert ui()['selected']['present']
 assert ipc('monitorUiQuery','','cpu','false') is True;assert ipc('monitorUiQuery','','bogus','false') is False
 print('PASS process search/sort/select; the selected PID is read in detail while the UI is open',flush=True)
 # 6. arrastre acotado al monitor (los límites del arrastre real son los mismos)
 g=ui()['layer'];m=round(16*0.9)
 assert ipc('monitorUiPlace','-500','-500') is True;g=ui()['layer'];assert (g['x'],g['y'])==(m,m) or abs(g['x']-m)<=1,g
 assert ipc('monitorUiPlace','5000','5000') is True;g=ui()['layer'];assert g['x']+g['w']<=g['screenW']-m+1 and g['y']+g['h']<=g['screenH']-m+1,g
 assert ipc('monitorUiPlace','300','120') is True;shortcut();wait(lambda s:not s['open']);shortcut();g=wait(lambda s:s['open'] and s['layer']['shown'])['layer'];assert (g['x'],g['y'])==(300,120),g
 print('PASS placement clamped to the monitor and remembered on reopen',flush=True)
 # 7. con la surface compacta abierta, cerrar la UI no vacía su historial
 assert ipc('open','system','') is True;wait(lambda s:s['level']=='inspect' and 'system@'+screen in s['claims'],get=sm)
 gen=sm()['generation'];hist=sm()['historyCount']
 assert ipc('monitorUiKey','Escape') is True;s=wait(lambda s:s['level']=='detail',get=sm)
 assert s['generation']==gen and s['historyCount']>=hist and s['processListCount']==0 and s['focusTarget'] is None,s
 assert ipc('close','system') is True;s=wait(lambda s:not s['running'],get=sm);assert s['historyCount']==0 and s['trendCount']==0
 print('PASS Esc closes; with the surface open history survives the UI closing; closing both stops sampling',flush=True)
finally:
 ipc('monitorUiPause','false');ipc('monitorUiQuery','','cpu','false');ipc('monitorUiSelect','0','0');ipc('monitorUiRange','60s')
 ipc('monitorUiClose');ipc('close','system')
 s=wait(lambda s:not s['running'],get=sm)
print('FINAL',json.dumps({'claims':s['claims'],'running':s['running'],'history':s['historyCount'],'trend':s['trendCount']}),flush=True)
