"""Exercise SCU through its command line in isolated libraries."""
import concurrent.futures
from contextlib import closing, contextmanager, suppress
from datetime import datetime
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import re
import resource
import select
import shlex
import shutil
import signal
import sqlite3
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest

import portable_cli

SCU = Path(sys.argv.pop(1)).resolve()
portable_cli.configure(SCU)


class ScuIntegration(portable_cli.PortableCliTests):
    def test_catalog_symlinks_preserve_overrides_and_broken_links_do_not_fall_back(self):
        executable = self.standalone_cli()
        catalog = json.loads(SCU.with_name('commands.json').read_bytes())
        command = next(c for c in catalog['commands'] if c['name'] == 'display_deck')
        command['help_file'] = 'detail.txt'
        (executable.parent / 'detail.txt').write_text('Linked catalog help from its directory.')
        target = executable.parent / 'custom.json'
        target.write_text(json.dumps(catalog))
        executable.with_name('commands.json').symlink_to(target.name)
        self.assertIn('Linked catalog help from its directory.', self.run_scu('disc', 'disd', executable=executable))
        target.unlink()
        self.run_scu('help', executable=executable, error='Could not load command catalog')

    def test_unreadable_catalog_is_an_error_instead_of_using_embedded_defaults(self):
        if os.geteuid() == 0:
            self.skipTest('Root can read a mode-000 catalog')
        executable = self.standalone_cli()
        path = executable.with_name('commands.json')
        path.write_bytes(SCU.with_name('commands.json').read_bytes())
        path.chmod(0)
        try:
            self.run_scu('help', executable=executable, error='Could not load command catalog')
        finally:
            path.chmod(0o600)

    def test_empty_named_output_does_not_consume_the_following_deck(self):
        self.store("main.pas", b"stored main\n")
        self.store("shared.inc", b"stored shared\n")
        working = self.root / "main.pas"
        working.write_bytes(b"unsaved work\n")
        for command in ("extract_deck",):
            with self.subTest(command=command):
                result = subprocess.run(
                    ["sh", "-c", 'OUT=""; "$1" "$2" output_file=$OUT main.pas', "sh", SCU, command],
                    cwd=self.root, capture_output=True, text=True, timeout=5,
                )
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("Expected a file path", result.stderr)
                self.assertEqual(working.read_bytes(), b"unsaved work\n")
        result = subprocess.run([SCU], cwd=self.root, input='extd of="" main.pas\n',
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Expected a file path", result.stderr)
        self.assertEqual(working.read_bytes(), b"unsaved work\n")


    def run_import(self, archive, library, *options, success=True):
        importer = Path(__file__).resolve().parents[1] / "tools/import_versions.py"
        result = subprocess.run([sys.executable, importer, archive, library, "--scu", SCU, *options],
                                cwd=self.root, capture_output=True, text=True, timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result


    def version_import_manifest(self, library, version):
        header = json.loads(self.run_scu(library, "disl", "j=y"))
        return next(item["import_manifest"] for item in header["versions"] if item["name"] == version)

    def test_directory_import_preserves_snapshots_history_deletions_and_original_names(self):
        archive = self.root / "source archive"
        archive.mkdir()
        (archive / ".COMMENT").write_text("#\n")
        expected = {
            "0.003": {"main.c": b"first\n", "obsolete": b"gone later",
                      "Makefile": b"build", "nested/source file": b"\0\xffbinary",
                      "A.c": b"upper", "a.c": b"lower", "scu-import-manifest.json": b"original file"},
            "0.0031": {"main.c": b"second\n", "Makefile": b"build"},
            "0.004": {"main.c": b"third\n", "obsolete": b"recreated"},
        }
        for version in reversed(expected):
            for relative, data in expected[version].items():
                path = archive / version / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
        (archive / "HISTORY").write_text(
            "Preamble and TODOs\n\nRevision: 0.003\nDate: original date\n"
            'Description: First "release"\nsecond line with \'quotes\' and \\backslash\n\n'
            "Revision: 0.0031 based on 0.003\nDate: next date\nDescription: First entry\nline two\n\n"
            "Revision: 0.0031\nDate: another date\nDescription: Second entry\n")
        library = self.root / "imported.sqlite"
        result = self.run_import(archive, library)
        self.assertIn("3 versions", result.stdout)
        self.assertIn("Audit verified:", result.stdout)
        with closing(sqlite3.connect(library)) as database:
            metadata = json.loads(database.execute("SELECT payload FROM library").fetchone()[0])
            header = metadata["header"]
            self.assertEqual(header["platform"], "Linux")
            self.assertEqual(header["comment_prefix"], "#")
            self.assertEqual([v["name"] for v in header["versions"]], list(expected))
            self.assertTrue(all(v["locked"] and v["locked_utc"] for v in header["versions"]))
            self.assertEqual(header["versions"][0]["description"],
                             'First "release"\nsecond line with \'quotes\' and \\backslash')
            self.assertEqual(header["versions"][1]["description"], "First entry\nline two\n\nSecond entry")
            self.assertEqual(header["versions"][2]["description"],
                             "No HISTORY description found for version 0.004.")
        for version, files in expected.items():
            manifest = self.version_import_manifest(library, version)
            self.assertEqual(manifest["version"], version)
            self.assertEqual({row["path"] for row in manifest["files"]}, set(files))
            actual_decks = {row.split("\t")[0] for row in self.table_data(self.run_scu(library, "disdl", "v=" + version)).splitlines()}
            self.assertEqual(actual_decks, {row["deck_name"] for row in manifest["files"]})
            for row in manifest["files"]:
                if row["path"] in {"Makefile", "A.c", "a.c"}:
                    self.assertEqual(row["deck_name"], row["path"])
                data = files[row["path"]]
                self.assertEqual(row["sha1"], hashlib.sha1(data).hexdigest())
                self.assertEqual(row["size"], len(data))
                self.run_scu(library, "extd", row["deck_name"], "extracted", "v=" + version)
                self.assertEqual((self.root / "extracted").read_bytes(), data)
        self.assertIn("  deleted", self.run_scu(library, "disd", "obsolete"))
        self.run_scu(library, "verify_audit_trail")
        self.assertEqual(list(self.root.glob(".scu-import-*")), [])

    def test_directory_import_strips_only_initial_scu_revision_headers(self):
        archive = self.root / 'archive'
        first = {
            'double': b'// SCU REVISION old\n// SCU REVISION retained\nbody\n',
            'plain': b'unchanged\n',
            'lf': b'// SCU REVISION 1.0 old\nbody\n',
            'crlf': b'// SCU REVISION 1.0\r\nbody\r\n',
            'cr': b'// SCU REVISION 1.0\rbody\r',
            'added': b'body\n',
            'removed': b'// SCU REVISION 1.0\nbody\n',
            'empty': b'',
            'header-only': b'// SCU REVISION 1.0 without newline',
            'header-exact': b'// SCU REVISION\n',
            'binary': b'// SCU REVISION 1.0\n\x00\xff\r\nbody',
            'later': b'copyright\n// SCU REVISION 1.0\nbody\n',
            'near': b'// SCU REVISIONED 1.0\nbody\n',
            'case': b'// scu revision 1.0\nbody\n',
            'indented': b' // SCU REVISION 1.0\nbody\n',
            'body-newline': b'// SCU REVISION 1.0\nbody\n',
            'body-space': b'// SCU REVISION 1.0\nint x;\n',
        }
        second = {
            'double': b'// SCU REVISION new\nbody\n',
            'plain': first['plain'],
            'lf': b'// SCU REVISION 1.1 new date\nbody\n',
            'crlf': b'// SCU REVISION 1.1\nbody\r\n',
            'cr': b'// SCU REVISION 1.1\r\nbody\r',
            'added': b'// SCU REVISION 1.1\nbody\n',
            'removed': b'body\n',
            'empty': b'// SCU REVISION 1.1',
            'header-only': b'',
            'header-exact': b'// SCU REVISION\tnew stamp\r',
            'binary': b'// SCU REVISION 1.1\r\n\x00\xff\r\nbody',
            'later': b'copyright\n// SCU REVISION 1.1\nbody\n',
            'near': b'// SCU REVISIONED 1.1\nbody\n',
            'case': b'// scu revision 1.1\nbody\n',
            'indented': b' // SCU REVISION 1.1\nbody\n',
            'body-newline': b'// SCU REVISION 1.1\nbody\n\n',
            'body-space': b'// SCU REVISION 1.1\nint  x;\n',
        }
        changed = {'double', 'later', 'near', 'case', 'indented', 'body-newline', 'body-space'}
        for version, files in [('1.0', first), ('1.1', second)]:
            (archive / version).mkdir(parents=True)
            for name, data in files.items():
                (archive / version / name).write_bytes(data)
        (archive / 'HISTORY').write_text('Revision: 1.0\nDescription: First\nRevision: 1.1\nDescription: Next\n')
        library = self.root / 'imported.sqlite'
        result = self.run_import(archive, library)
        self.assertIn('1.1: 17 files, 0 deletions, 7 stored, 10 inherited', result.stdout)
        with closing(sqlite3.connect(library)) as database:
            versions = database.execute('SELECT deck_name, library_version FROM deck_revisions').fetchall()
        imports = [json.loads(line.split(b' ', 1)[1]) for line in self.audit_lines(library)]
        imports = [event['parameters']['deck_name'] for event in imports if event.get('command') == 'import_deck']
        for name in first:
            with self.subTest(deck=name):
                self.assertEqual([v for deck, v in versions if deck == name], ['1.0', '1.1'] if name in changed else ['1.0'])
                self.assertEqual(imports.count(name), 2 if name in changed else 1)
                for version, files in [('1.0', first), ('1.1', second)]:
                    expected = files[name]
                    if name not in {'later', 'near', 'case', 'indented'} and expected.startswith(b'// SCU REVISION'):
                        expected = b''.join(expected.splitlines(keepends=True)[1:])
                    self.run_scu(library, 'extd', name, 'result', 'v=' + version)
                    self.assertEqual((self.root / 'result').read_bytes(), expected)
                self.assertEqual((archive / '1.0' / name).read_bytes(), first[name])
                self.assertEqual((archive / '1.1' / name).read_bytes(), second[name])
        manifest = self.version_import_manifest(library, '1.1')
        self.assertEqual(manifest['storage'], 'strip_initial_scu_revision_line')
        self.assertEqual(manifest['comparison'], 'bytes_ignoring_initial_scu_revision_line')
        for row in manifest['files']:
            original = second[row['path']]
            self.assertEqual(row['size'], len(original))
            self.assertEqual(row['sha1'], hashlib.sha1(original).hexdigest())
        self.run_scu(library, 'verify_audit_trail')

    def test_directory_import_header_inheritance_survives_real_edits_and_recreation(self):
        archive = self.root / 'archive'
        snapshots = {}
        for version in ['1.0', '1.1', '1.2', '1.3']:
            header = ('// SCU REVISION ' + version + '\n').encode()
            files = {'main': header + (b'old\n' if version in ['1.0', '1.1'] else b'new\n'),
                     'stable': header + b'never changes\n'}
            if version != '1.1':
                files['revived'] = header + b'same body\n'
            snapshots[version] = files
            (archive / version).mkdir(parents=True)
            for name, data in files.items():
                (archive / version / name).write_bytes(data)
        (archive / 'HISTORY').write_text(''.join(
            'Revision: ' + version + '\nDescription: Release ' + version + '\n' for version in snapshots))
        library = self.root / 'imported.sqlite'
        result = self.run_import(archive, library)
        self.assertIn('1.1: 2 files, 1 deletions, 0 stored, 2 inherited', result.stdout)
        self.assertIn('1.2: 3 files, 0 deletions, 2 stored, 1 inherited', result.stdout)
        self.assertIn('1.3: 3 files, 0 deletions, 0 stored, 3 inherited', result.stdout)
        with closing(sqlite3.connect(library)) as database:
            rows = database.execute('SELECT deck_name, library_version, deleted FROM deck_revisions ORDER BY sequence').fetchall()
        self.assertEqual([(version, deleted) for deck, version, deleted in rows if deck == 'main'], [('1.0', 0), ('1.2', 0)])
        self.assertEqual([(version, deleted) for deck, version, deleted in rows if deck == 'stable'], [('1.0', 0)])
        self.assertEqual([(version, deleted) for deck, version, deleted in rows if deck == 'revived'], [('1.0', 0), ('1.1', 1), ('1.2', 0)])
        for deck, inherited_from in [('main', '1.2'), ('stable', '1.0'), ('revived', '1.2')]:
            self.run_scu(library, 'extd', deck, 'result', 'v=1.3')
            self.assertEqual((self.root / 'result').read_bytes(), snapshots[inherited_from][deck].split(b'\n', 1)[1])
        listing = self.table_data(self.run_scu(library, 'disdl', 'v=1.3'))
        self.assertIn('main\t1.2-0.000', listing)
        self.assertIn('stable\t1.0-0.000', listing)
        self.assertIn('revived\t1.2-0.000', listing)
        self.run_scu(library, 'verify_audit_trail')

    def test_directory_import_inherits_exact_unchanged_files_and_recreates_removed_files(self):
        archive = self.root / "archive"
        versions = {
            "1.0": {"stable": b"\0stable", "main": b"first", "gone": b"gone", "revived": b"same", "empty": b""},
            "1.1": {"stable": b"\0stable", "main": b"other", "empty": b""},
            "1.2": {"stable": b"\0stable", "main": b"other", "revived": b"same", "empty": b""},
        }
        for version, files in versions.items():
            (archive / version).mkdir(parents=True)
            for name, content in files.items():
                path = archive / version / name
                path.write_bytes(content)
                os.utime(path, ns=(1234567890000000000, 1234567890000000000))
        (archive / "HISTORY").write_text("".join(
            f"Revision: {version}\nDescription: Version {version}\n" for version in versions))
        library = self.root / "imported.sqlite"
        result = self.run_import(archive, library)
        self.assertIn("1.1: 3 files, 2 deletions, 1 stored, 2 inherited", result.stdout)
        self.assertIn("1.2: 4 files, 0 deletions, 1 stored, 3 inherited", result.stdout)
        with closing(sqlite3.connect(library)) as database:
            rows = database.execute("SELECT deck_name, library_version, deck_revision, deleted "
                                    "FROM deck_revisions ORDER BY sequence").fetchall()
        self.assertEqual([row[1:] for row in rows if row[0] == "stable"], [("1.0", "0.000", 0)])
        self.assertEqual([row[1:] for row in rows if row[0] == "empty"], [("1.0", "0.000", 0)])
        self.assertEqual([row[1:] for row in rows if row[0] == "main"],
                         [("1.0", "0.000", 0), ("1.1", "0.000", 0)])
        self.assertEqual([row[1:] for row in rows if row[0] == "revived"],
                         [("1.0", "0.000", 0), ("1.1", "0.000", 1), ("1.2", "0.000", 0)])
        for version, files in versions.items():
            manifest = self.version_import_manifest(library, version)
            self.assertEqual({row["path"] for row in manifest["files"]}, set(files))
            for name, content in files.items():
                self.run_scu(library, "extd", name, "result", "v=" + version)
                self.assertEqual((self.root / "result").read_bytes(), content)
                self.assertEqual((archive / version / name).read_bytes(), content)
        listing = self.table_data(self.run_scu(library, "disdl", "v=1.2"))
        self.assertIn("stable\t1.0-0.000", listing)
        self.assertIn("main\t1.1-0.000", listing)
        self.assertIn("revived\t1.2-0.000", listing)
        changed = self.run_scu(library, "disv", "1.2")
        self.assertNotIn("stable", changed)
        self.assertNotIn("main ", changed)
        self.assertIn("revived", changed)
        self.run_scu(library, "verify_audit_trail")

    def test_directory_import_skips_hidden_files_and_hidden_directory_trees(self):
        archive = self.root / "archive"
        for version in ("1.0", "1.1"):
            directory = archive / version
            (directory / "visible").mkdir(parents=True)
            (directory / ".git" / "nested").mkdir(parents=True)
            (directory / "visible" / ".cache").mkdir()
            (directory / "main.c").write_bytes(b"unchanged")
            (directory / "visible" / "source file.c").write_bytes(b"nested")
            (directory / ".SHA1SUM").write_text(version)
            (directory / ".scu-exports.json").write_text("not an export manifest")
            (directory / ".git" / "nested" / "config").write_text("hidden tree")
            (directory / "visible" / ".cache" / "data").write_text("hidden nested tree")
            (directory / "visible" / ".secret").write_text("hidden nested file")
            (directory / ".hidden-link").symlink_to("missing")
            (directory / ".hidden-dir-link").symlink_to("visible", target_is_directory=True)
        (archive / "HISTORY").write_text(
            "Revision: 1.0\nDescription: First\nRevision: 1.1\nDescription: Second\n")
        library = self.root / "imported.sqlite"
        preview = self.run_import(archive, library, "--dry-run")
        self.assertIn("4 file snapshots", preview.stdout)
        self.assertIn("Plan 1.1: 2 files, 0 deletions", preview.stdout)
        result = self.run_import(archive, library)
        self.assertIn("1.1: 2 files, 0 deletions, 0 stored, 2 inherited", result.stdout)
        for version in ("1.0", "1.1"):
            manifest = self.version_import_manifest(library, version)
            self.assertEqual({row["path"] for row in manifest["files"]},
                             {"main.c", "visible/source file.c"})
            self.assertTrue(all(not part.startswith(".") for row in manifest["files"]
                                for part in Path(row["path"]).parts))
        with closing(sqlite3.connect(library)) as database:
            names = [row[0] for row in database.execute("SELECT DISTINCT deck_name FROM deck_revisions")]
            self.assertEqual(len(names), 2)
            self.assertNotIn("scu-import-manifest.json", names)
            self.assertNotIn("import-file-" + hashlib.sha256(b".SHA1SUM").hexdigest(), names)
        self.run_scu(library, "relv")
        self.assertFalse((self.root / "release" / "scu-import-manifest.json").exists())
        self.assertTrue((self.root / "release" / "main.c").exists())
        self.assertTrue((archive / "1.0" / ".SHA1SUM").exists())
        self.run_scu(library, "verify_audit_trail")

    def test_directory_import_dry_run_validation_and_destination_protection(self):
        archive = self.root / "archive"
        (archive / "8.10").mkdir(parents=True)
        (archive / "8.0031").mkdir()
        (archive / "8.0031/main").write_bytes(b"source")
        (archive / "HISTORY").write_text("Revision: 8.0031\nDescription: First\n")
        library = self.root / "imported.sqlite"
        result = self.run_import(archive, library, "--dry-run")
        self.assertLess(result.stdout.index("Plan 8.0031"), result.stdout.index("Plan 8.10"))
        self.assertIn("[missing HISTORY description]", result.stdout)
        self.assertFalse(library.exists())
        self.assertEqual(list(self.root.glob(".scu-import-*")), [])
        result = self.run_import(archive, library, "--strict-history", success=False)
        self.assertIn("No HISTORY description found for version 8.10", result.stderr)
        self.assertFalse(library.exists())
        (archive / "8.100").mkdir()
        result = self.run_import(archive, library, "--dry-run", success=False)
        self.assertIn("Duplicate numeric version", result.stderr)
        (archive / "8.100").rmdir()
        result = self.run_import(archive, archive / "inside.sqlite", success=False)
        self.assertIn("outside the source archive", result.stderr)
        sidecar = Path(str(library) + "-wal")
        sidecar.write_bytes(b"existing WAL")
        result = self.run_import(archive, library, success=False)
        self.assertIn("Destination already exists", result.stderr)
        self.assertEqual(sidecar.read_bytes(), b"existing WAL")
        self.assertFalse(library.exists())
        sidecar.unlink()
        library.write_bytes(b"existing contents")
        result = self.run_import(archive, library, success=False)
        self.assertIn("Destination already exists", result.stderr)
        self.assertEqual(library.read_bytes(), b"existing contents")

    def test_directory_import_rejects_links_and_does_not_publish_on_scu_failure(self):
        archive = self.root / "archive"
        (archive / "1.0").mkdir(parents=True)
        (archive / "HISTORY").write_text("Revision: 1.0\nDescription: First\n")
        (archive / "1.0/main").write_bytes(b"source")
        link = archive / "1.0/link"
        link.symlink_to("main")
        library = self.root / "imported.sqlite"
        result = self.run_import(archive, library, success=False)
        self.assertIn("Symbolic links", result.stderr)
        link.unlink()
        wrapper = self.root / "failing-scu"
        wrapper.write_text(
            "#!" + sys.executable + "\nimport os, sys\n"
            "if 'lock_version' in sys.argv:\n print('injected failure', file=sys.stderr); sys.exit(9)\n"
            "os.execv(" + repr(str(SCU)) + ", [" + repr(str(SCU)) + ", *sys.argv[1:]])\n")
        wrapper.chmod(0o700)
        result = self.run_import(archive, library, "--scu", str(wrapper), success=False)
        self.assertIn("injected failure", result.stderr)
        self.assertFalse(library.exists())
        self.assertEqual(list(self.root.glob(".scu-import-*")), [])
        self.assertEqual((archive / "1.0/main").read_bytes(), b"source")


    def test_deletion_is_saved_immediately_and_survives_quit(self):
        self.store("main", b"original")
        before = self.read_library()
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"deld main\n")
            self.assertIn(b"Deleted main", read_until(b"scu> "))
            self.assertTrue(self.read_library()["revisions"][-1]["deleted"])
            os.write(terminal, b'disdl\n')
            self.assertNotIn(b"main\t", read_until(b"scu> "))
            os.write(terminal, b"disd\n")
            self.assertIn(b"  deleted", read_until(b"scu> "))
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)
        self.assertTrue(self.read_library()["revisions"][-1]["deleted"])
        result = subprocess.run([SCU], cwd=self.root, capture_output=True, text=True,
                                input="savl\nquis\n", timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.table_data(self.run_scu("disdl")), "")
        self.run_scu("verify_audit_trail")


    def test_deletion_schema_upgrade_preserves_existing_payloads_and_audit_digests(self):
        self.store("main", b"source")
        before = self.read_library()
        head = self.run_scu("verify_audit_trail")
        with closing(sqlite3.connect(self.library, isolation_level=None)) as database:
            payloads = database.execute("SELECT payload FROM deck_revisions").fetchall()
            database.executescript("ALTER TABLE deck_revisions DROP COLUMN deleted; PRAGMA user_version = 5;")
            self.assertEqual(self.run_scu("verify_audit_trail"), head)
            self.assertEqual(database.execute("PRAGMA user_version").fetchone(), (5,))
            self.run_scu("deld", "main")
            self.assertEqual(database.execute("PRAGMA user_version").fetchone(), (8,))
            self.assertEqual(database.execute("SELECT payload FROM deck_revisions WHERE sequence = 1").fetchall(), payloads)
            self.assertEqual(database.execute("SELECT deleted FROM deck_revisions ORDER BY sequence").fetchall(), [(0,), (1,)])
        self.assertEqual(self.read_library()["revisions"][0], before["revisions"][0])
        self.run_scu("verify_audit_trail", "head=" + head.split("head=")[1])

    def test_deletion_recovery_restores_history_and_rejects_invalid_markers(self):
        self.store("main", b"original")
        self.run_scu("deld", "main")
        document = self.read_library()
        recovery = self.root / "deletion-recovery.json"
        recovery.write_text(json.dumps(document))
        restored = self.root / "restored.sqlite"
        self.run_scu(restored, "recl", recovery)
        self.assertEqual(self.table_data(self.run_scu(restored, "disdl")), "")
        self.assertIn("  deleted", self.run_scu(restored, "disd", "main"))
        self.run_scu(restored, "extd", "main", "old", "r=0.000")
        self.assertEqual((self.root / "old").read_bytes(), b"original")
        self.run_scu(restored, "cred", "main")
        self.run_scu(restored, "verify_audit_trail")
        document["revisions"][-1]["deleted"] = "yes"
        recovery.write_text(json.dumps(document))
        self.run_scu(self.root / "invalid.sqlite", "recl", recovery, error="deleted")
        document["revisions"][-1] = dict(document["revisions"][0], deck_revision="0.001", deleted=True)
        recovery.write_text(json.dumps(document))
        self.run_scu(self.root / "source-in-deletion.sqlite", "recl", recovery,
                     error='Deletion revision for deck "main" contains source')


    def test_completion_skips_deleted_snapshots_but_keeps_history_and_old_versions(self):
        self.store("gone", b"original")
        self.run_scu("locv", "d=First")
        self.run_scu("crev", "1.1")
        self.run_scu("deld", "gone")
        self.run_scu("locv", "d=Deleted")
        self.run_scu("crev", "1.2")
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"extd v=1.0 dn=gon\t of=old\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "old").read_bytes(), b"original")
            os.write(terminal, b"disd gon\t\n")
            self.assertIn(b"  deleted", read_until(b"scu> "))
            os.write(terminal, b"edid gon\t\n")
            self.assertIn(b'Deck "gon" does not exist', read_until(b"scu> "))
            os.write(terminal, b"cred gone\n")
            read_until(b"scu> ")
            prefix = b"extd dn=gone of=old v=1."
            os.write(terminal, prefix + b"\t\t")
            matches = read_until(b"scu> " + prefix)
            self.assertIn(b"1.0", matches)
            self.assertIn(b"1.2", matches)
            self.assertNotIn(b"1.1", matches)
            os.write(terminal, b'\x15quis\n')
            self.assertEqual(process.wait(timeout=5), 1)


    def test_catalog_rejects_options_and_resolves_exclusive_argument_aliases(self):
        executable = self.root / "scu"
        shutil.copy2(SCU, executable)
        catalog = json.loads(SCU.with_name("commands.json").read_bytes())
        command = next(c for c in catalog["commands"] if c["name"] == "extract_deck")
        command["options"] = []
        path = self.root / "commands.json"
        path.write_text(json.dumps(catalog))
        self.run_scu("help", executable=executable, error="Use a single arguments list")
        del command["options"]
        command["exclusive_arguments"] = [["v", "r"]]
        path.write_text(json.dumps(catalog))
        help_text = self.run_scu("disc", "extd", executable=executable)
        self.assertIn("Mutually exclusive arguments", help_text)
        self.assertIn("\n  v, r\n", help_text)
        self.assertNotIn("\nOptions\n", help_text)


    def test_display_version_default_empty_versions_errors_help_and_audit(self):
        output = self.run_scu("disv")
        self.assertEqual(output, 'Version "1.0".\nDeck name  Deck version  Modified (local TZ)  Status')
        begin, end = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()[-2:]]
        self.assertEqual(begin["command"], "display_version")
        self.assertEqual(begin["parameters"], {"version": "scu$current_version"})
        self.assertEqual(begin["provided_arguments"], [])
        self.assertEqual(end["snapshot"], {"version": "1.0", "library_revision": 0})
        help_text = self.run_scu("disc", "disv")
        self.assertIn("display_version, disv", help_text)
        self.assertIn("version (v) : string = scu$current_version", help_text)
        self.run_scu("locv", "d=Empty")
        self.run_scu("crev", "1.1")
        self.assertEqual(self.run_scu("disv"), output.replace('"1.0"', '"1.1"'))
        self.assertEqual(self.run_scu("disv", "9.9", error='Version "9.9" does not exist'), "")
        self.run_scu("verify_audit_trail")

    def test_display_version_sees_automatically_saved_edits_without_prompting(self):
        (self.root / "source").write_bytes(b"pending")
        result = subprocess.run([SCU], cwd=self.root, capture_output=True, text=True, timeout=10,
                                input="import_deck pending source\ndisv\nquis\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Version "1.0".', result.stdout)
        self.assertRegex(result.stdout, r"pending +1.0-0.000 +[^\n]+ +stored")
        self.assertEqual(self.read_library()["revisions"][0]["deck"], "pending")
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        index = next(i for i, event in enumerate(events) if event.get("command") == "display_version")
        self.assertFalse(events[index + 1].get("pending_save", False))
        self.assertEqual(events[index + 1]["snapshot"], {"version": "1.0", "library_revision": 1})
        self.run_scu("verify_audit_trail")

    def test_display_version_completes_library_versions_and_selectors(self):
        self.run_scu("locv", "d=First")
        self.run_scu("crev", "1.1")
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"disv v=scu$cur\t\n")
            self.assertIn(b'Version "1.1".', read_until(b"scu> "))
            os.write(terminal, b"disv v=scu$pre\t\n")
            self.assertIn(b'Version "1.0".', read_until(b"scu> "))
            os.write(terminal, b"disv --v\t1.0\n")
            self.assertIn(b'Version "1.0".', read_until(b"scu> "))
            os.write(terminal, b"quis\n")
            self.assertEqual(process.wait(timeout=5), 0)


    def test_deck_tables_wrap_long_names_to_terminal_width_without_truncating(self):
        name = "import-file-" + "a" * 64
        self.store("a", b"short")
        self.store(name, b"long")
        raw = self.run_scu("disv")
        self.assertIn(name, raw)
        self.assertGreater(max(map(len, raw.splitlines())), 80)
        for columns in (80, 60, 32, 8, 1):
            with self.subTest(columns=columns), self.terminal_session(
                    TERM="dumb", columns=columns, rows=200) as (process, terminal, read_until):
                read_until(b"scu> ")
                for command in ("disdl", "disv", "disd"):
                    os.write(terminal, command.encode() + b"\n")
                    lines = read_until(b"scu> ").decode().splitlines()[1:-1]
                    lines = [line for line in lines if not line.startswith("Using library version ")]
                    self.assertTrue(all(len(line) <= columns for line in lines), (command, columns, lines))
                    if columns >= 60 and command in ("disdl", "disv"):
                        header = next(line for line in lines if line.startswith("Deck name "))
                        width = header.index("Deck version") - 2
                        start = next(i for i, line in enumerate(lines) if line.startswith(name[:width]))
                        count = (len(name) + width - 1) // width
                        self.assertEqual("".join(line[:width].rstrip() for line in lines[start:start + count]), name)
                os.write(terminal, b"quis\n")
                self.assertEqual(process.wait(timeout=5), 0)


    def test_library_versions_are_columns_and_do_not_change_stored_configuration(self):
        def check(version, previous, status):
            before = self.read_library()["header"]
            summary, output = self.run_scu("disl").split("\n", 1)
            self.assertEqual(summary, f'Library "{self.library}".')
            attributes = dict(re.split(r" {2,}", line, maxsplit=1)
                              for line in output.splitlines()[1:])
            self.assertEqual(attributes["current_version"], f"{version} ({status})")
            self.assertEqual(attributes["previous_locked_version"], previous)
            self.assertNotIn("versions", attributes)
            self.assertEqual(self.read_library()["header"], before)
            self.assertNotIn("previous_locked_version", before)
        check("1.0", "none", "unlocked")
        self.run_scu("locv", "d=First")
        check("1.0", "none", "locked")
        self.run_scu("crev", "1.1")
        check("1.1", "1.0", "unlocked")
        self.run_scu("locv", "d=Second")
        check("1.1", "1.0", "locked")
        self.run_scu("crev", "1.2")
        check("1.2", "1.1", "unlocked")
        self.run_scu("verify_audit_trail")

    def test_removed_version_listing(self):
        for command in ("list_versions", "lisv"):
            self.run_scu(command, error="Unknown command")
            self.assertNotIn(command, self.run_scu("help"))

    def test_other_listings_use_headers_and_aligned_spaces(self):
        self.store("main", b"source")
        self.run_scu("relv")
        self.run_scu("locv", "d=First")
        self.run_scu("crev", "123456789.1234567890")
        cases = [
            (("disat", "5"), ["Command", "Status"]),
        ]
        for arguments, headings in cases:
            with self.subTest(command=arguments[0]):
                output = self.run_scu(*arguments)
                self.assertNotIn("\t", output)
                lines = output.splitlines()
                self.assertEqual(re.split(r" {2,}", lines[0]), headings)
                starts = [lines[0].index(heading) for heading in headings]
                for line in lines[1:]:
                    self.assertTrue(all(line[start - 2:start] == "  " for start in starts[1:]))
                    self.assertTrue(all(line[start:start + 1] != " " for start in starts))
        self.run_scu("verify_audit_trail")


    def test_quit_alias_exits_the_session_and_keeps_committed_changes(self):
        self.assertEqual(self.run_scu("disc", "quit"), self.run_scu("disc", "quis"))
        self.assertIn("quit_session, quis, quit", self.run_scu("disc", "quit"))
        result = subprocess.run([SCU], cwd=self.root, capture_output=True, text=True,
                                input="cred saved\nquit\ncred after-quit\n", timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.table_data(self.run_scu("disdl")), "saved\t1.0-0.000")
        self.run_scu("quit", error="quit_session is only available in interactive mode")
        self.run_scu("verify_audit_trail")

    def test_executor_accepts_and_audits_a_command_without_the_cli(self):
        database = self.root / "frontend.sqlite"
        subprocess.run([SCU.with_name("executor_probe"), database], cwd=self.root,
                       check=True, capture_output=True, timeout=5)
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines(database)]
        creation = events[2]
        self.assertEqual(creation["command"], "create_deck")
        self.assertEqual(creation["parameters"], {"deck_name": "example.pas", "from_file": "", "comment_prefix": "#"})
        self.assertEqual(creation["provided_arguments"], ["deck_name", "comment_prefix"])
        self.assertNotIn("options", creation)
        self.assertIn("records=6 interrupted=0", self.run_scu(database, "verify_audit_trail"))


    def test_review_safe_output_defaults_and_redirected_commands(self):
        self.store("shared.inc", b"shared\n")
        self.store("main.pas", b"main\n")
        working = self.root / "main.pas"
        working.write_bytes(b"unsaved work\n")
        self.run_scu("extd", "shared.inc", "output_file=", error="Expected a file path")
        self.run_scu("extd", "shared.inc", "output_file=", "build=no", error="Expected a file path")
        self.run_scu("extd", "shared.inc", "--revision=0.000")
        self.assertEqual((self.root / "shared.inc").read_bytes(), b"shared\n")
        self.assertEqual(working.read_bytes(), b"unsaved work\n")
        self.run_scu("lock_verison", error='Unknown command "lock_verison"')
        self.run_scu("extrct_deck", "main.pas", "x.pas", error='Unknown command "extrct_deck"')

        self.run_scu("conl", "bc=cat > build-input")
        result = subprocess.run(
            [SCU, "continue_on_error=yes"], cwd=self.root, input="extd shared.inc batch-out\ncred\ncred after-build\n",
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Missing required argument deck_name", result.stderr)
        self.assertEqual((self.root / "build-input").read_bytes(), b"")
        self.assertIn("after-build\t", self.table_data(self.run_scu("disdl")))
        self.run_scu("conl", "bc=")
        self.assertEqual(json.loads(self.run_scu("display_library", "json=yes"))["build_command"], "")


    def test_review_editor_uses_path_and_removes_backup_files(self):
        self.store("main", b"old")
        programs = self.root / "programs"
        programs.mkdir()
        (self.root / "vi").write_text("#!/bin/sh\ntouch wrong-editor\n")
        (self.root / "vi").chmod(0o700)
        editor = programs / "vi"
        editor.write_text('#!/bin/sh\nprintf "%s" "$1" > editor-path\n'
                          'printf backup > "$1~"\nln -s absent "${1%/*}/.#main"\n'
                          'printf edited > "$1"\n')
        editor.chmod(0o700)
        result = subprocess.run([SCU, "edid", "main"], cwd=self.root,
                                env=dict(os.environ, PATH=str(programs)),
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "wrong-editor").exists())
        self.assertFalse(Path((self.root / "editor-path").read_text()).parent.exists())
        self.run_scu("extd", "main", "edited")
        self.assertEqual((self.root / "edited").read_bytes(), b"edited")

    def test_review_version_order_noop_stores_and_output_modes(self):
        self.store("main", b"same\n")
        (self.root / "main").write_bytes(b"same\n")
        self.assertEqual(self.run_scu("import_deck", "main", "main"), "Imported 0 new, 0 changed, 0 deleted; 1 unchanged.")
        self.assertEqual(len(self.read_library()["revisions"]), 1)
        self.run_scu("lock_version", "Test version")
        self.run_scu("create_version", "1.1")
        self.run_scu("lock_version", "Test version")
        self.run_scu("create_version", "1.02", error="must be greater")
        self.assertEqual(self.run_scu("create_version"), "Created version 1.11")
        output = self.root / "mode-output"
        result = subprocess.run([SCU, "extd", "main", output], cwd=self.root, umask=0o027,
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.stat().st_mode & 0o777, 0o640)
        output.chmod(0o751)
        self.run_scu("extd", "main", output)
        self.assertEqual(output.stat().st_mode & 0o777, 0o751)


    def test_deck_versions_are_inferred_for_legacy_entries(self):
        self.store("main", b"old\n")
        self.store("other", b"unrelated\n")
        self.store("main", b"updated\n")
        document = self.read_library()
        del document["header"]["version_increment"]
        del document["header"]["revision_increment"]
        for entry in document["revisions"]:
            del entry["deck_revision"]
        self.write_library(document)
        original = self.read_library()
        self.assertEqual([line.split()[0] for line in self.run_scu("disd", "main").splitlines()[2:]],
                         ["1.0-0.001", "1.0-0.000"])
        self.assertEqual(self.read_library(), original)
        self.store("main", b"new\n")
        self.assertEqual(self.read_library()["revisions"][-1]["deck_revision"], "0.002")

    def test_last_modified_deck_defaults_follow_the_working_library(self):
        self.assertEqual(self.read_library()["header"]["last_modified_deck"], "")
        self.run_scu("display_deck", error="No deck has been modified")
        self.run_scu("extd", error="No deck has been modified")
        self.run_scu("extd", error="No deck has been modified")
        self.run_scu("edid", error="No deck has been modified")
        self.store("main.pas", b"old\n")
        self.store("other.pas", b"unrelated\n")
        self.run_scu("lock_version", "Test version")
        self.run_scu("create_version", "1.1")
        self.assertEqual(self.read_library()["header"]["last_modified_deck"], "other.pas")
        self.store("main.pas", b"new\n//SCU$VERSION\n")
        self.assertEqual(self.read_library()["header"]["last_modified_deck"], "main.pas")

        self.assertEqual(self.run_scu("display_deck"), self.run_scu("display_deck", "main.pas"))
        self.assertTrue(self.run_scu("disd", "dn=SCU$LAST_MODIFIED_DECK").splitlines()[2].startswith("1.1-0.000 "))
        self.assertIn("--- main.pas@1.0-0.000\n+++ main.pas@1.1-0.000", self.run_scu("display_deck_diff", "output_format=unified"))
        begin, outcome = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()[-2:]]
        self.assertEqual(begin["parameters"]["deck_name"], "scu$last_modified_deck")
        self.assertEqual(outcome["resolved_deck"], "main.pas")

        self.run_scu("extd", "output_file=last-source")
        self.assertEqual((self.root / "last-source").read_bytes(), b"new\n//SCU$VERSION\n")
        self.run_scu("extd")
        self.assertEqual((self.root / "main.pas").read_bytes(), b"new\n//SCU$VERSION\n")
        begin, outcome = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()[-2:]]
        self.assertEqual(begin["parameters"], {"deck_name": "scu$last_modified_deck",
                                              "output_file": "scu$deck_name", "version": "scu$current_version", "overwrite": "no", "build": "yes"})
        self.assertEqual(outcome["resolved_deck"], "main.pas")
        self.run_scu("extd", "output_file=last-expanded")
        self.assertEqual((self.root / "last-expanded").read_bytes(), b"new\n//SCU$VERSION\n")
        self.run_scu("extd")
        self.assertEqual((self.root / "main.pas").read_bytes(), b"new\n//SCU$VERSION\n")
        begin, outcome = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()[-2:]]
        self.assertEqual(begin["parameters"], {"deck_name": "scu$last_modified_deck",
                                              "output_file": "scu$deck_name", "build": "yes", "version": "scu$current_version", "overwrite": "no"})
        self.assertEqual(outcome["resolved_deck"], "main.pas")
        self.run_scu("extd", "other.pas")
        self.assertEqual((self.root / "other.pas").read_bytes(), b"unrelated\n")
        self.assertEqual((self.root / "main.pas").read_bytes(), b"new\n//SCU$VERSION\n")
        self.run_scu("configure_library", "editor=[\"true\"]")
        self.assertEqual(self.run_scu("edid"), "No changes to main.pas")
        begin, outcome = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()[-2:]]
        self.assertEqual(begin["parameters"]["deck_name"], "scu$last_modified_deck")
        self.assertEqual(outcome["resolved_deck"], "main.pas")

        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"create_deck pending.pas\n")
            self.assertIn(b"pending.pas version 1.1 revision 0.000", read_until(b"scu> "))
            os.write(terminal, b'disd\n')
            self.assertIn(b"1.1-0.000 ", read_until(b"scu> "))
            os.write(terminal, b'disd dn=scu$last\t\n')
            self.assertIn(b"1.1-0.000 ", read_until(b"scu> "))
            os.write(terminal, b"edid\n")
            self.assertIn(b"No changes to pending.pas", read_until(b"scu> "))
            os.write(terminal, b"extd\n")
            response = read_until(b"scu> ")
            self.assertNotIn(b"deck_name= ", response)
            self.assertNotIn(b"output_file= ", response)
            self.assertEqual((self.root / "pending.pas").read_bytes(), b"")
            (self.root / "pending.pas").unlink()
            os.write(terminal, b"extd\n")
            response = read_until(b"scu> ")
            self.assertNotIn(b"deck_name= ", response)
            self.assertNotIn(b"output_file= ", response)
            self.assertEqual((self.root / "pending.pas").read_bytes(), b"")
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)
        self.assertEqual(self.read_library()["header"]["last_modified_deck"], "pending.pas")

    def test_last_modified_deck_is_inferred_for_older_libraries(self):
        self.store("legacy", b"source\n")
        document = self.read_library()
        del document["header"]["last_modified_deck"]
        self.write_library(document)
        original = self.read_library()
        self.assertEqual(json.loads(self.run_scu("display_library", "json=yes"))["last_modified_deck"], "legacy")
        self.assertTrue(self.run_scu("disd").splitlines()[2].startswith("1.0-0.000 "))
        self.assertEqual(self.read_library(), original)
        self.run_scu("create_deck", "new")
        self.assertEqual(self.read_library()["header"]["last_modified_deck"], "new")


    def test_transfer_reports_saved_empty_deck_revisions_without_prompting(self):
        self.run_scu("cred", "main")
        result = subprocess.run([SCU], cwd=self.root, capture_output=True, text=True, timeout=20,
                                input="deld main\ncred main\nextd\nextd build=no\nquis\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, 'Using library version 1.0, deck "main", deck_version 1.0-0.002.\n' * 2)
        self.assertEqual((self.root / "main").read_bytes(), b"")
        self.assertEqual(len(self.read_library()["revisions"]), 3)
        self.run_scu("verify_audit_trail")


    def crash_export_write(self, at, directory, *arguments):
        compiler = shutil.which("cc")
        if compiler is None:
            self.skipTest("A C compiler is required to interrupt export writes.")
        shim = self.root / "export_crash.so"
        if not shim.exists():
            source = self.root / "export_crash.c"
            source.write_text("""
#define _GNU_SOURCE
#include <dlfcn.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int mkstemp(char *pattern) {
    static int (*real_mkstemp)(char *);
    static int count;
    if (!real_mkstemp) real_mkstemp = dlsym(RTLD_NEXT, "mkstemp");
    const char *dir = getenv("SCU_EXPORT_CRASH_DIRECTORY");
    if (dir && !strncmp(pattern, dir, strlen(dir)) &&
        !strncmp(pattern + strlen(dir), "/.scu-", 6)) {
        if (++count == atoi(getenv("SCU_EXPORT_CRASH_AT")))
            kill(getpid(), SIGKILL);
    }
    return real_mkstemp(pattern);
}
""")
            subprocess.run([compiler, "-shared", "-fPIC", "-o", shim, source, "-ldl"],
                           check=True, capture_output=True, timeout=20)
        result = subprocess.run([SCU, *arguments], cwd=self.root, capture_output=True, timeout=10,
                                env=dict(os.environ, LD_PRELOAD=str(shim),
                                         SCU_EXPORT_CRASH_DIRECTORY=str(directory),
                                         SCU_EXPORT_CRASH_AT=str(at)))
        self.assertEqual(result.returncode, -signal.SIGKILL, result.stderr)


    def test_export_recovery_discards_unpublished_intent_and_preserves_previous_manifest(self):
        self.store("main", b"old")
        self.run_scu("extd", "main", "output")
        path = self.root / ".scu-exports.json"
        original = json.loads(path.read_bytes())
        self.store("main", b"new")
        self.crash_export_write(2, self.root, "extd", "main", "output")
        self.assertIn("pending", json.loads(path.read_bytes()))
        self.assertEqual((self.root / "output").read_bytes(), b"old")
        self.assertIn("outdated", self.run_scu("verd", "od=.", error="need attention"))
        self.assertEqual(json.loads(path.read_bytes()), original)
        self.assertEqual((self.root / "output").read_bytes(), b"old")
        self.run_scu("extd", "main", "output")
        self.assertIn("Verified 1", self.run_scu("verd", "od=."))
        self.run_scu("verify_audit_trail")

    def test_export_recovery_handles_first_exports_before_and_after_publication(self):
        self.store("main", b"content")
        for stage in (2, 3):
            with self.subTest(stage=stage):
                directory = self.root / str(stage)
                directory.mkdir()
                output = directory / "custom.raw"
                self.crash_export_write(stage, directory, "extd", "main", output)
                path = directory / ".scu-exports.json"
                record = json.loads(path.read_bytes())
                self.assertEqual(record["files"], [])
                self.assertEqual(record["pending"]["entries"][0]["previous_sha256"], "")
                expected = 0 if stage == 2 else 1
                self.assertIn(f"Verified {expected}", self.run_scu("verd", "od=" + str(directory)))
                repaired = json.loads(path.read_bytes())
                self.assertNotIn("pending", repaired)
                self.assertEqual(len(repaired["files"]), expected)
                self.assertEqual(output.exists(), stage == 3)
        self.run_scu("verify_audit_trail")

    def test_export_recovery_preserves_modified_files_and_requires_explicit_reexport(self):
        self.store("main", b"generated")
        self.crash_export_write(3, self.root, "extd", "main", "custom.raw", "overwrite=yes")
        output = self.root / "custom.raw"
        output.write_bytes(b"user edits after interruption")
        path = self.root / ".scu-exports.json"
        report = self.run_scu("verd", "od=.", error="need attention")
        self.assertIn("interrupted export", report)
        self.assertIn("locally modified", report)
        document = json.loads(path.read_bytes())
        self.assertNotIn("pending", document)
        self.assertTrue(document["files"][0]["interrupted_export"])
        interrupted = path.read_bytes()
        self.run_scu("verd", "od=.", error="need attention")
        self.assertEqual(path.read_bytes(), interrupted)
        self.assertEqual(output.read_bytes(), b"user edits after interruption")
        # An interrupted retry must retain the earlier unresolved provenance.
        self.crash_export_write(2, self.root, "extd", "main", "custom.raw", "overwrite=yes")
        self.assertIn("interrupted export", self.run_scu("verd", "od=.", error="need attention"))
        self.assertEqual(path.read_bytes(), interrupted)
        self.assertEqual(output.read_bytes(), b"user edits after interruption")
        # Unrelated exports can proceed without discarding or overwriting this file.
        self.run_scu("extd", "main", "different.raw")
        self.assertEqual(output.read_bytes(), b"user edits after interruption")
        self.run_scu("extd", "main", "custom.raw", "overwrite=yes")
        self.assertEqual(output.read_bytes(), b"generated")
        self.assertNotIn("pending", json.loads(path.read_bytes()))
        self.assertFalse(any(e.get("interrupted_export") for e in json.loads(path.read_bytes())["files"]))
        self.assertIn("Verified 2", self.run_scu("verd", "od=."))
        self.run_scu("verify_audit_trail")

    def test_export_recovery_is_idempotent_when_repair_is_also_interrupted(self):
        self.store("main", b"source")
        self.crash_export_write(3, self.root, "extd", "main", "output")
        path = self.root / ".scu-exports.json"
        original = path.read_bytes()
        self.crash_export_write(1, self.root, "verd", "od=.")
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual((self.root / "output").read_bytes(), b"source")
        self.assertIn("Verified 1", self.run_scu("verd", "od=."))
        self.assertNotIn("pending", json.loads(path.read_bytes()))
        self.run_scu("verify_audit_trail")


    def test_export_recovery_rejects_unsafe_or_malformed_pending_records(self):
        self.store("main", b"source")
        self.crash_export_write(3, self.root, "extd", "main", "output")
        path = self.root / ".scu-exports.json"
        original = json.loads(path.read_bytes())
        for target, key, value, error in (
            ("entry", "file", "../escape", "invalid or duplicate file name"),
            ("journal", "previous_sha256", "invalid", "invalid previous output checksum"),
            ("entry", "sha256", "invalid", "invalid output checksum"),
        ):
            with self.subTest(key=key):
                document = json.loads(json.dumps(original))
                destination = document["pending"]["entries"][0]["entry"] if target == "entry" else document["pending"]["entries"][0]
                destination[key] = value
                if key == "file":
                    destination.pop("file_bytes", None)
                path.write_text(json.dumps(document))
                before = path.read_bytes()
                self.run_scu("verd", "od=.", error=error)
                self.assertEqual(path.read_bytes(), before)
                self.assertEqual((self.root / "output").read_bytes(), b"source")
        path.write_text(json.dumps(original))
        self.assertIn("Verified 1", self.run_scu("verd", "od=."))


    def test_extract_version_defaults_to_current_version_without_prompting(self):
        self.store("main", b"old")
        self.run_scu("locv", "d=First")
        self.run_scu("crev", "1.1")
        self.store("main", b"current")
        directory = self.root / "outputs"
        directory.mkdir()
        self.assertEqual(self.run_scu("extv", "od=" + str(directory)).splitlines(),
                         ["Deck name  Deck version  Status", "main       1.1-0.000     Created", "Wrote 1 deck(s) for version 1.1"])
        self.assertEqual((directory / "main").read_bytes(), b"current")
        begin, end = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()[-2:]]
        self.assertEqual(begin["parameters"]["version"], "scu$current_version")
        self.assertNotIn("version", begin["provided_arguments"])
        self.assertEqual(end["snapshot"]["version"], "1.1")
        self.run_scu("extv", "v=1.0", "od=" + str(directory))
        self.assertEqual((directory / "main").read_bytes(), b"old")
        with self.terminal_session(TERM="dumb") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, ("extv od=" + str(directory) + "\n").encode())
            result = read_until(b"scu> ")
            self.assertIn(b"Wrote 1 deck(s) for version 1.1", result)
            self.assertNotIn(b"version= ", result)
            os.write(terminal, b"quis\n")
            self.assertEqual(process.wait(timeout=5), 0)
        self.assertEqual((directory / "main").read_bytes(), b"current")
        self.run_scu("verify_audit_trail")

    def test_extract_version_defaults_to_library_directory_not_working_directory(self):
        directory = self.root / "libraries"
        directory.mkdir()
        library = directory / "project.sqlite"
        self.run_scu(library, "inil")
        source = directory / "Main.pas"
        source.write_bytes(b"source")
        self.run_scu(library, "impd", "main.pas", source.name)
        self.assertEqual(self.run_scu(library, "extv").splitlines(),
                         ["Deck name  Deck version  Status", "main.pas   1.0-0.000     Unchanged", "Wrote 0 deck(s) for version 1.0, 1 unchanged"])
        self.assertEqual((directory / "Main.pas").read_bytes(), b"source")
        self.assertFalse((self.root / "Main.pas").exists())
        begin, end = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines(library)[-2:]]
        self.assertEqual(begin["parameters"]["output_directory"], "scu$library_directory")
        self.assertNotIn("output_directory", begin["provided_arguments"])
        self.assertEqual(end["output_directory"], str(directory))
        with self.terminal_session("ln=" + str(library), TERM="dumb") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"extv\n")
            output = read_until(b"scu> ")
            self.assertIn(b"Wrote 0 deck(s) for version 1.0, 1 unchanged", output)
            self.assertNotIn(b"output_directory= ", output)
            self.assertNotIn(b"version= ", output)
            os.write(terminal, b"quis\n")
            self.assertEqual(process.wait(timeout=5), 0)
        self.run_scu(library, "extv", "od=.")
        self.assertEqual((self.root / "Main.pas").read_bytes(), b"source")
        self.run_scu(library, "verify_audit_trail")

    def test_verification_output_does_not_squeeze_names_for_deleted_decks(self):
        name = "import-file-" + "a" * 64
        self.store("boards.c", b"boards")
        self.store(name, b"hidden checksums")
        self.run_scu("relv", "v=scu$latest_version")
        self.run_scu("locv", "d=First")
        self.run_scu("crev", "1.1")
        path = self.root / "release" / ".scu-exports.json"
        before = path.read_bytes()
        self.run_scu("deld", name)
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual((self.root / "release" / name).read_bytes(), b"hidden checksums")
        output = self.run_scu("verd", error="1 of 2 deck file(s) need attention")
        lines = output.splitlines()
        self.assertEqual(re.split(r" {2,}", lines[0]), ["File", "Mode", "Exported", "Latest", "Status"])
        self.assertEqual(lines[1].split()[0], "boards.c")
        self.assertIn("deleted", output)
        self.assertIn("1.1-0.000", output)
        self.assertNotIn("unavailable:", output)
        self.assertEqual(path.read_bytes(), before)
        self.assertIn("Verified 2", self.run_scu("verd", "v=1.0"))
        for columns in (80, 96):
            with self.subTest(columns=columns), self.terminal_session(
                    TERM="dumb", columns=columns) as (process, terminal, read_until):
                read_until(b"scu> ")
                os.write(terminal, b"verd\n")
                body = read_until(b"scu> ").decode().splitlines()[1:-1]
                self.assertTrue(all(len(line) <= columns for line in body), body)
                board = next(line for line in body if line.startswith("boards.c "))
                self.assertIn("current", board)
                self.assertIn("expand", board)
                width = body[0].index("Mode") - 2
                self.assertGreaterEqual(width, len("scu-import-manifest.json"))
                start = next(i for i, line in enumerate(body) if line.startswith(name[:width]))
                self.assertEqual("".join(line[:width].rstrip() for line in body[start:start + 2]), name)
                os.write(terminal, b"quis\n")
                self.assertEqual(process.wait(timeout=5), 1)
        self.run_scu("verify_audit_trail")


    def test_verification_finishes_with_deck_file_and_reason_for_every_problem(self):
        for deck in ("ok", "old", "edited", "missing", "removed", "both"):
            self.store(deck, b"original")
            self.run_scu("extd", deck)
        self.store("old", b"new")
        (self.root / "edited").write_bytes(b"local")
        (self.root / "missing").unlink()
        self.run_scu("deld", "removed")
        self.store("both", b"new")
        (self.root / "both").write_bytes(b"local")
        self.store("broken", b"old")
        self.run_scu("extd", "broken", "broken", "build=no")
        self.store("broken", b"//SCU_COPY unknown_copy\n")
        self.store("unknown", b"untracked")
        (self.root / "unknown").write_bytes(b"untracked")
        manifest = (self.root / ".scu-exports.json").read_bytes()
        output = self.run_scu("verd", "od=.", error="7 of 8 deck file(s) need attention")
        self.assertEqual(output.count("Needs attention:"), 1)
        self.assertNotIn("No errors were found", output)
        listing, attention = output.split("Needs attention:\n", 1)
        self.assertIn("current", listing)
        self.assertNotIn('Deck "ok"', attention)
        for deck, filename, status in (
            ("old", "old", "outdated"), ("edited", "edited", "locally modified"),
            ("missing", "missing", "missing"), ("removed", "removed", "deleted"),
            ("both", "both", "outdated"),
            ("broken", "broken", "outdated"), ("unknown", "unknown", "untracked"),
        ):
            with self.subTest(deck=deck):
                self.assertIn(f'Deck "{deck}", file "{filename}": {status}', attention)
        self.assertIn("Exported deck version 1.0-0.000; latest deck version 1.0-0.001.", attention)
        self.assertIn("File checksum differs from its recorded export.", attention)
        self.assertIn("Output file does not exist.", attention)
        self.assertIn("Deck is deleted in library version 1.0", attention)
        self.assertIn("No export record exists for this file.", attention)
        self.assertEqual((self.root / ".scu-exports.json").read_bytes(), manifest)
        self.assertEqual((self.root / "edited").read_bytes(), b"local")
        self.run_scu("verify_audit_trail")


    def test_verification_attention_reports_nonregular_outputs_and_continues(self):
        self.store("bad", b"bad")
        self.store("ok", b"ok")
        self.run_scu("extd", "bad")
        self.run_scu("extd", "ok")
        output = self.root / "bad"
        output.unlink()
        output.mkdir()
        report = self.run_scu("verd", "od=.", error="1 of 2 deck file(s) need attention")
        table, attention = report.split("Needs attention:\n", 1)
        self.assertRegex(table, r"ok +extract +1.0-0.000 +1.0-0.000 +current")
        self.assertIn('Deck "bad", file "bad": unavailable:', attention)
        self.assertIn("Expected a regular file", attention)
        self.assertNotIn('Deck "ok"', attention)
        self.assertTrue(output.is_dir())


    def test_export_manifests_reject_corruption_and_reserved_output_paths(self):
        self.store("main", b"source")
        manifest = self.root / ".scu-exports.json"
        manifest.write_text("invalid JSON")
        output = self.root / "output"
        output.write_bytes(b"keep")
        self.run_scu("extd", "main", "output", error="Export manifest")
        self.assertEqual(output.read_bytes(), b"keep")
        manifest.unlink()
        self.run_scu("extd", "main", "output", "build=no", "overwrite=yes")
        saved = manifest.read_bytes()
        self.run_scu("extd", "main", manifest, error="reserved for the SCU export manifest")
        self.assertEqual(manifest.read_bytes(), saved)
        document = json.loads(saved)
        document["files"][0]["file"] = "../escape"
        document["files"][0].pop("file_bytes", None)
        manifest.write_text(json.dumps(document))
        self.run_scu("verd", "od=.", error="invalid or duplicate file name")
        self.assertFalse((self.root.parent / "escape").exists())

    def test_export_manifest_updates_are_serialized_across_libraries(self):
        other = self.root / "other.sqlite"
        self.run_scu(other, "inil")
        self.store("first", b"first")
        source = self.root / "other-source"
        source.write_bytes(b"second")
        self.run_scu(other, "impd", "second", source.name)
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as workers:
            tasks = [workers.submit(self.run_scu, "extd", "first", "first"),
                     workers.submit(self.run_scu, other, "extd", "second", "second")]
            for task in tasks:
                task.result()
        manifest = json.loads((self.root / ".scu-exports.json").read_bytes())
        self.assertEqual({e["file"] for e in manifest["files"]}, {"first", "second", "other-source"})
        self.assertIn("Verified 1", self.run_scu("verd", "od=."))
        self.assertIn("Verified 2", self.run_scu(other, "verd", "od=."))
        self.run_scu("verify_audit_trail")
        self.run_scu(other, "verify_audit_trail")

    def configure_file_patterns(self, patterns, library=None):
        editor = self.root / ".set-patterns.py"
        data = self.root / ".pattern-list"
        data.write_text("\n".join(patterns) + "\n")
        editor.write_text("import pathlib, sys; pathlib.Path(sys.argv[-1]).write_bytes(pathlib.Path(sys.argv[1]).read_bytes())")
        args = (library,) if library is not None else ()
        self.run_scu(*args, "conl", "editor=" + json.dumps([sys.executable, str(editor), str(data)]))
        self.run_scu(*args, "edifp")

    def test_import_scan_snapshots_new_changed_deleted_and_inherited_files(self):
        directory = self.root / "project"
        directory.mkdir()
        library = directory / "project.sqlite"
        self.run_scu(library, "inil")
        self.configure_file_patterns(["*.c", "m*.c", "Makefile"], library)
        main = directory / "main.c"
        main.write_bytes(b"first\n")
        (directory / "removed.c").write_bytes(b"old source\n")
        (directory / "Makefile").write_bytes(b"make\n")
        (self.root / "outside.c").write_bytes(b"wrong directory")
        self.run_scu(library, "cred", "unselected.txt")
        first = self.run_scu(library, "impd")
        self.assertIn("Imported 3 new, 0 changed, 0 deleted; 0 unchanged.", first)
        self.assertEqual(self.table_data("\n".join(first.splitlines()[:-1])).splitlines(),
                         ["Makefile\t1.0-0.000\tnew", "main.c\t1.0-0.000\tnew", "removed.c\t1.0-0.000\tnew"])
        self.assertEqual(self.run_scu(library, "impd"), "Imported 0 new, 0 changed, 0 deleted; 3 unchanged.")
        self.run_scu(library, "locv", "Initial snapshot")
        self.run_scu(library, "crev", "1.1")
        self.assertEqual(self.run_scu(library, "impd"), "Imported 0 new, 0 changed, 0 deleted; 3 unchanged.")
        mtime = main.stat().st_mtime_ns
        main.write_bytes(b"changed\n")
        os.utime(main, ns=(mtime, mtime))
        (directory / "removed.c").unlink()
        (directory / "added.c").write_bytes(b"new source\n")
        changed = self.run_scu(library, "impd")
        self.assertEqual(self.table_data("\n".join(changed.splitlines()[:-1])).splitlines(),
                         ["added.c\t1.1-0.000\tnew", "main.c\t1.1-0.000\tchanged", "removed.c\t1.1-0.000\tdeleted"])
        self.assertIn("Imported 1 new, 1 changed, 1 deleted; 1 unchanged.", changed)
        self.run_scu(library, "extd", "removed.c", self.root / "old", "v=1.0")
        self.assertEqual((self.root / "old").read_bytes(), b"old source\n")
        self.run_scu(library, "extd", "removed.c", self.root / "gone", error="does not exist")
        (directory / "removed.c").write_bytes(b"old source\n")
        self.assertIn("removed.c", self.run_scu(library, "impd"))
        self.assertIn("1.1-0.001", self.run_scu(library, "disd", "removed.c"))
        self.configure_file_patterns(["added.c"], library)
        (directory / "main.c").unlink()
        self.assertEqual(self.run_scu(library, "impd"), "Imported 0 new, 0 changed, 0 deleted; 1 unchanged.")
        listing = self.table_data(self.run_scu(library, "disdl"))
        self.assertIn("main.c\t1.1-0.000", listing)
        self.assertIn("Makefile\t1.0-0.000", listing)
        self.assertIn("unselected.txt\t", listing)
        self.assertNotIn("outside.c", listing)
        self.run_scu(library, "verify_audit_trail")

    def test_import_scan_keeps_case_distinct_decks_and_revisions(self):
        self.configure_file_patterns(["*.c"])
        source = self.root / "Main.c"
        source.write_bytes(b"source")
        self.assertIn("Imported 1 new", self.run_scu("impd"))
        self.assertEqual(self.read_library()["revisions"][-1]["source_path"], "Main.c")
        source.write_bytes(b"single deck")
        self.assertIn("changed", self.run_scu("impd", "Main.c"))
        (self.root / "main.c").write_bytes(b"distinct source")
        self.assertIn("Imported 1 new", self.run_scu("impd"))
        self.run_scu("relv")
        self.assertEqual((self.root / "release/Main.c").read_bytes(), b"single deck")
        self.assertEqual((self.root / "release/main.c").read_bytes(), b"distinct source")
        self.run_scu("extd", "MAIN.C", error="does not exist")
        source.unlink()
        self.assertIn("deleted", self.run_scu("impd"))
        self.assertEqual(self.read_library()["revisions"][-1]["source_path"], "Main.c")
        self.assertIn("main.c", self.run_scu("disdl"))
        source.write_bytes(b"recreated")
        self.assertIn("new", self.run_scu("impd"))
        self.assertEqual(self.read_library()["revisions"][-1]["deck_revision"], "0.003")
        self.run_scu("verify_audit_trail")

    def test_import_scan_rejects_symlinks_and_invalid_names_without_deleting_decks(self):
        self.configure_file_patterns(["*.c"])
        (self.root / "main.c").write_bytes(b"source")
        self.run_scu("impd")
        (self.root / "main.c").unlink()
        before = self.read_library()
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "outside.c").write_bytes(b"outside")
        (self.root / "src.c").symlink_to(outside, target_is_directory=True)
        self.run_scu("impd", error="symbolic link")
        self.assertEqual(self.read_library(), before)
        (self.root / "src.c").unlink()
        (self.root / "bad.c").symlink_to(outside / "outside.c")
        self.run_scu("impd", error="symbolic link")
        self.assertEqual(self.read_library(), before)
        (self.root / "bad.c").unlink()
        (self.root / "file with spaces.c").write_bytes(b"invalid deck filename")
        self.assertIn("1 new, 0 changed, 1 deleted", self.run_scu("impd"))
        self.assertIn("file-", self.run_scu("disdl"))
        self.run_scu("verify_audit_trail")

    def test_import_scan_does_not_import_sqlite_operational_files_or_export_manifest(self):
        self.configure_file_patterns(["*", ".scu-exports.json", "library.sqlite*"])
        (self.root / "main.c").write_bytes(b"source")
        (self.root / ".scu-exports.json").write_text('{"format":1,"files":[]}')
        (self.root / "subdir").mkdir()
        self.assertIn("Imported 1 new", self.run_scu("impd"))
        self.assertEqual([r["deck"] for r in self.read_library()["revisions"]], ["main.c"])
        self.run_scu("verify_audit_trail")

    def test_import_scan_rolls_back_entire_batch_on_revision_limit_or_audit_failure(self):
        self.configure_file_patterns(["*.c"])
        for name in ("alpha.c", "limited.c", "removed.c"):
            (self.root / name).write_bytes(b"original")
        self.run_scu("impd")
        self.run_scu("conl", "revision_increment=0.999")
        (self.root / "limited.c").write_bytes(b"limit")
        self.run_scu("impd")
        before = self.read_library()
        (self.root / "alpha.c").write_bytes(b"changed")
        (self.root / "limited.c").write_bytes(b"over limit")
        (self.root / "removed.c").unlink()
        self.run_scu("impd", error="revision limit")
        self.assertEqual(self.read_library(), before)
        self.run_scu("locv", "First")
        self.run_scu("crev", "1.1")
        with closing(sqlite3.connect(self.library, isolation_level=None)) as database:
            before = self.sqlite_state(database)
            state = database.execute("SELECT * FROM audit_state").fetchall()
            database.execute("""
                CREATE TRIGGER reject_snapshot BEFORE INSERT ON audit_records
                WHEN json_extract(substr(NEW.line, 66), '$.phase') = 'end'
                 AND json_extract(substr(NEW.line, 66), '$.success') = 1
                BEGIN SELECT RAISE(ABORT, 'injected snapshot audit failure'); END
            """)
            self.run_scu("impd", error="injected snapshot audit failure")
            self.assertEqual(self.sqlite_state(database), before)
            self.assertEqual(database.execute("SELECT * FROM audit_state").fetchall(), state)
            database.execute("DROP TRIGGER reject_snapshot")
        self.assertIn("Imported 0 new, 2 changed, 1 deleted", self.run_scu("impd"))
        self.run_scu("verify_audit_trail")

    def test_import_scan_wildcards_and_prefix_only_changes_without_subdirectories(self):
        self.configure_file_patterns(["[ab]?.c", "a?.c"])
        (self.root / "nested").mkdir()
        (self.root / "nested/a3.c").write_bytes(b"not selected")
        (self.root / "a1.c").write_bytes(b"//SCU_COPY part\n")
        (self.root / "b2.c").write_bytes(b"source")
        (self.root / "skip.c").write_bytes(b"not selected")
        self.assertIn("Imported 2 new", self.run_scu("impd", "cp=#"))
        self.assertEqual([r["comment_prefix"] for r in self.read_library()["revisions"]], ["#", "#"])
        self.assertIn("2 unchanged", self.run_scu("impd"))
        self.assertIn("Imported 0 new, 2 changed", self.run_scu("impd", "cp=//"))
        self.assertEqual([r["comment_prefix"] for r in self.read_library()["revisions"][-2:]], ["//", "//"])
        self.assertNotIn("skip.c", self.table_data(self.run_scu("disdl")))
        (self.root / "a1.c").unlink()
        self.assertIn("1 deleted", self.run_scu("impd"))
        self.assertEqual(self.read_library()["revisions"][-1]["comment_prefix"], "//")
        self.run_scu("verify_audit_trail")

    def test_import_scan_cancelled_lock_wait_has_no_effect(self):
        self.configure_file_patterns(["*.c"])
        (self.root / "main.c").write_bytes(b"source")
        with self.terminal_session(TERM="dumb") as (process, terminal, read_until):
            read_until(b"scu> ")
            before = self.read_library()
            audit = self.audit_lines()
            with self.library.with_name("." + self.library.name + ".lock").open("rb") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                os.write(terminal, b"impd\n")
                read_until(b"impd")
                process.send_signal(signal.SIGINT)
                self.assertIn(b"Command cancelled.", read_until(b"scu> "))
            self.assertEqual(self.read_library(), before)
            self.assertEqual(self.audit_lines(), audit)
            os.write(terminal, b"impd\n")
            self.assertIn(b"Imported 1 new", read_until(b"scu> "))
            os.write(terminal, b"quit\n")
            self.assertEqual(process.wait(timeout=5), 0)
        self.run_scu("verify_audit_trail")

    def test_import_scan_read_error_after_staging_a_change_rolls_back(self):
        self.configure_file_patterns(["*.c"])
        (self.root / "alpha.c").write_bytes(b"first")
        (self.root / "removed.c").write_bytes(b"old")
        self.run_scu("impd")
        before = self.read_library()
        (self.root / "alpha.c").write_bytes(b"changed")
        (self.root / "removed.c").unlink()
        with (self.root / "oversized.c").open("wb") as stream:
            stream.truncate(64 * 1024 * 1024 + 1)
        self.run_scu("impd", error="File exceeds")
        self.assertEqual(self.read_library(), before)
        self.run_scu("verify_audit_trail")

    def test_file_patterns_rejects_directory_components_without_changing_configuration(self):
        self.configure_file_patterns(["*.c"])
        before = self.read_library()
        for pattern in ("src/*.c", "./*.c", "dir\\*.c", "**/*.c", "src/file.c"):
            with self.subTest(pattern=pattern):
                (self.root / ".pattern-list").write_text(pattern + "\n")
                self.run_scu("edifp", error="subdirectories are not supported yet")
                self.assertEqual(self.read_library(), before)
        self.run_scu("verify_audit_trail")

    def test_previous_subdirectory_patterns_can_be_opened_and_corrected_without_scanning(self):
        document = self.read_library()
        document["header"]["file_patterns"] = ["src/*.c"]
        recovery = self.root / "earlier-selection.json"
        recovery.write_text(json.dumps(document))
        library = self.root / "earlier.sqlite"
        self.run_scu(library, "recl", recovery)
        self.assertIn("src/*.c", self.run_scu(library, "disl"))
        with closing(sqlite3.connect(library)) as database:
            before = self.sqlite_state(database)[:2]
        self.run_scu(library, "impd", error="subdirectories are not supported yet")
        with closing(sqlite3.connect(library)) as database:
            self.assertEqual(self.sqlite_state(database)[:2], before)
        self.configure_file_patterns(["*.c"], library)
        self.assertEqual(json.loads(self.run_scu(library, "display_library", "json=yes"))["file_patterns"], ["*.c"])
        self.run_scu(library, "verify_audit_trail")

    def test_import_source_file_rejects_directory_components_and_resolves_beside_library(self):
        directory = self.root / "project"
        directory.mkdir()
        library = directory / "project.sqlite"
        self.run_scu(library, "inil")
        (directory / "main.c").write_bytes(b"library directory source")
        (self.root / "main.c").write_bytes(b"wrong working-directory source")
        self.assertIn("Imported 1 new", self.run_scu(library, "impd", "main.c", "source_file=main.c"))
        self.run_scu(library, "extd", "main.c", self.root / "check")
        self.assertEqual((self.root / "check").read_bytes(), b"library directory source")
        with closing(sqlite3.connect(library)) as database:
            before = self.sqlite_state(database)[:2]
        for value in ("./main.c", "../main.c", "src/main.c", str(directory / "main.c"), ".", ".."):
            with self.subTest(value=value):
                self.run_scu(library, "impd", "main.c", "source_file=" + value,
                             error="filename without a directory component")
                self.run_scu(library, "impd", "main.c", "--source_file", value,
                             error="filename without a directory component")
                with closing(sqlite3.connect(library)) as database:
                    self.assertEqual(self.sqlite_state(database)[:2], before)
        self.run_scu(library, "verify_audit_trail")

    def test_import_source_file_completion_uses_library_directory_and_omits_directories(self):
        directory = self.root / "project"
        directory.mkdir()
        library = directory / "project.sqlite"
        self.run_scu(library, "inil")
        (directory / "source-first").write_bytes(b"selected file")
        (directory / "source-second").write_bytes(b"another file")
        (directory / "source-folder").mkdir()
        (self.root / "source-outside").write_bytes(b"wrong directory")
        with self.terminal_session("ln=" + str(library), TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"impd deck source_file=source-\t\t")
            response = read_until(b"scu> impd deck source_file=source-")
            self.assertIn(b"source-first", response)
            self.assertIn(b"source-second", response)
            self.assertNotIn(b"source-folder", response)
            self.assertNotIn(b"source-outside", response)
            os.write(terminal, b"\x15impd deck source_file=source-f\t\n")
            self.assertIn(b"Imported 1 new", read_until(b"scu> "))
            os.write(terminal, b"quit\n")
            self.assertEqual(process.wait(timeout=5), 0)
        self.run_scu(library, "extd", "deck", self.root / "check")
        self.assertEqual((self.root / "check").read_bytes(), b"selected file")

    def test_import_scan_empty_patterns_and_named_file_defaults_and_retired_command(self):
        self.assertIn("No file patterns", self.run_scu("impd"))
        self.assertEqual(self.read_library()["revisions"], [])
        source = self.root / "main.c"
        source.write_bytes(b"first")
        self.assertIn("new", self.run_scu("impd", "main.c"))
        self.assertEqual(self.run_scu("impd", "main.c"), "Imported 0 new, 0 changed, 0 deleted; 1 unchanged.")
        self.run_scu("impd", "source_file=main.c", error="Specify deck_name")
        self.run_scu("store_deck", "main.c", source, error="Unknown command")
        self.run_scu("stod", "main.c", source, error="Unknown command")
        self.run_scu("locv", "First")
        self.run_scu("impd", error="is locked")
        self.run_scu("verify_audit_trail")


    def test_import_deck_creates_recreates_and_enforces_unlocked_versions_and_revision_limits(self):
        source = self.root / "source.scu"
        source.write_bytes(b"source")
        self.assertIn("new", self.run_scu("impd", "missing", source.name))
        self.store("main", b"original")
        self.run_scu("conl", "ri=0.999")
        self.run_scu("impd", "main", source.name)
        self.assertIn("1 unchanged", self.run_scu("impd", "main", source.name))
        source.write_bytes(b"different source")
        self.run_scu("impd", "main", source.name, error="revision limit")
        self.run_scu("locv", "d=First")
        self.run_scu("impd", "main", source.name, error="is locked")
        self.run_scu("crev", "1.1")
        self.run_scu("impd", "main", source.name)
        self.assertEqual(self.read_library()["revisions"][-1]["deck_revision"], "0.000")
        self.run_scu("conl", "ri=0.001")
        self.run_scu("deld", "main")
        self.assertIn("new", self.run_scu("impd", "main", source.name))
        self.assertEqual(self.read_library()["revisions"][-1]["deck_revision"], "0.002")
        self.assertIn("import_deck, impd", self.run_scu("disc", "impd"))
        self.run_scu("verify_audit_trail")


    def test_completion_revisions_are_per_deck_and_version(self):
        self.store("main", b"old0")
        self.store("main", b"old1")
        self.store("inherited", b"inherited")
        self.run_scu("locv", "d=First")
        self.run_scu("crev", "1.1")
        self.store("main", b"new0")
        self.store("other", b"other0")
        self.store("other", b"other1")
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"extd main v=1.0 r=0.00\t\t")
            matches = read_until(b"scu> extd main v=1.0 r=0.00")
            self.assertIn(b"r=0.000", matches)
            self.assertIn(b"r=0.001", matches)
            os.write(terminal, b"\x15extd main v=1.1 r=0.00\t of=current\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "current").read_bytes(), b"new0")
            os.write(terminal, b"extd r=0.001 v=1.0 dn=ma\t of=old\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "old").read_bytes(), b"old1")
            os.write(terminal, b"extd main r=0.001 v=1.\t of=filtered-version\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "filtered-version").read_bytes(), b"old1")
            os.write(terminal, b"quis\n")
            self.assertEqual(process.wait(timeout=5), 0)

    def test_snapshot_commands_report_and_audit_the_resolved_snapshot(self):
        source = b"'SCU$VERSION'\n"
        self.store("main.pas", source)
        self.store("shared.inc", b"shared")
        self.run_scu("locv", "d=First")
        self.run_scu("crev", "1.1")
        self.store("extra.inc", b"extra")
        for version, revision in (("1.0", 2), ("1.1", 3)):
            for command in ("display_deck_list", "extract_deck", "extract_deck"):
                with self.subTest(command=command, version=version):
                    arguments = () if command == "display_deck_list" else ("main.pas", "output")
                    result = subprocess.run([SCU, command, *arguments, "version=" + version],
                                            cwd=self.root, capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertNotIn("library revision", result.stdout + result.stderr)
                    end = json.loads(self.audit_lines()[-1].split(b" ", 1)[1])
                    self.assertEqual(end["snapshot"], {"version": version, "library_revision": revision})
                    if command == "display_deck_list":
                        self.assertEqual(result.stderr, f"Using library version {version}.\n")
                    else:
                        self.assertEqual(end["deck_version"], "1.0-0.000")
                        self.assertEqual((self.root / "output").read_bytes(),
                                         source if command == "extract_deck" else f"'{version}'\n".encode())
        for command in ("extract_deck",):
            self.run_scu(command, "missing", "output", error='Deck "missing" does not exist in version 1.1.')
        self.run_scu("disdl", "--revision", "1", error="Unknown argument")
        self.run_scu("disdl", "v=9.0", error='Version "9.0" does not exist')
        self.run_scu("verify_audit_trail")

    def test_edit_file_patterns_saves_line_list_with_the_configured_waiting_editor(self):
        self.assertEqual(self.read_library()["header"]["file_patterns"], [])
        self.assertIn("file_patterns", self.run_scu("disl"))
        editor = self.root / "pattern-editor.py"
        candidate = self.root / "new-patterns"
        candidate.write_bytes(b"  *.pas \r\n\r\n*.inc\nMakefile\nfile with spaces.c\nheader.h\n")
        editor.write_text("""
import json, pathlib, sys
assert sys.argv[1] == '--wait'
path = pathlib.Path(sys.argv[-1])
pathlib.Path('editor-observed.json').write_text(json.dumps({
    'initial': path.read_text(), 'path': str(path),
    'mode': path.stat().st_mode & 0o777, 'directory_mode': path.parent.stat().st_mode & 0o777}))
path.write_bytes(pathlib.Path(sys.argv[2]).read_bytes())
path.with_suffix('.bak').write_text('editor backup')
""")
        self.run_scu("conl", "editor=" + json.dumps([sys.executable, str(editor), "--wait", str(candidate)]))
        self.assertEqual(self.run_scu("edifp"), "Saved 5 file pattern(s).")
        observed = json.loads((self.root / "editor-observed.json").read_text())
        self.assertEqual(observed["initial"], "")
        self.assertEqual((observed["mode"], observed["directory_mode"]), (0o600, 0o700))
        self.assertFalse(Path(observed["path"]).parent.exists())
        expected = ["*.pas", "*.inc", "Makefile", "file with spaces.c", "header.h"]
        self.assertEqual(self.read_library()["header"]["file_patterns"], expected)
        self.assertEqual(self.read_library()["revisions"], [])
        event = json.loads(self.audit_lines()[-2].split(b" ", 1)[1])
        self.assertEqual(event["command"], "edit_file_patterns")
        self.assertEqual(event["parameters"], {})
        self.assertIn('"*.pas"', self.run_scu("disl"))
        self.assertIn("edit_file_patterns, edifp", self.run_scu("disc", "edifp"))

        # Reopen the same list, edit while locked, and verify that no-op edits
        # do not rewrite metadata or advance its generation.
        self.run_scu("locv", "d=Configuration is library-wide")
        with closing(sqlite3.connect(self.library)) as database:
            before = database.execute("SELECT generation, payload FROM library").fetchone()
        self.assertEqual(self.run_scu("edit_file_patterns"), "Saved 5 file pattern(s).")
        observed = json.loads((self.root / "editor-observed.json").read_text())
        self.assertEqual(observed["initial"], "\n".join(expected) + "\n")
        with closing(sqlite3.connect(self.library)) as database:
            self.assertEqual(database.execute("SELECT generation, payload FROM library").fetchone(), before)
        candidate.write_bytes(b"\n  \n")
        self.assertEqual(self.run_scu("edifp"), "Saved 0 file pattern(s).")
        self.assertEqual(self.read_library()["header"]["file_patterns"], [])
        self.run_scu("verify_audit_trail")

    def test_editor_cleanup_removes_backups_and_links_after_success_or_failure(self):
        self.store("main", b"original\n")
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "sentinel").write_text("preserve")
        editor = self.root / "cleanup-editor.py"
        editor.write_text("""
import pathlib, sys
path = pathlib.Path(sys.argv[-1])
root = path.parent
pathlib.Path('working-path').write_text(str(path))
(root / 'backup' / 'nested').mkdir(parents=True)
(root / 'backup' / 'nested' / 'saved.c').write_text('backup')
(root / '.swap').write_text('swap')
(root / 'file-link').symlink_to(pathlib.Path(sys.argv[1]) / 'sentinel')
(root / 'directory-link').symlink_to(sys.argv[1], target_is_directory=True)
(root / 'dangling-link').symlink_to(root / 'absent')
sys.exit(int(sys.argv[2]))
""")
        for status in (0, 7):
            self.run_scu("conl", "editor=" + json.dumps([sys.executable, str(editor), str(outside), str(status)]))
            self.run_scu("edid", "main", error="Editor failed with exit status 7" if status else None)
            self.assertFalse(Path((self.root / "working-path").read_text()).parent.exists())
            self.assertEqual((outside / "sentinel").read_text(), "preserve")
            self.assertTrue(outside.is_dir())
        self.run_scu("verat")

    def test_edit_file_patterns_rejects_invalid_entries_and_editor_failures_atomically(self):
        candidate = self.root / "candidate"
        editor = self.root / "editor.py"
        editor.write_text("""
import pathlib, sys
path = pathlib.Path(sys.argv[-1])
pathlib.Path('working-path').write_text(str(path))
path.write_bytes(pathlib.Path('candidate').read_bytes())
if pathlib.Path('fail-editor').exists():
    sys.exit(7)
if pathlib.Path('remove-file').exists():
    path.unlink()
""")
        self.run_scu("conl", "editor=" + json.dumps([sys.executable, str(editor)]))
        candidate.write_bytes(b"*.pas\n")
        self.run_scu("edifp")
        before = self.read_library()
        for data, error in ((b"*.inc\n../outside\n", "parent-directory"),
                            (b"src/*.c\n", "subdirectories are not supported yet"),
                            (b"/tmp/outside\n", "relative to the library directory"),
                            (b"C:\\outside\n", "relative to the library directory"),
                            (b"*.inc\x00ignored\n", "NUL bytes"),
                            (b"x" * (1024 * 1024 + 1), "exceeds")):
            with self.subTest(data=data[:40]):
                candidate.write_bytes(data)
                self.run_scu("edifp", error=error)
                self.assertEqual(self.read_library(), before)
                self.assertFalse(Path((self.root / "working-path").read_text()).parent.exists())
        candidate.write_bytes(b"*.inc\n")
        for marker, error in (("fail-editor", "Editor failed with exit status 7"),
                              ("remove-file", "editor removed the working file")):
            (self.root / marker).touch()
            self.run_scu("edifp", error=error)
            (self.root / marker).unlink()
            self.assertEqual(self.read_library(), before)
        self.run_scu("verify_audit_trail")

    def test_edit_file_patterns_audit_failure_rolls_back_configuration(self):
        editor = self.root / "editor.py"
        editor.write_text("import pathlib, sys; pathlib.Path(sys.argv[-1]).write_text('*.pas\\n')")
        self.run_scu("conl", "editor=" + json.dumps([sys.executable, str(editor)]))
        with closing(sqlite3.connect(self.library, isolation_level=None)) as database:
            before = self.sqlite_state(database)
            state = database.execute("SELECT * FROM audit_state").fetchall()
            database.execute("""
                CREATE TRIGGER reject_patterns BEFORE INSERT ON audit_records
                WHEN json_extract(substr(NEW.line, 66), '$.phase') = 'end'
                 AND json_extract(substr(NEW.line, 66), '$.success') = 1
                BEGIN SELECT RAISE(ABORT, 'injected pattern audit failure'); END
            """)
            self.run_scu("edifp", error="injected pattern audit failure")
            self.assertEqual(self.sqlite_state(database), before)
            self.assertEqual(database.execute("SELECT * FROM audit_state").fetchall(), state)
            database.execute("DROP TRIGGER reject_patterns")
        self.run_scu("edifp")
        self.assertEqual(self.read_library()["header"]["file_patterns"], ["*.pas"])
        self.run_scu("verify_audit_trail")

    def test_file_patterns_legacy_default_preserves_audited_header_bytes(self):
        document = self.read_library()
        del document["header"]["file_patterns"]
        recovery = self.root / "old-library.json"
        recovery.write_text(json.dumps(document))
        legacy = self.root / "old.sqlite"
        self.run_scu(legacy, "recl", recovery)
        self.run_scu(legacy, "verify_audit_trail")
        with closing(sqlite3.connect(legacy)) as database:
            before = database.execute("SELECT generation, payload FROM library").fetchone()
        self.assertRegex(self.run_scu(legacy, "disl"), r"(?m)^file_patterns +\[\]$")
        with closing(sqlite3.connect(legacy)) as database:
            self.assertEqual(database.execute("SELECT generation, payload FROM library").fetchone(), before)
        self.assertNotIn("file_patterns", json.loads(self.run_scu(legacy, "display_library", "json=yes")))
        self.run_scu(legacy, "conl", 'editor=["true"]')
        self.assertEqual(self.run_scu(legacy, "edifp"), "Saved 0 file pattern(s).")
        self.assertNotIn("file_patterns", json.loads(self.run_scu(legacy, "display_library", "json=yes")))
        editor = self.root / "editor.py"
        editor.write_text("import pathlib, sys; pathlib.Path(sys.argv[-1]).write_text('Makefile\\n')")
        self.run_scu(legacy, "conl", "editor=" + json.dumps([sys.executable, str(editor)]))
        self.run_scu(legacy, "edifp")
        self.assertEqual(json.loads(self.run_scu(legacy, "display_library", "json=yes"))["file_patterns"], ["Makefile"])
        self.run_scu(legacy, "verify_audit_trail")

    def test_edit_file_patterns_interrupt_preserves_configuration_and_session(self):
        self.run_scu("conl", 'editor=["sh", "-c", "echo patterns-editor-ready; exec sleep 30"]')
        before = self.read_library()
        with self.terminal_session(TERM="dumb", controlling=True) as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"edifp\n")
            read_until(b"patterns-editor-ready")
            os.write(terminal, b"\x03")
            read_until(b"scu> ")
            self.assertEqual(self.read_library(), before)
            os.write(terminal, b"quit\n")
            process.wait(timeout=5)
        self.run_scu("verify_audit_trail")

    def test_header_configures_editor_and_preserves_old_comment_prefix(self):
        self.run_scu("conl", "--comment_prefix", "#", "--editor", '["true"]')
        self.store("demo", b"#SCU$VERSION\n")
        self.assertEqual(self.run_scu("edit_deck", "demo"), "No changes to demo")
        self.assertEqual(len(self.read_library()["revisions"]), 1)
        editor = self.root / "test editor"
        editor.write_text('#!/bin/sh\nprintf "%s\\n" "$1" >> "$2"\n')
        editor.chmod(0o700)
        self.run_scu("conl", "--editor", json.dumps([str(editor), "saved text"]))
        self.assertEqual(self.run_scu("edit_deck", "demo"),
                         "demo version 1.0 revision 0.001, deck version 1.0-0.001")
        self.run_scu("lock_version", "Test version")
        self.run_scu("edit_deck", "demo", error="is locked")
        self.run_scu("create_version", "1.1")
        self.run_scu("edid", "noot", error='Deck "noot" does not exist in version 1.1.')
        self.run_scu("conl", "--comment_prefix", "//", "--editor", '["false"]')
        self.run_scu("edit_deck", "demo", error="exit status 1")
        self.run_scu("extract_deck", "demo", "output", "--version", "1.0")
        self.assertEqual((self.root / "output").read_bytes(), b"#SCU$VERSION\nsaved text\n")
        header = json.loads(self.run_scu("display_library", "json=yes"))
        self.assertEqual(header["current_version"], "1.1")
        self.assertEqual(header["comment_prefix"], "//")
        self.assertEqual(header["editor"], ["false"])
        self.assertTrue(header["versions"][0]["locked"])
        self.assertEqual(header["versions"][0]["comment_prefix"], "#")
        self.assertEqual([entry["comment_prefix"] for entry in self.read_library()["revisions"]], ["#", "#"])

    def test_audit_detects_modified_records_and_checkpoint_rollback(self):
        self.run_scu("extract_deck", "missing", "output", error="does not exist")
        checkpoint = self.run_scu("verify_audit_trail").split("head=")[1]
        self.store("empty", b"")
        self.run_scu("verify_audit_trail", "--head", checkpoint)
        records = self.audit_lines()
        failed = json.loads(records[3].split(b" ", 1)[1])
        self.assertFalse(failed["success"])
        with closing(sqlite3.connect(self.library, isolation_level=None)) as database:
            database.execute("DELETE FROM audit_records WHERE sequence > 3")
            self.run_scu("verify_audit_trail", error="does not match the audit log")
            self.run_scu("verify_audit_trail", "--head", checkpoint, error="Saved audit head")
            database.executemany("INSERT INTO audit_records (sequence, line) VALUES (?, ?)", (
                (index, line.decode()) for index, line in enumerate(records[3:], start=4)
            ))
            database.execute("UPDATE audit_records SET line = replace(line, ?, ?) WHERE sequence = 5",
                             ('"empty"', '"other"'))
        self.run_scu("verify_audit_trail", error="digest mismatch")
        self.run_scu("import_deck", "other", "input", error="digest mismatch")

    def test_one_shot_commands_reuse_audit_state_and_full_verification_reads_the_prefix(self):
        self.table_data(self.run_scu("display_version_history"))
        head = self.run_scu("verify_audit_trail").split("head=")[1]
        with closing(sqlite3.connect(self.library, isolation_level=None)) as database:
            self.assertEqual(database.execute("SELECT record_count, head FROM audit_state").fetchone(), (4, head))
            trigger, = database.execute(
                "SELECT sql FROM sqlite_master WHERE name = 'audit_state_update'"
            ).fetchone()
            # Bypass normal SQL invalidation to simulate tampering with the verified prefix on disk.
            database.execute("DROP TRIGGER audit_state_update")
            database.execute("UPDATE audit_records SET line = replace(line, 'initialize_library', 'initialize_other') "
                             "WHERE sequence = 1")
            database.execute(trigger)
            self.table_data(self.run_scu("display_version_history"))
            last, = database.execute("SELECT line FROM audit_records WHERE sequence = 6").fetchone()
            self.assertEqual(database.execute("SELECT record_count, head FROM audit_state").fetchone(),
                             (6, last[:64]))
        self.run_scu("verify_audit_trail", error="Audit digest mismatch at record 1")

    def test_audit_state_is_seeded_for_an_existing_library(self):
        self.table_data(self.run_scu("display_version_history"))
        with closing(sqlite3.connect(self.library, isolation_level=None)) as database:
            database.executescript("""
                DROP TRIGGER audit_state_insert;
                DROP TRIGGER audit_state_update;
                DROP TRIGGER audit_state_delete;
                DROP INDEX audit_digest;
                DROP TABLE audit_state;
                PRAGMA user_version = 3;
            """)
            self.assertIn("records=4 interrupted=0", self.run_scu("verify_audit_trail"))
            self.assertEqual(database.execute("PRAGMA user_version").fetchone(), (3,))
            self.table_data(self.run_scu("display_version_history"))
            self.assertEqual(database.execute("SELECT record_count FROM audit_state").fetchone(), (6,))
            database.execute("UPDATE audit_state SET head = ?", ("0" * 64,))
        self.table_data(self.run_scu("display_version_history", error="Stored audit state does not match the audit log"))
        self.run_scu("verify_audit_trail", error="Stored audit state does not match the audit log")

    def test_history_successful_commands_have_no_pending_saves(self):
        (self.root / "first").write_bytes(b"first\n")
        (self.root / "second").write_bytes(b"second\n")
        script = (
            "cred pending\nimport_deck pending first\nimport_deck pending second\n"
            "extd pending copied\ndisdl\ndisvh\n"
            "conl bc=true\nconl bc=true\ndisplay_audit_trail\nquis\n"
        )
        result = subprocess.run([SCU], cwd=self.root, input=script,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "copied").read_bytes(), b"second\n")
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        attempts = [(events[index]["command"], events[index + 1])
                    for index in range(0, len(events), 2)]
        pending = [(name, outcome.get("pending_save", False)) for name, outcome in attempts[1:]]
        self.assertEqual(pending, [
            ("create_deck", False), ("import_deck", False), ("import_deck", False),
            ("extract_deck", False), ("display_deck_list", False),
            ("display_version_history", False), ("configure_library", False),
            ("configure_library", False),
        ])
        self.assertIn('extract_deck deck_name=pending output_file=copied version="scu$current_version"', result.stdout)
        self.assertRegex(result.stdout, r"display_version_history display_description=short limit=10 +succeeded")

    def test_background_terminal_eio_does_not_end_the_session(self):
        bash = shutil.which("bash")
        if bash is None:
            self.skipTest("Job-control shell required.")
        output = self.root / "background-output"
        errors = self.root / "background-errors"
        with self.terminal_session("--noprofile", "--norc", "-i", TERM="dumb",
                                   PS1="test-shell> ", HISTFILE="/dev/null",
                                   controlling=True, executable=bash) as (shell, terminal, read_until):
            read_until(b"test-shell> ")
            command = ("(trap '' TTIN TTOU; TERM=dumb exec " + shlex.quote(str(SCU)) +
                       " >background-output 2>background-errors) &\n")
            os.write(terminal, command.encode())
            read_until(b"test-shell> ")
            deadline = time.monotonic() + 8
            while not errors.exists() or b"scu> " not in errors.read_bytes():
                self.assertLess(time.monotonic(), deadline, "Background SCU did not reach its prompt")
                time.sleep(0.02)
            children = Path(f"/proc/{shell.pid}/task/{shell.pid}/children").read_text().split()
            self.assertEqual(len(children), 1)
            pid = int(children[0])
            os.write(terminal, b"echo SHELL-ALIVE\n")
            read_until(b"\r\nSHELL-ALIVE\r\n")
            self.assertTrue(Path(f"/proc/{pid}").exists())
            self.assertEqual(os.tcgetpgrp(terminal), shell.pid)
            os.write(terminal, b"fg %1\n")
            deadline = time.monotonic() + 8
            while os.tcgetpgrp(terminal) != pid:
                self.assertLess(time.monotonic(), deadline, "SCU did not gain the foreground")
                time.sleep(0.02)
            os.write(terminal, b'quis\n')
            deadline = time.monotonic() + 8
            while os.tcgetpgrp(terminal) != shell.pid:
                self.assertLess(time.monotonic(), deadline, "The shell did not regain the terminal")
                time.sleep(0.02)
            os.write(terminal, b"exit\n")
            self.assertEqual(shell.wait(timeout=8), 0)
        self.assertNotIn(b"Unknown command", errors.read_bytes())
        self.assertNotIn(b"SHELL-ALIVE", output.read_bytes())

    def test_signal_at_partial_prompt_writes_a_final_newline(self):
        with self.terminal_session(TERM="xterm", controlling=True) as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"unfinished")
            read_until(b"unfinished")
            process.send_signal(signal.SIGTERM)
            self.assertIn(b"\r\n", read_until(b"\r\n"))
            self.assertEqual(process.wait(timeout=8), 128 + signal.SIGTERM)

    def test_display_audit_trail_lists_expanded_commands_and_accepts_a_line_count(self):
        for index in range(1, 22):
            self.run_scu("cred", f"deck-{index}")
        self.table_data(self.run_scu("disdl", "v=1.0"))
        self.run_scu("extd", "dn=deck-21", "of=output copy")
        before = self.audit_lines()
        history = self.table_data(self.run_scu("display_audit_trail")).splitlines()
        self.assertEqual(len(history), 20)
        self.assertEqual(history[0], 'create_deck deck_name=deck-4\tsucceeded')
        self.assertEqual(history[-2:], [
            "display_deck_list version=1.0\tsucceeded",
            'extract_deck deck_name=deck-21 output_file="output copy" version="scu$current_version" overwrite=no build=yes\tsucceeded',
        ])
        self.assertEqual(self.table_data(self.run_scu("disat", "2")).splitlines(), history[-2:])
        self.assertEqual(self.table_data(self.run_scu("display_audit_trail", "nol=1")), history[-1])
        self.table_data(self.run_scu("display_audit_trail", "0", error="Expected a positive number_of_lines"))
        self.assertEqual(self.audit_lines(), before)

    def test_display_audit_trail_reports_failures_without_waiting_on_the_library_lock(self):
        self.run_scu("extd", "missing", "output", error="does not exist")
        self.run_scu("cred", "saved")
        before = self.audit_lines()
        with (self.root / ".library.sqlite.lock").open("rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            result = subprocess.run([SCU, "display_audit_trail", "2"], cwd=self.root,
                                    capture_output=True, text=True, timeout=2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.table_data(result.stdout).splitlines(), [
            'extract_deck deck_name=missing output_file=output version="scu$current_version" overwrite=no build=yes\tfailed',
            'create_deck deck_name=saved\tsucceeded',
        ])
        self.assertEqual(self.audit_lines(), before)
        # A begin without a matching end is still visible after a later command.
        with closing(sqlite3.connect(self.library)) as database, database:
            database.execute("DELETE FROM audit_records WHERE sequence = (SELECT max(sequence) FROM audit_records)")
        self.table_data(self.run_scu("disdl"))
        self.assertTrue(self.table_data(self.run_scu("disat", "2")).splitlines()[0].endswith("\tinterrupted"))


    def test_version_history_completes_positional_values_and_long_named_arguments(self):
        self.run_scu("locv", "description=First\nMore detail")
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"disvh fu\t 0\n")
            self.assertIn(b"First\nMore detail", read_until(b"scu> ").replace(b"\r\n", b"\n"))
            os.write(terminal, b"disvh --display_d\tf --lim\t0\n")
            self.assertIn(b"First\nMore detail", read_until(b"scu> ").replace(b"\r\n", b"\n"))
            os.write(terminal, b"disvh sh\t0\n")
            output = read_until(b"scu> ")
            self.assertIn(b"First", output)
            self.assertNotIn(b"More detail", output)
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)
        text = self.run_scu("display_command", "disvh")
        arguments = text.split("Arguments\n", 1)[1]
        self.assertIn("display_description (dd) : enum", arguments)
        self.assertIn("limit (l) : integer = 10", arguments)
        self.assertNotIn("\nOptions\n", text)
        self.assertIn("scu disvh short 0", text)


    def test_version_history_limit_validation_help_and_audit_defaults(self):
        self.assertEqual(len(self.run_scu("disvh").splitlines()), 2)
        event = json.loads(self.audit_lines()[-2].split(b" ", 1)[1])
        self.assertEqual(event["parameters"]["limit"], "10")
        self.run_scu("disvh", "l=0")
        event = json.loads(self.audit_lines()[-2].split(b" ", 1)[1])
        self.assertEqual(event["parameters"]["limit"], "0")
        before = self.read_library()
        self.run_scu("disvh", "limit=-1", error="Expected a nonnegative integer for limit")
        for value in ("1.5", "many", "9223372036854775808", ""):
            with self.subTest(value=value):
                self.run_scu("disvh", "limit=" + value, error="Expected integer value for limit")
        self.assertEqual(self.read_library(), before)
        self.assertIn("limit (l) : integer = 10", self.run_scu("display_command", "disvh"))
        with self.terminal_session(TERM="dumb") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"disvh\n")
            output = read_until(b"scu> ")
            self.assertIn(b"Version", output)
            self.assertNotIn(b"limit= ", output)
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)
        self.run_scu("verify_audit_trail")


    def test_enum_completion_and_default_history_mode_do_not_prompt(self):
        self.run_scu("locv", "description=First\nSecond")
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"disvh\n")
            output = read_until(b"scu> ")
            self.assertIn(b"First", output)
            self.assertNotIn(b"Second", output)
            os.write(terminal, b"disvh dd=fu\t\n")
            self.assertIn(b"First\nSecond", read_until(b"scu> ").replace(b"\r\n", b"\n"))
            os.write(terminal, b"disvh --display_description sh\t\n")
            self.assertNotIn(b"Second", read_until(b"scu> "))
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        histories = [event for event in events if event.get("command") == "display_version_history"]
        self.assertEqual([event["parameters"]["display_description"] for event in histories], ["short", "full", "short"])

    def test_enum_positional_arguments_validate_quote_prompt_and_complete(self):
        executable = self.root / "scu"
        shutil.copy2(SCU, executable)
        catalog = json.loads(SCU.with_name("commands.json").read_bytes())
        command = next(item for item in catalog["commands"] if item["name"] == "lock_version")
        argument = command["arguments"][0]
        argument["type"] = "enum"
        argument["values"] = ["Ready now", "Wait later"]
        (self.root / "commands.json").write_text(json.dumps(catalog))
        self.run_scu("locv", "d=not allowed", executable=executable,
                     error="Expected one of [Ready now, Wait later] for description")
        self.run_scu("locv", executable=executable, error="Missing required argument description")
        with self.terminal_session(TERM="xterm", executable=executable) as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"locv\n")
            prompt = read_until(b"description= ")
            self.assertIn(b"description (d) : enum [Ready now, Wait later] = scu$required", prompt)
            os.write(terminal, b"Re\t\n")
            self.assertIn(b"Locked version 1.0", read_until(b"scu> "))
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)
        self.assertEqual(self.read_library()["header"]["versions"][0]["description"], "Ready now")
        self.run_scu("crev", "1.1")
        result = subprocess.run([executable], cwd=self.root, capture_output=True, text=True, timeout=20,
                                input="locv d=\"Wait later\"\nquis\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_library()["header"]["versions"][-1]["description"], "Wait later")

    def test_enum_value_aliases_are_canonical_in_help_execution_and_audit(self):
        self.run_scu("locv", "description=First line\nSecond line")
        self.assertEqual(self.run_scu("disvh", "dd=s"), self.run_scu("disvh", "dd=short"))
        self.assertEqual(self.run_scu("disvh", "dd=F"), self.run_scu("disvh", "dd=full"))
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        histories = [event for event in events if event.get("command") == "display_version_history"]
        self.assertEqual([event["parameters"]["display_description"] for event in histories],
                         ["short", "short", "full", "full"])
        self.assertIn("enum [short (s), full (f)]", self.run_scu("display_command", "disvh"))
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            prefix = b"disvh dd="
            os.write(terminal, prefix + b"\t\t")
            output = read_until(b"scu> " + prefix)
            self.assertIn(b"short", output)
            self.assertIn(b"full", output)
            self.assertIn(b"dd=f ", output)
            self.assertIn(b"dd=s ", output)
            os.write(terminal, b"f\n")
            self.assertIn(b"First line\nSecond line", read_until(b"scu> ").replace(b"\r\n", b"\n"))
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)
        self.run_scu("verify_audit_trail")

    def test_enum_value_alias_defaults_and_quoted_argument_aliases(self):
        executable = self.root / "scu"
        shutil.copy2(SCU, executable)
        catalog = json.loads(SCU.with_name("commands.json").read_bytes())
        lock = next(c for c in catalog["commands"] if c["name"] == "lock_version")
        lock["arguments"][0].update(type="enum", values=[
            {"name": "Ready now", "aliases": ["publish", "r"]},
            {"name": "Wait later", "aliases": ["do later", "w"]}])
        history = next(c for c in catalog["commands"] if c["name"] == "display_version_history")
        history["arguments"][0]["value"] = "f"
        (self.root / "commands.json").write_text(json.dumps(catalog))
        self.assertIn("enum [short (s), full (f)] = full", self.run_scu("display_command", "disvh", executable=executable))
        with self.terminal_session(TERM="xterm", executable=executable) as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"locv d=publ\t\n")
            self.assertIn(b"Locked version 1.0", read_until(b"scu> "))
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)
        self.assertEqual(self.read_library()["header"]["versions"][0]["description"], "Ready now")
        self.run_scu("crev", "1.1")
        result = subprocess.run([executable], cwd=self.root, input="locv d=\"do later\"\ndisvh\nquis\n",
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_library()["header"]["versions"][-1]["description"], "Wait later")
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        locks = [event for event in events if event.get("command") == "lock_version"]
        self.assertEqual([event["parameters"]["description"] for event in locks], ["Ready now", "Wait later"])
        history = next(event for event in events if event.get("command") == "display_version_history")
        self.assertEqual(history["parameters"]["display_description"], "full")
        self.run_scu("verify_audit_trail")

    def test_enum_value_alias_collisions_are_rejected_at_catalog_load(self):
        executable = self.root / "scu"
        shutil.copy2(SCU, executable)
        original = json.loads(SCU.with_name("commands.json").read_bytes())
        for values in (
                [{"name": "short", "aliases": ["s"]}, {"name": "full", "aliases": ["S"]}],
                [{"name": "short", "aliases": ["full"]}, {"name": "full"}],
                [{"name": "short", "aliases": ["SHORT"]}],
                [{"name": "short", "aliases": ["s", "S"]}],
                [{"name": "short", "aliases": [""]}],
                [{"name": "short", "aliases": [1]}],
                [{"name": "short", "aliases": ["line\nbreak"]}]):
            with self.subTest(values=values):
                catalog = json.loads(json.dumps(original))
                history = next(c for c in catalog["commands"] if c["name"] == "display_version_history")
                history["arguments"][0]["values"] = values
                (self.root / "commands.json").write_text(json.dumps(catalog))
                self.run_scu("help", executable=executable, error="Could not load command catalog")

    def test_yes_no_switches_use_enum_aliases_and_canonical_audit_values(self):
        catalog = json.loads(SCU.with_name("commands.json").read_bytes())
        parameters = [catalog["batch_argument"], *(p for c in catalog["commands"] for p in c["arguments"])]
        self.assertFalse(any(p["type"] == "boolean" for p in parameters))
        for parameter in parameters:
            if parameter["name"] in ("build", "save_library", "continue_on_error", "ignore_space_changes"):
                self.assertEqual(parameter["type"], "enum")
                self.assertEqual(parameter["values"], [{"name": "yes", "aliases": ["y"]}, {"name": "no", "aliases": ["n"]}])
        self.store("main", b"source")
        self.run_scu("extd", "main", "expanded", "build=N")
        event = json.loads(self.audit_lines()[-2].split(b" ", 1)[1])
        self.assertEqual(event["parameters"]["build"], "no")
        self.assertEqual((self.root / "expanded").read_bytes(), b"source")
        result = subprocess.run([SCU, "coe=Y"], cwd=self.root, capture_output=True, text=True, timeout=20,
                                input="unknown_command\ncred continued\nquis\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("continued version", result.stdout)
        self.assertIn("continued\t", self.table_data(self.run_scu("disdl")))
        self.assertEqual(self.run_scu("disc", "quis").splitlines()[-1], "  None")
        self.run_scu("verify_audit_trail")

    def test_enum_definitions_and_defaults_are_validated_at_startup(self):
        executable = self.root / "scu"
        shutil.copy2(SCU, executable)
        original = json.loads(SCU.with_name("commands.json").read_bytes())
        audit = self.audit_lines()
        for changes, message in (
                ({"values": []}, "Expected nonempty enum values"),
                ({"values": None}, 'Invalid JSON field "values"'),
                ({"values": [1]}, "Expected an enum string or definition object"),
                ({"values": [""]}, "Expected a nonempty enum value"),
                ({"values": [" short"]}, "without surrounding whitespace"),
                ({"values": ["short", "SHORT"]}, 'Duplicate enum value or alias "SHORT"'),
                ({"values": ["line\nbreak"]}, "Enum values must be on one line"),
                ({"value": "bad"}, "Expected one of [short (s), full (f)]"),
                ({"value": 1}, "Expected a string default for enum"),
                ({"type": "string"}, "Allowed values require enum type"),
                ({"completion": "file"}, "Enum completion requires enum type and values")):
            with self.subTest(changes=changes):
                catalog = json.loads(json.dumps(original))
                command = next(c for c in catalog["commands"] if c["name"] == "display_version_history")
                command["arguments"][0].update(changes)
                (self.root / "commands.json").write_text(json.dumps(catalog))
                self.run_scu("help", executable=executable, error=message)
        catalog = json.loads(json.dumps(original))
        command = next(c for c in catalog["commands"] if c["name"] == "display_version_history")
        del command["arguments"][0]["values"]
        (self.root / "commands.json").write_text(json.dumps(catalog))
        self.run_scu("help", executable=executable, error="Expected nonempty enum values")
        self.assertEqual(self.audit_lines(), audit)


    def test_lock_version_requires_description_and_rolls_back_audit_failure(self):
        self.run_scu("lock_version", error="Missing required argument description")
        self.run_scu("lock_version", "description=", error="nonempty version description")
        self.run_scu("lock_version", "  ", error="nonempty version description")
        self.assertFalse(self.read_library()["header"]["versions"][0]["locked"])
        with closing(sqlite3.connect(self.library, isolation_level=None)) as database:
            database.execute("""
                CREATE TRIGGER reject_locked_outcome BEFORE INSERT ON audit_records
                WHEN json_extract(substr(NEW.line, 66), '$.phase') = 'end'
                AND json_extract(substr(NEW.line, 66), '$.success') = 1
                BEGIN SELECT RAISE(ABORT, 'injected lock audit failure'); END
            """)
            self.run_scu("locv", "d=Ready", error="injected lock audit failure")
            database.execute("DROP TRIGGER reject_locked_outcome")
        entry = self.read_library()["header"]["versions"][0]
        self.assertFalse(entry["locked"])
        self.assertNotIn("locked_utc", entry)
        self.assertNotIn("description", entry)
        self.assertIn("interrupted=0", self.run_scu("verify_audit_trail"))

    def test_interactive_lock_editor_cancellation_and_multiline_description(self):
        editor = ["sh", "-c", "echo lock-editor-ready; exec sleep 30"]
        self.run_scu("conl", "editor=" + json.dumps(editor))
        with self.terminal_session(TERM="dumb", controlling=True) as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"locv\n")
            read_until(b"lock-editor-ready")
            os.write(terminal, b"\x03")
            read_until(b"scu> ")
            self.assertFalse(self.read_library()["header"]["versions"][0]["locked"])
            editor = ["sh", "-c", """printf 'First line\\n\\nSecond paragraph\\n' > "$1" """, "editor"]
            self.run_scu("conl", "editor=" + json.dumps(editor))
            os.write(terminal, b"lock_version\n")
            self.assertIn(b"Locked version 1.0", read_until(b"scu> "))
            os.write(terminal, b"disvh dd=full\n")
            self.assertIn(b"First line\n\nSecond paragraph", read_until(b"scu> ").replace(b"\r\n", b"\n"))
            os.write(terminal, b"quit\n")
            process.wait(timeout=5)
        description = "First line\n\nSecond paragraph"
        self.assertEqual(self.read_library()["header"]["versions"][0]["description"], description)
        begins = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        self.assertEqual([e["parameters"]["description"] for e in begins
                          if e["phase"] == "begin" and e["command"] == "lock_version"], [description])

    def test_old_version_history_loads_without_inventing_lock_metadata(self):
        document = self.read_library()
        document["header"]["versions"][0]["locked"] = True
        self.write_library(document)
        self.assertEqual(re.split(r" {2,}", self.run_scu("disvh").splitlines()[-1]), ["1.0", "locked", "None"])
        self.run_scu("create_version", "1.1")
        stored = self.read_library()["header"]["versions"][0]
        self.assertNotIn("locked_utc", stored)
        self.assertNotIn("description", stored)

    def test_catalog_loads_without_the_handler_dependencies(self):
        source = self.root / "catalog_probe.pas"
        source.write_text("""
program CatalogProbe;
{$mode objfpc}{$H+}
uses ScuCommands;
var Catalog: TCommandCatalog;
begin
  Catalog := TCommandCatalog.Create(ParamStr(1));
  try
    WriteLn(Catalog.Commands.Count);
  finally
    Catalog.Free;
  end;
end.
""")
        units = self.root / "units"
        units.mkdir()
        project = Path(__file__).resolve().parents[1]
        compiled = subprocess.run(
            ["fpc", "-Fu" + str(project / "src"), "-FU" + str(units),
             "-FE" + str(self.root), source],
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
        for dependency in ("scucommandregistry.pas", "scuexecutor.pas", "scuaudit.pas", "sculibrary.pas"):
            self.assertNotIn(dependency, compiled.stdout.lower())
        catalog = json.loads(SCU.with_name("commands.json").read_bytes())
        catalog["commands"][0]["name"] = "frontend_only_command"
        path = self.root / "catalog.json"
        path.write_text(json.dumps(catalog))
        result = subprocess.run([self.root / "catalog_probe", path],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(int(result.stdout), len(catalog["commands"]))

    def test_signal_after_commit_preserves_the_successful_command(self):
        compiler = shutil.which("cc")
        if compiler is None:
            self.skipTest("A C compiler is required to inject a signal at commit.")
        source = self.root / "interrupt_after_commit.c"
        source.write_text("""
#define _GNU_SOURCE
#include <dlfcn.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
typedef int (*exec_fn)(void *, const char *, void *, void *, char **);
int sqlite3_exec(void *db, const char *sql, void *callback, void *arg, char **error) {
    static exec_fn real_exec;
    static int sent;
    if (!real_exec) real_exec = (exec_fn)dlsym(RTLD_NEXT, "sqlite3_exec");
    int result = real_exec(db, sql, callback, arg, error);
    if (!sent && result == 0 && strcmp(sql, "COMMIT") == 0) {
        sent = 1;
        kill(getpid(), atoi(getenv("SCU_TEST_SIGNAL")));
    }
    return result;
}
""")
        library = self.root / "interrupt_after_commit.so"
        subprocess.run([compiler, "-shared", "-fPIC", "-o", library, source, "-ldl"],
                       check=True, capture_output=True, timeout=20)
        for termination, expected in ((signal.SIGINT, 0), (signal.SIGTERM, 143)):
            with self.subTest(signal=termination):
                path = self.root / (termination.name + ".sqlite")
                self.run_scu(path, "inil")
                result = subprocess.run(
                    [SCU, path], cwd=self.root,
                    input="locv description=\"Completed command\"\nquis\n",
                    capture_output=True, text=True, timeout=10,
                    env=dict(os.environ, LD_PRELOAD=str(library), SCU_TEST_SIGNAL=str(int(termination))),
                )
                self.assertEqual(result.returncode, expected, result.stderr)
                if termination == signal.SIGINT:
                    self.assertIn("Locked version 1.0", result.stdout)
                self.assertNotIn("Command cancelled", result.stderr)
                self.assertIn("1.0\tlocked", self.table_data(self.run_scu(path, "disvh")))
                events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines(path)]
                self.assertTrue(all(event["success"] for event in events if event["phase"] == "end"))
                self.assertIn("interrupted=0", self.run_scu(path, "verify_audit_trail"))

    def test_archive_import_destination_uses_the_same_sqlite_extension_rule(self):
        archive = self.root / "archive"
        (archive / "1.0").mkdir(parents=True)
        (archive / "1.0/main.c").write_bytes(b"source")
        (archive / "HISTORY").write_text("Revision: 1.0\nDescription: First\n")
        for extension in (".json", ".db", ".sqlite3", ".other"):
            destination = self.root / ("invalid" + extension)
            result = self.run_import(archive, destination, success=False)
            self.assertIn("Library filename must have the .sqlite extension", result.stderr)
            self.assertFalse(destination.exists())
        destination = self.root / "imported"
        result = self.run_import(archive, destination)
        self.assertIn("Created " + str(destination) + ".sqlite", result.stdout)
        self.assertFalse(destination.exists())
        self.assertTrue(destination.with_suffix(".sqlite").exists())
        self.run_scu(destination, "verify_audit_trail")
        result = self.run_import(archive, destination, success=False)
        self.assertIn("Destination already exists", result.stderr)


    def test_output_replacement_preserves_group(self):
        group = next((group for group in os.getgroups() if group != os.getegid()), None)
        if group is None and os.geteuid() == 0:
            group = 65534 if os.getegid() != 65534 else 1
        if group is None:
            self.skipTest("A second writable group is required.")
        self.store("main", b"replacement")
        target = self.root / "target"
        target.write_bytes(b"old")
        try:
            os.chown(target, -1, group)
        except OSError as error:
            if error.errno in (errno.EINVAL, errno.EPERM):
                self.skipTest("The second group is unavailable in this user namespace.")
            raise
        target.chmod(0o640)
        self.run_scu("extd", "main", target, "overwrite=yes")
        self.assertEqual(target.read_bytes(), b"replacement")
        self.assertEqual(target.stat().st_gid, group)
        self.assertEqual(target.stat().st_mode & 0o777, 0o640)

    def test_bulk_outcomes_audit_the_canonical_output_directory(self):
        self.store("main", b"code")
        target = self.root / "destination"
        target.mkdir()
        (self.root / "alias").symlink_to(target, target_is_directory=True)
        for command in ("extract_version", "release_version"):
            with self.subTest(command=command):
                self.run_scu(command, "1.0", "alias")
                outcome = json.loads(self.audit_lines()[-1].split(b" ", 1)[1])
                self.assertEqual(outcome["output_directory"], str(target))


    def test_revision_payload_parser_matches_generic_json_parsing(self):
        source = self.root / "revision_json_probe.pas"
        source.write_text("""
program RevisionJSONProbe;
{$mode objfpc}{$H+}
uses SysUtils, FPJSON, ScuErrors, ScuFiles, ScuJSON, ScuRevisionJSON;

function Serialized(const Payload: RawByteString; Optimized: Boolean): RawByteString;
var
  Document: TJSONObject;
begin
  try
    if Optimized then
      Document := ParseRevisionPayload(Payload, 'test revision')
    else
      Document := ParseObject(Payload, 'test revision');
    try
      Result := Document.AsJSON;
    finally
      Document.Free;
    end;
  except
    on E: EScuError do Result := 'JSON error: ' + E.Message;
  end;
end;

var
  Index: Integer;
  Payload: RawByteString;
begin
  for Index := 1 to ParamCount do
  begin
    Payload := ReadBytes(ParamStr(Index), 1024 * 1024);
    if Serialized(Payload, False) <> Serialized(Payload, True) then
      raise Exception.Create('Parser mismatch for ' + ParamStr(Index));
  end;
  WriteLn('matched');
end.
""")
        units = self.root / "units"
        units.mkdir()
        project = Path(__file__).resolve().parents[1]
        compiled = subprocess.run(
            ["fpc", "-Fu" + str(project / "src"), "-FU" + str(units),
             "-FE" + str(self.root), source],
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
        documents = [
            '{"zstd_base64":"QUJDRA==","deck":"main","size":4}',
            '{"deck":"main","zstd_base64":"","size":0}',
            '{"deck":"main","zstd_base64":"text with spaces / and punctuation!","size":4}',
            '{"extension":{"zstd_base64":"nested"},"zstd_base64":"QUJDRA=="}',
            '{"extension":["quoted \\"zstd_base64\\" braces {}"],"zstd_base64":"QUJDRA=="}',
            '{"extension":"zstd_base64","zstd_base64":"QUJDRA=="}',
            '{"zstd_base64":"QUJDRA==","extension":{"zstd_base64":"nested"}}',
            '{"extension":"escaped \\\\ slash","zstd_base64":"QUJDRA=="}',
            '{"zstd_base64":"QUJDRA==","extension":"retained ☃"}',
            '{"zstd_base64":42}',
            '{"zstd_base64":null}',
            '{"size":4}',
            '{"zstd_base64":"QUJDRA==","broken":}',
            '{"zstd_base64":"QUJDRA=="} trailing',
            '{"zstd_base64":"QUJDRA==","zstd_base64":"QUJD"}',
            '{"zstd_\\u0062ase64":"QUJDRA==","zstd_base64":"QUJD"}',
            '{"zstd_\\u0062ase64":"QUJDRA=="}',
            '{"zstd_base64":"\\u0051UJDRA=="}',
            '{"zstd_base64":"a\\/b="}',
            '{"zstd_base64":"unterminated}',
            '{"zstd_base64":"unescaped\nnewline"}',
            '{"zstd_base64":"invalid\\qescape"}',
            '{"zstd_base64":"unescaped\x01control"}',
            '["zstd_base64", "QUJDRA=="]',
            '{}',
        ]
        files = []
        for index, document in enumerate(documents):
            path = self.root / f"payload-{index}.json"
            path.write_text(document)
            files.append(path)
        result = subprocess.run([self.root / "revision_json_probe", *files],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "matched")

    def test_revision_payload_spellings_preserve_audit_digests_and_extraction(self):
        data = bytes(range(256)) * 100
        self.store("main", data)
        verification = self.run_scu("verify_audit_trail")
        with closing(sqlite3.connect(self.library, isolation_level=None)) as database:
            payload, = database.execute("SELECT payload FROM deck_revisions").fetchone()
            document = json.loads(payload)
            encoded = document["zstd_base64"]
            plain = json.dumps(document)
            variants = [
                plain,
                json.dumps(document, indent=2),
                plain.replace('"zstd_base64"', '"zstd_\\u0062ase64"'),
                plain.replace('"' + encoded + '"', '"\\u%04x%s"' % (ord(encoded[0]), encoded[1:])),
                plain.replace('"' + encoded + '"', '"' + encoded.replace("/", "\\/") + '"'),
            ]
            for index, variant in enumerate(variants):
                with self.subTest(variant=index):
                    database.execute("UPDATE deck_revisions SET payload = ?", (variant,))
                    self.assertEqual(self.run_scu("verify_audit_trail"), verification)
                    self.run_scu("extd", "main", "extracted")
                    self.assertEqual((self.root / "extracted").read_bytes(), data)
                    stored, = database.execute("SELECT payload FROM deck_revisions").fetchone()
                    self.assertEqual(stored, variant)
                    # Extraction adds audit records. Use the resulting head as
                    # the baseline for the next equivalent JSON spelling.
                    verification = self.run_scu("verify_audit_trail")

    def test_library_audit_keeps_legacy_json_field_order_and_unknown_fields(self):
        self.store("main", b"first\n")
        document = self.read_library()
        header = document["header"]
        for name in ("build_command", "version_increment", "revision_increment", "last_modified_deck"):
            del header[name]
        header["extension"] = {"z": 1, "a": "retained"}
        header["versions"][0]["extension"] = ["retained"]
        revision = document["revisions"][0]
        for name in ("comment_prefix", "deck_revision", "copy_metadata"):
            revision.pop(name, None)
        document["revisions"][0] = {"extension": {"z": 2, "a": "retained"}, **revision}
        recovery = self.root / "legacy-recovery.json"
        recovery.write_text(json.dumps(document))
        restored = self.root / "restored.sqlite"
        self.run_scu(restored, "recover_library", recovery)
        verification = self.run_scu(restored, "verify_audit_trail")
        head = verification.split("head=")[1]
        contents = json.loads(self.audit_lines(restored)[-1].split(b" ", 1)[1])["saved_contents"]

        with closing(sqlite3.connect(restored, isolation_level=None)) as database:
            stored_metadata, = database.execute("SELECT payload FROM library").fetchone()
            stored_revision, = database.execute("SELECT payload FROM deck_revisions").fetchone()
            metadata = json.loads(stored_metadata)
            self.assertEqual(list(metadata["header"]), list(header) + [
                "build_command", "version_increment", "revision_increment", "last_modified_deck",
            ])
            self.assertEqual(list(json.loads(stored_revision)), list(document["revisions"][0]))
            self.assertEqual(contents["revision_sha256"], [hashlib.sha256(stored_revision.encode()).hexdigest()])
            header_start = re.search(r'"header"\s*:\s*', stored_metadata).end()
            _, header_length = json.JSONDecoder().raw_decode(stored_metadata[header_start:])
            serialized_header = stored_metadata[header_start:header_start + header_length]
            self.assertEqual(contents["header_sha256"], hashlib.sha256(serialized_header.encode()).hexdigest())

            database.execute("UPDATE library SET payload = ?", (json.dumps(metadata, indent=2),))
            database.execute("UPDATE deck_revisions SET payload = ?",
                             (json.dumps(json.loads(stored_revision), indent=2),))
            self.assertEqual(self.run_scu(restored, "verify_audit_trail", f"head={head}"), verification)
            self.run_scu(restored, "lock_version", "Test version")
            self.run_scu(restored, "create_version")
            self.run_scu(restored, "verify_audit_trail", f"head={head}")
            payload, = database.execute("SELECT payload FROM library").fetchone()
            self.assertEqual(json.loads(payload)["header"]["extension"], header["extension"])
            self.assertEqual(json.loads(payload)["header"]["versions"][0]["extension"], ["retained"])
            database.execute("UPDATE deck_revisions SET payload = ?",
                             (json.dumps(json.loads(stored_revision), sort_keys=True),))
            self.run_scu(restored, "verify_audit_trail", error="Library revision 1 does not match the audit log")

    def test_json_diagnostics_identify_the_option_file_and_revision(self):
        original = self.read_library()["header"]
        self.run_scu("configure_library", "editor=notjson", error="Invalid JSON for --editor:")
        failure = json.loads(self.audit_lines()[-1].split(b" ", 1)[1])
        self.assertFalse(failure["success"])
        self.assertIn("Invalid JSON for --editor:", failure["detail"])
        self.assertEqual(self.read_library()["header"], original)

        recovery = self.root / "malformed recovery.json"
        recovery.write_text("{ invalid")
        restored = self.root / "restored.sqlite"
        self.run_scu(restored, "recover_library", recovery, error=f'Recovery file "{recovery}":')
        self.assertFalse(restored.exists())

        self.store("main", b"source")
        with closing(sqlite3.connect(self.library, isolation_level=None)) as database:
            database.execute("UPDATE deck_revisions SET payload = '{ invalid' WHERE sequence = 1")
        self.run_scu("extract_deck", "main", "output",
                     error=f'SQLite revision 1 payload in "{self.library}":')
        self.assertFalse((self.root / "output").exists())

    def test_filesystem_and_sqlite_diagnostics_identify_the_affected_path(self):
        invalid = self.root / "invalid database.sqlite"
        invalid.write_bytes(b"This is not a SQLite database." * 100)
        self.run_scu(invalid, "verify_audit_trail", error=f'in "{invalid}": file is not a database')

        lock = self.library.with_name("." + self.library.name + ".lock")
        lock.unlink()
        lock.symlink_to(invalid)
        before = self.audit_lines()
        self.run_scu("lock_version", "Test version", error=f'Could not open lock file "{lock}":')
        self.assertEqual(self.audit_lines(), before)
        self.assertTrue(lock.is_symlink())

    def test_conversion_diagnostic_identifies_the_deck_and_field(self):
        self.store("main", b"source")
        with closing(sqlite3.connect(self.library, isolation_level=None)) as database:
            database.execute("UPDATE deck_revisions SET payload = json_set(payload, '$.size', 1.5) WHERE sequence = 1")
        self.run_scu("extract_deck", "main", "output",
                     error='Deck "main" revision payload: Expected an integer in JSON field "size".')
        self.assertFalse((self.root / "output").exists())

    def test_interactive_audit_detects_changes_from_other_processes(self):
        for mode in ("delete", "wal"):
            library = self.root / f"shared-{mode}.sqlite"
            self.run_scu(library, "inil")
            with self.subTest(mode=mode), closing(sqlite3.connect(library, isolation_level=None)) as db:
                self.assertEqual(db.execute(f"PRAGMA journal_mode={mode}").fetchone(), (mode,))
                with self.terminal_session(library, TERM="dumb") as (process, terminal, read_until):
                    read_until(b"scu> ")
                    # An independent SCU writer extends the chain between commands.
                    self.table_data(self.run_scu(library, "display_version_history"))
                    head = self.run_scu(library, "verify_audit_trail").split("head=")[1]
                    os.write(terminal, b"display_version_history\n")
                    self.assertRegex(read_until(b"scu> "), rb"1.0 +open")
                    self.assertIn("records=8 interrupted=0", self.run_scu(library, "verify_audit_trail", "head=" + head))

                    # Change an older record without changing the chain's tail.
                    original, = db.execute("SELECT line FROM audit_records WHERE sequence = 1").fetchone()
                    db.execute("UPDATE audit_records SET line = ? WHERE sequence = 1",
                               (original.replace('"phase"', '"phaze"', 1),))
                    os.write(terminal, b"display_version_history\n")
                    self.assertIn(b"Audit digest mismatch at record 1", read_until(b"scu> "))
                    self.run_scu(library, "verify_audit_trail", error="Audit digest mismatch at record 1")

                    db.execute("UPDATE audit_records SET line = ? WHERE sequence = 1", (original,))
                    os.write(terminal, b"display_version_history\n")
                    self.assertRegex(read_until(b"scu> "), rb"1.0 +open")
                    self.assertIn("records=10 interrupted=0", self.run_scu(library, "verify_audit_trail", "head=" + head))
                    os.write(terminal, b'quis\n')
                    self.assertEqual(process.wait(timeout=5), 1)

    def test_review_source_size_limit(self):
        source = self.root / "oversized"
        with source.open("wb") as stream:
            stream.truncate(64 * 1024 * 1024 + 1)
        self.run_scu("import_deck", "large", source.name, error="File exceeds the 67108864-byte limit")

    def test_review_closed_pipe_still_records_the_command_outcome(self):
        self.store("main", b"original\n" * 3000)
        self.store("main", b"replacement\n" * 3000)
        with subprocess.Popen([SCU, "disdd", "main"], cwd=self.root, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE) as process:
            process.stdout.close()
            self.assertEqual(process.wait(timeout=20), 1)
            self.assertIn(b"Broken pipe", process.stderr.read())
        self.assertIn("interrupted=0", self.run_scu("verify_audit_trail"))


    def sqlite_build_times(self, path):
        with closing(sqlite3.connect(path)) as database:
            rows = database.execute("SELECT line FROM audit_records ORDER BY sequence")
            events = (json.loads(row[0][65:]) for row in rows)
            return [event["utc"] for event in events if event["phase"] == "build" and event["success"]]


    def test_sqlite_journal_recovers_interactive_commands_killed_at_commit(self):
        compiler = shutil.which("cc")
        if compiler is None:
            self.skipTest("A C compiler is required to inject a crash at commit.")
        source = self.root / "crash_at_commit.c"
        source.write_text(r"""
#define _GNU_SOURCE
#include <dlfcn.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
typedef int (*exec_fn)(void *, const char *, void *, void *, char **);
int sqlite3_exec(void *db, const char *sql, void *callback, void *arg, char **error) {
    static exec_fn real_exec;
    if (!real_exec) real_exec = (exec_fn)dlsym(RTLD_NEXT, "sqlite3_exec");
    int commit = strcmp(sql, "COMMIT") == 0;
    if (commit && strcmp(getenv("SCU_CRASH_STAGE"), "before") == 0) {
        int (*flush)(void *) = dlsym(RTLD_NEXT, "sqlite3_db_cacheflush");
        if (!flush || flush(db) != 0) _exit(90);
        kill(getpid(), SIGKILL);
    }
    int result = real_exec(db, sql, callback, arg, error);
    if (commit && result == 0) kill(getpid(), SIGKILL);
    return result;
}
""")
        shim = self.root / "crash_at_commit.so"
        subprocess.run([compiler, "-shared", "-fPIC", "-o", shim, source, "-ldl"],
                       check=True, capture_output=True, timeout=20)
        for stage in ("before", "after"):
            with self.subTest(stage=stage):
                path = self.root / (stage + ".sqlite")
                self.run_scu(path, "inil")
                self.run_scu(path, "cred", "existing")
                with closing(sqlite3.connect(path)) as database:
                    before = self.sqlite_state(database)
                    self.assertEqual(database.execute("PRAGMA journal_mode").fetchone(), ("delete",))
                result = subprocess.run([SCU, path], cwd=self.root, input="cred staged\ncred never\n",
                                        capture_output=True, text=True, timeout=10,
                                        env=dict(os.environ, LD_PRELOAD=str(shim), SCU_CRASH_STAGE=stage))
                self.assertEqual(result.returncode, -signal.SIGKILL, result.stderr)
                if stage == "before":
                    journal = Path(str(path) + "-journal")
                    self.assertTrue(journal.exists())
                    self.assertGreater(journal.stat().st_size, 512)
                # Logical readers must recover before a writable command opens the library.
                self.run_scu(path, "verify_audit_trail")
                self.run_scu(path, "display_audit_trail", "1")
                listing = self.table_data(self.run_scu(path, "disdl"))
                self.assertIn("existing\t", listing)
                self.assertEqual("staged\t" in listing, stage == "after")
                with closing(sqlite3.connect(path)) as database:
                    state = self.sqlite_state(database)
                    self.assertEqual(database.execute("PRAGMA integrity_check").fetchone(), ("ok",))
                    if stage == "before":
                        self.assertEqual(state[:2], before[:2])
                        self.assertEqual(state[2][:-2], before[2])
                    else:
                        self.assertEqual([row[1] for row in state[1]], ["existing", "staged"])
                        self.assertEqual(len(state[2]), len(before[2]) + 4)
                self.assertIn("interrupted=0", self.run_scu(path, "verify_audit_trail"))
                self.assertFalse(list(self.root.glob("*.recovery-*.json")))

    def test_sqlite_interactive_audit_failure_rolls_back_entire_command(self):
        with closing(sqlite3.connect(self.library, isolation_level=None)) as database:
            with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
                read_until(b"scu> ")
                before = self.sqlite_state(database)
                head = self.run_scu("verify_audit_trail")
                state = database.execute("SELECT * FROM audit_state").fetchall()
                self.reject_sqlite_audit_outcome(database)
                os.write(terminal, b"cred staged\n")
                self.assertIn(b"injected audit write failure", read_until(b"scu> "))
                self.assertEqual(self.sqlite_state(database), before)
                self.assertEqual(database.execute("SELECT * FROM audit_state").fetchall(), state)
                self.assertEqual(self.run_scu("verify_audit_trail"), head)
                database.execute("DROP TRIGGER reject_audit_outcome")
                os.write(terminal, b"disdl\n")
                self.assertNotIn(b"staged ", read_until(b"scu> "))
                os.write(terminal, b"cred staged\n")
                self.assertIn(b"staged version", read_until(b"scu> "))
                self.assertEqual([r[1] for r in self.sqlite_state(database)[1]], ["staged"])
                os.write(terminal, b"quis\n")
                self.assertEqual(process.wait(timeout=5), 1)
        self.assertIn("interrupted=0", self.run_scu("verify_audit_trail"))

    def test_parallel_expansions_wait_for_the_same_output_directory(self):
        self.store("main", b"source\n")
        output = self.root / "expanded"
        output.mkdir()
        ready = self.root / "build-ready"
        release = self.root / "release-build"
        self.run_scu("configure_library",
                     "build_command=touch build-ready; while [ ! -e release-build ]; do sleep 0.02; done")
        with subprocess.Popen([SCU, "extract_deck", "main", output / "first"], cwd=self.root,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as first:
            try:
                deadline = time.monotonic() + 5
                while not ready.exists():
                    self.assertIsNone(first.poll(), "First expansion exited before starting the build")
                    self.assertLess(time.monotonic(), deadline, "First expansion did not start its build")
                    time.sleep(0.01)
                with subprocess.Popen([SCU, "extract_deck", "main", output / "second", "build=no"],
                                      cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as second:
                    try:
                        descriptors = Path(f"/proc/{second.pid}/fd")
                        deadline = time.monotonic() + 5
                        while second.poll() is None:
                            with suppress(FileNotFoundError, PermissionError):
                                if any(fd.resolve() == output for fd in descriptors.iterdir()):
                                    break
                            self.assertLess(time.monotonic(), deadline,
                                            "Second expansion did not open the output directory")
                            time.sleep(0.01)
                        if second.poll() is not None:
                            self.fail(second.communicate()[1].decode())
                        self.assertFalse((output / "second").exists())
                        release.touch()
                        _, error = second.communicate(timeout=5)
                        self.assertEqual(second.returncode, 0, error)
                    finally:
                        if second.poll() is None:
                            second.kill()
            finally:
                release.touch()
                try:
                    _, error = first.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    first.kill()
                    raise
            self.assertEqual(first.returncode, 0, error)
        self.assertEqual((output / "first").read_bytes(), b"source\n")
        self.assertEqual((output / "second").read_bytes(), b"source\n")
        self.assertIn("interrupted=0", self.run_scu("verify_audit_trail"))

    def test_single_and_bulk_builds_can_extract_another_deck_into_the_same_directory(self):
        self.store("main", b"main source\n")
        self.store("helper", b"helper source\n")
        self.run_scu("configure_library",
                     'build_command=if [ -d "$1" ]; then directory=$1; else directory=$(dirname "$1"); fi; '
                     f'{shlex.quote(str(SCU))} extract_deck helper "$directory/generated" build=no')
        for name, command in (("single", ("extract_deck", "main")),
                              ("bulk", ("extract_version", "1.0"))):
            with self.subTest(name=name):
                directory = self.root / name
                directory.mkdir()
                self.run_scu(*command, directory / "main" if name == "single" else directory)
                self.assertEqual((directory / "main").read_bytes(), b"main source\n")
                self.assertEqual((directory / "generated").read_bytes(), b"helper source\n")
                if name == "bulk":
                    self.assertIn("Wrote 0 deck(s) for version 1.0, 2 unchanged", self.run_scu(*command, directory))
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        self.assertEqual([event["success"] for event in events if event["phase"] == "build"], [True, True, True])
        self.assertIn("interrupted=0", self.run_scu("verify_audit_trail"))


    def test_version_diff_skips_legacy_headers(self):
        self.store("utils.h", b"// SCU REVISION 8.1296\r\nint f();\n")
        self.store("script", b"before\n# SCU REVISION old\n", "cp=#")
        self.run_scu("locv", "Before")
        self.run_scu("crev", "1.1")
        self.store("utils.h", b"// SCU REVISION 8.1306\r\nint f();\n")
        self.store("script", b"after\n # SCU REVISION indented\n# SCU REVISION new")
        for fmt in ["normal", "unified"]:
            diff = self.run_scu("disvd", "of=" + fmt)
            self.assertNotIn("utils.h", diff)
            self.assertNotIn("# SCU REVISION new", diff)
            self.assertNotIn("-# SCU REVISION old", diff)
            self.assertIn(" # SCU REVISION indented", diff)
            self.assertIn("after", diff)
            self.assertIn("// SCU REVISION 8.1306", self.run_scu("disvd", "of=" + fmt, "ilsh=n"))

        self.store("utils.h", b"// SCU REVISION 8.1306\r\nint g();\n")
        self.assertIn("2c2\n< int f();", self.run_scu("disvd"))
        self.assertIn(" // SCU REVISION 8.1296\n-int f();", self.run_scu("disvd", "of=unified"))

    def test_version_diff_defaults_and_named_versions_include_changed_and_added_decks(self):
        self.store("main", b"before\n")
        self.store("inherited", b"unchanged\n")
        self.store("reverted", b"original\n")
        self.run_scu("locv", "First release")
        self.run_scu("create_version", "1.1")
        self.store("main", b"after\n")
        self.store("added", b"new deck\n")
        self.run_scu("cred", "empty")
        self.store("reverted", b"temporary edit\n")
        self.store("reverted", b"original\n")
        result = subprocess.run([SCU, "display_version_diff", "output_format=unified"], cwd=self.root,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertRegex(self.run_scu("disvd"), r"empty +Added +0 +0 +0")
        self.assertNotIn("Diff summary", result.stdout)
        self.assertIn("--- a/main\t1.0-0.000\n+++ b/main\t1.1-0.000\n", result.stdout)
        self.assertIn("-before\n+after\n", result.stdout)
        self.assertIn("--- /dev/null\n+++ b/added\t1.1-0.000\n@@ -0,0 +1 @@\n+new deck\n", result.stdout)
        self.assertIn("Only in version 1.1: empty (empty deck)\n", result.stdout)
        self.assertNotIn("inherited", result.stdout)
        self.assertNotIn("reverted", result.stdout)
        expected = result.stdout.strip()
        self.assertEqual(self.run_scu("disvd", "fv=1.0", "tv=1.1", "output_format=unified"), expected)
        self.assertEqual(self.run_scu("disvd", "scu$previous_version", "scu$current_version", "output_format=unified"), expected)
        before, after = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()[-2:]]
        self.assertEqual(before["command"], "display_version_diff")
        self.assertEqual(after["from_snapshot"], {"version": "1.0", "library_revision": 3})
        self.assertEqual(after["to_snapshot"], {"version": "1.1", "library_revision": 8})
        reverse = self.run_scu("disvd", "1.1", "1.0", "output_format=unified")
        self.assertIn("--- a/added\t1.1-0.000\n+++ /dev/null\n", reverse)
        self.assertIn("-new deck", reverse)
        self.assertIn("Only in version 1.1: empty (empty deck)", reverse)
        self.assertEqual(self.run_scu("disvd", "1.1", "1.1", "output_format=unified"), "")
        self.assertIn("interrupted=0", self.run_scu("verify_audit_trail"))

    def test_version_diff_resolves_inherited_decks_and_interactive_edits(self):
        self.store("main", b"first\n")
        self.run_scu("locv", "First release")
        self.run_scu("create_version", "1.1")
        self.store("unrelated", b"unchanged\n")
        self.run_scu("locv", "Second release")
        self.run_scu("create_version", "1.2")
        (self.root / "pending").write_bytes(b"pending change\n")
        result = subprocess.run([SCU], cwd=self.root, capture_output=True, text=True,
                                input="import_deck main pending\ndisvd of=unified\nquis\n", timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("from_version=", result.stderr)
        self.assertNotIn("to_version=", result.stderr)
        self.assertIn("--- a/main\t1.0-0.000\n+++ b/pending\t1.2-0.000\n", result.stdout)
        self.assertIn("-first\n+pending change", result.stdout)
        self.assertNotIn("unrelated@", result.stdout)
        self.run_scu("extd", "main", "original")
        self.assertEqual((self.root / "original").read_bytes(), b"pending change\n")

    def test_version_diff_missing_previous_and_unknown_version_fail_without_prompting(self):
        self.run_scu("disvd", error="No locked version precedes current version 1.0")
        self.run_scu("disvd", "1.0", "9.9", error='Version "9.9" does not exist')
        self.assertTrue(self.run_scu("disvd", "1.0").endswith("No decks differ."))
        self.assertIn("interrupted=0", self.run_scu("verify_audit_trail"))

    def test_deck_diff_uses_current_names_and_rejects_retired_aliases(self):
        self.store("main", b"first\n")
        self.store("main", b"second\n")
        expected = self.run_scu("display_deck_diff", "main")
        self.assertEqual(self.run_scu("disdd", "main"), expected)
        attempt = json.loads(self.audit_lines()[-2].split(b" ", 1)[1])
        self.assertEqual(attempt["command"], "display_deck_diff")
        self.assertIn("display_deck_diff, disdd", self.run_scu("display_command", "disdd"))
        before = self.audit_lines()
        for command in ("display_diff", "diff_deck", "difd"):
            with self.subTest(command=command):
                self.run_scu(command, error=f'Unknown command "{command}"')
                self.run_scu("display_command", command, error=f'Unknown command "{command}"')
        self.assertEqual(self.audit_lines(), before)

    def test_version_diff_completion_suggests_library_selectors(self):
        self.run_scu("locv", "First")
        self.run_scu("create_version", "1.1")
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"disvd fv=scu$\t\t")
            response = read_until(b"scu$previous_version")
            self.assertIn(b"scu$current_version", response)
            # Consume the complete draft redraw, even when writes split across reads.
            while response.rfind(b"disvd fv=scu$") < response.rfind(b"scu$previous_version"):
                self.assertTrue(select.select([terminal], [], [], 5)[0], response)
                response += os.read(terminal, 4096)
            os.write(terminal, b"\x15disvd fv=1.0 tv=scu$cur\t\n")
            self.assertIn(b"To version 1.1", read_until(b"scu> "))
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=8), 0)


    def test_whitespace_diff_keeps_original_changed_lines_and_context(self):
        old = b"prefix  context\nvalue  =  1;  \ntrailing context\n"
        new = b"prefix\tcontext\nvalue\t= 2;\t\ntrailing\tcontext \n"
        self.store("main", old)
        self.store("main", new)
        result = subprocess.run([SCU, "disdd", "main", "output_format=unified"], cwd=self.root,
                                capture_output=True, timeout=20,
                                env=dict(os.environ, PATH="", TMPDIR=str(self.root / "unavailable")))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout,
                         b"--- main@1.0-0.000\n+++ main@1.0-0.001\n@@ -1,3 +1,3 @@\n"
                         b" prefix  context\n-value  =  1;  \n+value\t= 2;\t\n trailing context\n")

    def test_version_and_interactive_diffs_share_whitespace_defaults_and_exact_option(self):
        self.store("main", b"a  b  \n")
        self.run_scu("locv", "d=First")
        self.run_scu("crev", "1.1")
        self.store("main", b"a\tb\n")
        self.assertTrue(self.run_scu("disvd").endswith("No decks differ."))
        self.assertIn("< a  b  \n---\n> a\tb", self.run_scu("disvd", "ignore_space_changes=no"))
        result = subprocess.run([SCU], cwd=self.root, capture_output=True, text=True, timeout=20,
                                input="disdd main\ndisdd main isc=n\nquis\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("1c1\n"), 1)
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        diffs = [event for event in events if event.get("command") == "display_deck_diff"]
        self.assertEqual([event["parameters"]["ignore_space_changes"] for event in diffs], ["yes", "no"])
        self.assertIn("ignore_space_changes (isc) : enum [yes (y), no (n)] = yes", self.run_scu("display_command", "disdd"))
        self.run_scu("disdd", "main", "isc=maybe", error="Expected one of [yes (y), no (n)]")
        self.run_scu("verify_audit_trail")

    def test_whitespace_matching_is_used_in_diff_search_fallback(self):
        self.store("main", b"  same\t\tend  \n" + b"old\n" * 1600 + b"tail  words   \n")
        self.store("main", b"\tsame end\n" + b"new\n" * 1600 + b"tail\twords\n")
        result = subprocess.run([SCU, "disdd", "main", "output_format=unified"], cwd=self.root, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout,
                         b"--- main@1.0-0.000\n+++ main@1.0-0.001\n@@ -1,1602 +1,1602 @@\n"
                         b"   same\t\tend  \n" + b"-old\n" * 1600 + b"+new\n" * 1600 + b" tail  words   \n")


    def test_diff_output_format_aliases_defaults_prompts_and_validation(self):
        self.store("main", b"old\ncontext\n")
        self.store("main", b"new\ncontext\n")
        expected = "1c1\n< old\n---\n> new"
        self.assertEqual(self.run_scu("disdd", "main", "of=NORMAL"), expected)
        self.assertIn("@@ -1,2 +1,2 @@", self.run_scu("disdd", "main", "of=UNIFIED"))
        with self.terminal_session(TERM="dumb") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"disdd main\n")
            result = read_until(b"scu> ")
            self.assertIn(b"1c1\r\n< old\r\n---\r\n> new", result)
            self.assertNotIn(b" context", result)
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)
        self.run_scu("disdd", "main", "of=invalid", error="Expected one of [normal, unified] for output_format")
        self.run_scu("disvd", "of=invalid", error="Expected one of [normal, unified] for output_format")
        help_text = self.run_scu("display_command", "disdd")
        self.assertIn("output_format (of) : enum [normal, unified] = normal", help_text)
        self.assertIn("normal shows changed lines only", help_text)

    def test_normal_diff_search_fallback_emits_ranges_without_shared_lines(self):
        self.store("main", b"prefix\n" + b"old\n" * 1600 + b"suffix\n")
        self.store("main", b"prefix\n" + b"new\n" * 1600 + b"suffix\n")
        result = subprocess.run([SCU, "disdd", "main"], cwd=self.root, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"2,1601c2,1601\n" + b"< old\n" * 1600 + b"---\n" + b"> new\n" * 1600)


    def test_review_diff_preserves_scattered_hunks(self):
        lines = [f"line {index:05}\n".encode() for index in range(6500)]
        changed = lines.copy()
        for index in range(10, 6000, 10):
            changed[index] = f"changed {index:05}\n".encode()
        self.store("main", b"".join(lines))
        self.store("main", b"".join(changed))
        patch = self.run_scu("display_deck_diff", "main", "output_format=unified")
        self.assertEqual(sum(line.startswith("@@ ") for line in patch.splitlines()), 599)

    def test_diff_search_limit_fallback_emits_a_complete_unified_patch(self):
        old = "old\n" * 800 + "matching middle\n" + "old\n" * 800
        new = "new\n" * 800 + "matching middle\n" + "new\n" * 800
        self.store("main", ("prefix\n" + old + "suffix\n").encode())
        self.store("main", ("prefix\n" + new + "suffix\n").encode())
        patch = self.run_scu("disdd", "main", "output_format=unified").splitlines()
        self.assertEqual(patch[:4], ["--- main@1.0-0.000", "+++ main@1.0-0.001",
                                    "@@ -1,1603 +1,1603 @@", " prefix"])
        self.assertEqual(len(patch), 3207)
        self.assertEqual(patch[4:-1],
                         ["-" + line for line in old.splitlines()] +
                         ["+" + line for line in new.splitlines()])
        self.assertEqual(patch[-1], " suffix")

    def test_diff_search_edit_limit_boundary(self):
        shared = [f"unchanged {index}\n" for index in range(10)]
        for count, hunks in ((1536, 2), (1537, 1)):
            deck = f"limit-{count}"
            left = count // 2
            for line in ("old\n", "new\n"):
                self.store(deck, (line * left + "".join(shared) + line * (count - left)).encode())
            patch = self.run_scu("disdd", deck, "output_format=unified")
            self.assertEqual(sum(line.startswith("@@ ") for line in patch.splitlines()), hunks)

    def test_diff_merges_hunks_across_at_most_six_context_lines(self):
        lines = [f"line {index}\n".encode() for index in range(20)]
        for gap, expected in ((6, 1), (7, 2)):
            with self.subTest(gap=gap):
                deck = f"gap-{gap}"
                updated = lines.copy()
                updated[4] = b"first edit\n"
                updated[5 + gap] = b"second edit\n"
                self.store(deck, b"".join(lines))
                self.store(deck, b"".join(updated))
                patch = self.run_scu("display_deck_diff", deck, "output_format=unified")
                self.assertEqual(sum(line.startswith("@@ ") for line in patch.splitlines()), expected)

    def test_typed_definitions_and_aliases_are_loaded_per_command(self):
        (self.root / "source with spaces").write_text("stored text")
        subprocess.run(
            ["sh", "-c", '"$1" import_deck dn=1.25 source_file="source with spaces"', "sh", SCU],
            cwd=self.root, check=True, capture_output=True, timeout=20,
        )
        self.run_scu("extd", "dn=1.25", "output_file=output with spaces", "--r", "0.000")
        self.assertEqual((self.root / "output with spaces").read_text(), "stored text")
        self.run_scu("disvh", "l=1.25", error="Expected integer value for limit")
        self.run_scu("disvh", "l=0x1", error="Expected integer value for limit")
        self.run_scu("disvh", "l=9223372036854775808", error="Expected integer value for limit")

        executable = self.root / "scu"
        shutil.copy2(SCU, executable)
        definitions = json.loads(SCU.with_name("commands.json").read_bytes())
        display = next(command for command in definitions["commands"]
                       if command["name"] == "display_deck")
        display["aliases"].append("show_deck_history")
        display["arguments"][0].update(type="float", aliases=["number"], value="scu$required")
        definitions["library_argument"]["aliases"] = ["lib"]
        (self.root / "commands.json").write_text(json.dumps(definitions))
        self.assertIn("number", self.run_scu("display_command", "show_deck_history", executable=executable))
        self.assertIn("1.0-0.000 ", self.run_scu("--lib", self.library, "show_deck_history",
                                               "number=1.25", executable=executable))
        self.run_scu("show_deck_history", "number=1,25", error="Expected float", executable=executable)
        self.run_scu("show_deck_history", "number=nan", error="Expected float", executable=executable)
        self.run_scu("show_deck_history", "dn=1.25", error="Unknown argument dn", executable=executable)
        self.assertIn('old-alias".', self.run_scu("extd", "dn=1.25", "of=old-alias", executable=executable))

        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        extracts = [event for event in events if event.get("command") == "extract_deck"]
        self.assertEqual(extracts[-1]["parameters"], {"deck_name": "1.25", "output_file": "old-alias", "version": "scu$current_version", "overwrite": "no", "build": "yes"})
        self.assertEqual(extracts[0]["parameters"], {"deck_name": "1.25", "output_file": "output with spaces", "revision": "0.000", "version": "scu$current_version", "overwrite": "no", "build": "yes"})

    def test_executor_uses_argument_names_when_catalog_order_changes(self):
        self.store("main.pas", b"//SCU$VERSION\n")
        executable = self.root / "scu"
        shutil.copy2(SCU, executable)
        definitions = json.loads(SCU.with_name("commands.json").read_bytes())
        expand = next(command for command in definitions["commands"] if command["name"] == "extract_deck")
        expand["arguments"][:2] = reversed(expand["arguments"][:2])
        (self.root / "commands.json").write_text(json.dumps(definitions))
        directory = self.root / "build output"
        directory.mkdir()
        path = directory / "generated.pas"

        self.run_scu("extract_deck", path, "main.pas", "build=no", executable=executable)
        self.assertEqual(path.read_bytes(), b"//SCU$VERSION\n")
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        attempt = next(event for event in events if event.get("command") == "extract_deck")
        self.assertEqual(attempt["arguments"], [str(path), "main.pas", "scu$current_version", "no", "no"])
        self.assertEqual(attempt["parameters"], {"output_file": str(path), "deck_name": "main.pas", "build": "no", "version": "scu$current_version", "overwrite": "no"})
        self.assertEqual(attempt["provided_arguments"], ["output_file", "deck_name", "build"])

    def test_library_first_and_named_invocation_share_the_same_library(self):
        name = "project library"
        self.run_scu(f"ln={name}", "inil")
        (self.root / "source").write_text("project source")
        self.run_scu(f"ln={name}", "import_deck", "main.pas", "source")
        self.assertEqual(self.table_data(self.run_scu(f"library_name={name}", "disdl")), "main.pas\t1.0-0.000")
        self.assertEqual(self.table_data(self.run_scu("--library_name", name, "disdl")), "main.pas\t1.0-0.000")
        self.assertEqual(self.table_data(self.run_scu("--ln", name, "disdl")), "main.pas\t1.0-0.000")
        self.table_data(self.run_scu("ln=", name, "disdl", error="Expected a library name"))
        self.assertEqual(self.table_data(self.run_scu("disdl")), "")
        self.run_scu("ln=", error="Expected a library name")
        self.run_scu("ln=init", "inil")
        self.assertTrue((self.root / "init.sqlite").is_file())


    def test_command_file_failure_stops_enclosing_files_and_redirected_input(self):
        (self.root / "child.scu").write_text("cred before\ncred\ncred child-after\n")
        (self.root / "parent.scu").write_text("!child.scu\ncred parent-after\n")
        result = subprocess.run([SCU], cwd=self.root, capture_output=True, text=True,
                                input="!parent.scu\ncred stdin-after\n", timeout=20)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(str(self.root / "child.scu") + ":2:", result.stderr)
        self.assertIn("Missing required argument deck_name", result.stderr)
        listing = self.table_data(self.run_scu("disdl"))
        self.assertIn("before\t", listing)
        for name in ("child-after", "parent-after", "stdin-after"):
            self.assertNotIn(name + "\t", listing)
        result = subprocess.run([SCU, "coe=yes"], cwd=self.root, capture_output=True, text=True,
                                input="!parent.scu\ncred stdin-after\n", timeout=20)
        self.assertEqual(result.returncode, 1, result.stderr)
        listing = self.table_data(self.run_scu("disdl"))
        for name in ("child-after", "parent-after", "stdin-after"):
            self.assertIn(name + "\t", listing)

    def test_command_file_quit_exits_session_and_keeps_committed_changes(self):
        (self.root / "quit.scu").write_text(
            "cred discarded\nquis\ncred after-quit\n")
        result = subprocess.run([SCU, "!quit.scu"], cwd=self.root, capture_output=True,
                                text=True, input="cred after-file\n", timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        listing = self.table_data(self.run_scu("disdl"))
        self.assertIn("discarded\t", listing)
        for name in ("after-quit", "after-file"):
            self.assertNotIn(name + "\t", listing)
        (self.root / "empty.scu").write_text("")
        result = subprocess.run([SCU], cwd=self.root, capture_output=True, text=True,
                                input="!empty.scu\ncred after-empty\n", timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("after-empty\t", self.table_data(self.run_scu("disdl")))

    def test_interactive_command_file_can_continue_after_errors_without_prompting(self):
        (self.root / "continue.scu").write_text("cred\ncred continued-file\n")
        with self.terminal_session("coe=yes", TERM="dumb") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"!continue.scu\n")
            output = read_until(b"scu> ")
            self.assertIn(b"Missing required argument deck_name", output)
            self.assertIn(b"continued-file version", output)
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 1)
        self.assertIn("continued-file\t", self.table_data(self.run_scu("disdl")))

    def test_command_file_errors_are_bounded_and_do_not_execute_a_shell(self):
        for line, message in (("!", "Expected one command filename"),
                              ("! one two", "Expected one command filename"),
                              ("!missing", "missing"),
                              ("!touch shell-marker", "Expected one command filename")):
            result = subprocess.run([SCU], cwd=self.root, capture_output=True, text=True,
                                    input=line + "\ncred skipped\n", timeout=20)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn(message, result.stderr)
            self.assertNotIn("skipped\t", self.table_data(self.run_scu("disdl")))
        self.assertFalse((self.root / "shell-marker").exists())
        (self.root / "recursive.scu").write_text("!recursive.scu\n")
        result = subprocess.run([SCU, "!recursive.scu"], cwd=self.root, capture_output=True,
                                text=True, input="", timeout=20)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("cannot be nested more than 16 levels", result.stderr)

    def test_interactive_command_files_never_prompt_and_return_after_failure(self):
        (self.root / "commands with spaces.scu").write_text(
            "cred from-file\ncred\ncred skipped\n")
        with self.terminal_session(TERM="dumb") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b'! "commands with spaces.scu"\n')
            output = read_until(b"scu> ")
            self.assertIn(b"Missing required argument deck_name", output)
            self.assertNotIn(b"deck_name= ", output)
            os.write(terminal, b"cred from-prompt\n")
            read_until(b"scu> ")
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 1)
        listing = self.table_data(self.run_scu("disdl"))
        self.assertIn("from-file\t", listing)
        self.assertIn("from-prompt\t", listing)
        self.assertNotIn("skipped\t", listing)

    def test_interactive_session_uses_quoted_arguments_and_logs_commands(self):
        (self.root / "source with spaces").write_text("interactive source")
        result = subprocess.run(
            [SCU, "ln=interactive library", "continue_on_error=yes"], cwd=self.root, capture_output=True, text=True,
            input=(
                "\ninil\nimport_deck dn=main.pas source_file=\"source with spaces\"\n"
                'extd dn=main.pas output_file="unclosed\n'
                "extd dn=main.pas output_file='working copy.pas'\n"
                "disdl\nquis\nimport_deck ignored 'source with spaces'\n"
            ),
            timeout=20,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Unclosed quote", result.stderr)
        self.assertRegex(result.stdout, r"main.pas +1.0-0.000")
        self.assertNotIn("scu>", result.stdout + result.stderr)
        self.assertEqual((self.root / "working copy.pas").read_text(), "interactive source")
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines(self.root / "interactive library.sqlite")]
        commands = [event["command"] for event in events if event["phase"] == "begin"]
        self.assertEqual(commands, ["initialize_library", "import_deck", "extract_deck", "display_deck_list"])
        extract = next(event for event in events if event.get("command") == "extract_deck")
        self.assertEqual(extract["parameters"],
                         {"deck_name": "main.pas", "output_file": "working copy.pas", "version": "scu$current_version", "overwrite": "no", "build": "yes"})
        self.assertIn("records=8 interrupted=0",
                      self.run_scu("interactive library", "verify_audit_trail"))
        result = subprocess.run(
            [SCU], cwd=self.root, capture_output=True, text=True, input="display_version_history", timeout=20
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r"(?m)^1\.0 +open +None\s*$")

    def test_existing_visible_library_lock_is_respected(self):
        legacy = self.root / "legacy.sqlite.lock"
        legacy.touch()
        self.run_scu("legacy.sqlite", "inil")
        self.assertFalse((self.root / ".legacy.sqlite.lock").exists())
        with legacy.open("rb") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            with subprocess.Popen([SCU, "legacy.sqlite", "disl"], cwd=self.root,
                                  stdout=subprocess.PIPE) as process:
                with self.assertRaises(subprocess.TimeoutExpired):
                    process.wait(timeout=0.2)
                fcntl.flock(handle, fcntl.LOCK_UN)
                self.assertEqual(process.wait(timeout=5), 0)

    def test_interactive_missing_library_points_to_initialization(self):
        empty = self.root / "empty"
        empty.mkdir()
        result = subprocess.run(
            [SCU, "continue_on_error=yes"], cwd=empty, input="disdl\ninil\ndisdl\nquis\n",
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        database = empty / "library.sqlite"
        self.assertIn(f'Library "{database}" does not exist.', result.stderr)
        self.assertIn("Use initialize_library to create it.", result.stderr)
        self.assertNotIn("Could not open audit log", result.stderr)
        self.assertIn("Initialized version 1.0", result.stdout)
        self.assertIn("Using library version 1.0.", result.stderr)
        self.assertFalse((empty / "library.json").exists())
        self.assertFalse((empty / "library.sqlite.audit").exists())
        self.assertEqual((empty / ".library.sqlite.lock").stat().st_size, 0)
        with closing(sqlite3.connect(database)) as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM audit_records").fetchone(), (4,))
        self.assertIn("records=4", self.run_scu(database, "verify_audit_trail"))

    def test_json_files_are_not_opened_as_libraries(self):
        legacy = self.root / "library.json"
        legacy.write_text('{"format":1,"header":{},"revisions":[]}')
        original = legacy.read_bytes()
        self.table_data(self.run_scu(legacy, "disdl", error="Library filename must have the .sqlite extension"))
        self.run_scu(legacy, "inil", error="Library filename must have the .sqlite extension")
        self.assertEqual(legacy.read_bytes(), original)
        self.assertEqual(self.table_data(self.run_scu("disdl")), "")
        self.assertFalse(legacy.with_suffix(".json.audit").exists())

    def test_interactive_commands_save_immediately_and_quit_cannot_discard(self):
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"cred saved\n")
            self.assertIn(b"saved version", read_until(b"scu> "))
            self.assertEqual(self.read_library()["revisions"][0]["deck"], "saved")
            self.assertIn("saved\t", self.table_data(self.run_scu("disdl")))
            os.write(terminal, b"savl\n")
            self.assertIn(b"Library is already saved.", read_until(b"scu> "))
            os.write(terminal, b"quis save_library=no\n")
            self.assertIn(b"Unknown argument save_library for quit_session", read_until(b"scu> "))
            os.write(terminal, b"quis\n")
            self.assertEqual(process.wait(timeout=5), 1)
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        self.assertFalse(any(event.get("pending_save") for event in events))
        self.assertEqual(self.read_library()["revisions"][0]["deck"], "saved")
        self.assertIn("interrupted=0", self.run_scu("verify_audit_trail"))

    def test_interactive_commands_reload_concurrent_committed_changes(self):
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"cred first\n")
            read_until(b"scu> ")
            self.run_scu("cred", "external")
            os.write(terminal, b"cred last\n")
            self.assertIn(b"last version", read_until(b"scu> "))
            os.write(terminal, b"quis\n")
            self.assertEqual(process.wait(timeout=5), 0)
        self.assertEqual([r["deck"] for r in self.read_library()["revisions"]], ["first", "external", "last"])
        self.assertIn("interrupted=0", self.run_scu("verify_audit_trail"))

    def test_command_help_and_required_argument_prompts(self):
        listing = self.run_scu("discl")
        self.assertEqual(listing, self.run_scu("help"))
        self.assertEqual(listing, self.run_scu("discl"))
        self.assertRegex(listing, r"(?m)^extract_deck, extd +Write the original source bytes to a file\.$")
        self.assertNotIn("output_file", listing)
        help_text = self.run_scu("display_command", "command_name=extd")
        self.assertEqual(help_text.splitlines()[0], "extract_deck, extd")
        self.assertIn("deck_name (dn) : string = scu$last_modified_deck", help_text)
        self.assertIn("including COPY directives and macro text", help_text)
        self.assertIn("output_file (of) : string = scu$deck_name\n"
                      "    Destination for original bytes. Defaults to the selected revision's recorded source filename, or the deck name if absent; an explicit output_file is honored.", help_text)
        self.assertIn("revision (r) : string = scu$optional\n"
                      "    Deck revision within the selected library version, from 0.000 to 0.999. Omit to select the latest visible deck revision, including inherited decks.",
                      help_text)
        self.assertIn("version (v) : string = scu$current_version\n"
                      "    Library version containing the deck; defaults to scu$current_version. Combine with revision=0.001, or supply a complete deck version such as 1.1-0.001.", help_text)
        self.run_scu("display_command", error="Missing required argument command_name")
        self.run_scu("display_command", "command_name=", error='Unknown command ""')

        with self.terminal_session(TERM="dumb") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"display_command\n")
            self.assertIn(b"command_name (cn) : string = scu$required", read_until(b"command_name= "))
            os.write(terminal, b"extd\n")
            self.assertIn(help_text.replace("\n", "\r\n").encode(), read_until(b"scu> "))
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)

    def test_command_catalog_is_alphabetically_sorted(self):
        catalog = Path(__file__).resolve().parents[1] / "commands.json"
        definitions = json.loads(catalog.read_bytes())
        commands = definitions["commands"]
        command_names = [command["name"] for command in commands]
        self.assertEqual(command_names, sorted(command_names), "commands by full name")

        for option in ("library_argument", "batch_argument"):
            aliases = definitions[option]["aliases"]
            self.assertEqual(aliases, sorted(aliases), f"{option} aliases")
        for command in commands:
            name = command["name"]
            with self.subTest(command=name):
                self.assertEqual(command["aliases"], sorted(command["aliases"]), "command aliases")
            # Positional arguments are listed in parsing order. Check only their aliases.
            for parameter in command["arguments"]:
                with self.subTest(command=name, parameter=parameter["name"]):
                    aliases = parameter["aliases"]
                    self.assertEqual(aliases, sorted(aliases), "parameter aliases")
                    for value in parameter.get("values", []):
                        if isinstance(value, dict):
                            self.assertEqual(value.get("aliases", []), sorted(value.get("aliases", [])), "enum aliases")

    def test_format_commands_sorts_catalog_without_reordering_positional_arguments(self):
        project = Path(__file__).resolve().parents[1]
        catalog = json.loads((project / "commands.json").read_bytes())
        diff = next(command for command in catalog["commands"] if command["name"] == "display_deck_diff")
        diff["arguments"].reverse()
        # Custom catalogs may define additional aliases; exercise nontrivial
        # sorting independently of the shipped one-abbreviation convention.
        catalog['library_argument']['aliases'] = ['library_name', 'ln']
        expected = json.loads(json.dumps(catalog))

        catalog["library_argument"]["aliases"].reverse()
        catalog["batch_argument"]["aliases"].reverse()
        catalog["commands"].reverse()
        for command in catalog["commands"]:
            command["aliases"].reverse()
            for parameter in command["arguments"]:
                parameter["aliases"].reverse()
                for value in parameter.get("values", []):
                    if isinstance(value, dict):
                        value.get("aliases", []).reverse()

        path = self.root / "commands.json"
        path.write_text(json.dumps(catalog), encoding="utf-8")
        formatter = [sys.executable, str(project / "tools/format_commands.py"), str(path)]
        subprocess.run(formatter, check=True, timeout=20)
        formatted = path.read_bytes()
        self.assertEqual(json.loads(formatted), expected)
        self.assertIn(b'"aliases": ["library_name", "ln"]', formatted)
        subprocess.run(formatter, check=True, timeout=20)
        self.assertEqual(path.read_bytes(), formatted)

    def test_format_commands_accepts_argument_definitions_without_aliases(self):
        path = self.root / "commands.json"
        formatter = Path(__file__).resolve().parents[1] / "tools/format_commands.py"
        arguments = [{"name": "second"}, {"name": "first"}]
        catalog = {"format": 4, "commands": [
            {"name": "z_command", "arguments": arguments},
            {"name": "a_command", "arguments": []},
        ]}
        path.write_text(json.dumps(catalog))
        subprocess.run([sys.executable, formatter, path], check=True, timeout=20)
        first, last = json.loads(path.read_bytes())["commands"]
        self.assertEqual(first["name"], "a_command")
        self.assertEqual(last["arguments"], arguments)

    def test_command_catalog_rejects_legacy_formats_and_unknown_commands(self):
        executable = self.root / "scu"
        shutil.copy2(SCU, executable)
        catalog = self.root / "commands.json"
        for version in (1, 2, 3):
            catalog.write_text(json.dumps({"format": version}))
            self.run_scu("help", executable=executable, error="Expected format 4")
        definitions = json.loads(SCU.with_name("commands.json").read_bytes())
        definitions["commands"][0]["name"] = "unregistered_command"
        catalog.write_text(json.dumps(definitions))
        self.run_scu("help", executable=executable, error='No implementation for command "unregistered_command"')

    def test_command_catalog_rejects_invalid_definitions_at_startup(self):
        executable = self.root / "scu"
        shutil.copy2(SCU, executable)
        original = SCU.with_name("commands.json").read_bytes()
        audit = self.audit_lines()
        for section, name, field, value, message in (
            ("arguments", "revision", "type", "int", 'Unknown argument type "int" for revision'),
            ("arguments", "revision", "completion", "revison", 'Unknown completion kind "revison"'),
            ("arguments", "revision", "aliases", ["DN"], 'Ambiguous name or alias "DN"'),
            ("arguments", "revision", "aliases", [1], 'Expected a nonempty alias string for "revision"'),
            ("command", "", "aliases", ["DISDL"], 'Ambiguous name or alias "DISDL"'),
            ("command", "", "exclusive_arguments", [["version", "missing"]], 'Unknown argument "missing"'),
            ("command", "", "default_values", {"versoin": "1.0"}, 'Unknown parameter "versoin"'),
        ):
            with self.subTest(field=field, value=value):
                catalog = json.loads(original)
                command = next(item for item in catalog["commands"] if item["name"] == "extract_deck")
                target = command if section == "command" else next(
                    item for item in command[section] if item["name"] == name
                )
                target[field] = value
                path = self.root / "commands.json"
                path.write_text(json.dumps(catalog))
                self.run_scu("help", executable=executable,
                             error=f'Could not load command catalog "{path}": {message}')
        self.assertEqual(self.audit_lines(), audit)

    def test_running_session_keeps_its_validated_catalog_for_help_and_completion(self):
        self.store("main", b"source")
        executable = self.root / "scu"
        shutil.copy2(SCU, executable)
        catalog = json.loads(SCU.with_name("commands.json").read_bytes())
        command = next(item for item in catalog["commands"] if item["name"] == "extract_deck")
        command["exclusive_arguments"] = [["v", "r"]]
        path = self.root / "commands.json"
        path.write_text(json.dumps(catalog))
        with self.terminal_session(TERM="xterm", executable=executable) as (process, terminal, read_until):
            read_until(b"scu> ")
            path.write_text("invalid catalog")
            os.write(terminal, b"display_command extd\n")
            self.assertIn(b"v, r", read_until(b"scu> "))

            prefix = b"extd main expanded v=1.0 --"
            os.write(terminal, prefix + b"\t\t")
            matches = read_until(b"scu> " + prefix)
            self.assertIn(b"--build", matches)
            self.assertNotIn(b"--revision", matches)
            os.write(terminal, b"build no\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "expanded").read_bytes(), b"source")
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)

    def test_command_catalog_has_consistent_names_and_resolves_every_alias(self):
        definitions = json.loads(SCU.with_name("commands.json").read_bytes())
        commands = sorted(definitions["commands"], key=lambda command: command["name"])
        labels = [", ".join([command["name"], *command["aliases"]]) for command in commands]
        width = max(map(len, labels))
        self.assertEqual(self.run_scu("display_command_list").splitlines(), [
            f"{label:<{width}}  {command['summary']}"
            for label, command in zip(labels, commands)
        ])
        command_names = set()
        command_verbs = {
            "configure", "create", "delete", "display", "edit", "expand", "extract",
            "initialize", "import", "list", "lock", "quit", "recover", "release", "reset", "save",
            "show", "start", "store", "unlock", "verify",
        }
        for command in commands:
            name = command["name"]
            self.assertRegex(name, r"^[a-z]+(?:_[a-z]+)+$")
            words = name.split("_")
            self.assertIn(words[0], command_verbs, name)
            abbreviation = words[0][:3] + "".join(word[0] for word in words[1:])
            self.assertIn(abbreviation, command["aliases"], name)
            self.assertTrue(command["aliases"])
            help_text = self.run_scu("display_command", f"command_name={name}")
            self.assertEqual(help_text.splitlines()[:2],
                             [", ".join([name, *command["aliases"]]), command["summary"]])
            groups = command.get("exclusive_arguments", [])
            if groups:
                expected = ["Mutually exclusive arguments (choose at most one per group)"]
                expected.extend("  " + ", ".join(group) for group in groups)
                self.assertIn("\n".join(expected), help_text)
            else:
                self.assertNotIn("Mutually exclusive arguments", help_text)
            examples = command.get("examples", [])
            if examples:
                expected = ["Examples"]
                for example in examples:
                    expected.extend(["  " + example["command"], "    " + example["description"]])
                self.assertEqual(help_text.splitlines()[-len(expected):], expected)
            else:
                self.assertNotIn("\nExamples\n", help_text)
            for spelling in [name, *command["aliases"]]:
                self.assertNotIn(spelling.casefold(), command_names)
                command_names.add(spelling.casefold())
                self.assertEqual(self.run_scu("display_command", f"command_name={spelling}"), help_text)
            parameter_names = set()
            for index, parameter in enumerate(command["arguments"]):
                self.assertTrue(parameter["aliases"])
                for spelling in [parameter["name"], *parameter["aliases"]]:
                    self.assertNotIn(spelling.casefold(), parameter_names)
                    parameter_names.add(spelling.casefold())
                prefix = ""
                value = parameter["value"]
                aliases = ", ".join(parameter["aliases"])
                kind = parameter["type"]
                if kind == "enum":
                    choices = []
                    for value_definition in parameter["values"]:
                        if isinstance(value_definition, str):
                            choices.append(value_definition)
                        else:
                            aliases_text = ", ".join(value_definition.get("aliases", []))
                            choices.append(value_definition["name"] + (f" ({aliases_text})" if aliases_text else ""))
                    kind += " [" + ", ".join(choices) + "]"
                signature = f"{prefix}{parameter['name']} ({aliases}) : {kind} = {value}"
                self.assertIn(signature + "\n    " + parameter["description"], help_text)

    def test_optional_default_is_shown_and_applied(self):
        self.store("main.pas", b"source")
        executable = self.root / "scu"
        shutil.copy2(SCU, executable)
        definitions = json.loads(SCU.with_name("commands.json").read_bytes())
        extract = next(command for command in definitions["commands"]
                       if command["name"] == "extract_deck")
        extract["arguments"][1]["value"] = "default output"
        extract["arguments"][1]["prompt_for_default"] = True
        next(p for p in extract["arguments"] if p["name"] == "revision")["value"] = "0.000"
        next(p for p in extract["arguments"] if p["name"] == "revision")["prompt_for_default"] = True
        extract["help_file"] = "extract.txt"
        (self.root / "extract.txt").write_text("Help loaded from a file.")
        (self.root / "commands.json").write_text(json.dumps(definitions))
        help_text = self.run_scu("display_command", "extd", executable=executable)
        self.assertIn("Help loaded from a file.", help_text)
        self.assertIn("output_file (of) : string = default output", help_text)
        self.assertIn("revision (r) : string = 0.000", help_text)
        self.run_scu("extd", "main.pas", executable=executable)
        self.assertEqual((self.root / "default output").read_bytes(), b"source")
        self.run_scu("extd", "main.pas", "output_file=override", executable=executable)
        self.assertEqual((self.root / "override").read_bytes(), b"source")
        (self.root / "default output").unlink()
        self.store("main.pas", b"updated")
        with self.terminal_session(TERM="dumb", executable=executable) as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"extd main.pas\n")
            self.assertIn(b"output_file (of) : string = default output", read_until(b"output_file= "))
            os.write(terminal, b"\n")
            self.assertIn(b"revision (r) : string = 0.000", read_until(b"revision= "))
            os.write(terminal, b"\n")
            read_until(b"scu> ")
            os.write(terminal, b"extd main.pas\n")
            read_until(b"output_file= ")
            os.write(terminal, b"interactive override\n")
            read_until(b"revision= ")
            os.write(terminal, b"0.001\n")
            read_until(b"scu> ")
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)
        self.assertEqual((self.root / "default output").read_bytes(), b"source")
        self.assertEqual((self.root / "interactive override").read_bytes(), b"updated")

    @contextmanager
    def terminal_session(self, *arguments, columns=None, rows=24, executable=SCU,
                         controlling=False, read_timeout=5, **environment):
        master, slave = pty.openpty()
        env = dict(os.environ, XDG_STATE_HOME=str(self.root / "state"))
        env.update(environment)

        def take_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        try:
            if columns is not None:
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
            with subprocess.Popen([executable, *arguments], cwd=self.root, env=env, stdin=slave,
                                  stdout=slave, stderr=slave,
                                  preexec_fn=take_terminal if controlling else None) as process:
                os.close(slave)
                slave = None

                def read_until(needle):
                    output = b""
                    while needle not in output:
                        self.assertTrue(select.select([master], [], [], read_timeout)[0], output)
                        output += os.read(master, 4096)
                    return output

                try:
                    yield process, master, read_until
                finally:
                    if process.poll() is None:
                        process.kill()
        finally:
            if slave is not None:
                os.close(slave)
            os.close(master)

    def test_display_command_list_wraps_at_the_terminal_width(self):
        names = "configure_library, conl"
        description = "Set library configuration, editor, build command, release directory, or file patterns."
        for columns in (72, 36, 12):
            with self.subTest(columns=columns), self.terminal_session(TERM="dumb", columns=columns) as (
                process, terminal, read_until
            ):
                read_until(b"scu> ")
                os.write(terminal, b"discl\n")
                lines = read_until(b"scu> ").decode().splitlines()
                self.assertEqual(lines[0], "discl")
                self.assertEqual(lines[-1], "scu> ")
                listing = lines[1:-1]
                self.assertTrue(all(len(line) <= columns for line in listing), listing)
                if columns == 96:
                    indent = label_width + 2
                    end = next(i for i, line in enumerate(listing) if line.startswith("create_deck,"))
                    first, *continuations = listing[:end]
                    self.assertTrue(continuations)
                    self.assertEqual(first[:indent], names.ljust(indent))
                    self.assertTrue(all(line.startswith(" " * indent) for line in continuations))
                    self.assertEqual(" ".join(line[indent:] for line in listing[:end]), description)
                elif columns == 36:
                    start = next(i for i, line in enumerate(listing) if line.startswith("  "))
                    end = next(i for i, line in enumerate(listing) if line.startswith("create_deck,"))
                    self.assertEqual(" ".join(listing[:start]), names)
                    self.assertTrue(all(line.startswith("  ") for line in listing[start:end]))
                    self.assertEqual(" ".join(line[2:] for line in listing[start:end]), description)
                os.write(terminal, b'quis\n')
                self.assertEqual(process.wait(timeout=5), 0)

    def test_display_command_wraps_help_and_preserves_description_indentation(self):
        executable = self.root / "scu"
        shutil.copy2(SCU, executable)
        definitions = json.loads(SCU.with_name("commands.json").read_bytes())
        extract = next(command for command in definitions["commands"] if command["name"] == "extract_deck")
        extract["help_file"] = "extract.txt"
        (self.root / "commands.json").write_text(json.dumps(definitions))
        paragraph = "The first paragraph explains how to retrieve the original source from the library."
        indented = "This indented paragraph should keep the same margin when the terminal wraps the text."
        file_help = f"{paragraph}\n\n    {indented}"
        (self.root / "extract.txt").write_text(file_help)
        self.assertIn(file_help, self.run_scu("disc", "extd", executable=executable))

        for program in (SCU, executable):
            with self.subTest(program=program), self.terminal_session(
                TERM="dumb", columns=44, executable=program
            ) as (process, terminal, read_until):
                read_until(b"scu> ")
                os.write(terminal, b"disc extd\n")
                lines = read_until(b"scu> ").decode().splitlines()[1:-1]
                end = lines.index("Examples")
                self.assertTrue(all(len(line) <= 44 for line in lines[:end]), lines)
                body = lines[2:lines.index("Arguments")]
                if program == SCU:
                    self.assertGreater(len(body), 1)
                    self.assertEqual(" ".join(body), extract["help"])
                else:
                    separator = body.index("")
                    self.assertEqual(" ".join(body[:separator]), paragraph)
                    self.assertTrue(all(line.startswith("    ") for line in body[separator + 1:]))
                    self.assertEqual(" ".join(line[4:] for line in body[separator + 1:]), indented)
                start = lines.index("  revision (r) : string = scu$optional") + 1
                end = lines.index("  version (v) : string = scu$current_version")
                self.assertGreater(end - start, 1)
                self.assertTrue(all(line.startswith("    ") for line in lines[start:end]))
                self.assertEqual(" ".join(line[4:] for line in lines[start:end]),
                                 next(p for p in extract["arguments"] if p["name"] == "revision")["description"])
                self.assertIn("  " + extract["examples"][0]["command"], lines)
                os.write(terminal, b'quis\n')
                self.assertEqual(process.wait(timeout=5), 0)

    def test_interactive_parameter_prompt_wraps_to_the_terminal_width(self):
        executable = self.root / "scu"
        shutil.copy2(SCU, executable)
        definitions = json.loads(SCU.with_name("commands.json").read_bytes())
        store = next(command for command in definitions["commands"] if command["name"] == "import_deck")
        description = "Use a source file from the working directory to create or revise the deck."
        store["arguments"][1]["description"] = "    " + description
        store["arguments"][1]["value"] = "input.txt"
        store["arguments"][1]["prompt_for_default"] = True
        (self.root / "commands.json").write_text(json.dumps(definitions))
        (self.root / "input.txt").write_bytes(b"prompt source\n")

        with self.terminal_session(TERM="dumb", columns=30, executable=executable) as (
            process, terminal, read_until
        ):
            read_until(b"scu> ")
            os.write(terminal, b"import_deck sample\n")
            lines = read_until(b"source_file= ").decode().splitlines()
            self.assertTrue(all(len(line) <= 30 for line in lines), lines)
            body = [line for line in lines if line.startswith("    ")]
            self.assertGreater(len(body), 1)
            self.assertEqual(" ".join(line[4:] for line in body), description)
            self.assertIn("Press Enter to accept the default.", " ".join(lines))
            self.assertEqual(lines[-1], "source_file= ")
            os.write(terminal, b"\n")
            self.assertRegex(read_until(b"scu> "), rb"sample +1.0-0.000 +new")
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)

        self.run_scu("extd", "sample", "result")
        self.assertEqual((self.root / "result").read_bytes(), b"prompt source\n")

    def test_foreign_library_warnings_use_source_paths_and_volume_rules(self):
        for deck, filename in (("composed", "café.c"), ("decomposed", "cafe\u0301.c"),
                               ("device", "NUL.c"), ("removed", "aux.txt")):
            (self.root / filename).write_text(deck)
            self.run_scu("impd", deck, filename)
        self.run_scu("deld", "removed")
        document = self.read_library()
        for origin, affected in (("Windows", {"device"}), ("macOS", {"composed", "decomposed"})):
            document["header"]["platform"] = origin
            recovery = self.root / "import.json"
            recovery.write_text(json.dumps(document))
            library = self.root / (origin + ".sqlite")
            self.run_scu(library, "recl", recovery)
            output = self.run_scu(library, "disl")
            self.assertEqual(set(re.findall(r'^Warning .*?: deck "([^"]+)"', output, re.M)), affected)
            self.run_scu(library, "verat")

    def test_library_columns_omit_history_and_preserve_header_and_unknown_attributes(self):
        self.run_scu("locv", "description=HISTORY_MARKER\nSecond line")
        self.run_scu("crev", "123456789.1234567890")
        document = self.read_library()
        document["header"]["extra_setting"] = {"enabled": True, "count": 7}
        document["header"]["multiline_setting"] = "line one\nline two\tend"
        recovery = self.root / "recovery.json"
        recovery.write_text(json.dumps(document))
        restored = self.root / "restored.sqlite"
        self.run_scu(restored, "recl", recovery)
        before = json.loads(self.run_scu(restored, "display_library", "json=yes"))
        with closing(sqlite3.connect(restored)) as database:
            payload = database.execute("SELECT payload FROM library").fetchone()
        result = self.run_scu(restored, "disl")
        summary, table = result.split("\n", 1)
        self.assertEqual(summary, f'Library "{restored}".')
        self.assertNotIn("\t", table)
        self.assertNotIn("HISTORY_MARKER", result)
        rows = dict(re.split(r" {2,}", line, maxsplit=1) for line in table.splitlines()[1:])
        self.assertNotIn("versions", rows)
        self.assertEqual(set(rows), (set(before) - {"versions"}) | {"previous_locked_version"})
        self.assertEqual(rows["previous_locked_version"], "1.0")
        self.assertEqual(json.loads(rows["extra_setting"]), {"enabled": True, "count": 7})
        self.assertEqual(rows["multiline_setting"], "line one\\nline two\\tend")
        positions = [line.index(value, len(key) + 2) for key, value in rows.items()
                     for line in table.splitlines()[1:] if line.startswith(key + " ")]
        self.assertEqual(len(set(positions)), 1)
        self.assertEqual(json.loads(self.run_scu(restored, "display_library", "json=yes")), before)
        self.assertIn("HISTORY_MARKER", self.run_scu(restored, "disvh", "dd=full"))
        with closing(sqlite3.connect(restored)) as database:
            self.assertEqual(database.execute("SELECT payload FROM library").fetchone(), payload)
        self.run_scu(restored, "verify_audit_trail")

    def test_library_configuration_columns_wrap_values_and_stack_on_narrow_terminals(self):
        command = "make " + " ".join(f"target-{index}" for index in range(12))
        self.run_scu("conl", "bc=" + command)
        for columns in (48, 24, 1):
            with self.subTest(columns=columns), self.terminal_session(
                    TERM="xterm", columns=columns, rows=30) as (process, terminal, read_until):
                startup = read_until(b"scu> ").decode().replace("\r\n", "\n")
                table = startup.split(f'Library "{self.library}".\n', 1)[1].rsplit("scu> ", 1)[0]
                self.assertNotIn("\t", table)
                self.assertTrue(all(len(line) <= columns for line in table.splitlines()), table)
                if columns == 48:
                    lines = table.splitlines()
                    index = next(i for i, line in enumerate(lines) if line.startswith("build_command "))
                    indent = lines[index].index("make")
                    parts = [lines[index][indent:]]
                    for line in lines[index + 1:]:
                        if not line.startswith(" " * indent):
                            break
                        parts.append(line[indent:])
                    self.assertEqual(" ".join(parts), command)
                    self.assertGreater(len(parts), 1)
                elif columns == 24:
                    self.assertIn("build_command\n  make", table)
                os.write(terminal, b'quis\n')
                self.assertEqual(process.wait(timeout=5), 0)

    def test_terminal_one_shot_lock_uses_configured_editor(self):
        library = self.root / "SCU.sqlite"
        self.run_scu(library, "inil")

        def set_editor(script):
            self.run_scu(library, "conl", "editor=" + json.dumps(["sh", "-c", script, "editor"]))

        def lock(status):
            with self.terminal_session("ln=" + str(library), "locv") as (process, terminal, read_until):
                self.assertEqual(process.wait(timeout=5), status)

        set_editor("exit 0")
        lock(1)
        self.assertFalse(json.loads(self.run_scu(library, "disl", "j=y"))["versions"][0]["locked"])
        set_editor("exit 4")
        lock(1)
        self.run_scu(library, "locv", error="Missing required argument description")
        set_editor("""printf 'First line\\nSecond line\\n' > "$1" """)
        lock(0)
        version = json.loads(self.run_scu(library, "disl", "j=y"))["versions"][0]
        self.assertEqual(version["description"], "First line\nSecond line")
        self.assertTrue(version["locked"])
        self.run_scu(library, "verat")

        self.run_scu(library, "crev", "2.0")
        cli = shlex.join([str(SCU), str(library)])
        set_editor(f'{cli} locv description=Concurrent && {cli} crev 3.0 && echo stale > "$1"')
        lock(1)
        self.assertFalse(json.loads(self.run_scu(library, "disl", "j=y"))["versions"][-1]["locked"])

    def test_version_history_wraps_descriptions_before_locked_timestamps(self):
        descriptions = ["After clang-format", "Without the aspiration window in case of an absolute win or loss " * 3]
        self.run_scu("locv", "description=" + descriptions[0])
        self.run_scu("crev", "1.1")
        self.run_scu("locv", "description=" + descriptions[1])
        self.run_scu("crev", "1.2")
        entries = self.read_library()["header"]["versions"]
        for columns in (96, 80, 48, 32):
            with self.subTest(columns=columns), self.terminal_session(
                    TERM="dumb", columns=columns, rows=200) as (process, terminal, read_until):
                read_until(b"scu> ")
                os.write(terminal, b"disvh limit=5\n")
                body = read_until(b"scu> ").decode().splitlines()[1:-1]
                self.assertTrue(all(len(line) <= columns for line in body), body)
                for entry in entries[:-1]:
                    self.assertTrue(any(self.local_stamp(entry["locked_utc"]) in line for line in body), body)
                if columns >= 80:
                    starts = []
                    for entry in entries[:-1]:
                        row = next(line for line in body if line.startswith(entry["name"] + " "))
                        self.assertIn(self.local_stamp(entry["locked_utc"]), row)
                        starts.append(row.index(self.local_stamp(entry["locked_utc"])))
                    self.assertEqual(len(set(starts)), 1)
                if columns >= 80:
                    indent = body[0].index("Description")
                    first = next(i for i, line in enumerate(body) if line.startswith("1.1 "))
                    last = next(i for i in range(first + 1, len(body)) if body[i].startswith("1.2 "))
                    self.assertGreater(last - first, 1)
                    self.assertTrue(all(line[:indent].isspace() for line in body[first + 1:last]), body)
                    self.assertEqual("".join(line[indent:] for line in body[first:last]), descriptions[1])
                os.write(terminal, b"quis\n")
                self.assertEqual(process.wait(timeout=5), 0)
        self.assertEqual(self.read_library()["header"]["versions"], entries)
        self.run_scu("verify_audit_trail")

    def test_version_history_uses_aligned_space_columns_for_long_versions_and_full_descriptions(self):
        self.run_scu("locv", "description=First\nMore detail")
        self.run_scu("crev", "123456789.1234567890")
        self.run_scu("locv", "description=Second\nOther detail")
        self.run_scu("crev", "123456789.1234567891")
        entries = self.read_library()["header"]["versions"]
        widths = [len("123456789.1234567891"), len("locked"), len(self.local_stamp(entries[0]["locked_utc"]))]
        for mode in ("short", "full"):
            result = self.run_scu("disvh", "dd=" + mode)
            self.assertNotIn("\t", result)
            lines = result.splitlines()
            expected = [f'{"Version":<{widths[0]}}  {"Status":<{widths[1]}}  {"Locked (local TZ)":<{widths[2]}}  Description']
            if mode == "full":
                expected[0] = expected[0].split("  Description")[0].rstrip()
            for entry in entries:
                status = "locked" if entry["locked"] else "open"
                stamp = self.local_stamp(entry["locked_utc"]) if "locked_utc" in entry else "None"
                description = entry.get("description", "")
                if mode == "short":
                    description = description.split("\n")[0]
                else:
                    expected.append(f'{entry["name"]:<{widths[0]}}  {status:<{widths[1]}}  {stamp}')
                    if description:
                        expected.extend(description.splitlines())
                        expected.append("")
                    continue
                expected.append(f'{entry["name"]:<{widths[0]}}  {status:<{widths[1]}}  {stamp:<{widths[2]}}  {description}')
            self.assertEqual(lines, ("\n".join(expected)).rstrip().splitlines())
        self.assertEqual(self.read_library()["header"]["versions"], entries)
        self.run_scu("verify_audit_trail")

    def test_display_library_runs_when_opening_an_existing_library_at_a_terminal(self):
        project = self.root / "project library.sqlite"
        self.run_scu(project, "inil")
        self.run_scu(project, "lock_version", "Test version")
        summary, header = self.run_scu(project, "disl").split("\n", 1)
        self.assertEqual(summary, f'Library "{project}".')
        rows = dict(re.split(r" {2,}", line, maxsplit=1) for line in header.splitlines()[1:])
        self.assertEqual(json.loads(rows["editor"]), ["vi"])
        self.assertEqual(rows["build_command"], "(not set)")
        self.assertNotIn("versions", rows)
        self.assertNotIn("Test version", header)
        self.run_scu(project, "create_version", "1.1")
        editor = ["code", "--wait", "editor argument"]
        build_command = 'make -C "$1"'
        self.run_scu(project, "configure_library", "editor=" + json.dumps(editor),
                     "build_command=" + build_command, "comment_prefix=#", "version_increment=0.05")
        expected = f'Library "{project}".'
        expected_header = json.loads(self.run_scu(project, "display_library", "json=yes"))
        self.assertEqual(expected_header["editor"], editor)
        self.assertEqual(expected_header["build_command"], build_command)
        summary, header = self.run_scu(project, "disl").split("\n", 1)
        self.assertEqual(summary, expected)
        formatted_header = header
        rows = dict(re.split(r" {2,}", line, maxsplit=1) for line in header.splitlines()[1:])
        self.assertEqual(set(rows), (set(expected_header) - {"versions"}) | {"previous_locked_version"})
        self.assertEqual(rows["previous_locked_version"], "1.0")
        self.assertEqual(json.loads(rows["editor"]), editor)
        self.assertEqual(rows["build_command"], build_command)
        self.assertEqual(rows["comment_prefix"], "#")
        self.assertEqual(rows["version_increment"], "0.05")
        self.assertNotIn("Test version", header)

        with self.terminal_session(f"ln={project}") as (process, terminal, read_until):
            startup = read_until(b"scu> ").decode().replace("\r\n", "\n")
            self.assertIn(expected + "\n", startup)
            header = startup.split(expected + "\n", 1)[1].rsplit("scu> ", 1)[0]
            self.assertEqual(header.rstrip(), formatted_header)
            self.assertNotIn("Test version", header)
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)

        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines(project)]
        self.assertEqual([event.get("command") for event in events[-4::2]],
                         ["display_library", "display_library"])
        self.assertTrue(events[-1]["success"])
        self.assertEqual(events[-1]["detail"], expected)
        self.assertEqual(events[-1]["snapshot"], {"version": "1.1", "library_revision": 0})

        with self.terminal_session("new.sqlite") as (process, terminal, read_until):
            startup = read_until(b"scu> ")
            self.assertNotIn(b"scu:", startup)
            self.assertNotIn(b"Library ", startup)
            self.assertFalse((self.root / "new.sqlite").exists())
            os.write(terminal, b'inil\n')
            self.assertIn(b"Initialized version 1.0", read_until(b"scu> "))
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)

    def test_interrupt_cancels_pending_command_and_keeps_session_open(self):
        with self.terminal_session() as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"create_deck\n")
            self.assertIn(b"deck_name (dn) : string = scu$required", read_until(b"deck_name= "))
            process.send_signal(signal.SIGINT)
            self.assertIn(b"Command cancelled.", read_until(b"scu> "))
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)
        self.assertIn("records=4", self.run_scu("verify_audit_trail"))

    def test_ctrl_c_cancels_library_lock_wait_before_locking_version(self):
        lock_path = self.library.with_name("." + self.library.name + ".lock")
        with self.terminal_session(TERM="dumb", controlling=True) as (process, terminal, read_until):
            read_until(b"scu> ")
            before = self.audit_lines()
            with lock_path.open("rb") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                os.write(terminal, b"lock_version Test_version\n")
                descriptors = Path(f"/proc/{process.pid}/fd")
                deadline = time.monotonic() + 5
                while not any(fd.resolve() == lock_path for fd in descriptors.iterdir()):
                    self.assertLess(time.monotonic(), deadline, "SCU did not open the held lock")
                    time.sleep(0.01)
                os.write(terminal, b"\x03")
                response = read_until(b"scu> ")
                self.assertEqual(response.count(b"Command cancelled."), 1, response)
                self.assertNotIn(b"Locked version", response)
                self.assertEqual(self.audit_lines(), before)
            os.write(terminal, b"display_version_history\n")
            self.assertRegex(read_until(b"scu> "), rb"1.0 +open")
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)


    def test_review_interrupt_during_build_preserves_pending_changes(self):
        self.store("main", b"source")
        self.run_scu("conl", "bc=echo build-started; sleep 30")
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"cred pending\n")
            self.assertIn(b"pending version", read_until(b"scu> "))
            os.write(terminal, b"extd main built\n")
            read_until(b"build-started")
            process.send_signal(signal.SIGINT)
            self.assertIn(b"Build command interrupted", read_until(b"scu> "))
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 1)
        self.assertIn("pending\t", self.table_data(self.run_scu("disdl")))
        self.assertIn("interrupted=0", self.run_scu("verify_audit_trail"))

    def test_review_hangup_saves_and_termination_restores_terminal(self):
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"cred pending\n")
            self.assertIn(b"pending version", read_until(b"scu> "))
            process.send_signal(signal.SIGHUP)
            self.assertEqual(process.wait(timeout=5), 0)
            self.assertTrue(termios.tcgetattr(terminal)[3] & termios.ICANON)
        self.assertIn("pending\t", self.table_data(self.run_scu("disdl")))
        for termination in (signal.SIGTERM, signal.SIGQUIT):
            with self.subTest(signal=termination), self.terminal_session(TERM="xterm") as (
                process, terminal, read_until
            ):
                read_until(b"scu> ")
                name = termination.name.lower()
                os.write(terminal, f"cred {name}\n".encode())
                self.assertIn(b"version 1.0", read_until(b"scu> "))
                process.send_signal(termination)
                self.assertEqual(process.wait(timeout=5), 128 + termination)
                self.assertTrue(termios.tcgetattr(terminal)[3] & termios.ICANON)
                self.assertIn(f"{name}\t", self.table_data(self.run_scu("disdl")))
        self.assertIn("interrupted=0", self.run_scu("verify_audit_trail"))

    def test_termination_needs_no_save_when_library_lock_is_busy(self):
        lock_path = self.library.with_name("." + self.library.name + ".lock")
        with self.terminal_session(TERM="dumb") as (process, terminal, read_until), lock_path.open("rb") as lock:
            read_until(b"scu> ")
            os.write(terminal, b"cred committed\n")
            self.assertIn(b"committed version", read_until(b"scu> "))
            fcntl.flock(lock, fcntl.LOCK_EX)
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(timeout=5), 128 + signal.SIGTERM)
        self.assertEqual(list(self.root.glob("*.recovery-*.json")), [])
        self.assertIn("committed\t", self.table_data(self.run_scu("disdl")))

    def test_sigterm_during_build_saves_pending_changes(self):
        database = self.root / "project.sqlite"
        self.run_scu(database, "inil")
        self.run_scu(database, "cred", "main")
        self.run_scu(database, "conl", "bc=echo build-started; exec sleep 30")
        with self.terminal_session(database, TERM="dumb", controlling=True) as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"cred pending\n")
            self.assertIn(b"pending version", read_until(b"scu> "))
            os.write(terminal, b"extd main built\n")
            read_until(b"build-started")
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(timeout=5), 128 + signal.SIGTERM)
        self.assertIn("pending\t", self.table_data(self.run_scu(database, "disdl")))
        self.assertIn("interrupted=0", self.run_scu(database, "verify_audit_trail"))

    def test_build_uses_the_controlling_terminal_and_returns_it_to_scu(self):
        self.store("main", b"source")
        self.run_scu("conl", 'bc=stty tostop </dev/tty || exit; printf "Build answer? "; '
                     'read answer </dev/tty; echo "got=$answer"')
        with self.terminal_session(TERM="dumb", controlling=True) as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"extd main output\n")
            read_until(b"Build answer? ")
            os.write(terminal, b"yes\n")
            self.assertIn(b"got=yes", read_until(b"scu> "))
            self.assertFalse(termios.tcgetattr(terminal)[3] & termios.TOSTOP)
            os.write(terminal, b"extd main output\n")
            read_until(b"Build answer? ")
            os.write(terminal, b"\x03")
            self.assertIn(b"Build command interrupted", read_until(b"scu> "))
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 1)
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        self.assertEqual([event["success"] for event in events if event["phase"] == "build"], [True, False])

    def test_stopped_build_returns_control_to_scu(self):
        self.store("main", b"source")
        self.run_scu("conl", "bc=kill -STOP $$")
        with self.terminal_session(TERM="dumb", controlling=True) as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"extd main output\n")
            self.assertIn(b"Build command stopped before it finished", read_until(b"scu> "))
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 1)

    def test_ctrl_z_suspends_and_foreground_resumes_build_and_completion_pager(self):
        bash = shutil.which("bash")
        if bash is None:
            self.skipTest("Job-control shell required.")
        self.store("main", b"source")
        for index in range(12):
            (self.root / f"choice-{index:02d}").touch()
        build = (
            "from pathlib import Path\n"
            "from time import sleep\n"
            "Path('build-ready').touch()\n"
            "print('BUILD-START', flush=True)\n"
            "while not Path('resume').exists(): sleep(0.02)\n"
            "print('BUILD-RESUMED', flush=True)\n"
        )
        self.run_scu("conl", "bc=exec " + shlex.join([sys.executable, "-c", build]))
        with self.terminal_session("--noprofile", "--norc", "-i", TERM="dumb", columns=22, rows=5,
                                   PS1="test-shell> ", HISTFILE="/dev/null",
                                   controlling=True, executable=bash, read_timeout=10) as (shell, terminal, read_until):
            read_until(b"test-shell> ")
            os.write(terminal, ("TERM=xterm " + shlex.quote(str(SCU)) + " | cat\n").encode())
            read_until(b"scu> ")
            os.write(terminal, b"extd main expanded\n")
            read_until(b"BUILD-START")
            # The startup configuration can echo BUILD-START through `cat`
            # after the stderr prompt. Wait for the actual child, not that text.
            deadline = time.monotonic() + 5
            while not (self.root / "build-ready").exists():
                self.assertLess(time.monotonic(), deadline, "Build child did not become ready")
                time.sleep(0.01)
            os.write(terminal, b"\x1a")
            stopped = read_until(b"test-shell> ")
            self.assertIn(b"Stopped", stopped)
            (self.root / "resume").touch()
            os.write(terminal, b"fg\n")
            self.assertIn(b"BUILD-RESUMED", read_until(b"scu> "))
            os.write(terminal, b"extd main of=choice-\t\t")
            read_until(b"--More--")
            os.write(terminal, b"\x1a")
            self.assertIn(b"Stopped", read_until(b"test-shell> "))
            os.write(terminal, b"fg\n")
            read_until(b"--More--")
            (self.root / "choice-00").unlink()
            os.write(terminal, b"q00\n")
            self.assertIn(b"Using library version", read_until(b"deck_version 1.0-0.000."))
            self.assertEqual((self.root / "choice-00").read_bytes(), b"source")
            os.write(terminal, b'quis\n')
            read_until(b"test-shell> ")
            os.write(terminal, b"exit\n")
            self.assertEqual(shell.wait(timeout=10), 0)
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        outcomes = [event for event in events if event["phase"] == "build"]
        self.assertEqual(len(outcomes), 2)
        self.assertTrue(all(outcome["success"] for outcome in outcomes))

    def test_background_build_completion_leaves_shell_in_foreground(self):
        bash = shutil.which("bash")
        if bash is None:
            self.skipTest("Job-control shell required.")
        self.store("main", b"source")
        build = ("from pathlib import Path\nfrom time import sleep\n"
                 "print('BUILD-START', flush=True)\n"
                 "while not Path('resume').exists(): sleep(0.02)\n"
                 "print('BUILD-FINISHED', flush=True)\n")
        self.run_scu("conl", "bc=exec " + shlex.join([sys.executable, "-c", build]))
        with self.terminal_session("--noprofile", "--norc", "-i", TERM="dumb",
                                   PS1="test-shell> ", HISTFILE="/dev/null",
                                   controlling=True, executable=bash) as (shell, terminal, read_until):
            read_until(b"test-shell> ")
            os.write(terminal, (shlex.quote(str(SCU)) + "\n").encode())
            read_until(b"scu> ")
            scu_group = os.tcgetpgrp(terminal)
            os.write(terminal, b"extd main expanded\n")
            read_until(b"BUILD-START")
            os.write(terminal, b"\x1a")
            self.assertIn(b"Stopped", read_until(b"test-shell> "))
            os.write(terminal, b"bg\n")
            read_until(b"test-shell> ")
            (self.root / "resume").touch()
            read_until(b"BUILD-FINISHED")
            deadline = time.monotonic() + 8
            while not any(json.loads(line.split(b" ", 1)[1])["phase"] == "build"
                          for line in self.audit_lines()):
                self.assertLess(time.monotonic(), deadline, "Build outcome was not recorded")
                time.sleep(0.02)
            self.assertEqual(os.tcgetpgrp(terminal), shell.pid)
            os.write(terminal, b"echo SHELL-ALIVE\n")
            read_until(b"\r\nSHELL-ALIVE\r\n")
            os.write(terminal, b"fg\n")
            deadline = time.monotonic() + 8
            while os.tcgetpgrp(terminal) != scu_group:
                self.assertLess(time.monotonic(), deadline, "SCU did not return to the foreground")
                time.sleep(0.02)
            os.write(terminal, b'quis\n')
            deadline = time.monotonic() + 8
            while os.tcgetpgrp(terminal) != shell.pid:
                self.assertLess(time.monotonic(), deadline, "The shell did not regain the terminal")
                time.sleep(0.02)
            os.write(terminal, b"exit\n")
            self.assertEqual(shell.wait(timeout=8), 0)

    def test_background_build_waiting_for_terminal_input_can_resume_in_foreground(self):
        bash = shutil.which("bash")
        if bash is None:
            self.skipTest("Job-control shell required.")
        self.store("main", b"source")
        build = (
            "from pathlib import Path\nfrom time import sleep\n"
            "print('BUILD-START', flush=True)\n"
            "while not Path('resume').exists(): sleep(0.02)\n"
            "print('BUILD-READ', flush=True)\n"
            "with open('/dev/tty') as tty: answer = tty.readline().strip()\n"
            "print('BUILD-GOT=' + answer, flush=True)\n"
        )
        self.run_scu("conl", "bc=exec " + shlex.join([sys.executable, "-c", build]))
        with self.terminal_session("--noprofile", "--norc", "-i", TERM="dumb",
                                   PS1="test-shell> ", HISTFILE="/dev/null", read_timeout=10,
                                   controlling=True, executable=bash) as (shell, terminal, read_until):
            read_until(b"test-shell> ")
            os.write(terminal, (shlex.quote(str(SCU)) + "\n").encode())
            read_until(b"scu> ")
            scu_pid = os.tcgetpgrp(terminal)
            os.write(terminal, b"extd main expanded\n")
            read_until(b"BUILD-START")
            os.write(terminal, b"\x1a")
            self.assertIn(b"Stopped", read_until(b"test-shell> "))
            os.write(terminal, b"bg\n")
            read_until(b"test-shell> ")
            (self.root / "resume").touch()
            read_until(b"BUILD-READ")
            deadline = time.monotonic() + 8
            status = Path(f"/proc/{scu_pid}/status")
            while "T" not in next(line for line in status.read_text().splitlines() if line.startswith("State:")):
                self.assertLess(time.monotonic(), deadline, "SCU did not suspend with its build")
                time.sleep(0.02)
            events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
            self.assertFalse(any(event["phase"] == "build" for event in events))
            self.assertEqual(os.tcgetpgrp(terminal), shell.pid)
            os.write(terminal, b"fg\n")
            deadline = time.monotonic() + 8
            while os.tcgetpgrp(terminal) == shell.pid:
                self.assertLess(time.monotonic(), deadline, "The build did not gain the foreground")
                time.sleep(0.02)
            os.write(terminal, b"answer\n")
            self.assertIn(b"BUILD-GOT=answer", read_until(b"scu> "))
            os.write(terminal, b'quis\n')
            read_until(b"test-shell> ")
            os.write(terminal, b"exit\n")
            self.assertEqual(shell.wait(timeout=8), 0)
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        outcome, = (event for event in events if event["phase"] == "build")
        self.assertTrue(outcome["success"])

    def test_sigterm_at_completion_pager_saves_without_another_command(self):
        for index in range(12):
            (self.root / f"choice-{index:02d}").touch()
        with self.terminal_session(TERM="xterm", columns=22, rows=5) as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"cred pending\n")
            read_until(b"scu> ")
            os.write(terminal, b"extd pending of=choice-\t\t")
            read_until(b"--More--")
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(timeout=8), 128 + signal.SIGTERM)
            self.assertTrue(termios.tcgetattr(terminal)[3] & termios.ICANON)
        self.assertIn("pending\t", self.table_data(self.run_scu("disdl")))

    def test_sigterm_to_suspended_prompt_saves_without_foreground_resume(self):
        bash = shutil.which("bash")
        if bash is None:
            self.skipTest("Job-control shell required.")
        with self.terminal_session("--noprofile", "--norc", "-i", TERM="dumb",
                                   PS1="test-shell> ", HISTFILE="/dev/null",
                                   controlling=True, executable=bash) as (shell, terminal, read_until):
            read_until(b"test-shell> ")
            os.write(terminal, ("TERM=xterm " + shlex.quote(str(SCU)) + "\n").encode())
            read_until(b"scu> ")
            os.write(terminal, b"cred pending\n")
            read_until(b"scu> ")
            os.write(terminal, b"\x1a")
            self.assertIn(b"Stopped", read_until(b"test-shell> "))
            os.write(terminal, b"kill -TERM %1; kill -CONT %1; wait -f %1; echo wait=$?\n")
            read_until(b"wait=143")
            self.assertEqual(os.tcgetpgrp(terminal), shell.pid)
            os.write(terminal, b"exit\n")
            self.assertEqual(shell.wait(timeout=8), 0)
        self.assertIn("pending\t", self.table_data(self.run_scu("disdl")))

    def test_nested_build_requires_build_no(self):
        self.store("main", b"source")
        self.run_scu("conl", "bc=" + shlex.join([str(SCU), "extd", "main", "inner"]))
        result = subprocess.run([SCU, "extd", "main", "outer"], cwd=self.root,
                                capture_output=True, text=True, timeout=8)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Nested SCU builds are disabled", result.stderr)

    def test_editor_save_is_kept_when_editor_handles_ctrl_c(self):
        self.store("main", b"original\n")
        editor = ["sh", "-c", 'trap \'echo editor-caught\' INT; echo editor-ready; '
                  'while ! read answer || [ "$answer" != finish ]; do :; done; '
                  'printf "edited\\n" >> "$0"']
        self.run_scu("conl", "editor=" + json.dumps(editor))
        with self.terminal_session(TERM="dumb", controlling=True) as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"edid main\n")
            read_until(b"editor-ready")
            os.write(terminal, b"\x03")
            response = read_until(b"editor-caught")
            os.write(terminal, b"finish\n")
            response += read_until(b"scu> ")
            self.assertEqual(response.count(b"editor-caught"), 1, response)
            self.assertIn(b"main version 1.0 revision 0.001", response)
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)
        self.run_scu("extd", "main", "saved")
        self.assertEqual((self.root / "saved").read_bytes(), b"original\nedited\n")

    def test_review_hangup_conflict_writes_a_recovery_library(self):
        path = self.root / "project.sqlite"
        source = self.root / "pending-source"
        source.write_bytes(b"pending source\r\n\xff")
        self.run_scu(path, "inil")
        self.run_scu(path, "cred", "base")
        self.run_scu(path, "cred", "pending", "from_file=pending-source")
        with closing(sqlite3.connect(path)) as database:
            document = json.loads(database.execute("SELECT payload FROM library").fetchone()[0])
            document["revisions"] = [json.loads(row[0]) for row in database.execute("SELECT payload FROM deck_revisions ORDER BY sequence")]
        recovery = self.root / "legacy-full-recovery.json"
        recovery.write_text(json.dumps(document))
        recovery.chmod(0o600)
        self.run_scu(path, "cred", "concurrent")
        self.assertIn("concurrent\t", self.table_data(self.run_scu(path, "disdl")))
        self.run_scu(path, "recover_library", recovery, error="destination already exists")
        restored = self.root / "restored.sqlite"
        self.assertIn("Restored 2 revision(s)", self.run_scu(restored, "recl", recovery))
        self.assertEqual(restored.stat().st_mode & 0o777, 0o600)
        self.assertIn("records=2 interrupted=0", self.run_scu(restored, "verify_audit_trail"))
        history = self.table_data(self.run_scu(restored, "display_audit_trail"))
        self.assertIn("recover_library recovery_file=", history)
        self.assertEqual(self.table_data(self.run_scu(restored, "disdl")), "base\t1.0-0.000\npending\t1.0-0.000")
        self.run_scu(restored, "extd", "pending", "restored-source")
        self.assertEqual((self.root / "restored-source").read_bytes(), source.read_bytes())
        self.assertTrue(recovery.exists())

        bad_file = self.root / "corrupt-recovery.json"
        document["revisions"][-1]["sha1"] = "0" * 40
        bad_file.write_text(json.dumps(document))
        rejected = self.root / "rejected.sqlite"
        self.run_scu(rejected, "recover_library", bad_file, error="SHA-1")
        self.assertFalse(rejected.exists())

    def test_pending_recovery_restores_only_with_the_matching_base(self):
        self.store("main", b"saved\n")
        base = self.root / "saved-base.sqlite"
        (self.root / "pending-source").write_bytes(b"new version\n")
        shutil.copy2(self.library, base)
        with closing(sqlite3.connect(base)) as database:
            identity, generation = database.execute("SELECT identity, generation FROM library").fetchone()
        self.run_scu("locv", "Test_version")
        self.run_scu("crev", "1.1")
        self.run_scu("import_deck", "main", "pending-source")
        complete = self.read_library()
        document = {"format": "scu-pending-recovery-v1", "base_library_revision": 1,
                    "base_library_state": f"{identity}:{generation}", "header": complete["header"],
                    "pending_revisions": complete["revisions"][1:]}
        recovery = self.root / "legacy-pending.json"
        recovery.write_text(json.dumps(document))
        restored = self.root / "restored.sqlite"
        self.run_scu(restored, "recover_library", recovery, error="requires base_library")
        self.assertFalse(restored.exists())

        wrong = self.root / "wrong-generation.sqlite"
        shutil.copy2(base, wrong)
        self.run_scu(wrong, "configure_library", "build_command=true")
        self.run_scu(restored, "recover_library", recovery, f"base_library={wrong}",
                     error="does not match the saved snapshot")
        self.assertFalse(restored.exists())
        self.assertIn("Restored 2 revision(s)",
                      self.run_scu(restored, "recover_library", recovery, f"bl={base}"))
        self.assertIn("records=2 interrupted=0", self.run_scu(restored, "verify_audit_trail"))
        self.run_scu(restored, "extd", "main", "restored-source", "version=1.1")
        self.assertEqual((self.root / "restored-source").read_bytes(), b"new version\n")
        self.run_scu(restored, "extd", "main", "restored-base", "version=1.0")
        self.assertEqual((self.root / "restored-base").read_bytes(), b"saved\n")
        self.assertEqual(self.table_data(self.run_scu(base, "disdl")), "main\t1.0-0.000")

        # Older pending-only files did not record the base identity and generation.
        del document["base_library_state"]
        legacy = self.root / "legacy-recovery.json"
        legacy.write_text(json.dumps(document))
        restored_legacy = self.root / "legacy.sqlite"
        self.run_scu(restored_legacy, "recover_library", legacy, f"base_library={base}")
        self.assertIn("records=2 interrupted=0", self.run_scu(restored_legacy, "verify_audit_trail"))

    def test_pending_recovery_without_saved_revisions_needs_no_base(self):
        self.run_scu("cred", "pending")
        complete = self.read_library()
        document = {"format": "scu-pending-recovery-v1", "base_library_revision": 0,
                    "header": complete["header"], "pending_revisions": complete["revisions"]}
        recovery = self.root / "legacy-pending.json"
        recovery.write_text(json.dumps(document))
        self.library.unlink()
        self.run_scu("recover_library", recovery)
        self.assertIn("records=2 interrupted=0", self.run_scu("verify_audit_trail"))
        self.assertEqual(self.table_data(self.run_scu("disdl")), "pending\t1.0-0.000")

    def test_terminal_editor_handles_utf8_keys_and_ctrl_c_and_restores_terminal(self):
        (self.root / "café").write_bytes(b"source")
        with self.terminal_session(TERM="xterm", LC_ALL="C.UTF-8") as (process, terminal, read_until):
            read_until(b"scu> ")
            cooked_flags = termios.ICANON | termios.ECHO | termios.ISIG
            self.assertEqual(termios.tcgetattr(terminal)[3] & cooked_flags, 0)

            os.write(terminal, "Ximport_deck sample cafe界".encode() + b"\x1b[D\x7f" +
                     "é".encode() + b"\x1b[C\x7f\x1b[H\x1b[3~\x1b[F\r")
            self.assertRegex(read_until(b"scu> "), rb"sample +1.0-0.000 +new")

            os.write(terminal, b"create_deck\n")
            read_until(b"deck_name= ")
            os.write(terminal, b"unfinished\x03")
            self.assertIn(b"Command cancelled.", read_until(b"scu> "))
            os.write(terminal, b"partial\x03")
            self.assertIn(b"Command cancelled.", read_until(b"scu> "))

            os.write(terminal, b"\x04")
            self.assertEqual(process.wait(timeout=5), 0)
            self.assertEqual(termios.tcgetattr(terminal)[3] & cooked_flags, cooked_flags)

        self.run_scu("extract_deck", "sample", "copy")
        self.assertEqual((self.root / "copy").read_bytes(), b"source")
        self.assertEqual(json.loads((self.root / "state/scu/history.json").read_bytes()),
                         ["import_deck sample café", "create_deck"])
        with self.terminal_session(TERM="xterm", LC_ALL="C.UTF-8") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"\x1b[A\x1b[A\n")
            self.assertIn(b"1 unchanged", read_until(b"scu> "))
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)

    def test_terminal_history_recalls_and_edits_commands(self):
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b'display_command cn=inil\n')
            self.assertIn(b'initialize_library, inil', read_until(b"scu> "))
            os.write(terminal, b"\x1b[A\x7f\x7f\x7f\x7fquis\n")
            self.assertIn(b'quit_session, quis', read_until(b"scu> "))
            os.write(terminal, b'display_command cn=quis')
            os.write(terminal, b"\x1b[A\x1b[A\x1b[B\x1b[B\n")
            self.assertIn(b'quit_session, quis', read_until(b"scu> "))
            os.write(terminal, b"unfinished")
            read_until(b"unfinished")
            process.send_signal(signal.SIGINT)
            self.assertIn(b"Command cancelled.", read_until(b"scu> "))
            os.write(terminal, b"create_deck\n")
            read_until(b"deck_name= ")
            process.send_signal(signal.SIGINT)
            self.assertIn(b"Command cancelled.", read_until(b"scu> "))
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)

    def test_terminal_reverse_search_recalls_saved_history_for_editing(self):
        saved = ["display_command cn=quis", "display_command_list", "display_command cn=inil"]
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            for command in saved:
                os.write(terminal, command.encode() + b"\n")
                read_until(b"scu> ")
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)

        history = self.root / "state/scu/history.json"
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"\x12cn=")
            read_until(b'cn= => display_command cn=inil')
            os.write(terminal, b"\x12")
            read_until(b'cn= => display_command cn=quis')
            os.write(terminal, b"\n")
            read_until(b'scu> display_command cn=quis')
            self.assertEqual(json.loads(history.read_bytes()), saved)
            os.write(terminal, b"\x7f" * 4 + b"extd\n")
            self.assertIn(b"extract_deck, extd", read_until(b"scu> "))

            os.write(terminal, b"display_command cn=quis\x12inilx")
            read_until(b"inilx => (no match)")
            os.write(terminal, b"\x7f")
            read_until(b'inil => display_command cn=inil')
            os.write(terminal, b"\x1b")
            read_until(b'scu> display_command cn=quis')
            os.write(terminal, b"\n")
            self.assertIn(b'quit_session, quis', read_until(b"scu> "))

            os.write(terminal, b"partial\x12cn=\x03")
            self.assertIn(b"Command cancelled.", read_until(b"scu> "))
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)

        self.assertEqual(json.loads(history.read_bytes()),
                         saved + ["display_command cn=extd", "display_command cn=quis"])

    def test_terminal_history_loads_escaped_utf8_in_the_c_locale(self):
        history = self.root / "state/scu/history.json"
        history.parent.mkdir(parents=True, mode=0o700)
        command = "import_deck sample café"
        history.write_text(json.dumps([command]))
        (self.root / "café").write_bytes(b"source")
        with self.terminal_session(TERM="xterm", LC_ALL="C") as (process, terminal, read_until):
            self.assertNotIn(b"Could not load command history", read_until(b"scu> "))
            os.write(terminal, b"\x1b")
            time.sleep(0.32)
            os.write(terminal, b"[A\n")
            self.assertRegex(read_until(b"scu> "), rb"sample +1.0-0.000 +new")
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)
        self.assertEqual(json.loads(history.read_bytes()), [command, command])

    def test_terminal_history_survives_restart_and_merges_overlapping_sessions(self):
        environment = {
            "TERM": "xterm", "XDG_STATE_HOME": "",
            "HOME": str(self.root / "home"),
        }
        (self.root / "prompt answer").write_bytes(b"source")
        history = self.root / "home" / ".local" / "state" / "scu" / "history.json"
        with self.terminal_session(**environment) as (first, terminal, read_until),\
             self.terminal_session(**environment) as (second, other_terminal, other_read_until):
            self.assertNotIn(b"Could not load command history", read_until(b"scu> "))
            self.assertNotIn(b"Could not load command history", other_read_until(b"scu> "))
            os.write(terminal, b'import_deck remembered "prompt answer"\n')
            self.assertRegex(read_until(b"scu> "), rb"remembered +1.0-0.000 +new")
            os.write(other_terminal, b'display_command cn=quis\n')
            self.assertIn(b'quit_session, quis', other_read_until(b"scu> "))
            self.assertEqual(json.loads(history.read_bytes()),
                             ['import_deck remembered "prompt answer"', "display_command cn=quis"])
            self.assertEqual(history.stat().st_mode & 0o777, 0o600)
            os.write(terminal, b'quis\n')
            os.write(other_terminal, b'quis\n')
            self.assertEqual(first.wait(timeout=5), 0)
            self.assertEqual(second.wait(timeout=5), 0)

        with self.terminal_session(**environment) as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"\x1b[A\x7f\x7f\x7f\x7finil\n")
            self.assertIn(b'initialize_library, inil', read_until(b"scu> "))
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)
        self.assertEqual(json.loads(history.read_bytes()),
                         ['import_deck remembered "prompt answer"', "display_command cn=quis", "display_command cn=inil"])

    def test_terminal_tab_completes_command_and_parameter_names_and_aliases(self):
        (self.root / "source file").write_bytes(b"source")
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"display_\t\t")
            matches = read_until(b"scu> display_")
            self.assertIn(b"display_command_list", matches)
            self.assertIn(b"display_deck_list", matches)
            os.write(terminal, b"\x15")
            os.write(terminal, b'import_de\tdeck_na\tmain.pas sf\t"source file"\n')
            self.assertRegex(read_until(b"scu> "), rb"main.pas +1.0-0.000 +new")
            os.write(terminal, b"extd\tdn\tmain.pas output_f\tcopy --rev\t0.000\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "copy").read_bytes(), b"source")
            os.write(terminal, b"extd\tdn=main.pas of\tsecond rev\t0.000\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "second").read_bytes(), b"source")
            os.write(terminal, b'disdl\t--v\t1.0\n')
            self.assertRegex(read_until(b"scu> "), rb"main.pas +1.0-0.000")
            os.write(terminal, b'quis\t\n')
            self.assertEqual(process.wait(timeout=5), 0)

    def test_tab_completes_a_long_option_after_an_unfilled_required_option(self):
        self.store("main.pas", b"source")
        executable = self.root / "scu"
        shutil.copy2(SCU, executable)
        definitions = json.loads(SCU.with_name("commands.json").read_bytes())
        expand = next(command for command in definitions["commands"] if command["name"] == "extract_deck")
        version = next(option for option in expand["arguments"] if option["name"] == "version")
        version["value"] = "scu$required"
        (self.root / "commands.json").write_text(json.dumps(definitions))

        with self.terminal_session(TERM="xterm", executable=executable) as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"extd main.pas expanded --version --buil\tno\n")
            read_until(b"version= ")
            os.write(terminal, b"1.0\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "expanded").read_bytes(), b"source")
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        attempt = next(event for event in events if event.get("command") == "extract_deck")
        self.assertEqual(attempt["parameters"], {"deck_name": "main.pas", "output_file": "expanded", "build": "no", "version": "1.0", "overwrite": "no"})

    def test_tab_skips_a_positional_argument_with_an_empty_quoted_value_after_the_cursor(self):
        self.store("main", b"source")
        prefix, tail = b"extd main ", b' ""'
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, prefix + tail + b"\x02" * len(tail) + b"\t\t")
            matches = read_until(b"scu> " + prefix + tail)
            self.assertIn(b"revision", matches)
            self.assertNotIn(b"output_file", matches)
            os.write(terminal, b'\x05\x15quis\n')
            self.assertEqual(process.wait(timeout=5), 0)

    def test_terminal_tab_completion_lists_aligned_columns(self):
        self.store("main", b"source")
        names = ("pick-a", "pick-bb", "pick-cc", "pick-zzz", "pick-界", "pick-語")
        long_names = ("long-a" + "x" * 20, "long-b" + "y" * 20)
        for name in (*names, *long_names):
            (self.root / name).touch()

        def cells(text):
            return len(text) + sum(character in "界語" for character in text)

        for columns, per_row in ((28, 2), (20, 1)):
            with self.subTest(columns=columns), self.terminal_session(
                TERM="xterm", LC_ALL="C.UTF-8", columns=columns
            ) as (process, terminal, read_until):
                read_until(b"scu> ")
                os.write(terminal, b"extd of=pick-\t\t")
                output = read_until(b"scu> extd of=pick-").decode()
                rows = output.split("\r\n")[1:-1]
                self.assertEqual({candidate for row in rows for candidate in row.split()},
                                 {"of=" + name for name in names})
                for row in rows:
                    self.assertLessEqual(cells(row), columns)
                    self.assertEqual(len(row.split()), per_row)
                    if per_row == 2:
                        second = row.split()[1]
                        self.assertEqual(cells(row[:row.index(second)]), 13)
                (self.root / "pick-a").unlink()
                os.write(terminal, b"a\n")
                read_until(b"scu> ")
                self.assertEqual((self.root / "pick-a").read_bytes(), b"source")

                if columns == 20:
                    os.write(terminal, b"extd of=long-\t\t")
                    output = read_until(b"scu> extd of=long-").decode()
                    rows = output.split("\r\n")[1:-1]
                    labels = ["of=" + name for name in long_names]
                    self.assertEqual(rows, [part for label in labels for part in (label[:20], label[20:])])
                    os.write(terminal, b"\x15")

                os.write(terminal, b'quis\n')
                self.assertEqual(process.wait(timeout=5), 0)

    def test_review_completion_shows_longer_aliases_and_complete_paths(self):
        self.store("main", b"source")
        for name in ("my file.txt", "my fine.txt", "back\\slash.txt"):
            (self.root / name).touch()
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"disd\t\t")
            matches = read_until(b"scu> disd")
            self.assertIn(b"disdl", matches)
            os.write(terminal, b"\x15extd overwrite=yes of=my\t\t")
            matches = read_until(b"scu> extd overwrite=yes of=my\\ fi")
            self.assertIn(b"of=my\\ file.txt", matches)
            self.assertIn(b"of=my\\ fine.txt", matches)
            os.write(terminal, b"\x15extd overwrite=yes of=back\t\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "back\\slash.txt").read_bytes(), b"source")
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)

    def test_terminal_tab_completion_pages_and_restores_the_draft_cursor(self):
        self.store("main", b"source")
        names = [f"pick-{index:02}" for index in range(20)]
        for name in names:
            (self.root / name).touch()
        prefix, tail = b"extd of=pick-", b" dn=main"
        complete = prefix + tail + b"\x02" * len(tail) + b"\t\t"
        draft = b"scu> " + prefix + tail

        def matches(output):
            return [label.decode()[3:] for label in re.findall(rb"of=pick-\d{2}", output)]

        with self.terminal_session(TERM="xterm", columns=28, rows=5) as (
            process, terminal, read_until
        ):
            read_until(b"scu> ")
            os.write(terminal, complete)
            self.assertEqual(matches(read_until(b"--More--")), names[:8])
            os.write(terminal, b" ")
            self.assertEqual(matches(read_until(b"--More--")), names[8:16])
            os.write(terminal, b"\n")
            self.assertEqual(matches(read_until(b"--More--")), names[16:18])
            os.write(terminal, b"q")
            read_until(draft)
            (self.root / "pick-00").unlink()
            os.write(terminal, b"00\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "pick-00").read_bytes(), b"source")

            os.write(terminal, complete)
            self.assertEqual(matches(read_until(b"--More--")), names[:8])
            os.write(terminal, b"\t")
            self.assertEqual(matches(read_until(b"--More--")), names[8:16])
            os.write(terminal, b" ")
            last = read_until(draft)
            self.assertNotIn(b"--More--", last)
            self.assertEqual(matches(last), names[16:])
            (self.root / "pick-19").unlink()
            os.write(terminal, b"19\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "pick-19").read_bytes(), b"source")
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)

    def test_terminal_tab_completes_exact_case_deck_names(self):
        self.store("Makefile", b"upper")
        self.store("makefile", b"lower")
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            for prefix, expected in [(b"Ma", b"upper"), (b"ma", b"lower")]:
                os.write(terminal, b"extd " + prefix + b"\t of=result o=y\n")
                read_until(b"scu> ")
                self.assertEqual((self.root / "result").read_bytes(), expected)
            os.write(terminal, b"quis\n")
            self.assertEqual(process.wait(timeout=5), 0)

    def test_terminal_tab_completes_library_values_and_paths(self):
        self.store("main.pas", b"old\n")
        self.run_scu("lock_version", "Test version")
        self.run_scu("create_version", "2.0")
        for index in range(8):
            self.store("main.pas", f"edit {index}\n".encode())
        self.store("main.pas", b"new\n")
        directory = self.root / "output dir"
        directory.mkdir()
        (directory / "working copy").touch()
        (self.root / "prompt copy").write_bytes(b"prompt source\n")
        (self.root / "source file").write_bytes(b"new deck\n")
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            audit_before = self.audit_lines()
            os.write(terminal, b'extd overwrite=yes main.pas v=2.0 r=0.00\t\t')
            self.assertIn(b"r=0.008", read_until(b'scu> extd overwrite=yes main.pas v=2.0 r=0.00'))
            self.assertEqual(self.audit_lines(), audit_before)
            os.write(terminal, b"\x15extd overwrite=yes ma\t of=out\twork\t --v 1.0 --r 0.000\n")
            read_until(b"scu> ")
            self.assertEqual((directory / "working copy").read_bytes(), b"old\n")
            os.write(terminal, b"extd dn=ma\t v=2.\t of=expanded\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "expanded").read_bytes(), b"new\n")
            os.write(terminal, b"disdd of=unified ma\t 1.\t 2.0-0.008\t\n")
            self.assertIn(b"+++ main.pas@2.0-0.008", read_until(b"scu> "))
            os.write(terminal, b"disdd of=unified ma\t 1.\t scu$cur\t\n")
            self.assertIn(b"+++ main.pas@2.0-0.008", read_until(b"scu> "))
            os.write(terminal, b"disdd of=unified ma\t 1.\t\n")
            self.assertIn(b"+++ main.pas@2.0-0.008", read_until(b"scu> "))
            os.write(terminal, b"disdd of=unified ma\t scu$pre\t\n")
            self.assertIn(b"From deck version 2.0-0.007.", read_until(b"scu> "))
            os.write(terminal, b"disdd of=unified ma\t\n")
            self.assertIn(b"From deck version 2.0-0.007.", read_until(b"scu> "))
            os.write(terminal, b'import_deck prompted source_file="prompt c\t\n')
            self.assertRegex(read_until(b"scu> "), rb"prompted +2.0-0.000 +new")
            os.write(terminal, b"extd overwrite=yes prompted\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "prompt copy").read_bytes(), b"prompt source\n")
            os.write(terminal, b'cred latest ff="source f\t\n')
            self.assertIn(b"latest version 2.0 revision 0.000", read_until(b"scu> "))
            os.write(terminal, b"disdd of=unified latest scu$\t\n")
            self.assertIn(b"From deck version 2.0-0.000.", read_until(b"scu> "))
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)

    def test_completion_snapshot_refreshes_after_another_process_saves(self):
        self.store("first-deck", b"first")
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"extd fir\t of=first-out\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "first-out").read_bytes(), b"first")
            self.store("second-deck", b"second")
            os.write(terminal, b"extd sec\t of=second-out\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "second-out").read_bytes(), b"second")
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)

    def test_terminal_tab_filters_decks_by_snapshot_and_revisions_by_deck(self):
        self.store("alpha-old", b"old\n")
        self.store("inherited", b"inherited\n")
        self.run_scu("lock_version", "Test version")
        self.run_scu("create_version", "2.0")
        self.store("alpha-new", b"new deck\n")
        for index in range(6):
            self.store("other", f"other {index}\n".encode())
        self.store("alpha-old", b"updated\n")
        self.store("alpha-new", b"updated new deck\n")

        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            for command, output, source in (
                (b"extd --v 1.0 dn=alpha-\t of=old-version\n", "old-version", b"old\n"),
                (b"extd v=2.0 inh\t of=inherited-copy\n", "inherited-copy", b"inherited\n"),
                (b"extd v=1.0 r=0.000 dn=alpha-\t of=old-revision\n", "old-revision", b"old\n"),
            ):
                os.write(terminal, command)
                read_until(b"scu> ")
                self.assertEqual((self.root / output).read_bytes(), source)

            tail = b" of=version-after v=1.0"
            os.write(terminal, b"extd dn=alpha-" + tail + b"\x02" * len(tail) + b"\t\x05\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "version-after").read_bytes(), b"old\n")

            os.write(terminal, b"disdd of=unified fs=2.0-0.000 ts=1.0-0.000 dn=alpha-\t\n")
            self.assertIn(b"+++ alpha-old@1.0-0.000", read_until(b"scu> "))

            os.write(terminal, b"extd alpha-old r=0.\t\t")
            revisions = read_until(b"extd alpha-old r=0.000 ")
            self.assertIn(b"r=0.000", revisions)
            self.assertNotIn(b"r=0.001", revisions)
            os.write(terminal, b"\x15disdd of=unified dn=alpha-old ts=1.0-0.000 fs=2.0-\t\n")
            self.assertIn(b"--- alpha-old@2.0-0.000", read_until(b"scu> "))
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)

    def test_terminal_tab_filters_versions_to_snapshots_containing_the_deck(self):
        self.store("earlier", b"old")
        self.run_scu("lock_version", "Test version")
        self.run_scu("create_version", "1.1")
        self.store("later", b"source")
        self.run_scu("lock_version", "Test version")
        self.run_scu("create_version", "1.2")

        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b'disdl v=1.\t\t')
            self.assertIn(b"v=1.0", read_until(b'scu> disdl v=1.'))

            os.write(terminal, b"\x15extd dn=later v=1.\t\t")
            matches = read_until(b"scu> extd dn=later v=1.")
            self.assertNotIn(b"v=1.0", matches)
            self.assertIn(b"v=1.1", matches)
            self.assertIn(b"v=1.2", matches)
            os.write(terminal, b"2 of=inherited-copy\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "inherited-copy").read_bytes(), b"source")

            os.write(terminal, b"disdd dn=later ts=scu$current_deck_version fs=1.\t\n")
            self.assertIn(b"From deck version 1.1-0.000.", read_until(b"scu> "))
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)

    def test_terminal_tab_skips_supplied_parameters_and_all_their_aliases(self):
        self.store("main.pas", b"source")
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            command = b"extd main.pas of=copy --r 0.000 "
            os.write(terminal, command + b"\t\t\t")
            matches = read_until(b"scu> " + command)
            self.assertIn(b"build", matches)
            self.assertNotRegex(
                matches,
                rb"(?:^|\s)(?:deck_name|deck|dn|output_file|output|o|revision|r|version|v)(?:\s|$)",
            )

            command = b"extd dn=main.pas of=copy r=0.000 --"
            os.write(terminal, b"\x15" + command + b"\t\t\t")
            matches = read_until(b"scu> " + command)
            self.assertIn(b"--overwrite", matches)
            self.assertNotRegex(matches, rb"(?:^|\s)--(?:revision|r)(?:\s|$)")

            prefix = b"extd main.pas build=no --"
            tail = b" --r 0.000 of=copy"
            os.write(terminal, b"\x15" + prefix + tail + b"\x02" * len(tail) + b"\t\t\t")
            matches = read_until(b"scu> " + prefix + tail)
            self.assertIn(b"--overwrite", matches)
            self.assertNotIn(b"--revision", matches)
            self.assertIn(b"--version", matches)

            os.write(terminal, b"\x05\x15extd dn=main.pas of=expanded r=0.000 buil\tno\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "expanded").read_bytes(), b"source")
            os.write(terminal, b'quis\n')
            self.assertEqual(process.wait(timeout=5), 0)

    def test_terminal_tab_allows_revision_when_version_is_selected(self):
        self.store("main.pas", b"source")
        self.run_scu("extd", "main.pas", "unused", "v=1.0", "r=0.000")
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            command = b"extd main.pas of=copy --"
            os.write(terminal, command + b"\t\t")
            matches = read_until(b"scu> " + command)
            self.assertIn(b"--version", matches)
            self.assertIn(b"--revision", matches)

            command = b"extd main.pas of=copy --v 1.0 "
            os.write(terminal, b"\x15" + command + b"\t\t\t")
            matches = read_until(b"scu> " + command)
            self.assertIn(b"build", matches)
            self.assertRegex(matches, rb"(?:^|\s)(?:revision|r)=(?:\s|$)")

            command = b"extd main.pas of=copy v=1.0 --"
            os.write(terminal, b"\x15" + command + b"\t\t\t")
            matches = read_until(b"scu> " + command)
            self.assertIn(b"--build", matches)
            self.assertRegex(matches, rb"(?:^|\s)--(?:revision|r)(?:\s|$)")
            os.write(terminal, b'\x15quis\n')
            self.assertEqual(process.wait(timeout=5), 0)

    def test_concurrent_stores_preserve_all_revisions(self):
        source = self.root / "input"
        source.write_bytes(b"same bytes")

        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as workers:
            list(workers.map(
                lambda number: self.run_scu("import_deck", f"deck{number}", source.name), range(8)
            ))
        self.assertEqual(len(self.table_data(self.run_scu("disdl")).splitlines()), 8)
        self.assertIn("records=20 interrupted=0", self.run_scu("verify_audit_trail"))
        self.assertEqual(len(self.read_library()["revisions"]), 8)

    def test_review_snapshot_source_ownership_empty_selectors_and_symlinks(self):
        self.configure_file_patterns(["*.pas"])
        self.run_scu("cred", "virtual.pas")
        source = self.root / "actual.pas"
        source.write_bytes(b"first")
        self.run_scu("impd", "logical.pas", source.name)
        self.assertIn("1 unchanged", self.run_scu("impd"))
        source.write_bytes(b"second")
        self.assertIn("logical.pas", self.run_scu("impd"))
        before = self.read_library()
        self.run_scu("impd", "deck_name=", error="empty")
        self.run_scu("impd", "logical.pas", "source_file=", error="empty")
        link = self.root / "linked.pas"
        link.symlink_to(source)
        self.run_scu("impd", "linked.pas", error="symbolic link")
        self.assertEqual(self.read_library(), before)
        link.unlink(); source.unlink()
        self.assertIn("logical.pas", self.run_scu("impd"))
        listing = self.run_scu("disdl")
        self.assertIn("virtual.pas", listing)
        self.assertNotIn("logical.pas", listing)
        self.run_scu("verat")

    def test_review_outputs_require_explicit_replacement_and_protect_sources_databases(self):
        source = self.root / "main.pas"
        source.write_bytes(b"SCU$DECK_VERSION")
        self.run_scu("impd", "main.pas")
        out = self.root / "custom"
        out.write_bytes(b"private work")
        self.run_scu("extd", "main.pas", out, "build=no", error="overwrite=yes")
        self.assertEqual(out.read_bytes(), b"private work")
        self.run_scu("extd", "main.pas", out, "build=no", "overwrite=yes")
        self.run_scu("extd", "main.pas", source, "build=no", "overwrite=yes")
        other = self.root / "other.data"
        with sqlite3.connect(other) as db: db.execute("create table marker(value)")
        self.run_scu("extd", "main.pas", other, "overwrite=yes", error="SQLite")
        self.run_scu("impd", "flattened", out.name)
        self.assertEqual(source.read_bytes(), b"SCU$DECK_VERSION")

    def test_review_command_file_eof_comments_unknown_arguments_and_build_history(self):
        commands = self.root / "commands.scu"
        commands.write_text("# comment\ncred main\n")
        with subprocess.Popen([SCU, "!" + str(commands)], cwd=self.root, stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
            self.assertEqual(process.wait(timeout=5), 0)
        self.run_scu("extd", "main", "ouput_file=bad", error="output_file")
        self.run_scu("conl", "bc=exit 7")
        self.run_scu("extd", "main", error="Build command failed")
        self.assertIn("build failed", self.run_scu("disat", "1"))

    def test_review_unicode_export_manifest_roundtrips_in_c_locale(self):
        self.store("main", b"bytes")
        for locale in ("C", "C.UTF-8"):
            result = subprocess.run([SCU, "extd", "main", "é.scu"], cwd=self.root,
                                    capture_output=True, env=dict(os.environ, LC_ALL=locale))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((self.root / "é.scu").read_bytes(), b"bytes")
            manifest = json.loads((self.root / ".scu-exports.json").read_bytes())
            self.assertEqual(manifest["files"][0]["file_bytes"], "é.scu".encode().hex())
            result = subprocess.run([SCU, "verd", "od=."], cwd=self.root,
                                    capture_output=True, env=dict(os.environ, LC_ALL=locale))
            self.assertEqual(result.returncode, 0, result.stderr)


    def test_review_batch_manifest_is_written_twice_and_legacy_intents_recover(self):
        cc = shutil.which("cc")
        if cc is None:
            self.skipTest("C compiler required for publication counting")
        count = self.root / "count"
        c = self.root / "count.c"
        c.write_text(r"""
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
int mkstemp(char *pattern) {
  static int (*next)(char *);
  if (!next) next = dlsym(RTLD_NEXT, "mkstemp");
  const char *dir = getenv("SCU_COUNT_DIRECTORY");
  if (dir && !strncmp(pattern, dir, strlen(dir)) &&
      !strncmp(pattern + strlen(dir), "/.scu-", 6)) {
    FILE *out = fopen(getenv("SCU_COUNT_FILE"), "a");
    if (out) { fputs("publication\n", out); fclose(out); }
  }
  return next(pattern);
}
""")
        shim = self.root / "count.so"
        subprocess.run([cc, "-shared", "-fPIC", "-o", shim, c, "-ldl"], check=True, capture_output=True)
        for i in range(32):
            self.run_scu("cred", f"deck-{i:02}")
        directory = self.root / "release"
        directory.mkdir()
        result = subprocess.run([SCU, "relv"], cwd=self.root, capture_output=True,
                                env=dict(os.environ, LD_PRELOAD=str(shim), SCU_COUNT_DIRECTORY=str(directory),
                                         SCU_COUNT_FILE=str(count)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(count.read_text().splitlines()), 32 + 2)
        path = directory / ".scu-exports.json"
        document = json.loads(path.read_bytes())
        # A format-1 single-file pending intent remains readable.
        entry = document["files"].pop()
        entry.pop("file_bytes"); entry.pop("library_bytes")
        document["format"] = 1
        document["pending"] = {"entry": entry, "previous_sha256": ""}
        path.write_text(json.dumps(document))
        self.assertIn("Verified 32", self.run_scu("verd"))
        self.assertNotIn("pending", json.loads(path.read_bytes()))
        self.run_scu("verat")

    def test_release_complete_snapshot_inheritance_macros_and_literal_copy(self):
        self.store("inherited.pas", b"//SCU_COPY missing\r\nSCU$VERSION SCU$DECK_VERSION SCU$DATE SCU$TIME SCU$DATE_TIME\r\n")
        first = self.read_library()["revisions"][0]
        self.run_scu("locv", "First release"); self.run_scu("crev", "1.1")
        self.store("new.pas", b"SCU$VERSION $SCU_DATE scu$VERSION SCU$LIBRARY_VERSION\n")
        for args in ((), ("v=1.0",), ("v=1.1",)):
            self.run_scu("relv", *args)
            selected = "1.0" if args == ("v=1.0",) else "1.1"
            stamp = first["modified_utc"]
            expected = (f"//SCU_COPY missing\r\n{selected} 1.0-0.000 {stamp[:10]} {stamp[11:19]} {stamp}\r\n").encode()
            self.assertEqual((self.root / "release/inherited.pas").read_bytes(), expected)
        self.assertEqual((self.root / "release/new.pas").read_bytes(), b"1.1 $SCU_DATE scu$VERSION SCU$LIBRARY_VERSION\n")
        self.assertFalse((self.root / "inherited.pas").exists())
        self.assertIn("Verified 2", self.run_scu("verd"))
        payload = self.read_library()["revisions"][0]
        self.assertNotIn("copy_metadata", payload)
        self.run_scu("verat")


    def test_release_cleanup_removes_only_obsolete_matching_files(self):
        self.configure_file_patterns(["*.pas"])
        self.store("kept.pas", b"keep"); self.store("removed.pas", b"old")
        self.run_scu("relv")
        directory = self.root / "release"
        (directory / "obsolete.pas").write_bytes(b"untracked obsolete source")
        (directory / "README.md").write_text("release notes")
        (directory / "sub.pas").mkdir()
        (directory / "link.pas").symlink_to(self.root / "input")
        with sqlite3.connect(directory / "other.pas") as db: db.execute("create table marker(x)")
        self.run_scu("deld", "removed.pas")
        result = self.run_scu("relv")
        self.assertIn("removed 1 obsolete", result)
        self.assertFalse((directory / "removed.pas").exists())
        self.assertTrue((directory / "obsolete.pas").exists())
        self.assertIn("Kept untracked release file", result)
        self.assertEqual((directory / "README.md").read_text(), "release notes")
        self.assertTrue((directory / "sub.pas").is_dir())
        self.assertTrue((directory / "link.pas").is_symlink())
        self.assertTrue((directory / "other.pas").exists())
        records = json.loads((directory / ".scu-exports.json").read_bytes())["files"]
        self.assertEqual([r["file"] for r in records], ["kept.pas"])
        self.assertIn("No errors were found", self.run_scu("verd"))
        self.run_scu("verat")

    def test_release_cleanup_refuses_edited_tracked_files_and_preserves_working_sources(self):
        self.configure_file_patterns(["*.pas"])
        self.store("main.pas", b"old"); self.store("gone.pas", b"gone")
        self.run_scu("relv")
        directory = self.root / "release"
        (directory / "gone.pas").write_bytes(b"local edit")
        self.store("main.pas", b"new"); self.run_scu("deld", "gone.pas")
        manifest = (directory / ".scu-exports.json").read_bytes()
        self.run_scu("relv", error="overwrite=yes")
        self.assertEqual((directory / "main.pas").read_bytes(), b"old")
        self.assertEqual((directory / ".scu-exports.json").read_bytes(), manifest)
        self.run_scu("relv", "overwrite=yes")
        self.assertFalse((directory / "gone.pas").exists())
        self.assertEqual((directory / "main.pas").read_bytes(), b"new")
        self.run_scu("relv", "od=.", error="separate")
        self.assertEqual((self.root / "input").read_bytes(), b"new")

    def test_release_cleanup_and_writes_recover_together_after_interruption(self):
        self.configure_file_patterns(["*.pas"])
        self.store("main.pas", b"old"); self.store("gone.pas", b"old gone")
        self.run_scu("relv")
        self.store("main.pas", b"new"); self.run_scu("deld", "gone.pas")
        directory = self.root / "release"
        # One intent, one output, then one completion manifest: kill after deletion.
        self.crash_export_write(3, directory, "relv")
        self.assertEqual((directory / "main.pas").read_bytes(), b"new")
        self.assertFalse((directory / "gone.pas").exists())
        manifest = directory / ".scu-exports.json"
        pending = json.loads(manifest.read_bytes())["pending"]["entries"]
        self.assertTrue(any(p.get("delete") for p in pending))
        self.assertIn("No errors were found", self.run_scu("verd"))
        repaired = json.loads(manifest.read_bytes())
        self.assertNotIn("pending", repaired)
        self.assertEqual([r["file"] for r in repaired["files"]], ["main.pas"])
        self.run_scu("verat")

    def test_release_interrupted_cleanup_preserves_external_recreation(self):
        self.configure_file_patterns(["*.pas"])
        self.store("main.pas", b"keep"); self.store("gone.pas", b"gone")
        self.run_scu("relv"); self.run_scu("deld", "gone.pas")
        directory = self.root / "release"
        self.crash_export_write(2, directory, "relv")
        (directory / "gone.pas").write_bytes(b"recreated externally")
        report = self.run_scu("verd", error="need attention")
        self.assertIn("interrupted", report)
        self.assertEqual((directory / "gone.pas").read_bytes(), b"recreated externally")
        self.run_scu("relv", error="overwrite=yes")
        self.run_scu("relv", "overwrite=yes")
        self.assertFalse((directory / "gone.pas").exists())
        self.assertIn("No errors were found", self.run_scu("verd"))

    def test_extraction_builds_in_library_directory_and_publication_never_builds(self):
        self.store("main.pas", b"SCU$VERSION"); self.store("other.pas", b"other")
        self.run_scu("conl", "bc=pwd >> build-cwd; printf '%s\\n' \"$1\" >> build-targets")
        self.run_scu("extd", "main.pas")
        self.run_scu("extd", "main.pas", "build=no")
        self.run_scu("locv", "Release one"); self.run_scu("crev", "1.1")
        self.store("new.pas", b"new")
        self.run_scu("extv")
        self.assertEqual((self.root / "other.pas").read_bytes(), b"other")
        self.assertEqual((self.root / "main.pas").read_bytes(), b"SCU$VERSION")
        self.run_scu("relv")
        self.assertEqual((self.root / "build-cwd").read_text().splitlines(), [str(self.root)] * 2)
        self.assertEqual((self.root / "build-targets").read_text().splitlines(),
                         [str(self.root / "main.pas"), str(self.root)])
        self.run_scu("conl", "bc=exit 7")
        self.run_scu("extd", "main.pas", error="Build command failed")
        self.assertIn("build failed", self.run_scu("disat", "1"))
        self.run_scu("relv")
        self.assertIn("No errors were found", self.run_scu("verd"))
        self.run_scu("verat")

    def test_release_directory_configuration_removed_commands_and_help(self):
        header = json.loads(self.run_scu("disl", "j=y"))
        self.assertEqual(header["release_directory"], "release")
        self.assertNotIn("build_directory", header)
        self.store("main", b"source")
        self.run_scu("conl", "rd=releases")
        self.run_scu("relv")
        self.assertEqual((self.root / "releases/main").read_bytes(), b"source")
        self.run_scu("conl", "rd=.", error="separate")
        for command in ("expand_deck", "expd", "disec", "resec"):
            self.run_scu(command, error="Unknown command")
        self.run_scu("conl", "build_directory=build", error="Unknown argument")
        self.run_scu("relv", "build=yes", error="Unknown argument")
        self.assertNotIn("build (", self.run_scu("disc", "relv"))
        self.assertIn("build (b)", self.run_scu("disc", "extd"))
        self.assertIn("SCU$DATE_TIME", self.run_scu("disc", "relv"))

    def test_release_macro_scanner_skips_long_plain_text_efficiently(self):
        self.store("main", b"x" * (24 * 1024 * 1024) + b" SCU$VERSION\n")
        before = resource.getrusage(resource.RUSAGE_CHILDREN).ru_utime
        self.run_scu("extd", "main", "raw", "build=no")
        extract = resource.getrusage(resource.RUSAGE_CHILDREN).ru_utime - before
        before = resource.getrusage(resource.RUSAGE_CHILDREN).ru_utime
        self.run_scu("relv")
        expand = resource.getrusage(resource.RUSAGE_CHILDREN).ru_utime - before
        self.assertLess(expand, 4 * extract + 0.05)


    def test_release_unpublished_cleanup_intents_leave_previous_files_intact(self):
        self.configure_file_patterns(["*.pas"])
        self.store("main.pas", b"old"); self.store("gone.pas", b"gone")
        self.run_scu("relv")
        directory = self.root / "release"
        previous = (directory / ".scu-exports.json").read_bytes()
        self.store("main.pas", b"new"); self.run_scu("deld", "gone.pas")
        self.crash_export_write(2, directory, "relv")
        self.assertEqual((directory / "main.pas").read_bytes(), b"old")
        self.assertEqual((directory / "gone.pas").read_bytes(), b"gone")
        self.run_scu("verd", error="need attention")
        self.assertEqual((directory / ".scu-exports.json").read_bytes(), previous)
        self.assertEqual((directory / "gone.pas").read_bytes(), b"gone")
        self.run_scu("relv")
        self.assertFalse((directory / "gone.pas").exists())
        self.assertIn("No errors were found", self.run_scu("verd"))

    def test_release_macro_output_limit_preserves_previous_release(self):
        self.store("main", b"old")
        self.run_scu("relv")
        directory = self.root / "release"
        manifest = (directory / ".scu-exports.json").read_bytes()
        count = (64 * 1024 * 1024) // 25 + 1
        self.store("main", b"SCU$DATE_TIME\n" * count)
        self.run_scu("relv", error="64 MiB output limit")
        self.assertEqual((directory / "main").read_bytes(), b"old")
        self.assertEqual((directory / ".scu-exports.json").read_bytes(), manifest)
        self.run_scu("verat")


    def test_review_x13_untracked_release_files_require_explicit_cleanup(self):
        self.configure_file_patterns(["*"])
        (self.root / "main.pas").write_bytes(b"source")
        self.run_scu("impd", "main.pas")
        directory = self.root / "docs"
        directory.mkdir()
        (directory / "thesis.txt").write_bytes(b"unique work")
        (directory / "photo.jpg").write_bytes(b"photo")
        self.run_scu("conl", "rd=docs")
        result = self.run_scu("relv")
        self.assertIn('Kept untracked release file "thesis.txt"', result)
        self.assertEqual((directory / "thesis.txt").read_bytes(), b"unique work")
        self.assertEqual((directory / "photo.jpg").read_bytes(), b"photo")
        result = self.run_scu("relv", "overwrite=yes")
        self.assertIn('Removed obsolete release file "thesis.txt"', result)
        self.assertFalse((directory / "thesis.txt").exists())
        self.assertEqual((directory / "main.pas").read_bytes(), b"source")

    def test_review_x14_source_filenames_survive_extract_release_and_historical_selection(self):
        self.configure_file_patterns(["*.pas", "Makefile"])
        (self.root / "Makefile").write_bytes(b"all:\n\ttrue\n")
        (self.root / "Main.pas").write_bytes(b"old SCU$VERSION\n")
        self.run_scu("impd")
        self.run_scu("extv", "build=no")
        self.run_scu("extd", "Main.pas", "build=no")
        self.assertFalse((self.root / "main.pas").exists())
        self.assertFalse((self.root / "makefile").exists())
        self.assertIn("2 unchanged", self.run_scu("impd"))
        self.run_scu("locv", "First"); self.run_scu("crev", "1.1")
        (self.root / "Renamed.pas").write_bytes(b"new SCU$VERSION\n")
        self.run_scu("impd", "Main.pas", "Renamed.pas")
        self.run_scu("relv", "v=1.0")
        self.assertEqual((self.root / "release/Main.pas").read_bytes(), b"old 1.0\n")
        self.assertTrue((self.root / "release/Makefile").exists())
        self.run_scu("relv")
        self.assertFalse((self.root / "release/Main.pas").exists())
        self.assertEqual((self.root / "release/Renamed.pas").read_bytes(), b"new 1.1\n")
        self.assertIn("No errors were found", self.run_scu("verd"))
        self.run_scu("verat")

    def test_review_l8_arbitrary_filenames_and_long_manifest_keys_remain_distinct(self):
        names = ["file with spaces.c", "a" * 190 + "1.c", "a" * 190 + "2.c", "café.c", "a=b.c"]
        self.configure_file_patterns(["*.c"])
        for index, name in enumerate(names): (self.root / name).write_bytes(str(index).encode())
        self.assertIn("5 new", self.run_scu("impd"))
        self.run_scu("extv", "build=no"); self.run_scu("relv")
        for index, name in enumerate(names):
            self.assertEqual((self.root / "release" / name).read_bytes(), str(index).encode())
        manifest = json.loads((self.root / "release/.scu-exports.json").read_bytes())
        self.assertEqual(len(manifest["files"]), 5)
        self.assertEqual({r["file"] for r in manifest["files"]}, set(names))
        self.assertIn("5 unchanged", self.run_scu("impd"))
        self.assertIn("Verified 5", self.run_scu("verd"))
        self.assertIn("Verified 5", self.run_scu("verd", "od=."))
        self.run_scu("verat")

    def test_review_l9_import_refreshes_observed_sources_and_deletions(self):
        self.configure_file_patterns(["*.pas"])
        source = self.root / "Main.pas"
        source.write_bytes(b"first")
        self.run_scu("impd")
        self.assertIn("No errors were found", self.run_scu("verd", "od=."))
        source.write_bytes(b"second")
        self.run_scu("impd")
        record, = json.loads((self.root / ".scu-exports.json").read_bytes())["files"]
        self.assertEqual(record["deck_version"], "1.0-0.001")
        self.assertEqual(record["sha256"], hashlib.sha256(b"second").hexdigest())
        self.assertIn("No errors were found", self.run_scu("verd", "od=."))
        source.unlink()
        self.run_scu("impd")
        self.assertEqual(json.loads((self.root / ".scu-exports.json").read_bytes())["files"], [])
        self.assertIn("No errors were found", self.run_scu("verd", "od=."))

    def test_review_l9_observation_replays_after_commit_before_manifest_write(self):
        source = self.root / "Main.pas"
        source.write_bytes(b"committed source")
        self.crash_export_write(1, self.root, "impd", "main.pas", source.name)
        with closing(sqlite3.connect(self.library)) as database:
            self.assertEqual(database.execute("SELECT count(*) FROM deck_revisions").fetchone(), (1,))
            self.assertEqual(database.execute("SELECT count(*) FROM pending_working_exports").fetchone(), (1,))
        self.assertIn("No errors were found", self.run_scu("verd", "od=."))
        with closing(sqlite3.connect(self.library)) as database:
            self.assertEqual(database.execute("SELECT count(*) FROM pending_working_exports").fetchone(), (0,))
        self.assertEqual(source.read_bytes(), b"committed source")
        self.run_scu("verat")

    def test_review_l9_audit_failure_rolls_back_pending_observations_and_source_revision(self):
        source = self.root / "main.pas"
        source.write_bytes(b"old")
        self.run_scu("impd", "main.pas")
        manifest = (self.root / ".scu-exports.json").read_bytes()
        with closing(sqlite3.connect(self.library, isolation_level=None)) as db:
            db.execute("CREATE TRIGGER reject_import BEFORE INSERT ON audit_records "
                       "WHEN json_extract(substr(NEW.line,66), '$.phase') = 'end' "
                       "AND json_extract(substr(NEW.line,66), '$.success') = 1 "
                       "BEGIN SELECT RAISE(ABORT,'injected audit write failure'); END")
            source.write_bytes(b"new")
            self.run_scu("impd", "main.pas", error="injected audit write failure")
            self.assertEqual(db.execute("SELECT count(*) FROM deck_revisions").fetchone(), (1,))
            self.assertEqual(db.execute("SELECT count(*) FROM pending_working_exports").fetchone(), (0,))
        self.assertEqual((self.root / ".scu-exports.json").read_bytes(), manifest)
        self.assertEqual(source.read_bytes(), b"new")

    def test_review_f8_unchanged_publication_keeps_file_inode_and_timestamp(self):
        self.store("main.pas", b"SCU$VERSION SCU$DATE_TIME")
        self.run_scu("relv")
        source = self.root / "release/main.pas"
        before = source.stat()
        self.run_scu("relv")
        after = source.stat()
        self.assertEqual((after.st_ino, after.st_mtime_ns), (before.st_ino, before.st_mtime_ns))
        self.assertIn("No errors were found", self.run_scu("verd"))


    def test_review_x15_stale_private_stages_are_recovered_after_sigkill(self):
        self.store("main", b"release source")
        directory = self.root / "release"
        directory.mkdir()
        self.crash_export_write(1, directory, "relv")
        stages = list(directory.glob(".scu-stage-*"))
        self.assertEqual(len(stages), 1)
        self.assertTrue((stages[0] / "1").exists())
        self.assertEqual(stages[0].stat().st_mode & 0o777, 0o700)
        self.run_scu("relv")
        self.assertEqual(list(directory.glob(".scu-stage-*")), [])
        self.assertIn("No errors were found", self.run_scu("verd"))

    def test_review_x17_copy_warning_is_once_per_release_and_verification(self):
        self.store("main", b"//SCU_COPY missing\n//SCU_COPY also_missing\n")
        self.store("second", b"//SCU$COPY missing\n")
        for command in ("relv", "verd"):
            result = subprocess.run([SCU, command], cwd=self.root, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr.count("COPY is no longer expanded"), 1, result.stderr)
        self.assertEqual((self.root / "release/main").read_bytes(), b"//SCU_COPY missing\n//SCU_COPY also_missing\n")

    def test_review_p20_invalid_pattern_edit_is_preserved_for_correction(self):
        self.configure_file_patterns(["*.pas"])
        text = "*.pas\n../invalid\n*.c\n"
        editor = self.root / "invalid-editor.py"
        editor.write_text("import pathlib,sys; pathlib.Path(sys.argv[-1]).write_text(" + repr(text) + ")")
        self.run_scu("conl", "editor=" + json.dumps([sys.executable, str(editor)]))
        result = subprocess.run([SCU, "edifp"], cwd=self.root, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        match = re.search(r'preserved in "([^"]+)"', result.stderr)
        self.assertIsNotNone(match, result.stderr)
        recovered = Path(match[1])
        self.addCleanup(shutil.rmtree, recovered.parent)
        self.assertEqual(recovered.read_text(), text)
        self.assertEqual(json.loads(self.run_scu("disl", "j=y"))["file_patterns"], ["*.pas"])

    def test_review_p21_deleted_last_deck_is_explicit_and_working_file_is_reported(self):
        (self.root / "Main.pas").write_bytes(b"source")
        self.run_scu("impd", "main.pas", "Main.pas")
        self.configure_file_patterns(["*.pas"])
        output = self.run_scu("deld", "main.pas")
        self.assertIn("Working file", output)
        self.assertIn("import_deck will recreate", output)
        self.run_scu("extd", error="last modified deck")
        self.run_scu("edid", error="Specify deck_name explicitly")
        self.assertIn("deleted", self.run_scu("disd"))
        self.assertIn("1 new", self.run_scu("impd"))
        self.assertIn("No errors were found", self.run_scu("verd", "od=."))

    def test_review_d3_version_unified_diff_applies_to_multiple_actual_filenames(self):
        old = {"Main.pas": b"before\n", "second.txt": b"second before\n", "removed.txt": b"remove me\n", "with spaces.txt": b"old spaced\n", "with\ttab.txt": b"old tab\n"}
        for name, data in old.items():
            (self.root / name).write_bytes(data)
            self.run_scu("impd", ("file-" + hashlib.sha256(name.encode()).hexdigest()), name)
        self.run_scu("locv", "First"); self.run_scu("crev", "1.1")
        new = {"Main.pas": b"after\n", "second.txt": b"second after\n", "added.txt": b"new file\n", "with spaces.txt": b"new spaced\n", "with\ttab.txt": b"new tab\n"}
        for name, data in new.items():
            (self.root / name).write_bytes(data)
            self.run_scu("impd", ("file-" + hashlib.sha256(name.encode()).hexdigest()), name)
        self.run_scu("deld", "file-" + hashlib.sha256(b"removed.txt").hexdigest())
        difference = self.run_scu("disvd", "fv=1.0", "tv=1.1", "of=unified", "isc=no")
        self.assertIn("--- a/Main.pas\t1.0-0.000", difference)
        self.assertIn("+++ b/Main.pas\t1.1-0.000", difference)
        patch = shutil.which("patch")
        if patch is None: return  # Header semantics are still checked without this optional tool.
        checkout = self.root / "checkout"
        checkout.mkdir()
        for name, data in old.items(): (checkout / name).write_bytes(data)
        result = subprocess.run([patch, "-p1", "--batch"], cwd=checkout,
                                input=difference + "\n", capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual({p.name: p.read_bytes() for p in checkout.iterdir()}, new)

    def test_review_p19_history_wraps_at_words_without_losing_command_text(self):
        self.store("main", b"source")
        self.run_scu("extd", "main", "alpha beta gamma delta epsilon zeta eta theta")
        expected = self.table_data(self.run_scu("disat", "1")).split("\t")[0]
        with self.terminal_session(TERM="dumb", columns=56, rows=30) as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b'extd main "alpha beta gamma delta epsilon zeta eta theta"\n')
            read_until(b"scu> ")
            os.write(terminal, b"disat 1\n")
            lines = read_until(b"scu> ").decode().replace("\r\n", "\n").splitlines()
            start = next(i for i, line in enumerate(lines) if line.startswith("Command"))
            status_column = lines[start].index("Status")
            fragments = [line[:status_column].strip() for line in lines[start + 1:] if line and line != "scu> "]
            self.assertEqual(" ".join(fragments), expected)
            os.write(terminal, b"quis\n")
            self.assertEqual(process.wait(timeout=5), 0)

    def test_review_p17_editor_interrupt_stops_command_file_unless_continue_is_enabled(self):
        self.store("main", b"original\n")
        editor = ["sh", "-c", "trap 'echo editor-caught' INT; echo editor-ready; "
                  'while ! read answer || [ "$answer" != finish ]; do :; done; printf "edited\\n" >> "$0"']
        self.run_scu("conl", "editor=" + json.dumps(editor))
        for continuing in (False, True):
            name = "after-" + str(int(continuing))
            (self.root / "batch.scu").write_text("# comment\nedid main\ncred " + name + "\n")
            with self.terminal_session("coe=" + ("yes" if continuing else "no"), TERM="dumb",
                                       controlling=True) as (process, terminal, read_until):
                read_until(b"scu> ")
                os.write(terminal, b"!batch.scu\n")
                read_until(b"editor-ready")
                os.write(terminal, b"\x03")
                read_until(b"editor-caught")
                os.write(terminal, b"finish\n")
                output = read_until(b"scu> ")
                self.assertEqual((name + " version").encode() in output, continuing, output)
                os.write(terminal, b"quis\n")
                self.assertEqual(process.wait(timeout=5), 1)
            self.assertEqual(name in {row.split("\t")[0] for row in self.table_data(self.run_scu("disdl")).splitlines()}, continuing)

    def test_review_i10_completion_pager_reflows_on_resize_and_keeps_draft(self):
        self.store("main", b"source")
        for index in range(20): (self.root / f"pick-{index:02}").touch()
        with self.terminal_session(TERM="xterm", columns=28, rows=5) as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"extd of=pick-\t\t")
            read_until(b"--More--")
            fcntl.ioctl(terminal, termios.TIOCSWINSZ, struct.pack("HHHH", 6, 18, 0, 0))
            process.send_signal(signal.SIGWINCH)
            resized = read_until(b"--More--")
            self.assertIn(b"of=pick-00\r\n", resized)
            self.assertNotIn(b"of=pick-00  of=pick-01", resized)
            os.write(terminal, b"q")
            read_until(b"scu> ")
            (self.root / "pick-00").unlink()
            os.write(terminal, b"00\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "pick-00").read_bytes(), b"source")
            os.write(terminal, b"quis\n")
            self.assertEqual(process.wait(timeout=5), 0)


    def test_review_x15_sigterm_finishes_publication_and_removes_staging(self):
        cc = shutil.which("cc")
        if cc is None: self.skipTest("C compiler needed for deterministic signal injection")
        self.store("main", b"source")
        c = self.root / "term.c"
        c.write_text(r"""
#define _GNU_SOURCE
#include <dlfcn.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int mkstemp(char *pattern) {
  static int (*next)(char *); static int sent;
  if (!next) next = dlsym(RTLD_NEXT, "mkstemp");
  const char *dir = getenv("SCU_TERM_DIRECTORY");
  if (!sent && dir && !strncmp(pattern,dir,strlen(dir))) { sent=1; kill(getpid(),SIGTERM); }
  return next(pattern);
}
""")
        shim = self.root / "term.so"
        subprocess.run([cc, "-shared", "-fPIC", "-o", shim, c, "-ldl"], check=True, capture_output=True)
        directory = self.root / "release"
        result = subprocess.run([SCU, "relv"], cwd=self.root, capture_output=True, timeout=10,
                                env=dict(os.environ, LD_PRELOAD=str(shim), SCU_TERM_DIRECTORY=str(directory)))
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assertEqual((directory / "main").read_bytes(), b"source")
        self.assertEqual(list(directory.glob(".scu-stage-*")), [])
        self.assertIn("No errors were found", self.run_scu("verd"))


    def test_review_raw_filename_bytes_survive_scan_and_release(self):
        self.configure_file_patterns(["*.c"])
        name = b"raw-\xff.c"
        full = os.fsencode(self.root) + b"/" + name
        with open(full, "wb") as stream: stream.write(b"raw source")
        for command in (("impd",), ("extv", "build=no"), ("relv",), ("verd",)):
            result = subprocess.run([SCU, *command], cwd=self.root, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
        with open(os.fsencode(self.root / "release") + b"/" + name, "rb") as stream:
            self.assertEqual(stream.read(), b"raw source")
        manifest = json.loads((self.root / "release/.scu-exports.json").read_bytes())
        self.assertEqual(manifest["files"][0]["file_bytes"], name.hex())

    def test_review_m14_header_validation_names_the_library(self):
        with closing(sqlite3.connect(self.library)) as db, db:
            metadata = json.loads(db.execute("SELECT payload FROM library").fetchone()[0])
            metadata["header"]["editor"] = "invalid editor type"
            db.execute("UPDATE library SET payload=?", (json.dumps(metadata),))
        result = subprocess.run([SCU, "disl"], cwd=self.root, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(str(self.library), result.stderr)
        self.assertIn("header", result.stderr)
        self.assertIn("editor", result.stderr)

    def review_shim(self, name, source):
        compiler = shutil.which("cc")
        if compiler is None:
            self.skipTest("C compiler required for deterministic I/O instrumentation")
        path = self.root / (name + ".c")
        path.write_text(source)
        shim = self.root / (name + ".so")
        subprocess.run([compiler, "-shared", "-fPIC", "-o", shim, path, "-ldl"],
                       check=True, capture_output=True, timeout=20)
        return shim

    def test_review_b_x18_legacy_importer_provenance_requires_rebuild_before_export(self):
        archive = self.root / "archive"
        for version, files in (("1.0", {"Main.pas": b"old", "Other.pas": b"inherited"}),
                               ("1.1", {"Main.pas": b"new", "Other.pas": b"inherited"})):
            directory = archive / version
            directory.mkdir(parents=True)
            for name, data in files.items(): (directory / name).write_bytes(data)
        (archive / "HISTORY").write_text("Revision: 1.0\nDescription: First\nRevision: 1.1\nDescription: Next\n")
        # Reproduce the old importer's audited numeric staging associations.
        (self.root / "0").write_bytes(b"inherited")
        self.run_scu("impd", "other.pas", "0")
        (self.root / "0").write_bytes(b"new")
        self.run_scu("impd", "main.pas", "0")
        (self.root / "manifest.json").write_text(json.dumps({
            "format": 1, "source_archive": str(archive), "history": [], "files": []}))
        self.run_scu("impd", "scu-import-manifest.json", "manifest.json")
        before = self.read_library()["revisions"]
        for command in (("extv", "build=no"), ("relv",), ("extd", "main.pas"), ("verd",)):
            self.run_scu(*command, error="old importer with temporary source filenames")
        self.assertEqual(self.read_library()["revisions"], before)
        self.assertFalse((self.root / "release/0").exists())
        self.run_scu("extd", "main.pas", "output_file=rescued.pas", "build=no")
        self.assertEqual((self.root / "rescued.pas").read_bytes(), b"new")
        rebuilt = self.root / "rebuilt.sqlite"
        self.run_import(archive, rebuilt)
        (self.root / "rebuilt-release").mkdir()
        self.run_scu(rebuilt, "relv", "od=" + str(self.root / "rebuilt-release"))
        self.assertEqual((self.root / "rebuilt-release/Main.pas").read_bytes(), b"new")
        self.assertEqual((self.root / "rebuilt-release/Other.pas").read_bytes(), b"inherited")
        self.run_scu("verat"); self.run_scu(rebuilt, "verat")

    def test_review_b_l10_posix_filenames_are_not_patterns(self):
        names = ["src\\main.c", "C:main.c", "line\nbreak.c", "carriage\rreturn.c"]
        self.configure_file_patterns(["*.c"])
        for index, name in enumerate(names): (self.root / name).write_bytes(str(index).encode())
        self.assertIn("4 new", self.run_scu("impd"))
        self.assertIn("4 unchanged", self.run_scu("impd"))
        self.run_scu("extv", "build=no"); self.run_scu("relv")
        for index, name in enumerate(names):
            self.assertEqual((self.root / "release" / name).read_bytes(), str(index).encode())
        self.assertIn("No errors were found", self.run_scu("verd"))
        self.assertIn("No errors were found", self.run_scu("verd", "od=."))
        self.run_scu("verat")

    def test_review_b_l11_bad_observation_does_not_block_other_entries_or_exports(self):
        self.configure_file_patterns(["*.pas"])
        for name in ("big.pas", "good.pas"): (self.root / name).write_bytes(b"original")
        self.crash_export_write(1, self.root, "impd")
        with (self.root / "big.pas").open("wb") as stream:
            stream.truncate(64 * 1024 * 1024 + 1)
        result = self.run_scu("verd", "od=.", error="need attention")
        self.assertIn("untracked", result)
        manifest = json.loads((self.root / ".scu-exports.json").read_bytes())
        self.assertEqual([entry["file"] for entry in manifest["files"]], ["good.pas"])
        self.run_scu("extd", "good.pas", "build=no")
        with closing(sqlite3.connect(self.library)) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM pending_working_exports").fetchone(), (0,))
        (self.root / "retrieved").mkdir()
        self.run_scu("extv", "od=retrieved", "build=no")
        self.assertEqual((self.root / "retrieved/big.pas").read_bytes(), b"original")
        self.assertEqual((self.root / "big.pas").stat().st_size, 64 * 1024 * 1024 + 1)
        self.run_scu("verat")

    def test_review_b_i23_post_commit_interrupt_stops_command_file_with_saved_import(self):
        (self.root / "Main.pas").write_bytes(b"saved import")
        shim = self.review_shim("interrupt_observation", r'''
#define _GNU_SOURCE
#include <dlfcn.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int mkstemp(char *pattern) {
  static int (*next)(char *); static int sent;
  if (!next) next=dlsym(RTLD_NEXT,"mkstemp");
  const char *directory=getenv("SCU_TEST_DIRECTORY");
  if (!sent && directory && !strncmp(pattern,directory,strlen(directory)) &&
      !strncmp(pattern+strlen(directory),"/.scu-tmp-",10)) {
    sent=1; kill(getpid(),SIGINT);
  }
  return next(pattern);
}
''')
        script = self.root / "commands.txt"
        script.write_text("impd main.pas Main.pas\ncred should-not-run\n")
        result = subprocess.run([SCU, "!" + str(script)], cwd=self.root, capture_output=True,
                                text=True, timeout=10, env=dict(os.environ, LD_PRELOAD=str(shim),
                                                               SCU_TEST_DIRECTORY=str(self.root)))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Import was saved", result.stderr)
        self.assertEqual([r["deck"] for r in self.read_library()["revisions"]], ["main.pas"])
        with closing(sqlite3.connect(self.library)) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM pending_working_exports").fetchone(), (1,))
        self.assertIn("No errors were found", self.run_scu("verd", "od=."))
        self.run_scu("verat")

    def test_review_b_f9_import_and_verify_do_not_decode_for_metadata(self):
        names = [f"file-{index}.pas" for index in range(5)]
        self.configure_file_patterns(["*.pas"])
        for name in names: (self.root / name).write_bytes(b"payload")
        self.run_scu("impd")
        shim = self.review_shim("decode_count", r'''
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>
size_t ZSTD_decompress(void *dst,size_t cap,const void *src,size_t size) {
  static size_t (*next)(void*,size_t,const void*,size_t);
  if (!next) next=dlsym(RTLD_NEXT,"ZSTD_decompress");
  const char *path=getenv("SCU_DECODE_COUNT");
  if (path) { int fd=open(path,O_WRONLY|O_CREAT|O_APPEND,0600); if(fd>=0) {write(fd,"x",1);close(fd);} }
  return next(dst,cap,src,size);
}
''')
        counter = self.root / "decode-count"
        for command in (("impd",), ("verd", "od=.")):
            counter.unlink(missing_ok=True)
            result = subprocess.run([SCU, *command], cwd=self.root, capture_output=True, text=True,
                                    timeout=10, env=dict(os.environ, LD_PRELOAD=str(shim),
                                                        SCU_DECODE_COUNT=str(counter)))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(counter.read_bytes()), len(names), result.stdout)

    def test_review_b_f9_untracked_bad_metadata_is_reported_without_aborting_table(self):
        self.store("bad.pas", b"bad"); self.store("good.pas", b"good")
        (self.root / "good.pas").write_bytes(b"untracked")
        with closing(sqlite3.connect(self.library)) as db, db:
            payload = json.loads(db.execute("SELECT payload FROM deck_revisions WHERE sequence=1").fetchone()[0])
            payload["source_path_bytes"] = "not hex"
            db.execute("UPDATE deck_revisions SET payload=? WHERE sequence=1", (json.dumps(payload),))
        result = self.run_scu("verd", "od=.", error="need attention")
        self.assertIn("unavailable", result); self.assertIn("good.pas", result)
        self.assertIn("Needs attention:", result)

    def test_review_b_x19_staging_liveness_uses_locks_not_pids(self):
        self.store("main", b"source")
        directory = self.root / "release"
        directory.mkdir()
        # This PID need not exist in this namespace. A held lock still protects it.
        live = directory / ".scu-stage-2147483647-ABCDEF"
        live.mkdir(mode=0o700); (live / "1").write_bytes(b"live staged bytes")
        with (live / ".owner").open("wb") as owner:
            fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.run_scu("relv")
            self.assertEqual((live / "1").read_bytes(), b"live staged bytes")
        self.run_scu("relv")
        self.assertFalse(live.exists())
        # An unrelated live PID no longer prevents stale cleanup.
        stale = directory / f".scu-stage-{os.getpid()}-ABCDEF"
        stale.mkdir(mode=0o700); (stale / ".owner").touch(); (stale / "1").write_bytes(b"stale")
        self.run_scu("relv")
        self.assertFalse(stale.exists())
        legacy = directory / ".scu-stage-2147483647-LEGACY"
        legacy.mkdir(); (legacy / "1").write_bytes(b"unknown owner")
        self.run_scu("relv")
        self.assertTrue((legacy / "1").exists())
        atomic = directory / ".scu-tmp-2147483647-ABCDEF"
        with atomic.open("wb") as temporary:
            temporary.write(b"active atomic write"); temporary.flush()
            fcntl.flock(temporary, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.run_scu("relv")
            self.assertTrue(atomic.exists())
        self.run_scu("relv")
        self.assertFalse(atomic.exists())

    def test_review_b_m27_pattern_recovery_failure_retains_original_diagnostic(self):
        editor = self.root / "invalid-editor.py"
        editor.write_text("import pathlib,sys; pathlib.Path(sys.argv[-1]).write_text('../bad\\n')")
        self.run_scu("conl", "editor=" + json.dumps([sys.executable, str(editor)]))
        shim = self.review_shim("recovery_failure", r'''
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <string.h>
char *mkdtemp(char *pattern) {
  static char *(*next)(char *);
  if (!next) next=dlsym(RTLD_NEXT,"mkdtemp");
  if (strstr(pattern,"scu-patterns-recovery")) {errno=ENOSPC;return 0;}
  return next(pattern);
}
''')
        result = subprocess.run([SCU, "edifp"], cwd=self.root, capture_output=True, text=True,
                                timeout=10, env=dict(os.environ, LD_PRELOAD=str(shim)))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("parent-directory", result.stderr)
        self.assertIn("Could not preserve edited patterns", result.stderr)
        self.assertIn("No space left", result.stderr)

    def test_review_b_last_modified_output_selector_preserves_source_case(self):
        (self.root / "Main.pas").write_bytes(b"source")
        self.run_scu("impd", "main.pas", "Main.pas")
        self.run_scu("extd", "output_file=scu$last_modified_deck", "build=no")
        self.assertFalse((self.root / "main.pas").exists())
        self.assertEqual((self.root / "Main.pas").read_bytes(), b"source")


    def test_review_b_d3_unified_help_requires_exact_whitespace_for_patch(self):
        help_text = self.run_scu("disc", "disvd")
        self.assertIn("output_format=unified ignore_space_changes=no", help_text)
        self.assertIn("does not guarantee reconstruction of the target bytes", help_text)
        self.store("main", b"first  line\n")
        self.run_scu("locv", "Before"); self.run_scu("crev", "1.1")
        self.store("main", b"first    line\n")
        self.assertEqual(self.run_scu("disvd", "of=unified"), "")
        self.assertIn("-first  line", self.run_scu("disvd", "of=unified", "isc=no"))

    def make_old_importer_fixture(self):
        (self.root / "0").write_bytes(b"first")
        self.run_scu("impd", "first.pas", "0")
        (self.root / "0").write_bytes(b"second")
        self.run_scu("impd", "second.pas", "0")
        (self.root / "manifest.json").write_text(json.dumps({
            "format": 1, "source_archive": "ARCHIVE", "history": [], "files": []}))
        self.run_scu("impd", "scu-import-manifest.json", "manifest.json")
        self.run_scu("locv", "Old import"); self.run_scu("crev", "1.1")

    def test_review_c_x21_deleted_or_recreated_provenance_still_guards_library(self):
        self.make_old_importer_fixture()
        self.run_scu("deld", "scu-import-manifest.json")
        self.run_scu("deld", "second.pas")
        for stage in ("deleted", "recreated"):
            if stage == "recreated":
                (self.root / "scu-import-manifest.json").write_text("ordinary replacement")
                self.run_scu("impd", "scu-import-manifest.json", "scu-import-manifest.json")
            before = self.read_library()["revisions"]
            for command in (("extv", "build=no"), ("relv",), ("extd", "first.pas"), ("verd",),
                            ("disvd", "of=unified")):
                with self.subTest(stage=stage, command=command):
                    self.run_scu(*command, error="old importer with temporary source filenames")
            self.assertEqual(self.read_library()["revisions"], before)
            self.assertFalse((self.root / "release/0").exists())
            self.run_scu("extd", "first.pas", "of=rescue.pas", "build=no")
            self.assertEqual((self.root / "rescue.pas").read_bytes(), b"first")
        self.run_scu("verat")

    def test_review_c_old_importer_default_import_reports_rebuild(self):
        self.make_old_importer_fixture()
        self.run_scu("deld", "scu-import-manifest.json")
        (self.root / "0").unlink()
        self.run_scu("impd", "first.pas", error="old importer with temporary source filenames")
        # Explicit source selection is still available for deliberate repair/rescue.
        (self.root / "First.pas").write_bytes(b"new source")
        self.run_scu("impd", "first.pas", "First.pas")
        self.run_scu("extd", "first.pas", "of=rescue.pas", "build=no")
        self.assertEqual((self.root / "rescue.pas").read_bytes(), b"new source")
        self.run_scu("verat")

    def test_review_c_x20_read_only_stale_temporaries_are_removed(self):
        self.store("main", b"source")
        directory = self.root / "release"
        directory.mkdir()
        paths = [directory / f".scu-tmp-{os.getpid()}-{suffix}" for suffix in ("READON", "WRITAB")]
        for path, mode in zip(paths, (0o444, 0o644)):
            path.write_bytes(b"stale"); path.chmod(mode)
        # A read-only ownership marker also permits stale-stage cleanup.
        stage = directory / f".scu-stage-{os.getpid()}-ABCDEF"
        stage.mkdir(mode=0o700)
        (stage / ".owner").touch(mode=0o400)
        (stage / "1").write_bytes(b"stale staged bytes")
        self.run_scu("relv")
        self.assertTrue(all(not path.exists() for path in paths))
        self.assertFalse(stage.exists())
        self.run_scu("relv")
        self.assertIn("No errors were found", self.run_scu("verd"))

    def test_review_c_x19_real_scu_holds_stage_lock_until_killed(self):
        self.store("main", b"staged source")
        directory = self.root / "release"
        ready = self.root / "stage-ready"
        shim = self.review_shim("pause_staged_scu", r'''
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int mkstemp(char *pattern) {
  static int (*next)(char *); static int paused;
  if (!next) next=dlsym(RTLD_NEXT,"mkstemp");
  const char *directory=getenv("SCU_TEST_DIRECTORY"), *ready=getenv("SCU_TEST_READY");
  if (!paused && directory && ready && !strncmp(pattern,directory,strlen(directory)) &&
      !strncmp(pattern+strlen(directory),"/.scu-tmp-",10)) {
    paused=1; int fd=open(ready,O_WRONLY|O_CREAT,0600); if(fd>=0) close(fd);
    raise(SIGSTOP);
  }
  return next(pattern);
}
''')
        first = subprocess.Popen([SCU, "relv"], cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 env=dict(os.environ, LD_PRELOAD=str(shim), SCU_TEST_DIRECTORY=str(directory),
                                          SCU_TEST_READY=str(ready)))
        second = None
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and first.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(ready.exists(), "SCU did not reach the staged-publication pause")
            stages = list(directory.glob(".scu-stage-*"))
            self.assertEqual(len(stages), 1)
            self.assertEqual((stages[0] / "1").read_bytes(), b"staged source")
            with (stages[0] / ".owner").open("rb") as owner:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
            second = subprocess.Popen([SCU, "relv"], cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            time.sleep(0.1)
            self.assertIsNone(second.poll())
            self.assertTrue((stages[0] / "1").exists())
            first.kill(); first.communicate(timeout=5)
            output, error = second.communicate(timeout=10)
            self.assertEqual(second.returncode, 0, error)
            self.assertEqual(list(directory.glob(".scu-stage-*")), [])
            self.assertEqual((directory / "main").read_bytes(), b"staged source")
            self.assertIn("No errors were found", self.run_scu("verd"))
            self.run_scu("verat")
        finally:
            for process in (first, second):
                if process is not None:
                    if process.poll() is None: process.kill()
                    process.communicate(timeout=5)

    def test_review_c_filename_notices_escape_line_breaks(self):
        source = self.root / "source\nname.pas"
        source.write_bytes(b"source")
        self.run_scu("impd", "main.pas", "source_file=" + source.name)
        result = self.run_scu("deld", "main.pas")
        self.assertIn('source\\nname.pas" kept;', result)
        self.assertNotIn("source\nname.pas", result)
        self.configure_file_patterns(["*.pas"])
        (self.root / "release").mkdir()
        (self.root / "release" / source.name).write_bytes(b"untracked")
        result = self.run_scu("relv")
        self.assertIn('Kept untracked release file "source\\nname.pas"', result)
        self.assertNotIn("source\nname.pas", result)


    def test_configure_library_file_patterns_json_and_atomic_validation(self):
        empty_patterns = r"(?m)^file_patterns +\(not set\)$"
        self.assertRegex(self.run_scu("disl"), empty_patterns)
        self.run_scu("conl", 'file_patterns=["*.pas","Makefile"]', "build_command=original")
        header = json.loads(self.run_scu("disl", "j=y"))
        self.assertEqual(header["file_patterns"], ["*.pas", "Makefile"])
        for value, error in (('{}', 'JSON array'), ('[1]', 'only strings'),
                             ('["../bad"]', 'parent-directory')):
            with self.subTest(value=value):
                self.run_scu("conl", "file_patterns=" + value, "build_command=changed", error=error)
                self.assertEqual(json.loads(self.run_scu("disl", "j=y")), header)
        self.run_scu("conl", "fp=[]")
        self.assertRegex(self.run_scu("disl"), empty_patterns)
        self.assertEqual(json.loads(self.run_scu("disl", "j=y"))["file_patterns"], [])
        self.run_scu("verat")

    def test_configure_library_file_patterns_can_change_while_version_locked(self):
        self.store("main.pas", b"source")
        self.run_scu("locv", "Lock before configuring monitoring")
        self.run_scu("conl", 'file_patterns=["*.pas"]')
        self.assertEqual(json.loads(self.run_scu("disl", "j=y"))["file_patterns"], ["*.pas"])
        self.assertEqual(len(self.read_library()["revisions"]), 1)
        self.run_scu("verat")


if __name__ == "__main__":
    unittest.main()
