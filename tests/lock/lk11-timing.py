#!/usr/bin/env python3
"""LK-11: tiempo de lock.sh hasta caer a hyprlock, con hyprctl/qs/hyprlock FALSOS (nunca toca la sesión)."""
import json, os, subprocess, sys, tempfile, time
from pathlib import Path
LOCK_SH = Path(sys.argv[1])
MOCK = r'''#!/usr/bin/python3
import json, os, sys, time
from pathlib import Path
root = Path(os.environ['KT_DIR']); cfg = json.loads((root/'config.json').read_text())
name = Path(sys.argv[0]).name; args = sys.argv[1:]
if name == 'hyprctl':
    time.sleep(cfg.get('hyprctl_delay', 0)); print('false')
elif name == 'qs':
    time.sleep(cfg.get('qs_delay', 0)); sys.exit(1)
elif name == 'hyprlock':
    (root/'hyprlock.t').write_text(str(time.monotonic()))
elif name == 'sleep':
    time.sleep(float(args[0]))
'''
def run(label, **cfg):
    with tempfile.TemporaryDirectory() as d:
        root = Path(d); b = root/'bin'; b.mkdir()
        for n in ('hyprctl', 'qs', 'hyprlock', 'sleep', 'logger', 'seq'):
            p = b/n; p.write_text(MOCK); p.chmod(0o755)
        for n in ('bash', 'timeout'): (b/n).symlink_to('/usr/bin/'+n)
        (root/'config.json').write_text(json.dumps(cfg))
        t0 = time.monotonic()
        subprocess.run(['/usr/bin/bash', str(LOCK_SH)], env={**os.environ, 'PATH': str(b), 'KT_DIR': d}, timeout=60)
        t = root/'hyprlock.t'
        print(f"{label:48s} hyprlock a los {float(t.read_text())-t0:5.2f} s" if t.exists() else f"{label}: sin hyprlock")
run('shell ausente (qs sale al momento)')
run('shell colgado (qs no responde)', qs_delay=10)
run('shell colgado y hyprctl colgado', qs_delay=10, hyprctl_delay=5)
