#!/usr/bin/env python3
"""Paletas estáticas F-a: los presets de sumi/palettes/ y scripts/palette_presets.py.

    python3 -B tests/theme/palette-presets-test.py [ÁRBOL] [-v]

Esquema, hex, `dark` coherente con la claridad de `surface`, contrastes mínimos y, en un directorio temporal,
renderizado de TODAS las plantillas de la config de matugen del autor (KT_AUTHOR_MATUGEN, por defecto
~/.config/matugen/config.toml; si no existe, esa parte se omite y lo dice) y de la mínima del proyecto con
`matugen json`: rc 0, sin `{{`, JSON válido donde toca. Un mutante por regla tiene que detectarse.

Matugen SIEMPRE con -c y una config derivada: cada output_path dentro del temporal y sin hooks (nunca la config real,
que lanzaría kitty/Qt/Hyprland reales).
"""
import copy
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest

TREE = Path(sys.argv.pop(1)) if len(sys.argv) > 1 and not sys.argv[1].startswith('-') \
    else Path(__file__).resolve().parents[2] / 'sumi'
AUTHOR = Path(os.environ.get('KT_AUTHOR_MATUGEN') or Path.home() / '.config/matugen/config.toml')
MATUGEN = shutil.which(os.environ.get('MATUGEN_BIN', 'matugen'))


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    sys.dont_write_bytecode = True
    spec.loader.exec_module(m)
    return m


PP = module('palette_presets', TREE / 'scripts/palette_presets.py')
sys.path.insert(0, str(TREE / 'scripts'))
from theme_paths import load_matugen_config  # noqa: E402


