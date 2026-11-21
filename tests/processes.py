#!/usr/bin/env python3
"""Child process, build shell and authenticated Windows output-lease regressions."""
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import unittest

PROBE = Path(sys.argv.pop(1) if len(sys.argv) > 1 else 'build/process_probe').resolve()
WINE = '--wine' in sys.argv
if WINE:
    sys.argv.remove('--wine')
WINDOWS = WINE or os.name == 'nt'


def argument(value):
    if WINE and isinstance(value, Path):
        return 'Z:' + str(value.absolute()).replace('/', '\\')
    return str(value)


def command(*args):
    return (['wine', str(PROBE)] if WINE else [str(PROBE)]) + [argument(value) for value in args]


def quote(value):
    value = argument(value)
    return '"' + value + '"' if WINDOWS else shlex.quote(value)


class ProcessTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory = self.root / 'work 日本語 with spaces'
        self.directory.mkdir()

    def run_probe(self, *args, error=None, **options):
        result = subprocess.run(command(*args), capture_output=True, timeout=20, **options)
        if error is None:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)
        return result

    def child_command(self, *args):
        return ' '.join(quote(value) for value in (PROBE, *args))

    def test_argument_quoting_unicode_environment_cwd_stderr_and_null_input(self):
        values = ['two words', 'say "hi"', 'tail\\', '\\\\"quoted', 'déck 日本語', '&|<>^%']
        # FPC 3.2.2 Unix TProcess truncates argv at an empty StrNew slot.
        # Preserve that existing Linux behavior; test the new Windows case.
        if WINDOWS:
            values.insert(0, '')
        result = self.run_probe('run', 'self', self.directory, 'echo', *values,
                                env={**os.environ, 'SCU_TEST': 'parent'})
        args = [bytes.fromhex(line[4:].decode()).decode() for line in result.stdout.splitlines() if line.startswith(b'arg=')]
        self.assertEqual(args, values)
        env = next(line[4:] for line in result.stdout.splitlines() if line.startswith(b'env='))
        self.assertEqual(bytes.fromhex(env.decode()).decode(), 'override-日本語')
        cwd = next(line[4:] for line in result.stdout.splitlines() if line.startswith(b'cwd='))
        self.assertEqual(bytes.fromhex(cwd.decode()).decode().lower(), argument(self.directory).lower())
        self.assertIn(b'child-stderr', result.stderr)
        self.assertIn(b'input-eof', result.stdout)
        self.assertIn(b'status=0', result.stdout)

    @unittest.skipUnless(WINDOWS, "Windows executable lookup")
    def test_bare_editor_resolves_from_path(self):
        for directory in (self.directory, self.root):
            (directory / "sample-editor.exe").touch()
        result = self.run_probe("resolve", self.directory, "sample-editor", cwd=self.root)
        self.assertEqual(result.stdout.decode().strip().casefold(), argument(self.directory / "sample-editor.exe").casefold())

    def test_nonzero_exit_status_is_preserved(self):
        self.assertIn(b'status=37', self.run_probe('run', 'self', self.directory, 'exit', '37').stdout)

    def test_failed_start_and_bad_working_directory_have_context(self):
        self.run_probe('run', self.root / 'missing.exe', self.directory, error=b'missing.exe')
        if WINDOWS:
            self.run_probe('run', 'self', self.root / 'missing', 'echo', error=b'Could not start')

    def test_build_shell_streams_output_uses_working_directory_and_null_input(self):
        result = self.run_probe('build', self.directory, self.child_command('echo', 'build argument'))
        self.assertIn(b'child-stderr', result.stderr)
        self.assertIn(b'input-eof', result.stdout)
        cwd = next(line[4:] for line in result.stdout.splitlines() if line.startswith(b'cwd='))
        self.assertEqual(bytes.fromhex(cwd.decode()).decode().lower(), argument(self.directory).lower())

    def test_build_nonzero_exit_is_reported(self):
        command_line = 'exit /b 9' if WINDOWS else 'exit 9'
        self.run_probe('build', self.directory, command_line, error=b'exit status 9')

    def test_nested_builds_are_rejected(self):
        self.run_probe('build', self.directory, 'echo must-not-run',
                       env={**os.environ, 'SCU_BUILD_ACTIVE': '1'}, error=b'Nested SCU builds are disabled')

    def test_valid_build_handoff_allows_nested_output_access(self):
        marker = self.root / 'nested-result'
        result = self.run_probe('build', self.directory, self.child_command('nested', self.directory, marker))
        self.assertIn(b'nested-ok', result.stdout)
        self.assertEqual(marker.read_bytes(), b'nested')
        # The parent retained ownership, and releases it when the build completes.
        self.run_probe('nested', self.directory, self.root / 'after')

    def test_build_handoff_cannot_reuse_a_different_busy_directory(self):
        other = self.root / 'other'
        other.mkdir()
        marker = self.root / 'wrong-target'
        self.run_probe('lease_wrong', self.directory, other, marker, error=b'An expansion is already using output directory')
        self.assertFalse(marker.exists())

    @unittest.skipUnless(WINDOWS, 'Windows pre-launch cancellation')
    def test_cancellation_before_launch_has_no_child_effect(self):
        started, completed = self.root / 'started', self.root / 'escaped'
        self.run_probe('pre_cancel', started, completed, error=b'Command cancelled.')
        self.assertFalse(started.exists())
        self.assertFalse(completed.exists())

    @unittest.skipUnless(WINDOWS, 'Windows native console cancellation')
    def test_native_console_ctrl_c_cancels_the_job(self):
        if WINE:
            self.skipTest('Headless Wine cannot provide an isolated native Windows console.')
        started, completed = self.root / 'started', self.root / 'escaped'
        self.run_probe('console_tree', started, completed,
                       creationflags=subprocess.CREATE_NEW_CONSOLE, error=b'Command cancelled.')
        self.assertTrue(started.exists())
        time.sleep(3.2)
        self.assertFalse(completed.exists())

    @unittest.skipUnless(WINDOWS, 'Windows authenticated broker')
    def test_stolen_endpoint_is_rejected_for_a_process_outside_the_build_job(self):
        endpoint = self.root / 'endpoint'
        marker = self.root / 'forged-result'
        parent = subprocess.Popen(command('build', self.directory, self.child_command('lease_wait', endpoint)),
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: parent.poll() is None and parent.kill())
        deadline = time.monotonic() + 10
        while not endpoint.exists():
            self.assertIsNone(parent.poll())
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.01)
        value = endpoint.read_text()
        self.assertTrue(value.startswith('\\\\.\\pipe\\SCU.BuildLease.'))
        result = self.run_probe('nested', self.directory, marker,
                               env={**os.environ, 'SCU_BUILD_OUTPUT_LEASE': value, 'SCU_BUILD_ACTIVE': '1'},
                               error=b'No valid Windows build lease')
        self.assertFalse(marker.exists())
        stdout, stderr = parent.communicate(timeout=15)
        self.assertEqual(parent.returncode, 0, stderr)

    @unittest.skipUnless(WINDOWS, 'Windows handle whitelist')
    def test_unrelated_inheritable_handle_is_not_passed_to_children(self):
        self.assertIn(b'handle-isolated', self.run_probe('inheritance').stdout)

    @unittest.skipUnless(WINDOWS, 'Windows kill-on-close Job Object')
    def test_killing_the_parent_does_not_leave_build_descendants_running(self):
        started, completed = self.root / 'started', self.root / 'escaped'
        process = subprocess.Popen(command('run', 'self', self.directory, 'spawn_wait', started, completed),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        deadline = time.monotonic() + 10
        while not started.exists():
            self.assertIsNone(process.poll())
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.01)
        process.kill()
        process.communicate(timeout=15)
        time.sleep(3.2)
        self.assertFalse(completed.exists())

    @unittest.skipUnless(WINDOWS, 'Windows Job Object lifetime')
    def test_background_descendants_are_retired_before_build_returns(self):
        started, completed = self.root / 'started', self.root / 'escaped'
        self.run_probe('tree', started, completed)
        self.assertTrue(started.exists())
        time.sleep(3.2)
        self.assertFalse(completed.exists())

    def test_cancellation_terminates_the_child_tree(self):
        started, completed = self.root / 'started', self.root / 'escaped'
        process = subprocess.Popen(command('cancel_tree', started, completed),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        if not WINDOWS:
            deadline = time.monotonic() + 5
            while not started.exists():
                self.assertIsNone(process.poll())
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.01)
            process.send_signal(signal.SIGINT)
        stdout, stderr = process.communicate(timeout=15)
        self.assertTrue(started.exists(), stderr)
        if WINDOWS:
            self.assertEqual(process.returncode, 1, stderr)
            self.assertEqual(stderr.count(b'Command cancelled.'), 1, stderr)
        else:
            self.assertTrue(b'status=130' in stdout or b'status=137' in stdout, (stdout, stderr))
        time.sleep(3.2)
        self.assertFalse(completed.exists())


if __name__ == '__main__':
    unittest.main()
