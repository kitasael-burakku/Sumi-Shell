import json,os,pathlib,socket,subprocess,tempfile,threading
root=pathlib.Path(tempfile.mkdtemp(prefix='kt-video-'))
script=str(pathlib.Path(__file__).resolve().parents[3] / 'hypr/scripts/wallpaper-video-pause.sh')
values={'sumi-mpvpaper-A.sock':False,'sumi-mpvpaper-B.sock':True}
bad=set();servers=[]
def serve(name,server):
 while True:
  try:c,_=server.accept()
  except OSError:return
  with c:
   request=json.loads(c.recv(65536));cmd=request['command']
   if cmd[0]=='set_property':values[name]=cmd[2]
   c.sendall(b'{"event":"idle"}\n')
   response={'request_id':11,'error':'failure' if name in bad else 'success','data':values[name]}
   c.sendall((json.dumps(response)+'\n').encode())
for name in values:
 server=socket.socket(socket.AF_UNIX);server.bind(str(root/name));server.listen();servers.append(server)
 threading.Thread(target=serve,args=(name,server),daemon=True).start()
def run(*args):return subprocess.run(['bash',script,*args],env=dict(os.environ,XDG_RUNTIME_DIR=str(root)),capture_output=True,text=True,timeout=5)
r=run('status','--json');assert r.returncode==0 and json.loads(r.stdout)==values
snapshot=dict(values);assert run('on').returncode==0 and all(values.values())
assert run('restore',json.dumps(snapshot)).returncode==0 and values==snapshot
bad.add('sumi-mpvpaper-A.sock');assert run('status','--json').returncode!=0
assert run('restore','{"../outside":true}').returncode!=0
for server in servers:server.close()
print('PASS mpv events before reply, per-socket restoration and read errors')