def derived(cfg_path, outdir):
    """La config con cada salida en outdir/<clave> y sin pre/post_hook: [(clave, salida)] y la ruta de la config."""
    cfg = load_matugen_config(str(cfg_path))
    lines, outs = ['[config]'], []
    for k, v in (cfg.get('config') or {}).items():
        if not isinstance(v, dict):
            lines.append('%s = %s' % (k, json.dumps(v)))
    for key, t in (cfg.get('templates') or {}).items():
        o = os.path.join(outdir, key)
        outs.append((key, o, t['output_path']))
        lines += ['', '[templates.%s]' % json.dumps(key), 'input_path = %s' % json.dumps(t['input_path']),
                  'output_path = %s' % json.dumps(o)]
    p = os.path.join(outdir, 'config.toml')
    with open(p, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    return p, outs


def render(cfg_path, doc, sibling, root, tag):
    out = os.path.join(root, tag)
    os.makedirs(out)
    cfg, outs = derived(cfg_path, out)
    js = os.path.join(out, 'preset.json')
    with open(js, 'w') as f:
        json.dump(PP.matugen_doc(doc, sibling), f)
    r = subprocess.run([MATUGEN, '-c', cfg, 'json', js, '-q'], capture_output=True, text=True, timeout=60,
                       stdin=subprocess.DEVNULL)
    return r, outs


class Presets(unittest.TestCase):
    def setUp(self):
        self.ids = PP.list_ids()

    def test_first_batch_present(self):
        self.assertEqual(sorted(self.ids), ['catppuccin-latte', 'catppuccin-mocha', 'gruvbox-dark', 'gruvbox-light'])

    def test_all_valid(self):
        for pid in self.ids:
            with self.subTest(pid=pid):
                self.assertEqual(PP.validate(PP.read(pid), pid), [])

    def test_siblings_pair_up(self):
        for pid in self.ids:
            d = PP.load(pid)
            s = PP.sibling_of(d)
            with self.subTest(pid=pid):
                self.assertIsNotNone(s)
                self.assertEqual(s['sibling'], pid)
                self.assertNotEqual(s['dark'], d['dark'])

    def test_sources_and_licence_recorded(self):
        for pid in self.ids:
            d = PP.load(pid)
            with self.subTest(pid=pid):
                for part in ('palette', 'terminal'):
                    self.assertTrue(d['source'][part]['url'].startswith('https://'))
                    self.assertRegex(d['source'][part]['sha256'], r'^[0-9a-f]{64}$')
                self.assertIn('MIT', d['source']['license'])
                self.assertTrue(set(d['derived']) <= set(PP.ROLES))
        self.assertTrue((TREE / 'palettes/LICENSES.md').is_file())


class Mutants(unittest.TestCase):
    """Un mutante por regla: cada uno debe dar al menos un error que lo nombre."""

    def base(self):
        return copy.deepcopy(PP.read('catppuccin-mocha'))

    def errs(self, d):
        return ' | '.join(PP.validate(d, 'catppuccin-mocha'))

    def test_role_removed(self):
        d = self.base(); del d['roles']['outline_variant']
        self.assertIn('roles missing: outline_variant', self.errs(d))

    def test_unknown_role(self):
        d = self.base(); d['roles']['accent'] = '#ffffff'
        self.assertIn('unknown roles: accent', self.errs(d))

    def test_broken_hex(self):
        for bad in ('#12345', '1e1e2e', '#GGGGGG', '#1E1E2E', 12):
            d = self.base(); d['roles']['surface'] = bad
            with self.subTest(bad=bad):
                self.assertIn('not #rrggbb: surface', self.errs(d))

    def test_low_contrast_text(self):
        d = self.base(); d['roles']['on_surface'] = '#313244'
        self.assertIn('on_surface on surface', self.errs(d))

    def test_low_contrast_on_primary(self):
        d = self.base(); d['roles']['on_primary'] = d['roles']['primary']
        self.assertIn('on_primary on primary', self.errs(d))

    def test_low_contrast_outline(self):
        d = self.base(); d['roles']['outline'] = '#313244'
        self.assertIn('outline on surface', self.errs(d))

    def test_dark_flag_incoherent(self):
        d = self.base(); d['dark'] = False
        self.assertIn('dark is false but surface', self.errs(d))
        latte = copy.deepcopy(PP.read('catppuccin-latte')); latte['dark'] = True
        self.assertIn('dark is true but surface', ' '.join(PP.validate(latte, 'catppuccin-latte')))

    def test_terminal_key_missing(self):
        d = self.base(); del d['terminal']['color9']
        self.assertIn('terminal missing or not #rrggbb: color9', self.errs(d))

    def test_format_and_id(self):
        d = self.base(); d['format'] = 2
        self.assertIn('unknown format', self.errs(d))
        d = self.base()
        self.assertIn('does not match the file name', ' '.join(PP.validate(d, 'gruvbox-dark')))

    def test_no_licence(self):
        d = self.base(); d['source']['license'] = ''
        self.assertIn('licence', self.errs(d))

    def test_bad_id_never_reaches_a_path(self):
        for bad in ('../x', 'x', 'Mocha-1', 'a/b-c', ''):
            with self.subTest(bad=bad), self.assertRaises(PP.PresetError):
                PP.path_of(bad)


class Translate(unittest.TestCase):
    def test_matugen_doc_modes(self):
        m, l = PP.load('catppuccin-mocha'), PP.load('catppuccin-latte')
        dm = PP.matugen_doc(m, l)
        self.assertTrue(dm['is_dark_mode'])
        self.assertEqual(dm['colors']['surface']['default']['color'], '#1e1e2e')
        self.assertEqual(dm['colors']['surface']['dark']['color'], '#1e1e2e')
        self.assertEqual(dm['colors']['surface']['light']['color'], '#eff1f5')
        dl = PP.matugen_doc(l, m)
        self.assertFalse(dl['is_dark_mode'])
        self.assertEqual(dl['colors']['surface']['default']['color'], '#eff1f5')
        self.assertEqual(set(dl['colors']), set(PP.ROLES))

    def test_shell_colors_without_matugen(self):
        for pid in PP.list_ids():
            d = PP.load(pid)
            out = json.loads(PP.shell_colors(d))
            with self.subTest(pid=pid):
                self.assertEqual(len(out), 17)
                for k, v in out.items():
                    if k != '_comment':
                        self.assertEqual(v, d['roles'][k])

    def test_kitty_substitution(self):
        term = PP.load('gruvbox-light')['terminal']
        text = ('background #111111\nforeground    #222222   # comment\ncolor0  #000000\n'
                '# color1 #ffffff\ncolor16 #c0a878\nfont_size 11\n')
        out = PP.substitute('kitty', text, term)
        self.assertIn('background #fbf1c7\n', out)
        self.assertIn('foreground    #3c3836   # comment\n', out)
        self.assertIn('color0  #fdf4c1\n', out)
        self.assertIn('# color1 #ffffff\n', out)        # un comentario no se toca
        self.assertIn('color16 #c0a878\n', out)         # extendidos del usuario intactos
        self.assertIn('font_size 11\n', out)
        self.assertIn('\ncolor1 #cc241d\n', out)        # lo que faltaba se añade
        self.assertEqual(PP.substitute(None, text, term), text)

    def test_substitution_kind(self):
        self.assertEqual(PP.substitution_kind('/h/.config/kitty/colors/colors.conf'), 'kitty')
        self.assertEqual(PP.substitution_kind('/h/.config/kitty/kitty.conf'), 'kitty')
        self.assertIsNone(PP.substitution_kind('/h/.config/hyprlock/colors.conf'))
        self.assertIsNone(PP.substitution_kind('/h/.config/kitty-notes.conf'))

    def test_cli(self):
        r = subprocess.run([sys.executable, '-B', str(TREE / 'scripts/palette_presets.py'), 'validate'],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(json.loads(r.stdout)['ok'])
        r = subprocess.run([sys.executable, '-B', str(TREE / 'scripts/palette_presets.py'), 'matugen-json', '../x'],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 1)


@unittest.skipUnless(MATUGEN, 'matugen is not installed')
class Render(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='kt-presets-')
        self.addCleanup(self.tmp.cleanup)
        self.root = self.tmp.name

    def check_config(self, cfg):
        for pid in PP.list_ids():
            d = PP.load(pid)
            r, outs = render(cfg, d, PP.sibling_of(d), self.root, pid)
            with self.subTest(config=str(cfg), pid=pid):
                self.assertEqual(r.returncode, 0, r.stderr or r.stdout)
                for key, o, real in outs:
                    body = Path(o).read_text()
                    self.assertTrue(body.strip(), key)
                    self.assertNotIn('{{', body, key)
                    self.assertNotIn('<*', body, key)
                    if real.endswith('.json'):
                        json.loads(body)
                    if key == 'sumi_shell':
                        got = {k: v for k, v in json.loads(body).items() if k != '_comment'}
                        mine = {k: v for k, v in json.loads(PP.shell_colors(d)).items() if k != '_comment'}
                        self.assertEqual(got, mine)       # sin matugen = con matugen, token a token
        return outs

    def test_project_minimal_config(self):
        outs = self.check_config(TREE / 'templates/matugen-config.toml')
        self.assertEqual([k for k, _o, _r in outs], ['sumi_shell'])

    @unittest.skipUnless(AUTHOR.is_file(), 'no author matugen config (KT_AUTHOR_MATUGEN)')
    def test_author_config(self):
        outs = self.check_config(AUTHOR)
        print('\n  author config: %d templates rendered per preset' % len(outs), file=sys.stderr)
        self.assertGreaterEqual(len(outs), 2)

    @unittest.skipUnless(AUTHOR.is_file(), 'no author matugen config (KT_AUTHOR_MATUGEN)')
    def test_author_kitty_gets_the_official_ansi(self):
        d = PP.load('catppuccin-mocha')
        r, outs = render(AUTHOR, d, PP.sibling_of(d), self.root, 'kitty')
        self.assertEqual(r.returncode, 0, r.stderr)
        kitty = [(o, real) for _k, o, real in outs if PP.substitution_kind(real) == 'kitty']
        self.assertTrue(kitty, 'the author config has a kitty target')
        for o, _real in kitty:
            before = Path(o).read_text()
            text = PP.substitute('kitty', before, d['terminal'])
            got = dict(re.findall(r'^(color\d+|foreground|background|cursor)\s+(#[0-9a-f]{6})', text, re.M))
            for k in ['color%d' % i for i in range(16)] + ['foreground', 'background', 'cursor']:
                self.assertEqual(got[k], d['terminal'][k], k)
            # los extendidos (color16+) del autor siguen como los dejó su plantilla
            self.assertEqual(re.findall(r'^color(?:1[6-9]|2\d)\s+\S+', before, re.M),
                             re.findall(r'^color(?:1[6-9]|2\d)\s+\S+', text, re.M))

    def test_missing_role_is_a_render_error(self):
        """Mutante de plantilla: si un preset no trae un rol que la plantilla pide, matugen falla (rc 1) y nada vale."""
        d = copy.deepcopy(PP.load('gruvbox-dark'))
        os.makedirs(os.path.join(self.root, 'x'))
        cfg, _outs = derived(TREE / 'templates/matugen-config.toml', os.path.join(self.root, 'x'))
        doc = PP.matugen_doc(d, None)
        del doc['colors']['tertiary_fixed']
        js = os.path.join(self.root, 'x', 'bad.json')
        with open(js, 'w') as f:
            json.dump(doc, f)
        r = subprocess.run([MATUGEN, '-c', cfg, 'json', js, '-q'], capture_output=True, text=True, timeout=60)
        self.assertNotEqual(r.returncode, 0)


if __name__ == '__main__':
    unittest.main()
