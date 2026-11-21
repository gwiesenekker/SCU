"""Shared CLI integration tests: native Linux/Windows, or a Win64 CLI under Wine.

The Linux integration runner inherits this class. Keep terminal/job-control and
POSIX filesystem tests in integration.py; no Unix-only imports belong here.
"""
from contextlib import closing
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest

SCU = Path(__file__).resolve().parents[1] / 'build' / ('scu.exe' if os.name == 'nt' else 'scu')
WINE = False
WINE_EXECUTABLE = None


def configure(executable, wine=False):
    global SCU, WINE, WINE_EXECUTABLE
    SCU, WINE = Path(executable).resolve(), wine
    WINE_EXECUTABLE = shutil.which('wine') if wine else None
    if wine and not WINE_EXECUTABLE:
        raise ValueError('Wine is not installed or is not on PATH')


class PortableCliTests(unittest.TestCase):
    @staticmethod
    def local_stamp(value):
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone().isoformat(timespec="milliseconds")

    def argument(self, value):
        if WINE:
            if isinstance(value, Path):
                return 'Z:' + str(value.absolute()).replace('/', '\\')
            # Named arguments in shared tests may embed paths rather than carry
            # a Path object. Only translate this test's private root.
            return str(value).replace(str(self.root), 'Z:' + str(self.root).replace('/', '\\'))
        return str(value)

    def invoke(self, command, **kwargs):
        executable, *arguments = command
        command = ([WINE_EXECUTABLE, str(executable)] if WINE else [str(executable)])
        command += [self.argument(value) for value in arguments]
        if kwargs.get('text') and (WINE or os.name == 'nt'):
            kwargs.setdefault('encoding', 'utf-8')
        if WINE and 'input' in kwargs:
            if not str(executable).isascii() or not str(self.root).isascii():
                raise ValueError('Wine batch checks need ASCII executable/temporary-directory paths; native Windows has no such test limitation')
            # Wine's Unix stdin bridge cannot reliably PeekNamedPipe host pipes.
            # Feed the very same batch through a Windows-opened disk handle;
            # native Windows still exercises subprocess's real anonymous pipe.
            data = kwargs.pop('input')
            if isinstance(data, str):
                data = data.encode(kwargs.get('encoding') or 'utf-8')
            with tempfile.TemporaryDirectory(prefix='stdin-', dir=self.root) as directory:
                source = Path(directory) / 'commands.txt'
                source.write_bytes(data)
                values = [self.argument(Path(executable)), *command[2:]]
                if any(any(c in value for c in '%&|<>^') for value in values):
                    raise ValueError('Wine input adapter accepts only literal fixture arguments')
                line = subprocess.list2cmdline(values) + ' <' + subprocess.list2cmdline([self.argument(source)])
                # A command file avoids Wine's extra /c quote escaping for
                # quoted executable paths. Keep its encoding explicit.
                wrapper = Path(directory) / 'run.cmd'
                wrapper.write_bytes(('@echo off\r\nchcp 65001>nul\r\n' + line + '\r\n').encode('utf-8'))
                command = [WINE_EXECUTABLE, 'cmd', '/d', '/v:off', '/c', self.argument(wrapper)]
                return subprocess.run(command, **kwargs)
        return subprocess.run(command, **kwargs)

    def diff_environment(self):
        directory = self.root / 'unavailable'
        if WINE or os.name == 'nt':
            return dict(os.environ, PATH='', TEMP=self.argument(directory), TMP=self.argument(directory))
        return dict(os.environ, PATH='', TMPDIR=str(directory))

    def run_scu(self, *arguments, error=None, executable=None):
        result = self.invoke(
            [executable or SCU, *arguments], cwd=self.root, capture_output=True, text=True, timeout=30
        )
        if error is None:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn(error, result.stderr)
        return result.stdout.strip()

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.library = self.root / "library.sqlite"
        self.run_scu(self.library, "inil")


    @staticmethod
    def table_data(output):
        """Read aligned table cells for tests concerned with command semantics."""
        lines = output.splitlines()
        if not lines or lines[0] == "No expansion checkpoints.":
            return output
        columns = re.split(r" {2,}", lines[0])
        positions, start = [], 0
        for column in columns:
            start = lines[0].index(column, start)
            positions.append(start)
            start += len(column)
        return "\n".join("\t".join(line[start:end].rstrip() for start, end in
                         zip(positions, positions[1:] + [None])) for line in lines[1:])


    def store(self, name, source, *options):
        # Library fixtures have no persistent working files. Real import workflows
        # below use run_scu directly and exercise their manifest observations.
        (self.root / "input").write_bytes(source)
        path = self.root / name
        previous = path.read_bytes() if path.exists() else None
        manifest = self.root / ".scu-exports.json"
        tracking = manifest.read_bytes() if manifest.exists() else None
        path.write_bytes(source)
        try:
            self.run_scu("import_deck", name, path.name, *options)
        finally:
            if previous is None: path.unlink(missing_ok=True)
            else: path.write_bytes(previous)
            if tracking is None: manifest.unlink(missing_ok=True)
            else: manifest.write_bytes(tracking)


    def read_library(self):
        with closing(sqlite3.connect(self.library)) as database:
            metadata, = database.execute("SELECT payload FROM library WHERE id = 1").fetchone()
            document = json.loads(metadata)
            document["revisions"] = [json.loads(payload) for payload, in database.execute(
                "SELECT payload FROM deck_revisions ORDER BY sequence"
            )]
            return document


    def write_library(self, document):
        metadata = {name: value for name, value in document.items() if name != "revisions"}
        with closing(sqlite3.connect(self.library)) as database, database:
            database.execute("UPDATE library SET payload = ? WHERE id = 1", (json.dumps(metadata),))
            database.executemany("UPDATE deck_revisions SET payload = ? WHERE sequence = ?", (
                (json.dumps(entry), index) for index, entry in enumerate(document["revisions"], start=1)
            ))


    def audit_lines(self, path=None):
        with closing(sqlite3.connect(path or self.library)) as database:
            return [line.encode() for line, in database.execute("SELECT line FROM audit_records ORDER BY sequence")]


    def test_creation_platform_and_cross_platform_filename_warnings(self):
        host = "Windows" if WINE or os.name == "nt" else "Linux"
        foreign = "Linux" if host == "Windows" else "Windows"
        self.assertEqual(self.read_library()["header"]["platform"], host)
        for name in ("Makefile", "makefile", "MAKEFILE", "ordinary", "gone"):
            self.run_scu("cred", name)
        self.run_scu("deld", "gone")
        self.run_scu("locv", "First")
        self.run_scu("crev", "1.1")
        self.assertNotIn("Warning", self.run_scu("disl"))
        document = self.read_library()
        document["header"]["platform"] = foreign
        recovery = self.root / "foreign.json"
        recovery.write_text(json.dumps(document))
        restored = self.root / "foreign.sqlite"
        self.run_scu(restored, "recl", recovery)
        output = self.run_scu(restored, "disl")
        warnings = [line for line in output.splitlines() if line.startswith("Warning")]
        self.assertEqual(len(warnings), 3)
        for name in ("Makefile", "makefile", "MAKEFILE"):
            self.assertTrue(any(f'deck "{name}", file "{name}"' in w for w in warnings))
        self.assertEqual(json.loads(self.run_scu(restored, "disl", "json=yes"))["platform"], foreign)
        self.run_scu(restored, "verat")

        del document["header"]["platform"]
        recovery.write_text(json.dumps(document))
        legacy = self.root / "legacy.sqlite"
        self.run_scu(legacy, "recl", recovery)
        self.assertRegex(self.run_scu(legacy, "disl"), r"(?m)^platform +unknown$")
        self.assertNotIn("platform", json.loads(self.run_scu(legacy, "disl", "json=yes")))
        self.run_scu(legacy, "verat")

    def test_configure_creation_platform_once_on_locked_legacy_library(self):
        self.run_scu("cred", "main")
        self.run_scu("locv", "Imported")
        document = self.read_library()
        del document["header"]["platform"]
        recovery = self.root / "legacy.json"
        recovery.write_text(json.dumps(document))
        for platform in ("Linux", "Windows", "macOS"):
            with self.subTest(platform=platform):
                if platform == "macOS":
                    document["header"]["platform"] = "unknown"
                    recovery.write_text(json.dumps(document))
                library = self.root / (platform + ".sqlite")
                self.run_scu(library, "recl", recovery)
                self.run_scu(library, "conl", "platform=unknown", error="platform")
                self.run_scu(library, "conl", "p=" + platform.upper())
                events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines(library)]
                self.assertTrue(any(event.get("command") == "configure_library" and
                                    event.get("parameters") == {"platform": platform} for event in events))
                header = json.loads(self.run_scu(library, "disl", "j=y"))
                self.assertEqual(header, dict(document["header"], platform=platform))
                self.run_scu(library, "conl", "bc=changed", "platform=Linux", error="already recorded")
                self.assertEqual(json.loads(self.run_scu(library, "disl", "j=y")), header)
                self.run_scu(library, "verat")

    def test_version_tracker_expands_for_single_and_version_extractions(self):
        self.store("main.c", b"/* SCU$VERSION */")
        self.run_scu("conl", "vt=version.h", 'fp=["*.c","*.h"]')
        self.run_scu("locv", "Initial")
        self.run_scu("crev", "1.1")
        expanded = "version.h has been expanded"
        ignored = "version.h has been ignored (version tracker)"
        self.assertIn(expanded, self.run_scu("extd", "main.c"))
        header = self.root / "version.h"
        self.assertIn(b'#define PROJECT_VERSION "1.1"', header.read_bytes())
        self.assertEqual((self.root / "main.c").read_bytes(), b"/* SCU$VERSION */")
        stamp = header.stat().st_mtime_ns
        for args in [("extd", "main.c"), ("extv",)]:
            result = self.run_scu(*args)
            self.assertIn("version.h is unchanged", result.splitlines())
            self.assertNotIn(expanded, result)
            self.assertEqual(header.stat().st_mtime_ns, stamp)
        result = self.run_scu("extd", "version.h", "of=alternate.h")
        self.assertIn("alternate.h has been expanded", result.splitlines())
        self.assertIn("version.h is unchanged", result.splitlines())
        self.assertIn(expanded, self.run_scu("relv", "v=1.0"))
        self.assertIn("version.h is unchanged", self.run_scu("relv", "v=1.0").splitlines())
        self.assertIn(b'"1.0"', (self.root / "release/version.h").read_bytes())
        header.write_bytes(b"hand edited")
        for args in [("impd",), ("impd", "version.h"), ("verd", "od=.")]:
            self.assertIn(ignored, self.run_scu(*args))
        self.assertEqual(header.read_bytes(), b"hand edited")
        self.run_scu("extv", error="require overwrite=yes")
        self.assertIn(expanded, self.run_scu("extd", "version.h", "v=1.0", "o=y"))
        self.assertIn(b'"1.0"', header.read_bytes())
        self.assertNotIn("version.h", self.run_scu("disdl"))
        self.assertEqual(len(self.read_library()["revisions"]), 1)
        self.run_scu("conl", "vt=")
        self.assertNotIn(expanded, self.run_scu("extv"))
        self.assertIn(ignored, self.run_scu("impd"))
        self.run_scu("verat")

    def test_tracker_with_no_decks_and_name_collision(self):
        self.run_scu("conl", "vt=version.h")
        self.assertIn("version.h has been expanded", self.run_scu("extd"))
        self.assertIn("Wrote 0 deck(s)", self.run_scu("extv"))
        self.run_scu("conl", "vt=")
        self.store("main.c", b"source")
        self.run_scu("conl", "vt=main.c", error="already uses tracker name")

    def test_edit_tracker_persists_multiline_library_metadata(self):
        if WINE:
            self.skipTest("Editor fixture uses native Python")
        editor = self.root / "edit.py"
        template = 'release="SCU$VERSION"\nmodified=SCU$DATE\n'
        editor.write_text("from pathlib import Path\nimport sys\n" +
                          "Path(sys.argv[1]).write_bytes(" + repr(template.encode()) + ")")
        self.run_scu("conl", "vt=version.h", "editor=" + json.dumps([sys.executable, str(editor)]))
        self.run_scu("edivt")
        header = self.read_library()["header"]
        self.assertEqual(header["version_tracker_template"], template)
        self.run_scu("extd")
        expected = template.replace("SCU$VERSION", "1.0").replace("SCU$DATE", header["version_tracker_modified_utc"][:10])
        self.assertEqual((self.root / "version.h").read_bytes(), expected.encode())
        self.run_scu("verat")

    def test_invalid_tracker_template_rolls_back_pattern_change(self):
        invalid = self.root / "invalid.txt"
        invalid.write_bytes(b"bad" + bytes([0]) + b"template")
        before = self.read_library()["header"]
        self.run_scu("conl", 'fp=["*.h"]', "vt=version.h", "ttf=invalid.txt", error="UTF-8")
        self.assertEqual(self.read_library()["header"], before)
        self.run_scu("verat")

    def test_initialize_library_accepts_a_custom_initial_version(self):
        path = self.root / "custom.sqlite"
        self.assertEqual(self.run_scu(path, "inil", "v=0.003"), "Initialized version 0.003")
        self.run_scu(path, "cred", "main")
        self.assertEqual(self.table_data(self.run_scu(path, "disdl")), "main\t0.003-0.000")
        self.run_scu(path, "verify_audit_trail")
        self.run_scu(self.root / "invalid.sqlite", "inil", "v=invalid", error="Invalid version")


    def test_delete_deck_records_history_and_preserves_earlier_source(self):
        self.store("main.pas", b"original\n", "cp=#")
        source = self.read_library()["revisions"][0]
        self.assertIn("Deleted main.pas version 1.0 revision 0.001", self.run_scu("deld", "dn=main.pas"))
        self.assertEqual(self.table_data(self.run_scu("disdl")), "")
        document = self.read_library()
        self.assertEqual(document["revisions"][0], source)
        tombstone = document["revisions"][1]
        self.assertIs(tombstone["deleted"], True)
        self.assertEqual(tombstone["deck_revision"], "0.001")
        self.assertEqual(tombstone["size"], 0)
        self.assertEqual(tombstone["comment_prefix"], "#")
        self.assertEqual(document["header"]["last_modified_deck"], "main.pas")
        history = self.run_scu("disd").splitlines()
        self.assertTrue(history[2].startswith("1.0-0.001 ") and history[2].endswith("  deleted"), history)
        self.assertTrue(history[3].startswith("1.0-0.000 "), history)
        for command in ("extd",):
            self.run_scu(command, "main.pas", "output", error='does not exist in version 1.0')
            self.assertFalse((self.root / "output").exists())
            self.run_scu(command, "main.pas", "old", "v=1.0-0.000")
            self.assertEqual((self.root / "old").read_bytes(), b"original\n")
            self.run_scu(command, "main.pas", "output", "r=0.001", error="is deleted at deck version 1.0-0.001")
        self.run_scu("edid", "main.pas", error='does not exist in version 1.0')
        before = self.read_library()
        self.run_scu("deld", "main.pas", error='does not exist in version 1.0')
        self.run_scu("deld", "unknown", error='does not exist in version 1.0')
        self.assertEqual(self.read_library(), before)
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        deletion = next(e for e in events if e.get("command") == "delete_deck")
        self.assertEqual(deletion["parameters"], {"deck_name": "main.pas"})
        self.run_scu("verify_audit_trail")


    def test_deleted_decks_stay_absent_until_recreated_and_follow_revision_numbering(self):
        self.store("main", b"version one\n")
        self.run_scu("locv", "d=First")
        before = self.read_library()
        self.run_scu("deld", "main", error="Version 1.0 is locked")
        self.assertEqual(self.read_library(), before)
        self.run_scu("crev", "1.1")
        self.assertIn("revision 0.000", self.run_scu("deld"))
        self.assertEqual(self.table_data(self.run_scu("disdl")), "")
        self.assertIn("main\t1.0-0.000", self.table_data(self.run_scu("disdl", "v=1.0")))
        self.run_scu("extd", "main", "old", "v=1.0")
        self.assertEqual((self.root / "old").read_bytes(), b"version one\n")
        self.run_scu("locv", "d=Removed")
        self.run_scu("crev", "1.2")
        self.assertEqual(self.table_data(self.run_scu("disdl")), "")
        self.assertIn("revision 0.000", self.run_scu("cred", "main"))
        self.assertEqual(self.table_data(self.run_scu("disdl")), "main\t1.2-0.000")
        self.run_scu("deld", "main")
        self.assertIn("revision 0.002", self.run_scu("cred", "main"))
        self.run_scu("deld", "main")
        self.store("main", b"recreated by store\n")
        self.assertEqual(self.read_library()["revisions"][-1]["deck_revision"], "0.004")
        self.assertEqual(self.table_data(self.run_scu("disdl", "v=1.1")), "")
        self.run_scu("verify_audit_trail")


    def test_delete_and_recreate_require_a_new_version_at_revision_limit(self):
        self.run_scu("conl", "ri=0.999")
        self.store("main", b"original")
        self.store("main", b"changed")
        before = self.read_library()
        self.run_scu("deld", "main", error='has reached the revision limit')
        self.assertEqual(self.read_library(), before)
        self.run_scu("locv", "d=Full")
        self.run_scu("crev", "1.1")
        self.assertIn("revision 0.000", self.run_scu("deld", "main"))
        self.assertIn("revision 0.999", self.run_scu("cred", "main"))
        self.run_scu("deld", "main", error='has reached the revision limit')
        self.run_scu("verify_audit_trail")


    def test_deletion_and_recreation_diffs_use_missing_file_endpoints(self):
        self.store("main", b"original\n")
        self.run_scu("cred", "empty")
        self.run_scu("locv", "d=First")
        self.run_scu("crev", "1.1")
        self.run_scu("deld", "main")
        self.run_scu("deld", "empty")
        diff = self.run_scu("disdd", "main", "output_format=unified")
        self.assertIn("--- main@1.0-0.000\n+++ /dev/null", diff)
        self.assertIn("-original", diff)
        self.assertEqual(self.run_scu("disdd", "empty", "output_format=unified"), "Deleted empty deck empty")
        diff = self.run_scu("disvd", "output_format=unified")
        self.assertIn("Only in version 1.0: empty (empty deck)", diff)
        self.assertIn("+++ /dev/null", diff)
        self.run_scu("locv", "d=Removed")
        self.run_scu("crev", "1.2")
        self.run_scu("locv", "d=Still absent")
        self.run_scu("crev", "1.3")
        self.store("main", b"returned\n")
        self.run_scu("cred", "empty")
        diff = self.run_scu("disdd", "main", "output_format=unified")
        self.assertIn("--- /dev/null\n+++ main@1.3-0.000", diff)
        self.assertIn("+returned", diff)
        self.assertEqual(self.run_scu("disdd", "empty", "output_format=unified"), "Recreated empty deck empty")
        self.assertIn("--- /dev/null", self.run_scu("disvd", "fv=1.1", "tv=1.3", "output_format=unified"))
        self.assertEqual(self.run_scu("disvd", "fv=1.1", "tv=1.2", "output_format=unified"), "")
        self.assertIn("+++ /dev/null", self.run_scu("disvd", "fv=1.3", "tv=1.1", "output_format=unified"))


    def test_deletion_audit_failure_rolls_back_revision_header_and_audit(self):
        self.store("main", b"original")
        with closing(sqlite3.connect(self.library, isolation_level=None)) as database:
            before = self.sqlite_state(database)
            state = database.execute("SELECT * FROM audit_state").fetchall()
            database.executescript("""
                CREATE TRIGGER fail_deletion_audit BEFORE INSERT ON audit_records
                WHEN json_extract(substr(NEW.line, 66), '$.phase') = 'end'
                 AND json_extract(substr(NEW.line, 66), '$.success') = 1
                 AND EXISTS (SELECT 1 FROM deck_revisions WHERE deleted = 1)
                BEGIN SELECT RAISE(ABORT, 'injected deletion audit failure'); END;
            """)
            self.run_scu("deld", "main", error="injected deletion audit failure")
            self.assertEqual(self.sqlite_state(database), before)
            self.assertEqual(database.execute("SELECT * FROM audit_state").fetchall(), state)
            database.execute("DROP TRIGGER fail_deletion_audit")
        self.assertIn("main\t", self.table_data(self.run_scu("disdl")))
        self.run_scu("deld", "main")
        self.run_scu("verify_audit_trail")


    def test_full_audit_detects_tampered_deletion_index(self):
        self.store("main", b"original")
        self.run_scu("deld", "main")
        with closing(sqlite3.connect(self.library, isolation_level=None)) as database:
            database.execute("UPDATE deck_revisions SET deleted = 0 WHERE sequence = 2")
        self.run_scu("verify_audit_trail", error="SQLite deletion flag does not match revision 2")


    def test_all_command_parameters_share_one_ordered_argument_list(self):
        catalog = json.loads(SCU.with_name("commands.json").read_bytes())
        self.assertEqual(catalog["format"], 4)
        for command in catalog["commands"]:
            self.assertNotIn("options", command)
            self.assertNotIn("exclusive_options", command)
        self.store("main", b"first\n")
        self.store("main", b"second\n")
        self.run_scu("extd", "main", "expanded", "build=n")
        event = json.loads(self.audit_lines()[-2].split(b" ", 1)[1])
        self.assertEqual(event["parameters"], {"deck_name": "main", "output_file": "expanded", "build": "no", "version": "scu$current_version", "overwrite": "no"})
        self.assertNotIn("options", event)
        self.assertEqual(event["provided_arguments"], ["deck_name", "output_file", "build"])
        self.run_scu("extd", "main", "original", "0.000")
        self.assertEqual((self.root / "original").read_bytes(), b"first\n")
        self.run_scu("extd", "--dn", "main", "--output_file", "named", "--revision=0.000")
        self.assertEqual((self.root / "named").read_bytes(), b"first\n")
        self.run_scu("extd", "main", "bad", "0.999", "version=1.0", error="has no deck version")
        self.assertFalse((self.root / "bad").exists())
        self.run_scu("conl", "true")
        self.assertEqual(json.loads(self.run_scu("disl", "j=y"))["build_command"], "true")
        self.run_scu("verify_audit_trail")


    def test_optional_arguments_are_absent_but_explicit_empty_values_and_defaults_are_audited(self):
        self.run_scu("cred", "main")
        event = json.loads(self.audit_lines()[-2].split(b" ", 1)[1])
        self.assertEqual(event["parameters"], {"deck_name": "main"})
        self.assertEqual(event["provided_arguments"], ["deck_name"])
        self.run_scu("cred", "empty", "")
        event = json.loads(self.audit_lines()[-2].split(b" ", 1)[1])
        self.assertEqual(event["parameters"], {"deck_name": "empty", "from_file": ""})
        self.assertEqual(event["provided_arguments"], ["deck_name", "from_file"])
        self.run_scu("extd", "main", "out")
        event = json.loads(self.audit_lines()[-2].split(b" ", 1)[1])
        self.assertEqual(event["parameters"]["build"], "yes")
        self.assertNotIn("build", event["provided_arguments"])
        self.assertNotIn("revision", event["parameters"])
        self.assertEqual(event["parameters"]["version"], "scu$current_version")
        self.run_scu("verify_audit_trail")


    def test_deck_history_has_headers_deck_versions_and_aligned_status_columns(self):
        self.store("main", b"original")
        self.store("main", b"edited")
        self.run_scu("deld", "main")
        self.run_scu("locv", "d=First")
        self.run_scu("crev", "123456789.1234567890")
        self.run_scu("cred", "main")
        before = self.read_library()
        result = self.run_scu("disd", "main")
        self.assertNotIn("\t", result)
        self.assertNotIn("Library revision", result)
        self.assertEqual(result.splitlines()[0], 'Deck "main".')
        lines = result.splitlines()[1:]
        rows = [re.split(r" {2,}", line) for line in lines]
        self.assertEqual(rows[0], ["Deck version", "Modified (local TZ)", "Status"])
        self.assertEqual([row[0] for row in rows[1:]],
                         ["123456789.1234567890-0.000", "1.0-0.002", "1.0-0.001", "1.0-0.000"])
        self.assertEqual([row[2] for row in rows[1:]], ["stored", "deleted", "stored", "stored"])
        for index, payload in enumerate(reversed(before["revisions"]), start=1):
            self.assertEqual(rows[index][1], self.local_stamp(payload["modified_utc"]))
        for column in (1, 2):
            positions = [line.index(row[column]) for line, row in zip(lines, rows)]
            self.assertEqual(len(set(positions)), 1)
        self.assertEqual(self.read_library(), before)
        self.run_scu("verify_audit_trail")


    def test_display_version_lists_latest_changes_only_in_the_selected_version(self):
        for name in ("inherited", "main", "removed", "recreated"):
            self.store(name, b"original")
        self.run_scu("locv", "d=First")
        self.run_scu("crev", "1.1")
        self.store("main", b"changed")
        self.store("main", b"original")  # A recorded edit still counts after reverting bytes.
        self.run_scu("deld", "removed")
        self.run_scu("deld", "recreated")
        self.run_scu("cred", "recreated")
        self.store("new", b"new")
        self.run_scu("cred", "transient")
        self.run_scu("deld", "transient")
        before = self.read_library()
        output = self.run_scu("disv")
        title, table = output.split("\n", 1)
        self.assertEqual(title, 'Version "1.1".')
        self.assertNotIn("\t", output)
        self.assertEqual(re.split(r" {2,}", table.splitlines()[0]),
                         ["Deck name", "Deck version", "Modified (local TZ)", "Status"])
        rows = [row.split("\t") for row in self.table_data(table).splitlines()]
        self.assertEqual([(r[0], r[1], r[3]) for r in rows], [
            ("main", "1.1-0.001", "stored"),
            ("new", "1.1-0.000", "stored"),
            ("recreated", "1.1-0.001", "stored"),
            ("removed", "1.1-0.000", "deleted"),
            ("transient", "1.1-0.001", "deleted"),
        ])
        for row in rows:
            revision = next(r for r in reversed(before["revisions"]) if r["deck"] == row[0])
            self.assertEqual(row[2], self.local_stamp(revision["modified_utc"]))
        for arguments in (("display_version", "1.1"), ("disv", "v=1.1"),
                          ("disv", "--version", "1.1")):
            self.assertEqual(self.run_scu(*arguments), output)
        self.assertEqual(self.read_library(), before)
        self.run_scu("locv", "d=Second")
        self.run_scu("crev", "1.2")
        self.run_scu("cred", "removed")
        self.assertEqual(self.run_scu("disv", "1.1"), output)
        self.assertEqual(self.run_scu("disv", "v=scu$previous_version"), output)
        self.assertNotIn("inherited", self.run_scu("disv"))
        self.run_scu("verify_audit_trail")


    def test_create_version_canonical_name_abbreviation_and_retired_names(self):
        for retired in ("start_version", "stav"):
            before = self.audit_lines()
            self.run_scu(retired, "1.1", error="Unknown command")
            self.assertEqual(self.audit_lines(), before)
        self.run_scu("locv", "d=First")
        self.assertEqual(self.run_scu("create_version", "v=1.1"), "Created version 1.1")
        self.run_scu("locv", "d=Second")
        self.assertEqual(self.run_scu("crev"), "Created version 1.11")
        self.assertEqual(self.read_library()["header"]["current_version"], "1.11")
        self.assertIn("create_version, crev", self.run_scu("disc", "crev"))
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        creates = [event for event in events if event.get("command") == "create_version"]
        self.assertEqual(len(creates), 2)
        self.assertEqual(creates[0]["parameters"], {"version": "1.1"})
        self.assertEqual(creates[1]["parameters"], {})
        self.run_scu("verify_audit_trail")


    def test_deck_history_identifies_explicit_default_and_deleted_decks(self):
        self.store("main.pas", b"main")
        self.store("other.pas", b"other")
        self.assertEqual(self.run_scu("disd", "dn=main.pas").splitlines()[0], 'Deck "main.pas".')
        self.assertEqual(self.run_scu("disd").splitlines()[0], 'Deck "other.pas".')
        self.run_scu("deld", "main.pas")
        history = self.run_scu("disd")
        self.assertEqual(history.splitlines()[0], 'Deck "main.pas".')
        self.assertIn("deleted", history)
        self.assertEqual(self.run_scu("disd", "missing", error='does not exist'), "")
        self.run_scu("verify_audit_trail")


    def test_deck_list_has_aligned_headers_inherited_versions_and_empty_snapshots(self):
        self.assertEqual(self.run_scu("disdl"), "Deck name  Deck version")
        self.store("a", b"first")
        self.store("long-deck-name.pas", b"second")
        self.run_scu("locv", "d=First")
        self.run_scu("crev", "123456789.1234567890")
        self.store("a", b"changed")
        self.run_scu("cred", "gone")
        self.run_scu("deld", "gone")
        result = self.run_scu("disdl")
        self.assertEqual(result.splitlines(), [
            "Deck name           Deck version",
            "a                   123456789.1234567890-0.000",
            "long-deck-name.pas  1.0-0.000",
        ])
        self.run_scu("disdl", "--revision", "0", error="Unknown argument")
        inherited = self.run_scu("disdl", "v=1.0")
        self.assertIn("a                   1.0-0.000", inherited)
        self.assertNotIn("\t", result)
        self.run_scu("verify_audit_trail")


    def test_deck_history_limit_defaults_aliases_boundaries_and_auditing(self):
        for revision in range(12):
            self.store("main", str(revision).encode())
        self.run_scu("deld", "main")
        self.run_scu("locv", "d=First")
        self.run_scu("crev", "1.1")
        self.run_scu("cred", "main")
        full = self.run_scu("disd", "main", "limit=0").splitlines()
        self.assertEqual(len(full), 16)
        self.assertEqual(full[2].split()[0], "1.1-0.000")
        self.assertIn("deleted", full[3])
        self.assertEqual(self.run_scu("disd").splitlines(), full[:12])
        for arguments in (("main", "3"), ("dn=main", "l=3"),
                          ("--deck_name", "main", "--limit", "3")):
            self.assertEqual(self.run_scu("disd", *arguments).splitlines(), full[:5])
        self.assertEqual(self.run_scu("disd", "main", "l=9223372036854775807").splitlines(), full)
        self.run_scu("disd", "main", "l=-1", error="nonnegative integer for limit")
        self.run_scu("disd", "main", "l=bad", error="Expected integer value for limit")
        help_text = self.run_scu("disc", "disd")
        self.assertIn("limit (l) : integer = 10", help_text)
        self.run_scu("disd")
        event = json.loads(self.audit_lines()[-2].split(b" ", 1)[1])
        self.assertEqual(event["parameters"], {"deck_name": "scu$last_modified_deck", "limit": "10"})
        self.assertNotIn("limit", event["provided_arguments"])
        self.run_scu("verify_audit_trail")


    def test_extract_reports_the_resolved_root_deck_name(self):
        self.store("part", b"part")
        self.store("main", b"//SCU_COPY part\n")
        for command in ("extd",):
            for arguments in (("main", "output"), ()):
                with self.subTest(command=command, arguments=arguments):
                    result = self.invoke([SCU, command, *arguments], cwd=self.root,
                                            capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stderr,
                                     'Using library version 1.0, deck "main", deck_version 1.0-0.000.\n')
        self.run_scu("verify_audit_trail")


    def test_extract_reports_writes_and_identical_working_files(self):
        self.store("book.c", b"stored source\n")
        self.store("other.c", b"another deck\n")
        path = self.root / "book.c"
        self.assertIn('Wrote "', self.run_scu("extd", "book.c"))
        timestamp = path.stat().st_mtime_ns
        message = self.run_scu("extd", "book.c")
        self.assertIn('book.c" already matches deck version 1.0-0.000.', message)
        self.assertEqual(path.stat().st_mtime_ns, timestamp)
        path.write_bytes(b"local edit\n")
        self.run_scu("extd", "book.c", error="Use overwrite=yes")
        self.assertEqual(path.read_bytes(), b"local edit\n")
        self.assertIn('Wrote "', self.run_scu("extd", "book.c", "o=y", "b=n"))
        self.assertEqual(path.read_bytes(), b"stored source\n")

    def standalone_cli(self):
        directory = self.root / 'standalone'
        directory.mkdir()
        executable = directory / SCU.name
        shutil.copy2(SCU, executable)
        return executable

    def test_embedded_catalog_runs_without_adjacent_json_and_ignores_cwd_catalog(self):
        executable = self.standalone_cli()
        expected = self.run_scu('help')
        (self.root / 'commands.json').write_text('{malformed cwd override')
        self.assertEqual(self.run_scu('help', executable=executable), expected)
        self.assertEqual(self.run_scu('disc', 'extv', executable=executable), self.run_scu('disc', 'extv'))
        self.assertFalse(executable.with_name('commands.json').exists())

    def test_adjacent_catalog_overrides_embedded_help_and_invalid_override_is_not_ignored(self):
        executable = self.standalone_cli()
        catalog = json.loads(SCU.with_name('commands.json').read_bytes())
        command = next(c for c in catalog['commands'] if c['name'] == 'display_deck')
        command['help'] = 'External override with Unicode 日本 and quotes "kept".'
        path = executable.with_name('commands.json')
        path.write_text(json.dumps(catalog, ensure_ascii=False), encoding='utf-8')
        self.assertIn(command['help'], self.run_scu('disc', 'disd', executable=executable))
        path.write_text('{invalid override')
        self.run_scu('help', executable=executable, error='Could not load command catalog')
        path.unlink()
        path.mkdir()
        self.run_scu('help', executable=executable, error='Could not load command catalog')
        path.rmdir()
        self.assertEqual(self.run_scu('help', executable=executable), self.run_scu('help'))

    def test_shipped_argument_aliases_use_initials_and_help_matches_catalog(self):
        catalog = json.loads(SCU.with_name('commands.json').read_bytes())
        definitions = [catalog['library_argument'], catalog['batch_argument']]
        for command in catalog['commands']:
            definitions.extend(command.get('arguments', []))
            help_text = self.run_scu('disc', command['name'])
            for parameter in command.get('arguments', []):
                label = parameter['name'] + ' (' + ', '.join(parameter['aliases']) + ')'
                self.assertIn(label + ' : ', help_text)
            spellings = [name.casefold() for parameter in command.get('arguments', [])
                         for name in [parameter['name'], *parameter['aliases']]]
            self.assertEqual(len(spellings), len(set(spellings)), command['name'])
        for parameter in definitions:
            with self.subTest(parameter=parameter['name']):
                self.assertRegex(parameter['name'], r'^[a-z]+(?:_[a-z]+)*$')
                self.assertEqual(parameter['aliases'], [''.join(word[0] for word in parameter['name'].split('_'))])

    def test_extract_aliases_distinguish_output_revision_and_overwrite(self):
        self.store('main.c', b'old\n')
        self.store('main.c', b'new\n')
        directory = self.root / 'output'
        directory.mkdir()
        (directory / 'main.c').write_bytes(b'external edits\n')
        self.run_scu('extv', 'v=1.0', 'od=' + str(directory), 'o=y', 'b=n')
        self.assertEqual((directory / 'main.c').read_bytes(), b'new\n')
        self.run_scu('extd', 'dn=main.c', 'of=' + str(directory / 'main.c'), 'r=0.000', 'o=y', 'b=n')
        self.assertEqual((directory / 'main.c').read_bytes(), b'old\n')
        events = [json.loads(line.split(b' ', 1)[1]) for line in self.audit_lines()]
        command = next(e for e in reversed(events) if e.get('command') == 'extract_deck')
        self.assertEqual(command['parameters']['revision'], '0.000')
        self.assertEqual(command['parameters']['overwrite'], 'yes')
        self.assertNotIn('replace', command['parameters'])
        for option in ['directory=output', 'rp=yes', 'replace=yes']:
            self.run_scu('extv', option, error='Unknown argument')
        self.assertNotIn('replace (', self.run_scu('disc', 'extv'))

    def test_delete_only_an_empty_open_successor(self):
        self.run_scu("delv", "1.0", error="only library version")
        self.store("main", b"preserved")
        self.run_scu("locv", "Baseline")
        original = json.loads(self.run_scu("disl", "j=y"))
        self.run_scu("crev", "8.1307")
        self.run_scu("conl", "cp=#")
        self.run_scu("delv", "1.0", error="Only the current version")
        self.run_scu("delete_version", "v=8.1307")
        self.assertEqual(json.loads(self.run_scu("disl", "j=y")), original)
        self.assertIn("main", self.run_scu("disdl"))
        self.assertIn("delete_version version=8.1307", self.run_scu("disat"))
        self.run_scu("crev", "8.1307")
        self.store("main", b"edited")
        self.run_scu("delv", "8.1307", error="contains deck revisions")
        self.run_scu("locv", "Release")
        self.run_scu("delv", "8.1307", error="is locked")
        self.run_scu("verat")

    def test_unlock_current_version_and_relock(self):
        self.run_scu("unlv", error="already unlocked")
        self.store("main", b"first")
        self.run_scu("locv", "First lock")
        self.assertIn("Unlocked version 1.0", self.run_scu("unlv"))
        entry = self.read_library()["header"]["versions"][-1]
        self.assertFalse(entry["locked"])
        self.assertNotIn("locked_utc", entry)
        self.assertNotIn("description", entry)
        self.store("main", b"second")
        self.run_scu("locv", "Second lock")
        self.assertIn("Second lock", self.run_scu("disvh"))
        self.assertIn("First lock", self.run_scu("disat"))
        self.run_scu("crev", "1.1")
        self.run_scu("unlv", "1.0", error="Too many arguments")
        self.run_scu("unlv", error="already unlocked")
        self.assertTrue(self.read_library()["header"]["versions"][0]["locked"])
        manifest = {"format": 1, "version": "1.1", "source_archive": "archive",
                    "history": [], "files": []}
        (self.root / "manifest.json").write_text(json.dumps(manifest))
        self.run_scu("locv", "Imported", "imf=manifest.json")
        self.run_scu("unlv")
        self.run_scu("locv", "Rechecked")
        self.assertEqual(json.loads(self.run_scu("disl", "j=y"))["versions"][-1]["import_manifest"], manifest)
        self.run_scu("unlv")
        self.run_scu("delv", "1.1")
        self.run_scu("verat")

    def test_delete_populated_version_and_reuse_its_name(self):
        self.store("main", b"baseline")
        self.run_scu("locv", "Baseline")
        self.run_scu("crev", "1.1")
        self.run_scu("deld", "main")
        self.store("added", b"new")
        self.store("added", b"edited")
        working = self.root / "added"
        working.write_bytes(b"external edit")
        self.run_scu("delv", "1.0", "dr=y", error="Only the current version")
        with closing(sqlite3.connect(self.library, isolation_level=None)) as db:
            before = self.sqlite_state(db)
            db.executescript("""
                CREATE TRIGGER fail_version_deletion BEFORE INSERT ON audit_records
                WHEN json_extract(substr(NEW.line, 66), '$.saved_contents.removed_revisions') > 0
                BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END;
            """)
            self.run_scu("delv", "1.1", "dr=y", error="injected audit failure")
            self.assertEqual(self.sqlite_state(db), before)
            db.execute("DROP TRIGGER fail_version_deletion")
        self.assertIn("Removed 3 deck revision(s)", self.run_scu("delv", "1.1", "dr=y"))
        self.assertEqual(working.read_bytes(), b"external edit")
        self.assertEqual(self.read_library()["header"]["last_modified_deck"], "main")
        self.assertNotIn("added", self.run_scu("disdl"))
        self.run_scu("extd", "main", "of=check")
        self.assertEqual((self.root / "check").read_bytes(), b"baseline")
        self.run_scu("verat")
        self.run_scu("crev", "1.1")
        self.store("main", b"new revision")
        self.run_scu("locv", "Locked successor")
        self.run_scu("delv", "1.1", "dr=y", error="is locked")
        self.run_scu("verat")

    def test_version_import_manifest_lock_recovery_and_tamper_detection(self):
        self.store("main.c", b"source")
        manifest = {"format": 1, "version": "1.1", "source_archive": "archive",
                    "history": [{"description": "Original description"}], "files": []}
        path = self.root / "manifest.json"
        path.write_text(json.dumps(manifest))
        self.run_scu("locv", "Release", "imf=manifest.json", error="for version 1.0")
        manifest["version"] = "1.0"
        path.write_text(json.dumps(manifest))
        with closing(sqlite3.connect(self.library, isolation_level=None)) as db:
            db.executescript("""
                CREATE TRIGGER reject_manifest_lock BEFORE INSERT ON audit_records
                WHEN json_extract(substr(NEW.line, 66), '$.success') = 1
                BEGIN SELECT RAISE(ABORT, 'injected lock failure'); END;
            """)
            self.run_scu("locv", "Release", "imf=manifest.json", error="injected lock failure")
            self.assertEqual(db.execute("SELECT count(*) FROM version_import_manifests").fetchone(), (0,))
            db.execute("DROP TRIGGER reject_manifest_lock")
        self.run_scu("locv", "Release", "imf=manifest.json")
        document = self.read_library()
        document["header"] = json.loads(self.run_scu("disl", "j=y"))
        self.assertEqual(document["header"]["versions"][0]["import_manifest"], manifest)
        self.assertEqual(document["header"]["last_modified_deck"], "main.c")
        recovery = self.root / "recovery.json"
        recovery.write_text(json.dumps(document))
        restored = self.root / "restored.sqlite"
        self.run_scu(restored, "recl", recovery)
        self.assertEqual(json.loads(self.run_scu(restored, "disl", "j=y")), document["header"])
        self.run_scu(restored, "verat")
        with closing(sqlite3.connect(self.library, isolation_level=None)) as db:
            db.execute("UPDATE version_import_manifests SET payload = '{}'")
            self.run_scu("verat", error="checksum mismatch for version 1.0")
            db.execute("DELETE FROM version_import_manifests")
            self.run_scu("verat", error="Missing import manifest for version 1.0")

    def test_library_json_switch_and_audit_verification_abbreviation(self):
        summary = self.run_scu("disl")
        self.assertEqual(self.run_scu("disl", "json=false"), summary)
        header = json.loads(self.run_scu("disl", "json=true"))
        self.assertEqual(header["current_version"], "1.0")
        self.assertIn("versions", header)
        self.assertEqual(self.run_scu("verat"), self.run_scu("verify_audit_trail"))

    def test_only_nos_command_abbreviations_and_documented_convenience_aliases_are_shipped(self):
        catalog = json.loads(SCU.with_name("commands.json").read_bytes())
        for command in catalog["commands"]:
            words = command["name"].split("_")
            abbreviation = words[0][:3] + "".join(word[0] for word in words[1:])
            expected = [abbreviation] + {"display_command_list": ["help"], "quit_session": ["quit"]}.get(command["name"], [])
            self.assertEqual(command["aliases"], sorted(expected), command["name"])
        before = self.audit_lines()
        for spelling in ("dd", "deck_history", "ddl", "list_decks", "init", "configure", "modify_library",
                         "q", "show_library", "shol", "verify_audit", "vera", "--help", "-h"):
            with self.subTest(spelling=spelling):
                self.run_scu(spelling, error=f'Unknown command "{spelling}"')
        self.assertEqual(self.audit_lines(), before)
        self.assertEqual(self.run_scu("help"), self.run_scu("discl"))


    def test_explicit_empty_output_argument_preserves_working_file(self):
        expected = 'Expected a Windows output filename' if WINE or os.name == 'nt' else 'Expected a file path'
        self.store("main.pas", b"stored main\n")
        self.store("shared.inc", b"stored shared\n")
        working = self.root / "main.pas"
        working.write_bytes(b"unsaved work\n")
        for command in ("extract_deck",):
            with self.subTest(command=command):
                result = self.invoke(
                    [SCU, command, 'output_file=', 'main.pas'],
                    cwd=self.root, capture_output=True, text=True, timeout=5,
                )
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(expected, result.stderr)
                self.assertEqual(working.read_bytes(), b"unsaved work\n")
        result = self.invoke([SCU], cwd=self.root, input='extd of="" main.pas\n',
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(expected, result.stderr)
        self.assertEqual(working.read_bytes(), b"unsaved work\n")


    def test_deck_version_increments_and_rollover_are_per_deck(self):
        header = self.read_library()["header"]
        self.assertEqual((header["version_increment"], header["revision_increment"]), ("0.01", "0.001"))
        self.run_scu("configure_library", "version_increment=0.03", "revision_increment=0.333")
        self.store("main.pas", b"zero\n")
        self.store("other", b"unrelated\n")
        for source in (b"one\n", b"two\n", b"old release\n"):
            self.store("main.pas", source)
        self.assertEqual([entry["deck_revision"] for entry in self.read_library()["revisions"]],
                         ["0.000", "0.000", "0.333", "0.666", "0.999"])
        unchanged = self.read_library()
        (self.root / "input").write_bytes(b"beyond the revision limit\n")
        self.run_scu("import_deck", "main.pas", "input", error="has reached the revision limit")
        self.assertEqual(self.read_library(), unchanged)
        self.run_scu("lock_version", "Test version")
        self.assertEqual(self.run_scu("create_version"), "Created version 1.03")
        self.assertTrue(self.run_scu("disd", "main.pas").splitlines()[2].startswith("1.0-0.999 "))
        self.store("main.pas", b"new release\n")
        self.assertTrue(self.run_scu("disd", "main.pas").splitlines()[2].startswith("1.03-0.000 "))
        expected_patch = "-old release\n+new release"
        self.assertIn(expected_patch, self.run_scu("display_deck_diff", "output_format=unified"))
        self.assertIn(expected_patch, self.run_scu("display_deck_diff", "main.pas", "1.0-0.999", "1.03-0.000", "output_format=unified"))
        self.run_scu("extract_deck", "main.pas", "old", "version=1.0-0.999")
        self.assertEqual((self.root / "old").read_bytes(), b"old release\n")
        self.run_scu("configure_library", "ri=0.002")
        self.store("main.pas", b"next edit\n")
        history = self.run_scu("disd", "main.pas").splitlines()
        self.assertEqual([line.split()[0] for line in history[2:5]],
                         ["1.03-0.002", "1.03-0.000", "1.0-0.999"])
        self.assertEqual(self.table_data(self.run_scu("disdl")), "main.pas\t1.03-0.002\nother\t1.0-0.000")


    def test_create_deck_creates_empty_or_imported_first_revisions(self):
        empty_digest = hashlib.sha1(b"").hexdigest()
        self.assertEqual(self.run_scu("create_deck", "Empty.pas"),
                         "Empty.pas version 1.0 revision 0.000, deck version 1.0-0.000")
        source = b"// initial source\r\n\x00\xff"
        (self.root / "initial source").write_bytes(source)
        digest = hashlib.sha1(source).hexdigest()
        self.assertEqual(self.run_scu("cred", "dn=Imported.pas", "ff=initial source"),
                         "Imported.pas version 1.0 revision 0.000, deck version 1.0-0.000")
        self.assertEqual([entry["sha1"] for entry in self.read_library()["revisions"]],
                         [empty_digest, digest])
        self.run_scu("extract_deck", "Empty.pas", "empty-output")
        self.run_scu("extract_deck", "Imported.pas", "imported-output")
        self.assertEqual((self.root / "empty-output").read_bytes(), b"")
        self.assertEqual((self.root / "imported-output").read_bytes(), source)

        unchanged = self.read_library()
        self.run_scu("create_deck", "Imported.pas", "initial source", error="already exists")
        self.run_scu("create_deck", "unreadable", "from_file=missing", error="Could not open missing")
        self.assertEqual(self.read_library(), unchanged)
        self.run_scu("lock_version", "Test version")
        self.run_scu("create_deck", "new.pas", error="is locked")
        self.run_scu("create_version", "1.1")
        self.run_scu("create_deck", "Empty.pas", error="already exists")

        result = self.invoke([SCU], cwd=self.root, input="create_deck new.pas\nquis\n",
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertIn("new.pas version 1.1 revision 0.000", result.stdout)
        self.assertEqual(len(self.read_library()["revisions"]), 3)

        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        creates = [event["parameters"] for event in events if event.get("command") == "create_deck"]
        self.assertEqual(creates[:2], [{"deck_name": "Empty.pas"},
                                      {"deck_name": "Imported.pas", "from_file": "initial source"}])
        self.assertIn("interrupted=0", self.run_scu("verify_audit_trail"))


    def test_library_version_selectors_work_consistently_across_commands(self):
        self.store("main", b"old")
        self.run_scu("locv", "d=First")
        self.run_scu("crev", "1.1")
        self.store("main", b"current")
        directory = self.root / "output"
        directory.mkdir()
        for selector, version, expected in (("scu$previous_version", "1.0", b"old"),
                                             ("scu$current_version", "1.1", b"current")):
            for command in ("disdl", "disv"):
                self.assertIn(version, self.run_scu(command, "v=" + selector))
            self.run_scu("extv", "v=" + selector, "od=" + str(directory))
            self.assertEqual((directory / "main").read_bytes(), expected)
            self.run_scu("relv", "v=" + selector, "od=" + str(directory))
            self.assertEqual((directory / "main").read_bytes(), expected)
            self.assertIn("Verified 1", self.run_scu("verd", "v=" + selector, "od=" + str(directory)))
        for command in ("extd",):
            help_text = self.run_scu("disc", command)
            self.assertNotIn("Mutually exclusive", help_text)
            self.assertIn("version=1.1 revision=0.001", help_text)
        for command in ("disdl", "disv", "verd"):
            self.assertNotIn("revision (r)", self.run_scu("disc", command))
        self.run_scu("verify_audit_trail")


    def test_extract_version_lists_all_overwrite_conflicts_before_writing(self):
        for deck in ("absent", "edited", "identical", "untracked"):
            self.store(deck, b"stored source")
        directory = self.root / "outputs"
        directory.mkdir()
        self.run_scu("extd", "edited", "of=outputs/edited")
        manifest = directory / ".scu-exports.json"
        before = manifest.read_bytes()
        (directory / "edited").write_bytes(b"local edit")
        (directory / "identical").write_bytes(b"stored source")
        (directory / "untracked").write_bytes(b"untracked work")
        self.run_scu("conl", "build_command=echo built > build-marker")
        result = self.run_scu("extv", "od=outputs", error="require overwrite=yes. No decks were extracted.")
        self.assertEqual(self.table_data(result).splitlines(),
                         ["edited\t1.0-0.000\tLocally modified\tedited", "untracked\t1.0-0.000\tUntracked\tuntracked"])
        self.assertEqual(manifest.read_bytes(), before)
        self.assertFalse((directory / "absent").exists())
        self.assertFalse((self.root / "build-marker").exists())
        self.assertEqual((directory / "edited").read_bytes(), b"local edit")
        self.assertEqual((directory / "untracked").read_bytes(), b"untracked work")
        self.assertIn("Wrote 3 deck(s)", self.run_scu("extv", "od=outputs", "o=y", "b=n"))
        self.run_scu("verat")

    def test_extract_version_lists_the_complete_snapshot_with_latest_deck_versions(self):
        self.store("inherited", b"inherited")
        self.store("removed", b"removed")
        self.run_scu("locv", "d=First")
        self.run_scu("crev", "1.1")
        self.store("zebra", b"first")
        self.store("alpha", b"alpha")
        self.store("zebra", b"latest")
        self.run_scu("deld", "removed")
        expected = ["Deck name  Deck version  Status", "alpha      1.1-0.000     Created",
                    "inherited  1.0-0.000     Created", "zebra      1.1-0.001     Created", "Wrote 3 deck(s) for version 1.1"]
        self.assertEqual(self.run_scu("extv").splitlines(), expected)
        self.assertEqual((self.root / "alpha").read_bytes(), b"alpha")
        self.assertEqual((self.root / "zebra").read_bytes(), b"latest")
        self.assertEqual((self.root / "inherited").read_bytes(), b"inherited")
        self.assertFalse((self.root / "removed").exists())
        timestamp = (self.root / "alpha").stat().st_mtime_ns
        repeated = self.run_scu("extv").splitlines()
        self.assertEqual(repeated, [row.replace("Created", "Unchanged") for row in expected[:-1]] + ["Wrote 0 deck(s) for version 1.1, 3 unchanged"])
        self.assertEqual((self.root / "alpha").stat().st_mtime_ns, timestamp)
        outcome = json.loads(self.audit_lines()[-1].split(b" ", 1)[1])
        self.assertEqual(outcome["detail"], repeated[-1])
        (self.root / "zebra").unlink()
        (self.root / "alpha").write_bytes(b"local edit")
        mixed = self.run_scu("extv", "o=y").splitlines()
        self.assertEqual(mixed, [expected[0], "alpha      1.1-0.000     Replaced",
                                 "inherited  1.0-0.000     Unchanged", "zebra      1.1-0.001     Created",
                                 "Wrote 2 deck(s) for version 1.1, 1 unchanged"])
        self.assertEqual((self.root / "zebra").read_bytes(), b"latest")
        manifest = json.loads((self.root / ".scu-exports.json").read_bytes())
        self.assertEqual({e["deck_name"]: e["deck_version"] for e in manifest["files"]},
                         {"alpha": "1.1-0.000", "zebra": "1.1-0.001", "inherited": "1.0-0.000"})
        self.run_scu("locv", "d=Second")
        self.run_scu("crev", "1.2")
        self.assertIn("Wrote 0 deck(s) for version 1.2, 3 unchanged", self.run_scu("extv"))
        self.run_scu("verify_audit_trail")


    def test_verify_decks_flags_older_root_revision_and_honors_selected_version(self):
        self.store("main", b"old")
        self.run_scu("locv", "d=First")
        self.run_scu("crev", "1.1")
        self.store("main", b"current")
        self.run_scu("extd", "main", "output", "v=1.0", "r=0.000")
        output = self.run_scu("verd", "od=.", error="need attention")
        self.assertIn("outdated", output)
        self.assertIn("1.0-0.000", output)
        self.assertIn("1.1-0.000", output)
        self.assertIn("Verified 1", self.run_scu("verd", "od=.", "--version", "1.0"))
        self.run_scu("extd", "main", "output")
        (self.root / "output").write_bytes(b"local")
        output = self.run_scu("verd", "od=.", error="need attention")
        self.assertIn("locally modified", output)
        self.assertNotIn("outdated", output)


    def test_verify_decks_handles_untracked_files_and_never_creates_a_manifest(self):
        self.store("main", b"source")
        (self.root / "main").write_bytes(b"source")
        self.assertIn("untracked", self.run_scu("verd", "od=.", error="need attention"))
        self.assertFalse((self.root / ".scu-exports.json").exists())
        directory = self.root / "empty"
        directory.mkdir()
        self.assertIn("Verified 0", self.run_scu("verd", "od=empty"))
        self.assertFalse((directory / ".scu-exports.json").exists())
        help_text = self.run_scu("disc", "verd")
        self.assertIn("verify_decks, verd", help_text)
        self.assertIn("version (v) : string = scu$current_version", help_text)


    def test_import_deck_uses_an_existing_named_deck_regardless_of_filename(self):
        self.store("main.pas", b"old", "cp=#")
        self.run_scu("extd")
        source = self.root / "unrelated.anything"
        source.write_bytes(b"new\0\xff\n#SCU_COPY part\n")
        result = self.run_scu("impd", "main.pas", source.name)
        self.assertIn("1.0-0.001", result)
        self.assertEqual(self.read_library()["revisions"][-1]["deck"], "main.pas")
        self.assertEqual(self.read_library()["revisions"][-1]["comment_prefix"], "#")
        self.run_scu("extd", "main.pas", "check")
        self.assertEqual((self.root / "check").read_bytes(), source.read_bytes())
        self.run_scu("impd", "source_file=" + source.name, error="Specify deck_name")
        self.run_scu("impd", "dn=main.pas", "source_file=" + source.name)
        self.assertEqual(self.read_library()["revisions"][-1]["deck_revision"], "0.001")
        self.assertEqual(self.read_library()["header"]["last_modified_deck"], "main.pas")
        event = json.loads(self.audit_lines()[-2].split(b" ", 1)[1])
        self.assertEqual(event["command"], "import_deck")
        self.assertEqual(event["parameters"]["deck_name"], "main.pas")
        self.assertEqual(source.read_bytes(), b"new\0\xff\n#SCU_COPY part\n")
        self.run_scu("verify_audit_trail")


    def test_version_and_deck_revision_select_independently_with_inheritance(self):
        self.store("main", b"first")
        self.store("unrelated", b"unrelated")
        self.store("main", b"second")
        self.run_scu("locv", "d=First")
        self.run_scu("crev", "1.1")
        self.store("unrelated", b"changed")
        self.run_scu("extd", "main", "inherited")
        self.assertEqual((self.root / "inherited").read_bytes(), b"second")
        end = json.loads(self.audit_lines()[-1].split(b" ", 1)[1])
        self.assertEqual(end["deck_version"], "1.0-0.001")
        self.assertEqual(end["snapshot"], {"version": "1.1", "library_revision": 4})
        self.run_scu("extd", "main", "missing", "r=0.001", error='has no deck version "1.1-0.001"')
        for arguments in (("v=1.0", "r=0.000"), ("version=1.0-0.000",),
                          ("--version", "1.0", "--revision", "0.000")):
            self.run_scu("extd", "main", "old", *arguments)
            self.assertEqual((self.root / "old").read_bytes(), b"first")
            end = json.loads(self.audit_lines()[-1].split(b" ", 1)[1])
            self.assertEqual(end["deck_version"], "1.0-0.000")
            self.assertEqual(end["resolved_deck"], "main")
            self.assertEqual(end["snapshot"], {"version": "1.0", "library_revision": 3})
        self.store("main", b"current")
        self.run_scu("extd", "main", "current", "r=0.000")
        self.assertEqual((self.root / "current").read_bytes(), b"current")
        self.run_scu("verify_audit_trail")


    def test_deck_revision_validation_and_tombstones_preserve_output(self):
        self.store("main", b"original")
        self.run_scu("deld", "main")
        self.run_scu("cred", "main")
        output = self.root / "result"
        output.write_bytes(b"keep")
        for command in ("extd",):
            for value in ("1", "-0.001", "0.0001", "1e-3", "nan", "", "0x1", "99999999999999999999999"):
                self.run_scu(command, "main", "result", "r=" + value, error="Expected a deck revision")
                self.assertEqual(output.read_bytes(), b"keep")
            self.run_scu(command, "main", "result", "r=0.001", error="is deleted at deck version 1.0-0.001")
            self.run_scu(command, "main", "result", "v=1.0-0.000", "r=0.000",
                         error="complete deck version without revision")
            self.assertEqual(output.read_bytes(), b"keep")
        self.run_scu("extd", "main", "result", "r=0.000", "overwrite=yes")
        self.assertEqual(output.read_bytes(), b"original")
        self.run_scu("extd", "main", "result", "r=0.002")
        self.assertEqual(output.read_bytes(), b"")
        self.run_scu("verify_audit_trail")


    def test_version_history_accepts_positional_named_and_mixed_parameters(self):
        self.run_scu("locv", "description=First\nMore detail")
        self.run_scu("crev", "1.1")
        short = self.run_scu("disvh", "display_description=short", "limit=0")
        for arguments in (("short", "0"), ("s", "0"), ("dd=s", "0"), ("l=0", "short"),
                          ("--display_description", "s", "--limit", "0"),
                          ("--dd=s", "--l=0")):
            with self.subTest(arguments=arguments):
                self.assertEqual(self.run_scu("disvh", *arguments), short)
                event = json.loads(self.audit_lines()[-2].split(b" ", 1)[1])
                self.assertEqual(event["parameters"], {"display_description": "short", "limit": "0"})
                self.assertNotIn("options", event)
        full = self.run_scu("disvh", "dd=full", "limit=0")
        self.assertEqual(self.run_scu("disvh", "f", "0"), full)
        self.assertEqual(self.run_scu("disvh", "full"), self.run_scu("disvh", "dd=full"))
        self.run_scu("disvh", "s", "many", error="Expected integer value for limit")
        self.run_scu("disvh", "s", "0", "extra", error="Too many arguments")
        self.run_scu("disvh", "short", "dd=f", error="Duplicate argument display_description")
        self.run_scu("disvh", "short", "0", "l=1", error="Duplicate argument limit")
        self.run_scu("verify_audit_trail")


    def test_version_history_limit_selects_recent_versions_including_current(self):
        for index in range(12):
            self.run_scu("locv", "description=" + f"Release {index}\nMore detail")
            self.run_scu("crev", f"1.{index + 1:02d}")
        entries = self.read_library()["header"]["versions"]
        def names(output):
            return [re.split(r" {2,}", line, maxsplit=3)[0] for line in output.splitlines()[1:]]
        expected = [entry["name"] for entry in entries]
        output = self.run_scu("disvh")
        self.assertEqual(names(output), expected[-10:])
        self.assertIn("open", output.splitlines()[-1])
        self.assertEqual(names(self.run_scu("disvh", "limit=1")), expected[-1:])
        self.assertEqual(names(self.run_scu("disvh", "l=3")), expected[-3:])
        self.assertEqual(names(self.run_scu("disvh", "--limit", "0")), expected)
        self.assertEqual(names(self.run_scu("disvh", "limit=100")), expected)
        self.assertEqual(names(self.run_scu("disvh", "limit=9223372036854775807")), expected)
        full = self.run_scu("disvh", "limit=2", "dd=f")
        self.assertEqual(re.findall(r"^(1\.\d+)  +", full, re.M), expected[-2:])
        self.assertIn("\nRelease 11\nMore detail\n", full)
        self.assertEqual(self.read_library()["header"]["versions"], entries)
        self.run_scu("locv", "d=Current is locked")
        self.assertEqual(names(self.run_scu("disvh", "limit=1")), expected[-1:])
        self.assertIn("locked", self.run_scu("disvh", "limit=1").splitlines()[-1])
        self.run_scu("verify_audit_trail")


    def test_version_history_defaults_to_first_description_line_and_can_show_full_text(self):
        description = 'First line\nSecond line\n\nLast line with "quotes"'
        self.run_scu("locv", "description=" + description)
        entry = self.read_library()["header"]["versions"][0]
        prefix = f'{"1.0":<7}  {"locked":<6}  {self.local_stamp(entry["locked_utc"])}  '
        expected = f'{"Version":<7}  {"Status":<6}  {"Locked (local TZ)":<29}  Description\n' + prefix + "First line"
        self.assertEqual(self.run_scu("disvh"), expected)
        self.assertEqual(self.run_scu("disvh", "display_description=short"), expected)
        self.assertEqual(self.run_scu("disvh", "dd=SHORT"), expected)
        full = self.run_scu("disvh", "display_description=full")
        self.assertEqual(full.split("\n", 2)[2], description)
        self.assertEqual(self.run_scu("disvh", "--dd", "FULL"), full)
        self.assertEqual(self.read_library()["header"]["versions"][0], entry)
        audit = self.audit_lines()
        self.run_scu("disvh", "dd=invalid", error="Expected one of [short (s), full (f)] for display_description")
        self.assertEqual(self.audit_lines(), audit)
        help_text = self.run_scu("display_command", "disvh")
        self.assertIn("display_description (dd) : enum [short (s), full (f)] = short", help_text)
        self.run_scu("crev", "1.1")
        self.assertEqual(re.split(r" {2,}", self.run_scu("disvh").splitlines()[-1]), ["1.1", "open", "None"])
        self.run_scu("verify_audit_trail")


    def test_version_history_short_handles_crlf_and_empty_first_lines(self):
        for version, description, first in (("1.0", "First\r\nSecond", "First"),
                                            ("1.1", "Next\rSecond", "Next"),
                                            ("1.2", "\nLater", "")):
            if version != "1.0":
                self.run_scu("crev", version)
            self.run_scu("locv", "description=" + description)
            self.assertEqual(re.split(r" {2,}", self.run_scu("disvh").splitlines()[-1], maxsplit=3)[3:], [first] if first else [])
        self.run_scu("verify_audit_trail")


    def test_lock_version_records_description_and_utc_time(self):
        before = datetime.now().astimezone()
        self.run_scu("locv", "description=First stable release")
        after = datetime.now().astimezone()
        entry = self.read_library()["header"]["versions"][0]
        self.assertEqual(entry["description"], "First stable release")
        stamp = datetime.fromisoformat(entry["locked_utc"].replace("Z", "+00:00"))
        self.assertLessEqual(before.timestamp() - 0.001, stamp.timestamp())
        self.assertLessEqual(stamp.timestamp(), after.timestamp() + 0.001)
        self.assertEqual(self.run_scu("disvh").splitlines(), [
            f'{"Version":<7}  {"Status":<6}  {"Locked (local TZ)":<29}  Description',
            f'{"1.0":<7}  {"locked":<6}  {self.local_stamp(entry["locked_utc"])}  First stable release',
        ])
        self.run_scu("create_version", "1.1")
        self.assertEqual(re.split(r" {2,}", self.run_scu("display_version_history").splitlines()[-1]), ["1.1", "open", "None"])
        self.run_scu("cred", "main")
        self.assertEqual(self.read_library()["header"]["versions"][0], entry)
        self.run_scu("lock_version", "Second release")
        latest = self.read_library()["header"]["versions"][-1]
        self.assertEqual(latest["description"], "Second release")
        self.assertTrue(latest["locked_utc"].endswith("Z"))
        self.assertEqual(self.run_scu("disvh").splitlines()[-1],
                         f'{"1.1":<7}  {"locked":<6}  {self.local_stamp(latest["locked_utc"])}  Second release')
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        attempt = next(event for event in events if event.get("command") == "lock_version")
        self.assertEqual(attempt["parameters"], {"description": "First stable release"})
        self.assertIn("interrupted=0", self.run_scu("verify_audit_trail"))


    def test_library_names_append_sqlite_for_positional_and_named_forms(self):
        invocations = (("positional", ("positional", "inil")),
                       ("named", ("ln=named", "inil")),
                       ("long", ("--library_name", "long", "inil")),
                       ("alias", ("library_name=alias", "inil")),
                       ("flags", ("flags", "coe=yes", "inil")),
                       ("leading", ("coe=yes", "leading", "INIL")))
        for name, arguments in invocations:
            with self.subTest(arguments=arguments):
                self.run_scu(*arguments)
                path = self.root / (name + ".sqlite")
                self.assertEqual(path.read_bytes()[:16], b"SQLite format 3\0")
                self.assertFalse((self.root / name).exists())
                self.assertIn(self.argument(path), self.run_scu(name, "disl"))
                result = self.invoke([SCU, name], cwd=self.root, input="quit\n",
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.run_scu(name, "verify_audit_trail")
        self.run_scu("upper.SQLITE", "inil")
        self.assertTrue((self.root / "upper.SQLITE").exists())
        self.assertFalse((self.root / "upper.SQLITE.sqlite").exists())


    def test_library_names_reject_all_other_extensions_without_touching_files(self):
        for name in ("aap.json", "aap.db", "aap.sqlite3", "aap.JSON", "aap.backup", "aap.sqlite.bad", "aap."):
            for arguments in ((name, "inil"), ("ln=" + name, "inil"), ("--library_name", name, "inil")):
                with self.subTest(arguments=arguments):
                    self.run_scu(*arguments, error="Library filename must have the .sqlite extension")
                    for suffix in ("", ".sqlite", ".lock", ".sqlite.lock"):
                        self.assertFalse((self.root / (name + suffix)).exists())
        existing = self.root / "existing.db"
        shutil.copy2(self.library, existing)
        original = existing.read_bytes()
        self.run_scu(existing, "disl", error="Library filename must have the .sqlite extension")
        self.assertEqual(existing.read_bytes(), original)
        self.assertFalse((self.root / "existing.db.lock").exists())


    def test_library_name_selection_keeps_commands_and_unknown_command_diagnostics(self):
        self.run_scu("ln=help", "inil")
        self.assertTrue((self.root / "help.sqlite").exists())
        self.assertEqual(self.run_scu("help"), self.run_scu("discl"))
        self.assertIn("help.sqlite", self.run_scu("ln=help", "disl"))
        self.run_scu("not_a_command", error='Unknown command "not_a_command"')
        self.run_scu("not-created", "display_library", error='not-created.sqlite" does not exist')
        self.assertFalse((self.root / "not-created.sqlite").exists())


    def test_explicit_extensionless_library_path(self):
        (self.root / "libs").mkdir()
        self.run_scu("./libs/project", "inil")
        self.run_scu("./libs/project", "cred", "new")
        self.assertEqual(self.table_data(self.run_scu("./libs/project", "disdl")), "new\t1.0-0.000")
        self.run_scu("not_a_command", error='Unknown command "not_a_command"')


    def test_deck_decoder_rejects_noncanonical_base64(self):
        alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        for source, padding in ((b"a", "=="), (b"ab", "=")):
            with self.subTest(padding=padding):
                name = f"pad-{len(padding)}"
                self.store(name, source)
                document = self.read_library()
                entry = document["revisions"][-1]
                encoded = entry["zstd_base64"]
                self.assertTrue(encoded.endswith(padding))
                position = len(encoded) - len(padding) - 1
                noncanonical = alphabet[alphabet.index(encoded[position]) + 1]
                for bad in (encoded[:position] + noncanonical + padding, encoded[:-1], "!" + encoded[1:]):
                    entry["zstd_base64"] = bad
                    self.write_library(document)
                    self.run_scu("extd", name, "invalid-output", error="Invalid deck base64 encoding")
                    self.assertFalse((self.root / "invalid-output").exists())
                entry["zstd_base64"] = encoded
                self.write_library(document)


    def test_verify_audit_detects_changed_sqlite_payload(self):
        original_db = self.root / "original.sqlite"
        replacement_db = self.root / "replacement.sqlite"
        source = self.root / "source"
        for database, contents in ((original_db, b"original"), (replacement_db, b"replacement")):
            self.run_scu(database, "inil")
            source.write_bytes(contents)
            self.run_scu(database, "import_deck", "main", source.name)
        head = self.run_scu(original_db, "verify_audit_trail").split("head=")[1]
        with closing(sqlite3.connect(replacement_db)) as connection:
            payload, = connection.execute("SELECT payload FROM deck_revisions").fetchone()
        with closing(sqlite3.connect(original_db, isolation_level=None)) as connection:
            connection.execute("UPDATE deck_revisions SET payload = ? WHERE sequence = 1", (payload,))
        self.run_scu(original_db, "verify_audit_trail", "head=" + head,
                     error="Library revision 1 does not match the audit log")
        with closing(sqlite3.connect(original_db, isolation_level=None)) as connection:
            connection.execute("UPDATE deck_revisions SET payload = json_set(?, '$.size', 1)", (payload,))
        self.run_scu(original_db, "extd", "main", "tampered-output", error="size")
        with closing(sqlite3.connect(original_db, isolation_level=None)) as connection:
            connection.execute("UPDATE deck_revisions SET payload = json_set(?, '$.sha1', ?)", (payload, "0" * 40))
        self.run_scu(original_db, "extd", "main", "tampered-output", error="SHA-1")


    def sqlite_state(self, database):
        metadata = database.execute("SELECT * FROM library").fetchall()
        revisions = database.execute("SELECT * FROM deck_revisions ORDER BY sequence").fetchall()
        audit = database.execute("SELECT * FROM audit_records ORDER BY sequence").fetchall()
        return metadata, revisions, audit


    def reject_sqlite_audit_outcome(self, database):
        # Fail the success outcome only after the metadata, deck and audit begin
        # have all been written in the same transaction.
        database.execute("""
            CREATE TRIGGER reject_audit_outcome BEFORE INSERT ON audit_records
            WHEN json_extract(substr(NEW.line, 66), '$.phase') = 'end'
             AND json_extract(substr(NEW.line, 66), '$.success') = 1
             AND EXISTS (
                 SELECT 1 FROM library
                 WHERE json_extract(payload, '$.header.last_modified_deck') = 'staged'
             )
             AND EXISTS (SELECT 1 FROM deck_revisions WHERE deck_name = 'staged')
             AND EXISTS (
                 SELECT 1 FROM audit_records
                 WHERE line LIKE json_extract(substr(NEW.line, 66), '$.begin') || ' %'
             )
            BEGIN
                SELECT RAISE(ABORT, 'injected audit write failure');
            END
        """)


    def test_sqlite_audit_failure_rolls_back_one_shot_save(self):
        path = self.root / "project.sqlite"
        self.run_scu(path, "initialize_library")
        self.run_scu(path, "create_deck", "existing")
        before_head = self.run_scu(path, "verify_audit_trail")
        with closing(sqlite3.connect(path, isolation_level=None)) as database:
            before = self.sqlite_state(database)
            state = database.execute("SELECT * FROM audit_state").fetchall()
            self.reject_sqlite_audit_outcome(database)
            self.run_scu(path, "create_deck", "staged",
                         error="injected audit write failure")
            self.assertEqual(self.sqlite_state(database), before)
            self.assertEqual(database.execute("SELECT * FROM audit_state").fetchall(), state)
            self.assertEqual(self.run_scu(path, "verify_audit_trail"), before_head)
            database.execute("DROP TRIGGER reject_audit_outcome")
            self.run_scu(path, "create_deck", "staged")
            metadata, revisions, audit = self.sqlite_state(database)
            self.assertNotEqual(metadata, before[0])
            self.assertEqual([row[1] for row in revisions], ["existing", "staged"])
            self.assertEqual(audit[:-2], before[2])
            self.assertEqual(len(audit), len(before[2]) + 2)
            self.run_scu(path, "verify_audit_trail", "--head", before_head.split("head=")[1])


    def test_deck_history_and_aliases_use_canonical_audit_names(self):
        self.store("Main.pas", b"first")
        self.store("shared.inc", b"unrelated")
        self.store("Main.pas", b"second")
        self.run_scu("lock_version", "Test version")
        self.run_scu("create_version", "1.1")
        self.run_scu("lock_version", "Test version")
        self.run_scu("create_version", "1.2")
        self.store("Main.pas", b"third")
        revisions = self.read_library()["revisions"]
        expected = ['Deck "Main.pas".', "Deck version  Modified (local TZ)            Status"] + [
            f"{version + '-' + revisions[number - 1]['deck_revision']:<12}  "
            f"{self.local_stamp(revisions[number - 1]['modified_utc'])}  stored"
            for number, version in ((4, "1.2"), (3, "1.0"), (1, "1.0"))
        ]
        for arguments in (
            ("display_deck", "deck_name=Main.pas"),
            ("disd", "dn=Main.pas"),
            ("disd", "Main.pas"),
            ("DISD", "DN=Main.pas"),
        ):
            self.assertEqual(self.run_scu(*arguments).splitlines(), expected)
        self.run_scu("DISD", "DN=", "Main.pas", error="Expected integer value for limit")
        listing = self.table_data(self.run_scu("display_deck_list", "--version", "1.1"))
        self.assertEqual(self.table_data(self.run_scu("disdl", "v=1.1")), listing)
        self.assertEqual(self.table_data(self.run_scu("display_deck_list", "version=1.1")), listing)
        self.run_scu("disd", "dn=missing", error="does not exist")
        self.run_scu("disd", "Main.pas", "dn=Main.pas", error="Duplicate argument deck_name")

        records = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        displays = [event for event in records if event.get("command") == "display_deck"]
        self.assertEqual([event["parameters"] for event in displays],
                         [{"deck_name": "Main.pas", "limit": "10"}] * 4 + [{"deck_name": "missing", "limit": "10"}])
        lists = [event for event in records if event.get("command") == "display_deck_list"]
        self.assertEqual([event["parameters"] for event in lists], [{"version": "1.1"}] * 3)
        self.run_scu("verify_audit_trail")


    def test_diff_default_uses_prior_deck_revision_in_first_version(self):
        self.store("aap.c", b"first\n")
        self.run_scu("disdd", "output_format=unified", error='Deck "aap.c" has no earlier revision')
        self.store("aap.c", b"second\n")
        self.store("other", b"unrelated\n")
        output = self.run_scu("disdd", "dn=aap.c", "ts=1.0-0.001", "output_format=unified")
        self.assertIn("--- aap.c@1.0-0.000\n+++ aap.c@1.0-0.001", output)
        self.assertIn("-first\n+second", output)

        (self.root / "edited").write_bytes(b"third\n")
        result = self.invoke(
            [SCU], cwd=self.root, capture_output=True, text=True, timeout=20,
            input="import_deck aap.c edited\ndisd\ndisdd of=unified\nquis\n",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "From deck version 1.0-0.001.\nTo deck version 1.0-0.002.\n")
        self.assertIn("--- aap.c@1.0-0.001\n+++ aap.c@1.0-0.002\n", result.stdout)
        self.assertIn("-second\n+third", result.stdout)
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        outcome = events[-1]
        self.assertEqual(events[-2]["command"], "display_deck_diff")
        self.assertEqual(outcome["resolved_deck"], "aap.c")
        self.assertEqual(outcome["from_deck_version"], "1.0-0.001")
        self.assertEqual(outcome["to_deck_version"], "1.0-0.002")


    def test_diff_compares_raw_source_at_deck_versions(self):
        self.store("main.pas", b"//SCU_COPY old.inc\n' SCU$VERSION '\n")
        self.store("unrelated", b"other deck")
        self.run_scu("lock_version", "Test version")
        current = "scu$current_deck_version"
        previous = "scu$previous_deck_version"
        self.run_scu("display_deck_diff", "main.pas", previous, "output_format=unified",
                     error="has no earlier revision to compare with")
        self.run_scu("create_version", "1.1")
        self.store("main.pas", b"//SCU_COPY new.inc\n' SCU$VERSION '\n")
        old, new = "1.0-0.000", "1.1-0.000"

        def audit_outcome():
            return json.loads(self.audit_lines()[-1].split(b" ", 1)[1])

        def check_endpoints(before, after, from_deck, to_deck):
            arguments = ["main.pas"]
            if after is not None:
                arguments.insert(0, f"ts={after}")
            if before is not None:
                arguments.append(f"fs={before}")
            result = self.invoke(
                [SCU, "display_deck_diff", *arguments, "output_format=unified"],
                cwd=self.root, capture_output=True, text=True, timeout=20,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, f"From deck version {from_deck}.\nTo deck version {to_deck}.\n")
            if result.stdout:
                self.assertTrue(result.stdout.startswith(f"--- main.pas@{from_deck}\n+++ main.pas@{to_deck}\n"))
            end = audit_outcome()
            self.assertTrue(end["success"])
            self.assertEqual(end["from_deck_version"], from_deck)
            self.assertEqual(end["to_deck_version"], to_deck)
            self.assertNotIn("from_snapshot", end)
            self.assertNotIn("to_snapshot", end)
            return result.stdout

        output = check_endpoints(old, new, old, new)
        self.assertIn("-//SCU_COPY old.inc\n+//SCU_COPY new.inc\n", output)
        self.assertIn("SCU$VERSION", output)
        for before, after in ((old, current), (old, None), (previous, None), (None, None), (None, new)):
            self.assertEqual(check_endpoints(before, after, old, new), output)
        self.assertIn("-//SCU_COPY new.inc\n+//SCU_COPY old.inc\n",
                      check_endpoints(current.upper(), old, new, old))
        result = self.invoke(
            [SCU], cwd=self.root, capture_output=True, text=True, timeout=20,
            input="display_deck_diff of=unified main.pas\nquis\n",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "From deck version 1.0-0.000.\nTo deck version 1.1-0.000.\n")
        self.assertEqual(result.stdout, output)
        self.assertEqual(self.run_scu("disdd", "dn=main.pas", old, old, "output_format=unified"), "")
        self.run_scu("lock_version", "Test version")
        self.assertIn("-//SCU_COPY new.inc\n+//SCU_COPY old.inc\n",
                      check_endpoints(current, previous.upper(), new, old))
        self.run_scu("create_version", "1.2")
        self.assertEqual(check_endpoints(new, current, new, new), "")
        self.assertEqual(check_endpoints(previous, None, old, new), output)
        self.run_scu("display_deck_diff", "main.pas", old, "9.9-0.000", "output_format=unified", error='Version "9.9"')
        end = audit_outcome()
        self.assertFalse(end["success"])
        self.assertEqual(end["from_deck_version"], old)
        self.assertNotIn("to_deck_version", end)
        for selector in ("1.0", "2", "scu$current", "scu$previous"):
            self.run_scu("display_deck_diff", "main.pas", selector, "output_format=unified", error="Expected VERSION-REVISION")
        self.store("binary", b"\x00old")
        self.store("binary", b"\x00new")
        self.assertIn("Binary files binary@1.2-0.000 and binary@1.2-0.001 differ",
                      self.run_scu("display_deck_diff", "binary", "1.2-0.000", "1.2-0.001", "output_format=unified"))
        self.assertIn("interrupted=0", self.run_scu("verify_audit_trail"))


    def test_diff_ignores_whitespace_amount_changes_but_not_added_separators(self):
        cases = (
            (b"a b\n", b"a \t b \t\r\n", True),
            (b"  a\n", b"\ta\n", True),
            (b"a \t\v\f\r b\n", b"a b\n", True),
            (b"x", b"x\n", True),
            (b"x \t", b"x\n", True),
            (b" \n", b"\t\r\n", True),
            (b'"a b"\n', b'"a  b"\n', True),
            (b"ab\n", b"a b\n", False),
            (b"a\n", b" a\n", False),
            (b"a\nb\n", b"a\n\nb\n", False),
            (b"a,b\n", b"a, b\n", False),
            (b"a\xc2\xa0b\n", b"a b\n", False),
            (b"\0a  b\n", b"\0a b\n", False),
        )
        for index, (before, after, equal) in enumerate(cases):
            deck = f"whitespace-{index}"
            with self.subTest(before=before, after=after):
                self.store(deck, before)
                self.store(deck, after)
                self.assertEqual(bool(self.run_scu("disdd", deck)), not equal)
                exact = self.run_scu("disdd", deck, "isc=n")
                self.assertTrue(exact)
        self.run_scu("verify_audit_trail")


    def test_normal_diff_reports_add_delete_and_change_ranges_without_context(self):
        cases = (
            (b"a\n", b"b\n", b"1c1\n< a\n---\n> b\n"),
            (b"", b"one\ntwo\n", b"0a1,2\n> one\n> two\n"),
            (b"one\ntwo\n", b"", b"1,2d0\n< one\n< two\n"),
            (b"a\nc\n", b"a\nb\nc\n", b"1a2\n> b\n"),
            (b"a\n", b"a\nb\nc\n", b"1a2,3\n> b\n> c\n"),
            (b"a\nb\nc\n", b"a\nc\n", b"2d1\n< b\n"),
            (b"a\nb\nc\n", b"a\n", b"2,3d1\n< b\n< c\n"),
            (b"old\nkeep\n", b"keep\n", b"1d0\n< old\n"),
            (b"keep\n", b"new\nkeep\n", b"0a1\n> new\n"),
            (b"start\nold1\nold2\nend\n", b"start\nnew1\nnew2\nnew3\nend\n",
             b"2,3c2,4\n< old1\n< old2\n---\n> new1\n> new2\n> new3\n"),
            (b"a\nold\nmiddle\nold2\nend\n", b"a\nnew\nmiddle\nnew2\nend\n",
             b"2c2\n< old\n---\n> new\n4c4\n< old2\n---\n> new2\n"),
            (b"old", b"new", b"1c1\n< old\n\\ No newline at end of file\n---\n> new\n\\ No newline at end of file\n"),
        )
        for index, (old, new, expected) in enumerate(cases):
            with self.subTest(index=index):
                deck = f"normal-{index}"
                self.store(deck, old)
                self.store(deck, new)
                result = self.invoke([SCU, "disdd", deck], cwd=self.root, capture_output=True, timeout=20,
                                        env=self.diff_environment())
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)
        self.run_scu("verify_audit_trail")


    def test_version_diff_counts_each_edit_block_and_omits_binary_lines(self):
        self.store("main", b"gone\ngone again\nkeep\nold\nstay\nend")
        self.store("binary", b"\x00a")
        self.store("ignored", b"// SCU REVISION old\na b\n")
        self.run_scu("locv", "before")
        self.run_scu("crev", "1.1")
        self.store("main", b"keep\nnew\nextra\nstay\nend")
        self.store("binary", b"\x00b")
        self.store("ignored", b"// SCU REVISION new\na  b\n")
        for fmt in ("normal", "unified"):
            result = self.invoke([SCU, "disvd", "of=" + fmt], cwd=self.root,
                                 capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            if fmt == "unified":
                self.assertNotIn("Diff summary", result.stdout)
                self.assertNotIn("From version", result.stdout)
                identical = self.invoke([SCU, "disvd", "1.1", "1.1", "of=unified"], cwd=self.root,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual((identical.returncode, identical.stdout, identical.stderr), (0, "", ""))
                continue
            summary = result.stdout.split("Diff summary (2 changed)\n")[1]
            self.assertEqual(self.table_data(summary).splitlines(), [
                "binary\tModified (binary)\t-\t-\t-", "main\tModified\t1\t1\t2",
                "Total\t\t1\t1\t2"])

    def test_normal_version_diff_labels_changed_decks_and_missing_sides(self):
        self.store("main", b"before\n")
        self.store("removed", b"gone\n")
        self.store("inherited", b"unchanged\n")
        self.run_scu("locv", "d=First")
        self.run_scu("crev", "1.1")
        self.store("main", b"after\n")
        self.run_scu("deld", "removed")
        self.store("added", b"new\n")
        patch, summary = self.run_scu("disvd").split("Diff summary (3 changed)\n")
        self.assertEqual(self.table_data(summary).splitlines(), [
            "added\tAdded\t1\t0\t0", "main\tModified\t0\t1\t0",
            "removed\tDeleted\t0\t0\t1", "Total\t\t1\t1\t1"])
        self.assertEqual(patch.rstrip(),
                         "From version 1.0.\nTo version 1.1.\ndiff /dev/null added@1.1-0.000\n0a1\n> new\n"
                         "diff main@1.0-0.000 main@1.1-0.000\n1c1\n< before\n---\n> after\n"
                         "diff removed@1.0-0.000 /dev/null\n1d0\n< gone")
        outcome = json.loads(self.audit_lines()[-2].split(b" ", 1)[1])
        self.assertEqual(outcome["parameters"]["output_format"], "normal")
        self.run_scu("verify_audit_trail")


    def test_native_diff_handles_context_line_endings_and_empty_decks(self):
        unchanged = b"".join(f"line {index}\n".encode() for index in range(1, 21))
        updated = unchanged.replace(b"line 2\n", b"edit 2\n").replace(b"line 18\n", b"edit 18\n")
        large_old = b"old\n" * 600
        large_new = b"new\n" * 600
        cases = (
            (b"", b"added\n", b"@@ -0,0 +1 @@\n+added\n"),
            (b"removed\n", b"", b"@@ -1 +0,0 @@\n-removed\n"),
            (b"old\r\n\xfflast", b"new\r\n\xfflast\n",
             b"@@ -1,2 +1,2 @@\n-old\r\n-\xfflast\n\\ No newline at end of file\n+new\r\n+\xfflast\n"),
            (b"old\nlast", b"new\nlast",
             b"@@ -1,2 +1,2 @@\n-old\n+new\n last\n\\ No newline at end of file\n"),
            (unchanged, updated,
             b"@@ -1,5 +1,5 @@\n line 1\n-line 2\n+edit 2\n line 3\n line 4\n line 5\n"
             b"@@ -15,6 +15,6 @@\n line 15\n line 16\n line 17\n-line 18\n+edit 18\n line 19\n line 20\n"),
            (b"first\n" + large_old + b"last\n", b"first\n" + large_new + b"last\n",
             b"@@ -1,602 +1,602 @@\n first\n" + b"-old\n" * 600 + b"+new\n" * 600 + b" last\n"),
        )
        for revision, (before, after, expected) in enumerate(cases, start=1):
            old_revision, new_revision = 2 * revision - 1, 2 * revision
            with self.subTest(revision=old_revision):
                self.store("source", before)
                self.store("source", after)
                old, new = f"1.0-0.{old_revision - 1:03d}", f"1.0-0.{new_revision - 1:03d}"
                result = self.invoke(
                    [SCU, "display_deck_diff", "source", old, new, "ignore_space_changes=no", "output_format=unified"],
                    cwd=self.root, capture_output=True, timeout=20,
                    env=self.diff_environment(),
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                headers = f"--- source@{old}\n+++ source@{new}\n".encode()
                self.assertEqual(result.stdout, headers + expected)


    def test_release_deterministic_bytes_boundaries_binary_and_comment_preservation(self):
        source = b"//SCU$VERSION\r\n#SCU$VERSION\nXSCU$VERSION SCU$VERSION_2 SCU$Version\x00\xff SCU$DATE_TIME\r"
        self.store("main", source)
        stamp = self.read_library()["revisions"][0]["modified_utc"].encode()
        self.run_scu("relv")
        expected = b"//1.0\r\n#1.0\nXSCU$VERSION SCU$VERSION_2 SCU$Version\x00\xff " + stamp + b"\r"
        self.assertEqual((self.root / "release/main").read_bytes(), expected)
        self.run_scu("relv")
        self.assertEqual((self.root / "release/main").read_bytes(), expected)
        self.assertIn("No errors were found", self.run_scu("verd"))


    def test_release_version_name_alias_and_canonical_audit_command(self):
        self.store("main", b"SCU$VERSION")
        self.run_scu("relv")
        self.assertEqual((self.root / "release/main").read_bytes(), b"1.0")
        attempt, outcome = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()[-2:]]
        self.assertEqual(attempt["command"], "release_version")
        self.assertEqual(attempt["parameters"], {"version": "scu$current_version",
                         "output_directory": "scu$release_directory", "overwrite": "no"})
        self.assertEqual(outcome["snapshot"]["version"], "1.0")
        self.assertTrue(self.run_scu("disc", "relv").startswith("release_version, relv\n"))
        for spelling in ("expand_version", "expv"):
            self.run_scu(spelling, error="use release_version (relv)")


    def test_batch_stops_on_parse_and_execution_errors_and_saves_prior_changes(self):
        for index, failing in enumerate(("unknown_command", "cred", 'cred output comment_prefix="oops',
                                         "extd nonexistent output")):
            with self.subTest(command=failing):
                result = self.invoke(
                    [SCU], cwd=self.root, capture_output=True, text=True, timeout=20,
                    input=f"cred before{index}\n{failing}\ncred after{index}\n",
                )
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(f"before{index}\t", self.table_data(self.run_scu("disdl")))
                self.assertNotIn(f"after{index}\t", self.table_data(self.run_scu("disdl")))
                events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
                self.assertFalse(any(e.get("parameters", {}).get("deck_name") == f"after{index}"
                                     for e in events))
        self.run_scu("verify_audit_trail")


    def test_batch_continue_option_aliases_boolean_validation_and_exit_status(self):
        for index, options in enumerate((
                ["continue_on_error=yes"], ["--continue_on_error", "y"],
                ["coe=y"], ["--continue_on_error", "yes"],
                ["ln=" + str(self.library), "continue_on_error=yes"])):
            with self.subTest(options=options):
                result = self.invoke(
                    [SCU, *options], cwd=self.root, capture_output=True, text=True, timeout=20,
                    input=f"unknown_command\ncred continued{index}\n",
                )
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(f"continued{index}\t", self.table_data(self.run_scu("disdl")))
        for option in ("continue_on_error=no", "coe=n"):
            result = self.invoke([SCU, option], cwd=self.root, capture_output=True,
                                    text=True, input="unknown_command\ncred skipped\n", timeout=20)
            self.assertEqual(result.returncode, 1)
            self.assertNotIn("skipped\t", self.table_data(self.run_scu("disdl")))
        self.run_scu("continue_on_error=maybe", error="Expected one of [yes (y), no (n)]")
        self.run_scu("--continue_on_error", error="Expected a value for continue_on_error: [yes (y), no (n)]")
        self.run_scu("continue_on_error=", error="Expected one of [yes (y), no (n)]")


    def test_command_files_support_quoted_nested_paths_and_canonical_audit(self):
        directory = self.root / "scripts"
        directory.mkdir()
        (directory / "child commands.scu").write_text("cred nested\n")
        (directory / "main commands.scu").write_text(
            '\ncred parent\n! "child commands.scu"\ndisdl\n')
        result = self.invoke(
            [SCU, "ln=" + str(self.library), "!", "scripts/main commands.scu"],
            cwd=self.root, capture_output=True, text=True, input="cred after-file\n", timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("scu>", result.stdout + result.stderr)
        self.assertNotIn("after-file", self.run_scu("disdl"))
        listing = self.table_data(self.run_scu("disdl"))
        for name in ("parent", "nested"):
            self.assertIn(name + "\t", listing)
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        creates = [e for e in events if e.get("command") == "create_deck"]
        self.assertEqual([e["parameters"]["deck_name"] for e in creates],
                         ["parent", "nested"])
        self.assertFalse(any(e.get("command", "").startswith("!") for e in events))
        self.run_scu("verify_audit_trail")



    def test_unicode_library_source_paths_and_binary_bytes_roundtrip(self):
        directory = self.root / 'work 日本'
        directory.mkdir()
        library = directory / 'プロジェクト.sqlite'
        name = 'source 日本.c'
        data = b'// binary\r\n\x00\xffSCU$VERSION\r\n'
        (directory / name).write_bytes(data)
        self.run_scu(library, 'inil')
        self.run_scu(library, 'cred', 'main.c', 'from_file=' + str(directory / name))
        self.run_scu(library, 'impd', 'main.c', 'source_file=' + name)
        self.run_scu(library, 'extd', 'main.c', 'build=no')
        self.assertEqual((directory / name).read_bytes(), data)
        self.run_scu(library, 'relv')
        self.assertEqual((directory / 'release' / name).read_bytes(), data.replace(b'SCU$VERSION', b'1.0'))
        self.assertIn('No errors were found', self.run_scu(library, 'verd'))
        self.run_scu(library, 'verat')
        events = [json.loads(line.split(b' ', 1)[1]) for line in self.audit_lines(library)]
        creation = next(e for e in events if e.get('command') == 'create_deck')
        self.assertEqual(creation['parameters']['from_file'], self.argument(str(directory / name)))

    def test_build_success_and_failure_use_the_platform_shell_and_audit_outcomes(self):
        self.store('main.c', b'int main(void) { return 0; }\n')
        self.run_scu('conl', 'build_command=echo portable-build')
        self.assertIn('portable-build', self.run_scu('extd', 'main.c', 'build=yes'))
        self.run_scu('conl', 'build_command=exit 7')
        self.run_scu('extd', 'main.c', 'build=yes', error='Build command failed')
        events = [json.loads(line.split(b' ', 1)[1]) for line in self.audit_lines()]
        builds = [e for e in events if e.get('phase') == 'build']
        self.assertEqual([e['success'] for e in builds], [True, False])
        self.assertEqual((self.root / 'main.c').read_bytes(), b'int main(void) { return 0; }\n')
        self.run_scu('verat')

if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    parser.add_argument('--wine', action='store_true', help='Run a Win64 executable through Wine')
    args, remaining = parser.parse_known_args()
    try:
        configure(args.executable, args.wine)
    except ValueError as error:
        parser.error(str(error))
    unittest.main(argv=[sys.argv[0], *remaining])
