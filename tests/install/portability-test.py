#!/usr/bin/env python3
"""Regresiones de instalación con HOME temporal y servicios simulados."""
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import runpy
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("installer_bench", Path(__file__).with_name("installer-test.py"))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class PortabilityTests(unittest.TestCase):
    def setUp(self):
        self.bench = fixture.Bench({"hyprVersion": "0.57.2"})
        self.addCleanup(self.bench.close)
        self.production = {"SUMI_INSTALL_TEST": ""}
        (Path(self.bench.pam) / "login").write_text("auth required pam_unix.so\n")
        self.runtime = Path(self.bench.run_dir)

    def command(self, *args, extra=None):
        return self.bench.run(*args, extra={**self.production, **(extra or {})})

    def installation_denied(self, extra, reason):
        before = self.bench.snap()
        for args in (("install", "--no-units", "--dry-run"), ("install", "--no-units")):
            rc, output = self.command(*args, extra=extra)
            self.assertEqual(rc, 1, output)
            self.assertIn(reason, output)
        rc, output = self.command("check", "--json", "--install", "--no-units", extra=extra)
        self.assertEqual(rc, 1, output)
        findings = json.loads(output)["findings"]
        self.assertTrue(any(f["id"] == "install.preflight" and reason in f["cause"] for f in findings), output)
        self.assertEqual(self.bench.snap(), before)

    def test_new_roots_and_alternate_runtime(self):
        home = Path(self.bench.h)
        roots = {key: str(home / "xdg" / name) for key, name in
                 (("XDG_CONFIG_HOME", "config"), ("XDG_STATE_HOME", "state"), ("XDG_CACHE_HOME", "cache"))}
        extra = {**roots, "SUMI_INSTALL_RUNTIME_DIR": str(Path(self.bench.tmp) / "ignored")}
        witness = Path(self.bench.write("foreign.ini", "untouched\n"))
        before = self.bench.snap()
        for args in (("check", "--json", "--install", "--no-units"), ("install", "--no-units", "--dry-run")):
            rc, output = self.command(*args, extra=extra)
            self.assertEqual(rc, 0, output)
            self.assertEqual(self.bench.snap(), before)
            self.assertFalse((self.runtime / "sumi-install.lock").exists())
        self.assertEqual(self.command("install", "--no-units", extra=extra)[0], 0)
        lock = self.runtime / "sumi-install.lock"
        self.assertEqual(lock.stat().st_mode & 0o777, 0o600)
        for path in (roots["XDG_CONFIG_HOME"], roots["XDG_STATE_HOME"]):
            self.assertEqual(Path(path).stat().st_mode & 0o777, 0o700)
        self.assertFalse(Path(roots["XDG_CACHE_HOME"]).exists())
        self.assertEqual(self.command("uninstall", "--dry-run", extra=extra)[0], 0)
        self.assertEqual(self.command("uninstall", extra=extra)[0], 0)
        self.assertEqual(witness.read_text(), "untouched\n")
        for path in (roots["XDG_CONFIG_HOME"], roots["XDG_STATE_HOME"]):
            self.assertEqual(list(Path(path).iterdir()), [])

    def test_invalid_runtime_paths(self):
        runtime_link = self.runtime.parent / "runtime-link"
        runtime_link.symlink_to(self.runtime, target_is_directory=True)
        parent_link = self.runtime.parent / "parent-link"
        parent_link.symlink_to(self.runtime.parent, target_is_directory=True)
        mode_dir = self.runtime.parent / "unsafe"
        mode_dir.mkdir()
        mode_dir.chmod(0o755)
        for value, reason in [
            ("relative", "absolute path"),
            (str(self.runtime / ".." / "run"), "absolute path"),
            (str(runtime_link), "without symlinks"),
            (str(parent_link / "run"), "without symlinks"),
            (str(mode_dir), "mode 0700"),
            (str(self.runtime.parent / "missing"), "cannot be used for the installer lock"),
        ]:
            with self.subTest(value=value):
                self.installation_denied({"XDG_RUNTIME_DIR": value}, reason)

    def test_invalid_lock_objects(self):
        lock = self.runtime / "sumi-install.lock"
        witness = self.runtime / "foreign"
        witness.write_text("untouched\n")
        witness.chmod(0o600)
        lock.symlink_to(witness)
        self.installation_denied({}, "cannot be opened safely")
        lock.unlink()
        lock.hardlink_to(witness)
        self.installation_denied({}, "one link")
        lock.unlink()
        os.mkfifo(lock, 0o600)
        self.installation_denied({}, "regular file")
        lock.unlink()
        lock.write_text("")
        lock.chmod(0o644)
        self.installation_denied({}, "mode 0600")
        self.assertEqual(witness.read_text(), "untouched\n")

    def test_concurrent_lock_is_shared_by_preflight(self):
        lock = self.runtime / "sumi-install.lock"
        lock.touch(mode=0o600)
        with lock.open("r+b") as fd:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.installation_denied({}, "another install.sh is running")

    def test_managed_requires_manager_and_uses_the_resolved_qs(self):
        before = self.bench.snap()
        self.bench.spec["noManager"] = True
        self.bench.save_spec()
        for args in (("check", "--install"), ("install", "--dry-run"), ("install",)):
            rc, text = self.command(*args)
            self.assertEqual(rc, 1, text)
            self.assertIn("user service manager can't be reached", text)
        self.assertEqual(self.bench.snap(), before)
        self.bench.spec["noManager"] = False
        self.bench.save_spec()
        rc, text = self.command("install", "--enable")
        self.assertEqual(rc, 0, text)
        units = Path(self.bench.cfg) / "systemd/user"
        qs = str(Path(self.bench.bin) / "qs")
        shell = (units / "sumi-shell.service").read_text()
        self.assertIn("ExecStart=" + qs + " -c sumi", shell)
        self.assertIn("ExecReload=" + qs + " -c sumi", shell)
        self.assertIn("Environment=SUMI_QS=" + qs, (units / "sumi-lock-rescue.service").read_text())
        self.assertEqual(self.command("uninstall")[0], 0)
        self.assertEqual(self.bench.snap(), before)

    def test_known_missing_qml_dependency_blocks_installation(self):
        module_root = self.runtime / "qml"
        functions = runpy.run_path(str(ROOT / "packaging/qml_requirements.py"))
        for name in functions["required_modules"](str(ROOT / "sumi")):
            if name in ("Quickshell.Networking", "QtMultimedia"):
                continue
            folder = module_root.joinpath(*name.split("."))
            folder.mkdir(parents=True, exist_ok=True)
            (folder / "qmldir").write_text(f"module {name}\n")
        extra = {"QML_IMPORT_PATH": str(module_root), "KT_CHECK_QTPATHS": ""}
        self.installation_denied(extra, "missing required QML modules: Quickshell.Networking")
        networking = module_root / "Quickshell/Networking"
        networking.mkdir()
        (networking / "qmldir").write_text("module Quickshell.Networking\n")
        rc, text = self.command("install", "--no-units", "--dry-run", extra=extra)
        self.assertEqual(rc, 0, text)

    def test_website_import_is_explicit_idempotent_and_owned(self):
        source = Path(self.bench.write(".config/hypr/websites.conf", "[Example]\nTest | https://example.org\n"))
        target = Path(self.bench.cfg) / "sumi-shell/websites.conf"
        self.assertEqual(self.command("migrate", "websites-v1")[0], 0)
        self.assertFalse(target.exists())
        target.parent.mkdir()
        target.write_text("already mine\n")
        before = self.bench.snap()
        self.assertEqual(self.command("migrate", "websites-v1", "--apply")[0], 1)
        self.assertEqual(target.read_text(), "already mine\n")
        self.assertEqual(source.read_text(), "[Example]\nTest | https://example.org\n")
        target.write_bytes(source.read_bytes())
        self.assertEqual(self.command("migrate", "websites-v1", "--apply")[0], 0)
        self.assertEqual(self.command("migrate", "websites-v1", "--revert")[0], 1)
        self.assertEqual(target.read_bytes(), source.read_bytes())
        target.unlink()
        self.assertEqual(self.command("migrate", "websites-v1", "--apply")[0], 0)
        self.assertEqual(target.read_bytes(), source.read_bytes())
        imported = self.bench.snap()
        self.assertEqual(self.command("migrate", "websites-v1", "--apply")[0], 0)
        self.assertEqual(self.bench.snap(), imported)
        target.write_text("edited\n")
        self.assertEqual(self.command("migrate", "websites-v1", "--revert")[0], 1)
        self.assertEqual(target.read_text(), "edited\n")
        self.assertEqual(imported[".config/hypr/websites.conf"], before[".config/hypr/websites.conf"])


if __name__ == "__main__":
    unittest.main()
