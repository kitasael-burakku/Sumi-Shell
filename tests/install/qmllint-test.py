#!/usr/bin/env python3
"""F7 regression: Qt 5 on PATH must not hide a usable Qt 6 syntax checker."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('update', ROOT / 'packaging/update.py')
U = importlib.util.module_from_spec(spec)
spec.loader.exec_module(U)


class QmllintTests(unittest.TestCase):
    def test_qt5_on_path_falls_back_without_losing_syntax_validation(self):
        real = U.qmllint()
        self.assertIsNotNone(real, 'This regression needs a real qmllint with --bare')
        with tempfile.TemporaryDirectory() as d:
            old = Path(d) / 'qmllint'
            old.write_text('#!/bin/sh\nif [ "$1" = --help ]; then echo "Usage: qmllint files"; exit 0; fi\n'
                           'echo "qmllint: Unknown option bare" >&2\nexit 1\n')
            old.chmod(0o755)
            # A named Qt 6 wrapper also makes the regression independent of the host's Qt path.
            (Path(d) / 'qmllint6').symlink_to(real)
            with patch.dict(os.environ, {'PATH': d + os.pathsep + os.environ['PATH']}):
                self.assertEqual(os.path.realpath(U.qmllint()), os.path.realpath(real))
                errors, notes = U.static_checks([('Good.qml', '', 0o644, b'import QtQuick\nItem {}\n')])
                self.assertEqual(errors, [])
                self.assertEqual(notes, [])
                errors, _ = U.static_checks([('Bad.qml', '', 0o644, b'import QtQuick\nItem { property int = ; }\n')])
                self.assertTrue(any('QML:' in error for error in errors), errors)

    def select(self, choices, replies):
        with patch.object(U.shutil, 'which', side_effect=lambda name: choices.get(name)), \
             patch.object(U.os, 'access', side_effect=lambda path, mode: path in replies), \
             patch.object(U, 'run', side_effect=lambda argv, **kw: replies[argv[0]]) as probe:
            return U.qmllint(), probe.call_args_list

    def test_capable_path_keeps_precedence(self):
        selected, calls = self.select({'qmllint': '/custom/qmllint'}, {'/custom/qmllint': (0, '  --bare  Syntax only\n', '')})
        self.assertEqual(selected, '/custom/qmllint')
        self.assertEqual(len(calls), 1)

    def test_absolute_qt6_after_qt5(self):
        selected, _ = self.select({'qmllint': '/qt5/qmllint'}, {
            '/qt5/qmllint': (0, 'Usage: qmllint files\n', ''),
            '/usr/lib/qt6/bin/qmllint': (0, '  --bare  Syntax only\n', '')})
        self.assertEqual(selected, '/usr/lib/qt6/bin/qmllint')

    def test_failed_help_is_not_support(self):
        selected, _ = self.select({'qmllint': '/bad/qmllint'}, {'/bad/qmllint': (1, '', 'Unknown option --bare')})
        self.assertIsNone(selected)

    def test_alias_is_probed_once(self):
        selected, calls = self.select({'qmllint': '/same/qmllint', 'qmllint6': '/same/qmllint'},
                                      {'/same/qmllint': (0, 'Usage: files', '')})
        self.assertIsNone(selected)
        self.assertEqual(len(calls), 1)

    def test_missing_capability_is_explicit(self):
        with patch.object(U, 'qmllint', return_value=None):
            errors, notes = U.static_checks([('Good.qml', '', 0o644, b'import QtQuick\nItem {}\n')])
        self.assertEqual(errors, [])
        self.assertIn('No qmllint with --bare', notes[0])
        self.assertIn('load check still runs', notes[0])


if __name__ == '__main__':
    unittest.main()
