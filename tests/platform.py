#!/usr/bin/env python3
"""Small platform boundary checks, independent of filesystem/terminal services."""
import datetime
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PROBE = Path(sys.argv.pop(1) if len(sys.argv) > 1 else 'build/platform_probe').resolve()
LINUX = sys.platform.startswith('linux')


class PlatformTests(unittest.TestCase):
    def probe(self, *args, env=None, executable=PROBE, check=True):
        result = subprocess.run([str(executable), *map(str, args)], env=env,
                                text=True, capture_output=True)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.rstrip('\n')
        return result

    def test_fixed_timestamp_format(self):
        self.assertEqual(self.probe('fixed'), '2026-11-16T12:34:56.789Z')

    def test_clock_is_utc_in_different_timezones(self):
        for zone in ('UTC', 'Pacific/Auckland', 'America/New_York'):
            before = datetime.datetime.now(datetime.timezone.utc)
            value = self.probe('now', env={**os.environ, 'TZ': zone})
            after = datetime.datetime.now(datetime.timezone.utc)
            actual = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
            # Formatting truncates/rounds to milliseconds.
            margin = datetime.timedelta(milliseconds=2)
            self.assertLessEqual(before - margin, actual)
            self.assertLessEqual(actual, after + margin)

    @unittest.skipUnless(LINUX, 'POSIX TZ environment')
    def test_local_display_uses_offset_at_the_recorded_instant(self):
        cases = [
            ('Europe/Amsterdam', '2026-10-25T00:30:00.123Z', '2026-10-25T02:30:00.123+02:00'),
            ('Europe/Amsterdam', '2026-10-25T01:30:00.123Z', '2026-10-25T02:30:00.123+01:00'),
            ('Asia/Kathmandu', '2026-01-01T19:00:00.007Z', '2026-01-02T00:45:00.007+05:45'),
            ('America/New_York', '2026-01-01T01:00:00.000Z', '2025-12-31T20:00:00.000-05:00'),
        ]
        for zone, utc, local in cases:
            with self.subTest(zone=zone, utc=utc):
                self.assertEqual(self.probe('local', utc, env={**os.environ, 'TZ': zone}), local)

    def test_canonical_file_allows_missing_leaf(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            self.assertEqual(self.probe('file', root / 'new.pas'), str(root / 'new.pas'))
            self.assertEqual(self.probe('directory', root), str(root))

    def test_invalid_paths_keep_context(self):
        for value in ('', 'somewhere' + os.sep):
            result = self.probe('file', value, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Expected a file path.', result.stderr)
        with tempfile.TemporaryDirectory() as temporary:
            missing = str(Path(temporary) / 'missing')
            result = self.probe('directory', missing, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Could not resolve directory ' + missing, result.stderr)

    @unittest.skipUnless(LINUX, 'Linux symlink and filename semantics')
    def test_canonical_parent_follows_symlinks_but_leaf_does_not(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            actual = root / 'actual'
            actual.mkdir()
            (root / 'parent').symlink_to(actual, target_is_directory=True)
            (actual / 'target').write_text('source')
            (actual / 'leaf').symlink_to(actual / 'target')
            self.assertEqual(self.probe('directory', root / 'parent'), str(actual))
            self.assertEqual(self.probe('file', root / 'parent' / 'leaf'), str(actual / 'leaf'))

    @unittest.skipUnless(LINUX, 'Linux filename semantics')
    def test_linux_backslash_colon_and_non_ascii_names_unchanged(self):
        with tempfile.TemporaryDirectory() as temporary:
            for name in ('a\\b:c.pas', 'déck.pas', 'ends-in-backslash\\'):
                path = Path(temporary) / name
                self.assertEqual(self.probe('file', path), str(path))
            self.assertEqual(self.probe('library', 'a\\b'), 'a\\b.sqlite')

    def test_library_storage_paths(self):
        library = str(Path(tempfile.gettempdir()) / 'platform.sqlite')
        for suffix in ('', '.lock', '-journal', '-wal', '-shm'):
            self.assertEqual(self.probe('storage', library + suffix, library), '1')
        self.assertEqual(self.probe('storage', library + '.other', library), '0')
        self.assertEqual(self.probe('same', library, library.upper()), '0' if LINUX else '1')

    def test_library_extension_and_separator(self):
        self.assertEqual(self.probe('library', 'test'), 'test.sqlite')
        self.assertEqual(self.probe('library', 'test.SQLITE'), 'test.SQLITE')
        for value in ('', 'test.json', 'directory' + os.sep):
            self.assertNotEqual(self.probe('library', value, check=False).returncode, 0)

    def test_running_executable_and_suffix(self):
        self.assertEqual(Path(self.probe('running')), PROBE)
        self.assertEqual(self.probe('executable_name', 'scu'), 'scu' if LINUX else 'scu.exe')

    @unittest.skipUnless(LINUX, 'Linux executable discovery semantics')
    def test_symlink_launch_preserves_cli_and_gui_discovery(self):
        with tempfile.TemporaryDirectory() as temporary:
            link = Path(temporary) / 'linked-probe'
            link.symlink_to(PROBE)
            self.assertEqual(self.probe('running', executable=link), str(PROBE))
            self.assertEqual(self.probe('invocation', executable=link),
                             self.probe('legacy_invocation', executable=link))

    @unittest.skipUnless(LINUX, 'Linux XDG policy')
    def test_history_roots_and_fallbacks(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / 'home'
            state = Path(temporary) / 'state'
            env = {**os.environ, 'HOME': str(home), 'XDG_STATE_HOME': str(state)}
            self.assertEqual(self.probe('history', env=env), str(state))
            for value in ('', 'relative/state'):
                env['XDG_STATE_HOME'] = value
                self.assertEqual(self.probe('history', env=env), str(home / '.local/state'))
            env['HOME'] = 'relative/home'
            self.assertEqual(self.probe('history', env=env), '')
            self.assertFalse(home.exists())
            self.assertFalse(state.exists())

    @unittest.skipUnless(LINUX, 'Linux XDG policy')
    def test_gui_configuration_location_unchanged(self):
        for root in ('/tmp/scu-platform-config', 'relative/config'):
            env = {**os.environ, 'XDG_CONFIG_HOME': root}
            self.assertEqual(self.probe('preferences', env=env), root + '/scu/gui.json')
        # Existing GetUserDir fallback is checked against the actual GUI suite.
        value = self.probe('preferences', env={**os.environ, 'XDG_CONFIG_HOME': ''})
        self.assertTrue(value.endswith('/.config/scu/gui.json'), value)


if __name__ == '__main__':
    unittest.main()
