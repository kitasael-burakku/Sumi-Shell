import probe as t
import itertools,json

t.fake.joinpath('mode-state.json').unlink(missing_ok=True)
p=None
try:
 p,s=t.start()
 for first,second in itertools.product(['normal','focus','gaming','cinema'],repeat=2):
  t.setmode('normal'); t.fake.joinpath('backend.json').write_text(json.dumps(t.baseline))
  a=t.setmode(first); b=t.setmode(second); assert b['state']=='applied',(first,second,b)
  t.setmode('normal'); assert t.backend()==t.baseline,(first,second,t.backend())
 print('PASS all 16 transitions and exact restoration',flush=True)
 for key in t.baseline:
  t.fake.joinpath('faults.json').write_text(json.dumps({key:'ignore'}))
  s=t.setmode('gaming'); assert s['state']=='partial',(key,s)
  t.fake.joinpath('faults.json').write_text('{}'); t.setmode('normal')
  assert t.backend()==t.baseline,(key,t.backend())
 print('PASS ignored write for every effect',flush=True)
 for key in t.baseline:
  t.fake.joinpath('faults.json').write_text(json.dumps({key:'unavailable'}))
  s=t.setmode('gaming'); assert s['effects'][key]['status']=='unavailable',(key,s)
  t.fake.joinpath('faults.json').write_text('{}'); t.setmode('normal')
  assert t.backend()==t.baseline,(key,t.backend())
 print('PASS each unavailable capability',flush=True)
 # Ya estaba en el valor del modo: un cambio posterior también es manual.
 d=dict(t.baseline);d['dnd']={'on':True,'source':'mode'};t.fake.joinpath('backend.json').write_text(json.dumps(d))
 t.setmode('focus');d=t.backend();d['dnd']={'on':False,'source':'manual'};t.fake.joinpath('backend.json').write_text(json.dumps(d))
 t.call('check');s=t.settled();assert s['effects']['dnd']['status']=='modified',s
 t.setmode('focus');t.setmode('normal');assert t.backend()['dnd']=={'on':False,'source':'manual'}
 print('PASS manual change of initially matching effect',flush=True)
 # Simula lo que el reinicio limpia: la reclamación y el override, no las preferencias.
 t.setmode('gaming');p.kill();p.wait();d=t.backend();d['idle']=False;d['motion']['override']='';t.fake.joinpath('backend.json').write_text(json.dumps(d))
 p,s=t.start();assert s['state']=='applied' and t.backend()['idle'] and t.backend()['motion']['override']=='off',s
 t.setmode('normal');assert not t.backend()['idle'] and t.backend()['motion']['override']==''
 print('PASS ephemeral claims recreated and released after restart',flush=True)
finally:
 if p is not None:p.terminate();p.wait(timeout=5)
