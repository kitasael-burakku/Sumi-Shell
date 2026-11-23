#!/usr/bin/env python3
"""Desktop transactions with a fake GSettings database; never use the session bus."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

TREE = Path(sys.argv.pop(1)) if len(sys.argv) > 1 and not sys.argv[1].startswith('-') else Path(__file__).resolve().parents[2] / 'sumi'
FAKE = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p = Path(os.environ['TEST_SETTINGS_DB'])
d = json.loads(p.read_text())
if sys.argv[1] == 'get':
    print(repr(d[sys.argv[3]]))
elif sys.argv[1] == 'set' and not os.environ.get('TEST_DROP_WRITES'):
    d[sys.argv[3]] = sys.argv[4]
    p.write_text(json.dumps(d))
'''


class DesktopSync(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='kt-desktop-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.db = self.root / 'settings.json'
        self.db.write_text(json.dumps({'color-scheme': 'default', 'gtk-theme': 'Breeze'}))
        fake = self.root / 'gsettings'
        fake.write_text(FAKE)
        fake.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.root), XDG_CONFIG_HOME=str(self.root / 'config'),
                        XDG_STATE_HOME=str(self.root / 'state'), XDG_CACHE_HOME=str(self.root / 'cache'),
                        KT_GSETTINGS=str(fake), TEST_SETTINGS_DB=str(self.db),
                        KT_XSETTINGS_CONFIG='', KT_DESKTOP_SYNC='full',
                        KT_DESKTOP_LEDGER=str(self.root / 'ledger.json'), PYTHONDONTWRITEBYTECODE='1')
        self.env.pop('KT_STATIC_LIST_ARGV', None)

    def run_helper(self, *args, ok=True):
        p = subprocess.run([sys.executable, '-B', str(TREE / 'scripts/theme-preview.py'), *args],
                           env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(p.returncode, 0 if ok else 1, p.stdout + p.stderr)
        result = json.loads(p.stdout)
        self.assertEqual(result['ok'], ok)
        return result

    def values(self):
        return json.loads(self.db.read_text())

    def test_custom_theme_is_preserved_and_restore_tracks_only_owned_changes(self):
        result = self.run_helper('desktop', '--lightness', 'light')
        self.assertEqual(self.values(), {'color-scheme': 'prefer-light', 'gtk-theme': 'Breeze'})
        self.assertEqual(result['desktopSkipped']['gtk-theme'], 'custom-theme')
        result = self.run_helper('desktop-restore')
        self.assertEqual(result['restored'], ['color-scheme'])
        self.assertEqual(self.values()['color-scheme'], 'default')

    def test_adwaita_variants_round_trip(self):
        self.db.write_text(json.dumps({'color-scheme': 'default', 'gtk-theme': 'Adwaita-dark'}))
        self.run_helper('desktop', '--lightness', 'light')
        self.assertEqual(self.values()['gtk-theme'], 'Adwaita')
        self.run_helper('desktop-restore')
        self.assertEqual(self.values(), {'color-scheme': 'default', 'gtk-theme': 'Adwaita-dark'})

    def test_opt_out_changes_nothing(self):
        self.env['KT_DESKTOP_SYNC'] = 'off'
        before = self.db.read_bytes()
        self.run_helper('desktop', '--lightness', 'light')
        self.assertEqual(self.db.read_bytes(), before)

    def test_color_scheme_only_preserves_gtk(self):
        self.env['KT_DESKTOP_SYNC'] = 'colorScheme'
        self.run_helper('desktop', '--lightness', 'light')
        self.assertEqual(self.values(), {'color-scheme': 'prefer-light', 'gtk-theme': 'Breeze'})

    def test_later_user_edit_wins(self):
        self.run_helper('desktop', '--lightness', 'light')
        self.db.write_text(json.dumps({'color-scheme': 'prefer-dark', 'gtk-theme': 'Mine'}))
        result = self.run_helper('desktop-restore')
        self.assertEqual(result['changedByYou'], ['color-scheme'])
        self.assertEqual(self.values(), {'color-scheme': 'prefer-dark', 'gtk-theme': 'Mine'})

    def test_successful_exit_without_persistence_is_a_failure(self):
        self.env['TEST_DROP_WRITES'] = '1'
        result = self.run_helper('desktop', '--lightness', 'light', ok=False)
        self.assertIn('color-scheme', result['desktopFailures'])

    def test_failed_restore_keeps_ledger_for_retry(self):
        self.run_helper('desktop', '--lightness', 'light')
        self.env['TEST_DROP_WRITES'] = '1'
        result = self.run_helper('desktop-restore', ok=False)
        self.assertIn('color-scheme', result['unknown'])
        self.assertIn('color-scheme', json.loads((self.root / 'ledger.json').read_text())['keys'])
        self.env.pop('TEST_DROP_WRITES')
        self.run_helper('desktop-restore')
        self.assertEqual(self.values()['color-scheme'], 'default')

    def test_xsettings_disabled_does_not_need_a_guard_or_display(self):
        result = self.run_helper('xsettings-status')
        self.assertEqual(result['xsettings']['status'], 'disabled')
        self.assertFalse((self.root / 'state/sumi-shell/theme/xsettings').exists())


if __name__ == '__main__':
    unittest.main()
