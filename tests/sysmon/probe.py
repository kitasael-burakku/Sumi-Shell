import json,os,pathlib,shutil,subprocess,time,importlib.util
h=pathlib.Path.home();source=pathlib.Path(__file__).resolve().parents[2]/'sumi';root=pathlib.Path('/tmp/sumi-sysmon-probe')
for name in ['services','scripts','runtime','fake','lib']:(root/name).mkdir(parents=True,exist_ok=True)
(root/'runtime').chmod(0o700)
spec=importlib.util.spec_from_file_location('fixtures',pathlib.Path(__file__).with_name('test-collector.py'));fx=importlib.util.module_from_spec(spec);spec.loader.exec_module(fx);fx.fixture(root/'fake')
shutil.copy2(source/'services/Sysmon.qml',root/'services/Sysmon.qml');shutil.copy2(source/'lib/monitor-alerts.js',root/'lib/monitor-alerts.js');shutil.copy2(source/'scripts/sysmon-collect.py',root/'scripts/sysmon-collect.py')
(root/'services/qmldir').write_text('singleton Sysmon Sysmon.qml\nsingleton Session Session.qml\nsingleton Units Units.qml\n')
(root/'services/Session.qml').write_text('pragma Singleton\nimport QtQuick\nQtObject { property bool idle: false }\n')
(root/'services/Units.qml').write_text('pragma Singleton\nimport QtQuick\nQtObject { property int failedTotal: 0; function claim(w,v) {} function refreshFailed() {} }\n')
(root/'shell.qml').write_text('''import Quickshell
import Quickshell.Io
import "services"
ShellRoot {
 IpcHandler {
  target: "probe"
  function state(): string { return JSON.stringify(Sysmon.summary(true)); }
  function root(path: string): bool { return Sysmon.setTestRoot(path); }
  function claim(who: string, level: string): bool { Sysmon.claim(who,level); return true; }
  function poll(): bool { return Sysmon.poll(); }
  function idle(on: bool): bool { Session.idle=on; return true; }
  function page(before: string, count: int): string { return JSON.stringify(Sysmon.historyPage(before,count)); }
  function focus(pid: int, start: int): bool { Sysmon.setFocus(pid,start); return true; }
  function sample(id: string): string { return JSON.stringify({sample:Sysmon.sampleAt(id),processes:Sysmon.processesAt(id)}); }
 }
}
''')
env=dict(os.environ,QT_QPA_PLATFORM='offscreen',QT_QPA_PLATFORMTHEME='basic',XDG_RUNTIME_DIR=str(root/'runtime'))
def call(v,*args):
 r=subprocess.run(['qs','-p',str(root),'ipc','call','probe',v,*args],env=env,capture_output=True,text=True,timeout=3)
 if r.returncode:raise RuntimeError(r.stderr+r.stdout)
 return json.loads(r.stdout)
def wait(fn,timeout=6):
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  try:
   s=call('state')
   if fn(s):return s
  except (ValueError,RuntimeError):pass
  time.sleep(.04)
 raise AssertionError((s,(root/'log').read_text()[-4000:]))
def step(n):
 old=call('state')['ticks'];fx.clock(root/'fake',100+n)
 # El temporizador puede haber adquirido la lectura entre dos llamadas IPC.
 end=time.monotonic()+3
 while not call('poll'):
  assert time.monotonic()<end
  time.sleep(.01)
 return wait(lambda s:s['ticks']>old and not s['pending'])
