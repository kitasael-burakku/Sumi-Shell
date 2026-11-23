# Prueba de lectura: no aplica modos, energía ni operaciones del sistema.
import json,pathlib,subprocess,time
h=pathlib.Path.home();dest=h/'Pictures/rediseno-fase11';bak=h/'.local/share/kitasan-rediseno-bak/antes-11e2';bak.mkdir(parents=True,exist_ok=True)
def ipc(v,*a):return json.loads(subprocess.check_output(['qs','-c','sumi','ipc','call','sumi',v,*a],text=True))
def guard(surface):
 assert ipc('lockStatus')['phase']=='unlocked'
 assert subprocess.run(['pgrep','-x','hyprlock'],capture_output=True).returncode==1
 assert ipc('status')['screens'][0]['open']==surface

def key(k,surface='system'):
 guard(surface);subprocess.run(['wtype','-k',k],check=True);time.sleep(.13)
def shot(n):
 guard('system');subprocess.run(['grim','-t','jpeg','-q','80','-g','540,0 840x620',str(dest/('11e2-'+n+'.jpg'))],check=True)
def state():return ipc('systemMonitor','')
assert ipc('lockStatus')['phase']=='unlocked'
assert not ipc('sysmon','false')['testing']
try:
 assert ipc('open','performance','');time.sleep(.5)
 key('Down','dashboard')
 for _ in range(16):
  if ipc('dashboardPerformance','')['section']=='monitor':break
  key('Tab','dashboard')
 assert ipc('dashboardPerformance','')['section']=='monitor'
 key('Return','dashboard');assert state()['open'];shot('opening');time.sleep(8);shot('after')
 key('Down');assert state()['card'].startswith('gpu:');key('Up');key('Return');key('Left')
 s=state();old=s['shownId'];process=s['processId'];cpu=s['cards'][0];assert s['selectedSample']==old and cpu['processes']['rows']
 time.sleep(2);s=state();assert s['shownId']==old and s['processId']==process and s['cards'][0]==cpu
 sample=ipc('sysmonSample',old);assert sample['sample']['id']==old
 assert (sample['processes']['sampleId'] if sample['processes'] else '')==process
 shot('cpu-history');key('Next');shot('processes')
 saved=state();assert ipc('historyBack','');assert ipc('status')['screens'][0]['open']=='dashboard'
 assert ipc('historyForward','');time.sleep(.3);s=state();assert s['selectedSample']==saved['selectedSample'] and s['expanded']==saved['expanded']
 # El historial se liberó al salir; Back no inventa una muestra de la generación siguiente.
 assert s['expired'];shot('expired-live');key('End');assert not state()['selectedSample']
 key('Escape');key('Down');key('Return');shot('gpu-details');key('Escape')
 key('Down');key('Return');shot('memory-details');key('Escape')
 key('Down');key('Return');shot('network-details');key('Escape')
 key('Down');key('Return');shot('disk-details');key('Escape')
 for _ in range(8):
  if state()['card']=='energy':break
  key('Down')
 assert state()['card']=='energy';key('Return');shot('energy-details');key('Escape')
 key('Tab');assert state()['card']=='performance';key('Return');assert ipc('dashboardPerformance','')['section']=='mode'
 assert ipc('status')['screens'][0]['open']=='dashboard'
 assert ipc('open','system','');time.sleep(.4)
 assert ipc('sysmonWatch','11e2-summary','summary');assert ipc('sysmonWatch','11e2-other','detail')
 history=ipc('sysmon','false')['historyCount'];assert history>0
 assert ipc('close','system');time.sleep(.2);s=ipc('sysmon','false');assert s['level']=='detail' and s['historyCount']>=history
 assert ipc('sysmonWatch','11e2-other','');time.sleep(.2);s=ipc('sysmon','true');assert s['level']=='summary' and s['historyCount']==0 and s['processSampleCount']==0
 assert ipc('sysmonWatch','11e2-summary','');time.sleep(.2);s=ipc('sysmon','true');assert not s['running']
 (bak/'monitor-final.json').write_text(json.dumps({'selection':saved,'sample':sample,'after':s},indent=2))
 print('PASS Performance → Monitor → Performance by keyboard; coherent historical values/processes; Back/Forward expiry',flush=True)
 print('PASS GPU/memory/network/disk/energy detail; multiple consumers; last detail releases history; last consumer stops worker',flush=True)
finally:
 ipc('close','system');ipc('close','dashboard')
 for who in ['11e2-summary','11e2-other']:ipc('sysmonWatch',who,'')
