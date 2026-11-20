#!/usr/bin/env python3
"""File-service regressions; the same probe can run natively or under Wine."""
import concurrent.futures
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

PROBE = Path(sys.argv.pop(1) if len(sys.argv) > 1 else 'build/files_probe').resolve()
WINE = '--wine' in sys.argv
if WINE:
    sys.argv.remove('--wine')
WINDOWS = WINE or os.name == 'nt'
if not WINDOWS:
    import fcntl


def argument(value):
    if WINE and isinstance(value, Path):
        return 'Z:' + str(value.absolute()).replace('/', '\\')
    return str(value)


def command(*args):
    return (['wine', str(PROBE)] if WINE else [str(PROBE)]) + [argument(v) for v in args]


def host_path(value):
    value = value.decode().strip()
    if WINE:
        if value.startswith('Z:'):
            return Path(value[2:].replace('\\', '/'))
        return Path(os.environ['WINEPREFIX']) / ('drive_' + value[0].lower()) / value[3:].replace('\\', '/')
    return Path(value)


class FileTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'input.bin'
        self.output = self.root / 'output.bin'
        self.source.write_bytes(bytes(range(256)) * 257 + b'\r\n\x00last\n')

    def probe(self, *args, error=None, **kwargs):
        result = subprocess.run(command(*args), capture_output=True, timeout=20, **kwargs)
        if error is None:
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)
        return result

    def leftovers(self):
        return list(self.root.glob('.scu-tmp-*'))

    def test_binary_read_and_atomic_write_preserve_every_byte(self):
        data = self.source.read_bytes()
        self.probe('write', self.source, self.output)
        self.assertEqual(self.output.read_bytes(), data)
        self.assertEqual(self.probe('read', self.output, len(data)).stdout, data)
        self.assertEqual(self.leftovers(), [])
        self.probe('read', self.output, len(data) - 1, error=b'byte limit')
        self.probe('read', self.output, -1, error=b'byte limit')

    def test_empty_output_and_stream_position(self):
        self.probe('stream', self.source, self.output, '', 37)
        self.assertEqual(self.output.read_bytes(), self.source.read_bytes()[37:])
        self.probe('stream', self.source, self.output, '', self.source.stat().st_size)
        self.assertEqual(self.output.read_bytes(), b'')
        self.assertEqual(self.probe('read', self.output, 0).stdout, b'')

    def test_stream_failure_keeps_old_output_and_cleans_temporary_file(self):
        self.output.write_bytes(b'previous')
        self.probe('fail', self.source, self.output, error=b'Could not write')
        self.assertEqual(self.output.read_bytes(), b'previous')
        self.assertEqual(self.leftovers(), [])
        self.output.unlink()
        self.probe('fail', self.source, self.output, error=b'Could not write')
        self.assertFalse(self.output.exists())
        self.assertEqual(self.leftovers(), [])

    def test_cancellation_is_not_reclassified_and_cleans_temporary_file(self):
        self.output.write_bytes(b'previous')
        result = self.probe('cancel', self.source, self.output, error=b'Injected cancellation')
        self.assertNotIn(b'Could not write', result.stderr)
        self.assertEqual(self.output.read_bytes(), b'previous')
        self.assertEqual(self.leftovers(), [])

    def test_sync_failures_retain_path_context(self):
        self.probe('sync_invalid', self.output, error=b'Could not sync')
        self.probe('sync_parent', self.output)
        self.probe('sync_parent', self.root / 'missing' / 'file', error=b'missing')

    def test_no_replace_refuses_existing_file_and_directory(self):
        self.output.write_bytes(b'previous')
        self.probe('write', self.source, self.output, 'n', error=b'Could not')
        self.assertEqual(self.output.read_bytes(), b'previous')
        self.output.unlink()
        self.output.mkdir()
        self.probe('write', self.source, self.output, 'n', error=b'Could not')
        self.assertTrue(self.output.is_dir())
        self.assertEqual(self.leftovers(), [])

    def test_competing_no_replace_writers_have_exactly_one_winner(self):
        sources = []
        for index in range(6):
            source = self.root / f'candidate-{index}'
            source.write_bytes(bytes([index]) * 8192)
            sources.append(source)
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(lambda source: subprocess.run(
                command('write', source, self.output, 'n'), capture_output=True, timeout=20), sources))
        winners = [index for index, result in enumerate(results) if result.returncode == 0]
        self.assertEqual(len(winners), 1, [r.stderr for r in results])
        self.assertEqual(self.output.read_bytes(), sources[winners[0]].read_bytes())
        self.assertEqual(self.leftovers(), [])

    def test_readers_never_observe_partially_written_content(self):
        old = b'old' * 32768
        new = self.source.read_bytes()
        self.output.write_bytes(old)
        process = subprocess.Popen(command('repeat', self.source, self.output, '30'),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        observations = 0
        while process.poll() is None:
            self.assertIn(self.output.read_bytes(), (old, new))
            observations += 1
        stdout, stderr = process.communicate(timeout=20)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertGreater(observations, 0)
        self.assertEqual(self.output.read_bytes(), new)
        self.assertEqual(self.leftovers(), [])

    def test_replace_failure_keeps_directory_and_cleans_temporary_file(self):
        self.output.mkdir()
        (self.output / 'keep').write_bytes(b'keep')
        self.probe('write', self.source, self.output, error=b'Could not')
        self.assertEqual((self.output / 'keep').read_bytes(), b'keep')
        self.assertEqual(self.leftovers(), [])

    def test_regular_file_checks_and_sqlite_header(self):
        self.assertEqual(self.probe('regular', '').stdout.strip(), b'0')
        self.assertEqual(self.probe('sqlite', '').stdout.strip(), b'0')
        self.assertEqual(self.probe('regular', self.output).stdout.strip(), b'0')
        self.assertEqual(self.probe('regular', self.source).stdout.strip(), b'1')
        self.probe('regular', self.root, error=b'regular file')
        self.probe('read', self.root, 999999, error=b'regular file')
        self.assertEqual(self.probe('sqlite', self.root).stdout.strip(), b'0')
        self.assertEqual(self.probe('sqlite', self.source).stdout.strip(), b'0')
        database = self.root / 'data.sqlite'
        database.write_bytes(b'SQLite format 3\x00' + b'body')
        self.assertEqual(self.probe('sqlite', database).stdout.strip(), b'1')
        for suffix in ('.lock', '-journal', '-wal', '-shm'):
            self.assertEqual(self.probe('companion', Path(str(database) + suffix)).stdout.strip(), b'1')
        self.assertEqual(self.probe('companion', self.root / '.data.sqlite.lock').stdout.strip(), b'1')
        if WINDOWS:
            self.assertEqual(self.probe('companion', Path(str(database) + '.LOCK')).stdout.strip(), b'1')
        database.write_bytes(b'SQLite format 3')
        self.assertEqual(self.probe('sqlite', database).stdout.strip(), b'0')

    def paused_writer(self):
        process = subprocess.Popen(command('pause', self.source, self.output),
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        self.assertEqual(process.stdout.readline().strip(), b'ready')
        return process

    def test_cleanup_does_not_remove_an_active_atomic_output(self):
        process = self.paused_writer()
        temporary = self.leftovers()
        self.assertEqual(len(temporary), 1)
        self.probe('cleanup', self.root)
        self.assertTrue(temporary[0].exists())
        stdout, stderr = process.communicate(b'continue\n', timeout=20)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertEqual(self.output.read_bytes(), self.source.read_bytes())
        self.assertEqual(self.leftovers(), [])

    def test_interrupted_atomic_output_is_recovered(self):
        self.output.write_bytes(b'previous')
        process = self.paused_writer()
        self.assertEqual(len(self.leftovers()), 1)
        process.kill()
        process.communicate(timeout=20)
        self.assertEqual(self.output.read_bytes(), b'previous')
        self.probe('cleanup', self.root)
        self.assertEqual(self.leftovers(), [])

    def test_stale_stages_remove_only_known_regular_children(self):
        stage = host_path(self.probe('stage', self.root).stdout)
        self.probe('write', self.source, stage / '.owner')
        # Create staged data through the Windows API too: Wine cannot infer
        # Windows ownership reliably for files created directly by the host.
        self.probe('write', self.source, stage / '1')
        self.probe('cleanup', self.root)
        self.assertFalse(stage.exists())
        stage = host_path(self.probe('stage', self.root).stdout)
        self.probe('write', self.source, stage / '.owner')
        (stage / 'unknown').write_bytes(b'keep')
        (stage / '2').mkdir()
        self.probe('cleanup', self.root)
        self.assertEqual((stage / 'unknown').read_bytes(), b'keep')
        self.assertTrue((stage / '2').is_dir())

    def test_unmarked_stages_and_unrelated_temporary_names_are_untouched(self):
        stage = host_path(self.probe('stage', self.root).stdout)
        (stage / '1').write_bytes(b'keep')
        unknown = self.root / '.scu-tmp-invalid'
        unknown.write_bytes(b'keep')
        self.probe('cleanup', self.root)
        self.assertTrue((stage / '1').exists())
        self.assertTrue(unknown.exists())

    def test_temporary_and_staging_directories_are_unique(self):
        stages = [host_path(self.probe('stage', self.root).stdout) for _ in range(3)]
        self.assertEqual(len(set(stages)), 3)
        for stage in stages:
            self.assertTrue(stage.is_dir())
            self.assertEqual(stage.parent, self.root)
            if not WINDOWS:
                self.assertEqual(stage.stat().st_mode & 0o777, 0o700)
        temporary = host_path(self.probe('temp', 'scu-files-test').stdout)
        try:
            self.assertTrue(temporary.is_dir())
            if not WINDOWS:
                self.assertEqual(temporary.stat().st_mode & 0o777, 0o700)
        finally:
            shutil.rmtree(temporary)

    @unittest.skipIf(WINDOWS, 'POSIX symlink semantics')
    def test_symlinks_are_refused_or_replaced_without_modifying_the_target(self):
        self.output.symlink_to(self.source)
        self.assertEqual(self.probe('read', self.output, self.source.stat().st_size).stdout,
                         self.source.read_bytes())
        self.probe('read', self.output, 999999, 'nofollow', error=b'symbolic link')
        self.probe('regular', self.output, error=b'regular file')
        self.assertEqual(self.probe('sqlite', self.output).stdout.strip(), b'0')
        self.probe('write', self.source, self.output, 'n', error=b'Could not')
        self.assertTrue(self.output.is_symlink())
        self.probe('write', self.source, self.output)
        self.assertFalse(self.output.is_symlink())
        self.assertEqual(self.output.read_bytes(), self.source.read_bytes())

    @unittest.skipIf(WINDOWS, 'POSIX permissions and umask')
    def test_private_and_source_output_permissions_are_unchanged(self):
        self.probe('write', self.source, self.output, umask=0)
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o600)
        self.output.chmod(0o754)
        self.probe('write', self.source, self.output, 's', umask=0o077)
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o754)
        self.output.unlink()
        self.probe('write', self.source, self.output, 's', umask=0o027)
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o640)

    @unittest.skipIf(WINDOWS, 'POSIX nonblocking special-file handling')
    def test_fifo_and_device_reads_fail_without_blocking(self):
        fifo = self.root / 'fifo'
        os.mkfifo(fifo)
        self.probe('read', fifo, 999999, error=b'regular file')
        self.probe('read', Path('/dev/null'), 999999, error=b'regular file')
        self.assertEqual(self.probe('sqlite', fifo).stdout.strip(), b'0')

    @unittest.skipIf(WINDOWS, 'POSIX raw filenames')
    def test_linux_backslash_names_and_unicode_files_round_trip(self):
        self.output = self.root / 'déck\\with:bytes'
        self.probe('write', self.source, self.output)
        self.assertEqual(self.output.read_bytes(), self.source.read_bytes())

    @unittest.skipUnless(WINDOWS, 'Windows file sharing')
    def test_windows_open_reader_with_delete_sharing_is_handled_safely(self):
        self.output.write_bytes(b'previous')
        result = subprocess.run(command('shared', self.source, self.output),
                                capture_output=True, timeout=20)
        # MoveFileEx replacement of an open target is filesystem/runtime
        # dependent. Both success and a safe, explicit refusal are valid.
        if result.returncode == 0:
            self.assertEqual(self.output.read_bytes(), self.source.read_bytes())
        else:
            self.assertIn(b'holding the file open', result.stderr)
            self.assertEqual(self.output.read_bytes(), b'previous')
        self.assertEqual(self.leftovers(), [])

    @unittest.skipUnless(WINDOWS, 'Windows file sharing')
    def test_windows_blocking_reader_produces_clear_error_and_no_data_loss(self):
        self.output.write_bytes(b'previous')
        self.probe('blocked', self.source, self.output, error=b'holding the file open')
        self.assertEqual(self.output.read_bytes(), b'previous')
        self.assertEqual(self.leftovers(), [])

    @unittest.skipUnless(WINDOWS, 'Windows DACL preservation')
    def test_windows_source_output_preserves_access(self):
        self.probe('write', self.source, self.output)
        before = self.probe('access', self.output).stdout
        self.probe('write', self.source, self.output, 's')
        self.assertEqual(self.probe('access', self.output).stdout, before)

    @unittest.skipUnless(WINDOWS, 'Windows staging ownership lock')
    def test_windows_active_stage_marker_is_not_cleaned_up(self):
        stage = host_path(self.probe('stage', self.root).stdout)
        self.probe('write', self.source, stage / '.owner')
        self.probe('write', self.source, stage / '1')
        process = subprocess.Popen(command('hold_owner', stage / '.owner'),
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        self.assertEqual(process.stdout.readline().strip(), b'ready')
        self.probe('cleanup', self.root)
        self.assertTrue((stage / '1').exists())
        stdout, stderr = process.communicate(b'continue\n', timeout=20)
        self.assertEqual(process.returncode, 0, stderr)
        self.probe('cleanup', self.root)
        self.assertFalse(stage.exists())

    @unittest.skipUnless(WINDOWS, 'Windows reparse-point handling')
    def test_windows_reparse_points_are_refused_and_never_followed_by_cleanup(self):
        result = subprocess.run(command('link', self.output, self.source), capture_output=True, timeout=20)
        if result.returncode == 77:
            self.skipTest(result.stderr.decode(errors='replace'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.probe('read', self.output, self.source.stat().st_size).stdout,
                         self.source.read_bytes())
        self.probe('read', self.output, 999999, 'nofollow', error=b'reparse point')
        self.probe('regular', self.output, error=b'regular file')
        self.assertEqual(self.probe('sqlite', self.output).stdout.strip(), b'0')
        self.probe('write', self.source, self.output, 'n', error=b'Could not')
        self.probe('write', self.source, self.output)
        self.assertEqual(self.output.read_bytes(), self.source.read_bytes())
        self.assertEqual(self.probe('regular', self.output).stdout.strip(), b'1')

    @unittest.skipUnless(WINDOWS, 'Windows Unicode wide APIs and long paths')
    def test_windows_unicode_and_long_paths(self):
        directory = self.root
        for _ in range(5):
            directory /= 'long-directory-' + 'x' * 34
            directory.mkdir()
        self.output = directory / 'déck-日本語.bin'
        self.assertGreater(len(str(self.output)), 260)
        self.probe('write', self.source, self.output)
        self.assertTrue(self.output.exists())
        self.assertEqual(self.probe('read', self.output, self.source.stat().st_size).stdout,
                         self.source.read_bytes())


if __name__ == '__main__':
    unittest.main()
