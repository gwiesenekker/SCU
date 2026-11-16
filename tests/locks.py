#!/usr/bin/env python3
"""Cross-process lock and cancellation checks, native or using Wine."""
import os
from pathlib import Path
import queue
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

PROBE = Path(sys.argv.pop(1) if len(sys.argv) > 1 else 'build/locks_probe').resolve()
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


class LockTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.library_lock = self.root / 'library.sqlite.lock'
        self.output = self.root / 'output'
        self.output.mkdir()
        self.marker = self.root / 'effect'

    def cleanup_process(self, process):
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=10)

    def start(self, *args, env=None):
        process = subprocess.Popen(command(*args), stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        self.addCleanup(self.cleanup_process, process)
        return process

    def line(self, process):
        received = queue.Queue()
        threading.Thread(target=lambda: received.put(process.stdout.readline()), daemon=True).start()
        return received.get(timeout=15).strip()

    def hold(self, kind, path):
        process = self.start(kind, path, 'hold')
        self.assertEqual(self.line(process), b'waiting')
        self.assertEqual(self.line(process), b'locked')
        return process

    def release(self, process):
        stdout, stderr = process.communicate(b'continue\n', timeout=15)
        self.assertEqual(process.returncode, 0, stderr)

    def run_probe(self, *args, error=None, env=None):
        result = subprocess.run(command(*args), capture_output=True, timeout=15, env=env)
        if error is None:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)
        return result

    def test_library_and_output_locks_serialize_competing_processes(self):
        for kind, path in (('library', self.library_lock), ('output', self.output)):
            with self.subTest(kind=kind):
                self.marker.unlink(missing_ok=True)
                holder = self.hold(kind, path)
                waiter = self.start(kind, path, 'acquire', self.marker)
                self.assertEqual(self.line(waiter), b'waiting')
                time.sleep(0.08)
                self.assertIsNone(waiter.poll())
                self.assertFalse(self.marker.exists())
                self.release(holder)
                stdout, stderr = waiter.communicate(timeout=15)
                self.assertEqual(waiter.returncode, 0, stderr)
                self.assertEqual(self.marker.read_bytes(), b'effect')

    def test_cancelled_waits_have_no_effect_and_do_not_release_the_holder(self):
        for kind, path in (('library', self.library_lock), ('output', self.output)):
            with self.subTest(kind=kind):
                holder = self.hold(kind, path)
                result = self.run_probe(kind, path, 'cancel', self.marker, error=b'Command cancelled.')
                self.assertEqual(result.stderr.count(b'Command cancelled.'), 1)
                self.assertFalse(self.marker.exists())
                self.run_probe(kind, path, 'cancel', self.marker, error=b'Command cancelled.')
                self.assertIsNone(holder.poll())
                self.release(holder)
                self.run_probe(kind, path, 'acquire', self.marker)
                self.assertTrue(self.marker.exists())
                self.marker.unlink()

    def test_cancellation_after_acquisition_releases_the_lock_before_any_effect(self):
        for kind, path in (('library', self.library_lock), ('output', self.output)):
            with self.subTest(kind=kind):
                self.run_probe(kind, path, 'cancel_after', self.marker, error=b'Command cancelled.')
                self.assertFalse(self.marker.exists())
                self.run_probe(kind, path, 'acquire', self.marker)
                self.marker.unlink()

    def test_shutdown_stops_waiting_without_affecting_the_holder(self):
        for kind, path in (('library', self.library_lock), ('output', self.output)):
            with self.subTest(kind=kind):
                holder = self.hold(kind, path)
                self.run_probe(kind, path, 'stop', self.marker, error=b'busy during shutdown')
                self.assertFalse(self.marker.exists())
                self.assertIsNone(holder.poll())
                self.release(holder)

    def test_process_death_releases_library_and_output_locks(self):
        for kind, path in (('library', self.library_lock), ('output', self.output)):
            with self.subTest(kind=kind):
                holder = self.hold(kind, path)
                holder.kill()
                holder.communicate(timeout=15)
                self.run_probe(kind, path, 'acquire')

    def test_independent_output_directories_do_not_block_each_other(self):
        holder = self.hold('output', self.output)
        second = self.root / 'other'
        second.mkdir()
        self.run_probe('output', second, 'acquire', self.marker)
        self.assertTrue(self.marker.exists())
        self.release(holder)

    def test_build_markers_fail_fast_on_busy_outputs_instead_of_deadlocking(self):
        holder = self.hold('output', self.output)
        for action in ('reuse', 'acquire'):
            for marker in ('not-a-handle', '123456789'):
                self.run_probe('output', self.output, action, self.marker,
                               env={**os.environ, 'SCU_BUILD_OUTPUT_LOCK_FD': marker},
                               error=b'An expansion is already using output directory')
                self.assertFalse(self.marker.exists())
        self.release(holder)
        # The marker does not prevent acquisition when the directory is free.
        self.run_probe('output', self.output, 'reuse',
                       env={**os.environ, 'SCU_BUILD_OUTPUT_LOCK_FD': '123456789'})

    def test_build_handle_is_not_inherited_by_default(self):
        result = self.run_probe('output', self.output, 'flags')
        self.assertIn(b'flags=0' if WINDOWS else b'flags=1', result.stdout)

    def test_invalid_lock_targets_are_rejected(self):
        self.run_probe('library', self.output, 'acquire', error=b'lock file')
        self.run_probe('output', self.root / 'missing', 'acquire', error=b'directory')
        file = self.root / 'file'
        file.write_bytes(b'content')
        self.run_probe('output', file, 'acquire', error=b'directory')
        self.assertEqual(file.read_bytes(), b'content')

    def test_unicode_lock_paths(self):
        directory = self.root / '日本語-déck'
        directory.mkdir()
        self.run_probe('library', directory / 'library.sqlite.lock', 'acquire')
        self.run_probe('output', directory, 'acquire')

    def test_stage_owner_lock_cooperates_with_stale_file_cleanup(self):
        value = self.run_probe('stage', self.root).stdout.decode().strip()
        stage = Path(value[2:].replace('\\', '/')) if WINE else Path(value)
        self.run_probe('write', stage / '1')
        holder = self.hold('library', stage / '.owner')
        self.run_probe('cleanup', self.root)
        self.assertTrue((stage / '.owner').exists())
        self.assertTrue((stage / '1').exists())
        self.release(holder)
        self.run_probe('cleanup', self.root)
        self.assertFalse(stage.exists())

    def test_sidecar_lifecycle_and_reserved_name_are_platform_specific(self):
        self.run_probe('output', self.output, 'acquire')
        lock_file = self.output / '.scu-output.lock'
        self.assertEqual(lock_file.exists(), WINDOWS)
        result = subprocess.run(command('validate', '.SCU-OUTPUT.LOCK'), capture_output=True, timeout=15)
        self.assertEqual(result.returncode == 0, not WINDOWS)
        if WINDOWS:
            self.assertIn(b'reserved', result.stderr)
            self.run_probe('output', self.output, 'acquire')
            self.assertTrue(lock_file.exists())

    def test_console_ctrl_c_cancels_waits_once_before_any_effect(self):
        if WINE:
            self.skipTest('Headless Wine cannot provide an isolated native Windows console.')
        for kind, path in (('library', self.library_lock), ('output', self.output)):
            with self.subTest(kind=kind):
                holder = self.hold(kind, path)
                options = {'creationflags': subprocess.CREATE_NEW_CONSOLE} if WINDOWS else {}
                result = subprocess.run(command(kind, path, 'console_cancel', self.marker),
                                        capture_output=True, timeout=15, **options)
                self.release(holder)
                if result.returncode == 77:
                    self.skipTest(result.stderr.decode(errors='replace'))
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(result.stderr.count(b'Command cancelled.'), 1, result.stderr)
                self.assertFalse(self.marker.exists())
                self.run_probe(kind, path, 'acquire')

    @unittest.skipIf(WINDOWS, 'POSIX symlink refusal')
    def test_linux_sidecar_symlinks_are_not_followed(self):
        source = self.root / 'source'
        source.write_bytes(b'keep')
        self.library_lock.symlink_to(source)
        self.run_probe('library', self.library_lock, 'acquire', error=b'lock file')
        self.assertEqual(source.read_bytes(), b'keep')
        self.assertTrue(self.library_lock.is_symlink())

    @unittest.skipUnless(WINDOWS, 'Windows sidecar protection')
    def test_windows_sidecars_cannot_be_replaced_while_in_use(self):
        for kind, path in (('library', self.library_lock), ('output', self.output)):
            with self.subTest(kind=kind):
                holder = self.hold(kind, path)
                # Native Windows deletion is tested through the probe in the
                # backend: host unlink would bypass Wine's sharing checks.
                result = self.run_probe('protect', path if kind == 'library' else path / '.scu-output.lock',
                                        'acquire', error=b'protected')
                self.release(holder)


if __name__ == '__main__':
    unittest.main()
