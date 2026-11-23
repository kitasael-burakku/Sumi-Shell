#!/usr/bin/env python3
"""Muestreo de sólo lectura. Una petición por línea; EOF termina el propietario hijo."""
import json
import os
from pathlib import Path
import re
import sys
import time
import subprocess


def read(path, errors="strict"):
    try:
        return path.read_text(errors=errors).strip()
    except (OSError, UnicodeError):
        return None


def number(path, scale=1):
    try:
        return int(read(path)) / scale
    except (TypeError, ValueError):
        return None


def command_line(path, limit):
    # Leer sólo el prefijo que puede mostrar la vista. Los argv de Linux pueden
    # contener bytes fuera de UTF-8; una letra ilegible no invalida el proceso.
    try:
        with path.open('r', encoding='utf-8', errors='replace', newline='') as stream:
            return stream.read(limit).replace('\0', ' ').strip()
    except OSError:
        return ''


def unescape(s):
    return re.sub(r'\\([0-7]{3})', lambda m: chr(int(m[1], 8)), s)


def rate(value, previous, dt):
    if value is None or previous is None or dt <= 0 or value < previous:
        return None
    return (value - previous) / dt


class Collector:
    def __init__(self, root=''):
        self.root = root
        self.previous = {}
        self.previous_time = None
        self.sequence = 0
        self.hz = os.sysconf('SC_CLK_TCK')
        self.page = os.sysconf('SC_PAGE_SIZE')
        self.clear_detail()

    def clear_detail(self):
        # Sólo la CPU se mide en todos los niveles. Las otras tasas necesitan
        # dos lecturas de la misma apertura, también después de volver de summary.
        for key in ('net', 'disks', 'swapio'):
            self.previous.pop(key, None)
        self.process_previous = {}
        self.process_time = None
        self.process_id = None
        self.inventory = None
        self.inventory_time = -999
        self.mount_signature = None
        # Clases de frecuencia (M1): los sensores se releen cada 2 s, el hardware estático una vez.
        self.sensor_cache = None
        self.sensor_time = -999
        self.users = None
        self.focus_previous = None

    def path(self, name):
        return Path(self.root + name)

    def clock(self):
        if self.root:
            try:
                t = json.loads(read(self.path('/clock.json')))
                return float(t['mono']), float(t['epoch'])
            except (TypeError, ValueError, KeyError):
                pass
        return time.monotonic(), time.time()

    def cpu_counters(self):
        counters = {}
        for line in (read(self.path('/proc/stat')) or '').splitlines():
            p = line.split()
            if not p or not re.fullmatch(r'cpu\d*', p[0]):
                continue
            try:
                # guest y guest_nice ya forman parte de user y nice.
                v = [int(x) for x in p[1:9]]
                if len(v) < 4 or any(x < 0 for x in v):
                    continue
                counters[p[0]] = (sum(v), v[3] + (v[4] if len(v) > 4 else 0))
            except ValueError:
                continue
        return counters

    def cpu(self, detail, inspect=False):
        counters = self.cpu_counters()
        old = self.previous.get('cpu', {})
        def usage(k):
            if k not in counters or k not in old:
                return None
            dt, idle = counters[k][0] - old[k][0], counters[k][1] - old[k][1]
            return max(0, min(100, 100 * (1 - idle / dt))) if dt > 0 and 0 <= idle <= dt else None
        out = {'usagePct': usage('cpu'), 'logicalCount': sum(k != 'cpu' for k in counters) or None,
               'cores': [{'id': k, 'usagePct': usage(k)} for k in counters if k != 'cpu'] if detail else [],
               'temperatureC': None, 'temperatureMaxC': None, 'temperatureCriticalC': None,
               'temperatureSensor': None, 'frequencyMHz': None}
        for h in sorted(self.path('/sys/class/hwmon').glob('hwmon*')):
            if read(h / 'name') in ('k10temp', 'coretemp', 'zenpower'):
                v = number(h / 'temp1_input', 1000)
                if v is not None:
                    out.update(temperatureC=v, temperatureMaxC=number(h / 'temp1_max', 1000),
                               temperatureCriticalC=number(h / 'temp1_crit', 1000),
                               temperatureSensor=read(h / 'temp1_label') or read(h / 'name'))
                    break
        if detail:
            freq = [number(p, 1000) for p in self.path('/sys/devices/system/cpu/cpufreq').glob('policy*/scaling_cur_freq')]
            freq = [v for v in freq if v is not None]
            if freq:
                out['frequencyMHz'] = sum(freq) / len(freq)
                out['frequencyMaxMHz'] = max(freq)
        if inspect:
            for core in out['cores']:
                core['frequencyMHz'] = number(self.path('/sys/devices/system/cpu') / core['id'] / 'cpufreq/scaling_cur_freq', 1000)
        self.previous['cpu'] = counters
        return out

    def memory(self, detail=False, dt=0):
        fields = {}
        for l in (read(self.path('/proc/meminfo')) or '').splitlines():
            m = re.fullmatch(r'(\w+):\s+(\d+)\s+kB', l)
            if m:
                fields[m[1]] = int(m[2]) * 1024
        def group(total, available):
            t, a = fields.get(total), fields.get(available)
            if t is None or a is None or a > t:
                return {'totalB': t, 'availableB': None, 'usedB': None, 'usedPct': None}
            return {'totalB': t, 'availableB': a, 'usedB': t - a, 'usedPct': (t-a)*100/t if t else 0}
        out = group('MemTotal', 'MemAvailable')
        out['swap'] = group('SwapTotal', 'SwapFree')
        out['swap']['present'] = None if fields.get('SwapTotal') is None else fields['SwapTotal'] > 0
        if detail:
            # buff/cache como `free`: Buffers + Cached + SReclaimable. Es reclamable, no «perdida».
            parts = [fields.get(k) for k in ('Buffers', 'Cached', 'SReclaimable')]
            out.update(cacheB=sum(parts) if None not in parts else None, buffersB=fields.get('Buffers'),
                       shmemB=fields.get('Shmem'), dirtyB=fields.get('Dirty'), anonB=fields.get('AnonPages'),
                       pressureSomePct=None, pressureFullPct=None)
            for l in (read(self.path('/proc/pressure/memory')) or '').splitlines():
                m = re.match(r'(some|full) avg10=([\d.]+)', l)
                if m:
                    out['pressure' + m[1].capitalize() + 'Pct'] = float(m[2])
            vm = dict(l.split() for l in (read(self.path('/proc/vmstat')) or '').splitlines() if l.count(' ') == 1)
            counters = []
            for k in ('pswpin', 'pswpout'):
                try:
                    counters.append(int(vm[k]) * self.page)
                except (KeyError, ValueError):
                    counters.append(None)
            old = self.previous.get('swapio', [None, None])
            out['swap'].update(inBps=rate(counters[0], old[0], dt), outBps=rate(counters[1], old[1], dt))
            self.previous['swapio'] = counters
        return out

    def system(self):
        up = (read(self.path('/proc/uptime')) or '').split()
        load = (read(self.path('/proc/loadavg')) or '').split()
        def f(v, i):
            try:
                return float(v[i])
            except (IndexError, ValueError):
                return None
        return {'uptimeS': f(up, 0), 'load1': f(load, 0), 'load5': f(load, 1), 'load15': f(load, 2)}

    def gpus(self):
        out, seen = [], set()
        for card in sorted(self.path('/sys/class/drm').glob('card*')):
            if not re.fullmatch(r'card\d+', card.name) or not (card / 'device').exists():
                continue
            d = card / 'device'
            identity = str(d.resolve())
            if identity in seen:
                continue
            seen.add(identity)
            h = next(iter(sorted((d / 'hwmon').glob('hwmon*'))), d / 'missing')
            driver = (d / 'driver').resolve().name if (d / 'driver').exists() else read(h / 'name')
            name = read(d / 'product_name') or ' '.join(x for x in [driver, read(d / 'vendor'), read(d / 'device')] if x)
            identity = d.resolve().name if re.fullmatch(r'[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]', d.resolve().name) else card.name
            out.append({'id': identity, 'card': card.name, 'name': name or card.name,
                        'driver': driver, 'usagePct': number(d / 'gpu_busy_percent'),
                        'vramUsedB': number(d / 'mem_info_vram_used'), 'vramTotalB': number(d / 'mem_info_vram_total'),
                        'temperatureC': number(h / 'temp1_input', 1000), 'temperatureMaxC': number(h / 'temp1_max', 1000),
                        'temperatureCriticalC': number(h / 'temp1_crit', 1000),
                        'powerW': number(h / 'power1_average', 1e6) if (h / 'power1_average').exists() else number(h / 'power1_input', 1e6),
                        'powerCapW': number(h / 'power1_cap', 1e6),
                        'frequencyMHz': number(h / 'freq1_input', 1e6) if read(h / 'freq1_label') in (None, 'sclk') else None,
                        'fanRpm': number(h / 'fan1_input'), 'processState': 'unavailable',
                        'processReason': 'No reliable GPU process attribution from this driver interface'})
        return out

    def network(self, dt):
        out, counters = [], {}
        for line in (read(self.path('/proc/net/dev')) or '').splitlines():
            if ':' not in line:
                continue
            name, text = line.split(':', 1); name = name.strip()
            d = self.path('/sys/class/net') / name
            try:
                flags = int(read(d / 'flags'), 16)
                values = [int(x) for x in text.split()]
                if name == 'lo' or not flags & 1 or len(values) < 16 or read(d / 'operstate') not in ('up', 'unknown'):
                    continue
            except (TypeError, ValueError):
                continue
            identity = name + ':' + str(read(d / 'ifindex') or '?')
            counters[identity] = [values[0], values[8]]
            old = self.previous.get('net', {}).get(identity, [None, None])
            speed = number(d / 'speed')
            kind = 'wireless' if (d / 'wireless').exists() or (d / 'phy80211').exists() else 'wired' if (d / 'device').exists() else 'virtual'
            out.append({'id': identity, 'name': name, 'state': read(d / 'operstate'), 'kind': kind,
                        'speedMbps': speed if speed is not None and speed > 0 else None,
                        'rxTotalB': values[0], 'txTotalB': values[8],
                        'rxBps': rate(values[0], old[0], dt), 'txBps': rate(values[8], old[1], dt)})
        self.previous['net'] = counters
        def aggregate(k):
            return sum(r[k] for r in out) if out and all(r[k] is not None for r in out) else None
        return {'interfaces': out, 'rxBps': aggregate('rxBps'), 'txBps': aggregate('txBps')}

    def blocks(self, now):
        mounts = read(self.path('/proc/self/mountinfo'))
        if mounts != self.mount_signature or now - self.inventory_time >= 5:
            self.mount_signature, self.inventory_time = mounts, now
            try:
                if self.root:
                    data = json.loads(read(self.path('/lsblk.json')))
                else:
                    p = subprocess.run(['lsblk', '--json', '--bytes', '-o', 'NAME,KNAME,MAJ:MIN,PKNAME,TYPE,LABEL,UUID'],
                                       capture_output=True, text=True, timeout=1, check=True)
                    data = json.loads(p.stdout)
                entries = {}
                def visit(row, ancestors):
                    key = row['maj:min']; name = row['kname']
                    physical = [name] if row['type'] == 'disk' else ancestors
                    e = entries.setdefault(key, dict(row, parents=[]))
                    e['parents'] = sorted(set(e['parents'] + physical))
                    for child in row.get('children', []):
                        visit(child, physical)
                for row in data['blockdevices']:
                    visit(row, [])
                self.inventory = entries
            except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
                self.inventory = None
        return mounts, self.inventory

    def disks(self, now, dt):
        counts = {}
        for l in (read(self.path('/proc/diskstats')) or '').splitlines():
            p = l.split()
            try:
                if len(p) >= 13:
                    counts[p[2]] = [int(p[5]) * 512, int(p[9]) * 512, int(p[12])]
                elif len(p) >= 10:
                    counts[p[2]] = [int(p[5]) * 512, int(p[9]) * 512, None]
            except ValueError:
                pass
        def io(name):
            v = counts.get(name, [None, None, None]); old = self.previous.get('disks', {}).get(name, [None, None, None])
            busy = rate(v[2], old[2], dt)
            # io_ticks en ms por segundo: la fracción del intervalo con E/S en curso.
            return {'readBps': rate(v[0], old[0], dt), 'writeBps': rate(v[1], old[1], dt),
                    'busyPct': min(100, busy / 10) if busy is not None else None}
        mounts, entries = self.blocks(now)
        if mounts is None or entries is None:
            self.previous['disks'] = counts
            return None
        volumes = {}
        for l in mounts.splitlines():
            p = l.split()
            try:
                sep = p.index('-'); dev, mount = p[2], unescape(p[4]); fs, source = p[sep+1:sep+3]
                e = entries.get(dev)
                # Btrfs puede usar un major sintético por subvolumen: resolver por dispositivo.
                if not e and source.startswith('/dev/'):
                    source_name = Path(unescape(source)).name
                    e = next((v for v in entries.values() if v['kname'] == source_name or v['name'] == source_name), None)
                if not e or not e['parents'] or any(x.startswith(('loop', 'ram', 'zram')) for x in e['parents']):
                    continue
                if fs in ('tmpfs', 'devtmpfs', 'overlay', 'squashfs'):
                    continue
                key = fs + ':' + ((e.get('uuid') or dev) if fs == 'btrfs' else e['maj:min'])
                row = volumes.setdefault(key, {'id': key, 'label': e.get('label'), 'device': '/dev/'+e['kname'],
                    'fsType': fs, 'mounts': [], 'parents': [], 'ioDevice': e['kname'],
                    'totalB': None, 'usedB': None, 'availableB': None, 'usedPct': None})
                if mount not in row['mounts']:
                    row['mounts'].append(mount)
                parents = e['parents']
                if fs == 'btrfs' and e.get('uuid'):
                    parents = sorted({p for v in entries.values() if v.get('uuid') == e['uuid'] for p in v['parents']})
                row['parents'] = sorted(set(row['parents'] + parents))
                if row['totalB'] is None:
                    if self.root:
                        sizes = json.loads(read(self.path('/statvfs.json')))[mount]
                        total, free, avail = sizes['totalB'], sizes['freeB'], sizes['availableB']
                    else:
                        v = os.statvfs(mount)
                        total, free, avail = v.f_blocks*v.f_frsize, v.f_bfree*v.f_frsize, v.f_bavail*v.f_frsize
                    row.update(totalB=total, usedB=total-free, availableB=avail,
                               usedPct=(total-free)*100/total if total else None)
            except (ValueError, IndexError, KeyError, TypeError, OSError):
                continue
        groups = {}
        for row in volumes.values():
            row['mounts'].sort()
            row['io'] = io(row['ioDevice']) if len(row['parents']) == 1 else {'readBps': None, 'writeBps': None, 'busyPct': None}
            if len(row['parents']) > 1: row['ioDevice'] = None
            # Un volumen sobre varios discos se muestra una vez, con todos sus propietarios.
            key = '+'.join(row['parents'])
            g = groups.setdefault(key, {'id': key, 'devices': row['parents'], 'volumes': [],
                'io': [{'device': name, **io(name)} for name in row['parents']],
                'temperatureC': self.disk_temperature(row['parents']), 'health': None, 'healthState': 'unchecked'})
            g['volumes'].append(row)
        self.previous['disks'] = counts
        return sorted(groups.values(), key=lambda g: g['id'])

    def disk_temperature(self, devices):
        # NVMe: el hwmon cuelga del controlador (nvme0) y el disco es nvme0n1. Sin sensor, None.
        temps = []
        for d in devices:
            m = re.fullmatch(r'(nvme\d+)n\d+', d)
            if not m:
                continue
            for h in self.path('/sys/class/hwmon').glob('hwmon*'):
                if read(h / 'name') == 'nvme' and (h / 'device').resolve().name == m[1]:
                    v = number(h / 'temp1_input', 1000)
                    if v is not None:
                        temps.append(v)
        return max(temps) if temps else None

    def user_name(self, uid):
        if self.users is None:
            self.users = {}
            for l in (read(self.path('/etc/passwd')) or '').splitlines():
                p = l.split(':')
                if len(p) > 2 and p[2].isdigit():
                    self.users[int(p[2])] = p[0]
        return self.users.get(uid, str(uid))

    def processes(self, now, sample_id, memory, cpu_count, inspect=False):
        # detail: el top para el historial, cada 3 s y acotado. inspect: la lista entera, cada 2 s.
        if self.process_time is not None and now - self.process_time < (2 if inspect else 3):
            return None
        dt = now - self.process_time if self.process_time is not None else 0
        limit, budget = (4096, .25) if inspect else (512, .05)
        rows, previous, scanned, unreadable, truncated = [], {}, 0, 0, False
        started = time.monotonic()
        try:
            with os.scandir(self.path('/proc')) as dirs:
                for entry in dirs:
                    if not entry.name.isdigit():
                        continue
                    if scanned >= limit or time.monotonic() - started > budget:
                        truncated = True; break
                    scanned += 1
                    try:
                        raw = read(Path(entry.path) / 'stat', errors='replace'); end = raw.rindex(')')
                        values = raw[end+2:].split(); name = raw[raw.index('(')+1:end]
                        ticks = int(values[11]) + int(values[12]); start = int(values[19]); rss = int(values[21])*self.page
                        key = entry.name + ':' + str(start); previous[key] = ticks
                        cpu = rate(ticks, self.process_previous.get(key), dt)
                        cpu = cpu * 100/self.hz if cpu is not None else None
                        total = memory.get('totalB')
                        row = {'pid': int(entry.name), 'startTicks': start, 'name': name,
                            'cpuPct': cpu, 'cpuMachinePct': cpu/cpu_count if cpu is not None and cpu_count else None,
                            'memoryB': max(0, rss), 'memoryPct': rss*100/total if total else None}
                        if inspect:
                            cmd = command_line(Path(entry.path) / 'cmdline', 240)
                            # Campo 9 de /proc/PID/stat (flags), PF_KTHREAD de linux/sched.h.
                            kernel = bool(int(values[6]) & 0x00200000)
                            try:
                                uid = os.stat(entry.path).st_uid
                            except OSError:
                                uid = None
                            row.update(key=key, state=values[0], threads=int(values[17]), ppid=int(values[1]),
                                       nice=int(values[16]), cmd=cmd or ('[' + name + ']' if kernel else name), kernel=kernel,
                                       user=self.user_name(uid) if uid is not None else None)
                        rows.append(row)
                    except (AttributeError, ValueError, TypeError, IndexError, OSError):
                        unreadable += 1
        except OSError:
            truncated = True
        self.process_previous, self.process_time, self.process_id = previous, now, sample_id
        out = {'sampleId': sample_id, 'atMonoMs': now*1000, 'intervalMs': dt*1000 if dt else None,
                'state': 'unavailable' if not rows else 'partial' if truncated or unreadable else 'ok', 'scanned': scanned,
                'unreadable': unreadable, 'truncated': truncated, 'limit': limit,
                'cpu': sorted([r for r in rows if r['cpuPct'] is not None], key=lambda r: -r['cpuPct'])[:10],
                'memory': sorted(rows, key=lambda r: -r['memoryB'])[:10],
                'cpuState': 'ok' if dt and previous else 'unavailable',
                'gpuState': 'unavailable', 'gpuReason': 'No reliable GPU process attribution'}
        if inspect:
            # La lista entera viaja aparte: Sysmon sólo guarda la última, nunca en el historial.
            out['all'] = rows
            out['cpu'] = [{k: r[k] for k in ('pid', 'startTicks', 'name', 'cpuPct', 'cpuMachinePct', 'memoryB', 'memoryPct')} for r in out['cpu']]
            out['memory'] = [{k: r[k] for k in ('pid', 'startTicks', 'name', 'cpuPct', 'cpuMachinePct', 'memoryB', 'memoryPct')} for r in out['memory']]
        return out

    def focus(self, request, now):
        # Un proceso elegido en la UI: /proc/PID leído en cada muestra, sólo mientras está elegido.
        try:
            pid, start = int(request['pid']), int(request['startTicks'])
        except (KeyError, TypeError, ValueError):
            self.focus_previous = None
            return None
        base = self.path('/proc') / str(pid)
        raw = read(base / 'stat', errors='replace')
        try:
            end = raw.rindex(')'); values = raw[end+2:].split()
            if int(values[19]) != start:
                raise ValueError
        except (AttributeError, ValueError, IndexError):
            self.focus_previous = None
            return {'pid': pid, 'startTicks': start, 'state': 'gone'}
        status = {}
        for l in (read(base / 'status') or '').splitlines():
            k, _, v = l.partition(':')
            status[k] = v.strip()
        def kb(k):
            try:
                return int(status[k].split()[0]) * 1024
            except (KeyError, ValueError, IndexError):
                return None
        io = {}
        for l in (read(base / 'io') or '').splitlines():
            k, _, v = l.partition(':')
            try:
                io[k] = int(v)
            except ValueError:
                pass
        old = self.focus_previous if self.focus_previous and self.focus_previous[0] == (pid, start) else None
        dt = now - old[1] if old else 0
        read_b, write_b = io.get('read_bytes'), io.get('write_bytes')
        try:
            exe = os.readlink(base / 'exe')
        except OSError:
            exe = None
        try:
            fds = len(os.listdir(base / 'fd'))
        except OSError:
            fds = None
        ppid = int(values[1])
        parent = read(self.path('/proc') / str(ppid) / 'comm')
        uptime = (read(self.path('/proc/uptime')) or '0').split()[0]
        try:
            age = float(uptime) - start / self.hz
        except ValueError:
            age = None
        self.focus_previous = ((pid, start), now, read_b, write_b)
        cmd = command_line(base / 'cmdline', 4000)
        return {'pid': pid, 'startTicks': start, 'state': 'ok', 'runState': values[0], 'ppid': ppid, 'parent': parent,
                'cmd': cmd, 'exe': exe, 'threads': int(values[17]), 'nice': int(values[16]),
                'ageS': age, 'rssB': kb('VmRSS'), 'swapB': kb('VmSwap'), 'fds': fds,
                'ioAvailable': read_b is not None,
                'readBps': rate(read_b, old[2], dt) if old else None, 'writeBps': rate(write_b, old[3], dt) if old else None}

    def sensors(self, now):
        # Clase media: cada 2 s. La ausencia de un chip es falta de soporte, no un error.
        if self.sensor_cache is not None and now - self.sensor_time < 2:
            return self.sensor_cache
        kinds = {'k10temp': 'cpu', 'coretemp': 'cpu', 'zenpower': 'cpu', 'amdgpu': 'gpu', 'nouveau': 'gpu',
                 'nvidia': 'gpu', 'i915': 'gpu', 'xe': 'gpu', 'nvme': 'storage', 'drivetemp': 'storage',
                 'spd5118': 'memory', 'jc42': 'memory', 'acpitz': 'board'}
        chips = []
        for h in sorted(self.path('/sys/class/hwmon').glob('hwmon*'), key=lambda p: int(re.sub(r'\D', '', p.name) or 0)):
            name = read(h / 'name')
            if not name:
                continue
            device = (h / 'device').resolve().name if (h / 'device').exists() else None
            kind = kinds.get(name) or ('board' if re.match(r'(nct|it8|w83|asus|f718)', name) else
                   'network' if re.match(r'(r81|ath|iwl|mt7|igc|e1000)', name) else 'other')
            def group(prefix, scale, value_key):
                rows = []
                files = list(h.glob(prefix + '*_input'))
                if prefix == 'power':
                    have = {f.name.split('_')[0] for f in files}
                    files += [f for f in h.glob('power*_average') if f.name.split('_')[0] not in have]
                for f in sorted(files, key=lambda p: int(re.sub(r'\D', '', p.name.split('_')[0]) or 0)):
                    base = f.name.split('_')[0]
                    v = number(f, scale)
                    if v is None:
                        continue
                    if prefix == 'temp' and not -40 < v < 200:
                        continue
                    r = {'id': name + ':' + (device or h.name) + ':' + base, 'label': read(h / (base + '_label')) or base, value_key: v}
                    if prefix == 'temp':
                        # Un límite fuera de lo físico (NVMe publica 65262 °C) es «sin límite», no un umbral.
                        def limit(f):
                            x = number(h / (base + f), 1000)
                            return x if x is not None and 0 < x < 200 else None
                        r.update(maxC=limit('_max'), critC=limit('_crit'))
                    rows.append(r)
                return rows
            chip = {'id': name + ':' + (device or h.name), 'name': name, 'device': device, 'kind': kind,
                    'temps': group('temp', 1000, 'c'), 'fans': group('fan', 1, 'rpm'),
                    'volts': group('in', 1000, 'v'), 'power': group('power', 1e6, 'w')}
            if chip['temps'] or chip['fans'] or chip['volts'] or chip['power']:
                chips.append(chip)
        self.sensor_cache, self.sensor_time = {'atMonoMs': now * 1000, 'chips': chips}, now
        return self.sensor_cache

    def sample(self, level, focus=None):
        detail, inspect = level in ('detail', 'inspect'), level == 'inspect'
        started = time.monotonic(); now, epoch = self.clock(); self.sequence += 1
        dt = now - self.previous_time if self.previous_time is not None else 0
        cpu, mem = self.cpu(detail, inspect), self.memory(detail, dt)
        out = {'id': self.sequence, 'at': epoch*1000, 'monoMs': now*1000, 'intervalMs': dt*1000 if dt else None,
               'cpu': cpu, 'memory': mem, 'gpus': None, 'network': None, 'disks': None, 'system': None,
               'sensors': None, 'focus': None,
               'processes': None, 'processSampleId': None, 'level': level if detail else 'summary'}
        if detail:
            out.update(gpus=self.gpus(), network=self.network(dt), disks=self.disks(now, dt), system=self.system(),
                       processes=self.processes(now, self.sequence, mem, cpu['logicalCount'], inspect))
            out['processSampleId'] = self.process_id
        if inspect:
            out['sensors'] = self.sensors(now)
            out['focus'] = self.focus(focus, now) if focus else None
        self.previous_time = now
        out['readDurationMs'] = (time.monotonic()-started)*1000
        return out


def main():
    c = Collector(sys.argv[1] if len(sys.argv) > 1 else '')
    # La primera muestra publicada ya puede calcular uso. En aperturas rápidas
    # también dejamos avanzar los contadores. Sólo espera el proceso hijo.
    min_interval = 0.15
    c.previous['cpu'] = c.cpu_counters()
    next_read = time.monotonic() + min_interval
    generation = None
    for line in sys.stdin:
        try:
            request = json.loads(line)
            level = request['level'] if request['level'] in ('summary', 'detail', 'inspect') else 'summary'
            if generation is not None and generation != request['generation']:
                c.clear_detail()
            generation = request['generation']
            remaining = next_read - time.monotonic()
            if remaining > 0:
                time.sleep(remaining)
            next_read = time.monotonic() + min_interval
            sample = c.sample(level, request.get('focus'))
            print(json.dumps({'generation': request['generation'], 'sample': sample}, allow_nan=False), flush=True)
        except (KeyError, ValueError, TypeError) as e:
            print(json.dumps({'error': str(e)}), flush=True)


if __name__ == '__main__':
    main()
