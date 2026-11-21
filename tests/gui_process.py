#!/usr/bin/env python3
"""Headless GUI process/font/path checks on Linux, Windows or Wine."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PROBE = Path(sys.argv.pop(1)).resolve()
WINE = '--wine' in sys.argv
if WINE:
    sys.argv.remove('--wine')
WINDOWS = WINE or os.name == 'nt'

def argument(value):
    if WINE and isinstance(value, Path):
        return 'Z:' + str(value.absolute()).replace('/', '\\')
    return str(value)

class GuiProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def probe(self, *args, error=None):
        command = ['wine', str(PROBE)] if WINE else [str(PROBE)]
        result = subprocess.run(command + [argument(a) for a in args], cwd=self.root,
                                capture_output=True, timeout=30)
        if error is None:
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)
        return result.stdout.replace(b'\r\n', b'\n')

    def test_default_font(self):
        self.assertEqual(self.probe('font'), b'Consolas\n' if WINDOWS else b'monospace\n')

    def test_merged_streams_unicode_arguments_large_output_and_reuse(self):
        value = 'two words "quoted" 日本 \\tail\\'
        result = self.probe('emit', value)
        self.assertEqual(result, ('text=' + value + '\n').encode() + b'X' * (512 * 1024) + 'END 日本\n'.encode())

    def test_failed_launch_cleans_state_and_allows_retry(self):
        result = self.probe('failed-start', 'retry')
        self.assertEqual(result, b'rejected\ntext=retry\n' + b'X' * (512 * 1024) + 'END 日本\n'.encode())

    def test_unicode_preferences_directory_creation_and_repeat(self):
        path = self.root / 'preferences 日本' / 'nested' / 'scu'
        self.probe('directory', path)
        self.probe('directory', path)
        self.assertTrue(path.is_dir())
        blocker = self.root / 'file'
        blocker.write_bytes(b'keep')
        self.probe('directory', blocker, error=b'preferences directory')
        self.assertEqual(blocker.read_bytes(), b'keep')

    @unittest.skipUnless(WINDOWS, 'Windows console-free backend build')
    def test_gui_cli_and_build_descendants_have_no_console(self):
        scu = PROBE.with_name('scu.exe')
        library = self.root / 'library.sqlite'
        def cli(*args):
            command = ['wine', str(scu)] if WINE else [str(scu)]
            result = subprocess.run(command + [argument(library), *args], cwd=self.root,
                                    capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        cli('inil')
        cli('cred', 'main.c')
        cli('conl', 'build_command="' + argument(PROBE) + '" child emit "text=from-build"')
        result = self.probe('backend-build', library, scu)
        self.assertIn(b'text=from-build\n', result)
        self.assertIn('END 日本\n'.encode(), result)

    @unittest.skipUnless(WINDOWS, 'Windows GUI command job ownership')
    def test_abnormal_shutdown_retires_command_and_descendants(self):
        marker = self.root / 'should-not-exist'
        self.assertEqual(self.probe('abort', argument(marker)), b'aborted\n')
        self.assertFalse(marker.exists())

if __name__ == '__main__':
    unittest.main()
