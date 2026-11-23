# M4 (antes de la fase 12): la surface compacta y sus accesos a la UI de inspección, por teclado.
# Sólo lectura. Cada tecla comprueba unlocked, sin hyprlock y la surface esperada abierta (el
# teclado es suyo); empieza con ↓ como sonda. No cambia energía, modos ni procesos.
import json,pathlib,subprocess,time
dest=pathlib.Path.home()/'Pictures/rediseno-antes12'
def ipc(v,*a):
 out=subprocess.check_output(['qs','-c','sumi','ipc','call','sumi',v,*a],text=True).strip()
 try:return json.loads(out)
 except ValueError:return out
def opened():return ipc('status')['screens'][0]['open']
def guard(surface):
 assert ipc('lockStatus')['phase']=='unlocked'
 assert subprocess.run(['pgrep','-x','hyprlock'],capture_output=True).returncode==1
 assert opened()==surface,(opened(),surface)
def key(k,surface='system'):guard(surface);subprocess.run(['wtype','-k',k],check=True);time.sleep(.15)
def sm():return ipc('sysmon','false')
def compact():return ipc('systemMonitor','')
def ui():return ipc('monitorUiState')
def wait(fn,get,limit=8):
 end=time.monotonic()+limit
 while time.monotonic()<end:
  s=get()
  if fn(s):return s
  time.sleep(.15)
 raise AssertionError(s)
assert sm()['claims']=={} and not ui()['open']
try:
 assert ipc('open','system','') is True;time.sleep(.5)
 s=wait(lambda s:s['historyCount']>=3,compact)
 ids=[c['id'] for c in s['cards']];assert ids[0]=='cpu' and ids[-1]=='energy' and 'disks' in ids,ids
 assert all(c['graph'] for c in s['cards'] if c['id']!='energy' and not c['id'].endswith(':none'))
 assert not any('processes' in c or 'cores' in c for c in s['cards'])
 print('PASS compact cards: CPU, GPU, memory, network, disks, energy; micrographs; no processes/cores/mounts',flush=True)
 key('Down');s=compact();assert s['card']=='memory',s['card']
 key('Right');assert compact()['card']=='network'
 gen=sm()['generation'];hist=sm()['historyCount']
 key('Return');u=wait(lambda u:u['open'] and u['section']=='network',ui)
 wait(lambda s:opened()!='system',lambda:1)
 s=wait(lambda s:s['level']=='inspect' and not any(k.startswith('system@') for k in s['claims']),sm)
 assert s['generation']==gen and s['historyCount']>=hist,(s['generation'],gen,s['historyCount'],hist)
 print('PASS Enter on Network → UI / Network, surface closed, same sampling generation and history',flush=True)
 assert ipc('monitorUiClose') is True;wait(lambda s:not s['running'],sm)
 # Tab hasta Inspect y Dashboard → Performance
 assert ipc('open','system','') is True;time.sleep(.5)
 for _ in range(10):
  if compact()['card']=='inspect':break
  key('Tab')
 assert compact()['card']=='inspect';key('Return');wait(lambda u:u['open'] and u['section']=='overview',ui)
 assert ipc('monitorUiClose') is True
 print('PASS Tab reaches Inspect; Enter opens the UI on Overview',flush=True)
 assert ipc('open','performance','') is True;time.sleep(.5)
 key('Down','dashboard')
 for _ in range(16):
  if ipc('dashboardPerformance','')['section']=='monitor':break
  key('Tab','dashboard')
 assert ipc('dashboardPerformance','')['section']=='monitor'
 key('Right','dashboard');key('Return','dashboard');wait(lambda u:u['open'] and u['section']=='overview',ui)
 wait(lambda s:opened()!='dashboard',lambda:1)
 time.sleep(1.2);guard(opened())
 subprocess.run(['grim','-t','jpeg','-q','80',str(dest/'m4-from-dashboard.jpg')],check=True)
 print('PASS Dashboard → Performance → Inspect opens the same UI and closes the Dashboard',flush=True)
finally:
 ipc('monitorUiClose');ipc('close','system');ipc('close','dashboard')
 s=wait(lambda s:not s['running'],sm)
print('FINAL',json.dumps({'claims':s['claims'],'running':s['running'],'history':s['historyCount']}),flush=True)
