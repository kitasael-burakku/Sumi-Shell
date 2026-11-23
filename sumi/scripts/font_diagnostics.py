#!/usr/bin/env python3
"""Read-only Fontconfig diagnostics. Qt remains the UI inventory authority."""
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent

def normal(s):
    return ' '.join(s.split()).casefold()

def icon_points():
    text = (ROOT / 'lib/icon-catalog.js').read_text()
    block = text.split('var glyphs = Object.freeze(', 1)[1].split('})', 1)[0]
    points = {ord(c) for c in block if 0xE000 <= ord(c) <= 0xF8FF or 0xF0000 <= ord(c) <= 0xFFFFD}
    points.update(int(n, 16) for n in re.findall(r'\\u\{?([0-9a-fA-F]{4,6})\}?', block))
    points.update(int(n, 16) for n in re.findall(r'String.fromCodePoint\(0x([0-9a-fA-F]+)\)', block))
    return sorted(points)

def supports(charset, points):
    spans = [tuple(int(x, 16) for x in part.split('-')) for part in charset.split()]
    return [cp for cp in points if not any(a[0] <= cp <= a[-1] for a in spans)]

def detect():
    catalog = json.loads((ROOT / 'lib/font-catalog.json').read_text())
    points = icon_points()
    try:
        r = subprocess.run(['fc-list', '--format=%{family}\t%{charset}\n'], capture_output=True, text=True, timeout=5)
        if r.returncode:
            raise RuntimeError('fc-list failed')
        rows = [line.split('\t',1) for line in r.stdout.splitlines() if '\t' in line]
        if not rows and r.stdout.strip():
            raise RuntimeError('Fontconfig returned no family/charset records')
        installed = sorted({n.strip() for names,_ in rows for n in names.split(',')})
        coverage=[]; eligible=[]
        for name in catalog['icons']:
            faces = [chars for names,chars in rows if normal(name) in [normal(n) for n in names.split(',')]]
            # Every listed face must cover the map: never infer coverage from a "Nerd" name.
            missing = sorted({cp for face in faces for cp in supports(face,points)})
            ok = bool(faces) and not missing
            coverage.append({'family':name,'faces':len(faces),'covered':len(points)-len(missing) if faces else 0,'total':len(points),'missing':missing if faces else points})
            if ok: eligible.append(name)
        settings = Path(os.environ.get('XDG_CONFIG_HOME', str(Path.home()/'.config'))) / 'sumi-shell/settings.json'
        try:
            selection = json.loads(settings.read_text()).get('theme',{}).get('typography',{})
            if not isinstance(selection, dict) or any(not isinstance(selection.get(key,''), str) for key in ('preset','uiFamily','monoFamily')):
                raise ValueError('Invalid font selection')
            settings_state = 'read'
        except FileNotFoundError:
            selection = {}; settings_state = 'defaults'
        except (OSError,ValueError,AttributeError):
            selection = {}; settings_state = 'unknown'
        preset_id = selection.get('preset','iosevka')
        preset = next((p for p in catalog['presets'] if p['id']==preset_id), None)
        roles = {}
        for role,key in [('ui','uiFamily'),('mono','monoFamily')]:
            requested = [selection[key]] if selection.get(key) else (preset or catalog['presets'][0])[role]
            def match(names):
                return next((n for want in names for n in installed if normal(want)==normal(n)), '')
            found = match(requested)
            roles[role] = {'requested':requested[0], 'selected':found or match(catalog['fallback'][role]) or ('monospace' if role=='mono' else 'sans-serif'),
                           'available':bool(found) and preset is not None}
        return {'state':'available' if eligible else 'unavailable','eligible':eligible,'coverage':coverage,'familyCount':len(installed),
                'iconCount':len(points),'roles':roles,'preset':preset_id,'settings':settings_state,
                'authority':'Fontconfig; Qt inventory and effective names are reported separately by Typography'}
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as e:
        return {'state':'unknown','eligible':[],'coverage':[],'families':[],'error':str(e)}

if __name__ == '__main__':
    print(json.dumps(detect(),ensure_ascii=False,separators=(',',':')))
