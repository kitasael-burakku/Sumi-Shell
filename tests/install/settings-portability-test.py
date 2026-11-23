#!/usr/bin/env python3
"""Ejecuta Settings.qml sin ventanas ni buses de sesión. También funciona con IPC local deshabilitado."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2] / "sumi"
QS = shutil.which("qs")
PROBE = """import QtQuick
import Quickshell
import "services" as S
ShellRoot {
    Component.onCompleted: { void S.Settings.loaded; }
    Timer {
        interval: 1800
        running: true
        onTriggered: {
            console.log("SETTINGS_AUDIT " + JSON.stringify({
                loaded: S.Settings.loaded, status: S.Settings.status
            }));
            Qt.quit();
        }
    }
}
"""


class SettingsPortabilityTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="spa-")
        self.addCleanup(temp.cleanup)
        work = Path(temp.name)
        self.home = work / "h"
        self.config = self.home / "conf/sumi-shell"
        self.state = self.home / "state"
        self.settings = self.config / "settings.json"
        runtime = work / "r"
        runtime.mkdir(mode=0o700)
        self.config.mkdir(parents=True, mode=0o700)
        self.env = {
            "HOME": str(self.home), "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8",
            "XDG_CONFIG_HOME": str(self.config.parent), "XDG_STATE_HOME": str(self.state),
            "XDG_RUNTIME_DIR": str(runtime), "XDG_CONFIG_DIRS": str(work / "no-config"),
            "DBUS_SESSION_BUS_ADDRESS": "disabled:", "DBUS_SYSTEM_BUS_ADDRESS": "disabled:",
            "QT_QPA_PLATFORM": "offscreen", "QS_NO_RELOAD_POPUP": "1",
        }
        tree = work / "probe"
        (tree / "services").mkdir(parents=True)
        shutil.copytree(ROOT / "lib", tree / "lib")
        shutil.copyfile(ROOT / "services/Settings.qml", tree / "services/Settings.qml")
        (tree / "services/qmldir").write_text("singleton Settings Settings.qml\n")
        self.probe = tree / "shell.qml"
        self.probe.write_text(PROBE)

    def run_quickshell(self, status="ready"):
        self.assertIsNotNone(QS, "This suite requires Quickshell with Qt offscreen support")
        result = subprocess.run([QS, "--no-color", "-p", self.probe], cwd=self.home, env=self.env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=12)
        self.assertEqual(result.returncode, 0, result.stdout)
        report = next((line.partition("SETTINGS_AUDIT ")[2] for line in result.stdout.splitlines()
                       if "SETTINGS_AUDIT " in line), "")
        self.assertTrue(report, result.stdout)
        self.assertEqual(json.loads(report), {"loaded": True, "status": status})

    def write_rice_fixtures(self):
        hypr = self.home / ".config/hypr"
        (hypr / "scripts").mkdir(parents=True)
        (hypr / "modules").mkdir()
        for path, value in {"websites.conf": "[Example]\nTest | https://example.org\n",
                            "scripts/updates.sh": "# a fixture marker\n",
                            "modules/programs.lua": 'browser = "fixture-browser"\n'}.items():
            (hypr / path).write_text(value)

    def assert_migrated(self, version, document):
        original = (json.dumps({"schemaVersion": version, **document}) + "\n").encode()
        self.settings.write_bytes(original)
        self.run_quickshell()
        migrated = json.loads(self.settings.read_bytes())
        self.assertEqual(migrated["schemaVersion"], 4)
        backups = list(self.state.glob(f"sumi-shell/backups/settings/settings.v{version}-premigration-*.json"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), original)
        self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)
        saved = self.settings.read_bytes()
        self.run_quickshell()
        self.assertEqual(self.settings.read_bytes(), saved)
        self.assertEqual(list(self.state.glob("sumi-shell/backups/settings/*")), backups)
        return migrated

    def test_new_profile_with_legacy_markers_creates_only_neutral_settings(self):
        self.write_rice_fixtures()
        self.run_quickshell()
        self.assertEqual([p.name for p in self.config.iterdir()], ["settings.json"])
        new = json.loads(self.settings.read_text())
        self.assertEqual(new["schemaVersion"], 4)
        self.assertEqual(new["apps"]["browser"], "auto")
        self.assertEqual(new["theme"]["desktopSync"], "off")

    def test_v2_migration_ignores_rice_and_preserves_task_preferences(self):
        self.write_rice_fixtures()
        new = self.assert_migrated(2, {"unknown": {"number": 12},
            "shell": {"dashboard": {"dotbackupEveryDays": 5, "diskbackupEveryDays": 7,
                                    "taskEveryDays": {"dotbackup": 8, "local": 3}}}})
        self.assertEqual([p.name for p in self.config.iterdir()], ["settings.json"])
        self.assertEqual(new["providers"]["updates"], "auto")
        self.assertEqual(new["theme"]["desktopSync"], "off")
        self.assertEqual(new["apps"]["terminal"], "auto")
        self.assertEqual(new["apps"]["browser"], "auto")
        self.assertEqual(new["shell"]["dashboard"]["taskEveryDays"], {"dotbackup": 8, "diskbackup": 7, "local": 3})
        self.assertEqual(new["unknown"], {"number": 12})

    def test_v3_migration_preserves_explicit_files_and_values(self):
        files = {
            "tasks.json": b'{"version":1,"tasks":[]}\n',
            "websites.conf": b"[User]\nTest | https://example.org\n",
            "providers.json": b'{"version":1,"updates":{"scripts":[{"argv":["/usr/bin/true"],"supports":["list"]}]}}\n',
        }
        for name, contents in files.items():
            (self.config / name).write_bytes(contents)
        new = self.assert_migrated(3, {"apps": {"terminal": "foot", "browser": "firefox"},
                                       "theme": {"desktopSync": "colorScheme"}, "providers": {"theme": "static"}})
        self.assertEqual(new["providers"]["theme"], "static")
        self.assertEqual(new["providers"]["updates"], "script")
        self.assertEqual(new["apps"], {"terminal": "foot", "browser": "firefox"})
        self.assertEqual(new["theme"]["desktopSync"], "colorScheme")
        for name, contents in files.items():
            self.assertEqual((self.config / name).read_bytes(), contents)

    def test_relative_bases_fall_back_without_writing_to_working_directory(self):
        self.env["XDG_CONFIG_HOME"] = "relative/config"
        self.env["XDG_STATE_HOME"] = "relative/state"
        self.run_quickshell()
        self.assertTrue((self.home / ".config/sumi-shell/settings.json").is_file())
        self.assertFalse((self.home / "relative").exists())
        self.assertFalse(self.settings.exists())

    def test_invalid_settings_and_backup_remain_byte_identical(self):
        original = b'{"broken"\n'
        self.settings.write_bytes(original)
        self.run_quickshell("invalid")
        self.assertEqual(self.settings.read_bytes(), original)
        backups = list(self.state.glob("sumi-shell/backups/settings/settings.invalid-*.json"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
