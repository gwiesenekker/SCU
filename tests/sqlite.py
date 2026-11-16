#!/usr/bin/env python3
"""SQLite platform open/recovery checks, native or --wine."""
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

PROBE = Path(sys.argv.pop(1) if len(sys.argv) > 1 else 'build/sqlite_probe').resolve()
WINE = '--wine' in sys.argv
if WINE:
    sys.argv.remove('--wine')

class SQLiteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root / 'library.sqlite'

    def run_probe(self, mode, *extra, code=0):
        path = str(self.path)
        if WINE:
            path = 'Z:' + path.replace('/', '\\')
        command = (['wine', str(PROBE)] if WINE else [str(PROBE)])
        result = subprocess.run(command + [mode, path, *extra], capture_output=True, timeout=30)
        self.assertEqual(result.returncode, code, result.stderr.decode(errors='replace'))
        return result

    def check_saved(self, expected=b'saved'):
        self.assertEqual(self.run_probe('read').stdout.replace(b'\r\n', b'\n'), expected + b'\nok\n')

    def test_library_factory_recovers_metadata_and_audit_atomically(self):
        self.run_probe('library-create')
        self.run_probe('library-crash', code=23)
        self.assertEqual(self.run_probe('library-read').stdout.replace(b'\r\n', b'\n'),
                         b'1.0\nsaved-audit\n')
        with sqlite3.connect(self.path) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM audit_records').fetchone()[0], 1)
            self.assertEqual(db.execute('PRAGMA integrity_check').fetchone()[0], 'ok')

    def test_create_and_read(self):
        self.run_probe('create')
        self.check_saved()
        if os.name != 'nt' and not WINE:
            self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_unicode_and_long_path(self):
        self.path = self.root / ('directory-' + 'x' * 90) / ('directory-' + 'y' * 90) / 'bibliothèque-日本.sqlite'
        self.path.parent.mkdir(parents=True)
        self.run_probe('create')
        self.check_saved()

    def test_missing_read_does_not_create(self):
        self.run_probe('read', code=1)
        self.assertFalse(self.path.exists())

    def test_create_existing_never_truncates(self):
        self.run_probe('create')
        self.run_probe('create', code=1)
        self.check_saved()

    def test_failed_open_has_path_context(self):
        self.path = self.root / 'absent' / 'library.sqlite'
        result = self.run_probe('create', code=1)
        self.assertIn(b'library.sqlite', result.stderr)

    def test_corrupt_database_is_not_replaced(self):
        data = b'This is not SQLite' * 100
        self.path.write_bytes(data)
        self.run_probe('read', code=1)
        self.assertEqual(self.path.read_bytes(), data)

    def test_hot_journal_recovered_by_logically_read_only_open(self):
        self.run_probe('create')
        self.run_probe('crash', code=23)
        journal = Path(str(self.path) + '-journal')
        self.assertTrue(journal.exists())
        self.assertNotEqual(journal.read_bytes()[:8], bytes(8))
        self.check_saved()
        self.check_saved()
        with sqlite3.connect(self.path) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM sqlite_master WHERE name='spill'").fetchone()[0], 0)

    def test_live_writer_is_not_rolled_back_by_reader(self):
        self.run_probe('create')
        with sqlite3.connect(self.path) as db:
            db.execute("UPDATE state SET value='live'")
            self.check_saved()
            db.commit()
        self.check_saved(b'live')

    def test_destructor_rolls_back_but_commit_persists(self):
        self.run_probe('create')
        self.run_probe('write')
        self.check_saved()
        self.run_probe('write', 'commit')
        self.check_saved(b'changed')

    def test_read_only_file_remains_readable(self):
        self.run_probe('create')
        self.path.chmod(0o400)
        try:
            self.check_saved()
        finally:
            self.path.chmod(0o600)

    def test_query_only_enforced_during_recovery_capable_read(self):
        self.run_probe('create')
        self.assertIn(b'readonly', self.run_probe('forbidden', code=1).stderr.lower())
        self.check_saved()

if __name__ == '__main__':
    unittest.main()
