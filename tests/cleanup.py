#!/usr/bin/env python3
"""Release and editor-directory cleanup regressions, native or under Wine."""
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

PROBE = Path(sys.argv.pop(1) if len(sys.argv) > 1 else 'build/cleanup_probe').resolve()
WINE = '--wine' in sys.argv
if WINE:
    sys.argv.remove('--wine')
WINDOWS = WINE or os.name == 'nt'


def argument(value):
    if WINE and isinstance(value, Path):
        return 'Z:' + str(value.absolute()).replace('/', '\\')
    return str(value)


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.release = self.root / 'release'
        self.release.mkdir()
        self.editor = self.root / 'editor'
        self.editor.mkdir()
        self.library = self.release / 'library.sqlite'

    def run_probe(self, *args):
        command = (['wine', str(PROBE)] if WINE else [str(PROBE)])
        return subprocess.run(command + [argument(arg) for arg in args], capture_output=True, timeout=30)

    def probe(self, *args, error=None):
        result = self.run_probe(*args)
        if error is None:
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)
        return result.stdout.decode('utf-8').replace('\r\n', '\n')

    def collect(self, patterns='*', selected='', tracked=''):
        return self.probe('collect', self.release, self.library, patterns, selected, tracked).splitlines()

    def populate_editor(self):
        (self.editor / 'main.c').write_bytes(b'source\x00\xff')
        (self.editor / '.swap').write_text('editor backup')
        (self.editor / 'backups' / '日本').mkdir(parents=True)
        (self.editor / 'backups' / '日本' / 'saved😀.c').write_text('nested')

    def link(self, path, target, directory=False):
        if WINDOWS:
            result = self.run_probe('link', path, target, int(directory))
            if result.returncode == 77:
                self.skipTest('Runtime/filesystem lacks observable Windows reparse links')
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            path.symlink_to(target, target_is_directory=directory)

    def test_editor_removes_nested_unicode_hidden_and_binary_files(self):
        self.populate_editor()
        self.probe('editor', self.editor)
        self.assertFalse(self.editor.exists())

    def test_editor_cleanup_does_not_mask_original_failure(self):
        self.populate_editor()
        self.probe('failure', self.editor, error=b'Original editor failure')
        self.assertFalse(self.editor.exists())

    def test_editor_cleanup_does_not_consume_pending_cancellation(self):
        self.populate_editor()
        self.probe('cancel', self.editor, error=b'Command cancelled')
        self.assertFalse(self.editor.exists())

    def test_editor_cleanup_is_idempotent_for_empty_and_missing_directory(self):
        self.probe('editor', self.editor)
        self.probe('editor', self.editor)
        self.assertFalse(self.editor.exists())

    def test_editor_cleanup_does_not_follow_file_or_directory_links(self):
        outside = self.root / 'outside'
        outside.mkdir()
        sentinel = outside / 'sentinel'
        sentinel.write_text('preserve')
        self.link(self.editor / 'file-link', sentinel)
        self.link(self.editor / 'directory-link', outside, directory=True)
        self.link(self.editor / 'dangling-link', outside / 'absent')
        self.probe('editor', self.editor)
        self.assertEqual(sentinel.read_text(), 'preserve')
        self.assertFalse(self.editor.exists())

    def test_editor_long_path_and_many_directory_records(self):
        self.editor = self.editor / ('x' * 120) / ('y' * 120) / '日本'
        self.editor.mkdir(parents=True)
        # More than one native enumeration buffer, with stable sorted names.
        for index in range(1700):
            (self.editor / ('long-file-name-' + str(index).zfill(5) + '.bak')).write_text('data')
        self.probe('editor', self.editor)
        self.assertFalse(self.editor.exists())

    @unittest.skipUnless(WINDOWS, 'Windows blocked handles and best-effort cleanup')
    def test_windows_blocked_file_leaves_original_error_and_no_handle_leak(self):
        path = self.editor / 'held.c'
        path.write_text('held')
        self.probe('blocked', self.editor, path)
        self.assertFalse(self.editor.exists())

    @unittest.skipUnless(WINDOWS, 'Windows read-only editor backups')
    def test_windows_read_only_editor_backups_are_removed_or_left_intact(self):
        for name, flag in [('readonly.c', 'readonly'), ('hidden.c', 'hidden')]:
            path = self.editor / name
            path.write_text('backup')
            self.probe('attributes', path, flag)
        self.probe('editor', self.editor)
        self.assertFalse((self.editor / 'hidden.c').exists())
        readonly = self.editor / 'readonly.c'
        if readonly.exists():
            # Some runtimes deny opening a read-only file with DELETE access.
            # Best-effort cleanup must leave it protected, without hiding the
            # editor's original result or following another path to force it.
            self.assertEqual(readonly.read_text(), 'backup')
            self.assertFalse(readonly.stat().st_mode & 0o200)
        else:
            self.assertFalse(self.editor.exists())

    @unittest.skipUnless(WINDOWS, 'Windows root reparse-point refusal')
    def test_windows_editor_root_link_is_left_untouched_even_with_trailing_separator(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (outside / 'sentinel').write_text('preserve')
        root_link = self.root / 'root-link'
        self.link(root_link, outside, directory=True)
        self.probe('editor', argument(root_link) + '\\')
        self.assertTrue(root_link.is_symlink() or root_link.exists())
        self.assertEqual((outside / 'sentinel').read_text(), 'preserve')

    @unittest.skipUnless(WINDOWS, 'Windows hard-link attribute isolation')
    def test_windows_read_only_hard_link_never_changes_external_attributes(self):
        outside = self.root / 'outside.c'
        outside.write_text('preserve')
        linked = self.editor / 'linked.c'
        self.probe('hardlink', linked, outside)
        self.probe('attributes', outside, 'readonly')
        try:
            self.probe('editor', self.editor)
            self.assertEqual(outside.read_text(), 'preserve')
            self.assertFalse(outside.stat().st_mode & 0o200)
        finally:
            self.probe('attributes', outside, 'normal')

    def test_release_candidates_match_patterns_and_preserve_selected_or_nonregular_entries(self):
        for name in ['obsolete.c', 'current.c', 'notes.txt', '.hidden.c']:
            (self.release / name).write_text('source')
        (self.release / 'sub.c').mkdir()
        (self.release / 'sub.c' / 'inside.c').write_text('keep')
        self.assertEqual(self.collect('*.c', 'current.c'), ['obsolete.c'])
        self.assertEqual(self.collect('.*.c', 'current.c'), ['.hidden.c'])

    def test_release_manifest_candidates_include_missing_files_and_deduplicate(self):
        (self.release / 'old.c').write_text('old')
        (self.release / 'directory.c').mkdir()
        self.assertEqual(self.collect('*.c', 'current.c', 'missing.c\nold.c\nold.c\ncurrent.c\ndirectory.c'),
                         ['missing.c', 'old.c'])

    def test_release_candidates_protect_library_foreign_sqlite_and_companions(self):
        for name in ['library.sqlite', 'foreign.data']:
            with sqlite3.connect(self.release / name) as db:
                db.execute('CREATE TABLE source(x)')
        for name in ['library.sqlite.lock', 'library.sqlite-journal', 'library.sqlite-wal',
                     'library.sqlite-shm', 'foreign.data-wal', '.scu-exports.json', 'obsolete.c']:
            (self.release / name).write_text('keep')
        self.assertEqual(self.collect(), ['obsolete.c'])

    def test_release_eligible_does_not_follow_selected_links(self):
        outside = self.root / 'outside.c'
        outside.write_text('preserve')
        self.link(self.release / 'link.c', outside)
        self.assertEqual(self.collect('*.c', '', 'link.c'), [])
        self.assertEqual(outside.read_text(), 'preserve')

    def test_release_eligible_missing_errors_retain_filename(self):
        missing = self.release / 'missing.c'
        self.assertEqual(self.probe('inspect', missing, 'missing').strip(), '1')
        self.probe('inspect', missing, error=b'missing.c')

    def test_release_delete_only_removes_requested_file_and_supports_long_unicode_paths(self):
        directory = self.release / ('x' * 120) / ('y' * 120) / '日本'
        directory.mkdir(parents=True)
        path = directory / 'obsolete😀.c'
        keep = directory / 'keep.c'
        path.write_text('old'); keep.write_text('keep')
        self.probe('release-delete', path)
        self.assertFalse(path.exists())
        self.assertEqual(keep.read_text(), 'keep')
        self.probe('release-delete', path, error=b'obsolete')

    def test_release_directory_creation_and_file_refusal(self):
        directory = self.release / ('x' * 120) / ('y' * 120) / '日本'
        self.probe('ensure', directory)
        self.assertTrue(directory.is_dir())
        self.probe('ensure', directory)
        path = self.release / 'not-directory'
        path.write_text('keep')
        self.probe('ensure', path, error=b'real export directory')
        self.assertEqual(path.read_text(), 'keep')

    def test_release_directory_root_symlink_is_refused(self):
        outside = self.root / 'outside'
        outside.mkdir()
        link = self.release / 'root-link'
        self.link(link, outside, directory=True)
        self.probe('ensure', link, error=b'real export directory')
        self.assertTrue(outside.is_dir())

    @unittest.skipUnless(WINDOWS, 'Windows case aliases and platform control files')
    def test_windows_release_case_aliases_do_not_select_or_delete_protected_outputs(self):
        for name in ['CURRENT.C', 'old.c', '.SCU-EXPORTS.JSON', '.SCU-OUTPUT.LOCK', 'LIBRARY.SQLITE-WAL']:
            (self.release / name).write_text('keep')
        self.assertEqual(self.collect('*.c', 'current.c', 'OLD.C\ncurrent.c'), ['old.c'])
        self.assertEqual(self.collect('.*', '', '.SCU-EXPORTS.JSON\n.SCU-OUTPUT.LOCK'), [])
        self.assertEqual(self.collect('*', 'current.c'), ['old.c'])

    @unittest.skipUnless(WINDOWS, 'Windows stale manifest traversal refusal')
    def test_windows_cleanup_rejects_manifest_path_or_stream_names(self):
        outside = self.root / 'outside.c'
        outside.write_text('preserve')
        for name in ['..\\outside.c', 'old.c:stream.c']:
            self.probe('collect', self.release, self.library, '*.c', '', name, error=b'filename')
        self.assertEqual(outside.read_text(), 'preserve')

    @unittest.skipUnless(WINDOWS, 'Windows hidden release cleanup')
    def test_windows_release_hidden_attribute_does_not_hide_obsolete_files(self):
        path = self.release / 'old.c'
        path.write_text('obsolete')
        self.probe('attributes', path, 'hidden')
        self.assertEqual(self.collect('*.c'), ['old.c'])

    @unittest.skipUnless(WINDOWS, 'Windows release read-only attributes are preserved')
    def test_windows_release_read_only_deletion_fails_with_context(self):
        path = self.release / 'old.c'
        path.write_text('preserve')
        self.probe('attributes', path, 'readonly')
        try:
            self.probe('release-delete', path, error=b'old.c')
            self.assertTrue(path.exists())
            self.assertFalse(path.stat().st_mode & 0o200)
        finally:
            self.probe('attributes', path, 'normal')

    @unittest.skipUnless(WINDOWS, 'Windows release no-follow deletion')
    def test_windows_release_delete_refuses_reparse_entries(self):
        outside = self.root / 'outside.c'
        outside.write_text('preserve')
        link = self.release / 'link.c'
        self.link(link, outside)
        self.probe('release-delete', link, error=b'non-regular release file')
        self.assertEqual(outside.read_text(), 'preserve')

    @unittest.skipIf(WINDOWS, 'Original Linux filename bytes and symlink unlink behavior')
    def test_linux_release_names_and_symlink_unlink_are_unchanged(self):
        for name in ['back\\slash.c', 'colon:file.c']:
            (self.release / name).write_text('source')
        self.assertEqual(self.collect('*.c'), ['back\\slash.c', 'colon:file.c'])
        outside = self.root / 'outside.c'
        outside.write_text('keep')
        link = self.release / 'link.c'
        link.symlink_to(outside)
        self.probe('release-delete', link)
        self.assertFalse(link.exists())
        self.assertEqual(outside.read_text(), 'keep')

if __name__ == '__main__':
    unittest.main()
