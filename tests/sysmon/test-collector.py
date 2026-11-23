import importlib.util,json,pathlib,tempfile,unittest
SOURCE=pathlib.Path(__file__).resolve().parents[2]/'sumi/scripts/sysmon-collect.py'
spec=importlib.util.spec_from_file_location('collector',SOURCE);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

def put(root,name,text):
 p=root/name.lstrip('/');p.parent.mkdir(parents=True,exist_ok=True);p.write_text(str(text))
def fixture(root):
 put(root,'clock.json',json.dumps({'mono':100,'epoch':1000}))
 put(root,'proc/stat','cpu 100 0 100 800 0 0 0 0 50 0\ncpu0 50 0 50 400 0 0 0 0 25 0\ncpu1 50 0 50 400 0 0 0 0 25 0')
 put(root,'proc/meminfo','MemTotal: 100000 kB\nMemAvailable: 40000 kB\nSwapTotal: 10000 kB\nSwapFree: 8000 kB')
 put(root,'proc/net/dev','eth0: 1000 0 0 0 0 0 0 0 2000 0 0 0 0 0 0 0\nlo: 999 0 0 0 0 0 0 0 999 0 0 0 0 0 0 0')
 for k,v in [('flags','0x1003'),('ifindex',2),('operstate','up')]:put(root,'sys/class/net/eth0/'+k,v)
 for k,v in [('name','k10temp'),('temp1_input',45000),('temp1_crit',95000)]:put(root,'sys/class/hwmon/hwmon0/'+k,v)
 for i in range(2):
  p=f'sys/class/drm/card{i}/device/'
  for k,v in [('gpu_busy_percent',20+i*10),('mem_info_vram_used',1024),('mem_info_vram_total',8192),('hwmon/hwmon0/name','amdgpu'),('hwmon/hwmon0/temp1_input',55000)]:put(root,p+k,v)
 put(root,'proc/self/mountinfo','1 0 8:1 / / rw - ext4 /dev/sda1 rw\n2 1 8:1 /home /home rw - ext4 /dev/sda1 rw\n3 1 0:2 / /tmp rw - tmpfs tmpfs rw')
 put(root,'lsblk.json',json.dumps({'blockdevices':[{'name':'sda','kname':'sda','maj:min':'8:0','type':'disk','children':[{'name':'sda1','kname':'sda1','maj:min':'8:1','type':'part','uuid':'same','label':'System'}]}, {'name':'sdb','kname':'sdb','maj:min':'8:16','type':'disk','children':[{'name':'sdb1','kname':'sdb1','maj:min':'8:17','type':'part','uuid':'same','label':'Data'}]}]}))
 put(root,'statvfs.json',json.dumps({p:{'totalB':10000,'freeB':5000,'availableB':4000} for p in ['/','/home','/mnt/test']}))
 put(root,'proc/diskstats','8 0 sda 0 0 100 0 0 0 200 0\n8 1 sda1 0 0 100 0 0 0 200 0\n8 16 sdb 0 0 50 0 0 0 10 0\n8 17 sdb1 0 0 50 0 0 0 10 0')
 proc(root,100,10)
def proc(root,pid,ticks,start=1):
 values=['S']+['0']*21;values[11]=str(ticks);values[19]=str(start);values[21]='100'
 put(root,f'proc/{pid}/stat',str(pid)+' (a tricky ) name) '+' '.join(values))
def clock(root,mono):put(root,'clock.json',json.dumps({'mono':mono,'epoch':900+mono}))

