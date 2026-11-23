import probe as t
import json,os,time
t.fake.joinpath('mode-state.json').unlink(missing_ok=True)
p=None
try:
 p,s=t.start()
 # No se toca un efecto si el snapshot no puede escribirse.
 t.fake.chmod(0o500)
 before=t.backend();s=t.setmode('gaming');assert s['state']=='error' and t.backend()==before,s
 t.fake.chmod(0o700)
 print('PASS persistence failure prevents writes',flush=True)
 s=t.setmode('gaming');assert s['state']=='applied' and s['activeMode']=='gaming',s
 t.setmode('normal');assert t.backend()==before
 print('PASS retry after identical failed snapshot and restore',flush=True)
 # Un archivo roto impide nuevas peticiones y no se sobrescribe.
 p.terminate();p.wait();t.fake.joinpath('mode-state.json').write_text('{broken')
 log=t.root.joinpath('log').open('a')
 p=t.subprocess.Popen(['qs','-p',str(t.root),'--no-color'],env=t.env,stdout=log,stderr=log)
 for _ in range(50):
  try:
   s=t.call('state')
   if s['state']=='error':break
  except Exception:pass
  time.sleep(.1)
 assert s['state']=='error' and not s['loaded'] and t.call('set','gaming') is False,s
 assert t.fake.joinpath('mode-state.json').read_text()=='{broken'
 print('PASS corrupt record preserved, mode refused',flush=True)
finally:
 t.fake.chmod(0o700)
 if p is not None:p.terminate();p.wait(timeout=5)
