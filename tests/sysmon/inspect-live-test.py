# M1 (antes de la fase 12): nivel inspect en el shell vivo, sólo lectura, y su coste medido.
# Reclama por IPC con nombres propios y lo suelta en finally. No abre surfaces ni pulsa teclas.
import json,os,subprocess,time,sys
def ipc(v,*a):return json.loads(subprocess.check_output(['qs','-c','sumi','ipc','call','sumi',v,*a],text=True))
def state():return ipc('sysmon','false')
def wait(fn,limit=10):
 end=time.monotonic()+limit
 while time.monotonic()<end:
  s=state()
  if fn(s):return s
  time.sleep(.2)
 raise AssertionError(s)
hz=os.sysconf('SC_CLK_TCK')
def main_pid():return int(subprocess.check_output(['systemctl','--user','show','-p','MainPID','--value','sumi-shell'],text=True))
def collector():
 out=subprocess.run(['pgrep','-f','sysmon-collect.py'],capture_output=True,text=True).stdout.split()
 return [int(p) for p in out]
def ticks(pid):
 try:
  v=open(f'/proc/{pid}/stat').read().rsplit(')',1)[1].split();return int(v[11])+int(v[12])
 except OSError:return 0
def rss(pid):
 try:
  for l in open(f'/proc/{pid}/status'):
   if l.startswith('VmRSS'):return int(l.split()[1])//1024
 except OSError:return 0
def measure(label,seconds=20):
 qs=main_pid();c=collector();a=ticks(qs);b=sum(ticks(p) for p in c);t=time.monotonic()
 time.sleep(seconds);dt=time.monotonic()-t
 r={'level':label,'shellCpuPct':round((ticks(qs)-a)/hz/dt*100,2),'collectorCpuPct':round((sum(ticks(p) for p in collector())-b)/hz/dt*100,2),
    'shellRssMiB':rss(qs),'collectorRssMiB':sum(rss(p) for p in collector()),'collectors':len(collector())}
 print('COST',json.dumps(r),flush=True);return r
assert ipc('lockStatus')['phase']=='unlocked'
s0=state();assert s0['claims']=={} and not s0['testing'],s0['claims']
try:
 base=measure('none',10)
 assert ipc('sysmonWatch','m1-detail','detail');wait(lambda s:s['historyCount']>=3)
 det=measure('detail')
 gen=state()['generation']
 assert ipc('sysmonWatch','m1-ui','inspect');s=wait(lambda s:s['processListCount']>0 and s['sensorChips']>0)
 assert s['generation']==gen and s['historyCount']>=20,(s['generation'],gen,s['historyCount'])
 p=ipc('sysmonProcesses','cpu','5');print('PROCS',p['total'],p['info']['state'],[(r['name'],r['user'],round(r['cpuPct'] or 0,1)) for r in p['rows']],flush=True)
 me=[r for r in ipc('sysmonProcesses','pid','40')['rows']];top=p['rows'][0]
 assert ipc('sysmonFocus',str(top['pid']),str(top['startTicks']));s=wait(lambda s:s['focus'] and s['focus']['pid']==top['pid'])
 print('FOCUS',json.dumps({k:s['focus'][k] for k in ['pid','state','runState','parent','threads','rssB','fds','ioAvailable']}),flush=True)
 sen=ipc('sysmonSensors');print('SENSORS',[(c['name'],c['kind'],len(c['temps']),len(c['fans']),len(c['volts'])) for c in sen['sensors']['chips']],flush=True)
 ins=measure('inspect')
 s=state();print('ALERTS',s['alerts'],'TREND',s['trendCount'],s['trendSpanS'],flush=True)
 cur=ipc('sysmon','false')['current'];print('CURRENT',json.dumps({'cpuFreqMax':cur['cpu'].get('frequencyMaxMHz'),'gpuFreq':cur['gpus'][0]['frequencyMHz'],
   'diskTemps':[(d['id'],d['temperatureC']) for d in cur['disks']],'busy':[io['busyPct'] for d in cur['disks'] for io in d['io']],
   'cache':cur['memory']['cacheB'],'psi':cur['memory']['pressureSomePct'],'uptime':cur['system']['uptimeS'],'readMs':round(cur['readDurationMs'],1)}),flush=True)
 assert ipc('sysmonWatch','m1-ui','');s=wait(lambda s:s['level']=='detail' and s['processListCount']==0)
 assert s['generation']==gen and s['focus'] is None and s['sensorChips']==0
 print('PASS live inspect: same generation/history, full process list, sensors, focus; released back to detail',flush=True)
finally:
 ipc('sysmonFocus','0','0')
 for who in ['m1-ui','m1-detail']:ipc('sysmonWatch',who,'')
 s=wait(lambda s:not s['running'])
 assert s['trendCount']==0 and s['historyCount']==0 and s['processListCount']==0
 print('FINAL released: no collector, no history/trend/list',flush=True)