log=(root/'log').open('w');p=subprocess.Popen(['qs','-p',str(root),'--no-color'],env=env,stdout=log,stderr=log)
try:
 s=wait(lambda s:True);assert not s['running'] and s['historyCount']==0
 assert call('root',str(root/'fake'));assert call('claim','bar','summary')
 s=wait(lambda s:s['current'] is not None);assert s['historyCount']==0 and s['processSampleCount']==0 and s['current']['gpus'] is None
 assert call('root','') is False
 assert call('claim','one','detail');s=wait(lambda s:s['historyCount']>0)
 assert s['current']==s['history'][-1];generation=s['generation'];assert call('claim','two','detail')
 s=step(1);assert s['generation']==generation
 first=s['history'][0];selected=call('sample',first['id']);assert selected['sample']==first
 for n in range(2,67):s=step(n)
 seen=[];before=''
 while True:
  page=call('page',before,'8');seen= [r['id'] for r in page['samples']]+seen
  before=page['nextBefore']
  if not before:break
 assert len(seen)==len(set(seen)) and len(seen)>=59
 assert 59<=s['historyCount']<=60,s['historyCount'];assert s['processSampleCount']<=21
 assert s['current']['monoMs']-s['oldestMonoMs']<60000
 old=call('sample',first['id']);assert old['sample'] is None and old['processes'] is None
 for sample in s['history'][-6:]:
  old=call('sample',sample['id']);assert old['sample']==sample
  if old['processes']:assert old['processes']['atMonoMs']<=sample['monoMs'] and old['processes']['sampleId']==sample['processSampleId']
 print('PASS summary: no history/processes; coherent detail and bounded 60-second history',flush=True)
 # M1: tendencia de 5 s, inspect sin reiniciar, alertas sostenidas.
 assert 11<=s['trendCount']<=13 and s['trendSpanS']<=66,(s['trendCount'],s['trendSpanS'])
 assert s['processListCount']==0 and not s['inspect'] and s['alerts']==[]
 n=67
 assert call('claim','ui','inspect');s=wait(lambda s:s['level']=='inspect');assert s['generation']==generation and s['historyCount']>=59
 assert call('focus','100','1')
 for _ in range(3):s=step(n);n+=1
 assert s['generation']==generation and s['historyCount']>=59 and s['trendCount']>=11
 assert s['processListCount']==1 and s['processListInfo']['state']=='ok' and s['sensorChips']==1 and s['sensorPeakCount']==1
 assert s['focus'] and s['focus']['state']=='ok' and s['focus']['pid']==100,s['focus']
 assert call('claim','ui','');s=wait(lambda s:s['level']=='detail')
 s=step(n);n+=1;assert s['generation']==generation and s['processListCount']==0 and s['focus'] is None and s['sensorChips']==0
 fx.put(root/'fake','sys/class/hwmon/hwmon0/temp1_input',99000)
 for _ in range(5):s=step(n);n+=1
 assert not [a for a in s['alerts'] if a['id']=='temp:cpu.temp'],s['alerts']
 for _ in range(6):s=step(n);n+=1
 assert [a for a in s['alerts'] if a['id']=='temp:cpu.temp' and 'sensor' in a['detail']],s['alerts']
 fx.put(root/'fake','sys/class/hwmon/hwmon0/temp1_input',45000);s=step(n);n+=1;assert not s['alerts'],s['alerts']
 (root/'fake/sys/class/hwmon/hwmon0/temp1_input').unlink()
 for _ in range(5):s=step(n);n+=1
 assert [a for a in s['alerts'] if a['id']=='lost:cpu.temp'],s['alerts']
 fx.put(root/'fake','sys/class/hwmon/hwmon0/temp1_input',45000);s=step(n);n+=1;assert not s['alerts']
 print('PASS trend buckets, detail<->inspect keeps generation/history, inspect data released, sustained and lost-reading alerts',flush=True)
 assert call('claim','one','');assert call('state')['generation']==generation
 assert call('idle','true');s=wait(lambda s:not s['running']);assert s['historyCount']==0
 assert call('idle','false');s=wait(lambda s:s['current'] is not None);assert s['current']['cpu']['usagePct'] is None
 assert call('claim','two','');s=wait(lambda s:s['level']=='summary' and s['current'] is not None);assert s['historyCount']==0 and s['processSampleCount']==0 and s['trendCount']==0
 assert call('claim','bar','');s=wait(lambda s:not s['running']);ticks=s['ticks'];time.sleep(1.2);assert call('state')['ticks']==ticks
 print('PASS multiple consumers, idle reset, summary fallback, last release stops collection',flush=True)
 assert call('root','');assert call('root',str(root/'fake'));assert call('claim','death','detail');wait(lambda s:s['current'] is not None)
finally:
 p.terminate();p.wait(timeout=5);log.close()
time.sleep(.3)
procs=subprocess.check_output(['ps','-eo','pid,args'],text=True).splitlines()
assert not [l for l in procs if str(root/'scripts/sysmon-collect.py') in l],procs
print('PASS collector exits when its owner dies',flush=True)
