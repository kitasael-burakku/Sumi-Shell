# Sonda aislada de la surface COMPACTA (antes de la fase 12, M4; antes 11E-2): UI real, lecturas
# controladas y servicios de sesión sustituidos. MonitorUi es un sustituto que anota los Details.
import json,os,pathlib,shutil,subprocess,time,importlib.util,sys
sys.dont_write_bytecode=True
source=pathlib.Path(__file__).resolve().parents[2]/'sumi'
root=pathlib.Path('/tmp/sumi-monitor-ui-probe')
for n in ['surfaces','components','theme','services','scripts','lib','runtime','fake']:(root/n).mkdir(parents=True,exist_ok=True)
(root/'runtime').chmod(0o700)
for folder,files in {'surfaces':['System','Surface','SystemCard','SystemGraph'],'components':['ActionButton','Icon','SurfaceHeader','ScrollHint','Claim'],'services':['Sysmon'],'theme':['Typography']}.items():
 for n in files:shutil.copy2(source/folder/(n+'.qml'),root/folder/(n+'.qml'))
 (root/folder/'qmldir').write_text(''.join(('singleton ' if folder in ['services','theme'] else '')+n+' '+n+'.qml\n' for n in files))
shutil.copy2(source/'scripts/sysmon-collect.py',root/'scripts/sysmon-collect.py');shutil.copy2(source/'lib/monitor.js',root/'lib/monitor.js');shutil.copy2(source/'lib/monitor-alerts.js',root/'lib/monitor-alerts.js')
def stub(folder,name,body):
 (root/folder/(name+'.qml')).write_text('pragma Singleton\nimport QtQuick\nQtObject { '+body+' }\n')
 with (root/folder/'qmldir').open('a') as f:f.write('singleton '+name+' '+name+'.qml\n')
stub('services','Session','property bool idle: false')
stub('services','Settings','property real textScale: 1; property string weatherUnits: "celsius"')
stub('services','Operations','property var ops: ({}); function get(id) { return null; } function isLive(r) { return false; } function claim(id,name) {}')
stub('services','PowerProfile','property bool checked: true; property bool present: true; property string current: "balanced"; property string degradation: ""; function refresh() {}')
stub('services','Battery','property bool present: true; property int percent: 65; property bool charging: true; property bool low: false; property var peripherals: [{name:"Controller",percent:42,charging:false}]')
stub('services','Bt','property var all: []')
stub('services','MonitorUi','property var shown: []; function show(n,s) { shown = shown.concat([n + ":" + s]); return true; }')
stub('theme','Metrics','property real sp2: 8; property real sp3: 12; property real focusWidth: 2; property real hair: 1')
stub('theme','Motion','property int vanish: 0; property int standard: 0; property int fast: 0; function enter(c) { return c; }')
colors={'fg':'#f2efff','fgVariant':'#d4ccdf','primary':'#c1b9ff','secondary':'#d0bcee','hair':'#44414c','tileBg':'#24232a','selBg':'#44404e','warn':'#ffdc8e','outline':'#aaa2bb','hoverBg':'#44404e','disabledFg':'#999099','errorColor':'#ff9a9a','tintPrimary':'#c1b9ff','tintPrimarySoft':'#c1b9ff','tintSecondary':'#d0bcee','tintSecondarySoft':'#d0bcee','tintTertiary':'#aaaaff','tintTertiarySoft':'#aaaaff','tintDanger':'#ff9a9a','tintNeutral':'#ccccee'}
stub('theme','Theme','; '.join('property color '+k+': "'+v+'"' for k,v in colors.items()))
spec=importlib.util.spec_from_file_location('fx',source.parent/'tests/sysmon/test-collector.py');fx=importlib.util.module_from_spec(spec);spec.loader.exec_module(fx);fx.fixture(root/'fake')
(root/'shell.qml').write_text('''import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import "surfaces"
import "services"
ShellRoot {
 Window { id: win; width: 800; height: 612; visible: true; color: "#17171d"
  System { id: view; property int closes: 0; screenName: "probe"; s: 1; open: false; closeness: 1; onRequestClose: closes++ }
 }
 Window { visible: false; System { id: second; screenName: "second"; open: false; closeness: 1 } }
 IpcHandler { target: "probe"
  function secondView(on: bool): bool { second.open=on; return true; }
  function state(): string { return JSON.stringify(view.state()); }
  function metrics(): string { return JSON.stringify(Sysmon.summary(true)); }
  function setup(path: string): bool { return Sysmon.setTestRoot(path); }
  function visible(on: bool): bool { view.open=on; return true; }
  function scale(s: real): bool { view.s=s; return true; }
  function size(w: int, h: int): bool { win.width=w; win.height=h; return true; }
  function key(k: int): bool { view.keyPressed({key:k,modifiers:0,accepted:false}); return true; }
  function details(): string { return JSON.stringify({shown: MonitorUi.shown, closes: view.closes}); }
  function poll(): bool { return Sysmon.poll(); }
  function shot(path: string): bool { return win.contentItem.grabToImage(r => r.saveToFile(path)); }
 }
}
''')
env=dict(os.environ,QT_QPA_PLATFORM='offscreen',QT_QPA_PLATFORMTHEME='basic',XDG_RUNTIME_DIR=str(root/'runtime'))
def call(v,*args):
 r=subprocess.run(['qs','-p',str(root),'ipc','call','probe',v,*map(str,args)],env=env,capture_output=True,text=True,timeout=4)
 if r.returncode:raise RuntimeError(r.stderr+r.stdout)
 return json.loads(r.stdout)
