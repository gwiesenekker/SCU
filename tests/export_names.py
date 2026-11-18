#!/usr/bin/env python3
"""Export filename safety and byte identity, on Linux or Windows (optionally Wine)."""
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

PROBE = Path(sys.argv.pop(1) if len(sys.argv) > 1 else 'build/export_names_probe').resolve()
WINE = '--wine' in sys.argv
if WINE:
    sys.argv.remove('--wine')
WINDOWS = WINE or os.name == 'nt'
SCU = PROBE.with_name('scu.exe' if WINDOWS else 'scu')


def argument(value):
    if WINE and isinstance(value, Path):
        return 'Z:' + str(value.absolute()).replace('/', '\\')
    return str(value)


def raw(value):
    return value if isinstance(value, bytes) else value.encode('utf-8')


class ExportNamesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'work 日本'
        self.root.mkdir()
        self.library = self.root / 'library.sqlite'
        self.output = self.root / 'output'
        self.output.mkdir()
        self.manifest = self.output / '.scu-exports.json'

    def run_program(self, exe, *args, error=None):
        command = ['wine', str(exe)] if WINE else [str(exe)]
        result = subprocess.run(command + [argument(a) for a in args], cwd=self.root,
                                capture_output=True, timeout=40)
        if error is None:
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn(error, result.stderr)
        return result.stdout.replace(b'\r\n', b'\n')

    def probe(self, *args, **kwargs):
        return self.run_program(PROBE, *args, **kwargs)

    def cli(self, *args, library=None, **kwargs):
        return self.run_program(SCU, library or self.library, *args, **kwargs)

    def values(self, mode, names):
        return json.loads(self.probe(mode, *(raw(n).hex() for n in names)))

    def initialize(self):
        self.cli('inil')
        (self.root / 'source.c').write_bytes(b'int main(void) { return 0; }\n')
        self.cli('cred', 'main.c', 'from_file=source.c')

    def extract(self, filename='main.c', **kwargs):
        return self.cli('extd', 'main.c', 'output_file=' + argument(self.output / filename),
                        'build=no', **kwargs)

    def record(self, filename):
        return dict(file='display-only', file_bytes=raw(filename).hex(),
                    library=argument(self.library), deck_name='main.c', library_version='1.0',
                    deck_version='1.0-0.000', mode='extract', expansion_utc='',
                    comment_prefix='//', sha256=hashlib.sha256(b'payload').hexdigest())

    def write_manifest(self, files=(), pending=()):
        document = dict(format=2, files=list(files))
        if pending:
            document['pending'] = dict(entries=[dict(entry=e, previous_sha256='') for e in pending])
        self.manifest.write_text(json.dumps(document), encoding='utf-8')
        return self.manifest.read_bytes()

    def recovery(self, names):
        self.initialize()
        if len(names) > 1:
            self.cli('cred', 'other.c', 'from_file=source.c')
        with closing(sqlite3.connect(self.library)) as db:
            document = json.loads(db.execute('SELECT payload FROM library').fetchone()[0])
            document['revisions'] = [json.loads(p) for p, in db.execute(
                'SELECT payload FROM deck_revisions ORDER BY sequence')]
        for revision, name in zip(document['revisions'], names):
            revision['source_path'] = 'display-only.c'
            revision['source_path_bytes'] = raw(name).hex()
        path = self.root / 'recovery.json'
        path.write_text(json.dumps(document), encoding='utf-8')
        restored = self.root / 'restored.sqlite'
        self.cli('recl', path, library=restored)
        return restored

    @unittest.skipUnless(WINDOWS, 'Windows filename rules')
    def test_forbidden_components_and_devices(self):
        names = ['', '.', '..', 'a/b', 'a\\b', 'a:b', 'a"b', 'a<b', 'a>b', 'a|b', 'a?b',
                 'a*b', ' leading', 'trailing ', 'trailing.', 'nul', 'NuL.txt', 'CON', 'prn.c',
                 'aux', 'conin$', 'conout$.txt', 'COM1.c', 'lpt9', 'com¹.txt', 'LPT²', 'com³',
                 'NUL .txt', '.SCU-EXPORTS.JSON', '.SCU-OUTPUT.LOCK', '.owner',
                 '.scu-stage-other', '.SCU-TMP-other'] + [b'a' + bytes([c]) for c in range(32)]
        for name, result in zip(names, self.values('validate', names)):
            with self.subTest(name=name):
                self.assertNotEqual(result, 'ok')

    @unittest.skipUnless(WINDOWS, 'Windows UTF-8 and UTF-16 limits')
    def test_unicode_and_component_length(self):
        good = ['main.c', 'two words.c', '日本.c', 'é.c', 'é.c', 'COM0', 'COM10',
                'legal~name.c', 'a' * 255, '😀' * 127 + 'a']
        self.assertEqual(self.values('validate', good), ['ok'] * len(good))
        bad = [b'\xff', b'\xc0\xaf', b'\xed\xa0\x80', b'\xf4\x90\x80\x80',
               'a' * 256, '😀' * 128]
        self.assertTrue(all(r != 'ok' for r in self.values('validate', bad)))

    def test_filename_identity_matches_platform_without_unicode_normalization(self):
        names = ['Case.c', 'case.c', 'é.c', 'É.c', 'é.c', 'ß.c', 'ss.c']
        keys = self.values('keys', names)
        if WINDOWS:
            self.assertEqual(keys[0], keys[1])
            self.assertEqual(keys[2], keys[3])
            self.assertNotEqual(keys[2], keys[4])
            self.assertNotEqual(keys[5], keys[6])
        else:
            self.assertEqual(keys, [hashlib.sha256(raw(n)).hexdigest() for n in names])

    @unittest.skipUnless(WINDOWS, 'Windows lexical paths')
    def test_output_path_validation_precedes_windows_canonicalization(self):
        good = ['main.c', r'C:\work\main.c', r'C:main.c', r'\main.c',
                r'\\server\share\main.c', r'\\?\C:\work\main.c',
                r'\\?\UNC\server\share\main.c', r'..\work\main.c']
        self.assertEqual(self.values('paths', good), ['ok'] * len(good))
        bad = [r'C:\bad.\main.c', r'C:\NUL\main.c', r'C:\work\main.c:stream',
               r'\\.\NUL', r'\??\C:\main.c', r'\\?\GLOBALROOT\main.c',
               'C:\\work\\', r'\\server\share', r'C:\work\.SCU-EXPORTS.JSON']
        self.assertTrue(all(r != 'ok' for r in self.values('paths', bad)))

    @unittest.skipUnless(WINDOWS, 'Windows explicit export paths')
    def test_unsafe_explicit_targets_leave_existing_files_and_manifest_untouched(self):
        self.initialize()
        self.extract()
        before = self.manifest.read_bytes()
        source = (self.output / 'main.c').read_bytes()
        for name in ['main.c:stream', 'main.c.', 'NUL.c', '.SCU-EXPORTS.JSON', '.SCU-OUTPUT.LOCK']:
            self.extract(name, error=b'Windows')
            self.assertEqual(self.manifest.read_bytes(), before)
            self.assertEqual((self.output / 'main.c').read_bytes(), source)

    @unittest.skipUnless(WINDOWS, 'Windows manifest identities')
    def test_export_case_alias_is_one_manifest_entry(self):
        self.initialize()
        self.extract('source.c')
        self.extract('SOURCE.C')
        document = json.loads(self.manifest.read_text())
        self.assertEqual(len(document['files']), 1)
        self.assertIn(b'No errors', self.cli('verd', 'output_directory=' + argument(self.output)))

    @unittest.skipUnless(WINDOWS, 'Windows manifest collision handling')
    def test_duplicate_file_and_pending_aliases_rejected_before_recovery(self):
        for pending in [False, True]:
            entries = [self.record('Case.c'), self.record('case.c')]
            before = self.write_manifest(pending=entries) if pending else self.write_manifest(files=entries)
            self.probe('manifest', self.output, 'recover', error=b'duplicate')
            self.assertEqual(self.manifest.read_bytes(), before)
            self.assertEqual(sorted(p.name for p in self.output.iterdir()), ['.scu-exports.json'])

    @unittest.skipUnless(WINDOWS, 'Windows untrusted manifest filenames')
    def test_authoritative_filename_bytes_validated_in_records_and_pending_intents(self):
        for name in [r'..\outside.c', 'other:stream', '.SCU-EXPORTS.JSON', 'nul.pas', b'bad\xff']:
            for pending in [False, True]:
                entry = self.record(name)
                before = self.write_manifest(pending=[entry]) if pending else self.write_manifest(files=[entry])
                self.probe('manifest', self.output, 'recover', error=b'Windows')
                self.assertEqual(self.manifest.read_bytes(), before)
                self.assertFalse((self.root / 'outside.c').exists())

    @unittest.skipUnless(WINDOWS, 'Windows plan validation')
    def test_backend_manifest_plans_reject_names_and_aliases_without_publishing(self):
        for names in [('NUL.c',), ('..\\outside.c',), ('.SCU-EXPORTS.JSON',), ('One.c', 'ONE.C')]:
            self.probe('plan', self.output, self.library, *names, error=b'')
            self.assertEqual(list(self.output.iterdir()), [])

    @unittest.skipUnless(WINDOWS, 'Windows portable-library preflight')
    def test_version_case_collisions_fail_before_any_outputs_or_payload_rewrites(self):
        restored = self.recovery(['Case.c', 'case.c'])
        with closing(sqlite3.connect(restored)) as db:
            before = list(db.execute('SELECT payload FROM deck_revisions ORDER BY sequence'))
        sentinel = self.output / 'Case.c'
        sentinel.write_bytes(b'do not overwrite')
        self.cli('extv', 'output_directory=' + argument(self.output), 'replace=yes', 'build=no',
                 library=restored, error=b'collision')
        self.assertEqual(sentinel.read_bytes(), b'do not overwrite')
        self.assertFalse(self.manifest.exists())
        with closing(sqlite3.connect(restored)) as db:
            self.assertEqual(list(db.execute('SELECT payload FROM deck_revisions ORDER BY sequence')), before)
        self.cli('vera', library=restored)

    @unittest.skipUnless(WINDOWS, 'Windows portable-library source rules')
    def test_unsafe_recorded_source_rejected_without_export(self):
        restored = self.recovery(['nul.pas'])
        self.cli('extv', 'output_directory=' + argument(self.output), 'build=no',
                 library=restored, error=b'reserved device')
        self.assertEqual([p for p in self.output.iterdir() if p.name != '.scu-output.lock'], [])

    @unittest.skipUnless(WINDOWS, 'Windows complete release validation')
    def test_release_preflight_protects_obsolete_outputs_on_collision(self):
        restored = self.recovery(['Case.c', 'case.c'])
        obsolete = self.output / 'obsolete.c'
        obsolete.write_bytes(b'keep until the selected version is safe')
        self.cli('relv', 'output_directory=' + argument(self.output), 'replace=yes',
                 library=restored, error=b'collision')
        self.assertEqual(obsolete.read_bytes(), b'keep until the selected version is safe')
        self.assertFalse(self.manifest.exists())

    @unittest.skipUnless(WINDOWS, 'Windows recovery identities')
    def test_pending_case_alias_of_existing_record_recovers_as_one_file(self):
        (self.output / 'case.c').write_bytes(b'payload')
        self.write_manifest(files=[self.record('case.c')], pending=[self.record('CASE.C')])
        self.assertEqual(self.probe('manifest', self.output, 'recover'), b'1\n')
        document = json.loads(self.manifest.read_text())
        self.assertNotIn('pending', document)
        self.assertEqual(len(document['files']), 1)
        self.assertEqual((self.output / 'case.c').read_bytes(), b'payload')

    @unittest.skipUnless(WINDOWS, 'Windows existing directory targets')
    def test_directory_target_is_refused_without_changing_manifest(self):
        target = self.output / 'directory.c'
        target.mkdir()
        self.initialize()
        self.extract('directory.c', error=b'regular export target')
        self.assertFalse(self.manifest.exists())
        self.assertTrue(target.is_dir())

    @unittest.skipUnless(WINDOWS, 'Windows protected SQLite targets')
    def test_manifest_backend_cannot_plan_over_library_or_foreign_sqlite(self):
        self.initialize()
        for name in ['foreign.sqlite', 'foreign.sqlite-wal']:
            if name == 'foreign.sqlite':
                self.cli('inil', library=self.output / name)
            target = self.output / name
            before = target.read_bytes() if target.exists() else None
            self.probe('plan', self.output, self.library, name, error=b'protected SQLite')
            self.assertEqual(target.read_bytes() if target.exists() else None, before)
        self.assertFalse(self.manifest.exists())

    @unittest.skipUnless(WINDOWS, 'Windows queued observations')
    def test_pending_working_names_fail_before_manifest_changes(self):
        self.initialize()
        manifest = self.root / '.scu-exports.json'
        before = manifest.read_bytes() if manifest.exists() else None
        for names in [[('..\\outside.c', 'main.c')], [('Case.c', 'main.c'), ('case.c', 'other.c')]]:
            with closing(sqlite3.connect(self.library)) as db, db:
                db.execute('DELETE FROM pending_working_exports')
                for name, deck in names:
                    db.execute('INSERT INTO pending_working_exports VALUES (?, ?, ?, ?, ?, ?, ?)',
                               (hashlib.sha256(raw(name)).hexdigest(), raw(name), deck,
                                '1.0', '1.0-0.000', hashlib.sha256(b'payload').hexdigest(), 0))
            self.cli('extv', 'build=no', error=b'Windows')
            self.assertEqual(manifest.read_bytes() if manifest.exists() else None, before)
            self.assertFalse((self.root.parent / 'outside.c').exists())
            with closing(sqlite3.connect(self.library)) as db:
                self.assertEqual(db.execute('SELECT count(*) FROM pending_working_exports').fetchone()[0], len(names))

    @unittest.skipUnless(WINDOWS, 'Windows existing DOS aliases')
    def test_existing_short_alias_does_not_overwrite_long_target(self):
        self.initialize()
        target = self.output / 'Long filename for export.c'
        target.write_bytes(b'keep original')
        short = self.probe('short', target).decode().strip()
        if short.rsplit('\\', 1)[-1].casefold() == target.name.casefold():
            self.skipTest('Filesystem did not generate an 8.3 alias')
        self.cli('extd', 'main.c', 'output_file=' + short, 'replace=yes', 'build=no', error=b'short-name alias')
        self.assertEqual(target.read_bytes(), b'keep original')
        self.assertFalse(self.manifest.exists())

    @unittest.skipIf(WINDOWS, 'Linux byte-based filenames')
    def test_linux_raw_names_and_case_distinctions_remain_unchanged(self):
        names = [b'Case.c', b'case.c', b'back\\slash.c', b'colon:name.c', b'line\nname.c', b'raw\xff.c']
        self.assertEqual(self.values('validate', names), ['ok'] * len(names))
        self.assertEqual(self.values('keys', names), [hashlib.sha256(n).hexdigest() for n in names])
        self.initialize()
        for name in names:
            path = os.fsencode(self.output) + b'/' + name
            self.cli('extd', 'main.c', os.fsdecode(b'output_file=' + path), 'build=no')
            with open(path, 'rb') as source:
                self.assertEqual(source.read(), (self.root / 'source.c').read_bytes())
        files = json.loads(self.manifest.read_text())['files']
        self.assertEqual({bytes.fromhex(e['file_bytes']) for e in files}, set(names))
        self.cli('verd', 'output_directory=' + argument(self.output))
        self.cli('vera')


if __name__ == '__main__':
    unittest.main()
