import probe as t
import json
t.fake.joinpath('mode-state.json').unlink(missing_ok=True)
p=None
try:
 p,s=t.start()
 t.setmode('gaming');d=t.backend();d['glass']['enabled']=1;d['video']['sumi-mpvpaper-B.sock']=False
 t.fake.joinpath('backend.json').write_text(json.dumps(d));t.call('check');t.settled();t.setmode('normal')
 d=t.backend();assert d['glass']=={'enabled':1,'blur':1} and d['video']=={'sumi-mpvpaper-A.sock':False,'sumi-mpvpaper-B.sock':False},d
 print('PASS independent manual plugin option and video output',flush=True)
 alternate=dict(t.baseline);alternate.update(blur=False,animations=False,glass={'enabled':0,'blur':0},cursors=False,
     motion={'override':'off','preference':'reduced'},power='balanced',dnd={'on':True,'source':''})
 t.fake.joinpath('backend.json').write_text(json.dumps(alternate))
 for mode in ['focus','gaming','cinema']:
  t.setmode(mode);t.setmode('normal');assert t.backend()==alternate,(mode,t.backend())
 print('PASS non-default blur, plugins, motion, DND source and power restored',flush=True)
 t.setmode('gaming');d=t.backend();d['idle']=False;t.fake.joinpath('backend.json').write_text(json.dumps(d))
 t.call('check');s=t.settled();assert s['state']=='partial' and not s['effects']['idle']['manual'],s
 t.setmode('gaming');assert t.backend()['idle'];t.setmode('normal')
 print('PASS lost idle claim is failure, not manual override; retry reacquires',flush=True)
finally:
 if p is not None:p.terminate();p.wait(timeout=5)