def wait(fn,verb='state'):
 end=time.monotonic()+6;s=None
 while time.monotonic()<end:
  try:
   s=call(verb)
   if fn(s):return s
  except (ValueError,RuntimeError):pass
  time.sleep(.04)
 raise AssertionError((s,(root/'log').read_text()[-3000:]))
t=[100]
def step(ticks=None):
 old=call('metrics')['ticks'];t[0]+=1;fx.clock(root/'fake',t[0])
 if ticks is not None:fx.proc(root/'fake',100,ticks)
 end=time.monotonic()+3
 while not call('poll'):
  assert time.monotonic()<end
  time.sleep(.01)
 return wait(lambda s:s['ticks']>old and not s['pending'],'metrics')
def shot(name):
 assert call('shot',root/(name+'.png'));time.sleep(.2);assert (root/(name+'.png')).exists()
UP,DOWN,TAB,RET=0x01000013,0x01000015,0x01000001,0x01000004
log=(root/'log').open('w');p=subprocess.Popen(['qs','-p',str(root),'--no-color'],env=env,stdout=log,stderr=log)
try:
 wait(lambda s:True);assert call('setup',root/'fake');assert call('visible','true');wait(lambda s:s['current'] is not None,'metrics')
 for i in range(4):step(100+i*100)
 st=call('state');ids=[c['id'] for c in st['cards']]
 assert ids[0]=='cpu' and ids[1].startswith('gpu:') and ids[2].startswith('gpu:') and ids[3:]==['memory','network','disks','energy'],ids
 assert [c['section'] for c in st['cards']]==['cpu','gpu','gpu','memory','network','disks','']
 assert all(c['graph'] for c in st['cards'][:-1]) and st['cards'][-1]['graph'] is None
 assert not any('processes' in c for c in st['cards']);disks=st['cards'][5];assert disks['volumes']>=1,disks
 print('PASS compact cards: two GPUs, one Disks card with volumes, micrographs, no processes/cores',flush=True)
 assert call('key',RET);d=call('details');assert d['shown']==['probe:cpu'] and d['closes']==1,d
 assert call('key',DOWN);assert call('state')['card']==ids[2];assert call('key',UP);assert call('state')['card']=='cpu'
 for _ in range(len(ids)):
  if call('state')['card']=='inspect':break
  assert call('key',TAB)
 assert call('state')['card']=='inspect';assert call('key',RET);assert call('details')['shown'][-1]=='probe:overview'
 print('PASS Enter = Details in its section (surface asks to close); arrows move by row; Tab reaches Inspect',flush=True)
 shot('compact-wide');st=call('state');assert st['columns']==2 and st['contentHeight']>st['viewHeight'],'seven cards scroll'
 assert call('size',600,640);time.sleep(.2);assert call('state')['columns']==1;shot('compact-narrow')
 assert call('scale',1.25);time.sleep(.1);assert call('state')['columns']==1;shot('compact-narrow-125')
 assert call('scale',1);assert call('size',800,612);assert call('state')['columns']==2
 energy=[c for c in call('state')['cards'] if c['id']=='energy'][0];assert energy['headline']=='balanced'
 # temperatura sostenida (límite del sensor 95 °C): aviso en la tarjeta sólo tras 10 s
 fx.put(root/'fake','sys/class/hwmon/hwmon0/temp1_input',99000)
 for _ in range(5):step()
 assert not call('state')['cards'][0]['warning']
 for _ in range(6):step()
 assert call('state')['cards'][0]['warning'];shot('compact-hot')
 fx.put(root/'fake','sys/class/hwmon/hwmon0/temp1_input',45000);step();assert not call('state')['cards'][0]['warning']
 print('PASS 800/600 px and scale 1.25 layouts; sustained temperature marks the card, a short spike does not',flush=True)
 gpu=ids[1];assert call('key',DOWN) or True
 shutil.rmtree(root/'fake/sys/class/drm/card0');step();st=call('state');assert all(c['id']!=gpu for c in st['cards']) and len(st['cards'])==6
 assert st['contentHeight']<=st['viewHeight']+1,('six cards fit without scrolling',st['contentHeight'],st['viewHeight'])
 assert call('secondView','true');assert call('visible','false');s=call('metrics');assert s['level']=='detail' and s['historyCount']>0
 assert call('secondView','false');s=wait(lambda s:not s['running'],'metrics');assert s['historyCount']==0 and s['trendCount']==0
 empty=root/'empty';empty.mkdir(exist_ok=True);assert call('setup',empty);assert call('visible','true');wait(lambda s:s['current'] is not None,'metrics')
 st=call('state');assert st['cards'][0]['headline']=='No data' and st['cards'][1]['id']=='gpu:none';shot('compact-missing')
 print('PASS GPU removal, two views share / last releases, missing data stays No data',flush=True)
finally:
 p.terminate();p.wait(timeout=5);log.close()
text=(root/'log').read_text();assert not any(x in text for x in ['ReferenceError','TypeError','Binding loop','Unable to assign','Failed to load']),text
print('PASS clean QML log',flush=True)
