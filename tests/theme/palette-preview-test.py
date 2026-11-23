#!/usr/bin/env python3
"""Paletas estáticas F-b: el perfil `preset:<id>` de theme-preview.py y `theme-provider.py preset`, con árbol falso.

    python3 -B tests/theme/palette-preview-test.py [ÁRBOL] [-v]

Todo en un HOME/XDG temporal: config de matugen PROPIA de la prueba (kitty, GTK, un JSON y la shell; un post_hook que
sólo deja una marca), gsettings falso, matugen real siempre con esa config (-c) y un matugen FALSO lento para la
carrera con `reload`. Nunca toca el escritorio, la config de matugen ni el estado reales.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest

TREE = Path(sys.argv.pop(1)) if len(sys.argv) > 1 and not sys.argv[1].startswith('-') \
    else Path(__file__).resolve().parents[2] / 'sumi'
HELPER = TREE / 'scripts/theme-preview.py'
TP = Path(os.environ.get('KT_TEST_TP') or TREE / 'scripts/theme-provider.py')
MATUGEN = shutil.which('matugen')
sys.dont_write_bytecode = True
sys.path.insert(0, str(TREE / 'scripts'))
import palette_presets as PP  # noqa: E402

FAKE_GS = '''#!/usr/bin/env python3
import json, os, sys
db = os.environ['TEST_GS_DB']
d = json.load(open(db)) if os.path.exists(db) else {'color-scheme': 'default', 'gtk-theme': 'Adwaita-dark'}
if sys.argv[1] == 'get':
    print("'%s'" % d[sys.argv[3]])
elif sys.argv[1] == 'set':
    d[sys.argv[3]] = sys.argv[4]
    json.dump(d, open(db, 'w'))
'''
# Un matugen falso y LENTO: escribe «dynamic» en la salida de la shell de su config (como un reload de un fondo nuevo)
SLOW_MATUGEN = '''#!/usr/bin/env python3
import os, sys, time, tomllib
cfg = tomllib.load(open(sys.argv[sys.argv.index('--config') + 1], 'rb'))
open(os.environ['TEST_REACHED'], 'w').close()
time.sleep(float(os.environ.get('TEST_SLOW', '1.5')))
o = cfg['templates']['sumi_shell']['output_path']
open(o, 'w').write('{"surface": "#00ff00", "_dynamic": "slow reload"}\\n')
'''
KITTY_TPL = '''# kitty de prueba
background {{colors.background.default.hex}}
foreground {{colors.on_surface.default.hex}}
cursor {{colors.on_surface.default.hex}}
<* if {{ is_dark_mode }} *>
color0 {{colors.surface_container.default.hex}}
<* else *>
color0 {{colors.inverse_surface.default.hex}}
<* endif *>
color1 {{colors.error.default.hex}}
color4 {{colors.primary.default.hex | set_hue: 215}}
color16 #c0a878
'''
GTK_TPL = '@define-color window_bg_color {{colors.surface.default.hex}};\n@define-color accent_color {{colors.primary.default.hex}};\n'
MALY_TPL = '{"accent": "{{colors.tertiary.default.hex}}", "dark": <* if {{ is_dark_mode }} *>true<* else *>false<* endif *>}\n'


def sha(p):
    try:
        return hashlib.sha256(Path(p).read_bytes()).hexdigest()
    except OSError:
        return None


class Bench(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='kt-pv-')
        self.addCleanup(self.tmp.cleanup)
        R = self.R = Path(self.tmp.name)
        self.home, self.state, self.run_dir = R / 'home', R / 'state', R / 'run'
        for d in (self.home / '.config/kitty/colors', self.home / '.config/gtk-4.0', self.home / '.config/app',
                  self.state / 'sumi-shell/theme', self.run_dir, R / 'tpl', R / 'bin'):
            d.mkdir(parents=True, exist_ok=True)
        self.run_dir.chmod(0o700)
        (R / 'tpl/kitty.conf').write_text(KITTY_TPL)
        (R / 'tpl/gtk.css').write_text(GTK_TPL)
        (R / 'tpl/app.json').write_text(MALY_TPL)
        self.kitty = self.home / '.config/kitty/colors/colors.conf'
        self.gtk = self.home / '.config/gtk-4.0/gtk-colors.css'
        self.app = self.home / '.config/app/theme.json'
        self.colors = self.state / 'sumi-shell/colors.json'
        self.marks = R / 'hooks.log'
        self.cfg = R / 'config.toml'
        self.cfg.write_text('\n'.join([
            '[config]', 'prefer = "saturation"', '',
            '[templates.kitty]', 'input_path = "%s"' % (R / 'tpl/kitty.conf'), "output_path = '~/.config/kitty/colors/colors.conf'",
            'post_hook = "echo kitty >> %s"' % self.marks, '',
            '[templates.gtk4]', 'input_path = "%s"' % (R / 'tpl/gtk.css'), "output_path = '~/.config/gtk-4.0/gtk-colors.css'", '',
            '[templates.app]', 'input_path = "%s"' % (R / 'tpl/app.json'), "output_path = '~/.config/app/theme.json'", '',
            '[templates.sumi_shell]', 'input_path = "%s"' % (TREE / 'templates/matugen-colors.json'),
            "output_path = '~/.local/state/sumi-shell/colors.json'", '']))
        # lo de antes: unos colores «dinámicos» viejos en cada salida
        self.kitty.write_text('background #101010\ncolor0 #202020\ncolor16 #c0a878\n')
        self.gtk.write_text('@define-color window_bg_color #101010;\n')
        self.app.write_text('{"accent": "#123456", "dark": true}\n')
        self.colors.write_text((TREE / 'colors.static.json').read_text())
        gs = R / 'bin/gsettings'
        gs.write_text(FAKE_GS)
        gs.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home), XDG_STATE_HOME=str(self.state), XDG_RUNTIME_DIR=str(self.run_dir),
                        XDG_CONFIG_HOME=str(self.home / '.config'), XDG_CACHE_HOME=str(R / 'cache'),
                        MATUGEN_CONFIG=str(self.cfg), KT_GSETTINGS=str(gs), TEST_GS_DB=str(R / 'gs.json'),
                        KT_DESKTOP_SYNC='off', KT_XSETTINGS_CONFIG='', KT_HOOK_TIMEOUT='5', PYTHONDONTWRITEBYTECODE='1')
        for k in ('KT_STATIC_LIST_ARGV', 'KT_STATIC_LIST', 'MATUGEN_BIN', 'KT_PALETTES_DIR', 'MATUGEN_SENTINEL',
                  'MATUGEN_SCHEME_FILE', 'MATUGEN_PRESET_FILE', 'KT_WALL_STATE'):
            self.env.pop(k, None)
        self.snap = str(self.state / 'sumi-shell/theme-preview')
        self.theme = self.state / 'sumi-shell/theme'

    # ---- ayudas --------------------------------------------------------------------------------------------
    def helper(self, *args, env=None, ok=True):
        r = subprocess.run([sys.executable, '-B', str(HELPER)] + list(args), capture_output=True, text=True,
                           env=env or self.env, timeout=120)
        res = json.loads(r.stdout.strip().splitlines()[-1]) if r.stdout.strip() else {'ok': False, 'stderr': r.stderr}
        if ok is not None:
            self.assertEqual(res.get('ok'), ok, (args, res, r.stderr[-400:]))
        return res

    def tp(self, *args, env=None, rc=0):
        r = subprocess.run([sys.executable, '-B', str(TP), '--config', str(self.cfg)] + list(args), capture_output=True,
                           text=True, env=env or self.env, timeout=180)
        if rc is not None:
            self.assertEqual(r.returncode, rc, (args, r.stdout, r.stderr))
        return r

    def preview(self, profile, work='w1', **kw):
        w = str(self.R / work)
        st = self.helper('stage', '--work', w, '--profile', profile, *sum(([('--' + k), v] for k, v in kw.items()), []))
        self.helper('snapshot', '--snap', self.snap)
        inst = self.helper('install', '--work', w, '--snap', self.snap)
        return st, inst

    def outputs(self):
        return {p: sha(p) for p in (self.kitty, self.gtk, self.app, self.colors)}

    def preset_file(self):
        p = self.theme / 'preset'
        return p.read_text().strip() if p.exists() else ''

    def expect_preset(self, pid):
        d = PP.load(pid)
        shell = json.loads(self.colors.read_text())
        for k in ('surface', 'primary', 'on_surface', 'tertiary_fixed'):
            self.assertEqual(shell[k], d['roles'][k], (pid, k))
        kitty = self.kitty.read_text()
        for k in ('background', 'foreground', 'cursor', 'color0', 'color1', 'color4', 'color15'):
            self.assertIn('%s %s' % (k, d['terminal'][k]), kitty, (pid, k))
        self.assertIn('color16 #c0a878', kitty)                       # lo propio de la plantilla, intacto
        self.assertIn(d['roles']['surface'], self.gtk.read_text())
        app = json.loads(self.app.read_text())
        self.assertEqual(app, {'accent': d['roles']['tertiary'], 'dark': d['dark']})


@unittest.skipUnless(MATUGEN, 'matugen is not installed')
class PresetPreview(Bench):
    def test_stage_install_keep(self):
        st, inst = self.preview('preset:catppuccin-mocha')
        self.assertEqual((st['renderer'], st['entries'], st['substituted']), ('matugen', 4, ['kitty']))
        self.expect_preset('catppuccin-mocha')
        self.assertEqual(self.marks.read_text().split(), ['kitty'])   # los post_hook del preset = los de la config
        self.assertEqual(self.preset_file(), '')                        # la preview no persiste nada
        k = self.helper('keep', '--snap', self.snap, '--profile', 'preset:catppuccin-mocha')
        self.assertEqual(k['mode'], 'preset')
        self.assertEqual(self.preset_file(), 'catppuccin-mocha')
        self.assertFalse((self.theme / 'enabled').exists())
        self.assertFalse(os.path.exists(self.snap))
        self.assertEqual(self.helper('status', '--snap', self.snap)['persisted']['preset'], 'catppuccin-mocha')

    def test_revert_is_byte_exact(self):
        (self.theme / 'enabled').write_text('')
        before = self.outputs()
        self.preview('preset:gruvbox-light')
        self.expect_preset('gruvbox-light')
        r = self.helper('restore', '--snap', self.snap)
        self.assertEqual(len(r['restored']), 4)
        self.assertEqual(self.outputs(), before)
        self.assertTrue((self.theme / 'enabled').exists())
        self.assertEqual(self.preset_file(), '')

    def test_light_preset_desktop_follows_its_mode(self):
        env = dict(self.env, KT_DESKTOP_SYNC='colorScheme')
        w = str(self.R / 'w')
        self.helper('stage', '--work', w, '--profile', 'preset:catppuccin-latte', env=env)
        man = json.loads(Path(w, 'manifest.json').read_text())
        self.assertEqual((man['lightness'], man['desktop']), ('light', {'color-scheme': 'prefer-light'}))
        self.helper('stage', '--work', w, '--profile', 'preset:gruvbox-dark', env=env)
        self.assertEqual(json.loads(Path(w, 'manifest.json').read_text())['lightness'], 'dark')

    def test_gtk_facts_and_last_change(self):
        """F-d: el helper dice qué CSS de GTK cambió y el modo de antes/después; Keep (no Revert) lo deja en
        theme/last-change.json para que la shell avise de reabrir las apps GTK."""
        lc = self.theme / 'last-change.json'
        st, inst = self.preview('preset:catppuccin-mocha')
        self.assertEqual(inst['gtk'], {'gtk4': True})
        self.assertEqual((inst['lightnessBefore'], inst['lightness']), ('dark', 'dark'))
        self.helper('restore', '--snap', self.snap)
        self.assertFalse(lc.exists())                                    # Revert no es un cambio confirmado
        self.preview('preset:catppuccin-mocha', work='w2')
        k = self.helper('keep', '--snap', self.snap, '--profile', 'preset:catppuccin-mocha')
        d = json.loads(lc.read_text())
        self.assertEqual((d['profile'], d['gtk'], d['lightnessBefore'], d['lightness']),
                         ('preset:catppuccin-mocha', {'gtk4': True}, 'dark', 'dark'))
        self.assertEqual(k['change']['at'], d['at'])
        st, inst = self.preview('preset:catppuccin-latte', work='w3')
        self.assertEqual((inst['lightnessBefore'], inst['lightness']), ('dark', 'light'))   # base = Mocha
        self.helper('keep', '--snap', self.snap, '--profile', 'preset:catppuccin-latte')
        self.assertEqual(json.loads(lc.read_text())['lightness'], 'light')
        # sin cambio en los CSS (el mismo preset otra vez por la transacción): gtk vacío
        self.tp('preset', 'catppuccin-latte')
        self.assertEqual(json.loads(lc.read_text())['gtk'], {})

    def test_cut_halfway_is_recovered(self):
        before = self.outputs()
        w = str(self.R / 'w')
        self.helper('stage', '--work', w, '--profile', 'preset:catppuccin-mocha')
        self.helper('snapshot', '--snap', self.snap)
        # la segunda salida (gtk) no se puede escribir: install se corta con la primera (kitty) ya puesta
        gdir = self.gtk.parent
        gdir.chmod(0o500)
        try:
            r = self.helper('install', '--work', w, '--snap', self.snap, ok=False)
        finally:
            gdir.chmod(0o700)
        self.assertEqual(r.get('error'), 'install-failed')
        self.assertNotEqual(sha(self.kitty), before[self.kitty])
        self.assertEqual(json.loads(Path(self.snap, 'pending.json').read_text())['phase'], 'installing')
        rec = self.helper('recover', '--snap', self.snap)              # lo que hace la shell al volver
        self.assertEqual(rec['recovered'], 'restored')
        self.assertEqual(self.outputs(), before)

    def test_keep_refuses_if_preset_changed_outside(self):
        self.preview('preset:catppuccin-mocha')
        (self.theme / 'preset').write_text('gruvbox-dark')
        r = self.helper('keep', '--snap', self.snap, '--profile', 'preset:catppuccin-mocha', ok=False)
        self.assertEqual(r['error'], 'changed-outside')

    def test_bad_presets_never_reach_the_outputs(self):
        before = self.outputs()
        for profile in ('preset:nope-nope', 'preset:../x', 'preset:'):
            r = self.helper('stage', '--work', str(self.R / 'w'), '--profile', profile, ok=False)
            self.assertEqual(r['error'], 'preset-invalid', profile)
        # una plantilla que pide un rol que ningún preset trae: matugen falla en el stage, nada se instala
        (self.R / 'tpl/gtk.css').write_text('@define-color x {{colors.not_a_role.default.hex}};\n')
        r = self.helper('stage', '--work', str(self.R / 'w'), '--profile', 'preset:catppuccin-mocha', ok=False)
        self.assertEqual(r['error'], 'matugen-failed')
        self.assertEqual(self.outputs(), before)


@unittest.skipUnless(MATUGEN, 'matugen is not installed')
class Provider(Bench):
    def test_preset_to_preset(self):
        self.tp('preset', 'catppuccin-mocha')
        self.expect_preset('catppuccin-mocha')
        self.tp('preset', 'gruvbox-light')
        self.expect_preset('gruvbox-light')
        self.assertEqual(self.preset_file(), 'gruvbox-light')
        self.assertEqual(self.marks.read_text().split(), ['kitty', 'kitty'])   # una ronda de hooks por cambio
        self.assertFalse((self.state / 'sumi-shell/theme-apply').exists())   # transacción cerrada

    def test_preset_dynamic_preset(self):
        self.tp('preset', 'catppuccin-mocha')
        # dinámico desde un color de origen (Keep de la preview, como la shell)
        self.helper('stage', '--work', str(self.R / 'w'), '--profile', 'tonal-spot', '--source', '#89b4fa')
        self.helper('snapshot', '--snap', self.snap)
        self.helper('install', '--work', str(self.R / 'w'), '--snap', self.snap)
        self.helper('keep', '--snap', self.snap, '--profile', 'tonal-spot')
        self.assertTrue((self.theme / 'enabled').exists())
        self.assertEqual(self.preset_file(), '')
        self.assertNotEqual(json.loads(self.colors.read_text())['surface'], '#1e1e2e')
        self.tp('preset', 'gruvbox-dark')
        self.expect_preset('gruvbox-dark')
        self.assertFalse((self.theme / 'enabled').exists())
        self.assertEqual(self.preset_file(), 'gruvbox-dark')

    def test_new_wallpaper_with_a_preset_does_not_regenerate(self):
        self.tp('preset', 'catppuccin-latte')
        before = self.outputs()
        wall = self.R / 'wall.png'
        wall.write_bytes(b'not really a picture')
        r = self.tp('reload', str(wall))
        self.assertIn('dynamic colours are off', r.stdout)
        self.assertEqual(self.outputs(), before)

    def test_toggle_on_then_off(self):
        self.tp('preset', 'gruvbox-dark')
        self.tp('toggle', rc=None)                  # encender: quita el preset (no hay fondo: sin colores todavía)
        self.assertTrue((self.theme / 'enabled').exists())
        self.assertEqual(self.preset_file(), '')
        self.tp('toggle')                           # apagar = Minimaru, por la transacción
        self.assertFalse((self.theme / 'enabled').exists())
        self.assertEqual(self.colors.read_text(), (TREE / 'colors.static.json').read_text())

    def test_list(self):
        got = json.loads(self.tp('preset', '--list').stdout)
        self.assertEqual(sorted(p['id'] for p in got), sorted(PP.list_ids()))
        r = self.tp('preset', '--evil', rc=1)
        self.assertIn('not a preset id', r.stderr)

    def test_slow_reload_then_preset(self):
        """Un reload ya en marcha (matugen falso lento) y, mientras, un preset: el preset espera al cerrojo y gana."""
        (self.theme / 'enabled').write_text('')
        bin_ = self.R / 'slow-matugen'
        bin_.write_text(SLOW_MATUGEN)
        bin_.chmod(0o755)
        reached = self.R / 'reached'
        slow = dict(self.env, MATUGEN_BIN=str(bin_), TEST_REACHED=str(reached), TEST_SLOW='2')
        wall = self.R / 'wall.png'
        wall.write_bytes(b'x')
        p = subprocess.Popen([sys.executable, '-B', str(TP), '--config', str(self.cfg), 'reload', str(wall)], env=slow,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        for _ in range(100):
            if reached.exists():
                break
            time.sleep(0.05)
        self.assertTrue(reached.exists(), 'the slow reload started')
        self.tp('preset', 'catppuccin-mocha')
        p.communicate(timeout=30)
        self.assertEqual(p.returncode, 0)
        self.expect_preset('catppuccin-mocha')
        self.assertFalse((self.theme / 'enabled').exists())

    def test_reload_waiting_for_the_lock_sees_the_preset(self):
        """El hallazgo de la auditoría: un reload que ya pasó la comprobación del sentinel y espera mientras se
        confirma un preset. Con el cerrojo puesto (un Keep en curso) se quita el sentinel: el reload no escribe."""
        (self.theme / 'enabled').write_text('')
        bin_ = self.R / 'slow-matugen'
        bin_.write_text(SLOW_MATUGEN)
        bin_.chmod(0o755)
        slow = dict(self.env, MATUGEN_BIN=str(bin_), TEST_REACHED=str(self.R / 'reached'), TEST_SLOW='0')
        wall = self.R / 'wall.png'
        wall.write_bytes(b'x')
        before = self.outputs()
        with open(self.theme / '.desktop-sync.lock', 'a') as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            p = subprocess.Popen([sys.executable, '-B', str(TP), '--config', str(self.cfg), 'reload', str(wall)],
                                 env=slow, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            time.sleep(0.8)                         # ya pasó la primera comprobación; espera al cerrojo
            self.assertIsNone(p.poll())
            os.remove(self.theme / 'enabled')       # lo que hace Keep de un preset
            (self.theme / 'preset').write_text('catppuccin-mocha')
        out, err = p.communicate(timeout=30)
        self.assertEqual(p.returncode, 0, err)
        self.assertIn('turned off meanwhile', out)
        self.assertEqual(self.outputs(), before)


class WithoutMatugen(Bench):
    def setUp(self):
        super().setUp()
        self.env['MATUGEN_BIN'] = str(self.R / 'no-matugen')

    def test_shell_only(self):
        before = self.outputs()
        st, _inst = self.preview('preset:catppuccin-mocha')
        self.assertEqual((st['renderer'], st['entries']), ('shell-only', 1))
        self.helper('keep', '--snap', self.snap, '--profile', 'preset:catppuccin-mocha')
        self.assertEqual(json.loads(self.colors.read_text())['surface'], '#1e1e2e')
        for p in (self.kitty, self.gtk, self.app):
            self.assertEqual(sha(p), before[p], p)
        self.assertEqual(self.preset_file(), 'catppuccin-mocha')

    def test_static_without_matugen_leaves_unpaired_alone(self):
        before = self.outputs()
        self.preview('static')
        for p in (self.kitty, self.gtk, self.app):
            self.assertEqual(sha(p), before[p], p)


@unittest.skipUnless(MATUGEN, 'matugen is not installed')
class StaticGlass(Bench):
    def test_unpaired_targets_get_minimaru_dark(self):
        """D0-2: con la lista propia (sólo la shell), lo demás de la config se pinta con Minimaru."""
        (self.theme / 'enabled').write_text('')
        st, _ = self.preview('static')
        self.assertEqual(st['substituted'], ['kitty'])
        glass = PP.load_static('minimaru-dark')
        self.assertEqual(self.colors.read_text(), (TREE / 'colors.static.json').read_text())
        self.assertIn('color0 %s' % glass['terminal']['color0'], self.kitty.read_text())
        self.assertIn(glass['roles']['surface'], self.gtk.read_text())
        self.helper('keep', '--snap', self.snap, '--profile', 'static')
        self.assertFalse((self.theme / 'enabled').exists())
        self.assertEqual(self.preset_file(), '')

    def test_declared_pairs_win(self):
        """La lista estática del usuario (como apply-static-colors.sh --list): su par se copia tal cual."""
        mine = self.R / 'kitty.static.conf'
        mine.write_text('background #141414\ncolor0 #111111\n')
        lister = self.R / 'list.py'
        lister.write_text('import sys\nassert sys.argv[1:] == ["--list"]\nprint("copy\\t%s\\t%s")\nprint("copy\\t%s\\t%s")\n'
                          % (mine, self.kitty, TREE / 'colors.static.json', self.colors))
        env = dict(self.env, KT_STATIC_LIST_ARGV=json.dumps([sys.executable, str(lister), '--list']))
        w = str(self.R / 'w')
        self.helper('stage', '--work', w, '--profile', 'static', env=env)
        self.helper('snapshot', '--snap', self.snap, env=env)
        self.helper('install', '--work', w, '--snap', self.snap, env=env)
        self.assertEqual(self.kitty.read_text(), mine.read_text())
        self.assertIn(PP.load_static('minimaru-dark')['roles']['surface'], self.gtk.read_text())

    def test_toggle_off_with_the_declared_list(self):
        mine = self.R / 'kitty.static.conf'
        mine.write_text('background #141414\n')
        lister = self.R / 'list.py'
        lister.write_text('print("copy\\t%s\\t%s")\nprint("copy\\t%s\\t%s")\n'
                          % (mine, self.kitty, TREE / 'colors.static.json', self.colors))
        (self.theme / 'enabled').write_text('')
        sl = json.dumps([sys.executable, str(lister), '--list'])
        r = subprocess.run([sys.executable, '-B', str(TP), '--config', str(self.cfg), '--static-list', sl, 'toggle'],
                           capture_output=True, text=True, env=self.env, timeout=120)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.kitty.read_text(), mine.read_text())
        self.assertFalse((self.theme / 'enabled').exists())


if __name__ == '__main__':
    unittest.main()
