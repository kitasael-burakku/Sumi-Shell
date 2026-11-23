import sys
sys.dont_write_bytecode = True
# Sólo se ejecuta en un namespace de montajes privado, sin modificar los montajes de la sesión.
import importlib.util,os,pathlib,subprocess,tempfile,time
p=pathlib.Path(__file__).resolve().parents[2]/'sumi/scripts/sysmon-collect.py'
spec=importlib.util.spec_from_file_location('collector',p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
# Exigir root mapeado desde un usuario normal: jamás ejecutar en el namespace privilegiado.
mapping=pathlib.Path('/proc/self/uid_map').read_text().split()
assert len(mapping)==3 and mapping[0]=='0' and int(mapping[1])>0 and mapping[2]=='1', 'Run through unshare --user --map-root-user --mount'
subprocess.run(['mount','--make-rprivate','/'],check=True)
c=m.Collector();before=c.sample(True);assert before['disks']
def rows(s):return [v for d in s['disks'] for v in d['volumes']]
with tempfile.TemporaryDirectory(prefix='sumi-11e1-mount-') as t:
 mounted=False
 try:
  subprocess.run(['mount','--bind',str(pathlib.Path.home()/'Projects/Quickshell'),t],check=True);mounted=True
  subprocess.run(['mount','-o','remount,bind,ro',t],check=True)
  during=c.sample(True);assert len(rows(before))==len(rows(during))
  v=next(v for v in rows(during) if '/' in v['mounts']);assert t in v['mounts']
  subprocess.run(['umount',t],check=True);mounted=False
  after=c.sample(True);assert all(t not in v['mounts'] for v in rows(after))
  print('PASS real read-only bind mount / unmount in private namespace; no duplicate capacity')
  print('Disks',[(d['id'],[(v['device'],v['mounts']) for v in d['volumes']]) for d in after['disks']])
 finally:
  if mounted:subprocess.run(['umount',t],check=True)
