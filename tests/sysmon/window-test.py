import json,pathlib,subprocess,time
h=pathlib.Path.home();bak=h/'.local/share/kitasan-rediseno-bak/antes-11e1'
def ipc(v,*a):return json.loads(subprocess.check_output(['qs','-c','sumi','ipc','call','sumi',v,*a],text=True))
s=ipc('sysmon','true');assert not s['testing'] and not s['claims']
try:
 assert ipc('sysmonWatch','11e1-window','detail')
 time.sleep(2);initial=ipc('sysmon','true');first=initial['history'][0]['id']
 for n in range(64):
  time.sleep(1)
  if n in [20,40]:print('Real window elapsed',n+3,'s',flush=True)
 s=ipc('sysmon','true');assert 58<=s['historyCount']<=60,s['historyCount'];assert s['processSampleCount']<=21
 assert s['current']==s['history'][-1];assert s['current']['monoMs']-s['oldestMonoMs']<60000
 assert ipc('sysmonSample',first)['sample'] is None
 row=s['history'][-5];q=ipc('sysmonSample',row['id']);assert q['sample']==row
 assert q['processes'] and q['processes']['sampleId']==row['processSampleId']
 (bak/'sysmon-window.json').write_text(json.dumps(s,indent=2))
 print('PASS real 66-second window',s['historyCount'],'samples,',s['processSampleCount'],'process packets; historical attribution exact',flush=True)
finally:
 assert ipc('sysmonWatch','11e1-window','')
 time.sleep(.3)
print('Released:',ipc('sysmon','false')['historyCount'],flush=True)