class Test(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.tmp.name);fixture(self.root);self.c=m.Collector(str(self.root))
 def tearDown(self):self.tmp.cleanup()
 def test_rates_and_missing(self):
  s=self.c.sample('detail');self.assertIsNone(s['cpu']['usagePct']);self.assertIsNone(s['network']['rxBps']);self.assertEqual(len(s['gpus']),2)
  self.assertEqual(s['memory']['swap']['usedB'],2048000);self.assertIsNone(s['gpus'][0]['fanRpm'])
  put(self.root,'proc/stat','cpu 120 0 120 860 0 0 0 0 70 0\ncpu0 60 0 60 430 0 0 0 0 35 0\ncpu1 60 0 60 430 0 0 0 0 35 0')
  put(self.root,'proc/net/dev','eth0: 2000 0 0 0 0 0 0 0 4000 0 0 0 0 0 0 0')
  put(self.root,'proc/diskstats','8 0 sda 0 0 102 0 0 0 204 0\n8 1 sda1 0 0 102 0 0 0 204 0')
  clock(self.root,101);s=self.c.sample('detail')
  self.assertEqual(s['cpu']['usagePct'],40);self.assertEqual(s['cpu']['cores'][0]['usagePct'],40)
  self.assertEqual(s['network']['rxBps'],1000);self.assertEqual(s['disks'][0]['io'][0]['readBps'],1024)
  put(self.root,'proc/net/dev','eth0: 2 0 0 0 0 0 0 0 4 0 0 0 0 0 0 0');clock(self.root,102);s=self.c.sample('detail');self.assertIsNone(s['network']['rxBps'])
  (self.root/'proc/meminfo').unlink();(self.root/'sys/class/drm/card0/device/gpu_busy_percent').unlink();(self.root/'proc/stat').unlink()
  s=self.c.sample('detail');self.assertIsNone(s['memory']['usedB']);self.assertIsNone(s['cpu']['usagePct']);self.assertIsNone(s['gpus'][0]['usagePct'])
 def test_mounts_and_failures(self):
  s=self.c.sample('detail');v=s['disks'][0]['volumes'];self.assertEqual(len(v),1);self.assertEqual(v[0]['mounts'],['/','/home']);self.assertEqual(v[0]['availableB'],4000)
  mounts=self.root/'proc/self/mountinfo';original=mounts.read_text();mounts.write_text(original+'\n4 1 8:17 / /mnt/test rw - ext4 /dev/sdb1 rw');clock(self.root,101)
  s=self.c.sample('detail');self.assertEqual(len(s['disks']),2)
  mounts.write_text(original);clock(self.root,102);s=self.c.sample('detail');self.assertEqual(len(s['disks']),1)
  put(self.root,'lsblk.json','broken');clock(self.root,108);self.assertIsNone(self.c.sample('detail')['disks'])
 def test_process_history_bounds(self):
  a=self.c.sample('detail');self.assertEqual(a['processes']['memory'][0]['name'],'a tricky ) name');self.assertEqual(a['processes']['cpu'],[])
  clock(self.root,101);self.assertIsNone(self.c.sample('detail')['processes'])
  proc(self.root,100,310);clock(self.root,103);b=self.c.sample('detail');self.assertAlmostEqual(b['processes']['cpu'][0]['cpuPct'],100);self.assertEqual(a['processes']['cpu'],[])
  proc(self.root,100,900,start=2);clock(self.root,106);self.assertEqual(self.c.sample('detail')['processes']['cpu'],[])
  for i in range(101,630):proc(self.root,i,10)
  clock(self.root,109);s=self.c.sample('detail');self.assertLessEqual(s['processes']['scanned'],512);self.assertTrue(s['processes']['truncated']);self.assertLessEqual(len(s['processes']['memory']),10)
 def test_inspect_process_identity_and_command(self):
  # Linux permite argv con bytes fuera de UTF-8 y procesos de usuario sin cmdline.
  proc(self.root, 101, 10)
  proc(self.root, 102, 10)
  kstat = self.root/'proc/102/stat'
  name, fields = kstat.read_text().rsplit(')', 1)
  values = fields.split()
  values[6] = str(0x00200000)
  kstat.write_text(name + ') ' + ' '.join(values))
  cmdline = self.root/'proc/100/cmdline'
  cmdline.write_bytes(b'editor\x00archivo-\xff\x00' + b'x' * 50000)
  proc_stat = self.root/'proc/100/stat'
  proc_stat.write_bytes(proc_stat.read_bytes().replace(b'tricky', b'tricky-\xff'))
  sample = self.c.sample('inspect', {'pid': 100, 'startTicks': 1})
  rows = {r['pid']: r for r in sample['processes']['all']}
  self.assertFalse(rows[100]['kernel'])
  self.assertFalse(rows[101]['kernel'])
  self.assertTrue(rows[102]['kernel'])
  self.assertIn('tricky-�', rows[100]['name'])
  self.assertTrue(rows[100]['cmd'].startswith('editor archivo-� '))
  self.assertEqual(len(rows[100]['cmd']), 240)
  self.assertEqual(len(sample['focus']['cmd']), 4000)
  self.assertTrue(sample['focus']['cmd'].startswith(rows[100]['cmd']))

 def test_summary(self):
  s=self.c.sample('summary')
  for key in ['gpus','disks','network','processes','processSampleId']:self.assertIsNone(s[key])
  self.assertEqual(s['cpu']['cores'],[]);self.assertIsNone(self.c.process_time);self.assertIsNone(self.c.inventory)

 def test_multidisk_and_hotplug(self):
  (self.root/'sys/class/drm/card9').symlink_to(self.root/'sys/class/drm/card0',target_is_directory=True)
  self.assertEqual(len(self.c.sample('detail')['gpus']),2)
  import shutil
  shutil.rmtree(self.root/'sys/class/drm/card1');self.assertEqual(len(self.c.sample('detail')['gpus']),1)
  put(self.root,'sys/class/net/eth0/operstate','down');self.assertEqual(self.c.sample('detail')['network']['interfaces'],[])
  put(self.root,'proc/self/mountinfo','1 0 0:50 / / rw - btrfs /dev/sda1 rw\n2 1 0:51 /home /home rw - btrfs /dev/sda1 rw')
  s=self.c.sample('detail');self.assertEqual(len(s['disks']),1);self.assertEqual(s['disks'][0]['devices'],['sda','sdb'])
  v=s['disks'][0]['volumes'];self.assertEqual(len(v),1);self.assertEqual(v[0]['mounts'],['/','/home']);self.assertIsNone(v[0]['io']['readBps'])

 def test_inspect_level(self):
  # M1: lista entera con orden, usuario y comando; sensores agrupados; proceso elegido.
  put(self.root,'proc/100/cmdline','/usr/bin/tricky\0--flag\0');put(self.root,'proc/uptime','50.00 90.00')
  put(self.root,'proc/100/status','Name:\ttricky\nVmRSS:\t   400 kB\nVmSwap:\t  8 kB\n');put(self.root,'proc/100/io','read_bytes: 1000\nwrite_bytes: 0\n')
  put(self.root,'etc/passwd','root:x:0:0::/root:/bin/sh\n')
  for k,v in [('fan1_input',1200),('fan2_input',0),('in0_input',1350),('in0_label','Vcore')]:put(self.root,'sys/class/hwmon/hwmon1/'+k,v)
  put(self.root,'sys/class/hwmon/hwmon1/name','nct6687')
  put(self.root,'proc/meminfo','MemTotal: 100000 kB\nMemAvailable: 40000 kB\nBuffers: 1000 kB\nCached: 20000 kB\nSReclaimable: 3000 kB\nShmem: 500 kB\nSwapTotal: 10000 kB\nSwapFree: 8000 kB')
  put(self.root,'proc/vmstat','pswpin 10\npswpout 20')
  for k,v in [('name','nvme'),('temp1_input',42850),('temp1_max',88850),('temp2_input',48850),('temp2_max',65261850),('temp3_input',250000)]:put(self.root,'sys/class/hwmon/hwmon2/'+k,v)
  s=self.c.sample('inspect',{'pid':100,'startTicks':1})
  nv=[c for c in s['sensors']['chips'] if c['name']=='nvme'][0]['temps'];self.assertEqual([t['maxC'] for t in nv],[88.85,None])
  a=s['processes']['all'];self.assertEqual(len(a),1);r=a[0]
  self.assertEqual(r['cmd'],'/usr/bin/tricky --flag');self.assertFalse(r['kernel']);self.assertEqual(r['key'],'100:1');self.assertIsNotNone(r['user'])
  self.assertNotIn('cmd',s['processes']['memory'][0])
  chips={c['name']:c for c in s['sensors']['chips']};self.assertEqual(chips['k10temp']['kind'],'cpu');self.assertEqual(chips['nct6687']['kind'],'board')
  self.assertEqual([f['rpm'] for f in chips['nct6687']['fans']],[1200,0]);self.assertEqual(chips['nct6687']['volts'][0]['label'],'Vcore');self.assertAlmostEqual(chips['nct6687']['volts'][0]['v'],1.35)
  self.assertEqual(s['memory']['cacheB'],24000*1024);self.assertIsNone(s['memory']['swap']['inBps'])
  f=s['focus'];self.assertEqual(f['state'],'ok');self.assertEqual(f['cmd'],'/usr/bin/tricky --flag');self.assertEqual(f['rssB'],400*1024);self.assertIsNone(f['readBps'])
  self.assertEqual(s['system']['uptimeS'],50.0)
  put(self.root,'proc/100/io','read_bytes: 3000\nwrite_bytes: 0\n');put(self.root,'proc/vmstat','pswpin 12\npswpout 20');clock(self.root,102)
  s=self.c.sample('inspect',{'pid':100,'startTicks':1});self.assertEqual(s['focus']['readBps'],1000);self.assertIsNotNone(s['memory']['swap']['inBps'])
  self.assertIsNotNone(s['processes']['all'][0]['cpuPct'])
  # Clase media: los sensores no se releen antes de 2 s.
  put(self.root,'sys/class/hwmon/hwmon1/fan1_input',900);clock(self.root,103);s=self.c.sample('inspect',None)
  self.assertEqual({c['name']:c for c in s['sensors']['chips']}['nct6687']['fans'][0]['rpm'],1200);self.assertIsNone(s['focus'])
  self.assertIsNone(s['processes'])
  clock(self.root,105);s=self.c.sample('inspect',{'pid':100,'startTicks':7})
  self.assertEqual({c['name']:c for c in s['sensors']['chips']}['nct6687']['fans'][0]['rpm'],900);self.assertEqual(s['focus']['state'],'gone')
  # detail no lleva lista entera, sensores ni foco.
  clock(self.root,110);s=self.c.sample('detail',{'pid':100,'startTicks':1})
  self.assertNotIn('all',s['processes']);self.assertIsNone(s['sensors']);self.assertIsNone(s['focus'])
 def test_disk_busy_and_nvme_temperature(self):
  put(self.root,'proc/self/mountinfo','1 0 259:1 / / rw - ext4 /dev/nvme0n1p1 rw')
  put(self.root,'lsblk.json',json.dumps({'blockdevices':[{'name':'nvme0n1','kname':'nvme0n1','maj:min':'259:0','type':'disk','children':[{'name':'nvme0n1p1','kname':'nvme0n1p1','maj:min':'259:1','type':'part','uuid':'u'}]}]}))
  put(self.root,'proc/diskstats','259 0 nvme0n1 0 0 100 0 0 0 200 0 0 1000 0\n259 1 nvme0n1p1 0 0 100 0 0 0 200 0 0 1000 0')
  for k,v in [('name','nvme'),('temp1_input',48850)]:put(self.root,'sys/class/hwmon/hwmon5/'+k,v)
  (self.root/'sys/class/nvme/nvme0').mkdir(parents=True);(self.root/'sys/class/hwmon/hwmon5/device').symlink_to(self.root/'sys/class/nvme/nvme0',target_is_directory=True)
  s=self.c.sample('detail');self.assertEqual(s['disks'][0]['temperatureC'],48.85);self.assertIsNone(s['disks'][0]['io'][0]['busyPct'])
  put(self.root,'proc/diskstats','259 0 nvme0n1 0 0 100 0 0 0 200 0 0 1500 0\n259 1 nvme0n1p1 0 0 100 0 0 0 200 0 0 1500 0');clock(self.root,101)
  s=self.c.sample('detail');self.assertEqual(s['disks'][0]['io'][0]['busyPct'],50)

if __name__=='__main__':unittest.main()
