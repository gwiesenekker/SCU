#!/usr/bin/env python3
"""Audit actors and executor transactions through the native CLI/backend or Wine."""
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

PROBE = Path(sys.argv.pop(1) if len(sys.argv) > 1 else 'build/actor_probe').resolve()
WINE = '--wine' in sys.argv
if WINE:
    sys.argv.remove('--wine')
WINDOWS = WINE or os.name == 'nt'
SCU = PROBE.with_name('scu.exe' if WINDOWS else 'scu')


def argument(value):
    if WINE and isinstance(value, Path):
        return 'Z:' + str(value.absolute()).replace('/', '\\')
    return str(value)


class ActorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'work 日本'
        self.root.mkdir()
        self.library = self.root / 'library_日本.sqlite'

    def run_program(self, executable, *args, env=None):
        command = (['wine', str(executable)] if WINE else [str(executable)])
        return subprocess.run(command + [argument(arg) for arg in args], cwd=self.root,
                              capture_output=True, timeout=35, env=env)

    def probe(self, *args, error=None, env=None):
        result = self.run_program(PROBE, *args, env=env)
        if WINE and result.returncode == 77:
            self.skipTest(result.stderr.decode(errors='replace'))
        if error is None:
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)
        return result.stdout.replace(b'\r\n', b'\n')

    def cli(self, *args, library=None, error=None):
        result = self.run_program(SCU, library or self.library, *args)
        if error is None:
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)
        return result.stdout.replace(b'\r\n', b'\n')

    def initialize(self):
        self.cli('inil')

    def rows(self, library=None):
        with closing(sqlite3.connect(library or self.library)) as db:
            return [line.encode('utf-8') for line, in db.execute('SELECT line FROM audit_records ORDER BY sequence')]

    def events(self, library=None):
        return [json.loads(row[65:]) for row in self.rows(library)]

    def check_chain(self, library=None):
        head = b'0' * 64
        rows = self.rows(library)
        for row in rows:
            digest, payload = row.split(b' ', 1)
            self.assertEqual(digest, hashlib.sha256(b'SCU audit v1 ' + head + b' ' + payload).hexdigest().encode())
            head = digest
        return head

    def check_actor(self, event, source='process'):
        if WINDOWS:
            self.assertNotIn('uid', event)
            actor = event['actor']
            self.assertEqual(list(actor), ['platform', 'sid', 'token_source'])
            self.assertEqual(actor['platform'], 'windows')
            self.assertEqual(actor['token_source'], source)
            self.assertRegex(actor['sid'], r'^S-\d+(?:-\d+)+$')
        else:
            self.assertNotIn('actor', event)
            self.assertIs(type(event['uid']), int)
            self.assertEqual(event['uid'], os.geteuid())

    def test_actor_matches_effective_os_identity(self):
        # On Windows the probe independently parses the text SID and uses
        # EqualSid against TokenUser, rather than comparing two formatted SIDs.
        self.check_actor(json.loads(self.probe('actor')))

    def test_identity_does_not_come_from_username_environment(self):
        before = json.loads(self.probe('actor'))
        environment = dict(os.environ, USER='forged-user', USERNAME='forged-user', USERDOMAIN='forged-domain')
        self.assertEqual(json.loads(self.probe('actor', env=environment)), before)

    def test_begin_and_build_actors_keep_legacy_phase_field_order(self):
        self.initialize()
        self.probe('build-record', self.library)
        events = self.events()
        for event in events:
            if event['phase'] in ('begin', 'build'):
                self.check_actor(event)
                fields = list(event)
                actor = 'actor' if WINDOWS else 'uid'
                predecessor = 'command' if event['phase'] == 'begin' else 'output_path'
                self.assertEqual(fields.index(actor), fields.index(predecessor) + 1)
            else:
                self.assertNotIn('actor', event)
                self.assertNotIn('uid', event)
        self.check_chain()
        self.cli('vera')

    def test_executor_receives_full_command_and_audits_same_named_arguments(self):
        self.initialize()
        self.probe('execute', self.library, 'create_deck', 'deck_name=backend.pas', 'comment_prefix=#')
        creation = self.events()[-2]
        self.assertEqual(creation['command'], 'create_deck')
        self.assertEqual(creation['parameters'], {'deck_name': 'backend.pas', 'comment_prefix': '#'})
        self.assertEqual(creation['provided_arguments'], ['deck_name', 'comment_prefix'])
        self.check_actor(creation)
        self.assertIn(b'backend.pas', self.cli('disdl'))
        self.check_chain()

    def test_cli_aliases_expand_before_actor_and_audit_recording(self):
        self.initialize()
        self.cli('cred', 'dn=cli.pas')
        event = self.events()[-2]
        self.assertEqual(event['command'], 'create_deck')
        self.assertEqual(event['parameters']['deck_name'], 'cli.pas')
        self.assertNotIn('dn', event['parameters'])
        self.check_actor(event)

    def test_unknown_backend_command_has_no_effect_or_audit_record(self):
        self.initialize()
        before = self.rows()
        self.probe('execute', self.library, 'unregistered_command', error=b'No implementation')
        self.assertEqual(self.rows(), before)

    def test_failed_command_still_has_actor_and_atomic_outcome(self):
        self.initialize()
        self.cli('deld', 'absent', error=b'does not exist')
        events = self.events()
        self.check_actor(events[-2])
        self.assertFalse(events[-1]['success'])
        self.assertEqual(events[-1]['begin'], self.rows()[-2][:64].decode())
        with closing(sqlite3.connect(self.library)) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM deck_revisions').fetchone()[0], 0)
        self.check_chain()
        self.cli('vera')

    def test_successful_and_failed_builds_record_parent_actor(self):
        self.initialize()
        self.cli('cred', 'main.c')
        for command, succeeds in [('echo actor-build', True), ('exit 7', False)]:
            self.cli('conl', 'build_command=' + command)
            self.cli('extd', 'main.c', 'build=yes', error=None if succeeds else b'Build command failed')
            event = self.events()[-1]
            self.assertEqual(event['phase'], 'build')
            self.assertEqual(event['build_command'], command)
            self.assertEqual(event['success'], succeeds)
            self.check_actor(event)
            self.check_chain()
        self.cli('vera')

    def test_legacy_uid_payload_bytes_are_accepted_and_not_rewritten(self):
        self.initialize()
        rows = self.rows()
        head = rows[-1][:64]
        # Deliberately preserve whitespace/UTF-8 different from FPJSON output.
        begin = '{"phase":"begin", "command":"legacy-probe", "uid":42,"note":"café"}'
        digest = hashlib.sha256(b'SCU audit v1 ' + head + b' ' + begin.encode()).hexdigest()
        end = '{"phase":"end", "begin":"' + digest + '", "success":true}'
        legacy = [digest.encode() + b' ' + begin.encode()]
        legacy.append(hashlib.sha256(b'SCU audit v1 ' + digest.encode() + b' ' + end.encode()).hexdigest().encode() + b' ' + end.encode())
        with closing(sqlite3.connect(self.library)) as db, db:
            for sequence, line in enumerate(legacy, len(rows) + 1):
                db.execute('INSERT INTO audit_records(sequence,line) VALUES (?,?)', (sequence, line.decode()))
        self.cli('vera')
        self.cli('disl')
        self.assertEqual(self.rows()[:len(rows) + 2], rows + legacy)
        self.check_actor(self.events()[-2])
        self.check_chain()

    def test_identity_is_covered_by_the_existing_audit_digest(self):
        self.initialize()
        with closing(sqlite3.connect(self.library)) as db, db:
            line = db.execute('SELECT line FROM audit_records WHERE sequence=1').fetchone()[0]
            event = json.loads(line[65:])
            if WINDOWS:
                event['actor']['sid'] = 'S-1-5-18'
            else:
                event['uid'] += 1
            db.execute('UPDATE audit_records SET line=? WHERE sequence=1', (line[:65] + json.dumps(event),))
        self.cli('vera', error=b'Audit digest mismatch')

    def recovery_document(self):
        self.initialize()
        source = self.root / 'source.c'
        source.write_bytes(b'binary\x00\xff\r\n')
        self.cli('cred', 'main.c', 'from_file=source.c')
        with closing(sqlite3.connect(self.library)) as db:
            document = json.loads(db.execute('SELECT payload FROM library').fetchone()[0])
            document['revisions'] = [json.loads(p) for p, in db.execute('SELECT payload FROM deck_revisions ORDER BY sequence')]
        path = self.root / 'recovery_日本.json'
        path.write_text(json.dumps(document), encoding='utf-8')
        return path

    def test_recovery_uses_stream_copy_and_has_new_actor_records(self):
        recovery = self.recovery_document()
        restored = self.root / 'restored_日本.sqlite'
        self.assertIn(b'Restored 1 revision', self.cli('recl', recovery, library=restored))
        self.assertEqual(len(self.rows(restored)), 2)
        self.check_actor(self.events(restored)[0])
        self.check_chain(restored)
        self.cli('vera', library=restored)

    def test_recovery_stream_preserves_binary_data_and_long_paths(self):
        directory = self.root / ('a' * 120) / ('b' * 120) / '日本'
        directory.mkdir(parents=True)
        source, output = directory / 'source.sqlite', directory / 'copy.sqlite'
        data = bytes(range(256)) * 4096 + b'\x00\xfflast'
        source.write_bytes(data)
        self.probe('stream-copy', source, output)
        self.assertEqual(source.read_bytes(), data)
        self.assertEqual(output.read_bytes(), data)
        self.probe('stream-copy', directory / 'missing', output, error=b'missing')
        self.assertEqual(output.read_bytes(), data)

    @unittest.skipUnless(WINDOWS, 'Windows thread impersonation')
    def test_thread_identity_takes_priority_and_is_not_cached_between_threads(self):
        main, worker, restored = [json.loads(line) for line in self.probe('thread').splitlines()]
        self.check_actor(main, 'thread')
        self.check_actor(worker, 'process')
        self.check_actor(restored, 'process')
        self.assertEqual(main['actor']['sid'], restored['actor']['sid'])

    @unittest.skipUnless(WINDOWS, 'Windows anonymous token must not fall back to process')
    def test_unqueryable_thread_identity_is_an_error(self):
        self.assertEqual(self.probe('anonymous'), b'rejected\n')

    @unittest.skipUnless(WINDOWS, 'Windows actor failure occurs before audit append')
    def test_actor_failure_does_not_append_or_poison_audit_state(self):
        self.initialize()
        before = self.rows()
        self.probe('anonymous-audit', self.library)
        self.assertEqual(self.rows()[:len(before)], before)
        self.assertEqual(len(self.rows()), len(before) + 2)
        events = self.events()
        self.assertNotIn('must_not_be_logged', [e.get('command') for e in events])
        self.check_actor(events[-2])
        self.check_chain()
        self.cli('vera')

    @unittest.skipUnless(WINDOWS, 'Windows token-handle lifetime')
    def test_repeated_queries_release_token_handles(self):
        self.assertEqual(self.probe('handles'), b'handles ok\n')

    def check_recovery_temp_root(self, temporary):
        recovery = self.recovery_document()
        temporary.mkdir(parents=True)
        restored = self.root / 'restored.sqlite'
        mode = ['recover', temporary] if WINDOWS else ['execute']
        environment = None if WINDOWS else dict(os.environ, TMPDIR=str(temporary))
        self.probe(*mode, restored, 'recover_library', 'recovery_file=' + argument(recovery), env=environment)
        self.assertEqual(list(temporary.iterdir()), [])
        self.cli('vera', library=restored)
        document = json.loads(recovery.read_text(encoding='utf-8'))
        document['revisions'][0]['sha1'] = '0' * 40
        recovery.write_text(json.dumps(document), encoding='utf-8')
        rejected = self.root / 'rejected.sqlite'
        self.probe(*mode, rejected, 'recover_library', 'recovery_file=' + argument(recovery),
                   error=b'SHA-1', env=environment)
        self.assertFalse(rejected.exists())
        self.assertEqual(list(temporary.iterdir()), [])

    def test_recovery_cleans_temporary_files_after_success_and_validation_error(self):
        self.check_recovery_temp_root(self.root / 'temporary 日本')

    @unittest.skipUnless(WINDOWS, 'Windows executor long recovery path')
    def test_recovery_supports_long_temp_root_and_cleans_success_and_failure(self):
        # GetTempPathW needs a short-enough base; the generated private child
        # directory and library.sqlite path exceed MAX_PATH.
        root_units = len(argument(self.root).encode('utf-16-le')) // 2
        budget = 220 - root_units - 5  # three separators and two Japanese characters
        self.assertGreaterEqual(budget, 2, 'Test temporary base is already too long')
        temporary = self.root / ('t' * (budget // 2)) / ('u' * (budget - budget // 2)) / '日本'
        if WINE:
            sentinel = temporary / ('scu-probe-' + 'x' * 40)
            sentinel.mkdir(parents=True)
            result = self.run_program(PROBE, 'directory', sentinel)
            sentinel.rmdir()
            if result.returncode and b'More data available' in result.stderr:
                self.skipTest('Wine cannot normalize a long directory, before recovery or actor lookup')
            self.assertEqual(result.returncode, 0, result.stderr)
            temporary.rmdir()
        self.check_recovery_temp_root(temporary)

if __name__ == '__main__':
    unittest.main()
