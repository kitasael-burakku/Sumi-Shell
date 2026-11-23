import json,pathlib,subprocess,time,sys,importlib.util
sys.dont_write_bytecode=True
h=pathlib.Path.home();bak=h/'.local/share/kitasan-rediseno-bak/antes-11e1';dest=h/'Pictures/rediseno-fase11'
def ipc(v,*args):
 r=subprocess.run(['qs','-c','sumi','ipc','call','sumi',v,*args],capture_output=True,text=True,check=True,timeout=5)
 return json.loads(r.stdout)
def state():return ipc('sysmon','true')
def wait(fn,limit=8):
 end=time.monotonic()+limit
 while time.monotonic()<end:
  s=state()
  if fn(s):return s
  time.sleep(.1)
 raise AssertionError(s)
def guard():
 assert ipc('lockStatus')['phase']=='unlocked'
 assert subprocess.run(['pgrep','-x','hyprlock'],capture_output=True).returncode==1
 assert ipc('status')['screens'][0]['open']=='system'
def shot(n):
 guard();subprocess.run(['grim','-t','jpeg','-q','80','-g','720,0 480x460',str(dest/('11e1-'+n+'.jpg'))],check=True)
s0=state();assert s0['claims']=={} and not s0['testing'],s0
assert ipc('lockStatus')['phase']=='unlocked'
try:
 assert ipc('sysmonWatch','11e1-summary','summary')
 s=wait(lambda s:s['current'] is not None);assert s['historyCount']==0 and s['processSampleCount']==0
 assert ipc('sysmonWatch','11e1-a','detail');s=wait(lambda s:s['historyCount']>=3)
 assert s['current']==s['history'][-1];assert s['current']['cpu']['usagePct'] is not None
 assert ipc('sysmonWatch','11e1-b','detail');old=s['current']['id'];gen=s['generation']
 assert ipc('sysmonWatch','11e1-a','');s=state();assert s['generation']==gen and s['historyCount']>=3
 q=ipc('sysmonSample',old);assert q['sample']['id']==old
 if q['processes']:assert q['processes']['sampleId']==q['sample']['processSampleId']
 (bak/'sysmon-detail.json').write_text(json.dumps(s,indent=2))
 print('REAL',json.dumps({'cpuCores':s['current']['cpu']['logicalCount'],'gpuCount':len(s['current']['gpus']),
  'volumes':[(d['id'],[(v['device'],v['mounts'],v['availableB']) for v in d['volumes']]) for d in s['current']['disks']],
  'interfaces':[n['name'] for n in s['current']['network']['interfaces']], 'readMs':s['current']['readDurationMs']}),flush=True)
 assert ipc('open','system','');time.sleep(.08);shot('opening');time.sleep(.5);shot('after')
 assert ipc('sysmonWatch','11e1-b','');assert state()['level']=='detail'
 assert ipc('close','system');s=wait(lambda s:s['level']=='summary' and s['current'] is not None);assert s['historyCount']==0 and s['processSampleCount']==0
 assert ipc('sysmonWatch','11e1-summary','');s=wait(lambda s:not s['running']);assert s['historyCount']==0
 print('PASS live IPC: same current/history sample, named consumers, System claim, release to summary / stopped',flush=True)
 # Ausencias en el shell vivo mediante un árbol vacío: ningún dato real se sobrescribe.
 fake=pathlib.Path('/tmp/kt-11e1-empty');fake.mkdir(exist_ok=True)
 assert ipc('sysmonTestRoot',str(fake));assert state()['testing'] and state()['testRoot']==str(fake)
 assert ipc('open','system','');s=wait(lambda s:s['current'] is not None)
 assert s['current']['cpu']['usagePct'] is None and s['current']['memory']['usedB'] is None and s['current']['disks'] is None
 time.sleep(.4);shot('no-data');assert ipc('close','system');wait(lambda s:not s['running'])
 assert ipc('sysmonTestRoot','');assert not state()['testing']
 print('PASS live absent data stays null / No data; testRoot removed',flush=True)
finally:
 ipc('close','system')
 for who in ['11e1-a','11e1-b','11e1-summary']:ipc('sysmonWatch',who,'')
 wait(lambda s:not s['running'])
 if state()['testing']:assert ipc('sysmonTestRoot','')
print('FINAL',json.dumps(state()),flush=True)
