#!/usr/bin/env python3
"""Working-file scans and nested command-file paths, native or under Wine."""
import hashlib
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

PROBE = Path(sys.argv.pop(1) if len(sys.argv) > 1 else 'build/scan_probe').resolve()
WINE = '--wine' in sys.argv
if WINE:
    sys.argv.remove('--wine')
WINDOWS = WINE or os.name == 'nt'


def argument(value):
    if WINE and isinstance(value, Path):
        return 'Z:' + str(value.absolute()).replace('/', '\\')
    return str(value)


class ScanningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.library = self.root / 'library.sqlite'

    def probe(self, *args, error=None, cwd=None):
        command = (['wine', str(PROBE)] if WINE else [str(PROBE)])
        result = subprocess.run(command + [argument(arg) for arg in args],
                                cwd=cwd, capture_output=True, timeout=30)
        if error is None:
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)
        return result.stdout.decode('utf-8').replace('\r\n', '\n')

    def scan(self, pattern='*', mode='scan', *extra):
        return self.probe(mode, self.root, self.library, pattern, *extra).splitlines()

    def touch(self, name):
        (self.root / name).write_text('source', encoding='utf-8')

    def test_matching_and_sorted_nonrecursive_scan(self):
        for name in ['z.c', 'main.pas', 'a.c', 'Makefile', '.hidden.c']:
            self.touch(name)
        (self.root / 'sub.c').mkdir()
        (self.root / 'sub.c' / 'nested.c').write_text('nested')
        self.assertEqual(self.scan('*.c'), ['a.c|a.c', 'z.c|z.c'])
        self.assertEqual(self.scan('Makefile'), ['makefile|Makefile'])

    def test_owners_preserve_deck_identity(self):
        self.touch('main.pas')
        self.assertEqual(self.scan('*.pas', 'owner', 'main.pas'), ['tracked-deck|main.pas'])

    @unittest.skipUnless(WINDOWS, 'Windows case-insensitive source ownership')
    def test_windows_owner_lookup_and_conflicts_ignore_case(self):
        self.touch('main.pas')
        self.assertEqual(self.scan('*.PAS', 'owner', 'MAIN.PAS'), ['tracked-deck|main.pas'])
        self.probe('owners', self.root, self.library, '*.pas', 'main.pas', 'MAIN.PAS',
                   error=b'Several decks track source')

    def test_source_hash_is_stable_for_unicode_and_space_names(self):
        for name in ['hello world.c', '日本.c', 'smile😀.c']:
            self.touch(name)
        expected = sorted('file-' + hashlib.sha256(name.encode()).hexdigest() + '|' + name
                          for name in ['hello world.c', '日本.c', 'smile😀.c'])
        self.assertEqual(self.scan('*.c'), expected)

    def test_scan_long_unicode_directory(self):
        self.root = self.root / ('long-' + 'x' * 110) / ('long-' + 'y' * 110) / '日本'
        self.root.mkdir(parents=True)
        self.library = self.root / 'library.sqlite'
        self.touch('main.pas')
        self.assertEqual(self.scan('*.pas'), ['main.pas|main.pas'])

    def test_storage_manifest_and_foreign_sqlite_are_excluded(self):
        for name in ['library.sqlite', 'foreign.data']:
            with sqlite3.connect(self.root / name) as db:
                db.execute('CREATE TABLE data(x)')
        for name in ['library.sqlite.lock', 'library.sqlite-journal', 'library.sqlite-wal',
                     'library.sqlite-shm', 'foreign.data-wal', '.scu-exports.json', 'main.c']:
            self.touch(name)
        self.assertEqual(self.scan('*'), ['main.c|main.c'])
        self.assertEqual(self.scan('.scu-exports.json'), [])
        if WINDOWS:
            self.touch('.SCU-EXPORTS.JSON')
            self.assertEqual(self.scan('.SCU-EXPORTS.JSON'), [])
            self.touch('.scu-output.lock')
            self.assertEqual(self.scan('.scu-output.lock'), [])

    def test_patterns_reject_subdirectories(self):
        for pattern in ['src/*.c', 'src\\*.c', '../*', '/etc/*']:
            self.probe('scan', self.root, self.library, pattern, error=b'')

    def test_missing_directory_has_context(self):
        self.probe('scan', self.root / 'missing', self.library, '*', error=b'missing')

    def test_pending_cancellation_is_preserved(self):
        self.touch('main.c')
        self.probe('cancel', self.root, self.library, '*', error=b'Command cancelled')

    def test_globs(self):
        for pattern, name, expected in [('*', 'plain', True), ('*.*', 'plain', False),
                ('?.c', 'a.c', True), ('?.c', 'ab.c', False), ('[a-c].c', 'b.c', True),
                ('[!a-c].c', 'z.c', True), ('[!a-c].c', 'b.c', False),
                ('[]].c', '].c', True), ('[.c', '[.c', True),
                ('*', '.hidden', False), ('.*', '.hidden', True),
                ('a*b?c', 'alongbxc', True), ('a*b?c', 'alongbc', False),
                ('[a-c]*', 'b', True), ('*a*a*b', 'aaaaaac', False)]:
            with self.subTest(pattern=pattern, name=name):
                self.assertEqual(self.probe('match', pattern, name).strip(), str(int(expected)))

    @unittest.skipUnless(WINDOWS, 'Windows wildcard semantics')
    def test_windows_globs_case_unicode_and_scalar_question_mark(self):
        for pattern, name in [('*.C', 'main.c'), ('?.c', '😀.c'), ('[😀].c', '😀.c'),
                              ('é?.C', 'É日.c')]:
            self.assertEqual(self.probe('match', pattern, name).strip(), '1')

    @unittest.skipUnless(WINDOWS, 'Windows source filename policy')
    def test_windows_source_names_reject_paths_streams_devices_and_aliases(self):
        for name in ['src\\main.c', 'C:main.c', 'main.c:stream', 'NUL.c', 'CON', 'com1.c',
                     'lpt².c', 'bad?.c', 'bad*', 'name.', 'name ', '.SCU-EXPORTS.JSON', '.SCU-OUTPUT.LOCK']:
            self.probe('name', name, error=b'')
        self.probe('name', 'normal.c')

    @unittest.skipUnless(WINDOWS, 'Windows hidden attributes')
    def test_hidden_attribute_is_not_snapshotted(self):
        self.touch('hidden.c')
        self.probe('hidden', self.root / 'hidden.c')
        self.assertEqual(self.scan('*.c'), [])
        self.assertEqual(self.scan('hidden.c'), [])

    def test_selected_links_are_rejected(self):
        self.touch('target.txt')
        link = self.root / 'link.c'
        if WINDOWS:
            command = (['wine', str(PROBE)] if WINE else [str(PROBE)])
            result = subprocess.run(command + ['link', argument(link), argument(self.root / 'target.txt')],
                                    capture_output=True, timeout=30)
            if result.returncode == 77:
                self.skipTest(result.stderr.decode(errors='replace'))
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            link.symlink_to('target.txt')
        self.probe('scan', self.root, self.library, '*.c', error=b'symbolic link')
        self.assertEqual((self.root / 'target.txt').read_text(), 'source')

    @unittest.skipIf(WINDOWS, 'POSIX bytes and case-sensitive globs')
    def test_linux_names_and_globs_remain_unchanged(self):
        for name in ['back\\slash.c', 'colon:file.c']:
            self.probe('name', name)
            self.touch(name)
        self.assertEqual(len(self.scan('*.c')), 2)
        self.assertEqual(self.probe('match', '*.C', 'main.c').strip(), '0')
        self.assertEqual(self.probe('match', '[[:digit:]].c', '1.c').strip(), '1')

    def test_nested_files_relative_absolute_and_return_order(self):
        scripts = self.root / 'scripts space'
        scripts.mkdir()
        child = scripts / 'child 日本.scu'
        child.write_text('child-1\nchild-2\n', encoding='utf-8')
        absolute = self.root / 'absolute.scu'
        absolute.write_text('absolute\n')
        main = scripts / 'main.scu'
        main.write_text("parent-1\n!'child 日本.scu'\n!'" + argument(absolute) + "'\nparent-2\n", encoding='utf-8')
        lines = self.probe('files', main).splitlines()
        self.assertEqual([line.rsplit('|', 1)[1] for line in lines],
                         ['parent-1', 'child-1', 'child-2', 'absolute', 'parent-2'])
        self.assertIn('child 日本.scu:2|child-2', lines[2])
        self.assertTrue(lines[-1].endswith('main.scu:4|parent-2'))

    def test_invocation_arguments_preserve_unicode_empty_and_windows_paths(self):
        values = ['日本.scu', '', 'file with space.scu', r'C:\scripts\main.scu',
                  r'\\server\share\child.scu', 'smile😀.scu']
        self.assertEqual(self.probe('argv', *values).splitlines(), ['arg:' + value for value in values])

    def test_command_filename_parser_rejects_multiple_names_and_unclosed_quotes(self):
        self.probe('parse-file', 'one.scu two.scu', error=b'Expected one command filename')
        self.probe('parse-file', '"unclosed', error=b'Unclosed quote')
        self.probe('parse-file', '', error=b'Expected one command filename')

    @unittest.skipUnless(WINDOWS, 'Windows literal backslashes in ! filenames')
    def test_windows_command_filename_parser_preserves_slashes(self):
        for specification, expected in [
                (r'C:\scripts\child.scu', r'C:\scripts\child.scu'),
                (r'\\server\share\child.scu', r'\\server\share\child.scu'),
                ('"C:\\scripts space\\child.scu"', r'C:\scripts space\child.scu'),
                ('"\\\\server\\share space\\child.scu"', r'\\server\share space\child.scu'),
                ("'C:\\scripts space\\child.scu'", r'C:\scripts space\child.scu'),
                (r'\\?\C:\scripts\child.scu', r'\\?\C:\scripts\child.scu')]:
            with self.subTest(specification=specification):
                self.assertEqual(self.probe('parse-file', specification).strip(), expected)

    def test_command_files_lf_crlf_empty_and_partial_final_line(self):
        path = self.root / 'lines.scu'
        path.write_bytes(b'first\r\n\r\nlast')
        lines = self.probe('files', path).splitlines()
        self.assertEqual([line.rsplit('|', 1)[1] for line in lines], ['first', '', 'last'])
        path.write_bytes(b'')
        self.assertEqual(self.probe('files', path), '')

    def test_nested_missing_file_reports_resolved_path(self):
        directory = self.root / 'scripts'
        directory.mkdir()
        path = directory / 'main.scu'
        path.write_text('!missing.scu\n')
        self.probe('files', path, error=b'missing.scu')

    def test_command_files_depth_limit(self):
        path = self.root / 'main.scu'
        path.write_text('command\n')
        self.probe('depth', path, error=b'16 levels')

    @unittest.skipUnless(WINDOWS, 'Windows drive, UNC and root resolution')
    def test_windows_command_file_path_forms(self):
        for filename, parent, expected in [
                ('C:\\other\\child.scu', 'Z:\\scripts\\main.scu', 'C:\\other\\child.scu'),
                ('C:/other/child.scu', 'Z:/scripts/main.scu', 'C:\\other\\child.scu'),
                ('\\\\server\\share\\child.scu', 'Z:\\scripts\\main.scu', '\\\\server\\share\\child.scu'),
                ('\\child.scu', 'Z:\\scripts\\main.scu', 'Z:\\child.scu'),
                ('/child.scu', 'Z:\\scripts\\main.scu', 'Z:\\child.scu'),
                ('\\child.scu', '\\\\server\\share\\scripts\\main.scu', '\\\\server\\share\\child.scu'),
                ('child.scu', 'Z:\\scripts\\main.scu', 'Z:\\scripts\\child.scu'),
                ('../child.scu', 'Z:\\scripts\\main.scu', 'Z:\\child.scu'),
                ('\\\\?\\C:\\other\\child.scu', 'Z:\\scripts\\main.scu', '\\\\?\\C:\\other\\child.scu')]:
            with self.subTest(filename=filename):
                self.assertEqual(self.probe('resolve', filename, parent).strip().lower(), expected.lower())
        resolved = self.probe('resolve', 'C:child.scu', 'Z:\\scripts\\main.scu').strip()
        self.assertTrue(resolved.lower().startswith('c:'))
        self.assertNotIn('scripts', resolved.lower())

    @unittest.skipIf(WINDOWS, 'POSIX command-file byte paths')
    def test_linux_command_file_backslash_and_colon_remain_literal(self):
        main = self.root / 'main.scu'
        for child in ['child\\name.scu', 'C:child.scu']:
            (self.root / child).write_text('literal\n')
            main.write_text("!'" + child + "'\n")
            self.assertTrue(self.probe('files', main).endswith('|literal\n'))

if __name__ == '__main__':
    unittest.main()
